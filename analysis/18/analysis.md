# Alias Analysis Bug Investigation

Status: confirmed.

## Summary

`BasicAAResult::getModRefInfo(const CallBase *, const MemoryLocation &)` can
return `NoModRef` for `llvm.experimental.vector.histogram.*` calls even when the
histogram call updates the queried scalar pointer. This lets optimizers reuse a
stale load value across the intrinsic.

The root cause is that the histogram intrinsics are modeled as
`memory(argmem: readwrite)`, but their memory operand is a vector of pointers
(`<N x ptr>`). BasicAA refines argmem effects by iterating call data operands
and only considering operands whose type is a scalar pointer. For an argmem-only
call with only vector-of-pointer memory operands, the refinement starts from
`NoModRef`, skips the vector pointer, and replaces the whole argmem effect with
`NoModRef`.

This is not an integer-overflow issue, and it is distinct from the earlier
masked gather/scatter investigation: masked gather/scatter are not argmem-only,
so BasicAA's `Other` memory path remains conservative for them. The histogram
intrinsics are argmem-only, which exposes the scalar-pointer-only refinement.

## Prior Work Reviewed

The existing reports cover integer-offset overflow issues, atomic-ordering
ModRef holes, errno modeling, TBAA access-size/call-metadata issues,
GlobalsAA/operand-bundle issues, scoped-noalias barriers, `ptrmask` GEP
decomposition, nullable/extern-weak null object identity, matrix intrinsic size
overflow, and noalias call-return writability. I avoided those root causes.

I also checked two candidates that did not reproduce:

* Masked gather/scatter through `<N x ptr>` operands. Capture analysis and the
  `Other` memory effect keep BasicAA conservative; `aa-eval` reports `Mod` or
  `Ref`, not `NoModRef`.
* Generic `allocsize` calls as malloc-like side-effect suppression.
  `isMallocOrCallocLikeFn()` does not use the generic `allocsize` path, and
  `aa-eval` reports `ModRef` for a custom `noalias allocsize(0)` function
  against a global.

## Source Evidence

The histogram intrinsic definitions in `llvm/include/llvm/IR/Intrinsics.td`
use a vector operand for the updated pointers and only mark the intrinsic as
argument-memory-only:

```llvm
def int_experimental_vector_histogram_add : DefaultAttrsIntrinsic<[],
                             [ llvm_anyvector_ty, // Vector of pointers
                               llvm_anyint_ty,    // Increment
                               LLVMScalarOrSameVectorWidth<0, llvm_i1_ty>],
                             [ IntrArgMemOnly ]>;
```

The generated declaration for the reproducer confirms the resulting memory
attribute:

```llvm
declare void @llvm.experimental.vector.histogram.add.v2p0.i32(<2 x ptr>, i32, <2 x i1>)
    #0
attributes #0 = { nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
```

The LangRef says the first argument is "a vector of pointers to the memory
locations to be updated" and that the intrinsic performs a gather, update, and
scatter through that operand.

The unsound refinement is in `llvm/lib/Analysis/BasicAliasAnalysis.cpp`:

```cpp
if ((ArgMR | OtherMR) != OtherMR) {
  ModRefInfo NewArgMR = ModRefInfo::NoModRef;
  for (const Use &U : Call->data_ops()) {
    const Value *Arg = U;
    if (!Arg->getType()->isPointerTy())
      continue;
    ...
    if (ArgAlias != AliasResult::NoAlias)
      NewArgMR |= ArgMR & AAQI.AAR.getArgModRefInfo(Call, ArgIdx);
  }
  ArgMR = NewArgMR;
}
```

For the histogram call:

* `ArgMR` is `ModRef` because the call is `memory(argmem: readwrite)`.
* `OtherMR` is `NoModRef` because the call is argmem-only.
* The first data operand has type `<2 x ptr>`, so `isPointerTy()` is false.
* `NewArgMR` stays `NoModRef`, and `ArgMR` is replaced with `NoModRef`.

The same scalar-pointer assumption also appears in the generic call-vs-call
refinement in `llvm/lib/Analysis/AliasAnalysis.cpp`, so the fix should cover
both direct call-vs-location and call-vs-call queries.

## Reproducer

The reproducer is `analysis/18/histogram-vector-pointer.ll`.

