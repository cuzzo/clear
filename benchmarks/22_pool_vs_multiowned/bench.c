// Benchmark 22: Pool vs Pointer-based — Insert Cost (C baseline)
//
// Variant A (pool-like): Pre-allocate a contiguous array, fill sequentially.
// Variant B (pointer-based): malloc each entity, store pointers in an array.
//
// Compile: gcc -O2 -o bench_c bench.c
// Run:     ./bench_c

#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <string.h>

#define N 1000000

typedef struct {
    long x;
    long y;
    long health;
} Entity;

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

// Variant A: contiguous array (pool-like)
static long bench_pool(void) {
    Entity *pool = malloc(N * sizeof(Entity));
    if (!pool) { perror("malloc"); exit(1); }

    for (long i = 0; i < N; i++) {
        pool[i] = (Entity){ .x = i, .y = i * 2, .health = 100 };
    }

    long count = N;
    free(pool);
    return count;
}

// Variant B: individual mallocs (pointer-based, like ref-counted)
static long bench_pointer(void) {
    Entity **ptrs = malloc(N * sizeof(Entity *));
    if (!ptrs) { perror("malloc"); exit(1); }

    for (long i = 0; i < N; i++) {
        ptrs[i] = malloc(sizeof(Entity));
        if (!ptrs[i]) { perror("malloc"); exit(1); }
        *ptrs[i] = (Entity){ .x = i, .y = i * 2, .health = 100 };
    }

    long count = N;

    for (long i = 0; i < N; i++) {
        free(ptrs[i]);
    }
    free(ptrs);
    return count;
}

int main(void) {
    struct timespec t0, t1, t2;
    long hwm, rss;

    // Variant A: pool-like
    clock_gettime(CLOCK_MONOTONIC, &t0);
    long pool_count = bench_pool();
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double pool_ms = elapsed_ms(&t0, &t1);
    long pool_hwm, pool_rss;
    read_memory(&pool_hwm, &pool_rss);

    // Variant B: pointer-based
    clock_gettime(CLOCK_MONOTONIC, &t1);
    long ptr_count = bench_pointer();
    clock_gettime(CLOCK_MONOTONIC, &t2);
    double ptr_ms = elapsed_ms(&t1, &t2);
    long ptr_hwm, ptr_rss;
    read_memory(&ptr_hwm, &ptr_rss);

    printf("Pool vs Pointer insert (%d entities) — C baseline\n", N);
    printf("  Pool (contiguous):   %.1f ms  RSS %ld KB\n", pool_ms, pool_rss);
    printf("  Pointer (scattered): %.1f ms  RSS %ld KB\n", ptr_ms, ptr_rss);
    printf("  Peak RSS (VmHWM):    %ld KB\n", ptr_hwm);
    printf("  pool_count=%ld  ptr_count=%ld\n", pool_count, ptr_count);

    return 0;
}
