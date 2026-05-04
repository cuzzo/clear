// fsm-lock-safety-test.zig — Deadlock protection parity for FSM locks.
//
//   S1. Re-entrancy: FSM acquiring same mutex twice → lock_error.Deadlock.
//   S2. Pure-FSM cycle: A holds L1, B holds L2 + waits L1, A tries L2 →
//       lock_error.LockCycle via detectCycleFsm chain walk.
//   S3. Timeout: FSM parked on a never-released lock → lock_error.LockTimeout
//       after lock_timeout_ms via scanFsmLockWaiters.

const std = @import("std");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const qs = @import("queues.zig");
const ebr = @import("../lib/ebr.zig");
const fsm = @import("fsm.zig");
const pl = @import("../lib/parking-lot.zig");
const compat = @import("../lib/compat.zig");

const alloc = std.testing.allocator;

fn busySleepMs(ms: i64) void {
    const until = compat.milliTimestamp() + ms;
    while (compat.milliTimestamp() < until) {}
}

// ---- S1: re-entrancy -------------------------------------------------------

const Reentrant = struct {
    task: *fsm.FsmTask,
    mutex: *pl.ParkingMutex,
    sched: *fp.Scheduler,
    waiter1: qs.WaiterNode = undefined,
    waiter2: qs.WaiterNode = undefined,
    got_deadlock: bool = false,

    fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *Reentrant = @ptrCast(@alignCast(t.ctx.?));
        const r1 = self.mutex.tryLockForFsm(self.task, &self.waiter1, self.sched);
        if (r1 != .Acquired) return .{ .Done = {} };
        const r2 = self.mutex.tryLockForFsm(self.task, &self.waiter2, self.sched);
        if (r2 == .Error and self.task.lock_error == .Deadlock) {
            self.got_deadlock = true;
        }
        self.mutex.unlock();
        return .{ .Done = {} };
    }
};

test "FSM safety: re-entrant acquire returns lock_error.Deadlock" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &ebr_ctx, &pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.active_scheduler = undefined;

    var mutex: pl.ParkingMutex = .{};
    var s = Reentrant{ .task = undefined, .mutex = &mutex, .sched = &sched };
    s.task = try sched.allocFsmTask(&Reentrant.doResume);
    s.task.ctx = &s;
    sched.enqueueFsm(s.task);
    sched.drainFsmQueue();

    try std.testing.expect(s.got_deadlock);
    try std.testing.expect(mutex.tryLock());
    mutex.unlock();
}

// ---- S2: pure-FSM cycle ----------------------------------------------------

const CycleA = struct {
    task: *fsm.FsmTask,
    l1: *pl.ParkingMutex,
    l2: *pl.ParkingMutex,
    other_parked: *std.atomic.Value(bool),
    sched: *fp.Scheduler,
    waiter1: qs.WaiterNode = undefined,
    waiter2: qs.WaiterNode = undefined,
    step: u8 = 0,
    got_error: bool = false,

    fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *CycleA = @ptrCast(@alignCast(t.ctx.?));
        switch (self.step) {
            0 => {
                if (self.l1.tryLockForFsm(self.task, &self.waiter1, self.sched) != .Acquired)
                    return .{ .Done = {} };
                self.step = 1;
                return .{ .Yielded = {} };
            },
            1 => {
                if (!self.other_parked.load(.acquire)) return .{ .Yielded = {} };
                const r = self.l2.tryLockForFsm(self.task, &self.waiter2, self.sched);
                if (r == .Error and
                    (self.task.lock_error == .LockCycle or self.task.lock_error == .Deadlock))
                {
                    self.got_error = true;
                }
                self.l1.unlock();
                return .{ .Done = {} };
            },
            else => unreachable,
        }
    }
};

