/*
 * Sort Benchmark — C Baseline
 *
 * Sorts 1,000,000 f64 values using:
 *   1. Iterative Lomuto quicksort  (same algorithm as CLEAR)
 *   2. Bottom-up iterative mergesort (same algorithm as CLEAR)
 *
 * Data: deterministic permutation via Knuth's multiplicative hash
 *   val[i] = (i * 2654435761) % N  cast to double
 *   This is a permutation of [0, N-1], so sorted result is 0.0, 1.0, ..., N-1.0.
 *
 * "Perfect C": direct array indexing, no indirection, no runtime overhead.
 * CLEAR comparison uses CheatLib.getAt/setAt which the Zig inliner eliminates.
 *
 * Compile: gcc -O3 bench.c -o bench_c
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <time.h>

#define N 1000000

/* --- Iterative Lomuto quicksort --- */
static void qsort_c(double *arr, int64_t n) {
    /* Stack for (lo, hi) pairs. log2(1M) < 20; 64 pairs is safe. */
    int64_t lo_stk[64], hi_stk[64];
    int64_t sp = 0;
    lo_stk[sp] = 0;
    hi_stk[sp] = n - 1;
    sp++;

    while (sp > 0) {
        sp--;
        int64_t lo = lo_stk[sp];
        int64_t hi = hi_stk[sp];

        if (lo >= hi) continue;

        /* Lomuto partition: pivot = arr[hi] */
        double pivot = arr[hi];
        int64_t i = lo - 1;
        for (int64_t j = lo; j < hi; j++) {
            if (arr[j] <= pivot) {
                i++;
                double tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp;
            }
        }
        i++;
        { double tmp = arr[i]; arr[i] = arr[hi]; arr[hi] = tmp; }
        int64_t pi = i;

        /* Push larger subrange first (smaller processed first → O(log N) depth) */
        if ((pi - lo) > (hi - pi)) {
            lo_stk[sp] = lo;      hi_stk[sp] = pi - 1; sp++;
            lo_stk[sp] = pi + 1;  hi_stk[sp] = hi;     sp++;
        } else {
            lo_stk[sp] = pi + 1;  hi_stk[sp] = hi;     sp++;
            lo_stk[sp] = lo;      hi_stk[sp] = pi - 1; sp++;
        }
    }
}

/* --- Bottom-up iterative mergesort --- */
static void msort_c(double *arr, double *tmp, int64_t n) {
    for (int64_t width = 1; width < n; width *= 2) {
        for (int64_t lo = 0; lo < n; lo += 2 * width) {
            int64_t mid = lo + width;     if (mid > n) mid = n;
            int64_t hi  = lo + 2 * width; if (hi  > n) hi  = n;
            if (mid >= hi) continue;

            int64_t i = lo, j = mid, k = lo;
            while (k < hi) {
                if (j >= hi || (i < mid && arr[i] <= arr[j]))
                    tmp[k++] = arr[i++];
                else
                    tmp[k++] = arr[j++];
            }
            memcpy(arr + lo, tmp + lo, (hi - lo) * sizeof(double));
        }
    }
}

static void fill(double *arr, int64_t n) {
    for (int64_t i = 0; i < n; i++)
        arr[i] = (double)((i * (int64_t)2654435761ULL) % n);
}

int main(void) {
    double *arr = malloc(N * sizeof(double));
    double *tmp = malloc(N * sizeof(double));
    assert(arr && tmp);

    struct timespec t0, t1;

    /* --- Quicksort --- */
    fill(arr, N);
    clock_gettime(CLOCK_MONOTONIC, &t0);
    qsort_c(arr, N);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double qs_time = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    assert(arr[0] <= arr[1] && arr[N-2] <= arr[N-1]);
    /* --- Mergesort --- */
    fill(arr, N);
    clock_gettime(CLOCK_MONOTONIC, &t0);
    msort_c(arr, tmp, N);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double ms_time = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    assert(arr[0] <= arr[1] && arr[N-2] <= arr[N-1]);

    double total_ms = (qs_time + ms_time) * 1000.0;
    printf("BENCH_RESULT: %.0f ms\n", total_ms);
    printf("Sort 1M floats | Quicksort: %.1f ms | Mergesort: %.1f ms\n",
           qs_time * 1000.0, ms_time * 1000.0);

    free(arr);
    free(tmp);
    return 0;
}
