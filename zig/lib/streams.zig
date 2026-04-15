const std = @import("std");
const compat = @import("compat");
const fp = @import("../runtime/scheduler.zig");
const qs = @import("../runtime/queues.zig");

const Scheduler = fp.Scheduler;
const Task = qs.Task;

pub const Range = struct {
    start: f64,
    end: f64,
    current: f64 = 0,
    started: bool = false,

    pub fn next(self: *Range) anyerror!?f64 {
        return self.nextOrNull();
    }

    pub fn nextOrNull(self: *Range) anyerror!?f64 {
        if (!self.started) {
            self.current = self.start;
            self.started = true;
        }
        if (self.current >= self.end) return null;
        const out = self.current;
        self.current += 1.0;
        return out;
    }

    pub fn toList(self: Range, allocator: std.mem.Allocator) !std.ArrayListUnmanaged(f64) {
        const count = if (self.end > self.start) @as(usize, @intFromFloat(self.end - self.start)) else 0;
        var list = try std.ArrayListUnmanaged(f64).initCapacity(allocator, count);
        var cur = self.start;
        while (cur < self.end) : (cur += 1.0) {
            list.appendAssumeCapacity(cur);
        }
        return list;
    }

    pub fn deinit(self: *Range) void {
        _ = self;
    }
};

pub const IntRange = struct {
    start: i64,
    end: i64,
    current: i64 = 0,
    started: bool = false,

    pub fn next(self: *IntRange) anyerror!?i64 {
        return self.nextOrNull();
    }

    pub fn nextOrNull(self: *IntRange) anyerror!?i64 {
        if (!self.started) {
            self.current = self.start;
            self.started = true;
        }
        if (self.current >= self.end) return null;
        const out = self.current;
        self.current += 1;
        return out;
    }

    pub fn toList(self: IntRange, allocator: std.mem.Allocator) !std.ArrayListUnmanaged(i64) {
        const count = if (self.end > self.start) @as(usize, @intCast(self.end - self.start)) else 0;
        var list = try std.ArrayListUnmanaged(i64).initCapacity(allocator, count);
        var cur = self.start;
        while (cur < self.end) : (cur += 1) {
            list.appendAssumeCapacity(cur);
        }
        return list;
    }

    pub fn deinit(self: *IntRange) void {
        _ = self;
    }
};

