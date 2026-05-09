# BasicAA loses the address change from `llvm.ptrmask` during GEP decomposition

## Correction

The long-chain / complex-CFG BasicAA issue I checked first is already fixed in
this checkout. The relevant regression is
`llvm/test/Transforms/SLPVectorizer/X86/pr98978.ll`, and the local `opt`
behavior no longer reproduces that bad `NoAlias`.

The matrix-intrinsic issue is also prior work now: it is covered by
`/home/terrelln/.llms/2026-05-08-alias-analysis-7.md`, so I am not re-reporting
it here.

The current, distinct BasicAA bug I found is in GEP decomposition through
`llvm.ptrmask`. It is practical: it needs only pointer alignment and a small
mask such as `-2`, not offsets near `2^64` or a giant allocation.

## Summary

`BasicAAResult::DecomposeGEPExpression()` looks through calls reported by
`getArgumentAliasingToReturnedPointer(Call, false)`. That helper includes
`llvm.ptrmask`.

That is valid for underlying-object and capture analysis: `ptrmask(%p, %mask)`
is based on the same underlying object as `%p`. It is not valid for BasicAA's
symbolic GEP offset decomposition, because `ptrmask` can change the pointer
address.

For example, if `%base` is 2-byte aligned:

```text
%p = %base + 1
%q = ptrmask(%p, -2)    ; clears the low bit, so %q == %base
%r = %q + 1             ; %r == %p
```

BasicAA currently decomposes `%r` as if `ptrmask(%p, -2)` were exactly `%p`.
It therefore thinks `%r == %base + 2` while `%p == %base + 1`, returns
`NoAlias`, and lets GVN forward a stale load value.

## Bug location

`llvm/lib/Analysis/BasicAliasAnalysis.cpp:645-657`:

```cpp
} else if (const auto *Call = dyn_cast<CallBase>(V)) {
  // CaptureTracking can know about special capturing properties of some
  // intrinsics like launder.invariant.group, that can't be expressed with
  // the attributes, but have properties like returning aliasing pointer.
  // Because some analysis may assume that nocaptured pointer is not
  // returned from some special intrinsic (because function would have to
  // be marked with returns attribute), it is crucial to use this function
  // because it should be in sync with CaptureTracking. Not using it may
  // cause weird miscompilations where 2 aliasing pointers are assumed to
  // noalias.
  if (auto *RP = getArgumentAliasingToReturnedPointer(Call, false)) {
    V = RP;
    continue;
  }
}
```

`llvm/lib/Analysis/ValueTracking.cpp:6883-6902` includes `ptrmask` in that
helper:

```cpp
bool llvm::isIntrinsicReturningPointerAliasingArgumentWithoutCapturing(
    const CallBase *Call, bool MustPreserveNullness) {
  switch (Call->getIntrinsicID()) {
  ...
  case Intrinsic::ptrmask:
    return !MustPreserveNullness;
```

The LangRef specifies that `ptrmask` is equivalent to pointer arithmetic with a
possibly nonzero delta:

```llvm
%intptr = ptrtoint ptr %ptr to iPtrIdx
%masked = and iPtrIdx %intptr, %mask
%diff = sub iPtrIdx %masked, %intptr
%result = getelementptr i8, ptr %ptr, iPtrIdx %diff
```

So `ptrmask` preserves the underlying object, but it does not preserve the
byte offset from that object.

## Proof

Use a 64-bit pointer index and a two-byte-aligned `%base`.

```text
addr(%base) mod 2 = 0
addr(%p) = addr(%base) + 1
addr(%q) = addr(%p) & -2 = addr(%base)
addr(%r) = addr(%q) + 1 = addr(%p)
```

The two one-byte locations `%p` and `%r` must alias.

BasicAA's decomposition loses the `ptrmask` address delta:

```text
decompose(%p) = %base + 1
decompose(%r) = decompose(gep(ptrmask(%p, -2), 1))
              = decompose(gep(%p, 1))
              = %base + 2
```

