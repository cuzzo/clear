/*
 * Footgun: Causal Message Ordering — C
 *
 * Causal ordering: if event A caused event B (A happened-before B in the
 * logical sense), any observer must see A before B. FIFO channels preserve
 * per-sender order, but they provide no causal ordering across senders.
 *
 * Classic violation:
 *   Producer writes data to shared memory, then posts "data ready" to relay.
 *   Relay reads "data ready", then forwards "go" to consumer.
 *   Consumer receives "go", then reads shared memory.
 *   On weakly-ordered hardware (or with relaxed atomics), consumer may
 *   read stale shared memory even though it received "go" after "data ready".
 *
 * The causal chain:  write → "data ready" → "go" → read
 * requires explicit barriers at every hop to be safe.
 */

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

#define MSG 64

static char     shared_data[MSG];
static atomic_int stage = 0; /* 0=init, 1=data ready, 2=go */

/* Producer: writes data, then signals "data ready". */
static void *producer(void *arg) {
    (void)arg;
    strncpy(shared_data, "important result", MSG);
    /* BROKEN: relaxed store — no guarantee shared_data write is visible
     * to the consumer before stage==2 is observed on weak hardware. */
    atomic_store_explicit(&stage, 1, memory_order_relaxed);
    return NULL;
}

/* Relay: waits for "data ready", forwards "go". */
static void *relay(void *arg) {
    (void)arg;
    while (atomic_load_explicit(&stage, memory_order_relaxed) < 1) ;
    /* No barrier here: the write to shared_data may not be visible yet
     * when we forward "go". Causal chain is broken. */
    atomic_store_explicit(&stage, 2, memory_order_relaxed);
    return NULL;
}

/* Consumer: waits for "go", then reads data. */
static void *consumer(void *arg) {
    (void)arg;
    while (atomic_load_explicit(&stage, memory_order_relaxed) < 2) ;
    /* May see stale shared_data on ARM/POWER even though we received
     * "go" after "data ready" after the actual write. The causal chain
     * of messages did not carry the happens-before guarantee. */
    printf("consumer saw: '%s'\n", shared_data);
    return NULL;
}

int main(void) {
    pthread_t p, r, c;
    pthread_create(&c, NULL, consumer, NULL);
    pthread_create(&r, NULL, relay,    NULL);
    pthread_create(&p, NULL, producer, NULL);
    pthread_join(p, NULL);
    pthread_join(r, NULL);
    pthread_join(c, NULL);
    return 0;
}

/*
 * Fix: use memory_order_release on every store and memory_order_acquire
 * on every load that is part of the causal chain. Each hop in the relay
 * must establish happens-before, not just logical ordering of integers.
 *
 *   atomic_store_explicit(&stage, 1, memory_order_release); // producer
 *   while (atomic_load_explicit(&stage, memory_order_acquire) < 1) ;  // relay
 *   atomic_store_explicit(&stage, 2, memory_order_release); // relay
 *   while (atomic_load_explicit(&stage, memory_order_acquire) < 2) ;  // consumer
 */
