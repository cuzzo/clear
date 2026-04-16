# Benchmark 13: Backpressure

100,000 items processed with CPU work (5,000 LCG iterations each).
Producer is rate-limited when consumers fall behind.

## Backpressure mechanisms

- **CLEAR**: `CONCURRENT(workers: 32, parallel: TRUE) SELECT` — semaphore-gated
  pipeline. No channel; items are dispatched directly to worker fibers.
  Producer fiber blocks when all 32 slots are in-flight.
- **Go**: bounded channel (cap 64) + GOMAXPROCS consumer goroutines.
  Producer goroutine blocks on `ch <-` when channel is full.
- **Rust**: `crossbeam::channel::bounded(64)` + N_CPU native threads.
  Producer thread blocks on `tx.send()` when channel is full. Native threads
  are correct here — work is CPU-bound, not I/O-bound.

## Results (best of 5, all cores)

```
CLEAR      37ms
Go         72ms
Rust      243ms
```

CLEAR's pipeline avoids per-item channel send/receive overhead entirely —
the semaphore gates fiber dispatch without copying items through a queue.
Go and Rust pay channel overhead on every item; under 32-thread contention
on a 64-slot channel, Rust's native thread wake/sleep cycles add up more
than Go's lightweight goroutine scheduler.

## Note on prior Rust implementation

The original Rust implementation used Tokio + `Arc<Mutex<Receiver>>` (see
c54313ca8f331ac849440941428a084eca78f319). That approach serialized all
consumers through a single mutex, meaning only one consumer ran at a time.
It appeared faster (~50ms) but was not measuring backpressure throughput —
it was measuring a serialized lock. crossbeam's multi-consumer channel is
the correct implementation; the higher number is the honest one.
