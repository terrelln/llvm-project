# Alias Analysis Submission Summary

This reviews `prompt.md` and the submissions in `analysis/01` through
`analysis/17`. I ignored `analysis/18` and `analysis/19` as submissions, but I
did audit nearby code paths for logical extensions of the reported issues.

Validation was based on source inspection and local `build/bin/opt` runs. Where
the optimizer behavior reproduces but the IR/source proof depends on invalid or
ambiguous metadata semantics, I mark the report as not validated instead of
counting it as a confirmed miscompile.

## Priority Summary

| Priority | Submission(s) | Verdict | Rationale |
| --- | --- | --- | --- |
| High | 08 | Confirmed real miscompile | BasicAA treats `llvm.ptrmask` as offset-preserving during GEP decomposition; small C-reachable pattern. |
| High | 10 | Confirmed real miscompile | `isWritableObject()` treats arbitrary `noalias` call returns as writable; SimplifyCFG can introduce trapping stores. |
| High | 02 | Confirmed real miscompile | `getModRefInfo(Instruction, CallBase)` loses atomic ordering; Sink moves a call across a release store. |
| High | 05 | Confirmed real miscompile | New-format TBAA access sizes are ignored; GVN forwards across an overlapping wide access. |
| Medium-high | 04 | Confirmed real bug | `aliasErrno()` treats upper-bound access sizes as exact and drops `errnomem` effects. |
| Medium | 11 | Confirmed real bug | `GlobalsAA` function summaries ignore operand-bundle heap effects. IR-only trigger. |
| Medium | 15 | Confirmed real bug | TBAA call metadata suppresses unknown operand-bundle effects. IR-only trigger. |
| Medium-low | 12 | Confirmed real but niche | Distinct `extern_weak` globals can both resolve to valid null in `null_pointer_is_valid` functions. |
| Low | 07 | Confirmed real but impractical | Matrix intrinsic memory extent can wrap to zero for huge stride. |
| Low | 06 | Confirmed real but impractical | Two-variable `MinAbsVarIndex` reasoning can wrap for huge GEP indices. |
| Low | 14, 17 | Real latent API defect | `getModRefInfo(Instruction, Instruction)` loses I2 ordering, but no current optimizer path was shown. |
| Low | 01 | Real API invariant bug | `AliasResult::swap()` can leave a stale partial-alias offset; current consumers guard the dangerous sign. |
| Not validated | 03 | Submitted proof fails | Local BasicAA reports `PartialAlias`, not the claimed `NoAlias`. |
| Not validated | 09 | Semantics problem | Optimizer behavior reproduces, but current LangRef explicitly permits scoped-noalias fences. |
| Not validated | 13 | Semantics ambiguous | Nullable `noalias` return behavior reproduces, but same-address stores may violate `noalias`. |
| Not validated | 16 | Semantics problem | Scoped noalias masks errno in the test, but metadata/restrict semantics do not prove a defined aliasing case. |

## Groups Of Similar Bugs

### 1. Ordering And Barrier Semantics

**Analysis 02: ordered atomic instruction vs call**

This is confirmed. `AAResults::getModRefInfo(const Instruction *, const
CallBase *)` converts non-call, non-fence instructions to a `MemoryLocation`
and asks whether the call touches that address. That bypasses the
instruction-specific atomic ordering checks used for loads, stores, cmpxchg,
and atomicrmw.

I reproduced the Sink transform: a read-only call before a release store is
sunk into the successor block after the release store. That changes the ordering
guarantees of the release operation. Severity is high because this is an
ordinary optimization pass using a public AA API.

**Analysis 14 and analysis/17: ordered second instruction**

The corrected version in `analysis/17` is accurate. The two-instruction overload
`getModRefInfo(I1, I2)` converts `I2` to a `MemoryLocation`, so I2's ordering is
lost. `aa-eval` reports `NoModRef` for a call against a release store where the
call does not access the store's address.

The impact in `analysis/14` was overstated. I1's ordering is still checked by
the instruction-specific handler, and MemorySSA/EarlyCSE/GVN/DSE do not use this
two-instruction overload in the dangerous shape. This is a real API defect, but
currently latent.

**Analysis 09: scoped-noalias fences**

The optimizer behavior reproduces: a `fence seq_cst, !noalias !scope` can be
skipped as a clobber for a load tagged with matching `!alias.scope`, and
EarlyCSE folds the load difference to zero.

