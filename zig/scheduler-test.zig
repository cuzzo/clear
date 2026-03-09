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
// TEST 1: Integration Test (Wakeup Logic)
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

// -------------------------------------------------------------------------
// TEST 2: Multi-Threaded "Hammer" Integration Test
// -------------------------------------------------------------------------
// This test spawns N real OS threads, each running a Scheduler.
// It spawns a "Root Task" which then spawns thousands of "Worker Tasks".
// All workers signal a single WaitGroup.
// This validates:
//  1. Cross-thread wakeup (EventFD)
//  2. Work Stealing (Load balancing)
//  3. Atomic correctness of WaitGroup under heavy contention
//  4. Clean shutdown of the Scheduler cluster

const HammerContext = struct {
    wg: *WaitGroup,
    counter: *std.atomic.Value(usize),
};

// Updated to match TaskFn signature: fn(*anyopaque, ?*anyopaque) anyerror!void
fn hammerWorker(_: *anyopaque, args: ?*anyopaque) anyerror!void {
    const ctx: *HammerContext = @ptrCast(@alignCast(args));

    // 1. Simulate a tiny bit of CPU work to encourage interleaving
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        std.mem.doNotOptimizeAway(i);
    }

    // 2. Atomic Increment (Proof of work)
    _ = ctx.counter.fetchAdd(1, .seq_cst);

    // 3. Signal Done (This hits the WaitGroup lock)
    ctx.wg.done();
}

// Updated to match TaskFn signature
fn hammerRoot(_: *anyopaque, args: ?*anyopaque) anyerror!void {
    const ctx: *HammerContext = @ptrCast(@alignCast(args));
    const WORKER_COUNT = 10_000;

    std.debug.print("\n[Hammer] Spawning {d} workers...", .{WORKER_COUNT});

    // 1. Register intent to wait
    ctx.wg.add(WORKER_COUNT);

    // 2. Spawn loop
    const current_sched = scheduler.active_scheduler;

    var i: usize = 0;
    while (i < WORKER_COUNT) : (i += 1) {
        // We use Runtime.entryWrapper (or similar) as the trampoline.
        // We pass 'ctx' as the argument.
        try current_sched.submitSpawn(
            @intFromPtr(&Runtime.entryWrapper),
            hammerWorker,
            ctx,
            .{}
        );
    }

    std.debug.print("\n[Hammer] Waiting for completion...", .{});

    // 3. Block until all workers are done
    ctx.wg.wait();

    std.debug.print("\n[Hammer] All workers returned!", .{});
}

fn runSchedulerThread(sched: *Scheduler) void {
    // CRITICAL: Set thread-local so tasks can find the scheduler
    scheduler.active_scheduler = sched;
    sched.run();
}

test "Scheduler: Multi-Threaded Hammer (Work Stealing & Sync)" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    std.debug.print("\n--- Start Multi-Threaded Hammer Test ---", .{});

    // 1. Setup Global Resources
    var global_ctx = ebr.EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = memory.StackPool.init(allocator);
    defer stack_pool.deinit();

    // 2. Reset Registry
    {
        scheduler.global_registry.mutex.lock();
        defer scheduler.global_registry.mutex.unlock();

        // We simply overwrite the map with a fresh, empty state.
        // We assume the previous test called deinit() on the old map (which it did).
        // If we try to call deinit() or clearAndFree() on the old map here,
        // we panic because it's already dead.
        scheduler.global_registry.map = .{};
    }
    defer {
        scheduler.global_registry.mutex.lock();
        scheduler.global_registry.map.deinit(allocator);
        scheduler.global_registry.mutex.unlock();
    }

    // 3. Create Scheduler Cluster
    const THREAD_COUNT = 4;
    var scheds: [THREAD_COUNT]*Scheduler = undefined;
    var threads: [THREAD_COUNT]std.Thread = undefined;

    for (0..THREAD_COUNT) |i| {
        const s = try allocator.create(Scheduler);
        s.* = try Scheduler.init(allocator, &global_ctx, &stack_pool);
        s.shutdown_on_idle = true;
        scheds[i] = s;
    }

    // 4. Prepare Test Data
    var wg = WaitGroup.init(scheds[0]);
    var atomic_counter = std.atomic.Value(usize).init(0);

    var context = HammerContext{
        .wg = &wg,
        .counter = &atomic_counter,
    };

    // 5. Submit Root Task to Scheduler[0]
    try scheds[0].submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        hammerRoot,
        &context,
        .{}
    );

    // 6. Start Threads
    for (0..THREAD_COUNT) |i| {
        threads[i] = try std.Thread.spawn(.{}, runSchedulerThread, .{scheds[i]});
    }

    // 7. Wait for Shutdown
    for (threads) |t| {
        t.join();
    }

    // 8. Verification
    const final_count = atomic_counter.load(.seq_cst);
    std.debug.print("\n[Hammer] Final Counter: {d}\n", .{final_count});

    // Cleanup
    for (scheds) |s| {
        s.deinit();
        allocator.destroy(s);
    }

    try testing.expectEqual(@as(usize, 10_000), final_count);
    try testing.expectEqual(@as(usize, 0), wg.counter.load(.seq_cst));
}


