# Benchmark 18: AtomicPtr (M3) producer-consumer config swap

Lock-free atomic-pointer publish workload comparing M3 `@indirect:atomic`
against three baselines:

- CLEAR `@shared:writeLocked` (RwLock baseline)
- CLEAR `@shared:versioned` (MVCC baseline)
- Go `sync/atomic.Pointer[T]`
- Rust `arc-swap::ArcSwap` (the canonical Rust idiom; the M3 design
  reference)

## Workload

1 writer + 16 readers. Reader: 50K `WITH SNAPSHOT` snapshots of a
`Counter { a: Int64, b: Int64 }`, verifying the structural invariant
`b == a * 2` on every read. Writer: 5K rcu-publish iterations that
maintain the invariant by computing `(old.a + 1, (old.a + 1) * 2)`.

If the runtime EVER produced a torn read (b != 2*a), that's a
correctness bug — the violations counter is the trip-wire.

## Build / run

```
# CLEAR (compares all three CLEAR variants in one binary)
./clear build benchmarks/concurrent/19_atomic_ptr/bench.cht --optimized
./benchmarks/concurrent/19_atomic_ptr/bench
CLEAR_THREADS=8 ./benchmarks/concurrent/19_atomic_ptr/bench

# Go
cd benchmarks/concurrent/19_atomic_ptr && go build -o bench_go .
./bench_go

# Rust
cd benchmarks/concurrent/19_atomic_ptr && cargo build --release
./target/release/bench_rust
```

## Reference numbers (single host, contended)

Recorded on a 32-core x86_64 development machine. Numbers will vary
substantially with core count, contention, and the OS scheduler.

| Variant                 | Time    | Notes                                    |
|-------------------------|---------|------------------------------------------|
| CLEAR `@shared:writeLocked` (1T)   |   14 ms | Single scheduler — no real contention    |
| CLEAR `@shared:writeLocked` (8T)   |  206 ms | Writer-preferring fairness drains readers |
| CLEAR `@shared:versioned`  (8T)    |    3 ms | Lock-free reads, EBR-pinned snapshots    |
| CLEAR `@indirect:atomic`   (8T)    |    6 ms | rcu-loop CAS-publish, EBR-pinned reads   |
| Go `atomic.Pointer[T]`     (default GOMAXPROCS) | ~1 ms | GC-managed snapshots, native CAS |
| Rust `arc-swap::ArcSwap`   (16 OS threads) | ~8 ms | rcu via arc-swap's hazard-pointer slots |

(`(NT)` = `CLEAR_THREADS=N`.)

## What the numbers say

**Lock-free wins on writer pressure.** RwLock (writer-preferring) drains
the reader fanout each time the writer claims the exclusive lock; under
8 threads that's a 30-70x penalty vs the lock-free options. Both MVCC
and AtomicPtr stay in the single-digit-ms range.

**MVCC is parity-or-better with AtomicPtr on this workload.** That's
expected: the read paths are nearly identical (acquire-load + EBR pin),
and MVCC's bounded-retry update is the same shape as AtomicPtr's
unbounded rcu loop except for the surfaced-Conflict cap. The cell isn't
under enough contention here for the cap to fire.

**Go's GC-managed atomic.Pointer is fast.** ~1 ms vs ~8 ms for
arc-swap and CLEAR's lock-free options. Three contributors: (1) Go's
GC means readers don't pay any per-load refcount cost; (2) Go's
goroutine scheduler can pack 17 goroutines onto a small thread pool
with very low context-switch overhead; (3) the workload is small
enough (~800K total operations) that startup + scheduling dominates.

**arc-swap matches CLEAR's AtomicPtr.** Both implementations use
EBR-style reclamation under the hood; arc-swap uses per-thread
hazard-pointer slots while CLEAR uses ThreadLocalEbr. The user surface
is the same: `WITH SNAPSHOT cell AS x { ... }` lowers to roughly
`let snap = cfg.load();`. The design parity is by construction.

## Scaling notes

- The CLEAR bench reports ALL THREE variants in one binary. The
  `BENCH_RESULT` line carries the AtomicPtr time so the bench runner
  picks it up by default.
- Rust + Go binaries report only their own surface (atomic.Pointer
  and arc-swap respectively).
- Per-variant scaling (1, 4, 16, 32 readers; varying writer rates)
  is a separate matrix; this README captures the canonical
  contended-host numbers.

## Why this benchmark exists (M3 contract)

The M3 design (`docs/agents/atomicptr.md`) commits to:
- Read path matching arc-swap's load+pin shape.
- Mutate path matching arc-swap's `rcu` (unbounded retry, no Conflict).
- WITH-SNAPSHOT user surface unifying with @versioned.

This benchmark is the empirical check that the implementation actually
hits those targets — and that the resulting performance lands in the
right ballpark vs the libraries the design draws from.
