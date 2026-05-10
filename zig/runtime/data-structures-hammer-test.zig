// data-structures-hammer-test.zig -- TSan hammer coverage for legacy stream/channel wait loops.

const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const fp = CheatHeader.scheduler;
const fm = CheatHeader.fiber_memory;
const qs = @import("queues.zig");
const ebr = CheatHeader.EbrContext;

const allocator = std.heap.c_allocator;

fn runInScheduler(comptime MainCtx: type, ctx: *MainCtx) !void {
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
    if (comptime @hasDecl(MainCtx, "installScheduler")) {
        ctx.installScheduler(&sched);
    }

    var rt = try Runtime.init(allocator, 4 * 1024, &global_ebr);
    defer rt.deinit();
    rt.wireAllocator();

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&MainCtx.run)),
        ctx,
        .{ .stack_size = .Large, .pinned = true },
    );
    sched.run();
}

fn streamProducerParked(comptime S: type, stream: S) bool {
    while (stream.inner.lock.swap(1, .acquire) == 1) std.Thread.yield() catch {};
    const parked = stream.inner.producer_task != null;
    stream.inner.lock.store(0, .release);
    return parked;
}

fn streamConsumerParked(comptime S: type, stream: S) bool {
    while (stream.inner.lock.swap(1, .acquire) == 1) std.Thread.yield() catch {};
    const parked = stream.inner.consumer_task != null;
    stream.inner.lock.store(0, .release);
    return parked;
}

const LegacyStreamNextCtx = struct {
    stream: CheatLib.Stream(i64),
    value: i64 = -1,
    done: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn installScheduler(self: *@This(), sched: *fp.Scheduler) void {
        self.stream.inner.sched = sched;
    }

    fn consumer(_: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.value = (try self.stream.next()).?;
        _ = self.done.fetchAdd(1, .release);
    }

    fn producer(rt: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        var spins: usize = 0;
        while (!streamConsumerParked(CheatLib.Stream(i64), self.stream)) : (spins += 1) {
            if (spins > 100_000) return error.LegacyStreamConsumerDidNotPark;
            rt.checkYield();
        }
        var producer_stream = CheatLib.Stream(i64){ .inner = self.stream.inner, .alloc = allocator };
        try producer_stream.push(42);
        producer_stream.close();
        _ = self.done.fetchAdd(1, .release);
    }

    fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&consumer)), self, .{ .stack_size = .Large });
        try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&producer)), self, .{ .stack_size = .Large });
    }
};

// HAMMER-COVERS: ds.generator-next-park
test "Hammer: legacy Stream next parks on empty and wakes with pushed value" {
    var ctx = LegacyStreamNextCtx{ .stream = try CheatLib.Stream(i64).spawnNew(allocator, undefined) };
    try runInScheduler(LegacyStreamNextCtx, &ctx);
    try std.testing.expectEqual(@as(usize, 2), ctx.done.load(.acquire));
    try std.testing.expectEqual(@as(i64, 42), ctx.value);
    ctx.stream.deinit();
}

const LegacyStreamPushCtx = struct {
    stream: CheatLib.Stream(i64),
    count: usize = 0,
    sum: i64 = 0,
    done: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn installScheduler(self: *@This(), sched: *fp.Scheduler) void {
        self.stream.inner.sched = sched;
    }

    fn producer(_: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        var producer_stream = CheatLib.Stream(i64){ .inner = self.stream.inner, .alloc = allocator };
        for (0..65) |i| try producer_stream.push(@intCast(i));
        producer_stream.close();
        _ = self.done.fetchAdd(1, .release);
    }

    fn consumer(rt: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        var spins: usize = 0;
        while (!streamProducerParked(CheatLib.Stream(i64), self.stream)) : (spins += 1) {
            if (spins > 100_000) return error.LegacyStreamProducerDidNotPark;
            rt.checkYield();
        }
        while (try self.stream.next()) |value| {
            try std.testing.expectEqual(@as(i64, @intCast(self.count)), value);
            self.sum +%= value;
            self.count += 1;
        }
        _ = self.done.fetchAdd(1, .release);
    }

    fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&consumer)), self, .{ .stack_size = .Large });
        try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&producer)), self, .{ .stack_size = .Large });
    }
};

