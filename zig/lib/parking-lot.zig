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
//   - Deadlock detection: walk the owner chain before parking. Panic if a cycle
//     is found (re-entrant locking or AB/BA across @parallel) instead of hanging.
//   - Timeout: if a fiber waits more than LOCK_TIMEOUT_MS (30s), the scheduler
//     wakes it and it panics with a clear message instead of hanging forever.
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

// Returns the active scheduler if we are currently running inside a fiber,
// null otherwise (scheduler startup, test code, non-fiber paths).
inline fn getScheduler() ?*fp.Scheduler {
    if (!fp.scheduler_running) return null;
    return fp.active_scheduler;
}

// Walk the owner chain from `owner` looking for `waiter`. If found, the
// waiter is in a deadlock cycle. Depth-limited to 64 to guard against
// corrupted state. Read locks have no single owner, so they store null in
// waiting_for_lock_owner and act as chain terminators.
fn detectCycle(waiter: *Task, owner: ?*Task, lock_ptr: *anyopaque) void {
    var current = owner;
    var depth: usize = 0;
    while (current) |holder| : (depth += 1) {
        if (holder == waiter) {
            std.debug.print(
                "DEADLOCK: lock cycle — fiber {*} waiting on lock {*} which is " ++
                "transitively held by itself\n",
                .{ waiter, lock_ptr },
            );
            @panic("deadlock: lock cycle detected");
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

    pub fn lock(self: *ParkingMutex) void {
        if (self.tryLock()) return;
        self.lockSlow();
    }

    fn lockSlow(self: *ParkingMutex) void {
        const sched_opt = getScheduler();

        if (sched_opt == null) {
            // Non-fiber context: spin with OS yield backoff.
            var spins: u32 = 0;
            while (!self.tryLock()) {
                spins += 1;
                if (spins > 256) {
                    std.Thread.yield() catch {};
                    spins = 0;
                } else {
                    std.atomic.spinLoopHint();
                }
            }
            return;
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
            @panic("deadlock: re-entrant lock acquisition");
        }

        // Walk the owner chain: if the owner is transitively waiting for a
        // lock that task holds, we have an AB/BA cycle.
        detectCycle(task, current_owner, self);

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
                // Ownership was transferred; proceed normally.
                return;
            }
            std.debug.print(
                "LOCK TIMEOUT: fiber {*} waited >30s for mutex {*}\n",
                .{ task, self },
            );
            @panic("lock timeout: possible deadlock");
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
            const sched: *fp.Scheduler = @ptrCast(@alignCast(w.sched_ptr));
            sched.submitResume(w.task);
        } else {
            // No waiters — fully release the lock.
            self.locked.store(0, .release);
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// ParkingRwLock — readers-writer lock (write-preferring)
//
// State machine (protected by spin):
//   readers  > 0:  N readers hold the lock
//   readers == 0:  unlocked
//   write_locked:  exclusive writer holds the lock
//
// Write-preference: new readers are blocked when writers_waiting > 0.
// ─────────────────────────────────────────────────────────────────────────────
pub const ParkingRwLock = struct {
    readers: i32 = 0,
    write_locked: bool = false,
    writers_waiting: u32 = 0,
    // Spinlock protecting the state fields above and both waiter lists.
    spin: Atomic(u32) = Atomic(u32).init(0),
    write_waiters: WaiterList = .{},
    read_waiters: WaiterList = .{},
    write_owner: std.atomic.Value(?*Task) = std.atomic.Value(?*Task).init(null),

    fn spinAcquire(self: *ParkingRwLock) void {
        while (self.spin.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn spinRelease(self: *ParkingRwLock) void {
        self.spin.store(0, .release);
    }

    // Exclusive (write) lock
    pub fn lock(self: *ParkingRwLock) void {
        const sched_opt = getScheduler();

        if (sched_opt == null) {
            // Non-fiber: spin until we can write-lock.
            var spins: u32 = 0;
            while (true) {
                self.spinAcquire();
                if (!self.write_locked and self.readers == 0) {
                    self.write_locked = true;
                    self.spinRelease();
                    return;
                }
                self.spinRelease();
                spins += 1;
                if (spins > 256) { std.Thread.yield() catch {}; spins = 0; }
                else std.atomic.spinLoopHint();
            }
        }

        const sched = sched_opt.?;
        const task = sched.current_task.?;

        self.spinAcquire();
        if (!self.write_locked and self.readers == 0) {
            self.write_locked = true;
            self.write_owner.store(task, .release);
            self.spinRelease();
            return;
        }

        // Must wait. Detect cycle before parking (write lock has a single owner).
        const current_write_owner = self.write_owner.load(.acquire);
        detectCycle(task, current_write_owner, self);

        self.writers_waiting += 1;
        var node = WaiterNode{ .task = task, .sched_ptr = sched };
        self.write_waiters.push(&node);
        task.waiting_for_lock.store(self, .release);
        task.waiting_for_lock_list = &self.write_waiters;
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
            std.debug.print("LOCK TIMEOUT: fiber {*} waited >30s for write lock {*}\n", .{ task, self });
            @panic("lock timeout: possible deadlock");
        }

        self.write_owner.store(task, .release);
    }

    pub fn unlock(self: *ParkingRwLock) void {
        self.spinAcquire();
        self.write_locked = false;
        self.write_owner.store(null, .release);
        self.wakeNext();
        self.spinRelease();
    }

    // Shared (read) lock
    pub fn lockShared(self: *ParkingRwLock) void {
        const sched_opt = getScheduler();

        if (sched_opt == null) {
            var spins: u32 = 0;
            while (true) {
                self.spinAcquire();
                if (!self.write_locked and self.writers_waiting == 0) {
                    self.readers += 1;
                    self.spinRelease();
                    return;
                }
                self.spinRelease();
                spins += 1;
                if (spins > 256) { std.Thread.yield() catch {}; spins = 0; }
                else std.atomic.spinLoopHint();
            }
        }

        const sched = sched_opt.?;
        const task = sched.current_task.?;

        self.spinAcquire();
        // Write-preferring: block new readers if a writer is waiting or holds.
        if (!self.write_locked and self.writers_waiting == 0) {
            self.readers += 1;
            self.spinRelease();
            return;
        }

        var node = WaiterNode{ .task = task, .sched_ptr = sched };
        self.read_waiters.push(&node);
        task.waiting_for_lock.store(self, .release);
        task.waiting_for_lock_list = &self.read_waiters;
        task.lock_waiter_node = &node;
        task.status.store(.Blocked, .release);
        self.spinRelease();

        sched.registerLockWaiter(task);
        task.base.yield();

        task.waiting_for_lock.store(null, .release);
        task.waiting_for_lock_list = null;
        task.lock_waiter_node = null;

        if (task.lock_timed_out) {
            task.lock_timed_out = false;
            // Check if we were granted a read slot by unlock
            self.spinAcquire();
            const held = !self.write_locked;
            self.spinRelease();
            if (held) return; // ownership was transferred
            std.debug.print("LOCK TIMEOUT: fiber {*} waited >30s for read lock {*}\n", .{ task, self });
            @panic("lock timeout: possible deadlock");
        }
        // Ownership (reader slot) was already incremented for us by wakeNext().
    }

    pub fn unlockShared(self: *ParkingRwLock) void {
        self.spinAcquire();
        self.readers -= 1;
        if (self.readers == 0) self.wakeNext();
        self.spinRelease();
    }

    // Wake the highest-priority waiter (call while holding spinlock).
    // Writer-preference: wake a writer if one is waiting. Otherwise wake all
    // pending readers.
    fn wakeNext(self: *ParkingRwLock) void {
        if (self.write_waiters.head != null and !self.write_locked and self.readers == 0) {
            const w = self.write_waiters.pop().?;
            self.writers_waiting -= 1;
            self.write_locked = true;
            self.write_owner.store(w.task, .release);
            const sched: *fp.Scheduler = @ptrCast(@alignCast(w.sched_ptr));
            sched.submitResume(w.task);
            return;
        }
        // Wake all waiting readers (they can hold concurrently).
        if (!self.write_locked and self.writers_waiting == 0) {
            while (self.read_waiters.pop()) |r| {
                self.readers += 1;
                const sched: *fp.Scheduler = @ptrCast(@alignCast(r.sched_ptr));
                sched.submitResume(r.task);
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

        pub fn read(self: *Self) ReadGuard {
            self.rw.lockShared();
            return .{ .parent = self };
        }

        pub fn write(self: *Self) WriteGuard {
            self.rw.lock();
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
