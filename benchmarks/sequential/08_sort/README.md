# Benchmark 09: Sort

Iterative Lomuto quicksort + bottom-up mergesort on 1M `f64` values. Both use the same algorithm in C and CLEAR.

Data: deterministic permutation via Knuth multiplicative hash (`val[i] = (i * 2654435761) % N`).

- C: direct array indexing, stack-allocated sort stacks, `memcpy` in mergesort
- CLEAR: `Float64[]@list` (heap), TIGHT WHILE inner loops (no saveLoopMark/yield overhead), frame-allocated sort stacks

`BENCH_RESULT` = quicksort + mergesort combined.

## Results

| Language | Quicksort + Mergesort | vs C | RSS |
|----------|-----------------------|------|-----|
| C (`gcc -O3`) | ~107ms | baseline | ~17 MB |
| CLEAR (`--optimized`) | ~94ms | -12% | ~72 MB |

CLEAR is faster: LLVM generates better code than GCC for the TIGHT inner loops. The RSS gap is scheduler overhead (32 worker threads at ~1.5 MB each).
