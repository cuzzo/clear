# 17 — MVCC vs RwLock (narrow case)

Read-heavy comparison of `@shared:writeLocked` (RwLock) and
`@shared:versioned` (MVCC, lock-free reads via EBR) on a single
`Counter { value: Int64 }` cell.

This is the **narrow case** baseline — a single Int64 cell with
sparse writes. The read critical section is one cache-line load
(~1ns of work), so the ~10-30ns lock-acquire / EBR-pin overhead
dominates and the speedup compresses to ~2x. For scenarios where
MVCC pulls further ahead (3-10x), see:

- `04_concurrent_mvcc_fat_struct/`        -- multi-field reads (CS amortization)
- `05_concurrent_mvcc_pure_read/`         -- 32 cores, no writers (cache-coherence isolation)
- `06_concurrent_mvcc_writer_pressure/`   -- heavy write rate (reader-pile-up amplification)

## Workload
32 reader fibers each performing 100k reads of `counter.value`,
plus 4 writer fibers each performing 1k sparse increments. Total
reads: 3.2M.

## Cross-language note
Rust and Go don't have a stdlib MVCC primitive. The standard compare
on each is `parking_lot::RwLock` / `sync.RWMutex`, both of which match
CLEAR's `@shared:writeLocked`. An MVCC-equivalent in Rust requires
`crossbeam-epoch` for EBR plus manual atomic-pointer plumbing -- a
third-party crate, not the stdlib path most code reaches for. So this
benchmark is intentionally CLEAR-only: the comparison is between
CLEAR's two built-in choices for read-heavy concurrent state.

Run via:

    ruby benchmarks/runner.rb --release benchmarks/inter-clear/03_concurrent_mvcc_vs_rwlock/

The runner surfaces `BENCH_INFO:` lines that show RwLock vs MVCC
times and the speedup ratio.
