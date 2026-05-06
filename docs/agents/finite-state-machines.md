# Finite-State-Machine Tasks

CLEAR's scheduler supports two task forms:

| Form | Backing | Per-task cost | Uses |
|---|---|---|---|
| **Stackful fiber** | Dedicated fiber stack + assembly context switch | ~4 KB (Micro) + ~256 B metadata | General fibers, anything with recursive or conditional yields |
| **FSM (stackless)** | State struct + resume function, runs on worker's stack | ~40 B task header + caller's state struct | Linear or simple-branching bodies, no yield inside recursion |

FSM tasks run inline on the worker thread's stack and communicate with the
scheduler through a `YieldReason` return value, not an assembly context
switch. This is the same technique Rust async/await uses.

## Why two forms

Most `BG { ... }` blocks don't need a full stack. A block like
`BG { 1 }` or `BG { readFile("x") }` has no recursion, no conditional
yields, and no locals crossing many yield points. Compiling it to a state
machine is strictly cheaper:

- **Memory**: 48 B vs 4 344 B for the `Micro` stack tier — **90.5× smaller**
- **Spawn+dispatch**: 168 ns vs 761 ns per task — **4.5× faster**
- **Compute**: 171 ns vs 758 ns per task — **4.4× faster**

(Numbers from `zig/runtime/fsm-benchmark-test.zig`, ReleaseFast, 102 400
tasks batched 2048×50.)

When a function's body needs a stack (recursion, loops with yields
crossing iterations, calls into other stackful routines), the compiler
falls back to a stackful fiber. The `SUSPENDS` effect family tracks this
at the annotator level — see `docs/agents/effects.md`.

## Runtime shape

### Core types — `zig/runtime/fsm.zig`

```zig
pub const FsmTask = struct {
    resume_fn: ResumeFn,
    state_ptr: *anyopaque,
    status: FsmStatus = .Ready,
    spawn_ns: u64 = 0,
    waiter: ?*FsmIoWaiter = null,
};

pub const YieldReason = union(enum) {
    Done,                         // task complete
    Yielded,                      // wants to re-run (cooperative yield)
    WaitForIO: *FsmIoWaiter,      // blocked on an io_uring completion
};

pub const ResumeFn = *const fn (*FsmTask) YieldReason;
```

The caller embeds `FsmTask` as the first field of their state struct so a
`@fieldParentPtr("task", t)` recovers the state with no extra pointer hop.

### Scheduler integration

`Scheduler.fsm_ready_queue: ArrayListUnmanaged(*FsmTask)` holds pending
tasks. The main loop drains the FSM queue **before** any stackful
dispatch — FSM tasks never context-switch, so draining them is a tight
inline loop that completes trivial tasks in one pass and returns
`.Yielded` tasks to the queue for the next iteration.

`FsmIoWaiter.encode()` tags the low two bits of the io_uring `user_data`
field with `0b11`, distinguishing FSM waiters from stackful waiters
(`0b01`) and from direct Task pointers (`0b00`). `processCqes` checks
the FSM marker first since its pattern is a superset.

## Public API

### Runtime surface (Zig)

| Function | Purpose |
|---|---|
| `scheduler.enqueueFsm(task)` | Enqueue on the local scheduler (same thread). |
| `scheduler.drainFsmQueue()` | Run the main loop's FSM-drain branch explicitly (test-only). |
| `scheduler.submitFsmSpawn(task)` | Cross-scheduler submit via SPSC. |
| `runtime_hdr.spawnFsmBest(task)` | Pick the least-loaded scheduler (pickTwo) and submit. |
| `runtime_hdr.spawnFsmOn(sched, task)` | Submit to a specific scheduler. |

### Message path

1. Producer calls `spawnFsmBest` or `spawnFsmOn`.
2. An SPSC `Message` with tag `.FsmSpawn` and `fsm_task` set is pushed
   onto the target scheduler's channel.
3. Target scheduler's `drainChannels` pops the message and calls
   `enqueueFsm(task)` on itself.
