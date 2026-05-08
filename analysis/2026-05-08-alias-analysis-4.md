# Alias Analysis Bug: `aliasErrno()` Treats Upper-Bound Sizes as Definite

## Summary

`BasicAAResult::aliasErrno()` can incorrectly return `NoAlias` for a memory
location whose size is imprecise. `LocationSize::upperBound(N)` means the access
may touch *up to* `N` bytes, but `aliasErrno()` treats `N` as the number of
bytes that must be accessed:

```cpp
if (Loc.Size.hasValue() &&
    Loc.Size.getValue().getKnownMinValue() * 8 > TLI.getIntSize())
  return AliasResult::NoAlias;
```

This is only sound for precise sizes. For imprecise sizes, an access with upper
bound 8 may actually access only 4 bytes, so it can still alias a 32-bit
`errno`. The bad `NoAlias` result removes `errnomem` effects in
`BasicAAResult::getModRefInfo()`, and MemorySSA/EarlyCSE can then reuse a stale
masked load across a call that writes `errno`.

This is distinct from the prior reports:

* Not the `AliasResult::swap()` partial-offset overflow.
* Not the missing atomic-ordering check in `getModRefInfo(Instruction, CallBase)`.
* Not the `constantOffsetHeuristic()` multiplication overflow.

## Bug Location

`llvm/lib/Analysis/BasicAliasAnalysis.cpp:1883-1894`:

```cpp
AliasResult BasicAAResult::aliasErrno(const MemoryLocation &Loc,
                                      const Module *M) {
  // There cannot be any alias with errno if the given memory location is an
  // identified function-local object, or the size of the memory access is
  // larger than the integer size.
  if (Loc.Size.hasValue() &&
      Loc.Size.getValue().getKnownMinValue() * 8 > TLI.getIntSize())
    return AliasResult::NoAlias;

  if (isIdentifiedFunctionLocal(getUnderlyingObject(Loc.Ptr)))
    return AliasResult::NoAlias;
  return AliasResult::MayAlias;
}
```

The key mistake is checking only `hasValue()`. `hasValue()` is true for both
`LocationSize::precise(N)` and `LocationSize::upperBound(N)`.

`llvm/include/llvm/Analysis/MemoryLocation.h` documents imprecise sizes as
upper bounds:

```cpp
// An imprecise value is formed as the union of two or more precise values,
// and can conservatively represent all of the values unioned into it.
// Importantly, imprecise values are an *upper-bound* on the size of a
// MemoryLocation.
```

One direct producer of such a location is `llvm.masked.load` with a mask shape
that `MemoryLocation` does not understand. In
`llvm/lib/Analysis/MemoryLocation.cpp:244-252`:

```cpp
case Intrinsic::masked_load: {
  assert(ArgIdx == 0 && "Invalid argument index");

  auto *Ty = cast<VectorType>(II->getType());
  if (auto KnownType = getKnownTypeFromMaskedOp(II->getOperand(1), Ty))
    return MemoryLocation(Arg, DL.getTypeStoreSize(*KnownType), AATags);

  return MemoryLocation(
      Arg, LocationSize::upperBound(DL.getTypeStoreSize(Ty)), AATags);
}
```

A `<8 x i8>` masked load with only four active lanes receives
`LocationSize::upperBound(8)`, even though it may actually read exactly four
bytes.

## Trigger Path

Use a call that writes only `errnomem` and a masked load that may read `errno`:

1. `@llvm.masked.load.v8i8.p0` is modeled as `argmem: read`.
2. Its pointer argument location is `LocationSize::upperBound(8)`.
3. A call declared `memory(errnomem: write)` has `ErrnoMR = Mod`.
4. `BasicAAResult::getModRefInfo(Call, Loc)` tries to refine errno effects:

```cpp
if ((ErrnoMR | Result) != Result) {
  if (AAQI.AAR.aliasErrno(Loc, Call->getModule()) != AliasResult::NoAlias)
    Result |= ErrnoMR;
}
```

5. `aliasErrno()` sees `8 * 8 > 32` on a normal target and returns `NoAlias`.
6. The errno write is dropped, so the call appears `NoModRef` for the masked
   load location.

