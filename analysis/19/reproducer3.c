// C reproducer for GlobalsModRef errno bug.
// Demonstrates incorrect optimization: the load of `g` is eliminated at -O2.
//
// `g` is a static int whose address is never taken. aliasErrno returns
// MayAlias for it (it's an i32 global, not function-local). BasicAA correctly
// includes Mod from fmodf's errnomem:write effect when queried about the
// wrapper call vs `g`. But GlobalsModRef returns Ref (missing the Mod),
// and the AA chain intersects to Ref. GVN forwards the stale store of 42.
//
// Build and observe the optimization:
//   clang -O2 -S -emit-llvm reproducer3.c -o - | grep "ret i32"
//
// BUG:     "ret i32 42"  (load eliminated, store value forwarded)
// CORRECT: should preserve the load of g

static int g;

__attribute__((noinline))
static float do_fmodf(float x, float y) {
    return __builtin_fmodf(x, y);
}

int test(float x, float y) {
    g = 42;
    float r = do_fmodf(x, y);
    // Prevent `r` from being optimized away entirely
    if (r > 0.0f) g = 0;
    return g;
}
