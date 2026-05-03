# Parking-Lot Loom Coverage Audit (M1)

Single source of truth for the loom-coverage milestone (M3-M8). Every atomic
operation on the `parking_lot` + deadlock-detection critical path must appear
in this inventory and end up exercised by a Loom test that an invariant can
fail. The M8 coverage gate consumes this document as the canonical site list.

Scope: `zig/lib/parking-lot.zig` (ParkingMutex, ParkingRwLock, detectCycle)
plus the lock-related fields on `qs.Task` in `zig/runtime/queues.zig` that
the lock implementations write/read. Stackful (fiber) only — FSM tasks are
out of scope for this branch.

## How "full coverage" is enforced

A Loom test that *runs* through code is not the same as a Loom test that
*proves* an interleaving was exercised. The site list below assigns a
stable ID to every atomic op. M8 will instrument `SimAtomic` to record
which IDs fired during a run; the suite fails with `error.UncoveredSite`
if any ID was unhit at end of run. That makes the "ZERO untested atomics"
property mechanical, not aspirational.

## Atomic field declarations

| Field | Type | Loom-instrumented? |
|---|---|---|
| `ParkingMutex.state` (u64) | `Atomic(u64)` | yes (comptime alias) |
| `ParkingMutex.queue_spin` (u32) | `Atomic(u32)` | yes |
| `ParkingRwLock.state` (u32) | `Atomic(u32)` | yes |
| `ParkingRwLock.queue_spin` (u32) | `Atomic(u32)` | yes |
| `ParkingRwLock.write_owner` (?*Task) | **`std.atomic.Value(?*Task)`** | **NO — GAP-A** |
| `Task.status` | `Atomic(TaskStatus)` | yes |
| `Task.seq` (u32) | `Atomic(u32)` | yes |
| `Task.waiting_for_lock` (?*anyopaque) | `Atomic(?*anyopaque)` | yes |
| `Task.waiting_for_lock_kind` (u8) | `Atomic(u8)` | yes |
| `Task.waiting_for_lock_owner` (?*Task) | `Atomic(?*Task)` | yes |
| Futex pointer wrappers (u32/u64) | `*std.atomic.Value(...)` | n/a (kernel-side) |

## Site inventory — ParkingMutex

Locations are `parking-lot.zig:LINE`. Test column maps to an existing test
in `runtime/parking-lot-loom.zig` (M = mutex 256-schedule exhaustive,
P = mutex prng-500, L = lost-wake regression 3x3) or `(none)`.

### state (u64) + queue_spin

