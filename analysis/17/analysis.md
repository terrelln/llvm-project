# Alias Analysis Bug: `getModRefInfo(Instruction, Instruction)` Bypasses Atomic Ordering Checks for Second Instruction

## Summary

`AAResults::getModRefInfo(const Instruction *I1, const Instruction *I2,
AAQueryInfo &AAQI)` does not check the atomic ordering of instruction `I2`
before performing its alias query. When `I2` is an atomic load, store, cmpxchg,
or rmw with ordering stronger than unordered/monotonic, it has memory ordering
properties that affect **arbitrary** addresses. But the function converts `I2`
to a `MemoryLocation` and only checks if `I1` accesses that specific location,
missing the atomic ordering constraint.

This is a variant of the bug reported in analysis 2, but in a different code
path. Analysis 2 covered `getModRefInfo(Instruction, CallBase)` where the first
instruction is atomic. This bug covers `getModRefInfo(Instruction, Instruction)`
where the second instruction is atomic and is not a `CallBase`.

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
2. `I2` is a `CallBase` → delegates to `getModRefInfo(I1, Call2)`. (This is the
   buggy path from analysis 2 when `I1` is atomic.)
3. Otherwise → converts `I2` to a `MemoryLocation` and checks if `I1` accesses
   that location. **Missing the atomic ordering check for `I2`.**

## The Correct Behavior (Instruction-Specific Handlers)

Each instruction-specific `getModRefInfo` handler checks atomic ordering
**before** testing alias relationships:

| Instruction | Check | Location |
|-------------|-------|----------|
| `LoadInst` | `isStrongerThan(L->getOrdering(), Unordered)` | line 465 |
| `StoreInst` | `isStrongerThan(S->getOrdering(), Unordered)` | line 483 |
| `AtomicCmpXchgInst` | `isStrongerThanMonotonic(CX->getSuccessOrdering())` | line 578 |
| `AtomicRMWInst` | `isStrongerThanMonotonic(RMW->getOrdering())` | line 596 |

When the ordering threshold is exceeded, they return `ModRef` for **any**
location — the comment on line 577 explains why:

```cpp
// Acquire/Release cmpxchg has properties that matter for arbitrary addresses.
```

These ordering properties are lost when the query goes through the
`(Instruction, Instruction)` path and `I2` is converted to a `MemoryLocation`.

However, I1's ordering IS checked. The call at line 399:

```cpp
ModRefInfo MR = getModRefInfo(I1, MemoryLocation::getOrNone(I2), AAQI);
```

dispatches (via line 610) to I1's instruction-specific handler, which checks
I1's own ordering. So the bug only manifests when **I1 does NOT have strong
ordering** but **I2 does**.

## How the Bug Triggers

The bug triggers when:
1. `I1` is a memory-accessing instruction that does NOT itself have strong
   atomic ordering (e.g. a call, a non-atomic load/store, or a monotonic/
   unordered atomic)
2. `I2` is an atomic instruction with strong ordering (acquire, release,
   acq_rel, seq_cst) and is NOT a `CallBase`
3. `I1` and `I2` access different memory locations (so the alias check returns
   NoAlias)

In this case, `getModRefInfo(I1, I2)` returns `NoModRef`, but it should return
`ModRef` because `I2`'s ordering constraints affect arbitrary addresses.

## LLVM-IR Proof

```llvm
; Example 1: call with restricted memory effects + release store
;
; getModRefInfo(call @reader, store atomic release) should return ModRef,
; but the bug returns NoModRef because @reader doesn't access %flag
; and I2's release ordering is never checked.

declare void @reader(ptr %data) memory(argmem: read)

define void @call_vs_release_store(ptr noalias %flag, ptr noalias %data) {
  call void @reader(ptr %data)                         ; I1
  store atomic i32 1, ptr %flag release, align 4       ; I2

  ; getModRefInfo(I1, I2):
  ;   I2 = store atomic release to %flag (not a CallBase) → line 399
  ;   getModRefInfo(call @reader, {%flag, 4})
  ;     → dispatch to CallBase handler for I1
  ;     → @reader has memory(argmem: read) and arg is %data, not %flag
  ;     → NoModRef
  ;   I2's release ordering never checked
  ;   → returns NoModRef                                ← BUG
  ;
  ; Correct answer: ModRef (release store has ordering properties
  ; that affect arbitrary addresses)

  ret void
}

; Example 2: non-atomic store + acquire load to different addresses
;
; This is the clearest demonstration: I1 has no ordering, so I1's
; instruction-specific handler won't bail early. I2's acquire ordering
; is lost when I2 is converted to a MemoryLocation.

define void @plain_store_vs_acquire_load(ptr noalias %x, ptr noalias %y) {
  store i32 42, ptr %x                                 ; I1: non-atomic store
  %v = load atomic i32, ptr %y acquire, align 4        ; I2: acquire load

  ; getModRefInfo(I1, I2):
  ;   I2 = load atomic acquire from %y (not a CallBase) → line 399
  ;   getModRefInfo(store i32 42 to %x, {%y, 4})
  ;     → dispatch to StoreInst handler (line 479)
  ;     → line 483: isStrongerThan(non-atomic, Unordered) → false
  ;     → alias({%x, 4}, {%y, 4}) → NoAlias
  ;     → NoModRef
  ;   I2's acquire ordering never checked
  ;   → returns NoModRef                                ← BUG
  ;
  ; Correct answer: ModRef (acquire load has ordering properties
  ; that affect arbitrary addresses)

  ret void
}

; NOTE: Two atomics with strong ordering (e.g. release store + acquire load)
; do NOT demonstrate the bug, because I1's ordering is caught by I1's
; instruction-specific handler before the alias check.
```

