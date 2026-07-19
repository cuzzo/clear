// stream-test.zig
// Unit tests for CheatLib.Stream(T) — Phase 3 open/closeable streams.
//
// Full behavioral tests (concurrent generator fiber, multi-YIELD) require a
// live scheduler and are covered by transpile-tests/75_open_stream.clear.
//
// Run with:
//   zig test zig/stream-test.zig -lc zig/switch.S zig/onRoot.S
const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;
const compat = @import("../lib/compat.zig");
const build_options = @import("build_options");
const fc = @import("fiber-core.zig");
const fp = CheatHeader.scheduler;
const fm = CheatHeader.fiber_memory;
const qs = @import("queues.zig");

// Stack tier for spawned fibers in concurrency tests. TSan and kcov
// instrumentation grows each call frame (shadow-memory probes,
// interceptor frames), pushing test bodies that fit comfortably in the
// 16 KB Standard tier past the slab boundary. Under either, spawn at
// the 64 KB Large tier so the test is exercising the data structure,
// not the instrumented stack budget.
const test_stack_size: fc.StackSize =
    if (build_options.coverage or build_options.tsan) .Large else .Standard;

fn splitHammerIdleWait() void {
    // TSan records every intercepted sleep stack in StackDepot. This hammer
    // runs many scheduler threads across many local burn-in processes, so a
    // tight nanosleep polling loop can crash libtsan itself before it finds
    // user-code races.
    if (build_options.tsan) {
        std.atomic.spinLoopHint();
    } else {
        compat.sleepNs(std.time.ns_per_ms);
    }
}

fn splitHammerFutexWaitOnce(value: *std.atomic.Value(u32), expected: u32) void {
    const timeout = std.os.linux.timespec{ .sec = 0, .nsec = std.time.ns_per_ms };
    if (value.load(.acquire) == expected) {
        _ = std.os.linux.futex_4arg(
            &value.raw,
            .{ .cmd = .WAIT, .private = true },
            expected,
            &timeout,
        );
    }
}

fn splitHammerFutexWait(value: *std.atomic.Value(u32), expected: u32) void {
    while (value.load(.acquire) == expected) {
        splitHammerFutexWaitOnce(value, expected);
    }
}

fn splitHammerFutexWakeAll(value: *std.atomic.Value(u32)) void {
    _ = std.os.linux.futex_3arg(
        &value.raw,
        .{ .cmd = .WAKE, .private = true },
        std.math.maxInt(u32),
    );
}

fn splitHammerWakeRemoteSchedulers(idle_ticks: *usize) void {
    if ((idle_ticks.* & 0xff) == 0) {
        fp.global_registry.forceNotifyAll();
    }
    idle_ticks.* +%= 1;
    splitHammerIdleWait();
}

fn fakeSched() *CheatHeader.scheduler.Scheduler {
    return @ptrFromInt(@as(usize, @alignOf(CheatHeader.scheduler.Scheduler)));
}

fn splitNodeCount(comptime T: type, inner: *CheatLib.SplitStream(T).Inner) usize {
    var count: usize = 0;
    var cur = inner.chunks_head.load(.acquire);
    while (cur) |chunk| : (cur = chunk.next) count += chunk.len.load(.acquire);
    return count;
}

fn makeProducer(comptime T: type, stream: CheatLib.SplitStream(T)) CheatLib.SplitStream(T) {
    return .{
        .inner = stream.inner,
        .alloc = stream.alloc,
        .subscriber_id = std.math.maxInt(usize),
        .next_seq = stream.next_seq,
        .active = false,
    };
}

const BoundedPromiseProducer = struct {
    alloc: std.mem.Allocator,
    inner: *CheatLib.Promise(i64).Inner,
    value: i64,
};

fn boundedPromiseProducer(_: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const ctx = @as(*BoundedPromiseProducer, @ptrCast(@alignCast(raw_args.?)));
    defer ctx.alloc.destroy(ctx);
    ctx.inner.result = ctx.value;
    ctx.inner.wg.done();
}

const BoundedSelectState = struct {
    items: [4]CheatLib.Promise(i64),
    results: ?std.ArrayListUnmanaged(i64) = null,
};

fn boundedMapDouble(_: *Runtime, _: ?*anyopaque, value: i64) anyerror!i64 {
    return value * 2;
}

fn boundedKeepGtTwo(_: *Runtime, _: ?*anyopaque, value: i64) anyerror!bool {
    return value > 2;
}

const BoundedEachState = struct {
    items: [4]CheatLib.Promise(i64),
    total: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
};

const BoundedErrorState = struct {
    items: [4]CheatLib.Promise(i64),
    err: ?anyerror = null,
};

const PreservedSelectResult = anyerror!i64;

const BoundedPreservedErrorState = struct {
    items: [4]CheatLib.Promise(i64),
    results: ?std.ArrayListUnmanaged(PreservedSelectResult) = null,
};

const TestSelectStream = struct {
    items: []const i64,
    next_index: usize = 0,

    fn next(self: *@This()) !?i64 {
        if (self.next_index >= self.items.len) return null;
        defer self.next_index += 1;
        return self.items[self.next_index];
    }
};

const StreamPreservedErrorState = struct {
    source: TestSelectStream,
    results: ?std.ArrayListUnmanaged(PreservedSelectResult) = null,
};

fn boundedAccumulate(_: *Runtime, raw_args: ?*anyopaque, value: i64) anyerror!void {
    const state = @as(*BoundedEachState, @ptrCast(@alignCast(raw_args.?)));
    _ = state.total.fetchAdd(value, .seq_cst);
}

fn boundedMapErrorOnThree(_: *Runtime, _: ?*anyopaque, value: i64) anyerror!i64 {
    if (value == 3) return error.IntentionalBoundedSelect;
    return value;
}

fn preserveMapErrorOnThree(_: *Runtime, _: ?*anyopaque, value: i64) PreservedSelectResult {
    if (value == 3) return error.IntentionalBoundedSelect;
    return value;
}

fn boundedWhereErrorOnThree(_: *Runtime, _: ?*anyopaque, value: i64) anyerror!bool {
    if (value == 3) return error.IntentionalBoundedWhere;
    return true;
}

fn boundedEachErrorOnThirty(_: *Runtime, _: ?*anyopaque, value: i64) anyerror!void {
    if (value == 30) return error.IntentionalBoundedEach;
}

const ListReduceState = struct {
    items: [6]i64 = .{ 1, 2, 3, 4, 5, 6 },
    count: i64 = -1,
    sum: i64 = -1,
    average: f64 = -1,
    min: i64 = -1,
    max: i64 = -1,
    empty_count: i64 = -1,
    empty_sum: i64 = -1,
    empty_average: f64 = -1,
    empty_min: i64 = -1,
    empty_max: i64 = -1,
};

const ListReduceErrorState = struct {
    items: [6]i64 = .{ 1, 2, 3, 4, 5, 6 },
    count_err: ?anyerror = null,
    reduce_err: ?anyerror = null,
};

fn listKeepGtTwo(_: *Runtime, _: ?*anyopaque, value: i64) anyerror!bool {
    return value > 2;
}

fn listMapI64(_: *Runtime, _: ?*anyopaque, value: i64) anyerror!i64 {
    return value;
}

fn listMapF64(_: *Runtime, _: ?*anyopaque, value: i64) anyerror!f64 {
    return @floatFromInt(value);
}