// -------------------------------------------------------------------------
// TEST: getLeastLoaded — picks scheduler with fewest active_tasks
// -------------------------------------------------------------------------

test "SchedulerRegistry.getLeastLoaded returns null for empty registry" {
    var reg: scheduler.SchedulerRegistry = .{};
    defer reg.deinit(std.testing.allocator);

    const result = reg.getLeastLoaded();
    try testing.expect(result == null);
}

test "SchedulerRegistry.getLeastLoaded returns the only registered scheduler" {
    const allocator = std.testing.allocator;
    var reg: scheduler.SchedulerRegistry = .{};
    defer reg.deinit(allocator);

    // Create a minimal scheduler struct — only active_tasks matters for getLeastLoaded.
    var sched_a: Scheduler = undefined;
    sched_a.active_tasks = std.atomic.Value(usize).init(5);

    // Register under a fake thread ID.
    try reg.register(allocator, @as(std.Thread.Id, @intCast(1001)), &sched_a);

    const result = reg.getLeastLoaded();
    try testing.expect(result != null);
    try testing.expectEqual(&sched_a, result.?);
}

test "SchedulerRegistry.getLeastLoaded picks the less-loaded of two schedulers" {
    const allocator = std.testing.allocator;
    var reg: scheduler.SchedulerRegistry = .{};
    defer reg.deinit(allocator);

    var sched_busy: Scheduler = undefined;
    sched_busy.active_tasks = std.atomic.Value(usize).init(10);

    var sched_idle: Scheduler = undefined;
    sched_idle.active_tasks = std.atomic.Value(usize).init(2);

    try reg.register(allocator, @as(std.Thread.Id, @intCast(2001)), &sched_busy);
    try reg.register(allocator, @as(std.Thread.Id, @intCast(2002)), &sched_idle);

    const result = reg.getLeastLoaded();
    try testing.expect(result != null);
    // Must pick the idle scheduler (load = 2), not the busy one (load = 10).
    try testing.expectEqual(&sched_idle, result.?);
}

test "SchedulerRegistry.getLeastLoaded handles zero-load schedulers (tie: returns one)" {
    const allocator = std.testing.allocator;
    var reg: scheduler.SchedulerRegistry = .{};
    defer reg.deinit(allocator);

    var sched_a: Scheduler = undefined;
    sched_a.active_tasks = std.atomic.Value(usize).init(0);

    var sched_b: Scheduler = undefined;
    sched_b.active_tasks = std.atomic.Value(usize).init(0);

    try reg.register(allocator, @as(std.Thread.Id, @intCast(3001)), &sched_a);
    try reg.register(allocator, @as(std.Thread.Id, @intCast(3002)), &sched_b);

    const result = reg.getLeastLoaded();
    try testing.expect(result != null);
    // Either is acceptable when tied; just verify it returns one of them.
    const is_a = result.? == &sched_a;
    const is_b = result.? == &sched_b;
    try testing.expect(is_a or is_b);
}
