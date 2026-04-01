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

### 3. String interpolation overhead in CLEAR hot loops (~7x)

**Symptom**: Raw Zig sharded mutex at 32w: zipf=23ms, mixed=31ms.
CLEAR benchmark at 32w: zipf=169ms, mixed=223ms. That's 7x overhead.

**Root cause**: Each map access builds a key via string interpolation:
`"key:${k.toString()}"` transpiles to:
```zig
try std.mem.concat(rt.frameAlloc(), u8, &.{
    "key:",
    try CheatLib.intToString(rt.frameAlloc(), k),
    ""
})
```

This performs 2 allocations per map access (intToString + concat), even though the
frame allocator is a bump allocator. The vtable dispatch, bounds checking, and memcpy
add up at 1M operations.

Go and Rust have the same per-operation string formatting cost (`fmt.Sprintf` / `format!`),
but their allocators (Go's GC heap, Rust's jemalloc) have lower per-allocation overhead
than Zig's allocator vtable dispatch.

**Fix options**:
- Stack-buffer string formatting: `fmtInt` + `bufConcat` that write directly into a
  `[256]u8` stack buffer. Zero allocation, zero vtable dispatch. This would eliminate
  the 7x overhead for transient strings (map keys, comparisons).
- Requires transpiler changes to detect transient string contexts and emit stack-buffer
  code instead of allocator-based code.

### 4. Zig's HashMap vs Rust's hashbrown (SwissTable)

**Symptom**: At 1 worker (no contention), Zig and Rust are within 5% of each other.
This is not currently a bottleneck.

**Root cause**: Zig uses `StringHashMapUnmanaged` (open addressing, robin hood probing).
Rust's DashMap uses `hashbrown` (SwissTable with SIMD-accelerated probing). SwissTable is
generally 10-30% faster for lookups due to SIMD metadata scanning.

**Current impact**: Negligible at current scale. May matter at higher operation counts
or smaller shard counts where per-lookup time dominates.

## Summary: where the time goes (mixed workload, 32 workers)

```
Component                   Zig raw    Rust raw    CLEAR
Map + lock (mutex, 128sh)    31ms       15ms       31ms*
String interpolation           -          -       ~190ms
Total                        31ms       15ms       223ms

* CLEAR uses the same Zig primitives as the raw benchmark
```

The 2x gap between Zig Mutex (31ms) and Rust parking_lot (15ms) is the lock
implementation quality. The 7x gap between Zig raw and CLEAR is string allocation.