fn listKeepErrorOnFive(_: *Runtime, _: ?*anyopaque, value: i64) anyerror!bool {
    if (value == 5) return error.IntentionalListCount;
    return value > 0;
}

fn listMapErrorOnFive(_: *Runtime, _: ?*anyopaque, value: i64) anyerror!i64 {
    if (value == 5) return error.IntentionalListReduce;
    return value;
}

fn listReduceConsumer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*ListReduceState, @ptrCast(@alignCast(raw_args.?)));
    state.count = try CheatLib.concurrentListCount(i64, listKeepGtTwo, rt, state.items[0..], 3, 2, false, .{ .stack_size = test_stack_size }, null);
    state.sum = try CheatLib.concurrentListReduce(i64, i64, listMapI64, rt, state.items[0..], 3, 2, false, .{ .stack_size = test_stack_size }, null, 0, .sum);
    state.average = try CheatLib.concurrentListReduce(i64, f64, listMapF64, rt, state.items[0..], 3, 2, false, .{ .stack_size = test_stack_size }, null, 0.0, .average);
    state.min = try CheatLib.concurrentListReduce(i64, i64, listMapI64, rt, state.items[0..], 3, 2, false, .{ .stack_size = test_stack_size }, null, std.math.maxInt(i64), .min);
    state.max = try CheatLib.concurrentListReduce(i64, i64, listMapI64, rt, state.items[0..], 3, 2, false, .{ .stack_size = test_stack_size }, null, std.math.minInt(i64), .max);

    const empty = state.items[0..0];
    state.empty_count = try CheatLib.concurrentListCount(i64, listKeepGtTwo, rt, empty, 3, 2, false, .{ .stack_size = test_stack_size }, null);
    state.empty_sum = try CheatLib.concurrentListReduce(i64, i64, listMapI64, rt, empty, 3, 2, false, .{ .stack_size = test_stack_size }, null, 0, .sum);
    state.empty_average = try CheatLib.concurrentListReduce(i64, f64, listMapF64, rt, empty, 3, 2, false, .{ .stack_size = test_stack_size }, null, 0.0, .average);
    state.empty_min = try CheatLib.concurrentListReduce(i64, i64, listMapI64, rt, empty, 3, 2, false, .{ .stack_size = test_stack_size }, null, std.math.maxInt(i64), .min);
    state.empty_max = try CheatLib.concurrentListReduce(i64, i64, listMapI64, rt, empty, 3, 2, false, .{ .stack_size = test_stack_size }, null, std.math.minInt(i64), .max);
}

fn listReduceParallelConsumer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*ListReduceState, @ptrCast(@alignCast(raw_args.?)));
    state.count = try CheatLib.concurrentListCount(i64, listKeepGtTwo, rt, state.items[0..], 3, 2, true, .{ .stack_size = test_stack_size }, null);
    state.sum = try CheatLib.concurrentListReduce(i64, i64, listMapI64, rt, state.items[0..], 3, 2, true, .{ .stack_size = test_stack_size }, null, 0, .sum);
}

fn listReduceErrorConsumer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*ListReduceErrorState, @ptrCast(@alignCast(raw_args.?)));
    _ = CheatLib.concurrentListCount(i64, listKeepErrorOnFive, rt, state.items[0..], 3, 2, false, .{ .stack_size = test_stack_size }, null) catch |err| {
        state.count_err = err;
    };
    _ = CheatLib.concurrentListReduce(i64, i64, listMapErrorOnFive, rt, state.items[0..], 3, 2, false, .{ .stack_size = test_stack_size }, null, 0, .sum) catch |err| {
        state.reduce_err = err;
    };
}

fn boundedSelectConsumer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*BoundedSelectState, @ptrCast(@alignCast(raw_args.?)));
    state.results = try CheatLib.concurrentBoundedSelect(i64, i64, 4, boundedMapDouble, rt.heapAlloc(), rt, &state.items, 2, 3, false, .{}, null);
}

fn boundedWhereConsumer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*BoundedSelectState, @ptrCast(@alignCast(raw_args.?)));
    state.results = try CheatLib.concurrentBoundedWhere(i64, 4, boundedKeepGtTwo, rt.heapAlloc(), rt, &state.items, 2, 3, false, .{}, null);
}

fn boundedEachConsumer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*BoundedEachState, @ptrCast(@alignCast(raw_args.?)));
    try CheatLib.concurrentBoundedEach(i64, 4, boundedAccumulate, rt, &state.items, 2, 3, false, .{}, state);
}

fn boundedSelectErrorConsumer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*BoundedErrorState, @ptrCast(@alignCast(raw_args.?)));
    var result = CheatLib.concurrentBoundedSelect(i64, i64, 4, boundedMapErrorOnThree, rt.heapAlloc(), rt, &state.items, 2, 3, false, .{}, null) catch |err| {
        state.err = err;
        return;
    };
    result.deinit(rt.heapAlloc());
}

fn boundedSelectPreservedErrorConsumer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*BoundedPreservedErrorState, @ptrCast(@alignCast(raw_args.?)));
    state.results = try CheatLib.concurrentBoundedSelectPreservingErrors(
        i64,
        PreservedSelectResult,
        4,
        preserveMapErrorOnThree,
        rt.heapAlloc(),
        rt,
        &state.items,
        2,
        3,
        false,
        .{},
        null,
    );
}

fn streamSelectPreservedErrorConsumer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*StreamPreservedErrorState, @ptrCast(@alignCast(raw_args.?)));
    state.results = try CheatLib.concurrentStreamSelectPreservingErrors(
        i64,
        PreservedSelectResult,
        preserveMapErrorOnThree,
        false,
        rt.heapAlloc(),
        rt,
        &state.source,
        2,
        4,
        2,
        false,
        .{},
        null,
    );
}

fn boundedWhereErrorConsumer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*BoundedErrorState, @ptrCast(@alignCast(raw_args.?)));
    var result = CheatLib.concurrentBoundedWhere(i64, 4, boundedWhereErrorOnThree, rt.heapAlloc(), rt, &state.items, 2, 3, false, .{}, null) catch |err| {
        state.err = err;
        return;
    };
    result.deinit(rt.heapAlloc());
}

fn boundedEachErrorConsumer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*BoundedErrorState, @ptrCast(@alignCast(raw_args.?)));
    CheatLib.concurrentBoundedEach(i64, 4, boundedEachErrorOnThirty, rt, &state.items, 2, 3, false, .{}, null) catch |err| {
        state.err = err;
        return;
    };
}

fn makeBoundedPromiseItems(rt: *Runtime, values: [4]i64) ![4]CheatLib.Promise(i64) {
    var promises: [4]CheatLib.Promise(i64) = undefined;
    for (values, 0..) |value, i| {
        promises[i] = try CheatLib.Promise(i64).spawn(rt.heapAlloc(), rt.getSched());
        const producer = try rt.heapAlloc().create(BoundedPromiseProducer);
        producer.* = .{ .alloc = rt.heapAlloc(), .inner = promises[i].inner, .value = value };
        try rt.getSched().submitSpawn(
            @intFromPtr(&Runtime.entryWrapper),
            @as(qs.TaskFn, @ptrCast(&boundedPromiseProducer)),
            producer,
            .{},
        );
    }
    return promises;
}

// ---------------------------------------------------------------------------
// Struct shape
// ---------------------------------------------------------------------------

