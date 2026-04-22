/*
 * Footgun: TOCTOU (Time-of-Check to Time-of-Use) — C
 *
 * Two classic forms:
 *
 * 1. Filesystem: access() checks permissions, open() uses the path.
 *    Between the two calls, an attacker replaces the file with a symlink
 *    to a privileged file. The check passes on the original; the open
 *    hits the attacker's target. CVE-2001-0872 (OpenSSH), countless others.
 *
 * 2. In-process: read a shared value to make a decision, release the
 *    lock, then act. Another thread modifies the value in the window.
 *    The decision is stale. C has no language-level help here.
 */

#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <unistd.h>

/* ---- Form 1: filesystem TOCTOU ---- */

void filesystem_toctou(const char *path) {
    /* CHECK: does the file exist and is it readable? */
    if (access(path, R_OK) == 0) {
        /* Window: between access() and open(), another process
         * could replace `path` with a symlink to /etc/shadow.
         * No atomic "check-and-open" in POSIX C. */

        /* USE: open and read */
        FILE *f = fopen(path, "r");
        if (f) {
            char buf[64];
            if (fgets(buf, sizeof buf, f))
                printf("read: %s", buf);
            fclose(f);
        }
    }
}

/* ---- Form 2: in-process lock TOCTOU ---- */

static int balance = 100;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;

void withdraw(int amount) {
    /* CHECK: is there enough balance? */
    pthread_mutex_lock(&mu);
    int ok = (balance >= amount);
    pthread_mutex_unlock(&mu); /* lock released — window opens */

    if (ok) {
        /* Another thread can withdraw between the unlock above
         * and the lock below, driving balance negative. */
        pthread_mutex_lock(&mu);
        balance -= amount;     /* USE: act on stale check */
        pthread_mutex_unlock(&mu);
        printf("withdrew %d, balance = %d\n", amount, balance);
    }
}

static void *withdraw_thread(void *arg) {
    withdraw(*(int *)arg);
    return NULL;
}

int main(void) {
    /* Filesystem demo (non-destructive) */
    filesystem_toctou("/etc/hostname");

    /* In-process demo: two threads each try to withdraw 80 from 100.
     * With TOCTOU both can succeed, leaving balance = -60. */
    int amt = 80;
    pthread_t t1, t2;
    pthread_create(&t1, NULL, withdraw_thread, &amt);
    pthread_create(&t2, NULL, withdraw_thread, &amt);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);

    printf("final balance = %d (may be negative)\n", balance);
    return 0;
}

/*
 * Fix for form 1: open() with O_NOFOLLOW, or openat() with a dirfd
 * that was already validated, or operate entirely on fds not paths.
 *
 * Fix for form 2: keep the lock held across both check and act:
 *   lock → check → act → unlock  (no window)
 */