// HAMMER-COVERS: ds.generator-push-park
test "Hammer: legacy Stream push parks on full ring and consumer drains every value" {
    var ctx = LegacyStreamPushCtx{ .stream = try CheatLib.Stream(i64).spawnNew(allocator, undefined) };
    try runInScheduler(LegacyStreamPushCtx, &ctx);
    try std.testing.expectEqual(@as(usize, 2), ctx.done.load(.acquire));
    try std.testing.expectEqual(@as(usize, 65), ctx.count);
    try std.testing.expectEqual(@as(i64, 2080), ctx.sum);
    ctx.stream.deinit();
}

const InfNextCtx = struct {
    stream: CheatLib.InfStream(i64),
    value: i64 = -1,
    done: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn installScheduler(self: *@This(), sched: *fp.Scheduler) void {
        self.stream.inner.sched = sched;
    }

    fn consumer(_: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.value = try self.stream.next();
        _ = self.done.fetchAdd(1, .release);
    }

    fn producer(rt: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        var spins: usize = 0;
        while (!streamConsumerParked(CheatLib.InfStream(i64), self.stream)) : (spins += 1) {
            if (spins > 100_000) return error.InfStreamConsumerDidNotPark;
            rt.checkYield();
        }
        var producer_stream = CheatLib.InfStream(i64){ .inner = self.stream.inner, .alloc = allocator };
        try producer_stream.push(7);
        producer_stream.close();
        _ = self.done.fetchAdd(1, .release);
    }

    fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&consumer)), self, .{ .stack_size = .Large });
        try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&producer)), self, .{ .stack_size = .Large });
    }
};

// HAMMER-COVERS: ds.stream-next-park
test "Hammer: InfStream next parks on empty and wakes with pushed value" {
    var ctx = InfNextCtx{ .stream = try CheatLib.InfStream(i64).spawnNew(allocator, undefined) };
    try runInScheduler(InfNextCtx, &ctx);
    try std.testing.expectEqual(@as(usize, 2), ctx.done.load(.acquire));
    try std.testing.expectEqual(@as(i64, 7), ctx.value);
    ctx.stream.deinit();
}

const InfNextOrNullCtx = struct {
    stream: CheatLib.InfStream(i64),
    value: ?i64 = null,
    eof: bool = false,
    done: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn installScheduler(self: *@This(), sched: *fp.Scheduler) void {
        self.stream.inner.sched = sched;
    }

    fn consumer(_: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.value = try self.stream.nextOrNull();
        self.eof = (try self.stream.nextOrNull()) == null;
        _ = self.done.fetchAdd(1, .release);
    }

    fn producer(rt: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        var spins: usize = 0;
        while (!streamConsumerParked(CheatLib.InfStream(i64), self.stream)) : (spins += 1) {
            if (spins > 100_000) return error.InfStreamConsumerDidNotPark;
            rt.checkYield();
        }
        var producer_stream = CheatLib.InfStream(i64){ .inner = self.stream.inner, .alloc = allocator };
        try producer_stream.push(11);
        producer_stream.close();
        _ = self.done.fetchAdd(1, .release);
    }

    fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&consumer)), self, .{ .stack_size = .Large });
        try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&producer)), self, .{ .stack_size = .Large });
    }
};

// HAMMER-COVERS: ds.stream-next-or-null-park
test "Hammer: InfStream nextOrNull parks on empty, receives value, then observes EOF" {
    var ctx = InfNextOrNullCtx{ .stream = try CheatLib.InfStream(i64).spawnNew(allocator, undefined) };
    try runInScheduler(InfNextOrNullCtx, &ctx);
    try std.testing.expectEqual(@as(usize, 2), ctx.done.load(.acquire));
    try std.testing.expectEqual(@as(?i64, 11), ctx.value);
    try std.testing.expect(ctx.eof);
    ctx.stream.deinit();
}

const InfPushCtx = struct {
    stream: CheatLib.InfStream(i64),
    count: usize = 0,
    sum: i64 = 0,
    done: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn installScheduler(self: *@This(), sched: *fp.Scheduler) void {
        self.stream.inner.sched = sched;
    }

    fn producer(_: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        var producer_stream = CheatLib.InfStream(i64){ .inner = self.stream.inner, .alloc = allocator };
        for (0..65) |i| try producer_stream.push(@intCast(i));
        producer_stream.close();
        _ = self.done.fetchAdd(1, .release);
    }

    fn consumer(rt: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        var spins: usize = 0;
        while (!streamProducerParked(CheatLib.InfStream(i64), self.stream)) : (spins += 1) {
            if (spins > 100_000) return error.InfStreamProducerDidNotPark;
            rt.checkYield();
        }
        while (try self.stream.nextOrNull()) |value| {
            try std.testing.expectEqual(@as(i64, @intCast(self.count)), value);
            self.sum +%= value;
            self.count += 1;
        }
        _ = self.done.fetchAdd(1, .release);
    }

    fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&consumer)), self, .{ .stack_size = .Large });
        try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&producer)), self, .{ .stack_size = .Large });
    }
};

