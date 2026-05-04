// fsm-rwlock-test.zig — ParkingRwLock with FSM tasks. Mirrors the
// tests in fsm-lock-test.zig but for the shared/exclusive rwlock.
//
// Covers:
//   R1. Uncontended write acquire + release (fast path).
//   R2. Uncontended read acquire + multiple concurrent readers.
//   R3. Reader blocks while writer is parked (write-priority).
//   R4. FSM writer wakes FSM reader-queue on release.
//   R5. Mixed FSM + stackful contention on the same rwlock.
//   R6. Write re-entrancy returns lock_error.Deadlock.
//   R7. Write timeout wakes with lock_error.LockTimeout.

const std = @import("std");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const qs = @import("queues.zig");
const ebr = @import("../lib/ebr.zig");
const fsm = @import("fsm.zig");
const pl = @import("../lib/parking-lot.zig");
const compat = @import("../lib/compat.zig");
const rt_mod = @import("runtime.zig");
const CheatHeader = @import("runtime-header.zig");
const Runtime = rt_mod.Runtime;

const alloc = std.testing.allocator;

fn busySleepMs(ms: i64) void {
    const until = compat.milliTimestamp() + ms;
    while (compat.milliTimestamp() < until) {}
}

// ----- Fixtures -----------------------------------------------------------

const WriteFsm = struct {
    task: *fsm.FsmTask,
    rw: *pl.ParkingRwLock,
    counter: *u64,
    sched: *fp.Scheduler,
    waiter: qs.WaiterNode = undefined,
    step: u8 = 0,
    completed: bool = false,

    fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *WriteFsm = @ptrCast(@alignCast(t.ctx.?));
        switch (self.step) {
            0 => {
                self.step = 1;
                const r = self.rw.tryWriteLockForFsm(self.task, &self.waiter, self.sched);
                return switch (r) {
                    .Acquired => cs(self),
                    .Registered => .{ .WaitForLock = {} },
                    .Error => .{ .Done = {} },
                };
            },
            1 => return cs(self),
            else => unreachable,
        }
    }
    fn cs(self: *WriteFsm) fsm.YieldReason {
        self.counter.* += 1;
        self.rw.unlock();
        self.completed = true;
        return .{ .Done = {} };
    }
};

const ReadFsm = struct {
    task: *fsm.FsmTask,
    rw: *pl.ParkingRwLock,
    counter: *u64,
    sched: *fp.Scheduler,
    waiter: qs.WaiterNode = undefined,
    step: u8 = 0,
    completed: bool = false,

    fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *ReadFsm = @ptrCast(@alignCast(t.ctx.?));
        switch (self.step) {
            0 => {
                self.step = 1;
                const r = self.rw.tryReadLockForFsm(self.task, &self.waiter, self.sched);
                return switch (r) {
                    .Acquired => cs(self),
                    .Registered => .{ .WaitForLock = {} },
                    .Error => .{ .Done = {} },
                };
            },
            1 => return cs(self),
            else => unreachable,
        }
    }
    fn cs(self: *ReadFsm) fsm.YieldReason {
        self.counter.* += 1;
        self.rw.unlockShared();
        self.completed = true;
        return .{ .Done = {} };
    }
};

// ----- Tests --------------------------------------------------------------

test "R1: uncontended FSM write acquire/release" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &ebr_ctx, &pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.active_scheduler = undefined;

    var rw: pl.ParkingRwLock = .{};
    var counter: u64 = 0;
    var w = WriteFsm{ .task = undefined, .rw = &rw, .counter = &counter, .sched = &sched };
    w.task = try sched.allocFsmTask(&WriteFsm.doResume);
    w.task.ctx = &w;

    sched.enqueueFsm(w.task);
    sched.drainFsmQueue();

    try std.testing.expect(w.completed);
    try std.testing.expectEqual(@as(u64, 1), counter);
    // rwlock is released — try write lock succeeds immediately.
    try rw.lock();
    rw.unlock();
}

test "R2: multiple FSM readers hold concurrently" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &ebr_ctx, &pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.active_scheduler = undefined;

    var rw: pl.ParkingRwLock = .{};
    var counter: u64 = 0;
    const N = 8;
    const readers = try alloc.alloc(ReadFsm, N);
    defer alloc.free(readers);
    for (readers) |*r| {
        r.* = .{ .task = undefined, .rw = &rw, .counter = &counter, .sched = &sched };
        r.task = try sched.allocFsmTask(&ReadFsm.doResume);
        r.task.ctx = r;
        sched.enqueueFsm(r.task);
    }
    // All N readers should acquire on the fast path (no writer holds).
    sched.drainFsmQueue();
    try std.testing.expectEqual(@as(u64, N), counter);
    for (readers) |r| try std.testing.expect(r.completed);
    // Lock fully released.
    try rw.lock();
    rw.unlock();
}

