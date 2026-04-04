# Benchmark 15: Stream Merge

8 BG STREAM producers each yield 100K values. Consumer reads round-robin
from all 8 streams, sums values. Total: 800K values.

## Known Issue: Rendezvous Overhead

**CLEAR's InfStream is a single-slot rendezvous channel.** Each YIELD/NEXT
pair requires a full fiber context switch (~200ns). 800K values = 1.6M
context switches.

Go's buffered channel (capacity 64) lets producers batch 64 values before
blocking. This means ~64x fewer context switches for the same throughput.

```
              CLEAR     Go     Rust
1 thread      316ms    33ms    91ms
32 threads    335ms    62ms    82ms
```

CLEAR's time is constant across thread counts because all 8 producers +
consumer converge on the same scheduler after the first yield (InfStream
stores a single scheduler pointer). No parallelism is exploited.

## Results (32 cores, best of 5)

```
Rust (crossbeam)    82ms
Go (buffered chan)   62ms
CLEAR (InfStream)  335ms   (+443% vs Go)
```

## Profile breakdown (32 cores)

```
40%  Scheduler.run (idle work-stealing on 31 empty schedulers)
18%  kernel (syscalls)
 7%  InfStream.next (spinlock + read)
 6%  schedule (submitResume, now uses same-scheduler fast path)
24%  SgCtx*.run (actual producer work)
```

## Root cause: context switch per value

Per NEXT/YIELD round-trip:
- 3 spinlock acquisitions (push lock, next lock, push re-lock)
- 2 task status atomic stores
- 1 full x86-64 context switch (7 register save/restore)
- 1 ready_queue push

At 800K values, this costs ~160ms in pure context-switch overhead.

## Fix: Buffered InfStream (post-v0.1)

Add a configurable buffer to InfStream (e.g. `~Int64[INF, buf: 64]`).
Producer fills the buffer without blocking, consumer drains it without
switching. This would reduce context switches by ~64x, closing the gap
with Go's buffered channels.

The same-scheduler fast path in submitResume (skip SPSC ring when
`self == active_scheduler`) is already implemented but has minimal effect
because SPSC overhead was <5% of the total cost.
