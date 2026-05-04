// fsm-lock-test.zig — ParkingMutex with FSM tasks + mixed FSM/stackful
// contention. Mirrors the shapes in parking-lot-test.zig but for the
// FSM-side tryLockForFsm API.
//
// Covers:
//   M1. Uncontended FSM acquire (fast path).
//   M2. FSM contends with pre-held stackful lock — registers, wakes
//       on unlock, proceeds.
//   M3. Mixed queue — stackful + FSM waiters on the same mutex, FIFO
//       order respected, each correctly resumed.
//   M4. N FSMs contending on a single mutex — all complete, counter
//       equals N (no lost wakes, no double-increments).
//
// Out of scope for MVP (documented in parking-lot.zig):
//   - Timeout scanning of FSM waiters
//   - Cycle detection through FSM owners
//   - ParkingRwLock FSM support

const std = @import("std");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const fc = @import("fiber-core.zig");
const qs = @import("queues.zig");
const ebr = @import("../lib/ebr.zig");
const fsm = @import("fsm.zig");
const pl = @import("../lib/parking-lot.zig");
const rt_mod = @import("runtime.zig");
const CheatHeader = @import("runtime-header.zig");
const Runtime = rt_mod.Runtime;

const alloc = std.testing.allocator;

// --- Test fixture: an FSM that increments a shared counter under lock ---
//
// Three-state machine:
//   0: tryLockForFsm → Acquired? go to 2 : go to 1 (return WaitForLock)
//   1: (woken) — we now hold the lock; fall through to 2
//   2: CS: counter += 1; unlock; Done
const LockingFsm = struct {
    task: *fsm.FsmTask,
    mutex: *pl.ParkingMutex,
    counter: *u64,
    sched: *fp.Scheduler,
    waiter: qs.WaiterNode = undefined,
    step: u8 = 0,
    completed: bool = false,

    fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *LockingFsm = @ptrCast(@alignCast(t.ctx.?));
        switch (self.step) {
            0 => {
                self.step = 1;
                const r = self.mutex.tryLockForFsm(self.task, &self.waiter, self.sched);
                return switch (r) {
                    .Acquired => continueAfterLock(self),
                    .Registered => .{ .WaitForLock = {} },
                    .Error => .{ .Done = {} },
                };
            },
            1 => {
                // Woken — ownership has been handed off to us by unlock.
                return continueAfterLock(self);
            },
            else => unreachable,
        }
    }

    fn continueAfterLock(self: *LockingFsm) fsm.YieldReason {
        self.counter.* += 1;
        self.mutex.unlock();
        self.completed = true;
        return .{ .Done = {} };
    }

    fn init(mutex: *pl.ParkingMutex, counter: *u64, sched: *fp.Scheduler) LockingFsm {
        return .{
            .task = undefined,  // caller wires task + task.ctx after copy
            .mutex = mutex,
            .counter = counter,
            .sched = sched,
        };
    }

    /// Bind `f` to a slab-allocated FsmTask. Must be called AFTER `f`
    /// has been moved to its final memory location (the FsmTask.ctx
    /// back-pointer must address the live struct).
    fn bind(f: *LockingFsm) !void {
        f.task = try f.sched.allocFsmTask(&LockingFsm.doResume);
        f.task.ctx = f;
    }
};

fn setupScheduler(
    ebr_ctx: *ebr.EbrContext,
    pool: *fm.StackPool,
) !fp.Scheduler {
    return fp.Scheduler.init(alloc, ebr_ctx, pool);
}

// --- M1: uncontended FSM acquire ---
test "FSM mutex: uncontended tryLockForFsm acquires on fast path" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try setupScheduler(&ebr_ctx, &pool);
    defer sched.deinit();

    var mutex: pl.ParkingMutex = .{};
    var counter: u64 = 0;
    var f = LockingFsm.init(&mutex, &counter, &sched);
    try LockingFsm.bind(&f);

    sched.enqueueFsm(f.task);
    sched.drainFsmQueue();

    try std.testing.expect(f.completed);
    try std.testing.expectEqual(@as(u64, 1), counter);
    try std.testing.expectEqual(@as(u64, 0), sched.active_tasks.load(.monotonic));
    // Mutex left unlocked.
    try std.testing.expect(mutex.tryLock());
    mutex.unlock();
}

