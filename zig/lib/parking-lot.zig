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
// ParkingRwLock — fair readers-writer lock
//
// State (protected by `spin`):
//   readers > 0        N readers hold the lock
//   write_locked       exclusive writer holds the lock
//   (neither)          unlocked
//
// Fairness: a single FIFO queue of waiters. wakeNext drains from the head:
//   - head is a Writer and readers == 0  -> grant write, stop.
//   - head is a Reader                    -> grant read, continue draining
//     contiguous readers until the first Writer (which stays queued).
// New arrivals queue unconditionally if the queue is non-empty -- this
// prevents both writer starvation (no reader bypasses a queued writer)
// and reader starvation (no writer stream bypasses queued readers).
//
// Non-fiber callers (tests, startup, off-fiber embedding) spin briefly
// then park on `gen` via the futex; every state-changing op wakes one.
// ─────────────────────────────────────────────────────────────────────────────
pub const ParkingRwLock = struct {
    readers: i32 = 0,
    write_locked: bool = false,
    // Spinlock protecting the state fields above and the waiter list.
    spin: Atomic(u32) = Atomic(u32).init(0),
    // Unified FIFO waiter queue. Each node carries its kind (Read|Write).
    waiters: WaiterList = .{},
    write_owner: std.atomic.Value(?*Task) = std.atomic.Value(?*Task).init(null),
    // Futex counter for non-fiber waiters. Bumped on every state change
    // that could unblock a waiter (unlock, unlockShared when readers==0,
    // and inside wakeNext's reader drain). Non-fiber waiters call
    // `gen.wait(last_seen, null)` to sleep until a change occurs.
    gen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn spinAcquire(self: *ParkingRwLock) void {
        while (self.spin.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn spinRelease(self: *ParkingRwLock) void {
        self.spin.store(0, .release);
    }

    // Bump the futex generation and wake any non-fiber waiter. Called from
    // unlock paths; safe to call with the spinlock held.
    fn signalGen(self: *ParkingRwLock) void {
        _ = self.gen.fetchAdd(1, .release);
        Futex.wake(&self.gen, 1);
    }

    // Exclusive (write) lock
    pub fn lock(self: *ParkingRwLock) LockError!void {
        const sched_opt = getScheduler();

        if (sched_opt == null) {
            // Non-fiber: short spin, then park on futex.
            var spins: u32 = 0;
            while (true) {
                self.spinAcquire();
                // Fair: a non-fiber writer bypasses the waiter queue (we have
                // no WaiterNode to park on from off-fiber). This is rare path
                // usage (bootstrap, tests); correctness-over-fairness is fine.
                if (!self.write_locked and self.readers == 0) {
                    self.write_locked = true;
                    self.spinRelease();
                    return;
                }
                const snapshot = self.gen.load(.acquire);
                self.spinRelease();
                if (spins < SPIN_BUDGET) {
                    std.atomic.spinLoopHint();
                    spins += 1;
                } else {
                    Futex.wait(&self.gen, snapshot);
                    spins = 0;
                }
            }
        }

        const sched = sched_opt.?;
        const task = sched.current_task.?;

        self.spinAcquire();
        // Fast path: only if lock is fully unheld and no one is queued.
        if (!self.write_locked and self.readers == 0 and self.waiters.isEmpty()) {
            self.write_locked = true;
            self.write_owner.store(task, .release);
            self.spinRelease();
            return;
        }

        // Must wait. Detect cycle before parking (write lock has a single owner).
        const current_write_owner = self.write_owner.load(.acquire);
        self.spinRelease();
        try detectCycle(task, current_write_owner, self);
        self.spinAcquire();

        var node = WaiterNode{ .task = task, .sched_ptr = sched, .kind = .Write };
        self.waiters.push(&node);
        task.waiting_for_lock.store(self, .release);
        task.waiting_for_lock_list = &self.waiters;
        task.lock_waiter_node = &node;
        task.waiting_for_lock_owner = current_write_owner;
        task.status.store(.Blocked, .release);
        self.spinRelease();

        sched.registerLockWaiter(task);
        task.base.yield();

        task.waiting_for_lock.store(null, .release);
        task.waiting_for_lock_list = null;
        task.lock_waiter_node = null;
        task.waiting_for_lock_owner = null;

        if (task.lock_timed_out) {
            task.lock_timed_out = false;
            if (self.write_locked and self.write_owner.load(.acquire) == task) return;
            std.debug.print("LOCK TIMEOUT: fiber {*} waited for write lock {*}\n", .{ task, self });
            return error.LockTimeout;
        }

        self.write_owner.store(task, .release);
    }

    pub fn unlock(self: *ParkingRwLock) void {
        self.spinAcquire();
        self.write_locked = false;
        self.write_owner.store(null, .release);
        self.wakeNext();
        self.spinRelease();
        self.signalGen();
    }

    // Shared (read) lock
    pub fn lockShared(self: *ParkingRwLock) LockError!void {
        const sched_opt = getScheduler();

        if (sched_opt == null) {
            var spins: u32 = 0;
            while (true) {
                self.spinAcquire();
                // Fair: a new reader joins only if nobody is queued, so we
                // cannot bypass a waiting writer.
                if (!self.write_locked and self.waiters.isEmpty()) {
                    self.readers += 1;
                    self.spinRelease();
                    return;
                }
                const snapshot = self.gen.load(.acquire);
                self.spinRelease();
                if (spins < SPIN_BUDGET) {
                    std.atomic.spinLoopHint();
                    spins += 1;
                } else {
                    Futex.wait(&self.gen, snapshot);
                    spins = 0;
                }
            }
        }

        const sched = sched_opt.?;
        const task = sched.current_task.?;

        self.spinAcquire();
        // Fair: if anyone is queued ahead of us, park -- don't leapfrog.
        if (!self.write_locked and self.waiters.isEmpty()) {
            self.readers += 1;
            self.spinRelease();
            return;
        }

        var node = WaiterNode{ .task = task, .sched_ptr = sched, .kind = .Read };
        self.waiters.push(&node);
        task.waiting_for_lock.store(self, .release);
        task.waiting_for_lock_list = &self.waiters;
        task.lock_waiter_node = &node;
        // waiting_for_lock_owner stays null: read locks have no single owner.
        task.status.store(.Blocked, .release);
        self.spinRelease();

        sched.registerLockWaiter(task);
        task.base.yield();

        task.waiting_for_lock.store(null, .release);
        task.waiting_for_lock_list = null;
        task.lock_waiter_node = null;

        if (task.lock_timed_out) {
            task.lock_timed_out = false;
            self.spinAcquire();
            const held = !self.write_locked;
            self.spinRelease();
            if (held) return;
            std.debug.print("LOCK TIMEOUT: fiber {*} waited for read lock {*}\n", .{ task, self });
            return error.LockTimeout;
        }
        // Ownership (reader slot) was already incremented for us by wakeNext().
    }

    pub fn unlockShared(self: *ParkingRwLock) void {
        self.spinAcquire();
        self.readers -= 1;
        if (self.readers == 0) self.wakeNext();
        self.spinRelease();
        self.signalGen();
    }

    // Wake the next waiter(s) in FIFO order (call with spinlock held).
    // Must be called only when the lock is in a grantable state:
    //   - From unlock(): write_locked == false (just cleared), readers == 0.
    //   - From unlockShared(): readers just dropped to 0, write_locked == false.
    //
    // Drain rule: peek at head.
    //   - Head is Writer and readers == 0  -> grant write, stop.
    //   - Head is Reader                    -> grant read, loop for next.
    //   - Stop on first Writer after grants if any reader(s) remain held
    //     (read batch has concurrency; writer must wait for the batch to
    //     drain before it can acquire exclusive).
    fn wakeNext(self: *ParkingRwLock) void {
        while (self.waiters.peek()) |head| {
            switch (head.kind) {
                .Write => {
                    // Writer can only acquire when no readers hold the lock.
                    // If we've already granted reads in this loop iteration,
                    // readers > 0, and we stop.
                    if (self.readers > 0) return;
                    const w = self.waiters.pop().?;
                    self.write_locked = true;
                    self.write_owner.store(w.task, .release);
                    w.task.waiting_for_lock_owner = null;
                    w.task.waiting_for_lock_list = null;
                    w.task.lock_waiter_node = null;
                    w.task.waiting_for_lock.store(null, .release);
                    const sched: *fp.Scheduler = @ptrCast(@alignCast(w.sched_ptr));
                    sched.submitResume(w.task);
                    return;
                },
                .Read => {
                    const r = self.waiters.pop().?;
                    self.readers += 1;
                    r.task.waiting_for_lock_list = null;
                    r.task.lock_waiter_node = null;
                    r.task.waiting_for_lock.store(null, .release);
                    const sched: *fp.Scheduler = @ptrCast(@alignCast(r.sched_ptr));
                    sched.submitResume(r.task);
                    // Keep draining: next head might be another reader.
                },
            }
        }
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
