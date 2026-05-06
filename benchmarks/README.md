# Benchmarks

Benchmarks are organized into three categories:

- **sequential/** - single-threaded compute, memory, and language-feature benchmarks
- **concurrent/** - fiber scheduling, BG blocks, channels, contention benchmarks
- **server/** - TCP/HTTP server benchmarks with client load generators

## ⚠️ Disclaimer ⚠️

These benchmarks are purely to guide the development of CLEAR.

They consistently show CLEAR outperforming Go and/or Rust in a number of metrics where - with better more scientific benchmarks - CLEAR would be unlikely to outperform them.

Most sequential benchmarks are meant to compare to "Perfect C". Nothing is expected to beat "Perfect C". These benchmarks should separate things that are easy to write "Perfect C". Some of them have known issues where C is not performing as well as it's eventually *intended* to. Sequential Rust benchmarks are meant to compare idiomatic Rust to C (so this would include RefCell/Cell overhead rather than comparing unsafe Rust). *Most* Rust benchmarks should also not be beatable - at best CLEAR should tie.

Concurrent benchmarks are far less easy to compare fairly. They should be interpretted with a **HUGE GRAIN OF SALT**. They are not designed to favor CLEAR, but the benchmarks are a strange mix of 1) compute heavy, 2) I/O / wait heavy, 3) micro benchmarks.

At this stage, they are meant to show that CLEAR is moving in the right direction, and has some reasonable level of performance.

CLEAR is not meant to be seriously considered for use at this stage. More effort will be put into making truly fair and valuable benchmarks when CLEAR is ready for actual adoption.

## Running

```bash
# Category flags
ruby benchmarks/runner.rb --sequential         # all sequential benchmarks
ruby benchmarks/runner.rb --concurrent         # all concurrent benchmarks
ruby benchmarks/runner.rb --server             # all server benchmarks
ruby benchmarks/runner.rb --all                # all three categories

# Default (no flag): sequential/01-09
ruby benchmarks/runner.rb

# Single benchmark
ruby benchmarks/runner.rb benchmarks/sequential/04_hashmap/
ruby benchmarks/runner.rb benchmarks/concurrent/09_kvstore/
ruby benchmarks/runner.rb benchmarks/server/02_json_api/

# Speed / load flags
ruby benchmarks/runner.rb --smoke benchmarks/server/02_json_api/  # CLEAR only, 0.1x scale (~5s)
ruby benchmarks/runner.rb --fast  benchmarks/sequential/04_hashmap/ # All langs, 0.25x scale
ruby benchmarks/runner.rb --release benchmarks/sequential/04_hashmap/ # 5x scale, best of 5
ruby benchmarks/runner.rb --smoke --all                            # Smoke test everything
ruby benchmarks/runner.rb --leak --all --bencher-json bencher.json  # Leak checks + Bencher BMF JSON

# Core count
ruby benchmarks/runner.rb --cores=2 benchmarks/concurrent/09_kvstore/
```

## Bencher CI

Leak-mode benchmark CI writes Bencher JSON for each shard and uploads it with `bencher run`.
GitHub Actions needs:

- `secrets.BENCHER_API_TOKEN` -- Bencher API token
- `vars.BENCHER_PROJECT` -- optional Bencher project slug; CI defaults to `clear` when unset
- `vars.BENCHER_TESTBED` -- optional; defaults to `ubuntu-latest`

The runner automatically:
- Transpiles `.cht` -> Zig -> binary (ReleaseFast)
- Compiles C (`bench.c`), Rust (`bench.rs`/`Cargo.toml`), and Go (`bench.go`) baselines if present
- Runs best-of-5 wall-clock timing for each language
- Reports CLEAR vs C/Go/Rust overhead percentages
- Uses jemalloc if available (`LD_PRELOAD`)
- Sets `CLEAR_THREADS` from env or `nproc` (overridden by a `THREADS` file in the benchmark dir)

## Sequential benchmarks

Pure single-threaded performance. All use `CLEAR_THREADS=1` implicitly (no scheduler work items).

| # | Name | What it measures | Cross-language |
|---|------|-----------------|----------------|
| 01 | call_overhead | Recursive fib -- call overhead and stack frame cost | C, Rust |
| 02 | sroa | Scalar replacement of aggregates | C, Rust |
| 03 | alloc_throughput | Heap alloc+fill+sum+free (10K x 10K elements) | C, Rust |
| 04 | hashmap | HashMap insert + lookup (1M i64 keys) | C, Rust |
| 05 | string_builder | String concatenation via list+join | C |
| 06 | simd | Vec4 dot product (100M iterations) | C |
| 07 | pointer_chase | Pool-based linked traversal (1M nodes) | C |
| 08 | sort | Quicksort + mergesort (1M elements) | C |
| 09 | frame_vs_heap | Frame allocation vs heap escape + memory | C, Go |
| 10 | pool_vs_multiowned | Fixed-capacity Pool vs List insert + memory | C, Go |
| 11 | pipeline_overhead | Pipeline abstraction tax + memory | C, Go |
| 12 | weak_ref_graph | Weak reference graph traversal | C |
| 13 | soa_layout | SOA vs AOS layout (100K particles x 100 iters) | C, Rust |
| 14 | iterator | Zero-copy borrowed iteration vs indexed loop | C, Rust |

## Concurrent benchmarks

Exercises CLEAR's fiber scheduler, BG blocks, channels, and synchronization primitives.
Comparisons are against Go goroutines and Rust/Tokio tasks.

| # | Name | What it measures | Cross-language |
|---|------|-----------------|----------------|
| 01 | socket_throughput | TCP echo throughput | C, Rust |
| 02 | concurrent_search | Parallel file search with fibers | Rust, Go |
| 03 | atomic_contention | 1024 fibers contending on one atomic | Go |
| 04 | fanout_fanin | Fan-out 10K work items to 8 workers | Rust, Go |
| 05 | backpressure | 100K items with worker backpressure | Rust, Go |
| 06 | dynamic_spawn | Spawn + collect 100K fibers | Rust, Go |
| 07 | stream_merge | Merge sorted streams | Rust, Go |
| 08 | pubsub | 64 subscribers, 100K messages each | Rust, Go |
| 09 | kvstore | KV store: uniform + Zipfian workloads | Rust, Go |
| 10 | shard_vs_locked | @sharded vs @locked HashMap contention | - |
| 11 | parallel_aggregation | SHARD pipeline on sharded HashMap | Rust, Go |
| 12 | false_sharing | False sharing detection and avoidance | C, Rust, Go |
| 13 | rwlock_starvation | RWLock reader/writer starvation patterns | Rust, Go |
| 14 | nested_lock | Nested mutex acquisition (bank transfer) | Rust, Go |

## Server benchmarks

TCP/HTTP server workloads. These require a client load generator and measure RPS/latency,
not wall time. Use `--server` to run them.

| # | Name | What it measures | Cross-language |
|---|------|-----------------|----------------|
| 01 | tcp_kvstore | TCP RESP protocol key-value server | DragonflyDB |
| 02 | json_api | TCP JSON server (FFI-heavy, wrk load) | Rust, Go |
| 03 | pathological | Worst-case allocation/contention patterns | Rust, Go |

## Memory benchmarks

Sequential benchmarks 09-11 report memory consumption alongside timing:

- `currentMemoryKb()` -- VmRSS from `/proc/self/status`
- `peakMemoryKb()` -- VmHWM from `/proc/self/status`

```bash
# Single-threaded (lowest RSS, fair comparison to single-threaded C/Go)
CLEAR_THREADS=1 ./benchmarks/sequential/09_frame_vs_heap/bench_clear

# Multi-threaded (adds ~2 MB per worker scheduler)
CLEAR_THREADS=2 ./benchmarks/sequential/09_frame_vs_heap/bench_clear
```

## Per-benchmark overrides

Two override files can be placed in any benchmark directory:

- `TIMEOUT` -- integer seconds; overrides `RUN_TIMEOUT` for that benchmark
- `THREADS` -- integer; fixes `CLEAR_THREADS` for that benchmark (e.g. `1` for single-core workloads)

## Adding a new benchmark

1. Choose the right category directory (`sequential/`, `concurrent/`, or `server/`)
2. Number it next in sequence within that category
3. Create `bench.cht` with a `FN main()` entry point
4. Optionally add `bench.c`, `bench.go`, `bench.rs` for cross-language baselines
5. For memory reporting, use `currentMemoryKb()` and `peakMemoryKb()`
6. Run: `ruby benchmarks/runner.rb benchmarks/<category>/NN_name/`
