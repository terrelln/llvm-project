# Alias Analysis Bug: `AliasResult::swap()` Offset Overflow

## Summary

`AliasResult::swap()` silently fails to negate the `PartialAlias` offset when the
offset is exactly `-4194304` (`-2^22`), because its negation (`4194304`) does not
fit in the 23-bit signed `Offset` field. The stale un-negated offset remains,
violating the invariant that `alias(A,B).offset == -alias(B,A).offset`.

## Bug Location

**File:** `llvm/include/llvm/Analysis/AliasAnalysis.h`, lines 82-141

The `AliasResult` class stores an optional byte offset in a 23-bit signed
bitfield (range `[-4194304, 4194303]`):

```cpp
static const int OffsetBits = 23;

unsigned int Alias : AliasBits;
unsigned int HasOffset : 1;
signed int Offset : OffsetBits;
```

The `setOffset` method silently drops updates that don't fit:

```cpp
void setOffset(int32_t NewOffset) {
    if (isInt<OffsetBits>(NewOffset)) {
      HasOffset = true;
      Offset = NewOffset;
    }
    // BUG: when NewOffset doesn't fit, HasOffset and Offset are unchanged.
    // The old stale values remain.
}
```

The `swap` method relies on `setOffset` to negate the offset:

```cpp
void swap(bool DoSwap = true) {
    if (DoSwap && hasOffset())
      setOffset(-getOffset());
}
```

When `Offset == -4194304`:
1. `getOffset()` returns `-4194304`
2. `-getOffset()` computes `4194304`
3. `isInt<23>(4194304)` is **false** (max is `4194303`)
4. `setOffset` silently drops the update
5. `HasOffset` remains `true`, `Offset` remains `-4194304`

The offset should have been negated, but it wasn't. The `AliasResult` now reports
an offset with the **wrong sign**.

## How It Triggers

The sole producer of `PartialAlias` offsets is `BasicAAResult::aliasGEP()` in
`llvm/lib/Analysis/BasicAliasAnalysis.cpp` (lines 1210-1218):

```cpp
AliasResult AR = AliasResult::PartialAlias;
if (VRightSize.hasValue() && !VRightSize.isScalable() &&
    Off.ule(INT32_MAX) && (Off + VRightSize.getValue()).ule(LSize)) {
  AR.setOffset(-Off.getSExtValue());
  AR.swap(Swapped);
}
return AR;
```

The `swap(Swapped)` call fails when `Off` is exactly `4194304` and `Swapped` is
true (because `-(-4194304) = 4194304` overflows the 23-bit field).

This value then propagates through `aliasCheckRecursive` (line 1843), where
`Result.swap()` is called unconditionally when V2 is the GEP operand, and through
the alias cache (lines 1775, 1798), which also uses `swap()` to normalize/restore
argument order.

## Concrete Trigger Path

Given:
- `%q = getelementptr i8, ptr %p, i64 4194304`
- `Loc1 = MemoryLocation(%p, 4194308)` — a 4194308-byte access at `%p`
- `Loc2 = MemoryLocation(%q, 4)` — a 4-byte access at `%p + 4194304`

`Loc2` is fully nested within `Loc1` (bytes `[4194304, 4194308)` of `[0, 4194308)`).

**Query `alias(Loc1, Loc2)` — base pointer first:**

1. `aliasCheckRecursive`: V1=`%p` (not GEP), V2=`%q` (GEP)
2. Takes the `else if (GV2)` branch, calls `aliasGEP(%q, 4, %p, 4194308, ...)`
3. Inside `aliasGEP`: `Off = 4194304`, `Swapped = false`
4. `setOffset(-4194304)` — succeeds (fits in 23 bits)
5. `swap(false)` — no-op
6. Returns `PartialAlias(-4194304)` (meaning GEP1 + (-4194304) = V2)
7. Back in `aliasCheckRecursive`: `Result.swap()` — tries `setOffset(4194304)` — **FAILS**
8. Final result: `PartialAlias(-4194304)`

**Expected:** `PartialAlias(+4194304)` — because `%p + 4194304 = %q`
**Actual:** `PartialAlias(-4194304)` — wrong sign

**Query `alias(Loc2, Loc1)` — GEP pointer first:**

1. `aliasCheckRecursive`: V1=`%q` (GEP), V2=`%p` (not GEP)
2. Takes the `if (GV1)` branch, calls `aliasGEP(%q, 4, %p, 4194308, ...)` directly
3. Same computation: `setOffset(-4194304)`, `swap(false)` = no-op
4. No additional swap in `aliasCheckRecursive`
5. Final result: `PartialAlias(-4194304)`

**Expected:** `PartialAlias(-4194304)` — because `%q + (-4194304) = %p`
**Actual:** `PartialAlias(-4194304)` — correct

**Invariant violation:** Both directions return offset `-4194304`. The invariant
`alias(A,B).offset == -alias(B,A).offset` requires them to have opposite signs.

## LLVM-IR Proof

```llvm
; RUN: opt -aa-pipeline=basic-aa -passes="print<aa-eval>" -print-all-alias-modref-info -disable-output < %s
;
; The 4-byte load at %q is nested within the 4194308-byte load at %p.
; BasicAA should report PartialAlias with |offset| = 4194304.
; Due to the swap() overflow bug, alias(%p-loc, %q-loc) returns offset
; -4194304 instead of +4194304.

define void @swap_overflow_bug(ptr %p) {
  ; 4194308 bytes = 1048577 x i32
  %big = load <1048577 x i32>, ptr %p, align 4

  %q = getelementptr i8, ptr %p, i64 4194304
  %small = load i32, ptr %q, align 4

  ret void
}
```

