# Benchmark 01: Call Overhead

Recursive Fibonacci(40): ~204M recursive calls, zero heap allocation.
Measures pure function call overhead and stack frame cost.

`BENCH_RESULT` = elapsed ms

## Results

| Language | Time | vs C |
|----------|------|------|
| C | ~154ms | baseline |
| CLEAR | ~266ms | +73% |
| Rust | ~265ms | +72% |

CLEAR matches Rust, both ~73% slower than C.

## Why CLEAR and Rust are slower than C

C compiles `fib(n-1) + fib(n-2)` to a direct call with no overhead.

CLEAR emits `rt` (runtime context pointer) as the first parameter of every function.
This extra argument prevents some compiler optimizations and adds per-call overhead.
It also means stack frames are larger (one additional pointer slot).

Rust similarly adds overhead due to its calling convention for small integer return values
vs C's direct register passing.

## Path to matching C

Marking `fib` as `@pure` (no runtime calls, no allocation) would let the compiler omit
the `rt` parameter and produce identical call sequences to C. Pure functions with
only primitive types and no heap operations don't need the runtime pointer.
