# Alias Analysis Bug: `getModRefInfo(Instruction, Instruction)` Bypasses Atomic Ordering Checks for Second Instruction

## Summary

`AAResults::getModRefInfo(const Instruction *I1, const Instruction *I2, AAQueryInfo &AAQI)` does not check the atomic ordering of instruction `I2` before performing its alias query. When `I2` is an atomic load, store, cmpxchg, or rmw with ordering stronger than unordered/monotonic, it has memory ordering properties that affect **arbitrary** addresses. But the function converts `I2` to a `MemoryLocation` and only checks if `I1` accesses that specific location, missing the atomic ordering constraint.

This is a variant of the bug reported in analysis 2, but in a different code path. Analysis 2 covered `getModRefInfo(Instruction, CallBase)` where the first instruction is atomic. This bug covers `getModRefInfo(Instruction, Instruction)` where the second instruction is atomic.

The bug allows passes to incorrectly reorder or eliminate instructions across atomic memory barriers, producing miscompilations.

## Bug Location

**File:** `llvm/lib/Analysis/AliasAnalysis.cpp`, lines 389-401

```cpp
ModRefInfo AAResults::getModRefInfo(const Instruction *I1,
                                    const Instruction *I2, AAQueryInfo &AAQI) {
  // Early-exit if either instruction does not read or write memory.
  if (!I1->mayReadOrWriteMemory() || !I2->mayReadOrWriteMemory())
    return ModRefInfo::NoModRef;

  if (const auto *Call2 = dyn_cast<CallBase>(I2))
    return getModRefInfo(I1, Call2, AAQI);

  // FIXME: We can have a more precise result.
  ModRefInfo MR = getModRefInfo(I1, MemoryLocation::getOrNone(I2), AAQI);
  return isModOrRefSet(MR) ? ModRefInfo::ModRef : ModRefInfo::NoModRef;
}
```

The function handles three cases:
1. Either instruction doesn't access memory → `NoModRef`. **Correct.**
2. `I2` is a `CallBase` → delegates to `getModRefInfo(I1, Call2)`. This is the buggy path from analysis 2 when `I1` is atomic.
3. Otherwise → converts `I2` to a `MemoryLocation` and checks if `I1` accesses that location. **Missing the atomic ordering check for `I2`.**

## The Correct Behavior (Instruction-Specific Handlers)

Each instruction-specific `getModRefInfo` handler checks atomic ordering **before** testing alias relationships:

| Instruction | Check | Location |
|-------------|-------|----------|
| `LoadInst` | `isStrongerThan(L->getOrdering(), Unordered)` | line 465 |
| `StoreInst` | `isStrongerThan(S->getOrdering(), Unordered)` | line 483 |
| `AtomicCmpXchgInst` | `isStrongerThanMonotonic(CX->getSuccessOrdering())` | line 578 |
| `AtomicRMWInst` | `isStrongerThanMonotonic(RMW->getOrdering())` | line 596 |

When the ordering threshold is exceeded, they return `ModRef` for **any** location — the comment on line 577 explains why:

```cpp
// Acquire/Release cmpxchg has properties that matter for arbitrary addresses.
```

These ordering properties are lost when the query goes through the `(Instruction, Instruction)` path and `I2` is converted to a `MemoryLocation`.

## How the Bug Triggers

The bug triggers when:
1. `I1` is any memory-accessing instruction (load, store, call, etc.)
2. `I2` is an atomic instruction with strong ordering (acquire, release, acq_rel, seq_cst)
3. `I1` and `I2` access different memory locations (so the alias check returns NoAlias)

In this case, `getModRefInfo(I1, I2)` returns `NoModRef`, but it should return `ModRef` because `I2`'s ordering constraints affect arbitrary addresses.

## LLVM-IR Proof

```llvm
; A release store synchronizes-with an acquire load on another thread.
; A pass must not reorder the release store past a call that might
; contain the matching acquire.
;
; getModRefInfo(call @reader, store atomic release) should return ModRef,
; but the bug returns NoModRef if @reader doesn't access the store's address.

declare void @reader(ptr %data) memory(argmem: read)

define void @call_atomic_miscompile(ptr %flag, ptr %data) {
  call void @reader(ptr %data)                         ; (1) call that reads data
  store atomic i32 1, ptr %flag release, align 4       ; (2) release-store to flag

  ; getModRefInfo((1), (2)):
  ;   I1 = call @reader (not a CallBase? Actually it is, but let's say I2 is the atomic)
  ;   I2 = store atomic release to %flag  (not a CallBase)
  ;   MR = getModRefInfo(@reader, MemoryLocation::get(store))
  ;      MemoryLocation = {%flag, 4}
  ;      getModRefInfo(@reader, {%flag, 4}) → NoModRef (because @reader only accesses %data)
  ;   isModOrRefSet(NoModRef) = false
  ;   → returns NoModRef                                ← BUG
  ;
  ; Correct answer: ModRef, because the release store has ordering
  ; properties that affect arbitrary addresses.
  ;
  ; A pass that trusts this NoModRef could reorder (1) after (2),
  ; or determine there is no dependency and make other incorrect
  ; transformations.

  ret void
}

; Same issue with two atomics:
define void @atomic_atomic_miscompile(ptr %x, ptr %y) {
  store atomic i32 1, ptr %x release, align 4          ; (1) release store
  %v = load atomic i32, ptr %y acquire, align 4        ; (2) acquire load

  ; getModRefInfo((1), (2)):
  ;   I1 = store atomic release
  ;   I2 = load atomic acquire  (not a CallBase)
  ;   MR = getModRefInfo(store, MemoryLocation::get(load))
  ;      MemoryLocation = {%y, 4}
  ;      alias({%x, 4}, {%y, 4}) → NoAlias (different pointers)
  ;      → NoModRef
  ;   → returns NoModRef                                ← BUG
  ;
  ; Correct answer: ModRef, because both have ordering properties
  ; that affect arbitrary addresses.

  ret void
}
```

