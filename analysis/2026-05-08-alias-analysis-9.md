# Alias Analysis Bug: FenceInst AA Chain Handler Allows ScopedNoAliasAA to Break Fence Barriers

## Summary

The recent commit `e2f92a324bff` ("[AA] Teach getModRefInfo(FenceInst) to
consult the AA chain") changed `AAResults::getModRefInfo(FenceInst, Loc)` to
iterate through all AA implementations. This allows `ScopedNoAliasAAResult` to
return `NoModRef` for a fence instruction that carries `!noalias` metadata
covering the queried location's `!alias.scope`. Since fences are global memory
barriers (not access-specific), scoped noalias reasoning does not apply to
them. The incorrect `NoModRef` result causes MemorySSA to skip the fence when
looking for clobbers, and EarlyCSE then CSEs loads across the fence barrier.

**This is not a hand-crafted-IR-only bug.** The LLVM inliner's
`PropagateCallSiteMetadata` function naturally produces `!noalias` on fences
during nested inlining of functions with C `restrict` parameters. A C program
using `restrict` and `__atomic_thread_fence` can be miscompiled at `-O2`.

## Relationship to Analysis 2

Analysis 2 found that `getModRefInfo(Instruction, CallBase)` bypasses atomic
ordering checks for non-call atomic instructions. This bug is in a **different
code path** and has a **different mechanism**:

| | Analysis 2 | This Bug |
|---|---|---|
| **Location** | `AAResults::getModRefInfo(Instruction*, CallBase*)` (line 204) | `AAResults::getModRefInfo(FenceInst*, MemoryLocation&)` (line 505) via `ScopedNoAliasAAResult::getModRefInfo(FenceInst*, ...)` (line 97) |
| **Root cause** | Missing ordering check before alias query | ScopedNoAliasAA applying access-specific noalias reasoning to a global barrier |
| **Affected instructions** | Atomic loads/stores/cmpxchg/rmw vs calls | Fences vs memory locations |
| **Trigger** | Any atomic op + call with restricted memory effects | Fence with `!noalias` metadata (produced by nested inlining with `restrict`) |
| **How metadata arrives** | N/A (no metadata involved) | `PropagateCallSiteMetadata` copies callsite `!noalias` to inlined fence |
| **Consuming pass** | Sink pass (demonstrated) | EarlyCSE via MemorySSA |
| **C reproducible** | Yes, with specific pass pipeline | Yes, with `-O2` and nested `restrict` + `always_inline` |

The common theme is that barrier semantics are bypassed, but the mechanisms
are independent: analysis 2 is a missing check in the `(Instruction, CallBase)`
overload, while this bug is ScopedNoAliasAA being consulted for an instruction
type (fences) where its reasoning is unsound.

## Bug Location

**File:** `llvm/lib/Analysis/AliasAnalysis.cpp`, lines 505-527 (introduced by
commit `e2f92a324bff`)

```cpp
ModRefInfo AAResults::getModRefInfo(const FenceInst *F,
                                    const MemoryLocation &Loc,
                                    AAQueryInfo &AAQI) {
  if (Loc.Ptr) {
    ModRefInfo Result = ModRefInfo::ModRef;

    for (const auto &AA : AAs) {
      Result &= AA->getModRefInfo(F, Loc, AAQI);   // ← ScopedNoAliasAA
      if (isNoModRef(Result))                        //   can return NoModRef
        return ModRefInfo::NoModRef;
    }
    ...
  }
  return ModRefInfo::ModRef;
}
```

**File:** `llvm/lib/Analysis/ScopedNoAliasAA.cpp`, lines 97-112

```cpp
ModRefInfo ScopedNoAliasAAResult::getModRefInfo(const FenceInst *F,
                                                const MemoryLocation &Loc,
                                                AAQueryInfo &AAQI) {
  ...
  if (!mayAliasInScopes(Loc.AATags.Scope,
                        F->getMetadata(LLVMContext::MD_noalias)))
    return ModRefInfo::NoModRef;       // ← Unsound for fences
  ...
}
```

## How `!noalias` Arrives on Fences

The inliner's `PropagateCallSiteMetadata` (`InlineFunction.cpp:943-981`)
copies callsite metadata to all memory-accessing instructions in the inlined
body:

```cpp
for (Instruction &I : BB) {
  if (!I.mayReadOrWriteMemory())   // fence returns true here
    continue;
  ...
  if (NoAlias)
    I.setMetadata(LLVMContext::MD_noalias, MDNode::concatenate(
        I.getMetadata(LLVMContext::MD_noalias), NoAlias));
}
```

A fence has `mayReadOrWriteMemory() == true`, so it receives the callsite's
`!noalias` metadata. This happens during nested inlining:

1. `middle(int *restrict a, int *restrict b)` is inlined into `outer()`.
   `AddAliasScopeMetadata` creates scoped noalias metadata for the `restrict`
   parameters and adds `!noalias` to the call to `inner_fence()` (which
   doesn't access `%b`).

2. `inner_fence()` (which contains the fence) is then inlined.
   `PropagateCallSiteMetadata` copies the callsite's `!noalias` to the fence.

Result: `fence seq_cst, !noalias !{scope_for_b}`.

Note that `AddAliasScopeMetadata` correctly skips fences (line 1284: fences
have no `PtrArgs` and are not `IsFuncCall`). The bug is that
`PropagateCallSiteMetadata` does NOT skip fences.

## C Reproducer

```c
// Compile with: clang -O2
// Bug: outer() is compiled to always return 0.
// Correct: outer() should load *y twice (before/after fence) and return
// the difference, which may be non-zero under concurrent modification.

__attribute__((always_inline))
static inline void inner_fence(int *p, int val) {
    *p = val;
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
}

__attribute__((always_inline))
static inline int middle(int *restrict a, int *restrict b) {
    int v1 = *b;
    inner_fence(a, 42);
    int v2 = *b;
    return v2 - v1;
}

int outer(int *restrict x, int *restrict y) {
    return middle(x, y);
}
```

**Compiled output at `-O2`:**

```llvm
define dso_local i32 @outer(ptr noalias %x, ptr noalias %y) {
entry:
  store i32 42, ptr %x, align 4, !tbaa !4
  fence seq_cst
  ret i32 0              ; ← BUG: should load *y and return v2-v1
}
```

**Without `restrict`:** both loads survive and the function returns the
difference. Confirmed by comparison.

## LLVM-IR Reproducer

```llvm
; RUN: opt -aa-pipeline=basic-aa,scoped-noalias-aa \
; RUN:   -passes='early-cse<memssa>' -S < %s | FileCheck %s

target triple = "x86_64-unknown-linux-gnu"

define i32 @fence_noalias_bug(ptr %p) {
; CHECK-LABEL: @fence_noalias_bug(
; CHECK:         %v1 = load i32, ptr %p
; CHECK:         fence seq_cst
; CHECK:         %v2 = load i32, ptr %p
; CHECK:         %diff = sub i32 %v2, %v1
; CHECK:         ret i32 %diff
  %v1 = load i32, ptr %p, align 4, !alias.scope !2
  fence seq_cst, !noalias !2
  %v2 = load i32, ptr %p, align 4, !alias.scope !2
  %diff = sub i32 %v2, %v1
  ret i32 %diff
}

!0 = !{!"domain"}
!1 = !{!1, !0, !"scope1"}
!2 = !{!1}
```

**Miscompiled output:**

```llvm
define i32 @fence_noalias_bug(ptr %p) {
  %v1 = load i32, ptr %p, align 4, !alias.scope !0
  fence seq_cst, !noalias !0
  ret i32 0
}
```

EarlyCSE replaced `%v2` with `%v1` and folded `sub` to zero.

## Fix

Two independent fixes are needed:

**Fix 1:** `ScopedNoAliasAAResult::getModRefInfo(FenceInst, ...)` should
always return `ModRef`:

```cpp
ModRefInfo ScopedNoAliasAAResult::getModRefInfo(const FenceInst *F,
                                                const MemoryLocation &Loc,
                                                AAQueryInfo &AAQI) {
  return ModRefInfo::ModRef;
}
```

Fences are global barriers. Scoped noalias reasoning applies to memory
accesses at specific addresses; fences don't access addresses.

**Fix 2:** `PropagateCallSiteMetadata` should skip fences:

```cpp
for (Instruction &I : BB) {
  if (!I.mayReadOrWriteMemory())
    continue;
  if (isa<FenceInst>(I))
    continue;   // Fences are not address-specific accesses
  ...
}
```

Either fix alone prevents the miscompilation. Both should be applied for
defense-in-depth.
