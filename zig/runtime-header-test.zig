const std = @import("std");
const rt_mod = @import("runtime.zig");
const fp = @import("scheduler.zig");
const qs = @import("queues.zig");
const fm = @import("fiber-memory.zig");
const ebr = @import("ebr.zig");
const header = @import("runtime-header.zig");

// Import the C library
const c = @cImport({
    @cInclude("time.h");
    @cInclude("unistd.h");
});

const CheatLib = header.CheatLib;
const Runtime = rt_mod.Runtime;

// This is the function the Fiber will run
fn fiberFfiTask(rt: *Runtime, _: ?*anyopaque) anyerror!void {
    std.debug.print("\n[Fiber] Entering FFI Task. Current PID: {d}", .{c.getpid()});

    // 1. Prepare the C struct (on the Fiber stack)
    var req = c.struct_timespec{
        .tv_sec = 0,
        .tv_nsec = 50_000_000, // 50ms
    };
    var rem: c.struct_timespec = undefined;

    std.debug.print("\n[Fiber] Calling nanosleep via Root Stack Trampoline...", .{});

    // 2. USE THE TRAMPOLINE
    // This calls nanosleep(req, rem) on the Root Stack.
    // CheatLib.ffi(runtime, function, args_tuple)
    _ = CheatLib.ffi(rt, c.nanosleep, .{ &req, &rem });

    std.debug.print("\n[Fiber] Successfully returned from C! No stack corruption detected.", .{});

    // 3. Simple verification
    const val = c.getpid();
    CheatLib.assert(val > 0, "PID should be positive");
}

test "Root Stack Trampoline: C Standard Library Integration" {
    const allocator = std.testing.allocator;

    // --- Standard Boilerplate ---
    var global_ctx = ebr.EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();

    fp.active_scheduler = &sched;

    defer fp.global_registry.deinit(allocator);

    // ----------------------------

    std.debug.print("\n\n--- Start FFI Trampoline Test ---", .{});

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&fiberFfiTask)),
        null,
        .{}
    );

    // This will run until the fiber finishes.
    sched.run();

    std.debug.print("\n--- End FFI Trampoline Test ---\n", .{});
}

// ---------------------------------------------------------------------------
// Promise(T) tests
// ---------------------------------------------------------------------------
//
// These tests exercise the BG / ~T runtime primitive independently of the
// CLEAR compiler so the Zig invariants can be verified before Phase 4 wires
// up the parser and transpiler.
// ---------------------------------------------------------------------------

// Shared state threaded between producer and consumer fibers via a pointer
// on the main (test) stack.  The scheduler runs synchronously on that same
// stack, so the pointer is valid throughout sched.run().
const PromiseTestState = struct {
    promise: CheatLib.Promise(f64),
    result:  f64 = 0.0,
};

// Producer: receives a *Promise(f64).Inner as args, writes a value, signals done.
fn promiseProducer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    _ = rt;
    const inner = @as(*CheatLib.Promise(f64).Inner, @ptrCast(@alignCast(raw_args.?)));
    inner.result = 42.0;
    inner.wg.done();
}

// Consumer: receives *PromiseTestState, calls next() (which blocks until
// the producer signals), stores the result.
fn promiseConsumer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    _ = rt;
    const state = @as(*PromiseTestState, @ptrCast(@alignCast(raw_args.?)));
    state.result = state.promise.next();
}

test "Promise(f64): producer writes, consumer next() reads via fiber yield" {
    const allocator = std.testing.allocator;

    var global_ctx = ebr.EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();

    fp.active_scheduler = &sched;
    defer fp.global_registry.deinit(allocator);

    // Create the promise (Inner is heap-allocated by spawn()).
    var state = PromiseTestState{
        .promise = try CheatLib.Promise(f64).spawn(allocator, &sched),
    };

    // Spawn producer first so it may run before the consumer blocks.
    // The fast-path in WaitGroup.wait() handles the case where done() fires first.
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&promiseProducer)),
        state.promise.inner,   // producer receives the Inner directly
        .{}
    );

    // Spawn consumer — calls promise.next() which blocks until producer signals.
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&promiseConsumer)),
        &state,
        .{}
    );

    sched.run();

    try std.testing.expectEqual(@as(f64, 42.0), state.result);
}

// Verify that the fast path works: if the producer completes before the
// consumer even calls wait(), the counter is already 0 and wait() returns
// immediately without yielding.
fn promiseProducerImmediate(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    _ = rt;
    const inner = @as(*CheatLib.Promise(f64).Inner, @ptrCast(@alignCast(raw_args.?)));
    inner.result = 99.0;
    inner.wg.done();
}

fn promiseConsumerAfterDone(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    _ = rt;
    const state = @as(*PromiseTestState, @ptrCast(@alignCast(raw_args.?)));
    // By the time the consumer runs (LIFO scheduling), the producer may have
    // already finished.  next() must handle both orderings.
    state.result = state.promise.next();
}

test "Promise(f64): next() fast-path when producer finishes first" {
    const allocator = std.testing.allocator;

    var global_ctx = ebr.EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();

    fp.active_scheduler = &sched;
    defer fp.global_registry.deinit(allocator);

    var state = PromiseTestState{
        .promise = try CheatLib.Promise(f64).spawn(allocator, &sched),
    };

    // Consumer spawned first so it lands at the bottom of the LIFO ready queue.
    // Producer runs first (top of stack), signals done, then consumer runs and
    // takes the fast path in wait() (counter == 0).
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&promiseConsumerAfterDone)),
        &state,
        .{}
    );
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&promiseProducerImmediate)),
        state.promise.inner,
        .{}
    );

    sched.run();

    try std.testing.expectEqual(@as(f64, 99.0), state.result);
}

