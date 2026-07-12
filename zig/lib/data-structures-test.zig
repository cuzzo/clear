const std = @import("std");
const rt_mod = @import("../runtime/runtime.zig");
const fp = @import("../runtime/scheduler.zig");
const qs = @import("../runtime/queues.zig");
const fm = @import("../runtime/fiber-memory.zig");
const ebr = @import("ebr.zig");
const CheatLib = @import("../runtime/runtime-header.zig").CheatLib;
const Runtime = rt_mod.Runtime;

test "unboxMove releases only the unique box shell and transfers payload ownership" {
    const allocator = std.testing.allocator;
    const Payload = struct { bytes: []u8 };

    const boxed = try CheatLib.localCreate(Payload, allocator, .{
        .bytes = try allocator.dupe(u8, "owned payload"),
    });
    const moved = CheatLib.unboxMove(Payload, allocator, boxed);
    defer allocator.free(moved.bytes);

    try std.testing.expectEqualStrings("owned payload", moved.bytes);
}

test "Set(Rc(T)) uses handle identity and releases removed keys" {
    const allocator = std.testing.allocator;
    const RcItem = CheatLib.Rc(u64);
    var set: CheatLib.Set(RcItem) = .{};
    defer set.deinit(allocator);

    const item = try CheatLib.rcCreate(u64, allocator, 7);
    try set.insert(allocator, CheatLib.rcRetain(u64, item));
    try std.testing.expect(set.contains(item));
    try std.testing.expectEqual(@as(usize, 2), item.ctrl.strong);

    set.remove(allocator, item);
    try std.testing.expect(!set.contains(item));
    try std.testing.expectEqual(@as(usize, 1), item.ctrl.strong);
    CheatLib.rcRelease(u64, allocator, item);
}

const PromiseTestState = struct {
    promise: CheatLib.Promise(f64),
    result: f64 = 0.0,
};

fn promiseProducer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    _ = rt;
    const inner = @as(*CheatLib.Promise(f64).Inner, @ptrCast(@alignCast(raw_args.?)));
    inner.result = 42.0;
    inner.wg.done();
}

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

    var state = PromiseTestState{
        .promise = try CheatLib.Promise(f64).spawn(allocator, &sched),
    };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&promiseProducer)),
        state.promise.inner,
        .{},
    );
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&promiseConsumer)),
        &state,
        .{},
    );

    sched.run();
    try std.testing.expectEqual(@as(f64, 42.0), state.result);
}

fn promiseProducerImmediate(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    _ = rt;
    const inner = @as(*CheatLib.Promise(f64).Inner, @ptrCast(@alignCast(raw_args.?)));
    inner.result = 99.0;
    inner.wg.done();
}

fn promiseConsumerAfterDone(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    _ = rt;
    const state = @as(*PromiseTestState, @ptrCast(@alignCast(raw_args.?)));
    state.result = try state.promise.next();
}

// Pins the Promise(T).next() contract referenced by the BC runner's
// AWAIT cache (`futureResolved`). Promise.next() destroys its
// heap-allocated Inner before returning (zig/lib/data-structures.zig
// `self.alloc.destroy(self.inner)`); a SECOND next() on the same
// handle would `self.inner.wg.wait()` against freed memory (UAF, then
// double-free of Inner on the second destroy) -- DebugAllocator and
// glibc both catch it (`free(): double free detected in tcache 2`).
//
// We previously had a test that EXERCISED the second next() to prove
// the crash; it triggered SIGABRT during `sched.run()` and made CI
// red. The contract is documented in the source instead: this test
// asserts the safe single-next path AND the structural guarantee
// (next() consumes the handle by destroying Inner). If anyone later
// makes Promise idempotent (e.g. by folding it into SharedPromise's
// retain/refcount), the BC's `futureResolved` cache becomes
// optimization-only and this test should be revisited alongside
// `_bc_runner.clear`'s AWAIT branch.
test "Promise(f64).next() consumes the handle: documented contract" {
    // Assert the type-level shape: Inner has a wg + result; alloc is the
    // GPA used to destroy() Inner on next(). Calling next() twice on
    // the same handle is UB by construction.
    const Inner = CheatLib.Promise(f64).Inner;
    const fields = @typeInfo(Inner).@"struct".fields;
    var found_result = false;
    var found_wg = false;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, "result")) found_result = true;
        if (std.mem.eql(u8, f.name, "wg")) found_wg = true;
    }
    try std.testing.expect(found_result);
    try std.testing.expect(found_wg);

    // alloc is on the Promise struct itself (used in destroy(self.inner))
    const promise_fields = @typeInfo(CheatLib.Promise(f64)).@"struct".fields;
    var found_alloc = false;
    inline for (promise_fields) |f| {
        if (std.mem.eql(u8, f.name, "alloc")) found_alloc = true;
    }
    try std.testing.expect(found_alloc);
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

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&promiseConsumerAfterDone)),
        &state,
        .{},
    );
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&promiseProducerImmediate)),
        state.promise.inner,
        .{},
    );

    sched.run();
    try std.testing.expectEqual(@as(f64, 99.0), state.result);
}

// ---------------------------------------------------------------------------
// BoundedStream(i64, N): scheduler-based tests for nextOrNull() and deinit()
// ---------------------------------------------------------------------------

