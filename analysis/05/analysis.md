# Alias Analysis Investigation

Requested output file: `analysis-codex.md` instead of `analysis.md`.

## Prior Work Reviewed

The supplied prior analyses already cover these bugs, so they are excluded from
this report:

1. `AliasResult::swap()` can leave a stale partial-alias offset when negating
   `-2^22`.
2. `AAResults::getModRefInfo(Instruction, CallBase)` misses atomic-ordering
   effects for non-call atomic instructions.
3. `BasicAAResult::constantOffsetHeuristic()` can overflow when multiplying
   the minimum index difference by a scale.
4. `BasicAAResult::aliasErrno()` treats imprecise upper-bound sizes as definite
   sizes.

## Summary

`TypeBasedAAResult::Aliases()` ignores the access-size operand of new-format
size-aware TBAA tags. As a result, TypeBasedAA can return `NoAlias`/`NoModRef`
for two accesses with overlapping byte ranges when their typed offsets are not
equal.

A concrete case is an 8-byte `omnipotent char` access at offset 0 and a 4-byte
`int` access at offset 4 in the same TBAA base object. These accesses overlap
in bytes `[4, 8)`, and `char` may alias `int`, but TypeBasedAA treats them as
disjoint because it only compares `OffsetInBase == SubobjectTag.getOffset()`.

This can miscompile GVN: a `memset` that writes bytes `[0, 8)` can be skipped as
`NoModRef` for a later load from bytes `[4, 8)`, allowing GVN to forward a stale
store that the `memset` overwrote.

## Bug Location

`llvm/lib/Analysis/TypeBasedAliasAnalysis.cpp` defines a size-aware access tag:

```cpp
// lines 213-239
bool isNewFormat() const { ... }

uint64_t getSize() const {
  if (!isNewFormat())
    return UINT64_MAX;
  return mdconst::extract<ConstantInt>(Node->getOperand(3))->getZExtValue();
}
```

But the matching logic never uses `getSize()`:

```cpp
// lines 639-647
if (BaseType.getNode() == SubobjectTag.getBaseType()) {
  MayAlias = OffsetInBase == SubobjectTag.getOffset() ||
             BaseType.getNode() == BaseTag.getAccessType() ||
             SubobjectTag.getBaseType() == SubobjectTag.getAccessType();
  ...
  return true;
}
```

`matchAccessTags()` then returns that result as definitive:

```cpp
// lines 714-718
if (mayBeAccessToSubobjectOf(TagA, TagB, CommonType, GenericTag, MayAlias) ||
    mayBeAccessToSubobjectOf(TagB, TagA, CommonType, GenericTag, MayAlias))
  return MayAlias;
```

The bad result reaches ModRef queries here:

```cpp
// lines 452-455
if (const MDNode *L = Loc.AATags.TBAA)
  if (const MDNode *M = Call->getMetadata(LLVMContext::MD_tbaa))
    if (!Aliases(L, M))
      return ModRefInfo::NoModRef;
```

This is not just dead metadata. `AAMDNodes::extendToTBAA()` updates operand 3
for new-format tags when widening/combining memory operations (lines 815-838),
so the implementation explicitly preserves and mutates access sizes but does
not consult them when answering alias questions.

## Source-Level Proof

Use these valid new-format TBAA tags. The `Pair` base object has a leading
`char` field at offset 0 and an `int` field at offset 4:

```llvm
!0 = !{!"Simple C++ TBAA"}
!1 = !{!0, i64 1, !"omnipotent char"}
!2 = !{!1, i64 4, !"int"}
!3 = !{!1, i64 8, !"Pair", !1, i64 0, i64 1, !2, i64 4, i64 4}

; Wide access: bytes [0, 8), through omnipotent char.
!4 = !{!3, !1, i64 0, i64 8}

; Second int field: bytes [4, 8).
!5 = !{!3, !2, i64 4, i64 4}
```

`matchAccessTags(!4, !5)` computes:

1. `CommonType = getLeastCommonType(char, int) = char`.
2. First `mayBeAccessToSubobjectOf(BaseTag=!4, SubobjectTag=!5)` starts at
   `BaseType = Pair`, `OffsetInBase = 0`.
3. `BaseType.getNode() == SubobjectTag.getBaseType()` is true because both use
   base `Pair`.
4. It sets `MayAlias` to:
   - `0 == 4` -> false
   - `Pair == char` -> false
   - `Pair == int` -> false
5. The reverse check similarly compares `4 == 0` and returns false.
6. `matchAccessTags()` returns false, so TypeBasedAA returns `NoAlias` or
   `NoModRef`.

