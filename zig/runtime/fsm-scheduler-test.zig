// fsm-scheduler-test.zig — integration tests for FSM tasks dispatched
// through the real Scheduler (not just dispatchOnce in isolation). Exercises:
//   - enqueueFsm + drainFsmQueue across multiple iterations
//   - cooperative yields (.Yielded) are deferred to the next iteration, not
//     redrained within the same batch (prevents FSM-task livelock)
//   - .Done releases active_tasks count
//   - FSM queue empty after completion
//   - WaitForIO parks task; manual wake via enqueueFsm resumes
//   - hasWork reports FSM queue

const std = @import("std");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const ebr = @import("../lib/ebr.zig");
const fsm = @import("fsm.zig");

const alloc = std.testing.allocator;

// ----- test fixtures ---------------------------------------------------------

const DoneAfterN = struct {
    task: *fsm.FsmTask,
    remaining: u32,
    step_count: u32 = 0,

    fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *DoneAfterN = @ptrCast(@alignCast(t.ctx.?));
        self.step_count += 1;
        if (self.remaining == 0) return .{ .Done = {} };
        self.remaining -= 1;
        return .{ .Yielded = {} };
    }

    fn init(n: u32) DoneAfterN {
        return .{ .task = undefined, .remaining = n };
    }

    fn bind(self: *DoneAfterN, sched: *fp.Scheduler) !void {
        self.task = try sched.allocFsmTask(&DoneAfterN.doResume);
        self.task.ctx = self;
    }
};

// ----- tests -----------------------------------------------------------------

test "enqueueFsm + drainFsmQueue: single-step task finishes in one drain" {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);
    var stack_pool = fm.StackPool.init(alloc);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &global_ebr, &stack_pool);
    defer sched.deinit();

    var s = DoneAfterN.init(0); // Done on first resume
    try s.bind(&sched);

    sched.enqueueFsm(s.task);
    try std.testing.expect(sched.fsm_ready_queue.len() == 1);
    try std.testing.expectEqual(@as(u64, 1), sched.active_tasks.load(.monotonic));

    sched.drainFsmQueue();
    try std.testing.expect(sched.fsm_ready_queue.len() == 0);
    try std.testing.expectEqual(@as(u64, 0), sched.active_tasks.load(.monotonic));
    try std.testing.expectEqual(fsm.FsmStatus.Finished, s.task.status);
    try std.testing.expectEqual(@as(u32, 1), s.step_count);
}

test ".Yielded defers to next iteration, does not re-drain within same batch" {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);
    var stack_pool = fm.StackPool.init(alloc);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &global_ebr, &stack_pool);
    defer sched.deinit();

    var s = DoneAfterN.init(5); // 5 yields, then Done (6 total resumes)
    try s.bind(&sched);

    sched.enqueueFsm(s.task);

    // Single batch: the task should be dispatched exactly once even though it
    // re-queued itself via .Yielded. Prevents FSM livelock.
    sched.drainFsmQueue();
    try std.testing.expectEqual(@as(u32, 1), s.step_count);
    try std.testing.expect(sched.fsm_ready_queue.len() == 1);
    try std.testing.expectEqual(fsm.FsmStatus.Ready, s.task.status);

    // Subsequent iterations advance one step each.
    for (1..6) |_| sched.drainFsmQueue();
    try std.testing.expectEqual(@as(u32, 6), s.step_count);
    try std.testing.expectEqual(fsm.FsmStatus.Finished, s.task.status);
    try std.testing.expectEqual(@as(u64, 0), sched.active_tasks.load(.monotonic));
}

test "multiple FSM tasks drain fairly in one batch" {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);
    var stack_pool = fm.StackPool.init(alloc);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &global_ebr, &stack_pool);
    defer sched.deinit();

    var tasks: [10]DoneAfterN = undefined;
    for (&tasks) |*t| {
        t.* = DoneAfterN.init(0);
        try t.bind(&sched);
        sched.enqueueFsm(t.task);
    }
    try std.testing.expectEqual(@as(u64, 10), sched.active_tasks.load(.monotonic));

    // One drain should complete all 10 since each hits Done on first resume.
    sched.drainFsmQueue();
    try std.testing.expect(sched.fsm_ready_queue.len() == 0);
    try std.testing.expectEqual(@as(u64, 0), sched.active_tasks.load(.monotonic));
    for (&tasks) |*t| {
        try std.testing.expectEqual(fsm.FsmStatus.Finished, t.task.status);
        try std.testing.expectEqual(@as(u32, 1), t.step_count);
    }
}

test "WaitForIO parks task; manual wake via enqueueFsm resumes" {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);
    var stack_pool = fm.StackPool.init(alloc);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &global_ebr, &stack_pool);
    defer sched.deinit();

    const IoTask = struct {
        task: *fsm.FsmTask,
        waiter: fsm.FsmIoWaiter = undefined,
        step: u8 = 0,
        final_result: i32 = 0,

        fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
            const self: *@This() = @ptrCast(@alignCast(t.ctx.?));
            switch (self.step) {
                0 => {
                    self.step = 1;
                    self.waiter = fsm.FsmIoWaiter.init(self.task);
                    return .{ .WaitForIO = &self.waiter };
                },
                1 => {
                    self.final_result = self.waiter.result;
                    return .{ .Done = {} };
                },
                else => unreachable,
            }
        }
    };
    var s: IoTask = .{ .task = undefined };
    s.task = try sched.allocFsmTask(&IoTask.doResume);
    s.task.ctx = &s;

    sched.enqueueFsm(s.task);
    sched.drainFsmQueue();
    try std.testing.expectEqual(fsm.FsmStatus.Blocked, s.task.status);
    try std.testing.expect(sched.fsm_ready_queue.len() == 0);
    // active_tasks still counted — task is parked.
    try std.testing.expectEqual(@as(u64, 1), sched.active_tasks.load(.monotonic));

    // Simulate CQE arrival: fill result, re-enqueue (what processCqes would do).
    s.waiter.result = 128;
    sched.enqueueFsm(s.task);
    // enqueueFsm increments active_tasks; we need to offset because the task
    // was never decremented — it just moved from Blocked to Ready.
    _ = sched.active_tasks.fetchSub(1, .monotonic);

    sched.drainFsmQueue();
    try std.testing.expectEqual(fsm.FsmStatus.Finished, s.task.status);
    try std.testing.expectEqual(@as(i32, 128), s.final_result);
    try std.testing.expectEqual(@as(u64, 0), sched.active_tasks.load(.monotonic));
}

test "hasWork reports true while FSM queue is non-empty" {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);
    var stack_pool = fm.StackPool.init(alloc);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &global_ebr, &stack_pool);
    defer sched.deinit();

    try std.testing.expect(!sched.hasWorkPub());

    var s = DoneAfterN.init(0);
    try s.bind(&sched);
    sched.enqueueFsm(s.task);

    try std.testing.expect(sched.hasWorkPub());

    sched.drainFsmQueue();
    try std.testing.expect(!sched.hasWorkPub());
}
