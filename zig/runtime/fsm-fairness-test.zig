// fsm-fairness-test.zig — FSM vs stackful dispatch fairness.
//
// Protects two invariants that would otherwise be easy to regress when
// changing the main-loop dispatch policy:
//
//   F1. FSMs cannot hog.
//       Under a burst of short FSMs the scheduler must not starve
//       stackful tasks. drainFsmQueue uses a per-iteration cap
//       (FSM_DRAIN_BATCH, currently 64) so the stackful hot path always
//       gets a chance to run within bounded time.
//
//   F2. Yielded FSMs cannot hog within a single drain batch.
//       The underlying Chase-Lev deque is LIFO for owner-pop. Without
//       the fsm_deferred_queue staging, a single yielding task would
//       monopolize the whole batch. With it, every yielder in a batch
//       advances exactly once per drain iteration.
//
// The tests exercise dispatch bookkeeping directly (they do not run the
// scheduler main loop) — they call enqueueFsm + drainFsmQueue + ready_queue
// operations and assert on per-iteration progress.

const std = @import("std");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const ebr = @import("../lib/ebr.zig");
const fsm = @import("fsm.zig");
const compat = @import("../lib/compat.zig");

const alloc = std.testing.allocator;

const Counter = struct {
    task: fsm.FsmTask,
    remaining: u32,
    step_count: u32 = 0,

    fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *Counter = @fieldParentPtr("task", t);
        self.step_count += 1;
        if (self.remaining == 0) return .{ .Done = {} };
        self.remaining -= 1;
        return .{ .Yielded = {} };
    }
};

fn mkSched() !struct { sched: fp.Scheduler, ebr_ctx: ebr.EbrContext, pool: fm.StackPool } {
    var out: struct { sched: fp.Scheduler, ebr_ctx: ebr.EbrContext, pool: fm.StackPool } = undefined;
    out.ebr_ctx = .{};
    out.pool = fm.StackPool.init(alloc);
    out.sched = try fp.Scheduler.init(alloc, &out.ebr_ctx, &out.pool);
    return out;
}

test "F1: FSM queue cannot hog — drain is bounded per iteration" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &ebr_ctx, &pool);
    defer sched.deinit();

    // Enqueue far more FSMs than FSM_DRAIN_BATCH so a single drain cannot
    // process all of them. Each task completes on first dispatch (no
    // yielding), so the ONLY thing bounding the drain is the batch cap.
    const N = 512;
    const batch_cap: usize = 64; // matches scheduler.FSM_DRAIN_BATCH
    const tasks = try alloc.alloc(Counter, N);
    defer alloc.free(tasks);

    for (tasks) |*c| {
        c.* = .{ .task = undefined, .remaining = 0 };
        c.task = fsm.FsmTask.init(&Counter.doResume, c);
        sched.enqueueFsm(&c.task);
    }

    // Before drain: queue has N entries.
    try std.testing.expectEqual(@as(usize, N), sched.fsm_ready_queue.len());

    // One drain should run exactly batch_cap tasks, not all N.
    sched.drainFsmQueue();
    try std.testing.expectEqual(@as(usize, N - batch_cap), sched.fsm_ready_queue.len());
    var completed: usize = 0;
    for (tasks) |c| if (c.step_count == 1) { completed += 1; };
    try std.testing.expectEqual(batch_cap, completed);

    // Further drains finish the rest in equal-sized batches.
    const expected_passes = (N + batch_cap - 1) / batch_cap;
    var passes: usize = 1; // already ran once
    while (sched.fsm_ready_queue.len() > 0) : (passes += 1) {
        sched.drainFsmQueue();
        if (passes > expected_passes + 2) return error.TooManyPasses;
    }
    try std.testing.expectEqual(expected_passes, passes);
    try std.testing.expectEqual(@as(u64, 0), sched.active_tasks.load(.monotonic));
}

test "F2: Yielded FSMs cannot monopolize a batch — every yielder advances once" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &ebr_ctx, &pool);
    defer sched.deinit();

    // All tasks yield many times — if a single task were popped + pushed
    // and re-popped within the same batch (LIFO starvation), its
    // step_count would grow while others stayed at 0.
    const batch_cap: usize = 64;
    const N = batch_cap; // fits exactly in one batch so every task gets one resume
    const YIELDS: u32 = 10;
    const tasks = try alloc.alloc(Counter, N);
    defer alloc.free(tasks);

    for (tasks) |*c| {
        c.* = .{ .task = undefined, .remaining = YIELDS };
        c.task = fsm.FsmTask.init(&Counter.doResume, c);
        sched.enqueueFsm(&c.task);
    }

    // After one drain: every task must have resumed exactly once. No
    // outlier, no zero-counter.
    sched.drainFsmQueue();
    for (tasks) |c| {
        try std.testing.expectEqual(@as(u32, 1), c.step_count);
    }

    // Queue now holds all N yielders again (flushed from deferred).
    try std.testing.expectEqual(@as(usize, N), sched.fsm_ready_queue.len());

    // K drains later, every task must have resumed exactly 1+K times.
    const K: u32 = 5;
    for (0..K) |_| sched.drainFsmQueue();
    for (tasks) |c| {
        try std.testing.expectEqual(@as(u32, 1 + K), c.step_count);
    }
}

test "F1b: stackful dispatch is reachable even with a large FSM queue" {
    // The fairness contract: after draining the FSM batch, the main loop
    // dispatches one stackful task. We verify the queue-size relationship:
    // no matter how many FSMs are pending, the stackful ready_queue is
    // never "blocked" from being inspected — i.e., if we simulate the
    // main-loop structure, stackful work is always checked.
    //
    // We don't run the scheduler main loop here (too heavy for a unit
    // test); instead we verify the structural invariant that drainFsmQueue
    // returns in bounded time even under a giant queue, at which point
    // the main loop would immediately look at the stackful queue.
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &ebr_ctx, &pool);
    defer sched.deinit();

    const HUGE = 10_000;
    const tasks = try alloc.alloc(Counter, HUGE);
    defer alloc.free(tasks);
    for (tasks) |*c| {
        c.* = .{ .task = undefined, .remaining = 0 };
        c.task = fsm.FsmTask.init(&Counter.doResume, c);
        sched.enqueueFsm(&c.task);
    }

    const t0 = compat.milliTimestamp();
    sched.drainFsmQueue();
    const elapsed = compat.milliTimestamp() - t0;

    // One drain on 10 K tasks should complete in well under 10 ms — it
    // processes only 64 tasks, not 10 000. (Generous bound for CI.)
    try std.testing.expect(elapsed < 50);
    // And it did NOT drain the whole queue.
    try std.testing.expect(sched.fsm_ready_queue.len() > 0);
    try std.testing.expect(sched.fsm_ready_queue.len() == HUGE - 64);
}
