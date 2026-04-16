# Benchmark 11: Atomic Contention

1024 fibers/goroutines each increment a shared counter 10 000 times.
Expected total: 10 240 000.

## What each implementation actually does

- **CLEAR**: `c @local` pins all BG fibers to the **same single scheduler**.
  Execution is cooperative and single-threaded within that scheduler.
  `c.value += 1` is a plain struct field increment -- no atomics, no mutex,
  no memory barrier. The counter's cache line stays in L1 Modified state for
  the entire run. Zero bus traffic. Zero lock overhead.

- **Go**: `atomic.AddInt64` is a hardware atomic RMW (`LOCK XADD`). With
  GOMAXPROCS > 1, goroutines run on multiple OS threads and the counter's
  cache line bounces between L1 caches on every increment. This is the
  "parallelism tax" for shared mutable state under M:N scheduling.

## This is NOT a head-to-head performance comparison

Go is doing genuine cross-core concurrent work; CLEAR is doing cooperative
single-threaded work. CLEAR is faster here not because its runtime is
faster, but because it is doing fundamentally less work -- `@local` is an
opt-in escape hatch that trades parallelism for zero-overhead shared mutation.

The right framing is: **CLEAR gives you a language-level primitive to
eliminate atomic contention when you don't need parallelism.** The code is
three lines and requires no Mutex, no channel, no RwLock.

## @local: the feature

```
MUTABLE c = Counter{ value: 0 } @local;

FOR i IN (0 ..< 1024) DO
    futures.append(BG { FOR j IN (0 ..< 10000) -> c.value += 1; });
END
```

`@local` on the binding tells the compiler: all BG blocks that capture `c`
must be scheduled on the local fiber scheduler. The compiler enforces this
at the call site -- it is a compile-time guarantee, not a runtime lock.
No synchronization primitives are needed or inserted.

## No Rust implementation

Rust's equivalent for cross-core shared mutation is `Arc<AtomicI64>`, which
is the same `LOCK XADD` pattern as Go. Rust has no equivalent of `@local`
in the standard library (you would reach for a thread-local or a
single-threaded executor, neither of which is idiomatic for this pattern).
A Rust `@local`-equivalent would match CLEAR's numbers for the same reason:
no atomics. This benchmark is not about Rust's performance -- it is about
the language primitive.

## Results

```
             Go (atomic)   CLEAR (@local)
all cores       ~6ms            ~4ms
```

Go's time reflects real parallel work with cache-line contention.
CLEAR's time reflects sequential cooperative increments with no memory
barriers -- a different workload entirely.