4. Main loop's FSM drain runs the task.

## Invariants

**I1** — `active_tasks` balance. Every enqueue increments; every Done
decrements. Waiter park/wake does not touch the counter. At scheduler
quiescence `active_tasks == 0`.

**I2** — Queue contents are `.Ready`. A Blocked or Finished task never
appears in `fsm_ready_queue`.

**I3** — Single-consumer drain. Only the owning scheduler drains
`fsm_ready_queue`. Other threads submit via SPSC; they do not touch the
queue directly.

**I4** — Migration. An idle sibling scheduler can steal up to half of a
victim's FSM queue via `FsmRunQueue.tryStealFrom`. Stolen tasks run on
the stealer. Work-stealing for FSMs mirrors the stackful ready_queue
steal — same Chase-Lev algorithm, independent queue instance. In the
idle-steal path the scheduler tries stackful first, falls back to FSM
if no stackful tasks are available.

**I4b** — Fairness. `drainFsmQueue` is bounded to `FSM_DRAIN_BATCH`
(64) tasks per call so bursts of FSMs cannot starve the stackful
dispatch that follows. Within a batch, `.Yielded` tasks stage on
`fsm_deferred_queue` and flush back to the main queue only after the
batch completes — this prevents a single yielder from monopolizing
the batch (the Chase-Lev deque's LIFO owner-pop would otherwise
re-dispatch the same task every time).

**I5** — Caller owns state. The state struct that embeds `FsmTask` is
allocated and freed by the caller, never by the scheduler. Freeing while
the task is `.Ready` or `.Blocked` is UB by contract.

**I6** — Lock waiter polymorphism (MVP). `queues.WaiterNode` carries an
optional `fsm_task: ?*FsmTask`; when set, the node represents an FSM
waker rather than a stackful `*Task`. `ParkingMutex.unlock` dispatches
on `waiter.isFsm()` — stackful waiters wake via `submitResume`, FSM
waiters via `submitFsmResume` (a new SPSC `FsmResume` message that
does NOT re-increment `active_tasks`). FSM waiter nodes live in the
user state struct alongside the `FsmTask`.

## Parking-lot integration (MVP)

`ParkingMutex` supports FSM contention via `tryLockForFsm(&task, &waiter, sched)`
which returns `.Acquired` or `.Registered`. A compiled FSM state machine
uses it like:

```zig
switch (state.step) {
    N => {
        state.step = N + 1;
        return switch (mutex.tryLockForFsm(&state.task, &state.waiter, sched)) {
            .Acquired => afterAcquire(state),
            .Registered => .{ .WaitForLock = {} },
        };
    },
    N + 1 => afterAcquire(state),  // woken; lock has been handed off to us
}
```

Deadlock protection — parity with the stackful path for the common
cases:

- **Re-entrancy detection**: `tryLockForFsm` checks `fsm_owner` against
  the calling FSM. Same-task re-acquire returns `.Error` with
  `lock_error = .Deadlock`.
- **Pure-FSM cycle detection**: `detectCycleFsm` walks the
  `waiting_for_fsm_owner` chain. Cycles of any depth ≤ 64 involving
  only FSM holders return `.Error` with `lock_error = .LockCycle`.
- **FSM → stackful (one hop) cycle detection**: The walker follows
  `waiting_for_lock_owner` one level when the chain transitions to a
  stackful holder.
- **Timeout**: `Scheduler.fsm_lock_waiters` parallels `lock_waiters`.
  `scanFsmLockWaiters` runs every main-loop iteration; on expiry the
  task is re-enqueued with `lock_error = .LockTimeout`.

`ParkingRwLock` support (this branch):
- `tryWriteLockForFsm` — mirrors `tryLockForFsm` with write-exclusive
  semantics. Re-entrancy + cycle detection via `fsm_write_owner`
  side field and `detectCycleFsm`.
