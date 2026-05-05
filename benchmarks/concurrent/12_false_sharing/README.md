# Benchmark 27: False Sharing

N threads each increment their own counter M times (40M total work).
Tests whether CLEAR's `@shared:locked` eliminates false sharing by construction.

## What each implementation does

| Implementation | Sync | Layout |
|----------------|------|--------|
| C packed | none (racy) | adjacent int64s (false sharing) |
| C padded | none (racy) | 64-byte aligned (no false sharing) |
| Go heap-alloc | none (racy) | separate `*int64` per goroutine |
| Rust Arc<Mutex> | mutex | separate heap alloc per thread |
| CLEAR @shared:locked | mutex | separate heap alloc per fiber |

`BENCH_RESULT` per language: C=padded, Go=heap-alloc, Rust=Arc<Mutex>, CLEAR=elapsed.

## Results (32 threads, 40M total increments)

| Implementation | ms | vs CLEAR |
|----------------|-----|---------|
| CLEAR @shared:locked | ~56ms | baseline |
| Rust Arc<Mutex> | ~116ms | CLEAR -52% |
| Go heap-alloc (racy) | ~3ms | n/a - no mutex |
| C padded (racy) | ~3ms | n/a - no mutex |

## CLEAR scheduler mode

This benchmark should use stackful CLEAR workers, for example
`BG { @standard:@parallel -> ... }`.

The worker task is deliberately tiny:

```clear
FOR j IN (0_i64 ..< increments) DO
    WITH EXCLUSIVE ref AS inner {
        inner.value = inner.value + 1;
    }
END
```

Each worker repeats an uncontended lock, one integer increment, and unlock roughly
1.25M times. There is no I/O, no meaningful blocking, and only `threadCount()`
long-running workers, so per-task memory is not the limiting factor. The hot cost
is per-iteration dispatch.

FSM workers are correct here, but they are the wrong tradeoff for this shape. The
FSM lowering must preserve resumable lock semantics, so each `WITH EXCLUSIVE`
goes through the FSM lock protocol, state dispatch, body segment, unlock segment,
and cleanup bookkeeping. Stackful workers lower to a tight acquire/body/release
loop. On the 32-thread benchmark, the fixed FSM path was about 2x slower than the
stackful path for this specific workload.

The memory tradeoff goes the other direction. FSM tasks avoid per-fiber stacks;
the runtime benchmark reports a compact `FsmTask` plus small state storage versus
a stackful task with `Task`, `Fiber`, and a reserved stack. That is the right trade
for huge numbers of parked, blocked, or lightly suspended tasks. It is not the
right trade for a small number of CPU-bound workers executing millions of tiny
critical sections.

This benchmark is therefore an example of why CLEAR supports both models:
use FSMs when task count and memory footprint dominate, and use stackful fibers
when hot-loop compute throughput dominates.

## Interpretation

**CLEAR vs Rust Arc<Mutex>**: same mechanism (heap alloc + mutex), CLEAR is ~2x faster.
This reflects CLEAR's lighter-weight mutex implementation.

**CLEAR vs C padded / Go heap-alloc**: NOT a fair comparison. C and Go have no mutex -
they are racy writes that happen to be cache-isolated. The 18x gap is the cost of
mutex acquisition, not false sharing.

**False sharing penalty (from C packed vs C padded)**:
On 32 cores, packed counters cause 5-10x slowdown due to cache line bouncing.
CLEAR `@shared:locked` sidesteps this entirely: each `@shared` is a separate heap
allocation with its own control block, so no manual padding is needed.

## Key finding

CLEAR eliminates false sharing by construction. The programmer gets automatic cache
isolation without manual `__attribute__((aligned(64)))` or padding structs.
The cost is mutex overhead, which is expected and present in all safe concurrent
counter implementations. Rust's Arc<Mutex> pays the same cost; CLEAR pays ~half.