pub fn SplitStream(
    comptime T: type,
    comptime WaitGroupType: type,
    comptime cloneValue: fn (std.mem.Allocator, T) anyerror!T,
    comptime cleanupValue: fn (std.mem.Allocator, *T) void,
) type {
    return struct {
        const Self = @This();
        const ChunkCap = 256;
        const PublishQuantum = ChunkCap;
        const InvalidSubscriber = std.math.maxInt(usize);

        const Chunk = struct {
            start_seq: usize,
            len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
            write_len: usize = 0,
            values: [ChunkCap]T = undefined,
            next: ?*Chunk = null,
        };

        const SubscriberRecord = struct {
            active: bool = false,
            seq: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
            parked: bool = false,
            task: ?*Task = null,
            sched: ?*Scheduler = null,
        };

        pub const Inner = struct {
            alloc: std.mem.Allocator,
            chunks_head: ?*Chunk = null,
            chunks_tail: ?*Chunk = null,
            head_seq: usize = 0,
            tail_seq: usize = 0,
            wg: WaitGroupType = undefined,
            subscribers: std.ArrayListUnmanaged(SubscriberRecord) = .empty,
            active_subscribers: usize = 0,
            err: ?anyerror = null,
            closed: bool = false,
            mutex: compat.Mutex = .{},
        };

        inner: *Inner,
        alloc: std.mem.Allocator,
        subscriber_id: usize = InvalidSubscriber,
        next_seq: usize = 0,
        next_chunk: ?*Chunk = null,
        next_index: usize = 0,
        active: bool = true,

        const ChunkCursor = struct {
            chunk: *Chunk,
            index: usize,
        };

        fn destroyChunk(inner: *Inner, chunk: *Chunk) void {
            for (0..chunk.write_len) |i| {
                cleanupValue(inner.alloc, &chunk.values[i]);
            }
            inner.alloc.destroy(chunk);
        }

        fn minReadSeq(inner: *Inner) usize {
            var min_seq = inner.tail_seq;
            var any_live = false;
            for (inner.subscribers.items) |record| {
                if (!record.active) continue;
                any_live = true;
                const seq = record.seq.load(.acquire);
                if (seq < min_seq) min_seq = seq;
            }
            return if (any_live) min_seq else inner.tail_seq;
        }

        fn releaseConsumedPrefix(inner: *Inner) void {
            while (inner.chunks_head) |head| {
                const published = head.len.load(.acquire);
                if (published == 0) break;
                if (head.start_seq + published > minReadSeq(inner)) break;
                inner.chunks_head = head.next;
                inner.head_seq = head.start_seq + published;
                if (inner.chunks_head == null) inner.chunks_tail = null;
                destroyChunk(inner, head);
            }
        }

        fn clearAllChunks(inner: *Inner) void {
            var cur = inner.chunks_head;
            while (cur) |chunk| {
                const next_chunk = chunk.next;
                destroyChunk(inner, chunk);
                cur = next_chunk;
            }
            inner.chunks_head = null;
            inner.chunks_tail = null;
            inner.head_seq = inner.tail_seq;
        }

        fn destroyInner(inner: *Inner) void {
            inner.subscribers.deinit(inner.alloc);
            inner.alloc.destroy(inner);
        }

        fn wakeParkedSubscribers(inner: *Inner) void {
            for (inner.subscribers.items) |*record| {
                if (!record.active or !record.parked) continue;
                record.parked = false;
                if (record.sched) |sched| {
                    if (record.task) |task| {
                        sched.schedule(task);
                    }
                }
            }
        }

        fn findCursor(inner: *Inner, seq: usize) ?ChunkCursor {
            if (seq < inner.head_seq or seq >= inner.tail_seq) return null;

            var cur = inner.chunks_head;
            while (cur) |chunk| : (cur = chunk.next) {
                const published = chunk.len.load(.acquire);
                const chunk_end = chunk.start_seq + published;
                if (seq >= chunk.start_seq and seq < chunk_end) {
                    return .{ .chunk = chunk, .index = seq - chunk.start_seq };
                }
            }
            return null;
        }

        fn currentCursor(self: *const Self) ?ChunkCursor {
            if (self.next_chunk) |chunk| {
                if (self.next_index < chunk.len.load(.acquire) and chunk.start_seq + self.next_index == self.next_seq) {
                    return .{ .chunk = chunk, .index = self.next_index };
                }
            }
            return findCursor(self.inner, self.next_seq);
        }

        fn allocSubscriber(inner: *Inner, seq: usize) !usize {
            for (inner.subscribers.items, 0..) |*record, i| {
                if (!record.active) {
                    record.* = .{ .active = true, .seq = std.atomic.Value(usize).init(seq) };
                    inner.active_subscribers += 1;
                    return i;
                }
            }
            try inner.subscribers.append(inner.alloc, .{ .active = true, .seq = std.atomic.Value(usize).init(seq) });
            inner.active_subscribers += 1;
            return inner.subscribers.items.len - 1;
        }

        fn publishChunk(inner: *Inner, chunk: *Chunk) bool {
            const published_len = chunk.len.load(.acquire);
            if (chunk.write_len <= published_len) return false;
            const published = chunk.write_len - published_len;
            chunk.len.store(chunk.write_len, .release);
            inner.tail_seq += published;
            return true;
        }

        pub fn spawnNew(alloc: std.mem.Allocator, sched: anytype) !Self {
            const inner = try alloc.create(Inner);
            inner.* = .{
                .alloc = alloc,
                .wg = WaitGroupType.init(sched),
            };
            const subscriber_id = try allocSubscriber(inner, inner.head_seq);
            return .{
                .inner = inner,
                .alloc = alloc,
                .subscriber_id = subscriber_id,
                .next_seq = inner.head_seq,
            };
        }

        pub fn push(self: *Self, val: T) !void {
            var published = false;
            self.inner.mutex.lock();

            if (self.inner.active_subscribers == 0) {
                self.inner.mutex.unlock();
                var tmp = val;
                cleanupValue(self.inner.alloc, &tmp);
                return;
            }

            var tail = self.inner.chunks_tail;
            if (tail == null or tail.?.write_len == ChunkCap) {
                const chunk = try self.inner.alloc.create(Chunk);
                chunk.* = .{ .start_seq = self.inner.tail_seq };
                if (tail) |existing_tail| {
                    existing_tail.next = chunk;
                } else {
                    self.inner.chunks_head = chunk;
                }
                self.inner.chunks_tail = chunk;
                tail = chunk;
            }

            const chunk = tail.?;
            chunk.values[chunk.write_len] = val;
            chunk.write_len += 1;
            const published_len = chunk.len.load(.acquire);
            if (chunk.write_len == ChunkCap or (chunk.write_len - published_len) >= PublishQuantum) {
                published = publishChunk(self.inner, chunk);
            }
            if (published) {
                wakeParkedSubscribers(self.inner);
            }
            self.inner.mutex.unlock();
        }

        pub fn close(self: *Self) void {
            self.inner.mutex.lock();
            if (self.inner.chunks_tail) |tail| {
                _ = publishChunk(self.inner, tail);
            }
            self.inner.closed = true;
            wakeParkedSubscribers(self.inner);
            const should_destroy = self.inner.active_subscribers == 0;
            self.inner.mutex.unlock();

            if (should_destroy) {
                self.inner.mutex.lock();
                clearAllChunks(self.inner);
                self.inner.mutex.unlock();
                destroyInner(self.inner);
            }
        }

        pub fn setError(self: *Self, err: anyerror) void {
            self.inner.mutex.lock();
            self.inner.err = err;
            wakeParkedSubscribers(self.inner);
            self.inner.mutex.unlock();
        }

        pub fn retain(self: Self) Self {
            std.debug.assert(self.active);

            self.inner.mutex.lock();
            const subscriber_id = allocSubscriber(self.inner, self.next_seq) catch unreachable;
            self.inner.mutex.unlock();

            return .{
                .inner = self.inner,
                .alloc = self.alloc,
                .subscriber_id = subscriber_id,
                .next_seq = self.next_seq,
                .next_chunk = self.next_chunk,
                .next_index = self.next_index,
            };
        }

        pub fn next(self: *Self) anyerror!?T {
            std.debug.assert(self.active);
            while (true) {
                self.inner.mutex.lock();

                if (self.inner.err) |err| {
                    self.inner.mutex.unlock();
                    return err;
                }

                if (self.currentCursor()) |cursor| {
                    const out = try cloneValue(self.inner.alloc, cursor.chunk.values[cursor.index]);
                    const chunk_len = cursor.chunk.len.load(.acquire);
                    const advance_in_same_chunk = cursor.index + 1 < chunk_len;
                    const advance_into_next_chunk = !advance_in_same_chunk and cursor.chunk.next != null;
                    const wait_for_tail_growth = !advance_in_same_chunk and !advance_into_next_chunk and chunk_len < ChunkCap and !self.inner.closed and cursor.chunk == self.inner.chunks_tail;

                    if (advance_in_same_chunk) {
                        self.next_chunk = cursor.chunk;
                        self.next_index = cursor.index + 1;
                    } else if (cursor.chunk.next) |next_chunk| {
                        self.next_chunk = next_chunk;
                        self.next_index = 0;
                    } else if (wait_for_tail_growth) {
                        self.next_chunk = cursor.chunk;
                        self.next_index = cursor.index + 1;
                    } else {
                        self.next_chunk = null;
                        self.next_index = 0;
                    }

                    self.next_seq += 1;
                    if (self.subscriber_id != InvalidSubscriber) {
                        self.inner.subscribers.items[self.subscriber_id].seq.store(self.next_seq, .release);
                    }
                    self.inner.mutex.unlock();
                    return out;
                }

                if (self.inner.closed) {
                    self.inner.mutex.unlock();
                    return null;
                }

                if (fp.scheduler_running and fp.active_scheduler.current_task != null) {
                    const task = fp.active_scheduler.getCurrent();
                    if (self.subscriber_id != InvalidSubscriber) {
                        var record = &self.inner.subscribers.items[self.subscriber_id];
                        record.parked = true;
                        record.task = task;
                        record.sched = fp.active_scheduler;
                    }
                    task.status.store(.Blocked, .release);
                    self.inner.mutex.unlock();
                    task.base.yield();
                } else {
                    self.inner.mutex.unlock();
                    std.Thread.yield() catch {};
                }
            }
        }

        pub fn deinit(self: *Self) void {
            if (!self.active) return;

            var should_destroy = false;
            self.inner.mutex.lock();
            if (self.subscriber_id != InvalidSubscriber) {
                var record = &self.inner.subscribers.items[self.subscriber_id];
                record.active = false;
                record.seq.store(self.inner.tail_seq, .release);
                record.parked = false;
                record.task = null;
                record.sched = null;
                std.debug.assert(self.inner.active_subscribers > 0);
                self.inner.active_subscribers -= 1;
                self.subscriber_id = InvalidSubscriber;
            }
            self.active = false;
            self.next_chunk = null;
            self.next_index = 0;

            if (self.inner.active_subscribers == 0) {
                clearAllChunks(self.inner);
                should_destroy = self.inner.closed;
            } else {
                releaseConsumedPrefix(self.inner);
            }
            self.inner.mutex.unlock();

            if (should_destroy) destroyInner(self.inner);
        }
    };
}

