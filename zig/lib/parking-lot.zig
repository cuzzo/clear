// Fiber-aware mutex and readers-writer lock for the CLEAR cooperative scheduler.
//
// On contention, the calling fiber parks (yields to its scheduler) instead of
// blocking the OS thread with a futex. The scheduler resumes the fiber when the
// lock becomes available via direct ownership transfer from unlock().
//
// Fast path: one atomic CAS — identical cost to tryLock(). Zero overhead when
// uncontended. Slow path: cooperative fiber yield + scheduler wakeup, cheaper
// than pthread_mutex_lock (no futex syscall, no OS scheduler involvement).
//
// Safety properties vs pthread_mutex:
//   - Deadlock detection: walk the owner chain before parking. Return
//     error.Deadlock on re-entrant acquisition or AB/BA cycle. The fiber's
//     defers run on error unwind, releasing any locks it already holds and
//     unblocking other waiters. No process kill required.
//   - Timeout: if a fiber waits more than sched.lock_timeout_ms (default 30s),
//     the scheduler wakes it and lock() returns error.LockTimeout.
//   - Non-fiber context: falls back to a tight spin (safe for scheduler startup
//     code, tests, and any path where active_scheduler is not set).
//
// Loom testing: the Atomic type alias picks up SimAtomic in Loom mode, making
// all CAS operations on locked/readers/spin yield points for exhaustive testing.

const std = @import("std");

// Comptime-switchable atomic: SimAtomic in Loom mode, std.atomic.Value otherwise.
// `root` here is the executable root — for the parking-lot-loom executable
// (see ../parking-lot-loom-test.zig), it re-exports `pub const SimAtomic`.
// For every other build the decl is absent, so the alias resolves to the
// real `std.atomic.Value`. SimAtomic exposes the same `raw: T` field as
// `std.atomic.Value`, so helpers like Futex below that take `*Atomic(...)`
// and use `&ptr.raw` type-check identically in both modes.
const Atomic = blk: {
    const root = @import("root");
    break :blk if (@hasDecl(root, "SimAtomic")) root.SimAtomic else std.atomic.Value;
};

const qs = @import("../runtime/queues.zig");
const fc = @import("../runtime/fiber-core.zig");
const fp = @import("../runtime/scheduler.zig");
const compat = @import("compat.zig");

const Task = qs.Task;
const WaiterNode = qs.WaiterNode;
const WaiterList = qs.WaiterList;

// Profile telemetry (comptime-gated). HoldStart is a conditional field:
// when CLEAR_PROFILE == false it's `void` (zero-sized), so production
// builds have exactly the same ParkingMutex layout they did before.
const rt_profile = @import("../runtime/runtime-header.zig");
const lock_profile = @import("../runtime/lock-profile.zig");
const HoldStart = if (rt_profile.CLEAR_PROFILE) u64 else void;

pub const LockError = error{
    // Self-cyclic: the waiter is the owner (same fiber re-acquired). Always a
    // user bug; not retryable. Maps to ErrorKind.System.
    Deadlock,
    // Multi-hop cycle (A holds X and waits on Y; B holds Y and waits on X).
    // Resolvable if either party backs off and retries with jitter, so it's
    // classified as Transient.
    LockCycle,
    // Lock wait exceeded the scheduler's lock_timeout_ms deadline. Transient.
    LockTimeout,
};

// Non-fiber (raw-thread) waiters spin this many iterations before falling
// back to a futex park. Tuned to match glibc pthread's adaptive mutex which
// spins around 100 iterations on contended mutexes before parking.
const SPIN_BUDGET: u32 = 100;

// Thin Linux-futex wrapper for the non-fiber fallback. The CLEAR runtime is
// Linux-only (io_uring), so a portable abstraction is unnecessary. Used
// only on the raw-thread path — fiber callers park on the scheduler via
// task.base.yield() which is cheaper than any syscall.
//
// Linux futex is u32-only. For a u64 atomic (e.g. ParkingMutex.state which
// packs owner pointer + flag bits), we wait on the lower 32 bits via
// pointer cast. x86_64 is little-endian, so the lower 32 bits live at the
// base address of the u64. A change to upper bits (owner pointer changing)
// will spuriously wake the futex; we just retry, which is correct.
const linux = std.os.linux;
const Futex = struct {
    // Pointer types are `*Atomic(...)` rather than `*std.atomic.Value(...)`
    // so the helpers type-check whether `Atomic` resolves to the real
    // std.atomic.Value (production) or to SimAtomic (loom). Both expose
    // `raw: T`, so `&ptr.raw` is a `*T` in either case. Loom never reaches
    // these calls at runtime (the non-fiber branch is dead under loom),
    // so the syscall is never made — but the type system is satisfied.
    inline fn wait(ptr: *Atomic(u32), expected: u32) void {
        const op = linux.FUTEX_OP{ .cmd = .WAIT, .private = true };
        _ = linux.futex_4arg(@ptrCast(&ptr.raw), op, expected, null);
    }
    inline fn wake(ptr: *Atomic(u32), n: u32) void {
        const op = linux.FUTEX_OP{ .cmd = .WAKE, .private = true };
        _ = linux.futex_3arg(@ptrCast(&ptr.raw), op, n);
    }
    inline fn waitU64Low(ptr: *Atomic(u64), expected_low: u32) void {
        const op = linux.FUTEX_OP{ .cmd = .WAIT, .private = true };
        _ = linux.futex_4arg(@ptrCast(&ptr.raw), op, expected_low, null);
    }
    inline fn wakeU64(ptr: *Atomic(u64), n: u32) void {
        const op = linux.FUTEX_OP{ .cmd = .WAKE, .private = true };
        _ = linux.futex_3arg(@ptrCast(&ptr.raw), op, n);
    }
};

// Returns the active scheduler if we are currently running inside a fiber,
// null otherwise (scheduler startup, test code, non-fiber paths).
inline fn getScheduler() ?*fp.Scheduler {
    if (!fp.scheduler_running) return null;
    return fp.active_scheduler;
}

// Walk the owner chain from `owner` looking for `waiter`. If found,
// return error.Deadlock when the owner is the waiter (depth 0,
// self-cyclic, always a user bug) or error.LockCycle when the cycle
// is multi-hop (AB/BA, resolvable by one party backing off).
// Depth-limited to MAX_CHAIN_DEPTH (32) to guard against corrupted
// state. Read locks store null in waiting_for_lock_owner and act as
// chain terminators.

/// Result of an FSM-side lock acquisition attempt. Shared between
/// ParkingMutex.tryLockForFsm, ParkingRwLock.tryWriteLockForFsm and
/// ParkingRwLock.tryReadLockForFsm.
pub const FsmLockResultTop = enum {
    /// Lock acquired synchronously; caller proceeds to CS.
    Acquired,
    /// Waiter was registered on the lock's queue. Caller's FSM resume
    /// fn must return YieldReason.WaitForLock.
    Registered,
    /// Safety violation (re-entrancy, cycle). Specific error is on
    /// `fsm_task.lock_error`.
    Error,
};
//
// Best-effort under TOCTOU: per-Task fields are atomic with paired
// release/acquire ordering (see queues.zig for park/wake store order),
// but a chain walk across N Tasks isn't a single atomic snapshot.
// 14_nested_lock at THREADS>=4 with a strict-address-ordered workload
// can still trigger a false-positive panic from a stale-but-consistent
// chain observation -- documented in benchmarks/tofix.md as the
// remaining structural fix needed (likely a packed atomic state).
// Snapshot of one hop in the chain walk. Captured per-Task so we can
// validate after the walk that no Task transitioned during it AND that
// the LOCK STATE the Task is waiting on hasn't shifted under us.
//
// `gen` is task.generation captured AFTER the slab pin succeeded.
// During validation, comparing task.generation to `gen` detects
// slot-level reuse (same slab, same slot, but a different logical
// Task occupies it now). The slab pin itself rules out the slab
// having been freed, so the read of task.generation is structurally
// safe even when the Task slot has been recycled.
//
// `wait_kind` / `wait_lock` / `wait_state` capture the lock the
// holder is waiting on AT THE MOMENT of the walk. Validation re-reads
// the lock's atomic state and compares to `wait_state`. Any change
// (owner transfer, flag flip, lock release) is treated as a torn
// snapshot — the chain we walked is no longer authoritative. This
// closes the residual false-positive class where the chain walk
// derived `next` from a lock state that subsequently transitioned but
// happened to land on the same `next` pointer in a way the seq +
// per-Task checks didn't notice (e.g. the INITIAL hop, where the
// lock the waiter is trying to acquire transferred ownership between
// the caller's pre-walk read and the validation phase).
const HopSnapshot = struct {
    task: *Task,
    seq: u32,
    gen: u32,
    /// LOCK_KIND_* of the lock `task` is waiting on at snapshot time.
    /// Validation re-reads task.waiting_for_lock_kind and compares.
    wait_kind: u8,
    /// Lock pointer the task is waiting on. null when the chain
    /// terminates at this hop (task no longer parked, on a shared
    /// rwlock, or parked on an unknown lock kind).
    wait_lock: ?*anyopaque,
    /// Snapshot of the lock's atomic state at walk time. For
    /// ParkingMutex this is the full u64 (LOCKED + flags + owner
    /// pointer). For ParkingRwLock-write it is the write_owner
    /// pointer cast to u64. Validation re-reads via `readLockState`
    /// and any difference torns the snapshot.
    ///
    /// The next-hop owner pointer is derivable on demand via
    /// `ownerFromState(wait_state, wait_kind)`, so we don't store
    /// it separately — keeping HopSnapshot at 32 bytes matters on
    /// 12 KB Standard fiber stacks where detectCycle frames stack
    /// alongside lockSlow + the user fiber's own locals.
    wait_state: u64,
};