I do not validate this as a real bug as submitted. Current LangRef explicitly
says `noalias` and `alias.scope` metadata may be attached to fences to indicate
which scoped memory regions the fence does or does not concern. The C proof also
relies on ordinary non-atomic loads observing concurrent modification, which is
not a defined C execution. A real bug here would need to show that LLVM
generates invalid fence scope metadata for a defined program, preferably with
atomic accesses.

**Logical extensions checked**

The "instruction converted to `MemoryLocation` loses ordering" pattern appears
in exactly the two overloads above:

- `getModRefInfo(Instruction, CallBase)` is exploitable today through Sink and
  MemorySSA-style call-use queries.
- `getModRefInfo(Instruction, Instruction)` is wrong as an API result, but I did
  not find a current optimization path that consumes it unsafely.

For fences, the AA behavior matches current LangRef metadata semantics. The
remaining audit target is metadata production, not the `ScopedNoAliasAA` query
alone.

### 2. Pointer Identity And Address-Changing Intrinsics

**Analysis 08: `llvm.ptrmask` in GEP decomposition**

This is one of the strongest reports. `DecomposeGEPExpression()` looks through
calls returned by `getArgumentAliasingToReturnedPointer(Call, false)`, and that
helper includes `llvm.ptrmask`. This is valid for underlying-object reasoning
but not for symbolic byte-offset decomposition, because `ptrmask` can change
the address.

The reproduced pattern is small:

```llvm
%p = getelementptr i8, ptr %base, i64 1
%q = call ptr @llvm.ptrmask.p0.i64(ptr %p, i64 -2)
%r = getelementptr i8, ptr %q, i64 1
```

With `%base` aligned to 2, `%r == %p`, but BasicAA reports `NoAlias`. Running
GVN before InstCombine returns stale `7`; folding the ptrmask first exposes the
correct return `42`. This is C-reachable through `__builtin_align_down()`.

**Analysis 12: `extern_weak` globals with valid null**

This is confirmed. BasicAA treats two distinct `extern_weak` globals as
different identified objects and reports `NoAlias`. In a
`null_pointer_is_valid` function, unresolved `extern_weak` symbols become null,
and null is a valid load/store address. If both symbols are unresolved, stores
through `@x` and `@y` alias.

GVN folds the submitted shape to `ret i8 7` even though the both-unresolved
execution should return `42`. Severity is medium-low because it requires
`extern_weak`, valid null, and an execution environment where address zero is
usable.

**Analysis 13: nullable `noalias` returns**

The local behavior reproduces: BasicAA reports `NoAlias` for two distinct
nullable `noalias` call returns in a `null_pointer_is_valid` function, and GVN
folds to the stale store.

I do not count this as validated. Return `noalias` has allocation-like
semantics: memory locations accessed via values based on the return are not also
accessed via values not based on it, and return values additionally represent
allocated storage disjoint from other storage accessible to the caller. If two
such results are both null and both are used for stores to the same valid null
address, the program may already violate the `noalias` contract. This needs a
LangRef decision before being treated like the `extern_weak` case.

**Logical extensions checked**

The confirmed address-changing intrinsic in
`getArgumentAliasingToReturnedPointer(..., false)` is `llvm.ptrmask`. The
invariant-group and AArch64 tagging intrinsics in the same helper are intended
to preserve the memory address for AA purposes. I did not find the same small
offset-loss pattern for `llvm.threadlocal.address`.

The identified-object shortcut also covers `noalias` calls and
`noalias`/`byval` arguments. The `extern_weak` case is the clean validated
instance because LangRef explicitly says unresolved weak symbols become null.
The nullable `noalias` family is real optimizer behavior but not yet a proven
semantic bug.

### 3. Memory Location Size Modeling

**Analysis 04: `aliasErrno()` and upper-bound sizes**

This is confirmed. `BasicAAResult::aliasErrno()` uses
`Loc.Size.hasValue()` and compares the known minimum value against `sizeof(int)`.
`hasValue()` is true for both precise sizes and upper bounds. An
`upperBound(8)` access can actually touch four bytes and therefore can alias a
32-bit `errno`.

