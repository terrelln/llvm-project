# Alias Analysis Bug: `MinAbsVarIndex` Overflow in Two-Variable GEP Path

## Practical Impact

**Low.** This is a real logic error that can produce an incorrect NoAlias
result and miscompilation, but the trigger conditions require array indices
near ±2^62 on 64-bit targets (or ±2^30 on 32-bit targets). No realistic
program has single arrays that span a significant fraction of the address
space, so this bug is unlikely to manifest in practice.

It is included here as a soundness issue in the reasoning, not as a
high-priority miscompilation risk.

## Summary

`BasicAAResult::aliasGEP()` in `llvm/lib/Analysis/BasicAliasAnalysis.cpp`
(lines 1393-1407) computes `MinAbsVarIndex` for the case where two variable GEP
indices have negated scales: `VarIndex = Scale * V0 + (-Scale) * V1 = Scale * (V0 - V1)`.

The code checks that `Scale * V0` and `Scale * V1` individually do not overflow
signed (`MultiplyByScaleNoWrap`), and concludes that
`|VarIndex| >= |Scale|` when `V0 != V1`. This conclusion is **wrong**: the
individual products can each fit in the signed range while their **difference**
wraps around the index bit width, producing a `|VarIndex|` much smaller than
`|Scale|`.

The subsequent check at lines 1410-1418 uses this incorrect `MinAbsVarIndex`
to return **NoAlias** for pointers that actually overlap.

## Bug Location

**File:** `llvm/lib/Analysis/BasicAliasAnalysis.cpp`, lines 1393-1418

```cpp
  } else if (DecompGEP1.VarIndices.size() == 2) {
    // VarIndex = Scale*V0 + (-Scale)*V1.
    // If V0 != V1 then abs(VarIndex) >= abs(Scale).     // ← WRONG
    const VariableGEPIndex &Var0 = DecompGEP1.VarIndices[0];
    const VariableGEPIndex &Var1 = DecompGEP1.VarIndices[1];
    if (Var0.hasNegatedScaleOf(Var1) && Var0.Val.TruncBits == 0 &&
        Var0.Val.hasSameCastsAs(Var1.Val) && !AAQI.MayBeCrossIteration &&
        MultiplyByScaleNoWrap(Var0) && MultiplyByScaleNoWrap(Var1) &&
        isKnownNonEqual(Var0.Val.V, Var1.Val.V, ...))
      MinAbsVarIndex = Var0.Scale.abs();                  // ← BUG
  }

  if (MinAbsVarIndex) {
    APInt OffsetLo = DecompGEP1.Offset - *MinAbsVarIndex;
    APInt OffsetHi = DecompGEP1.Offset + *MinAbsVarIndex;
    if (OffsetLo.isNegative() && (-OffsetLo).uge(V1Size.getValue()) &&
        OffsetHi.isNonNegative() && OffsetHi.uge(V2Size.getValue()))
      return AliasResult::NoAlias;                        // ← WRONG RESULT
  }
```

## Root Cause

`MultiplyByScaleNoWrap(Var)` (lines 1363-1376) returns `true` when
`Var.IsNSW` is true, meaning `Scale * V` does not overflow signed. This
guarantees that `|Scale * V| >= |Scale|` for a single non-zero variable `V`:
the product is a non-zero multiple of `Scale` that fits in the signed range,
so it must be at least `|Scale|`.

But for the two-variable case, the **VarIndex** is:

```
VarIndex = Scale * V0 - Scale * V1 = Scale * (V0 - V1)     (mod 2^N)
```

The code checks `MultiplyByScaleNoWrap` for `V0` and `V1` separately, confirming
that `Scale * V0` and `Scale * V1` each fit in `[-2^(N-1), 2^(N-1)-1]`. But
their **difference** can have magnitude up to `2*(2^(N-1)-1) = 2^N - 2`, which
overflows signed N-bit arithmetic. When this overflow wraps the difference to a
small value, `|VarIndex|` can be much less than `|Scale|`.