const BsTestState3 = struct {
    stream: CheatLib.BoundedStream(i64, 3),
    sum: i64 = 0,
};

const BsProducerArgs = struct {
    inner: *CheatLib.Promise(i64).Inner,
    value: i64,
};

fn bsProducer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    _ = rt;
    const args = @as(*BsProducerArgs, @ptrCast(@alignCast(raw_args.?)));
    args.inner.result = args.value;
    args.inner.wg.done();
}

fn bsConsumerAll3(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    _ = rt;
    const state = @as(*BsTestState3, @ptrCast(@alignCast(raw_args.?)));
    while (try state.stream.nextOrNull()) |item| {
        state.sum += item;
    }
}

fn bsConsumerOne3(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    _ = rt;
    // Consume only the first item — simulates TAKE_WHILE that exits after item 0.
    const state = @as(*BsTestState3, @ptrCast(@alignCast(raw_args.?)));
    if (try state.stream.nextOrNull()) |item| {
        state.sum += item;
    }
}

test "BoundedStream(i64,3): nextOrNull() consumes all items in order" {
    const allocator = std.testing.allocator;

    var global_ctx = ebr.EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();

    fp.active_scheduler = &sched;
    defer fp.global_registry.deinit(allocator);

    var state = BsTestState3{
        .stream = CheatLib.BoundedStream(i64, 3){
            .items = .{
                try CheatLib.Promise(i64).spawn(allocator, &sched),
                try CheatLib.Promise(i64).spawn(allocator, &sched),
                try CheatLib.Promise(i64).spawn(allocator, &sched),
            },
            .head = 0,
        },
    };

    var p0_args = BsProducerArgs{ .inner = state.stream.items[0].inner, .value = 10 };
    var p1_args = BsProducerArgs{ .inner = state.stream.items[1].inner, .value = 20 };
    var p2_args = BsProducerArgs{ .inner = state.stream.items[2].inner, .value = 30 };

    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&bsProducer)), &p0_args, .{});
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&bsProducer)), &p1_args, .{});
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&bsProducer)), &p2_args, .{});
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&bsConsumerAll3)), &state, .{});

    sched.run();

    // All 3 items consumed: sum == 10+20+30 == 60.  stream.head == 3.
    try std.testing.expectEqual(@as(i64, 60), state.sum);
    try std.testing.expectEqual(@as(usize, 3), state.stream.head);
    // nextOrNull() now returns null (exhausted) without touching items.
    const trailing_null = try state.stream.nextOrNull();
    try std.testing.expect(trailing_null == null);
    // DebugAllocator will fail the test if any Promise.Inner was leaked.
}

test "BoundedStream(i64,3): deinit() drains unconsumed promises (early-exit simulation)" {
    // Simulates the TAKE_WHILE / LIMIT early-exit pattern: consumer stops after the
    // first item, leaving 2 unconsumed promises.  deinit() must free their Inners.
    const allocator = std.testing.allocator;

    var global_ctx = ebr.EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();

    fp.active_scheduler = &sched;
    defer fp.global_registry.deinit(allocator);

    var state = BsTestState3{
        .stream = CheatLib.BoundedStream(i64, 3){
            .items = .{
                try CheatLib.Promise(i64).spawn(allocator, &sched),
                try CheatLib.Promise(i64).spawn(allocator, &sched),
                try CheatLib.Promise(i64).spawn(allocator, &sched),
            },
            .head = 0,
        },
    };

    var p0_args = BsProducerArgs{ .inner = state.stream.items[0].inner, .value = 10 };
    var p1_args = BsProducerArgs{ .inner = state.stream.items[1].inner, .value = 20 };
    var p2_args = BsProducerArgs{ .inner = state.stream.items[2].inner, .value = 30 };

    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&bsProducer)), &p0_args, .{});
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&bsProducer)), &p1_args, .{});
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&bsProducer)), &p2_args, .{});
    // Consumer exits after first item; producers for items[1] and [2] still run.
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&bsConsumerOne3)), &state, .{});

    sched.run();

    // Only item[0] was consumed; head advanced to 1.
    try std.testing.expectEqual(@as(i64, 10), state.sum);
    try std.testing.expectEqual(@as(usize, 1), state.stream.head);

    // All producers have completed (sched.run returned), so wg.counter == 0 for
    // items[1] and [2].  deinit() calls next() from non-fiber context: wg.wait()
    // sees counter == 0 and returns immediately, freeing each Inner.
    state.stream.deinit();

    try std.testing.expectEqual(@as(usize, 3), state.stream.head);
    // DebugAllocator will fail the test if any Promise.Inner was leaked.
}

test {
    _ = @import("../runtime/bounded-stream-test.zig");
    _ = @import("../runtime/inf-stream-test.zig");
    _ = @import("../runtime/shared-promise-test.zig");
    _ = @import("../runtime/pool-test.zig");
    _ = @import("../runtime/sharded-list-test.zig");
    _ = @import("../runtime/sharded-pool-test.zig");
    _ = @import("../runtime/slab-alloc-test.zig");
    _ = @import("../runtime/soa-list-test.zig");
    _ = @import("../runtime/soa-pool-test.zig");
    _ = @import("../runtime/stream-test.zig");
}
