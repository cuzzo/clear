# Benchmark 18: Shared-Nothing KV Store (SHARD pipeline)

1M key-value operations across 32 shards with three workloads:
uniform SET, uniform GET, mixed 80/20 (200K SET + 800K GET).

## The CLEAR feature: SHARD pipeline

```clear
(0..<n) |> SHARD("key:" + toString(_), map) |> CONCURRENT EACH {
    map[_] = "value";
};
```

One line. Zero locks. Each fiber owns its shard exclusively —
no RwLock, no Mutex, no cross-fiber contention on map operations.
The pipeline hashes the key, routes to the owning scheduler, and
each shard fiber processes only its own keys. DragonflyDB model.

## What Go and Rust require for the same pattern

Both need explicit plumbing: one channel per shard, N producer
goroutines/threads hashing and routing, N shard goroutines/threads
draining channels. ~60 lines vs 1 line in CLEAR.

The Go and Rust implementations here do exactly this — the same
zero-lock shared-nothing model, expressed with full manual plumbing.

## Results (best of 5, all cores, 3 workloads summed)

```
Go        222ms
Rust      389ms
CLEAR     691ms
```

CLEAR is slower despite zero lock contention. This is the same fiber
runtime overhead documented in benchmark 17's ANALYSIS.md: the fiber
scheduler's per-iteration cost (arena mark/rewind, checkYield, work-
stealing) degrades under high-frequency map operations and does not
scale with core count.

Go wins because channel send/receive has lower overhead than CLEAR's
fiber context switch at this granularity, and goroutine scheduling
has better CPU affinity under concurrent map workloads.

## What this benchmark demonstrates

The SHARD pipeline's value is **ergonomic, not currently performance**.
Writing shared-nothing routing in Go or Rust requires ~60 lines of
channel plumbing and careful ownership management. CLEAR does it in 1
line with a safe, composable syntax.

The performance gap is a fiber runtime issue, not an algorithmic one.
The generated map code runs at native speed (verified in benchmark 17,
layer R6). A native-thread SHARD implementation would match or beat Go.
