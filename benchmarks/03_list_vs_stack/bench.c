/*
 * List vs. Stack Benchmark — C Baseline (Perfect)
 *
 * WHY C IS FAST:
 *   C can declare a fixed-size array on the OS stack: double arr[N].
 *   The OS stack is pre-committed memory — filling and summing it is a
 *   tight load/store loop with no allocator involvement whatsoever.
 *
 *   1000 outer iterations × 1000 element fills + sums:
 *     - 0 malloc/free calls
 *     - 0 allocator function calls
 *     - 0 error-union checks
 *     - Stack reclamation is free at each inner-loop scope exit
 *
 * Expected: 1M fills + 1M reads in ~1–2ms.
 */

#include <stdio.h>
#include <stdint.h>
#include <assert.h>
#include <time.h>

#define N 1000

int main(void) {
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    double total = 0.0;
    for (int64_t outer = 0; outer < N; outer++) {
        double arr[N];
        for (int64_t i = 0; i < N; i++) arr[i] = (double)i;

        double s = 0.0;
        for (int64_t i = 0; i < N; i++) s += arr[i];
        total += s;
    }

    assert(total > 0.0);

    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed = (end.tv_sec - start.tv_sec) +
                     (end.tv_nsec - start.tv_nsec) / 1e9;
    printf("total = %.0f\n", total);
    printf("Time: %.4f seconds\n", elapsed);
    return 0;
}