test "Stream has inner and alloc fields (no head — ring buffer tracks position in Inner)" {
    const S = CheatLib.Stream(f64);
    const fields = @typeInfo(S).@"struct".fields;
    var found_inner = false;
    var found_alloc = false;
    var found_head = false;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, "inner")) found_inner = true;
        if (std.mem.eql(u8, f.name, "alloc")) found_alloc = true;
        if (std.mem.eql(u8, f.name, "head")) found_head = true;
    }
    try std.testing.expect(found_inner);
    try std.testing.expect(found_alloc);
    try std.testing.expect(!found_head); // ring buffer — no consumer head field on the handle
}

test "Stream.Inner has ring buffer fields, wg, closed, err (no items ArrayList)" {
    const Inner = CheatLib.Stream(f64).Inner;
    const fields = @typeInfo(Inner).@"struct".fields;
    var found_buf = false;
    var found_head = false;
    var found_tail = false;
    var found_closed = false;
    var found_wg = false;
    var found_items = false;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, "buf")) found_buf = true;
        if (std.mem.eql(u8, f.name, "head")) found_head = true;
        if (std.mem.eql(u8, f.name, "tail")) found_tail = true;
        if (std.mem.eql(u8, f.name, "closed")) found_closed = true;
        if (std.mem.eql(u8, f.name, "wg")) found_wg = true;
        if (std.mem.eql(u8, f.name, "items")) found_items = true;
    }
    try std.testing.expect(found_buf);
    try std.testing.expect(found_head);
    try std.testing.expect(found_tail);
    try std.testing.expect(found_closed);
    try std.testing.expect(found_wg);
    try std.testing.expect(!found_items); // ArrayList replaced by ring buffer
}

// ---------------------------------------------------------------------------
// push/next via ring buffer (fast path: no blocking, fake sched is safe)
// ---------------------------------------------------------------------------

test "Stream.push and next deliver items via ring buffer" {
    const S = CheatLib.Stream(f64);
    const alloc = std.testing.allocator;

    // spawnNew with a fake sched — fast path never dereferences it.
    var stream = try S.spawnNew(alloc, fakeSched());
    // Skip deinit (would call wg.wait on fake sched); manually free Inner below.

    var gen = S{ .inner = stream.inner, .alloc = alloc };
    try gen.push(10.0);
    try gen.push(20.0);
    try gen.push(30.0);

    // Mark closed directly — avoids wg.done() on fake sched.
    stream.inner.closed.store(true, .release);

    const v1 = try stream.next();
    const v2 = try stream.next();
    const v3 = try stream.next();
    const v4 = try stream.next(); // null — ring empty and closed

    try std.testing.expectApproxEqAbs(10.0, v1.?, 1e-9);
    try std.testing.expectApproxEqAbs(20.0, v2.?, 1e-9);
    try std.testing.expectApproxEqAbs(30.0, v3.?, 1e-9);
    try std.testing.expectEqual(@as(?f64, null), v4);

    alloc.destroy(stream.inner);
}

test "Stream.push works for bool type (ring buffer)" {
    const S = CheatLib.Stream(bool);
    const alloc = std.testing.allocator;

    var stream = try S.spawnNew(alloc, fakeSched());
    var gen = S{ .inner = stream.inner, .alloc = alloc };
    try gen.push(true);
    try gen.push(false);

    stream.inner.closed.store(true, .release);

    try std.testing.expectEqual(@as(?bool, true), try stream.next());
    try std.testing.expectEqual(@as(?bool, false), try stream.next());
    try std.testing.expectEqual(@as(?bool, null), try stream.next());

    alloc.destroy(stream.inner);
}

test "Stream.next returns null immediately when closed and ring is empty" {
    const S = CheatLib.Stream(i64);
    const alloc = std.testing.allocator;

    var stream = try S.spawnNew(alloc, fakeSched());
    stream.inner.closed.store(true, .release); // closed before any push

    try std.testing.expectEqual(@as(?i64, null), try stream.next());

    alloc.destroy(stream.inner);
}

test "Stream ring buffer preserves FIFO order across 64-item boundary" {
    const S = CheatLib.Stream(i64);
    const alloc = std.testing.allocator;

    var stream = try S.spawnNew(alloc, fakeSched());
    var gen = S{ .inner = stream.inner, .alloc = alloc };

    // Push exactly BUF_SIZE items (64) without triggering blocking.
    var i: i64 = 0;
    while (i < 64) : (i += 1) try gen.push(i);

    stream.inner.closed.store(true, .release);

    var j: i64 = 0;
    while (j < 64) : (j += 1) {
        const v = try stream.next();
        try std.testing.expectEqual(@as(?i64, j), v);
    }
    try std.testing.expectEqual(@as(?i64, null), try stream.next());

    alloc.destroy(stream.inner);
}

// ---------------------------------------------------------------------------
// Type distinctness
// ---------------------------------------------------------------------------

test "Stream(f64) and Promise(f64) are distinct types" {
    const S = CheatLib.Stream(f64);
    const P = CheatLib.Promise(f64);
    try std.testing.expect(S != P);
}

test "Stream(f64) and Stream(bool) are distinct types" {
    const SF = CheatLib.Stream(f64);
    const SB = CheatLib.Stream(bool);
    try std.testing.expect(SF != SB);
}

test "Stream(f64) and BoundedStream(f64, 3) are distinct types" {
    const S = CheatLib.Stream(f64);
    const BS = CheatLib.BoundedStream(f64, 3);
    try std.testing.expect(S != BS);
}

test "IntRange nextOrNull and toList work" {
    var range = CheatLib.IntRange{ .start = 0, .end = 3 };
    try std.testing.expectEqual(@as(?i64, 0), try range.next());
    try std.testing.expectEqual(@as(?i64, 1), try range.nextOrNull());
    try std.testing.expectEqual(@as(?i64, 2), try range.nextOrNull());
    try std.testing.expectEqual(@as(?i64, null), try range.nextOrNull());

    var list = try (CheatLib.IntRange{ .start = 2, .end = 5 }).toList(std.testing.allocator);
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqual(@as(i64, 2), list.items[0]);
    try std.testing.expectEqual(@as(i64, 3), list.items[1]);
    try std.testing.expectEqual(@as(i64, 4), list.items[2]);
}

test "Range nextOrNull and toList work" {
    var range = CheatLib.Range{ .start = 1.5, .end = 4.5 };
    try std.testing.expectEqual(@as(?f64, 1.5), try range.next());
    try std.testing.expectEqual(@as(?f64, 2.5), try range.nextOrNull());
    try std.testing.expectEqual(@as(?f64, 3.5), try range.nextOrNull());
    try std.testing.expectEqual(@as(?f64, null), try range.nextOrNull());

    var list = try (CheatLib.Range{ .start = 0.5, .end = 2.5 }).toList(std.testing.allocator);
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqual(@as(f64, 0.5), list.items[0]);
    try std.testing.expectEqual(@as(f64, 1.5), list.items[1]);
}

test "SplitStream has inner, alloc, next_seq, and active fields" {
    const S = CheatLib.SplitStream(i64);
    const fields = @typeInfo(S).@"struct".fields;
    var found_inner = false;
    var found_alloc = false;
    var found_next_seq = false;
    var found_active = false;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, "inner")) found_inner = true;
        if (std.mem.eql(u8, f.name, "alloc")) found_alloc = true;
        if (std.mem.eql(u8, f.name, "next_seq")) found_next_seq = true;
        if (std.mem.eql(u8, f.name, "active")) found_active = true;
    }
    try std.testing.expect(found_inner);
    try std.testing.expect(found_alloc);
    try std.testing.expect(found_next_seq);
    try std.testing.expect(found_active);
}

