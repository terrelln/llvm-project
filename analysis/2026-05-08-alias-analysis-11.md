# Alias Analysis Investigation

## Status

Found a distinct non-overflow miscompilation candidate in `GlobalsAA` /
`GlobalsModRef`. I validated the standalone LLVM IR reproducer with the local
`build/bin/opt` and `build/bin/FileCheck`; the current optimizer folds the test
function to `ret i32 0`.

There is not a plain C source reproducer for this exact bug. The bug depends on
a non-assume operand bundle with unoverridden heap effects, such as
`[ "unknown"(ptr %p) ]`, and Clang's C frontend has no source spelling or
builtin that emits that construct. C-generated bundles I found either attach to
`llvm.assume` (`separate_storage`) or are explicitly excluded from heap
read/write bundle effects (`kcfi`, `ptrauth`, `convergencectrl`,
`deactivation-symbol`), with `funclet` only arising from EH lowering and not
providing a C-level heap clobber through the bundled pointer.

This report intentionally avoids the issues covered by the supplied prior
analyses:

1. `AliasResult::swap()` stale partial-alias offsets.
2. Missing atomic-ordering checks in `getModRefInfo(Instruction, CallBase)`.
3. `constantOffsetHeuristic()` distance multiplication overflow.
4. `aliasErrno()` treating imprecise upper-bound sizes as exact.
5. New-format TBAA tags ignoring access size.
6. Two-variable `MinAbsVarIndex` overflow in BasicAA.
7. Matrix intrinsic memory-location size overflow.
8. `llvm.ptrmask` being treated as offset-preserving during GEP decomposition.
9. Scoped-noalias metadata breaking fence barriers.
10. `isWritableObject()` treating `noalias` call returns as writable.

I also checked and rejected two tempting directions:

* A select/phi merge of different `PartialAlias` offsets: this checkout's
  `AliasResult::operator==` compares offset state, so the merge does not lose
  offset information.
* Scoped-noalias metadata on calls accessing `errnomem`: LangRef explicitly
  defines `!alias.scope` / `!noalias` for memory-accessing calls, so that is not
  a valid standalone bug.

## Summary

`GlobalsAAResult::AnalyzeCallGraph()` summarizes a function's memory effects
from the callee function in the call graph, but it does not account for
callsite operand bundles. That is unsound: LangRef says an unknown operand
bundle makes the call's bundle operands escape and gives the call unknown heap
read/write effects unless those effects are overridden by callsite-specific
attributes.

The rest of LLVM's memory-effect code knows this. `CallBase::getMemoryEffects()`
and `BasicAAResult::getMemoryEffects(CallBase *)` both OR in operand-bundle
effects before intersecting with callsite attributes. `GlobalsAA` does not. As a
result, an internal function containing only

```llvm
call void @leaf() [ "unknown"(ptr %p) ]
```

where `@leaf` has no memory effects, can be summarized by `GlobalsAA` as
`memory(none)`. BasicAA then consumes that bad function summary for direct
calls to the internal wrapper and can answer `NoModRef` for a location that the
operand bundle is allowed to read or write.

That lets MemorySSA-backed optimizations CSE or forward loads across a call that
may clobber the loaded memory.

## Semantics Being Violated

LangRef's generic operand bundle semantics say:

```text
The bundle operands for an unknown operand bundle escape in unknown ways before
control is transferred to the callee or invokee.

Calls and invokes with operand bundles have unknown read / write effect on the
heap on entry and exit (even if the call target specifies a memory attribute),
unless they're overridden with callsite specific attributes.
```

Therefore this call has heap memory effects even though the callee `@leaf`
itself is `memory(none)`:

```llvm
call void @leaf() [ "unknown"(ptr %p) ]
```

There is no callsite-specific `memory(...)` attribute on the call, so the
callee's `memory(none)` behavior does not suppress the unknown bundle's heap
read/write effect.

## Bug Location

`llvm/lib/Analysis/GlobalsModRef.cpp` computes function summaries in
`GlobalsAAResult::AnalyzeCallGraph()`. While walking the call graph it
propagates only the callee function summary:

```cpp
if (Function *Callee = CI->second->getFunction()) {
  if (FunctionInfo *CalleeFI = getFunctionInfo(Callee)) {
    // Propagate function effect up.
    FI.addFunctionInfo(*CalleeFI);
  } else {
    ...
  }
}
```

For declaration or `optnone` SCCs, it similarly consults the callee `Function`
attributes rather than a particular `CallBase`. Later, while scanning the
function body, it skips all call instructions:

