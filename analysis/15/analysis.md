# Alias Analysis Bug: TBAA call metadata hides unknown operand-bundle effects

## Summary

`TypeBasedAAResult` applies a call's `!tbaa` metadata to the whole `CallBase`
without preserving the independent memory effects introduced by operand
bundles.  Unknown operand bundles are specified to have unknown heap read/write
effects unless a call-site memory attribute overrides them.  A call can
therefore have a `memory(none)` callee and still clobber heap memory through an
unknown operand bundle.

When the call has `!tbaa` metadata that does not alias a nearby load/store tag,
TBAA answers `NoModRef` for the entire call.  MemorySSA then treats the call as
not clobbering that location, and EarlyCSE can forward a value across a call
whose operand bundle is allowed to write the same memory.

This is a distinct underlying issue from the prior GlobalsAA operand-bundle
report: the bad result here comes from TypeBasedAA's call metadata handling and
is reproduced with `-aa-pipeline=basic-aa,tbaa` even though BasicAA itself models
the operand bundle effects correctly.

## Relevant code

`llvm/lib/Analysis/TypeBasedAliasAnalysis.cpp`:

```cpp
MemoryEffects TypeBasedAAResult::getMemoryEffects(const CallBase *Call,
                                                  AAQueryInfo &AAQI) {
  if (!shouldUseTBAA())
    return MemoryEffects::unknown();

  // If this is an "immutable" type, the access is not observable.
  if (const MDNode *M = Call->getMetadata(LLVMContext::MD_tbaa))
    if ((!isStructPathTBAA(M) && TBAANode(M).isTypeImmutable()) ||
        (isStructPathTBAA(M) && TBAAStructTagNode(M).isTypeImmutable()))
      return MemoryEffects::none();

  return MemoryEffects::unknown();
}

ModRefInfo TypeBasedAAResult::getModRefInfo(const CallBase *Call,
                                            const MemoryLocation &Loc,
                                            AAQueryInfo &AAQI) {
  if (!shouldUseTBAA())
    return ModRefInfo::ModRef;

  if (const MDNode *L = Loc.AATags.TBAA)
    if (const MDNode *M = Call->getMetadata(LLVMContext::MD_tbaa))
      if (!Aliases(L, M))
        return ModRefInfo::NoModRef;

  return ModRefInfo::ModRef;
}
```

The `getModRefInfo()` method has no operand-bundle check before returning
`NoModRef`, and `getMemoryEffects()` can also return `MemoryEffects::none()` for
immutable call TBAA without preserving operand-bundle reads/writes.

By contrast, BasicAA explicitly unions operand-bundle effects into the called
function's memory effects:

```cpp
if (Call->hasReadingOperandBundles())
  FuncME |= MemoryEffects::readOnly();
if (Call->hasClobberingOperandBundles())
  FuncME |= MemoryEffects::writeOnly();
```

## Why this is wrong

The LangRef specifies unknown operand bundle semantics:

> Calls and invokes with operand bundles have unknown read / write effect on the
> heap on entry and exit (even if the call target specifies a `memory`
> attribute), unless they're overridden with callsite specific attributes.

It also describes call memory effects as:

```text
CallSiteEffects & (FunctionEffects | OperandBundleEffects)
```

The reproducer uses a `memory(none)` callee, so the call's ordinary callee memory
effects are empty.  The unknown operand bundle still contributes heap ModRef
effects because the call site has no restrictive memory attribute.  The call's
`!tbaa` metadata can be treated as describing the callee-side access, which is
vacuously harmless for a `memory(none)` callee, but it must not erase the
separate operand-bundle heap effects.

## Reproducer

`analysis/15/reproducer.ll`:

```llvm
declare void @leaf() memory(none)

define i32 @tbaa_operand_bundle_clobber(ptr %p) {
entry:
  store i32 1, ptr %p, align 4, !tbaa !1
  call void @leaf() [ "unknown"(ptr %p) ], !tbaa !2
  %after = load i32, ptr %p, align 4, !tbaa !1
  ret i32 %after
}

!0 = !{!"root"}
!1 = !{!"int", !0}
!2 = !{!"float", !0}
```