That false one-byte difference is enough for BasicAA to answer `NoAlias` for
two one-byte accesses.

## LLVM IR reproducer

```llvm
; RUN: opt -passes=verify -disable-output < %s
; RUN: opt -aa-pipeline=basic-aa -passes=aa-eval \
; RUN:   -print-all-alias-modref-info -disable-output < %s 2>&1 | \
; RUN:   FileCheck %s --check-prefix=AA
; RUN: opt -passes='instcombine,simplifycfg' -S < %s | \
; RUN:   FileCheck %s --check-prefix=FOLD-FIRST
; RUN: opt -aa-pipeline=basic-aa \
; RUN:   -passes='gvn,instcombine,simplifycfg' -S < %s | \
; RUN:   FileCheck %s --check-prefix=GVN-FIRST

declare ptr @llvm.ptrmask.p0.i64(ptr, i64)

define i8 @ptrmask_gep_miscompile(ptr align 2 %base) {
entry:
  %p = getelementptr i8, ptr %base, i64 1
  %q = call ptr @llvm.ptrmask.p0.i64(ptr %p, i64 -2)
  %r = getelementptr i8, ptr %q, i64 1

  store i8 7, ptr %p, align 1
  store i8 42, ptr %r, align 1
  %v = load i8, ptr %p, align 1
  ret i8 %v
}

; Current buggy AA result:
; AA: NoAlias:{{.*}}i8* %p, i8* %r

; Folding the ptrmask first proves %r is %base + 1, so the function returns 42.
; FOLD-FIRST: store i8 42
; FOLD-FIRST: ret i8 42

; Running GVN first trusts the bad NoAlias result and returns stale 7.
; The final IR still stores 42 to the same address.
; GVN-FIRST: store i8 42
; GVN-FIRST: ret i8 7
```

## Verified local behavior

I verified this with the local `build/bin/opt`.

`aa-eval` reports:

```text
Function: ptrmask_gep_miscompile: 2 pointers, 1 call sites
  NoAlias: i8* %p, i8* %r
```

`instcombine,simplifycfg` first produces the expected result:

```llvm
%r = getelementptr i8, ptr %base, i64 1
store i8 42, ptr %r, align 1
ret i8 42
```

`gvn,instcombine,simplifycfg` produces a miscompile:

```llvm
%r = getelementptr i8, ptr %base, i64 1
store i8 42, ptr %r, align 1
ret i8 7
```

The optimized function writes `42` to `%base + 1` and returns `7` from the same
byte.

## Practicality

This does not need a huge object, a huge loop count, or an address close to
`2^64`. The trigger is a normal pointer-tag/alignment operation:

```text
mask = -2
base alignment = 2
p = base + 1
```

Clearing the low bit is a common operation for tagged pointers and alignment
rounding. The reproducer uses a two-byte object layout and one-byte accesses.

## C reproducer

Clang exposes this through `__builtin_align_down()`, which lowers to
`llvm.ptrmask` for pointer operands.

```c
#include <stddef.h>

__attribute__((noinline)) unsigned char f(unsigned char *base) {
  unsigned char *p = base + 1;
  unsigned char *q = __builtin_align_down(p, 2);
  unsigned char *r = q + 1;

  *p = 7;
  *r = 42;
  return *p;
}

int main(void) {
  _Alignas(2) unsigned char buf[2] = {0, 0};
  return f(buf) != 42;
}
```

The source-level operation is within the same allocation: `buf` is two-byte
aligned, `p == buf + 1`, `__builtin_align_down(p, 2) == buf`, and `r == buf + 1`.
So `f()` should return `42`.

Local verification:

```text
build/bin/clang -O0 repro.c && ./a.out  # exits 0
build/bin/clang -O2 repro.c && ./a.out  # exits 1
```

The optimized IR for `f()` contains the bad forwarded return:

```llvm
%add.ptr = getelementptr inbounds nuw i8, ptr %base, i64 1
%aligned_result = tail call align 2 ptr @llvm.ptrmask.p0.i64(ptr nonnull %add.ptr, i64 -2)
%add.ptr1 = getelementptr inbounds nuw i8, ptr %aligned_result, i64 1
store i8 7, ptr %add.ptr, align 1
store i8 42, ptr %add.ptr1, align 1
ret i8 7
```

