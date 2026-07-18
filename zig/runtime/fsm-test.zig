//! Tests extracted from runtime/fsm.zig.
//!
//! Pre-V33 these tests lived inline at the bottom of fsm.zig.
//! Moving them here keeps production diffs free of test churn.

const std = @import("std");
const testing = std.testing;

const fsm = @import("fsm.zig");
const FsmTask = fsm.FsmTask;
const FsmStatus = fsm.FsmStatus;
const FsmIoWaiter = fsm.FsmIoWaiter;
const YieldReason = fsm.YieldReason;
const dispatchOnce = fsm.dispatchOnce;

test "FsmTask: trivial single-state task completes" {
    const State = struct {
        seen: u32 = 0,

        fn doResume(t: *FsmTask) YieldReason {
            const self: *@This() = @ptrCast(@alignCast(t.ctx.?));
            self.seen += 1;
            return .{ .Done = {} };
        }
    };
    var s: State = .{ .seen = 0 };
    var task = FsmTask.init(&State.doResume);
    task.ctx = &s;

    const reason = dispatchOnce(&task);
    try testing.expect(reason == .Done);
    try testing.expectEqual(@as(u32, 1), s.seen);
    try testing.expectEqual(FsmStatus.Finished, task.status);
}

test "FsmTask: multi-step state machine advances per resume" {
    const State = struct {
        step: u8 = 0,
        accumulator: u64 = 0,

        fn doResume(t: *FsmTask) YieldReason {
            const self: *@This() = @ptrCast(@alignCast(t.ctx.?));
            switch (self.step) {
                0 => {
                    self.accumulator = 10;
                    self.step = 1;
                    return .{ .Yielded = {} };
                },
                1 => {
                    self.accumulator *= 2;
                    self.step = 2;
                    return .{ .Yielded = {} };
                },
                2 => {
                    self.accumulator += 7;
                    return .{ .Done = {} };
                },
                else => unreachable,
            }
        }
    };
    var s: State = .{};
    var task = FsmTask.init(&State.doResume);
    task.ctx = &s;

    try testing.expect(dispatchOnce(&task) == .Yielded);
    try testing.expectEqual(FsmStatus.Ready, task.status);
    try testing.expect(dispatchOnce(&task) == .Yielded);
    try testing.expect(dispatchOnce(&task) == .Done);
    try testing.expectEqual(FsmStatus.Finished, task.status);
    try testing.expectEqual(@as(u64, 27), s.accumulator);
}

test "FsmTask: WaitForIO sets Blocked and stashes waiter" {
    const State = struct {
        task: *FsmTask = undefined,
        waiter: FsmIoWaiter = undefined,
        step: u8 = 0,

        fn doResume(t: *FsmTask) YieldReason {
            const self: *@This() = @ptrCast(@alignCast(t.ctx.?));
            switch (self.step) {
                0 => {
                    self.step = 1;
                    self.waiter = FsmIoWaiter.init(self.task);
                    return .{ .WaitForIO = &self.waiter };
                },
                1 => {
                    // The scheduler would have filled self.waiter.result
                    // before re-dispatching; mirror that here.
                    if (self.waiter.result < 0) return .{ .Done = {} };
                    return .{ .Done = {} };
                },
                else => unreachable,
            }
        }
    };
    var s: State = .{};
    var task = FsmTask.init(&State.doResume);
    task.ctx = &s;
    s.task = &task;

    const reason = dispatchOnce(&task);
    try testing.expect(reason == .WaitForIO);
    try testing.expectEqual(FsmStatus.Blocked, task.status);
    try testing.expect(task.waiter == &s.waiter);

    // Simulate CQE arrival: scheduler fills result, re-enqueues, re-dispatches.
    s.waiter.result = 42;
    const second = dispatchOnce(&task);
    try testing.expect(second == .Done);
    try testing.expectEqual(FsmStatus.Finished, task.status);
    // Waiter is cleared on re-dispatch entry.
    try testing.expect(task.waiter == null);
}

test "FsmIoWaiter: encode/decode round-trips with FSM marker" {
    var dummy_task: FsmTask = .{ .resume_fn = undefined };
    var waiter = FsmIoWaiter.init(&dummy_task);
    const ud = waiter.encode();

    try testing.expect(FsmIoWaiter.isFsmMarker(ud));
    const decoded = FsmIoWaiter.decode(ud);
    try testing.expectEqual(&waiter, decoded);
}

test "FsmIoWaiter: marker distinguishes FSM from stackful IoWaiter" {
    var dummy_task: FsmTask = .{ .resume_fn = undefined };
    var fsm_waiter = FsmIoWaiter.init(&dummy_task);
    const fsm_ud = fsm_waiter.encode();

    // Stackful IoWaiter uses `ptr | 1` (bit 1 = 0).
    const fake_stackful_ud: u64 = @intFromPtr(&fsm_waiter) | 1;

    try testing.expect(FsmIoWaiter.isFsmMarker(fsm_ud));
    try testing.expect(!FsmIoWaiter.isFsmMarker(fake_stackful_ud));
    // Plain Task pointer (bit 0 = 0) also not an FSM marker.
    try testing.expect(!FsmIoWaiter.isFsmMarker(@intFromPtr(&fsm_waiter)));
}

test "FsmRunQueue: init propagates array allocation failure" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });

    try testing.expectError(error.OutOfMemory, fsm.FsmRunQueue.initWithAllocator(failing.allocator()));
}

test "FsmRunQueue: init propagates array header allocation failure" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });

    try testing.expectError(error.OutOfMemory, fsm.FsmRunQueue.initWithAllocator(failing.allocator()));
}