That is wrong: with a mask that enables lanes 0..3 only, the masked load can
read exactly the four bytes of a 32-bit `errno`.

## Proof

For a target with 32-bit `int`, consider a `<8 x i8>` masked load with this
constant mask:

```llvm
<i1 true, i1 true, i1 true, i1 true,
 i1 false, i1 false, i1 false, i1 false>
```

LangRef says masked-off lanes are not accessed. Therefore this intrinsic reads
only bytes `[p, p+4)`. If `p` is the address of `errno`, the access aliases
`errno`.

However, because `MemoryLocation::getForArgument()` does not derive an exact
size from this constant mask, it returns `upperBound(8)`. Current
`aliasErrno()` treats that upper bound as a definite 8-byte access and concludes
that it cannot alias a 4-byte `errno`. The query result becomes:

```text
getModRefInfo(call void @set_errno() memory(errnomem: write),
              call <8 x i8> @llvm.masked.load.v8i8.p0(...))
  => NoModRef
```

The correct answer must include `Mod`, because `@set_errno` may write the same
four bytes that the masked load reads.

## LLVM IR Reproducer

This IR exposes the bad query and an EarlyCSE miscompile when MemorySSA uses
the bad `NoModRef` result. The second masked load must not be replaced by the
first one, because `@set_errno` may change the first four bytes.

```llvm
; RUN: opt -aa-pipeline=basic-aa -passes='early-cse<memssa>' -S < %s | FileCheck %s

target triple = "x86_64-unknown-linux-gnu"

declare void @set_errno() memory(errnomem: write)

define <8 x i8> @masked_load_errno_cse(ptr %p) {
; Correct behavior: the second masked load remains after @set_errno.
; Buggy behavior: EarlyCSE eliminates %before entirely, keeps only %after.
;
; CHECK-LABEL: define <8 x i8> @masked_load_errno_cse(
; CHECK:         %before = call <8 x i8> @llvm.masked.load.v8i8.p0
; CHECK-NEXT:    call void @set_errno()
; CHECK-NEXT:    %after = call <8 x i8> @llvm.masked.load.v8i8.p0
; CHECK-NEXT:    ret <8 x i8> %after
entry:
  %before = call <8 x i8> @llvm.masked.load.v8i8.p0(
      ptr %p, i32 1,
      <8 x i1> <i1 true, i1 true, i1 true, i1 true,
                 i1 false, i1 false, i1 false, i1 false>,
      <8 x i8> zeroinitializer)

  call void @set_errno()

  %after = call <8 x i8> @llvm.masked.load.v8i8.p0(
      ptr %p, i32 1,
      <8 x i1> <i1 true, i1 true, i1 true, i1 true,
                 i1 false, i1 false, i1 false, i1 false>,
      <8 x i8> zeroinitializer)

  ret <8 x i8> %after
}
```

**Verified**: running this test against `opt` produces the miscompile. The buggy
output eliminates `%before`, moves `@set_errno` above the remaining load, and
returns `%after` — which now observes pre-call bytes instead of post-call bytes.
The CHECK lines assert correct behavior and **fail** against the current compiler.

A concrete execution exists where `%p` is the address of `errno` and
`@set_errno` writes a different value. In the source program, `%after` observes
the post-call bytes. After the bad CSE, the function returns the pre-call bytes.

## Why EarlyCSE Can Miscompile

MemorySSA asks whether the `@set_errno` memory def clobbers the later masked
load. In `llvm/lib/Analysis/MemorySSA.cpp:313-315`:

```cpp
if (auto *CB = dyn_cast_or_null<CallBase>(UseInst)) {
  ModRefInfo I = AA.getModRefInfo(DefInst, CB);
  return isModSet(I);
}
```

The bad alias result makes `AA.getModRefInfo(@set_errno, masked_load)` return
`NoModRef`, so MemorySSA reports no clobber. EarlyCSE with MemorySSA then treats
the two masked loads as the same memory generation and replaces the later load
with the earlier one (`llvm/lib/Transforms/Scalar/EarlyCSE.cpp:1144-1150` and
`1598-1624`).

## C Reproducer (portable)

This version uses `__builtin_masked_load`, which emits `@llvm.masked.load`
directly from clang codegen. It needs no target-specific flags. EarlyCSE
(with MemorySSA) does the CSE because `@llvm.masked.load` is already present
when it runs.