## Verification

The bug in Example 1 (call vs release store) can be confirmed through `aa-eval`:

```bash
build/bin/opt -aa-pipeline=basic-aa -passes=aa-eval \
  -print-all-alias-modref-info -disable-output < reproducer.ll 2>&1
```

Output includes:
```
NoModRef:   call void @reader(ptr %data) <->   store atomic i32 1, ptr %flag release, align 4
```

This confirms the API returns `NoModRef` when the correct answer is `ModRef`.

**Note:** `aa-eval` can only test Example 1 because it populates `OtherMemOps`
with `CallBase` and atomic instructions only (`AliasAnalysisEvaluator.cpp:122`).
A non-atomic store (Example 2) is not added to `OtherMemOps`, so `aa-eval`
never tests that pair through the two-instruction overload. Example 2 is
validated by code tracing only.

## Impact Assessment

### Callers of `getModRefInfo(Instruction*, Instruction*)`

I audited every call to `getModRefInfo` in the LLVM codebase. Only these callers
use the two-instruction overload (where I2 could be a non-CallBase atomic):

| Caller | Location | Can I2 be ordered atomic? |
|--------|----------|--------------------------|
| `AliasAnalysisEvaluator` | `AliasAnalysisEvaluator.cpp:247` | Yes, but diagnostic only |
| LICM `noConflictingReadWrites` | `LICM.cpp:2336` | **No** — `canSinkOrHoistInst` filters at line 1265: `if (!SI->isUnordered()) return false;` |
| FlattenCFG `CompareIfRegionBlock` | `FlattenCFG.cpp:350` | Possible but unlikely to cause miscompilation |

### Passes that do NOT use this overload

- **MemorySSA**: Uses `getModRefInfo(DefInst, CB)` (Instruction, CallBase
  overload — analysis 2's path) and `getModRefInfo(DefInst, UseLoc)`
  (Instruction, MemoryLocation overload). Never calls the two-instruction
  overload.
- **EarlyCSE, GVN, DSE**: All query through MemorySSA, which does not use the
  two-instruction overload.
- **Sink pass**: Calls `getModRefInfo(S, Call)` (Instruction, CallBase overload)
  and `getModRefInfo(S, Loc)` (Instruction, MemoryLocation overload). Never
  calls the two-instruction overload.
- **LICM** (hoisting path): Guards against ordered atomics before reaching the
  buggy call.

### Current exploitability

No current optimization pass calls `getModRefInfo(I1, I2)` with an ordered
atomic as I2 in a way that produces incorrect transformations. The bug is a
**latent API-level defect**: the API returns incorrect results, but no consumer
currently acts on those results to produce wrong code.

This is still worth fixing — the API contract is violated, and any future pass
that uses the two-instruction overload could be affected.

## Fix

Add atomic ordering checks for I2 before converting it to a `MemoryLocation`,
mirroring the checks in the instruction-specific handlers:

```cpp
ModRefInfo AAResults::getModRefInfo(const Instruction *I1,
                                    const Instruction *I2, AAQueryInfo &AAQI) {
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

## Relationship to Analysis 2

Analysis 2 reported a similar bug in `getModRefInfo(Instruction, CallBase)`,
where the first instruction's atomic ordering was not checked. This bug is in
`getModRefInfo(Instruction, Instruction)`, where the second instruction's
atomic ordering is not checked when I2 is a non-CallBase atomic.

Both bugs have the same root cause: converting an instruction to a
`MemoryLocation` loses the instruction's ordering semantics.

| Bug | Path | What's missing |
|-----|------|----------------|
| Analysis 2 | `getModRefInfo(Instruction, CallBase)` line 204 | I1's ordering not checked |
| This bug | `getModRefInfo(Instruction, Instruction)` line 389 | I2's ordering not checked |

Analysis 2 has a concrete exploitable path (Sink pass). This bug is a latent
API defect — the fix is correct and worthwhile, but no current pass triggers it.