## Root cause

`isIntrinsicReturningPointerAliasingArgumentWithoutCapturing` is used for
multiple purposes:

1. `getUnderlyingObject` — find the base object (correct to look through `ptrmask`)
2. `DecomposeGEPExpression` — compute exact byte offsets (**incorrect** to look through `ptrmask`)
3. Capture analysis — track pointer provenance (correct to look through `ptrmask`)
4. Noalias analysis — propagate noalias attributes (correct to look through `ptrmask`)

The issue is that `ptrmask` preserves the **underlying object** but not the
**exact address/offset**. For purposes 1, 3, and 4, looking through `ptrmask`
is correct. For purpose 2 it is incorrect.

The same issue applies to `threadlocal_address` — it also appears in the
helper and also changes the pointer address.

### Intrinsic classification

**Address-preserving** (safe for GEP decomposition):
- `launder.invariant.group` — only affects TBAA metadata
- `strip.invariant.group` — only affects TBAA metadata
- `aarch64.irg` — adds random tag, preserves address bits
- `aarch64.tagp` — transfers tag, preserves address bits
- `amdgcn.make.buffer.rsrc` — creates buffer resource, preserves base address

**Object-preserving only** (NOT safe for GEP decomposition):
- `ptrmask` — masks address bits, can change offset by arbitrary amount
- `threadlocal_address` — computes thread-local address, changes base

## Fix

Do not use `getArgumentAliasingToReturnedPointer(Call, false)` as a blanket
"same symbolic address" rule in `DecomposeGEPExpression()`.

### Option A: Special-case in `DecomposeGEPExpression` (conservative)

Stop GEP decomposition at `llvm.ptrmask`:

```cpp
if (const auto *Call = dyn_cast<CallBase>(V)) {
  if (auto *II = dyn_cast<IntrinsicInst>(Call);
      II && II->getIntrinsicID() == Intrinsic::ptrmask) {
    Decomposed.Base = V;
    return Decomposed;
  }

  if (auto *RP = getArgumentAliasingToReturnedPointer(Call, false)) {
    V = RP;
    continue;
  }
}
```

This is targeted but doesn't address the general issue or `threadlocal_address`.

### Option B: New helper distinguishing "preserves address" (recommended)

Split the helper into two concepts:

```text
1. same underlying object / returned provenance
2. same address, modulo the pointer index type
```

BasicAA GEP decomposition needs the second property.

```cpp
// In ValueTracking.cpp
bool llvm::isIntrinsicReturningPointerPreservingAddress(
    const CallBase *Call) {
  switch (Call->getIntrinsicID()) {
  case Intrinsic::launder_invariant_group:
  case Intrinsic::strip_invariant_group:
  case Intrinsic::aarch64_irg:
  case Intrinsic::aarch64_tagp:
  case Intrinsic::amdgcn_make_buffer_rsrc:
    return true;
  // ptrmask and threadlocal_address are NOT included
  default:
    return false;
  }
}

// In BasicAliasAnalysis.cpp, DecomposeGEPExpression
} else if (const auto *Call = dyn_cast<CallBase>(V)) {
  if (auto *RP = getArgumentAliasingToReturnedPointer(Call, false)) {
    if (isIntrinsicReturningPointerPreservingAddress(Call)) {
      V = RP;
      continue;
    }
  }
}
```

This correctly handles `ptrmask`, `threadlocal_address`, and any future
intrinsics that preserve the underlying object but not the address.

## Testing

Beyond `aa-eval` and `gvn`, the following passes also rely on BasicAA and
should be tested to ensure the fix doesn't break valid optimizations:

- `early-cse` — uses MemorySSA which relies on alias analysis
- `dse` — dead store elimination relies on alias analysis
- `licm` — loop invariant code motion
- `memcpyopt` — memcpy optimization