The provided masked-load shape produces `NoModRef` between a masked load and a
call declared `memory(errnomem: write)`. With a diff-style version of the test,
EarlyCSE folds the result to zero across the errno-writing call. This generalizes
to every producer of imprecise `LocationSize::upperBound(N)` where the actual
runtime access may be no larger than `sizeof(int)`.

Relevant upper-bound producers found in `MemoryLocation::getForArgument()`:

- masked load/store when the mask does not produce a known exact type,
- matrix load/store with non-unit stride,
- `memset_chk`/`memcpy_chk`,
- `strncpy` source operand,
- `memccpy`.

**Analysis 07: matrix intrinsic extent overflow**

This is confirmed. Matrix column-major load/store computes:

```cpp
DL.getTypeAllocSize(ScalarTy) * (ConstStride * (Cols - 1) + Rows)
```

with unchecked `uint64_t` arithmetic. With rows `1`, columns `2`, and stride
`-1`, the modeled extent wraps to zero. AA reports `NoModRef` for a matrix store
that actually writes `%base`, and GVN before matrix lowering returns stale `7`
while lowering first returns `42`.

Severity is low because the trigger requires adversarial huge strides.

**Logical extension found: `llvm.experimental.memset.pattern`**

The same unchecked computed-size family exists in
`MemoryLocation::getForArgument()` for `llvm.experimental.memset.pattern`:

```cpp
LenCI->getZExtValue() * DL.getTypeAllocSize(PatternType)
```

I verified a direct extension using an `i16` pattern and count `2^63`. The true
write is huge and includes `%base`, but the modeled size wraps to zero, AA
reports `NoModRef`, and GVN returns stale `7`. This was not one of the
submissions through `17`, but it is a real logical extension of analysis 07.

Ordinary `memcpy`/`memmove`/`memset` use a byte length directly in this code
path, so they do not have this multiplication overflow shape there.

### 4. BasicAA GEP Arithmetic And AliasResult Offsets

**Analysis 06: two-variable `MinAbsVarIndex` overflow**

This is confirmed as an AA soundness bug. With two `nusw` GEP indices at scale
7 and an assumption that the indices differ, BasicAA reports `NoAlias` for two
four-byte accesses. The submitted large concrete values make the addresses
overlap by two bytes because the difference of two individually non-wrapping
scaled products can wrap.

Severity is low. The trigger needs indices near the signed limits and objects
spanning almost the whole address space, so it is not a practical real-world
miscompile.

**Analysis 03: `constantOffsetHeuristic()` overflow**

I could not validate the submitted proof. Running the reported IR shape in this
checkout produces `PartialAlias`, not `NoAlias`. The source does contain an
unchecked multiply in `constantOffsetHeuristic()`, but the submitted example
does not reach a bad result. I did not find a replacement reproducer during the
extension audit.

**Analysis 01: `AliasResult::swap()` offset asymmetry**

This is confirmed as an API invariant bug. `AliasResult` stores partial-alias
offsets in a 23-bit signed field. `-4194304` is representable but `+4194304` is
not. `swap()` negates via `setOffset()`, and `setOffset()` silently leaves the
old offset in place if the new value does not fit.

`aa-eval` prints:

```text
PartialAlias (off -4194304): <1048577 x i32>* %p, i32* %q
```

for a direction that should have the positive offset. Current GVN and DSE
consumers guard against negative offsets before using them, so this is a missed
optimization / invariant violation rather than a demonstrated miscompile.

### 5. TBAA And Operand-Bundle Modeling

**Analysis 05: new-format TBAA access size ignored**

This is confirmed. New-format TBAA access tags have a size operand, but
`TypeBasedAAResult::Aliases()` does not consult `TBAAStructTagNode::getSize()`.
It compares offsets and type reachability only.

The reproduced case uses an 8-byte omnipotent-char access at offset 0 and a
4-byte int access at offset 4 in the same base object. Their byte ranges
overlap, but TBAA reports no alias. GVN forwards `123456` across a memset that
actually overwrites the loaded bytes.

This likely affects widened/combined memory operations with size-aware TBAA
metadata, including metadata produced through `AAMDNodes::extendToTBAA()`.

**Analysis 11: `GlobalsAA` summaries ignore operand bundles**

