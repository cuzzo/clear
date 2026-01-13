const std = @import("std");
const safety = @import("safety.zig");
const rt_mod = @import("runtime.zig");
const fc = @import("fiber-core.zig");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const qs = @import("queues.zig");

const CheatLib = @import("runtime-header.zig").CheatLib;
const Runtime = rt_mod.Runtime;
const EbrContext = @import("ebr.zig").EbrContext;
const ThreadLocalEbr = @import("ebr.zig").ThreadLocalEbr;
const Scheduler = fp.Scheduler;
const StackPool = fm.StackPool;

var recursive_calls: usize = 0;
var start_recursion_depth: usize = 0;
var test_recursion_depth: usize = 0;
var start_sp: usize = 0;
var second_sp: usize = 0;


// The recursive function that consumes stack
fn recurseDeeply() void {
    safety.depthGuard();

    // Consume stack (~16 bytes per frame + overhead)
    var buf: [16]u8 = undefined;
    @memset(&buf, @intCast(test_recursion_depth % 255));
    std.mem.doNotOptimizeAway(&buf);

    if (test_recursion_depth == start_recursion_depth) {
       start_sp = safety.__min_depth;
    }
    else if (test_recursion_depth == start_recursion_depth - 1) {
       second_sp = safety.__min_depth;
    }

    if (test_recursion_depth > 0) {
        test_recursion_depth -= 1;
        // Never inline for test (ensure we recurse)
        @call(.never_inline, recurseDeeply, .{});
        // Access the buffer AFTER the call to ensure the frame stays alive, never TCO
        std.mem.doNotOptimizeAway(&buf);
    } else {
       return;
    }
}

test "depth guard" {
    start_recursion_depth = 1000;
    test_recursion_depth = start_recursion_depth;

    recurseDeeply();
    std.debug.print("START SP: {d}\n", .{start_sp});

    const frame_size = start_sp - second_sp;
    std.debug.print("FRAME SIZE: {d}\n", .{frame_size});

    const expected_sp = start_sp - frame_size * start_recursion_depth;
    std.debug.print("EXPECTED SP: {d}\n", .{expected_sp});
    std.debug.print("END SP: {d}\n", .{safety.__min_depth});
    try std.testing.expectEqual(expected_sp, safety.__min_depth);
}


var transacted = false;

const GuardError = error{ UnexpectedGlobalReentrancy };

fn reentrancyGuardedFunction() GuardError!void {
    // This entire preamble must be included in each guarded function
    // We use @src() to get a unique identifier for this specific line/file
    const state = &safety.GlobalReentrancyGuard(@src()).locked;

    if (state.*) {
        return error.UnexpectedGlobalReentrancy;
    }

    state.* = true;
    defer state.* = false;
    // End preamble

    transacted = true; // This is SUPPOSED to prevent foo from re-entering, but someone broke BAR, so it does not
    try foo(); // Foo is SUPPOSED to not logically re-enter guardedFunc, but it does.
    std.debug.print("Executing guarded logic...\n", .{});
}

var seed: usize = 0;

fn baz() bool {
    var prng = std.Random.DefaultPrng.init(seed);
    return prng.random().boolean();
}

fn bar() bool {
    return transacted and baz(); // someone added a call to baz, which sometimes returns false, leading to re-entrancy
}

fn foo() GuardError!void { // in Zig, this error is viral (comes from possibility to call guardedFunc), but not in CLEAR, this is a FAULT
    if (bar()) {
       std.debug.print("Short-circuited\n", .{});
       return;
    }
    try reentrancyGuardedFunction();
}

test "global re-entrancy guard (forced true)" {
    reentrancyGuardedFunction() catch { unreachable; };

    std.debug.print("Succesfully Short Circuited", .{});
    try std.testing.expectEqual(true, baz());
}

test "global re-entrancy guard (forced false)" {
    seed = 2;
    reentrancyGuardedFunction() catch |err| {
       std.debug.print("Succesfully Protected: {s}\n", .{@errorName(err)});
       try std.testing.expectEqual(false, baz());
       return;
    };

    unreachable;
}


fn recursionGuardedFunction(recursive: bool) !void {
    // PREAMBLE
    var guard = try safety.StackGuard.enter(@src());
    guard.push();
    defer guard.pop();
    // END PREAMBLE

    if (recursive) {
        // This should fail because it's the same stack
        try recursionGuardedFunction(false);
    }
}

test "fiber-safe stack recursion" {
    // --- SIMULATE FIBER A ---
    var fiber_a_context: ?*safety.GuardNode = null;
    var fiber_b_context: ?*safety.GuardNode = null;

    // 1. Fiber A enters the function
    safety.stack_guard_head = fiber_a_context;
    try recursionGuardedFunction(false);
    fiber_a_context = safety.stack_guard_head; // Save A's context
    std.debug.print("Fiber A entered safely.\n", .{});

    // 2. Fiber A tries to recurse (Should Error)
    safety.stack_guard_head = fiber_a_context;
    const result = recursionGuardedFunction(true);
    try std.testing.expectError(error.UnexpectedRecursion, result);
    std.debug.print("Fiber A recursion blocked successfully.\n", .{});

    // 3. SIMULATE CONTEXT SWITCH TO FIBER B
    // Even though Fiber A is "inside" the function, Fiber B should be allowed in
    safety.stack_guard_head = fiber_b_context;
    try recursionGuardedFunction(false);
    fiber_b_context = safety.stack_guard_head;
    std.debug.print("Fiber B entered safely while Fiber A was 'suspended'.\n", .{});

    // 4. SWITCH BACK TO FIBER A
    safety.stack_guard_head = fiber_a_context;
    std.debug.print("Switched back to Fiber A context.\n", .{});
}



