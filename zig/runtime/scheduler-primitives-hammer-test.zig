// scheduler-primitives-hammer-test.zig -- TSan hammer coverage for scheduler wait loops.

const std = @import("std");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const ebr = @import("../lib/ebr.zig");
const Runtime = @import("runtime.zig").Runtime;
const CheatHeader = @import("runtime-header.zig");
const qs = @import("queues.zig");

const allocator = std.heap.c_allocator;

fn noop(_: *anyopaque, _: ?*anyopaque) anyerror!void {}

// HAMMER-COVERS: waitgroup.wait-non-fiber
test "Hammer: WaitGroup non-fiber wait yields until done publishes completion" {
    var global_ebr = ebr.EbrContext{};
    defer global_ebr.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(allocator, &global_ebr, &stack_pool);
    defer sched.deinit();

    var wg = fp.WaitGroup.init(&sched);
    wg.add(1);
    var waiter_started = std.atomic.Value(bool).init(false);
    var waiter_finished = std.atomic.Value(bool).init(false);

    const Waiter = struct {
        fn run(group: *fp.WaitGroup, started: *std.atomic.Value(bool), finished: *std.atomic.Value(bool)) void {
            started.store(true, .release);
            group.wait();
            finished.store(true, .release);
        }
    };

    const waiter = try std.Thread.spawn(.{}, Waiter.run, .{ &wg, &waiter_started, &waiter_finished });
    while (!waiter_started.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    for (0..1_000) |_| {
        try std.testing.expect(!waiter_finished.load(.acquire));
        std.Thread.yield() catch {};
    }

    wg.done();
    waiter.join();

    try std.testing.expect(waiter_finished.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), wg.counter.load(.seq_cst));
}

const WaitGroupFiberCtx = struct {
    wg: *fp.WaitGroup,
    completed: *std.atomic.Value(usize),

    fn waiter(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.wg.wait();
        _ = self.completed.fetchAdd(1, .release);
    }

    fn releaser(rt: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        var spins: usize = 0;
        while (self.wg.waiting_task == null) : (spins += 1) {
            if (spins > 100_000) return error.WaitGroupFiberDidNotPark;
            rt.checkYield();
        }
        self.wg.done();
        _ = self.completed.fetchAdd(1, .release);
    }
};

// HAMMER-COVERS: waitgroup.wait-fiber-park
test "Hammer: WaitGroup fiber wait parks and done wakes exactly one waiter" {
    var global_ebr = ebr.EbrContext{};
    defer global_ebr.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(allocator, &global_ebr, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(allocator);
    }
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;

    var rt = try Runtime.init(allocator, 4 * 1024, &global_ebr);
    defer rt.deinit();
    rt.wireAllocator();

    var wg = fp.WaitGroup.init(&sched);
    wg.add(1);
    var completed = std.atomic.Value(usize).init(0);
    var ctx = WaitGroupFiberCtx{ .wg = &wg, .completed = &completed };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&WaitGroupFiberCtx.waiter)),
        &ctx,
        .{ .stack_size = .Large },
    );
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&WaitGroupFiberCtx.releaser)),
        &ctx,
        .{ .stack_size = .Large },
    );

    sched.run();

    try std.testing.expectEqual(@as(usize, 2), completed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), wg.counter.load(.seq_cst));
    try std.testing.expectEqual(@as(?*qs.Task, null), wg.waiting_task);
}

const SemaphoreFiberCtx = struct {
    sem: *fp.Semaphore,
    completed: *std.atomic.Value(usize),
    entered: *std.atomic.Value(usize),

    fn acquirer(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.sem.acquire();
        _ = self.entered.fetchAdd(1, .release);
        _ = self.completed.fetchAdd(1, .release);
    }

    fn releaser(rt: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        var spins: usize = 0;
        while (self.sem.waiting_task == null) : (spins += 1) {
            if (spins > 100_000) return error.SemaphoreFiberDidNotPark;
            rt.checkYield();
        }
        try std.testing.expectEqual(@as(usize, 0), self.entered.load(.acquire));
        self.sem.release();
        _ = self.completed.fetchAdd(1, .release);
    }
};

// HAMMER-COVERS: semaphore.acquire-park
test "Hammer: Semaphore acquire parks at zero and release grants the slot to the waiter" {
    var global_ebr = ebr.EbrContext{};
    defer global_ebr.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(allocator, &global_ebr, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(allocator);
    }
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;

    var rt = try Runtime.init(allocator, 4 * 1024, &global_ebr);
    defer rt.deinit();
    rt.wireAllocator();

    var sem = fp.Semaphore.init(0, &sched);
    var completed = std.atomic.Value(usize).init(0);
    var entered = std.atomic.Value(usize).init(0);
    var ctx = SemaphoreFiberCtx{ .sem = &sem, .completed = &completed, .entered = &entered };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&SemaphoreFiberCtx.acquirer)),
        &ctx,
        .{ .stack_size = .Large },
    );
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&SemaphoreFiberCtx.releaser)),
        &ctx,
        .{ .stack_size = .Large },
    );

    sched.run();

    try std.testing.expectEqual(@as(usize, 2), completed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), entered.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), sem.counter.load(.seq_cst));
    try std.testing.expectEqual(@as(?*qs.Task, null), sem.waiting_task);
}
