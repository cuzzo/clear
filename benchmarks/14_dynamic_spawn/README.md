# Benchmark 14: Dynamic Spawn

Spawns 100K individual fibers/goroutines/tasks, each doing 10K LCG
iterations of CPU-bound work. Measures per-spawn overhead + parallel
execution.

## Known Issue: Idle Scheduler Spinning

**This benchmark is not a good scaling test.** At high core counts, CLEAR's
idle schedulers spin on work-stealing instead of parking. The actual work
completes quickly, but 31 idle schedulers waste cycles competing for the
work-steal deque. At 8 threads CLEAR matches Go; at 32 threads the idle
spinning adds ~30% overhead.

```
threads    CLEAR     Go
  4        161ms   ---
  8        152ms   159ms   (parity)
 32        200ms    58ms   (+245%)
```

The fix is scheduler parking (idle schedulers sleep instead of spin). This
is tracked for post-v0.1.

## Results (32 cores, best of 5)

```
Rust (tokio)     93ms
Go (goroutines)  58ms
CLEAR (fibers)  200ms   (+245% vs Go)
```

## Why Rust is fast

Tokio tasks are heap-allocated state machines (~few hundred bytes). There
is no stack allocation per task. Spawn cost is ~0.8us/task regardless of
core count.

CLEAR and Go both allocate a stack per fiber/goroutine (16KB and 2KB
respectively). This makes their spawn overhead 10-100x higher per task.

## Profile breakdown (32 cores)

```
38.5%  actual user work (doWork LCG loop)
11.8%  scheduler main loop (work-stealing spin)
10.3%  drainChannels (processing SPSC spawn messages)
10.0%  malloc/free (Fiber + Task struct allocation)
 7.1%  submitSpawn (queueing spawn messages)
 5.7%  main fiber spawning loop
```

Only 38.5% of CPU goes to real work. The rest is scheduler overhead,
dominated by idle work-stealing and per-fiber GPA allocations.

## This is a micro-benchmark

This benchmark tests the worst-case spawn pattern: 100K individual BG
blocks in a sequential loop. Real CLEAR code uses CONCURRENT EACH for
batch parallelism:

```clear
-- Individual spawn (what this benchmark tests):
FOR i IN (0_i64 ..< 100000) -> futures.append(BG { doWork(i); });

-- Batch parallelism (idiomatic CLEAR):
results = (0_i64 ..< 100000) s> CONCURRENT EACH doWork(_);
```

CONCURRENT EACH distributes work across schedulers without per-item fiber
allocation. It is the correct tool for parallelizing a batch of identical
compute tasks.

Individual BG spawn matters for patterns like "one fiber per incoming
request" where tasks arrive over time rather than in a batch. CLEAR
matches Go's performance at 8 threads for this pattern.