| ID | Line | Op | Step | Hit by |
|---|---|---|---|---|
| PM-01 | 290 | `queue_spin.cmpxchgWeak(0,1, .acquire, .monotonic)` | spinAcquireQueue | L (slow path) |
| PM-02 | 295 | `queue_spin.store(0, .release)` | spinReleaseQueue | L |
| PM-03 | 300 | `state.load(.acquire)` | isLocked | post-test invariant |
| PM-04 | 303 | `state.load(.acquire)` | ownerTask | indirect via detectCycle |
| PM-05 | 307 | `state.fetchOr(STATE_LOCKED, .monotonic)` | presetLocked (test rendezvous helper) | (none) |
| PM-06 | 311 | `state.load(.acquire)` | tryLock load | (none) |
| PM-07 | 318 | `state.cmpxchgWeak(cur, new, .acquire, .monotonic)` | tryLock CAS | (none) |
| PM-08 | 326 | `state.load(.acquire)` | lock fast-path load | M, P, L |
| PM-09 | 333 | `state.cmpxchgWeak(cur, new, .acquire, .monotonic)` | lock fast-path CAS | M, P, L |
| PM-10 | 369 | `state.load(.monotonic)` | non-fiber spin loop | (none) — non-fiber unreachable from loom |
| PM-11 | 376 | `state.load(.monotonic)` | non-fiber yield-loop check | (none) |
| PM-12 | 387 | `state.fetchOr(STATE_HAS_THREAD_SLEEPER, .acquire)` | non-fiber park-bit | (none) |
| PM-13 | 395 | `state.load(.acquire)` | non-fiber CAS preamble | (none) |
| PM-14 | 398 | `state.cmpxchgWeak(cur, new, .acquire, .monotonic)` | non-fiber acquire CAS | (none) |
| PM-15 | 406 | `state.load(.acquire)` | lockSlow re-entrancy check | L |
| PM-16 | 423 | `state.load(.acquire)` | lockSlow recheck under spin | L |
| PM-17 | 426 | `state.cmpxchgWeak(recheck, new, .acquire, .monotonic)` | lockSlow recheck CAS | L (rare) |
| PM-18 | 451 | `state.fetchOr(STATE_HAS_WAITERS, .acq_rel)` | park-bit set | L |
| PM-19 | 460 | `state.cmpxchgStrong(after_or, target, .acquire, .monotonic)` | park-grab attempt | L |
| PM-20 | 500 | `state.load(.acquire)` | post-wake timeout check | (none) — no timeout test |
| PM-21 | 519 | `state.fetchAnd(STATE_FLAG_MASK & ~STATE_LOCKED, .release)` | unlock fast-path | M, P, L |
| PM-22 | 530 | `state.load(.acquire)` | unlock recheck under spin | L |
| PM-23 | 545 | `state.cmpxchgStrong(cur_state, new, .release, .monotonic)` | unlock owner-transfer CAS | L |
| PM-24 | 567 | `state.fetchAnd(~STATE_HAS_WAITERS, .release)` | stale-waiters cleanup | (none) — needs synthetic timeout |

24 mutex sites. Loom-eligible (fiber path, not the non-fiber branches):
PM-01..PM-09, PM-15..PM-24 → **19 sites**. Currently exercised: PM-01, 02,
08, 09, 15..19, 21..23 → **12 sites**. Untested: **PM-05 (presetLocked),
PM-06/07 (tryLock), PM-20 (timeout post-wake), PM-24 (stale-waiters
cleanup)**. PM-03/04 are read-only inspection helpers used by post-test
invariants — count as covered. Non-fiber sites (PM-10..14) excluded
from loom scope.

## Site inventory — ParkingRwLock

Test column: WW = "two writers exhaustive", WR = "writer vs reader",
RWW = "two readers + one writer prng".

### state (u32) + queue_spin

