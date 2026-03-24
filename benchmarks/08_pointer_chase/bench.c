/*
 * Pointer-Chasing Benchmark — C Baseline
 *
 * Builds a singly-linked list of N nodes in a contiguous array, then
 * wires "next" pointers using an additive prime-step permutation:
 *
 *   nodes[i].next = &nodes[(i + STEP) % N]
 *
 * N = 2,000,000.  STEP = 999983 (prime, coprime with N).
 * gcd(999983, 2000000) = 1 → the walk visits all N nodes exactly once.
 *
 * Why this defeats hardware prefetchers:
 *   - Node size = 16 bytes; the stride between consecutive accesses is
 *     STEP * 16 = 15.9 MB.
 *   - L2 cache on this machine = 8 MB; L3 = none (VM).
 *   - Working set = N * 16 bytes = 32 MB, 4× larger than L2.
 *   - Every access misses L2 and goes to DRAM.
 *   - Even a stride prefetcher cannot help: the stride (15.9 MB) is
 *     larger than the entire L2 cache — it cannot prefetch that far ahead.
 *
 * MEASURED: ~0.37 s wall time (runner.rb baseline, full process).
 * CLEAR comparison (bench.cht):
 *   - Uses @pool (CheatLib.Pool) + Id<Node> (u64) handles.
 *   - pool.get(id) adds: optional unwrap, alive check, generation check,
 *     and address arithmetic — ~4–6 extra ops vs C's 1 pointer load.
 *   - The same additive permutation is used so the access pattern is
 *     identical; any timing difference is pure indirection overhead.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <assert.h>
#include <time.h>

#define N    2000000LL
#define STEP  999983LL   /* prime, gcd(STEP, N) = 1 */

typedef struct Node {
    int64_t     val;
    struct Node *next;
} Node;

int main(void) {
    Node *nodes = malloc((size_t)N * sizeof(Node));
    assert(nodes);

    for (int64_t i = 0; i < N; i++) {
        nodes[i].val  = i;
        nodes[i].next = &nodes[(i + STEP) % N];
    }

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    /* Walk the chain: start at node[0], take N steps. */
    int64_t      sum = 0;
    const Node  *cur = &nodes[0];
    for (int64_t s = 0; s < N; s++) {
        sum += cur->val;
        cur  = cur->next;
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);

    /* sum = 0 + STEP + 2*STEP + ... (mod N) = N*(N-1)/2 */
    assert(sum > 0);
    double elapsed = (t1.tv_sec  - t0.tv_sec) +
                     (t1.tv_nsec - t0.tv_nsec) / 1e9;
    printf("sum = %ld\n", sum);
    printf("Time: %.4f seconds\n", elapsed);

    free(nodes);
    return 0;
}