```llvm
define i32 @histogram_add_clobbers_scalar(ptr %p) {
entry:
  store i32 10, ptr %p, align 4
  %ptrs.0 = insertelement <2 x ptr> poison, ptr %p, i32 0
  %ptrs.1 = insertelement <2 x ptr> %ptrs.0, ptr %p, i32 1
  call void @llvm.experimental.vector.histogram.add.v2p0.i32(
      <2 x ptr> %ptrs.1, i32 1, <2 x i1> <i1 true, i1 false>)
  %after = load i32, ptr %p, align 4
  ret i32 %after
}
```

Only lane 0 is active. The intrinsic increments the `i32` at `%p`, so the
function should return `11` or keep the final load. Scalarizing the intrinsic
and simplifying produces the semantic oracle:

```console
$ build/bin/opt -passes='scalarize-masked-mem-intrin,instcombine,simplifycfg' -S analysis/18/histogram-vector-pointer.ll
define i32 @histogram_add_clobbers_scalar(ptr %p) {
entry:
  store i32 11, ptr %p, align 4
  ret i32 11
}
```

BasicAA instead says the histogram call does not access `%p`:

```console
$ build/bin/opt -aa-pipeline=basic-aa -passes=aa-eval -print-all-alias-modref-info -disable-output analysis/18/histogram-vector-pointer.ll
Function: histogram_add_clobbers_scalar: 1 pointers, 1 call sites
  NoModRef:  Ptr: i32* %p <-> call void @llvm.experimental.vector.histogram.add.v2p0.i32(...)
```

GVN then folds the final load across the call and returns the stale store:

```console
$ build/bin/opt -passes=gvn -S analysis/18/histogram-vector-pointer.ll
define i32 @histogram_add_clobbers_scalar(ptr %p) {
entry:
  store i32 10, ptr %p, align 4
  %ptrs.0 = insertelement <2 x ptr> poison, ptr %p, i32 0
  %ptrs.1 = insertelement <2 x ptr> %ptrs.0, ptr %p, i32 1
  call void @llvm.experimental.vector.histogram.add.v2p0.i32(<2 x ptr> %ptrs.1, i32 1, <2 x i1> <i1 true, i1 false>)
  ret i32 10
}
```

This is a miscompile: the optimized function returns `10`, but the intrinsic
updates `%p` to `11`.

## Fix

Do not treat non-scalar pointer operands as proof that argmem is disjoint from
the queried location. If a call has argmem effects through a pointer vector and
AA cannot represent that vector-of-pointers operand as a `MemoryLocation`, the
refinement must preserve the original argmem effect or otherwise conservatively
mark it as potentially aliasing.

For `BasicAAResult::getModRefInfo(Call, Loc)`, the conservative shape is:

```cpp
if ((ArgMR | OtherMR) != OtherMR) {
  ModRefInfo NewArgMR = ModRefInfo::NoModRef;
  for (const Use &U : Call->data_ops()) {
    const Value *Arg = U;
    unsigned ArgIdx = Call->getDataOperandNo(&U);

    if (!Arg->getType()->isPointerTy()) {
      if (Arg->getType()->isPtrOrPtrVectorTy()) {
        // MemoryLocation cannot describe a vector of possible addresses.
        // Preserve this argument's argmem effect conservatively.
        NewArgMR |= ArgMR & AAQI.AAR.getArgModRefInfo(Call, ArgIdx);
      }
      continue;
    }

    ...
  }
  ArgMR = NewArgMR;
}
```

Equivalently, when a relevant pointer-vector argmem operand is seen, bail out of
the refinement and leave `ArgMR` unchanged. That is simpler and safely handles
future vector-of-pointer argmem intrinsics even if per-argument ModRef metadata
is incomplete.

The generic call-vs-call refinement in `AAResults::getModRefInfo(Call1, Call2)`
should receive the same treatment. When an argmem-only call has pointer-vector
arguments that cannot be converted to `MemoryLocation`, it should return the
current conservative `Result` rather than an empty accumulated `R`.

Useful regression tests:

* A BasicAA `aa-eval` test where the histogram call must not report
  `NoModRef` against a scalar pointer that appears in the vector operand.
* A GVN test where the final load is not folded to the pre-histogram store.
* A call-vs-call ModRef test for a histogram call and a scalar store/call
  touching the same pointer-vector element.
