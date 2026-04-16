# Benchmark 10: Concurrent File Search

2000 files x ~10KB each (~20MB total, fits in page cache). Spawn one
fiber/goroutine/task per file, count occurrences of "the", report top-10.

## Backpressure

A key dimension of this benchmark is how each language handles bounded
concurrency over a large file set:

- **CLEAR**: `BG {}` blocks batched in groups of 128 via `search_batch!`.
  `NEXT futures` awaits the batch before spawning the next. Explicit,
  composable, ~5 lines.
- **Rust**: `tokio::sync::Semaphore(128)` caps in-flight tasks. Each task
  acquires a permit before spawning and releases it on completion.
  Idiomatic, ~3 lines.
- **Go**: no explicit backpressure — spawns all 2000 goroutines at once.
  Go's scheduler handles the resulting concurrency transparently. This
  works because goroutines are cheap (~2KB initial stack, grows on demand).

## Results (best of 5, 2000 files x 10KB, all CPUs unless noted)

```
cores    Go      Rust    CLEAR
all     31ms    20ms      -
  1       -       -      43ms
  2       -       -      52ms  (*)
  4       -       -      26ms
  8       -       -      23ms
 16       -       -      11ms
```

(*) 2-core result is slightly worse than 1-core: cross-scheduler fiber
stealing adds coordination overhead that outweighs the parallel gain for
this batch size. At 4+ cores the parallelism dominates.

## Search kernel (stdlib note)

bench.cht calls `countOccurrences(content, needle)` which is currently a
stdlib function wrapping libc `memchr`. This is effectively a native shim:
CLEAR cannot express the raw pointer iteration that SIMD byte search
requires without unsafe pointer arithmetic, which the language does not yet
have.

The correct future state is for CLEAR's `indexOf` to be SIMD-backed and for
an `indexOfFrom(haystack, needle, start)` variant to exist (avoiding
per-iteration `substr` allocations), after which `countOccurrences` could be
written as a plain CLEAR function and removed from the stdlib entirely.

For now `countOccurrences` and `indexOf` both use libc `memchr` in the
runtime (same approach as Go's `bytes.Count` and Rust's `memchr::memmem`),
making the search kernel comparison honest.

## Analysis

- **Go**: spawns all 2000 goroutines at once; scheduler absorbs the load.
  `bytes.Count` uses hand-written SSE2/AVX2 assembly for the search kernel.
- **Rust**: `Semaphore(128)` backpressure mirrors CLEAR's batch approach.
  `memchr::memmem` uses AVX2 for the search kernel.
- **CLEAR**: fibers are ~2KB, comparable to goroutines. At 16 cores CLEAR
  outperforms both Go and Rust on this workload once the search kernel is
  SIMD-equivalent.

CLEAR's 4→16 core scaling (26ms → 11ms, 2.4x) reflects genuine parallel
I/O + compute. The 1→2 core dip is a known scheduler artifact for
fine-grained batch workloads and does not appear at 4+ cores.
