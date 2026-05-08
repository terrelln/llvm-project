# Alias Analysis Bug: `getModRefInfo(Instruction, CallBase)` Bypasses Atomic Ordering Checks

## Summary

`AAResults::getModRefInfo(const Instruction *I, const CallBase *Call2)` does not
check the atomic ordering of instruction `I` before performing its alias query.
The instruction-specific `getModRefInfo` handlers (for `LoadInst`, `StoreInst`,
`AtomicCmpXchgInst`, `AtomicRMWInst`) all return `ModRef` unconditionally when
the atomic ordering is stronger than a threshold — because acquire/release/seqcst
operations have memory ordering properties that affect **arbitrary** addresses.
But the `(Instruction, CallBase)` overload skips these checks entirely, returning
`NoModRef` when `Call2` doesn't access the atomic instruction's specific memory
location. This can cause a pass to incorrectly reorder or eliminate instructions
across an atomic memory barrier, producing a miscompilation.

## Bug Location

**File:** `llvm/lib/Analysis/AliasAnalysis.cpp`, lines 204-223

```cpp
ModRefInfo AAResults::getModRefInfo(const Instruction *I, const CallBase *Call2,
                                    AAQueryInfo &AAQI) {
  // We may have two calls.
  if (const auto *Call1 = dyn_cast<CallBase>(I)) {
    // Check if the two calls modify the same memory.
    return getModRefInfo(Call1, Call2, AAQI);
  }
  // If this is a fence, just return ModRef.
  if (I->isFenceLike())
    return ModRefInfo::ModRef;
  // Otherwise, check if the call modifies or references the
  // location this memory access defines.  The best we can say
  // is that if the call references what this instruction
  // defines, it must be clobbered by this location.
  const MemoryLocation DefLoc = MemoryLocation::get(I);         // ← only checks I's location
  ModRefInfo MR = getModRefInfo(Call2, DefLoc, AAQI);
  if (isModOrRefSet(MR))
    return ModRefInfo::ModRef;
  return ModRefInfo::NoModRef;                                    // ← BUG: misses atomic ordering
}
```

The function handles three cases:
1. `I` is a `CallBase` → delegates to the call-call overload. **Correct.**
2. `I` is fence-like → returns `ModRef`. **Correct.**
3. `I` is any other memory instruction → checks if `Call2` accesses `I`'s
   specific location. **Missing the atomic ordering check.**

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
`(Instruction, CallBase)` path instead of the instruction-specific handler.

## How the Bug Triggers

`getModRefInfo(I, Call2)` is called from `getModRefInfo(I1, I2)` (line 395)
whenever `I2` is a `CallBase`:

```cpp
ModRefInfo AAResults::getModRefInfo(const Instruction *I1,
                                    const Instruction *I2, AAQueryInfo &AAQI) {
  ...
  if (const auto *Call2 = dyn_cast<CallBase>(I2))
    return getModRefInfo(I1, Call2, AAQI);    // ← enters the buggy path
  ...
}
```

So any pass that queries the dependency between an atomic instruction `I1` and
a call `I2` hits the buggy path when `I1` is **not** itself a call.

## LLVM-IR Proof

