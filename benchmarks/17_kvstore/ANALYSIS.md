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

### 3. Fiber execution model overhead (~139ms, NOT generated code)

**Symptom**: Raw Zig sharded mutex at 32w: zipf=23ms.
CLEAR benchmark at 32w: zipf=161ms. That's ~139ms / 7x overhead.

**Root cause**: Layered benchmarking (bench_layers.zig) isolates every source of
overhead individually. NONE of the generated code contributes measurable cost:

```
Layer                              zipf (32w)   delta
L0: raw (pre-built keys)            23ms         baseline
L1: + string formatting (c_alloc)   22ms         +0ms
L2: + bump allocator                22ms         +0ms
L3: + vtable dispatch               23ms         +0ms
L4: + intToString+concat (2 alloc)  23ms         +0ms
L5: + stack-buf (0 allocs)          22ms         +0ms
R1: + checkYield                    23ms         +0ms
R2: + loopMark save/restore         21ms         +0ms
R3: + ctx pointer indirection       23ms         +0ms
R4: + ALL overhead combined         23ms         +0ms
R5: + REAL CheatArena               23ms         +0ms
R6: EXACT CLEAR code, native thr    22ms         +0ms
CLEAR (fibers)                     161ms       +139ms
```

**R6 is the critical result**: the EXACT code pattern CLEAR generates — Arc deref,
CheatArena vtable alloc, getMark/rewind, checkYield, context pointer — runs at 22ms
on native OS threads. CLEAR runs the same code at 161ms on fibers.

The entire 139ms gap is the fiber execution model:
- Running on 64KB mmap'd stacks vs 8MB OS thread stacks
- Cooperative scheduler overhead (work stealing, queue management)
- Fiber stack cache/TLB behavior (mmap'd memory in a different region)
- Potential lack of kernel thread-local optimizations on fiber stacks

**This is NOT fixable by optimizing generated code.** The fix must be in the
fiber runtime or scheduler itself. Potential approaches:
- Thread-pool mode for compute-heavy BG blocks (bypass fiber overhead)
- Larger fiber stacks to improve cache locality
- Reduce scheduler polling frequency
- Use native threads when fiber count equals scheduler count

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
Map + lock (mutex, 128sh)    23ms       13ms       23ms
Generated code overhead        -          -        +0ms  (verified: R6 = 22ms)
Fiber execution model          -          -      +139ms
Total                        23ms       13ms       161ms
```

Two independent problems:
1. **Zig Mutex vs Rust parking_lot (2x)**: 23ms vs 13ms. Lock quality.
2. **Fiber model vs native threads (7x)**: 22ms vs 161ms for identical code.
   String formatting, allocators, vtable, checkYield, loopMark — all add 0ms.
   The overhead is entirely in how the cooperative fiber scheduler executes code.
