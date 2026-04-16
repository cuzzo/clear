/*
 * Benchmark 21: Frame vs Heap Escape — C Baseline
 *
 * Variant A (stack):  snprintf into a stack buffer each iteration.
 *                     No malloc — analogous to CLEAR's frame allocation.
 * Variant B (heap):   malloc + snprintf + free each iteration.
 *                     Analogous to CLEAR's heap-promoted (escape) path.
 *
 * Both variants build the string "item-N-value" for N in [0, 100000)
 * and sum the string lengths.
 *
 * Build: gcc -O2 -o bench_c bench.c
 * Run:   ./bench_c
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <assert.h>

#define N 1000000

static double elapsed_ms(struct timespec a, struct timespec b) {
    return (b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6;
}

static void read_memory(long *hwm_kb, long *rss_kb) {
    *hwm_kb = 0;
    *rss_kb = 0;
    FILE *f = fopen("/proc/self/status", "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, "VmHWM:", 6) == 0)
            *hwm_kb = strtol(line + 6, NULL, 10);
        else if (strncmp(line, "VmRSS:", 6) == 0)
            *rss_kb = strtol(line + 6, NULL, 10);
    }
    fclose(f);
}

/* Variant A: stack buffer, no heap allocation */
static int64_t bench_stack(int n) {
    int64_t total = 0;
    for (int i = 0; i < n; i++) {
        char buf[64];
        int len = snprintf(buf, sizeof(buf), "item-%d-value", i);
        total += len;
    }
    return total;
}

/* Variant B: malloc + free each iteration */
static int64_t bench_heap(int n) {
    int64_t total = 0;
    for (int i = 0; i < n; i++) {
        char buf[64];
        int len = snprintf(buf, sizeof(buf), "item-%d-value", i);
        char *s = malloc(len + 1);
        assert(s);
        memcpy(s, buf, len + 1);
        total += len;
        free(s);
    }
    return total;
}

int main(void) {
    struct timespec t0, t1, t2;
    long hwm_kb, rss_kb;

    /* Warm up */
    bench_stack(1000);
    bench_heap(1000);

    /* Variant A: stack */
    clock_gettime(CLOCK_MONOTONIC, &t0);
    int64_t stack_total = bench_stack(N);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    long stack_rss;
    read_memory(&hwm_kb, &stack_rss);
    double stack_ms = elapsed_ms(t0, t1);

    /* Variant B: heap */
    clock_gettime(CLOCK_MONOTONIC, &t1);
    int64_t heap_total = bench_heap(N);
    clock_gettime(CLOCK_MONOTONIC, &t2);
    long heap_rss;
    read_memory(&hwm_kb, &heap_rss);
    double heap_ms = elapsed_ms(t1, t2);

    assert(stack_total == heap_total);

    read_memory(&hwm_kb, &rss_kb);
    /* BENCH_RESULT = stack (no-malloc) path — mirrors CLEAR's frame path */
    printf("BENCH_RESULT: %.0f ms\n", stack_ms);
    printf("Frame vs Heap Escape (%d iterations) — C baseline\n", N);
    printf("  Stack (no malloc):  %.0f ms  RSS %ld KB\n", stack_ms, stack_rss);
    printf("  Heap  (malloc):     %.0f ms  RSS %ld KB\n", heap_ms, heap_rss);
    printf("  Heap overhead:      %.0f ms  (%.0f%% slower)\n",
           heap_ms - stack_ms, (heap_ms / stack_ms - 1.0) * 100.0);
    printf("  Peak RSS (VmHWM):   %ld KB\n", hwm_kb);
    return 0;
}
