# Alias Analysis Bug: `aliasErrno()` Treats Upper-Bound Access Sizes as Definite

## Summary

`BasicAAResult::aliasErrno()` in `llvm/lib/Analysis/BasicAliasAnalysis.cpp:1888`
uses `Loc.Size.hasValue()` instead of `Loc.Size.isPrecise()` to guard a size-based
exclusion. An upper-bound `LocationSize` (from e.g. `llvm.masked.load`) may
represent an access as small as zero bytes, yet `aliasErrno()` treats the upper
bound as the actual access size. When the upper bound exceeds `sizeof(int)`, the
function incorrectly returns `NoAlias`, dropping errno effects from the call's
`ModRefInfo`. EarlyCSE or GVN can then CSE or forward stale values across a call
that writes `errno`.

## Bug Location

**File:** `llvm/lib/Analysis/BasicAliasAnalysis.cpp`, lines 1883-1895

```cpp
AliasResult BasicAAResult::aliasErrno(const MemoryLocation &Loc,
                                      const Module *M) {
  if (Loc.Size.hasValue() &&
      Loc.Size.getValue().getKnownMinValue() * 8 > TLI.getIntSize())
    return AliasResult::NoAlias;

  if (isIdentifiedFunctionLocal(getUnderlyingObject(Loc.Ptr)))
    return AliasResult::NoAlias;
  return AliasResult::MayAlias;
}
```

`hasValue()` returns true for BOTH `LocationSize::precise(N)` and
`LocationSize::upperBound(N)` (confirmed at `MemoryLocation.h:153` — it only
checks against `AfterPointer` and `BeforeOrAfterPointer`). The check on line
1888 should use `isPrecise()` instead, because an upper-bound size of N means
the access may touch anywhere from 0 to N bytes. Only a *precise* size can
prove the access is strictly larger than `errno`.

## How the Upper-Bound Size Arises

`MemoryLocation::getForArgument()` at `MemoryLocation.cpp:244-252` produces
upper-bound sizes for `llvm.masked.load` when the mask is not a recognized
`get.active.lane.mask` intrinsic:

```cpp
case Intrinsic::masked_load: {
  auto *Ty = cast<VectorType>(II->getType());
  if (auto KnownType = getKnownTypeFromMaskedOp(II->getOperand(1), Ty))
    return MemoryLocation(Arg, DL.getTypeStoreSize(*KnownType), AATags);
  return MemoryLocation(
      Arg, LocationSize::upperBound(DL.getTypeStoreSize(Ty)), AATags);
}
```

A `<8 x i8>` masked load with a constant mask `<1,1,1,1,0,0,0,0>` gets
`LocationSize::upperBound(8)`, even though only 4 bytes are actually read.

## Trigger Path

1. `@llvm.masked.load.v8i8.p0` is modeled as `memory(argmem: read)`.
2. Its pointer argument location is `LocationSize::upperBound(8)`.
3. A call declared `memory(errnomem: write)` has `ErrnoMR = Mod`.
4. `BasicAAResult::getModRefInfo(Call, Loc)` at line 1008 tries to refine
   errno effects:
   ```cpp
   if ((ErrnoMR | Result) != Result) {
     if (AAQI.AAR.aliasErrno(Loc, Call->getModule()) != AliasResult::NoAlias)
       Result |= ErrnoMR;
   }
   ```
5. `aliasErrno()` sees `8 * 8 = 64 > 32` (x86-64, 32-bit int) and returns
   `NoAlias`.
6. The errno write is dropped → result is `NoModRef`.
7. MemorySSA sees no clobber. EarlyCSE CSEs the two masked loads.

## LLVM-IR Proof

```llvm
; RUN: opt -aa-pipeline=basic-aa -passes='early-cse<memssa>' -S < %s | FileCheck %s

target triple = "x86_64-unknown-linux-gnu"

declare void @set_errno() memory(errnomem: write)

define <8 x i8> @errno_upperbound_cse(ptr %p) {
; Correct: both loads must survive — @set_errno may change bytes [0,4) at %p.
; Buggy: %v2 is CSE'd with %v1, sub folds to zeroinitializer.
;
; CHECK-LABEL: define <8 x i8> @errno_upperbound_cse(
; CHECK:         %v1 = call <8 x i8> @llvm.masked.load
; CHECK:         call void @set_errno()
; CHECK:         %v2 = call <8 x i8> @llvm.masked.load
; CHECK:         %diff = sub <8 x i8> %v2, %v1
; CHECK:         ret <8 x i8> %diff
  %v1 = call <8 x i8> @llvm.masked.load.v8i8.p0(
      ptr %p, i32 1,
      <8 x i1> <i1 true, i1 true, i1 true, i1 true,
                 i1 false, i1 false, i1 false, i1 false>,
      <8 x i8> zeroinitializer)

  call void @set_errno()

  %v2 = call <8 x i8> @llvm.masked.load.v8i8.p0(
      ptr %p, i32 1,
      <8 x i1> <i1 true, i1 true, i1 true, i1 true,
                 i1 false, i1 false, i1 false, i1 false>,
      <8 x i8> zeroinitializer)

  %diff = sub <8 x i8> %v2, %v1
  ret <8 x i8> %diff
}
```

