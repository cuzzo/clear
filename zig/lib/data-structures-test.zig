const std = @import("std");
const rt_mod = @import("../runtime/runtime.zig");
const fp = @import("../runtime/scheduler.zig");
const qs = @import("../runtime/queues.zig");
const fm = @import("../runtime/fiber-memory.zig");
const ebr = @import("ebr.zig");
const CheatLib = @import("../runtime/runtime-header.zig").CheatLib;
const Runtime = rt_mod.Runtime;

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