| ID | Line | Op | Step | Hit by |
|---|---|---|---|---|
| PR-01 | 634 | `state.load(.acquire)` | isWriteLocked | post-test |
| PR-02 | 637 | `state.load(.acquire)` | readerCount | post-test |
| PR-03 | 641 | `queue_spin.cmpxchgWeak(0,1, ..)` | spinAcquireQueue | WR, WW, RWW |
| PR-04 | 646 | `queue_spin.store(0, .release)` | spinReleaseQueue | WR, WW, RWW |
| PR-05 | 654 | `state.cmpxchgWeak(0, WRITE_LOCKED, ..)` | write fast path | WW, WR |
| PR-06 | 682 | `state.load(.monotonic)` | non-fiber write spin | (none) |
| PR-07 | 690 | `state.cmpxchgWeak(0, WRITE_LOCKED, ..)` | non-fiber write CAS | (none) |
| PR-08 | 706 | `state.cmpxchgWeak(0, WRITE_LOCKED, ..)` | write recheck under spin | WW |
| PR-09 | 718 | `state.fetchOr(HAS_WAITERS_BIT, .acq_rel)` | write park-bit set | WW, WR |
| PR-10 | 721 | `state.cmpxchgStrong(after_or, target, ..)` | write park-grab | WW |
| PR-11 | 755 | `state.load(.acquire)` | post-wake timeout WRITE_LOCKED check | (none) |
| PR-12 | 779 | `state.fetchAnd(~WRITE_LOCKED_BIT, .release)` | write unlock | WW, WR |
| PR-13 | 790 | `state.fetchAdd(1, .acquire)` | shared fast path | WR, RWW |
| PR-14 | 798 | `state.fetchSub(1, .release)` | shared fast-path undo | WR, RWW |
| PR-15 | 817 | `state.load(.monotonic)` | non-fiber shared spin | (none) |
| PR-16 | 824 | `state.fetchAdd(1, .acquire)` | non-fiber shared add | (none) |
| PR-17 | 826 | `state.fetchSub(1, .release)` | non-fiber shared undo | (none) |
| PR-18 | 839 | `state.fetchAdd(1, .acquire)` | shared recheck under spin | WR, RWW |
| PR-19 | 846 | `state.fetchSub(1, .release)` | shared recheck undo | WR, RWW |
| PR-20 | 852 | `state.fetchAdd(1, .acquire)` | shared retry-after-wake | RWW (rare) |
| PR-21 | 857 | `state.fetchSub(1, .release)` | shared retry undo | (none) — narrow window |
| PR-22 | 869 | `state.fetchOr(HAS_WAITERS_BIT, .acq_rel)` | shared park-bit set | RWW |
| PR-23 | 871 | `state.fetchAdd(1, .acquire)` | shared park-grab | RWW |
| PR-24 | 877 | `state.fetchSub(1, .release)` | shared park-grab undo | (none) |
| PR-25 | 916 | `state.fetchSub(1, .release)` | unlockShared | WR, RWW |
| PR-26 | 935 | `state.load(.acquire)` | wakeNext writer-promote load | WW, RWW |
| PR-27 | 945 | `state.cmpxchgWeak(cur, target, ..)` | wakeNext writer-promote CAS | WW, RWW |
| PR-28 | 969 | `state.fetchAdd(1, .acquire)` | wakeNext per-reader credit | RWW |
| PR-29 | 983 | `state.fetchAnd(~HAS_WAITERS_BIT, .release)` | wakeNext drain end | RWW |

### write_owner (NAKED, see GAP-A)

| ID | Line | Op | Step | Hit by |
|---|---|---|---|---|
| PR-W1 | 624 | `init(null)` | declaration | n/a |
| PR-W2 | 153 | `write_owner.load(.acquire)` | currentChainOwner (cycle detect) | (none) |
| PR-W3 | 656 | `write_owner.store(sched.current_task, .release)` | write fast-path acquire | WW, WR |
| PR-W4 | 699 | `write_owner.load(.acquire)` | lockSlow seed for detectCycle | WW |
| PR-W5 | 707 | `write_owner.store(task, .release)` | write recheck-under-spin acquire | WW |
| PR-W6 | 722 | `write_owner.store(task, .release)` | write park-grab acquire | WW |
| PR-W7 | 756 | `write_owner.load(.acquire)` | post-timeout owner-recovery check | (none) |
| PR-W8 | 765 | `write_owner.store(task, .release)` | post-wake (transferred) | WW |
| PR-W9 | 776 | `write_owner.store(null, .release)` | unlock | WW, WR |
| PR-W10 | 953 | `write_owner.store(w.task, .release)` | wakeNext writer-grant | WW, RWW |

29 + 10 = **39 rwlock sites**. Loom-eligible (excluding non-fiber 06/07/15/16/17):
**34 sites**. Currently exercised: 22. Untested: **PR-11 (timeout
post-wake), PR-21 (shared park-grab undo - narrow), PR-24 (shared
post-park undo), PR-W2 (cycle-detect read of write_owner — invisible
under GAP-A), PR-W7 (owner-recovery post-timeout)** plus 5 sites that
are *executed* but invisible to Loom because of GAP-A.

## Site inventory — Task lock fields (cross-cutting)

These are read by the lock impls (park/wake) and read by `detectCycle`.
All are now `Atomic` thanks to commit `b9876146`.

