/* False Sharing Benchmark -- C
 *
 * N threads each increment their own counter M times.
 * Two layouts:
 *   1. PACKED:  counters are adjacent int64s (same cache line)
 *   2. PADDED:  each counter is on its own 64-byte cache line
 *
 * The packed layout suffers false sharing: every write invalidates
 * the cache line on all other cores, causing ~5-20x slowdown on
 * multi-core machines.
 *
 * Build: gcc -O3 -pthread bench.c -o bench_c
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <pthread.h>
#include <time.h>
#include <unistd.h>

#define MAX_THREADS 256
#define TOTAL_WORK 40000000LL

/* Packed: all counters adjacent, likely sharing cache lines */
static volatile int64_t packed_counters[MAX_THREADS];

/* Padded: each counter on its own cache line */
typedef struct {
    volatile int64_t value;
    char pad[56]; /* 64 - 8 = 56 bytes padding */
} __attribute__((aligned(64))) PaddedCounter;

static PaddedCounter padded_counters[MAX_THREADS];

typedef struct {
    int thread_id;
    int use_padded;
    int64_t increments;
} ThreadArg;

static void *worker(void *arg) {
    ThreadArg *ta = (ThreadArg *)arg;
    int id = ta->thread_id;
    int64_t n = ta->increments;

    if (ta->use_padded) {
        for (int64_t i = 0; i < n; i++) {
            padded_counters[id].value++;
        }
    } else {
        for (int64_t i = 0; i < n; i++) {
            packed_counters[id]++;
        }
    }
    return NULL;
}

static double run_test(int n_threads, int64_t increments, int use_padded) {
    pthread_t threads[MAX_THREADS];
    ThreadArg args[MAX_THREADS];

    memset((void *)packed_counters, 0, sizeof(packed_counters));
    memset(padded_counters, 0, sizeof(padded_counters));

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    for (int i = 0; i < n_threads; i++) {
        args[i].thread_id = i;
        args[i].use_padded = use_padded;
        args[i].increments = increments;
        pthread_create(&threads[i], NULL, worker, &args[i]);
    }
    for (int i = 0; i < n_threads; i++) {
        pthread_join(threads[i], NULL);
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);
    double elapsed = (t1.tv_sec - t0.tv_sec) * 1000.0
                   + (t1.tv_nsec - t0.tv_nsec) / 1e6;

    /* Verify */
    int64_t total = 0;
    for (int i = 0; i < n_threads; i++) {
        total += use_padded ? padded_counters[i].value : packed_counters[i];
    }
    int64_t expected = (int64_t)n_threads * increments;
    if (total != expected) {
        fprintf(stderr, "ERROR: total=%ld expected=%ld\n", total, expected);
    }

    return elapsed;
}

int main(void) {
    int n_threads = (int)sysconf(_SC_NPROCESSORS_ONLN);
    if (n_threads > MAX_THREADS) n_threads = MAX_THREADS;
    int64_t increments = TOTAL_WORK / n_threads;

    /* Warm up */
    run_test(n_threads, increments, 0);
    run_test(n_threads, increments, 1);

    /* Packed (false sharing) */
    double packed_ms = run_test(n_threads, increments, 0);

    /* Padded (no false sharing) */
    double padded_ms = run_test(n_threads, increments, 1);

    double ratio = packed_ms / padded_ms;

    /* BENCH_RESULT = padded (no false sharing, no mutex baseline) */
    printf("BENCH_RESULT: %.0f ms\n", padded_ms);
    printf("False-sharing (%d threads x %ld iters)\n", n_threads, increments);
    printf("  Packed (false sharing):  %.1f ms\n", packed_ms);
    printf("  Padded (no false share): %.1f ms\n", padded_ms);
    printf("  Slowdown:                %.1fx\n", ratio);

    return 0;
}