That answer is wrong: byte range `[0, 8)` overlaps `[4, 8)`, and the first
access is through `omnipotent char`, which may alias the `int` field.

## LLVM IR Reproducer

This IR demonstrates both the bad ModRef answer and the resulting GVN
miscompile. Correct execution returns zero, because the `memset` overwrites the
second field before the load.

```llvm
; RUN: opt -aa-pipeline=basic-aa,tbaa -passes=aa-eval \
; RUN:   -evaluate-aa-metadata -print-all-alias-modref-info \
; RUN:   -disable-output < %s 2>&1 | FileCheck %s --check-prefix=AA
; RUN: opt -aa-pipeline=basic-aa,tbaa -passes=gvn -S < %s | \
; RUN:   FileCheck %s --check-prefix=GVN

; AA should not say NoModRef here, because memset writes bytes [0, 8)
; and %field1 reads bytes [4, 8). Current TypeBasedAA reports NoModRef.
; AA: NoModRef:  Ptr: ptr %field1 <->  call void @llvm.memset.p0.i64

; Correct GVN output must keep the load or return 0. Current GVN can forward
; the stale store across the skipped memset and return 123456.
; GVN-LABEL: define i32 @tbaa_size_ignored_miscompile(
; GVN: call void @llvm.memset.p0.i64
; GVN-NOT: ret i32 123456

declare void @llvm.memset.p0.i64(ptr nocapture writeonly, i8, i64, i1 immarg)

define i32 @tbaa_size_ignored_miscompile(ptr %s) {
entry:
  %field1 = getelementptr i8, ptr %s, i64 4

  ; Writes bytes [4, 8).
  store i32 123456, ptr %field1, align 4, !tbaa !5

  ; Writes bytes [0, 8), including %field1. The !tbaa tag says this is an
  ; 8-byte omnipotent-char access starting at Pair offset 0.
  call void @llvm.memset.p0.i64(
      ptr align 4 %s, i8 0, i64 8, i1 false), !tbaa !4

  ; Must read zero after the memset.
  %v = load i32, ptr %field1, align 4, !tbaa !5
  ret i32 %v
}

!0 = !{!"Simple C++ TBAA"}
!1 = !{!0, i64 1, !"omnipotent char"}
!2 = !{!1, i64 4, !"int"}
!3 = !{!1, i64 8, !"Pair", !1, i64 0, i64 1, !2, i64 4, i64 4}
!4 = !{!3, !1, i64 0, i64 8}
!5 = !{!3, !2, i64 4, i64 4}
```

## Why This Miscompiles

The later load queries the previous `memset` through MemoryDependenceAnalysis.
For a `NoModRef` answer, MemoryDependenceAnalysis skips the instruction (lines
620-621). Because TypeBasedAA reports `NoModRef` for the `memset` versus
`%field1`, the scan continues backward and finds the stale store to `%field1`.
GVN can then forward the stored constant (lines 1336-1342 in `GVN.cpp`).

The transformed program can return `123456`. The original program must return
`0`, because the intervening `memset` writes all four bytes loaded from
`%field1`.

## Fix

Make new-format TBAA matching honor access byte ranges. In particular, the
offset-equality test in `mayBeAccessToSubobjectOf()` should become a
range-overlap test for new-format tags:

```cpp
static bool rangesMayOverlap(uint64_t AStart, uint64_t ASize,
                             uint64_t BStart, uint64_t BSize) {
  if (ASize == UINT64_MAX || BSize == UINT64_MAX)
    return true;
  if (AStart > UINT64_MAX - ASize || BStart > UINT64_MAX - BSize)
    return true;
  uint64_t AEnd = AStart + ASize;
  uint64_t BEnd = BStart + BSize;
  return AStart < BEnd && BStart < AEnd;
}
```

Then, when both tags are new-format and are being compared in a common base
coordinate system, set `MayAlias` based on range overlap rather than exact
offset equality. On unknown size or arithmetic overflow, return `MayAlias`.
Old-format tags should keep the existing behavior.

At minimum, a conservative fix is to return `MayAlias` whenever two new-format
tags reach the same base object and either tag has size larger than the scalar
slot implied by the current offset-only check. The better fix is to fully use
`TBAAStructTagNode::getSize()` throughout `matchAccessTags()`.

## Verification Status

I could not run `opt` in this workspace: no built `opt`, `llvm-as`, or
`FileCheck` binary was available in the repository or on the current `PATH`.
The reproducer and proof above are derived directly from the implementation.
