// fsm-benchmark-test.zig — FSM vs stackful task performance comparison.
//
// Measures three things:
//   1. Per-task memory footprint (static struct size)
//   2. Per-task spawn+dispatch wall-clock
//   3. Throughput: tasks/sec under matched workloads
//
// The comparison isolates what FSM tasks are supposed to win on: no
// fiber stack, no assembly context switch. Both sides dispatch a body
// that is either a trivial "return Done" or ~100 integer adds.
//
// Batched: both sides submit in batches of BATCH tasks, dispatch to
// completion, then submit the next batch. Keeps the stackful SPSC ring
// (4 K slots) from filling before the scheduler drains it.
//
// Skipped in Debug builds (numbers only meaningful in ReleaseFast).
// Prints results through std.debug.print so they show up in test output.

const std = @import("std");
const builtin = @import("builtin");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const fc = @import("fiber-core.zig");
const qs = @import("queues.zig");
const ebr = @import("../lib/ebr.zig");
const compat = @import("../lib/compat.zig");
const fsm = @import("fsm.zig");
const runtime_hdr = @import("runtime-header.zig");

const BATCH: usize = 2048;
const N_BATCHES: usize = 50;
const TOTAL: usize = BATCH * N_BATCHES;
const COMPUTE_ADDS: u32 = 100;

// ---------------------------------------------------------------------------
// FSM side
// ---------------------------------------------------------------------------

const FsmState = struct {
    task: fsm.FsmTask,
    acc: u64 = 0,

    fn doResumeCompute(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *FsmState = @fieldParentPtr("task", t);
        var i: u32 = 0;
        while (i < COMPUTE_ADDS) : (i += 1) self.acc += i;
        return .{ .Done = {} };
    }

    fn doResumeEmpty(t: *fsm.FsmTask) fsm.YieldReason {
        _ = t;
        return .{ .Done = {} };
    }
};

// ---------------------------------------------------------------------------
// Stackful side
// ---------------------------------------------------------------------------

const StackfulState = struct {
    acc: u64 = 0,
};

fn stackfulBodyCompute(rt: *anyopaque, ctx: ?*anyopaque) anyerror!void {
    _ = rt;
    const state: *StackfulState = @ptrCast(@alignCast(ctx.?));
    var i: u32 = 0;
    while (i < COMPUTE_ADDS) : (i += 1) state.acc += i;
}

fn stackfulBodyEmpty(rt: *anyopaque, ctx: ?*anyopaque) anyerror!void {
    _ = rt;
    _ = ctx;
}

// ---------------------------------------------------------------------------
// Runners (batched)
// ---------------------------------------------------------------------------

fn runFsmBatched(alloc: std.mem.Allocator, resume_fn: fsm.ResumeFn, label: []const u8) !u64 {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);
    var stack_pool = fm.StackPool.init(alloc);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &global_ebr, &stack_pool);
    defer sched.deinit();

    const states = try alloc.alloc(FsmState, BATCH);
    defer alloc.free(states);

    var total_acc: u64 = 0;
    const t0 = compat.nanoTimestamp();

    var batch: usize = 0;
    while (batch < N_BATCHES) : (batch += 1) {
        for (states) |*s| {
            s.* = .{ .task = undefined };
            s.task = fsm.FsmTask.init(resume_fn);
            sched.enqueueFsm(&s.task);
        }
        var iters: u32 = 0;
        while (sched.fsm_ready_queue.len() > 0) : (iters += 1) {
            sched.drainFsmQueue();
            if (iters > 100) return error.StalledQueue;
        }
        for (states) |s| {
            if (s.task.status != .Finished) return error.NotAllCompleted;
            total_acc += s.acc;
        }
    }

    const t1 = compat.nanoTimestamp();
    const ns: u64 = t1 - t0;
    const per_task_ns: f64 = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(TOTAL));
    std.debug.print("  FSM ({s}): {d} tasks in {d:.2}ms, {d:.1} ns/task, {d:.1}M tasks/sec (acc={d})\n", .{
        label,
        TOTAL,
        @as(f64, @floatFromInt(ns)) / 1_000_000.0,
        per_task_ns,
        1_000_000_000.0 / per_task_ns / 1_000_000.0,
        total_acc,
    });
    return ns;
}

