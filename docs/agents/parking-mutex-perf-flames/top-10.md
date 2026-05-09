# Top-10 hot functions: 08_pubsub with parking_lot streams patch

Captured 2026-05-09 on 32-core Intel Xeon Gold 6548N, ReleaseFast, jemalloc, 32 schedulers.
Patch: `lib/streams.zig:120` `mutex: pl.ParkingMutex` (otherwise master `streams-fix` branch).

Workload: 1 publisher, 64 subscribers, 10K messages, scale=5.0 (50K messages effective).
Total runtime under perf: ~15.2s (without perf: 8.68s; baseline compat.Mutex: 0.164s).
Samples: 11,452 at 999Hz, dwarf call graphs.

## Self-time top 10 (no children)

```
13.64%  Scheduler.run                  -- main scheduler loop
12.31%  ParkingMutex.lock              -- includes lockSlow which dominates
 9.34%  pthread_mutex_lock             -- INTERNAL: from pinTask via detectCycle
 9.24%  bench BgCtx0.run               -- the actual benchmark logic
 7.74%  Scheduler.drainChannels        -- cross-scheduler SPSC wake drain
 7.70%  compiler_rt.memset             -- chunk zeroing + ensureChannel buffer init
 5.74%  ParkingMutex.unlock            -- includes submitResume path
 5.60%  Scheduler.submitResume         -- cross-scheduler wake submit
 4.05%  pthread_mutex_unlock           -- pair of the 9.34% above
 3.83%  [vdso] (clock_gettime)         -- timeout-scanner clock probes
```

## Children-time decomposition (callers)

### `next()` = 52.62% of total runtime

```
SplitStream.next                              52.62%
  ParkingMutex.lock                           32.17%  (61% of next time)
    ParkingMutex.lockSlow                     31.45%
      detectCycle                             26.10%  (cycle-walk overhead)
        pinTask                               17.68%
          SlabAllocator.refFromPtr            11.23%
            compat.Mutex.lock (pthread)       9.04%   <-- INTERNAL pthread inside detectCycle
              pthread_mutex_lock              8.75%
            compat.Mutex.unlock               0.77%
          atomic.Value(u32).load              1.56%
        Scheduler.registerLockWaiter          1.44%
        Scheduler.milliTimestamp              1.36%
          clock_gettime                       1.23%
      compiler_rt.memset                      5.32%
      spinReleaseQueue                        1.14%
      atomic stores (waiting_for_lock_*)      ~2%
  ParkingMutex.unlock                         15.43%  (29% of next time)
    Scheduler.submitResume                    8.79%   (cross-scheduler wake)
      Scheduler.ensureChannel                 3.40%   (lazy channel alloc)
        compiler_rt.memset                    2.99%
      SpscRing.push                           1.94%
    state.fetchAnd                            1.71%
    libc.write                                1.04%   (event_fd notify syscall)
    spinAcquireQueue                          0.84%
  processMessage (actual work)                4.32%
```

### Worker `Scheduler.run` = 31.41% of total runtime

```
Scheduler.run                                 31.41%
  drainChannels                               8.42%
    SpscRing.pop                              5.05%
    enqueueTask -> RunQueue.push              1.09%
  scanLockWaiters                             6.98%   <-- timeout scanner!
    milliTimestamp / clock_gettime            4.54%
  scanFsmLockWaiters                          2.10%
    milliTimestamp / clock_gettime            2.04%
  idleStealFrom -> RunQueue.tryStealFrom      1.82%
  processCqes                                 1.70%
    SmartEventFd.consume -> read              1.65%   (event_fd consume syscall)
  earliestLockWaiterDeadlineMsUntil           1.08%
    milliTimestamp / clock_gettime            0.96%
  RunQueue.pop                                0.77%
```

## Diagnosis

The 53x regression compounds three sources:

1. **`detectCycle` is 26% of total** — directly contradicts the doc's Attempt 2 claim
   that cycle detection wasn't the dominant cost. `pinTask` inside `detectCycle` takes a
   pthread mutex in the slab allocator (`SlabAllocator.refFromPtr` -> `compat.Mutex.lock`
   on the slab's internal pin counter), which is 9% of total time spent on a *pthread mutex
   inside the cycle-detection logic*. Every contended fiber acquire walks the owner chain;
   each hop pins a Task slab; pinning takes the slab's pthread mutex.

2. **`Scheduler.submitResume` + `drainChannels` = 16.5%** — cross-scheduler wake plumbing.
   With 64 subscribers parked across 32 scheduler threads, every `wakeParkedSubscribers`
   call from `push` triggers up to 64 cross-scheduler wakes via SPSC channel + event_fd.
   Plus the unlock's pop-one pathway adds another wake per unlock. This is the wave
   structure the Plan agent diagnosed, confirmed.

3. **`scanLockWaiters` + `scanFsmLockWaiters` = 9%** — the timeout-scanner registers every
   lock waiter with the scheduler, which scans the registry on every scheduler tick and
   calls `clock_gettime` (vdso) on each. With 64 fibers parking and unparking constantly,
   the registry churns fast and the scanner runs more often.

## Implications for plan

- **Task 3 (wake-one) WILL help substantially** — the 16.5% in submitResume/drainChannels
  drops roughly proportionally with the wake-fanout reduction. Estimate: 3-5x speedup just
  from wake-one (depends on how many subscribers are actually parked at any moment).

- **Task 4 expansion: a stream-targeted "no-cycle-check" lock** would eliminate 26% of
  total time. Doc's `lockNoCycle` attempt may have been incomplete (left `pinTask` cost in
  via something else). Worth re-attempting now that we have a clear profile.

- **Task 5 (slow-path opt) is also high-value for the bench-gap track** — the OS-thread
  bench likely shows similar `detectCycle`/`pinTask` cost but in pthread-only paths. Plus
  `Mutex` at 4x worse than pthread on heavy/realistic warrants a dedicated profile run.

## Files

- `/tmp/pubsub-park.perf` (93MB, kept until session end) — raw perf.data
- `/home/yahn/cheat/zig/lib/parking-lot.zig:272-399` — `detectCycle` source
- `/home/yahn/cheat/zig/runtime/slab-alloc.zig` — slab pin/refFromPtr (the pthread cost
  hidden inside detectCycle)
