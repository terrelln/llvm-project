# Alias Analysis Bug: `noalias` Call Returns Are Treated As Writable

## Status

Confirmed with the local `./build/bin/opt`.

This is not one of the prior integer-overflow reports, and it is not the
previous scoped-noalias/fence or atomic-ordering issue. The bug is in an
AliasAnalysis helper used by transforms that need to know whether a speculative
store is safe.

## Summary

`llvm::isWritableObject()` in `llvm/lib/Analysis/AliasAnalysis.cpp` returns
true for any value produced by a call with a `noalias` return attribute:

```cpp
// TODO: Noalias shouldn't imply writability, this should check for an
// allocator function instead.
return isNoAliasCall(Object);
```

That is unsound. A `noalias` return proves disjointness/allocated-storage
properties. It does not prove that introducing a new store through the returned
pointer cannot trap or create a data race. LLVM has a separate `writable`
attribute for that kind of guarantee, and `isWritableObject()` already handles
`writable` specially for arguments.

The bad answer is consumed by `SimplifyCFG`'s conditional-store speculation.
If a block first loads from a pointer and then conditionally stores to the same
pointer, `SimplifyCFG` may convert the conditional store into an unconditional
store of either the new value or the old loaded value. That is only valid if
the pointer is known writable. Because `isWritableObject()` says a `noalias`
call return is writable, `SimplifyCFG` can introduce an unconditional store to
readable but non-writable memory.

## Bug Location

`llvm/lib/Analysis/AliasAnalysis.cpp`, current lines 967-990:

```cpp
bool llvm::isWritableObject(const Value *Object,
                            bool &ExplicitlyDereferenceableOnly) {
  ExplicitlyDereferenceableOnly = false;

  // TODO: Alloca might not be writable after its lifetime ends.
  // See https://github.com/llvm/llvm-project/issues/51838.
  if (isa<AllocaInst>(Object))
    return true;

  if (auto *A = dyn_cast<Argument>(Object)) {
    // Also require noalias, otherwise writability at function entry cannot be
    // generalized to writability at other program points, even if the pointer
    // does not escape.
    if (A->hasAttribute(Attribute::Writable) && A->hasNoAliasAttr()) {
      ExplicitlyDereferenceableOnly = true;
      return true;
    }

    return A->hasByValAttr();
  }

  // TODO: Noalias shouldn't imply writability, this should check for an
  // allocator function instead.
  return isNoAliasCall(Object);
}
```

The relevant consumer is `SimplifyCFG`:

`llvm/lib/Transforms/Utils/SimplifyCFG.cpp`, current lines 3066-3079:

```cpp
if (auto *LI = dyn_cast<LoadInst>(&CurI)) {
  if (LI->getPointerOperand() == StorePtr && LI->getType() == StoreTy &&
      LI->isSimple() && LI->getAlign() >= StoreToHoist->getAlign()) {
    Value *Obj = getUnderlyingObject(StorePtr);
    bool ExplicitlyDereferenceableOnly;
    if (isWritableObject(Obj, ExplicitlyDereferenceableOnly) &&
        capturesNothing(
            PointerMayBeCaptured(Obj, CaptureComponents::Provenance)
                .WithoutRet) &&
        (!ExplicitlyDereferenceableOnly ||
         isDereferenceablePointer(StorePtr, StoreTy,
                                  LI->getDataLayout()))) {
      // Found a previous load, return it.
      return LI;
    }
  }
}
```

If this returns the prior load, the transform builds an unconditional store:

`llvm/lib/Transforms/Utils/SimplifyCFG.cpp`, current lines 3331-3342:

```cpp
if (SpeculatedStoreValue) {
  IRBuilder<NoFolder> Builder(BI);
  Value *OrigV = SpeculatedStore->getValueOperand();
  Value *TrueV = SpeculatedStore->getValueOperand();
  Value *FalseV = SpeculatedStoreValue;
  if (Invert)
    std::swap(TrueV, FalseV);
  Value *S = Builder.CreateSelect(
      BrCond, TrueV, FalseV, "spec.store.select", BI);
  Sel = cast<Instruction>(S);
  SpeculatedStore->setOperand(0, S);
```

## LLVM IR Reproducer

```llvm
; Current buggy command:
;   opt -passes='simplifycfg' -S < %s
;
; Correct behavior: the store must remain conditional.
; Current buggy behavior: simplifycfg creates an unconditional store.

target triple = "x86_64-unknown-linux-gnu"

declare noalias ptr @get_ro()

define void @store_speculates_to_noalias_return(i1 %c) {
entry:
  %p = call noalias ptr @get_ro()
  %old = load i32, ptr %p, align 4
  br i1 %c, label %then, label %end

then:
  store i32 42, ptr %p, align 4
  br label %end

end:
  ret void
}
```

## Observed Miscompile

With the `noalias` return attribute, `simplifycfg` speculates the store:

```llvm
$ build/bin/opt -passes='simplifycfg' -S -o - repro.ll

declare noalias ptr @get_ro()

define void @store_speculates_to_noalias_return(i1 %c) {
entry:
  %p = call noalias ptr @get_ro()
  %old = load i32, ptr %p, align 4
  %spec.store.select = select i1 %c, i32 42, i32 %old
  store i32 %spec.store.select, ptr %p, align 4
  ret void
}
```

Without `noalias`, the same pass leaves the conditional store in place:

```llvm
declare ptr @get_ro()

define void @store_speculates_to_noalias_return(i1 %c) {
entry:
  %p = call ptr @get_ro()
  %old = load i32, ptr %p, align 4
  br i1 %c, label %then, label %end

then:
  store i32 42, ptr %p, align 4
  br label %end

end:
  ret void
}
```

The repro also passes verifier before and after the transform:

```text
build/bin/opt -passes='verify,simplifycfg,verify' -disable-output repro.ll
```

## C Reproducer

Clang can produce the same IR from C. The Microsoft spelling
`__declspec(restrict)` maps directly to an LLVM `noalias` return. On non-MS
targets this spelling requires `-fdeclspec` or the broader `-fms-extensions`.
The GNU `__attribute__((malloc))` spelling also maps to the same LLVM return
attribute and does not require an extra frontend flag, but
`__declspec(restrict)` is the more direct "return value is not aliased" source
trigger.

```c
// Compile with:
//   clang -O1 -fdeclspec repro.c -o repro
//
// Expected behavior: prints 123, because f(0) does not execute the source
// store.
// Current optimized behavior: SIGSEGV, because SimplifyCFG speculates an
// unconditional store of the loaded value back to a read-only mapping.

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

__declspec(restrict) __attribute__((noinline))
int *get_ro(void) {
  long page = sysconf(_SC_PAGESIZE);
  void *p = mmap(NULL, (size_t)page, PROT_READ | PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (p == MAP_FAILED)
    abort();
  *(int *)p = 123;
  if (mprotect(p, (size_t)page, PROT_READ) != 0)
    abort();
  return (int *)p;
}

__attribute__((noinline))
int f(int c) {
  int *p = get_ro();
  int old = *p;
  if (c)
    *p = 42;
  return old;
}

int main(void) {
  printf("%d\n", f(0));
  return 0;
}
```

Verified locally:

```text
$ build/bin/clang -O1 -fdeclspec repro.c -o repro
$ ./repro
Segmentation fault (exit 139)

$ build/bin/clang -O0 -fdeclspec repro.c -o repro-O0
$ ./repro-O0
123
```

At `-O1`, the generated IR for `f` contains the same bad unconditional store:

```llvm
define dso_local i32 @f(i32 noundef %c) local_unnamed_addr {
entry:
  %call = tail call noalias ptr @get_ro()
  %0 = load i32, ptr %call, align 4
  %tobool.not = icmp eq i32 %c, 0
  %spec.store.select = select i1 %tobool.not, i32 %0, i32 42
  store i32 %spec.store.select, ptr %call, align 4
  ret i32 %0
}
```

## Proof of Unsoundness

The declaration permits a function that returns fresh, disjoint, readable
storage that is not writable. For example, `@get_ro` can allocate or map a new
read-only page and return a pointer into it. That satisfies the noalias return
contract: the returned storage is disjoint from other objects accessible to the
caller. It does not satisfy a writable contract, and no such attribute is
present in the IR.

For such an implementation:

1. `%p = call noalias ptr @get_ro()` returns a readable, non-writable pointer.
2. `%old = load i32, ptr %p` succeeds.
3. If `%c` is false, the original function reaches `ret void` without storing
   to `%p`.
4. If `%c` is true, the original function stores to `%p`; that path may trap or
   have undefined behavior.

The optimized function performs:

```llvm
%spec.store.select = select i1 %c, i32 42, i32 %old
store i32 %spec.store.select, ptr %p
```

That store executes even when `%c` is false. The false path was defined in the
original program, but the optimized program may trap or introduce undefined
behavior by writing back the loaded value to non-writable memory. Speculating a
store of the same value is still a store, so it requires an actual writability
guarantee.

The `noalias` return guarantee is not enough. LLVM's own comment at the bug
site says the same thing: "`Noalias shouldn't imply writability`".

## Why This Is An AliasAnalysis Bug

`isWritableObject()` lives in `AliasAnalysis.cpp` and is exported from
`llvm/Analysis/AliasAnalysis.h`. Transforms call it as a shared AA utility for
questions of the form "can I introduce a store to this object?".

The helper currently conflates two independent facts:

- `noalias` return: the returned object is disjoint from other accessible
  objects.
- writable: a store through the pointer can be introduced without trapping or
  racing.

Only the second fact justifies SimplifyCFG's transformation.

## Proposed Fix

Do not treat arbitrary `noalias` call returns as writable.

The conservative source change is:

```cpp
bool llvm::isWritableObject(const Value *Object,
                            bool &ExplicitlyDereferenceableOnly) {
  ...

  // A noalias return proves disjointness, not writability.
  if (auto *CB = dyn_cast<CallBase>(Object)) {
    // Only return true for calls that are known allocation functions whose
    // returned storage is writable, or for a future explicit return-side
    // writable guarantee.
    return isKnownWritableAllocator(CB);
  }

  return false;
}
```

The exact predicate should use allocator knowledge rather than `noalias`
alone. Reasonable options:

1. Return false for `isNoAliasCall(Object)` until a precise allocator predicate
   is available.
2. Return true only for calls recognized by `TargetLibraryInfo` or allocation
   attributes as writable allocation functions.
3. If LLVM grows a return-value equivalent of the `writable` attribute, require
   that explicit guarantee.

The important invariant is:

```text
No transform may introduce a store to a noalias call return unless the return
is also known to be writable.
```