- `tryReadLockForFsm` — optimistic fetchAdd fast path, reader-waiter
  registration with write-priority fairness. No re-entrancy check
  (readers stack), no cycle chain owner (readers have no single
  owner, matching stackful semantics).
- `wakeNext` write and read branches both dispatch on `waiter.isFsm()`:
  FSM wakers go via `submitFsmResume`; stackful via `submitResume`.
  Reader batch wake calls `submitFsmResume` per reader.
- `unlock` clears `fsm_write_owner`; timeout scanning applies.

Remaining MVP gaps:
- Deeper mixed-chain walks (FSM → Stackful → FSM) are not traced —
  `FsmTask` does not yet track `waiting_for_task_owner`. The immediate
  cycles people actually write (pure-FSM, or FSM on a single stackful
  holder) are detected on both `ParkingMutex` and `ParkingRwLock`.

The scheduler thread-local hygiene that made this work reliably
landed in commit e55c8bbc (`run()` now clears
`scheduler_running`/`active_scheduler` on exit via defer, closing a
latent class of fragility where Scheduler layout changes could
convert "worked by accident" tests into hard crashes).

## Test coverage

| Kind | File | What it checks |
|---|---|---|
| Unit | `runtime/fsm.zig` (inline) | State transitions, WaitForIO encoding |
| Scheduler integration | `runtime/fsm-scheduler-test.zig` | enqueue/drain/Yielded fairness/WaitForIO park+wake/hasWork |
| VOPR | `runtime/fsm-vopr-test.zig` | 128-seed PRNG fuzzer + invariants I1-I5 after every 8 steps |
| Race | `runtime/fsm-race-test.zig` | 4-thread independent schedulers balance active_tasks; SPSC 1P/1C cross-thread submission |
| Steal | `runtime/fsm-steal-test.zig` | FsmRunQueue.tryStealFrom transfers half; stolen tasks complete on the stealer; structural separation of queues |
| Fairness (primitives) | `runtime/fsm-fairness-test.zig` | FSM drain bounded to FSM_DRAIN_BATCH per iteration; yielded tasks cannot monopolize a batch; stackful dispatch reachable under FSM burst load |
| Fairness (end-to-end) | `runtime/fsm-endtoend-fairness-test.zig` | Drives `sched.run()` with mixed FSM + stackful load. Stackful fiber increments a counter on each yield while N FSMs fire concurrently. Both counters reach their expected values before run() exits — proves the full main loop (not just the drain primitive) interleaves fairly in both orderings. |
| Concurrent stress | `runtime/fsm-concurrent-test.zig` | Real OS threads hammering `FsmRunQueue` push/pop/stealOne. Verifies no task is lost or delivered twice under thousands of concurrent operations. |
| Hammer | `runtime/fsm-hammer-test.zig` | Time-boxed stress, 250K+ tasks/sec, WaitForIO under load |
| Benchmark | `runtime/fsm-benchmark-test.zig` | FSM vs stackful perf comparison + cross-scheduler spawn throughput + work-stealing under skew |
| Cross-scheduler | `runtime/fsm-cross-scheduler-test.zig` | submitFsmSpawn, spawnFsmBest, spawnFsmOn correctness |
| Mutex (FSM) | `runtime/fsm-lock-test.zig` | uncontended, contended park+wake, mixed FSM+stackful contention, N=64 stress |
| Mutex VOPR | `runtime/fsm-lock-vopr-test.zig` | 32-seed PRNG fuzzer of mixed FSM+stackful ordering; invariants I1–I4 |
| Mutex safety | `runtime/fsm-lock-safety-test.zig` | re-entrancy, pure-FSM cycle, timeout |
| RwLock (FSM) | `runtime/fsm-rwlock-test.zig` | write acquire/release, N concurrent readers, writer blocks readers + release wakes all, mixed FSM+stackful write contention, re-entrancy + write timeout |

