// semaphore-test.zig
// Unit tests for CheatHeader.Semaphore — fiber-aware counting semaphore.
//
// Run with:
//   zig test zig/semaphore-test.zig -lc zig/switch.S zig/onRoot.S
const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;
const fm = @import("fiber-memory.zig");
const fp = @import("scheduler.zig");

// ---------------------------------------------------------------------------
// Shared test setup helper — returns a configured scheduler.
// Caller is responsible for deferring sched.deinit() and fp.global_registry.deinit().
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Test 1: basic acquire / release — counter goes 2 → 0 → 2
// ---------------------------------------------------------------------------
test "Semaphore.acquire decrements counter; release increments it" {
    const t_alloc = std.testing.allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(t_alloc);

    var rt = try Runtime.init(t_alloc, 1024 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    var stack_pool = fm.StackPool.init(t_alloc);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(t_alloc, &global_ctx, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(t_alloc);
    }
    fp.active_scheduler = &sched;

    const Ctx = struct {
        sem: CheatHeader.Semaphore,
        counter_after: usize = 0,
    };
    var ctx = Ctx{ .sem = CheatHeader.Semaphore.init(2, &sched) };

    const TestRunner = struct {
        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            _ = raw_rt;
            const c = @as(*Ctx, @ptrCast(@alignCast(raw_args.?)));
            // Two acquires should succeed without blocking (counter: 2 -> 1 -> 0)
            c.sem.acquire();
            c.sem.acquire();
            // Two releases (counter: 0 -> 1 -> 2)
            c.sem.release();
            c.sem.release();
            c.counter_after = c.sem.counter.load(.seq_cst);
        }
    };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&TestRunner.run)),
        &ctx,
        .{},
    );
    sched.run();
    try std.testing.expectEqual(@as(usize, 2), ctx.counter_after);
}

// ---------------------------------------------------------------------------
// Test 2: pool_size limits concurrency — all tasks complete within pool_size.
// ---------------------------------------------------------------------------
test "Semaphore limits concurrent fibers to pool_size (all tasks complete)" {
    const t_alloc = std.testing.allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(t_alloc);

    var rt = try Runtime.init(t_alloc, 1024 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    var stack_pool = fm.StackPool.init(t_alloc);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(t_alloc, &global_ctx, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(t_alloc);
    }
    fp.active_scheduler = &sched;

    const POOL_SIZE: usize = 2;
    const NUM_TASKS: usize = 6;

    const SharedState = struct {
        sem: CheatHeader.Semaphore,
        wg: CheatHeader.WaitGroup,
        completed: std.atomic.Value(usize),
    };

    const TaskCtx = struct {
        state: *SharedState,
    };

    var state = SharedState{
        .sem = CheatHeader.Semaphore.init(POOL_SIZE, &sched),
        .wg = CheatHeader.WaitGroup.init(&sched),
        .completed = std.atomic.Value(usize).init(0),
    };

    var task_ctxs: [NUM_TASKS]TaskCtx = undefined;
    for (&task_ctxs) |*tc| tc.* = .{ .state = &state };

    const Worker = struct {
        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            _ = raw_rt;
            const tc = @as(*TaskCtx, @ptrCast(@alignCast(raw_args.?)));
            defer tc.state.wg.done();
            defer tc.state.sem.release();
            _ = tc.state.completed.fetchAdd(1, .seq_cst);
        }
    };

    const MainRunner = struct {
        state_ptr: *SharedState,
        ctxs_ptr: []TaskCtx,

        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            _ = raw_rt;
            self.state_ptr.wg.add(NUM_TASKS);
            for (self.ctxs_ptr) |*tc| {
                self.state_ptr.sem.acquire();
                try fp.active_scheduler.submitSpawn(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&Worker.run)),
                    tc,
                    .{},
                );
            }
            self.state_ptr.wg.wait();
        }
    };

    var runner = MainRunner{ .state_ptr = &state, .ctxs_ptr = &task_ctxs };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&MainRunner.run)),
        &runner,
        .{},
    );
    sched.run();

    try std.testing.expectEqual(NUM_TASKS, state.completed.load(.seq_cst));
}

// ---------------------------------------------------------------------------
// Test 3: blocking and waking — fiber blocks when counter=0, wakes on release.
// ---------------------------------------------------------------------------
test "Semaphore blocks acquirer when exhausted and wakes it on release" {
    const t_alloc = std.testing.allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(t_alloc);

    var rt = try Runtime.init(t_alloc, 1024 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    var stack_pool = fm.StackPool.init(t_alloc);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(t_alloc, &global_ctx, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(t_alloc);
    }
    fp.active_scheduler = &sched;

    const Shared = struct {
        sem: CheatHeader.Semaphore,
        wg: CheatHeader.WaitGroup,
        sequence: std.atomic.Value(usize),
    };

    var shared = Shared{
        .sem = CheatHeader.Semaphore.init(1, &sched),
        .wg = CheatHeader.WaitGroup.init(&sched),
        .sequence = std.atomic.Value(usize).init(0),
    };

    // Acquirer: acquires once (succeeds), then again (should block until Releaser fires).
    const Acquirer = struct {
        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            _ = raw_rt;
            const s = @as(*Shared, @ptrCast(@alignCast(raw_args.?)));
            defer s.wg.done();
            s.sem.acquire(); // succeeds immediately (counter 1->0)
            _ = s.sequence.fetchAdd(1, .seq_cst); // sequence = 1
            s.sem.acquire(); // blocks (counter is 0)
            _ = s.sequence.fetchAdd(10, .seq_cst); // sequence = 11 after wake
            s.sem.release();
            s.sem.release();
        }
    };

    // Releaser: yields first to let Acquirer run, then releases.
    const Releaser = struct {
        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            _ = raw_rt;
            const s = @as(*Shared, @ptrCast(@alignCast(raw_args.?)));
            defer s.wg.done();
            // yield so Acquirer runs first and blocks on second acquire
            fp.active_scheduler.getCurrent().base.yield();
            _ = s.sequence.fetchAdd(100, .seq_cst); // sequence = 101
            s.sem.release(); // wake the blocked Acquirer
        }
    };

    const Main = struct {
        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            _ = raw_rt;
            const s = @as(*Shared, @ptrCast(@alignCast(raw_args.?)));
            s.wg.add(2);
            try fp.active_scheduler.submitSpawn(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&Acquirer.run)),
                s,
                .{},
            );
            try fp.active_scheduler.submitSpawn(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&Releaser.run)),
                s,
                .{},
            );
            s.wg.wait();
        }
    };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&Main.run)),
        &shared,
        .{},
    );
    sched.run();

    // Expected: sequence = 1 + 100 + 10 = 111
    // (Acquirer increments 1, Releaser increments 100, Acquirer-after-wake increments 10)
    try std.testing.expectEqual(@as(usize, 111), shared.sequence.load(.seq_cst));
}
