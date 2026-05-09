# Alias Analysis Submission Summary

This reviews the submissions under `analysis/` against the local LLVM checkout
and `prompt.md`. I read the markdown reports in `analysis/01` through
`analysis/15`, the extra review/reproducer files, and the test-only files that
are currently present in `analysis/16`.

I validated the concrete claims by inspecting the relevant source and, where a
small reproducer was available, running the local `build/bin/opt`. The
classification below distinguishes confirmed miscompilations from API defects,
missed optimizations, and candidates whose proof is incomplete or whose
semantics need more review.

## Priority Summary

| Priority | Submission(s) | Finding | Validation |
| --- | --- | --- | --- |
| High | 08 | `llvm.ptrmask` is treated as offset-preserving in BasicAA GEP decomposition. | Confirmed miscompile; small C-reachable pattern. |
| High | 09 | `ScopedNoAliasAA` can make fences appear `NoModRef`. | Confirmed EarlyCSE miscompile; C-reachable via nested inlining/restrict. |
| High | 02 | `getModRefInfo(Instruction, CallBase)` misses ordered atomic effects. | Confirmed Sink moves a call across a release store. |
| High | 10 | `isWritableObject()` treats arbitrary `noalias` call returns as writable. | Confirmed SimplifyCFG speculates a store; C reproducer can fault. |
| Medium-high | 04 | `aliasErrno()` treats upper-bound sizes as exact. | Confirmed EarlyCSE removes a masked load across an `errnomem` write. |
| Medium-high | 05 | New-format TBAA access sizes are ignored. | Confirmed GVN forwards a stale value across an overlapping `memset`. |
| Medium | 11 | `GlobalsAA` ignores operand-bundle memory effects in function summaries. | Confirmed with `analysis/11/reproducer.ll`; IR-only trigger. |
| Medium-low | 12 | `extern_weak` globals are treated as distinct with valid null. | Confirmed optimizer behavior; real but target/environment niche. |
| Low | 07, 15 | Intrinsic memory-size arithmetic overflows for matrix and `memset_pattern`. | Confirmed, but triggers require adversarial huge sizes/strides. |
| Low | 06 | Two-variable BasicAA `MinAbsVarIndex` reasoning can wrap. | Confirmed API/miscompile shape, but practically requires enormous indices. |
| Low | 14 | `getModRefInfo(Instruction, Instruction)` misses ordered effects of `I2`. | Real API defect, but no current optimizer path was shown. |
| Low | 01 | `AliasResult::swap()` can leave a stale partial-alias offset. | Confirmed wrong offset sign; current consumers appear guarded. |
| Unvalidated | 03 | `constantOffsetHeuristic()` overflow claim. | The submitted IR reports `PartialAlias`, not `NoAlias`, in this checkout. |
| Uncertain | 13, 16 | Null-valid `noalias` return/argument extensions. | Optimizer behavior confirmed; legality depends on `noalias` null semantics. |

## Groups Of Similar Bugs

### 1. Barrier And Ordering Semantics Lost

**Analysis 02: ordered atomic instruction vs call**

This is a real correctness bug. `AAResults::getModRefInfo(const Instruction *,
const CallBase *)` handles non-call, non-fence instructions by converting the
instruction to a `MemoryLocation` and querying whether the call touches that
location. That loses the ordering semantics of atomic loads/stores/cmpxchg/rmw.

I reproduced the Sink case from the report: a read-only call before a release
store is sunk into a successor block after the release store. That violates the
release ordering rule.

**Analysis 14: ordered second instruction in the two-instruction overload**

The underlying API defect is real: `getModRefInfo(I1, I2)` also converts `I2`
to a `MemoryLocation` when `I2` is not a call, so `I2`'s ordering is lost. The
example `call @reader` vs `store atomic release` produces `NoModRef` in
`aa-eval`.

However, `analysis/15/review.md` is correct that the report overstates impact.
The two-atomic example is wrong because `I1`'s ordered store is caught by the
instruction-specific handler. I did not find a current MemorySSA/EarlyCSE/GVN
path that consumes the two-instruction overload in the dangerous shape. This is
a real latent API bug, not a demonstrated optimizer miscompile.

**Analysis 09: fences and scoped-noalias**

This is a separate but related barrier bug. `AAResults::getModRefInfo(FenceInst,
Loc)` now consults the AA chain, and `ScopedNoAliasAAResult` can return
`NoModRef` for a fence with `!noalias` metadata. A fence is not an
address-specific access, so scoped-noalias reasoning should not remove it as a
clobber.

I reproduced the EarlyCSE failure: two loads separated by a `fence seq_cst` are
CSE'd to `ret i32 0` when the fence carries matching `!noalias`.

**Logical extensions checked**

The same "instruction converted to `MemoryLocation` loses ordering" pattern
exists in exactly the two overloads above. The normal
`getModRefInfo(Instruction, MemoryLocation)` dispatch checks the ordering of
the instruction being dispatched on. MemorySSA uses the `(Instruction,
CallBase)` overload for call uses and the `(Instruction, MemoryLocation)`
overload otherwise; it does not use the two-instruction overload.

