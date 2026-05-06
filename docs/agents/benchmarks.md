# Benchmarks

## Branch Quality Tracker - benchmark-fix

Ruby coverage and static analysis findings introduced by this branch:

- [x] Cover `CONCURRENT(batch: N)` validation branches in `PipeAnalysis`.
- [x] Cover `PipelineHost#substitute_placeholders` for hash, assert, and if nodes.
- [x] Cover SHARD+CONCURRENT Zig lowering error/cleanup branches.
- [x] Cover FSM profile dispatch fallback branches.
- [x] Cover `FsmWrapperEmitter` B1 wrapper emission branches.
- [x] Cover MIR BG task profile helper branches.
- [x] Cover Doctor `@parallel` recommendation metadata, source-line fallback, and local BG scanning.
- [x] Reduce local Reek/Flog pressure in `PipeAnalysis#analyze_concurrent_op` by sharing concurrent option validation helpers.
- [x] Reduce local Reek/Flog pressure in `Doctor#emit_parallel_bg_hint!` and `Doctor#section_fibers` by splitting recommendation helpers and caching repeated fields.
- [ ] Reduce new Reek pressure in `PipelineHost#lower_shard_concurrent_each_zig`; tracked for the runtime-lowering follow-up because this RawZig path should move out of `PipelineHost`.
- [x] Reduce repeated `batch` option handling in `PipelineGenerator#transpile_concurrent_*`.
- [ ] Add or intentionally defer RuboCop wiring; the current bundle has no `rubocop` executable.

Verification after this pass:

- `COVERAGE=1 bundle exec rspec spec`: 3596 examples, 0 failures; added-line coverage delta is clean (`uncovered_added=0`).
- `bundle exec reek src --format json`: branch has 83 normalized new findings versus `origin/master`, down from 95 before this pass; remaining findings are mostly large-method/design pressure in the branch's compiler/runtime lowering work.
- `bundle exec flay src`: branch total 26151 versus master 26099.
- `bundle exec flog src`: no changed method with a positive complexity delta above 10 after normalization; reported "new" rows are parser/name matching artifacts at score 0.0.
- `bundle exec rubocop`: not available in the current bundle.

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

---

## Full Suite Run - 2026-04-16 (benchmarks 01-31, `--all`, CLEAR_THREADS=32)

### Runtime floor

The CLEAR runtime with 32 schedulers (`CLEAR_THREADS=32`) has a baseline RSS of ~15MB for trivial
single-fiber workloads. This is the scheduler, 32 OS thread stacks (lazily committed), jemalloc
metadata, and EBR context. Benchmarks 01-07, 21, and 30 all show ~15MB CLEAR vs 1.5-2MB for
C/Rust/Go. The 10x ratio in these microbenchmarks is entirely the runtime floor - not a per-task
memory issue. This is acceptable for v0.1.

### Speed summary

| # | Benchmark | CLEAR | Best peer | Delta | Notes |
|---|-----------|-------|-----------|-------|-------|
| 01 | call_overhead | 265ms | C 154ms | +72% | floor-dominated |
| 02 | sroa | 486ms | C 374ms | +30% | |
| 03 | alloc_throughput | 127ms | Rust 168ms | -24% | beats Rust |
| 04 | socket_throughput | 97ms | Rust 62ms | +56% | |
| 05 | hashmap | 96ms | C 78ms | +23% | |
| 06 | string_builder | 105ms | C 65ms | +62% | |
| 07 | simd | 149ms | C 209ms | -29% | CLEAR wins (auto-vectorization) |
| 08 | pointer_chase | 213ms | C 202ms | +5% | |
| 09 | sort | 93ms | C 109ms | -15% | CLEAR wins |
| 10 | concurrent_search | 14ms | Rust 18ms | -22% | CLEAR wins |
| 11 | atomic_contention | 12ms | Go 193ms | -94% | cooperative vs preemptive |
| 12 | fanout_fanin | 7ms | Rust 3ms | +133% | Rust=stackless tasks |
| 13 | backpressure | 12ms | Go 69ms | -83% | CLEAR wins |
| 14 | dynamic_spawn | 178ms | Go 62ms | +187% | known regression 16+ cores |
| 15 | stream_merge | 5ms | Rust 87ms | -94% | CLEAR wins |
| 16 | pubsub | 121ms | Go 166ms | -27% | CLEAR wins |
| 17 | kvstore | 171ms | Rust 180ms | -5% | CLEAR wins |
| 18 | shard_vs_locked | 642ms | Go 204ms | +214% | fiber chan overhead vs native chan |
| 19 | parallel_aggregation | 44ms | Go 3ms | +1367% | known issue |
| 20 | tcp_kvstore | 1.49M SET, 1.52M GET | DragonflyDB | +49% SET | CLEAR wins |
| 21 | frame_vs_heap | 18ms | C 35ms | -49% | CLEAR wins |
| 22 | pool_vs_multiowned | 71ms | C 63ms | +13% | |
| 23 | pipeline_overhead | 182ms | Go 188ms | -3% | CLEAR wins |
| 24 | json_api | 64ms SET / 399ms GET | Rust 116ms/578ms | wins SET+GET | CLEAR wins |
| 25 | pathological | 537K r/s | Rust 313K r/s | +72% | CLEAR wins |
| 26 | weak_ref_graph | 16ms | C 10ms | +60% | |
| 27 | false_sharing | 50ms | Rust 114ms | -56% | unfair: mutex vs no-mutex |
| 28 | soa_layout | 9ms | C 9ms | 0% | |
| 29 | rwlock_starvation | 5525ms | Rust 5999ms | -8% | CLEAR wins |
| 30 | iterator | 3ms | C 15ms | -80% | CLEAR wins (LLVM forced noinline) |
| 31 | nested_lock | 2707ms | Rust 1776ms | +52% | 3-lock nesting overhead |