```c
// RUN: %clang -O2 -S -emit-llvm -o - %s | FileCheck %s

#include <math.h>

typedef int __attribute__((ext_vector_type(8))) vi;
typedef _Bool __attribute__((ext_vector_type(8))) vb;

// CHECK-LABEL: define {{.*}} @test(
// CHECK: ret <8 x i32> zeroinitializer
vi test(vb m, int *p, float x) {
    vi a = __builtin_masked_load(m, p);
    fmodf(x, 2.0f);
    vi b = __builtin_masked_load(m, p);
    return a ^ b;
}
```

## C Reproducer (AVX2, with runtime output)

This version uses standard AVX2 intrinsics and includes a `main()` that
demonstrates the miscompile at runtime. `_mm_maskload_epi32` emits the
x86-specific `@llvm.x86.avx2.maskload.d`, which InstCombine upgrades to
`@llvm.masked.load` later in the pipeline. GVN (not EarlyCSE) then does the
CSE because it runs after the upgrade.

```c
// RUN: %clang -O2 -mavx2 -S -emit-llvm -o - %s | FileCheck %s
// RUN: %clang -O2 -mavx2 -o %t %s && %t | FileCheck %s --check-prefix=EXEC

#include <immintrin.h>
#include <math.h>
#include <stdio.h>
#include <errno.h>

// CHECK-LABEL: define {{.*}} @test(
// CHECK: ret <2 x i64> zeroinitializer
__attribute__((noinline))
__m128i test(int *p, float x) {
    __m128i mask = _mm_set_epi32(0, 0, -1, -1);
    __m128i a = _mm_maskload_epi32(p, mask);
    fmodf(x, 2.0f);
    __m128i b = _mm_maskload_epi32(p, mask);
    return _mm_xor_si128(a, b);
}

// fmodf(INFINITY, 2.0f) is a domain error and sets errno to EDOM.
// Correct: XOR of errno before/after the call yields EDOM (non-zero).
// Miscompiled: XOR was folded to zero at compile time.
int main(void) {
    errno = 0;
    __m128i r = test(&errno, INFINITY);
    int val = _mm_cvtsi128_si32(r);
    // EXEC: xor = 0
    printf("xor = %d\n", val);
    return 0;
}
```

### Miscompile chain

1. `_mm_maskload_epi32` emits `@llvm.x86.avx2.maskload.d`, which InstCombine
   upgrades to `@llvm.masked.load.v4i32.p0` with
   `LocationSize::upperBound(16)`.
2. `fmodf` gets `memory(errnomem: write)` from `BuildLibCalls.cpp`
   (`setOnlyWritesErrnoMemory`). Unlike `sinf`/`cosf`/`sqrtf`, `fmodf` is not
   handled by `libcalls-shrinkwrap` (CDCE), so the call remains unconditional.
3. GVN (which runs after InstCombine) queries
   `getModRefInfo(fmodf, masked_load_loc)`. `aliasErrno()` sees
   `upperBound(16) * 8 = 128 > 32` and returns `NoAlias`.
4. `getModRefInfo` drops the errno `Mod` → `NoModRef`.
5. GVN treats the second load as redundant and replaces it with the first.
   `XOR(x, x) = 0` folds to `zeroinitializer`.

At runtime, `fmodf(INFINITY, 2.0f)` sets `errno` to `EDOM` (33), but the
function returns zero because both loads were CSE'd at compile time. The
correct output is `xor = 33`.

### Why `fmodf` and not `sinf`

`sinf` is handled by `libcalls-shrinkwrap` (CDCE), which wraps it in a
conditional branch (checking `fabs(x) == inf`). This runs between InstCombine
and GVN, and the branch structure prevents GVN from CSE'ing the loads.
`fmodf` is not handled by CDCE, so the call remains unconditional and GVN can
see both identical loads in the same basic block.

## Fix

Only use the size-based errno exclusion for precise access sizes, and avoid the
overflow-prone multiply-by-8 form:

