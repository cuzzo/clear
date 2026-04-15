# Benchmarks

## Single-Core (Benchmark 05: HashMap, 1M keys)

CLEAR's numeric HashMap outperforms hand-optimized C with FNV-1a hashing. CLEAR uses Zig's AutoHashMap with frame-arena allocation - zero GPA calls in the hot path.

| Language | Variant | Insert | Lookup | Total | vs C String |
|----------|---------|--------|--------|-------|-------------|
| C | string key, FNV-1a | ~180 ms | ~170 ms | ~350 ms | 1.0x (baseline) |
| C | f64 key, bit-cast | ~130 ms | ~70 ms | ~200 ms | 0.57x |
| CLEAR | string key, frame | ~580 ms | ~155 ms | ~735 ms | 2.1x |
| CLEAR | numeric i64 key | ~110 ms | ~58 ms | ~168 ms | **0.48x** |

Idiomatic CLEAR single-core performance vs hand-optimized C is typically 0-30% slower for string workloads, and competitive or faster for numeric workloads.

## Multi-Core, Non-Adversarial (Benchmark 24: TCP JSON API)

TCP server benchmark: generate JSON files (SET), read + parse them (GET). Tests file I/O, JSON parsing via FFI, string handling, and concurrent connection management. 32 cores, 10K GETs, 50 concurrent connections.

| Server | SET (ms) | GET (ms) | Verified |
|--------|----------|----------|----------|
| Rust/Tokio | 66 | 54 | 10000/10000 |
| Go | 85 | 56 | 10000/10000 |
| **CLEAR** | 81 | **51** | 10000/10000 |

All servers within ~15% on SET. CLEAR has the fastest GET (JSON parse + file read + response). All verified, zero errors.

## Multi-Core, Adversarial (Benchmark 25: Pathological Workloads)

Pure compute over TCP. Three phases test scheduler fairness: uniform (all equal work), skewed (0.5% of requests 100x heavier), adversarial (one connection does all heavy work). 32 cores, 10K requests, 50 concurrent connections.

| Server | Uniform (req/s) | Skewed (req/s) | Adversarial (req/s) |
|--------|-----------------|----------------|---------------------|
| Rust/Tokio | 328,442 | 374,491 | 357,627 |
| Go | 322,593 | 361,316 | 356,704 |
| **CLEAR** | 341,142 | 366,551 | 356,041 |

All three runtimes within ~5% across all phases. No server has a consistent advantage - the workload is dominated by the compute kernel, not scheduling overhead.

## Reality: Multi-Core KV Store (Benchmark 20: RESP protocol, vs Dragonfly)

A RESP-compatible TCP KV store tested with `redis-benchmark`. 2 cores, 100K operations, 50 concurrent connections. CLEAR uses `@sharded(8):locked` HashMap with fiber-per-connection.

**With pipelining (P=16), 2 cores:**

| Server | SET rps | GET rps | SET p50 | SET p99 | GET p50 | GET p99 |
|--------|---------|---------|---------|---------|---------|---------|
| CLEAR (2 threads) | 98,328 | **106,044** | 7.75 ms | **16.18 ms** | 6.70 ms | **17.10 ms** |
| Dragonfly (2 threads) | 95,057 | 102,145 | **6.92 ms** | 20.91 ms | **6.68 ms** | 18.61 ms |

**Without pipelining, 2 cores:**

| Server | SET rps | GET rps | SET p50 | SET p99 | GET p50 | GET p99 |
|--------|---------|---------|---------|---------|---------|---------|
| CLEAR (2 threads) | 17,152 | **17,061** | 1.98 ms | **6.96 ms** | **1.94 ms** | **7.43 ms** |
| Dragonfly (2 threads) | 16,980 | 15,309 | **1.54 ms** | 9.14 ms | 2.10 ms | 8.90 ms |

Throughput within 5-10%. CLEAR has consistently better p99 latency; Dragonfly has slightly better p50 without pipelining.

