# Alias Analysis Miscompile Investigation

## Status

Confirmed a distinct alias-analysis soundness bug in `ObjCARCAA`.

Artifacts:

- `analysis/21/analysis.md`
- `analysis/21/objc-arc-operand-bundle.ll`

## Prompt Requirements

- Research LLVM alias analysis code.
- Find and explain a practical alias-analysis miscompile bug.
- Provide proof that the bug exists.
- Provide LLVM IR that exposes the bug and produces a miscompile.
- Provide a source-level fix proposal without modifying LLVM source files.

## Prior Work Reviewed

The existing reports cover these root causes, so this investigation will avoid
re-reporting them:

- `AliasResult::swap()` leaves stale partial-alias offsets.
- `getModRefInfo(Instruction, CallBase)` loses atomic ordering for the first
  instruction.
- `getModRefInfo(Instruction, Instruction)` loses atomic ordering for the second
  instruction; this appears latent in current optimization consumers.
- BasicAA GEP arithmetic overflow cases, including `constantOffsetHeuristic()`,
  two-variable `MinAbsVarIndex`, and matrix/memset-pattern extent overflow.
- `BasicAAResult::aliasErrno()` treating `LocationSize::upperBound` as exact.
- New-format TBAA access-size metadata being ignored.
- TypeBasedAA call metadata dropping operand-bundle effects and explicit
  `errnomem` effects.
- ScopedNoAliasAA behavior on fences and errno calls.
- `llvm.ptrmask` being treated as address-offset-preserving in GEP
  decomposition.
- `isWritableObject()` treating arbitrary `noalias` returns as writable.
- `GlobalsAA` summaries ignoring operand-bundle effects.
- `extern_weak` and nullable `noalias` null-valid object identity issues.
- BasicAA argmem refinement skipping vector-of-pointer operands such as vector
  histogram intrinsics.

Current direction: confirmed a distinct operand-bundle bug in `ObjCARCAA`.

## Bug: `ObjCARCAA` Drops Operand-Bundle Effects

`ObjCARCAAResult::getModRefInfo(const CallBase *, const MemoryLocation &)`
hard-codes several ObjC ARC runtime calls as `NoModRef` for compiler-visible
memory. That answer is only valid for the intrinsic's normal ARC semantics. It
is not valid for a particular call site that carries operand bundles with
independent memory effects.

This is a different code path from the prior operand-bundle reports:

- `analysis/11` covers `GlobalsAA` function summaries.
- `analysis/15` covers `TypeBasedAA` call metadata.
- This report covers `ObjCARCAA` directly returning `NoModRef` for a bundled
  call.

## Source Evidence

`llvm/lib/Analysis/ObjCARCAliasAnalysis.cpp` returns `NoModRef` for several ARC
runtime calls without checking the call site's operand bundles:

```cpp
ModRefInfo ObjCARCAAResult::getModRefInfo(const CallBase *Call,
                                          const MemoryLocation &Loc,
                                          AAQueryInfo &AAQI) {
  if (!EnableARCOpts)
    return AAResultBase::getModRefInfo(Call, Loc, AAQI);

  switch (GetBasicARCInstKind(Call)) {
  case ARCInstKind::Retain:
  case ARCInstKind::RetainRV:
  case ARCInstKind::Autorelease:
  case ARCInstKind::AutoreleaseRV:
  case ARCInstKind::NoopCast:
  case ARCInstKind::AutoreleasepoolPush:
  case ARCInstKind::FusedRetainAutorelease:
  case ARCInstKind::FusedRetainAutoreleaseRV:
    // These functions don't access any memory visible to the compiler.
    return ModRefInfo::NoModRef;
  default:
    break;
  }

  return AAResultBase::getModRefInfo(Call, Loc, AAQI);
}
```

LangRef says operand bundles are call-site semantics, not callee signature
semantics. For unknown operand bundles:

```text
The bundle operands for an unknown operand bundle escape in unknown ways before
control is transferred to the callee or invokee.

Calls and invokes with operand bundles have unknown read / write effect on the
heap on entry and exit (even if the call target specifies a memory attribute),
unless they're overridden with callsite specific attributes.
```

The generic call memory-effect code accounts for this. `CallBase::
getMemoryEffects()` and `BasicAAResult::getMemoryEffects(Call)` OR in
`hasReadingOperandBundles()` and `hasClobberingOperandBundles()` effects before
answering call ModRef queries. `ObjCARCAA` does not, and because `AAResults`
intersects all AA results, the `ObjCARCAA` `NoModRef` result can erase the
conservative answer from `BasicAA`.

## Reproducer

The reproducer is `analysis/21/objc-arc-operand-bundle.ll`.

```llvm
target triple = "x86_64-apple-macosx14.0.0"

declare ptr @llvm.objc.retain(ptr)

define i32 @objc_arc_bundle_clobber(ptr %p, ptr %obj) {
entry:
  store i32 1, ptr %p, align 4
  %r = call ptr @llvm.objc.retain(ptr %obj) [ "unknown"(ptr %p) ]
  %after = load i32, ptr %p, align 4
  ret i32 %after
}
```

`@llvm.objc.retain` is one of the calls for which `ObjCARCAA` returns
`NoModRef`. The unknown operand bundle is allowed to read and write heap memory
on call entry or exit, and `%p` is a bundle operand that escapes in unknown
ways. There is no call-site memory attribute overriding those effects.

## Verified Behavior

The IR verifies:

```sh
build/bin/opt -passes=verify -disable-output \
  analysis/21/objc-arc-operand-bundle.ll
```

With `basic-aa` alone, MemorySSA correctly treats the bundled retain call as the
clobber for the later load, and EarlyCSE keeps the load:

```sh
build/bin/opt -S -aa-pipeline=basic-aa \
  -passes='early-cse<memssa>,instcombine,simplifycfg' \
  analysis/21/objc-arc-operand-bundle.ll
```

Relevant output:

```llvm
store i32 1, ptr %p, align 4
%r = call ptr @llvm.objc.retain(ptr %obj) [ "unknown"(ptr %p) ]
%after = load i32, ptr %p, align 4
ret i32 %after
```

With `objc-arc-aa` added, `aa-eval` reports the wrong answer:

```sh
build/bin/opt -aa-pipeline=basic-aa,objc-arc-aa -passes=aa-eval \
  -print-all-alias-modref-info -disable-output \
  analysis/21/objc-arc-operand-bundle.ll
```

Output:

```text
NoModRef:  Ptr: i32* %p <-> %r = call ptr @llvm.objc.retain(ptr %obj) [ "unknown"(ptr %p) ]
```

MemorySSA then skips the call as the load's clobber, and EarlyCSE folds the
load to the stale store:

```sh
build/bin/opt -S -aa-pipeline=basic-aa,objc-arc-aa \
  -passes='early-cse<memssa>,instcombine,simplifycfg' \
  analysis/21/objc-arc-operand-bundle.ll
```

Relevant output:

```llvm
store i32 1, ptr %p, align 4
%r = call ptr @llvm.objc.retain(ptr %obj) [ "unknown"(ptr %p) ]
ret i32 1
```

The `FileCheck` checks embedded in `objc-arc-operand-bundle.ll` validate the
same behavior locally.

## Proof Of Miscompilation

The source IR is defined for an operand-bundle implementation that writes a new
`i32` through `%p` on entry to, or exit from, the bundled call. This is within
the LangRef semantics of an unknown operand bundle: the bundle operand `%p`
escapes, and the call has unknown heap read/write effects.

For such an implementation:

1. The first store writes `1` to `%p`.
2. The operand-bundle effect during the retain call writes, for example, `2` to
   `%p`.
3. The source load reads `2`, so the function returns `2`.
4. The optimized function returns the stale constant `1`.

The optimization is therefore not semantics-preserving. The underlying wrong AA
answer is `ObjCARCAA` applying a callee-specific "ARC retain does not access
compiler-visible memory" fact to the whole call site, even though operand
bundles are independent call-site effects.

## Fix

`ObjCARCAAResult::getModRefInfo(Call, Loc)` should preserve operand-bundle
effects before returning `NoModRef` for recognized ARC calls.

A conservative fix is to make operand bundles neutralize the ARC-specific
`NoModRef` shortcut:

```cpp
ModRefInfo ObjCARCAAResult::getModRefInfo(const CallBase *Call,
                                          const MemoryLocation &Loc,
                                          AAQueryInfo &AAQI) {
  if (!EnableARCOpts)
    return AAResultBase::getModRefInfo(Call, Loc, AAQI);

  ModRefInfo BundleMR = ModRefInfo::NoModRef;
  if (Call->hasReadingOperandBundles())
    BundleMR |= ModRefInfo::Ref;
  if (Call->hasClobberingOperandBundles())
    BundleMR |= ModRefInfo::Mod;
  if (isModOrRefSet(BundleMR))
    return BundleMR;

  switch (GetBasicARCInstKind(Call)) {
  case ARCInstKind::Retain:
  case ARCInstKind::RetainRV:
  case ARCInstKind::Autorelease:
  case ARCInstKind::AutoreleaseRV:
  case ARCInstKind::NoopCast:
  case ARCInstKind::AutoreleasepoolPush:
  case ARCInstKind::FusedRetainAutorelease:
  case ARCInstKind::FusedRetainAutoreleaseRV:
    return ModRefInfo::NoModRef;
  default:
    break;
  }

  return AAResultBase::getModRefInfo(Call, Loc, AAQI);
}
```

Returning `ModRefInfo::ModRef` whenever relevant operand bundles are present
would also be correct and simpler. The essential requirement is that the
ARC-specific result may only describe the ARC runtime call itself; it must not
erase independent memory effects attached to the call site.

## Notes

The default new-pass-manager AA pipeline does not register `objc-arc-aa`; the
miscompile is exposed when that public AA component is used in the AA pipeline.
This is still a real AA soundness bug: `objc-arc-aa` is a registered alias
analysis pass, and its result is not a conservative refinement of the call
site's LangRef memory effects.

## Source-Level Reproducer Status

I did not find an honest C, Objective-C, or C++ source spelling that emits the
exact memory-clobbering bundled ARC runtime call used by the reproducer above.
Clang's source-level operand-bundle producers are narrower:

- Objective-C ARC return-value optimization emits `"clang.arc.attachedcall"` on
  ordinary calls such as message sends or helper calls, not on the ARC runtime
  intrinsic that `ObjCARCAA` recognizes.
- Inlining may insert a plain `llvm.objc.retain` for an attached call, but it
  does not attach the clobbering call-site bundle needed for this bug.
- Objective-C++ EH on Windows can emit a `llvm.objc.retain` with a `"funclet"`
  bundle. That shape is in `analysis/21/objc-funclet-retain.mm`, but `funclet`
  is not a heap-clobbering bundle carrying the queried pointer, so it is only a
  frontend reachability example for bundled ARC intrinsics, not a full
  source-level miscompile reproducer.

Generate that near-miss IR with:

```sh
build/bin/clang -cc1 -triple x86_64-windows-msvc \
  -x objective-c++ -fobjc-arc -fobjc-exceptions \
  -fexceptions -fcxx-exceptions -emit-llvm -o - \
  analysis/21/objc-funclet-retain.mm
```
