# 17c — MVCC vs RwLock: writer pressure

Scenario E from the MVCC scenario taxonomy. Drives writers hard so the
RwLock writer-preferring fairness policy forces reader pile-ups.

## Workload
- 28 readers x 100k iters reading a single Counter cell.
- 4 writers x 25k iters bumping the value.
- Writes are ~3.5% of reads, sustained for the full run.

The original `17_mvcc_vs_rwlock` has writes at ~0.1% of reads and only
4k total writes — writers barely show up. This bench keeps the readers
similar but turns the writer dial up by 25x.

## Why MVCC pulls ahead here
- **RwLock**: writer-preferring fairness means new readers block once a
  writer is waiting. With 4 writers issuing 25k updates each, any
  reader's read-acquire racing with a pending writer gets queued.
  Reader throughput stalls in writer-shaped windows.
- **MVCC**: writers publish via CAS + EBR retire. Readers never touch
  the lock state. Reader throughput is unaffected by writer rate.

## Expected
4-7x MVCC win on 32 cores. Observed on a 32-core run is much
higher (>100x) because RwLock readers stall behind every write
under writer-preferring fairness, while MVCC reads stay lock-free.

## Why this dir has a TIMEOUT file
The RwLock leg under heavy writer pressure takes 3-5s wall at
`--release` scale (~3000-4000 ms RwLock vs ~25 ms MVCC). The
runner's default per-run timeout is 2s, which kills the bench
mid-RwLock-leg before the comparison completes. `TIMEOUT=15`
gives the RwLock leg enough headroom; the MVCC leg still finishes
in tens of milliseconds.

Run via:

    ruby benchmarks/runner.rb --release benchmarks/concurrent/17c_mvcc_writer_pressure/
