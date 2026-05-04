// fsm-hammer-test.zig — stress test for FSM task dispatch.
//
// Spawns a large batch of FSM tasks and drains them through the scheduler's
// drainFsmQueue until every task reaches .Done. Verifies correctness
// (checksum) and absence of leaks / stalls.
//
// FSM tasks in the MVP are per-scheduler-local — no cross-thread submission
// yet — so this hammer operates on a single scheduler with a deep queue.
// That covers the MVP surface: main-loop dispatch, .Yielded re-queue,
// mixed batches of short and long FSMs.
//
// Duration: time-boxed like parking-lot-hammer-test (default 2s via
// CLEAR_HAMMER_SECONDS env var).
//
// Run: via zig build test (wired through zig/build.zig)

pub const CLEAR_FRAME_DEBUG = false;

const std = @import("std");
const builtin = @import("builtin");
const runtime_hdr = @import("runtime/runtime-header.zig");
const fp = @import("runtime/scheduler.zig");
const fm = @import("runtime/fiber-memory.zig");
const ebr = @import("lib/ebr.zig");
const fsm = @import("runtime/fsm.zig");
const compat = @import("lib/compat.zig");
const build_options = @import("build_options");

const alloc = std.testing.allocator;

// FSM task that sums integers 1..=N across N+1 resumes. Verification: final
// accumulator equals N*(N+1)/2.
const SumTo = struct {
    task: *fsm.FsmTask,
    target: u32,
    current: u32 = 0,
    sum: u64 = 0,

    fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *SumTo = @ptrCast(@alignCast(t.ctx.?));
        if (self.current >= self.target) return .{ .Done = {} };
        self.current += 1;
        self.sum += self.current;
        return .{ .Yielded = {} };
    }

    fn expectedSum(target: u32) u64 {
        const t: u64 = target;
        return t * (t + 1) / 2;
    }
};

fn hammerDurationMs() u64 {
    if (std.c.getenv("CLEAR_HAMMER_SECONDS")) |env_z| {
        const s = std.mem.span(env_z);
        const secs = std.fmt.parseInt(u64, s, 10) catch 0;
        if (secs > 0) return secs * 1000;
    }
    if (build_options.coverage) return 50;
    return if (builtin.mode == .Debug) 1000 else 2000;
}

test "FSM hammer: 10000 tasks each running 100 yields complete with correct sums" {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);
    var stack_pool = fm.StackPool.init(alloc);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &global_ebr, &stack_pool);
    defer sched.deinit();

    const N_TASKS = if (build_options.coverage) 100 else 10_000;
    const TARGET = if (build_options.coverage) 10 else 100;

    const tasks = try alloc.alloc(SumTo, N_TASKS);
    defer alloc.free(tasks);

    for (tasks) |*t| {
        t.* = .{ .task = try sched.allocFsmTask(&SumTo.doResume), .target = TARGET }; t.task.ctx = t;
        
        sched.enqueueFsm(t.task);
    }

    try std.testing.expectEqual(@as(u64, N_TASKS), sched.active_tasks.load(.monotonic));

    // Drain until everything is .Finished. drainFsmQueue processes a
    // snapshot per call; each SumTo takes TARGET+1 drains to complete.
    // Drain batch is capped (FSM_DRAIN_BATCH=64) for fairness with
    // stackful tasks; many more iterations needed than the naive yields-
    // per-task count.
    var iterations: u32 = 0;
    const iteration_cap = @as(u32, @intCast((N_TASKS * (TARGET + 1) / 64) + 200));
    while (sched.fsm_ready_queue.len() > 0) : (iterations += 1) {
        sched.drainFsmQueue();
        if (iterations > iteration_cap) {
            std.debug.print("FSM hammer made no progress after {d} iterations\n", .{iterations});
            return error.StalledQueue;
        }
    }

    try std.testing.expectEqual(@as(u64, 0), sched.active_tasks.load(.monotonic));
    const expected = SumTo.expectedSum(TARGET);
    for (tasks) |t| {
        try std.testing.expectEqual(fsm.FsmStatus.Finished, t.task.status);
        try std.testing.expectEqual(expected, t.sum);
    }
}

