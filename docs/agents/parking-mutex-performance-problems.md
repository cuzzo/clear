# ParkingMutex performance problems

## TL;DR

`lib/parking-lot.zig`'s `ParkingMutex` is **>11.8x slower than `compat.Mutex`
(`pthread_mutex_t`)** on the `08_pubsub` benchmark — `compat.Mutex` runs in
0.169s, ParkingMutex hits the bench harness's 2s TIMEOUT. This blocks the
fiber-runtime correctness fix that motivated the migration: switching
`lib/streams.zig`'s `Inner.mutex` from `compat.Mutex` to `ParkingMutex` so
contended fibers yield to the scheduler instead of blocking the OS thread.

A real fix needs ParkingMutex's hot path rewritten or a hybrid
spin-then-park lock added. **Until then, `lib/streams.zig` and
`lib/data-structures.zig` keep `compat.Mutex` and the latent OS-thread
blocking issue.**

## The motivating production issue

`compat.Mutex` is a literal `pthread_mutex_t` (see `zig/lib/compat.zig:4`).
When fiber A holds the mutex and fiber B (potentially on the same OS
thread) tries to lock, B blocks at the kernel via `futex_wait`. Every
other fiber scheduled on B's thread also stops running until A releases.
For a fiber runtime, that's a thread-stall hazard.

