# Analysis 19: GlobalsModRef Fails to Track `errnomem` Write Effects

## Bug Summary

`GlobalsAAResult::getModRefInfo(CallBase*, MemoryLocation&)` incorrectly returns
`Ref` (read-only) instead of `ModRef` for calls to functions that write errno
through external function calls. This is because GlobalsModRef's per-global
analysis does not account for `errnomem: write` memory effects from external
calls that don't callback into the module.

## Root Cause

GlobalsModRef tracks per-global read/write information using two mechanisms:

1. **`MayReadAnyGlobal` flag**: Set when an external function may read
   non-argument memory. This correctly marks that ANY tracked global might be
   read.

2. **Per-global `ModRefInfo` map**: Records which specific globals each function
   reads or writes. Populated by:
   - `AnalyzeGlobals()`: Scans direct uses (loads/stores) of each global.
   - `addFunctionInfo()`: Propagates per-global info from internal callees.

The bug: there is **no `MayWriteAnyGlobal` flag**. When an external function has
`errnomem: write` effects (or any non-arg, non-inaccessible write effects) and
does not callback into the module (`MaySyncOrCallIntoModule` returns false),
GlobalsModRef:
- Adds `ModRef` to the caller's **overall** `ModRefInfo` ✓
- Sets `MayReadAnyGlobal` (read side only) ✓
- Does **NOT** set `KnowNothing` (because no callback) ✗
- Does **NOT** add per-global `Mod` for any specific global ✗

Then in `getModRefInfoForGlobal()`:
```cpp
ModRefInfo GlobalMRI = mayReadAnyGlobal() ? ModRefInfo::Ref : ModRefInfo::NoModRef;
auto I = Info.GlobalInfo.find(&GV);
if (I != Info.GlobalInfo.end())
    GlobalMRI |= I->second;
return GlobalMRI;
```

Only `MayReadAnyGlobal` contributes (Ref). No per-global Mod exists for the
errno global. So the function returns **Ref** even though the function writes
errno.

## Affected Code Path

**File**: `llvm/lib/Analysis/GlobalsModRef.cpp`

1. `AnalyzeCallGraph()` (line ~548-556): When processing an external callee with
   write effects that doesn't callback:
   ```cpp
   FI.addModRefInfo(ModRefInfo::ModRef);          // overall MRI set correctly
   if (!F->onlyAccessesArgMemory())
       FI.setMayReadAnyGlobal();                  // only READ flag set
   if (MaySyncOrCallIntoModule(*F)) {
       KnowNothing = true;                        // NOT reached for nosync nocallback
       break;
   }
   ```

2. `getModRefInfoForGlobal()` (line ~156-164): Returns only `Ref` when no
   per-global Mod exists.

3. `getModRefInfo()` (line ~950-968): Uses per-global info to answer queries:
   ```cpp
   Known = FI->getModRefInfoForGlobal(*GV) |      // = Ref (wrong, should include Mod)
           getModRefInfoForArgument(Call, GV, AAQI);
   ```

## Impact

BasicAA correctly detects the errno write and returns `ModRef` for the call.
But the AA chain intersects all providers' results:
```
Result = BasicAA(ModRef) & GlobalsModRef(Ref) = Ref
```

GlobalsModRef's incorrect `Ref` masks BasicAA's correct `Mod`, so the final
result is `Ref`. GVN then forwards a stale store value past the errno-writing
call, producing incorrect code.

## Proof: LLVM IR Reproducer

See `reproducer.ll`. The test shows:

```llvm
@my_errno = internal global i32 0

declare float @fmodf(float, float) nosync nocallback memory(errnomem: write)

define internal void @wrapper(ptr %out, float %x, float %y) {
  %r = call float @fmodf(float %x, float %y)
  store float %r, ptr %out
  ret void
}

define i32 @test(float %x, float %y) {
  store i32 0, ptr @my_errno          ; store 0 to errno
  %buf = alloca float
  call void @wrapper(ptr %buf, float %x, float %y)  ; calls fmodf → writes errno
  %e = load i32, ptr @my_errno        ; should load fmodf's errno value
  ret i32 %e                          ; should NOT be 0
}
```

**Without GlobalsModRef** (`opt -passes='gvn'`): The load is preserved. ✓

**With GlobalsModRef** (`opt -passes='require<globals-aa>,gvn'`): GVN forwards
the store value `0` to the load and returns `ret i32 0`. ✗

**At -O2** (`opt -O2`): The wrapper is inlined and the result is `ret i32 0`. ✗

## Conditions for Triggering

1. An internal (local-linkage) global whose address is not taken in the IR
2. A function that calls an external function with `errnomem: write` effects
3. The external function has `nosync` and `nocallback` (so `MaySyncOrCallIntoModule` returns false — typical for math library functions)
4. The calling function does NOT directly access the tracked global
5. The tracked global may alias errno (per `aliasErrno`)

## Proposed Fix (Description Only)

Add a `MayModAnyGlobal` flag (or equivalently, a `MayModRefAnyGlobal` flag) to
`FunctionInfo`. In `AnalyzeCallGraph`, when processing an external call that is
not read-only and not arg-only, set this flag alongside `MayReadAnyGlobal`. In
`getModRefInfoForGlobal`, use this flag to include `Mod` in the result:

```cpp
ModRefInfo GlobalMRI = ModRefInfo::NoModRef;
if (mayReadAnyGlobal())
    GlobalMRI |= ModRefInfo::Ref;
if (mayModAnyGlobal())     // NEW
    GlobalMRI |= ModRefInfo::Mod;
```

Alternatively, when `MaySyncOrCallIntoModule` returns false but the function
has non-arg write effects (including errnomem), set `KnowNothing = true` to
fall back to conservative analysis. This is less precise but simpler.

## Relation to Prior Work

This bug is distinct from all prior analyses:
- **Not** an integer overflow issue (Bugs 01, 03, 06, 07)
- **Not** an atomic ordering issue (Bugs 02, 14, 17)
- **Not** a ScopedNoAliasAA metadata masking issue (Bugs 09, 16)
- **Not** a TBAA issue (Bugs 05, 15)
- **Not** an object identification issue (Bugs 10, 12, 13)
- **Not** a ptrmask issue (Bug 08)
- Bug 11 found that GlobalsAA ignores operand-bundle effects — this is a
  **different** GlobalsAA bug about missing `errnomem` write tracking in
  per-global analysis
