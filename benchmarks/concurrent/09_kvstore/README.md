# Benchmark 17: KV Store (Concurrent HashMap)

1M key-value operations across N workers with four workloads:
uniform SET, uniform GET, Zipfian GET (hot-key skew), mixed 80/20 read/write.

## Strategy

CLEAR uses `@shared:sharded(128):locked` - an Arc-wrapped HashMap with 128 shards,
Mutex per shard. Any fiber can access any shard; the Mutex handles synchronization
internally. No WITH blocks needed.

- Go: 128-shard `sync.RWMutex` map (custom, matches CLEAR/DashMap structure).
  `sync.Map` is NOT used — it is read-optimized and degrades severely on
  write-heavy workloads (2s+ for uniform SET vs 426ms with sharded mutex).
- Rust: `DashMap` (parking_lot RwLock, `num_cpus * 4` shards)

## Running

```bash
ruby benchmarks/runner.rb --smoke benchmarks/17_kvstore/   # CLEAR only
ruby benchmarks/runner.rb --fast benchmarks/17_kvstore/    # All langs, 3 runs
ruby benchmarks/runner.rb benchmarks/17_kvstore/           # Normal, 5 runs
ruby benchmarks/runner.rb --cores=8 benchmarks/17_kvstore/ # Control core count
```

## Known Issues

### Zig Mutex vs Rust parking_lot (2x gap at 32 cores)

Raw map backend comparison with pre-built keys (no language overhead):

```
                       Zig Mutex 128sh    Rust DashMap 128sh
  1 worker               209ms              215ms
  8 workers                41ms               45ms
 32 workers                31ms               15ms          <-- 2x gap
```

At low core counts, Zig Mutex and Rust parking_lot are equivalent. At 32 cores
the gap widens to 2x. Both use userspace atomics on the fast path, but parking_lot
has adaptive spinning and a smaller lock word (1 byte vs 4 bytes), reducing cache
line contention under heavy parallelism.

This is a Zig stdlib quality issue. Zig's `std.Thread.Mutex` (`FutexImpl`) uses a
simple spin-then-futex strategy. parking_lot uses adaptive spinning calibrated to
the critical section length, plus thread parking with backoff. Closing this gap
requires a custom Mutex implementation.

Note: CLEAR's RwLock (`@shared:writeLocked`) now uses `pthread_rwlock_t` with
writer-preferring attributes (`PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP`),
eliminating the starvation that previously caused 5x overhead on mixed workloads.
For short critical sections like KV ops, Mutex (`:locked`) is still preferred
since RwLock has slightly higher per-operation overhead from tracking reader count.

### Fiber runtime per-iteration overhead (7x)

See ANALYSIS.md for details. Layered benchmarking proved string formatting adds
0ms overhead — the frame allocator bump is ~5ns, invisible at this scale. The
entire 138ms gap (23ms raw vs 161ms CLEAR) comes from the fiber runtime:

- `saveLoopMark()`/`restoreLoopMark()` every iteration (arena mark/rewind)
- `checkYield()` every iteration (counter + branch)
- BG context pointer indirection (captured vars accessed through ctx struct)
