# Alias Analysis Bug: ScopedNoAliasAA Masks Errno Effects via `!noalias` Metadata

## Summary

`ScopedNoAliasAAResult::getModRefInfo(CallBase*, MemoryLocation&)` returns
`NoModRef` when the call's `!noalias` metadata covers the queried location's
`!alias.scope`. This incorrectly masks **all** of the call's memory effects,
including `errnomem` writes that have nothing to do with pointer-based scoped
noalias reasoning.

A call declared `memory(errnomem: write)` with `!noalias !{scope_X}` will
appear to have no effect on a location tagged with `!alias.scope !{scope_X}`,
even when that location IS errno. EarlyCSE (with MemorySSA) then CSEs loads
across the call, producing wrong values.

**This is NOT the same as analysis 9.** Analysis 9 found that ScopedNoAliasAA
applies to `FenceInst`, which is a global barrier. This bug is in the
`CallBase` overload: the call's errno effects are masked out by scoped noalias
metadata that only covers pointer-argument-based accesses.

| | Analysis 9 | This Bug |
|---|---|---|
| **Overload** | `getModRefInfo(FenceInst*, MemoryLocation&)` | `getModRefInfo(CallBase*, MemoryLocation&)` |
| **Instruction** | Fence (global barrier) | Call with `errnomem` effects |
| **Root cause** | Scoped noalias applied to non-address-specific barrier | Scoped noalias masks errno effects that are not pointer-based |
| **Metadata source** | `PropagateCallSiteMetadata` on fence | `AddAliasScopeMetadata` / `PropagateCallSiteMetadata` on call |

## Bug Location

**File:** `llvm/lib/Analysis/ScopedNoAliasAA.cpp`, lines 80-95

```cpp
ModRefInfo ScopedNoAliasAAResult::getModRefInfo(const CallBase *Call,
                                                const MemoryLocation &Loc,
                                                AAQueryInfo &AAQI) {
  if (!EnableScopedNoAlias)
    return ModRefInfo::ModRef;

  if (!mayAliasInScopes(Loc.AATags.Scope,
                        Call->getMetadata(LLVMContext::MD_noalias)))
    return ModRefInfo::NoModRef;       // ← BUG: masks errno effects

  if (!mayAliasInScopes(Call->getMetadata(LLVMContext::MD_alias_scope),
                        Loc.AATags.NoAlias))
    return ModRefInfo::NoModRef;       // ← BUG: masks errno effects

  return ModRefInfo::ModRef;
}
```

When the call's `!noalias` scopes cover the location's `!alias.scope`, the
function returns `NoModRef`. But the call may have `memory(errnomem: write)`
effects that are independent of pointer-based aliasing. These errno effects
should NOT be masked by scoped noalias metadata.

## How It Triggers

The `!noalias` metadata is produced by the inliner's `AddAliasScopeMetadata`
(for `restrict` parameters) and `PropagateCallSiteMetadata` (for nested
inlining). When a function with `restrict` parameters is inlined, instructions
that don't access a particular `restrict` parameter's memory get `!noalias`
for that parameter's scope.

If the inlined function calls a library function that writes errno (e.g.,
`fmodf`, `strtol`, or any function with `memory(errnomem: write)`), the call
gets `!noalias` metadata for the `restrict` parameter's scope. Later, a load
from that parameter's memory gets `!alias.scope` for the same scope.

ScopedNoAliasAA sees the scope match and returns `NoModRef` for the call vs
the load location. This drops the errno write effect. MemorySSA treats the
call as non-clobbering, and EarlyCSE CSEs loads across the call.

## LLVM IR Reproducer

```llvm
; RUN: opt -aa-pipeline=basic-aa,scoped-noalias-aa \
; RUN:   -passes='early-cse<memssa>' -S < %s | FileCheck %s

target triple = "x86_64-unknown-linux-gnu"

declare void @set_errno() memory(errnomem: write)

define i32 @scoped_noalias_errno(ptr %errno_ptr) {
; CHECK-LABEL: define i32 @scoped_noalias_errno(
; CHECK:         %v1 = load i32, ptr %errno_ptr
; CHECK-NEXT:    call void @set_errno()
; CHECK-NEXT:    %v2 = load i32, ptr %errno_ptr
; CHECK-NEXT:    %diff = sub i32 %v2, %v1
; CHECK-NEXT:    ret i32 %diff
  %v1 = load i32, ptr %errno_ptr, align 4, !alias.scope !2
  call void @set_errno(), !noalias !2
  %v2 = load i32, ptr %errno_ptr, align 4, !alias.scope !2
  %diff = sub i32 %v2, %v1
  ret i32 %diff
}

!0 = !{!"domain"}
!1 = !{!1, !0, !"scope_errno"}
!2 = !{!1}
```

## Verified Miscompilation

```
$ build/bin/opt -aa-pipeline=basic-aa,scoped-noalias-aa \
    -passes='early-cse<memssa>' -S < analysis/16/reproducer.ll

define i32 @scoped_noalias_errno(ptr %errno_ptr) {
  %v1 = load i32, ptr %errno_ptr, align 4, !alias.scope !0
  call void @set_errno(), !noalias !0
  ret i32 0
}
```

EarlyCSE replaced `%v2` with `%v1` and folded `sub %v1, %v1` to `0`. The
second load is eliminated entirely. This is wrong because `@set_errno()` may
modify the memory at `%errno_ptr` (if it is errno).

