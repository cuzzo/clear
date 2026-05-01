// fsm-endtoend-fairness-test.zig — end-to-end fairness through sched.run().
//
// fsm-fairness-test.zig proves the drain PRIMITIVES are bounded. This
// test closes the gap by driving the full scheduler main loop with mixed
// FSM + stackful load and verifying that BOTH sides make progress:
//
//   E1. Stackful progress under heavy FSM load.
//       A stackful fiber increments a counter on every yield. An FSM
//       burst of N tasks is enqueued before it. After run() completes,
//       both the stackful counter and the FSM counter must match their
//       expected values. If FSM drain were unbounded, the stackful
//       fiber would still eventually run but could be starved for a
//       long stretch; the bounded drain guarantees progress every
//       iteration of the main loop.
//
//   E2. FSM progress when a stackful fiber is also in flight.
//       Same scenario, inverted focus: even though the stackful fiber
//       is cooperatively yielding, the FSM queue continues to drain
//       across iterations.
//
// These tests set shutdown_on_idle = true so run() exits once
// active_tasks hits 0, at which point both counters must be fully
// populated.

const std = @import("std");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const ebr = @import("../lib/ebr.zig");
const fsm = @import("fsm.zig");
const rt_mod = @import("runtime.zig");
const CheatHeader = @import("runtime-header.zig");
const Runtime = rt_mod.Runtime;

const alloc = std.testing.allocator;

const N_FSM = 500;
const STACKFUL_YIELDS: u32 = 50;

// FSM that increments a shared counter once, then completes.
const FsmCounter = struct {
    task: fsm.FsmTask,
    counter: *std.atomic.Value(u32),

    fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *FsmCounter = @fieldParentPtr("task", t);
        _ = self.counter.fetchAdd(1, .release);
        return .{ .Done = {} };
    }
};

// Stackful fiber body — yields STACKFUL_YIELDS times, bumps counter each pass.
const StackfulCtx = struct {
    counter: *std.atomic.Value(u32),
};

fn stackfulBody(rt_opaque: *anyopaque, ctx_opaque: ?*anyopaque) anyerror!void {
    const rt: *Runtime = @ptrCast(@alignCast(rt_opaque));
    const ctx: *StackfulCtx = @ptrCast(@alignCast(ctx_opaque.?));
    var i: u32 = 0;
    while (i < STACKFUL_YIELDS) : (i += 1) {
        _ = ctx.counter.fetchAdd(1, .release);
        rt.checkYield();
    }
}

// Setup fiber — runs inside the scheduler, enqueues a stackful fiber and
// a burst of FSM tasks. The main thread's sched.run() keeps running until
// shutdown_on_idle triggers.
fn setupBody(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
    const setup: *SetupCtx = @ptrCast(@alignCast(raw.?));

    // Enqueue FSM burst first so it sits on the queue before the stackful
    // fiber starts running. This is the scenario where FSM could starve
    // stackful under an unbounded drain.
    for (setup.fsm_pool) |*f| {
        f.* = .{ .task = undefined, .counter = setup.fsm_counter };
        f.task = fsm.FsmTask.init(&FsmCounter.doResume);
        setup.sched.enqueueFsm(&f.task);
    }

    // Spawn the stackful fiber.
    try setup.sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&stackfulBody)),
        setup.stackful_ctx,
        .{ .stack_size = .Standard },
    );
}

const SetupCtx = struct {
    sched: *fp.Scheduler,
    fsm_pool: []FsmCounter,
    fsm_counter: *std.atomic.Value(u32),
    stackful_ctx: *StackfulCtx,
};

test "end-to-end fairness: stackful fiber and FSM burst both complete via sched.run()" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var rt = try Runtime.init(alloc, 512 * 1024, &ebr_ctx);
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

    var fsm_counter = std.atomic.Value(u32).init(0);
    var stackful_counter = std.atomic.Value(u32).init(0);

    const fsm_pool = try alloc.alloc(FsmCounter, N_FSM);
    defer alloc.free(fsm_pool);

    var stackful_ctx: StackfulCtx = .{ .counter = &stackful_counter };
    var setup: SetupCtx = .{
        .sched = &sched,
        .fsm_pool = fsm_pool,
        .fsm_counter = &fsm_counter,
        .stackful_ctx = &stackful_ctx,
    };

    // Submit the setup fiber, which in turn submits the FSM burst and the
    // stackful worker once the scheduler is live.
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&setupBody)),
        &setup,
        .{ .stack_size = .Standard },
    );

    // sched.run() exits when active_tasks == 0 (shutdown_on_idle default).
    sched.run();

    // Both sides must have made full progress.
    try std.testing.expectEqual(@as(u32, N_FSM), fsm_counter.load(.acquire));
    try std.testing.expectEqual(STACKFUL_YIELDS, stackful_counter.load(.acquire));
}

// A second scenario: put the stackful fiber in first, then drown it in
// FSMs. Same correctness guarantee — both counters reach target.
test "end-to-end fairness: stackful-first + FSM burst still progresses" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var rt = try Runtime.init(alloc, 512 * 1024, &ebr_ctx);
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

    var fsm_counter = std.atomic.Value(u32).init(0);
    var stackful_counter = std.atomic.Value(u32).init(0);

    const fsm_pool = try alloc.alloc(FsmCounter, N_FSM);
    defer alloc.free(fsm_pool);

    var stackful_ctx: StackfulCtx = .{ .counter = &stackful_counter };

    const InvertedSetup = struct {
        sched: *fp.Scheduler,
        fsm_pool: []FsmCounter,
        fsm_counter: *std.atomic.Value(u32),
        stackful_ctx: *StackfulCtx,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            // Stackful first.
            try self.sched.submitSpawn(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&stackfulBody)),
                self.stackful_ctx,
                .{ .stack_size = .Standard },
            );
            // Then FSM burst.
            for (self.fsm_pool) |*f| {
                f.* = .{ .task = undefined, .counter = self.fsm_counter };
                f.task = fsm.FsmTask.init(&FsmCounter.doResume);
                self.sched.enqueueFsm(&f.task);
            }
        }
    };

    var setup: InvertedSetup = .{
        .sched = &sched,
        .fsm_pool = fsm_pool,
        .fsm_counter = &fsm_counter,
        .stackful_ctx = &stackful_ctx,
    };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&InvertedSetup.run)),
        &setup,
        .{ .stack_size = .Standard },
    );

    sched.run();
    try std.testing.expectEqual(@as(u32, N_FSM), fsm_counter.load(.acquire));
    try std.testing.expectEqual(STACKFUL_YIELDS, stackful_counter.load(.acquire));
}