## Mathematical Proof

Let `Scale = 7`, `N = 64`, `SMAX = 2^63 - 1 = 9223372036854775807`.

`M = floor(SMAX / 7) = 1317624576693539401`.

Verify: `7 * M = 9223372036854775807 = SMAX` (exactly).

Choose `V0 = M`, `V1 = -M`. Then:

| Value | Result | In signed 64-bit range? |
|-------|--------|------------------------|
| `7 * V0` | `9223372036854775807` = `SMAX` | Yes |
| `7 * V1` | `-9223372036854775807` = `-SMAX` | Yes |
| `7*V0 - 7*V1` | `2 * SMAX = 2^64 - 2` | **Overflows** |

In 64-bit modular arithmetic:
```
7*V0 - 7*V1  =  2^64 - 2  ≡  -2   (mod 2^64)
```

So `|VarIndex| = 2`, but the code sets `MinAbsVarIndex = 7` and assumes
`|VarIndex| >= 7`. The assumption is violated.

**Pointer relationship:**
```
%p = base + 7*V0 = base + SMAX
%q = base + 7*V1 = base - SMAX
%q - %p = -2*SMAX mod 2^64 = 2          ← %q is 2 bytes after %p
```

Two 4-byte accesses at `%p` and `%q`:
```
%p access: [%p, %p+4)
%q access: [%p+2, %p+6)
Overlap:   [%p+2, %p+4)  — 2 bytes
```

BasicAA returns **NoAlias** (because `MinAbsVarIndex` 7 >= 4 for both sizes),
but the accesses **overlap by 2 bytes**.

## Generality

This bug affects many `Scale` values. The condition for the bug is:
`2 + 2*R < Scale`, where `R = (2^(N-1) - 1) mod Scale`. When `R` is small
relative to `Scale`, the wrapped difference is small relative to `Scale`.

Vulnerable scales (64-bit, first 10): **7, 21, 23, 25, 29, 31, 33, 35, 37, 39, ...**

The pattern affects any scale `S` where `(2^63 - 1)` is nearly divisible by `S`.

## How It Triggers

The two-variable path is entered when `aliasGEP` is called for two GEP
instructions that index into the same base with different variable indices:

```llvm
%p = getelementptr nusw [7 x i8], ptr %base, i64 %i
%q = getelementptr nusw [7 x i8], ptr %base, i64 %j
```

After `DecomposeGEPExpression` and `subtractDecomposedGEPs`:

- `DecompGEP1.VarIndices = [{%i, Scale=7, IsNSW=true}, {%j, Scale=7, IsNegated=true, IsNSW=true}]`
- `DecompGEP1.Offset = 0`

The `nusw` flag on the GEP sets `IsNSW = true` on each variable index,
because the index-to-byte multiplication `index * 7` is declared not to
overflow signed.

`MultiplyByScaleNoWrap` returns `true` for both indices (due to `IsNSW`).
`isKnownNonEqual(%i, %j)` returns true (from the `llvm.assume`).
`MinAbsVarIndex` is set to 7, and the NoAlias check passes for any access
size <= 7.

## LLVM-IR Proof