pub fn concurrentBoundedSelect(
    comptime WaitGroupT: type,
    comptime T: type,
    comptime R: type,
    comptime N: usize,
    comptime mapFn: anytype,
    comptime localSpawnFn: anytype,
    comptime parallelSpawnFn: anytype,
    comptime cleanupResultFn: anytype,
    alloc: std.mem.Allocator,
    rt: anytype,
    items: anytype,
    workers: usize,
    parallel: bool,
    task_cfg: anytype,
    user_ctx: ?*anyopaque,
) !std.ArrayListUnmanaged(R) {
    _ = T;
    const ItemsPtr = @TypeOf(items);
    const PromiseT = @typeInfo(@typeInfo(ItemsPtr).pointer.child).array.child;
    const RuntimeT = @TypeOf(rt.*);
    const Slot = ?R;

    const slots = try alloc.alloc(Slot, N);
    defer alloc.free(slots);
    for (slots) |*slot| slot.* = null;
    errdefer {
        for (slots) |*slot| {
            if (slot.*) |*value| cleanupResultFn(alloc, value);
        }
    }

    var err_code = std.atomic.Value(u16).init(0);
    var next_idx = std.atomic.Value(usize).init(0);
    var wg = WaitGroupT.init(rt.getSched());

    const Worker = struct {
        wg: *WaitGroupT,
        items: *[N]PromiseT,
        slots: []Slot,
        next_idx: *std.atomic.Value(usize),
        err_code: *std.atomic.Value(u16),
        user_ctx: ?*anyopaque,

        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const worker_rt = @as(*RuntimeT, @ptrCast(@alignCast(raw_rt)));
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            while (true) {
                const idx = ctx.next_idx.fetchAdd(1, .monotonic);
                if (idx >= N) break;
                const item = try ctx.items[idx].next();
                const mapped = mapFn(worker_rt, ctx.user_ctx, item) catch |err| {
                    _ = ctx.err_code.cmpxchgStrong(0, @intFromError(err), .seq_cst, .seq_cst);
                    continue;
                };
                ctx.slots[idx] = mapped;
                worker_rt.checkYield();
            }
        }
    };

    var worker_ctxs: [64]Worker = undefined;
    const actual_workers = @min(if (workers == 0) @as(usize, 1) else workers, @as(usize, 64));
    if (actual_workers == 0) return .empty;
    wg.add(actual_workers);
    for (0..actual_workers) |i| {
        worker_ctxs[i] = .{
            .wg = &wg,
            .items = items,
            .slots = slots,
            .next_idx = &next_idx,
            .err_code = &err_code,
            .user_ctx = user_ctx,
        };
        if (parallel) {
            try parallelSpawnFn(@ptrCast(&Worker.run), &worker_ctxs[i], task_cfg);
        } else {
            try localSpawnFn(wg.sched, @ptrCast(&Worker.run), &worker_ctxs[i], task_cfg);
        }
    }
    wg.wait();

    const err_int = err_code.load(.seq_cst);
    if (err_int != 0) return @errorFromInt(err_int);

    var count: usize = 0;
    for (slots) |slot| {
        if (slot != null) count += 1;
    }
    var out = try std.ArrayListUnmanaged(R).initCapacity(alloc, count);
    errdefer {
        for (out.items) |*value| cleanupResultFn(alloc, value);
        out.deinit(alloc);
    }
    for (slots) |*slot| {
        if (slot.*) |value| {
            out.appendAssumeCapacity(value);
            slot.* = null;
        }
    }
    return out;
}