var fiber_b_entered = false;
var fiber_a_recursion_failed = false;
var fiber_a_yielded = false;
var global_cleanup_ran = false;
const TestMode = enum { global, stack };

// workers annot error
fn fiberWorker(_: *Runtime, ctx: ?*anyopaque) anyerror!void {
    const mode = @as(TestMode, @enumFromInt(@intFromPtr(ctx)));

    var cleanup_run = false;
    defer {
        // CHANGED: Update global flag so test can see it
        if (cleanup_run and mode == .global) global_cleanup_ran = true;
    }

    if (mode == .global) {
        const Guard = safety.GlobalReentrancyGuard("shared_key");
        if (Guard.locked) {
            cleanup_run = true; // Mark that we "failed" and cleaned up
            return; // Return SUCCESS to the scheduler
        }

        Guard.locked = true;
        defer Guard.locked = false;

        // Yield to let Fiber B try to enter
        fc.__fiber.?.yield();
    } else {
        // Stack Guard Preamble
        var guard = try safety.StackGuard.enter(@src());
        guard.push();
        defer guard.pop();

        // Fiber A runs first. It sets yielded=true and yields.
        // Fiber B runs second. It sees yielded=true, so it enters the 'else' block.
        if (!fiber_a_yielded) {
            std.debug.print("Fiber A yielding...\n", .{});
            fiber_a_yielded = true;
            fc.__fiber.?.yield();

            // Fiber A Resumes here
            std.debug.print("Fiber A resumed, attempting recursion...\n", .{});
            fiberGuardedRecursion(1) catch |err| {
                if (err == error.UnexpectedRecursion) {
                    fiber_a_recursion_failed = true;
                }
            };
        } else {
            fiber_b_entered = true;
            std.debug.print("Fiber B entering the same function safely!\n", .{});
        }
    }
    cleanup_run = true;
}

fn fiberGuardedRecursion(depth: usize) !void {
    var guard = try safety.StackGuard.enter(@src());
    guard.push();
    defer guard.pop();
    if (depth > 0) {
        try fiberGuardedRecursion(depth - 1);
    }
}

// --- 3. THE RUNNER (Required Setup Boilerplate) ---
// This is unavoidable: You must boot the Scheduler inside the OS Thread.
fn testRunner(rt: *Runtime, allocator: std.mem.Allocator, mode: TestMode) !void {
    // Init StackPool & Scheduler
    const stack_pool = try allocator.create(StackPool);
    stack_pool.* = StackPool.init(allocator);
    defer { stack_pool.deinit(); allocator.destroy(stack_pool); }

    const sched = try allocator.create(Scheduler);
    sched.* = try Scheduler.init(allocator, rt.ebr.context, stack_pool);
    defer { sched.deinit(); allocator.destroy(sched); }

    fp.active_scheduler = sched;
    sched.shutdown_on_idle = true;

    const arg_ptr = @as(?*anyopaque, @ptrFromInt(@intFromEnum(mode)));

    // 2. SUBMIT WITH CAST
    // We cast &fiberWorker to qs.TaskFn. This is exactly what Runtime.spawn does.
    // Since fiberWorker now accepts (*anyopaque, ?*anyopaque), the signature matches physically.
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&fiberWorker)),
        arg_ptr,
        .{}
    );

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&fiberWorker)),
        arg_ptr,
        .{}
    );

    sched.run();
}

// --- 4. THE TEST ENTRY POINT ---
test "Fiber Safety Simple" {
    const allocator = std.testing.allocator;
    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    {
        fp.global_registry.mutex.lock();
        defer fp.global_registry.mutex.unlock();
        fp.global_registry.map = .{};
    }
    defer {
        fp.global_registry.mutex.lock();
        fp.global_registry.map.deinit(allocator);
        fp.global_registry.mutex.unlock();
    }

    // Test Global
    fiber_b_entered = false; // Reset globals
    fiber_a_recursion_failed = false;

    // Reset global lock state
    safety.GlobalReentrancyGuard("shared_key").locked = false;

    // Use CheatLib to create the thread environment
    const t1 = try CheatLib.spawnThread(allocator, 64 * 1024, &global_ctx, testRunner, .{ allocator, TestMode.global });
    t1.join();

    // Note: We expect B to have failed in Global mode (it yields, B tries, B fails).

    // Test Stack
    fiber_b_entered = false; // Reset globals
    fiber_a_recursion_failed = false;

    const t2 = try CheatLib.spawnThread(allocator, 64 * 1024, &global_ctx, testRunner, .{ allocator, TestMode.stack });
    t2.join();

    try std.testing.expect(fiber_b_entered);
    try std.testing.expect(fiber_a_recursion_failed);
}