```cpp
// We handle calls specially because the graph-relevant aspects are
// handled above.
if (isa<CallBase>(&I))
  continue;
```

The call graph record does carry the callsite for normal call edges, but this
code only uses `CI->second` (the callee node). The memory effects here are a
property of the particular callsite, and `FI.addFunctionInfo(*CalleeFI)` cannot
see `Call->hasReadingOperandBundles()` or
`Call->hasClobberingOperandBundles()`. The later body scan also cannot
compensate because it unconditionally skips calls.

This is inconsistent with `llvm/lib/IR/Instructions.cpp`:

```cpp
MemoryEffects CallBase::getMemoryEffects() const {
  MemoryEffects ME = getAttributes().getMemoryEffects();
  if (auto *Fn = dyn_cast<Function>(getCalledOperand())) {
    MemoryEffects FnME = Fn->getMemoryEffects();
    if (hasOperandBundles()) {
      if (hasReadingOperandBundles())
        FnME |= MemoryEffects::readOnly();
      if (hasClobberingOperandBundles())
        FnME |= MemoryEffects::writeOnly();
    }
    ...
    ME &= FnME;
  }
  return ME;
}
```

and with `llvm/lib/Analysis/BasicAliasAnalysis.cpp`:

```cpp
MemoryEffects BasicAAResult::getMemoryEffects(const CallBase *Call,
                                              AAQueryInfo &AAQI) {
  MemoryEffects Min = Call->getAttributes().getMemoryEffects();

  if (const Function *F = dyn_cast<Function>(Call->getCalledOperand())) {
    MemoryEffects FuncME = AAQI.AAR.getMemoryEffects(F);
    // Operand bundles on the call may also read or write memory, in addition
    // to the behavior of the called function.
    if (Call->hasReadingOperandBundles())
      FuncME |= MemoryEffects::readOnly();
    if (Call->hasClobberingOperandBundles())
      FuncME |= MemoryEffects::writeOnly();
    ...
    Min &= FuncME;
  }

  return Min;
}
```

`GlobalsAAResult::getMemoryEffects(const Function *F)` then publishes the bad
summary:

```cpp
MemoryEffects GlobalsAAResult::getMemoryEffects(const Function *F) {
  if (FunctionInfo *FI = getFunctionInfo(F))
    return MemoryEffects(FI->getModRefInfo());

  return MemoryEffects::unknown();
}
```

## LLVM IR Reproducer

```llvm
; RUN: opt -S -aa-pipeline=basic-aa,globals-aa \
; RUN:   -passes='require<globals-aa>,early-cse<memssa>' < %s | FileCheck %s

define internal void @leaf() memory(none) nounwind willreturn {
entry:
  ret void
}

define internal void @wrapper_with_unknown_bundle(ptr %p) nounwind willreturn {
entry:
  ; The unknown operand bundle makes %p escape and gives this call unknown heap
  ; read/write effects, despite the callee's memory(none) behavior.
  call void @leaf() [ "unknown"(ptr %p) ]
  ret void
}

define i32 @globalsaa_operand_bundle_bug(ptr %p) {
; Correct: the second load must remain after the wrapper call.
; Buggy: GlobalsAA summarizes @wrapper_with_unknown_bundle as memory(none),
;        so MemorySSA-backed EarlyCSE can replace %after with %before and
;        fold this function to ret i32 0.
;
; CHECK-LABEL: define i32 @globalsaa_operand_bundle_bug(
; CHECK:         %before = load i32, ptr %p
; CHECK-NEXT:    call void @wrapper_with_unknown_bundle(ptr %p)
; CHECK-NEXT:    %after = load i32, ptr %p
; CHECK-NEXT:    %diff = sub i32 %after, %before
; CHECK-NEXT:    ret i32 %diff
entry:
  %before = load i32, ptr %p
  call void @wrapper_with_unknown_bundle(ptr %p)
  %after = load i32, ptr %p
  %diff = sub i32 %after, %before
  ret i32 %diff
}
```

The standalone reproducer is `analysis/2026-05-08-alias-analysis-11-reproducer.ll`.
It documents the current buggy behavior:

```text
build/bin/opt -S -aa-pipeline=basic-aa,globals-aa \
  -passes='require<globals-aa>,early-cse<memssa>' \
  < analysis/2026-05-08-alias-analysis-11-reproducer.ll \
| build/bin/FileCheck analysis/2026-05-08-alias-analysis-11-reproducer.ll
```

