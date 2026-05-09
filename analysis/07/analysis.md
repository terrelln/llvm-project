# Alias Analysis Bug: Matrix Intrinsic MemoryLocation Size Overflow

Requested output file: `analysis-codex2.md` instead of `analysis.md`.

## Prior Work Reviewed

The supplied prior analyses and local analysis files already cover these bugs,
so this report avoids re-reporting them:

1. `AliasResult::swap()` can leave a stale partial-alias offset when negating
   `-2^22`.
2. `AAResults::getModRefInfo(Instruction, CallBase)` misses atomic-ordering
   effects for non-call atomic instructions.
3. `BasicAAResult::constantOffsetHeuristic()` can overflow when multiplying a
   minimum index difference by a scale.
4. `BasicAAResult::aliasErrno()` treats imprecise upper-bound sizes as exact.
5. `TypeBasedAAResult::Aliases()` ignores the access-size operand of
   new-format TBAA tags.
6. `BasicAAResult::aliasGEP()` can overflow its two-variable
   `MinAbsVarIndex` reasoning.

## Summary

`MemoryLocation::getForArgument()` computes the byte extent of
`llvm.matrix.column.major.load/store` with unchecked integer arithmetic. A valid
large matrix stride can wrap the computed extent to zero. BasicAA then treats the
matrix intrinsic's pointer argument as a zero-sized access, returns `NoModRef`
against memory the intrinsic really writes, and GVN can forward a stale value
across the matrix store.

The concrete reproducer uses a `<1 x 2>` `i8` matrix store with stride `i64 -1`.
The verifier accepts this because the stride is interpreted as an unsigned
positive value, `2^64 - 1 >= Rows`. The matrix store starts at `%base + 1`; its
second column is at `%base + 1 + (2^64 - 1)`, i.e. `%base`, so it overwrites the
byte later loaded from `%base`.

Current BasicAA instead models the matrix store's memory location as
`upperBound(0)`, so it reports `NoModRef` and GVN changes the function from
returning `42` to returning `7`.

## Bug Location

`llvm/lib/Analysis/MemoryLocation.cpp:291-317`:

```cpp
case Intrinsic::matrix_column_major_load:
case Intrinsic::matrix_column_major_store: {
  bool IsLoad = II->getIntrinsicID() == Intrinsic::matrix_column_major_load;
  assert(ArgIdx == (IsLoad ? 0 : 1) && "Invalid argument index");

  auto *Stride = dyn_cast<ConstantInt>(II->getArgOperand(IsLoad ? 1 : 2));
  uint64_t Rows =
      cast<ConstantInt>(II->getArgOperand(IsLoad ? 3 : 4))->getZExtValue();
  uint64_t Cols =
      cast<ConstantInt>(II->getArgOperand(IsLoad ? 4 : 5))->getZExtValue();

  if (!Stride)
    return MemoryLocation(Arg, LocationSize::afterPointer(), AATags);

  uint64_t ConstStride = Stride->getZExtValue();
  auto *VT = cast<VectorType>(IsLoad ? II->getType()
                                     : II->getArgOperand(0)->getType());
  assert(Cols != 0 && "Matrix cannot have 0 columns");
  TypeSize Size = DL.getTypeAllocSize(VT->getScalarType()) *
                  (ConstStride * (Cols - 1) + Rows);

  if (ConstStride == Rows)
    return MemoryLocation(Arg, LocationSize::precise(Size), AATags);
  return MemoryLocation(Arg, LocationSize::upperBound(Size), AATags);
}
```

The expression `ConstStride * (Cols - 1) + Rows` is computed in `uint64_t`, and
the later `TypeSize * element-count` multiplication also wraps. No overflow is
checked before the result is converted into a precise or upper-bound
`LocationSize`.

For the reproducer:

```text
Rows = 1
Cols = 2
ConstStride = 2^64 - 1
element size = 1 byte

ConstStride * (Cols - 1) + Rows
= (2^64 - 1) * 1 + 1
= 2^64
= 0  (mod 2^64)
```

So `MemoryLocation::getForArgument()` returns `LocationSize::upperBound(0)`.
Then `BasicAAResult::aliasCheck()` immediately returns `NoAlias` for a zero-size
location:

```cpp
if (V1Size.isZero() || V2Size.isZero())
  return AliasResult::NoAlias;
```

That bad `NoAlias` result causes the matrix store to be classified as
`NoModRef` for `%base`.

## LLVM IR Reproducer

