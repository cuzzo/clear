/*
 * Benchmark 23: Pipeline Overhead — C Baseline
 *
 * Test 1: Simple sum (handwritten + pipeline-equivalent), 20 iterations.
 * Test 2: Fused filter+square+sum (handwritten + pipeline-equivalent), 20 iterations.
 * Test 3: 4-stage filter+double+filter+sum (handwritten + pipeline-equivalent), 20 iterations.
 *
 * All 6 timed loops match CLEAR's 6 timed loops for apples-to-apples comparison.
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
    for (int64_t i = 0; i < n; i++) sum += data[i];
    return sum;
}

static double fused_loop(const double *data, int64_t n) {
    double sum = 0.0;
    for (int64_t i = 0; i < n; i++) {
        double v = data[i];
        if (v > 500.0) sum += v * v;
    }
    return sum;
}

static double long_fused_loop(const double *data, int64_t n) {
    double sum = 0.0;
    for (int64_t i = 0; i < n; i++) {
        double v = data[i];
        if (v > 200.0) {
            double doubled = v * 2.0;
            if (doubled < 1500.0) sum += doubled;
        }
    }
    return sum;
}

int main(void) {
    double *data = malloc(N * sizeof(double));
    if (!data) { perror("malloc"); return 1; }

    int64_t state = 42;
    for (int64_t i = 0; i < N; i++) {
        state = state * 6364136223846793005LL + (i + 1442695040888963407LL);
        int64_t raw = state % 1000;
        if (raw < 0) raw = -raw;
        data[i] = (double)raw;
    }

    struct timespec t0, t1, t2, t3, t4, t5;
    double accum = 0.0;

    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int r = 0; r < ITER; r++) accum += sum_loop(data, N);
    clock_gettime(CLOCK_MONOTONIC, &t1);

    clock_gettime(CLOCK_MONOTONIC, &t2);
    for (int r = 0; r < ITER; r++) accum += fused_loop(data, N);
    clock_gettime(CLOCK_MONOTONIC, &t3);

    clock_gettime(CLOCK_MONOTONIC, &t4);
    for (int r = 0; r < ITER; r++) accum += long_fused_loop(data, N);
    clock_gettime(CLOCK_MONOTONIC, &t5);

    if (accum == 0.0) { printf("unexpected zero\n"); return 1; }

    long hwm, rss;
    read_memory(&hwm, &rss);

    double sum_ms   = elapsed_ms(&t0, &t1);
    double fused_ms = elapsed_ms(&t2, &t3);
    double long_ms  = elapsed_ms(&t4, &t5);

    /* BENCH_RESULT = sum loop (cross-language baseline for CLEAR pipeline comparison) */
    printf("BENCH_RESULT: %.0f ms\n", sum_ms);
    printf("Pipeline overhead (%d elements x %d iters) -- C baseline\n", N, ITER);
    printf("  Sum loop (handwritten):    %.0f ms\n", sum_ms);
    printf("  Fused loop (2-stage):      %.0f ms\n", fused_ms);
    printf("  Fused loop (4-stage):      %.0f ms\n", long_ms);
    printf("  Peak RSS: %ld KB\n", hwm);

    free(data);
    return 0;
}
