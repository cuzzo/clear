const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

// Adjust these imports to point to your actual files
const fiber_core = @import("fiber-core.zig");
const scheduler = @import("scheduler.zig");
const queues = @import("queues.zig");
const memory = @import("fiber-memory.zig");
const ebr = @import("ebr.zig");

// Assuming WaitGroup is now in sync.zig or scheduler.zig
// Adjust this import to where you placed the new struct
const WaitGroup = scheduler.WaitGroup;
const Scheduler = scheduler.Scheduler;
const Runtime = @import("runtime.zig").Runtime;

// -------------------------------------------------------------------------
// TEST 1: The "Hammer" Test (Atomic Correctness)
// -------------------------------------------------------------------------
// This runs on raw OS threads. It proves that 'done()' never misses a decrement.
// It relies on a "Mock" scheduler just to satisfy the struct initialization,
// but we never call 'wait()', so the scheduler is never touched.

test "WaitGroup: Thread-Safe Atomic Decrement" {
    // 1. Setup
    // We cast a null pointer to *Scheduler because we won't use it in this test.
    // We only test add/done logic here.
    const mock_sched = @as(*Scheduler, @ptrFromInt(0xDEADBEE0)); // Aligned dummy

    var wg = WaitGroup.init(mock_sched);

    const THREADS = 10;
    const LOOPS = 100_000;

    // We are adding 1 million items to the counter
    wg.add(THREADS * LOOPS);

    const Worker = struct {
        fn run(ptr: *WaitGroup, count: usize) void {
            for (0..count) |_| {
                ptr.done();
            }
        }
    };

    // 2. Spawn Threads to hammer the counter
    var threads: [THREADS]std.Thread = undefined;
    for (0..THREADS) |i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{ &wg, LOOPS });
    }

    // 3. Join
    for (threads) |t| t.join();

    // 4. Verify
    // If the old race condition existed, this would be > 0
    std.debug.print("\n[Atomic Test] Final Counter: {d}\n", .{wg.counter.load(.seq_cst)});
    try testing.expectEqual(@as(usize, 0), wg.counter.load(.seq_cst));
}


// -------------------------------------------------------------------------
// TEST 2: Integration Test (Wakeup Logic)
// -------------------------------------------------------------------------
// This runs inside your Runtime. It verifies that a task actually blocks
// and gets woken up by another task.

var global_wg: WaitGroup = undefined;
var wakeup_time: i64 = 0;

fn waiterTask(_: *Runtime) !void {
    std.debug.print("\n[Waiter] Waiting for workers...", .{});

    // This should Yield the fiber until the counter hits 0
    global_wg.wait();

    wakeup_time = std.time.milliTimestamp();
    std.debug.print("\n[Waiter] Unblocked!", .{});
}

fn workerTask(rt: *Runtime) !void {
    // Simulate work
    rt.sleep(50);
    std.debug.print("\n[Worker] Done.", .{});
    global_wg.done();
}

test "WaitGroup: Integration (Block & Wake)" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    // 1. Boilerplate Runtime Setup
    var global_ctx = ebr.EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = memory.StackPool.init(allocator);
    defer stack_pool.deinit();

    defer {
        scheduler.global_registry.mutex.lock();
        scheduler.global_registry.map.deinit(allocator);
        scheduler.global_registry.mutex.unlock();
    }

    var sched = try Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();

    // Register as active for this thread
    scheduler.active_scheduler = &sched;

    // 2. Initialize WaitGroup linked to this scheduler
    global_wg = WaitGroup.init(&sched);
    global_wg.add(1); // One worker

    std.debug.print("\n--- Start Integration Test ---", .{});
    const start_time = std.time.milliTimestamp();

    // 3. Spawn Waiter
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(queues.TaskFn, @ptrCast(&waiterTask)),
        null,
        .{}
    );

    // 4. Spawn Worker
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(queues.TaskFn, @ptrCast(&workerTask)),
        null,
        .{}
    );

    // 5. Run
    // We run until there are no tasks left.
    // In a real loop, you'd have a better exit condition, but for tests,
    // we can rely on run() returning if you set shutdown_on_idle = true (default).
    sched.run();

    // 6. Verification
    // Ensure the waiter actually waited (wakeup time should be after start + sleep)
    const elapsed = wakeup_time - start_time;
    std.debug.print("\n--- Elapsed: {d}ms ---\n", .{elapsed});

    try testing.expect(elapsed >= 50); // It must have waited for the worker
    try testing.expectEqual(@as(usize, 0), global_wg.counter.load(.seq_cst));
}

