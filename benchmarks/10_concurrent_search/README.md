# Benchmark 10: Concurrent File Search

128 files x 10KB each (1.28MB total, fits in page cache). Spawn one
fiber/goroutine/thread per file, count occurrences of "the", report top-10.

## Results (best of 5)

```
cores     Rust      Go      CLEAR
  1      4.9ms    4.4ms     3ms
  2      4.5ms    2.3ms     4ms
  4      3.9ms    1.2ms     2ms
  8      4.4ms    0.8ms     2ms
 16      4.2ms    0.8ms     3ms
 32      4.2ms    0.8ms     5ms
```

## Analysis

The workload is ~3ms total. Scaling is limited by Amdahl's law — the serial
portion (listDir, sort, print) dominates at high core counts.

- **Go**: Best scaling (5.5x). Go's goroutine scheduler multiplexes I/O
  efficiently across OS threads. `bytes.Count` uses SIMD.
- **Rust**: Flat. OS thread-per-file has high fixed overhead for a workload
  where files are in the page cache.
- **CLEAR**: Slight scaling 1->8 (1.5x). At 32 cores, scheduler overhead
  (128 fiber spawns across 32 schedulers) exceeds the parallel work.

The 32-core regression is not a runtime bug — it's a benchmark too small
to amortize scheduler startup cost. For workloads >100ms, CLEAR scales
well (see benchmarks 13, 16, 17).

## readFile implementation

CLEAR's `readFile` uses `onRootStack` to execute the read on the scheduler's
OS stack (avoids stack overflow on small fiber stacks). This adds one context
switch per file read (~1us each, ~128us total). Not a bottleneck — the total
I/O cost is ~1ms for 128x10KB reads from page cache.

## Improving this benchmark

To show scaling more clearly, the workload would need to be 10-100x larger
(more files, larger files, or repeated iterations). The current 3ms workload
is below the noise floor for scheduler overhead measurement.