```llvm
; A release store synchronizes-with an acquire load on another thread.
; A pass must not reorder the release store past a call that might
; contain the matching acquire.
;
; getModRefInfo(release_store, call @reader) should return ModRef,
; but the bug returns NoModRef if @reader doesn't access %flag.

declare void @reader(ptr %data) memory(argmem: read)

define void @release_store_miscompile(ptr %flag, ptr %data) {
  store i32 42, ptr %data                             ; (1) write shared data
  store atomic i32 1, ptr %flag release, align 4       ; (2) release-store to flag
  call void @reader(ptr %data)                         ; (3) call that reads data

  ; getModRefInfo((2), (3)):
  ;   I = store atomic release to %flag  (not a CallBase, not fence-like)
  ;   Call2 = @reader(%data)
  ;   DefLoc = {%flag, 4}
  ;   MR = getModRefInfo(@reader, {%flag, 4})
  ;      @reader only accesses %data (argmem:read), not %flag → NoModRef
  ;   isModOrRefSet(NoModRef) = false
  ;   → returns NoModRef                                ← BUG
  ;
  ; Correct answer: ModRef, because the release store has ordering
  ; properties that affect arbitrary addresses (line 483).
  ;
  ; A pass that trusts this NoModRef could reorder (3) before (2),
  ; or determine there is no dependency and make other incorrect
  ; transformations.

  ret void
}

; Same issue with cmpxchg:
declare void @unknown() memory(inaccessiblemem: readwrite)

define i1 @cmpxchg_miscompile(ptr %lock) {
  %pair = cmpxchg ptr %lock, i32 0, i32 1 seq_cst seq_cst  ; (1) seqcst cmpxchg
  %ok = extractvalue { i32, i1 } %pair, 1
  call void @unknown()                                       ; (2) call to unknown

  ; getModRefInfo((1), (2)):
  ;   I = cmpxchg seq_cst  (not a CallBase, not fence-like)
  ;   Call2 = @unknown()
  ;   DefLoc = {%lock, 4}
  ;   MR = getModRefInfo(@unknown, {%lock, 4})
  ;      @unknown only accesses inaccessible mem, not %lock → NoModRef
  ;   → returns NoModRef                                ← BUG
  ;
  ; Correct answer: ModRef (line 578: isStrongerThanMonotonic(seq_cst) = true)

  ret i1 %ok
}

; And with atomicrmw:
define i32 @atomicrmw_miscompile(ptr %counter) {
  %old = atomicrmw add ptr %counter, i32 1 acq_rel        ; (1) acq_rel atomicrmw
  call void @unknown()                                      ; (2) call

  ; getModRefInfo((1), (2)):
  ;   I = atomicrmw acq_rel  (not a CallBase, not fence-like)
  ;   → returns NoModRef                                ← BUG
  ;
  ; Correct answer: ModRef (line 596: isStrongerThanMonotonic(acq_rel) = true)

  ret i32 %old
}
```

## Comparison: Correct Path vs Buggy Path

For a `seq_cst` cmpxchg at address `%lock`, with a call that does NOT access
`%lock`:

| Query path | Result | Correct? |
|------------|--------|----------|
| `getModRefInfo(cmpxchg, some_other_location)` | **ModRef** (line 578 catches ordering) | Yes |
| `getModRefInfo(cmpxchg, some_call)` | **NoModRef** (ordering not checked) | **NO** |

The same cmpxchg instruction produces opposite results depending on whether the
other operand is a memory location or a call instruction.

## Fix

Add atomic ordering checks to `getModRefInfo(Instruction, CallBase)` before the
alias query, mirroring the checks in the instruction-specific handlers:

```cpp
ModRefInfo AAResults::getModRefInfo(const Instruction *I, const CallBase *Call2,
                                    AAQueryInfo &AAQI) {
  if (const auto *Call1 = dyn_cast<CallBase>(I))
    return getModRefInfo(Call1, Call2, AAQI);

  if (I->isFenceLike())
    return ModRefInfo::ModRef;

  // Be conservative in the face of atomic operations with ordering
  // constraints that affect arbitrary addresses.
  if (const auto *LI = dyn_cast<LoadInst>(I)) {
    if (isStrongerThan(LI->getOrdering(), AtomicOrdering::Unordered))
      return ModRefInfo::ModRef;
  } else if (const auto *SI = dyn_cast<StoreInst>(I)) {
    if (isStrongerThan(SI->getOrdering(), AtomicOrdering::Unordered))
      return ModRefInfo::ModRef;
  } else if (const auto *CX = dyn_cast<AtomicCmpXchgInst>(I)) {
    if (isStrongerThanMonotonic(CX->getSuccessOrdering()))
      return ModRefInfo::ModRef;
  } else if (const auto *RMW = dyn_cast<AtomicRMWInst>(I)) {
    if (isStrongerThanMonotonic(RMW->getOrdering()))
      return ModRefInfo::ModRef;
  }

  const MemoryLocation DefLoc = MemoryLocation::get(I);
  ModRefInfo MR = getModRefInfo(Call2, DefLoc, AAQI);
  if (isModOrRefSet(MR))
    return ModRefInfo::ModRef;
  return ModRefInfo::NoModRef;
}
```