test "SplitStream replays the same ordered values to two retained handles" {
    const S = CheatLib.SplitStream(i64);
    var stream = try S.spawnNew(std.testing.allocator, fakeSched());
    defer stream.deinit();

    var producer = makeProducer(i64, stream);
    try producer.push(1);
    try producer.push(2);
    try producer.push(3);
    producer.close();

    var clone = stream.retain();
    defer clone.deinit();

    try std.testing.expectEqual(@as(?i64, 1), try stream.next());
    try std.testing.expectEqual(@as(?i64, 2), try stream.next());
    try std.testing.expectEqual(@as(?i64, 3), try stream.next());
    try std.testing.expectEqual(@as(?i64, null), try stream.next());

    try std.testing.expectEqual(@as(?i64, 1), try clone.next());
    try std.testing.expectEqual(@as(?i64, 2), try clone.next());
    try std.testing.expectEqual(@as(?i64, 3), try clone.next());
    try std.testing.expectEqual(@as(?i64, null), try clone.next());
}

test "SplitStream keeps a memoized item until all owners consume it" {
    const S = CheatLib.SplitStream(i64);
    var stream = try S.spawnNew(std.testing.allocator, fakeSched());
    defer stream.deinit();

    var producer = makeProducer(i64, stream);
    try producer.push(11);
    try producer.push(22);
    producer.close();

    var clone = stream.retain();
    defer clone.deinit();

    try std.testing.expectEqual(@as(usize, 2), splitNodeCount(i64, stream.inner));
    try std.testing.expectEqual(@as(?i64, 11), try stream.next());
    try std.testing.expectEqual(@as(usize, 2), splitNodeCount(i64, stream.inner));

    try std.testing.expectEqual(@as(?i64, 11), try clone.next());
    try std.testing.expectEqual(@as(usize, 2), splitNodeCount(i64, stream.inner));
    try std.testing.expectEqual(@as(i64, 11), stream.inner.chunks_head.load(.acquire).?.values[0]);
    try std.testing.expectEqual(@as(usize, 1), stream.inner.subscribers.items[stream.subscriber_id].seq.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), stream.inner.subscribers.items[clone.subscriber_id].seq.load(.acquire));
}

test "SplitStream retain clones from the source handle current unread position" {
    const S = CheatLib.SplitStream(i64);
    var stream = try S.spawnNew(std.testing.allocator, fakeSched());
    defer stream.deinit();

    var producer = makeProducer(i64, stream);
    try producer.push(4);
    try producer.push(5);
    try producer.push(6);
    producer.close();

    try std.testing.expectEqual(@as(?i64, 4), try stream.next());

    var clone = stream.retain();
    defer clone.deinit();

    try std.testing.expectEqual(@as(?i64, 5), try clone.next());
    try std.testing.expectEqual(@as(?i64, 6), try clone.next());
    try std.testing.expectEqual(@as(?i64, null), try clone.next());
}

test "SplitStream deinit releases unread items for a lagging owner" {
    const S = CheatLib.SplitStream(i64);
    var stream = try S.spawnNew(std.testing.allocator, fakeSched());
    defer stream.deinit();

    var producer = makeProducer(i64, stream);
    try producer.push(7);
    try producer.push(8);
    producer.close();

    var clone = stream.retain();

    try std.testing.expectEqual(@as(?i64, 7), try stream.next());
    try std.testing.expectEqual(@as(usize, 2), splitNodeCount(i64, stream.inner));

    clone.deinit();

    try std.testing.expectEqual(@as(usize, 2), splitNodeCount(i64, stream.inner));
    try std.testing.expectEqual(@as(i64, 8), stream.inner.chunks_head.load(.acquire).?.values[1]);
    try std.testing.expectEqual(@as(usize, 1), stream.inner.active_subscribers.load(.acquire));
}

test "SplitStream drops producer values immediately when no owners remain" {
    const S = CheatLib.SplitStream([]const u8);
    var stream = try S.spawnNew(std.testing.allocator, fakeSched());

    var producer = makeProducer([]const u8, stream);
    stream.inner.active_subscribers.store(0, .release);
    stream.subscriber_id = std.math.maxInt(usize);
    stream.active = false;

    const msg = try std.testing.allocator.dupe(u8, "orphaned");
    try producer.push(msg);
    producer.close();
    stream.active = true;
    stream.deinit();
}

test "SplitStream propagates terminal errors to all handles" {
    const S = CheatLib.SplitStream(i64);
    var stream = try S.spawnNew(std.testing.allocator, fakeSched());
    defer stream.deinit();

    var clone = stream.retain();
    defer clone.deinit();

    var producer = makeProducer(i64, stream);
    producer.setError(error.TestFailure);
    producer.close();

    try std.testing.expectError(error.TestFailure, stream.next());
    try std.testing.expectError(error.TestFailure, clone.next());
}

test "SplitStream releases string payloads after all readers finish" {
    const S = CheatLib.SplitStream([]const u8);
    var stream = try S.spawnNew(std.testing.allocator, fakeSched());
    defer stream.deinit();

    var clone = stream.retain();
    defer clone.deinit();

    var producer = makeProducer([]const u8, stream);
    try producer.push(try std.testing.allocator.dupe(u8, "alpha"));
    try producer.push(try std.testing.allocator.dupe(u8, "beta"));
    producer.close();

    const s1 = (try stream.next()).?;
    defer CheatLib.cleanup([]const u8, std.testing.allocator, &s1);
    const s2 = (try stream.next()).?;
    defer CheatLib.cleanup([]const u8, std.testing.allocator, &s2);
    try std.testing.expectEqualStrings("alpha", s1);
    try std.testing.expectEqualStrings("beta", s2);
    try std.testing.expectEqual(@as(?[]const u8, null), try stream.next());

    const c1 = (try clone.next()).?;
    defer CheatLib.cleanup([]const u8, std.testing.allocator, &c1);
    const c2 = (try clone.next()).?;
    defer CheatLib.cleanup([]const u8, std.testing.allocator, &c2);
    try std.testing.expectEqualStrings("alpha", c1);
    try std.testing.expectEqualStrings("beta", c2);
    try std.testing.expectEqual(@as(?[]const u8, null), try clone.next());
}

test "SplitStream error after pushing unread strings releases buffered nodes on deinit" {
    const S = CheatLib.SplitStream([]const u8);
    var stream = try S.spawnNew(std.testing.allocator, fakeSched());
    defer stream.deinit();

    var clone = stream.retain();
    defer clone.deinit();

    var producer = makeProducer([]const u8, stream);
    try producer.push(try std.testing.allocator.dupe(u8, "left"));
    try producer.push(try std.testing.allocator.dupe(u8, "right"));
    producer.setError(error.TestFailure);
    producer.close();

    try std.testing.expectError(error.TestFailure, stream.next());
    try std.testing.expectError(error.TestFailure, clone.next());
}

const ThreadResult = struct {
    values: [3]i64 = [_]i64{0} ** 3,
    count: usize = 0,
};

fn readSplitStream(stream: *CheatLib.SplitStream(i64), result: *ThreadResult) !void {
    while (try stream.next()) |value| {
        result.values[result.count] = value;
        result.count += 1;
    }
}

const SplitFiberReadState = struct {
    stream: CheatLib.SplitStream(i64),
    out: *[3]i64,
    count: usize = 0,
};

