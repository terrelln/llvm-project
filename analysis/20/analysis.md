# Alias Analysis Miscompile Investigation

Status: confirmed. Reproducers and fix sketch are included below.

## Scope

I am looking for a practical LLVM alias-analysis soundness bug that can cause a mis-compilation. Per the prompt, I am excluding integer-overflow-only issues.

## Running Notes

- Reserved this directory as `analysis/20`.
- Read the existing reports under `analysis/`. I will not re-report the following
  root causes:
  - `AliasResult::swap()` stale partial-alias offset.
  - Missing atomic ordering in `getModRefInfo(Instruction, CallBase)`.
  - `constantOffsetHeuristic()` and two-variable GEP arithmetic overflows.
  - `aliasErrno()` treating upper-bound sizes as exact.
  - New-format TBAA access sizes being ignored.
  - Matrix intrinsic memory-location extent overflow.
  - `llvm.ptrmask` being treated as offset-preserving during GEP decomposition.
  - Scoped-noalias effects on fences, errno calls, and operand-bundle/TBAA calls.
  - `isWritableObject()` treating arbitrary `noalias` returns as writable.
  - `GlobalsAA` ignoring operand-bundle callsite effects.
  - `extern_weak` and nullable `noalias` null-valid object identity issues.
  - `getModRefInfo(Instruction, Instruction)` losing the second instruction's
    atomic ordering, which appears to be a latent API defect.
  - BasicAA argmem refinement dropping vector-of-pointer operands for histogram
    intrinsics.
- Found and validated a distinct non-overflow TypeBasedAA soundness issue:
  call-level TBAA can drop explicit `errnomem` effects.

## Bug: TypeBasedAA Call Metadata Drops `errnomem`

I found a candidate that is related to, but distinct from, the prior
operand-bundle TBAA report. `TypeBasedAAResult` treats a call's `!tbaa` metadata
as proving facts about the entire call. That can erase explicit `errnomem`
effects, even though `errnomem` is a separate implicit memory location and is
not the ordinary typed pointer access described by the call's TBAA tag.

Two local reproducers:

- `tbaa-errno.ll`: a call with `memory(argmem: read, errnomem: write)` has a
  `float` TBAA tag, while surrounding loads from an `errno` pointer have an
  `int` TBAA tag. With BasicAA alone, the loads remain. With
  `basic-aa,tbaa`, MemorySSA skips the call as a clobber and EarlyCSE folds the
  difference to zero.
- `tbaa-immutable-argmem-errno.ll`: the same shape, but the call's ordinary
  argument-memory read is tagged as immutable TBAA. `TypeBasedAAResult::
  getMemoryEffects(Call)` returns `MemoryEffects::none()` for the whole call,
  again dropping the `errnomem` write.

This is not the prior TBAA access-size issue and not the prior operand-bundle
issue: the missing effect here is the explicit `ErrnoMem` component of the
call's memory effects.

## Source Evidence

`llvm/lib/Analysis/TypeBasedAliasAnalysis.cpp` has two problematic call-level
answers:

```cpp
MemoryEffects TypeBasedAAResult::getMemoryEffects(const CallBase *Call,
                                                  AAQueryInfo &AAQI) {
  ...
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
  ...
  if (const MDNode *L = Loc.AATags.TBAA)
    if (const MDNode *M = Call->getMetadata(LLVMContext::MD_tbaa))
      if (!Aliases(L, M))
        return ModRefInfo::NoModRef;

  return ModRefInfo::ModRef;
}
```

Neither path checks whether the call has `ErrnoMem` effects. By contrast,
BasicAA explicitly separates `ArgMem`, `ErrnoMem`, and `Other` for calls in
`BasicAAResult::getModRefInfo(Call, Loc)` and only adds the errno component when
`aliasErrno(Loc)` cannot exclude it.

The TypeBasedAA answers are sound for the typed memory operation described by
the call's `!tbaa` tag. They are not sound for independent implicit effects like
`memory(errnomem: write)`.

## Proof

Use a call whose ordinary pointer access is a float read and whose independent
implicit effect is an errno write:

```llvm
declare void @touch_float(ptr) memory(argmem: read, errnomem: write)
```

Surround it with two loads from `%errno_ptr`, tagged as `int`, and tag the call
as a `float` access:

```llvm
%before = load i32, ptr %errno_ptr, !tbaa !int_tag
call void @touch_float(ptr %f), !tbaa !float_tag
%after = load i32, ptr %errno_ptr, !tbaa !int_tag
%diff = sub i32 %after, %before
ret i32 %diff
```

For the ordinary `argmem: read` through `%f`, the `float` TBAA tag can prove no
alias with the `int` loads. However, the call also has
`memory(errnomem: write)`. If `%errno_ptr` is the address of `errno`, the call
may modify the bytes read by the second load. There is no `llvm.errno.tbaa`
metadata in the module that proves `int` cannot alias errno, so the errno write
must be preserved.