fn runStackfulBatched(alloc: std.mem.Allocator, body: qs.TaskFn, label: []const u8) !u64 {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);
    var stack_pool = fm.StackPool.init(alloc);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &global_ebr, &stack_pool);
    defer sched.deinit();

    const states = try alloc.alloc(StackfulState, BATCH);
    defer alloc.free(states);

    var total_acc: u64 = 0;
    const t0 = compat.nanoTimestamp();

    var batch: usize = 0;
    while (batch < N_BATCHES) : (batch += 1) {
        for (states) |*s| s.* = .{};
        for (states) |*s| {
            try sched.submitSpawn(
                @intFromPtr(&runtime_hdr.Runtime.entryWrapper),
                body,
                s,
                .{ .stack_size = .Micro },
            );
        }
        sched.run();
        for (states) |s| total_acc += s.acc;
    }

    const t1 = compat.nanoTimestamp();
    const ns: u64 = t1 - t0;
    const per_task_ns: f64 = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(TOTAL));
    std.debug.print("  Stackful ({s}): {d} tasks in {d:.2}ms, {d:.1} ns/task, {d:.1}M tasks/sec (acc={d})\n", .{
        label,
        TOTAL,
        @as(f64, @floatFromInt(ns)) / 1_000_000.0,
        per_task_ns,
        1_000_000_000.0 / per_task_ns / 1_000_000.0,
        total_acc,
    });
    return ns;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "FSM vs Stackful: memory footprint" {
    std.debug.print("\n== Task struct size ==\n", .{});
    std.debug.print("  FsmTask           = {d} bytes\n", .{@sizeOf(fsm.FsmTask)});
    std.debug.print("  FsmState (full)   = {d} bytes\n", .{@sizeOf(FsmState)});
    std.debug.print("  qs.Task           = {d} bytes\n", .{@sizeOf(qs.Task)});
    std.debug.print("  fc.Fiber          = {d} bytes\n", .{@sizeOf(fc.Fiber)});
    std.debug.print("  Micro stack       = {d} bytes\n", .{fm.MICRO_STACK_SIZE});
    const fsm_footprint = @sizeOf(FsmState);
    const stackful_footprint = @sizeOf(qs.Task) + @sizeOf(fc.Fiber) + fm.MICRO_STACK_SIZE;
    std.debug.print("  Per-task total:   FSM={d} B  Stackful={d} B  ratio={d:.1}x\n\n", .{
        fsm_footprint,
        stackful_footprint,
        @as(f64, @floatFromInt(stackful_footprint)) / @as(f64, @floatFromInt(fsm_footprint)),
    });
    try std.testing.expect(fsm_footprint < stackful_footprint);
}

test "FSM vs Stackful: empty body (spawn + complete, no work)" {
    if (builtin.mode == .Debug) return error.SkipZigTest;
    std.debug.print("\n== Empty body ({d} tasks = {d} batches of {d}) ==\n", .{ TOTAL, N_BATCHES, BATCH });
    const alloc = std.heap.c_allocator;
    const fsm_ns = try runFsmBatched(alloc, &FsmState.doResumeEmpty, "empty");
    const stack_ns = try runStackfulBatched(alloc, @ptrCast(&stackfulBodyEmpty), "empty");
    std.debug.print("  FSM speedup: {d:.2}x\n", .{@as(f64, @floatFromInt(stack_ns)) / @as(f64, @floatFromInt(fsm_ns))});
    try std.testing.expect(fsm_ns < stack_ns);
}