| ID | Field | Op | Step | Hit by |
|---|---|---|---|---|
| TK-01 | `seq` | `load(.acquire)` (line 189) | detectCycle hop snapshot | (none) — no chain test |
| TK-02 | `seq` | `load(.acquire)` (line 216) | detectCycle hop revalidation | (none) |
| TK-03 | `seq` | `fetchAdd(1, .release)` (482, 738, 890 park; 496, 560, 750, 900, 960, 975 wake) | park / wake transition | M, P, L, WW, WR, RWW |
| TK-04 | `waiting_for_lock_kind` | `load(.acquire)` (143) | currentChainOwner dispatch | (none) — no chain test |
| TK-05 | `waiting_for_lock_kind` | `store(...)` (474, 492, 556, 733, 746, 884, 897, 956, 974) | park kind / wake clear | M, P, L, WW, WR, RWW |
| TK-06 | `waiting_for_lock` | `load(.acquire)` (145) | currentChainOwner | (none) |
| TK-07 | `waiting_for_lock` | `store(...)` (475, 491, 555, 734, 745, 885, 896, 955, 973) | park / wake | L, WW, WR, RWW |
| TK-08 | `waiting_for_lock_owner` | `store(...)` (473, 493, 557, 732, 747, 957) | park / wake clear | L, WW, WR |
| TK-09 | `status` | `store(.Blocked, .release)` (478, 737, 889) | park transition | L, WW, WR, RWW |
| TK-10 | `status` | `load` (harness unpark check) | harness, scheduler.submitResume | M, P, L, WW, WR, RWW |

10 task-field site classes. Untested classes: **TK-01, TK-02, TK-04, TK-06**
— all of which are the detectCycle read path. There is currently **zero
loom coverage of the cycle-detection chain walk.** Every existing test has
chain depth 0 (no chain hop ever read).

## Detected gaps

### GAP-A: `ParkingRwLock.write_owner` is not Loom-instrumented

`zig/lib/parking-lot.zig:624` declares
`write_owner: std.atomic.Value(?*Task)` instead of using the comptime
`Atomic` alias that picks `SimAtomic` under loom. **9 access sites
(PR-W2..W10) become invisible to the Loom harness.** The cycle-detect
read of write_owner (line 153, the *only* write-rwlock cycle-detection
read) cannot interleave under Loom. Fix in M2: change to `Atomic(?*Task)`.
Verify: rerun WW; cycle/detect-tests in M6 cannot pass without this.

### GAP-B: `SimAtomic` is missing `fetchAnd`

`runtime/vopr-atomic.zig` exposes load / store / cmpxchg{Strong,Weak} /
swap / fetchAdd / fetchSub / fetchOr but **not `fetchAnd`**. parking-lot.zig
calls `state.fetchAnd(...)` at PM-21, PM-24, PR-12, PR-29 — four sites
on the unlock hot path.

`zig build test` currently passes the parking-lot-loom-test, which means
either (a) Zig's lazy semantic analysis is somehow eliding the missing
method (suspicious — unlock IS called and IS instantiated), or (b) the
comptime `Atomic` alias is silently resolving to `std.atomic.Value`
under the loom build, in which case **all six existing loom tests have
been running with real atomics and never actually exercising loom
interleaving.** This is a critical correctness question for M2: a
loom suite that doesn't actually loom is worse than no loom suite, since
it gives false confidence. M2 must (1) add `SimAtomic.fetchAnd`, (2)
add a runtime assertion (e.g. a counter incremented by `yieldPoint`)
that proves the loom path actually fires from inside lock/unlock during
a test run, (3) determine which of (a)/(b) is happening and document it.

### GAP-C: detectCycle has zero loom coverage

The `detectCycle` chain walk (lines 178-239) reads `Task.seq`,
`waiting_for_lock_kind`, `waiting_for_lock`, and the lock owner field
across N hops in a snapshot loop with retry. Every existing loom test
exercises chain depth 0 (no waiter ever finds another waiter as its
chain target). PR-W2, PR-W4, TK-01..02, TK-04, TK-06 are unhit.

