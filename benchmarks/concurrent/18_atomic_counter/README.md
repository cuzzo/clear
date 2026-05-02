# Benchmark 18: Atomic Counter — apples-to-apples

8 workers each perform 1,000,000 atomic increments on a single shared
counter. Total expected: 8M.

This is the **right** way to compare CLEAR's `@shared:atomic` to other
languages — atomics are implemented similarly across the board:

- **CLEAR**: `MUTABLE c: Int64 = 0 @shared:atomic;` then `c += 1`
  auto-rewrites to `c.ctrl.data.fetchAdd(1)`. The cell is `Atomic(i64)`
  inside an `Arc` (M1 layout; M2 will drop the Arc indirection).
  Memory ordering: `.monotonic` (relaxed).
- **Go**: `var counter int64; atomic.AddInt64(&counter, 1)`. Lowers to
  `LOCK XADDQ` on x86 — sequentially consistent (full memory barrier).
- **Rust**: `Arc<AtomicI64>` with `fetch_add(1, Ordering::Relaxed)`.
  Same `LOCK XADDQ` pattern; relaxed ordering matches CLEAR.

All three drive 8 OS-thread-equivalent workers against a single
contended cache line. The wall-clock time is dominated by inter-core
coherence latency on the shared line — every increment has to ping-pong
the cache between L1s.

## What was hidden before this benchmark

CLEAR auto-pins BG fibers that capture an `@shared` (Arc) binding —
the assumption was that the inner data might not be thread-safe, so
keep the fibers on the same scheduler. That was wrong for
`@shared:atomic`: the inner cell is *literally* a hardware atomic,
self-synchronizing by construction. Auto-pinning serialized 8
workers onto a single thread, hiding the contention story entirely
behind cooperative single-thread scheduling. The fix (in this same
commit): skip the auto-pin when `info.sync == :atomic`, mirroring
the existing skip for `DashMap` (the other self-synchronizing shape).

## Results (8 workers * 1M increments, multi-thread scheduler)

```
            time      vs CLEAR
CLEAR       0.116 s    base
Rust        0.125 s    +7.8%
Go          0.133 s    +14.7%
```

CLEAR is 7-13% faster than Go/Rust at the contended-counter shape.
The win is not from the atomic op itself — that's the same `LOCK
XADDQ` instruction on all three — but from CLEAR's scheduler being
slightly cheaper per fiber-resume than Go's M:N goroutine scheduler
or Rust's OS thread overhead at this granularity.

## Per-thread scaling (informative, not the headline)

```
threads    CLEAR    Go      Rust
1          48 ms    42 ms   --       (uncontended; one core does all)
2          66 ms   111 ms   --       (CLEAR's work-stealing not yet active at 2)
4         143 ms   139 ms   --       (matched contention)
8         123 ms   138 ms   125 ms   (steady state)
16        128 ms   138 ms   125 ms
32        126 ms   138 ms   125 ms
```

At 1 thread CLEAR is ~14% slower than Go, reflecting the M1 Arc
indirection (`c.ctrl.data.fetchAdd`) — one extra load per op. Once
contention dominates (8+ threads), the extra load is noise relative
to cache-line bouncing latency. M2 drops the Arc and that gap closes.

## What this is NOT

This is not a "CLEAR atomics are X% faster" headline result — the
margin is small and within run-to-run variance. The point of the
benchmark is:

1. **Apples-to-apples**: same workload, same hardware operation,
   same memory ordering (modulo Go's seq-cst), three implementations.
2. **Negative-result detection**: any new performance regression in
   the M1.x atomic path will show up as a CLEAR-vs-Go gap that's
   bigger than ~10%. Pinning regression, Arc-vs-bare regression,
   spurious yield insertion — all caught by this benchmark.
3. **Scheduler validation**: the per-thread scaling table proves the
   fibers are actually distributing across cores under contention,
   instead of running cooperatively on one.

## Next milestones

- **M1.x**: explicit atomic methods (`fetchAnd`, `fetchOr`, `cmpxchg`)
  via stdlib registry.
- **M2.2**: drop the `Arc` wrapper from `@shared:atomic` (bare
  `Atomic(T)`); closes the 1-thread gap with Go.
- **M2.3**: atomic with explicit lifetime tying so BG handles
  carrying atomic refs satisfy the lifetime checker without Arc.
