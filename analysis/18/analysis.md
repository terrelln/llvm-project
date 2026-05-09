# Alias Analysis Bug Investigation

Status: in progress.

This directory is reserved for a fresh investigation into an LLVM alias analysis
miscompile. Existing reports under `analysis/` will be reviewed first to avoid
duplicating prior work.

## Prior Work Reviewed

The existing reports cover integer-offset overflow issues, atomic-ordering
ModRef holes, errno modeling, TBAA access-size/call-metadata issues,
GlobalsAA/operand-bundle issues, scoped-noalias barriers, `ptrmask` GEP
decomposition, nullable/extern-weak null object identity, matrix intrinsic size
overflow, and noalias call-return writability. I am avoiding those root causes.

## Candidate

Current candidate: `BasicAAResult::getModRefInfo(const CallBase *,
MemoryLocation)` appears to miss accesses performed by masked gather/scatter
intrinsics through vector-of-pointer operands.

The relevant shape is:

* `llvm.masked.gather` and `llvm.masked.scatter` access memory through an
  operand of type `<N x ptr>`.
* The intrinsic definitions are `IntrReadMem` / `IntrWriteMem`, not
  `IntrArgMemOnly`.
* In `BasicAAResult::getModRefInfo(Call, Loc)`, accesses classified as `Other`
  are dropped for identified function-local objects that have not escaped
  before the call.
* The later argument-memory refinement only iterates scalar pointer data
  operands (`Arg->getType()->isPointerTy()`), so a `<N x ptr>` gather/scatter
  operand cannot reintroduce the real access to the local object.

If this reasoning is correct, AA can answer `NoModRef` for a masked scatter to
an alloca and a subsequent scalar load from that same alloca.

### Result: rejected

The hypothesis does not reproduce. Inserting an alloca pointer into a vector
before a masked gather/scatter is treated conservatively enough by capture
analysis: `aa-eval` reports `Mod` for masked scatter and `Ref` for masked gather
against the alloca, and EarlyCSE does not forward across the intrinsic. The
candidate file is kept as `reproducer.ll` for reference, but this is not the
bug.