fn splitFiberReader(_: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*SplitFiberReadState, @ptrCast(@alignCast(raw_args.?)));
    defer state.stream.deinit();
    while (try state.stream.next()) |value| {
        state.out[state.count] = value;
        state.count += 1;
    }
}

const SplitFiberProducerState = struct {
    stream: CheatLib.SplitStream(i64),
};

fn splitFiberProducer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*SplitFiberProducerState, @ptrCast(@alignCast(raw_args.?)));
    defer state.stream.close();
    try state.stream.push(101);
    rt.checkYield();
    try state.stream.push(102);
    rt.checkYield();
    try state.stream.push(103);
}

const PlainStreamCrossSchedulerState = struct {
    stream: CheatLib.Stream(i64),
    ready: *std.atomic.Value(usize),
    completed: *std.atomic.Value(usize),
    count: usize = 0,
    total: i64 = 0,
};

fn plainStreamCrossSchedulerConsumer(_: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*PlainStreamCrossSchedulerState, @ptrCast(@alignCast(raw_args.?)));
    _ = state.ready.fetchAdd(1, .acq_rel);

    while (try state.stream.next()) |value| {
        state.total += value;
        state.count += 1;
    }

    _ = state.completed.fetchAdd(1, .acq_rel);
}

const PlainStreamProducerWakeState = struct {
    stream: CheatLib.Stream(i64),
    attempted: usize,
    completed: *std.atomic.Value(usize),
    closed: *std.atomic.Value(usize),
};

fn plainStreamFillProducer(_: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*PlainStreamProducerWakeState, @ptrCast(@alignCast(raw_args.?)));
    defer state.stream.close();

    var i: usize = 0;
    while (i < state.attempted) : (i += 1) {
        state.stream.push(@intCast(i)) catch |err| {
            if (err == error.StreamClosed) {
                _ = state.closed.fetchAdd(1, .acq_rel);
                return;
            }
            return err;
        };
    }

    _ = state.completed.fetchAdd(1, .acq_rel);
}

const PlainStreamDeinitState = struct {
    stream: CheatLib.Stream(i64),
    completed: *std.atomic.Value(usize),
};

fn streamProducerParked(stream: CheatLib.Stream(i64)) bool {
    while (stream.inner.lock.swap(1, .acquire) == 1) std.Thread.yield() catch {};
    const parked = stream.inner.producer_task != null;
    stream.inner.lock.store(0, .release);
    return parked;
}

fn streamConsumerParked(stream: CheatLib.Stream(i64)) bool {
    while (stream.inner.lock.swap(1, .acquire) == 1) std.Thread.yield() catch {};
    const parked = stream.inner.consumer_task != null;
    stream.inner.lock.store(0, .release);
    return parked;
}

fn plainStreamDeinitTask(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*PlainStreamDeinitState, @ptrCast(@alignCast(raw_args.?)));
    while (!streamProducerParked(state.stream)) rt.checkYield();
    state.stream.deinit();
    _ = state.completed.fetchAdd(1, .acq_rel);
}

const PlainStreamCloseState = struct {
    stream: CheatLib.Stream(i64),
    completed: *std.atomic.Value(usize),
};

fn plainStreamCloseTask(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*PlainStreamCloseState, @ptrCast(@alignCast(raw_args.?)));
    while (!streamConsumerParked(state.stream)) rt.checkYield();
    state.stream.close();
    _ = state.completed.fetchAdd(1, .acq_rel);
}

const PlainStreamNextWakeState = struct {
    stream: CheatLib.Stream(i64),
    value: i64 = -1,
    completed: *std.atomic.Value(usize),
};

fn plainStreamNextWakeTask(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*PlainStreamNextWakeState, @ptrCast(@alignCast(raw_args.?)));
    while (!streamProducerParked(state.stream)) rt.checkYield();
    state.value = (try state.stream.next()).?;
    _ = state.completed.fetchAdd(1, .acq_rel);
}

fn splitHammerMix(seed: i64) i64 {
    var x = seed;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        x = x *% 6364136223846793005 +% 1442695040888963407;
    }
    return x;
}

const SplitParallelSubscriberState = struct {
    stream: CheatLib.SplitStream(i64),
    total: i64 = 0,
    count: usize = 0,
    ready: *std.atomic.Value(usize),
    completed: *std.atomic.Value(usize),
};

fn splitParallelSubscriber(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*SplitParallelSubscriberState, @ptrCast(@alignCast(raw_args.?)));
    defer {
        _ = state.completed.fetchAdd(1, .acq_rel);
    }
    defer state.stream.deinit();

    _ = state.ready.fetchAdd(1, .acq_rel);
    var total: i64 = 0;
    var count: usize = 0;
    while (true) {
        const msg = try state.stream.next();
        if (msg == null) break;
        total = total +% splitHammerMix(msg.?);
        count += 1;
        if ((count & 63) == 0) rt.checkYield();
    }

    state.total = total;
    state.count = count;
}

const SplitParallelProducerState = struct {
    stream: CheatLib.SplitStream(i64),
    message_count: usize,
    completed: *std.atomic.Value(usize),
};

fn splitParallelProducer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*SplitParallelProducerState, @ptrCast(@alignCast(raw_args.?)));
    defer {
        _ = state.completed.fetchAdd(1, .acq_rel);
    }
    defer state.stream.close();

    var i: usize = 0;
    while (i < state.message_count) : (i += 1) {
        try state.stream.push(@as(i64, @intCast(i)));
        if ((i & 63) == 0) rt.checkYield();
    }
}

test "SplitStream preserves order across two OS-thread consumers" {
    const S = CheatLib.SplitStream(i64);
    var stream = try S.spawnNew(std.testing.allocator, fakeSched());
    defer stream.deinit();

    var clone = stream.retain();
    defer clone.deinit();

    var producer = makeProducer(i64, stream);
    try producer.push(101);
    try producer.push(102);
    try producer.push(103);
    producer.close();

    var left = ThreadResult{};
    var right = ThreadResult{};

    const t1 = try std.Thread.spawn(.{}, readSplitStream, .{ &stream, &left });
    const t2 = try std.Thread.spawn(.{}, readSplitStream, .{ &clone, &right });
    t1.join();
    t2.join();

    try std.testing.expectEqual(@as(usize, 3), left.count);
    try std.testing.expectEqual(@as(usize, 3), right.count);
    try std.testing.expectEqualSlices(i64, left.values[0..left.count], &[_]i64{ 101, 102, 103 });
    try std.testing.expectEqualSlices(i64, right.values[0..right.count], &[_]i64{ 101, 102, 103 });
}

test "SplitStream wakes multiple waiting fibers as items arrive" {
    const allocator = std.testing.allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.global_registry.deinit(allocator);

    var rt = try Runtime.init(allocator, 4 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const S = CheatLib.SplitStream(i64);
    var stream = try S.spawnNew(allocator, &sched);

    var left_values = [_]i64{0} ** 3;
    var right_values = [_]i64{0} ** 3;
    var left_state = SplitFiberReadState{ .stream = stream, .out = &left_values };
    var right_state = SplitFiberReadState{ .stream = stream.retain(), .out = &right_values };
    var producer_state = SplitFiberProducerState{ .stream = makeProducer(i64, stream) };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&splitFiberReader)),
        &left_state,
        .{ .stack_size = test_stack_size },
    );
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&splitFiberReader)),
        &right_state,
        .{ .stack_size = test_stack_size },
    );
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&splitFiberProducer)),
        &producer_state,
        .{ .stack_size = test_stack_size },
    );

    sched.run();

    try std.testing.expectEqual(@as(usize, 3), left_state.count);
    try std.testing.expectEqual(@as(usize, 3), right_state.count);
    try std.testing.expectEqualSlices(i64, left_values[0..left_state.count], &[_]i64{ 101, 102, 103 });
    try std.testing.expectEqualSlices(i64, right_values[0..right_state.count], &[_]i64{ 101, 102, 103 });
}