Alternatively, the function could delegate to the instruction-specific handler
instead of reimplementing the alias check:

```cpp
ModRefInfo AAResults::getModRefInfo(const Instruction *I, const CallBase *Call2,
                                    AAQueryInfo &AAQI) {
  if (const auto *Call1 = dyn_cast<CallBase>(I))
    return getModRefInfo(Call1, Call2, AAQI);
  if (I->isFenceLike())
    return ModRefInfo::ModRef;
  const MemoryLocation DefLoc = MemoryLocation::get(I);
  // Use the instruction-specific handler, which checks atomic ordering.
  ModRefInfo MR = getModRefInfo(I, DefLoc, AAQI);
  if (isNoModRef(MR))
    return ModRefInfo::NoModRef;
  // I accesses DefLoc. Check if Call2 also accesses it.
  ModRefInfo CallMR = getModRefInfo(Call2, DefLoc, AAQI);
  if (isModOrRefSet(CallMR))
    return ModRefInfo::ModRef;
  // I has ordering effects but Call2 doesn't touch DefLoc.
  // If I's handler returned ModRef due to ordering, we must propagate that.
  if (MR == ModRefInfo::ModRef)
    return ModRefInfo::ModRef;
  return ModRefInfo::NoModRef;
}
```

---

## Review

### Verdict

The bug identification, explanation, and proposed fix are all correct.

### Verified Claims

1. **The buggy function (lines 204-223)** — Code matches exactly. The three
   cases are correctly described: CallBase delegation, fence-like check,
   location-only alias query with no atomic ordering check.

2. **`isFenceLike()` does NOT cover atomic memory operations** — Confirmed at
   `llvm/include/llvm/IR/Instruction.h:879-892`. It only returns true for
   `Fence`, `CatchPad`, `CatchRet`, `Call`, and `Invoke`. `Store`, `Load`,
   `AtomicCmpXchg`, and `AtomicRMW` all fall through to the buggy case 3.

3. **Instruction-specific handlers check ordering** — All four confirmed:
   - `LoadInst` (line 465): `isStrongerThan(ordering, Unordered)` → `ModRef`
   - `StoreInst` (line 483): `isStrongerThan(ordering, Unordered)` → `ModRef`
   - `AtomicCmpXchgInst` (line 578): `isStrongerThanMonotonic` → `ModRef`
   - `AtomicRMWInst` (line 596): `isStrongerThanMonotonic` → `ModRef`

4. **The dispatch path** — Line 395-396 confirms that when `I2` is a `CallBase`,
   the buggy `getModRefInfo(I1, Call2, AAQI)` is called, bypassing the
   instruction-specific handlers at lines 620-646.

5. **The LLVM-IR examples are well-crafted** — Each correctly demonstrates the
   discrepancy between the buggy path and the instruction-specific handlers.

6. **The proposed fix is correct** — It mirrors the exact ordering thresholds
   from each instruction-specific handler: `isStrongerThan(Unordered)` for
   loads/stores, `isStrongerThanMonotonic` for cmpxchg/atomicrmw.

### Gap: Can This Bug Cause a Miscompilation?

The analysis proves the API returns incorrect results but does not demonstrate
that any optimization pass acts on those results to produce wrong code. Two
callers hit the buggy path:

**Sink pass** (`llvm/lib/Transforms/Scalar/Sink.cpp:61-63`) — This is the most
direct path to a miscompilation. The Sink pass iterates instructions in reverse,
collecting write instructions into a `Stores` set. For each read-only call, it
checks whether any later store conflicts:

```cpp
for (Instruction *S : Stores)
  if (isModSet(AA.getModRefInfo(S, Call)))
    return false;
```

Consider:

