# Benchmark 29: RwLock Writer Starvation

Tests whether a language's RwLock starves writers under heavy read contention.

## Setup

- N-1 reader threads/fibers each hold the read lock for ~busyWork(100), loop 2M times
- 1 writer thread/fiber acquires the exclusive lock, loops 1K times
- Measures: total time, writer completion time, avg/max write wait per acquire

## Results (32 threads, Linux x86_64)

| Lang  | Total  | Writer Done | Max Write Wait | Starved? |
|-------|--------|-------------|----------------|----------|
| CLEAR | 5.4s   | 5.2s        | 5.1s           | YES      |
| Go    | 2.9s   | 14ms        | 25us           | No       |
| Rust  | 6.4s   | 77ms        | 1.8ms          | No       |

## Analysis

**CLEAR (Zig std.Thread.RwLock)**: Severe writer starvation. The writer is blocked
for nearly the entire benchmark duration. Zig's RwLock is reader-preferring -- new
readers can acquire the lock while a writer is waiting, so a steady stream of
overlapping readers starves the writer indefinitely.

**Go (sync.RWMutex)**: No starvation. Go's RWMutex is writer-preferring -- once a
writer calls Lock(), new RLock() calls block until the writer finishes. The writer
completes in 14ms despite 31 concurrent readers.

**Rust (std::sync::RwLock / pthread_rwlock)**: No starvation on Linux. Linux's
pthread_rwlock is writer-preferring -- pthread_rwlock_wrlock blocks incoming readers
once a writer is waiting. The writer sees brief contention (1.8ms max) but is never
starved.

## Implications for CLEAR

CLEAR's `@shared:writeLocked` (Arc<RwLock<T>>) should not be used for write-heavy or
write-latency-sensitive workloads under read contention. Alternatives:

- `@shared:locked` (Arc<Mutex<T>>) -- no reader/writer distinction, FIFO fairness
- `@sharded(N):locked` -- partition data to reduce contention
- Application-level batching -- accumulate writes and apply under a single lock acquire

## Running

```bash
ruby benchmarks/runner.rb --smoke benchmarks/29_rwlock_starvation/   # CLEAR only
ruby benchmarks/runner.rb --fast benchmarks/29_rwlock_starvation/    # All langs
ruby benchmarks/runner.rb benchmarks/29_rwlock_starvation/           # Full run
```
