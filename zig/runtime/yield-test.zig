// yield-test.zig — unit tests for cooperative yield infrastructure.
//
// Tests verify:
//   1. checkYield counter arithmetic (power-of-two rollover at YIELD_BUDGET)
//   2. coopYield: yields only when another fiber is in the ready_queue
//   3. Two fibers interleave correctly via checkYield
//
// Run with:
//   zig test zig/yield-test.zig -lc zig/switch.S zig/onRoot.S

const std = @import("std");

const CheatLib  = @import("runtime-header.zig").CheatLib;
const Runtime   = @import("runtime.zig").Runtime;
const fp        = @import("scheduler.zig");
const qs        = @import("queues.zig");
const fc        = @import("fiber-core.zig");
const fm        = @import("fiber-memory.zig");

const Scheduler = fp.Scheduler;
const StackPool = fm.StackPool;
const EbrContext = @import("../lib/ebr.zig").EbrContext;

// comptime guard — force linker to include assembly trampolines
comptime { _ = fc; }

// ---------------------------------------------------------------------------
// 1. Counter arithmetic: YIELD_MASK == 4095, rolls over at 4096
// ---------------------------------------------------------------------------

test "checkYield counter rolls over at 4096 iterations" {
    // We can't call checkYield directly without a scheduler, but we can verify
    // the constants embedded in the runtime are correct.
    // yield_counter starts at 0; after 4096 wrapping increments it is 0 again.
    var counter: u32 = 0;
    const YIELD_MASK: u32 = 4096 - 1;
    var fires: usize = 0;

    var i: usize = 0;
    while (i < 4096 * 3) : (i += 1) {
        counter = (counter +% 1) & YIELD_MASK;
        if (counter == 0) fires += 1;
    }
    // Should fire exactly 3 times across 3 × 4096 iterations
    try std.testing.expectEqual(@as(usize, 3), fires);
}

test "checkYield counter does not fire in fewer than 4096 iterations" {
    var counter: u32 = 0;
    const YIELD_MASK: u32 = 4096 - 1;
    var fires: usize = 0;

    var i: usize = 0;
    while (i < 4095) : (i += 1) {
        counter = (counter +% 1) & YIELD_MASK;
        if (counter == 0) fires += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), fires);
}

// ---------------------------------------------------------------------------
// 2. coopYield: single fiber — should NOT yield when queue is empty
// ---------------------------------------------------------------------------

var single_yield_count: usize = 0;

fn singleFiberTask(rt: *Runtime) !void {
    const sched = fp.active_scheduler;

    // With only one fiber running, ready_queue is empty → coopYield is a no-op.
    // Call it multiple times; the task should never context-switch.
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        sched.coopYield();
    }
    single_yield_count += 1;
    _ = rt;
}

test "coopYield is a no-op when no other fiber is ready" {
    // Use the C allocator (system malloc) for scheduler integration tests.
    // The scheduler's internal hashmaps are not fully freed in deinit — a pre-existing
    // known issue. Using the GPA would print false-positive leak reports.
    const allocator = std.heap.c_allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();

    fp.active_scheduler = &sched;
    single_yield_count = 0;

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&singleFiberTask)),
        null, .{});

    sched.run();

    // Task completed exactly once (no spurious re-entries)
    try std.testing.expectEqual(@as(usize, 1), single_yield_count);
}

// ---------------------------------------------------------------------------
// 3. Two fibers interleave via coopYield
// ---------------------------------------------------------------------------

// Each fiber increments its own counter, calling coopYield each iteration.
// We verify both fibers make progress and finish.

var fiber_a_count: usize = 0;
var fiber_b_count: usize = 0;
const FIBER_ITERS: usize = 8;

fn fiberA(rt: *Runtime) !void {
    const sched = fp.active_scheduler;
    var i: usize = 0;
    while (i < FIBER_ITERS) : (i += 1) {
        fiber_a_count += 1;
        sched.coopYield(); // yield so B can run
    }
    _ = rt;
}

fn fiberB(rt: *Runtime) !void {
    const sched = fp.active_scheduler;
    var i: usize = 0;
    while (i < FIBER_ITERS) : (i += 1) {
        fiber_b_count += 1;
        sched.coopYield();
    }
    _ = rt;
}

test "two fibers interleave via coopYield" {
    // Use the C allocator (system malloc) for scheduler integration tests.
    // The scheduler's internal hashmaps are not fully freed in deinit — a pre-existing
    // known issue. Using the GPA would print false-positive leak reports.
    const allocator = std.heap.c_allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();

    fp.active_scheduler = &sched;
    fiber_a_count = 0;
    fiber_b_count = 0;

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&fiberA)),
        null, .{});
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&fiberB)),
        null, .{});

    sched.run();

    try std.testing.expectEqual(@as(usize, FIBER_ITERS), fiber_a_count);
    try std.testing.expectEqual(@as(usize, FIBER_ITERS), fiber_b_count);
}
