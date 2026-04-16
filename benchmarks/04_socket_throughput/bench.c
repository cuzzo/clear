/*
 * Socket Throughput Benchmark — C Baseline
 *
 * TCP loopback: writer sends 100,000 × 256-byte messages, reader
 * reads until all 25,600,000 bytes received using a 4096-byte stack
 * buffer. Zero heap allocation in the read loop.
 *
 * Timer covers only the read loop (matches CLEAR's BENCH_RESULT scope).
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <assert.h>
#include <time.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <sys/wait.h>

#define N        100000
#define MSG_SIZE 256
#define TOTAL    (N * MSG_SIZE)
#define PORT     14538

int main(void) {
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    assert(server_fd >= 0);
    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr = {0};
    addr.sin_family      = AF_INET;
    addr.sin_port        = htons(PORT);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) == 0);
    assert(listen(server_fd, 1) == 0);

    pid_t pid = fork();
    assert(pid >= 0);

    if (pid == 0) {
        /* Child: writer */
        close(server_fd);
        int conn = socket(AF_INET, SOCK_STREAM, 0);
        assert(conn >= 0);
        assert(connect(conn, (struct sockaddr *)&addr, sizeof(addr)) == 0);
        char msg[MSG_SIZE];
        memset(msg, 'X', MSG_SIZE);
        for (int i = 0; i < N; i++) {
            ssize_t w = 0;
            while (w < MSG_SIZE) {
                ssize_t n = write(conn, msg + w, MSG_SIZE - w);
                assert(n > 0);
                w += n;
            }
        }
        close(conn);
        _exit(0);
    }

    /* Parent: accept, then time only the read loop */
    int client_fd = accept(server_fd, NULL, NULL);
    assert(client_fd >= 0);
    close(server_fd);

    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    char buf[4096];
    int64_t total_bytes = 0;
    while (total_bytes < TOTAL) {
        ssize_t n = read(client_fd, buf, sizeof(buf));
        assert(n > 0);
        total_bytes += n;
    }

    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed_ms = (end.tv_sec - start.tv_sec) * 1e3 +
                        (end.tv_nsec - start.tv_nsec) / 1e6;

    printf("BENCH_RESULT: %.0f ms\n", elapsed_ms);
    printf("total_bytes = %ld\n", (long)total_bytes);
    printf("Throughput: %.0f MB/s\n", TOTAL / (elapsed_ms / 1e3) / 1e6);

    close(client_fd);
    wait(NULL);
    return 0;
}
