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

## Scaling (32 cores, normal mode, best of 5)

### Concurrent Compute

| Benchmark | Rust | Go | CLEAR | vs Rust | Scaling |
|-----------|------|----|-------|---------|---------|
| 12 Fan-Out/Fan-In | 7.5ms | 42.8ms | **7ms** | **-7%** | 10.4x (1->32c) |
| 13 Backpressure | 56ms | 69ms | **12ms** | **-79%** | 5.8x |
| 15 Stream Merge | 83ms | 61ms | 265ms | +215% | flat |
| 16 Pub/Sub | 2945ms | 826ms | **83ms** | **-97%** | 4.6x |

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
