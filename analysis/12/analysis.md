# BasicAA bug: `extern_weak` globals are treated as disjoint even when they can both be null

NOTE: gcc has this same behavior. And writing to a NULL weak pointer is super weird, so I'm not sure if this is a bug or not.

## Summary

BasicAA can return `NoAlias` for two distinct `extern_weak` global variables even in a function where address-space 0 null is a valid memory location. This is unsound: LangRef says an unresolved `extern_weak` symbol becomes null, and `null_pointer_is_valid` says null is a valid address for loads and stores. If two weak globals are both unresolved, both pointers denote the same null address and memory operations through them alias.

This is not an integer-overflow issue and does not require large values. Clang can emit the relevant IR from ordinary weak declarations when compiled with `-fno-delete-null-pointer-checks`.

## Root cause

`llvm::isIdentifiedObject()` currently treats every non-alias `GlobalValue` as an identified object:

```c++
// llvm/lib/Analysis/AliasAnalysis.cpp
bool llvm::isIdentifiedObject(const Value *V) {
  if (isa<AllocaInst>(V))
    return true;
  if (isa<GlobalValue>(V) && !isa<GlobalAlias>(V))
    return true;
  ...
}
```

BasicAA then uses that helper to conclude that different identified objects cannot alias:

```c++
// llvm/lib/Analysis/BasicAliasAnalysis.cpp
if (O1 != O2) {
  if (isIdentifiedObject(O1) && isIdentifiedObject(O2))
    return AliasResult::NoAlias;
  ...
}
```

That rule misses the special `extern_weak` case. LangRef says:

```text
extern_weak:
  ... if not linked, the symbol becomes null instead of being an undefined reference.
```

and for `null_pointer_is_valid`:

```text
the null address in address-space 0 is considered to be a valid address for memory loads and stores.
```

So two distinct `extern_weak` globals are not necessarily two distinct storage objects in a null-valid function.

## LLVM IR reproducer

```llvm
@x = extern_weak global i8
@y = extern_weak global i8

define i8 @extern_weak_null_alias() null_pointer_is_valid {
entry:
  store i8 7, ptr @x
  store i8 42, ptr @y
  %v = load i8, ptr @x
  ret i8 %v
}
```

If both weak symbols are unresolved, both `@x` and `@y` are null. Since null is valid in this function, the second store overwrites the first store and the function should return `42`.

BasicAA says the locations do not alias:

```text
$ build/bin/opt -aa-pipeline=basic-aa -passes=aa-eval \
    -print-all-alias-modref-info -disable-output -S repro.ll

Function: extern_weak_null_alias: 2 pointers, 0 call sites
  NoAlias: i8* @x, i8* @y
```

GVN consumes that answer and folds the load to the first store:

```text
$ build/bin/opt -aa-pipeline=basic-aa \
    -passes='gvn,instcombine,simplifycfg' -S repro.ll

define i8 @extern_weak_null_alias() #0 {
entry:
  store i8 7, ptr @x, align 1
  store i8 42, ptr @y, align 1
  ret i8 7
}
```

That optimized result is wrong for the valid execution where both weak symbols resolve to null and null memory is valid.

## C source path

Clang emits the same shape from C:

```c
extern char x __attribute__((weak));
extern char y __attribute__((weak));

int f(void) {
  x = 7;
  y = 42;
  return x;
}
```

With:

```text
build/bin/clang -S -emit-llvm -O2 -fno-delete-null-pointer-checks repro.c
```

the function has `null_pointer_is_valid`, both globals are `extern_weak`, and the return is folded to `7`. In an environment where address zero is mapped and writable, the source program writes `7` to address zero, writes `42` to the same address, and should return `42`.

## Proposed fix

Do not use the generic "different identified objects" shortcut for `extern_weak` globals when the weak symbol can become a dereferenceable null pointer.

A conservative fix is to stop treating `extern_weak` `GlobalValue`s as identified objects in `isIdentifiedObject()`. A more precise fix is to keep the existing precision for ordinary globals, but in `BasicAAResult::aliasCheck()` suppress the `isIdentifiedObject(O1) && isIdentifiedObject(O2)` `NoAlias` result when either underlying object is an `extern_weak` `GlobalValue` whose address space has a valid null pointer in the current function:

```c++
auto IsExternWeakWithValidNull = [&](const Value *V) {
  auto *GV = dyn_cast<GlobalValue>(V);
  return GV && GV->hasExternalWeakLinkage() &&
         NullPointerIsDefined(&F, GV->getAddressSpace());
};

if (isIdentifiedObject(O1) && isIdentifiedObject(O2) &&
    !IsExternWeakWithValidNull(O1) && !IsExternWeakWithValidNull(O2))
  return AliasResult::NoAlias;
```

This also covers non-zero address spaces, where LLVM does not generally assume a zero bit-pattern is non-dereferenceable.