/// Bound on chain length. Cycles in real code are tiny (the
/// pathological 14_nested_lock benchmark forms 2- or 3-hop cycles);
/// 32 is generous. Larger arrays inflate detectCycle's stack frame,
/// and detectCycle runs on the calling fiber's stack — whose default
/// (Standard tier) is only 12 KB. With pin per hop (32 B) + hop
/// snapshot (32 B), 32 entries lives in 2 KB plus retry locals.
const MAX_CHAIN_DEPTH: usize = 32;
const MAX_DETECT_RETRIES: u32 = 8;

/// Read the atomic state of a lock identified by (kind, ptr). The
/// returned u64 is the single linearization point that captures
/// the lock's owner-relevant state. `ownerFromState` extracts the
/// owner pointer from it. Walker snapshots this once per hop and
/// re-reads it during validation to detect any transition.
inline fn readLockState(kind: u8, lock_ptr: *anyopaque) u64 {
    return switch (kind) {
        qs.LOCK_KIND_MUTEX => blk: {
            const m: *ParkingMutex = @ptrCast(@alignCast(lock_ptr));
            break :blk m.state.load(.acquire);
        },
        qs.LOCK_KIND_RWLOCK_WRITE => blk: {
            const r: *ParkingRwLock = @ptrCast(@alignCast(lock_ptr));
            break :blk @intFromPtr(r.write_owner.load(.acquire));
        },
        // Shared rwlock and unknown kinds are chain terminators —
        // caller should never hand them to readLockState.
        else => 0,
    };
}

/// Extract the exclusive owner *Task from a state value previously
/// obtained via readLockState. Returns null if the lock is currently
/// free or held by a non-fiber (e.g. raw thread that left the owner
/// bits zero).
inline fn ownerFromState(state: u64, kind: u8) ?*Task {
    return switch (kind) {
        qs.LOCK_KIND_MUTEX => blk: {
            const owner_bits = state & ParkingMutex.STATE_OWNER_MASK;
            break :blk if (owner_bits == 0) null else @as(?*Task, @ptrFromInt(owner_bits));
        },
        qs.LOCK_KIND_RWLOCK_WRITE => blk: {
            break :blk if (state == 0) null else @as(?*Task, @ptrFromInt(state));
        },
        else => null,
    };
}

// detectCycle: walk the owner chain and report a real cycle as
// error.LockCycle / error.Deadlock.
//
// Robustness has FOUR layers:
//   1. Slab pin per hop. Before reading any field of a chain holder
//      (`*Task` observed transitively from a lock's state), pin the
//      slab containing that Task via `fp.pinTask`. The pin holds a
//      refcount on the slab, so the underlying memory cannot be
//      freed by `task_slab.shrinkEmpty` while the walk is in
//      progress. If pinTask returns null, the *Task pointer refers
//      to a slab that has already been freed (e.g. the holder
//      finished and its scheduler shrank the empty slab); we treat
//      that as a chain terminator and the walk is benignly empty.
//   2. Generation check per hop. After the pin succeeds the slab
//      memory is alive but the SLOT may have been recycled
//      (different logical Task now occupies it). `gen` is
//      task.generation captured at pin time; if a later read of
//      task.generation differs, we know the slot was reused mid-
//      walk → snapshot torn, retry.
//   3. The per-Task `seq` counter. seq increments on every
//      park/wake transition; if it changed between snapshot and
//      validation, the holder transitioned and the walk is stale.
//   4. PER-HOP LOCK STATE SNAPSHOT. The walker captures the full
//      atomic state of the lock the holder is waiting on (mutex
//      `state` u64, or rwlock `write_owner` pointer) and re-reads
//      it during validation. Any transition — owner transfer, flag
//      flip, lock release — torns the snapshot. The INITIAL hop
//      (the lock the waiter itself wants) is included: the walker
//      reads the initial state once per attempt and validates it,
//      so a transfer between the caller's pre-walk hint and our
//      derivation cannot produce a false-positive cycle observation.
//
// After MAX_DETECT_RETRIES torn snapshots we treat the system as
// "transitioning constantly" and return without panic. A real cycle
// would have produced a stable snapshot within the retry budget.
fn detectCycle(waiter: *Task, lock_ptr: *anyopaque, lock_kind: u8) LockError!void {
    // detectCycle is only called for exclusive (write-style) locks.
    // Shared rwlock acquisition cannot deadlock-by-itself: there is
    // no single owner to walk back to.
    std.debug.assert(lock_kind == qs.LOCK_KIND_MUTEX or
                     lock_kind == qs.LOCK_KIND_RWLOCK_WRITE);

    var hops: [MAX_CHAIN_DEPTH]HopSnapshot = undefined;
    var pins: [MAX_CHAIN_DEPTH]?fp.TaskPin = [_]?fp.TaskPin{null} ** MAX_CHAIN_DEPTH;
    var attempt: u32 = 0;

    // Always release pins on return, even on early-exit / error paths.
    defer for (pins) |maybe_pin| {
        if (maybe_pin) |p| fp.unpinTask(p);
    };

    while (attempt < MAX_DETECT_RETRIES) : (attempt += 1) {
        // Drop pins from any prior attempt before re-walking.
        for (&pins) |*slot| {
            if (slot.*) |p| { fp.unpinTask(p); slot.* = null; }
        }

        // Read the initial lock state fresh per attempt. This is the
        // anchor of the walk: a stale starting owner from a previous
        // attempt cannot leak through.
        const initial_state = readLockState(lock_kind, lock_ptr);
        var current = ownerFromState(initial_state, lock_kind);

        var n: usize = 0;
        var found_self_at_depth: ?usize = null;

        while (current) |holder| : (n += 1) {
            if (n >= MAX_CHAIN_DEPTH) break;

            // Pin the slab containing `holder`. If the slab was freed
            // (or `holder` was never slab-allocated, e.g. a Loom-harness
            // stub Task), treat as a chain terminator: a freed Task
            // cannot be in any cycle by definition.
            const pin = fp.pinTask(holder) orelse break;
            pins[n] = pin;

            const seq0 = holder.seq.load(.acquire);
            const wait_kind = holder.waiting_for_lock_kind.load(.acquire);
            const wait_lock = holder.waiting_for_lock.load(.acquire);

            // Determine if `holder` is parked on a chain-walkable lock.
            // Shared rwlock and "no kind" are chain terminators; we
            // record the snapshot anyway (so validation can verify the
            // holder didn't transition into being waiting on something
            // walkable mid-validation) but do not extend the walk.
            const walkable = wait_lock != null and
                (wait_kind == qs.LOCK_KIND_MUTEX or
                 wait_kind == qs.LOCK_KIND_RWLOCK_WRITE);
            const wait_state: u64 = if (walkable)
                readLockState(wait_kind, wait_lock.?)
            else
                0;
            const next = if (walkable) ownerFromState(wait_state, wait_kind) else null;

            hops[n] = .{
                .task = holder,
                .seq = seq0,
                .gen = pin.gen,
                .wait_kind = wait_kind,
                .wait_lock = wait_lock,
                .wait_state = wait_state,
            };
            if (holder == waiter) {
                found_self_at_depth = n;
                break;
            }
            if (next == null) break;
            current = next;
        }

        // Validate snapshot. Four checks per hop, plus an initial-state
        // re-read covering the hop -1 / waiter-side lock:
        //   (0) Initial lock state unchanged → the lock the waiter is
        //       trying to acquire still has the same exclusive owner
        //       (and same flag bits). Catches the "stale starting
        //       owner" race that no per-hop check could detect: the
        //       chain walk derived `current` from a lock state that
        //       transferred ownership before validation.
        //   (1) Generation unchanged → the slab slot wasn't recycled.
        //   (2) Task seq unchanged → the holder didn't transition.
        //   (3) Holder's wait fields and lock state unchanged → the
        //       holder is still parked on the same lock with the same
        //       owner / flag configuration, so the chain link this hop
        //       represents is still authoritative.
        // For a real cycle, all participants are parked and the locks'
        // states are frozen, so all checks pass.
        var torn = false;
        if (readLockState(lock_kind, lock_ptr) != initial_state) torn = true;
        if (!torn) for (hops[0..n]) |h| {
            if (h.task.generation.load(.acquire) != h.gen) { torn = true; break; }
            if (h.task.seq.load(.acquire) != h.seq) { torn = true; break; }
            if (h.task.waiting_for_lock_kind.load(.acquire) != h.wait_kind) {
                torn = true; break;
            }
            if (h.task.waiting_for_lock.load(.acquire) != h.wait_lock) {
                torn = true; break;
            }
            // Re-read the wait lock's state. Equal state ⇒ owner +
            // flags unchanged ⇒ chain link h.next is still derived
            // from the same authoritative source.
            if (h.wait_lock) |wl| {
                if (readLockState(h.wait_kind, wl) != h.wait_state) {
                    torn = true; break;
                }
            }
        };
        if (torn) continue;

        if (found_self_at_depth) |depth| {
            if (depth == 0) return error.Deadlock;
            return error.LockCycle;
        }
        return; // clean walk, no cycle
    }
    return;
}

