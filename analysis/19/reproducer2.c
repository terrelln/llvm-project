// Test whether GlobalsModRef + errno miscompiles with real fmodf.
// The static global `g` is a non-address-taken i32 that aliasErrno
// returns MayAlias for. If GlobalsModRef says the wrapper call only
// reads g (Ref), GVN will forward 0 to the load.

static int g;

extern float fmodf(float, float);

__attribute__((noinline))
static void wrapper(float *out, float x, float y) {
    *out = fmodf(x, y);
}

int test(float x, float y) {
    g = 0;
    float buf;
    wrapper(&buf, x, y);
    return g;  // should not be folded to 0
}
