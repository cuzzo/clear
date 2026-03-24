/*
 * StringBuilder Benchmark — C baselines
 *
 * Three C strategies for comparison with CLEAR's frame-concat approach:
 *
 *   1. GPA-accumulate: malloc a new buffer each concat, don't free the old one
 *      until the end.  Simulates CLEAR's frame model but with GPA cost instead
 *      of a bump-pointer — isolates the allocator overhead from the copy cost.
 *
 *   2. Realloc: realloc the buffer on every concat (the naive C approach).
 *      Frees the old allocation implicitly; best-case extends in place.
 *
 *   3. StringBuilder: geometric growth (double capacity when full).
 *      Classic amortised-O(1)-per-append pattern; effectively zero alloc cost
 *      on the hot path after the first few doublings.
 *
 *   4. Pre-alloc: compute total length up front, single malloc, memcpy all pieces.
 *      Theoretical floor — zero realloc cost, optimal memcpy.
 *
 * N    = 1 000  concats per run   (builds a ~7 KB string)
 * RUNS = 1 000  timed runs
 *
 * Frame memory for CLEAR's naive concat:
 *   sum(piece_len, 2*piece_len, ..., N*piece_len) = piece_len * N*(N+1)/2 ≈ 3.5 MB
 *   → fits comfortably in an 8 MB arena, reset between runs.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <assert.h>

#define N    1000
#define RUNS 1000

static const char *pieces[] = {
    "alpha", "beta_x", "gamma_", "delta",
    "epsilon", "zeta_y", "eta_12", "theta",
};
#define NPIECES (sizeof(pieces) / sizeof(pieces[0]))

static double elapsed_ms(struct timespec a, struct timespec b) {
    return (b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6;
}

/* Compute the total length of one run (N concats) so we can pre-alloc */
static size_t total_len_per_run(void) {
    size_t len = 0;
    for (int i = 0; i < N; i++) len += strlen(pieces[i % NPIECES]);
    return len;
}

int main(void) {
    struct timespec t0, t1;
    volatile size_t total = 0; /* prevent dead-code elimination */

    /* ================================================================
     * 1. GPA-accumulate: malloc each concat, don't free old until end
     *    Closest analogy to CLEAR's frame model — same copy pattern,
     *    but GPA cost per alloc instead of bump-pointer.
     * ================================================================ */
    {
        /* Track all allocations so we can free at end of each run */
        char **allocs = malloc(sizeof(char *) * (N + 1));
        assert(allocs);

        clock_gettime(CLOCK_MONOTONIC, &t0);
        for (int r = 0; r < RUNS; r++) {
            int nallocs = 0;
            char *s = malloc(1);
            s[0] = '\0';
            size_t slen = 0;
            allocs[nallocs++] = s;

            for (int i = 0; i < N; i++) {
                const char *p = pieces[i % NPIECES];
                size_t plen = strlen(p);
                char *ns = malloc(slen + plen + 1);
                assert(ns);
                memcpy(ns, s, slen);
                memcpy(ns + slen, p, plen + 1);
                slen += plen;
                s = ns;
                allocs[nallocs++] = ns;
            }
            total += slen;

            for (int j = 0; j < nallocs; j++) free(allocs[j]);
        }
        clock_gettime(CLOCK_MONOTONIC, &t1);
        free(allocs);
        printf("[C-1] GPA-accum   : %.1f ms total | %.3f ms/run | %zu final bytes\n",
               elapsed_ms(t0, t1), elapsed_ms(t0, t1) / RUNS, total / RUNS);
    }

    total = 0;

    /* ================================================================
     * 2. Realloc: realloc buffer on every concat
     *    Standard naive-C pattern.  realloc may extend in-place or
     *    malloc+memcpy+free.
     * ================================================================ */
    {
        clock_gettime(CLOCK_MONOTONIC, &t0);
        for (int r = 0; r < RUNS; r++) {
            char *s = malloc(1);
            s[0] = '\0';
            size_t slen = 0;

            for (int i = 0; i < N; i++) {
                const char *p = pieces[i % NPIECES];
                size_t plen = strlen(p);
                s = realloc(s, slen + plen + 1);
                assert(s);
                memcpy(s + slen, p, plen + 1);
                slen += plen;
            }
            total += slen;
            free(s);
        }
        clock_gettime(CLOCK_MONOTONIC, &t1);
        printf("[C-2] Realloc     : %.1f ms total | %.3f ms/run | %zu final bytes\n",
               elapsed_ms(t0, t1), elapsed_ms(t0, t1) / RUNS, total / RUNS);
    }

    total = 0;

    /* ================================================================
     * 3. StringBuilder: geometric growth (double capacity when full)
     *    Amortised O(1) per append.  Hot-path is just memcpy + len++.
     * ================================================================ */
    {
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
        printf("[C-3] StringBuilder: %.1f ms total | %.3f ms/run | %zu final bytes\n",
               elapsed_ms(t0, t1), elapsed_ms(t0, t1) / RUNS, total / RUNS);
    }

    total = 0;

    /* ================================================================
     * 4. Pre-alloc: single malloc with exact final size
     *    Theoretical minimum — zero realloc overhead.
     * ================================================================ */
    {
        size_t final_len = total_len_per_run();

        clock_gettime(CLOCK_MONOTONIC, &t0);
        for (int r = 0; r < RUNS; r++) {
            char *s = malloc(final_len + 1);
            assert(s);
            size_t pos = 0;
            for (int i = 0; i < N; i++) {
                const char *p = pieces[i % NPIECES];
                size_t plen = strlen(p);
                memcpy(s + pos, p, plen);
                pos += plen;
            }
            s[pos] = '\0';
            total += pos;
            free(s);
        }
        clock_gettime(CLOCK_MONOTONIC, &t1);
        printf("[C-4] Pre-alloc   : %.1f ms total | %.3f ms/run | %zu final bytes\n",
               elapsed_ms(t0, t1), elapsed_ms(t0, t1) / RUNS, total / RUNS);
    }

    return 0;
}
