# Alias Analysis Miscompile Investigation

Status: slot reserved, investigation starting.

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
- Next step: inspect the AA implementations for a distinct, practical
  non-overflow soundness bug with a concrete optimizer consumer.
