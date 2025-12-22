const std = @import("std");
const CheatLib = @import("runtime-header.zig").CheatLib;
const Runtime = @import("runtime.zig").Runtime;
const fp = @import("fiber-pool.zig");
const Stack = fp.Stack;
const Fiber = fp.Fiber;
const Context = fp.Context;
const EbrContext = @import("ebr.zig").EbrContext;
const Scheduler = fp.Scheduler;
const WaitGroup = fp.WaitGroup;


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
    std.debug.print("\n[Task 1] Hello! My stack offset is: {d}", .{rt.frame_fba.end_index});

    // Simulate some work using the Runtime
    const ptr = rt.frame_fba.allocator().create(u64) catch unreachable;
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

    var stack_pool = fp.StackPool.init(allocator);
    defer stack_pool.deinit();

    // 2. Setup Scheduler
    var sched = try Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();

    // Link the global pointer (so entryWrapper can find us)
    fp.active_scheduler = &sched;

    std.debug.print("\n--- Spawning Tasks ---", .{});
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper),
        @as(fp.TaskFn, @ptrCast(&userTask1)),
        null,
        .{});
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper),
        @as(fp.TaskFn, @ptrCast(&userTask2)),
        null,
        .{});

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
    fp.active_scheduler.getCurrent().base.yield();

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
fn mainTask(_: *Runtime) !void {
    const sched = fp.active_scheduler;

    std.debug.print("\n[Main] Initializing WaitGroup...", .{});
    wg = WaitGroup.init(sched);
    wg.add(2);

    std.debug.print("\n[Main] Spawning workers...", .{});
    sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper),
        @as(fp.TaskFn, @ptrCast(&workerA)),
        null,
        .{}) catch unreachable;
    sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper),
        @as(fp.TaskFn, @ptrCast(&workerB)),
        null,
        .{}) catch unreachable;

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

    var stack_pool = fp.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();

    fp.active_scheduler = &sched;

    std.debug.print("\n\n--- Start Concurrency Test ---", .{});

    // We spawn the main coordinator, which spawns the others
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper),
        @as(fp.TaskFn, @ptrCast(&mainTask)),
        null,
        .{});

    sched.run();

    std.debug.print("\n--- End Concurrency Test ---\n", .{});

    // Assertions
    try std.testing.expectEqual(@as(u64, 100), result_a);
    try std.testing.expectEqual(@as(u64, 200), result_b);
}

// Runaway Task

fn infiniteLoop(rt: *Runtime) !void {
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
             fp.active_scheduler.getCurrent().base.yield();
        }
    }
}

test "Timeout Cancellation" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = fp.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;

    std.debug.print("\n\n--- Start Timeout Test ---", .{});

    // Spawn with 10ms timeout
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper),
        @as(fp.TaskFn, @ptrCast(&infiniteLoop)),
        null,
        .{ .timeout_ms = 10 });

    const start = std.time.milliTimestamp();
    sched.run();
    const end = std.time.milliTimestamp();

    std.debug.print("\n--- End Timeout Test (Duration: {d}ms) ---\n", .{end - start});

    // It should finish reasonably quickly (e.g., < 50ms), definitely not hang.
}

// Sleeping Beauty Test

// Sleep for 100ms
fn fastTask(rt: *Runtime) !void {
    std.debug.print("\n[Fast] Sleeping 100ms...", .{});
    rt.sleep(100);
    std.debug.print("\n[Fast] Woke up!", .{});
}

// Sleep for 300ms
fn slowTask(rt: *Runtime) !void {
    std.debug.print("\n[Slow] Sleeping 300ms...", .{});
    rt.sleep(300);
    std.debug.print("\n[Slow] Woke up!", .{});
}

test "Non-Blocking Sleep" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = fp.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;

    std.debug.print("\n\n--- Start Sleep Test ---", .{});

    const start = std.time.milliTimestamp();

    // Spawn both.
    // If sleep was blocking, this would take 100 + 300 = 400ms.
    // Since it's non-blocking, it should take ~300ms total.
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper),
        @as(fp.TaskFn, @ptrCast(&slowTask)),
        null,
        .{});
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper),
        @as(fp.TaskFn, @ptrCast(&fastTask)),
        null,
        .{});

    sched.run();

    const end = std.time.milliTimestamp();
    const duration = end - start;

    std.debug.print("\n--- Total Duration: {d}ms ---\n", .{duration});

    // Assert it ran in parallel (took less than sum of sleeps)
    try std.testing.expect(duration < 390);
    try std.testing.expect(duration >= 300);
}