## Why ScopedNoAliasAA Should Not Mask Errno Effects

Scoped noalias metadata describes pointer-based aliasing relationships. From
the LangRef:

> The noalias metadata ... indicates that memory accesses via pointers belonging
> to the scopes of its noalias metadata will not access memory that is also
> accessed by memory accesses identified by its alias.scope metadata.

The `errnomem` write is NOT via a pointer operand of the call. It's an
intrinsic property of the called function (e.g., a C library function that sets
`errno`). The errno address is not passed as an argument — it's implicit.

Therefore, `!noalias` metadata on a call should NOT suppress the call's errno
effects. The scoped noalias reasoning only applies to the call's
pointer-argument-based memory accesses, not to its implicit errno writes.

## How the Metadata Arrives in Practice

Through the inliner, when a function with `restrict` parameters calls an
errno-writing function:

```c
#include <math.h>

float middle(float *restrict a, float *restrict b, float x) {
    float v1 = *b;
    *a = fmodf(x, 2.0f);  // fmodf has memory(errnomem: write)
    float v2 = *b;
    return v2 - v1;
}
```

When `middle` is inlined:
1. `AddAliasScopeMetadata` creates scopes for the `restrict` parameters
2. The `fmodf` call doesn't access `b`, so it gets `!noalias !{scope_for_b}`
3. The loads from `*b` get `!alias.scope !{scope_for_b}`
4. ScopedNoAliasAA sees the scope match → `NoModRef` for `fmodf` vs `*b`
5. EarlyCSE CSEs the two loads of `*b`

This is wrong if `b` points to errno: `fmodf(INFINITY, 2.0f)` sets `errno`
to `EDOM`, which changes the value at `*b`.

## Fix

`ScopedNoAliasAAResult::getModRefInfo(CallBase*, MemoryLocation&)` should
not return `NoModRef` when the call has errno effects. Instead, it should
preserve the errno effects and only mask pointer-based effects.

Option 1: Return at most `errnomem` effects, not `NoModRef`:

```cpp
ModRefInfo ScopedNoAliasAAResult::getModRefInfo(const CallBase *Call,
                                                const MemoryLocation &Loc,
                                                AAQueryInfo &AAQI) {
  if (!EnableScopedNoAlias)
    return ModRefInfo::ModRef;

  if (!mayAliasInScopes(Loc.AATags.Scope,
                        Call->getMetadata(LLVMContext::MD_noalias)))
    // Scoped noalias only applies to pointer-based accesses.
    // Errno effects are not covered by scoped noalias metadata.
    return Call->getMemoryEffects().getModRef(IRMemLocation::ErrnoMem);

  if (!mayAliasInScopes(Call->getMetadata(LLVMContext::MD_alias_scope),
                        Loc.AATags.NoAlias))
    return Call->getMemoryEffects().getModRef(IRMemLocation::ErrnoMem);

  return ModRefInfo::ModRef;
}
```

Option 2: Be conservative and always return `ModRef` when errno effects
are present:

```cpp
ModRefInfo ScopedNoAliasAAResult::getModRefInfo(const CallBase *Call,
                                                const MemoryLocation &Loc,
                                                AAQueryInfo &AAQI) {
  if (!EnableScopedNoAlias)
    return ModRefInfo::ModRef;

  // Scoped noalias cannot mask errno effects.
  if (isModOrRefSet(Call->getMemoryEffects().getModRef(IRMemLocation::ErrnoMem)))
    return ModRefInfo::ModRef;

  if (!mayAliasInScopes(Loc.AATags.Scope,
                        Call->getMetadata(LLVMContext::MD_noalias)))
    return ModRefInfo::NoModRef;

  if (!mayAliasInScopes(Call->getMetadata(LLVMContext::MD_alias_scope),
                        Loc.AATags.NoAlias))
    return ModRefInfo::NoModRef;

  return ModRefInfo::ModRef;
}
```

Option 1 is more precise (only preserves errno effects, not all effects).
Option 2 is simpler and more conservative.

Similarly, the `getModRefInfo(CallBase*, CallBase*)` overload at lines 114-129
has the same issue: it should not mask errno effects via scoped noalias.

## C Reproducer

The bug is triggerable from C source with `restrict` parameters and
`fmodf`:

```c
#include <errno.h>
#include <math.h>
#include <stdio.h>

__attribute__((always_inline))
static int middle(float *restrict a, int *restrict b, float x) {
    int v1 = *b;
    *a = fmodf(x, 2.0f);
    int v2 = *b;
    return v2 - v1;
}

__attribute__((noinline))
int outer(float *restrict a, int *restrict b, float x) {
    return middle(a, b, x);
}

int main(void) {
    float dummy;
    errno = 0;
    int diff = outer(&dummy, &errno, __builtin_inff());
    printf("diff = %d\n", diff);
    return diff == 0 ? 1 : 0;
}
```

**Verified locally:**

```
$ build/bin/clang -O0 -o repro_O0 reproducer.c -lm && ./repro_O0
diff = 33

$ build/bin/clang -O2 -o repro_O2 reproducer.c -lm && ./repro_O2
diff = 0
```

At `-O0`: `diff = 33` (EDOM, correct). At `-O2`: `diff = 0` (wrong,
miscompiled).
