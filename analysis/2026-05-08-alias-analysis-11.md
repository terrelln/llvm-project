# Alias Analysis Investigation

## Status

In progress. This report is intentionally avoiding the issues already covered
by the supplied prior analyses:

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

I am currently checking remaining non-overflow alias-analysis paths that can
produce a wrong `NoAlias` or `NoModRef` result and feed an optimizer.