// IO Test, i.e., this is starting to get useful

// Helper to set a socket to Non-Blocking mode
// We MUST do this, otherwise the OS will block the thread before our Runtime can yield.
// Only works on Linux
fn setNonBlocking(fd: i32) !void {
    const flags = try std.posix.fcntl(fd, std.os.linux.F.GETFL, 0);
    _ = try std.posix.fcntl(fd, std.os.linux.F.SETFL, flags | std.os.linux.SOCK.NONBLOCK);
}

// Global sockets for the test
var read_fd: i32 = undefined;
var write_fd: i32 = undefined;

// Task A: Tries to read. It should BLOCK (Yield) initially because there is no data.
fn readerTask(_: *Runtime) !void {
    std.debug.print("\n[Reader] Starting. Trying to read...", .{});

    var buf: [128]u8 = undefined;

    // This call will:
    // 1. See no data (EAGAIN)
    // 2. Register FD with Epoll
    // 3. Yield to Scheduler
    // ... Time Passes ...
    // 4. Wake up when WriterTask writes data
    const n = try CheatLib.read(read_fd, &buf);

    std.debug.print("\n[Reader] Woke up! Received: {s}", .{buf[0..n]});
}

// Task B: Sleeps, then writes data.
fn writerTask(rt: *Runtime) !void {
    std.debug.print("\n[Writer] Sleeping 100ms...", .{});
    rt.sleep(100);

    std.debug.print("\n[Writer] Waking up and writing 'Hello'...", .{});
    _ = try std.posix.write(write_fd, "Hello Fiber!");
}

// Only works on Linux
test "Async I/O with Epoll" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = fp.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;

    // 1. Setup Socket Pair (Simulates Client/Server connection)
    var fds: [2]i32 = undefined;
    _ = std.os.linux.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds);
    read_fd = fds[0];
    write_fd = fds[1];

    // CRITICAL: Set Non-Blocking!
    try setNonBlocking(read_fd);
    try setNonBlocking(write_fd);

    defer std.posix.close(read_fd);
    defer std.posix.close(write_fd);

    std.debug.print("\n\n--- Start I/O Test ---", .{});

    // 2. Spawn Tasks
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper),
        @as(fp.TaskFn, @ptrCast(&readerTask)),
        null,
        .{});
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper),
        @as(fp.TaskFn, @ptrCast(&writerTask)),
        null,
        .{});

    sched.run();

    std.debug.print("\n--- End I/O Test ---\n", .{});
}


// Multi-threaded Fiber Pools

// A heavy task to simulate work
fn heavyTask(rt: *Runtime) !void {
    const thread_id = std.Thread.getCurrentId();
    std.debug.print("\n[Thread {d}] Task Started.", .{thread_id});

    // Sleep to prove we are running concurrently with other threads
    rt.sleep(100);

    std.debug.print("\n[Thread {d}] Task Finished.", .{thread_id});
}

// The Entry Point for each OS Thread
fn threadEntryPoint(allocator: std.mem.Allocator, global_ctx: *EbrContext, stack_pool: *fp.StackPool) !void {
    // 1. Initialize Thread-Local Scheduler
    var sched = try Scheduler.init(allocator, global_ctx, stack_pool);
    defer sched.deinit();

    // 2. Set the thread-local pointer
    fp.active_scheduler = &sched;

    // 3. Spawn Fibers (These stay on THIS thread)
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper),
        @as(fp.TaskFn, @ptrCast(&heavyTask)),
        null,
        .{});
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper),
        @as(fp.TaskFn, @ptrCast(&heavyTask)),
        null,
        .{});

    // 4. Run Loop
    sched.run();
}

test "Multi-Threaded Shared Nothing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = fp.StackPool.init(allocator);
    defer stack_pool.deinit();

    std.debug.print("\n\n--- Start Multi-Thread Test ---", .{});

    // Spawn 3 OS Threads
    var threads: [3]std.Thread = undefined;
    for (0..3) |i| {
        threads[i] = try std.Thread.spawn(.{}, threadEntryPoint, .{allocator, &global_ctx, &stack_pool});
    }

    // Also run a scheduler on the Main Thread (Thread 4)
    try threadEntryPoint(allocator, &global_ctx, &stack_pool);

    // Wait for others
    for (threads) |t| {
        t.join();
    }

    std.debug.print("\n--- End Multi-Thread Test ---\n", .{});
}
