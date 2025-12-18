const std = @import("std");
const crt = @import("runtime-header.zig");
const Runtime = crt.Runtime;
const Stack = crt.Stack;
const Fiber = crt.Fiber;
const Context = crt.Context;
const EbrContext = crt.EbrContext;
const Scheduler = crt.Scheduler;
const WaitGroup = crt.WaitGroup;


// Stack

test "Stack Allocation and Permissions" {
    // 1. Create a 1MB Stack
    var stack = try Stack.init(1024 * 1024);
    defer stack.deinit();

    std.debug.print("\nStack allocated at: {X} -> {X}\n", .{
        @intFromPtr(stack.memory.ptr),
        @intFromPtr(stack.memory.ptr) + stack.memory.len
    });

    // 2. Prove we can use the top (Where the stack starts)
    const top = stack.getStackTop();
    const ptr = @as(*u64, @ptrFromInt(top));
    ptr.* = 0xDEADBEEF;

    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), ptr.*);
    std.debug.print("Successfully wrote to stack top: {X}\n", .{top});

    // 3. Prove the Guard Page exists
    // The bottom of the memory slice is protected.
    // WARNING: Uncommenting this line will crash the test with a Segfault!
    // stack.memory[0] = 1;
}

// Fiber

// Global to store the main thread's context
var main_ctx: Context = undefined;
var my_fiber: Fiber = undefined;

// The function our fiber will run
fn fiberEntry() void {
    std.debug.print("\n[Fiber] Hello from the fiber stack!", .{});

    // Jump back to main
    std.debug.print("\n[Fiber] Yielding back...", .{});
    my_fiber.yield();

    // If we get here, main switched to us again!
    std.debug.print("\n[Fiber] I am back again!", .{});
    my_fiber.yield();
}

test "Context Switching" {
    std.debug.print("\n[Main] Initializing Fiber...", .{});

    // 1. Create Fiber pointing to our function
    // We cast the function pointer to usize to write it to the stack
    my_fiber = try Fiber.init(1024 * 1024, @intFromPtr(&fiberEntry));
    defer my_fiber.deinit();

    std.debug.print("\n[Main] Switching to Fiber...", .{});

    // 2. Switch to it (Save main_ctx, Load my_fiber.ctx)
    my_fiber.switchTo(&main_ctx);

    std.debug.print("\n[Main] Back in Main! Switching again...", .{});

    // 3. Switch back to resume where it left off
    my_fiber.switchTo(&main_ctx);

    std.debug.print("\n[Main] Done.", .{});
}


// We need to expose the global scheduler pointer for the test to link up
// (In your real app, manage this carefully)

fn userTask1(rt: *Runtime) !void {
    std.debug.print("\n[Task 1] Hello! My stack offset is: {d}", .{rt.stack_fba.end_index});

    // Simulate some work using the Runtime
    const ptr = rt.stack_fba.allocator().create(u64) catch unreachable;
    ptr.* = 12345;
    std.debug.print("\n[Task 1] Allocated data on fiber heap: {d}", .{ptr.*});
}

fn userTask2(_: *Runtime) !void {
    std.debug.print("\n[Task 2] Hello! I am a different task.", .{});
}

test "Full Scheduler Integration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // 1. Setup Global Context (EBR)
    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    // 2. Setup Scheduler
    var sched = Scheduler.init(allocator, &global_ctx);
    defer sched.deinit();

    // Link the global pointer (so entryWrapper can find us)
    crt.active_scheduler = &sched;

    std.debug.print("\n--- Spawning Tasks ---", .{});
    try sched.spawn(.{}, userTask1);
    try sched.spawn(.{}, userTask2);

    std.debug.print("\n--- Running Scheduler ---", .{});
    sched.run();

    std.debug.print("\n--- Finished ---", .{});
}


// Wait Group

var result_a: u64 = 0;
var result_b: u64 = 0;
var wg: WaitGroup = undefined;

// Worker A: Sleeps (yields) then sets a value
fn workerA(rt: *Runtime) !void {
    _ = rt;
    std.debug.print("\n[Worker A] Started. Doing work...", .{});

    // Simulate work by yielding once (optional, proves we can yield without breaking WG)
    crt.active_scheduler.getCurrent().base.yield();

    result_a = 100;
    std.debug.print("\n[Worker A] Done.", .{});
    wg.done();
}

