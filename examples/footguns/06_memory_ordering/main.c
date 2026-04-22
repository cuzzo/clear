/*
 * Footgun: Memory Ordering — C
 *
 * C11 atomics expose the full memory-order hierarchy. Using
 * memory_order_relaxed on a "publish flag" pattern is correct on x86
 * (which has a strong memory model) but silently broken on ARM, POWER,
 * and RISC-V (weak models). The bug disappears on most developer machines
 * and only surfaces on the hardware it ships to.
 *
 * Pattern: producer writes data, then sets a flag. Consumer polls the
 * flag, then reads data. With relaxed ordering, the CPU may reorder the
 * consumer's flag-read before its data-read, so it sees flag=1 but
 * reads stale data (or worse: partially-written data).
 */

#include <stdatomic.h>
#include <stdio.h>
#include <pthread.h>
#include <string.h>

#define MSG_LEN 64

static char     message[MSG_LEN];
static atomic_int ready_broken  = 0; /* wrong: relaxed */
static atomic_int ready_correct = 0; /* correct: release/acquire */

/* ---- BROKEN: relaxed ordering ---- */

static void *producer_broken(void *arg) {
    (void)arg;
    strncpy(message, "hello from producer", MSG_LEN);
    /* relaxed: CPU/compiler may reorder this store before the strcpy
     * is visible to other cores on weakly-ordered hardware. */
    atomic_store_explicit(&ready_broken, 1, memory_order_relaxed);
    return NULL;
}

static void *consumer_broken(void *arg) {
    (void)arg;
    while (!atomic_load_explicit(&ready_broken, memory_order_relaxed))
        ; /* spin */
    /* On ARM/POWER: may read stale or empty message even though
     * ready_broken == 1, because no ordering barrier exists. */
    printf("broken:  '%s'\n", message);
    return NULL;
}

/* ---- CORRECT: release/acquire ordering ---- */

static void *producer_correct(void *arg) {
    (void)arg;
    strncpy(message, "hello from producer", MSG_LEN);
    /* release: all prior stores are visible before this store. */
    atomic_store_explicit(&ready_correct, 1, memory_order_release);
    return NULL;
}

static void *consumer_correct(void *arg) {
    (void)arg;
    while (!atomic_load_explicit(&ready_correct, memory_order_acquire))
        ; /* spin */
    /* acquire: all stores from the releasing thread are now visible.
     * Guaranteed to see the strncpy result on all architectures. */
    printf("correct: '%s'\n", message);
    return NULL;
}

int main(void) {
    pthread_t prod, cons;

    /* Broken run */
    memset(message, 0, MSG_LEN);
    pthread_create(&cons, NULL, consumer_broken, NULL);
    pthread_create(&prod, NULL, producer_broken, NULL);
    pthread_join(prod, NULL);
    pthread_join(cons, NULL);

    /* Correct run */
    memset(message, 0, MSG_LEN);
    pthread_create(&cons, NULL, consumer_correct, NULL);
    pthread_create(&prod, NULL, producer_correct, NULL);
    pthread_join(prod, NULL);
    pthread_join(cons, NULL);

    return 0;
}

/*
 * Compile: gcc -pthread -O2 -o memord main.c && ./memord
 *
 * On x86: both likely print correctly (strong memory model masks the bug).
 * On ARM/POWER: broken version may print empty string or garbage.
 * TSan does NOT detect this — it is not a data race, it is a happens-before
 * violation that only manifests on weakly-ordered hardware.
 *
 * Rule: always use release/acquire (or seq_cst) for publish-flag patterns.
 * Use relaxed only for counters where you never make decisions on the value.
 */
