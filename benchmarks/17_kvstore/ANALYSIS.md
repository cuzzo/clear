# KVStore Benchmark - Performance Analysis

## Raw Map Backend Comparison (128 shards, pre-built keys, no runtime overhead)

```
                    ZIG (128 shards)              RUST DashMap (128 shards)
                    zipf(GET)   mixed(80/20)      zipf(GET)   mixed(80/20)
  1 worker          211ms       216ms              212ms       215ms
  2 workers         120ms       126ms              122ms       129ms
  4 workers          60ms        69ms               64ms        68ms
  8 workers          41ms        53ms               32ms        45ms
 16 workers          22ms        65ms               21ms        24ms
 32 workers          13ms        72ms               13ms        15ms

  Zig Mutex (128 shards)
  1 worker          203ms       209ms
  8 workers          44ms        41ms
 32 workers          23ms        31ms
```

## Known Issues

### 1. RwLock writer starvation on mixed workloads (5x gap at 32 cores)

**Symptom**: Zig sharded RwLock mixed = 72ms vs Rust DashMap mixed = 15ms at 32 workers.

**Root cause**: Zig's `std.Thread.RwLock` is `pthread_rwlock_t` on Linux - a kernel-managed
lock. Every lock/unlock crosses into kernel space. Under contention with mixed read/write
workloads, writers are starved by the stream of readers because pthread_rwlock defaults to
reader-preference.

Rust's DashMap uses `parking_lot::RwLock` which is:
- Userspace spinning with futex fallback (no syscall on fast path)
- Writer-preferring (prevents writer starvation)
- Adaptive spinning before blocking

**Evidence**: Zig's own Mutex (which uses `FutexImpl` with userspace `lock bts` fast path)
performs much better: 31ms mixed at 32 workers (2.3x faster than Zig RwLock). This confirms
the lock implementation, not the map structure, is the bottleneck.

**Fix options**:
- Use `:locked` (Mutex) instead of `:writeLocked` (RwLock) for mixed workloads. Mutex uses
  Zig's futex-based implementation which is 2x faster.
- Implement a custom RwLock with parking_lot-style semantics (userspace spinning, writer
  preference, adaptive backoff). This would close the remaining 2x gap vs Rust.
- For read-only workloads (zipf GET), RwLock and DashMap are equivalent (both 13ms at 32w).

### 2. Shard count matters: 8 shards is too few for 32+ workers

**Symptom**: With 8 shards, mixed workload doesn't scale at all (1.0x from 1w to 32w).

**Root cause**: Zipf distribution concentrates traffic on a few hot keys. With 8 shards,
hot keys map to 1-2 shards, creating a bottleneck. With 128 shards (matching Rust's
`num_cpus * 4`), contention per shard drops proportionally.

**Evidence**: At 8 shards, sharded-rw mixed goes from 213ms (1w) to 206ms (32w) = 1.0x.
At 128 shards, it goes from 216ms (1w) to 72ms (32w) = 3.0x.

**Current state**: bench.cht uses `@shared:sharded(128):locked`.

### 3. Fiber runtime per-iteration overhead (~138ms, NOT string allocation)

**Symptom**: Raw Zig sharded mutex at 32w: zipf=23ms.
CLEAR benchmark at 32w: zipf=161ms. That's ~138ms / 7x overhead.

**Root cause**: Layered benchmarking (bench_layers.zig) proved that string
formatting, allocator choice, and vtable dispatch add ZERO measurable overhead:

```
Layer                              zipf (32w)
L0: raw (pre-built keys)            23ms
L1: + fmt.count+bufPrint+c_alloc    22ms    (string formatting: +0ms)
L2: + bump alloc (no free)          24ms    (bump vs c_alloc: +0ms)
L3: + vtable dispatch               24ms    (vtable overhead: +0ms)
L4: + intToString+concat (old)      22ms    (2-alloc path: +0ms)
L5: stack-buf fmt (0 allocs)        22ms    (0-alloc path: +0ms)
CLEAR                              161ms    (+138ms from fiber runtime)
```

The entire 138ms gap is the fiber runtime's per-iteration overhead:

1. `saveLoopMark()` + `defer restoreLoopMark()` — called EVERY loop iteration.
   `getMark()` is cheap (3 field reads). `rewind()` is NOT cheap: checks
   `large_objects.items.len`, `blocks.items.len`, conditional frees, etc.
   Even when nothing needs freeing, the branching and memory accesses add up.

2. `checkYield()` — called EVERY loop iteration. Increments counter, masks,
   branches. The actual yield (coopYield) only fires every 4096 iterations,
   but the check itself is ~2-3ns per call = ~60-90ms over 31.25M total calls.

3. BG context struct pointer indirection — all captured variables accessed
   through `ctx.map`, `ctx.cnt`, etc. instead of direct locals. Extra pointer
   chase per access.

4. `frameAlloc()` indirection — `fp.__pinned_local_alloc orelse self.frame_allocator`
   branch on every allocation.

**Fix options**:
- Hoist `saveLoopMark`/`restoreLoopMark` out of tight inner loops when no
  allocations escape the loop body (common case).
- Reduce `checkYield` frequency or make it truly zero-cost (e.g., cooperative
  points only at function calls, not every loop iteration).
- Inline BG context fields as locals when the fiber is not stolen.

### 4. Zig's HashMap vs Rust's hashbrown (SwissTable)

**Symptom**: At 1 worker (no contention), Zig and Rust are within 5% of each other.
This is not currently a bottleneck.

**Root cause**: Zig uses `StringHashMapUnmanaged` (open addressing, robin hood probing).
Rust's DashMap uses `hashbrown` (SwissTable with SIMD-accelerated probing). SwissTable is
generally 10-30% faster for lookups due to SIMD metadata scanning.

**Current impact**: Negligible at current scale. May matter at higher operation counts
or smaller shard counts where per-lookup time dominates.

## Summary: where the time goes (zipf GET, 32 workers)

```
Component                   Zig raw    Rust raw    CLEAR
Map + lock (mutex, 128sh)    23ms       13ms       23ms*
Fiber runtime overhead         -          -       ~138ms
Total                        23ms       13ms       161ms

* String formatting adds 0ms — verified by layered benchmarking.
  The frame allocator bump is ~5ns per alloc, invisible at this scale.
```

The 2x gap between Zig Mutex (23ms) and Rust parking_lot (13ms) is lock
implementation quality. The 7x gap between Zig raw and CLEAR is the fiber
runtime's per-loop-iteration overhead (loop mark save/restore + checkYield).
