# Benchmark 29: RwLock Writer Starvation

Tests whether a language's RwLock starves writers under heavy read contention.

## Setup

- N-1 reader threads/fibers each hold the read lock for ~busyWork(100), loop 2M times
- 1 writer thread/fiber acquires the exclusive lock, loops 1K times
- Measures: total time, writer completion time, avg/max write wait per acquire

## Results (32 threads, Linux x86_64)

| Lang  | Total  | Writer Done | Max Write Wait | Starved? |
|-------|--------|-------------|----------------|----------|
| CLEAR | 5.6s   | 15-83ms     | 1-2ms          | No       |
| Go    | 2.9s   | 14ms        | 25us           | No       |
| Rust  | 6.2s   | 77ms        | 1.8ms          | No       |

All three languages use writer-preferring RwLock implementations, so none exhibit
writer starvation.

## Analysis

**CLEAR**: Uses `pthread_rwlock_t` initialized with `PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP`.
This blocks new readers once a writer is waiting, preventing starvation. Writer completes
in 15-83ms with 1-2ms max wait per acquire.

**Go (sync.RWMutex)**: Custom writer-preferring implementation. Once a writer calls
Lock(), new RLock() calls block until the writer finishes. Writer completes in 14ms.

**Rust (std::sync::RwLock)**: Custom futex-based RwLock (not pthread). Writer-preferring.
Writer sees brief contention (1.8ms max) but is never starved.

### History: glibc reader-preferring default

Before this fix, CLEAR used Zig's `std.Thread.RwLock` which zero-initializes
`pthread_rwlock_t`. On glibc, zero-initialized = `PTHREAD_RWLOCK_PREFER_READER_NP`
(reader-preferring). This caused severe writer starvation: the writer was blocked
for 5+ seconds (the entire benchmark duration) because new readers continuously
acquired the lock ahead of the waiting writer.

The fix: initialize with `PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP` (value 2),
a glibc extension that blocks new `rdlock()` calls once a `wrlock()` is pending.
This matches Go and Rust behavior. The `_NONRECURSIVE` suffix means a thread holding
a read lock cannot recursively re-acquire it (deadlock instead). CLEAR's `WITH` block
semantics already prevent recursive locking, so this is safe.

## Running

```bash
ruby benchmarks/runner.rb --smoke benchmarks/29_rwlock_starvation/   # CLEAR only
ruby benchmarks/runner.rb --fast benchmarks/29_rwlock_starvation/    # All langs
ruby benchmarks/runner.rb benchmarks/29_rwlock_starvation/           # Full run
```
