# experimental/ — code preserved for future revival

## Unwinding

```bash
zig test unwind-test.zig unwind.S -lc -lunwind   -O Debug   -fno-strip   -rdynamic   --eh-frame-hdr
```

## parking-lot.zig

Fiber-aware mutex (`ParkingMutex`) and readers-writer lock (`ParkingRwLock`)
designed to park fibers on the scheduler instead of blocking the OS thread.

**Status: not in use.** The implementation was reverted to `compat.RwLocked`
(pthread_rwlock_t) because under raw-thread contention `ParkingRwLock` was
~10x slower than pthread, with super-linear degradation:

| Threads | ParkingRwLock | pthread_rwlock_t | Ratio |
|---------|---------------|------------------|-------|
| 2       | 3.7 ms        | 3.7 ms           | 1.00x |
| 4       | 80.1 ms       | 46.9 ms          | 0.59x |
| 8       | 601.2 ms      | 125.7 ms         | 0.21x |
| 16      | 2098.2 ms     | 243.8 ms         | 0.12x |

### Root cause

`ParkingRwLock` protects multi-field state (`readers`, `write_locked`,
waiter queue) with an internal spinlock (`spin: Atomic(u32)`). Every
acquire/release does a CAS loop on this single shared cache line. Under
N-thread contention, the CAS retries N-1 times on average and the line
bounces between cores. pthread_rwlock uses a **single atomic state word**
with `fetch_add` for reader entry and CAS for writer entry — fully
lock-free fast paths, no secondary spinlock.

### What it would take to revive

1. **Compact state into a single atomic word** (~32 bits): readers count,
   write_locked bit, has_waiters bit. Reader fast path becomes
   `state.fetchAdd(1)` with rollback on conflict; writer fast path becomes
   `state.cmpxchg(0, WRITE_LOCKED)`. This eliminates the secondary spinlock
   for fast paths.
2. **Move the waiter queue + parking metadata behind a separate fallback
   path** that's only entered when the fast path detects waiters via the
   has_waiters bit.
3. **Re-add the scheduler-side support** (see "missing infrastructure"
   below) since the in-tree `scheduler.zig` and `queues.zig` were reverted
   to pre-parking-lot state. Specifically: `Task.waiting_for_lock`,
   `Task.waiting_for_lock_list`, `Task.lock_waiter_node`,
   `Task.lock_wait_start_ms`, `Task.lock_timed_out`,
   `Task.waiting_for_lock_owner`, plus `Scheduler.lock_waiters`,
   `Scheduler.lock_timeout_ms`, `Scheduler.registerLockWaiter`,
   `Scheduler.scanLockWaiters`, and the lock-waiter timeout SQE in the
   idle path.
4. **Re-add `WaiterNode`/`WaiterList`/`WaiterKind`** to `queues.zig`.

### What's preserved here

- `parking-lot.zig` — the implementation as it was at the point of revert,
  with FIFO fairness in the rwlock and futex fallback in the mutex.
- `parking-lot-test.zig` — 25 functional tests including deadlock detection,
  timeouts, and the multi-lock defer-unwind safety test.
- `parking-lot-loom.zig` + `parking-lot-loom-test.zig` — exhaustive
  interleaving tests (256 schedules each for mutex acquire/release, rwlock
  two-writers, rwlock writer-vs-reader; PRNG tests with `LOOM_FUZZ_SEEDS`
  env var).
- `parking-lot-benchmark-test.zig` — head-to-head perf vs `pthread_mutex_t`
  and `pthread_rwlock_t`, with a scaling test at 2/4/8/16 threads.

These files will not compile against the current main runtime. To revive,
restore the scheduler-side support (see git history at commit `f94c403e`
or earlier) and update the build.zig test/benchmark lists to point at
these paths.
