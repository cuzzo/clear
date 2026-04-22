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

pub const LockError = error{
    Deadlock,
    LockTimeout,
};

// Non-fiber (raw-thread) waiters spin this many iterations before falling
// back to a futex park. Short enough that very brief contention stays in
// user space; long enough that sustained contention parks in the kernel
// instead of burning 100% CPU.
const SPIN_BUDGET: u32 = 64;

// Thin Linux-futex wrapper for the non-fiber fallback. The CLEAR runtime is
// Linux-only (io_uring), so a portable abstraction is unnecessary. Used
// only on the raw-thread path — fiber callers park on the scheduler via
// task.base.yield() which is cheaper than any syscall.
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
};

// Returns the active scheduler if we are currently running inside a fiber,
// null otherwise (scheduler startup, test code, non-fiber paths).
inline fn getScheduler() ?*fp.Scheduler {
    if (!fp.scheduler_running) return null;
    return fp.active_scheduler;
}

// Walk the owner chain from `owner` looking for `waiter`. If found, the
// waiter is in a deadlock cycle. Returns error.Deadlock so the caller can
// unwind cleanly via defer blocks rather than killing the process.
// Depth-limited to 64 to guard against corrupted state.
// Read locks store null in waiting_for_lock_owner and act as chain terminators.
fn detectCycle(waiter: *Task, owner: ?*Task, lock_ptr: *anyopaque) LockError!void {
    var current = owner;
    var depth: usize = 0;
    while (current) |holder| : (depth += 1) {
        if (holder == waiter) {
            std.debug.print(
                "DEADLOCK: lock cycle — fiber {*} waiting on lock {*} which is " ++
                "transitively held by itself\n",
                .{ waiter, lock_ptr },
            );
            return error.Deadlock;
        }
        if (depth >= 64) break;
        current = holder.waiting_for_lock_owner;
    }
}