```llvm
; RUN: opt -aa-pipeline=basic-aa -passes="print<aa-eval>" \
; RUN:   -print-all-alias-modref-info -disable-output < %s
;
; BasicAA incorrectly returns NoAlias for two 4-byte accesses that
; can overlap by 2 bytes when %i and %j take specific values.
;
; Trigger: %i = 1317624576693539401, %j = -1317624576693539401
;   7*%i = 2^63 - 1  (fits in signed 64-bit, nusw satisfied)
;   7*%j = -(2^63 - 1) (fits in signed 64-bit, nusw satisfied)
;   %p - %q = 7*%i - 7*%j = 2^64 - 2 ≡ -2 (mod 2^64)
;   So %q = %p + 2; the 4-byte accesses overlap.

define void @minabsvarindex_overflow(ptr noalias %base, i64 %i, i64 %j) {
  %ne = icmp ne i64 %i, %j
  call void @llvm.assume(i1 %ne)

  %p = getelementptr nusw [7 x i8], ptr %base, i64 %i
  %q = getelementptr nusw [7 x i8], ptr %base, i64 %j

  ; BasicAA path:
  ;   VarIndices = [{%i, Scale=7, NSW}, {%j, Scale=7, negated, NSW}]
  ;   MultiplyByScaleNoWrap: both IsNSW → true
  ;   isKnownNonEqual(%i, %j): true (from assume)
  ;   MinAbsVarIndex = 7
  ;   OffsetLo = -7, OffsetHi = 7
  ;   7 >= 4 (V1Size) and 7 >= 4 (V2Size)
  ;   → NoAlias                                          ← WRONG
  ;
  ;   Correct answer: MayAlias (they overlap for the trigger values)

  %v1 = load i32, ptr %p
  %v2 = load i32, ptr %q

  ret void
}

declare void @llvm.assume(i1)
```

## Miscompilation Path

GVN uses `MemoryDependenceAnalysis`, which queries `alias(%p, %q)`.
BasicAA returns `NoAlias`. GVN then determines that a store to `%q`
does not clobber a load from `%p`, and forwards an earlier store value:

```llvm
define i32 @miscompile(ptr noalias %base, i64 %i, i64 %j) {
  %ne = icmp ne i64 %i, %j
  call void @llvm.assume(i1 %ne)

  %p = getelementptr nusw [7 x i8], ptr %base, i64 %i
  %q = getelementptr nusw [7 x i8], ptr %base, i64 %j

  store i32 42, ptr %p
  store i32 99, ptr %q
  %v = load i32, ptr %p

  ; GVN sees NoAlias(%p, %q) → store 99 to %q is not a clobber of %p.
  ; GVN forwards store 42 → %v = 42.
  ;
  ; But with trigger values, %q = %p + 2. The store of 99 overwrites
  ; bytes [%p+2, %p+6), partially clobbering the i32 at %p.
  ; The load at %p should return a value with its upper 2 bytes modified.
  ; Returning 42 is incorrect.

  ret i32 %v
}
```

## Why the 1-Variable Path Is Correct

The 1-variable path (lines 1381-1392) does not have this bug:

```
VarIndex = Scale * V      (single variable, V ≠ 0)
```

When `IsNSW` is true, `Scale * V` doesn't overflow signed. Since `V ≠ 0`,
`Scale * V` is a non-zero multiple of `Scale` in the mathematical integers,
and since it fits in signed N-bit, its absolute value is at least `|Scale|`.
No subtraction of two products occurs, so no overflow from their difference.

## Fix

The simplest correct fix is to not trust the `IsNSW` shortcut in
`MultiplyByScaleNoWrap` when it's called from the 2-variable path. The
bit-width-based analysis (which proves the multiplication can't wrap for
ANY value) is safe for the 2-variable case because if `|Scale * V| < 2^(N-1)`
holds for all possible `V`, then `|Scale * V0 - Scale * V1| < 2^N`, and since
the minimum non-zero `|Scale * (V0 - V1)|` in mathematical integers is
`|Scale|`, the wrapped value also has absolute value >= `|Scale|`.