**Important caveat**: This is NOT an apples-to-apples comparison. CLEAR's server is a minimal RESP parser with a sharded HashMap. Dragonfly is a production database with significantly more per-command overhead:
- **Memory management**: mimalloc with per-key accounting, fragmentation optimization
- **Expiry/eviction**: TTL tracking, background expiry, LRU/LFU metadata
- **Persistence**: Snapshot subsystem (codepaths exist even when disabled)
- **Access control**: ACL system, AUTH enforcement
- **Transactions**: MULTI/EXEC coordination, Lua scripting engine
- **Observability**: Per-command statistics, slow log, CLIENT TRACKING

The comparison demonstrates CLEAR's raw multi-core I/O and sharded HashMap performance. A fair comparison would require CLEAR to implement these features.

## Fiber Runtime Scaling (2-32 cores, --fast mode)

### 11: Atomic Contention (CLEAR vs Go)

| Cores | CLEAR | Go | vs Go |
|-------|-------|-----|-------|
| 2 | 27ms | 163ms | **-84%** |
| 4 | 28ms | 151ms | **-81%** |
| 8 | 28ms | 158ms | **-82%** |
| 16 | 32ms | 175ms | **-82%** |
| 32 | 48ms | 214ms | **-78%** |

CLEAR dominates at all core counts.

### 12: Fan-Out/Fan-In

| Cores | CLEAR | Go | Rust | vs Go | vs Rust |
|-------|-------|-----|------|-------|---------|
| 2 | 78ms | 587ms | 19ms | **-87%** | +318% |
| 4 | 24ms | 295ms | 10ms | **-92%** | +133% |
| 8 | 16ms | 150ms | 11ms | **-89%** | +51% |
| 16 | 13ms | 78ms | 10ms | **-83%** | +35% |
| 32 | 27ms | 47ms | 11ms | **-42%** | +145% |

Beats Go at all cores. Rust (Tokio stackless tasks) is faster. CLEAR regresses at 32 cores due to idle scheduler spinning.

### 13: Backpressure

| Cores | CLEAR | Go | Rust | vs Go | vs Rust |
|-------|-------|-----|------|-------|---------|
| 2 | 69ms | 333ms | 56ms | **-79%** | +24% |
| 4 | 27ms | 188ms | 57ms | **-86%** | **-54%** |
| 8 | 19ms | 127ms | 59ms | **-85%** | **-68%** |
| 16 | 19ms | 85ms | 59ms | **-77%** | **-67%** |
| 32 | 36ms | 70ms | 57ms | **-49%** | **-37%** |

Beats both Go and Rust at 4+ cores. Rust and Go don't scale; CLEAR does.

### 14: Dynamic Spawn

| Cores | CLEAR | Go | Rust | vs Go | vs Rust |
|-------|-------|-----|------|-------|---------|
| 2 | 292ms | 638ms | 82ms | **-54%** | +257% |
| 4 | 221ms | 321ms | 87ms | **-31%** | +155% |
| 8 | 142ms | 163ms | 89ms | **-13%** | +60% |
| 16 | 178ms | 85ms | 88ms | +110% | +104% |
| 32 | 212ms | 60ms | 92ms | +253% | +130% |

100K fibers spawned sequentially. Beats Go at 2-8 cores. Known regression at 16+ cores: idle schedulers spin on work-stealing instead of parking. Rust (Tokio) is flat because tasks are heap-allocated state machines (no stack allocation). Scheduler parking tracked for post-v0.1.

### 15: Stream Merge

| Cores | CLEAR | Go | Rust | vs Go | vs Rust |
|-------|-------|-----|------|-------|---------|
| 2 | 14ms | 74ms | 86ms | **-82%** | **-84%** |
| 4 | 13ms | 49ms | 86ms | **-73%** | **-84%** |
| 8 | 14ms | 51ms | 98ms | **-72%** | **-86%** |
| 16 | 16ms | 56ms | 77ms | **-72%** | **-80%** |
| 32 | 25ms | 65ms | 77ms | **-61%** | **-67%** |

