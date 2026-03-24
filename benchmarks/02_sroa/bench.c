/*
 * SROA Benchmark — C Baseline
 *
 * WHAT THIS MEASURES:
 *   BigVec has 130 f64 fields (1040 bytes). sum3() reads only x1, x2, x3.
 *   127 of the 130 field initialisations are dead.
 *
 *   With -O3 + inlining + SROA (Scalar Replacement of Aggregates):
 *     - LLVM decomposes BigVec into 130 scalar SSA values
 *     - DCE eliminates the 127 unused ones
 *     - The loop body reduces to ~3 scalar fadd instructions per iteration
 *
 * PREVENTING CONSTANT FOLDING:
 *   `limit` is volatile so the compiler cannot evaluate the loop at compile
 *   time.  Loop inputs are fed from `acc` (previous result), creating a true
 *   recurrence that forces serial evaluation — matching the same dependency
 *   chain CLEAR must execute.
 *   acc triples quickly and becomes inf after ~50 iterations; IEEE 754 inf
 *   arithmetic is well-defined so the loop body continues to execute.
 *
 * N = 10 000 000 iterations.
 *
 * CLEAR DOES NOT IMPLEMENT SROA.
 *   The transpiler emits the full 130-field struct initialisation every
 *   iteration, plus a saveLoopMark/restoreLoopMark pair.
 *   Expected overhead: significant — dominated by 20 M runtime calls plus
 *   127 dead f64 writes per iteration.
 */

#include <stdio.h>
#include <stdint.h>
#include <assert.h>
#include <time.h>
#include <string.h>

typedef struct {
    double x1, x2, x3, x4, x5, x6, x7, x8, x9, x10;
    double x11, x12, x13, x14, x15, x16, x17, x18, x19, x20;
    double x21, x22, x23, x24, x25, x26, x27, x28, x29, x30;
    double x31, x32, x33, x34, x35, x36, x37, x38, x39, x40;
    double x41, x42, x43, x44, x45, x46, x47, x48, x49, x50;
    double x51, x52, x53, x54, x55, x56, x57, x58, x59, x60;
    double x61, x62, x63, x64, x65, x66, x67, x68, x69, x70;
    double x71, x72, x73, x74, x75, x76, x77, x78, x79, x80;
    double x81, x82, x83, x84, x85, x86, x87, x88, x89, x90;
    double x91, x92, x93, x94, x95, x96, x97, x98, x99, x100;
    double x101, x102, x103, x104, x105, x106, x107, x108, x109, x110;
    double x111, x112, x113, x114, x115, x116, x117, x118, x119, x120;
    double x121, x122, x123, x124, x125, x126, x127, x128, x129, x130;
} BigVec;

static double sum3(BigVec v) {
    return v.x1 + v.x2 + v.x3;
}

int main(void) {
    /* volatile prevents the compiler from evaluating the loop at compile time */
    volatile int64_t limit = 10000000;

    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    double acc = 1.0;
    for (int64_t i = 0; i < limit; i++) {
        BigVec bv;
        memset(&bv, 0, sizeof(bv));
        bv.x1 = acc;
        bv.x2 = acc + 1.0;
        bv.x3 = acc + 2.0;
        acc = sum3(bv);   /* acc = 3*acc + 3; triples, becomes inf ~50 iters */
    }

    assert(acc > 0.0); /* inf > 0 is true */

    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed = (end.tv_sec - start.tv_sec) +
                     (end.tv_nsec - start.tv_nsec) / 1e9;

    printf("acc = %g\nTime: %.4f seconds\n", acc, elapsed);
    return 0;
}