```llvm
; RUN: opt -passes=verify -disable-output < %s
; RUN: opt -aa-pipeline=basic-aa -passes=aa-eval \
; RUN:   -print-all-alias-modref-info -disable-output < %s 2>&1 | \
; RUN:   FileCheck %s --check-prefix=AA
; RUN: opt -passes='lower-matrix-intrinsics,instcombine,simplifycfg' \
; RUN:   -S < %s | FileCheck %s --check-prefix=LOWER-FIRST
; RUN: opt -aa-pipeline=basic-aa \
; RUN:   -passes='gvn,lower-matrix-intrinsics,instcombine,simplifycfg' \
; RUN:   -S < %s | FileCheck %s --check-prefix=GVN-FIRST

declare void @llvm.matrix.column.major.store.v2i8.i64(
    <2 x i8>, ptr, i64, i1 immarg, i32 immarg, i32 immarg)

define i8 @matrix_store_wrap(ptr %base) {
entry:
  %p = getelementptr i8, ptr %base, i64 1
  store i8 7, ptr %base, align 1

  ; Column 0 stores 0 to %p.
  ; Column 1 stores 42 to %p + (2^64 - 1), which is %base.
  call void @llvm.matrix.column.major.store.v2i8.i64(
      <2 x i8> <i8 0, i8 42>, ptr %p, i64 -1,
      i1 false, i32 1, i32 2)

  %v = load i8, ptr %base, align 1
  ret i8 %v
}

; Current buggy AA result:
; AA: NoModRef:{{.*}}Ptr: i8* %base{{.*}}call void @llvm.matrix.column.major.store.v2i8.i64

; Lowering first exposes the real store to %base, so the function returns 42.
; LOWER-FIRST: ret i8 42

; Running GVN first trusts the bad NoModRef answer and forwards the stale store.
; GVN-FIRST: ret i8 7
```

## Verified Behavior

I verified the reproducer with the local `build/bin/opt`.

`aa-eval` reports the wrong mod/ref result:

```text
Function: matrix_store_wrap: 1 pointers, 1 call sites
  NoModRef:  Ptr: i8* %base <->  call void @llvm.matrix.column.major.store.v2i8.i64(...)
```

Lowering the matrix intrinsic before GVN produces the semantically expected
result:

```llvm
store <1 x i8> splat (i8 42), ptr %base, align 1
ret i8 42
```

Running GVN before matrix lowering miscompiles:

```llvm
store <1 x i8> splat (i8 42), ptr %base, align 1
ret i8 7
```

The final IR still writes `42` to `%base`, but returns the stale value `7`.

## Practical Triggerability

This is triggerable from Clang source that uses the public matrix builtin, not
only from hand-written IR. Clang exposes:

```cpp
using m2 = unsigned char __attribute__((matrix_type(1, 2)));

unsigned char f(unsigned char *base, m2 m) {
  unsigned char *p = base + 1;
  base[0] = 7;
  __builtin_matrix_column_major_store(m, p, (unsigned long)-1);
  return base[0];
}
```

With `clang -fenable-matrix -O2`, the generated optimized IR/assembly stores
the second matrix element to `base[0]` but still returns the stale constant `7`.

That said, the trigger is not likely to occur accidentally in normal dense
matrix code. It needs an enormous stride such as `SIZE_MAX` so that the lowered
column address wraps back before the starting pointer. Clang Sema accepts such a
constant because it only checks the documented precondition `stride >= rows`.
However, the Clang matrix builtin documentation describes the operation as
equivalent to repeated C pointer increments; under that source-level model,
stepping by `SIZE_MAX` from `base + 1` in an ordinary finite object is
questionable/undefined. So the practical risk is low for well-formed
application code, but real for frontends, tests, fuzzers, or source using the
matrix builtin with adversarial stride values.

## Why This Is Valid IR

The matrix intrinsic verifier accepts the program. The LangRef specifies that
matrix column addresses are computed with the target data layout's pointer index
type. With a 64-bit pointer index, adding `i64 -1` to `%base + 1` wraps to
`%base`. The intrinsic therefore stores the second element to the same byte that
the later scalar load reads.

This is not a zero-byte access. The zero-sized `MemoryLocation` is only an AA
modeling artifact caused by overflow in the size calculation.

## Fix

`MemoryLocation::getForArgument()` should not form a precise or upper-bound size
from overflowing matrix span arithmetic. Use checked arithmetic for both the
element span and the byte span. If any step overflows the pointer index width,
return an unknown before-or-after location for the pointer argument, because
wrapped column addresses may land before `%Ptr`.

Sketch using the helpers from `llvm/Support/CheckedArithmetic.h`:

```cpp
uint64_t ConstStride = Stride->getZExtValue();
uint64_t ScalarSize = DL.getTypeAllocSize(VT->getScalarType()).getFixedValue();
std::optional<uint64_t> LastColumnSpan =
    checkedMulUnsigned(ConstStride, Cols - 1);
std::optional<uint64_t> ElementSpan =
    LastColumnSpan ? checkedAddUnsigned(*LastColumnSpan, Rows) : std::nullopt;
std::optional<uint64_t> ByteSpan =
    ElementSpan ? checkedMulUnsigned(*ElementSpan, ScalarSize) : std::nullopt;

if (!ByteSpan)
  return MemoryLocation::getBeforeOrAfter(Arg, AATags);

LocationSize Size =
    ConstStride == Rows ? LocationSize::precise(*ByteSpan)
                        : LocationSize::upperBound(*ByteSpan);
return MemoryLocation(Arg, Size, AATags);
```

The exact code should use LLVM's available checked arithmetic helpers/APInt
style, but the important property is the fallback: on overflow, AA must not
model the matrix access as a small or zero-sized after-pointer range.
