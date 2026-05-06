// stream-test.zig
// Unit tests for CheatLib.Stream(T) — Phase 3 open/closeable streams.
//
// Full behavioral tests (concurrent generator fiber, multi-YIELD) require a
// live scheduler and are covered by transpile-tests/75_open_stream.cht.
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

fn fakeSched() *CheatHeader.scheduler.Scheduler {
    return @ptrFromInt(@as(usize, @alignOf(CheatHeader.scheduler.Scheduler)));
}

fn splitNodeCount(comptime T: type, inner: *CheatLib.SplitStream(T).Inner) usize {
    var count: usize = 0;
    var cur = inner.chunks_head;
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

fn boundedAccumulate(_: *Runtime, raw_args: ?*anyopaque, value: i64) anyerror!void {
    const state = @as(*BoundedEachState, @ptrCast(@alignCast(raw_args.?)));
    _ = state.total.fetchAdd(value, .seq_cst);
}

fn boundedSelectConsumer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*BoundedSelectState, @ptrCast(@alignCast(raw_args.?)));
    state.results = try CheatLib.concurrentBoundedSelect(i64, i64, 4, boundedMapDouble,
        rt.heapAlloc(), rt, &state.items, 2, 3, false, .{}, null);
}

fn boundedWhereConsumer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*BoundedSelectState, @ptrCast(@alignCast(raw_args.?)));
    state.results = try CheatLib.concurrentBoundedWhere(i64, 4, boundedKeepGtTwo,
        rt.heapAlloc(), rt, &state.items, 2, 3, false, .{}, null);
}

fn boundedEachConsumer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*BoundedEachState, @ptrCast(@alignCast(raw_args.?)));
    try CheatLib.concurrentBoundedEach(i64, 4, boundedAccumulate,
        rt, &state.items, 2, 3, false, .{}, state);
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
    var found_head  = false;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, "inner")) found_inner = true;
        if (std.mem.eql(u8, f.name, "alloc")) found_alloc = true;
        if (std.mem.eql(u8, f.name, "head"))  found_head  = true;
    }
    try std.testing.expect(found_inner);
    try std.testing.expect(found_alloc);
    try std.testing.expect(!found_head); // ring buffer — no consumer head field on the handle
}

test "Stream.Inner has ring buffer fields, wg, closed, err (no items ArrayList)" {
    const Inner = CheatLib.Stream(f64).Inner;
    const fields = @typeInfo(Inner).@"struct".fields;
    var found_buf    = false;
    var found_head   = false;
    var found_tail   = false;
    var found_closed = false;
    var found_wg     = false;
    var found_items  = false;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, "buf"))    found_buf    = true;
        if (std.mem.eql(u8, f.name, "head"))   found_head   = true;
        if (std.mem.eql(u8, f.name, "tail"))   found_tail   = true;
        if (std.mem.eql(u8, f.name, "closed")) found_closed = true;
        if (std.mem.eql(u8, f.name, "wg"))     found_wg     = true;
        if (std.mem.eql(u8, f.name, "items"))  found_items  = true;
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

    try std.testing.expectEqual(@as(?bool, true),  try stream.next());
    try std.testing.expectEqual(@as(?bool, false), try stream.next());
    try std.testing.expectEqual(@as(?bool, null),  try stream.next());

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
    const S  = CheatLib.Stream(f64);
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
    try std.testing.expectEqual(@as(i64, 11), stream.inner.chunks_head.?.values[0]);
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
    try std.testing.expectEqual(@as(i64, 8), stream.inner.chunks_head.?.values[1]);
    try std.testing.expectEqual(@as(usize, 1), stream.inner.active_subscribers);
}

test "SplitStream drops producer values immediately when no owners remain" {
    const S = CheatLib.SplitStream([]const u8);
    var stream = try S.spawnNew(std.testing.allocator, fakeSched());

    var producer = makeProducer([]const u8, stream);
    stream.deinit();

    const msg = try std.testing.allocator.dupe(u8, "orphaned");
    try producer.push(msg);
    producer.close();
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
    completed: *std.atomic.Value(usize),
};

fn splitParallelSubscriber(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*SplitParallelSubscriberState, @ptrCast(@alignCast(raw_args.?)));
    defer state.stream.deinit();

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
    _ = state.completed.fetchAdd(1, .acq_rel);
}