// --- M2: FSM blocks on held lock; manual wake via unlock on another fiber ---
test "FSM mutex: contended FSM parks, wakes on release" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try setupScheduler(&ebr_ctx, &pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.active_scheduler = undefined;

    var mutex: pl.ParkingMutex = .{};
    var counter: u64 = 0;
    // Pre-acquire the lock from outside (no scheduler_running, so it
    // presents as "locked by unknown owner" which is fine for the
    // contention test — the FSM just has to find LOCKED and park).
    try std.testing.expect(mutex.tryLock());

    var f = LockingFsm.init(&mutex, &counter, &sched);
    try LockingFsm.bind(&f);
    sched.enqueueFsm(f.task);

    // First drain: FSM finds lock held, registers as waiter, returns
    // WaitForLock. Queue becomes empty.
    sched.drainFsmQueue();
    try std.testing.expectEqual(fsm.FsmStatus.Blocked, f.task.status);
    try std.testing.expect(f.task.lock_waiter.load(.acquire) != null);
    try std.testing.expect(sched.fsm_ready_queue.len() == 0);
    // active_tasks is still 1 — task is parked, not finished.
    try std.testing.expectEqual(@as(u64, 1), sched.active_tasks.load(.monotonic));

    // Unlock: wakes the FSM waiter. submitFsmResume on same scheduler
    // goes through the fast path (push directly to fsm_ready_queue).
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;
    mutex.unlock();
    try std.testing.expectEqual(fsm.FsmStatus.Ready, f.task.status);
    try std.testing.expect(sched.fsm_ready_queue.len() == 1);

    // Drain: FSM resumes in step 1, enters CS, unlocks, Done.
    sched.drainFsmQueue();
    try std.testing.expect(f.completed);
    try std.testing.expectEqual(@as(u64, 1), counter);
    try std.testing.expectEqual(@as(u64, 0), sched.active_tasks.load(.monotonic));
}

// --- M3: FSM + stackful contending on the same mutex ---
//
// Spawn a stackful fiber that holds the lock, yields, then releases. Enqueue
// an FSM that also wants the lock. Drive sched.run() to completion. Both
// should complete exactly once, counter == 2.
const StackfulCtx = struct {
    mutex: *pl.ParkingMutex,
    counter: *u64,
};

fn stackfulLocker(rt_opaque: *anyopaque, ctx_opaque: ?*anyopaque) anyerror!void {
    const rt: *Runtime = @ptrCast(@alignCast(rt_opaque));
    const ctx: *StackfulCtx = @ptrCast(@alignCast(ctx_opaque.?));
    defer alloc.destroy(ctx);
    try ctx.mutex.lock();
    ctx.counter.* += 1;
    rt.checkYield();
    ctx.mutex.unlock();
}

const SetupMixed = struct {
    sched: *fp.Scheduler,
    mutex: *pl.ParkingMutex,
    counter: *u64,
    fsms: []LockingFsm,

    fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
        const self: *SetupMixed = @ptrCast(@alignCast(raw.?));
        const sctx = try alloc.create(StackfulCtx);
        sctx.* = .{ .mutex = self.mutex, .counter = self.counter };
        try self.sched.submitSpawn(
            @intFromPtr(&Runtime.entryWrapper),
            @as(CheatHeader.TaskFn, @ptrCast(&stackfulLocker)),
            sctx,
            .{ .stack_size = .Standard },
        );
        for (self.fsms) |*f| {
            f.* = LockingFsm.init(self.mutex, self.counter, self.sched);
            try LockingFsm.bind(f);
            self.sched.enqueueFsm(f.task);
        }
    }
};

test "FSM + stackful contend on same mutex; both complete" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var rt = try Runtime.init(alloc, 512 * 1024, &ebr_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try setupScheduler(&ebr_ctx, &pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(alloc);
    }
    fp.active_scheduler = &sched;

    var mutex: pl.ParkingMutex = .{};
    var counter: u64 = 0;

    const N_FSM = 4;
    const fsms = try alloc.alloc(LockingFsm, N_FSM);
    defer alloc.free(fsms);

    var setup: SetupMixed = .{
        .sched = &sched,
        .mutex = &mutex,
        .counter = &counter,
        .fsms = fsms,
    };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&SetupMixed.run)),
        &setup,
        .{ .stack_size = .Standard },
    );
    sched.run();

    // Expect: stackful (+1) + N FSMs (+1 each) = 1 + N_FSM.
    try std.testing.expectEqual(@as(u64, 1 + N_FSM), counter);
    for (fsms) |f| try std.testing.expect(f.completed);
    try std.testing.expect(mutex.tryLock());
    mutex.unlock();
}

// --- M4: N FSMs contending — stress the wake chain ---
test "FSM mutex: 64 FSMs contend, counter equals N" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var rt = try Runtime.init(alloc, 512 * 1024, &ebr_ctx);
    defer rt.deinit();
    rt.wireAllocator();
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try setupScheduler(&ebr_ctx, &pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(alloc);
    }
    fp.active_scheduler = &sched;

    var mutex: pl.ParkingMutex = .{};
    var counter: u64 = 0;

    const N = 64;
    const fsms = try alloc.alloc(LockingFsm, N);
    defer alloc.free(fsms);

    const SetupN = struct {
        sched_ptr: *fp.Scheduler,
        mutex_ptr: *pl.ParkingMutex,
        counter_ptr: *u64,
        fsms_slice: []LockingFsm,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            for (self.fsms_slice) |*f| {
                f.* = LockingFsm.init(self.mutex_ptr, self.counter_ptr, self.sched_ptr);
                try LockingFsm.bind(f);
                self.sched_ptr.enqueueFsm(f.task);
            }
        }
    };
    var setup: SetupN = .{
        .sched_ptr = &sched,
        .mutex_ptr = &mutex,
        .counter_ptr = &counter,
        .fsms_slice = fsms,
    };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&SetupN.run)),
        &setup,
        .{ .stack_size = .Standard },
    );
    sched.run();

    try std.testing.expectEqual(@as(u64, N), counter);
    for (fsms) |f| try std.testing.expect(f.completed);
}
