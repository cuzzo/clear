/*
 * Socket Throughput Benchmark — C Baseline (Perfect)
 *
 * WHY C IS FAST:
 *   The read buffer lives on the OS stack: char buf[4096].
 *   Each read() call fills the buffer in place — zero allocator involvement.
 *
 *   100,000 reads × 256-byte messages:
 *     - 0 malloc/free calls
 *     - 0 error-union checks
 *     - 0 pool bookkeeping
 *
 * WHAT CLEAR USED TO DO (before ReadPool):
 *   tcpRead → allocator.dupe(u8, buf[0..n])
 *   = 1 GPA malloc per read × 100,000 reads
 *   GPA has a lock, header writes, and freelist bookkeeping.
 *
 * WHAT CLEAR DOES NOW (ReadPool):
 *   tcpRead → pool.acquire() = @ctz(free_mask) — bitmask op, no malloc
 *   Slot released via restoreFrameMark() at scope exit — O(1) bitmask OR.
 *   100,000 reads = 0 GPA malloc calls in the hot path.
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <assert.h>
#include <time.h>
#include <sys/socket.h>
#include <unistd.h>
#include <sys/wait.h>

#define N        100000
#define MSG_SIZE 256

int main(void) {
    int fds[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);

    pid_t pid = fork();
    assert(pid >= 0);

    if (pid == 0) {
        /* Child: writer — fills the pipe as fast as the reader drains it */
        close(fds[0]);
        char msg[MSG_SIZE];
        memset(msg, 'X', MSG_SIZE);
        for (int i = 0; i < N; i++) {
            ssize_t written = 0;
            while (written < MSG_SIZE) {
                ssize_t n = write(fds[1], msg + written, MSG_SIZE - written);
                assert(n > 0);
                written += n;
            }
        }
        close(fds[1]);
        _exit(0);
    }

    /* Parent: reader — measure only the read loop */
    close(fds[1]);

    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    char buf[4096]; /* Stack buffer — zero allocation */
    int64_t total_bytes = 0;
    for (int i = 0; i < N; i++) {
        ssize_t got = 0;
        while (got < MSG_SIZE) {
            ssize_t n = read(fds[0], buf + got, MSG_SIZE - got);
            assert(n > 0);
            got += n;
        }
        total_bytes += got;
    }

    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed = (end.tv_sec - start.tv_sec) +
                     (end.tv_nsec - start.tv_nsec) / 1e9;

    printf("reads = %d\n", N);
    printf("total_bytes = %ld\n", (long)total_bytes);
    printf("Time: %.4f seconds\n", elapsed);
    printf("Throughput: %.2f M reads/sec\n", N / elapsed / 1e6);

    close(fds[0]);
    wait(NULL);
    return 0;
}
