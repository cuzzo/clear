# Profiling

## Quick Start

```bash
./clear profile myapp.clear
./clear doctor myapp.profile/
```

`clear profile` builds with allocation tracking enabled (zero overhead in normal builds), runs the program, and collects:
- **Heap profile**: allocation counts and bytes per call site
- **CPU profile**: `perf record` sampling (when available)
- **Syscalls**: `strace -c` breakdown
- **Hardware counters**: `perf stat` (cycles, cache misses, branch misses)

`clear doctor` reads the profile data and prints actionable optimization advice with CLEAR source line numbers.

## Example: Optimizing Benchmark 17 (KV Store)

### Step 1: Profile

```bash
./clear profile benchmarks/concurrent/09_kvstore/bench.clear
./clear doctor benchmarks/concurrent/09_kvstore/bench.profile/
```

### Step 2: Read the CPU profile

```
=== CPU Profile ===
  37.49%  hash_map.HashMapUnmanaged.getIndex    -- hashmap probing
  12.21%  pthread_rwlock_unlock                  -- RwLock release
   6.37%  memcpy                                 -- value copying
   5.29%  hash.wyhash.Wyhash.hash               -- key hashing
   4.88%  ShardedStringMap.put                   -- shard selection + lock
   2.84%  pthread_rwlock_rdlock                  -- RwLock acquire
```

**Observation**: 15% of CPU is in `pthread_rwlock_unlock` + `pthread_rwlock_rdlock`. That's lock overhead, not useful work.

### Step 3: Check hardware counters

```
=== Hardware Counters ===
  5,390,314,521  instructions         #  1.66 insn per cycle
     10,001,037  cache-misses         # 52.87% of all cache refs
     60,878,759  L1-dcache-load-misses  #  4.88% of all L1-dcache accesses
```

**Observation**: 53% LLC cache miss rate. The hashmap's random-access probing misses the cache on every other access. This is inherent to hash tables with large working sets - not fixable by resharding.

### Step 4: Form a hypothesis

Two bottlenecks:
1. **Lock contention (15% CPU)**: The benchmark uses `@writeLocked` (RwLock). RwLock has high per-operation overhead even for single-writer access. For write-heavy workloads, `@locked` (Mutex) should be cheaper.
2. **Cache misses (53% LLC)**: Inherent to random hash probing across 1M keys. Not fixable without changing the data structure.

### Step 5: Test the change

Switch from `@shared:sharded(128):writeLocked` to `@shared:sharded(128):locked`:

| Config | SET | GET | Zipf | Mixed | Total |
|---|---|---|---|---|---|
| `@writeLocked` (before) | 110ms | 17ms | 18ms | 77ms | 246ms |
| `@locked` (after) | **58ms** | 20ms | 24ms | **26ms** | **198ms** |

- SET: **47% faster** (Mutex has lower overhead for exclusive access)
- Mixed: **66% faster** (RwLock writer starvation was killing mixed workloads)
- Total: **20% faster**
- GET/Zipf: slightly slower (Mutex blocks concurrent readers that RwLock allows)

### Step 6: Compare against Rust and Go

| | Rust (DashMap) | Go (sync.RWMutex) | CLEAR @locked |
|---|---|---|---|
| SET | 75ms | 1217ms | **58ms** |
| GET | 14ms | 529ms | 20ms |
| Zipf | 13ms | 17ms | 24ms |
| Mixed | 19ms | 26ms | 26ms |
| **Total** | **237ms** | **1806ms** | **198ms** |

CLEAR beats Rust (DashMap) by 17% total. SET is 22% faster than DashMap.

### What the profiler told us

The profiler didn't just confirm "it's slow" - it pointed to the specific mechanism:
1. CPU profile showed 15% in rwlock functions
2. Hardware counters confirmed cache misses are inherent (not fixable)
3. This directed the fix to the lock type, not the shard count

We also tested reducing shards from 128 to 32 - this made things **worse** (more contention per shard), confirming that the shard count wasn't the problem.

## How It Works

### Heap Profiling

Built into the runtime allocator VTable. Every allocation in the runtime passes `@returnAddress()` (the caller's return address). The profiler records this address, allocation count, and bytes per site in a fixed-size hash table (1024 sites, no heap allocations inside the profiler).

Key runtime helpers (`charAtCodepoint`, `intToString`, `substr`, `concat`, `join`) also call `profileAlloc()` with their own `@returnAddress()`, giving function-level attribution.

Controlled by a comptime flag (`CLEAR_PROFILE`). When not set, all profiling code is eliminated at compile time - zero overhead in production.

### CPU Profiling

Uses Linux `perf record` for sampling-based CPU profiling. Requires `perf_event_paranoid <= 2`:

```bash
sudo sysctl kernel.perf_event_paranoid=2  # temporary, resets on reboot
```

### Source Mapping

`clear doctor` maps addresses back to CLEAR source lines using:
1. `addr2line` to resolve addresses to Zig file:line
2. `// CLR:N` comments in the transpiled Zig to map back to CLEAR line numbers

Profile builds use `-fno-strip` to retain debug symbols.

## Environment Variables

| Variable | Set by | Purpose |
|---|---|---|
| `CLEAR_ALLOC_PROFILE` | `clear profile` | Output path for allocation data |
| `CLEAR_THREADS` | User | Number of scheduler threads |