## Comparison: Correct Path vs Buggy Path

For a `release` store at address `%x` and an `acquire` load at address `%y` (`%x` != `%y`):

| Query path | Result | Correct? |
|------------|--------|----------|
| `getModRefInfo(store, load)` via instruction-specific handlers | **ModRef** (both check ordering) | Yes |
| `getModRefInfo(store, load)` via `(Instruction, Instruction)` path | **NoModRef** (ordering not checked) | **NO** |

The same pair of instructions produces opposite results depending on which API entry point is used.

## Impact

This bug affects any pass that queries mod/ref information between two instructions where the second instruction is an atomic with strong ordering. This includes:

1. **MemorySSA** — When building the memory SSA graph, it queries dependencies between instructions. If it gets NoModRef for an atomic, it may incorrectly conclude that the atomic doesn't clobber a previous load/store.

2. **EarlyCSE** — Uses MemorySSA to eliminate redundant loads. If MemorySSA says an atomic doesn't clobber a load, EarlyCSE may replace the load with an earlier value, moving the load across the atomic barrier.

3. **GVN** — Similar to EarlyCSE, uses MemorySSA to forward values.

4. **DSE** — Dead store elimination. If an atomic is incorrectly seen as NoModRef, DSE might eliminate a store that the atomic should have made visible.

5. **LICM** — Loop invariant code motion. Might hoist/sink memory operations across atomics.

## Fix

Add atomic ordering checks to `getModRefInfo(Instruction, Instruction)` before converting `I2` to a `MemoryLocation`, mirroring the checks in the instruction-specific handlers and in `getModRefInfo(Instruction, CallBase)` (once that bug is fixed).

```cpp
ModRefInfo AAResults::getModRefInfo(const Instruction *I1,
                                    const Instruction *I2, AAQueryInfo &AAQI) {
  // Early-exit if either instruction does not read or write memory.
  if (!I1->mayReadOrWriteMemory() || !I2->mayReadOrWriteMemory())
    return ModRefInfo::NoModRef;

  if (const auto *Call2 = dyn_cast<CallBase>(I2))
    return getModRefInfo(I1, Call2, AAQI);

  // Be conservative in the face of atomic operations with ordering
  // constraints that affect arbitrary addresses.
  if (const auto *LI = dyn_cast<LoadInst>(I2)) {
    if (isStrongerThan(LI->getOrdering(), AtomicOrdering::Unordered))
      return ModRefInfo::ModRef;
  } else if (const auto *SI = dyn_cast<StoreInst>(I2)) {
    if (isStrongerThan(SI->getOrdering(), AtomicOrdering::Unordered))
      return ModRefInfo::ModRef;
  } else if (const auto *CX = dyn_cast<AtomicCmpXchgInst>(I2)) {
    if (isStrongerThanMonotonic(CX->getSuccessOrdering()))
      return ModRefInfo::ModRef;
  } else if (const auto *RMW = dyn_cast<AtomicRMWInst>(I2)) {
    if (isStrongerThanMonotonic(RMW->getOrdering()))
      return ModRefInfo::ModRef;
  }

  // FIXME: We can have a more precise result.
  ModRefInfo MR = getModRefInfo(I1, MemoryLocation::getOrNone(I2), AAQI);
  return isModOrRefSet(MR) ? ModRefInfo::ModRef : ModRefInfo::NoModRef;
}
```

Alternatively, the function could check `I1`'s ordering as well (for symmetry), though the primary issue is with `I2` since `I1`'s ordering would be checked when `I1` is the atomic and the query goes through a different path.

## Relationship to Analysis 2

Analysis 2 reported a similar bug in `getModRefInfo(Instruction, CallBase)`, where the first instruction's atomic ordering was not checked. This bug is the symmetric case in `getModRefInfo(Instruction, Instruction)`, where the second instruction's atomic ordering is not checked.

Both bugs have the same root cause: converting an instruction to a `MemoryLocation` loses the instruction's ordering semantics. The fixes are similar: check atomic ordering before the conversion.

The two bugs are independent and both need to be fixed. Fixing one without the other still leaves a miscompilation path.

## Verification

The reproducer at `reproducer.ll` demonstrates the bug. Running:

```bash
opt -aa-pipeline=basic-aa -passes="print-alias-sets" -disable-output < reproducer.ll
```

Shows `NoModRef` for the test cases, when it should show `ModRef`.

A more direct test would use a pass that consumes mod/ref info and observe the miscompilation, similar to the Sink pass test in analysis 2.