```llvm
declare i32 @read_data(ptr) nounwind willreturn memory(argmem: read)

define i32 @test(ptr noalias %flag, ptr %data, i1 %cond) {
entry:
  %v = call i32 @read_data(ptr %data)            ; (1) read-only call
  store atomic i32 1, ptr %flag release, align 4  ; (2) release store
  br i1 %cond, label %then, label %else
then:
  ret i32 %v
else:
  ret i32 0
}
```

Processing `entry` in reverse:

1. Release store (2): `mayWriteToMemory()` = true → added to `Stores`, not
   sinkable.
2. Call (1): `mayWriteToMemory()` = false (`argmem: read`). Passes all safety
   checks (`nounwind`, `willreturn`, not convergent). Enters the `Stores` loop:
   `getModRefInfo(release_store_to_%flag, @read_data(%data))` → NoModRef (bug).
   `isSafeToMove` returns true.
3. `SinkInstruction` finds `%v`'s only use is in `then`.
   `then->getUniquePredecessor() == entry`, so the `mayReadFromMemory` guard at
   line 87 (which only triggers on critical edges) does not fire.
   `IsAcceptableTarget` returns true.

Result after sinking:

```llvm
define i32 @test(ptr noalias %flag, ptr %data, i1 %cond) {
entry:
  store atomic i32 1, ptr %flag release, align 4
  br i1 %cond, label %then, label %else
then:
  %v = call i32 @read_data(ptr %data)             ; SUNK past release store
  ret i32 %v
else:
  ret i32 0
}
```

The read has been moved past the release store, violating LLVM's release
semantics (no preceding memory operation may be reordered past a release store).

**MemorySSA** (`llvm/lib/Analysis/MemorySSA.cpp:313-316`) — The clobber walker
calls `AA.getModRefInfo(DefInst, CB)` when the use instruction is a `CallBase`.
An atomic def with ordering is incorrectly skipped, producing a wrong MemorySSA
graph. Downstream passes (DSE, LICM, EarlyCSE, GVN, MemCpyOpt) rely on this
graph, but constructing an end-to-end miscompilation through MemorySSA is harder
since those passes have additional safety checks.

---

## Validated Reproducer

All three atomic instruction types reproduce the bug end-to-end through the Sink
pass. The reproducer is at `reproducer.ll` in the repo root and copied below:

```llvm
; Reproducer for alias analysis bug: getModRefInfo(Instruction, CallBase)
; bypasses atomic ordering checks.
;
; The Sink pass queries getModRefInfo(atomic_op, call). The buggy path returns
; NoModRef because the call doesn't access the atomic op's specific address,
; but the atomic op has ordering properties that affect arbitrary addresses.
; This causes the Sink pass to incorrectly sink the call past the atomic op.
;
; RUN: opt -passes=sink -S < %s | FileCheck %s

; @read_data only reads its pointer argument — it does NOT access %flag.
declare i32 @read_data(ptr) nounwind willreturn memory(argmem: read)

; CHECK-LABEL: define i32 @release_store_sink_bug
define i32 @release_store_sink_bug(ptr noalias %flag, ptr %data, i1 %cond) {
entry:
  ; This call should NOT be sunk past the release store, because the release
  ; store is a memory barrier: no preceding memory operation may move past it.
  ;
  ; BUG: the call IS sunk because getModRefInfo(store atomic release, call)
  ;      returns NoModRef — it only checks whether @read_data accesses %flag
  ;      and misses the atomic ordering constraint.
  %v = call i32 @read_data(ptr %data)
  store atomic i32 1, ptr %flag release, align 4
  br i1 %cond, label %then, label %else

; BUG: @read_data is sunk past the release store into %then.
; CHECK:       entry:
; CHECK-NEXT:    store atomic i32 1, ptr %flag release, align 4
; CHECK:       then:
; CHECK-NEXT:    %v = call i32 @read_data(ptr %data)
; CHECK-NEXT:    ret i32 %v
;
; CORRECT (if fixed): @read_data stays in entry before the release store.

then:
  ret i32 %v

else:
  ret i32 0
}

; @read_inaccessible reads only inaccessible memory — it does NOT access %lock.
declare i32 @read_inaccessible() nounwind willreturn memory(inaccessiblemem: read)

; Same bug with seq_cst cmpxchg.
; CHECK-LABEL: define i32 @cmpxchg_sink_bug
define i32 @cmpxchg_sink_bug(ptr noalias %lock, i1 %cond) {
entry:
  %x = call i32 @read_inaccessible()
  %pair = cmpxchg ptr %lock, i32 0, i32 1 seq_cst seq_cst
  br i1 %cond, label %then, label %else

; BUG: @read_inaccessible is sunk past the seq_cst cmpxchg.
; CHECK:       entry:
; CHECK-NEXT:    %pair = cmpxchg
; CHECK:       then:
; CHECK-NEXT:    %x = call i32 @read_inaccessible()
; CHECK-NEXT:    ret i32 %x

then:
  ret i32 %x

else:
  ret i32 0
}

; Same bug with acq_rel atomicrmw.
; CHECK-LABEL: define i32 @atomicrmw_sink_bug
define i32 @atomicrmw_sink_bug(ptr noalias %counter, i1 %cond) {
entry:
  %x = call i32 @read_inaccessible()
  %old = atomicrmw add ptr %counter, i32 1 acq_rel
  br i1 %cond, label %then, label %else

; BUG: @read_inaccessible is sunk past the acq_rel atomicrmw.
; CHECK:       entry:
; CHECK-NEXT:    %old = atomicrmw add
; CHECK:       then:
; CHECK-NEXT:    %x = call i32 @read_inaccessible()
; CHECK-NEXT:    ret i32 %x

then:
  ret i32 %x

else:
  ret i32 0
}
```

