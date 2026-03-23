/*
 * HashMap Benchmark — C Baseline (Open-Addressing, FNV-1a)
 *
 * WHY THIS IS THE FASTEST PRACTICAL C:
 *   - Single heap allocation for the bucket array (no per-key malloc).
 *     C advantage: keys are kept as pointers into a pre-allocated buffer;
 *     the map never copies the key bytes. CLEAR must heap-dupe every key.
 *   - FNV-1a: 1–3 ns per hash, one branch per comparison (cache-friendly).
 *   - Open addressing + linear probing: maximum cache locality on lookup.
 *   - No locking, no error-union checks, no GPA bookkeeping.
 *   - Table pre-sized to 2× next power-of-two so no rehash ever occurs.
 *
 * ADVANTAGES OVER CLEAR's @map (current state):
 *   1. Zero per-key malloc   — CLEAR dupes every key string to GPA heap.
 *   2. Zero rehash copies    — CLEAR's std.StringHashMapUnmanaged grows
 *      geometrically, triggering ~20 bucket-array heap allocs for 1M keys.
 *   3. No error-union checks — CLEAR wraps every put in `try`.
 *
 * Expected: 1M inserts + 1M lookups in ~200–350 ms.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <time.h>

#define N        1000000
/* 2M buckets → ~50% load factor for 1M items; power-of-2 for cheap masking */
#define CAP      (1u << 21)
#define MASK     (CAP - 1u)

/* FNV-1a 64-bit */
static inline uint64_t fnv1a(const char *s, size_t len) {
    uint64_t h = 14695981039346656037ULL;
    for (size_t i = 0; i < len; i++) {
        h ^= (uint8_t)s[i];
        h *= 1099511628211ULL;
    }
    return h;
}

typedef struct { const char *key; double val; } Slot;

static inline void ht_put(Slot *tbl, const char *key, double val) {
    uint32_t h = (uint32_t)(fnv1a(key, strlen(key)) & MASK);
    while (tbl[h].key) {
        if (strcmp(tbl[h].key, key) == 0) { tbl[h].val = val; return; }
        h = (h + 1) & MASK;
    }
    tbl[h].key = key;
    tbl[h].val = val;
}

static inline double ht_get(const Slot *tbl, const char *key) {
    uint32_t h = (uint32_t)(fnv1a(key, strlen(key)) & MASK);
    while (tbl[h].key) {
        if (strcmp(tbl[h].key, key) == 0) return tbl[h].val;
        h = (h + 1) & MASK;
    }
    return 0.0;
}

int main(void) {
    /* Pre-generate all key strings — one allocation, no per-key duplication. */
    char (*keys)[8] = malloc((size_t)N * 8);
    assert(keys);
    for (int i = 0; i < N; i++) snprintf(keys[i], 8, "%d", i);

    /* Single heap allocation for the bucket array. */
    Slot *tbl = calloc(CAP, sizeof(Slot));
    assert(tbl);

    struct timespec t0, t1;

    /* ---- INSERT ---- */
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < N; i++) ht_put(tbl, keys[i], (double)i);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double ins_ms = (t1.tv_sec - t0.tv_sec) * 1e3 +
                    (t1.tv_nsec - t0.tv_nsec) / 1e6;

    /* ---- LOOKUP ---- */
    double sum = 0.0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < N; i++) sum += ht_get(tbl, keys[i]);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double lkp_ms = (t1.tv_sec - t0.tv_sec) * 1e3 +
                    (t1.tv_nsec - t0.tv_nsec) / 1e6;

    assert(sum > 0.0);
    printf("sum = %.0f\n", sum);
    printf("Insert: %.1f ms | Lookup: %.1f ms | Total: %.1f ms\n",
           ins_ms, lkp_ms, ins_ms + lkp_ms);

    free(tbl);
    free(keys);
    return 0;
}