test "FsmRunQueue: push propagates growth allocation failure" {
    const initial_capacity = @as(usize, 1) << fsm.FsmRunQueue.INITIAL_LOG_SIZE;
    const State = struct {
        fn doResume(_: *FsmTask) YieldReason {
            return .{ .Done = {} };
        }
    };

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    var queue = try fsm.FsmRunQueue.initWithAllocator(failing.allocator());
    defer queue.deinit();

    var tasks: [initial_capacity + 1]FsmTask = undefined;
    for (&tasks) |*task| {
        task.* = FsmTask.init(&State.doResume);
    }

    for (tasks[0..initial_capacity]) |*task| {
        try queue.push(failing.allocator(), task);
    }

    try testing.expectError(error.OutOfMemory, queue.push(failing.allocator(), &tasks[initial_capacity]));
}

test "FsmRunQueue: push propagates old-array retention failure" {
    const initial_capacity = @as(usize, 1) << fsm.FsmRunQueue.INITIAL_LOG_SIZE;
    const State = struct {
        fn doResume(_: *FsmTask) YieldReason {
            return .{ .Done = {} };
        }
    };

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 4 });
    var queue = try fsm.FsmRunQueue.initWithAllocator(failing.allocator());
    defer queue.deinit();

    var tasks: [initial_capacity + 1]FsmTask = undefined;
    for (&tasks) |*task| {
        task.* = FsmTask.init(&State.doResume);
    }

    for (tasks[0..initial_capacity]) |*task| {
        try queue.push(failing.allocator(), task);
    }

    try testing.expectError(error.OutOfMemory, queue.push(failing.allocator(), &tasks[initial_capacity]));
    try testing.expectEqual(initial_capacity, queue.len());
}

test "dispatchOnce: Yielded reuses task across many iterations" {
    const State = struct {
        remaining: u32 = 0,
        sum: u64 = 0,

        fn doResume(t: *FsmTask) YieldReason {
            const self: *@This() = @ptrCast(@alignCast(t.ctx.?));
            if (self.remaining == 0) return .{ .Done = {} };
            self.sum += self.remaining;
            self.remaining -= 1;
            return .{ .Yielded = {} };
        }
    };
    var s: State = .{ .remaining = 100 };
    var task = FsmTask.init(&State.doResume);
    task.ctx = &s;

    var loops: u32 = 0;
    while (true) {
        const r = dispatchOnce(&task);
        loops += 1;
        if (r == .Done) break;
    }
    try testing.expectEqual(@as(u32, 101), loops);
    try testing.expectEqual(@as(u64, 5050), s.sum);
}

test "FsmRunQueue: grow succeeds and retains items" {
    const initial_capacity = @as(usize, 1) << fsm.FsmRunQueue.INITIAL_LOG_SIZE;
    const State = struct {
        fn doResume(_: *FsmTask) YieldReason {
            return .{ .Done = {} };
        }
    };
    var queue = try fsm.FsmRunQueue.initWithAllocator(testing.allocator);
    defer queue.deinit();

    var tasks: [initial_capacity * 2]FsmTask = undefined;
    for (&tasks) |*task| task.* = FsmTask.init(&State.doResume);

    for (&tasks) |*task| try queue.push(testing.allocator, task);

    try testing.expectEqual(initial_capacity * 2, queue.len());
    var i: usize = tasks.len;
    while (i > 0) {
        i -= 1;
        const task = &tasks[i];
        const popped = queue.pop();
        try testing.expectEqual(task, popped);
    }
    try testing.expectEqual(@as(usize, 0), queue.len());
    try testing.expect(queue.pop() == null);
}

test "FsmRunQueue: stealOne on empty returns null" {
    var queue = try fsm.FsmRunQueue.initWithAllocator(testing.allocator);
    defer queue.deinit();
    try testing.expect(queue.stealOne() == null);
}

test "FsmRunQueue: tryStealFrom on empty returns 0" {
    var queue1 = try fsm.FsmRunQueue.initWithAllocator(testing.allocator);
    defer queue1.deinit();
    var queue2 = try fsm.FsmRunQueue.initWithAllocator(testing.allocator);
    defer queue2.deinit();
    try testing.expectEqual(@as(usize, 0), queue1.tryStealFrom(&queue2, testing.allocator));
}

test "FsmRunQueue: tryStealFrom steals half the elements" {
    const State = struct {
        fn doResume(_: *FsmTask) YieldReason {
            return .{ .Done = {} };
        }
    };
    var queue1 = try fsm.FsmRunQueue.initWithAllocator(testing.allocator);
    defer queue1.deinit();
    var queue2 = try fsm.FsmRunQueue.initWithAllocator(testing.allocator);
    defer queue2.deinit();

    var tasks: [4]FsmTask = undefined;
    for (&tasks) |*task| task.* = FsmTask.init(&State.doResume);

    for (&tasks) |*task| try queue2.push(testing.allocator, task);
    try testing.expectEqual(@as(usize, 4), queue2.len());

    const stolen = queue1.tryStealFrom(&queue2, testing.allocator);
    try testing.expectEqual(@as(usize, 2), stolen);
    try testing.expectEqual(@as(usize, 2), queue1.len());
    try testing.expectEqual(@as(usize, 2), queue2.len());

    try testing.expectEqual(&tasks[1], queue1.pop());
    try testing.expectEqual(&tasks[0], queue1.pop());
    try testing.expect(queue1.pop() == null);

    try testing.expectEqual(&tasks[3], queue2.pop());
    try testing.expectEqual(&tasks[2], queue2.pop());
    try testing.expect(queue2.pop() == null);
}
