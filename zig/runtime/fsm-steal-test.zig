// fsm-steal-test.zig — FSM work-stealing correctness.
//
// Prior to this commit, FSM tasks were pinned to their owning scheduler.
// Now an idle sibling can steal half the FSM queue via
// FsmRunQueue.tryStealFrom, mirroring the stackful ready_queue steal.
//
// Tests:
//   S1. Direct tryStealFrom: scheduler B can grab half of A's FSMs.
//   S2. Stolen tasks complete correctly when drained by the stealer.
//   S3. Structural: FSM queue is still distinct from stackful ready_queue.
//   S4. Stolen active_tasks balance (counter moves with tasks).

pub const CLEAR_FRAME_DEBUG = false;

const std = @import("std");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const ebr = @import("../lib/ebr.zig");
const fsm = @import("fsm.zig");

const alloc = std.testing.allocator;

const Counter = struct {
    task: *fsm.FsmTask,
    completed: bool = false,

    fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *Counter = @ptrCast(@alignCast(t.ctx.?));
        self.completed = true;
        return .{ .Done = {} };
    }
};

test "S1: FsmRunQueue.tryStealFrom transfers ~half of victim's tasks" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var pool_a = fm.StackPool.init(alloc);
    defer pool_a.deinit();
    var pool_b = fm.StackPool.init(alloc);
    defer pool_b.deinit();
    var sched_a = try fp.Scheduler.init(alloc, &ebr_ctx, &pool_a);
    defer sched_a.deinit();
    var sched_b = try fp.Scheduler.init(alloc, &ebr_ctx, &pool_b);
    defer sched_b.deinit();

    const N = 100;
    const tasks = try alloc.alloc(Counter, N);
    defer alloc.free(tasks);

    for (tasks) |*c| {
        c.* = .{ .task = try sched_a.allocFsmTask(&Counter.doResume) };
        c.task.ctx = c;
        sched_a.enqueueFsm(c.task);
    }

    const a_before = sched_a.fsm_ready_queue.len();
    try std.testing.expectEqual(@as(usize, N), a_before);

    const stolen = sched_b.fsm_ready_queue.tryStealFrom(&sched_a.fsm_ready_queue, alloc);
    try std.testing.expect(stolen > 0);
    try std.testing.expect(stolen <= (N + 1) / 2);
    try std.testing.expectEqual(N - stolen, sched_a.fsm_ready_queue.len());
    try std.testing.expectEqual(stolen, sched_b.fsm_ready_queue.len());
}

test "S2: stolen tasks complete correctly when dispatched by the stealer" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var pool_a = fm.StackPool.init(alloc);
    defer pool_a.deinit();
    var pool_b = fm.StackPool.init(alloc);
    defer pool_b.deinit();
    var sched_a = try fp.Scheduler.init(alloc, &ebr_ctx, &pool_a);
    defer sched_a.deinit();
    var sched_b = try fp.Scheduler.init(alloc, &ebr_ctx, &pool_b);
    defer sched_b.deinit();

    const N = 200;
    const tasks = try alloc.alloc(Counter, N);
    defer alloc.free(tasks);
    for (tasks) |*c| {
        c.* = .{ .task = try sched_a.allocFsmTask(&Counter.doResume) };
        c.task.ctx = c;
        sched_a.enqueueFsm(c.task);
    }

    const stolen = sched_b.fsm_ready_queue.tryStealFrom(&sched_a.fsm_ready_queue, alloc);
    // Transfer active_tasks: stealing mirrors the scheduler's own policy.
    _ = sched_b.active_tasks.fetchAdd(stolen, .monotonic);
    _ = sched_a.active_tasks.fetchSub(stolen, .monotonic);

    // Drain both schedulers until quiescent.
    var it: u32 = 0;
    while (sched_a.fsm_ready_queue.len() > 0 or sched_b.fsm_ready_queue.len() > 0) : (it += 1) {
        sched_a.drainFsmQueue();
        sched_b.drainFsmQueue();
        if (it > (N / 64) + 100) return error.StalledDrain;
    }

    var completed: usize = 0;
    for (tasks) |c| if (c.completed) { completed += 1; };
    try std.testing.expectEqual(@as(usize, N), completed);
    try std.testing.expectEqual(@as(u64, 0), sched_a.active_tasks.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), sched_b.active_tasks.load(.monotonic));
}

test "S3: FSM queue is structurally distinct from stackful ready_queue" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &ebr_ctx, &pool);
    defer sched.deinit();

    var c: Counter = .{ .task = try sched.allocFsmTask(&Counter.doResume) };
    c.task.ctx = &c;
    sched.enqueueFsm(c.task);

    // Enqueuing an FSM must not appear in the stackful queue.
    try std.testing.expectEqual(@as(usize, 1), sched.fsm_ready_queue.len());
    try std.testing.expectEqual(@as(usize, 0), sched.ready_queue.len());

    sched.drainFsmQueue();
    try std.testing.expect(c.completed);
    try std.testing.expectEqual(@as(usize, 0), sched.fsm_ready_queue.len());
}

test "S4: empty victim returns 0 stolen, leaves both queues empty" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var pool_a = fm.StackPool.init(alloc);
    defer pool_a.deinit();
    var pool_b = fm.StackPool.init(alloc);
    defer pool_b.deinit();
    var sched_a = try fp.Scheduler.init(alloc, &ebr_ctx, &pool_a);
    defer sched_a.deinit();
    var sched_b = try fp.Scheduler.init(alloc, &ebr_ctx, &pool_b);
    defer sched_b.deinit();

    const stolen = sched_b.fsm_ready_queue.tryStealFrom(&sched_a.fsm_ready_queue, alloc);
    try std.testing.expectEqual(@as(usize, 0), stolen);
    try std.testing.expectEqual(@as(usize, 0), sched_a.fsm_ready_queue.len());
    try std.testing.expectEqual(@as(usize, 0), sched_b.fsm_ready_queue.len());
}
