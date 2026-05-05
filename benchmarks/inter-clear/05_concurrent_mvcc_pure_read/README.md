# 17b — MVCC vs RwLock: pure-read stress (no writers)

Scenario D from the MVCC scenario taxonomy. The cleanest scenario for
isolating MVCC's win at high core counts.

## Workload
- 32 readers x 200k iters reading a single Counter cell.
- **Zero writers.**

## Why MVCC pulls ahead here
With no writers, you might expect RwLock readers to have no contention
since they all hold the shared mode. They don't:

- **RwLock**: every read-acquire must atomically update the reader-count
  on the lock's state cache line. With 32 readers on 32 cores, all cores
  CAS the same cache line, and MESI cache-coherence traffic serializes
  the acquires. Throughput is bounded by inter-core write traffic, not
  by useful work.

- **MVCC**: read = `acquire-load` of an immutable pointer + EBR pin
  (one store to a per-thread slot). The pointer load is a clean read of
  a shared-cache line; the pin writes a thread-local cache line. No
  inter-core write traffic at all. Throughput scales linearly with cores.

## Expected
5-10x MVCC win on 32 cores. Below that means EBR pin is touching
something it shouldn't, or the lock fast path is more cache-friendly
than expected.

Run via:

    ruby benchmarks/runner.rb --release benchmarks/inter-clear/05_concurrent_mvcc_pure_read/