const CycleB = struct {
    task: *fsm.FsmTask,
    l1: *pl.ParkingMutex,
    l2: *pl.ParkingMutex,
    parked: *std.atomic.Value(bool),
    sched: *fp.Scheduler,
    waiter1: qs.WaiterNode = undefined,
    waiter2: qs.WaiterNode = undefined,
    step: u8 = 0,

    fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *CycleB = @ptrCast(@alignCast(t.ctx.?));
        switch (self.step) {
            0 => {
                if (self.l2.tryLockForFsm(self.task, &self.waiter2, self.sched) != .Acquired)
                    return .{ .Done = {} };
                self.parked.store(true, .release);
                self.step = 1;
                const r = self.l1.tryLockForFsm(self.task, &self.waiter1, self.sched);
                return switch (r) {
                    .Registered => .{ .WaitForLock = {} },
                    .Acquired => continueB(self),
                    .Error => .{ .Done = {} },
                };
            },
            1 => return continueB(self),
            else => unreachable,
        }
    }
    fn continueB(self: *CycleB) fsm.YieldReason {
        self.l1.unlock();
        self.l2.unlock();
        return .{ .Done = {} };
    }
};

test "FSM safety: pure-FSM cycle A->L2->B->L1->A detected" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &ebr_ctx, &pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.active_scheduler = undefined;

    var l1: pl.ParkingMutex = .{};
    var l2: pl.ParkingMutex = .{};
    var parked = std.atomic.Value(bool).init(false);

    var a = CycleA{ .task = undefined, .l1 = &l1, .l2 = &l2, .other_parked = &parked, .sched = &sched };
    a.task = try sched.allocFsmTask(&CycleA.doResume);
    a.task.ctx = &a;
    var b = CycleB{ .task = undefined, .l1 = &l1, .l2 = &l2, .parked = &parked, .sched = &sched };
    b.task = try sched.allocFsmTask(&CycleB.doResume);
    b.task.ctx = &b;

    // Drive A through step 0: acquires L1, yields.
    sched.enqueueFsm(a.task);
    sched.drainFsmQueue();
    // Enqueue B: acquires L2, parks on L1 (setting waiting_for_fsm_owner=A).
    sched.enqueueFsm(b.task);
    sched.drainFsmQueue();
    try std.testing.expectEqual(fsm.FsmStatus.Blocked, b.task.status);
    // Now drain: A resumes at step 1, tries L2 → detectCycleFsm sees
    // A → L2.fsm_owner(B) → B.waiting_for_fsm_owner(A) → cycle.
    var iters: u32 = 0;
    while (sched.fsm_ready_queue.len() > 0 and iters < 20) : (iters += 1) {
        sched.drainFsmQueue();
    }
    try std.testing.expect(a.got_error);
}

// ---- S3: timeout -----------------------------------------------------------

const Timeout = struct {
    task: *fsm.FsmTask,
    mutex: *pl.ParkingMutex,
    sched: *fp.Scheduler,
    waiter: qs.WaiterNode = undefined,
    step: u8 = 0,
    got_timeout: bool = false,

    fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *Timeout = @ptrCast(@alignCast(t.ctx.?));
        switch (self.step) {
            0 => {
                self.step = 1;
                const r = self.mutex.tryLockForFsm(self.task, &self.waiter, self.sched);
                return switch (r) {
                    .Registered => .{ .WaitForLock = {} },
                    .Acquired => .{ .Done = {} },
                    .Error => .{ .Done = {} },
                };
            },
            1 => {
                if (self.task.lock_error == .LockTimeout) self.got_timeout = true;
                return .{ .Done = {} };
            },
            else => unreachable,
        }
    }
};

test "FSM safety: lock wait timeout surfaces lock_error.LockTimeout" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &ebr_ctx, &pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.active_scheduler = undefined;
    sched.lock_timeout_ms = 50;

    var mutex: pl.ParkingMutex = .{};
    try std.testing.expect(mutex.tryLock());

    var s = Timeout{ .task = undefined, .mutex = &mutex, .sched = &sched };
    s.task = try sched.allocFsmTask(&Timeout.doResume);
    s.task.ctx = &s;
    sched.enqueueFsm(s.task);
    sched.drainFsmQueue();
    try std.testing.expectEqual(fsm.FsmStatus.Blocked, s.task.status);

    busySleepMs(100);
    sched.scanFsmLockWaitersPub();

    try std.testing.expectEqual(fsm.FsmStatus.Ready, s.task.status);
    try std.testing.expectEqual(fsm.FsmLockError.LockTimeout, s.task.lock_error);

    sched.drainFsmQueue();
    try std.testing.expect(s.got_timeout);
    mutex.unlock();
}