## Verified Miscompilation

```
$ build/bin/opt -aa-pipeline=basic-aa -passes='early-cse<memssa>' -S test.ll
```

Output (miscompiled):
```llvm
define <8 x i8> @errno_upperbound_cse(ptr %p) {
  %v1 = call <8 x i8> @llvm.masked.load.v8i8.p0(...)
  call void @set_errno()
  ret <8 x i8> zeroinitializer
}
```

EarlyCSE replaced `%v2` with `%v1` and folded `sub %v1, %v1` to
`zeroinitializer`. If `%p` points to `errno` and `@set_errno` writes a
different value, the correct result is non-zero but the program always returns
zero.

## Why EarlyCSE Miscompiles

MemorySSA asks whether the `@set_errno` memory def clobbers the later masked
load. In `MemorySSA.cpp:313-315`:

```cpp
if (auto *CB = dyn_cast_or_null<CallBase>(UseInst)) {
  ModRefInfo I = AA.getModRefInfo(DefInst, CB);
  return isModSet(I);
}
```

The bad alias result makes `AA.getModRefInfo(@set_errno, masked_load)` return
`NoModRef`, so MemorySSA reports no clobber. EarlyCSE with MemorySSA then
treats the two masked loads as the same memory generation and replaces the
later one with the earlier one.

## Fix

Only use the size-based errno exclusion for precise access sizes:

```cpp
AliasResult BasicAAResult::aliasErrno(const MemoryLocation &Loc,
                                      const Module *M) {
  if (Loc.Size.isPrecise() && Loc.Size.hasValue() &&
      Loc.Size.getValue().getKnownMinValue() * 8 > TLI.getIntSize())
    return AliasResult::NoAlias;

  if (isIdentifiedFunctionLocal(getUnderlyingObject(Loc.Ptr)))
    return AliasResult::NoAlias;
  return AliasResult::MayAlias;
}
```

Only precise sizes can prove the access is strictly larger than `errno`. For
upper-bound sizes, the actual access might be as small as `sizeof(int)` or
smaller, so we cannot exclude an alias with `errno`.

## Secondary Finding: `MergeAliasResults` Silently Drops Offset Accuracy

`MergeAliasResults()` at `BasicAliasAnalysis.cpp:1429` uses
`AliasResult::operator==` which only compares the `Alias` field, ignoring
the `Offset`:

```cpp
static AliasResult MergeAliasResults(AliasResult A, AliasResult B) {
  if (A == B)
    return A;   // Returns A's offset even when B has a different offset
  ...
}
```

When `aliasSelect` or `aliasPHI` merges two `PartialAlias` results with
different offsets (e.g., offset=4 from one arm and offset=8 from the other),
`MergeAliasResults` returns one arm's offset arbitrarily. This violates the
invariant that the `PartialAlias` offset accurately represents the pointer
relationship.

**Current impact:** Benign. All current consumers have safeguards:

- **GVN:** For load-to-load forwarding via `ClobberOffset`, the useful case
  (query load nested within dep load) always produces a negative offset from
  `alias(QueryLoc, DepLoc)`, which GVN discards. The fallback
  `analyzeLoadFromClobberingLoad` also fails for select/phi pointers.

- **DSE `OW_Complete`:** The PartialAlias offset is only set when the nesting
  condition `Off + RightSize <= LeftSize` holds in `aliasGEP`. This nesting
  condition IS the same as DSE's `Off + DeadSize <= KillingSize` check. So
  if both arms produce PartialAlias with offset, BOTH satisfy OW_Complete
  regardless of which offset is chosen.

- **DSE `OW_PartialEarlierWithFullLater`:** The geometry required (killing
  store smaller, dead store larger) is incompatible with the nesting check
  direction in `aliasGEP`, so this path is never reached via PartialAlias
  offsets from select/phi merges.

**Recommended fix:** Drop the offset when both results are `PartialAlias`
with different offsets:

```cpp
static AliasResult MergeAliasResults(AliasResult A, AliasResult B) {
  if (A == B) {
    if (A == AliasResult::PartialAlias &&
        A.hasOffset() && B.hasOffset() &&
        A.getOffset() != B.getOffset()) {
      return AliasResult::PartialAlias;  // no offset
    }
    return A;
  }
  ...
}
```