**Validation command:**

```sh
build/bin/opt -passes=sink -S < reproducer.ll | build/bin/FileCheck reproducer.ll
```

FileCheck passes, confirming the Sink pass incorrectly sinks calls past atomic
operations with ordering constraints.

### Test Case 1: Release Store

```llvm
declare i32 @read_data(ptr) nounwind willreturn memory(argmem: read)

define i32 @release_store_sink_bug(ptr noalias %flag, ptr %data, i1 %cond) {
entry:
  %v = call i32 @read_data(ptr %data)
  store atomic i32 1, ptr %flag release, align 4
  br i1 %cond, label %then, label %else
then:
  ret i32 %v
else:
  ret i32 0
}
```

**Result:** `@read_data` is sunk from `entry` (before the release store) into
`then` (after the release store and branch), violating release semantics.

```llvm
; Output from opt -passes=sink:
define i32 @release_store_sink_bug(ptr noalias %flag, ptr %data, i1 %cond) {
entry:
  store atomic i32 1, ptr %flag release, align 4
  br i1 %cond, label %then, label %else
then:
  %v = call i32 @read_data(ptr %data)       ; SUNK past release store — BUG
  ret i32 %v
else:
  ret i32 0
}
```

### Test Case 2: seq_cst cmpxchg

```llvm
declare i32 @read_inaccessible() nounwind willreturn memory(inaccessiblemem: read)

define i32 @cmpxchg_sink_bug(ptr noalias %lock, i1 %cond) {
entry:
  %x = call i32 @read_inaccessible()
  %pair = cmpxchg ptr %lock, i32 0, i32 1 seq_cst seq_cst
  br i1 %cond, label %then, label %else
then:
  ret i32 %x
else:
  ret i32 0
}
```

**Result:** `@read_inaccessible` is sunk past the seq_cst cmpxchg.

### Test Case 3: acq_rel atomicrmw

```llvm
define i32 @atomicrmw_sink_bug(ptr noalias %counter, i1 %cond) {
entry:
  %x = call i32 @read_inaccessible()
  %old = atomicrmw add ptr %counter, i32 1 acq_rel
  br i1 %cond, label %then, label %else
then:
  ret i32 %x
else:
  ret i32 0
}
```

**Result:** `@read_inaccessible` is sunk past the acq_rel atomicrmw.

### Why These Reproduce

