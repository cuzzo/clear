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
const fp = CheatHeader.scheduler;
const fm = CheatHeader.fiber_memory;
const qs = @import("queues.zig");

fn fakeSched() *CheatHeader.scheduler.Scheduler {
    return @ptrFromInt(@as(usize, @alignOf(CheatHeader.scheduler.Scheduler)));
}

fn splitNodeCount(comptime T: type, inner: *CheatLib.SplitStream(T).Inner) usize {
    var count: usize = 0;
    var cur = inner.items_head;
    while (cur) |node| : (cur = node.next) count += 1;
    return count;
}

fn makeProducer(comptime T: type, stream: CheatLib.SplitStream(T)) CheatLib.SplitStream(T) {
    return .{
        .inner = stream.inner,
        .alloc = stream.alloc,
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
        rt.heapAlloc(), rt, &state.items, 2, false, .{}, null);
}

fn boundedWhereConsumer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*BoundedSelectState, @ptrCast(@alignCast(raw_args.?)));
    state.results = try CheatLib.concurrentBoundedWhere(i64, 4, boundedKeepGtTwo,
        rt.heapAlloc(), rt, &state.items, 2, false, .{}, null);
}

fn boundedEachConsumer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*BoundedEachState, @ptrCast(@alignCast(raw_args.?)));
    try CheatLib.concurrentBoundedEach(i64, 4, boundedAccumulate,
        rt, &state.items, 2, false, .{}, state);
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

test "Stream has inner, alloc, and head fields" {
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
    try std.testing.expect(found_head);
}

test "Stream.Inner has items and wg fields" {
    const Inner = CheatLib.Stream(f64).Inner;
    const fields = @typeInfo(Inner).@"struct".fields;
    var found_items = false;
    var found_wg    = false;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, "items")) found_items = true;
        if (std.mem.eql(u8, f.name, "wg"))    found_wg    = true;
    }
    try std.testing.expect(found_items);
    try std.testing.expect(found_wg);
}

test "Stream head defaults to 0" {
    // Verify the default value in the head field definition
    const S = CheatLib.Stream(f64);
    const field_defaults = comptime blk: {
        const fields = @typeInfo(S).@"struct".fields;
        var head_default: usize = 999;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, "head")) {
                if (f.default_value_ptr) |ptr| {
                    head_default = @as(*const usize, @ptrCast(@alignCast(ptr))).*;
                }
            }
        }
        break :blk head_default;
    };
    try std.testing.expectEqual(@as(usize, 0), field_defaults);
}

// ---------------------------------------------------------------------------
// push() adds items to Inner.items (simulate generator phase)
// ---------------------------------------------------------------------------

test "Stream.push appends to inner items (direct Inner manipulation)" {
    const S = CheatLib.Stream(f64);
    const alloc = std.testing.allocator;

    const inner = try alloc.create(S.Inner);
    inner.* = .{};  // items starts empty; wg field left undefined (not called)
    defer {
        inner.items.deinit(alloc);
        alloc.destroy(inner);
    }

    // Simulate the generator fiber calling push() on a local stream handle
    var gen_handle = S{ .inner = inner, .alloc = alloc };
    try gen_handle.push(10.0);
    try gen_handle.push(20.0);
    try gen_handle.push(30.0);

    try std.testing.expectEqual(@as(usize, 3), inner.items.items.len);
    try std.testing.expectApproxEqAbs(10.0, inner.items.items[0], 1e-9);
    try std.testing.expectApproxEqAbs(20.0, inner.items.items[1], 1e-9);
    try std.testing.expectApproxEqAbs(30.0, inner.items.items[2], 1e-9);
}

test "Stream.push works for bool type" {
    const S = CheatLib.Stream(bool);
    const alloc = std.testing.allocator;

    const inner = try alloc.create(S.Inner);
    inner.* = .{};
    defer {
        inner.items.deinit(alloc);
        alloc.destroy(inner);
    }

    var gen_handle = S{ .inner = inner, .alloc = alloc };
    try gen_handle.push(true);
    try gen_handle.push(false);

    try std.testing.expectEqual(@as(usize, 2), inner.items.items.len);
    try std.testing.expect(inner.items.items[0] == true);
    try std.testing.expect(inner.items.items[1] == false);
}

// ---------------------------------------------------------------------------
// head advancement via direct field access (validate the algorithm,
// not the scheduler-dependent wait() path)
// ---------------------------------------------------------------------------

