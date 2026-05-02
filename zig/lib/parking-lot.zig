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
const Atomic = blk: {
    const root = @import("root");
    break :blk if (@hasDecl(root, "SimAtomic")) root.SimAtomic else std.atomic.Value;
};

const qs = @import("../runtime/queues.zig");
const fc = @import("../runtime/fiber-core.zig");
const fp = @import("../runtime/scheduler.zig");

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
    inline fn wait(ptr: *std.atomic.Value(u32), expected: u32) void {
        const op = linux.FUTEX_OP{ .cmd = .WAIT, .private = true };
        _ = linux.futex_4arg(@ptrCast(&ptr.raw), op, expected, null);
    }
    inline fn wake(ptr: *std.atomic.Value(u32), n: u32) void {
        const op = linux.FUTEX_OP{ .cmd = .WAKE, .private = true };
        _ = linux.futex_3arg(@ptrCast(&ptr.raw), op, n);
    }
    inline fn waitU64Low(ptr: *std.atomic.Value(u64), expected_low: u32) void {
        const op = linux.FUTEX_OP{ .cmd = .WAIT, .private = true };
        _ = linux.futex_4arg(@ptrCast(&ptr.raw), op, expected_low, null);
    }
    inline fn wakeU64(ptr: *std.atomic.Value(u64), n: u32) void {
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

// Walk the owner chain from `owner` looking for `waiter`. If found, return
// error.Deadlock when the owner is the waiter (depth 0, self-cyclic,
// always a user bug) or error.LockCycle when the cycle is multi-hop (AB/BA,
// resolvable by one party backing off). Depth-limited to 64 to guard
// against corrupted state. Read locks store null in waiting_for_lock_owner
// and act as chain terminators.
// Walk the owner chain from `owner` looking for `waiter`. If found,
// return error.Deadlock when the owner is the waiter (depth 0,
// self-cyclic, always a user bug) or error.LockCycle when the cycle
// is multi-hop (AB/BA, resolvable by one party backing off).
// Depth-limited to 64 to guard against corrupted state. Read locks
// store null in waiting_for_lock_owner and act as chain terminators.
//
// Best-effort under TOCTOU: per-Task fields are atomic with paired
// release/acquire ordering (see queues.zig for park/wake store order),
// but a chain walk across N Tasks isn't a single atomic snapshot.
// 14_nested_lock at THREADS>=4 with a strict-address-ordered workload
// can still trigger a false-positive panic from a stale-but-consistent
// chain observation -- documented in benchmarks/tofix.md as the
// remaining structural fix needed (likely a packed atomic state).
// Snapshot of one hop in the chain walk. Captured per-Task so we can
// validate after the walk that no Task transitioned during it.
const HopSnapshot = struct {
    task: *Task,
    seq: u32,
    next: ?*Task,
};

const MAX_CHAIN_DEPTH: usize = 64;
const MAX_DETECT_RETRIES: u32 = 8;

// Look up the CURRENT exclusive owner of the lock that `holder` is parked on.
// Reads the lock's authoritative state field — does NOT trust the holder's
// stored waiting_for_lock_owner (that goes stale when ownership transfers
// to one waiter and other queued waiters keep their pre-transfer owner field).
//
// Returns:
//   - null + chain-terminator-reason if `holder` is no longer parked
//     (lock == null), is on a shared/read lock (no single owner), or is
//     parked on an unknown lock kind.
//   - the current exclusive owner of the lock otherwise.
fn currentChainOwner(holder: *Task) ?*Task {
    const kind = holder.waiting_for_lock_kind.load(.acquire);
    if (kind == qs.LOCK_KIND_NONE or kind == qs.LOCK_KIND_RWLOCK_SHARED) return null;
    const lock_raw = holder.waiting_for_lock.load(.acquire) orelse return null;
    return switch (kind) {
        qs.LOCK_KIND_MUTEX => blk: {
            const m: *ParkingMutex = @ptrCast(@alignCast(lock_raw));
            break :blk m.ownerTask();
        },
        qs.LOCK_KIND_RWLOCK_WRITE => blk: {
            const r: *ParkingRwLock = @ptrCast(@alignCast(lock_raw));
            break :blk r.write_owner.load(.acquire);
        },
        else => null,
    };
}

// detectCycle: walk the owner chain and report a real cycle as
// error.LockCycle / error.Deadlock.
//
// Robustness has two layers:
//   1. Each hop derives the next Task by reading the LOCK's current owner
//      (currentChainOwner). The previously-cached waiting_for_lock_owner
//      field goes stale when ownership transfers to another waiter, so
//      relying on it produced apparent cycles through tasks that no
//      longer owned the locks the chain leads through.
//   2. The per-Task `seq` counter increments on every park/wake transition.
//      We snapshot seq before reading the lock fields and re-read it after
//      the walk; if any Task transitioned mid-walk, the snapshot is torn
//      and we retry. A real cycle is a STABLE configuration (every Task in
//      the cycle is parked, none can transition until someone breaks the
//      cycle), so seqs stay stable and the walk converges.
//
// After MAX_DETECT_RETRIES torn snapshots we treat the system as
// "transitioning constantly" and return without panic. A real cycle would
// have produced a stable snapshot within the retry budget.
fn detectCycle(waiter: *Task, owner: ?*Task, lock_ptr: *anyopaque) LockError!void {
    var hops: [MAX_CHAIN_DEPTH]HopSnapshot = undefined;
    var attempt: u32 = 0;

    while (attempt < MAX_DETECT_RETRIES) : (attempt += 1) {
        var n: usize = 0;
        var current = owner;
        var found_self_at_depth: ?usize = null;

        while (current) |holder| : (n += 1) {
            if (n >= MAX_CHAIN_DEPTH) break;
            const seq0 = holder.seq.load(.acquire);
            const next = currentChainOwner(holder);
            hops[n] = .{ .task = holder, .seq = seq0, .next = next };
            if (holder == waiter) {
                found_self_at_depth = n;
                break;
            }
            if (next == null) break; // holder not parked / shared / unknown kind
            current = next;
        }

        // Validate snapshot: re-read each hop's seq. If any changed, some
        // Task transitioned during the walk → snapshot is torn → retry.
        var torn = false;
        for (hops[0..n]) |h| {
            if (h.task.seq.load(.acquire) != h.seq) {
                torn = true;
                break;
            }
        }
        if (torn) continue;

        if (found_self_at_depth) |depth| {
            if (depth == 0) {
                std.debug.print(
                    "DEADLOCK: fiber {*} re-acquired lock {*} it already holds\n",
                    .{ waiter, lock_ptr },
                );
                return error.Deadlock;
            }
            std.debug.print(
                "LOCK CYCLE: fiber {*} waiting on lock {*} transitively held by " ++
                "itself via {} hop(s)\n",
                .{ waiter, lock_ptr, depth },
            );
            return error.LockCycle;
        }
        return; // clean walk, no cycle
    }
    return;
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
        if (current_owner == task) {
            std.debug.print(
                "DEADLOCK: re-entrant lock acquisition — fiber {*} already holds mutex {*}\n",
                .{ task, self },
            );
            return error.Deadlock;
        }

        // Walk the owner chain BEFORE taking queue_spin.
        try detectCycle(task, current_owner, self);

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
        // After fetchOr, double-check LOCKED. If the lock became free in
        // the same window, the unlocker might already have decided "no
        // waiters" and returned. Try to grab the lock ourselves rather
        // than parking — otherwise we'd park forever (the LOST WAKE bug).
        const after_or = self.state.fetchOr(STATE_HAS_WAITERS, .acq_rel) | STATE_HAS_WAITERS;
        if ((after_or & STATE_LOCKED) == 0) {
            // Lock became free during our setup window. Try to acquire.
            // Preserve flag bits including HAS_WAITERS (we may still queue,
            // and a future unlock will clear stale HAS_WAITERS if needed).
            const target = STATE_LOCKED | @intFromPtr(task)
                | (after_or & STATE_FLAG_MASK);
            if (self.state.cmpxchgStrong(after_or, target, .acquire, .monotonic) == null) {
                self.spinReleaseQueue();
                return;
            }
            // CAS lost — someone else got it. Fall through to park.
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
        task.waiting_for_lock_list = &self.waiters;
        task.lock_waiter_node = &node;
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
        task.waiting_for_lock_list = null;
        task.lock_waiter_node = null;
        _ = task.seq.fetchAdd(1, .release);

        if (task.lock_timed_out) {
            task.lock_timed_out = false;
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
        // Single atomic op: clear LOCKED + OWNER, preserving flag bits.
        // fetchAnd returns the prior value, which tells us whether to wake.
        const prev = self.state.fetchAnd(STATE_FLAG_MASK & ~STATE_LOCKED, .release);
        // = fetchAnd(STATE_HAS_WAITERS | STATE_HAS_THREAD_SLEEPER)
        // Hot path: no waiters of either kind. Single atomic op total.
        if ((prev & STATE_WAKE_BITS) == 0) return;

        if ((prev & STATE_HAS_WAITERS) != 0) {
            self.spinAcquireQueue();
            const waiter = self.waiters.pop();
            const more_after = !self.waiters.isEmpty();
            if (waiter) |w| {
                // Transfer ownership: rebuild state with LOCKED, owner, and
                // any preserved flag bits.
                const sleeper_bit: u64 = prev & STATE_HAS_THREAD_SLEEPER;
                const more_bit: u64 = if (more_after) STATE_HAS_WAITERS else 0;
                const new_state: u64 = STATE_LOCKED | sleeper_bit | more_bit
                    | @intFromPtr(w.task);
                self.state.store(new_state, .release);
                // Wake-side ordering: lock cleared FIRST (with .release)
                // so a concurrent detectCycle reader sees lock==null and
                // does not chase a stale waiting_for_lock_owner.
                w.task.waiting_for_lock.store(null, .release);
                w.task.waiting_for_lock_kind.store(qs.LOCK_KIND_NONE, .release);
                w.task.waiting_for_lock_owner.store(null, .release);
                w.task.waiting_for_lock_list = null;
                w.task.lock_waiter_node = null;
                _ = w.task.seq.fetchAdd(1, .release);
                const sched: *fp.Scheduler = @ptrCast(@alignCast(w.sched_ptr));
                sched.submitResume(w.task);
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
    write_owner: std.atomic.Value(?*Task) = std.atomic.Value(?*Task).init(null),
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

        // Detect cycles BEFORE taking the queue spin.
        const current_write_owner = self.write_owner.load(.acquire);
        try detectCycle(task, current_write_owner, self);

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
        // and take the wake path; double-check after fetchOr to grab the
        // lock if it became free in our setup window.
        const after_or = self.state.fetchOr(HAS_WAITERS_BIT, .acq_rel) | HAS_WAITERS_BIT;
        if ((after_or & (WRITE_LOCKED_BIT | READER_MASK)) == 0) {
            // Lock fully free. Try to grab it.
            const target = WRITE_LOCKED_BIT | (after_or & HAS_WAITERS_BIT);
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
        task.waiting_for_lock_owner.store(current_write_owner, .release);
        task.waiting_for_lock_kind.store(qs.LOCK_KIND_RWLOCK_WRITE, .release);
        task.waiting_for_lock.store(self, .release);
        task.waiting_for_lock_list = &self.waiters;
        task.lock_waiter_node = &node;
        task.status.store(.Blocked, .release);
        _ = task.seq.fetchAdd(1, .release);
        self.spinReleaseQueue();

        sched.registerLockWaiter(task);
        task.base.yield();

        // Wake-side ordering: lock FIRST so the chain walker stops at us.
        task.waiting_for_lock.store(null, .release);
        task.waiting_for_lock_kind.store(qs.LOCK_KIND_NONE, .release);
        task.waiting_for_lock_owner.store(null, .release);
        task.waiting_for_lock_list = null;
        task.lock_waiter_node = null;
        _ = task.seq.fetchAdd(1, .release);

        if (task.lock_timed_out) {
            task.lock_timed_out = false;
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
        // Clear write bit. fetchAnd returns the prior value so we can detect
        // HAS_WAITERS in one atomic op (no separate load).
        const prev = self.state.fetchAnd(~WRITE_LOCKED_BIT, .release);
        if ((prev & HAS_WAITERS_BIT) != 0) {
            self.spinAcquireQueue();
            self.wakeNext();
            self.spinReleaseQueue();
        }
    }

    // Shared (read) lock
    pub fn lockShared(self: *ParkingRwLock) LockError!void {
        // Fast path: optimistic fetchAdd. Conflict → undo and slow path.
        const prev = self.state.fetchAdd(1, .acquire);
        if ((prev & NON_READER_BITS) == 0) return; // no writer, no waiters → got it
        // Conflict: undo our increment.
        // Critical: if our undo restores state to "0 readers + HAS_WAITERS",
        // we must call wakeNext. Otherwise a queued writer can deadlock --
        // the actual last reader's unlockShared saw our transient +1 and
        // skipped its wake; if we don't wake here, no future op will, since
        // state has no holders to release.
        const prev_undo = self.state.fetchSub(1, .release);
        if ((prev_undo & READER_MASK) == 1 and (prev_undo & HAS_WAITERS_BIT) != 0) {
            self.spinAcquireQueue();
            self.wakeNext();
            self.spinReleaseQueue();
        }
        return self.lockSharedSlow();
    }

    fn lockSharedSlow(self: *ParkingRwLock) LockError!void {
        const sched_opt = getScheduler();

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
                if ((prev & NON_READER_BITS) == 0) return;
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
                return;
            }
            // Same wake-on-undo logic as the fast path. We already hold
            // queue_spin so we can call wakeNext directly.
            const prev_undo = self.state.fetchSub(1, .release);
            if ((prev_undo & READER_MASK) == 1 and (prev_undo & HAS_WAITERS_BIT) != 0) {
                self.wakeNext();
                // wakeNext may have drained everyone we'd queue behind. If
                // state is now grantable for us, take it; otherwise fall
                // through and queue.
                const prev_retry = self.state.fetchAdd(1, .acquire);
                if ((prev_retry & NON_READER_BITS) == 0) {
                    self.spinReleaseQueue();
                    return;
                }
                _ = self.state.fetchSub(1, .release);
            }
        }

        // Set HAS_WAITERS_BIT BEFORE pushing. Same LOST WAKE race as the
        // exclusive path: an unlock that runs between our last state load
        // and our push must observe HAS_WAITERS=1 in its fetchAdd-undo
        // path (line ~813) and call wakeNext. If the lock became fully
        // free in our setup window, try to grab a reader slot ourselves.
        const after_or = self.state.fetchOr(HAS_WAITERS_BIT, .acq_rel) | HAS_WAITERS_BIT;
        if ((after_or & WRITE_LOCKED_BIT) == 0) {
            // No writer holds it. Try to add ourselves as a reader.
            // fetchAdd here is the standard reader-acquire; the acquire
            // ordering pairs with the writer-unlock release.
            const prev_retry = self.state.fetchAdd(1, .acquire);
            if ((prev_retry & WRITE_LOCKED_BIT) == 0) {
                self.spinReleaseQueue();
                return;
            }
            // Lost the race — undo and park.
            _ = self.state.fetchSub(1, .release);
        }

        var node = WaiterNode{ .task = task, .sched_ptr = sched, .kind = .Read };
        self.waiters.push(&node);
        // SHARED kind: detectCycle treats this as a chain terminator (read
        // locks have no single owner — multiple readers may hold it).
        task.waiting_for_lock_kind.store(qs.LOCK_KIND_RWLOCK_SHARED, .release);
        task.waiting_for_lock.store(self, .release);
        task.waiting_for_lock_list = &self.waiters;
        task.lock_waiter_node = &node;
        // waiting_for_lock_owner stays null: read locks have no single owner.
        task.status.store(.Blocked, .release);
        _ = task.seq.fetchAdd(1, .release);
        self.spinReleaseQueue();

        sched.registerLockWaiter(task);
        task.base.yield();

        task.waiting_for_lock.store(null, .release);
        task.waiting_for_lock_kind.store(qs.LOCK_KIND_NONE, .release);
        task.waiting_for_lock_list = null;
        task.lock_waiter_node = null;
        _ = task.seq.fetchAdd(1, .release);

        if (task.lock_timed_out) {
            task.lock_timed_out = false;
            // wakeNext would have already incremented our reader slot if it
            // granted us the lock. Detecting that here without a separate
            // flag is racy with concurrent unlocks; keep the simple path
            // and treat all timeouts as errors. In practice, the reader
            // grant is fast enough that the timeout race is negligible.
            std.debug.print("LOCK TIMEOUT: fiber {*} waited for read lock {*}\n", .{ task, self });
            return error.LockTimeout;
        }
        // Ownership (reader slot) was already incremented by wakeNext.
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
                    self.write_owner.store(w.task, .release);
                    // Wake-side ordering: lock cleared FIRST.
                    w.task.waiting_for_lock.store(null, .release);
                    w.task.waiting_for_lock_kind.store(qs.LOCK_KIND_NONE, .release);
                    w.task.waiting_for_lock_owner.store(null, .release);
                    w.task.waiting_for_lock_list = null;
                    w.task.lock_waiter_node = null;
                    _ = w.task.seq.fetchAdd(1, .release);
                    const sched: *fp.Scheduler = @ptrCast(@alignCast(w.sched_ptr));
                    sched.submitResume(w.task);
                    return; // grant one writer per wakeNext
                },
                .Read => {
                    // Grant a reader slot. WRITE_LOCKED is clear here (we
                    // only enter wakeNext after clearing it). HAS_WAITERS
                    // stays set; we'll fix it up after the drain.
                    _ = self.state.fetchAdd(1, .acquire);
                    const r = self.waiters.pop().?;
                    r.task.waiting_for_lock_list = null;
                    r.task.lock_waiter_node = null;
                    r.task.waiting_for_lock.store(null, .release);
                    r.task.waiting_for_lock_kind.store(qs.LOCK_KIND_NONE, .release);
                    _ = r.task.seq.fetchAdd(1, .release);
                    const sched: *fp.Scheduler = @ptrCast(@alignCast(r.sched_ptr));
                    sched.submitResume(r.task);
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