**Loom coverage.** Direct, not inferred:
- **`FsmRunQueue`**: covered by `runtime/fsm-loom.zig`. Three
  exhaustive scenarios driven through `SimAtomic`:
  - `pop_vs_steal` — 2 048 interleavings
  - `push_pop_vs_steal` — 4 096 interleavings
  - `two_thieves` (one item) — 256 interleavings
  Plus a PRNG-seeded test (default 200 seeds, scalable via
  `LOOM_FUZZ_SEEDS` env var).
- **Underlying primitives** (`RunQueue` Chase-Lev + `WaiterList`
  spinlock + SPSC ring) are covered by `vopr-loom.zig` and
  `parking-lot-loom.zig` — `FsmRunQueue` uses the same algorithm as
  `RunQueue` and `ParkingMutex` FSM waiters use the same `WaiterList`
  as stackful waiters, so those proofs carry over.
- **FSM-lock wake-path atomic surface** (`fsm_owner.store/load`,
  same-thread `submitFsmResume` fast path) does not introduce
  additional cross-thread interleavings beyond what the underlying
  mutex state CAS + WaiterList spinlock already cover. Exhaustive
  Loom of the FSM-waiter-in-ParkingMutex composition requires
  extending `parking-lot-loom.zig`'s stub-task scaffolding to
  synthesize FSM waiters; tracked as a follow-up. Practical
  correctness covered by `fsm-lock-test.zig`, `fsm-lock-vopr-test.zig`
  (32-seed PRNG mixed contention), and `fsm-lock-safety-test.zig`.

## Active Tracker

### EBR Scheduler-Thread Wiring

Recent MVCC/EBR work moved runtime use toward one `ThreadLocalEbr` per
scheduler thread, with tasks resolving the active participant through
runtime/scheduler TLS rather than owning a private participant per spawn.
The correctness contract is:

- A task may be stolen or resumed on another scheduler.
- A `Versioned(T).Guard` must release the exact EBR participant it pinned.
- Nested pins must keep the participant active until the outermost guard
  releases.
- Retired nodes must survive writer-task exit while any task still holds
  a guard.

Required tests:

| Kind | Required coverage |
|---|---|
| Unit | `ThreadLocalEbr.enter` / `exit` nested pin depth: inner exit must not clear `is_active`; outer exit must clear it. |
| Unit | `Versioned(T).Guard` captures and releases the same `ThreadLocalEbr` pointer even if the active scheduler changes before guard release. |
| Fiber stress | Writer task retires a version and exits while a different task holds a guard; reclaim must not free the guarded value until release. |
| Scheduler stress | MVCC reads/writes under task stealing, proving `Runtime.currentEbr()` follows the executing scheduler and does not use per-task EBR state. |
| Loom | Exhaustive model for EBR `pin_depth`, `is_active`, `local_epoch`, retire, and reclaim interleavings. Any new atomic field or ordering in EBR must be represented in this model. |
| Loom | Guard migration model: pin on participant A, scheduler TLS changes before release, guard release still exits participant A and reclaim sees the correct active set. |
| VOPR | No EBR-specific VOPR is required unless the fix adds retries, IO, timers, or scheduler-yield loops. If scheduler migration/retry logic changes, add it to the scheduler/FSM VOPR model. |

### FSM Context Allocation

Current generated FSM contexts are heap allocated and carry one field per
promoted variable name. The planned allocation policy is:

- **Now:** add 64 B, 128 B, and 256 B scheduler-local slabs for generated FSM
  contexts, initialized with the scheduler/runtime allocator.
- **Now:** add explicit `@stack` so the compiler can select a stack tier
  at compile time when an FSM context is too large or a stack is the
  better execution model.
- **Future:** reuse context slots across disjoint live ranges instead of
  one field per source variable name.
- **Future:** add `@fsm:heap` as an explicit opt-in for oversized heap
  FSM contexts.

Required tests:

