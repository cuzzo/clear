/*
 * SROA Benchmark — C Baseline (Perfect)
 *
 * BigVec is stack-allocated each iteration; C reclaims it automatically.
 * With -O3 + inlining + SROA: only x1, x2, x3 are live. x4..x130
 * initializations are dead-code-eliminated. The loop is pure arithmetic.
 *
 * Runs 100 000 iterations trivially. CLEAR crashes after ~1000.
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
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    double acc = 0.0;
    for (int64_t i = 0; i < 100000; i++) {
        BigVec bv;
        memset(&bv, 0, sizeof(bv));
        bv.x1 = acc;
        bv.x2 = acc + 1.0;
        bv.x3 = acc + 2.0;
        acc += sum3(bv);
    }

    assert(acc > 0.0);

    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed = (end.tv_sec - start.tv_sec) +
                     (end.tv_nsec - start.tv_nsec) / 1e9;

    printf("acc = %.6f\n", acc);
    printf("Time: %.4f seconds\n", elapsed);
    return 0;
}