// Worker B: Sets value immediately
fn workerB(rt: *Runtime) !void {
    _ = rt;
    std.debug.print("\n[Worker B] Started.", .{});
    result_b = 200;
    std.debug.print("\n[Worker B] Done.", .{});
    wg.done();
}

// Main Coordinator Task
fn mainTask(rt: *Runtime) !void {
    _ = rt;
    const sched = crt.active_scheduler;

    std.debug.print("\n[Main] Initializing WaitGroup...", .{});
    wg = WaitGroup.init(sched);
    wg.add(2);

    std.debug.print("\n[Main] Spawning workers...", .{});
    sched.spawn(.{}, workerA) catch unreachable;
    sched.spawn(.{}, workerB) catch unreachable;

    std.debug.print("\n[Main] Waiting (Blocking)...", .{});

    // THIS IS THE MAGIC:
    // This fiber will effectively "pause", allowing the scheduler
    // to run Worker A and B until they call wg.done().
    wg.wait();

    std.debug.print("\n[Main] Woke up!", .{});
}

test "Structured Concurrency with WaitGroup" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    var sched = Scheduler.init(allocator, &global_ctx);
    defer sched.deinit();

    crt.active_scheduler = &sched;

    std.debug.print("\n\n--- Start Concurrency Test ---", .{});

    // We spawn the main coordinator, which spawns the others
    try sched.spawn(.{}, mainTask);

    sched.run();

    std.debug.print("\n--- End Concurrency Test ---\n", .{});

    // Assertions
    try std.testing.expectEqual(@as(u64, 100), result_a);
    try std.testing.expectEqual(@as(u64, 200), result_b);
}

// Runaway Task

fn infiniteLoop(rt: *crt.Runtime) !void {
    std.debug.print("\n[Task] Starting infinite loop (Timeout: 10ms)...", .{});

    var i: usize = 0;
    while (true) {
        // [CRITICAL] This is the "Brakes".
        // Without this, the fiber would run forever (until OS preemption).
        try rt.checkpoint();

        // Burn some CPU
        i += 1;
        if (i % 100000 == 0) {
             // Yield occasionally to let the clock update
             // (In single-threaded schedulers, time only passes when we yield or check OS)
             // But std.time.milliTimestamp() is a syscall, so it works.
             crt.active_scheduler.getCurrent().base.yield();
        }
    }
}

test "Timeout Cancellation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var global_ctx = crt.EbrContext{};
    defer global_ctx.deinit(allocator);

    var sched = crt.Scheduler.init(allocator, &global_ctx);
    defer sched.deinit();
    crt.active_scheduler = &sched;

    std.debug.print("\n\n--- Start Timeout Test ---", .{});

    // Spawn with 10ms timeout
    try sched.spawn(.{ .timeout_ms = 10 }, infiniteLoop);

    const start = std.time.milliTimestamp();
    sched.run();
    const end = std.time.milliTimestamp();

    std.debug.print("\n--- End Timeout Test (Duration: {d}ms) ---\n", .{end - start});

    // It should finish reasonably quickly (e.g., < 50ms), definitely not hang.
}

// Sleeping Beauty Test

// Sleep for 100ms
fn fastTask(rt: *crt.Runtime) !void {
    std.debug.print("\n[Fast] Sleeping 100ms...", .{});
    rt.sleep(100);
    std.debug.print("\n[Fast] Woke up!", .{});
}

// Sleep for 300ms
fn slowTask(rt: *crt.Runtime) !void {
    std.debug.print("\n[Slow] Sleeping 300ms...", .{});
    rt.sleep(300);
    std.debug.print("\n[Slow] Woke up!", .{});
}

test "Non-Blocking Sleep" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var global_ctx = crt.EbrContext{};
    defer global_ctx.deinit(allocator);

    var sched = crt.Scheduler.init(allocator, &global_ctx);
    defer sched.deinit();
    crt.active_scheduler = &sched;

    std.debug.print("\n\n--- Start Sleep Test ---", .{});

    const start = std.time.milliTimestamp();

    // Spawn both.
    // If sleep was blocking, this would take 100 + 300 = 400ms.
    // Since it's non-blocking, it should take ~300ms total.
    try sched.spawn(.{}, slowTask);
    try sched.spawn(.{}, fastTask);

    sched.run();

    const end = std.time.milliTimestamp();
    const duration = end - start;

    std.debug.print("\n--- Total Duration: {d}ms ---\n", .{duration});

    // Assert it ran in parallel (took less than sum of sleeps)
    try std.testing.expect(duration < 390);
    try std.testing.expect(duration >= 300);
}
