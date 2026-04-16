# Benchmarks

## Running

```bash
# Single benchmark (auto-detects C/Go/Rust baselines)
ruby benchmarks/runner.rb benchmarks/01_stack_vs_heap/

# All benchmarks (01-09)
ruby benchmarks/runner.rb

# All benchmarks (01-19)
ruby benchmarks/runner.rb --all

# Specific benchmark by path
ruby benchmarks/runner.rb benchmarks/22_pool_vs_multiowned/
```

The runner automatically:
- Transpiles `.cht` → Zig → binary (ReleaseFast)
- Compiles C (`bench.c`), Rust (`bench.rs`/`Cargo.toml`), and Go (`bench.go`) baselines if present
- Runs best-of-5 wall-clock timing for each language
- Reports CLEAR vs C/Go/Rust overhead percentages
- Uses jemalloc if available (`LD_PRELOAD`)
- Sets `CLEAR_THREADS` from env or `nproc`

## Memory benchmarks

Benchmarks 21-23 report memory consumption alongside timing using two stdlib functions:

- `currentMemoryKb()` — VmRSS from `/proc/self/status` (current physical memory)
- `peakMemoryKb()` — VmHWM from `/proc/self/status` (high-water mark)

These read `/proc/self/status` directly, so they work identically in C and Go baselines for cross-language comparison.

To run memory-aware benchmarks individually (control thread count):

```bash
# Single-threaded (lowest RSS, fair comparison to single-threaded C/Go)
CLEAR_THREADS=1 ./benchmarks/21_frame_vs_heap/bench_clear

# Multi-threaded (adds ~2 MB per worker scheduler)
CLEAR_THREADS=2 ./benchmarks/21_frame_vs_heap/bench_clear
```

**Important: Build mode affects stack usage and memory.**
- The runner uses `-O ReleaseFast` — smallest binaries, lowest RSS.
- `-OReleaseSafe` adds bounds/overflow checks that significantly inflate stack frames. Fiber stacks that are sufficient under ReleaseFast may overflow under ReleaseSafe, causing segfaults. If debugging fiber crashes, use `-OReleaseFast` or increase the fiber stack size (`@service` = 2 MB).
- `-ODebug` disables inlining, so stack frames are smaller individually but function call depth is preserved. Useful for stack traces but not representative of production performance.

## Benchmark index

| # | Name | What it measures | Cross-language |
|---|------|-----------------|----------------|
| 01 | call_overhead | Recursive fib — call overhead and stack frame cost | C, Rust |
| 02 | sroa | Scalar replacement of aggregates | C, Rust |
| 03 | alloc_throughput | Heap alloc+fill+sum+free (10K x 10K elements) | C, Rust |
| 04 | socket_throughput | TCP echo throughput | C, Rust |
| 05 | hashmap | HashMap insert + lookup (1M keys) | C, Rust |
| 06 | string_builder | String concatenation via list+join | C |
| 07 | simd | Vec4 dot product (100M iterations) | C |
| 08 | pointer_chase | Pool-based linked traversal (1M nodes) | C |
| 09 | sort | Quicksort + mergesort (1M elements) | C |
| 10 | concurrent_search | Parallel file search with fibers | Rust, Go |
| 11 | atomic_contention | 1024 fibers contending on one atomic | Go |
| 12 | fanout_fanin | Fan-out 10K work items to 8 workers | Rust, Go |
| 13 | backpressure | 100K items with worker backpressure | Rust, Go |
| 14 | dynamic_spawn | Spawn + collect 10K fibers | Rust, Go |
| 15 | stream_merge | Merge sorted streams | Rust, Go |
| 16 | pubsub | 64 subscribers, 100K messages each | Rust, Go |
| 17 | kvstore | KV store: uniform + Zipfian workloads | Rust, Go |
| 18 | shard_vs_locked | @sharded vs @locked HashMap contention | - |
| 19 | parallel_aggregation | SHARD pipeline on sharded HashMap | Rust, Go |
| 20 | tcp_kvstore | TCP RESP protocol key-value server | - |
| 21 | frame_vs_heap | Frame allocation vs heap escape + memory | C, Go |
| 22 | pool_vs_multiowned | Fixed-capacity Pool vs List insert + memory | C, Go |
| 23 | pipeline_overhead | Pipeline abstraction tax + memory | C, Go |

## Planned benchmarks

| # | Name | What it measures |
|---|------|-----------------|
| - | fastmath | Float SROA/DCE quality: measures how aggressively each compiler eliminates dead float writes (fast-math skews Rust, making cross-language comparison invalid without a separate benchmark) |

## Adding a new benchmark

1. Create `benchmarks/NN_name/bench.cht` with a `FN main()` entry point
2. Optionally add `bench.c`, `bench.go`, `bench.rs` for cross-language baselines
3. For memory reporting, use `currentMemoryKb()` and `peakMemoryKb()`
4. Run: `ruby benchmarks/runner.rb benchmarks/NN_name/`