| Kind | Required coverage |
|---|---|
| Runtime unit | 64 B, 128 B, and 256 B slab allocate/free/reuse, exact-size boundaries, and alignment. |
| Runtime unit | Oversized context never enters a small slab class. |
| Runtime scheduler | FSM task allocated on one scheduler and completed/stolen/freed on another routes free correctly and does not touch a non-thread-safe foreign slab directly. |
| Runtime leak | Slab contexts are returned on success, error, cancellation, lock timeout, and IO wake error paths. |
| Runtime stress | Many schedulers spawn and complete small FSM contexts concurrently with kcov-compatible bounded hammer tests. |
| Compiler/transpile | Small context lowers to 64 B slab; medium context lowers to 128 B slab; larger common context lowers to 256 B slab; oversized context requires `@stack` or future `@fsm:heap`. |
| Compiler/transpile | Generated FSM context no longer stores unnecessary allocator fields for the slab path. |
| Compiler/transpile | Current no-slot-reuse behavior is covered with a fixture that has disjoint variables across suspend points; future slot reuse changes that expected shape deliberately. |
| Loom | If FSM context slabs add new atomics or remote-free queues, model allocate/free/reuse and cross-scheduler free routing. Existing runtime stress is not a substitute for this. |
| VOPR | If context free routing adds retries, timed polling, IO waits, or scheduler-yield loops, add those transitions to the scheduler/FSM VOPR model. Pure local slab allocate/free does not require VOPR by policy. |

## Roadmap

**Landed:**
- MVP: scheduler-local enqueue + inline dispatch + WaitForIO
- VOPR, race, steal, hammer, benchmark coverage
- SPSC cross-scheduler spawn + `spawnFsmBest` / `spawnFsmOn`
- Work-stealing via `FsmRunQueue.tryStealFrom`
- Bounded per-iteration drain (`FSM_DRAIN_BATCH=64`) + deferred
  staging queue for per-batch yielder fairness
- **`ParkingMutex.tryLockForFsm` + polymorphic `WaiterNode`
  + `submitFsmResume` for lock wake routing** (this branch)

**Planned next:**
- **Loom coverage of SPSC FSM submission + FSM work-stealing +
  FSM lock wake atomics**. Requires stub-task harness akin to
  `parking-lot-loom.zig`. Algorithmic correctness transfers from
  RunQueue + WaiterList (both Loom-tested today); the concurrent
  stress and VOPR tests cover practical race surface.
- **ParkingRwLock FSM support** (same polymorphic waiter, needs
  reader-batch wake dispatch).
- **FSM deadlock detection** and **timeout scanning** for lock
  waiters. Requires encoding the FSM owner pointer in the mutex
  state word (or a side table) and extending `detectCycle` to
  walk through it. Currently stuck-on-owner. An
  overloaded scheduler's FSM queue is invisible to idle siblings. When
  it lands, FSM tasks get load-balanced the same way stackful fibers do.
- **Parking-lot lock integration**. Today an FSM that needs a contended
  lock cannot represent `WaitForLock` — the compiler must fall back to
  stackful. Adding `WaitForLock(&ParkingMutex)` to `YieldReason` plus a
  matching scheduler branch closes this. Low priority; the fall-back is
  already correct.
- **Compiler emission**. Uses the `SUSPENDS` effect family to classify
  each `BG { ... }` at annotation time and emit the FSM form whenever
  possible. The classifier is in place; emission is not.

## When to use which form

The compiler picks automatically based on effects. The rule:

| Function effects at BG site | Form |
|---|---|
| (no effects) or `SUSPENDS` | FSM (trivial 1-state or linear) |
| `SUSPENDS_CONDITIONAL` | FSM with branching states |
| `SUSPENDS_LOOP` | FSM with loop-preserving state (larger state struct) |
| `REENTRANT` (transitive) | Stackful (recursion needs a stack) |

`BLOCKING` (lock wait) currently forces stackful until parking-lot
integration lands.

## Non-goals

- FSM is not a general async/await surface — the compiler manages it;
  user code writes `BG { ... }`.
- FSM does not reduce latency of compute-bound code. The win is in
  spawn/dispatch overhead and memory, not instruction throughput.
- FSM state is caller-owned. The scheduler does not free user state
  structs.