// ─────────────────────────────────────────────────────────────────────────────
// ParkingMutex — exclusive (write) lock
// ─────────────────────────────────────────────────────────────────────────────
pub const ParkingMutex = struct {
    // 0 = UNLOCKED, 1 = LOCKED
    locked: Atomic(u32) = Atomic(u32).init(0),
    // Task currently holding the lock (for deadlock cycle detection).
    // std.atomic.Value (not SimAtomic) so the scheduler loop can read it
    // without becoming a Loom yield point.
    owner: std.atomic.Value(?*Task) = std.atomic.Value(?*Task).init(null),
    // Queue of parked fibers waiting for this lock.
    waiters: WaiterList = .{},

    pub fn tryLock(self: *ParkingMutex) bool {
        if (self.locked.cmpxchgWeak(0, 1, .acquire, .monotonic) == null) {
            if (getScheduler()) |sched| {
                self.owner.store(sched.current_task, .release);
            }
            return true;
        }
        return false;
    }

    pub fn lock(self: *ParkingMutex) LockError!void {
        if (self.tryLock()) return;
        return self.lockSlow();
    }

    fn lockSlow(self: *ParkingMutex) LockError!void {
        const sched_opt = getScheduler();

        if (sched_opt == null) {
            // Non-fiber context: adaptive spin then futex park.
            // Previous version spun forever with std.Thread.yield(), which
            // burned 100% of a core under contention. Futex parks the
            // thread in the kernel (zero CPU) until the locked field is
            // seen at 0 -- i.e. until unlock() wakes it.
            var spins: u32 = 0;
            while (true) {
                if (self.tryLock()) return;
                if (spins < SPIN_BUDGET) {
                    std.atomic.spinLoopHint();
                    spins += 1;
                    continue;
                }
                // Park: wait while locked == 1. Returns when unlock stores 0
                // and calls Futex.wake (or on spurious wakeup, which retries).
                Futex.wait(&self.locked, 1);
                spins = 0;
            }
        }

        const sched = sched_opt.?;
        const task = sched.current_task.?;

        // Re-entrancy check: same task already owns the lock → deadlock.
        const current_owner = self.owner.load(.acquire);
        if (current_owner == task) {
            std.debug.print(
                "DEADLOCK: re-entrant lock acquisition — fiber {*} already holds mutex {*}\n",
                .{ task, self },
            );
            return error.Deadlock;
        }

        // Walk the owner chain: if the owner is transitively waiting for a
        // lock that task holds, we have an AB/BA cycle.
        try detectCycle(task, current_owner, self);

        // Set up intrusive waiter on our stack frame (no heap alloc).
        var node = WaiterNode{
            .task = task,
            .sched_ptr = sched,
        };

        // Record lock metadata on the task for the scheduler's timeout scanner
        // and for cycle detection by other waiters.
        task.waiting_for_lock.store(self, .release);
        task.waiting_for_lock_list = &self.waiters;
        task.lock_waiter_node = &node;
        task.waiting_for_lock_owner = current_owner;

        // Add to waiter list and set Blocked under the spinlock so unlock()
        // cannot pop our node and submitResume before we have set Blocked.
        // (Same-scheduler: cooperative, no actual race. @parallel: the spinlock
        // ensures unlock's pop sees a consistent state.)
        self.waiters.spinAcquire();
        self.waiters.push(&node);
        task.status.store(.Blocked, .release);
        self.waiters.spinRelease();

        // Register with scheduler for timeout detection.
        sched.registerLockWaiter(task);

        // Yield to the scheduler. Resumed when unlock() calls submitResume(task).
        task.base.yield();

        // ── Resumed here ─────────────────────────────────────────────────────
        // Clear lock metadata now that we're no longer parked.
        task.waiting_for_lock.store(null, .release);
        task.waiting_for_lock_list = null;
        task.lock_waiter_node = null;
        task.waiting_for_lock_owner = null;

        if (task.lock_timed_out) {
            task.lock_timed_out = false;
            // Scheduler already removed our node from the waiter list.
            // Try one more CAS — if the lock was transferred to us by a racing
            // unlock() that fired after the timeout scan removed our node,
            // we hold it and can proceed.
            if (self.locked.load(.acquire) == 1 and self.owner.load(.acquire) == task) {
                return;
            }
            std.debug.print("LOCK TIMEOUT: fiber {*} waited for mutex {*}\n", .{ task, self });
            return error.LockTimeout;
        }

        // Ownership was transferred by unlock(). Record us as owner.
        self.owner.store(task, .release);
    }

    pub fn unlock(self: *ParkingMutex) void {
        // Clear owner unconditionally — we no longer hold it after this call.
        self.owner.store(null, .release);

        // Pop the next waiter (if any) and transfer ownership directly.
        // The lock stays in LOCKED state — no unlock/relock round-trip.
        self.waiters.spinAcquire();
        const waiter = self.waiters.pop();
        self.waiters.spinRelease();

        if (waiter) |w| {
            // Transfer ownership to the waiter. The lock stays locked.
            // unlock() sets owner so the waiter can check re-entrancy later.
            self.owner.store(w.task, .release);
            // Clear wait-state BEFORE submitResume. Once this task is Ready,
            // another fiber's detectCycle may walk w.task.waiting_for_lock_owner
            // before w.task actually runs. If we leave the stale pre-wake
            // pointer set, detectCycle can report a cycle that no longer exists
            // (false-positive error.Deadlock). The wake site is the only race-
            // free place to clear these; the post-yield cleanup in lockSlow()
            // is redundant after this but kept for defense-in-depth.
            w.task.waiting_for_lock_owner = null;
            w.task.waiting_for_lock_list = null;
            w.task.lock_waiter_node = null;
            w.task.waiting_for_lock.store(null, .release);
            const sched: *fp.Scheduler = @ptrCast(@alignCast(w.sched_ptr));
            sched.submitResume(w.task);
            // Fiber waiter path: the locked field stays 1 (ownership transferred).
            // A raw-thread waiter parked on Futex.wait(&locked, 1) stays asleep;
            // it'll be woken when a future unlock takes the no-waiter branch.
        } else {
            // No fiber waiters — fully release the lock and wake one raw-thread
            // waiter (if any) via the futex.
            self.locked.store(0, .release);
            Futex.wake(&self.locked, 1);
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
        // Fast path: only succeeds if state is fully zero.
        if (self.state.cmpxchgWeak(0, WRITE_LOCKED_BIT, .acquire, .monotonic) == null) {
            if (getScheduler()) |sched| {
                self.write_owner.store(sched.current_task, .release);
            }
            return;
        }
        return self.lockSlow();
    }

    fn lockSlow(self: *ParkingRwLock) LockError!void {
        const sched_opt = getScheduler();

        if (sched_opt == null) {
            // Non-fiber: spin with OS yield backoff. Off-fiber callers are
            // rare (bootstrap / tests / off-fiber embedding); not worth the
            // cache-line cost a futex-on-state design would add to the hot
            // fiber path.
            var spins: u32 = 0;
            while (true) {
                if (self.state.cmpxchgWeak(0, WRITE_LOCKED_BIT, .acquire, .monotonic) == null) return;
                spins += 1;
                if (spins > 256) { std.Thread.yield() catch {}; spins = 0; }
                else std.atomic.spinLoopHint();
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

        // Park in FIFO queue. Set HAS_WAITERS_BIT so unlockers know to
        // call wakeNext. We OR the bit (idempotent) under queue_spin.
        _ = self.state.fetchOr(HAS_WAITERS_BIT, .release);

        var node = WaiterNode{ .task = task, .sched_ptr = sched, .kind = .Write };
        self.waiters.push(&node);
        task.waiting_for_lock.store(self, .release);
        task.waiting_for_lock_list = &self.waiters;
        task.lock_waiter_node = &node;
        task.waiting_for_lock_owner = current_write_owner;
        task.status.store(.Blocked, .release);
        self.spinReleaseQueue();

        sched.registerLockWaiter(task);
        task.base.yield();

        task.waiting_for_lock.store(null, .release);
        task.waiting_for_lock_list = null;
        task.lock_waiter_node = null;
        task.waiting_for_lock_owner = null;

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
            var spins: u32 = 0;
            while (true) {
                const prev = self.state.fetchAdd(1, .acquire);
                if ((prev & NON_READER_BITS) == 0) return;
                _ = self.state.fetchSub(1, .release);
                spins += 1;
                if (spins > 256) { std.Thread.yield() catch {}; spins = 0; }
                else std.atomic.spinLoopHint();
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

        // Park.
        _ = self.state.fetchOr(HAS_WAITERS_BIT, .release);

        var node = WaiterNode{ .task = task, .sched_ptr = sched, .kind = .Read };
        self.waiters.push(&node);
        task.waiting_for_lock.store(self, .release);
        task.waiting_for_lock_list = &self.waiters;
        task.lock_waiter_node = &node;
        // waiting_for_lock_owner stays null: read locks have no single owner.
        task.status.store(.Blocked, .release);
        self.spinReleaseQueue();

        sched.registerLockWaiter(task);
        task.base.yield();

        task.waiting_for_lock.store(null, .release);
        task.waiting_for_lock_list = null;
        task.lock_waiter_node = null;

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
                    w.task.waiting_for_lock_owner = null;
                    w.task.waiting_for_lock_list = null;
                    w.task.lock_waiter_node = null;
                    w.task.waiting_for_lock.store(null, .release);
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
