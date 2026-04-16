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
#include <assert.h>

#define N 5000000

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

// Variant A: contiguous array (mirrors CLEAR @list)
static long bench_array(void) {
    Entity *arr = malloc(N * sizeof(Entity));
    if (!arr) { perror("malloc"); exit(1); }

    for (long i = 0; i < N; i++)
        arr[i] = (Entity){ .x = i, .y = i * 2, .health = 100 };

    long sum = 0;
    for (long i = 0; i < N; i++)
        sum += arr[i].health;

    free(arr);
    return sum;
}

// Variant B: individual mallocs per entity (mirrors CLEAR @pool generational overhead)
static long bench_pointer(void) {
    Entity **ptrs = malloc(N * sizeof(Entity *));
    if (!ptrs) { perror("malloc"); exit(1); }

    for (long i = 0; i < N; i++) {
        ptrs[i] = malloc(sizeof(Entity));
        if (!ptrs[i]) { perror("malloc"); exit(1); }
        *ptrs[i] = (Entity){ .x = i, .y = i * 2, .health = 100 };
    }

    long sum = 0;
    for (long i = 0; i < N; i++)
        sum += ptrs[i]->health;

    for (long i = 0; i < N; i++)
        free(ptrs[i]);
    free(ptrs);
    return sum;
}

int main(void) {
    struct timespec t0, t1, t2;
    long hwm, rss;

    // Variant A: contiguous array (BENCH_RESULT = this path)
    clock_gettime(CLOCK_MONOTONIC, &t0);
    long arr_sum = bench_array();
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double arr_ms = elapsed_ms(&t0, &t1);
    long arr_hwm, arr_rss;
    read_memory(&arr_hwm, &arr_rss);

    // Variant B: individual mallocs
    clock_gettime(CLOCK_MONOTONIC, &t1);
    long ptr_sum = bench_pointer();
    clock_gettime(CLOCK_MONOTONIC, &t2);
    double ptr_ms = elapsed_ms(&t1, &t2);
    long ptr_hwm, ptr_rss;
    read_memory(&ptr_hwm, &ptr_rss);

    assert(arr_sum == ptr_sum);

    printf("BENCH_RESULT: %.0f ms\n", arr_ms);
    printf("Pool vs List (%d entities, insert + sum health) -- C baseline\n", N);
    printf("  Array (dense):   %.1f ms  RSS %ld KB\n", arr_ms, arr_rss);
    printf("  Pointer (N mallocs): %.1f ms  RSS %ld KB\n", ptr_ms, ptr_rss);
    printf("  Pointer overhead: %.0f ms\n", ptr_ms - arr_ms);
    printf("  Peak RSS (VmHWM): %ld KB\n", ptr_hwm);

    return 0;
}