Current TypeBasedAA instead lets MemorySSA skip the call as the clobber for the
second load. EarlyCSE then replaces `%after` with `%before` and folds the
function to `ret i32 0`.

This is a real semantic difference. A legal implementation of `@touch_float`
can read from `%f`, set errno from `0` to `33`, and return. The original
function then returns `33`; the optimized function always returns `0`.

## Reproducer

Main reproducer: `analysis/20/tbaa-errno.ll`

```llvm
target triple = "x86_64-unknown-linux-gnu"

declare void @touch_float(ptr) memory(argmem: read, errnomem: write)

define i32 @tbaa_call_metadata_hides_errno(ptr %errno_ptr, ptr %f) {
entry:
  %before = load i32, ptr %errno_ptr, align 4, !tbaa !3
  call void @touch_float(ptr %f), !tbaa !4
  %after = load i32, ptr %errno_ptr, align 4, !tbaa !3
  %diff = sub i32 %after, %before
  ret i32 %diff
}

!0 = !{!"Simple C/C++ TBAA"}
!1 = !{!"omnipotent char", !0}
!2 = !{!"int", !1}
!5 = !{!"float", !1}
!3 = !{!2, !2, i64 0}
!4 = !{!5, !5, i64 0}
```

Validation:

```sh
build/bin/opt -passes=verify -disable-output analysis/20/tbaa-errno.ll

build/bin/opt -S -aa-pipeline=basic-aa \
  -passes='early-cse<memssa>,instcombine,simplifycfg' \
  analysis/20/tbaa-errno.ll -o -

build/bin/opt -S -aa-pipeline=basic-aa,tbaa \
  -passes='early-cse<memssa>,instcombine,simplifycfg' \
  analysis/20/tbaa-errno.ll -o -
```

With BasicAA alone, the two loads remain. With `basic-aa,tbaa`, the output is:

```llvm
define i32 @tbaa_call_metadata_hides_errno(ptr %errno_ptr, ptr %f) {
entry:
  call void @touch_float(ptr %f), !tbaa !0
  ret i32 0
}
```

MemorySSA with `basic-aa,tbaa` shows the bad clobber relation directly: the
call is a `MemoryDef`, but the second load is still a `MemoryUse(liveOnEntry)`,
not a use of that call's def.

The second reproducer, `analysis/20/tbaa-immutable-argmem-errno.ll`, demonstrates
the same missing `ErrnoMem` preservation through the immutable-call
`getMemoryEffects(Call)` path. The call's ordinary argmem read is tagged as an
immutable float access, but the call still explicitly writes errno. With TBAA
enabled, MemorySSA does not even create a `MemoryDef` for the call.

## Fix

TypeBasedAA should split the typed call access from independent call effects.
It must not return `NoModRef` or `MemoryEffects::none()` for the whole call when
the call has `ErrnoMem` effects that may alias the queried location.

For `getModRefInfo(Call, Loc)`, preserve any known errno component before
applying the TBAA disjointness result. In sketch form:

```cpp
ModRefInfo TypeBasedAAResult::getModRefInfo(const CallBase *Call,
                                            const MemoryLocation &Loc,
                                            AAQueryInfo &AAQI) {
  if (!shouldUseTBAA())
    return ModRefInfo::ModRef;

  ModRefInfo IndependentMR = ModRefInfo::NoModRef;

  // This should be the call's known independent ErrnoMem effect, not the
  // ordinary typed pointer access described by the call's !tbaa tag. The
  // implementation should use the same memory-effect decomposition used by
  // the call ModRef path, and should avoid treating an entirely unknown call as
  // "explicit errno only".
  ModRefInfo ErrnoMR = getKnownErrnoEffect(Call);
  if (isModOrRefSet(ErrnoMR) &&
      aliasErrno(Loc, Call->getModule()) != AliasResult::NoAlias)
    IndependentMR |= ErrnoMR;

  if (const MDNode *L = Loc.AATags.TBAA)
    if (const MDNode *M = Call->getMetadata(LLVMContext::MD_tbaa))
      if (!Aliases(L, M))
        return IndependentMR;

  return ModRefInfo::ModRef;
}
```

The exact implementation should also include the same preservation in:

- `getMemoryEffects(Call)`, where immutable call TBAA currently returns
  `MemoryEffects::none()` for the whole call.
- `getModRefInfo(Call1, Call2)`, for call-vs-call queries where either side has
  independent errno effects.

The prior operand-bundle TBAA issue needs the same structural treatment for
operand-bundle heap effects; this report adds `ErrnoMem` to the list of
independent effects TypeBasedAA must preserve.
