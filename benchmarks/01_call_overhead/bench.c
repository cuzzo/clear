#include <stdio.h>
#include <stdint.h>
#include <assert.h>
#include <time.h>

// C baseline: recursive Fibonacci, measures call overhead and stack frame cost.
// Goal: ~204M recursive calls with zero heap allocation.

int64_t fib(int64_t n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

int main() {
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    int64_t result = fib(40);
    assert(result == 102334155);

    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed = (end.tv_sec - start.tv_sec) + 
                    (end.tv_nsec - start.tv_nsec) / 1e9;

    long elapsed_ms = (long)((end.tv_sec - start.tv_sec) * 1000 + (end.tv_nsec - start.tv_nsec) / 1000000);
    /* BENCH_RESULT = elapsed ms */
    printf("BENCH_RESULT: %ld ms\n", elapsed_ms);
    printf("Fib(40) = %ld\n", result);
    printf("Time: %.4f seconds\n", elapsed);
    return 0;
}
