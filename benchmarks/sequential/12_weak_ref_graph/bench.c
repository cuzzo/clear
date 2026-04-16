/*
 * Weak-Reference Graph Benchmark — C Baseline
 *
 * Builds a binary tree of N nodes (BFS order in a flat array).
 * Each child stores a back-pointer to its parent.
 *
 * In C, the back-pointer is a raw pointer — zero overhead.
 * In CLEAR, children are @multiowned (Rc) and the parent back-pointer
 * is @link (WeakRc), paying downgrade/upgrade/release costs.
 *
 * Two timed phases:
 *   1. BUILD: Allocate N nodes via individual malloc (one control block per
 *      node, matching CLEAR's rcCreate). Wire child indices + parent
 *      back-pointers. Each non-root node gets one "downgrade" (LINK).
 *   2. WALK:  BFS scan that resolves every parent back-pointer and
 *             accumulates a checksum.
 *
 * N = 2,000,000 nodes.
 *
 * The BUILD phase uses per-node malloc (not a flat array) so the
 * allocation profile matches CLEAR's rcCreate, which does one
 * heap allocation per control block.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <assert.h>
#include <time.h>

#define N 200000

typedef struct Node {
    int64_t       id;
    struct Node  *parent;   /* back-pointer (would be @link in CLEAR) */
    int64_t       left;     /* index into nodes[], -1 = none */
    int64_t       right;
} Node;

static double elapsed_ms(struct timespec *t0, struct timespec *t1) {
    return (t1->tv_sec - t0->tv_sec) * 1000.0 +
           (t1->tv_nsec - t0->tv_nsec) / 1e6;
}

int main(void) {
    struct timespec t0, t1, t2, t3;

    /* --- Phase 1: BUILD --- */
    clock_gettime(CLOCK_MONOTONIC, &t0);

    /* Per-node malloc to match CLEAR's rcCreate allocation profile */
    Node **nodes = malloc(N * sizeof(Node *));
    assert(nodes);
    for (int64_t i = 0; i < N; i++) {
        nodes[i] = malloc(sizeof(Node));
        nodes[i]->id     = i;
        nodes[i]->parent = NULL;
        nodes[i]->left   = -1;
        nodes[i]->right  = -1;
    }

    /* Wire parent-child + back-pointers (BFS tree layout) */
    for (int64_t i = 0; i < N; i++) {
        int64_t l = 2 * i + 1;
        int64_t r = 2 * i + 2;
        if (l < N) {
            nodes[i]->left   = l;
            nodes[l]->parent = nodes[i];   /* "LINK" in CLEAR */
        }
        if (r < N) {
            nodes[i]->right  = r;
            nodes[r]->parent = nodes[i];
        }
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);

    /* --- Phase 2: WALK — resolve every parent back-pointer --- */
    int64_t checksum = 0;
    for (int64_t i = 0; i < N; i++) {
        checksum += nodes[i]->id;

        /* "RESOLVE" in CLEAR: dereference parent back-pointer */
        if (nodes[i]->parent != NULL) {
            checksum += nodes[i]->parent->id;
        }
    }

    clock_gettime(CLOCK_MONOTONIC, &t2);

    /* --- Cleanup --- */
    for (int64_t i = 0; i < N; i++) {
        free(nodes[i]);
    }
    free(nodes);

    clock_gettime(CLOCK_MONOTONIC, &t3);

    assert(checksum > 0);
    double build_ms = elapsed_ms(&t0, &t1);
    double walk_ms  = elapsed_ms(&t1, &t2);
    double free_ms  = elapsed_ms(&t2, &t3);
    double total_ms = elapsed_ms(&t0, &t3);

    /* BENCH_RESULT = total (build + walk + free) */
    printf("BENCH_RESULT: %.0f ms\n", total_ms);
    printf("Weak-reference graph (%d nodes)\n", N);
    printf("  build:    %.1f ms\n", build_ms);
    printf("  walk:     %.1f ms\n", walk_ms);
    printf("  free:     %.1f ms\n", free_ms);
    printf("  total:    %.1f ms\n", total_ms);

    return 0;
}