```cpp
  } else if (DecompGEP1.VarIndices.size() == 2) {
    const VariableGEPIndex &Var0 = DecompGEP1.VarIndices[0];
    const VariableGEPIndex &Var1 = DecompGEP1.VarIndices[1];
    // For 2 variables with negated scales: VarIndex = Scale*(V0-V1).
    // Individual MultiplyByScaleNoWrap (via IsNSW) is insufficient:
    // two in-range products can have a difference that wraps.
    // Use the bit-width-based proof which holds for all value pairs.
    auto MultiplyByScaleNoWrapForDiff = [](const VariableGEPIndex &Var) {
      int ValOrigBW = Var.Val.V->getType()->getPrimitiveSizeInBits();
      int MaxScaleValueBW = Var.Val.getBitWidth() - ValOrigBW;
      if (MaxScaleValueBW <= 0)
        return false;
      return Var.Scale.ule(
          APInt::getMaxValue(MaxScaleValueBW).zext(Var.Scale.getBitWidth()));
    };
    if (Var0.hasNegatedScaleOf(Var1) && Var0.Val.TruncBits == 0 &&
        Var0.Val.hasSameCastsAs(Var1.Val) && !AAQI.MayBeCrossIteration &&
        MultiplyByScaleNoWrapForDiff(Var0) &&
        MultiplyByScaleNoWrapForDiff(Var1) &&
        isKnownNonEqual(Var0.Val.V, Var1.Val.V,
                        SimplifyQuery(DL, DT, &AC, Var0.CxtI
                                                       ? Var0.CxtI
                                                       : Var1.CxtI)))
      MinAbsVarIndex = Var0.Scale.abs();
  }
```

## Why the Trigger Is Impractical

For Scale = 7 on a 64-bit target, the trigger requires `V0 ≈ 1.3×10^18` and
`V1 ≈ -1.3×10^18`. This means the GEP addresses span ~2^64 bytes from the
base pointer. No realistic allocation is that large.

On 32-bit targets the trigger is `V0 ≈ 3×10^8`, requiring a ~2GB `[7 x i8]`
array — possible in theory but extremely unlikely in practice. And the
`nusw` flag (without `inbounds`) is uncommon; most frontends emit `inbounds`
GEPs, which constrain pointers to within the allocated object, making these
extreme indices unreachable.

For scales that are powers of 2 (the most common case for struct sizes),
the wrapped product is always a multiple of the scale, so the bug cannot
trigger at all. It only affects odd scales (7, 11, 21, 23, ...) where
`2^(N-1) - 1` is nearly divisible by the scale.

## Areas Checked Without Finding Bugs

The following areas were checked and appear correct:

- **GCD-based modular NoAlias** (lines 1289-1350): Sound. The GCD of
  ScaleForGCD values correctly divides all variable terms (even with wrapping
  arithmetic). The srem + modular gap check is correct.

- **ConstantRange intersection** (lines 1354-1359): Sound. smul_fast and
  smul_sat produce correct (possibly over-wide) ranges. The intersection
  check is conservative.

- **nuw-based NoAlias** (lines 1273-1276): Sound. When nuw is preserved
  after subtraction, the variable terms are unsigned non-negative, making
  the constant offset a true lower bound on the pointer distance.

- **Inbounds NoAlias** (lines 1147-1158): Sound. The signed comparison
  correctly handles the relationship between inbounds pointers and access
  sizes.

- **PartialAlias offset** (lines 1207-1221): The offset computation and
  sign handling are correct (the swap overflow from analysis 1 is a
  separate known issue).

- **Constant-offset NoAlias** (line 1221): The unsigned comparison
  `Off.ult(LSize)` correctly determines non-overlap for constant offsets.

- **aliasSelect / aliasPHI**: MergeAliasResults is conservative but
  sound — never produces incorrect NoAlias.

- **TBAA**: `matchAccessTags` and the type hierarchy traversal appear correct.

- **AliasSetTracker**: Ordering thresholds (isStrongerThanMonotonic for
  loads/stores) are consistent with how atomic instructions are handled.

- **getModRefInfo(I1, I2) for non-call I2** (lines 389-401): Dispatches
  through instruction-specific handlers which correctly check I1's atomic
  ordering. Unlike the (I, CallBase) path from analysis 2, I1's ordering
  is NOT skipped here.

- **Cache / assumption mechanism** (lines 1756-1830): The NoAlias
  assumption cycle-breaking, assumption-use tracking, and invalidation
  logic are sound. Disproven assumptions correctly purge dependent results.