The store/load use an `int` TBAA tag, while the call has a disjoint `float` TBAA
tag.  The unknown bundle operand is `%p`, and the bundle semantics allow a heap
write through that escaped pointer between the store and the load.  The load
therefore cannot be replaced with the earlier stored value `1`.

## Proof

With BasicAA only, MemorySSA correctly treats the unknown operand-bundle call as
the clobber for the later load:

```text
; 1 = MemoryDef(liveOnEntry)
  store i32 1, ptr %p, align 4, !tbaa !0
; 2 = MemoryDef(1)
  call void @leaf() [ "unknown"(ptr %p) ], !tbaa !3
; MemoryUse(2)
  %after = load i32, ptr %p, align 4, !tbaa !0
```

With TBAA enabled, the call's disjoint `!tbaa` metadata makes MemorySSA skip the
call as a clobber:

```text
; 1 = MemoryDef(liveOnEntry)
  store i32 1, ptr %p, align 4, !tbaa !0
; 2 = MemoryDef(1)
  call void @leaf() [ "unknown"(ptr %p) ], !tbaa !3
; MemoryUse(1)
  %after = load i32, ptr %p, align 4, !tbaa !0
```

Then EarlyCSE forwards the stale store value across the call:

```llvm
define i32 @tbaa_operand_bundle_clobber(ptr %p) {
entry:
  store i32 1, ptr %p, align 4, !tbaa !0
  call void @leaf() [ "unknown"(ptr %p) ], !tbaa !3
  ret i32 1
}
```

That transform is invalid because a legal unknown-bundle implementation may
write a different `i32` to `%p` before the load.

Commands used:

```sh
build/bin/opt -aa-pipeline=basic-aa -passes='print<memoryssa>' -disable-output analysis/15/reproducer.ll
build/bin/opt -aa-pipeline=basic-aa,tbaa -passes='print<memoryssa>' -disable-output analysis/15/reproducer.ll
build/bin/opt -aa-pipeline=basic-aa,tbaa -passes='early-cse<memssa>,instcombine,simplifycfg' -S analysis/15/reproducer.ll
```

The default optimization pipeline also miscompiles the function:

```sh
build/bin/opt -passes='default<O2>' -S analysis/15/reproducer.ll
```

It returns `1` directly after the call.

## Suggested fix

TBAA should not let call metadata suppress operand-bundle memory effects.  At a
minimum:

1. `TypeBasedAAResult::getModRefInfo(const CallBase *, const MemoryLocation &)`
   should return the operand-bundle ModRef component when the call has reading
   or clobbering operand bundles, even if the call's `!tbaa` metadata is
   disjoint from the queried location.
2. `TypeBasedAAResult::getMemoryEffects(const CallBase *)` should preserve
   operand-bundle effects before returning `MemoryEffects::none()` for immutable
   call TBAA.  Conservatively returning `MemoryEffects::unknown()` for calls with
   non-ignorable operand bundles would be correct.
3. The call-vs-call TBAA query should receive the same treatment, because either
   call may carry operand-bundle effects that are independent of the callee
   access described by call metadata.

A conservative shape for the first case is:

```cpp
ModRefInfo TypeBasedAAResult::getModRefInfo(const CallBase *Call,
                                            const MemoryLocation &Loc,
                                            AAQueryInfo &AAQI) {
  if (!shouldUseTBAA())
    return ModRefInfo::ModRef;

  ModRefInfo BundleMR = ModRefInfo::NoModRef;
  if (Call->hasReadingOperandBundles())
    BundleMR |= ModRefInfo::Ref;
  if (Call->hasClobberingOperandBundles())
    BundleMR |= ModRefInfo::Mod;
  if (isModOrRefSet(BundleMR))
    return BundleMR;

  if (const MDNode *L = Loc.AATags.TBAA)
    if (const MDNode *M = Call->getMetadata(LLVMContext::MD_tbaa))
      if (!Aliases(L, M))
        return ModRefInfo::NoModRef;

  return ModRefInfo::ModRef;
}
```

This gives up some TBAA precision for calls with meaningful operand bundles, but
it preserves the LangRef-required heap effects.  A more precise version could
split callee memory effects from operand-bundle effects and apply TBAA only to
the former.