Affected files (compat-lock instances grep'd 2026-05-08):

| File | Lock instance |
|---|---|
| `lib/streams.zig:131` | `Inner.mutex: compat.Mutex` |
| `lib/data-structures.zig:1224` | `mutex: compat.Mutex` |
| `lib/data-structures.zig:2674` | `lock: compat.RwLock` |
| `lib/data-structures.zig:2796` | `lock: compat.Mutex` |
| `lib/data-structures.zig:2981` | `lock: compat.Mutex` |

`lib/observable.zig` has zero `compat.Mutex` -- it's all atomics.

## What was tried

### Attempt 1 — drop-in replacement

Change `Inner.mutex: compat.Mutex` → `Inner.mutex: pl.ParkingMutex`,
update all `mutex.lock();` call sites to `mutex.lock() catch unreachable;`.
Production semantics: `lock()` includes cycle detection (`detectCycle`)
and a 100ms (debug) / 30s (release) timeout scanner.

Result on TSan stress test "SplitStream survives multithreaded spawnBest
pubsub hammer" (16 subscribers + 7 worker schedulers + 4096 messages):

```
LOCK TIMEOUT: fiber Task@... waited for mutex ParkingMutex@...
thread panic: attempt to unwrap error: LockTimeout
```

The 100ms debug timeout was too aggressive under TSan-instrumented
timing. Even bumping it to 30s, the same test failed with
`expected 17, found 0` — zero subscribers completed within the test's
15s deadline. Diagnostic counters revealed:

```
completed=0/17 push_enter=294 push_locked=293 push_unlocked=292
next_enter=84 next_locked=84 next_park=16 next_returned=55 wake_fired=16
```

Producer pushed 292 messages in 15s ≈ 50ms per push cycle. Consumers
received 55 values total across 16 subscribers. compat.Mutex (pthread)
finished the same workload comfortably; ParkingMutex couldn't keep up.

### Attempt 2 — variant skipping deadlock protection

Added `lockNoCycle()` method gating both `detectCycle` and
`registerLockWaiter` (the timeout scanner registration) on a comptime
`cycle_check` parameter. The intent: streams don't form lock graphs,
so cycle detection and timeout protection are pure overhead.

Result: same `expected 17, found 0` failure. Skipping the bookkeeping
didn't change the underlying throughput limit.

### Attempt 3 — benchmark to confirm direction

`08_pubsub` benchmark (1 publisher × 64 subscribers × 10K messages, all
flowing through one `SplitStream`):

| | BEFORE (compat.Mutex) | AFTER (ParkingMutex) |
|---|---|---|
| Time | 0.169s | TIMEOUT (>2s) |
| vs Go (goroutines) | -13.78% | catastrophic |
| vs Rust (tokio) | -80.39% | catastrophic |

That's the stop sign: the migration regresses real-world pubsub
workloads by at least an order of magnitude.

## Why ParkingMutex is so much slower

ParkingMutex's slow path on contention:

1. `queue_spin` acquire (atomic CAS loop on internal queue lock)
2. `state.fetchOr(STATE_HAS_WAITERS)` (atomic RMW)
3. Push waiter node to `self.waiters` (linked list manipulation)
4. Atomic stores: `waiting_for_lock_owner`, `waiting_for_lock_kind`,
   `waiting_for_lock`, `waiting_for_lock_list`, `lock_waiter_node`,
   `status`, `seq.fetchAdd`
5. `queue_spin` release
6. `task.base.yield()` (fiber context switch back to scheduler)
7. Scheduler runs other fibers
8. On unlock: `state.fetchAnd` to clear LOCKED, then if
   `STATE_HAS_WAITERS` is set, re-acquire `queue_spin`,
   `cmpxchgStrong` to atomically transfer ownership, `pop` waiter,
   `submitResume(task)` (cross-scheduler SPSC channel + event_fd
   notify if target scheduler is parked)
9. Target scheduler `drainChannels()` reads SPSC, sets `status=.Ready`,
   pushes to ready_queue
10. Eventual fiber resume + return from `task.base.yield()`

That's ~15+ atomic operations and at least one OS-thread synchronization
(event_fd) per contended acquire/release pair, plus context-switch
overhead. Each step is correct in isolation; the chain is just long.

`pthread_mutex_t` (compat.Mutex) on contention:

1. `cmpxchg` on the futex word
2. If contended: `FUTEX_WAIT` syscall
3. On unlock: `cmpxchg` clears the word; if previous value indicated
   waiters, `FUTEX_WAKE` syscall

Two atomic ops, two syscalls. glibc additionally implements **adaptive
spin** (try CAS for a few hundred iterations before falling to futex)
and **futex hand-off** (the kernel can directly hand the lock to one
waiter on `FUTEX_WAKE_OP`). These are decades of optimization that
ParkingMutex doesn't have.

For brief critical sections (typical of streams' chunk-publish path),
the spin-then-park optimization is what makes pthread fast. Every
ParkingMutex contention pays the full park+wake cost.

## What a fix would look like

Three plausible paths, in increasing scope:

1. **Adaptive spin in ParkingMutex's fast path.** Before falling to
   `lockSlow`, retry the CAS for some bounded number of iterations
   (~100-500). Most brief contention resolves within the spin budget,
   avoiding the slow path entirely. Modest engineering: ~50 lines.

2. **Lock hand-off in unlock.** Currently unlock pops one waiter and
   transfers ownership via `cmpxchgStrong`. If the CAS races with a
   concurrent fast-path acquirer, unlock bails and the waiter stays
   parked until next unlock. Reordering the CAS to happen BEFORE
   queue_spin release — and verifying via the loom suite that no
   races break the pop+wake invariant — would tighten the critical
   path. Larger engineering: probably 100-200 lines plus loom test
   updates.

3. **Hybrid spin-park primitive.** A new lock type that spins for ~1µs,
   then parks via the existing ParkingMutex protocol. Different shape
   than ParkingMutex (no queue_spin overhead on the fast path), so it
   would live alongside as `lib/parking-lot.zig:SpinParkingMutex` or
   similar. Largest engineering: new full primitive + correctness tests
   + benchmarks.

Path (1) is the cheapest first investment. If it closes >50% of the
gap, may be enough to unblock the streams migration without a full
rewrite.

## Reproducer

```bash
cd /home/yahn/clear
ruby benchmarks/runner.rb benchmarks/concurrent/08_pubsub/    # baseline (compat.Mutex)

# Apply the candidate change in lib/streams.zig:
#   const pl = @import("parking-lot.zig");
#   ...
#   mutex: pl.ParkingMutex = .{},   // was: compat.Mutex
#   ... self.inner.mutex.lock() catch unreachable;   // was: .lock();

ruby benchmarks/runner.rb benchmarks/concurrent/08_pubsub/    # observe TIMEOUT
```

Alternative diagnostic: TSan stress test
`SplitStream survives multithreaded spawnBest pubsub hammer` in
`zig/runtime/stream-test.zig` -- with ParkingMutex it hits LockTimeout
(at 100ms debug) or `expected 17, found 0` (at 30s).

## Until ParkingMutex is fast enough

`lib/streams.zig` and `lib/data-structures.zig` continue to use
`compat.Mutex`. The latent OS-thread blocking issue exists but does
not manifest in current benchmarks because:

- Most production fibers are single-stream/single-data-structure (no
  intra-data-structure contention).
- Multi-fiber-per-scheduler use of these data structures is rare in
  current code paths.

Loom-testing of `lib/streams.zig`, `lib/data-structures.zig`, and the
broader Tier 4 library surface remains blocked on this. The atomic-
op-coverage report's "uncovered (file unloaded)" category for these
files reflects this dependency.