test "Stream wakes a consumer parked on a different scheduler" {
    const allocator = std.testing.allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var shutdown = std.atomic.Value(bool).init(false);
    var worker_ready = std.atomic.Value(usize).init(0);
    var worker_sched_ptr = std.atomic.Value(usize).init(0);

    const WorkerCtx = struct {
        allocator: std.mem.Allocator,
        global_ctx: *EbrContext,
        stack_pool: *fm.StackPool,
        shutdown: *std.atomic.Value(bool),
        ready: *std.atomic.Value(usize),
        sched_ptr: *std.atomic.Value(usize),
    };

    const workerMain = struct {
        fn run(ctx: *WorkerCtx) void {
            var worker_sched = fp.Scheduler.init(ctx.allocator, ctx.global_ctx, ctx.stack_pool) catch return;
            defer worker_sched.deinit();
            worker_sched.shutdown_on_idle = false;
            worker_sched.global_shutdown = ctx.shutdown;
            fp.active_scheduler = &worker_sched;
            fp.scheduler_running = true;
            ctx.sched_ptr.store(@intFromPtr(&worker_sched), .release);
            _ = ctx.ready.fetchAdd(1, .acq_rel);
            worker_sched.run();
            fp.scheduler_running = false;
            ctx.sched_ptr.store(0, .release);
        }
    }.run;

    var worker_ctx = WorkerCtx{
        .allocator = allocator,
        .global_ctx = &global_ctx,
        .stack_pool = &stack_pool,
        .shutdown = &shutdown,
        .ready = &worker_ready,
        .sched_ptr = &worker_sched_ptr,
    };

    const worker = try std.Thread.spawn(.{}, workerMain, .{&worker_ctx});
    defer {
        shutdown.store(true, .release);
        fp.global_registry.notifyAll();
        worker.join();
        fp.global_registry.deinit(allocator);
    }

    const deadline = compat.milliTimestamp() + 5_000;
    while (worker_ready.load(.acquire) == 0 and compat.milliTimestamp() < deadline) {
        compat.sleepNs(std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 1), worker_ready.load(.acquire));

    const worker_sched = @as(*fp.Scheduler, @ptrFromInt(worker_sched_ptr.load(.acquire)));

    var source_sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer source_sched.deinit();

    const S = CheatLib.Stream(i64);
    var stream = try S.spawnNew(allocator, &source_sched);
    defer stream.deinit();

    var ready = std.atomic.Value(usize).init(0);
    var completed = std.atomic.Value(usize).init(0);
    var state = PlainStreamCrossSchedulerState{
        .stream = stream,
        .ready = &ready,
        .completed = &completed,
    };

    try worker_sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&plainStreamCrossSchedulerConsumer)),
        &state,
        .{ .stack_size = test_stack_size },
    );

    while (ready.load(.acquire) == 0 and compat.milliTimestamp() < deadline) {
        compat.sleepNs(std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 1), ready.load(.acquire));

    var parked = false;
    while (compat.milliTimestamp() < deadline) {
        while (stream.inner.lock.swap(1, .acquire) == 1) std.Thread.yield() catch {};
        parked = stream.inner.consumer_task != null;
        stream.inner.lock.store(0, .release);
        if (parked) break;
    }
    try std.testing.expect(parked);

    var producer = S{ .inner = stream.inner, .alloc = allocator };
    try producer.push(42);
    producer.close();

    while (completed.load(.acquire) == 0 and compat.milliTimestamp() < deadline) {
        compat.sleepNs(std.time.ns_per_ms);
    }

    try std.testing.expectEqual(@as(usize, 1), completed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), state.count);
    try std.testing.expectEqual(@as(i64, 42), state.total);
}

test "Stream close wakes a consumer parked on empty ring" {
    const allocator = std.testing.allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.global_registry.deinit(allocator);

    const S = CheatLib.Stream(i64);
    var stream = try S.spawnNew(allocator, &sched);

    var ready = std.atomic.Value(usize).init(0);
    var completed = std.atomic.Value(usize).init(0);
    var close_completed = std.atomic.Value(usize).init(0);
    var consumer_state = PlainStreamCrossSchedulerState{
        .stream = stream,
        .ready = &ready,
        .completed = &completed,
    };
    var close_state = PlainStreamCloseState{
        .stream = stream,
        .completed = &close_completed,
    };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&plainStreamCloseTask)),
        &close_state,
        .{ .stack_size = test_stack_size },
    );
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&plainStreamCrossSchedulerConsumer)),
        &consumer_state,
        .{ .stack_size = test_stack_size },
    );
    sched.run();

    try std.testing.expectEqual(@as(usize, 1), completed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), close_completed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), consumer_state.count);
    stream.deinit();
}

test "Stream next wakes a producer parked on full ring" {
    const allocator = std.testing.allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.global_registry.deinit(allocator);

    const S = CheatLib.Stream(i64);
    var stream = try S.spawnNew(allocator, &sched);
    defer stream.deinit();

    var completed = std.atomic.Value(usize).init(0);
    var closed = std.atomic.Value(usize).init(0);
    var next_completed = std.atomic.Value(usize).init(0);
    var state = PlainStreamProducerWakeState{
        .stream = stream,
        .attempted = 65,
        .completed = &completed,
        .closed = &closed,
    };
    var next_state = PlainStreamNextWakeState{
        .stream = stream,
        .completed = &next_completed,
    };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&plainStreamNextWakeTask)),
        &next_state,
        .{ .stack_size = test_stack_size },
    );
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&plainStreamFillProducer)),
        &state,
        .{ .stack_size = test_stack_size },
    );
    sched.run();

    try std.testing.expectEqual(@as(usize, 1), completed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), closed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), next_completed.load(.acquire));
    try std.testing.expectEqual(@as(i64, 0), next_state.value);

    var expected: i64 = 1;
    while (try stream.next()) |value| : (expected += 1) {
        try std.testing.expectEqual(expected, value);
    }
    try std.testing.expectEqual(@as(i64, 65), expected);
}

test "Stream deinit wakes a producer parked on full ring" {
    const allocator = std.testing.allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.global_registry.deinit(allocator);

    const S = CheatLib.Stream(i64);
    const stream = try S.spawnNew(allocator, &sched);

    var completed = std.atomic.Value(usize).init(0);
    var closed = std.atomic.Value(usize).init(0);
    var producer_state = PlainStreamProducerWakeState{
        .stream = stream,
        .attempted = 65,
        .completed = &completed,
        .closed = &closed,
    };
    var deinit_completed = std.atomic.Value(usize).init(0);
    var deinit_state = PlainStreamDeinitState{
        .stream = stream,
        .completed = &deinit_completed,
    };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&plainStreamDeinitTask)),
        &deinit_state,
        .{ .stack_size = test_stack_size },
    );
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&plainStreamFillProducer)),
        &producer_state,
        .{ .stack_size = test_stack_size },
    );
    sched.run();

    try std.testing.expectEqual(@as(usize, 0), completed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), closed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), deinit_completed.load(.acquire));
}

