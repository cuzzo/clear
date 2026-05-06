# Benchmark 01: Call Overhead

Recursive Fibonacci(40): ~204M recursive calls, zero heap allocation.
Measures pure function call overhead and stack frame cost.

`fib` is marked `EFFECTS REENTRANT:TIGHT` so the benchmark measures
direct recursive call overhead rather than cooperative scheduler fairness
polling. Plain `EFFECTS REENTRANT` injects `rt.checkYield()` at every
recursive entry; that is important for long-running recursive work in
production, but it is not part of an apples-to-apples call overhead test
against C and Rust.

`BENCH_RESULT` = elapsed ms

## Results

| Language | Time | vs C |
|----------|------|------|
| C | ~154ms | baseline |
| CLEAR | ~224-230ms | +45-49% |
| Rust | ~265ms | +72% |

CLEAR is faster than Rust here after removing the scheduler yield poll,
but still slower than C.

## Why CLEAR and Rust are slower than C

C compiles `fib(n-1) + fib(n-2)` to a direct call with no overhead.

CLEAR still emits `rt` (runtime context pointer) as the first parameter of
the function. This extra argument can inhibit some optimizer choices and
adds per-call register pressure.

With plain `EFFECTS REENTRANT`, CLEAR also emits a cooperative yield poll
on every recursive entry:

```zig
rt.checkYield();
```

Profiling showed this dominated the old benchmark result: `checkYield`
updates the per-runtime yield counter, masks it against the 4096-call
budget, and checks scheduler state before deciding whether to yield. That
is the right default for fairness, but it is not comparable to C/Rust's
bare recursive calls. `EFFECTS REENTRANT:TIGHT` keeps real recursion and
only removes that entry poll.

Rust similarly adds overhead due to its calling convention for small integer return values
vs C's direct register passing.

## Path to matching C

Marking `fib` as `@pure` (no runtime calls, no allocation) would let the compiler omit
the `rt` parameter and produce identical call sequences to C. Pure functions with
only primitive types and no heap operations don't need the runtime pointer.