pub fn concurrentBoundedWhere(
    comptime WaitGroupT: type,
    comptime T: type,
    comptime N: usize,
    comptime predFn: anytype,
    comptime localSpawnFn: anytype,
    comptime parallelSpawnFn: anytype,
    comptime cleanupItemFn: anytype,
    alloc: std.mem.Allocator,
    rt: anytype,
    items: anytype,
    workers: usize,
    parallel: bool,
    task_cfg: anytype,
    user_ctx: ?*anyopaque,
) !std.ArrayListUnmanaged(T) {
    const ItemsPtr = @TypeOf(items);
    const PromiseT = @typeInfo(@typeInfo(ItemsPtr).pointer.child).array.child;
    const RuntimeT = @TypeOf(rt.*);
    const Slot = ?T;

    const slots = try alloc.alloc(Slot, N);
    defer alloc.free(slots);
    for (slots) |*slot| slot.* = null;
    errdefer {
        for (slots) |*slot| {
            if (slot.*) |*value| cleanupItemFn(alloc, value);
        }
    }

    var err_code = std.atomic.Value(u16).init(0);
    var next_idx = std.atomic.Value(usize).init(0);
    var wg = WaitGroupT.init(rt.getSched());

    const Worker = struct {
        wg: *WaitGroupT,
        items: *[N]PromiseT,
        slots: []Slot,
        alloc: std.mem.Allocator,
        next_idx: *std.atomic.Value(usize),
        err_code: *std.atomic.Value(u16),
        user_ctx: ?*anyopaque,

        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const worker_rt = @as(*RuntimeT, @ptrCast(@alignCast(raw_rt)));
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            while (true) {
                const idx = ctx.next_idx.fetchAdd(1, .monotonic);
                if (idx >= N) break;
                var item = try ctx.items[idx].next();
                const keep = predFn(worker_rt, ctx.user_ctx, item) catch |err| {
                    _ = ctx.err_code.cmpxchgStrong(0, @intFromError(err), .seq_cst, .seq_cst);
                    continue;
                };
                if (keep) {
                    ctx.slots[idx] = item;
                } else {
                    cleanupItemFn(ctx.alloc, &item);
                }
                worker_rt.checkYield();
            }
        }
    };

    var worker_ctxs: [64]Worker = undefined;
    const actual_workers = @min(if (workers == 0) @as(usize, 1) else workers, @as(usize, 64));
    if (actual_workers == 0) return .empty;
    wg.add(actual_workers);
    for (0..actual_workers) |i| {
        worker_ctxs[i] = .{
            .wg = &wg,
            .items = items,
            .slots = slots,
            .alloc = alloc,
            .next_idx = &next_idx,
            .err_code = &err_code,
            .user_ctx = user_ctx,
        };
        if (parallel) {
            try parallelSpawnFn(@ptrCast(&Worker.run), &worker_ctxs[i], task_cfg);
        } else {
            try localSpawnFn(wg.sched, @ptrCast(&Worker.run), &worker_ctxs[i], task_cfg);
        }
    }
    wg.wait();

    const err_int = err_code.load(.seq_cst);
    if (err_int != 0) return @errorFromInt(err_int);

    var count: usize = 0;
    for (slots) |slot| {
        if (slot != null) count += 1;
    }
    var out = try std.ArrayListUnmanaged(T).initCapacity(alloc, count);
    errdefer {
        for (out.items) |*value| cleanupItemFn(alloc, value);
        out.deinit(alloc);
    }
    for (slots) |*slot| {
        if (slot.*) |value| {
            out.appendAssumeCapacity(value);
            slot.* = null;
        }
    }
    return out;
}

