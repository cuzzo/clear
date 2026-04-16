/*
 * HashMap Benchmark — C Baseline
 *
 * Open-addressing hashmap with i64 keys and f64 values.
 * 1M inserts followed by 1M lookups. Pre-sized to 2M buckets
 * (50% load factor) — no rehash occurs.
 *
 * Hash: Murmur finalizer mix on the raw i64 bits.
 * Single calloc for the bucket array; no per-key allocation.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <time.h>

#define N    1000000
#define CAP  2097152   /* next power-of-two above 2*N */
#define MASK (CAP - 1)

typedef struct { int64_t key; double val; int used; } Slot;

static inline uint64_t hash_i64(int64_t k) {
    uint64_t h = (uint64_t)k;
    h ^= h >> 33;
    h *= 0xff51afd7ed558ccdULL;
    h ^= h >> 33;
    h *= 0xc4ceb9fe1a85ec53ULL;
    h ^= h >> 33;
    return h;
}

static inline void map_put(Slot *tbl, int64_t key, double val) {
    uint32_t h = (uint32_t)(hash_i64(key) & MASK);
    while (tbl[h].used && tbl[h].key != key) h = (h + 1) & MASK;
    tbl[h].key = key; tbl[h].val = val; tbl[h].used = 1;
}

static inline double map_get(const Slot *tbl, int64_t key) {
    uint32_t h = (uint32_t)(hash_i64(key) & MASK);
    while (tbl[h].used) {
        if (tbl[h].key == key) return tbl[h].val;
        h = (h + 1) & MASK;
    }
    return 0.0;
}

static double elapsed_ms(struct timespec a, struct timespec b) {
    return (b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6;
}

int main(void) {
    Slot *tbl = calloc(CAP, sizeof(Slot));
    assert(tbl);

    struct timespec t0, t1;

    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int64_t i = 0; i < N; i++) map_put(tbl, i, (double)i);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double ins_ms = elapsed_ms(t0, t1);

    double sum = 0.0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int64_t i = 0; i < N; i++) sum += map_get(tbl, i);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double lkp_ms = elapsed_ms(t0, t1);

    assert(sum > 0.0);
    free(tbl);

    printf("BENCH_RESULT: %.0f ms\n", ins_ms + lkp_ms);
    printf("Insert: %.1f ms | Lookup: %.1f ms | Total: %.1f ms\n",
           ins_ms, lkp_ms, ins_ms + lkp_ms);
    return 0;
}
