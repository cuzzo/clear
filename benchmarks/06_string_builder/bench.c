/*
 * StringBuilder Benchmark — C StringBuilder vs CLEAR List+join
 *
 * WHAT WE ARE MEASURING:
 *   Both sides do the same logical work:
 *     - 10 000 runs
 *     - Each run: append 1 000 pieces to a growing string, then use the result
 *
 *   C strategy: geometric growth (double capacity when full).
 *     Classic amortised-O(1)-per-append pattern; O(N) total copies per run.
 *     This is the fairest comparison to CLEAR's List+join, which also does
 *     O(N) total copies (collect into list, then one pass to join).
 *
 *   CLEAR strategy: append to String[]@list, then join(parts, "").
 *     The @list is frame-allocated (bump pointer). saveLoopMark/restoreLoopMark
 *     rewinds the arena each iteration, keeping memory O(1) across runs.
 *
 * WHY OTHER C STRATEGIES ARE NOT THE BASELINE:
 *   GPA-accumulate (malloc each concat):  O(N²) copies — CLEAR equivalent would
 *     be naive string concat, not List+join. Not a fair comparison.
 *   Realloc (realloc every concat):       same O(N²) issue on most allocators.
 *   Pre-alloc (know length up front):     cheats by computing total length first.
 *     CLEAR doesn't have this option without two passes.
 *
 * PARAMETERS:
 *   N    = 1 000 appends per run  (builds a ~5 KB string)
 *   RUNS = 10 000 runs            (10 M total append calls)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <assert.h>

#define N    1000
#define RUNS 10000

static const char *pieces[] = {
    "alpha", "beta_x", "gamma_", "delta",
    "epsilon", "zeta_y", "eta_12", "theta",
};
#define NPIECES (sizeof(pieces) / sizeof(pieces[0]))

static double elapsed_ms(struct timespec a, struct timespec b) {
    return (b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6;
}

int main(void) {
    struct timespec t0, t1;
    volatile size_t total = 0;

    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int r = 0; r < RUNS; r++) {
        size_t cap = 64;
        size_t len = 0;
        char *s = malloc(cap);
        assert(s);

        for (int i = 0; i < N; i++) {
            const char *p = pieces[i % NPIECES];
            size_t plen = strlen(p);
            while (len + plen + 1 > cap) cap *= 2;
            s = realloc(s, cap);
            assert(s);
            memcpy(s + len, p, plen);
            len += plen;
        }
        s[len] = '\0';
        total += len;
        free(s);
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);

    printf("total_bytes=%zu\nTime: %.4f seconds\n",
           (size_t)(total / RUNS), elapsed_ms(t0, t1) / 1000.0);
    return 0;
}