The optimized IR contains:

```llvm
define i32 @globalsaa_operand_bundle_bug(ptr %p) {
entry:
  %before = load i32, ptr %p, align 4
  call void @wrapper_with_unknown_bundle(ptr %p)
  ret i32 0
}
```

The IR is valid. The unknown bundle is not a decorative marker: LangRef gives
it memory semantics. A legal implementation of that bundle can read and write
the heap location reachable through `%p` on call entry or exit, so `%after` is
not necessarily equal to `%before`.

## C Source Reachability

I could not write an honest C program that is miscompiled because of this exact
issue. The required input is an LLVM IR callsite feature, not a C semantic
feature: Clang does not lower plain C to an arbitrary unknown operand bundle,
and the C-reachable bundles do not create the heap-clobbering callsite effect
used by the reproducer.

The earlier C file that printed this LLVM IR was intentionally removed; that was
only an IR emitter, not a C source reproducer.

## Proof of the Bad Query

For `@wrapper_with_unknown_bundle`, `GlobalsAAResult::AnalyzeCallGraph()` sees a
call-graph edge to `@leaf`. `@leaf` has no memory effects, so its
`FunctionInfo` has `NoModRef`. The wrapper's call-graph walk propagates that
callee summary with `FI.addFunctionInfo(*CalleeFI)`, adding no `ModRefInfo` to
the wrapper's `FunctionInfo`.

The wrapper body contains no non-call memory instructions. The body scan skips
the `call void @leaf() [ "unknown"(ptr %p) ]` instruction because calls are
assumed to have been handled by the call graph. At this point the wrapper's
`FunctionInfo` still has `NoModRef`, and `GlobalsAAResult::getMemoryEffects`
reports `MemoryEffects::none()` for the wrapper function.

Now consider the later AA query in the caller:

```text
Call = call void @wrapper_with_unknown_bundle(ptr %p)
Loc  = MemoryLocation for load i32, ptr %p
```

`BasicAAResult::getModRefInfo(Call, Loc)` asks the aggregate AA for
`getMemoryEffects(Call)`. For a direct call, BasicAA computes call effects from
`AAQI.AAR.getMemoryEffects(F)` for the callee function. The aggregate function
effect includes the `GlobalsAA` result above, so BasicAA sees the wrapper as
not accessing memory and returns `NoModRef`.

That `NoModRef` is wrong. The wrapper contains a callsite whose unknown operand
bundle can read and write the heap through `%p`.

## Miscompilation Path

MemorySSA and MemorySSA-backed EarlyCSE rely on AA to decide whether an
intervening call clobbers a later load. With the bad `NoModRef`, the wrapper
call is not a clobber for `load i32, ptr %p`. The two loads in the reproducer
therefore appear to be in the same memory generation, and EarlyCSE can replace
`%after` with `%before`.

The optimized function becomes equivalent to:

```llvm
define i32 @globalsaa_operand_bundle_bug(ptr %p) {
entry:
  %before = load i32, ptr %p
  call void @wrapper_with_unknown_bundle(ptr %p)
  ret i32 0
}
```

That is not semantics-preserving for an unknown operand bundle implementation
that writes a new `i32` value through `%p` during the bundled call.

## Fix

`GlobalsAAResult::AnalyzeCallGraph()` must account for callsite-specific
effects before publishing a function summary.

The conservative fix is:

1. When visiting call graph edges, inspect the corresponding `CallBase`
   instances, not only the callee `Function`.
2. If a call has `hasReadingOperandBundles()`, add at least `Ref` to the
   caller function's `FunctionInfo`.
3. If a call has `hasClobberingOperandBundles()`, add `ModRef` or at least
   `Mod` as appropriate.
4. Treat pointer operands in unknown clobbering bundles as escaping for the
   purposes of any global-specific information, or conservatively drop the
   function/global summary when the escape cannot be represented.

An implementation can mirror `CallBase::getMemoryEffects()` / BasicAA's
callsite logic: start from the callee's function effect, OR in operand-bundle
read/write effects for the specific callsite, then apply callsite-specific
`memory(...)` attributes. The key requirement is that the module summary must
not report `memory(none)` for a function whose callsite operand bundles have
unoverridden heap effects.

A regression test should use an internal wrapper around a `memory(none)` callee
with an unknown operand bundle, then verify that
`require<globals-aa>,early-cse<memssa>` does not CSE a load across a call to
that wrapper.
