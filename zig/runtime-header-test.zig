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
    state.result = try state.promise.next();
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
    state.result = try state.promise.next();
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

// ---------------------------------------------------------------------------
// BG-pattern integration tests
// ---------------------------------------------------------------------------
//
// These tests simulate the exact Zig code that the CLEAR transpiler generates
// for BG blocks: a heap-allocated context struct with by-value captures, a
// fiber that writes to Promise.Inner and signals done, and a caller fiber that
// calls promise.next() to block until the result is ready.
//
// Running them here (rather than only through all-tests.zig) gives us direct
// visibility into the runtime behaviour at the Zig level, independent of the
// Ruby compiler pipeline.
// ---------------------------------------------------------------------------

// Shared result state for BG integration tests.
// Lives on the test stack for the duration of sched.run().
const BgResult = struct {
    value: f64 = 0.0,
};

// Simulates the cheatMain fiber for:
//   x: Number = 10.0;
//   p: ~Number = BG { x + 5.0; };
//   result: Number = NEXT p;
fn bgCheatMain(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const out = @as(*BgResult, @ptrCast(@alignCast(raw_args.?)));
    const x: f64 = 10.0;

    // --- Transpiler output for: p: ~Number = BG { x + 5.0; } ---
    const BgCtx = struct {
        inner: *CheatLib.Promise(f64).Inner,
        alloc: std.mem.Allocator,
        x: f64, // captured by value

        fn run(raw_rt: *anyopaque, raw_args_inner: ?*anyopaque) anyerror!void {
            const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
            _ = &__rt;
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args_inner.?)));
            defer ctx.alloc.destroy(ctx);
            defer ctx.inner.wg.done();
            ctx.inner.result = ctx.x + 5.0;
        }
    };
    const alloc = rt.getSched().allocator;
    const p = try CheatLib.Promise(f64).spawn(alloc, rt.getSched());
    const bg_ctx = try alloc.create(BgCtx);
    bg_ctx.* = .{ .inner = p.inner, .alloc = alloc, .x = x };
    try rt.getSched().submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&BgCtx.run)),
        bg_ctx,
        .{},
    );
    // --- Transpiler output for: result: Number = NEXT p ---
    out.value = try p.next();
}

test "BG pattern: cheatMain-fiber spawns BG-fiber with by-value capture, NEXTs result" {
    const allocator = std.testing.allocator;

    var global_ctx = ebr.EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    defer fp.global_registry.deinit(allocator);

    fp.active_scheduler = &sched;

    var result = BgResult{};
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&bgCheatMain)),
        &result,
        .{},
    );
    sched.run();

    // 10.0 + 5.0 = 15.0
    try std.testing.expectEqual(@as(f64, 15.0), result.value);
}

// ---------------------------------------------------------------------------
// Shared state for the 3-concurrent-BG test.

const BgConcurrentResult = struct {
    a: f64 = 0.0,
    b: f64 = 0.0,
    c: f64 = 0.0,
};

