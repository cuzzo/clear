# Benchmark 12: Fan-Out / Fan-In

10,000 items, each processed with 100K LCG iterations (CPU-bound).
Results collected into a single checksum.

## Execution model

- **CLEAR**: `CONCURRENT(parallel: TRUE) SELECT` - a bounded worker pool
  (N_CPU workers) fed from a shared queue. Zero per-item fiber spawn.
- **Rust**: Rayon `into_par_iter` - work-stealing thread pool, N_CPU threads.
  Zero per-item thread spawn. Same structural model as CLEAR.
- **Go**: one goroutine per item (10,000 goroutines). Goroutines are cheap
  (~2KB initial stack) but 10K spawns still pay scheduling overhead.

CLEAR and Rust both amortize concurrency setup across the work queue.
Go pays a small per-item spawn cost, which shows in the numbers.

## Results (best of 5, all cores)

```
Rust (Rayon)    7ms
CLEAR           30ms
Go              52ms
```

The CLEAR vs Rust gap is runtime overhead, not algorithmic: Rayon uses native
OS threads with no scheduler indirection; CLEAR fibers add a thin cooperative
scheduling layer. Both do the same work.
