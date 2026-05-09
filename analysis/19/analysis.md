# Analysis 19: Alias Analysis Bug Investigation

## Status: In Progress

## Prior Work Summary

Already-found bugs (to avoid duplicating):
- **01**: AliasResult::swap() offset overflow (missed opt, not miscompile)
- **02**: getModRefInfo(Inst, CallBase) bypasses atomic ordering checks
- **03**: constantOffsetHeuristic multiplication overflow
- **04**: aliasErrno() treats upper-bound sizes as definite
- **05**: TypeBasedAA ignores access size in new-format TBAA
- **06**: MinAbsVarIndex overflow in two-variable GEP path
- **07**: Matrix intrinsic MemoryLocation size overflow
- **08**: BasicAA looks through llvm.ptrmask during GEP decomposition
- **09**: ScopedNoAliasAA breaks fence barriers via !noalias metadata
- **10**: isWritableObject() treats noalias returns as writable
- **11**: GlobalsAA ignores operand-bundle memory effects
- **12**: extern_weak globals treated as disjoint identified objects
- **13**: Nullable noalias returns in null_pointer_is_valid functions
- **14**: getModRefInfo(I1, I2) misses I2's atomic ordering
- **15**: TBAA call metadata masks operand-bundle effects
- **16**: ScopedNoAliasAA masks errno effects
- **17**: Same as 14 (re-analysis)
- **18**: Placeholder/in-progress

## Investigation

Currently investigating...