// Simulates:
//   a: ~Number = BG { 10.0 };
//   b: ~Number = BG { 20.0 };
//   c: ~Number = BG { 30.0 };
//   rc = NEXT c; rb = NEXT b; ra = NEXT a;
fn bgConcurrentMain(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const out = @as(*BgConcurrentResult, @ptrCast(@alignCast(raw_args.?)));

    // Generic BG context carrying a constant f64 result.
    const BgFixed = struct {
        inner: *CheatLib.Promise(f64).Inner,
        alloc: std.mem.Allocator,
        value: f64,

        fn run(raw_rt: *anyopaque, raw_args_inner: ?*anyopaque) anyerror!void {
            const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
            _ = &__rt;
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args_inner.?)));
            defer ctx.alloc.destroy(ctx);
            defer ctx.inner.wg.done();
            ctx.inner.result = ctx.value;
        }
    };

    const alloc = rt.getSched().allocator;

    // Spawn three concurrent BG fibers.
    const pa = try CheatLib.Promise(f64).spawn(alloc, rt.getSched());
    const ctx_a = try alloc.create(BgFixed);
    ctx_a.* = .{ .inner = pa.inner, .alloc = alloc, .value = 10.0 };
    try rt.getSched().submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&BgFixed.run)), ctx_a, .{});

    const pb = try CheatLib.Promise(f64).spawn(alloc, rt.getSched());
    const ctx_b = try alloc.create(BgFixed);
    ctx_b.* = .{ .inner = pb.inner, .alloc = alloc, .value = 20.0 };
    try rt.getSched().submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&BgFixed.run)), ctx_b, .{});

    const pc = try CheatLib.Promise(f64).spawn(alloc, rt.getSched());
    const ctx_c = try alloc.create(BgFixed);
    ctx_c.* = .{ .inner = pc.inner, .alloc = alloc, .value = 30.0 };
    try rt.getSched().submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&BgFixed.run)), ctx_c, .{});

    // NEXT in reverse order — tests both slow-path (yield) and fast-path (already done).
    out.c = try pc.next();
    out.b = try pb.next();
    out.a = try pa.next();
}

test "BG pattern: 3 concurrent fibers, NEXT in reverse-spawn order" {
    const allocator = std.testing.allocator;

    var global_ctx = ebr.EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    defer fp.global_registry.deinit(allocator);

    fp.active_scheduler = &sched;

    var result = BgConcurrentResult{};
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&bgConcurrentMain)),
        &result,
        .{},
    );
    sched.run();

    try std.testing.expectEqual(@as(f64, 10.0), result.a);
    try std.testing.expectEqual(@as(f64, 20.0), result.b);
    try std.testing.expectEqual(@as(f64, 30.0), result.c);
}

// ---------------------------------------------------------------------------
// Value-isolation test: mutating the outer variable after spawning a BG fiber
// must not affect the fiber's result (since BG captures by VALUE, not pointer).

const BgIsolationResult = struct {
    value: f64 = 0.0,
};

fn bgIsolationMain(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const out = @as(*BgIsolationResult, @ptrCast(@alignCast(raw_args.?)));

    const BgCapture = struct {
        inner: *CheatLib.Promise(f64).Inner,
        alloc: std.mem.Allocator,
        captured: f64, // by-value copy of the outer variable

        fn run(raw_rt: *anyopaque, raw_args_inner: ?*anyopaque) anyerror!void {
            const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
            _ = &__rt;
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args_inner.?)));
            defer ctx.alloc.destroy(ctx);
            defer ctx.inner.wg.done();
            // The fiber uses the snapshotted value, not whatever `base` is now.
            ctx.inner.result = ctx.captured * 2.0;
        }
    };

    const alloc = rt.getSched().allocator;
    var base: f64 = 5.0;

    // Spawn BG fiber — captures base=5.0 by value.
    const p = try CheatLib.Promise(f64).spawn(alloc, rt.getSched());
    const bg_ctx = try alloc.create(BgCapture);
    bg_ctx.* = .{ .inner = p.inner, .alloc = alloc, .captured = base };
    try rt.getSched().submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&BgCapture.run)), bg_ctx, .{});

    // Mutate base AFTER spawning — should not affect the fiber's captured copy.
    base = 99.0;
    _ = &base; // keep base alive to show mutation doesn't affect fiber

    // NEXT — fiber must return 5.0 * 2.0 = 10.0, not 99.0 * 2.0 = 198.0.
    out.value = try p.next();
}

test "BG pattern: by-value capture is isolated from post-spawn mutation of outer variable" {
    const allocator = std.testing.allocator;

    var global_ctx = ebr.EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    defer fp.global_registry.deinit(allocator);

    fp.active_scheduler = &sched;

    var result = BgIsolationResult{};
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&bgIsolationMain)),
        &result,
        .{},
    );
    sched.run();

    // Must be 5.0 * 2.0 = 10.0 (snapshot at spawn), NOT 99.0 * 2.0.
    try std.testing.expectEqual(@as(f64, 10.0), result.value);
}
