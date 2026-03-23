#include <stdio.h>
#include <stdint.h>
#include <assert.h>
#include <time.h>

// Perfect C Baseline
// Goal: 0 Heap allocs, standard OS stack management.

int64_t fib(int64_t n) {
    if (n <= 1) return n;
    return fib(n - 1) + fib(n - 2);
}

int main() {
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    int64_t result = fib(35);
    assert(result == 9227465);

    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed = (end.tv_sec - start.tv_sec) + 
                    (end.tv_nsec - start.tv_nsec) / 1e9;

    printf("Fib(35) = %ld\n", result);
    printf("Time: %.4f seconds\n", elapsed);
    return 0;
}