test "FSM vs Stackful: compute body (100 integer adds each)" {
    if (builtin.mode == .Debug) return error.SkipZigTest;
    std.debug.print("\n== Compute body ({d} tasks, {d} adds each) ==\n", .{ TOTAL, COMPUTE_ADDS });
    const alloc = std.heap.c_allocator;
    const fsm_ns = try runFsmBatched(alloc, &FsmState.doResumeCompute, "compute");
    const stack_ns = try runStackfulBatched(alloc, @ptrCast(&stackfulBodyCompute), "compute");
    std.debug.print("  FSM speedup: {d:.2}x\n", .{@as(f64, @floatFromInt(stack_ns)) / @as(f64, @floatFromInt(fsm_ns))});
    try std.testing.expect(fsm_ns < stack_ns);
}

// ---------------------------------------------------------------------------
// Cross-scheduler submission comparison: submitFsmSpawn vs submitSpawn.
//
// Measures the cost of putting work onto another scheduler's queue via
// SPSC — the same path a compiler-emitted BG block would take when
// spawnFsmBest / spawnFsmOn picks a different scheduler. Isolates the
// message-routing cost from the dispatch cost.
//
// FSM side is self-contained (drain on main thread). Stackful cross-
// scheduler benchmarking requires a dedicated multi-thread harness
// because the target scheduler's run() must be spun on its own thread
// with the scheduler_running / active_scheduler globals set up; that's
// straightforward to build but out of scope here. The in-scheduler
// comparison above already demonstrates the FSM perf win; SPSC
// correctness for FSM is covered by fsm-cross-scheduler-test.zig.
// ---------------------------------------------------------------------------

const CROSS_N: usize = 4096; // one full SPSC ring, no drain mid-submit

fn runCrossSpawnFsm(alloc: std.mem.Allocator) !u64 {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);
    var pool_a = fm.StackPool.init(alloc);
    defer pool_a.deinit();
    var pool_b = fm.StackPool.init(alloc);
    defer pool_b.deinit();
    var sender = try fp.Scheduler.init(alloc, &global_ebr, &pool_a);
    defer sender.deinit();
    var target = try fp.Scheduler.init(alloc, &global_ebr, &pool_b);
    defer target.deinit();
    defer fp.global_registry.deinit(alloc);
    try fp.global_registry.register(alloc, 9_001, &sender);
    try fp.global_registry.register(alloc, 9_002, &target);
    defer fp.global_registry.unregister(9_001);
    defer fp.global_registry.unregister(9_002);

    const states = try alloc.alloc(FsmState, CROSS_N);
    defer alloc.free(states);

    const t0 = compat.nanoTimestamp();
    for (states) |*s| {
        s.* = .{ .task = undefined };
        s.task = fsm.FsmTask.init(&FsmState.doResumeEmpty);
        try target.submitFsmSpawn(&s.task);
    }
    target.drainChannels();
    // drainFsmQueue processes up to FSM_DRAIN_BATCH (64) tasks per call;
    // loop until the queue is empty so all 4096 tasks complete.
    while (target.fsm_ready_queue.len() > 0) target.drainFsmQueue();
    const t1 = compat.nanoTimestamp();

    for (states) |s| if (s.task.status != .Finished) return error.NotAllCompleted;
    const ns: u64 = t1 - t0;
    const per_task_ns: f64 = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(CROSS_N));
    std.debug.print("  FSM cross-spawn: {d} tasks in {d:.2}ms, {d:.1} ns/task\n", .{
        CROSS_N,
        @as(f64, @floatFromInt(ns)) / 1_000_000.0,
        per_task_ns,
    });
    return ns;
}

test "FSM cross-scheduler spawn throughput (self-contained)" {
    if (builtin.mode == .Debug) return error.SkipZigTest;
    std.debug.print("\n== FSM cross-scheduler spawn ({d} tasks through SPSC) ==\n", .{CROSS_N});
    const alloc = std.heap.c_allocator;
    const fsm_ns = try runCrossSpawnFsm(alloc);
    _ = fsm_ns;
}

