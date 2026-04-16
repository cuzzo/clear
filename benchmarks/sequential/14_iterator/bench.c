/*
 * Iterator Benchmark — C Baseline
 *
 * Compares pointer-based iteration vs indexed loop over a heap array.
 * 1000 outer iterations × 10000 Int64 elements.
 * Total: 10M element reads.
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>

#define N 10000
#define ITERS 1000

typedef struct {
    const int64_t *data;
    int64_t pos;
    int64_t len;
} SliceIter;

static SliceIter make_iter(const int64_t *data, int64_t len) {
    return (SliceIter){ .data = data, .pos = 0, .len = len };
}

/* noinline to prevent LLVM from optimizing the iterator pattern away */
__attribute__((noinline)) int has_next(SliceIter *it) { return it->pos < it->len; }
__attribute__((noinline)) int64_t current_val(SliceIter *it) { return it->data[it->pos]; }
__attribute__((noinline)) void advance_iter(SliceIter *it) { it->pos++; }

static double elapsed_ms(struct timespec a, struct timespec b) {
    return (b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6;
}

int main(void) {
    int64_t *data = malloc(N * sizeof(int64_t));
    for (int64_t i = 0; i < N; i++) data[i] = i * 7 + 13;

    struct timespec t0, t1, t2, t3;
    int64_t result1 = 0, result2 = 0;

    /* Benchmark 1: pointer iterator */
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int outer = 0; outer < ITERS; outer++) {
        SliceIter it = make_iter(data, N);
        while (has_next(&it)) {
            result1 += current_val(&it);
            advance_iter(&it);
        }
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);

    /* Benchmark 2: raw indexed loop */
    clock_gettime(CLOCK_MONOTONIC, &t2);
    for (int outer = 0; outer < ITERS; outer++) {
        for (int64_t i = 0; i < N; i++) {
            result2 += data[i];
        }
    }
    clock_gettime(CLOCK_MONOTONIC, &t3);

    /* BENCH_RESULT = iterator time (primary metric) */
    printf("BENCH_RESULT: %.0f ms\n", elapsed_ms(t0, t1));
    printf("Iterator benchmark (%d elements x %d iters)\n", N, ITERS);
    printf("  Iterator: %.1f ms\n", elapsed_ms(t0, t1));
    printf("  Raw loop: %.1f ms\n", elapsed_ms(t2, t3));

    free(data);
    return 0;
}
