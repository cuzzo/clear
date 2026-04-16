# Benchmark 03: Alloc Throughput

Measures heap allocator throughput combined with sequential array fill and sum.

10,000 outer iterations. Each iteration:
1. Allocate a 10,000-element float array (80 KB)
2. Fill it sequentially (0.0, 1.0, ..., 9999.0)
3. Sum all elements
4. Free it

Total: 10K alloc+free cycles, 100M element writes, 100M element reads.

All three languages pre-allocate exact capacity upfront - no reallocs:
- C: `malloc(N * sizeof(double))` + `free`
- Rust: `Vec::with_capacity(N)`
- CLEAR: `Float64[10000]@list` (emits `initCapacity(alloc, N)`)

## Results

| Language | Time | vs C |
|----------|------|------|
| C (`gcc -O3`) | ~90ms | baseline |
| CLEAR (`--optimized`, TIGHT WHILE) | ~127ms | +42% |
| Rust (`--release`) | ~167ms | +86% |

CLEAR is faster than Rust here. Rust's `Vec::push` pays bounds-check overhead
on every append (100M checks). C's raw indexed write has no such check.
CLEAR's list append is bounds-checked only on capacity growth (which never
happens here since capacity is pre-allocated).

The CLEAR binary also runs a Regular FOR variant as an overhead reference
(not measured by the runner). Run the binary directly to see both numbers.
