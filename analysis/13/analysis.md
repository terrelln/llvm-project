# Alias Analysis Investigation

## Status

Investigation in progress. I have read the existing analyses and am looking for
a distinct alias-analysis miscompile, avoiding integer-overflow-only issues and
avoiding the root causes already reported.

## Prior Work Reviewed

The existing local reports already cover these issues, so this analysis will not
re-report them:

1. `AliasResult::swap()` stale partial-alias offsets when negating `-2^22`.
2. Missing atomic-ordering checks in `getModRefInfo(Instruction, CallBase)`.
3. `constantOffsetHeuristic()` distance multiplication overflow.
4. `aliasErrno()` treating imprecise upper-bound sizes as exact.
5. New-format TBAA tags ignoring access size.
6. Two-variable `MinAbsVarIndex` overflow in BasicAA.
7. Matrix intrinsic memory-location size overflow.
8. `llvm.ptrmask` being treated as offset-preserving during GEP decomposition.
9. Scoped-noalias metadata breaking fence barriers.
10. `isWritableObject()` treating `noalias` call returns as writable.
11. `GlobalsAA` ignoring operand-bundle memory effects in function summaries.
12. `extern_weak` globals treated as distinct identified objects when they can
    both resolve to valid null pointers.

## Candidate: Nullable `noalias` Call Returns in `null_pointer_is_valid`

I have a locally verified candidate. It is related to, but not the same as, the
`extern_weak` report above: the same "different identified objects are
disjoint" shortcut is also used for `noalias` call returns. `noalias` returns
model allocation-like functions, and allocation-like functions such as `malloc`
may return null. In a `null_pointer_is_valid` function, two failed allocations
can both produce the same valid null address.

Current BasicAA nevertheless answers `NoAlias` for two distinct `noalias` call
results:

```llvm
declare noalias ptr @alloc_or_null() memory(inaccessiblemem: readwrite)

define i8 @noalias_null_alias() null_pointer_is_valid {
entry:
  %p = call noalias ptr @alloc_or_null()
  %q = call noalias ptr @alloc_or_null()
  store i8 7, ptr %p, align 1
  store i8 42, ptr %q, align 1
  %v = load i8, ptr %p, align 1
  ret i8 %v
}
```

Observed locally:

```text
build/bin/opt -aa-pipeline=basic-aa -passes=aa-eval \
  -print-all-alias-modref-info -disable-output

  NoAlias: i8* %p, i8* %q
```

And:

```text
build/bin/opt -aa-pipeline=basic-aa \
  -passes='gvn,instcombine,simplifycfg' -S

  store i8 7, ptr %p
  store i8 42, ptr %q
  ret i8 7
```

If both calls return null, and null is a valid byte address for this function,
the second store overwrites the first and the correct return value is `42`.

I am doing one more search pass before finalizing this report, because the
underlying shortcut overlaps with the existing `extern_weak` null-valid report.
