/*
 * List vs. Stack Benchmark — C Baseline (Heap Array)
 *
 * Allocates a heap array each outer iteration via malloc, fills it,
 * sums it, and frees it. Apples-to-apples comparison with Rust
 * (Vec::with_capacity) and CLEAR (Float64[1000]@list).
 *
 * 1000 outer iterations × 1000 element fills + sums:
 *   - 1 malloc + 1 free per outer iteration
 *   - 0 reallocs (pre-allocated to exact size)
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <assert.h>
#include <time.h>

#define N 1000

int main(void) {
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    double total = 0.0;
    for (int64_t outer = 0; outer < N; outer++) {
        double *arr = (double *)malloc(N * sizeof(double));
        for (int64_t i = 0; i < N; i++) arr[i] = (double)i;

        double s = 0.0;
        for (int64_t i = 0; i < N; i++) s += arr[i];
        total += s;
        free(arr);
    }

    assert(total > 0.0);

    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed = (end.tv_sec - start.tv_sec) +
                     (end.tv_nsec - start.tv_nsec) / 1e9;
    printf("total = %.0f\n", total);
    printf("Time: %.4f seconds\n", elapsed);
    return 0;
}
