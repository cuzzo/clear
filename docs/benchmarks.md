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

CLEAR, Rust/Tokio, and Go achieve similar throughput within ~5% for typical server workloads. CLEAR and Rust use roughly half the peak memory of Go (no garbage collector).

| Server | SET (ms) | GET (ms) | Verified |
|--------|----------|----------|----------|
| Rust/Tokio | 1292 | 20830 | 10000/10000 |
| Go | 1252 | 20393 | 10000/10000 |
| **CLEAR** | **1089** | 21080 | 10000/10000 |

*10K GETs, 50 concurrent connections, all verified.*

## Multi-Core, Adversarial (Benchmark 25: Pathological Workloads)

NOTE: CLEAR performs well in these benchmarks, but in the ugly world of reality, it is highly unlikely to be this competitive with Go at p99.9 in adversarial workloads.

Benchmark 25 tests scheduler fairness under adversarial load using iterated SHA256 hashing. Three phases: uniform (all equal), skewed (1% of requests 1000x heavier), and adversarial (one connection does all heavy work).

**Phase 1: Uniform (50K requests, 50 concurrent)**

| Server | p50 | p99 | p99.9 | Throughput |
|--------|-----|-----|-------|------------|
| Rust/Tokio | 4.89 ms | 12.86 ms | 16.65 ms | 9228 req/s |
| Go | 5.50 ms | 16.14 ms | 26.82 ms | 8043 req/s |
| CLEAR | 5.36 ms | 14.21 ms | 18.52 ms | 8418 req/s |

**Phase 2: Skewed (1% of requests 1000x heavier, 50K requests, 50 concurrent)**

| Server | p50 | p99 | p99.9 | Throughput |
|--------|-----|-----|-------|------------|
| Rust/Tokio | 4.30 ms | 32.69 ms | 59.12 ms | 7015 req/s |
| Go | 4.10 ms | 25.82 ms | 36.86 ms | 7733 req/s |
| **CLEAR** | 4.18 ms | **23.71 ms** | **33.71 ms** | **8086 req/s** |

**Phase 3: Adversarial (1 connection all-heavy, 49 all-light, 50K requests, 50 concurrent)**

| Server | p50 | p99 | p99.9 | Throughput |
|--------|-----|-----|-------|------------|
| Rust/Tokio | 3.21 ms | 34.80 ms | 73.75 ms | 2868 req/s |
| Go | 2.95 ms | 15.63 ms | 30.54 ms | 3492 req/s |
| **CLEAR** | **2.80 ms** | 16.36 ms | **21.41 ms** | **3635 req/s** |

CLEAR wins on throughput and p99.9 in the adversarial phase. Go's preemptive scheduler gives it the best p99 under adversarial load, but CLEAR's cooperative scheduling with per-iteration yields is competitive across all percentiles.

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

## SCALING

```

  ┌──────────────────────┬──────────────────────────────────────┬─────────────┬─────────┐
  │      Benchmark       │              2c -> 32c               │ vs Rust 32c │ Verdict │
  ├──────────────────────┼──────────────────────────────────────┼─────────────┼─────────┤
  │ 16 pubsub            │ 541ms -> 118ms (4.6x)                │ -96%        │ GREAT   │
  ├──────────────────────┼──────────────────────────────────────┼─────────────┼─────────┤
  │ 13 backpressure      │ 69ms -> 33ms (2.1x)                  │ -46%        │ GOOD    │
  ├──────────────────────┼──────────────────────────────────────┼─────────────┼─────────┤
  │ 17 kvstore           │ 916ms -> 241ms (3.8x)                │ +9%         │ GOOD    │
  ├──────────────────────┼──────────────────────────────────────┼─────────────┼─────────┤
  │ 15 stream_merge      │ 65ms -> 79ms (flat)                  │ -11%        │ OK      │
  ├──────────────────────┼──────────────────────────────────────┼─────────────┼─────────┤
  │ 12 fanout_fanin      │ 78ms -> 31ms (2.5x)                  │ +171%       │ MIXED   │
  ├──────────────────────┼──────────────────────────────────────┼─────────────┼─────────┤
  │ 10 concurrent_search │ 8ms -> 25ms (negative)               │ +164%       │ BAD     │
  ├──────────────────────┼──────────────────────────────────────┼─────────────┼─────────┤
  │ 11 atomic_contention │ 26ms -> 48ms (negative)              │ --          │ BAD     │
  ├──────────────────────┼──────────────────────────────────────┼─────────────┼─────────┤
  │ 14 dynamic_spawn     │ 47ms -> 42ms (erratic, 1106ms at 8c) │ +238%       │ BAD     │
  ├──────────────────────┼──────────────────────────────────────┼─────────────┼─────────┤
  │ 19 parallel_agg      │ 984ms -> 997ms (flat)                │ --          │ BAD     │
  └──────────────────────┴──────────────────────────────────────┴─────────────┴─────────┘
```