This is confirmed. `GlobalsAAResult::AnalyzeCallGraph()` propagates callee
function summaries, then skips call instructions while scanning the body. It
does not account for callsite operand bundles. A wrapper around a `memory(none)`
callee with an unknown operand bundle can therefore be summarized as
`memory(none)`, even though LangRef gives unknown bundles heap read/write
effects unless callsite memory attributes override them.

The supplied `analysis/11/reproducer.ll` folds the function to `ret i32 0` with
`basic-aa,globals-aa` and EarlyCSE. This is valid IR but not C-reachable through
ordinary Clang source.

**Analysis 15: TBAA call metadata hides operand-bundle effects**

This is confirmed. `TypeBasedAAResult::getModRefInfo(Call, Loc)` returns
`NoModRef` when the call's `!tbaa` tag is disjoint from the location tag. It
does not preserve the independent heap effects introduced by unknown operand
bundles.

The supplied `analysis/15/reproducer.ll` shows the contrast:

- with BasicAA only, MemorySSA correctly makes the load depend on the bundled
  call,
- with TBAA enabled, MemorySSA skips the call,
- EarlyCSE then returns stale `1`.

This is a distinct code path from analysis 11: the bad result comes from TBAA,
not a GlobalsAA function summary.

**Analysis 16: scoped-noalias masking errno effects**

The optimizer behavior reproduces: a call declared `memory(errnomem: write)`
with `!noalias` can be treated as `NoModRef` for a matching `!alias.scope` load,
and EarlyCSE folds the difference to zero.

I do not validate it as a real bug under current semantics. LangRef defines
`noalias`/`alias.scope` metadata for memory-accessing calls broadly. If the call
metadata says the call's memory accesses do not alias the scoped load, then an
execution where the call's errno write aliases that load appears to violate the
metadata promise. The C reproducer also passes `&errno` through a `restrict`
parameter while calling a function that modifies `errno`, which appears to
violate the same noalias/restrict premise. Treating errno effects as outside
scoped metadata would require a semantics change or a more precise metadata
rule.

**Logical extensions checked**

The operand-bundle issue appears in multiple layers:

- `BasicAAResult::getMemoryEffects(CallBase *)` explicitly ORs in reading and
  clobbering operand-bundle effects.
- `GlobalsAA` does not account for those effects while summarizing callees.
- `TypeBasedAAResult::getModRefInfo(Call, Loc)`,
  `TypeBasedAAResult::getModRefInfo(Call, Call)`, and the immutable-type
  `getMemoryEffects(Call)` path can all suppress effects without preserving
  operand-bundle memory.

Those TBAA call-vs-call and immutable-call paths should be included in any fix
or regression audit.

### 6. Writability Inference

**Analysis 10: `noalias` call returns treated as writable**

This is confirmed and high priority. `isWritableObject()` returns
`isNoAliasCall(Object)` for any call result with a `noalias` return attribute.
The source comment already notes that this is wrong: noalias proves disjointness,
not that introducing a new store is safe.

SimplifyCFG's conditional-store speculation consumes this helper. I reproduced
the report:

- with `declare noalias ptr @get_ro()`, SimplifyCFG creates an unconditional
  store of a select,
- without `noalias`, the conditional store remains.

A `noalias` function may return fresh readable storage that is not writable
after the call. The original false branch only loads; the optimized false branch
stores back the loaded value and can trap. This is C-reachable through source
that lowers to a `noalias` return, such as `__declspec(restrict)` or allocator
annotations.

**Logical extensions checked**

The same helper is also used by LICM and MemCpyOpt. I confirmed the SimplifyCFG
miscompile, but any fix should audit all `isWritableObject()` callers. The safe
rule is to require an actual writability/allocation guarantee, not `noalias`
alone.

## Verification Notes

I ran the available checked reproducers for `analysis/11`, `analysis/15`, and
`analysis/17`, and directly inspected the optimized output for
`analysis/16`. I also ran inline `opt` reproducers for `01`, `02`, `03`, `04`,
`05`, `06`, `07`, `08`, `10`, `12`, and `13`.

Key local observations:

- `analysis/03` reports `PartialAlias`, not the claimed `NoAlias`.
- `analysis/09` and `analysis/16` reproduce the optimized output claimed by the
  reports, but the semantic proof is not sufficient under current LangRef.
- The additional `experimental_memset_pattern` extension produces the same
  `NoModRef`/stale-return shape as the matrix size overflow family.