// ---------------------------------------------------------------------------
// Work-stealing benchmark: skewed load + siblingsteal.
//
// All tasks are pushed to scheduler A. Baseline drains from A alone.
// Stealing variant has scheduler B steal half, then both drain in
// parallel (simulated by alternating drain calls on one thread since
// real multi-thread scheduler harness is complex). Wall-clock ratio
// tells us whether stealing is pulling its weight under skew.
// ---------------------------------------------------------------------------

const STEAL_N: usize = 20_000;

fn runStealBaseline(alloc: std.mem.Allocator) !u64 {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &global_ebr, &pool);
    defer sched.deinit();

    const states = try alloc.alloc(FsmState, STEAL_N);
    defer alloc.free(states);

    const t0 = compat.nanoTimestamp();
    for (states) |*s| {
        s.* = .{ .task = undefined };
        s.task = fsm.FsmTask.init(&FsmState.doResumeCompute);
        sched.enqueueFsm(&s.task);
    }
    var iters: u32 = 0;
    while (sched.fsm_ready_queue.len() > 0) : (iters += 1) {
        sched.drainFsmQueue();
        if (iters > (STEAL_N / 64) + 200) return error.StalledQueue;
    }
    const t1 = compat.nanoTimestamp();
    return t1 - t0;
}

fn runStealWithSibling(alloc: std.mem.Allocator) !u64 {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);
    var pool_a = fm.StackPool.init(alloc);
    defer pool_a.deinit();
    var pool_b = fm.StackPool.init(alloc);
    defer pool_b.deinit();
    var a = try fp.Scheduler.init(alloc, &global_ebr, &pool_a);
    defer a.deinit();
    var b = try fp.Scheduler.init(alloc, &global_ebr, &pool_b);
    defer b.deinit();

    const states = try alloc.alloc(FsmState, STEAL_N);
    defer alloc.free(states);

    const t0 = compat.nanoTimestamp();
    for (states) |*s| {
        s.* = .{ .task = undefined };
        s.task = fsm.FsmTask.init(&FsmState.doResumeCompute);
        a.enqueueFsm(&s.task);
    }

    // Simulate cooperative sibling: every few drain passes on A, B steals
    // half of whatever's left. Not multi-threaded — single-thread
    // alternation demonstrates the mechanism without OS-thread overhead.
    var iters: u32 = 0;
    while (a.fsm_ready_queue.len() > 0 or b.fsm_ready_queue.len() > 0) : (iters += 1) {
        a.drainFsmQueue();
        if (b.fsm_ready_queue.len() == 0 and a.fsm_ready_queue.len() > 64) {
            const stolen = b.fsm_ready_queue.tryStealFrom(&a.fsm_ready_queue, alloc);
            _ = b.active_tasks.fetchAdd(stolen, .monotonic);
            _ = a.active_tasks.fetchSub(stolen, .monotonic);
        }
        b.drainFsmQueue();
        if (iters > (STEAL_N / 64) + 500) return error.StalledQueue;
    }
    const t1 = compat.nanoTimestamp();

    for (states) |s| {
        if (s.task.status != .Finished) return error.NotAllCompleted;
    }
    return t1 - t0;
}

test "FSM work-stealing: skewed load with sibling steal" {
    if (builtin.mode == .Debug) return error.SkipZigTest;
    std.debug.print("\n== FSM work-stealing under skew ({d} compute tasks on A) ==\n", .{STEAL_N});
    const alloc = std.heap.c_allocator;
    const baseline_ns = try runStealBaseline(alloc);
    const steal_ns = try runStealWithSibling(alloc);
    std.debug.print("  Baseline (A only):     {d:.2}ms\n", .{
        @as(f64, @floatFromInt(baseline_ns)) / 1_000_000.0,
    });
    std.debug.print("  With sibling steal:    {d:.2}ms\n", .{
        @as(f64, @floatFromInt(steal_ns)) / 1_000_000.0,
    });
    std.debug.print("  Note: single-thread alternation; real benefit scales with actual cores.\n", .{});
}