// HAMMER-COVERS: ds.stream-push-park
test "Hammer: InfStream push parks on full ring and consumer drains every value" {
    var ctx = InfPushCtx{ .stream = try CheatLib.InfStream(i64).spawnNew(allocator, undefined) };
    try runInScheduler(InfPushCtx, &ctx);
    try std.testing.expectEqual(@as(usize, 2), ctx.done.load(.acquire));
    try std.testing.expectEqual(@as(usize, 65), ctx.count);
    try std.testing.expectEqual(@as(i64, 2080), ctx.sum);
    ctx.stream.deinit();
}

fn channelProducerParked(comptime C: type, channel: C) bool {
    channel.inner.mutex.lock();
    const parked = channel.inner.producer_parked and channel.inner.producer_task != null;
    channel.inner.mutex.unlock();
    return parked;
}

fn channelConsumerParked(comptime C: type, channel: C) bool {
    channel.inner.mutex.lock();
    var parked = false;
    for (channel.inner.consumer_tasks) |task| {
        if (task != null) {
            parked = true;
            break;
        }
    }
    channel.inner.mutex.unlock();
    return parked;
}

const ChannelPopCtx = struct {
    channel: CheatLib.BoundedChannel(i64),
    value: ?i64 = null,
    eof: bool = false,
    done: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn consumer(_: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.value = try self.channel.pop();
        self.eof = (try self.channel.pop()) == null;
        _ = self.done.fetchAdd(1, .release);
    }

    fn producer(rt: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        var spins: usize = 0;
        while (!channelConsumerParked(CheatLib.BoundedChannel(i64), self.channel)) : (spins += 1) {
            if (spins > 100_000) return error.ChannelConsumerDidNotPark;
            rt.checkYield();
        }
        try self.channel.push(33);
        self.channel.close();
        _ = self.done.fetchAdd(1, .release);
    }

    fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&consumer)), self, .{ .stack_size = .Large });
        try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&producer)), self, .{ .stack_size = .Large });
    }
};

// HAMMER-COVERS: ds.channel-pop-park
test "Hammer: BoundedChannel pop parks on empty and wakes with pushed item" {
    var ctx = ChannelPopCtx{ .channel = try CheatLib.BoundedChannel(i64).init(allocator, 2) };
    defer ctx.channel.deinit();
    try runInScheduler(ChannelPopCtx, &ctx);
    try std.testing.expectEqual(@as(usize, 2), ctx.done.load(.acquire));
    try std.testing.expectEqual(@as(?i64, 33), ctx.value);
    try std.testing.expect(ctx.eof);
}

const ChannelPushCtx = struct {
    channel: CheatLib.BoundedChannel(i64),
    count: usize = 0,
    sum: i64 = 0,
    done: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    fn producer(_: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        for (0..3) |i| try self.channel.push(@intCast(i));
        self.channel.close();
        _ = self.done.fetchAdd(1, .release);
    }

    fn consumer(rt: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        var spins: usize = 0;
        while (!channelProducerParked(CheatLib.BoundedChannel(i64), self.channel)) : (spins += 1) {
            if (spins > 100_000) return error.ChannelProducerDidNotPark;
            rt.checkYield();
        }
        while (try self.channel.pop()) |value| {
            try std.testing.expectEqual(@as(i64, @intCast(self.count)), value);
            self.sum +%= value;
            self.count += 1;
        }
        _ = self.done.fetchAdd(1, .release);
    }

    fn run(_: *Runtime, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&consumer)), self, .{ .stack_size = .Large });
        try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&producer)), self, .{ .stack_size = .Large });
    }
};

// HAMMER-COVERS: ds.channel-push-park
test "Hammer: BoundedChannel push parks on full ring and consumer drains every item" {
    var ctx = ChannelPushCtx{ .channel = try CheatLib.BoundedChannel(i64).init(allocator, 2) };
    defer ctx.channel.deinit();
    try runInScheduler(ChannelPushCtx, &ctx);
    try std.testing.expectEqual(@as(usize, 2), ctx.done.load(.acquire));
    try std.testing.expectEqual(@as(usize, 3), ctx.count);
    try std.testing.expectEqual(@as(i64, 3), ctx.sum);
}
