/*
 * Footgun: Data Race — C
 *
 * Two threads increment a shared counter 1,000,000 times each.
 * Expected result: 2,000,000. Actual result: less, unpredictably.
 *
 * The read-increment-write of `counter++` is three instructions.
 * Both threads can read the same value, both increment it, and both
 * write back — losing one of the increments. C has no concept of
 * data-race-free by default; this compiles and runs silently wrong.
 */

#include <pthread.h>
#include <stdio.h>

#define ITERS 1000000L

static long counter = 0;

static void *increment(void *arg) {
    (void)arg;
    for (long i = 0; i < ITERS; i++)
        counter++; /* not atomic: load / add / store race */
    return NULL;
}

int main(void) {
    pthread_t t1, t2;
    pthread_create(&t1, NULL, increment, NULL);
    pthread_create(&t2, NULL, increment, NULL);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);

    /* Almost never prints 2000000. */
    printf("counter = %ld (expected %ld)\n", counter, 2 * ITERS);
    return 0;
}

/*
 * Compile and run:
 *   gcc -pthread -O2 -o race main.c && ./race
 *   gcc -pthread -O2 -fsanitize=thread -o race main.c && ./race  # TSan
 *
 * Result without sanitizers: wrong answer, no diagnostic.
 * Result with TSan: WARNING: ThreadSanitizer: data race
 *
 * Fix: use _Atomic long counter, or protect with pthread_mutex_t.
 */