Each test constructs the conditions for the Sink pass to hit the buggy path:

1. The call has `nounwind willreturn` and restricted memory effects → passes
   `isSafeToMove` safety checks (not a may-throw, will-return, not convergent).
2. The call does not write memory → not added to `Stores`, eligible for sinking.
3. The atomic instruction writes memory → added to `Stores`.
4. The call enters the `Stores` loop at `Sink.cpp:61-63`:
   `getModRefInfo(atomic_store, call)` → enters `AliasAnalysis.cpp:204`.
5. The atomic instruction is not a `CallBase` and not fence-like → falls through
   to the location-only alias check at line 218.
6. `%flag`/`%lock`/`%counter` is `noalias` with the call's memory
   (`argmem`/`inaccessiblemem`) → `getModRefInfo(call, DefLoc)` returns
   `NoModRef`.
7. The atomic ordering check is never performed → `NoModRef` is returned.
8. `isSafeToMove` returns true → the call is sunk into a successor block.

### C Reproducer

The bug can also be reproduced from C source with full control over the pass
pipeline. The C source is at `reproducer.c` in the repo root.

**Source:**

```c
__attribute__((noinline))
int read_data(const int *data) {
    return *data;
}

int release_store_sink_bug(int *restrict flag, int *restrict data, int cond) {
    int v = read_data(data);
    __atomic_store_n(flag, 1, __ATOMIC_RELEASE);
    if (cond)
        return v;
    return 0;
}
```

**Validation commands:**

```sh
build/bin/clang -emit-llvm -S -O0 -Xclang -disable-O0-optnone reproducer.c -o /tmp/reproducer-c.ll
build/bin/opt -passes='inferattrs,cgscc(function-attrs),attributor,function(mem2reg)' \
    -S /tmp/reproducer-c.ll -o /tmp/reproducer-c-attr.ll
build/bin/opt -passes=sink -S /tmp/reproducer-c-attr.ll
```

**Result:** `@read_data` is sunk from `entry` (before the release store) into
`if.then` (after the release store), same miscompilation as the LLVM-IR test.

**How the C maps to the required IR properties:**

| IR requirement | C source | Pass that infers it |
|----------------|----------|---------------------|
| `noalias` between `%flag` and `%data` | `restrict` on both pointers | Clang (`-emit-llvm`) |
| `memory(argmem: read)` on `@read_data` | Visible function body (`return *data`) | `function-attrs` then `attributor` (chained) |
| `nounwind willreturn` on `@read_data` | Inferred from simple body | `function-attrs` / `attributor` |
| Call not inlined | `__attribute__((noinline))` | Clang |
| Branch structure for sink target | `if (cond) return v;` | Clang (`-O0`) |

**Why the pass chain matters:** Neither attribute-inference pass alone produces
`memory(argmem: read)`. `function-attrs` infers `memory(read)` (correct access
type, scope too broad — the call appears to read all memory including `%flag`,
so the alias check coincidentally returns the right answer). `attributor` alone
infers `memory(argmem: readwrite)` (correct scope, access type too broad —
`mayWriteToMemory()` returns true so the Sink pass never considers the call for
sinking). Chaining `function-attrs` then `attributor` narrows to
`memory(argmem: read)`.

**Why `simplifycfg` must be avoided:** Running `simplifycfg` after `mem2reg`
collapses the `if/else` into a `select` instruction, eliminating the successor
blocks entirely. With only one basic block, the Sink pass has nowhere to sink to.

The LLVM-IR reproducer is more robust because it pins all attributes and control
flow directly, without depending on a fragile pass ordering.

### Multi-Threaded Runtime Reproducer

The miscompilation can be observed producing wrong values at runtime. The source
is at `reproducer_mt.c` in the repo root.

**Source:**

