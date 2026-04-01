# Benchmark 14: Dynamic Spawn

Spawns 10K individual fibers/goroutines/tasks, each doing 10K LCG
iterations of CPU-bound work. Measures per-spawn overhead + parallel
execution.

## Results (best of 3)

```
cores     Rust      Go      CLEAR
  1      7.8ms   128ms      81ms
  2      8.2ms    65ms      37ms
  4      8.6ms    33ms      19ms
  8      8.7ms    16ms      16ms
 16      7.7ms     8ms      19ms
 32      9.1ms     7ms      23ms
```

## Why Rust is flat at ~8ms

Tokio tasks are heap-allocated state machines (~few hundred bytes). There
is no stack allocation per task. Spawn cost is ~0.8us/task regardless of
core count - the work finishes before parallelism matters.

CLEAR and Go both allocate a stack per fiber/goroutine (16KB and 2KB
respectively). This makes their spawn overhead 10-100x higher per task.

## Why CLEAR regresses at 16-32 cores

All 10K tasks are spawned from the main scheduler's sequential loop. At
32 cores, 31 idle schedulers spin on work-stealing CAS operations against
the main scheduler's deque while it's being populated. The contention on
the deque's atomic top counter creates backpressure on the spawn path.

Phase breakdown confirms this:

```
cores   Spawn    Collect   Total
  1      58ms     23ms     81ms
  8      15ms      2ms     17ms
 32      24ms      0ms     24ms
```

Execution scales perfectly (collect = 0ms at 4+ cores). The regression is
entirely in the spawn phase due to work-stealing contention.

## This is a micro-benchmark

This benchmark tests the worst-case spawn pattern: 10K individual BG
blocks in a sequential loop. Real CLEAR code uses CONCURRENT EACH for
batch parallelism:

```clear
-- Individual spawn (what this benchmark tests):
FOR i IN (0_i64 ..< 10000) -> futures.append(BG { doWork(i); });

-- Batch parallelism (idiomatic CLEAR):
results = (0_i64 ..< 10000) s> CONCURRENT EACH doWork(_);
```

CONCURRENT EACH distributes work across schedulers without per-item fiber
allocation. It is the correct tool for parallelizing a batch of identical
compute tasks.

Individual BG spawn matters for patterns like "one fiber per incoming
request" where tasks arrive over time rather than in a batch. CLEAR
matches Go's performance at 8 cores for this pattern, which is the
relevant comparison (both use M:N fiber scheduling with stack allocation).
