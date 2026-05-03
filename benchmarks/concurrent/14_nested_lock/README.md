# Benchmark 31: Nested Lock (Bank Transfer)

Bank transfer workload: 64 accounts, N workers doing random transfers.
Each transfer acquires 3 locks: a read lock on the bank container, then
two mutex locks on accounts (ordered by index to prevent deadlock).

## Setup

- 64 accounts, each protected by a mutex, inside an RwLock-protected bank
- N worker threads/fibers, each doing 500K random transfers
- Each transfer: RLock bank, pick two accounts, Mutex lock both (lower index first), transfer $1
- Verify: total balance conserved after all transfers

## Results (32 workers, Linux x86_64)

| Lang  | Total  | vs Go   | vs Rust  |
|-------|--------|---------|----------|
| Rust  | ~1.79s |         |          |
| Go    | ~2.15s |         |          |
| CLEAR | ~5.52s | +157%   | +208%    |

All three implementations are structurally identical: Arc<RwLock<Bank>> containing
Vec<Mutex<Account>>. The benchmark is apples-to-apples — same `cargo build --release`,
`go build`, `clear build --optimized` (LLVM ReleaseFast).

## Analysis

CLEAR is ~2.5× behind Rust and ~2× behind Go. Sources, in observed order
of impact (from `clear profile` + `clear doctor` on the 32-worker run):

### 1. Per-account-mutex park/wake overhead (dominant remaining cost)

71% of CPU is in `Locked.acquire` / `Locked.Guard.release`. The critical
sections are tiny — 0.2–0.7µs avg hold — but each contended acquire under
`@shared:locked` goes through the fiber park sequence:

  - fast-path CAS fails,
  - `lockSlow` takes `queue_spin`, sets HAS_WAITERS, pushes waiter, sets
    `task.status = .Blocked`, yields to scheduler,
  - holder's `unlock` calls `submitResume(waiter)` — if the waiter sits on
    a *different* scheduler-thread, this routes through SPSC + dirty_mask
    + eventfd notification → `io_uring_enter` syscall.

Profile evidence: 23.9s sys / 7.5s user (89% sys). 82% of syscall time is
`io_uring_enter` (cross-scheduler wakeup notifications). Rust's
`std::sync::Mutex` uses futex directly — one syscall per real block,
decided in the kernel queue. CLEAR's fiber-aware path adds scheduler IPC
overhead that wins for long critical sections (hundreds of µs+) but
loses on tiny ones.

Three plausible fixes, none implemented yet:
  - Adaptive spinning before parking on the fiber path (a `SPIN_BUDGET`
    of ~100 cmpxchg iterations would absorb 0.2–0.7µs hold times without
    ever entering the scheduler). The existing non-fiber branch in
    `lockSlow` already does this.
  - A `@spin` capability — opt out of fiber-park-and-wake for short CS.
  - Cross-scheduler wake batching — coalesce N consecutive
    `submitResume`s into one `io_uring_enter`.

### 2. Workstealing balance is uneven

32 schedulers, but ~6 schedulers got 0% of the work and the busy ones
ranged from 3% to 9%. Result: some cores idle while others queue up
waiters. Fixing this would cut wakeup chains.

### 3. Arc refcount on each account-ref extraction

Reading `bank.accounts[i]` increments the per-account Arc refcount
(decremented on guard drop). Rust's `&Vec[i]` is a borrow with no
refcount traffic. Counted but lower-impact on this workload.

### Historical regression

A prior version of this README documented CLEAR at ~2.69s (+27% vs Go,
+54% vs Rust). The 9.86s → 5.52s jump back came from one fix:
`runtime-header.zig:randomInt` was calling `getrandom(2)` per call.
At 1M transfers × 2 random picks = 2M syscalls = 8.7s of kernel time.
Now backed by a per-thread Xoshiro256++ seeded once from
`getrandom`. The remaining 5.52s vs the historical 2.69s suggests
either a deeper regression in master since that measurement, or the
historical number was on different hardware — either way, the 71%-CPU-
in-lock-impl pattern above is the present bottleneck and is independent
of whatever else may have shifted.

The nested locking pattern works correctly in all three languages. Lock
ordering by account index prevents deadlocks. Total balance is conserved
across all runs.

## TODO

- **Implement automatic lock sorting in the compiler.** Multi-binding
  `WITH EXCLUSIVE a AS x, EXCLUSIVE b AS y` currently acquires locks in
  declaration order. The compiler should sort by pointer address at runtime
  to prevent deadlocks automatically, eliminating the need for manual
  index-ordered locking. This is a stated design goal in the manifesto
  (DEADLOCK.md) but not yet implemented.

## Running

```bash
ruby benchmarks/runner.rb --smoke benchmarks/31_nested_lock/   # CLEAR only
ruby benchmarks/runner.rb --fast benchmarks/31_nested_lock/    # All langs
ruby benchmarks/runner.rb benchmarks/31_nested_lock/           # Full run
```
