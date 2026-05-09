// Demonstrates the GlobalsModRef bug at the optimization level.
// The load of `flag` is incorrectly eliminated because GlobalsModRef
// reports the wrapper call as Ref-only (missing the errnomem Mod).
//
// The runtime result happens to be correct by coincidence (fmodf writes
// to the real errno, not to `flag`), but the optimization decision is
// wrong: the compiler cannot prove `flag` is unmodified across the call
// since `aliasErrno` returns MayAlias for it.
//
// Compile: clang -O2 -S -emit-llvm reproducer.c -o - | grep "ret i32"
// Bug:     "ret i32 0" (load eliminated, value forwarded from store)
// Correct: should preserve the load (flag may alias errno per aliasErrno)

static int flag;

float fmodf(float, float) __attribute__((pure));
// ^ This is wrong, but illustrates the point: if fmodf is declared with
// limited memory effects, GlobalsModRef's per-global analysis won't
// include writes to `flag`.

static void wrapper(float *out, float x, float y) {
    *out = fmodf(x, y);
}

int test(float x, float y) {
    flag = 0;
    float buf;
    wrapper(&buf, x, y);
    return flag;
}