This is M6's surface. The full set of cycle-detect interleavings is:
- self-cycle (depth 0) → `error.Deadlock`
- 2-hop AB/BA → `error.LockCycle`
- 3-hop ABC/BCA → `error.LockCycle`
- ownership transfers mid-walk → must NOT false-positive (validates
  seq+chain-link snapshot retry)
- constantly transitioning chain (MAX_DETECT_RETRIES exhausted) → walk
  returns clean, no panic
- read-lock terminator: shared waiter on the chain → walk stops at
  shared-kind, no false positive

### GAP-D: No timeout-path coverage

PM-20, PM-24, PR-11, PR-21, PR-24, PR-W7 are all on timeout / stale-
waiters paths. The current loom harness has no timeout simulation —
`task.lock_timed_out` is never set during a loom run. M5/M6 may need
a synthetic "force-timeout" hook (e.g., harness sets the flag on a
parked task at a chosen yield point).

### GAP-E: presetLocked + tryLock untested under loom

PM-05, PM-06, PM-07. `presetLocked` is used by the existing
parking-lot-test.zig rendezvous primitives (4 callers); under
contention, the rendezvous-style wakeup path is its own race surface.
M3 should fold a presetLocked + tryLock fiber pattern into the matrix.

## Existing loom tests

`runtime/parking-lot-loom.zig`:

| Test | Pattern | Sites hit | Sites missed |
|---|---|---|---|
| mutex acquireVsRelease exhaustive (256 schedules) | 2 fibers x 1 cycle | fast paths PM-08/09/21 + queue_spin if contention | most slow path |
| mutex acquireVsRelease prng (500 seeds) | same as above | same | same |
| mutex lost-wake regression (3 fibers x 3 cycles, base-3 exhaustive 59049) | full park/unpark with contention | PM-01/02/08/09/15..19/21..23 | PM-05/06/07/20/24 |
| rwlock two writers exhaustive (256) | 2 fibers x 1 write | PR-03..05/08..10/12 + PR-W3/W4/W5/W6/W8/W9/W10 (invisible) | PR-11/PR-W2/W7 |
| rwlock writer vs reader exhaustive (256) | 1 W + 1 R | PR-03..05/09/12..14/18/19/25 + PR-W3/W9 | reader-drain |
| rwlock 2 readers + 1 writer prng (500) | 1 W + 2 R | PR-03/04/13/14/18..20/22/23/25..29 + PR-W10 | PR-21/24/W2/W7 |

## Milestones the inventory drives

- **M2** — fix GAP-A and GAP-B; add the loom-actually-fires assertion.
- **M3** — generalize the mutex matrix to cover PM-05..07 and the
  invariants need to hold at every yield point (one owner, LOCKED ⇔
  owner_bits ≠ 0, HAS_WAITERS bit ⇒ queue non-empty / under-cleanup).
- **M4** — one targeted exhaustive test per mutex park/wake race:
  park-grab vs unlock fetchAnd (PM-21 + PM-18/19), unlock owner-transfer
  CAS losing (PM-23), stale-HAS_WAITERS cleanup (PM-24).
- **M5** — rwlock park/unpark races covering PR-21/24 and the
  writer-pref CAS-retry loop in wakeNext (PR-26/27).
- **M6** — cycle-detection coverage (closes GAP-C). Six chain
  scenarios, all six error / non-error outcomes asserted. Forces TK-01,
  TK-02, TK-04, TK-06, PR-W2 to fire.
- **M7** — dropped (FSM out of scope on this branch).
- **M8** — instrument `SimAtomic` with per-call-site IDs (use the IDs
  from this document); accumulate hit bitmap; suite fails on any unhit
  ID. Closes the "ZERO untested atomics" requirement structurally.
- **M9** — fast / nightly tiers wired into `zig build test`.