test "Stream head advances as items are consumed (simulated)" {
    const S = CheatLib.Stream(f64);
    const alloc = std.testing.allocator;

    const inner = try alloc.create(S.Inner);
    inner.* = .{};
    defer {
        inner.items.deinit(alloc);
        alloc.destroy(inner);
    }

    var consumer = S{ .inner = inner, .alloc = alloc };

    // Push 2 items (simulating generator)
    try consumer.push(100.0);
    try consumer.push(200.0);

    // Simulate the post-wait() part of next() — advance head manually
    try std.testing.expectEqual(@as(usize, 0), consumer.head);
    // First pop
    consumer.head += 1;
    try std.testing.expectEqual(@as(usize, 1), consumer.head);
    // Second pop
    consumer.head += 1;
    try std.testing.expectEqual(@as(usize, 2), consumer.head);
    // Exhausted: head >= items.len
    try std.testing.expect(consumer.head >= inner.items.items.len);
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

test "SplitStream has inner, alloc, next_node, started, and active fields" {
    const S = CheatLib.SplitStream(i64);
    const fields = @typeInfo(S).@"struct".fields;
    var found_inner = false;
    var found_alloc = false;
    var found_next_node = false;
    var found_started = false;
    var found_active = false;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, "inner")) found_inner = true;
        if (std.mem.eql(u8, f.name, "alloc")) found_alloc = true;
        if (std.mem.eql(u8, f.name, "next_node")) found_next_node = true;
        if (std.mem.eql(u8, f.name, "started")) found_started = true;
        if (std.mem.eql(u8, f.name, "active")) found_active = true;
    }
    try std.testing.expect(found_inner);
    try std.testing.expect(found_alloc);
    try std.testing.expect(found_next_node);
    try std.testing.expect(found_started);
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
    try std.testing.expectEqual(@as(usize, 1), stream.inner.items_head.?.remaining_readers);

    try std.testing.expectEqual(@as(?i64, 11), try clone.next());
    try std.testing.expectEqual(@as(usize, 1), splitNodeCount(i64, stream.inner));
    try std.testing.expectEqual(@as(i64, 22), stream.inner.items_head.?.value);
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

    try std.testing.expectEqual(@as(usize, 1), splitNodeCount(i64, stream.inner));
    try std.testing.expectEqual(@as(i64, 8), stream.inner.items_head.?.value);
    try std.testing.expectEqual(@as(usize, 1), stream.inner.owner_count);
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
}

const SplitParallelProducerState = struct {
    stream: CheatLib.SplitStream(i64),
    message_count: usize,
};

fn splitParallelProducer(rt: *Runtime, raw_args: ?*anyopaque) anyerror!void {
    const state = @as(*SplitParallelProducerState, @ptrCast(@alignCast(raw_args.?)));
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
        .{},
    );
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&splitFiberReader)),
        &right_state,
        .{},
    );
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&splitFiberProducer)),
        &producer_state,
        .{},
    );

    sched.run();

    try std.testing.expectEqual(@as(usize, 3), left_state.count);
    try std.testing.expectEqual(@as(usize, 3), right_state.count);
    try std.testing.expectEqualSlices(i64, left_values[0..left_state.count], &[_]i64{ 101, 102, 103 });
    try std.testing.expectEqualSlices(i64, right_values[0..right_state.count], &[_]i64{ 101, 102, 103 });
}

test "SplitStream survives multithreaded spawnBest pubsub hammer" {
    const allocator = std.testing.allocator;
    const subscriber_count = 16;
    const message_count = 4096;
    const worker_count = 7;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var shutdown = std.atomic.Value(bool).init(false);

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
        std.posix.nanosleep(0, std.time.ns_per_ms);
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
    };

    var subscribers: [subscriber_count]SplitParallelSubscriberState = undefined;
    subscribers[0] = .{ .stream = seed_stream };
    for (1..subscriber_count) |i| {
        subscribers[i] = .{ .stream = subscribers[0].stream.retain() };
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
        .{},
    );

    sched.run();

    shutdown.store(true, .release);
    fp.global_registry.notifyAll();
    for (&workers) |*worker| worker.join();

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
        .{},
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
        .{},
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
        .{},
    );
    sched.run();

    try std.testing.expectEqual(@as(i64, 100), state.total.load(.seq_cst));
}
