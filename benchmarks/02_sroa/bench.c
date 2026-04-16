/*
 * SROA Benchmark — C Baseline
 *
 * BigVec has 130 int64_t fields (1040 bytes). sum3() reads only x1, x2, x3.
 * 127 of the 130 field initialisations are dead.
 *
 * With -O3 + SROA: LLVM decomposes BigVec into scalars, DCE eliminates the
 * 127 unused ones, and the loop body reduces to ~3 integer adds per iteration.
 *
 * volatile limit prevents the compiler from evaluating the loop at compile
 * time. acc is fed back each iteration (true data dependency) and reduced
 * mod 1_000_000_007 to stay bounded.
 *
 * N = 100 000 000 iterations.
 * Build: gcc -O3 -o bench_c bench.c
 */

#include <stdio.h>
#include <stdint.h>
#include <assert.h>
#include <time.h>

typedef struct {
    int64_t x1, x2, x3, x4, x5, x6, x7, x8, x9, x10;
    int64_t x11, x12, x13, x14, x15, x16, x17, x18, x19, x20;
    int64_t x21, x22, x23, x24, x25, x26, x27, x28, x29, x30;
    int64_t x31, x32, x33, x34, x35, x36, x37, x38, x39, x40;
    int64_t x41, x42, x43, x44, x45, x46, x47, x48, x49, x50;
    int64_t x51, x52, x53, x54, x55, x56, x57, x58, x59, x60;
    int64_t x61, x62, x63, x64, x65, x66, x67, x68, x69, x70;
    int64_t x71, x72, x73, x74, x75, x76, x77, x78, x79, x80;
    int64_t x81, x82, x83, x84, x85, x86, x87, x88, x89, x90;
    int64_t x91, x92, x93, x94, x95, x96, x97, x98, x99, x100;
    int64_t x101, x102, x103, x104, x105, x106, x107, x108, x109, x110;
    int64_t x111, x112, x113, x114, x115, x116, x117, x118, x119, x120;
    int64_t x121, x122, x123, x124, x125, x126, x127, x128, x129, x130;
} BigVec;

static int64_t sum3(BigVec v) {
    return v.x1 + v.x2 + v.x3;
}

int main(void) {
    volatile int64_t limit = 100000000;

    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    int64_t acc = 1;
    for (int64_t i = 0; i < limit; i++) {
        /* Designated initializer: x4-x130 are zero-initialised by C spec.
         * SROA + DCE eliminates all 127 dead zero-writes. */
        BigVec bv = {.x1 = acc, .x2 = acc + 1, .x3 = acc + 2};
        acc = sum3(bv) % 1000000007;
    }

    assert(acc > 0);

    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed = (end.tv_sec - start.tv_sec) +
                     (end.tv_nsec - start.tv_nsec) / 1e9;

    long elapsed_ms = (long)(elapsed * 1000);
    /* BENCH_RESULT = elapsed ms */
    printf("BENCH_RESULT: %ld ms\n", elapsed_ms);
    printf("acc = %ld\nTime: %.4f seconds\n", acc, elapsed);
    return 0;
}
