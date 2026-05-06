# Benchmark 05: Backpressure

100,000 items processed with CPU work (5,000 LCG iterations each).
Producer is rate-limited when consumers fall behind — all three languages
use a bounded channel (capacity 64) as the back pressure mechanism.

## Workload

```
N        = 100,000 items
Work     = 5,000 LCG iterations per item (wrapping multiply + add)
Capacity = 64  (channel / buffer slots)
Workers  = threadCount() (auto-scaled to available cores)
Result   = sum of all LCG outputs mod 1e9 (checksum: 516709808)
```

## Back pressure mechanisms

- **CLEAR**: `BG STREAM { YIELD i } |> CONCURRENT(capacity: 64) EACH { ... }`
  The producer fiber blocks in `BoundedChannel.push()` when all 64 slots are
  occupied. Workers accumulate into a `@shared:locked` struct — no result list
  is ever materialized. Peak memory is O(capacity), not O(N).

- **Go**: `make(chan uint64, 64)` + `runtime.GOMAXPROCS(0)` goroutines.
  Producer goroutine blocks on `ch <-` when channel is full. Workers
  accumulate via `sync/atomic.Uint64` (lock-free).

- **Rust**: `crossbeam::channel::bounded(64)` + `available_parallelism()`
  native threads. Producer thread blocks on `tx.send()` when channel is full.
  Workers accumulate via `AtomicU64` (lock-free). Native threads are correct
  here: work is CPU-bound, not I/O-bound.

## Results (direct binary run, all cores, optimized builds)

```
CLEAR (fibers + BoundedChannel)     57 ms
Go    (goroutines + chan)            74 ms   +30% vs CLEAR
Rust  (threads + crossbeam)        233 ms  +308% vs CLEAR
```

All three produce checksum 516709808.

CLEAR's M:N fiber scheduler has lower context-switch overhead than Go
goroutines for this pattern (high-rate items, moderate work per item).
Rust's native thread wakeups (OS-level futex) dominate at 32 workers
competing on a 64-slot channel, making crossbeam the slowest despite
zero scheduler overhead per-item.

## Memory

CLEAR holds only 64 items in the BoundedChannel at any point — the
`@shared:locked` accumulator contains a single Int64. Go and Rust are
similarly bounded by their channel capacity. RSS overhead from CLEAR's
fiber stack pool (~16 MB) is the main runtime cost vs Go's ~2 MB.

## Note on prior CLEAR implementation (semaphore approach)

The original CLEAR benchmark (prior to BoundedChannel) used
`items |> CONCURRENT(workers: 32) SELECT processItem(_.seed)` which:
- Materialized all 100K results into a heap list (O(N) memory)
- Used a semaphore to gate fiber dispatch (not a channel)
- Reported 37ms, but was not measuring the same workload

The new implementation uses a real `BoundedChannel` and accumulates
in-place. The 57ms result is the honest channel-back-pressure number.

## Note on prior Rust implementation

The original Rust implementation used Tokio + `Arc<Mutex<Receiver>>` which
serialized all consumers through a single mutex. crossbeam's multi-consumer
channel is the correct implementation.