test "R3: FSM writer blocks FSM readers; write release wakes all readers" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &ebr_ctx, &pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.active_scheduler = undefined;

    var rw: pl.ParkingRwLock = .{};
    var counter: u64 = 0;

    // Pre-acquire write lock from outside the scheduler.
    try rw.lock();

    const N = 4;
    const readers = try alloc.alloc(ReadFsm, N);
    defer alloc.free(readers);
    for (readers) |*r| {
        r.* = .{ .task = undefined, .rw = &rw, .counter = &counter, .sched = &sched };
        r.task = try sched.allocFsmTask(&ReadFsm.doResume);
        r.task.ctx = r;
        sched.enqueueFsm(r.task);
    }

    // First drain: all readers try to acquire, find WRITE_LOCKED, park.
    sched.drainFsmQueue();
    for (readers) |r| try std.testing.expectEqual(fsm.FsmStatus.Blocked, r.task.status);
    try std.testing.expectEqual(@as(u64, 0), counter);

    // Release the write lock. wakeNext drains all reader waiters in FIFO,
    // each gets submitFsmResume. scheduler_running must be true so the
    // wake path uses the same-scheduler fast path instead of the SPSC
    // ring (which wouldn't be drained by this single-threaded test).
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;
    rw.unlock();

    // Drain the woken readers — they CS and unlockShared each.
    var iters: u32 = 0;
    while (sched.fsm_ready_queue.len() > 0 and iters < 20) : (iters += 1) {
        sched.drainFsmQueue();
    }
    try std.testing.expectEqual(@as(u64, N), counter);
    for (readers) |r| try std.testing.expect(r.completed);
    // All readers released → writer can acquire.
    try rw.lock();
    rw.unlock();
}

test "R5: mixed FSM + stackful write contention" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var rt = try Runtime.init(alloc, 256 * 1024, &ebr_ctx);
    defer rt.deinit();
    rt.wireAllocator();
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &ebr_ctx, &pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(alloc);
    }
    fp.active_scheduler = &sched;

    var rw: pl.ParkingRwLock = .{};
    var counter: u64 = 0;

    const StackfulCtx = struct { rw: *pl.ParkingRwLock, counter: *u64 };
    const stackfulBody = struct {
        fn go(_: *anyopaque, ctx_op: ?*anyopaque) anyerror!void {
            const c: *StackfulCtx = @ptrCast(@alignCast(ctx_op.?));
            defer alloc.destroy(c);
            try c.rw.lock();
            c.counter.* += 1;
            c.rw.unlock();
        }
    }.go;

    const N_FSM = 4;
    const fsms = try alloc.alloc(WriteFsm, N_FSM);
    defer alloc.free(fsms);

    const Setup = struct {
        sched: *fp.Scheduler,
        rw: *pl.ParkingRwLock,
        counter: *u64,
        fsms: []WriteFsm,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            // Stackful writer
            const sctx = try alloc.create(StackfulCtx);
            sctx.* = .{ .rw = self.rw, .counter = self.counter };
            try self.sched.submitSpawn(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&stackfulBody)),
                sctx,
                .{ .stack_size = .Standard },
            );
            // FSM writers
            for (self.fsms) |*f| {
                f.* = .{ .task = undefined, .rw = self.rw, .counter = self.counter, .sched = self.sched };
                f.task = try self.sched.allocFsmTask(&WriteFsm.doResume);
                f.task.ctx = f;
                self.sched.enqueueFsm(f.task);
            }
        }
    };
    var setup: Setup = .{
        .sched = &sched,
        .rw = &rw,
        .counter = &counter,
        .fsms = fsms,
    };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&Setup.run)),
        &setup,
        .{ .stack_size = .Standard },
    );
    sched.run();

    try std.testing.expectEqual(@as(u64, 1 + N_FSM), counter);
    for (fsms) |f| try std.testing.expect(f.completed);
    try rw.lock();
    rw.unlock();
}

// ---- Safety: re-entrancy + timeout ----------------------------------------

const Reentrant = struct {
    task: *fsm.FsmTask,
    rw: *pl.ParkingRwLock,
    sched: *fp.Scheduler,
    w1: qs.WaiterNode = undefined,
    w2: qs.WaiterNode = undefined,
    got_deadlock: bool = false,

    fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *Reentrant = @ptrCast(@alignCast(t.ctx.?));
        const r1 = self.rw.tryWriteLockForFsm(self.task, &self.w1, self.sched);
        if (r1 != .Acquired) return .{ .Done = {} };
        const r2 = self.rw.tryWriteLockForFsm(self.task, &self.w2, self.sched);
        if (r2 == .Error and self.task.lock_error == .Deadlock) self.got_deadlock = true;
        self.rw.unlock();
        return .{ .Done = {} };
    }
};

test "R6: FSM write re-entrancy returns lock_error.Deadlock" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &ebr_ctx, &pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.active_scheduler = undefined;

    var rw: pl.ParkingRwLock = .{};
    var s = Reentrant{ .task = undefined, .rw = &rw, .sched = &sched };
    s.task = try sched.allocFsmTask(&Reentrant.doResume);
    s.task.ctx = &s;
    sched.enqueueFsm(s.task);
    sched.drainFsmQueue();
    try std.testing.expect(s.got_deadlock);
    try rw.lock();
    rw.unlock();
}

const WriteTimeout = struct {
    task: *fsm.FsmTask,
    rw: *pl.ParkingRwLock,
    sched: *fp.Scheduler,
    waiter: qs.WaiterNode = undefined,
    step: u8 = 0,
    got_timeout: bool = false,

    fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *WriteTimeout = @ptrCast(@alignCast(t.ctx.?));
        switch (self.step) {
            0 => {
                self.step = 1;
                const r = self.rw.tryWriteLockForFsm(self.task, &self.waiter, self.sched);
                return switch (r) {
                    .Registered => .{ .WaitForLock = {} },
                    else => .{ .Done = {} },
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

test "R7: FSM write wait timeout surfaces lock_error.LockTimeout" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &ebr_ctx, &pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.active_scheduler = undefined;
    sched.lock_timeout_ms = 50;

    var rw: pl.ParkingRwLock = .{};
    try rw.lock(); // never released

    var s = WriteTimeout{ .task = undefined, .rw = &rw, .sched = &sched };
    s.task = try sched.allocFsmTask(&WriteTimeout.doResume);
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
    rw.unlock();
}