```c
#include <pthread.h>
#include <stdio.h>

#define ITERS 10000000

__attribute__((noinline))
int read_data(const int *data) {
    return *data;
}

__attribute__((noinline))
int test_func(int *restrict flag, int *restrict data, int cond) {
    int v = read_data(data);
    __atomic_store_n(flag, 1, __ATOMIC_RELEASE);
    if (cond)
        return v;
    return 0;
}

// Phase protocol: -1 (init) → 0 (main reset) → 1 (modifier ready) → 2 (modifier done)
static int shared_flag __attribute__((aligned(64)));
static int shared_data __attribute__((aligned(64)));
static int phase       __attribute__((aligned(64))) = -1;

static void *modifier(void *arg) {
    (void)arg;
    for (int i = 0; i < ITERS; i++) {
        while (__atomic_load_n(&phase, __ATOMIC_ACQUIRE) != 0)
            ;
        __atomic_store_n(&phase, 1, __ATOMIC_RELEASE);
        while (__atomic_load_n(&shared_flag, __ATOMIC_ACQUIRE) == 0)
            ;
        shared_data = 999;
        __atomic_store_n(&phase, 2, __ATOMIC_RELEASE);
    }
    return NULL;
}

int main(void) {
    pthread_t tid;
    pthread_create(&tid, NULL, modifier, NULL);

    int bad = 0;
    for (int i = 0; i < ITERS; i++) {
        shared_data = 42;
        __atomic_store_n(&shared_flag, 0, __ATOMIC_SEQ_CST);
        __atomic_store_n(&phase, 0, __ATOMIC_SEQ_CST);

        while (__atomic_load_n(&phase, __ATOMIC_ACQUIRE) != 1)
            ;

        int v = test_func(&shared_flag, &shared_data, 1);

        while (__atomic_load_n(&phase, __ATOMIC_ACQUIRE) != 2)
            ;

        if (v != 42) {
            if (++bad <= 3)
                printf("FAIL iter %d: got %d, expected 42\n", i, v);
        }
    }

    pthread_join(tid, NULL);
    printf("%s: %d/%d iterations wrong\n", bad ? "FAIL" : "PASS", bad, ITERS);
    return bad ? 1 : 0;
}
```

**Build and run commands:**

```sh
build/bin/clang -emit-llvm -S -O0 -Xclang -disable-O0-optnone \
    reproducer_mt.c -o /tmp/mt.ll
build/bin/opt -passes='inferattrs,cgscc(function-attrs),attributor,function(mem2reg)' \
    -S /tmp/mt.ll -o /tmp/mt_attr.ll
build/bin/opt -passes=sink -S /tmp/mt_attr.ll -o /tmp/mt_buggy.ll
build/bin/clang -O0 /tmp/mt_buggy.ll -o /tmp/mt_buggy -lpthread
build/bin/clang -O0 /tmp/mt_attr.ll  -o /tmp/mt_correct -lpthread
```

**Results:**

```
=== CORRECT ===
PASS: 0/10000000 iterations wrong

=== BUGGY ===
FAIL iter 991: got 999, expected 42
FAIL iter 1194: got 999, expected 42
FAIL iter 1888: got 999, expected 42
FAIL: 1585/10000000 iterations wrong
```

The correct version never fails. The miscompiled version returns 999 (the
modifier's value) instead of 42 in ~1500 out of 10 million iterations.

**How the test works:**

The main thread and a modifier thread synchronize via a three-state `phase`
variable (`-1` init → `0` reset → `1` ready → `2` done):

1. Main resets `shared_data = 42`, `shared_flag = 0`, `phase = 0`.
2. Modifier sees `phase == 0`, sets `phase = 1` (ready), spins on
   `shared_flag`.
3. Main sees `phase == 1`, calls `test_func` which reads `shared_data` and
   release-stores `shared_flag = 1`.
4. Modifier sees `shared_flag == 1`, writes `shared_data = 999`, sets
   `phase = 2`.
5. Main sees `phase == 2`, checks the return value.

In correctly compiled code, `test_func` reads `shared_data` (step 3) **before**
the release store. The modifier only writes after seeing `shared_flag = 1`,
which happens after the read. So the read always returns 42.

In miscompiled code, the read is sunk past the release store. The modifier can
see `shared_flag = 1` and write `shared_data = 999` before the sunk read
executes, causing `test_func` to return 999.