/// Cycle detection for an FSM waiter attempting to acquire `lock_ptr`.
/// Walks the chain of holders. At each hop: prefer the FSM chain
/// (waiting_for_fsm_owner) if set, fall back to the stackful chain
/// (waiting_for_lock_owner). Finds FSM↔FSM cycles and FSM→Stackful
/// one-hop cycles. Does NOT trace FSM→Stackful→FSM cycles yet —
/// requires FsmTask to track waiting_for_task_owner (follow-up).
///
/// TODO(rebase-onto-vm-fix-rewrite): tighten this to match
/// detectCycle's option-C protocol (slab pin per Task hop,
/// generation check, atomic per-hop lock-state snapshot, retry on
/// torn snapshot, atomic loads on FsmTask back-pointer fields).
/// See "FSM safety parity" in the rebase plan.
fn detectCycleFsm(
    waiter: *fp.FsmTask,
    initial_task_owner: ?*Task,
    initial_fsm_owner: ?*fp.FsmTask,
    lock_ptr: *anyopaque,
) LockError!void {
    var depth: usize = 0;
    var cur_task: ?*Task = initial_task_owner;
    var cur_fsm: ?*fp.FsmTask = initial_fsm_owner;
    while (depth < 64) : (depth += 1) {
        if (cur_fsm) |ft| {
            if (ft == waiter) {
                if (depth == 0) {
                    std.debug.print(
                        "DEADLOCK: FSM {*} re-acquired lock {*}\n",
                        .{ waiter, lock_ptr },
                    );
                    return error.Deadlock;
                }
                std.debug.print(
                    "LOCK CYCLE: FSM {*} waiting on lock {*} via {} hop(s)\n",
                    .{ waiter, lock_ptr, depth },
                );
                return error.LockCycle;
            }
            // FsmTask.waiting_for_fsm_owner is a plain ?*FsmTask in
            // thunks-cleanup. Atomicizing FsmTask fields is the
            // follow-up step for FSM safety parity; for now read
            // unsynchronized — the FsmTask lifetime is bounded by
            // its scheduler's run loop (no cross-scheduler free
            // window) so this is best-effort.
            const next_fsm_any = ft.waiting_for_fsm_owner;
            cur_task = null;
            cur_fsm = next_fsm_any;
        } else if (cur_task) |t| {
            // FSM waiter cannot equal a Task holder; follow the stackful
            // chain. .acquire pairs with the .release stores in lockSlow's
            // park sequence after vm-fix-rewrite atomicized the field.
            cur_fsm = null;
            cur_task = t.waiting_for_lock_owner.load(.acquire);
        } else break;
    }
}


