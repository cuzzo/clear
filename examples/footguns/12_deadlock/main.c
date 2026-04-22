/*
 * Footgun: Deadlock — C
 *
 * C's pthread mutexes block forever when a deadlock occurs. There is no
 * built-in detection or timeout. The process hangs silently; the only
 * indication is that it stops making progress.
 *
 * The classic pattern: two threads, two mutexes, opposite acquisition order.
 * Thread A holds mutex1, waits for mutex2.
 * Thread B holds mutex2, waits for mutex1.
 * Neither can proceed. The program hangs indefinitely.
 *
 * Detection requires external tooling (Helgrind, ThreadSanitizer with
 * -fsanitize=thread, or gdb with thread apply all bt). There is no language
 * construct that prevents this.
 */

#include <pthread.h>
#include <stdio.h>
#include <unistd.h>

static pthread_mutex_t mu_a = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t mu_b = PTHREAD_MUTEX_INITIALIZER;

/* Thread 1: locks A then B. */
static void *thread1(void *arg) {
    (void)arg;
    pthread_mutex_lock(&mu_a);
    printf("thread1: acquired A\n");
    usleep(1000); /* give thread2 time to acquire B */
    printf("thread1: waiting for B...\n");
    pthread_mutex_lock(&mu_b);  /* DEADLOCK: thread2 holds B */
    printf("thread1: acquired B (never reached)\n");
    pthread_mutex_unlock(&mu_b);
    pthread_mutex_unlock(&mu_a);
    return NULL;
}

/* Thread 2: locks B then A — opposite order. */
static void *thread2(void *arg) {
    (void)arg;
    pthread_mutex_lock(&mu_b);
    printf("thread2: acquired B\n");
    usleep(1000); /* give thread1 time to acquire A */
    printf("thread2: waiting for A...\n");
    pthread_mutex_lock(&mu_a);  /* DEADLOCK: thread1 holds A */
    printf("thread2: acquired A (never reached)\n");
    pthread_mutex_unlock(&mu_a);
    pthread_mutex_unlock(&mu_b);
    return NULL;
}

/* CORRECT: consistent lock order — always A before B. */
static void *thread_fixed(void *arg) {
    (void)arg;
    /* Both threads take A first, then B — no cycle possible. */
    pthread_mutex_lock(&mu_a);
    pthread_mutex_lock(&mu_b);
    printf("fixed thread: holds both locks\n");
    pthread_mutex_unlock(&mu_b);
    pthread_mutex_unlock(&mu_a);
    return NULL;
}

int main(void) {
    printf("--- correct: consistent lock order ---\n");
    pthread_t t3, t4;
    pthread_create(&t3, NULL, thread_fixed, NULL);
    pthread_create(&t4, NULL, thread_fixed, NULL);
    pthread_join(t3, NULL);
    pthread_join(t4, NULL);

    printf("--- broken: opposite lock order (will deadlock) ---\n");
    printf("(not run — would hang the program)\n");
    /* pthread_t t1, t2;
     * pthread_create(&t1, NULL, thread1, NULL);
     * pthread_create(&t2, NULL, thread2, NULL);
     * pthread_join(t1, NULL);  -- hangs here
     * pthread_join(t2, NULL); */

    return 0;
}

/*
 * Compile: gcc -o deadlock_c main.c -lpthread && ./deadlock_c
 *
 * Detect the broken version: gcc -fsanitize=thread -o deadlock_c main.c -lpthread
 * (TSan detects the lock cycle and reports it before the hang.)
 *
 * Fix: enforce a global lock acquisition order. If locks have a natural
 * identity (e.g., pointer address), always acquire the lower-address lock
 * first: if (&mu_a < &mu_b) { lock a then b } else { lock b then a }
 */
