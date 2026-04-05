# Benchmark 02: SROA (Scalar Replacement of Aggregates)

BigVec has 130 Float64 fields (1040 bytes). `sum3()` reads only x1, x2, x3.
127 of 130 field initializations are dead writes. Tests whether the backend
eliminates them via SROA + DCE.

## Results

| Build | Time | Notes |
|-------|------|-------|
| C (`gcc -O3`) | 181ms | SROA + SSE |
| CLEAR (Zig native backend) | 173ms | SROA works, no SSE (x87 softfloat) |
| CLEAR (Zig + LLVM via `-target`) | 181ms | SROA + SSE, matches C |
| Zig + LLVM + `@setFloatMode(.optimized)` | 3.7ms | Loop folded (fast-math) |
| Rust (`--release`) | 1.4ms | Loop folded (fast-math default for this pattern) |

## Analysis

All compilers successfully apply SROA - the 127 dead fields are eliminated.
The disassembly confirms pure `addsd`/`vaddsd` instructions in the hot loop
with no struct allocation or memset.

The 130x gap between Rust (1.4ms) and C/CLEAR (181ms) is NOT about SROA.
It is about **fast-math loop folding**: the `acc` recurrence reaches infinity
after ~50 iterations, and with fast-math enabled, LLVM proves the remaining
~99.99M iterations are constant and folds the entire loop away.

- Rust's `rustc` annotates FP ops with `fast` flags by default for this pattern
- C with `-ffast-math` would match (~3ms)
- Zig with `@setFloatMode(.optimized)` matches (3.7ms)
- Without fast-math, strict IEEE 754 semantics require evaluating every iteration

## CLEAR path to matching Rust

A `@fastmath` function annotation in CLEAR that emits `@setFloatMode(.optimized)`
in the generated Zig would close the gap. This is an opt-in semantic change
(NaN/infinity handling becomes undefined) - not a default.

The Zig native x86_64 backend (used for fast ~2s builds) does not emit SSE
instructions for floating point. The LLVM backend (used for `--optimized` builds)
does emit SSE and matches C performance. Both backends apply SROA correctly.
