# Benchmark 30: Borrowed Iterator

Struct-based iterator over a 10K-element Int64 array, 1000 outer iterations.
10M element reads total. Measures the cost of the iterator abstraction itself.

## Pattern

All three languages use the same structure:

```
struct SliceIter { data: borrowed pointer, pos: int, len: int }
fn has_next(iter) -> bool
fn current(iter) -> element
fn advance(iter) -> next iter
```

Functions are marked `noinline` / `__attribute__((noinline))` to prevent
LLVM from inlining the iterator into the loop body and eliminating the
abstraction. This measures function call overhead per element, not the
optimizer's ability to see through the pattern.

## Results (ReleaseFast, single-core, noinline)

| Language | Iterator (ms) | vs C |
|----------|--------------|------|
| C | 16.4 | baseline |
| CLEAR | 18.9 | +15% |
| Rust | 27.9 | +70% |

CLEAR's borrowed iterator matches C within 15%. Faster than Rust because
Zig's calling convention has less overhead than Rust's for small structs.

## With inlining (what the optimizer can do)

| Language | Iterator (ms) | Notes |
|----------|--------------|-------|
| C | 0 | LLVM inlines all three calls, vectorizes the sum |
| Rust | 0 | Same — LLVM eliminates the iterator entirely |
| CLEAR | 16.7 | Zig's native x86 backend does not inline across functions |

With inlining enabled, C and Rust reduce to a single vectorized loop.
The iterator struct, has_next check, and advance call all disappear.
CLEAR cannot do this yet because:

1. **Zig's native x86 backend (`-fno-llvm`) does not inline across function
   boundaries.** The `./clear build` default uses `-fno-llvm` for fast ~2s
   compile times. The LLVM backend (`./clear build --optimized`) would inline,
   but CLEAR functions use `anytype` parameters which Zig monomorphizes —
   the LLVM backend should be able to inline these.

2. **CLEAR emits `rt` (Runtime pointer) as the first parameter of every
   function.** This prevents Zig from treating iterator functions as pure
   (no side effects), blocking some optimizations. A `@pure` annotation
   that omits the `rt` parameter for functions that don't use the runtime
   would enable LLVM to fully inline and vectorize.

3. **The `checkYield()` call at loop back-edges** is a function call that
   the optimizer can't eliminate (it has side effects). `TIGHT` loops skip
   this, but the iterator's `WHILE hasNext(iter)` loop is not marked TIGHT
   because it calls non-trivial functions. Teaching the annotator that
   pure iterator functions are safe for TIGHT would eliminate this overhead.

## Path to matching C/Rust (0ms)

Three changes, in order of impact:

1. **`@pure` function annotation** — omit `rt` parameter, enable LLVM
   to prove no side effects. Iterator functions (hasNext, current, advance)
   are pure by definition.

2. **LLVM backend for benchmarks** — `./clear build --optimized` already
   uses LLVM. The runner should use this for apples-to-apples comparison
   with C/Rust `-O3`.

3. **Auto-detect TIGHT eligibility** — if a loop body only calls `@pure`
   functions, suppress `checkYield()` automatically. No manual TIGHT
   annotation needed.

With all three, LLVM would see the same IR as C/Rust and produce the
same vectorized loop. The iterator abstraction becomes zero-cost.