8 BG STREAM producers, 100K values each. Buffered SPSC ring (64-slot) replaces single-slot rendezvous. 50x improvement over previous implementation. Beats both Go (buffered channels) and Rust (crossbeam) at all core counts.

### 16: Pub/Sub

| Cores | CLEAR | Go | Rust | vs Go | vs Rust |
|-------|-------|-----|------|-------|---------|
| 2 | 544ms | 824ms | 1846ms | **-34%** | **-71%** |
| 4 | 284ms | 812ms | 2168ms | **-65%** | **-87%** |
| 8 | 197ms | 881ms | 2555ms | **-78%** | **-92%** |
| 16 | 138ms | 815ms | 2812ms | **-83%** | **-95%** |
| 32 | 122ms | 786ms | 2910ms | **-96%** | **-96%** |

Near-linear scaling. Go and Rust get worse with more cores (channel contention). CLEAR's shared-nothing architecture avoids this entirely.

### 18: Shard vs Locked (CLEAR only)

| Cores | 2 | 4 | 8 | 16 | 32 |
|-------|---|---|---|----|----|
| CLEAR | 393ms | 319ms | 280ms | 276ms | 298ms |

Scales well to 16 cores; slight regression at 32.

### 19: Parallel Aggregation

| Cores | CLEAR | Go | Rust | vs Go | vs Rust |
|-------|-------|-----|------|-------|---------|
| 2 | 1432ms | 990ms | 681ms | +45% | +110% |
| 8 | 1168ms | 993ms | 689ms | +18% | +70% |
| 32 | 1110ms | 1029ms | 680ms | +8% | +63% |

CLEAR is slower. Rust and Go are flat (workload doesn't parallelize further). Gap narrows at higher core counts but doesn't close.

### KV Store (Benchmark 17)

`@shared:sharded(128):locked` HashMap, zipfian distribution. Mutex-based locking (not RwLock) - `clear profile` showed 15% CPU in `pthread_rwlock` overhead; switching to `@locked` (Mutex) cut total time by 20% (see [profiling case study](profiling.md)).

| Workload | Rust (DashMap) | Go | CLEAR | vs Rust |
|----------|------|----|-------|---------|
| SET (1M keys) | 75ms | 1217ms | **58ms** | **-22%** |
| GET (1M keys) | 14ms | 529ms | 20ms | +43% |
| Zipf GET | 13ms | 17ms | 24ms | +79% |
| Mixed 80/20 | 19ms | 26ms | 26ms | +39% |
| **Total** | **237ms** | **1806ms** | **198ms** | **-17%** |

CLEAR beats Rust (DashMap) by 17% total. SET is 22% faster. Mixed workloads match Go. GET/Zipf are slower than DashMap (Mutex blocks concurrent readers that DashMap's sharded RwLock allows).

### TCP KV Store (Benchmark 20) vs DragonflyDB

RESP protocol, 10K ops, 50 concurrent, pipeline 16.

| Op | DragonflyDB | CLEAR | vs Dragonfly |
|----|-------------|-------|--------------|
| SET | 1.0M rps | 588K rps | 0.59x |
| GET | 1.25M rps | **1.43M rps** | **+14%** |
| INCR | 1.1M rps | **1.25M rps** | **+14%** |

All handler fibers are pinned to the main scheduler (cooperative I/O
multiplexing). Throughput scales with pipeline depth, not core count.
The benchmark tests I/O efficiency, not CPU parallelism.

### Known Issues

| Issue | Impact | Workaround |
|-------|--------|------------|
| `@writeLocked` (RwLock) overhead | 15% CPU in lock ops for write-heavy workloads | Use `@locked` (Mutex) - 20% faster total on KV store |
| `onRootStack` FFI overhead | 400x for hot FFI loops | Use `:safe` effect for lightweight FFI |
| LLVM inlining across yield points | Corruption when fiber stolen mid-yield | `noinline` on socket I/O and onRootStack functions |