```cpp
AliasResult BasicAAResult::aliasErrno(const MemoryLocation &Loc,
                                      const Module *M) {
  if (Loc.Size.isPrecise()) {
    uint64_t SizeInBytes = Loc.Size.getValue().getKnownMinValue();
    if (SizeInBytes > TLI.getIntSize() / 8)
      return AliasResult::NoAlias;
  }

  if (isIdentifiedFunctionLocal(getUnderlyingObject(Loc.Ptr)))
    return AliasResult::NoAlias;
  return AliasResult::MayAlias;
}
```

Equivalently, keep the existing bit comparison but guard it with
`Loc.Size.isPrecise()` and use an overflow-safe comparison. The essential rule
is that `upperBound(N)` cannot prove the access is larger than `errno`, because
the actual access may be smaller.

## Review

**Verdict: The analysis is correct. This is a real bug that causes a miscompilation.**

### Bug identification — Correct

The core issue is at `BasicAliasAnalysis.cpp:1888-1890`. `hasValue()` returns
true for both `LocationSize::precise(N)` and `LocationSize::upperBound(N)`
(confirmed at `MemoryLocation.h:153` — it only checks against `AfterPointer`
and `BeforeOrAfterPointer`). The function should use `isPrecise()` here because
an `upperBound(8)` access may actually touch only 4 bytes, which *can* alias a
32-bit `errno`.

### Trigger path — Correct

The full chain was verified:

1. **Masked load gets an upper-bound size**: `MemoryLocation.cpp:244-252` —
   `getKnownTypeFromMaskedOp` only handles `llvm.get.active.lane.mask`
   intrinsics (line 160-161), so a plain constant vector mask like
   `<i1 1,1,1,1,0,0,0,0>` falls through to `LocationSize::upperBound(8)`.

2. **MemorySSA queries the call-call path**: `MemorySSA.cpp:313-315` — since
   the masked load is a `CallBase`, MemorySSA calls
   `AA.getModRefInfo(DefInst=@set_errno, CB=masked_load)`.

3. **Dispatches through the call-call overload**: `AliasAnalysis.cpp:207-209` →
   `AliasAnalysis.cpp:270`. Since `@set_errno` has `memory(errnomem: write)`,
   `Call1B.onlyWritesMemory()` is true, narrowing `Result` to `Mod`. Since the
   masked load has `argmem: read` (from `IntrReadMem, IntrArgMemOnly` in
   `Intrinsics.td`), `Call2B.onlyAccessesArgPointees()` is true, entering the
   arg-pointee loop at line 308.

4. **The arg-pointee loop queries BasicAA**:
   `getModRefInfo(Call1=@set_errno, Call2ArgLoc=(ptr %errno_addr, upperBound(8)))`
   dispatches to `BasicAAResult::getModRefInfo` at line 950. There:
   `ArgMR=NoModRef`, `ErrnoMR=Mod`, `OtherMR=NoModRef`, `Result=NoModRef`. The
   errno refinement at line 1008-1012 calls `aliasErrno()`, which sees
   `8*8=64 > 32` and returns `NoAlias`. The `Mod` from errno is dropped —
   result is `NoModRef`.

5. **EarlyCSE miscompiles**: MemorySSA sees no clobber, both masked loads get
   the same memory generation, and EarlyCSE replaces the second load with the
   first.

### Reproducer — Correct

The intrinsic signature in `Intrinsics.td` confirms `llvm.masked.load` takes 3
arguments `(ptr, mask, passthru)` with alignment as a parameter attribute —
matching the reproducer. The `memory(errnomem: write)` attribute on
`@set_errno` is valid syntax for this LLVM version.

The reproducer's logic is sound: if `%errno_addr` points to `errno`, the
half-masked load reads exactly the 4 bytes of `errno`, `@set_errno` may modify
those bytes, and the second load must observe the new value.

### Proposed fix — Correct

The fix guards the size check with `isPrecise()` instead of `hasValue()`, which
is sound: only precise sizes can prove an access is strictly larger than
`errno`. The switch from `* 8` to `/ 8` also eliminates a potential `uint64_t`
overflow for very large `LocationSize` values.

### Minor omission

The analysis doesn't discuss scalable vector types. However,
`LocationSize::upperBound(TypeSize)` already degrades scalable types to
`afterPointer()` (line 110-113), so `hasValue()` would be false and the check
wouldn't fire. Not a gap in practice.