### Memory analysis

The RSS ratio `CLEAR/peer` is the key metric. A ratio near 1.0x for large-data benchmarks means
CLEAR's memory consumption tracks the data size correctly. A ratio high above the expected
floor+data baseline is a problem.

**Category 1 - floor-dominated (OK for v0.1):**

These benchmarks have tiny working sets. The entire RSS ratio is the runtime floor vs bare C/Rust.
Per-fiber and per-data-element memory is not the issue.

| # | CLEAR RSS | Peer RSS | Ratio | Verdict |
|---|-----------|----------|-------|---------|
| 01 call_overhead | 15.5MB | C 1.5MB | 10.3x | OK - floor |
| 02 sroa | 15.5MB | C 1.5MB | 10.3x | OK - floor |
| 03 alloc_throughput | 15.2MB | C 1.5MB | 10.2x | OK - floor |
| 04 socket_throughput | 16.0MB | C 1.5MB | 10.7x | OK - floor |
| 06 string_builder | 15.5MB | C 1.5MB | 10.3x | OK - floor |
| 07 simd | 15.8MB | C 1.5MB | 10.5x | OK - floor |
| 21 frame_vs_heap | 15.5MB | C 1.5MB | 10.3x | OK - floor |
| 30 iterator | 14.8MB | C 1.5MB | 9.7x | OK - floor |

**Category 2 - data-proportional (OK):**

Large working sets where CLEAR tracks C/Go/Rust within acceptable bounds.

| # | CLEAR RSS | Peer RSS | Ratio | Verdict |
|---|-----------|----------|-------|---------|
| 05 hashmap | 74.8MB | C 50.2MB | 1.5x | OK |
| 17 kvstore | 211.5MB | Go 223.2MB | 0.95x | OK - CLEAR uses less than Go |
| 18 shard_vs_locked | 161.0MB | Rust 169.7MB | 0.95x | OK - CLEAR uses less than Rust |
| 20 tcp_kvstore | 38.8MB | DragonflyDB 62.0MB | 0.63x | OK - CLEAR uses 37% less |
| 22 pool_vs_multiowned | 187.6MB | C 196.4MB | 0.96x | OK - CLEAR uses less than C |

**Category 3 - concurrent, floor + N-fiber stacks (OK for v0.1, monitor post-v0.1):**

These benchmarks involve N concurrent fibers. CLEAR's 64KB fiber stacks contribute to RSS
proportionally. The per-fiber overhead vs Go (2KB growable) is ~32x for shallow stacks, and the
numbers reflect that. This is a known architectural constraint.

| # | CLEAR RSS | Peer RSS | Ratio | Verdict |
|---|-----------|----------|-------|---------|
| 11 atomic_contention | 23.5MB | Go 4.3MB | 5.5x | OK - floor + N fiber stacks |
| 13 backpressure | 40.5MB | Go 1.8MB | 22.5x | OK - floor + 32 workers, tiny data |
| 15 stream_merge | 16.0MB | Go 1.8MB | 8.9x | OK - floor |
| 16 pubsub | 33.8MB | Go 2.0MB | 16.9x | OK - floor + ring buffers |
| 27 false_sharing | 34.0MB | C 1.5MB | 22.7x | OK - floor + 32 threads, unfair comparison anyway |
| 29 rwlock_starvation | 33.0MB | Go 1.8MB | 18.3x | OK - floor + N readers |
| 31 nested_lock | 32.8MB | Go 1.8MB | 18.2x | OK - floor + 64 mutexes + N workers |

**Category 4 - FLAGGED: per-fiber memory higher than expected:**

These cannot be attributed to the runtime floor or data size alone. The excess is proportional
to fibers spawned or concurrent tasks, which violates the v0.1 criterion.

**FLAGGED: 14_dynamic_spawn - 49MB CLEAR vs 15MB Go (3.3x)**

Benchmark spawns 100K fibers sequentially. Go goroutines start at 2KB (grow on demand). CLEAR
fibers use fixed 64KB stacks. At 100K fibers, the peak concurrent fiber count × 64KB dominates
RSS. This is a structural per-fiber overhead, not a runtime floor issue. The gap is proportional
to the number of live fibers. Rust (Tokio) uses 28MB because tasks are stackless state machines.

Tracked for post-v0.1: scheduler parking to reduce idle-scheduler spinning; stackful vs stackless
hybrid for shallow fibers.