pub fn concurrentBoundedEach(
    comptime WaitGroupT: type,
    comptime T: type,
    comptime N: usize,
    comptime eachFn: anytype,
    comptime localSpawnFn: anytype,
    comptime parallelSpawnFn: anytype,
    rt: anytype,
    items: anytype,
    workers: usize,
    parallel: bool,
    task_cfg: anytype,
    user_ctx: ?*anyopaque,
) !void {
    _ = T;
    const ItemsPtr = @TypeOf(items);
    const PromiseT = @typeInfo(@typeInfo(ItemsPtr).pointer.child).array.child;
    const RuntimeT = @TypeOf(rt.*);

    var err_code = std.atomic.Value(u16).init(0);
    var next_idx = std.atomic.Value(usize).init(0);
    var wg = WaitGroupT.init(rt.getSched());

    const Worker = struct {
        wg: *WaitGroupT,
        items: *[N]PromiseT,
        next_idx: *std.atomic.Value(usize),
        err_code: *std.atomic.Value(u16),
        user_ctx: ?*anyopaque,

        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const worker_rt = @as(*RuntimeT, @ptrCast(@alignCast(raw_rt)));
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            while (true) {
                const idx = ctx.next_idx.fetchAdd(1, .monotonic);
                if (idx >= N) break;
                const item = try ctx.items[idx].next();
                eachFn(worker_rt, ctx.user_ctx, item) catch |err| {
                    _ = ctx.err_code.cmpxchgStrong(0, @intFromError(err), .seq_cst, .seq_cst);
                    continue;
                };
                worker_rt.checkYield();
            }
        }
    };

    var worker_ctxs: [64]Worker = undefined;
    const actual_workers = @min(if (workers == 0) @as(usize, 1) else workers, @as(usize, 64));
    if (actual_workers == 0) return;
    wg.add(actual_workers);
    for (0..actual_workers) |i| {
        worker_ctxs[i] = .{
            .wg = &wg,
            .items = items,
            .next_idx = &next_idx,
            .err_code = &err_code,
            .user_ctx = user_ctx,
        };
        if (parallel) {
            try parallelSpawnFn(@ptrCast(&Worker.run), &worker_ctxs[i], task_cfg);
        } else {
            try localSpawnFn(wg.sched, @ptrCast(&Worker.run), &worker_ctxs[i], task_cfg);
        }
    }
    wg.wait();

    const err_int = err_code.load(.seq_cst);
    if (err_int != 0) return @errorFromInt(err_int);
}