test "SplitStream survives multithreaded spawnBest pubsub hammer" {
    if (!build_options.tsan and !build_options.coverage) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    // Keep the pre-existing TSan stress shape. This test already has a
    // dedicated TSan workload; do not shrink it further for stability.
    const subscriber_count = if (build_options.coverage) 3 else if (build_options.tsan) 8 else 16;
    const message_count = if (build_options.coverage) 64 else if (build_options.tsan) 1024 else 4096;
    // kcov ptraces every scheduler OS thread. This hammer's real cross-thread
    // coverage belongs to the TSan lane; under kcov keep the same spawnBest /
    // SplitStream surface on the active scheduler so coverage stays bounded.
    const worker_count = if (build_options.coverage) 0 else if (build_options.tsan) 3 else 7;
    const lock_timeout_ms: i64 = if (build_options.tsan) 300_000 else 30_000;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var shutdown = std.atomic.Value(bool).init(false);
    var ready = std.atomic.Value(usize).init(0);
    var completed = std.atomic.Value(usize).init(0);

    // Two-phase shutdown barrier (mirrors the canonical fix from
    // commit 12499259 applied to versioned-fiber-stress-test.zig and
    // siblings). Workers post-run() fence on `post_run_workers` then
    // block on `deinit_phase` before invoking their per-thread
    // sched.deinit. The test body waits for every worker to be at the
    // fence (proving none is still in handleTaskAfterDispatch's
    // .Finished -> freeStack -> submitRemoteStackFree path) before
    // flipping `deinit_phase` and joining. Without this, T_b's push
    // into T_a's SPSC ring races T_a's `allocator.destroy(ring)` at
    // scheduler.zig:543 -- a cross-scheduler shutdown UAF that leaks
    // the stolen-stack's Fiber and surfaces as `(empty stack trace)`
    // in DebugAllocator's leak report.
    var post_run_workers = std.atomic.Value(u32).init(0);
    var deinit_phase = std.atomic.Value(u32).init(0);

    const WorkerCtx = struct {
        allocator: std.mem.Allocator,
        global_ctx: *EbrContext,
        stack_pool: *fm.StackPool,
        shutdown: *std.atomic.Value(bool),
        post_run_workers: *std.atomic.Value(u32),
        deinit_phase: *std.atomic.Value(u32),
    };

    const workerMain = struct {
        fn run(ctx: *WorkerCtx) void {
            var worker_sched = fp.Scheduler.init(ctx.allocator, ctx.global_ctx, ctx.stack_pool) catch return;
            worker_sched.shutdown_on_idle = false;
            worker_sched.global_shutdown = ctx.shutdown;
            // The default Debug timeout is 100ms, which under TSan-instrumented
            // multi-scheduler stress is sometimes too aggressive — read-lock
            // acquires can take >100ms. Bump for this stress test only.
            if (build_options.tsan or build_options.coverage) worker_sched.lock_timeout_ms = lock_timeout_ms;
            fp.active_scheduler = &worker_sched;
            fp.scheduler_running = true;
            worker_sched.run();
            fp.scheduler_running = false;

            // Phase 1: announce we have left run() and will issue no
            // more cross-scheduler submits.
            _ = ctx.post_run_workers.fetchAdd(1, .release);
            splitHammerFutexWakeAll(ctx.post_run_workers);
            // Phase 2: block until every peer has reached the fence.
            // Past this point no peer is in a submitRemote* path, so
            // freeing our SPSC channels in worker_sched.deinit is safe.
            splitHammerFutexWait(ctx.deinit_phase, 0);
            worker_sched.deinit();
        }
    }.run;

    var worker_ctx = WorkerCtx{
        .allocator = allocator,
        .global_ctx = &global_ctx,
        .stack_pool = &stack_pool,
        .shutdown = &shutdown,
        .post_run_workers = &post_run_workers,
        .deinit_phase = &deinit_phase,
    };

    var workers: [worker_count]std.Thread = undefined;
    for (0..worker_count) |i| {
        workers[i] = try std.Thread.spawn(.{}, workerMain, .{&worker_ctx});
    }
    while (fp.global_registry.count() < worker_count) {
        splitHammerIdleWait();
    }

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(allocator);
    }
    sched.global_shutdown = &shutdown;
    if (build_options.tsan or build_options.coverage) sched.lock_timeout_ms = lock_timeout_ms;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;

    var rt = try Runtime.init(allocator, 4 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const S = CheatLib.SplitStream(i64);
    const seed_stream = try S.spawnNew(allocator, &sched);
    var producer_state = SplitParallelProducerState{
        .stream = makeProducer(i64, seed_stream),
        .message_count = message_count,
        .completed = &completed,
    };

    var subscribers: [subscriber_count]SplitParallelSubscriberState = undefined;
    subscribers[0] = .{ .stream = seed_stream, .ready = &ready, .completed = &completed };
    for (1..subscriber_count) |i| {
        subscribers[i] = .{ .stream = subscribers[0].stream.retain(), .ready = &ready, .completed = &completed };
    }

    for (&subscribers) |*subscriber| {
        try CheatHeader.spawnBest(
            @intFromPtr(&Runtime.entryWrapper),
            @as(qs.TaskFn, @ptrCast(&splitParallelSubscriber)),
            subscriber,
            .{ .stack_size = .Large },
        );
    }

    const ready_deadline = compat.milliTimestamp() + 15_000;
    var ready_idle_ticks: usize = 0;
    while (ready.load(.acquire) < subscriber_count and compat.milliTimestamp() < ready_deadline) {
        if (!sched.pollOne()) {
            splitHammerWakeRemoteSchedulers(&ready_idle_ticks);
        }
    }
    try std.testing.expectEqual(@as(usize, subscriber_count), ready.load(.acquire));

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&splitParallelProducer)),
        &producer_state,
        .{ .stack_size = test_stack_size },
    );

    const expected_completed = subscriber_count + 1;
    // TSan-instrumented runs are dramatically slower than release because
    // every atomic op is intercepted. Combined with the small SpscRing
    // size (which makes producer pushes hit the wait-and-work loop more
    // often), the 15s release deadline isn't enough — the test is
    // correct (no races, no deadlock), just slow under instrumentation.
    const deadline_ms: i64 = if (build_options.tsan or build_options.coverage) 600_000 else 15_000;
    const deadline = compat.milliTimestamp() + deadline_ms;
    var completed_idle_ticks: usize = 0;
    while (completed.load(.acquire) < expected_completed and compat.milliTimestamp() < deadline) {
        if (!sched.pollOne()) {
            splitHammerWakeRemoteSchedulers(&completed_idle_ticks);
        }
    }

    shutdown.store(true, .release);
    fp.global_registry.notifyAll();

    // Two-phase shutdown: wait for every worker to be at its post-run
    // fence (no peer is still in submitRemoteStackFree), then release
    // the deinit barrier so all workers can free their channels in
    // parallel without racing each other's submits.
    const expected_workers = @as(u32, @intCast(worker_count));
    while (post_run_workers.load(.acquire) < expected_workers) {
        fp.global_registry.forceNotifyAll();
        splitHammerFutexWaitOnce(&post_run_workers, post_run_workers.load(.acquire));
    }
    deinit_phase.store(1, .release);
    splitHammerFutexWakeAll(&deinit_phase);

    for (&workers) |*worker| worker.join();

    try std.testing.expectEqual(expected_completed, completed.load(.acquire));

    const expected_total = blk: {
        var total: i64 = 0;
        var i: usize = 0;
        while (i < message_count) : (i += 1) {
            total = total +% splitHammerMix(@as(i64, @intCast(i)));
        }
        break :blk total;
    };

    for (subscribers) |subscriber| {
        try std.testing.expectEqual(@as(usize, message_count), subscriber.count);
        try std.testing.expectEqual(expected_total, subscriber.total);
    }
}

