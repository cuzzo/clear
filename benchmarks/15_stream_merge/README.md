# Benchmark 15: Stream Merge

8 producers each generate 100K values (LCG sequence).
Consumer reads round-robin from all 8 streams, sums values.
Total: 800K values merged from 8 streams.

## Execution model

- **CLEAR**: `BG STREAM` — 8 cooperative fiber producers on the same
  scheduler. `YIELD`/`NEXT` is a direct fiber context switch; zero channel
  allocation, zero lock contention. No parallelism (all fibers share one
  scheduler thread by default).
- **Go**: 8 goroutines writing to a shared buffered channel (cap 64).
  Producers run in parallel across GOMAXPROCS threads; consumer blocks on
  channel receive.
- **Rust**: 8 threads + `crossbeam::channel::bounded(64)`. Same structure
  as Go; native threads instead of goroutines.

## Results (best of 5, all cores)

```
CLEAR      22ms
Go         63ms
Rust       99ms
```

CLEAR's YIELD/NEXT path is a same-scheduler cooperative switch with no
channel buffer, no lock, and no cross-thread wakeup. Go and Rust pay
channel send/receive overhead on every one of 800K items; under
8-producer contention on a 64-slot channel, the synchronization cost
dominates the trivial per-item compute.

CLEAR does not parallelize the producers (no `parallel: TRUE`), but for
this workload — where per-item work is a single LCG step — parallelism
buys nothing: channel overhead exceeds compute time at any core count.

## Historical note

An earlier version of this benchmark showed CLEAR at ~335ms due to
per-YIELD spinlock + full register-save context switch overhead. Runtime
improvements (scheduler fast path, reduced spinlock scope) brought this
to 22ms. The old profile breakdown is preserved below for reference.

```
Old profile (335ms, 32 cores):
  40%  Scheduler.run (idle work-stealing on 31 empty schedulers)
  18%  kernel (syscalls)
   7%  InfStream.next (spinlock + read)
   6%  schedule (submitResume)
  24%  SgCtx*.run (actual producer work)
```