A unit test analogous to the existing `PartialAliasOffsetSign` test
(`llvm/unittests/Analysis/AliasAnalysisTest.cpp:350`) demonstrates the
inconsistency directly:

```cpp
TEST_F(AliasAnalysisTest, SwapOverflowBug) {
  // Build IR with two accesses 4194304 bytes apart
  // Loc1 = {%p, 4194308}, Loc2 = {gep(%p, 4194304), 4}

  auto &AA = getAAResults(*F);

  // Both directions should give opposite-sign offsets
  auto AR1 = AA.alias(Loc1, Loc2);
  EXPECT_EQ(AR1, AliasResult::PartialAlias);
  EXPECT_EQ(4194304, AR1.getOffset());   // FAILS: actual is -4194304

  auto AR2 = AA.alias(Loc2, Loc1);
  EXPECT_EQ(AR2, AliasResult::PartialAlias);
  EXPECT_EQ(-4194304, AR2.getOffset());  // passes (correct by luck)
}
```

## Impact

The offset is consumed by:

1. **`MemoryDependenceAnalysis`** — stores the offset in `ClobberOffsets`
   (`llvm/lib/Analysis/MemoryDependenceAnalysis.cpp:519-521`)
2. **`GVN`** — uses it for load forwarding from partially-aliasing loads
   (`llvm/lib/Transforms/Scalar/GVN.cpp:1363-1367`)

GVN discards negative offsets (`*ClobberOff < 0` → `Offset = -1`), so the wrong
sign causes a **missed optimization** (GVN fails to forward a value it should
be able to) rather than a miscompilation. However, the API invariant violation
could lead to worse consequences in future consumers that don't guard against
negative offsets.

## Fix

`setOffset` should clear `HasOffset` when the value doesn't fit, rather than
leaving stale data:

```cpp
void setOffset(int32_t NewOffset) {
    if (isInt<OffsetBits>(NewOffset)) {
      HasOffset = true;
      Offset = NewOffset;
    } else {
      HasOffset = false;
      Offset = 0;
    }
}
```

This ensures `swap()` produces a valid state: either the correctly negated offset,
or no offset at all. Consumers already check `hasOffset()` before reading the
offset.

## Secondary Finding: Missing `AAQI` Forwarding

Three `getModRefInfo` overloads in `llvm/lib/Analysis/AliasAnalysis.cpp` call
`getModRefInfoMask(Loc)` without forwarding the available `AAQueryInfo`, bypassing
the batch cache:

| Line | Function | Call |
|------|----------|------|
| 242 | `getModRefInfo(const CallBase*, ...)` | `getModRefInfoMask(Loc)` |
| 497 | `getModRefInfo(const StoreInst*, ...)` | `getModRefInfoMask(Loc)` |
| 522 | `getModRefInfo(const FenceInst*, ...)` | `getModRefInfoMask(Loc)` |

Three other overloads (`VAArgInst` line 541, `CatchPadInst` line 554,
`CatchReturnInst` line 566) correctly pass `AAQI`. The inconsistency causes
redundant AA queries when operating through `BatchAAResults`, a performance issue
but not a correctness bug.

---

## Review

### Bug Identification: Correct

The `AliasResult::setOffset()` at `llvm/include/llvm/Analysis/AliasAnalysis.h:130`
silently drops updates when the value doesn't fit the 23-bit signed field (range
`[-4194304, 4194303]`). This means `swap()` at line 138 fails to negate the
minimum value `-4194304` because `+4194304` exceeds the maximum. Confirmed via
`isInt<23>` at `llvm/include/llvm/Support/MathExtras.h:175`:

- `isInt<23>(-4194304)` → `-4194304 <= -4194304 && -4194304 < 4194304` → **true**
- `isInt<23>(4194304)` → `-4194304 <= 4194304 && 4194304 < 4194304` → **false**

So `-4194304` is a representable value whose negation is not representable — a
classic two's complement asymmetry bug.

### Trigger Path: Correct

The path through `aliasGEP` (line 1216: `setOffset(-4194304)` succeeds) and then
`aliasCheckRecursive` (line 1843: `Result.swap()` tries `setOffset(4194304)` and
silently fails) is accurately traced. The `Swapped` flag logic in `aliasGEP` at
line 1189 is also correctly analyzed.

The cache interactions at lines 1775 and 1798 compound the problem — `-4194304`
becomes a fixed point of the buggy `swap()`, so the cache returns the same value
regardless of argument order.

### Miscompilation: No

All three consumers of the PartialAlias offset guard against negative values:

1. **GVN** (`GVN.cpp:1365`): Discards negative offsets (`*ClobberOff < 0 → Offset = -1`)
2. **DSE** (`DeadStoreElimination.cpp:1308`): Guards with `Off >= 0`
3. **MemDepAnalysis** (`MemoryDependenceAnalysis.cpp:520`): Just stores the value;
   consumers above filter it

Since the bug can only produce a wrongly-negative offset (never a wrongly-positive
one), and all consumers guard against negative offsets, the impact is a **missed
optimization** (failure to forward/eliminate), not a miscompilation.

### Gaps

1. **Missing DSE consumer**: The analysis identified MemDep and GVN but missed
   `DeadStoreElimination.cpp:1307` which also reads the offset. DSE has the same
   `Off >= 0` guard, so the conclusion holds, but the analysis is incomplete.

2. **IR proof**: The `print<aa-eval>` output will show the offset, but depends on
   which direction the evaluator queries. The unit test sketch is more definitive.

3. **Proposed fix is sound**: Setting `HasOffset = false` when the negation
   overflows preserves correctness (consumers check `hasOffset()` before
   `getOffset()`) and stays within the 4-byte size constraint.