For fences, the broader audit target is AA providers that apply
address-specific reasoning to `FenceInst`. `ScopedNoAliasAA` is the confirmed
bad provider.

### 2. Pointer Identity And Provenance Shortcuts

**Analysis 08: `ptrmask` in GEP decomposition**

This is one of the strongest submissions. `DecomposeGEPExpression()` looks
through calls returned by `getArgumentAliasingToReturnedPointer(Call, false)`.
That helper includes `llvm.ptrmask`, which preserves provenance/underlying
object but may change the address. BasicAA then reasons about the wrong byte
offset.

I reproduced the report's small case:

```llvm
%p = getelementptr i8, ptr %base, i64 1
%q = call ptr @llvm.ptrmask.p0.i64(ptr %p, i64 -2)
%r = getelementptr i8, ptr %q, i64 1
```

With `%base` aligned to 2, `%r == %p`, but GVN first returns stale `7` while
InstCombine first exposes the correct `42`. This is practical because it maps
to `__builtin_align_down()`.

**Analysis 12: `extern_weak` globals with valid null**

The optimizer behavior is confirmed. In a `null_pointer_is_valid` function,
GVN folds:

```llvm
store i8 7, ptr @x
store i8 42, ptr @y
%v = load i8, ptr @x
```

to `ret i8 7` for two distinct `extern_weak` globals. If both symbols are
unresolved, LangRef says they become null; with valid null, both stores target
the same address and the correct value would be `42`.

This is real but niche: it requires `extern_weak`, valid null, and an execution
environment where address zero is usable.

**Analysis 13 and analysis/16: nullable `noalias` extensions**

The test files in `analysis/16` show the optimizer also folds similar cases for
distinct `noalias` call returns and for `noalias` arguments. The behavior is
confirmed locally.

I would not count these as fully validated bugs yet. `noalias` itself may make
same-address accesses undefined, especially for arguments. Return `noalias` is
more subtle because allocation-like functions may return null and are not
required to be `nonnull`, but LangRef says return `noalias` means allocated
storage disjoint from objects accessible to the caller. This needs a focused
LangRef-level decision before treating it as the same quality as the
`extern_weak` finding.

**Logical extensions checked**

`ptrmask` is the confirmed address-changing member of
`getArgumentAliasingToReturnedPointer(..., false)`. Other listed intrinsics
such as invariant-group strip/launder and AArch64 tag intrinsics are intended to
preserve the memory address for AA purposes. `threadlocal_address` is different
semantically, but I did not find the same small offset-loss pattern there.

The null-valid family also touches `isIdentifiedObject()` generally:
globals, `noalias` calls, `noalias`/`byval` arguments. The `extern_weak` case is
the clean validated instance because the LangRef explicitly gives unresolved
weak symbols the null address.

### 3. Memory Location Size Modeling

**Analysis 04: `aliasErrno()` and upper-bound sizes**

This is real. `aliasErrno()` checks `Loc.Size.hasValue()` and compares the
known minimum value against `sizeof(int)`, but `hasValue()` is true for both
precise and upper-bound sizes. An `upperBound(8)` access may actually access
four bytes and therefore may alias a 32-bit `errno`.

I reproduced the EarlyCSE result from the local
`llvm/test/Analysis/BasicAA/errno-upperbound.ll`: the first masked load is
removed across a call declared `memory(errnomem: write)`.

This generalizes beyond the masked-load example. Any producer of an imprecise
`LocationSize::upperBound(N)` where the actual access may be at most `sizeof(int)`
can hit the same bug. Relevant producers include masked loads/stores with
unknown masks and some bounded libc models such as `*_chk`, `strncpy` source,
and `memccpy`.

**Analysis 07: matrix intrinsic extent overflow**

This is real but low-practicality. `MemoryLocation::getForArgument()` computes
the matrix memory span with unchecked arithmetic:

```cpp
DL.getTypeAllocSize(ScalarTy) * (ConstStride * (Cols - 1) + Rows)
```

With stride `-1`, rows `1`, cols `2`, the modeled size wraps to zero even
though the lowered store writes `%base`. I reproduced the ordering-sensitive
miscompile: GVN before matrix lowering returns stale `7`, while lowering first
shows the store of `42` to `%base`.

**Analysis 15: `llvm.experimental.memset_pattern` extent overflow**

The markdown report in `analysis/15/analysis.md` is also real. The intrinsic
case computes `Count * sizeof(PatternType)` without overflow checking. I
reconstructed the report's IR and confirmed GVN returns stale `7` when the true
write size is `2^67` bytes but the modeled size wraps to zero.

This is the same family as the matrix bug, but a different intrinsic path.

**Logical extensions checked**

I searched `MemoryLocation::getForArgument()`. The confirmed unchecked computed
extents are matrix load/store and `experimental_memset_pattern`. The ordinary
memcpy/memset/memmove and libc cases generally use a byte length directly, so
they do not have the same multiplication overflow shape there. They may still
participate in the `aliasErrno()` upper-bound bug when modeled imprecisely.

### 4. BasicAA GEP Arithmetic Reasoning

**Analysis 06: two-variable `MinAbsVarIndex` overflow**

