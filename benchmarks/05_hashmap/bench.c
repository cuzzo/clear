/*
 * HashMap Benchmark — C Baseline (Open-Addressing, FNV-1a + direct float key)
 *
 * Tests two variants:
 *   1. String-keyed open-addressing table with FNV-1a (original baseline)
 *   2. f64-keyed open-addressing table with integer bit-cast hash
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
 * f64-keyed variant:
 *   - Integer bit-cast hash (1 instruction on x86-64) replaces FNV-1a.
 *   - Key comparison is a single 64-bit XOR — no strcmp.
 *   - Expected to be ~2–3× faster than the string variant on insert.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <time.h>

/* Cached scale factor — resolved once, used everywhere. */
static double _bench_scale = 0.0;
static double get_bench_scale() {
    if (_bench_scale == 0.0) {
        const char *s = getenv("BENCH_SCALE");
        _bench_scale = s ? atof(s) : 1.0;
        if (_bench_scale <= 0.0) _bench_scale = 1.0;
    }
    return _bench_scale;
}

#define N_BASE   1000000
#define N        ((int)(N_BASE * get_bench_scale()))
/* 2M buckets → ~50% load factor for 1M items; power-of-2 for cheap masking */
static uint32_t next_pow2(uint32_t v) {
    v--; v |= v >> 1; v |= v >> 2; v |= v >> 4; v |= v >> 8; v |= v >> 16; v++;
    return v < 1024 ? 1024 : v;
}
static uint32_t _bench_cap = 0;
static uint32_t get_cap(void) {
    if (!_bench_cap) _bench_cap = next_pow2((uint32_t)((1u << 21) * get_bench_scale()));
    return _bench_cap;
}
#define CAP      get_cap()
#define MASK     (CAP - 1)


/* ---- String-keyed variant (FNV-1a) ---- */

static inline uint64_t fnv1a(const char *s, size_t len) {
    uint64_t h = 14695981039346656037ULL;
    for (size_t i = 0; i < len; i++) {
        h ^= (uint8_t)s[i];
        h *= 1099511628211ULL;
    }
    return h;
}

typedef struct { const char *key; double val; } StrSlot;

static inline void str_put(StrSlot *tbl, const char *key, double val) {
    uint32_t h = (uint32_t)(fnv1a(key, strlen(key)) & MASK);
    while (tbl[h].key) {
        if (strcmp(tbl[h].key, key) == 0) { tbl[h].val = val; return; }
        h = (h + 1) & MASK;
    }
    tbl[h].key = key;
    tbl[h].val = val;
}

static inline double str_get(const StrSlot *tbl, const char *key) {
    uint32_t h = (uint32_t)(fnv1a(key, strlen(key)) & MASK);
    while (tbl[h].key) {
        if (strcmp(tbl[h].key, key) == 0) return tbl[h].val;
        h = (h + 1) & MASK;
    }
    return 0.0;
}

/* ---- f64-keyed variant (bit-cast hash) ---- */

/* Mixing step prevents degenerate clusters for sequential integer-as-float keys */
static inline uint64_t f64_hash(double k) {
    uint64_t bits;
    memcpy(&bits, &k, 8);
    /* Murmur finalizer mix */
    bits ^= bits >> 33;
    bits *= 0xff51afd7ed558ccdULL;
    bits ^= bits >> 33;
    bits *= 0xc4ceb9fe1a85ec53ULL;
    bits ^= bits >> 33;
    return bits;
}

typedef struct { double key; double val; int used; } F64Slot;

static inline void f64_put(F64Slot *tbl, double key, double val) {
    uint32_t h = (uint32_t)(f64_hash(key) & MASK);
    while (tbl[h].used) {
        if (tbl[h].key == key) { tbl[h].val = val; return; }
        h = (h + 1) & MASK;
    }
    tbl[h].key = key;
    tbl[h].val = val;
    tbl[h].used = 1;
}

static inline double f64_get(const F64Slot *tbl, double key) {
    uint32_t h = (uint32_t)(f64_hash(key) & MASK);
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
    struct timespec t0, t1;

    /* Pre-generate string keys */
    char (*keys)[16] = malloc((size_t)N * 16);
    assert(keys);
    for (int i = 0; i < N; i++) snprintf(keys[i], 16, "%d", i);

    /* ---- String-keyed benchmark ---- */
    {
        StrSlot *tbl = calloc(CAP, sizeof(StrSlot));
        assert(tbl);

        clock_gettime(CLOCK_MONOTONIC, &t0);
        for (int i = 0; i < N; i++) str_put(tbl, keys[i], (double)i);
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double ins_ms = elapsed_ms(t0, t1);

        double sum = 0.0;
        clock_gettime(CLOCK_MONOTONIC, &t0);
        for (int i = 0; i < N; i++) sum += str_get(tbl, keys[i]);
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double lkp_ms = elapsed_ms(t0, t1);

        assert(sum > 0.0);
        printf("[C-1] String  Insert: %.1f ms | Lookup: %.1f ms | Total: %.1f ms\n",
               ins_ms, lkp_ms, ins_ms + lkp_ms);
        free(tbl);
    }

    /* ---- f64-keyed benchmark ---- */
    {
        F64Slot *tbl = calloc(CAP, sizeof(F64Slot));
        assert(tbl);

        clock_gettime(CLOCK_MONOTONIC, &t0);
        for (int i = 0; i < N; i++) f64_put(tbl, (double)i, (double)i);
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double ins_ms = elapsed_ms(t0, t1);

        double sum = 0.0;
        clock_gettime(CLOCK_MONOTONIC, &t0);
        for (int i = 0; i < N; i++) sum += f64_get(tbl, (double)i);
        clock_gettime(CLOCK_MONOTONIC, &t1);
        double lkp_ms = elapsed_ms(t0, t1);

        assert(sum > 0.0);
        printf("[C-2] f64-key Insert: %.1f ms | Lookup: %.1f ms | Total: %.1f ms\n",
               ins_ms, lkp_ms, ins_ms + lkp_ms);
        free(tbl);
    }

    free(keys);
    return 0;
}
