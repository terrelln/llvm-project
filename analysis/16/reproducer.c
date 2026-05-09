// C reproducer for ScopedNoAliasAA errno masking bug.
//
// Compile and run:
//   clang -O2 -o reproducer reproducer.c -lm
//   ./reproducer
//
// Expected output: "diff = 33" (EDOM = 33 on Linux)
// Buggy output:    "diff = 0"
//
// The bug: when middle() is inlined, the fmodf call gets !noalias metadata
// for the 'b' restrict parameter. ScopedNoAliasAA then masks the errno
// write effect, and EarlyCSE CSEs the two loads of *b.

#include <errno.h>
#include <math.h>
#include <stdio.h>

__attribute__((always_inline))
static int middle(float *restrict a, int *restrict b, float x) {
    int v1 = *b;
    // fmodf(INFINITY, 2.0f) is a domain error that sets errno to EDOM.
    // fmodf has memory(errnomem: write) in LLVM.
    *a = fmodf(x, 2.0f);
    int v2 = *b;
    return v2 - v1;
}

__attribute__((noinline))
int outer(float *restrict a, int *restrict b, float x) {
    return middle(a, b, x);
}

int main(void) {
    float dummy;
    errno = 0;
    // Pass &errno as the 'b' parameter. Since 'b' is restrict, the
    // compiler assumes it doesn't alias 'a'. But restrict does NOT
    // say 'b' can't be errno.
    int diff = outer(&dummy, &errno, __builtin_inff());
    printf("diff = %d\n", diff);
    return diff == 0 ? 1 : 0;  // exit 1 if buggy
}