test "concurrentBoundedSelect returns all mapped items in source order" {
    const allocator = std.testing.allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.global_registry.deinit(allocator);

    var rt = try Runtime.init(allocator, 4 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    var state = BoundedSelectState{ .items = try makeBoundedPromiseItems(&rt, .{ 1, 2, 3, 4 }) };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&boundedSelectConsumer)),
        &state,
        .{ .stack_size = test_stack_size },
    );
    sched.run();

    var result = state.results.?;
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), result.items.len);
    try std.testing.expectEqual(@as(i64, 2), result.items[0]);
    try std.testing.expectEqual(@as(i64, 4), result.items[1]);
    try std.testing.expectEqual(@as(i64, 6), result.items[2]);
    try std.testing.expectEqual(@as(i64, 8), result.items[3]);
}

test "concurrentBoundedSelectPreservingErrors retains callback errors as elements" {
    const allocator = std.testing.allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.global_registry.deinit(allocator);

    var rt = try Runtime.init(allocator, 4 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    var state = BoundedPreservedErrorState{ .items = try makeBoundedPromiseItems(&rt, .{ 1, 2, 3, 4 }) };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&boundedSelectPreservedErrorConsumer)),
        &state,
        .{ .stack_size = test_stack_size },
    );
    sched.run();

    var result = state.results.?;
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), result.items.len);
    try std.testing.expectEqual(@as(i64, 1), try result.items[0]);
    try std.testing.expectEqual(@as(i64, 2), try result.items[1]);
    try std.testing.expectError(error.IntentionalBoundedSelect, result.items[2]);
    try std.testing.expectEqual(@as(i64, 4), try result.items[3]);
}

test "concurrentStreamSelectPreservingErrors retains callback errors as elements" {
    const allocator = std.testing.allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.global_registry.deinit(allocator);

    var rt = try Runtime.init(allocator, 4 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const values = [_]i64{ 1, 2, 3, 4 };
    var state = StreamPreservedErrorState{ .source = .{ .items = &values } };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&streamSelectPreservedErrorConsumer)),
        &state,
        .{ .stack_size = test_stack_size },
    );
    sched.run();

    var result = state.results.?;
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), result.items.len);
    var definite_count: usize = 0;
    var saw_preserved_error = false;
    for (result.items) |item| {
        if (item) |_| {
            definite_count += 1;
        } else |err| {
            try std.testing.expectEqual(error.IntentionalBoundedSelect, err);
            saw_preserved_error = true;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), definite_count);
    try std.testing.expect(saw_preserved_error);
}

test "concurrentBoundedWhere filters items and preserves source order" {
    const allocator = std.testing.allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.global_registry.deinit(allocator);

    var rt = try Runtime.init(allocator, 4 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    var state = BoundedSelectState{ .items = try makeBoundedPromiseItems(&rt, .{ 1, 2, 3, 4 }) };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&boundedWhereConsumer)),
        &state,
        .{ .stack_size = test_stack_size },
    );
    sched.run();

    var result = state.results.?;
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqual(@as(i64, 3), result.items[0]);
    try std.testing.expectEqual(@as(i64, 4), result.items[1]);
}

test "concurrentBoundedEach visits every item exactly once" {
    const allocator = std.testing.allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.global_registry.deinit(allocator);

    var rt = try Runtime.init(allocator, 4 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    var state = BoundedEachState{ .items = try makeBoundedPromiseItems(&rt, .{ 10, 20, 30, 40 }) };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&boundedEachConsumer)),
        &state,
        .{ .stack_size = test_stack_size },
    );
    sched.run();

    try std.testing.expectEqual(@as(i64, 100), state.total.load(.seq_cst));
}

test "concurrentBounded callbacks propagate worker errors" {
    const allocator = std.testing.allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.global_registry.deinit(allocator);

    var rt = try Runtime.init(allocator, 4 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    var select_state = BoundedErrorState{ .items = try makeBoundedPromiseItems(&rt, .{ 1, 2, 3, 4 }) };
    var where_state = BoundedErrorState{ .items = try makeBoundedPromiseItems(&rt, .{ 1, 2, 3, 4 }) };
    var each_state = BoundedErrorState{ .items = try makeBoundedPromiseItems(&rt, .{ 10, 20, 30, 40 }) };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&boundedSelectErrorConsumer)),
        &select_state,
        .{ .stack_size = test_stack_size },
    );
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&boundedWhereErrorConsumer)),
        &where_state,
        .{ .stack_size = test_stack_size },
    );
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&boundedEachErrorConsumer)),
        &each_state,
        .{ .stack_size = test_stack_size },
    );
    sched.run();

    try std.testing.expectEqual(error.IntentionalBoundedSelect, select_state.err.?);
    try std.testing.expectEqual(error.IntentionalBoundedWhere, where_state.err.?);
    try std.testing.expectEqual(error.IntentionalBoundedEach, each_state.err.?);
}

test "concurrentListCount and concurrentListReduce compute scalar folds" {
    const allocator = std.testing.allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.global_registry.deinit(allocator);

    var rt = try Runtime.init(allocator, 4 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    var state = ListReduceState{};
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&listReduceConsumer)),
        &state,
        .{ .stack_size = test_stack_size },
    );
    sched.run();

    try std.testing.expectEqual(@as(i64, 4), state.count);
    try std.testing.expectEqual(@as(i64, 21), state.sum);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), state.average, 0.0001);
    try std.testing.expectEqual(@as(i64, 1), state.min);
    try std.testing.expectEqual(@as(i64, 6), state.max);

    try std.testing.expectEqual(@as(i64, 0), state.empty_count);
    try std.testing.expectEqual(@as(i64, 0), state.empty_sum);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), state.empty_average, 0.0001);
    try std.testing.expectEqual(std.math.maxInt(i64), state.empty_min);
    try std.testing.expectEqual(std.math.minInt(i64), state.empty_max);
}

test "concurrentList scalar folds support spawnBest dispatch" {
    const allocator = std.testing.allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.global_registry.deinit(allocator);

    var rt = try Runtime.init(allocator, 4 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    var state = ListReduceState{};
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&listReduceParallelConsumer)),
        &state,
        .{ .stack_size = test_stack_size },
    );
    sched.run();

    try std.testing.expectEqual(@as(i64, 4), state.count);
    try std.testing.expectEqual(@as(i64, 21), state.sum);
}

test "concurrentList scalar fold callbacks propagate worker errors" {
    const allocator = std.testing.allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.global_registry.deinit(allocator);

    var rt = try Runtime.init(allocator, 4 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    var state = ListReduceErrorState{};
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&listReduceErrorConsumer)),
        &state,
        .{ .stack_size = test_stack_size },
    );
    sched.run();

    try std.testing.expectEqual(error.IntentionalListCount, state.count_err.?);
    try std.testing.expectEqual(error.IntentionalListReduce, state.reduce_err.?);
}
