# Benchmark 02: SROA (Scalar Replacement of Aggregates)

BigVec has 130 Int64 fields (1040 bytes). `sum3()` reads only x1, x2, x3.
127 of 130 field initializations are dead writes. Tests whether LLVM eliminates
them via SROA + DCE.

## Results (100M iterations)

| Language | Time | vs C |
|----------|------|------|
| C (`gcc -O3`) | ~0.38s | baseline |
| Rust (`--release`) | ~0.45s | +19% |
| CLEAR (`--optimized`) | ~0.52s | +37% |

## Analysis

SROA is working in all three - without it, 130 x 8 = 1040 bytes of dead writes
per iteration would produce a 5-10x slowdown, not 19-37%.

The gap is **integer overflow semantics**:

- C defaults to signed integer UB on overflow. LLVM exploits this to treat loop
  counters and accumulators as no-wrap induction variables, enabling loop
  unrolling, vectorization, and induction variable simplification.
- CLEAR defaults to panic on overflow (wrapping arithmetic `+%` in ReleaseFast).
  LLVM sees two's complement semantics and cannot assume no-wrap, losing those
  optimizations.

In short: **C defaults to UB, CLEAR defaults to Panic.** The ~37% gap is the
optimization headroom C gets for free from undefined behavior.

Rust's `black_box(acc)` prevents LLVM from seeing through the loop recurrence,
which partially explains its gap vs C independent of overflow semantics.
