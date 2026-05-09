# Alias Analysis Bug: `constantOffsetHeuristic` Overflow in MinDiffBytes

## Summary

`BasicAAResult::constantOffsetHeuristic()` in
`llvm/lib/Analysis/BasicAliasAnalysis.cpp` (line 2019-2020) computes
`MinDiffBytes = MinDiff * |Scale|` using a wrapping APInt multiplication. When
the product overflows the index bit width, the wrapped result can be **larger**
than the actual minimum byte distance between two pointers. The subsequent check
`MinDiffBytes >= AccessSize` then falsely passes, causing the function to return
NoAlias for pointers that actually overlap.

## Bug Location

**File:** `llvm/lib/Analysis/BasicAliasAnalysis.cpp`, lines 2017-2027

```cpp
APInt MinDiff = E0.Offset - E1.Offset, Wrapped = -MinDiff;
MinDiff = APIntOps::umin(MinDiff, Wrapped);
APInt MinDiffBytes =
    MinDiff.zextOrTrunc(Var0.Scale.getBitWidth()) * Var0.Scale.abs();
                                                 // ^^^ CAN OVERFLOW

return MinDiffBytes.uge(V1Size + GEP.Offset.abs()) &&
       MinDiffBytes.uge(V2Size + GEP.Offset.abs());
```

`MinDiff` is correctly computed as the minimum distance between two index offsets
on the wrap-around ring (line 2017-2018). But the conversion to bytes on line
2019-2020 multiplies by `|Scale|` **without checking for overflow**. When the
product wraps, `MinDiffBytes` can be much larger than the true minimum byte
distance, causing the `uge` checks to pass incorrectly.

## How It Works

The `constantOffsetHeuristic` handles GEP pairs where two variable indices have
negated scales and differ only by a constant. For example:

```
GEP1 = base + Scale * (V + A)
GEP2 = base + Scale * (V + B)
distance = Scale * (A - B)   (mod 2^N)
```

The function computes:
1. `MinDiff = min(|A - B|, 2^W - |A - B|)` — minimum index distance (line 2017-2018)
2. `MinDiffBytes = MinDiff * |Scale|` — convert to bytes (line 2019-2020)
3. Check `MinDiffBytes >= AccessSize` — NoAlias if gap exceeds access size (line 2026-2027)

Step 1 correctly accounts for wrapping of the **index** arithmetic. But step 2
does not account for wrapping of the **byte distance** multiplication. When
`MinDiff * |Scale| >= 2^N` (where N is the pointer index width), the product
wraps and the result is wrong.

## Concrete Example

Choose `Scale = 5` (element size of `[5 x i8]`) and offset
`D = floor(2^64 / 5) = 3689348814741910323`.

Then `5 * D = 18446744073709551615 = 2^64 - 1 ≡ -1 (mod 2^64)`.

```
GEP1 = base + 5 * V
GEP2 = base + 5 * (V + D) = base + 5*V + (2^64 - 1) = GEP1 - 1
```

So GEP2 is exactly **1 byte before** GEP1. Two 4-byte accesses at GEP1 and GEP2
overlap by 3 bytes.

The heuristic computes:
- `MinDiff = min(D, 2^64 - D) = D` (since `D < 2^63`)
- `MinDiffBytes = D * 5 mod 2^64 = 2^64 - 1`
- `2^64 - 1 >= 4` → **true** → returns **NoAlias**

But the actual minimum byte distance is `min(2^64 - 1, 1) = 1`, and `1 < 4`,
so the accesses **do** alias. The result is **wrong**.

## LLVM-IR Proof

```llvm
define void @constantOffsetHeuristic_overflow(ptr noalias %base, i64 %V) {
  ; D = floor(2^64 / 5) = 3689348814741910323
  ; 5 * D mod 2^64 = 2^64 - 1 = -1
  ; So GEP2 = GEP1 - 1; the 4-byte accesses overlap by 3 bytes.

  %j = add i64 %V, 3689348814741910323

  %p1 = getelementptr [5 x i8], ptr %base, i64 %V
  %p2 = getelementptr [5 x i8], ptr %base, i64 %j

  ; p1 = base + 5*V
  ; p2 = base + 5*(V + D) = base + 5*V + 5*D = base + 5*V - 1 = p1 - 1
  ;
  ; 4-byte access at p1: bytes [p1, p1+4)
  ; 4-byte access at p2: bytes [p1-1, p1+3)
  ; Overlap: bytes [p1, p1+3)  -- 3 bytes of overlap
  ;
  ; BasicAA's constantOffsetHeuristic incorrectly returns NoAlias because:
  ;   MinDiff = 3689348814741910323
  ;   MinDiffBytes = MinDiff * 5 mod 2^64 = 2^64 - 1
  ;   2^64 - 1 >= 4  →  NoAlias  (WRONG)

  %v1 = load i32, ptr %p1
  %v2 = load i32, ptr %p2

  ret void
}
```

To verify: `opt -aa-pipeline=basic-aa -passes="print<aa-eval>" -print-all-alias-modref-info`
should report NoAlias for the two load locations, but the correct answer is
PartialAlias (they overlap by 3 bytes).

## Why This Is a Miscompilation

A downstream pass (GVN, DSE, LICM, etc.) that trusts this NoAlias result could:
- Reorder the loads incorrectly
- Eliminate a store that a later load depends on
- Hoist/sink memory operations across aliasing accesses

Any such transformation would produce incorrect code.

## Precedent: Other Multiplications in This File Check for Overflow

The two other places in `aliasGEP` that multiply a distance/scale check for
overflow explicitly:

```cpp
// Line 1225-1228: vscale NoAlias check
bool Overflow;
APInt UpperRange = CR.getUnsignedMax().umul_ov(
    APInt(Off.getBitWidth(), LSize.getKnownMinValue()), Overflow);
if (!Overflow && Off.uge(UpperRange))
    return AliasResult::NoAlias;

// Line 1248-1254: vscale variable index check
bool Overflows = !DecompGEP1.VarIndices[0].IsNSW;
if (Overflows) {
    ...
    (void)CR.getSignedMax().smul_ov(Scale, Overflows);
}
if (!Overflows) { ... return AliasResult::NoAlias; }
```

Both use `umul_ov`/`smul_ov` and bail out when overflow occurs.
`constantOffsetHeuristic` is the only multiplication of a distance by a scale
in this file that does **not** check for overflow.

## Fix

After computing `MinDiffBytes`, take the minimum with its complement to account
for wrap-around in pointer arithmetic, mirroring what line 2017-2018 already does
for index arithmetic:

```cpp
APInt MinDiffBytes =
    MinDiff.zextOrTrunc(Var0.Scale.getBitWidth()) * Var0.Scale.abs();

// Account for wrapping of the byte-distance multiplication.
APInt WrappedBytes = -MinDiffBytes;
MinDiffBytes = APIntOps::umin(MinDiffBytes, WrappedBytes);

return MinDiffBytes.uge(V1Size + GEP.Offset.abs()) &&
       MinDiffBytes.uge(V2Size + GEP.Offset.abs());
```

Alternatively, check for overflow before using the result:

```cpp
bool Overflow;
APInt MinDiffBytes =
    MinDiff.zextOrTrunc(Var0.Scale.getBitWidth())
        .umul_ov(Var0.Scale.abs(), Overflow);
if (Overflow)
    return false;  // Can't prove NoAlias when multiplication overflows.

return MinDiffBytes.uge(V1Size + GEP.Offset.abs()) &&
       MinDiffBytes.uge(V2Size + GEP.Offset.abs());
```