// ─────────────────────────────────────────────────────────────────────────────
// ParkingMutex — exclusive (write) lock
// ─────────────────────────────────────────────────────────────────────────────
pub const ParkingMutex = struct {
    // Packed state in a single atomic u64. ALL hot-path data lives here:
    //   bits 0:        LOCKED            -- lock currently held
    //   bits 1:        HAS_WAITERS       -- one or more fibers parked
    //   bits 2:        HAS_THREAD_SLEEPER -- one or more raw threads parked
    //   bits 3-63:     OWNER             -- *Task pointer (Task is 8-aligned,
    //                                       so its low 3 bits are always 0;
    //                                       fits cleanly above flag bits)
    //
    // For non-fiber holders the OWNER bits are 0; cycle detection sees a
    // null owner and treats the chain as terminated (correct -- we have no
    // way to walk a non-fiber holder's wait chain).
    //
    // Putting the owner pointer in the same atomic as the lock state means:
    //   * One CAS on acquire sets BOTH lock and owner -- no separate store.
    //   * One fetchAnd on release clears BOTH -- no separate store.
    //   * One cache line touched per op (was two with separate `owner`).
    //
    // Linux futex is u32-only; we wait on the lower 32 bits of state via
    // Futex.waitU64Low. Owner-bits changing in the upper part causes
    // spurious wakes, which we correctly handle (loop and retry).
    pub const STATE_LOCKED:             u64 = 1;
    pub const STATE_HAS_WAITERS:        u64 = 2;
    pub const STATE_HAS_THREAD_SLEEPER: u64 = 4;
    pub const STATE_FLAG_MASK:          u64 = 7;
    pub const STATE_OWNER_MASK:         u64 = ~@as(u64, 7);
    pub const STATE_WAKE_BITS:          u64 = STATE_HAS_WAITERS | STATE_HAS_THREAD_SLEEPER;

    state: Atomic(u64) = Atomic(u64).init(0),
    // FSM owner side field. Task owners live in the state word's owner
    // bits; FSM owners live here to avoid alignment assumptions on
    // FsmTask pointers. Set on Acquired by tryLockForFsm, cleared by
    // unlock. Read by detectCycleFsm during cycle-walk.
    fsm_owner: Atomic(?*fp.FsmTask) = Atomic(?*fp.FsmTask).init(null),
    // Spinlock protecting the waiter queue.
    queue_spin: Atomic(u32) = Atomic(u32).init(0),
    waiters: WaiterList = .{},
    // Profile-only: captured at acquire success, read at unlock entry
    // to compute hold time. Only ever touched by the thread holding
    // the lock, so no synchronization needed. Zero-sized in non-
    // profile builds via the `HoldStart` conditional alias.
    hold_start_ns: HoldStart = if (rt_profile.CLEAR_PROFILE) 0 else {},

    inline fn ownerOf(state_val: u64) ?*Task {
        const owner_bits = state_val & STATE_OWNER_MASK;
        if (owner_bits == 0) return null;
        return @ptrFromInt(owner_bits);
    }

    fn spinAcquireQueue(self: *ParkingMutex) void {
        while (self.queue_spin.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    fn spinReleaseQueue(self: *ParkingMutex) void {
        self.queue_spin.store(0, .release);
    }

    /// Test/inspection helpers.
    pub fn isLocked(self: *const ParkingMutex) bool {
        return (self.state.load(.acquire) & STATE_LOCKED) != 0;
    }
    pub fn ownerTask(self: *const ParkingMutex) ?*Task {
        return ownerOf(self.state.load(.acquire));
    }
    /// Pre-lock without an owner. Test rendezvous primitive only.
    pub fn presetLocked(self: *ParkingMutex) void {
        _ = self.state.fetchOr(STATE_LOCKED, .monotonic);
    }

    pub fn tryLock(self: *ParkingMutex) bool {
        const cur = self.state.load(.acquire);
        if ((cur & STATE_LOCKED) != 0) return false;
        const owner_val: u64 = if (getScheduler()) |sched|
            @intFromPtr(sched.current_task)
        else
            0;
        const new_state = cur | STATE_LOCKED | owner_val;
        return self.state.cmpxchgWeak(cur, new_state, .acquire, .monotonic) == null;
    }

    pub const FsmLockResult = FsmLockResultTop;

    /// FSM lock acquisition.
    ///
    /// Non-blocking from the fiber-yield perspective. On success, returns
    /// `.Acquired` and the caller owns the lock. On contention, registers
    /// `waiter` (storage supplied by the caller — lives in the FSM's user
    /// state struct) on the mutex's waiter queue, sets `fsm_task.lock_waiter`,
    /// and returns `.Registered`. The caller's FSM resume function must
    /// then return `YieldReason.WaitForLock`; the scheduler parks the
    /// task, and `unlock()` on the owner wakes it via `submitFsmResume`.
    ///
    /// Returns `.Error` with `fsm_task.lock_error` set on safety
    /// violations (re-entrancy, cycle). Timeout is surfaced by the
    /// scheduler's scanFsmLockWaiters via the same lock_error field.
    pub fn tryLockForFsm(
        self: *ParkingMutex,
        fsm_task: *fp.FsmTask,
        waiter: *WaiterNode,
        sched: *fp.Scheduler,
    ) FsmLockResult {
        // Safety: re-entrancy.
        if (self.fsm_owner.load(.acquire)) |cur_fsm| {
            if (cur_fsm == fsm_task) {
                std.debug.print(
                    "DEADLOCK: FSM {*} re-acquired mutex {*} it already holds\n",
                    .{ fsm_task, self },
                );
                fsm_task.lock_error = .Deadlock;
                return .Error;
            }
        }
        // Safety: cycle detection.
        const pre_state = self.state.load(.acquire);
        const pre_task_owner = ownerOf(pre_state);
        const pre_fsm_owner = self.fsm_owner.load(.acquire);
        detectCycleFsm(fsm_task, pre_task_owner, pre_fsm_owner, self) catch |err| {
            fsm_task.lock_error = switch (err) {
                error.Deadlock => .Deadlock,
                error.LockCycle => .LockCycle,
                else => .Deadlock,
            };
            return .Error;
        };

        // Fast path: uncontended CAS.
        const cur = self.state.load(.acquire);
        if ((cur & STATE_LOCKED) == 0) {
            const new_state = cur | STATE_LOCKED;
            if (self.state.cmpxchgWeak(cur, new_state, .acquire, .monotonic) == null) {
                self.fsm_owner.store(fsm_task, .release);
                if (rt_profile.CLEAR_PROFILE) {
                    self.hold_start_ns = lock_profile.now();
                    lock_profile.recordAcquire(@intFromPtr(self), 0, false);
                }
                return .Acquired;
            }
        }

        // Contended path: register under queue_spin.
        self.spinAcquireQueue();
        const recheck = self.state.load(.acquire);
        if ((recheck & STATE_LOCKED) == 0) {
            const new_state = recheck | STATE_LOCKED;
            if (self.state.cmpxchgWeak(recheck, new_state, .acquire, .monotonic) == null) {
                self.fsm_owner.store(fsm_task, .release);
                self.spinReleaseQueue();
                if (rt_profile.CLEAR_PROFILE) {
                    self.hold_start_ns = lock_profile.now();
                    lock_profile.recordAcquire(@intFromPtr(self), 0, true);
                }
                return .Acquired;
            }
        }
        _ = self.state.fetchOr(STATE_HAS_WAITERS, .release);

        waiter.* = WaiterNode{
            .task = undefined,
            .fsm_task = fsm_task,
            .sched_ptr = sched,
            .kind = .Write,
        };
        self.waiters.push(waiter);
        fsm_task.lock_waiter = waiter;
        fsm_task.waiting_for_lock = self;
        fsm_task.waiting_for_lock_list = &self.waiters;
        fsm_task.waiting_for_fsm_owner = pre_fsm_owner;
        fsm_task.lock_wait_start_ms = compat.milliTimestamp();
        sched.registerFsmLockWaiter(fsm_task);

        self.spinReleaseQueue();
        return .Registered;
    }

    pub fn lock(self: *ParkingMutex) LockError!void {
        const wait_start: u64 = if (rt_profile.CLEAR_PROFILE) lock_profile.now() else 0;

        // Fast path: load + CAS preserving any flag bits already set,
        // packing owner into state in the same atomic op as LOCKED.
        const cur = self.state.load(.acquire);
        if ((cur & STATE_LOCKED) == 0) {
            const owner_val: u64 = if (getScheduler()) |sched|
                @intFromPtr(sched.current_task)
            else
                0;
            const new_state = cur | STATE_LOCKED | owner_val;
            if (self.state.cmpxchgWeak(cur, new_state, .acquire, .monotonic) == null) {
                if (rt_profile.CLEAR_PROFILE) {
                    self.hold_start_ns = lock_profile.now();
                    lock_profile.recordAcquire(@intFromPtr(self), 0, false);
                }
                return;
            }
        }
        try self.lockSlow();
        if (rt_profile.CLEAR_PROFILE) {
            const acquired_at = lock_profile.now();
            self.hold_start_ns = acquired_at;
            lock_profile.recordAcquire(@intFromPtr(self), acquired_at - wait_start, true);
        }
    }

    fn lockSlow(self: *ParkingMutex) LockError!void {
        const sched_opt = getScheduler();

        if (sched_opt == null) {
            // Non-fiber: spin-then-yield-then-futex.
            //
            // For brief CS the spin phase acquires without leaving user
            // space. The yield phase covers moderate hold times. Only for
            // genuinely long waits do we futex-park.
            //
            // We CLEAR HAS_THREAD_SLEEPER when waking from futex. Letting
            // it stay sticky meant every unlock thereafter paid a Futex.wake
            // syscall (~1500ns) even when no one was parked, which is what
            // made Mutex slower than RwLock-as-mutex on contended brief-CS
            // workloads (RwLock has no thread-sleeper bit at all).
            const NF_SPIN_BUDGET:  u32 = 256;
            const NF_YIELD_BUDGET: u32 = 32;
            while (true) {
                var spins: u32 = 0;
                while (spins < NF_SPIN_BUDGET) : (spins += 1) {
                    if ((self.state.load(.monotonic) & STATE_LOCKED) == 0) break;
                    std.atomic.spinLoopHint();
                }
                if (spins == NF_SPIN_BUDGET) {
                    var yields: u32 = 0;
                    while (yields < NF_YIELD_BUDGET) : (yields += 1) {
                        std.Thread.yield() catch {};
                        if ((self.state.load(.monotonic) & STATE_LOCKED) == 0) break;
                    }
                    if (yields == NF_YIELD_BUDGET) {
                        // Long wait -- park on futex.
                        // The HAS_THREAD_SLEEPER bit is left sticky after
                        // wake. Clearing it on wake creates a lost-wake
                        // deadlock when multiple threads are parked: A
                        // wakes, clears the bit, A unlocks → bit clear →
                        // no wake fires for still-parked B. Sticky-bit
                        // means every unlock thereafter pays a Futex.wake
                        // syscall (~1500ns) but it's correct.
                        const before = self.state.fetchOr(STATE_HAS_THREAD_SLEEPER, .acquire);
                        if ((before & STATE_LOCKED) == 0) continue; // race
                        const expected_low: u32 = @truncate(before | STATE_HAS_THREAD_SLEEPER);
                        Futex.waitU64Low(&self.state, expected_low);
                        continue;
                    }
                }
                // Looks free -- attempt CAS preserving other bits.
                const cur = self.state.load(.acquire);
                if ((cur & STATE_LOCKED) != 0) continue;
                const new_state = cur | STATE_LOCKED;
                if (self.state.cmpxchgWeak(cur, new_state, .acquire, .monotonic) == null) return;
            }
        }

        const sched = sched_opt.?;
        const task = sched.current_task.?;

        // Re-entrancy check: same task already owns the lock → deadlock.
        const cur_state = self.state.load(.acquire);
        const current_owner = ownerOf(cur_state);
        if (current_owner == task) return error.Deadlock;

        // Walk the owner chain BEFORE taking queue_spin. detectCycle
        // re-reads `self.state` itself (via readLockState) so that a
        // stale `current_owner` here cannot leak into the walk —
        // that's the option-(C) initial-state validation.
        try detectCycle(task, self, qs.LOCK_KIND_MUTEX);

        self.spinAcquireQueue();

        // Re-check: state might have become unlocked. CAS preserving flag
        // bits; pack owner in the same op.
        const recheck = self.state.load(.acquire);
        if ((recheck & STATE_LOCKED) == 0) {
            const new_state = recheck | STATE_LOCKED | @intFromPtr(task);
            if (self.state.cmpxchgWeak(recheck, new_state, .acquire, .monotonic) == null) {
                self.spinReleaseQueue();
                return;
            }
        }

        // Set HAS_WAITERS BEFORE pushing to the queue. The race we close
        // here: an unlock that runs between the recheck above and our push
        // to the waiter list. If unlock samples HAS_WAITERS=0 (because we
        // haven't set it yet), it returns without taking queue_spin and
        // without waking anyone. Setting HAS_WAITERS first means any
        // concurrent unlock observes HAS_WAITERS=1 in its fetchAnd and
        // takes the wake path; once it hits queue_spin it serializes with
        // us and either pops our node (if we've pushed) or sees an empty
        // queue + clears the stale HAS_WAITERS.
        //
        // After fetchOr, double-check LOCKED. If the lock became free AND
        // the waiter queue is empty, we can safely grab the lock without
        // parking. The empty-queue check is critical: if a real waiter is
        // queued, an in-flight unlock is about to transfer ownership to
        // them via state.store (line ~493 below). If we acquire here AND
        // then release queue_spin, that unlock would pop the waiter and
        // store-overwrite our owner field — both us AND the waiter would
        // think we own the lock, corrupting the protected data. We hold
        // queue_spin so no concurrent push can race with isEmpty().
        const after_or = self.state.fetchOr(STATE_HAS_WAITERS, .acq_rel) | STATE_HAS_WAITERS;
        if ((after_or & STATE_LOCKED) == 0 and self.waiters.isEmpty()) {
            // Lock free + queue empty: safe to acquire. A concurrent unlock
            // that already passed fetchAnd is now waiting on queue_spin;
            // when it gets in, it pops the empty queue and hits the
            // stale-HAS_WAITERS cleanup, which only clears HAS_WAITERS —
            // never touches LOCKED/owner — so our acquire is preserved.
            const target = STATE_LOCKED | @intFromPtr(task)
                | (after_or & STATE_HAS_THREAD_SLEEPER);
            if (self.state.cmpxchgStrong(after_or, target, .acquire, .monotonic) == null) {
                self.spinReleaseQueue();
                return;
            }
            // CAS lost — fall through to park.
        }

        var node = WaiterNode{ .task = task, .sched_ptr = sched, .kind = .Write };
        self.waiters.push(&node);
        // Park-side ordering: owner FIRST, then lock with .release. Cycle
        // detection on another core does an .acquire load of `lock`; if
        // it sees a non-null lock, it is guaranteed (release/acquire pair)
        // to also see the matching owner store.
        task.waiting_for_lock_owner.store(current_owner, .release);
        task.waiting_for_lock_kind.store(qs.LOCK_KIND_MUTEX, .release);
        task.waiting_for_lock.store(self, .release);
        task.waiting_for_lock_list.store(&self.waiters, .release);
        task.lock_waiter_node.store(&node, .release);
        task.status.store(.Blocked, .release);
        // Mark transition for detectCycle's snapshot validation. Must come
        // AFTER the field stores so a walker that observes the new seq is
        // guaranteed to also observe the new (lock, kind).
        _ = task.seq.fetchAdd(1, .release);
        self.spinReleaseQueue();

        sched.registerLockWaiter(task);
        task.base.yield();

        // Wake-side ordering: lock cleared FIRST so a walker that loads
        // lock as null after our release stops the chain regardless of
        // any stale owner field.
        task.waiting_for_lock.store(null, .release);
        task.waiting_for_lock_kind.store(qs.LOCK_KIND_NONE, .release);
        task.waiting_for_lock_owner.store(null, .release);
        task.waiting_for_lock_list.store(null, .release);
        task.lock_waiter_node.store(null, .release);
        _ = task.seq.fetchAdd(1, .release);

        if (task.lock_timed_out.load(.acquire)) {
            task.lock_timed_out.store(false, .release);
            if (ownerOf(self.state.load(.acquire)) == task) return;
            std.debug.print("LOCK TIMEOUT: fiber {*} waited for mutex {*}\n", .{ task, self });
            return error.LockTimeout;
        }

        // Ownership transferred by unlock; nothing more to do (state already
        // has owner = task).
    }

    pub fn unlock(self: *ParkingMutex) void {
        if (rt_profile.CLEAR_PROFILE) {
            if (self.hold_start_ns != 0) {
                const hold = lock_profile.now() - self.hold_start_ns;
                lock_profile.recordRelease(@intFromPtr(self), hold);
                self.hold_start_ns = 0;
            }
        }
        // fsm_owner is set only by FSM-side acquire/transfer paths and
        // is null when a stackful Task holds the lock — no clear needed
        // here. Adding an extra .release store every unlock would burn
        // a SimAtomic yield point and (per loom regression) destabilize
        // the lost-wake schedule space without functional benefit.
        // Single atomic op: clear LOCKED + OWNER, preserving flag bits.
        // fetchAnd returns the prior value, which tells us whether to wake.
        const prev = self.state.fetchAnd(STATE_FLAG_MASK & ~STATE_LOCKED, .release);
        // = fetchAnd(STATE_HAS_WAITERS | STATE_HAS_THREAD_SLEEPER)
        // Hot path: no waiters of either kind. Single atomic op total.
        if ((prev & STATE_WAKE_BITS) == 0) return;

        if ((prev & STATE_HAS_WAITERS) != 0) {
            self.spinAcquireQueue();
            // Re-read state under spin: a parker may have re-acquired via
            // the lockSlow double-check-after-fetchOr path while we were
            // blocked on queue_spin. If so, abort the transfer — that
            // owner will wake the queue on its own unlock.
            const cur_state = self.state.load(.acquire);
            if ((cur_state & STATE_LOCKED) != 0) {
                self.spinReleaseQueue();
                return;
            }
            // Peek (don't pop yet): we need to atomically transfer ownership
            // to head waiter. If state changes between our load and store, we
            // bail without popping so the head stays queued for next unlock.
            const head = self.waiters.head;
            if (head) |w| {
                const more_after = w.next != null;
                const sleeper_bit: u64 = cur_state & STATE_HAS_THREAD_SLEEPER;
                const more_bit: u64 = if (more_after) STATE_HAS_WAITERS else 0;
                // FSM wakers do not encode an owner pointer (FSMs hold
                // exclusivity via self.fsm_owner instead — packed
                // owner-bits are reserved for stackful Task pointers).
                const owner_bits: u64 = if (w.isFsm()) @as(u64, 0) else @intFromPtr(w.task);
                const new_state: u64 = STATE_LOCKED | sleeper_bit | more_bit | owner_bits;
                if (self.state.cmpxchgStrong(cur_state, new_state, .release, .monotonic) != null) {
                    // State changed (concurrent fast-path acquire). Bail.
                    self.spinReleaseQueue();
                    return;
                }
                // Transfer succeeded — now safe to pop and wake.
                _ = self.waiters.pop();
                if (w.isFsm()) {
                    // FSM wake: clear FSM-side fields, set fsm_owner so
                    // detectCycleFsm sees this FSM as the holder, then
                    // submit FSM resume. FsmTask field atomicization is
                    // a follow-up; fields are set non-atomically here
                    // (FsmTask lifetime is bounded by its scheduler's
                    // run loop).
                    const ft: *fp.FsmTask = @ptrCast(@alignCast(w.fsm_task.?));
                    self.fsm_owner.store(ft, .release);
                    ft.lock_waiter = null;
                    ft.waiting_for_lock = null;
                    ft.waiting_for_lock_list = null;
                    ft.waiting_for_fsm_owner = null;
                    const sched: *fp.Scheduler = @ptrCast(@alignCast(w.sched_ptr));
                    sched.submitFsmResume(ft) catch unreachable;
                } else {
                    // Stackful wake-side ordering: lock cleared FIRST
                    // (with .release) so a concurrent detectCycle reader
                    // sees lock==null and does not chase a stale
                    // waiting_for_lock_owner.
                    w.task.waiting_for_lock.store(null, .release);
                    w.task.waiting_for_lock_kind.store(qs.LOCK_KIND_NONE, .release);
                    w.task.waiting_for_lock_owner.store(null, .release);
                    w.task.waiting_for_lock_list.store(null, .release);
                    w.task.lock_waiter_node.store(null, .release);
                    _ = w.task.seq.fetchAdd(1, .release);
                    const sched: *fp.Scheduler = @ptrCast(@alignCast(w.sched_ptr));
                    sched.submitResume(w.task);
                }
                self.spinReleaseQueue();
                return;
            }
            // Stale HAS_WAITERS (timed-out waiter). Clear it.
            _ = self.state.fetchAnd(~STATE_HAS_WAITERS, .release);
            self.spinReleaseQueue();
            // Fall through to thread sleeper wake check.
        }

        if ((prev & STATE_HAS_THREAD_SLEEPER) != 0) {
            Futex.wakeU64(&self.state, 1);
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// ParkingRwLock — fair readers-writer lock with lock-free fast paths
//
// State is packed into a single atomic u32 word, accessed via atomic
// fetch_add / cmpxchg / fetch_and -- NO secondary spinlock for the fast
// paths. The previous design protected separate readers/write_locked/queue
// fields with an internal spinlock; that spinlock's CAS loop was the
// dominant cost under N-thread contention (cache line bouncing between
// cores). The single-word design matches what pthread_rwlock and Rust's
// parking_lot::RwLock use.
//
// State layout (u32):
//   bits 0-29: reader count (~1B max)
//   bit 30:    WRITE_LOCKED
//   bit 31:    HAS_WAITERS  (queue is non-empty; slow path required)
//
// Fast paths (no spin lock):
//   lockShared:  state.fetchAdd(1); if conflict (write/waiters bit set),
//                undo via state.fetchSub(1) and fall to slow path.
//   lock:        state.cmpxchg(0, WRITE_LOCKED). Fails if any bit set.
//   unlockShared: state.fetchSub(1); if was last reader and HAS_WAITERS,
//                go to wakeNext.
//   unlock:      state.fetchAnd(~WRITE_LOCKED); if HAS_WAITERS, wakeNext.
//
// Slow paths take a separate `queue_spin` to manage the waiter FIFO. The
// HAS_WAITERS bit lets fast-path releases skip the queue spin entirely
// when no one is parked -- the common case.
//
// Fairness: single FIFO waiter queue. wakeNext drains from head:
//   - Writer at head and no readers → grant write, stop.
//   - Reader at head → grant read, continue draining contiguous readers.
// New arrivals queue if HAS_WAITERS is set, preventing both reader and
// writer starvation.
// ─────────────────────────────────────────────────────────────────────────────
pub const ParkingRwLock = struct {
    pub const WRITE_LOCKED_BIT: u32 = 1 << 30;
    pub const HAS_WAITERS_BIT:  u32 = 1 << 31;
    pub const READER_MASK:      u32 = (1 << 30) - 1;
    pub const NON_READER_BITS:  u32 = WRITE_LOCKED_BIT | HAS_WAITERS_BIT;

    state: Atomic(u32) = Atomic(u32).init(0),
    // Spinlock protecting the waiter queue + the moves of HAS_WAITERS_BIT.
    // Only entered on slow path (waiters parking, wakeNext draining) -- not
    // in the contended fast path.
    queue_spin: Atomic(u32) = Atomic(u32).init(0),
    waiters: WaiterList = .{},
    // GAP-A fix: was `std.atomic.Value(?*Task)`. With the comptime alias,
    // SimAtomic substitution under loom now covers every read/write of
    // write_owner — including the cycle-detect reads in detectCycle's
    // option-C readLockState path.
    write_owner: Atomic(?*Task) = Atomic(?*Task).init(null),
    // Parallel FSM owner side field. Set when an FSM holds the write
    // lock; stackful holders use write_owner instead. Null while
    // unlocked or reader-held (readers have no single owner). Enables
    // re-entrancy + cycle detection for FSM writers.
    fsm_write_owner: Atomic(?*fp.FsmTask) = Atomic(?*fp.FsmTask).init(null),
    // Profile-only: write-lock hold start. Reader lock hold times are
    // trickier (multiple concurrent readers) and deferred; for now we
    // instrument the write path since that's where contention bites.
    hold_start_ns: HoldStart = if (rt_profile.CLEAR_PROFILE) 0 else {},

    // Aliases to keep the existing field-access API surface used by tests/
    // benchmarks readable. These are NOT separate fields -- they read the
    // packed state word.
    pub fn isWriteLocked(self: *const ParkingRwLock) bool {
        return (self.state.load(.acquire) & WRITE_LOCKED_BIT) != 0;
    }
    pub fn readerCount(self: *const ParkingRwLock) i32 {
        return @intCast(self.state.load(.acquire) & READER_MASK);
    }

    fn spinAcquireQueue(self: *ParkingRwLock) void {
        while (self.queue_spin.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }
    fn spinReleaseQueue(self: *ParkingRwLock) void {
        self.queue_spin.store(0, .release);
    }

    // Exclusive (write) lock
    pub fn lock(self: *ParkingRwLock) LockError!void {
        const wait_start: u64 = if (rt_profile.CLEAR_PROFILE) lock_profile.now() else 0;

        // Fast path: only succeeds if state is fully zero.
        if (self.state.cmpxchgWeak(0, WRITE_LOCKED_BIT, .acquire, .monotonic) == null) {
            if (getScheduler()) |sched| {
                self.write_owner.store(sched.current_task, .release);
            }
            if (rt_profile.CLEAR_PROFILE) {
                self.hold_start_ns = lock_profile.now();
                lock_profile.recordAcquire(@intFromPtr(self), 0, false);
            }
            return;
        }
        try self.lockSlow();
        if (rt_profile.CLEAR_PROFILE) {
            const acquired_at = lock_profile.now();
            self.hold_start_ns = acquired_at;
            lock_profile.recordAcquire(@intFromPtr(self), acquired_at - wait_start, true);
        }
    }

    fn lockSlow(self: *ParkingRwLock) LockError!void {
        const sched_opt = getScheduler();

        if (sched_opt == null) {
            // Non-fiber: test-then-CAS. CAS-spinning bounces the cache line
            // every iteration; reading-then-CAS lets all waiters share the
            // line until exactly one acquires.
            while (true) {
                var spins: u32 = 0;
                while (spins < SPIN_BUDGET) : (spins += 1) {
                    if (self.state.load(.monotonic) == 0) break;
                    std.atomic.spinLoopHint();
                }
                if (spins == SPIN_BUDGET) {
                    std.Thread.yield() catch {};
                    continue;
                }
                // Looks free; try once.
                if (self.state.cmpxchgWeak(0, WRITE_LOCKED_BIT, .acquire, .monotonic) == null) return;
                // Lost the race; loop back to read-spin.
            }
        }

        const sched = sched_opt.?;
        const task = sched.current_task.?;

        // Detect cycles BEFORE taking the queue spin. detectCycle
        // re-reads `self.write_owner` itself (via readLockState) so
        // that a transition between this hint read and the walk
        // cannot leak through.
        try detectCycle(task, self, qs.LOCK_KIND_RWLOCK_WRITE);

        self.spinAcquireQueue();

        // Re-check: state might have become 0 between our fast-path attempt
        // and now. If so, take it without queueing.
        if (self.state.cmpxchgWeak(0, WRITE_LOCKED_BIT, .acquire, .monotonic) == null) {
            self.write_owner.store(task, .release);
            self.spinReleaseQueue();
            return;
        }

        // Set HAS_WAITERS_BIT BEFORE pushing. See ParkingMutex.lockSlow for
        // the full LOST WAKE race explanation. Same fix here: unlock that
        // races with our park must observe HAS_WAITERS=1 in its fetchAnd
        // and take the wake path. Only attempt CAS-to-grab when the queue
        // is empty — an in-flight wakeNext for an existing waiter would
        // store-overwrite our owner field if we leapfrog them.
        const after_or = self.state.fetchOr(HAS_WAITERS_BIT, .acq_rel) | HAS_WAITERS_BIT;
        if ((after_or & (WRITE_LOCKED_BIT | READER_MASK)) == 0 and self.waiters.isEmpty()) {
            const target = WRITE_LOCKED_BIT;
            if (self.state.cmpxchgStrong(after_or, target, .acquire, .monotonic) == null) {
                self.write_owner.store(task, .release);
                self.spinReleaseQueue();
                return;
            }
            // CAS lost — fall through to park.
        }

        var node = WaiterNode{ .task = task, .sched_ptr = sched, .kind = .Write };
        self.waiters.push(&node);
        // Park-side ordering: owner+kind FIRST, then lock with .release.
        task.waiting_for_lock_owner.store(self.write_owner.load(.acquire), .release);
        task.waiting_for_lock_kind.store(qs.LOCK_KIND_RWLOCK_WRITE, .release);
        task.waiting_for_lock.store(self, .release);
        task.waiting_for_lock_list.store(&self.waiters, .release);
        task.lock_waiter_node.store(&node, .release);
        task.status.store(.Blocked, .release);
        _ = task.seq.fetchAdd(1, .release);
        self.spinReleaseQueue();

        sched.registerLockWaiter(task);
        task.base.yield();

        // Wake-side ordering: lock FIRST so the chain walker stops at us.
        task.waiting_for_lock.store(null, .release);
        task.waiting_for_lock_kind.store(qs.LOCK_KIND_NONE, .release);
        task.waiting_for_lock_owner.store(null, .release);
        task.waiting_for_lock_list.store(null, .release);
        task.lock_waiter_node.store(null, .release);
        _ = task.seq.fetchAdd(1, .release);

        if (task.lock_timed_out.load(.acquire)) {
            task.lock_timed_out.store(false, .release);
            // Did wakeNext grant us the lock right before timeout fired?
            if ((self.state.load(.acquire) & WRITE_LOCKED_BIT) != 0
                and self.write_owner.load(.acquire) == task)
            {
                return;
            }
            std.debug.print("LOCK TIMEOUT: fiber {*} waited for write lock {*}\n", .{ task, self });
            return error.LockTimeout;
        }

        // Ownership transferred by wakeNext.
        self.write_owner.store(task, .release);
    }

    pub fn unlock(self: *ParkingRwLock) void {
        if (rt_profile.CLEAR_PROFILE) {
            if (self.hold_start_ns != 0) {
                const hold = lock_profile.now() - self.hold_start_ns;
                lock_profile.recordRelease(@intFromPtr(self), hold);
                self.hold_start_ns = 0;
            }
        }
        self.write_owner.store(null, .release);
        // fsm_write_owner is set only by FSM-side acquire/transfer paths
        // and is null when a stackful Task holds the lock. Skipping the
        // clear here saves a SimAtomic yield point on the hot stackful
        // unlock path (otherwise the address-ordered VOPR loom test
        // exhausts MAX_STEPS).
        // Clear write bit. fetchAnd returns the prior value so we can detect
        // HAS_WAITERS in one atomic op (no separate load).
        const prev = self.state.fetchAnd(~WRITE_LOCKED_BIT, .release);
        if ((prev & HAS_WAITERS_BIT) != 0) {
            self.spinAcquireQueue();
            self.wakeNext();
            self.spinReleaseQueue();
        }
    }

    // FSM write lock — non-blocking registration.
    //
    // Returns `.Acquired` / `.Registered` / `.Error` (on safety
    // violation via fsm_task.lock_error). Parallels ParkingMutex's
    // tryLockForFsm with the rwlock state encoding. Re-entrancy and
    // cycle detection match Mutex behavior — a writer chain is a
    // single-owner chain, so detectCycleFsm applies.
    pub fn tryWriteLockForFsm(
        self: *ParkingRwLock,
        fsm_task: *fp.FsmTask,
        waiter: *WaiterNode,
        sched: *fp.Scheduler,
    ) FsmLockResultTop {
        // Safety: write re-entrancy on the same FSM.
        if (self.fsm_write_owner.load(.acquire)) |cur| {
            if (cur == fsm_task) {
                std.debug.print(
                    "DEADLOCK: FSM {*} re-acquired rwlock write {*}\n",
                    .{ fsm_task, self },
                );
                fsm_task.lock_error = .Deadlock;
                return .Error;
            }
        }
        // Safety: cycle detection across stackful/FSM writer chains.
        const pre_task_owner = self.write_owner.load(.acquire);
        const pre_fsm_owner = self.fsm_write_owner.load(.acquire);
        detectCycleFsm(fsm_task, pre_task_owner, pre_fsm_owner, self) catch |err| {
            fsm_task.lock_error = switch (err) {
                error.Deadlock => .Deadlock,
                error.LockCycle => .LockCycle,
                else => .Deadlock,
            };
            return .Error;
        };

        // Fast path: state == 0 → claim WRITE_LOCKED.
        const cur = self.state.load(.acquire);
        if (cur == 0) {
            if (self.state.cmpxchgWeak(0, WRITE_LOCKED_BIT, .acquire, .monotonic) == null) {
                self.fsm_write_owner.store(fsm_task, .release);
                if (rt_profile.CLEAR_PROFILE) {
                    self.hold_start_ns = lock_profile.now();
                    lock_profile.recordAcquire(@intFromPtr(self), 0, false);
                }
                return .Acquired;
            }
        }

        // Slow path: register under queue_spin.
        self.spinAcquireQueue();
        const recheck = self.state.load(.acquire);
        if (recheck == 0) {
            if (self.state.cmpxchgWeak(0, WRITE_LOCKED_BIT, .acquire, .monotonic) == null) {
                self.fsm_write_owner.store(fsm_task, .release);
                self.spinReleaseQueue();
                if (rt_profile.CLEAR_PROFILE) {
                    self.hold_start_ns = lock_profile.now();
                    lock_profile.recordAcquire(@intFromPtr(self), 0, true);
                }
                return .Acquired;
            }
        }
        _ = self.state.fetchOr(HAS_WAITERS_BIT, .release);

        waiter.* = WaiterNode{
            .task = undefined,
            .fsm_task = fsm_task,
            .sched_ptr = sched,
            .kind = .Write,
        };
        self.waiters.push(waiter);
        fsm_task.lock_waiter = waiter;
        fsm_task.waiting_for_lock = self;
        fsm_task.waiting_for_lock_list = &self.waiters;
        fsm_task.waiting_for_fsm_owner = pre_fsm_owner;
        fsm_task.lock_wait_start_ms = compat.milliTimestamp();
        sched.registerFsmLockWaiter(fsm_task);

        self.spinReleaseQueue();
        return .Registered;
    }

    // FSM read lock — non-blocking registration.
    //
    // No re-entrancy check: read locks are stackable by design. No
    // owner-chain entry: readers have no single owner to walk through
    // (consistent with the stackful path). Timeout scanning still
    // applies via registerFsmLockWaiter.
    pub fn tryReadLockForFsm(
        self: *ParkingRwLock,
        fsm_task: *fp.FsmTask,
        waiter: *WaiterNode,
        sched: *fp.Scheduler,
    ) FsmLockResultTop {
        // Fast path: optimistic fetchAdd. Undo if WRITE_LOCKED or HAS_WAITERS set.
        const prev = self.state.fetchAdd(1, .acquire);
        if ((prev & NON_READER_BITS) == 0) {
            if (rt_profile.CLEAR_PROFILE) {
                lock_profile.recordReadAcquire(@intFromPtr(self), 0, false);
            }
            return .Acquired;
        }
        // Conflict: undo the optimistic increment, then register as a reader waiter.
        //
        // Critical: if our undo restores state to "0 readers + HAS_WAITERS
        // + no writer", we MUST call wakeNext. Otherwise a queued writer
        // can deadlock: a concurrent unlock saw our transient +1 in state
        // and skipped its wake (wakeNext for a write waiter returns when
        // READER_MASK != 0); if we don't wake here, no future op will,
        // since there are no holders left to release. This mirrors
        // lockShared's stackful undo logic. Missing this call is a
        // deterministic lost-wakeup race witnessed by
        // fsm-rwlock-hammer-test.zig.
        //
        // The WRITE_LOCKED == 0 guard is critical: if the writer still
        // holds when we undo, calling wakeNext could grant a reader at
        // queue head (the .Read branch of wakeNext does fetchAdd
        // unconditionally — its callers are expected to know WRITE_LOCKED
        // is clear). The writer's eventual unlock will trigger the wake
        // for us.
        const prev_undo = self.state.fetchSub(1, .release);
        if ((prev_undo & READER_MASK) == 1
            and (prev_undo & HAS_WAITERS_BIT) != 0
            and (prev_undo & WRITE_LOCKED_BIT) == 0)
        {
            self.spinAcquireQueue();
            self.wakeNext();
            self.spinReleaseQueue();
        }

        self.spinAcquireQueue();
        // Re-check: maybe lock cleared and no writer waiters in the queue.
        const st = self.state.load(.acquire);
        if ((st & WRITE_LOCKED_BIT) == 0) {
            // No writer holds. But if there are writer waiters, we still
            // park to preserve write-priority fairness (mirror stackful).
            const head = self.waiters.peek();
            const has_writer_ahead = head != null and head.?.kind == .Write;
            if (!has_writer_ahead) {
                _ = self.state.fetchAdd(1, .acquire);
                self.spinReleaseQueue();
                if (rt_profile.CLEAR_PROFILE) {
                    lock_profile.recordReadAcquire(@intFromPtr(self), 0, true);
                }
                return .Acquired;
            }
        }
        _ = self.state.fetchOr(HAS_WAITERS_BIT, .release);

        waiter.* = WaiterNode{
            .task = undefined,
            .fsm_task = fsm_task,
            .sched_ptr = sched,
            .kind = .Read,
        };
        self.waiters.push(waiter);
        fsm_task.lock_waiter = waiter;
        fsm_task.waiting_for_lock = self;
        fsm_task.waiting_for_lock_list = &self.waiters;
        // Readers have no single owner; leave waiting_for_fsm_owner null.
        fsm_task.waiting_for_fsm_owner = null;
        fsm_task.lock_wait_start_ms = compat.milliTimestamp();
        sched.registerFsmLockWaiter(fsm_task);

        self.spinReleaseQueue();
        return .Registered;
    }

    // Shared (read) lock
    pub fn lockShared(self: *ParkingRwLock) LockError!void {
        // Fast path: optimistic fetchAdd. Conflict → undo and slow path.
        const prev = self.state.fetchAdd(1, .acquire);
        if ((prev & NON_READER_BITS) == 0) {
            if (rt_profile.CLEAR_PROFILE) {
                lock_profile.recordReadAcquire(@intFromPtr(self), 0, false);
            }
            return; // no writer, no waiters → got it
        }
        // Conflict: undo our increment.
        // Critical: if our undo restores state to "0 readers + HAS_WAITERS",
        // we must call wakeNext. Otherwise a queued writer can deadlock --
        // the actual last reader's unlockShared saw our transient +1 and
        // skipped its wake; if we don't wake here, no future op will, since
        // state has no holders to release.
        // The WRITE_LOCKED == 0 guard mirrors the FSM fix in fb0576b9:
        // wakeNext's .Read branch does fetchAdd(1) UNCONDITIONALLY (its
        // callers are expected to know WRITE_LOCKED is clear). If we
        // call wakeNext here while a writer still holds, we'd grant a
        // queued reader a phantom slot -- the reader wakes thinking it
        // has the read lock and races with the writer's mutation.
        // The writer's eventual unlock will fire the wake when it
        // releases, so skipping here loses no progress.
        const prev_undo = self.state.fetchSub(1, .release);
        if ((prev_undo & READER_MASK) == 1
            and (prev_undo & HAS_WAITERS_BIT) != 0
            and (prev_undo & WRITE_LOCKED_BIT) == 0)
        {
            self.spinAcquireQueue();
            self.wakeNext();
            self.spinReleaseQueue();
        }
        return self.lockSharedSlow();
    }

    fn lockSharedSlow(self: *ParkingRwLock) LockError!void {
        const sched_opt = getScheduler();
        const wait_start: u64 = if (rt_profile.CLEAR_PROFILE) lock_profile.now() else 0;

        if (sched_opt == null) {
            // Test-then-fetchAdd. fetchAdd thrashes the cache line on every
            // failed attempt (the +1/-1 still touches the line). Read-spin
            // until WRITE_LOCKED is clear, then optimistically fetchAdd.
            while (true) {
                var spins: u32 = 0;
                while (spins < SPIN_BUDGET) : (spins += 1) {
                    if ((self.state.load(.monotonic) & WRITE_LOCKED_BIT) == 0) break;
                    std.atomic.spinLoopHint();
                }
                if (spins == SPIN_BUDGET) {
                    std.Thread.yield() catch {};
                    continue;
                }
                const prev = self.state.fetchAdd(1, .acquire);
                if ((prev & NON_READER_BITS) == 0) {
                    if (rt_profile.CLEAR_PROFILE) {
                        const acquired_at = lock_profile.now();
                        lock_profile.recordReadAcquire(@intFromPtr(self), acquired_at - wait_start, true);
                    }
                    return;
                }
                _ = self.state.fetchSub(1, .release);
            }
        }

        const sched = sched_opt.?;
        const task = sched.current_task.?;

        self.spinAcquireQueue();

        // Re-check: maybe state cleared between fast-path attempt and now.
        // Only join if NO waiters are queued (FIFO fairness; otherwise we'd
        // leapfrog them).
        if (self.waiters.isEmpty()) {
            const prev = self.state.fetchAdd(1, .acquire);
            if ((prev & NON_READER_BITS) == 0) {
                self.spinReleaseQueue();
                if (rt_profile.CLEAR_PROFILE) {
                    const acquired_at = lock_profile.now();
                    lock_profile.recordReadAcquire(@intFromPtr(self), acquired_at - wait_start, true);
                }
                return;
            }
            // Same wake-on-undo logic as the fast path. We already hold
            // queue_spin so we can call wakeNext directly. Guard with
            // WRITE_LOCKED_BIT == 0 (mirrors the fast-path guard) so we
            // never wake a reader while a writer still holds the lock.
            const prev_undo = self.state.fetchSub(1, .release);
            if ((prev_undo & READER_MASK) == 1 and (prev_undo & HAS_WAITERS_BIT) != 0 and (prev_undo & WRITE_LOCKED_BIT) == 0) {
                self.wakeNext();
                // wakeNext may have drained everyone we'd queue behind. If
                // state is now grantable for us, take it; otherwise fall
                // through and queue.
                const prev_retry = self.state.fetchAdd(1, .acquire);
                if ((prev_retry & NON_READER_BITS) == 0) {
                    self.spinReleaseQueue();
                    if (rt_profile.CLEAR_PROFILE) {
                        const acquired_at = lock_profile.now();
                        lock_profile.recordReadAcquire(@intFromPtr(self), acquired_at - wait_start, true);
                    }
                    return;
                }
                _ = self.state.fetchSub(1, .release);
            }
        }

        // Set HAS_WAITERS_BIT BEFORE pushing. Same LOST WAKE race as the
        // exclusive path. For shared acquire, an unlock that runs between
        // our last state load and our push must observe HAS_WAITERS=1
        // in its fetchAdd-undo path (line ~813) and call wakeNext.
        // Only grab a reader slot when no writer holds the lock AND
        // the queue is empty — leapfrogging a queued writer would
        // starve them; a queued reader can be safely woken by wakeNext
        // alongside us.
        const after_or = self.state.fetchOr(HAS_WAITERS_BIT, .acq_rel) | HAS_WAITERS_BIT;
        if ((after_or & WRITE_LOCKED_BIT) == 0 and self.waiters.isEmpty()) {
            const prev_retry = self.state.fetchAdd(1, .acquire);
            if ((prev_retry & WRITE_LOCKED_BIT) == 0) {
                self.spinReleaseQueue();
                return;
            }
            // Writer arrived between checks — undo and park.
            _ = self.state.fetchSub(1, .release);
        }

        var node = WaiterNode{ .task = task, .sched_ptr = sched, .kind = .Read };
        self.waiters.push(&node);
        // SHARED kind: detectCycle treats this as a chain terminator (read
        // locks have no single owner — multiple readers may hold it).
        task.waiting_for_lock_kind.store(qs.LOCK_KIND_RWLOCK_SHARED, .release);
        task.waiting_for_lock.store(self, .release);
        task.waiting_for_lock_list.store(&self.waiters, .release);
        task.lock_waiter_node.store(&node, .release);
        // waiting_for_lock_owner stays null: read locks have no single owner.
        task.status.store(.Blocked, .release);
        _ = task.seq.fetchAdd(1, .release);
        self.spinReleaseQueue();

        sched.registerLockWaiter(task);
        task.base.yield();

        task.waiting_for_lock.store(null, .release);
        task.waiting_for_lock_kind.store(qs.LOCK_KIND_NONE, .release);
        task.waiting_for_lock_list.store(null, .release);
        task.lock_waiter_node.store(null, .release);
        _ = task.seq.fetchAdd(1, .release);

        if (task.lock_timed_out.load(.acquire)) {
            task.lock_timed_out.store(false, .release);
            // wakeNext would have already incremented our reader slot if it
            // granted us the lock. Detecting that here without a separate
            // flag is racy with concurrent unlocks; keep the simple path
            // and treat all timeouts as errors. In practice, the reader
            // grant is fast enough that the timeout race is negligible.
            std.debug.print("LOCK TIMEOUT: fiber {*} waited for read lock {*}\n", .{ task, self });
            return error.LockTimeout;
        }
        // Ownership (reader slot) was already incremented by wakeNext.
        if (rt_profile.CLEAR_PROFILE) {
            const acquired_at = lock_profile.now();
            lock_profile.recordReadAcquire(@intFromPtr(self), acquired_at - wait_start, true);
        }
    }

    pub fn unlockShared(self: *ParkingRwLock) void {
        const prev = self.state.fetchSub(1, .release);
        // Wake only when we were the LAST reader AND there are waiters.
        if ((prev & READER_MASK) == 1 and (prev & HAS_WAITERS_BIT) != 0) {
            self.spinAcquireQueue();
            self.wakeNext();
            self.spinReleaseQueue();
        }
    }

    // Wake the next waiter(s) in FIFO order. MUST be called with queue_spin
    // held. Drains from queue head subject to current state.
    fn wakeNext(self: *ParkingRwLock) void {
        while (self.waiters.peek()) |head| {
            switch (head.kind) {
                .Write => {
                    // Writer needs state to have READER_MASK == 0 and
                    // WRITE_LOCKED clear. Loop the CAS to absorb transient
                    // state changes from concurrent reader fast-path attempts
                    // (they fetchAdd then undo when they see HAS_WAITERS).
                    var cur = self.state.load(.acquire);
                    while (true) {
                        // If readers hold, the last one's unlockShared
                        // will call us again. Stop draining.
                        if ((cur & READER_MASK) != 0) return;
                        // Target: claim WRITE_LOCKED, preserve HAS_WAITERS
                        // iff more waiters remain after this pop.
                        const more_after = (self.waiters.head != self.waiters.tail);
                        const target = WRITE_LOCKED_BIT
                            | (if (more_after) HAS_WAITERS_BIT else @as(u32, 0));
                        if (self.state.cmpxchgWeak(cur, target, .acquire, .monotonic)) |actual| {
                            cur = actual;
                            // Brief retry on transient (reader add/undo race).
                            continue;
                        }
                        break; // CAS succeeded
                    }
                    const w = self.waiters.pop().?;
                    // Profile: granting a parked writer = a contended
                    // acquire. Stackful writers' lockSlow re-records on
                    // resume, but FSM writers don't re-enter
                    // tryWriteLockForFsm after the wake -- this is their
                    // only acquire site.
                    if (rt_profile.CLEAR_PROFILE and w.isFsm()) {
                        lock_profile.recordAcquire(@intFromPtr(self), 0, true);
                    }
                    if (w.isFsm()) {
                        const ft: *fp.FsmTask = @ptrCast(@alignCast(w.fsm_task.?));
                        self.fsm_write_owner.store(ft, .release);
                        self.write_owner.store(null, .release);
                        ft.lock_waiter = null;
                        ft.waiting_for_lock = null;
                        ft.waiting_for_fsm_owner = null;
                        const sched: *fp.Scheduler = @ptrCast(@alignCast(w.sched_ptr));
                        sched.submitFsmResume(ft) catch unreachable;
                    } else {
                        self.write_owner.store(w.task, .release);
                        // Wake-side ordering: lock cleared FIRST.
                        w.task.waiting_for_lock.store(null, .release);
                        w.task.waiting_for_lock_kind.store(qs.LOCK_KIND_NONE, .release);
                        w.task.waiting_for_lock_owner.store(null, .release);
                        w.task.waiting_for_lock_list.store(null, .release);
                        w.task.lock_waiter_node.store(null, .release);
                        _ = w.task.seq.fetchAdd(1, .release);
                        const sched: *fp.Scheduler = @ptrCast(@alignCast(w.sched_ptr));
                        sched.submitResume(w.task);
                    }
                    return; // grant one writer per wakeNext
                },
                .Read => {
                    // Grant a reader slot. WRITE_LOCKED is clear here (we
                    // only enter wakeNext after clearing it). HAS_WAITERS
                    // stays set; we'll fix it up after the drain.
                    _ = self.state.fetchAdd(1, .acquire);
                    const r = self.waiters.pop().?;
                    // Profile: granting a parked reader = a contended
                    // read acquire. Stackful readers' lockSharedSlow
                    // re-records on resume; FSM readers do not.
                    if (rt_profile.CLEAR_PROFILE and r.isFsm()) {
                        lock_profile.recordReadAcquire(@intFromPtr(self), 0, true);
                    }
                    if (r.isFsm()) {
                        const ft: *fp.FsmTask = @ptrCast(@alignCast(r.fsm_task.?));
                        ft.lock_waiter = null;
                        ft.waiting_for_lock = null;
                        ft.waiting_for_fsm_owner = null;
                        const sched: *fp.Scheduler = @ptrCast(@alignCast(r.sched_ptr));
                        sched.submitFsmResume(ft) catch unreachable;
                    } else {
                        r.task.waiting_for_lock_list.store(null, .release);
                        r.task.lock_waiter_node.store(null, .release);
                        r.task.waiting_for_lock.store(null, .release);
                        r.task.waiting_for_lock_kind.store(qs.LOCK_KIND_NONE, .release);
                        _ = r.task.seq.fetchAdd(1, .release);
                        const sched: *fp.Scheduler = @ptrCast(@alignCast(r.sched_ptr));
                        sched.submitResume(r.task);
                    }
                    // Continue draining: next head might be another reader.
                },
            }
        }
        // Queue drained → clear HAS_WAITERS so fast paths skip the spin.
        _ = self.state.fetchAnd(~HAS_WAITERS_BIT, .release);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// ParkingRwLocked(T) — thin wrapper providing read()/write() guard API,
// mirroring compat.RwLocked(T) so data-structures.zig can swap it in.
// ─────────────────────────────────────────────────────────────────────────────
pub fn ParkingRwLocked(comptime T: type) type {
    return struct {
        rw: ParkingRwLock = .{},
        data: T,

        const Self = @This();

        pub fn init(val: T) Self {
            return .{ .data = val };
        }

        // NOTE: read()/write() panic on lock errors (Deadlock/LockTimeout)
        // because CLEAR's @shared:writeLocked WITH-block codegen emits these
        // without `try`. For explicit error handling, call self.rw.lock() /
        // self.rw.lockShared() directly, which return LockError!void.
        //
        // This preserves a stable guard-based API (compat.RwLocked mirror)
        // while keeping the lower-level parking-lot API fallible for code
        // that wants to recover from deadlocks.
        pub fn read(self: *Self) ReadGuard {
            self.rw.lockShared() catch |e| {
                std.debug.panic("ParkingRwLocked.read: {}", .{e});
            };
            return .{ .parent = self };
        }

        pub fn write(self: *Self) WriteGuard {
            self.rw.lock() catch |e| {
                std.debug.panic("ParkingRwLocked.write: {}", .{e});
            };
            return .{ .parent = self };
        }

        // Fallible variants for callers that want to recover from errors.
        pub fn readOrErr(self: *Self) LockError!ReadGuard {
            try self.rw.lockShared();
            return .{ .parent = self };
        }

        pub fn writeOrErr(self: *Self) LockError!WriteGuard {
            try self.rw.lock();
            return .{ .parent = self };
        }

        // FSM Phase B2-WITH (rwlock) — non-yielding acquire variants.
        // Same protocol as ParkingMutex.tryLockForFsm: returns Acquired
        // on success, Registered if the FSM was queued (caller yields
        // WaitForLock), or Error on safety violation. Pair with
        // unlock()/unlockShared() once the CS finishes.
        pub fn tryWriteLockForFsm(
            self: *Self,
            fsm_task: *fp.FsmTask,
            waiter: *qs.WaiterNode,
            sched: *fp.Scheduler,
        ) FsmLockResultTop {
            return self.rw.tryWriteLockForFsm(fsm_task, waiter, sched);
        }

        pub fn tryReadLockForFsm(
            self: *Self,
            fsm_task: *fp.FsmTask,
            waiter: *qs.WaiterNode,
            sched: *fp.Scheduler,
        ) FsmLockResultTop {
            return self.rw.tryReadLockForFsm(fsm_task, waiter, sched);
        }

        pub fn unlock(self: *Self) void {
            self.rw.unlock();
        }

        pub fn unlockShared(self: *Self) void {
            self.rw.unlockShared();
        }

        pub const ReadGuard = struct {
            parent: *Self,

            pub fn get(self: *ReadGuard) *const T {
                return &self.parent.data;
            }

            pub fn release(self: *ReadGuard) void {
                self.parent.rw.unlockShared();
            }
        };

        pub const WriteGuard = struct {
            parent: *Self,

            pub fn get(self: *WriteGuard) *T {
                return &self.parent.data;
            }

            pub fn getConst(self: *WriteGuard) *const T {
                return &self.parent.data;
            }

            pub fn release(self: *WriteGuard) void {
                self.parent.rw.unlock();
            }
        };
    };
}
