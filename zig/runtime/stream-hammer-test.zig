// stream-hammer-test.zig -- TSan hammer coverage for stream wait loops.

const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const fp = CheatHeader.scheduler;
const fm = CheatHeader.fiber_memory;
const fc = @import("fiber-core.zig");
const qs = @import("queues.zig");
const ebr = CheatHeader.EbrContext;

const allocator = std.heap.c_allocator;
const test_stack_size: fc.StackSize = .Large;

fn makeProducer(comptime T: type, stream: CheatLib.SplitStream(T)) CheatLib.SplitStream(T) {
    return .{
        .inner = stream.inner,
        .alloc = stream.alloc,
        .subscriber_id = std.math.maxInt(usize),
        .next_seq = stream.next_seq,
        .active = false,
    };
}

fn splitProducerParked(stream: CheatLib.SplitStream(i64)) bool {
    return stream.inner.producer_parked.load(.acquire) != 0 and
        stream.inner.producer_task.load(.acquire) != null;
}

fn splitSubscriberParked(stream: CheatLib.SplitStream(i64)) bool {
    if (stream.subscriber_id == std.math.maxInt(usize)) return false;
    const rec = &stream.inner.subscribers.items[stream.subscriber_id];
    return rec.parked.load(.acquire) != 0 and rec.task.load(.acquire) != null;
}

const SplitNextConsumer = struct {
    stream: CheatLib.SplitStream(i64),
    ready: *std.atomic.Value(usize),
    completed: *std.atomic.Value(usize),
    value: i64 = -1,

    fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        _ = self.ready.fetchAdd(1, .release);
        defer self.stream.deinit();
        const got = (try self.stream.next()) orelse return error.ExpectedSplitValue;
        self.value = got;
        try std.testing.expectEqual(@as(?i64, null), try self.stream.next());
        _ = self.completed.fetchAdd(1, .release);
    }
};

const SplitNextProducer = struct {
    stream: CheatLib.SplitStream(i64),
    watched: *CheatLib.SplitStream(i64),
    completed: *std.atomic.Value(usize),

    fn run(rt: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        var spins: usize = 0;
        while (!splitSubscriberParked(self.watched.*)) : (spins += 1) {
            if (spins > 100_000) return error.SplitSubscriberDidNotPark;
            rt.checkYield();
        }
        try self.stream.push(42);
        self.stream.close();
        _ = self.completed.fetchAdd(1, .release);
    }
};

// HAMMER-COVERS: streams.next-park
test "Hammer: SplitStream next parks an empty subscriber and push wakes it with the value" {
    var global_ebr = ebr{};
    defer global_ebr.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(allocator, &global_ebr, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(allocator);
    }
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;

    var rt = try Runtime.init(allocator, 4 * 1024, &global_ebr);
    defer rt.deinit();
    rt.wireAllocator();

    const S = CheatLib.SplitStream(i64);
    var stream = try S.spawnNew(allocator, &sched);
    var consumer_stream = stream.retain();
    const producer_stream = makeProducer(i64, stream);
    var ready = std.atomic.Value(usize).init(0);
    var consumer_done = std.atomic.Value(usize).init(0);
    var producer_done = std.atomic.Value(usize).init(0);
    var consumer = SplitNextConsumer{
        .stream = consumer_stream,
        .ready = &ready,
        .completed = &consumer_done,
    };
    var producer = SplitNextProducer{
        .stream = producer_stream,
        .watched = &consumer_stream,
        .completed = &producer_done,
    };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&SplitNextConsumer.run)),
        &consumer,
        .{ .stack_size = test_stack_size },
    );
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&SplitNextProducer.run)),
        &producer,
        .{ .stack_size = test_stack_size },
    );
    sched.run();

    try std.testing.expectEqual(@as(usize, 1), ready.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), producer_done.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), consumer_done.load(.acquire));
    try std.testing.expectEqual(@as(i64, 42), consumer.value);
    stream.deinit();
}

const SplitBackpressureProducer = struct {
    stream: CheatLib.SplitStream(i64),
    attempted: usize,
    completed: *std.atomic.Value(usize),

    fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        defer self.stream.close();
        for (0..self.attempted) |i| {
            try self.stream.push(@intCast(i));
        }
        _ = self.completed.fetchAdd(1, .release);
    }
};

const SplitBackpressureDrain = struct {
    stream: CheatLib.SplitStream(i64),
    producer_stream: *CheatLib.SplitStream(i64),
    expected: usize,
    completed: *std.atomic.Value(usize),
    count: usize = 0,
    sum: i64 = 0,

    fn run(rt: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        defer self.stream.deinit();
        var spins: usize = 0;
        while (!splitProducerParked(self.producer_stream.*)) : (spins += 1) {
            if (spins > 200_000) return error.SplitProducerDidNotPark;
            rt.checkYield();
        }
        while (try self.stream.next()) |value| {
            try std.testing.expectEqual(@as(i64, @intCast(self.count)), value);
            self.sum +%= value;
            self.count += 1;
        }
        try std.testing.expectEqual(self.expected, self.count);
        _ = self.completed.fetchAdd(1, .release);
    }
};

// HAMMER-COVERS: streams.push-backpressure-park
test "Hammer: SplitStream producer parks on backpressure and a slow subscriber drains every value" {
    var global_ebr = ebr{};
    defer global_ebr.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(allocator, &global_ebr, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(allocator);
    }
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;

    var rt = try Runtime.init(allocator, 4 * 1024, &global_ebr);
    defer rt.deinit();
    rt.wireAllocator();

    const S = CheatLib.SplitStream(i64);
    var stream = try S.spawnNew(allocator, &sched);
    const slow_subscriber = stream.retain();
    var producer_stream = makeProducer(i64, stream);

    const total_messages = 16 * 256 + 17;
    var producer_done = std.atomic.Value(usize).init(0);
    var drain_done = std.atomic.Value(usize).init(0);
    var producer = SplitBackpressureProducer{
        .stream = producer_stream,
        .attempted = total_messages,
        .completed = &producer_done,
    };
    var drain = SplitBackpressureDrain{
        .stream = slow_subscriber,
        .producer_stream = &producer_stream,
        .expected = total_messages,
        .completed = &drain_done,
    };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&SplitBackpressureDrain.run)),
        &drain,
        .{ .stack_size = test_stack_size },
    );
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&SplitBackpressureProducer.run)),
        &producer,
        .{ .stack_size = test_stack_size },
    );
    sched.run();

    try std.testing.expectEqual(@as(usize, 1), producer_done.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), drain_done.load(.acquire));
    try std.testing.expectEqual(total_messages, drain.count);
    var expected_sum: i64 = 0;
    for (0..total_messages) |i| expected_sum +%= @intCast(i);
    try std.testing.expectEqual(expected_sum, drain.sum);
    stream.deinit();
}
