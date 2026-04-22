/*
 * Footgun: Task Leak — C
 *
 * A detached pthread blocks indefinitely on a mutex it will never
 * acquire. The main thread exits, but the leaked thread and its
 * resources (stack, TLS, mutex state) persist until the OS cleans up
 * the process. In a long-running server that spawns threads per-request,
 * this exhausts the thread limit and eventually deadlocks the server.
 *
 * C has no structured concurrency. pthread_detach() is "fire and forget"
 * by design. Nothing warns you that the thread will block forever.
 */

#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

static pthread_mutex_t held = PTHREAD_MUTEX_INITIALIZER;

static void *blocked_worker(void *arg) {
    (void)arg;
    /* This lock is held by main and never released.
     * This thread blocks here until the process exits. */
    pthread_mutex_lock(&held);
    printf("worker: got lock (never reached)\n");
    pthread_mutex_unlock(&held);
    return NULL;
}

int main(void) {
    /* Hold the mutex so the worker blocks forever. */
    pthread_mutex_lock(&held);

    for (int i = 0; i < 5; i++) {
        pthread_t t;
        pthread_create(&t, NULL, blocked_worker, NULL);
        pthread_detach(t); /* detached: no join, no cleanup signal */
        printf("spawned detached thread %d\n", i + 1);
    }

    printf("main: exiting with 5 leaked threads still blocked\n");
    /* pthread_mutex_unlock(&held); -- never called */
    return 0;
}

/*
 * Compile and run:
 *   gcc -pthread -o task_leak main.c && ./task_leak
 *
 * Result: main exits, OS reclaims everything — but in a daemon process
 * this accumulates until ulimit -u is hit. No runtime warning.
 *
 * Fix: use pthread_cancel() + pthread_join(), or pass a shutdown flag
 * and a condition variable so workers can exit cleanly.
 */
