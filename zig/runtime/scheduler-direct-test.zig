const std = @import("std");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const fc = @import("fiber-core.zig");
const qs = @import("queues.zig");
const ebr = @import("../lib/ebr.zig");
const spsc = @import("spsc.zig");

const alloc = std.testing.allocator;
const DummyTaskParts = struct {
    task: *qs.Task,
    fiber: *fc.Fiber,
};

fn dummyTaskFn(_: *anyopaque, _: ?*anyopaque) anyerror!void {}

fn makeDummyTask() !DummyTaskParts {
    const fiber = try alloc.create(fc.Fiber);
    fiber.* = .{
        .stack = .{ .memory = &[_]u8{} },
        .ctx = .{ .sp = 0 },
        .parent_ctx = undefined,
        .size_class = .Standard,
        .stack_limit = 0,
        .stack_guard_head = null,
    };

    const task = try alloc.create(qs.Task);
    task.* = .{
        .base = fiber,
        .user_fn = @ptrCast(&dummyTaskFn),
    };

    return .{ .task = task, .fiber = fiber };
}

fn destroyDummyTask(parts: DummyTaskParts) void {
    alloc.destroy(parts.task);
    alloc.destroy(parts.fiber);
}

test "Scheduler.ensureChannel is idempotent per sender index" {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);

    var stack_pool = fm.StackPool.init(alloc);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(alloc, &global_ebr, &stack_pool);
    defer sched.deinit();

    const ring1 = try sched.ensureChannel(3);
    const ring2 = try sched.ensureChannel(3);

    try std.testing.expectEqual(ring1, ring2);
    try std.testing.expect(ring1.isEmpty());
}

test "Scheduler.submitResume on same scheduler is idempotent while queued" {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);

    var stack_pool = fm.StackPool.init(alloc);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(alloc, &global_ebr, &stack_pool);
    defer sched.deinit();

    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;
    defer fp.active_scheduler = undefined;

    const parts = try makeDummyTask();
    defer destroyDummyTask(parts);

    sched.submitResume(parts.task);
    sched.submitResume(parts.task);

    try std.testing.expect(parts.task.in_inbox.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), sched.ready_queue.len());

    const popped = sched.ready_queue.pop();
    try std.testing.expectEqual(parts.task, popped);
}

test "Scheduler.submitSpawn queues one task after drainChannels" {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);

    var stack_pool = fm.StackPool.init(alloc);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(alloc, &global_ebr, &stack_pool);
    defer sched.deinit();

    try sched.submitSpawn(@intFromPtr(&dummyTaskFn), @ptrCast(&dummyTaskFn), null, .{});
    sched.drainChannels();

    try std.testing.expectEqual(@as(usize, 1), sched.ready_queue.len());
    try std.testing.expectEqual(@as(usize, 1), sched.active_tasks.load(.monotonic));

    const task = sched.ready_queue.pop().?;
    _ = sched.active_tasks.fetchSub(1, .monotonic);
    sched.releaseTaskEbr(task);
    sched.freeStack(task.base.stack);
    alloc.destroy(task.base);
    sched.task_slab.destroy(task);
}

test "Scheduler.drainRemoteCalls executes and completes exactly once" {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);

    var stack_pool = fm.StackPool.init(alloc);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(alloc, &global_ebr, &stack_pool);
    defer sched.deinit();

    var completion = fp.RemoteCompletion{ .wg = fp.WaitGroup.init(&sched) };
    completion.wg.add(1);

    const Ctx = struct {
        count: usize = 0,
        fn run(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.count += 1;
        }
    };

    var ctx = Ctx{};
    const ring = try sched.ensureChannel(0);
    try std.testing.expect(ring.push(.{
        .tag = .RemoteCall,
        .rc_func = @ptrCast(&Ctx.run),
        .rc_ctx = @ptrCast(&ctx),
        .rc_wg = @ptrCast(&completion),
    }));
    _ = sched.dirty_mask.fetchOr(@as(u64, 1), .seq_cst);

    sched.drainRemoteCalls();
    sched.drainRemoteCalls();

    try std.testing.expectEqual(@as(usize, 1), ctx.count);
    try std.testing.expect(completion.finished.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), completion.wg.counter.load(.seq_cst));
    try std.testing.expect(ring.isEmpty());
}