test "FSM hammer: time-boxed stress with mixed task lengths" {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);
    var stack_pool = fm.StackPool.init(alloc);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &global_ebr, &stack_pool);
    defer sched.deinit();

    const duration_ms = hammerDurationMs();
    const deadline_ms: i64 = compat.milliTimestamp() + @as(i64, @intCast(duration_ms));
    var total_completed: u64 = 0;
    var total_sum: u64 = 0;
    var prng = std.Random.DefaultPrng.init(0xCAFE_F5D);
    const rng = prng.random();

    const BATCH = if (build_options.coverage) 32 else 256;
    const tasks = try alloc.alloc(SumTo, BATCH);
    defer alloc.free(tasks);

    while (true) {
        if (compat.milliTimestamp() >= deadline_ms) break;

        var expected_batch_sum: u64 = 0;
        for (tasks) |*t| {
            const target: u32 = @intCast(1 + rng.uintLessThan(u32, 64));
            t.* = .{ .task = try sched.allocFsmTask(&SumTo.doResume), .target = target }; t.task.ctx = t;
            
            expected_batch_sum += SumTo.expectedSum(target);
            sched.enqueueFsm(t.task);
        }

        var iters: u32 = 0;
        while (sched.fsm_ready_queue.len() > 0) : (iters += 1) {
            sched.drainFsmQueue();
            if (iters > 1_000) return error.StalledQueue;
        }

        // Verify batch.
        for (tasks) |t| {
            try std.testing.expectEqual(fsm.FsmStatus.Finished, t.task.status);
            total_sum += t.sum;
        }
        total_completed += BATCH;

        // Active task count must balance between batches.
        try std.testing.expectEqual(@as(u64, 0), sched.active_tasks.load(.monotonic));
    }

    std.debug.print("FSM hammer: completed {d} tasks ({d} sum) in {d}ms\n", .{
        total_completed,
        total_sum,
        duration_ms,
    });
    try std.testing.expect(total_completed > 0);
}

test "FSM hammer: WaitForIO park/wake cycle under load" {
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
        observed: i32 = 0,

        fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
            const self: *@This() = @ptrCast(@alignCast(t.ctx.?));
            switch (self.step) {
                0 => {
                    self.step = 1;
                    self.waiter = fsm.FsmIoWaiter.init(self.task);
                    return .{ .WaitForIO = &self.waiter };
                },
                1 => {
                    self.observed = self.waiter.result;
                    return .{ .Done = {} };
                },
                else => unreachable,
            }
        }
    };

    const N = if (build_options.coverage) 100 else 5_000;
    const tasks = try alloc.alloc(IoTask, N);
    defer alloc.free(tasks);

    for (tasks, 0..) |*t, i| {
        t.* = .{ .task = try sched.allocFsmTask(&IoTask.doResume) }; t.task.ctx = t;
        
        _ = i;
        sched.enqueueFsm(t.task);
    }

    // Park every task on its waiter. Drain batch is 64 per iteration,
    // so loop until the queue is empty.
    var park_iters: u32 = 0;
    while (sched.fsm_ready_queue.len() > 0) : (park_iters += 1) {
        sched.drainFsmQueue();
        if (park_iters > (N / 64) + 100) return error.StalledQueue;
    }
    for (tasks) |t| {
        try std.testing.expectEqual(fsm.FsmStatus.Blocked, t.task.status);
    }
    try std.testing.expectEqual(@as(u64, N), sched.active_tasks.load(.monotonic));

    // Simulate CQE wakes: in real dispatch, enqueueFsm increments active_tasks
    // but the task was never decremented on its park (it just transitioned
    // Blocked->Ready), so we compensate.
    for (tasks, 0..) |*t, i| {
        t.waiter.result = @intCast(i);
        sched.enqueueFsm(t.task);
        _ = sched.active_tasks.fetchSub(1, .monotonic);
    }

    // Drain the wakes until done.
    var iters: u32 = 0;
    while (sched.fsm_ready_queue.len() > 0) : (iters += 1) {
        sched.drainFsmQueue();
        if (iters > (N / 64) + 100) return error.StalledQueue;
    }

    for (tasks, 0..) |t, i| {
        try std.testing.expectEqual(fsm.FsmStatus.Finished, t.task.status);
        try std.testing.expectEqual(@as(i32, @intCast(i)), t.observed);
    }
    try std.testing.expectEqual(@as(u64, 0), sched.active_tasks.load(.monotonic));
}