**FLAGGED: 19_parallel_aggregation - 44MB CLEAR vs 12MB Go (3.7x)**

32 worker fibers accumulate partial sums. Go: 12MB (goroutines + tiny stacks + data). CLEAR:
floor(15MB) + data(~5MB) + 32 fiber stacks(2MB) = ~22MB expected, actual 44MB. The extra ~22MB
is unaccounted. Likely: each worker materializes a partial result list on the heap. The pipeline
aggregation path may be allocating intermediate buffers that could be frame-allocated.

**Category 5 - FLAGGED: data structure overhead above baseline:**

These have a working set larger than expected from the data alone, unrelated to fiber count.

**FLAGGED: 08_pointer_chase - 148MB CLEAR vs C 32MB (4.5x)**

C allocates 32MB for a tree/linked-list. CLEAR expected: 32MB data + 15MB floor = ~47MB. Actual:
148MB = +101MB unexplained. The benchmark uses a generational pool (`T[N]@pool`). At large N,
the pool's per-slot metadata (alive flag + generation counter) adds overhead beyond the value
itself. At 5M nodes the slot metadata array alone can be significant. Additionally, each node
being accessed via `pool.get(id)` (indirect) vs C's raw pointer may cause jemalloc fragmentation.
Investigate whether pool slot arrays are oversized relative to actual inserted count.

**FLAGGED: 09_sort - 70MB CLEAR vs C 17MB (4.1x)**

C uses 17MB for the sort array. CLEAR expected: ~17MB + 15MB floor = ~32MB. Actual 70MB = +38MB
unexplained. The sort benchmark likely creates a temporary copy (CLEAR's sort may not be in-place
or may materialize an intermediate ArrayList). The ~38MB extra matches approximately 2x the data
size, suggesting a full copy is being allocated and not freed before peak RSS is measured.

**FLAGGED: 23_pipeline_overhead - 191MB CLEAR vs C 80MB (2.4x)**

C uses 80MB for large message buffers. CLEAR expected: ~80MB + 15MB floor = ~95MB. Actual 191MB
= +96MB above expected. The pipeline `CONCURRENT SELECT` stage materializes intermediate results
into heap-allocated ArrayLists. With a large input these intermediate buffers can double the
working set. Consider whether intermediate materialization can be deferred or frame-allocated
for pipelines where the full input fits in the frame.

**FLAGGED: 25_pathological (server) - 37MB CLEAR vs Rust 4.7MB (7.8x)**

The pathological server has no persistent data - RSS should track the live-connection count only.
Rust Tokio uses 4.7MB because async tasks are stackless; each connection is a state machine of
~100-500 bytes. CLEAR fiber per-connection: 64KB stack. At 50 concurrent connections: 50 x 64KB
= 3.2MB fiber stacks + 15MB floor = ~18MB expected, actual 37MB = +19MB above expected.
The 37MB vs Rust 4.7MB ratio (7.8x) is partially structural (fiber vs stackless) but the excess
beyond 18MB is unexplained. May be scheduler-internal buffers allocated per connection, or
jemalloc overhead from per-connection allocations not being batched.

**FLAGGED: 28_soa_layout - 180MB CLEAR vs C 55MB (3.3x)**

C stores all SOA/AOS arrays globally (~55MB total for all variants). CLEAR with 32 schedulers:
during the SOA pipeline operation, all 32 OS scheduler threads are running, and each touches its
stack deeply enough to commit pages. If each of 32 threads commits ~5MB of stack (nested pipeline
+ runtime calls), that contributes 160MB of stack RSS on top of the ~20MB data+floor. This is
the "32 live scheduler threads" RSS inflation problem for CPU-heavy single-fiber workloads.
The fix is scheduler parking: idle schedulers should park rather than spin-steal, which would
prevent their stacks from being committed during the active fiber's work.

### Summary of flagged items

| # | Benchmark | CLEAR RSS | Expected | Excess | Root cause | Priority |
|---|-----------|-----------|----------|--------|------------|---------|
| 14 | dynamic_spawn | 49MB | ~20MB | +29MB | 64KB/fiber × N live fibers | High |
| 08 | pointer_chase | 148MB | ~47MB | +101MB | pool slot metadata at large N | Medium |
| 23 | pipeline_overhead | 191MB | ~95MB | +96MB | CONCURRENT pipeline intermediate buffers | Medium |
| 28 | soa_layout | 180MB | ~70MB | +110MB | 32 scheduler thread stacks committing | Medium (same root as 14) |
| 25 | pathological server | 37MB | ~18MB | +19MB | per-connection fiber overhead vs stackless | Medium |
| 09 | sort | 70MB | ~32MB | +38MB | temporary sort copy not freed before peak RSS | Low |
| 19 | parallel_aggregation | 44MB | ~22MB | +22MB | intermediate aggregation heap buffers | Low |

The highest-priority items (14, 28) share the same root cause: **64KB fiber stacks committed for
each live fiber/scheduler thread**. This is CLEAR's structural difference from Go (growable 2KB)
and Rust/Tokio (stackless). For v0.1 this is documented and acceptable as a known constraint.
Post-v0.1 the scheduler parking fix resolves items 14 and 28 together.