const SplitParallelProducerState = struct {
    stream: CheatLib.SplitStream(i64),
    message_count: usize,
    completed: *std.atomic.Value(usize),
};

fn splitParallelProducer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*SplitParallelProducerState, @ptrCast(@alignCast(raw_args.?)));
    defer state.stream.close();

    var i: usize = 0;
    while (i < state.message_count) : (i += 1) {
        try state.stream.push(@as(i64, @intCast(i)));
        if ((i & 63) == 0) rt.checkYield();
    }
    _ = state.completed.fetchAdd(1, .acq_rel);
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
    const subscriber_count = if (build_options.coverage) 3 else 16;
    const message_count = if (build_options.coverage) 64 else 4096;
    // kcov ptraces every scheduler OS thread. This hammer's real cross-thread
    // coverage belongs to the TSan lane; under kcov keep the same spawnBest /
    // SplitStream surface on the active scheduler so coverage stays bounded.
    const worker_count = if (build_options.coverage) 0 else 7;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var shutdown = std.atomic.Value(bool).init(false);
    var completed = std.atomic.Value(usize).init(0);

    const WorkerCtx = struct {
        allocator: std.mem.Allocator,
        global_ctx: *EbrContext,
        stack_pool: *fm.StackPool,
        shutdown: *std.atomic.Value(bool),
    };

    const workerMain = struct {
        fn run(ctx: *WorkerCtx) void {
            var worker_sched = fp.Scheduler.init(ctx.allocator, ctx.global_ctx, ctx.stack_pool) catch return;
            defer worker_sched.deinit();
            worker_sched.shutdown_on_idle = false;
            worker_sched.global_shutdown = ctx.shutdown;
            fp.active_scheduler = &worker_sched;
            fp.scheduler_running = true;
            worker_sched.run();
            fp.scheduler_running = false;
        }
    }.run;

    var worker_ctx = WorkerCtx{
        .allocator = allocator,
        .global_ctx = &global_ctx,
        .stack_pool = &stack_pool,
        .shutdown = &shutdown,
    };

    var workers: [worker_count]std.Thread = undefined;
    for (0..worker_count) |i| {
        workers[i] = try std.Thread.spawn(.{}, workerMain, .{&worker_ctx});
    }
    while (fp.global_registry.count() < worker_count) {
        compat.sleepNs(std.time.ns_per_ms);
    }

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(allocator);
    }
    sched.global_shutdown = &shutdown;
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
    subscribers[0] = .{ .stream = seed_stream, .completed = &completed };
    for (1..subscriber_count) |i| {
        subscribers[i] = .{ .stream = subscribers[0].stream.retain(), .completed = &completed };
    }

    for (&subscribers) |*subscriber| {
        try CheatHeader.spawnBest(
            @intFromPtr(&Runtime.entryWrapper),
            @as(qs.TaskFn, @ptrCast(&splitParallelSubscriber)),
            subscriber,
            .{ .stack_size = .Large },
        );
    }

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&splitParallelProducer)),
        &producer_state,
        .{ .stack_size = test_stack_size },
    );

    const expected_completed = subscriber_count + 1;
    const deadline = compat.milliTimestamp() + 15_000;
    while (completed.load(.acquire) < expected_completed and compat.milliTimestamp() < deadline) {
        sched.drainChannels();
        if (sched.ready_queue.len() > 0) {
            const task = sched.ready_queue.pop() orelse continue;
            sched.current_task = task;
            fc.__current_task_fn = @intFromPtr(task.user_fn);
            fc.__current_task_size = task.base.size_class;
            task.base.switchTo(&sched.main_ctx);
            switch (task.status.load(.acquire)) {
                .Finished => {
                    _ = sched.active_tasks.fetchSub(1, .monotonic);
                    sched.releaseTaskEbr(task);
                    sched.freeStack(task.base.stack);
                    sched.allocator.destroy(task.base);
                    sched.task_slab.destroy(task);
                },
                .Ready => {
                    sched.ready_queue.push(sched.allocator, task) catch unreachable;
                },
                .Blocked => {},
            }
        } else {
            compat.sleepNs(std.time.ns_per_ms);
        }
    }

    shutdown.store(true, .release);
    fp.global_registry.notifyAll();
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
