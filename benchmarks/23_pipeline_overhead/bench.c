/*
 * Benchmark 23: Pipeline Overhead — C Baseline
 *
 * Test 1: Simple sum of 10M float64 values, 20 iterations.
 * Test 2: Fused filter (>500.0) + square + sum, 20 iterations.
 *
 * Data: deterministic LCG
 *   state = state * 6364136223846793005 + (i + 1442695040888963407)
 *   val = abs(state % 1000) as double
 *
 * Compile: gcc -O2 -o bench_c bench.c
 * Run:     ./bench_c
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

#define N    10000000
#define ITER 20

static void read_memory(long *vm_hwm_kb, long *vm_rss_kb) {
    *vm_hwm_kb = 0;
    *vm_rss_kb = 0;
    FILE *f = fopen("/proc/self/status", "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "VmHWM:", 6) == 0)
            *vm_hwm_kb = atol(line + 6);
        else if (strncmp(line, "VmRSS:", 6) == 0)
            *vm_rss_kb = atol(line + 6);
    }
    fclose(f);
}

static double elapsed_ms(struct timespec *start, struct timespec *end) {
    return (end->tv_sec - start->tv_sec) * 1000.0
         + (end->tv_nsec - start->tv_nsec) / 1e6;
}

static double sum_loop(const double *data, int64_t n) {
    double sum = 0.0;
    for (int64_t i = 0; i < n; i++) {
        sum += data[i];
    }
    return sum;
}

static double fused_loop(const double *data, int64_t n) {
    double sum = 0.0;
    for (int64_t i = 0; i < n; i++) {
        double v = data[i];
        if (v > 500.0) {
            sum += v * v;
        }
    }
    return sum;
}

int main(void) {
    double *data = malloc(N * sizeof(double));
    if (!data) { perror("malloc"); return 1; }

    /* Build data with same LCG as CLEAR */
    int64_t state = 42;
    for (int64_t i = 0; i < N; i++) {
        state = state * 6364136223846793005LL + (i + 1442695040888963407LL);
        int64_t raw = state % 1000;
        if (raw < 0) raw = -raw;
        data[i] = (double)raw;
    }

    struct timespec t0, t1, t2, t3;
    double accum = 0.0;

    /* ---- Test 1: Simple sum, 20 iterations ---- */
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int r = 0; r < ITER; r++) {
        accum += sum_loop(data, N);
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double sum_ms = elapsed_ms(&t0, &t1);
    long sum_hwm, sum_rss;
    read_memory(&sum_hwm, &sum_rss);

    /* ---- Test 2: Fused filter+square+sum, 20 iterations ---- */
    clock_gettime(CLOCK_MONOTONIC, &t2);
    for (int r = 0; r < ITER; r++) {
        accum += fused_loop(data, N);
    }
    clock_gettime(CLOCK_MONOTONIC, &t3);
    double fused_ms = elapsed_ms(&t2, &t3);
    long fused_hwm, fused_rss;
    read_memory(&fused_hwm, &fused_rss);

    /* Prevent DCE */
    if (accum == 0.0) { printf("unexpected zero\n"); return 1; }

    /* ---- Report ---- */
    printf("Pipeline Overhead (%d Float64 elements, %d iters) — C baseline\n", N, ITER);
    printf("\n");
    printf("Test 1: SUM only (zero-alloc, single pass)\n");
    printf("  Handwritten loop:  %.1f ms\n", sum_ms);
    printf("  RSS after:         %ld KB\n", sum_rss);
    printf("\n");
    printf("Test 2: WHERE + SELECT + SUM (fused loop)\n");
    printf("  Fused loop:        %.1f ms  RSS %ld KB\n", fused_ms, fused_rss);
    printf("\n");
    printf("  Peak RSS (VmHWM):  %ld KB\n", fused_hwm);

    free(data);
    return 0;
}