This is real as an AA result. With `getelementptr nusw [7 x i8]` and assumed
non-equal indices, BasicAA reports `NoAlias` for two four-byte accesses even
though the submitted large concrete values can make the addresses overlap by
two bytes. I reproduced the `aa-eval` `NoAlias`.

Severity is low because the trigger requires indices near signed limits and
effectively address-space-sized objects. It is still a soundness bug.

**Analysis 03: `constantOffsetHeuristic()` overflow**

I could not validate this as submitted. Running the provided IR shape in this
checkout reports `PartialAlias`, not `NoAlias`. The earlier constant-offset
logic appears to fold the concrete `5 * D == -1` relationship before
`constantOffsetHeuristic()` can misclassify it.

The source does contain an unchecked `APInt` multiply in
`constantOffsetHeuristic()`, so there may be a real bug with a more constrained
IR shape that reaches that heuristic. The submitted proof and reproducer are
not sufficient.

**Analysis 01: `AliasResult::swap()` offset asymmetry**

This is a real API bug. `AliasResult` stores offsets in a 23-bit signed
bitfield. `-4194304` is representable, but `+4194304` is not. `swap()` calls
`setOffset(-getOffset())`, and `setOffset()` silently leaves the old offset in
place when the new value does not fit.

I reproduced `aa-eval` printing:

```text
PartialAlias (off -4194304): <1048577 x i32>* %p, i32* %q
```

for the direction that should have a positive offset. Current GVN/DSE consumers
guard against negative offsets, so this is a missed optimization / invariant
violation rather than a demonstrated miscompile.

### 5. TBAA And Metadata Modeling

**Analysis 05: new-format TBAA access size ignored**

This is real. New-format access tags carry an access size operand, but
`TypeBasedAAResult::Aliases()` only compares offsets and type reachability in
`mayBeAccessToSubobjectOf()`. It does not use `TBAAStructTagNode::getSize()`.

I reproduced the report's GVN result. An 8-byte omnipotent-char `memset` at
offset 0 and a 4-byte int load at offset 4 overlap, but TBAA returns
`NoModRef`; GVN forwards the stale store and returns `123456`.

This likely affects any widened/combined memory operation whose new-format TBAA
tag size is larger than the scalar slot implied by its offset, not just the
specific `memset` example. `AAMDNodes::extendToTBAA()` makes this especially
important because LLVM itself updates the size operand when widening metadata.

**Extra current file: `analysis/15/reproducer.ll`**

The current `analysis/15/reproducer.ll` does not match `analysis/15/analysis.md`.
It is a TBAA plus unknown operand-bundle test:

```llvm
call void @leaf() [ "unknown"(ptr %p) ], !tbaa !float
```

With only BasicAA, MemorySSA treats the call as the clobber. With BasicAA+TBAA,
the load becomes a `MemoryUse` of the earlier store and EarlyCSE returns `1`.
The FileCheck expectations in that file pass locally.

I am not folding this into the main validated list because there is no written
analysis explaining the LangRef argument. It is a plausible logical extension:
TBAA may be filtering the unknown heap effects introduced by an operand bundle,
even though those effects are not ordinary typed callee accesses. This deserves
a separate write-up.

### 6. Function/Call Effect Summaries

**Analysis 11: GlobalsAA ignores operand-bundle effects**

This is real. `GlobalsAAResult::AnalyzeCallGraph()` propagates only callee
function summaries through call graph edges and then skips call instructions in
the body scan. For a call such as:

```llvm
call void @leaf() [ "unknown"(ptr %p) ]
```

where `@leaf` is `memory(none)`, the wrapper can be summarized as
`memory(none)` even though LangRef gives unknown operand bundles heap
read/write effects unless overridden by callsite attributes.

I verified `analysis/11/reproducer.ll`: with `globals-aa` required,
EarlyCSE folds the function to `ret i32 0`.

This is an IR-level issue rather than an ordinary C frontend issue, but it is a
clear summary bug.

### 7. AA Utility Misused As Writability Proof

**Analysis 10: noalias call returns treated as writable**

This is real and important even though it is an AA utility rather than an alias
query. `isWritableObject()` returns true for any `noalias` call result. The
comment at the bug site already says this is wrong.

I reproduced SimplifyCFG converting a conditional store into an unconditional
store of either the new value or the old loaded value. If the `noalias` return
points to readable but non-writable memory, the original false path is defined
but the optimized program can trap.

Logical extensions: `isWritableObject()` is also used by LICM and
MemCpyOptimizer, not only SimplifyCFG. The report only proves SimplifyCFG, but
those consumers should be audited under the same rule: `noalias` is not a
writability guarantee.

## Notes On Repository State

`analysis/15/` contains mixed content:

* `analysis/15/analysis.md` reports the `experimental.memset_pattern` overflow.
* `analysis/15/reproducer.ll` currently contains the TBAA/unknown-bundle test.
* `analysis/15/review.md` reviews analysis 14.

`analysis/16/` currently contains only LLVM IR test files for the null-valid
`extern_weak` / `noalias` family and no `analysis.md`.

I did not modify any source code. The summary above is based on the current
contents of the workspace.
