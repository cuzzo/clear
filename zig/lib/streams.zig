const std = @import("std");
const compat = @import("compat.zig");
const pl = @import("parking-lot.zig");
const fp = @import("../runtime/scheduler.zig");
const qs = @import("../runtime/queues.zig");

const Scheduler = fp.Scheduler;
const Task = qs.Task;

// Comptime-switchable atomic: SimAtomic in Loom mode (when the test
// executable re-exports `pub const SimAtomic`), real `std.atomic.Value`
// otherwise. Same pattern as `lib/parking-lot.zig:33` so SplitStream's
// atomic ops become Loom yield points and show up in atomic-coverage.
const Atomic = blk: {
    const root = @import("root");
    break :blk if (@hasDecl(root, "SimAtomic")) root.SimAtomic else std.atomic.Value;
};

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
        // Producer backpressure threshold: when the live chunk count reaches
        // this value, push() parks the producer until subscribers consume
        // enough that releaseConsumedPrefix can free chunks. With ChunkCap=256
        // this caps the in-flight buffer at MaxChunks * 256 values. Set to
        // produce a reasonable RSS bound while not bottlenecking throughput.
        const MaxChunks = 16;

        const Chunk = struct {
            start_seq: usize,
            len: Atomic(usize) = Atomic(usize).init(0),
            write_len: usize = 0,
            values: [ChunkCap]T = undefined,
            next: ?*Chunk = null,
        };

        // Fields are atomic so TSan sees synchronization across the
        // ParkingRwLock boundary. ParkingRwLock provides correct
        // happens-before via its own atomic state (Loom-verified) but
        // TSan does not model the parking-lot rwlock as a synchronizer
        // (see comment in parking-rwlock-fiber-hammer-test.zig:191).
        // Without atomic field accesses, TSan flags non-atomic field
        // reads/writes between threads as data races even though the
        // lock serializes them.
        const SubscriberRecord = struct {
            active: Atomic(u8) = Atomic(u8).init(0),
            seq: Atomic(usize) = Atomic(usize).init(0),
            parked: Atomic(u8) = Atomic(u8).init(0),
            task: Atomic(?*Task) = Atomic(?*Task).init(null),
            sched: Atomic(?*Scheduler) = Atomic(?*Scheduler).init(null),
            // Set on first next() call. Records with is_reader == 0 are the
            // spawnNew anchor handle (never reads — exists to keep Inner
            // alive); excluding them from minReadSeq lets backpressure
            // releaseConsumedPrefix actually free chunks all real readers
            // consumed. retain() sets this to 1 since clones are explicit
            // readers; spawnNew's sub keeps it 0 until next() promotes it.
            is_reader: Atomic(u8) = Atomic(u8).init(0),
        };

        pub const Inner = struct {
            alloc: std.mem.Allocator,
            chunks_head: Atomic(?*Chunk) = Atomic(?*Chunk).init(null),
            chunks_tail: Atomic(?*Chunk) = Atomic(?*Chunk).init(null),
            head_seq: Atomic(usize) = Atomic(usize).init(0),
            tail_seq: Atomic(usize) = Atomic(usize).init(0),
            wg: WaitGroupType = undefined,
            subscribers: std.ArrayListUnmanaged(SubscriberRecord) = .{ .items = &.{}, .capacity = 0 },
            active_subscribers: Atomic(usize) = Atomic(usize).init(0),
            err_set: Atomic(u8) = Atomic(u8).init(0),
            err: anyerror = error.NoError,
            closed: Atomic(u8) = Atomic(u8).init(0),
            mutex: pl.ParkingRwLock = .{},
            wake_cursor: usize = 0,
            // Producer-side park/wake for backpressure (push() parks when
            // chunkCount >= MaxChunks; subscribers' next() wakes via
            // wakeParkedProducer after advancing seq through a chunk).
            producer_parked: Atomic(u8) = Atomic(u8).init(0),
            producer_task: Atomic(?*Task) = Atomic(?*Task).init(null),
            producer_sched: Atomic(?*Scheduler) = Atomic(?*Scheduler).init(null),
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

        fn lockInner(inner: *Inner) void {
            while (true) {
                inner.mutex.lock() catch |err| switch (err) { error.LockTimeout => continue, else => unreachable };
                return;
            }
        }

        fn lockSharedInner(inner: *Inner) void {
            while (true) {
                inner.mutex.lockShared() catch |err| switch (err) { error.LockTimeout => continue, else => unreachable };
                return;
            }
        }

        fn destroyChunk(inner: *Inner, chunk: *Chunk) void {
            for (0..chunk.write_len) |i| {
                cleanupValue(inner.alloc, &chunk.values[i]);
            }
            inner.alloc.destroy(chunk);
        }

        // Conservative minReadSeq: considers ALL active subscribers (does
        // not filter by is_reader). Used by deinit-time releaseConsumedPrefix
        // so the spawnNew anchor's seq still constrains chunk lifetime
        // when next() may not yet have been called on it.
        fn minReadSeq(inner: *Inner) usize {
            const tail_seq = inner.tail_seq.load(.acquire);
            var min_seq = tail_seq;
            var any_live = false;
            for (inner.subscribers.items) |*record| {
                if (record.active.load(.acquire) == 0) continue;
                any_live = true;
                const seq = record.seq.load(.acquire);
                if (seq < min_seq) min_seq = seq;
            }
            return if (any_live) min_seq else tail_seq;
        }

        // Aggressive minReadSeq for push-time backpressure: skips both
        // exclude_id and is_reader=0 records. The is_reader filter excludes
        // the spawnNew anchor (the BG STREAM producer pattern's `msgs`
        // handle that holds Inner alive but never reads). Without this,
        // backpressure-time releaseConsumedPrefix would never free chunks
        // because the anchor's seq stays at 0.
        fn minReadSeqForBackpressure(inner: *Inner, exclude_id: usize) usize {
            const tail_seq = inner.tail_seq.load(.acquire);
            var min_seq = tail_seq;
            var any_live = false;
            for (inner.subscribers.items, 0..) |*record, i| {
                if (i == exclude_id) continue;
                if (record.active.load(.acquire) == 0) continue;
                if (record.is_reader.load(.acquire) == 0) continue;
                any_live = true;
                const seq = record.seq.load(.acquire);
                if (seq < min_seq) min_seq = seq;
            }
            return if (any_live) min_seq else tail_seq;
        }

        fn releaseConsumedPrefix(inner: *Inner) void {
            while (true) {
                const head = inner.chunks_head.load(.acquire) orelse break;
                const published = head.len.load(.acquire);
                if (published == 0) break;
                if (head.start_seq + published > minReadSeq(inner)) break;
                inner.chunks_head.store(head.next, .release);
                inner.head_seq.store(head.start_seq + published, .release);
                if (inner.chunks_head.load(.acquire) == null) inner.chunks_tail.store(null, .release);
                destroyChunk(inner, head);
            }
        }

        // push-time variant: uses backpressure-aware minReadSeq.
        fn releaseConsumedPrefixForBackpressure(inner: *Inner, exclude_id: usize) void {
            while (true) {
                const head = inner.chunks_head.load(.acquire) orelse break;
                const published = head.len.load(.acquire);
                if (published == 0) break;
                if (head.start_seq + published > minReadSeqForBackpressure(inner, exclude_id)) break;
                inner.chunks_head.store(head.next, .release);
                inner.head_seq.store(head.start_seq + published, .release);
                if (inner.chunks_head.load(.acquire) == null) inner.chunks_tail.store(null, .release);
                destroyChunk(inner, head);
            }
        }

        fn clearAllChunks(inner: *Inner) void {
            var cur = inner.chunks_head.load(.acquire);
            while (cur) |chunk| {
                const next_chunk = chunk.next;
                destroyChunk(inner, chunk);
                cur = next_chunk;
            }
            inner.chunks_head.store(null, .release);
            inner.chunks_tail.store(null, .release);
            inner.head_seq.store(inner.tail_seq.load(.acquire), .release);
        }

        fn destroyInner(inner: *Inner) void {
            inner.subscribers.deinit(inner.alloc);
            inner.alloc.destroy(inner);
        }

        // Count chunks currently in the linked list. Called under exclusive
        // lock by push() to decide whether to park the producer.
        fn chunkCount(inner: *Inner) usize {
            var count: usize = 0;
            var cur = inner.chunks_head.load(.acquire);
            while (cur) |chunk| : (cur = chunk.next) count += 1;
            return count;
        }

        // Wake the producer if it's parked. Called by subscribers after
        // their seq advances; releaseConsumedPrefix runs on the next push,
        // and may free a chunk that previously kept the producer parked.
        fn wakeParkedProducer(inner: *Inner) void {
            if (inner.producer_parked.load(.acquire) == 0) return;
            inner.producer_parked.store(0, .release);
            if (inner.producer_sched.load(.acquire)) |sched| {
                if (inner.producer_task.load(.acquire)) |task| {
                    sched.schedule(task);
                }
            }
        }

        fn wakeAllParkedSubscribers(inner: *Inner) void {
            for (inner.subscribers.items) |*record| {
                if (record.active.load(.acquire) == 0) continue;
                if (record.parked.load(.acquire) == 0) continue;
                record.parked.store(0, .release);
                if (record.sched.load(.acquire)) |sched| {
                    if (record.task.load(.acquire)) |task| {
                        sched.schedule(task);
                    }
                }
            }
        }

        // Wake one parked subscriber per call, round-robin. Avoids the
        // thundering herd that wake-all creates with N>>1 subscribers; each
        // subsequent push wakes the next subscriber in turn. Subscribers
        // catch up to tail in a single next() call so per-publish wake-one
        // is sufficient for liveness as long as publishes continue.
        fn wakeOneParkedSubscriber(inner: *Inner) void {
            const n = inner.subscribers.items.len;
            if (n == 0) return;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const idx = (inner.wake_cursor + i) % n;
                const record = &inner.subscribers.items[idx];
                if (record.active.load(.acquire) == 0) continue;
                if (record.parked.load(.acquire) == 0) continue;
                record.parked.store(0, .release);
                inner.wake_cursor = (idx + 1) % n;
                if (record.sched.load(.acquire)) |sched| {
                    if (record.task.load(.acquire)) |task| {
                        sched.schedule(task);
                    }
                }
                return;
            }
        }

        fn findCursor(inner: *Inner, seq: usize) ?ChunkCursor {
            if (seq < inner.head_seq.load(.acquire) or seq >= inner.tail_seq.load(.acquire)) return null;

            var cur = inner.chunks_head.load(.acquire);
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

        fn allocSubscriber(inner: *Inner, seq: usize, is_reader: u8) !usize {
            for (inner.subscribers.items, 0..) |*record, i| {
                if (record.active.load(.acquire) == 0) {
                    record.active.store(1, .release);
                    record.seq.store(seq, .release);
                    record.parked.store(0, .release);
                    record.task.store(null, .release);
                    record.sched.store(null, .release);
                    record.is_reader.store(is_reader, .release);
                    _ = inner.active_subscribers.fetchAdd(1, .release);
                    return i;
                }
            }
            try inner.subscribers.append(inner.alloc, .{
                .active = Atomic(u8).init(1),
                .seq = Atomic(usize).init(seq),
                .is_reader = Atomic(u8).init(is_reader),
            });
            _ = inner.active_subscribers.fetchAdd(1, .release);
            return inner.subscribers.items.len - 1;
        }

        fn publishChunk(inner: *Inner, chunk: *Chunk) bool {
            const published_len = chunk.len.load(.acquire);
            if (chunk.write_len <= published_len) return false;
            const published = chunk.write_len - published_len;
            chunk.len.store(chunk.write_len, .release);
            _ = inner.tail_seq.fetchAdd(published, .release);
            return true;
        }

        pub fn spawnNew(alloc: std.mem.Allocator, sched: anytype) !Self {
            const inner = try alloc.create(Inner);
            inner.* = .{
                .alloc = alloc,
                .wg = WaitGroupType.init(sched),
            };
            inner.wg.add(1);
            const head_seq = inner.head_seq.load(.acquire);
            // spawnNew's anchor handle is is_reader=0 — it exists to hold
            // a reference to Inner but typically does not call next().
            // First next() call promotes is_reader to 1 (see next() below).
            const subscriber_id = try allocSubscriber(inner, head_seq, 0);
            return .{
                .inner = inner,
                .alloc = alloc,
                .subscriber_id = subscriber_id,
                .next_seq = head_seq,
            };
        }

        pub fn push(self: *Self, val: T) !void {
            var published = false;
            lockInner(self.inner);

            if (self.inner.active_subscribers.load(.acquire) == 0) {
                self.inner.mutex.unlock();
                var tmp = val;
                cleanupValue(self.inner.alloc, &tmp);
                return;
            }

            // Backpressure: free any consumed chunks (excluding the
            // producer's own subscriber record from minReadSeq — see
            // releaseConsumedPrefixExcluding comment), then park if the
            // live chunk count is still at the limit. Subscribers' next()
            // calls wakeParkedProducer after advancing seq, allowing
            // releaseConsumedPrefix to free chunks and the producer to
            // push again.
            // HAMMER-WAIT-LOOP-BEGIN: tag=streams.push-backpressure-park
            // What stalls: chunk count is at MaxChunks because all
            // subscribers are slower than the producer (or one subscriber
            // is the bottleneck — minReadSeqForBackpressure pins
            // releasable chunks to the slowest non-anchor reader).
            // Yield contract: park the producer task on the inner
            // (producer_task + producer_parked=1) under the exclusive
            // lock, drop the lock, and yield to the scheduler. The
            // first subscriber to advance past the parked producer's
            // chunk in next() calls wakeParkedProducer, which clears
            // producer_parked and resumes the task.
            while (true) {
                releaseConsumedPrefixForBackpressure(self.inner, self.subscriber_id);
                if (chunkCount(self.inner) < MaxChunks) break;
                if (!fp.scheduler_running or fp.active_scheduler.current_task == null) break;
                wakeAllParkedSubscribers(self.inner);
                const task = fp.active_scheduler.getCurrent();
                self.inner.producer_task.store(task, .release);
                self.inner.producer_sched.store(fp.active_scheduler, .release);
                self.inner.producer_parked.store(1, .release);
                task.status.store(.Blocked, .release);
                self.inner.mutex.unlock();
                task.base.yield();
                lockInner(self.inner);
            }
            // HAMMER-WAIT-LOOP-END: tag=streams.push-backpressure-park

            var tail = self.inner.chunks_tail.load(.acquire);
            if (tail == null or tail.?.write_len == ChunkCap) {
                const chunk = try self.inner.alloc.create(Chunk);
                chunk.* = .{ .start_seq = self.inner.tail_seq.load(.acquire) };
                if (tail) |existing_tail| {
                    existing_tail.next = chunk;
                } else {
                    self.inner.chunks_head.store(chunk, .release);
                }
                self.inner.chunks_tail.store(chunk, .release);
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
                wakeOneParkedSubscriber(self.inner);
            }
            self.inner.mutex.unlock();
        }

        pub fn close(self: *Self) void {
            lockInner(self.inner);
            const already_closed = self.inner.closed.load(.acquire) != 0;
            if (self.inner.chunks_tail.load(.acquire)) |tail| {
                _ = publishChunk(self.inner, tail);
            }
            if (!already_closed) self.inner.closed.store(1, .release);
            wakeAllParkedSubscribers(self.inner);
            // Producer may have parked itself for backpressure and never
            // returned to push; close() must wake it (typically a no-op
            // since close() is called by the producer after it finishes).
            wakeParkedProducer(self.inner);
            self.inner.mutex.unlock();
            if (!already_closed) self.inner.wg.done();
        }

        pub fn setError(self: *Self, err: anyerror) void {
            lockInner(self.inner);
            self.inner.err = err;
            self.inner.err_set.store(1, .release);
            wakeAllParkedSubscribers(self.inner);
            wakeParkedProducer(self.inner);
            self.inner.mutex.unlock();
        }

        pub fn retain(self: Self) Self {
            std.debug.assert(self.active);

            lockInner(self.inner);
            // CLONE / retain → explicit reader.
            const subscriber_id = allocSubscriber(self.inner, self.next_seq, 1) catch unreachable;
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
            // Promote anchor handles from spawnNew to "real reader" on
            // first next() call. Idempotent atomic store; cheap.
            if (self.subscriber_id != InvalidSubscriber) {
                self.inner.subscribers.items[self.subscriber_id].is_reader.store(1, .release);
            }
            // HAMMER-WAIT-LOOP-BEGIN: tag=streams.next-park
            // What stalls: a subscriber's cursor has caught up to the
            // tail of the chunk list and there is no new value yet
            // (producer slow, or producer is itself parked for
            // backpressure waiting on a different subscriber).
            // Yield contract: two-phase. Phase 1 takes lockShared and
            // either returns a value or detects close/error in O(1).
            // Phase 2 (no value) upgrades to exclusive lock, registers
            // the subscriber as parked (record.task / record.parked=1)
            // under the lock, drops the lock, and yields. The next
            // push() that publishes a value calls
            // wakeOneParkedSubscriber to resume one round-robin parked
            // reader; close()/setError wake all parked subscribers.
            while (true) {
                // Phase 1: shared read attempt. Multiple subscribers can concurrently
                // walk chunks and read values; the writer (push/close/setError) takes
                // exclusive. Each subscriber atomically updates only its own seq.
                lockSharedInner(self.inner);

                if (self.inner.err_set.load(.acquire) != 0) {
                    const err = self.inner.err;
                    self.inner.mutex.unlockShared();
                    return err;
                }

                if (self.currentCursor()) |cursor| {
                    const out = try cloneValue(self.inner.alloc, cursor.chunk.values[cursor.index]);
                    const chunk_len = cursor.chunk.len.load(.acquire);
                    const advance_in_same_chunk = cursor.index + 1 < chunk_len;
                    const advance_into_next_chunk = !advance_in_same_chunk and cursor.chunk.next != null;
                    const wait_for_tail_growth = !advance_in_same_chunk and !advance_into_next_chunk and chunk_len < ChunkCap and self.inner.closed.load(.acquire) == 0 and cursor.chunk == self.inner.chunks_tail.load(.acquire);

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
                    self.inner.mutex.unlockShared();
                    // Wake the producer after advancing seq so it can free
                    // consumed chunks and proceed if it was parked. Cheap
                    // atomic check; only schedules a task when actually parked.
                    wakeParkedProducer(self.inner);
                    return out;
                }

                if (self.inner.closed.load(.acquire) != 0) {
                    self.inner.mutex.unlockShared();
                    return null;
                }
                self.inner.mutex.unlockShared();

                // Phase 2: need to park. Take exclusive to write SubscriberRecord
                // park state. Re-check after upgrading — a writer may have published
                // between unlockShared and lock acquire.
                lockInner(self.inner);

                if (self.inner.err_set.load(.acquire) != 0) {
                    const err = self.inner.err;
                    self.inner.mutex.unlock();
                    return err;
                }

                if (self.currentCursor() != null) {
                    self.inner.mutex.unlock();
                    continue;
                }

                if (self.inner.closed.load(.acquire) != 0) {
                    self.inner.mutex.unlock();
                    return null;
                }

                if (fp.scheduler_running and fp.active_scheduler.current_task != null) {
                    const task = fp.active_scheduler.getCurrent();
                    if (self.subscriber_id != InvalidSubscriber) {
                        var record = &self.inner.subscribers.items[self.subscriber_id];
                        record.parked.store(1, .release);
                        record.task.store(task, .release);
                        record.sched.store(fp.active_scheduler, .release);
                    }
                    task.status.store(.Blocked, .release);
                    self.inner.mutex.unlock();
                    task.base.yield();
                } else {
                    self.inner.mutex.unlock();
                    std.Thread.yield() catch {};
                }
            }
            // HAMMER-WAIT-LOOP-END: tag=streams.next-park
        }

        pub fn deinit(self: *Self) void {
            if (!self.active) return;

            var should_destroy = false;
            var should_signal_close = false;
            lockInner(self.inner);
            if (self.subscriber_id != InvalidSubscriber) {
                var record = &self.inner.subscribers.items[self.subscriber_id];
                record.active.store(0, .release);
                record.seq.store(self.inner.tail_seq.load(.acquire), .release);
                record.parked.store(0, .release);
                record.task.store(null, .release);
                record.sched.store(null, .release);
                std.debug.assert(self.inner.active_subscribers.load(.acquire) > 0);
                _ = self.inner.active_subscribers.fetchSub(1, .release);
                self.subscriber_id = InvalidSubscriber;
            }
            self.active = false;
            self.next_chunk = null;
            self.next_index = 0;

            if (self.inner.active_subscribers.load(.acquire) == 0) {
                should_signal_close = self.inner.closed.load(.acquire) == 0;
                self.inner.closed.store(1, .release);
                clearAllChunks(self.inner);
                should_destroy = true;
            } else {
                releaseConsumedPrefix(self.inner);
            }
            // Last subscriber's deinit releases chunks; wake producer in
            // case it was parked waiting for chunk count to drop.
            wakeParkedProducer(self.inner);
            self.inner.mutex.unlock();

            if (should_destroy) {
                if (should_signal_close) self.inner.wg.done();
                self.inner.wg.wait();
                destroyInner(self.inner);
            }
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
    batch: usize,
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

    var err_code = Atomic(u16).init(0);
    var next_idx = Atomic(usize).init(0);
    var wg = WaitGroupT.init(rt.getSched());
    const batch_size = @max(batch, 1);

    const Worker = struct {
        wg: *WaitGroupT,
        items: *[N]PromiseT,
        slots: []Slot,
        next_idx: *Atomic(usize),
        batch_size: usize,
        err_code: *Atomic(u16),
        user_ctx: ?*anyopaque,

        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const worker_rt = @as(*RuntimeT, @ptrCast(@alignCast(raw_rt)));
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            while (true) {
                const start = ctx.next_idx.fetchAdd(ctx.batch_size, .monotonic);
                if (start >= N) break;
                const end = @min(start + ctx.batch_size, N);
                for (start..end) |idx| {
                    const item = try ctx.items[idx].next();
                    const mapped = mapFn(worker_rt, ctx.user_ctx, item) catch |err| {
                        _ = ctx.err_code.cmpxchgStrong(0, @intFromError(err), .seq_cst, .seq_cst);
                        continue;
                    };
                    ctx.slots[idx] = mapped;
                }
                worker_rt.checkYield();
            }
        }
    };

    var worker_ctxs: [64]Worker = undefined;
    const actual_workers = @min(if (workers == 0) @as(usize, 1) else workers, @as(usize, 64));
    if (actual_workers == 0) return .{ .items = &.{}, .capacity = 0 };
    wg.add(actual_workers);
    for (0..actual_workers) |i| {
        worker_ctxs[i] = .{
            .wg = &wg,
            .items = items,
            .slots = slots,
            .next_idx = &next_idx,
            .batch_size = batch_size,
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
    batch: usize,
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

    var err_code = Atomic(u16).init(0);
    var next_idx = Atomic(usize).init(0);
    var wg = WaitGroupT.init(rt.getSched());
    const batch_size = @max(batch, 1);

    const Worker = struct {
        wg: *WaitGroupT,
        items: *[N]PromiseT,
        slots: []Slot,
        alloc: std.mem.Allocator,
        next_idx: *Atomic(usize),
        batch_size: usize,
        err_code: *Atomic(u16),
        user_ctx: ?*anyopaque,

        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const worker_rt = @as(*RuntimeT, @ptrCast(@alignCast(raw_rt)));
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            while (true) {
                const start = ctx.next_idx.fetchAdd(ctx.batch_size, .monotonic);
                if (start >= N) break;
                const end = @min(start + ctx.batch_size, N);
                for (start..end) |idx| {
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
                }
                worker_rt.checkYield();
            }
        }
    };

    var worker_ctxs: [64]Worker = undefined;
    const actual_workers = @min(if (workers == 0) @as(usize, 1) else workers, @as(usize, 64));
    if (actual_workers == 0) return .{ .items = &.{}, .capacity = 0 };
    wg.add(actual_workers);
    for (0..actual_workers) |i| {
        worker_ctxs[i] = .{
            .wg = &wg,
            .items = items,
            .slots = slots,
            .alloc = alloc,
            .next_idx = &next_idx,
            .batch_size = batch_size,
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
    batch: usize,
    parallel: bool,
    task_cfg: anytype,
    user_ctx: ?*anyopaque,
) !void {
    _ = T;
    const ItemsPtr = @TypeOf(items);
    const PromiseT = @typeInfo(@typeInfo(ItemsPtr).pointer.child).array.child;
    const RuntimeT = @TypeOf(rt.*);

    var err_code = Atomic(u16).init(0);
    var next_idx = Atomic(usize).init(0);
    var wg = WaitGroupT.init(rt.getSched());
    const batch_size = @max(batch, 1);

    const Worker = struct {
        wg: *WaitGroupT,
        items: *[N]PromiseT,
        next_idx: *Atomic(usize),
        batch_size: usize,
        err_code: *Atomic(u16),
        user_ctx: ?*anyopaque,

        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const worker_rt = @as(*RuntimeT, @ptrCast(@alignCast(raw_rt)));
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            while (true) {
                const start = ctx.next_idx.fetchAdd(ctx.batch_size, .monotonic);
                if (start >= N) break;
                const end = @min(start + ctx.batch_size, N);
                for (start..end) |idx| {
                    const item = try ctx.items[idx].next();
                    eachFn(worker_rt, ctx.user_ctx, item) catch |err| {
                        _ = ctx.err_code.cmpxchgStrong(0, @intFromError(err), .seq_cst, .seq_cst);
                        continue;
                    };
                }
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
            .batch_size = batch_size,
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

pub fn concurrentShardedListEachInPlace(
    comptime WaitGroupT: type,
    comptime T: type,
    comptime N: usize,
    comptime eachFn: anytype,
    comptime localSpawnFn: anytype,
    comptime parallelSpawnFn: anytype,
    rt: anytype,
    list: anytype,
    parallel: bool,
    task_cfg: anytype,
    user_ctx: ?*anyopaque,
) !void {
    const RuntimeT = @TypeOf(rt.*);

    if (!fp.scheduler_running or fp.active_scheduler.current_task == null) {
        for (0..N) |i| {
            for (list.shards[i].items) |*item_ptr| {
                try eachFn(rt, user_ctx, item_ptr);
            }
        }
        return;
    }

    var err_code = Atomic(u16).init(0);
    var wg = WaitGroupT.init(rt.getSched());

    const Worker = struct {
        wg: *WaitGroupT,
        shard: *std.ArrayListUnmanaged(T),
        err_code: *Atomic(u16),
        user_ctx: ?*anyopaque,

        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const worker_rt = @as(*RuntimeT, @ptrCast(@alignCast(raw_rt)));
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            for (ctx.shard.items) |*item_ptr| {
                eachFn(worker_rt, ctx.user_ctx, item_ptr) catch |err| {
                    _ = ctx.err_code.cmpxchgStrong(0, @intFromError(err), .seq_cst, .seq_cst);
                    continue;
                };
            }
            worker_rt.checkYield();
        }
    };

    var worker_ctxs: [N]Worker = undefined;
    wg.add(N);
    for (0..N) |i| {
        worker_ctxs[i] = .{
            .wg = &wg,
            .shard = &list.shards[i],
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

pub fn concurrentShardedPoolEachInPlace(
    comptime WaitGroupT: type,
    comptime T: type,
    comptime N: usize,
    comptime eachFn: anytype,
    comptime localSpawnFn: anytype,
    comptime parallelSpawnFn: anytype,
    rt: anytype,
    pool: anytype,
    parallel: bool,
    task_cfg: anytype,
    user_ctx: ?*anyopaque,
) !void {
    const RuntimeT = @TypeOf(rt.*);
    const ShardPtrT = @TypeOf(&pool.shards[0]);
    _ = T;

    if (!fp.scheduler_running or fp.active_scheduler.current_task == null) {
        for (0..N) |i| {
            for (0..pool.shards[i].capacity) |idx| {
                const value = pool.shards[i].valueAtIndex(idx) orelse continue;
                try eachFn(rt, user_ctx, value);
            }
        }
        return;
    }

    var err_code = Atomic(u16).init(0);
    var wg = WaitGroupT.init(rt.getSched());

    const Worker = struct {
        wg: *WaitGroupT,
        shard: ShardPtrT,
        err_code: *Atomic(u16),
        user_ctx: ?*anyopaque,

        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const worker_rt = @as(*RuntimeT, @ptrCast(@alignCast(raw_rt)));
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            for (0..ctx.shard.capacity) |idx| {
                const value = ctx.shard.valueAtIndex(idx) orelse continue;
                eachFn(worker_rt, ctx.user_ctx, value) catch |err| {
                    _ = ctx.err_code.cmpxchgStrong(0, @intFromError(err), .seq_cst, .seq_cst);
                    continue;
                };
            }
            worker_rt.checkYield();
        }
    };

    var worker_ctxs: [N]Worker = undefined;
    wg.add(N);
    for (0..N) |i| {
        worker_ctxs[i] = .{
            .wg = &wg,
            .shard = &pool.shards[i],
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

// Dynamic-stream variants of the concurrent helpers above. They mirror
// concurrentBoundedSelect/Where/Each but pull items via `next()` /
// `nextOrNull()` over an unsized source stream, fanning items out to
// N worker fibers through a BoundedChannel. A single feeder fiber owns
// the source; workers race on the channel head.
//
// `is_inf` chooses the source pop method: `nextOrNull()` for infinite
// streams (returns null at end-of-stream) vs `next()` for bounded/open.
//
// `ChannelT` is supplied as a comptime parameter so streams.zig doesn't
// take a hard dependency on data-structures.zig — runtime-header.zig
// resolves it to `CheatLib.BoundedChannel(T)` at the call site.

pub fn concurrentStreamSelect(
    comptime WaitGroupT: type,
    comptime ChannelT: type,
    comptime T: type,
    comptime R: type,
    comptime mapFn: anytype,
    comptime localSpawnFn: anytype,
    comptime parallelSpawnFn: anytype,
    comptime cleanupResultFn: anytype,
    comptime is_inf: bool,
    alloc: std.mem.Allocator,
    rt: anytype,
    src: anytype,
    workers: usize,
    capacity: usize,
    batch: usize,
    parallel: bool,
    task_cfg: anytype,
    user_ctx: ?*anyopaque,
) !std.ArrayListUnmanaged(R) {
    _ = T;
    const SrcPtr = @TypeOf(src);
    const RuntimeT = @TypeOf(rt.*);

    var chan = try ChannelT.init(alloc, capacity);
    defer chan.deinit();
    var err_code = Atomic(u16).init(0);
    var wg = WaitGroupT.init(rt.getSched());
    const batch_size = @max(batch, 1);

    const Feeder = struct {
        wg: *WaitGroupT,
        src: SrcPtr,
        chan: *ChannelT,

        fn run(_: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            defer ctx.chan.close();
            if (is_inf) {
                while (try ctx.src.nextOrNull()) |item| {
                    try ctx.chan.push(item);
                }
            } else {
                while (try ctx.src.next()) |item| {
                    try ctx.chan.push(item);
                }
            }
        }
    };

    const Worker = struct {
        wg: *WaitGroupT,
        chan: *ChannelT,
        local: std.ArrayListUnmanaged(R),
        alloc: std.mem.Allocator,
        err: *Atomic(u16),
        batch_size: usize,
        user_ctx: ?*anyopaque,

        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const worker_rt = @as(*RuntimeT, @ptrCast(@alignCast(raw_rt)));
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            while (try ctx.chan.pop()) |first| {
                var item = first;
                var n: usize = 0;
                while (true) : (n += 1) {
                    const mapped = mapFn(worker_rt, ctx.user_ctx, item) catch |e| {
                        _ = ctx.err.cmpxchgStrong(0, @intFromError(e), .seq_cst, .seq_cst);
                        break;
                    };
                    try ctx.local.append(ctx.alloc, mapped);
                    if (n + 1 >= ctx.batch_size) break;
                    item = (try ctx.chan.pop()) orelse break;
                }
                worker_rt.checkYield();
            }
        }
    };

    const MAX_WORKERS: usize = 64;
    const actual_workers = @min(if (workers == 0) @as(usize, 1) else workers, MAX_WORKERS);
    var feeder_ctx = Feeder{ .wg = &wg, .src = src, .chan = &chan };
    var worker_ctxs: [MAX_WORKERS]Worker = undefined;
    wg.add(1 + actual_workers);

    // Feeder: always local-scheduler so the source is owned by one fiber.
    try localSpawnFn(wg.sched, @ptrCast(&Feeder.run), &feeder_ctx, task_cfg);

    for (0..actual_workers) |i| {
        worker_ctxs[i] = .{
            .wg = &wg,
            .chan = &chan,
            .local = .empty,
            .alloc = alloc,
            .err = &err_code,
            .batch_size = batch_size,
            .user_ctx = user_ctx,
        };
        if (parallel) {
            try parallelSpawnFn(@ptrCast(&Worker.run), &worker_ctxs[i], task_cfg);
        } else {
            try localSpawnFn(wg.sched, @ptrCast(&Worker.run), &worker_ctxs[i], task_cfg);
        }
    }
    wg.wait();

    errdefer {
        for (0..actual_workers) |i| {
            for (worker_ctxs[i].local.items) |*v| cleanupResultFn(alloc, v);
            worker_ctxs[i].local.deinit(alloc);
        }
    }

    const err_int = err_code.load(.seq_cst);
    if (err_int != 0) return @errorFromInt(err_int);

    var total: usize = 0;
    for (0..actual_workers) |i| total += worker_ctxs[i].local.items.len;
    var out = try std.ArrayListUnmanaged(R).initCapacity(alloc, total);
    errdefer {
        for (out.items) |*v| cleanupResultFn(alloc, v);
        out.deinit(alloc);
    }
    for (0..actual_workers) |i| {
        out.appendSliceAssumeCapacity(worker_ctxs[i].local.items);
        worker_ctxs[i].local.deinit(alloc);
    }
    return out;
}

pub fn concurrentStreamWhere(
    comptime WaitGroupT: type,
    comptime ChannelT: type,
    comptime T: type,
    comptime predFn: anytype,
    comptime localSpawnFn: anytype,
    comptime parallelSpawnFn: anytype,
    comptime cleanupItemFn: anytype,
    comptime is_inf: bool,
    alloc: std.mem.Allocator,
    rt: anytype,
    src: anytype,
    workers: usize,
    capacity: usize,
    batch: usize,
    parallel: bool,
    task_cfg: anytype,
    user_ctx: ?*anyopaque,
) !std.ArrayListUnmanaged(T) {
    const SrcPtr = @TypeOf(src);
    const RuntimeT = @TypeOf(rt.*);

    var chan = try ChannelT.init(alloc, capacity);
    defer chan.deinit();
    var err_code = Atomic(u16).init(0);
    var wg = WaitGroupT.init(rt.getSched());
    const batch_size = @max(batch, 1);

    const Feeder = struct {
        wg: *WaitGroupT,
        src: SrcPtr,
        chan: *ChannelT,

        fn run(_: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            defer ctx.chan.close();
            if (is_inf) {
                while (try ctx.src.nextOrNull()) |item| {
                    try ctx.chan.push(item);
                }
            } else {
                while (try ctx.src.next()) |item| {
                    try ctx.chan.push(item);
                }
            }
        }
    };

    const Worker = struct {
        wg: *WaitGroupT,
        chan: *ChannelT,
        local: std.ArrayListUnmanaged(T),
        alloc: std.mem.Allocator,
        err: *Atomic(u16),
        batch_size: usize,
        user_ctx: ?*anyopaque,

        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const worker_rt = @as(*RuntimeT, @ptrCast(@alignCast(raw_rt)));
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            while (try ctx.chan.pop()) |first| {
                var item = first;
                var n: usize = 0;
                while (true) : (n += 1) {
                    var item_mut = item;
                    const keep = predFn(worker_rt, ctx.user_ctx, item) catch |e| {
                        _ = ctx.err.cmpxchgStrong(0, @intFromError(e), .seq_cst, .seq_cst);
                        cleanupItemFn(ctx.alloc, &item_mut);
                        break;
                    };
                    if (keep) {
                        try ctx.local.append(ctx.alloc, item);
                    } else {
                        cleanupItemFn(ctx.alloc, &item_mut);
                    }
                    if (n + 1 >= ctx.batch_size) break;
                    item = (try ctx.chan.pop()) orelse break;
                }
                worker_rt.checkYield();
            }
        }
    };

    const MAX_WORKERS: usize = 64;
    const actual_workers = @min(if (workers == 0) @as(usize, 1) else workers, MAX_WORKERS);
    var feeder_ctx = Feeder{ .wg = &wg, .src = src, .chan = &chan };
    var worker_ctxs: [MAX_WORKERS]Worker = undefined;
    wg.add(1 + actual_workers);

    try localSpawnFn(wg.sched, @ptrCast(&Feeder.run), &feeder_ctx, task_cfg);

    for (0..actual_workers) |i| {
        worker_ctxs[i] = .{
            .wg = &wg,
            .chan = &chan,
            .local = .empty,
            .alloc = alloc,
            .err = &err_code,
            .batch_size = batch_size,
            .user_ctx = user_ctx,
        };
        if (parallel) {
            try parallelSpawnFn(@ptrCast(&Worker.run), &worker_ctxs[i], task_cfg);
        } else {
            try localSpawnFn(wg.sched, @ptrCast(&Worker.run), &worker_ctxs[i], task_cfg);
        }
    }
    wg.wait();

    errdefer {
        for (0..actual_workers) |i| {
            for (worker_ctxs[i].local.items) |*v| cleanupItemFn(alloc, v);
            worker_ctxs[i].local.deinit(alloc);
        }
    }

    const err_int = err_code.load(.seq_cst);
    if (err_int != 0) return @errorFromInt(err_int);

    var total: usize = 0;
    for (0..actual_workers) |i| total += worker_ctxs[i].local.items.len;
    var out = try std.ArrayListUnmanaged(T).initCapacity(alloc, total);
    errdefer {
        for (out.items) |*v| cleanupItemFn(alloc, v);
        out.deinit(alloc);
    }
    for (0..actual_workers) |i| {
        out.appendSliceAssumeCapacity(worker_ctxs[i].local.items);
        worker_ctxs[i].local.deinit(alloc);
    }
    return out;
}

pub fn concurrentStreamEach(
    comptime WaitGroupT: type,
    comptime ChannelT: type,
    comptime T: type,
    comptime eachFn: anytype,
    comptime localSpawnFn: anytype,
    comptime parallelSpawnFn: anytype,
    comptime is_inf: bool,
    alloc: std.mem.Allocator,
    rt: anytype,
    src: anytype,
    workers: usize,
    capacity: usize,
    batch: usize,
    parallel: bool,
    task_cfg: anytype,
    user_ctx: ?*anyopaque,
) !void {
    _ = T;
    const SrcPtr = @TypeOf(src);
    const RuntimeT = @TypeOf(rt.*);

    var chan = try ChannelT.init(alloc, capacity);
    defer chan.deinit();
    var err_code = Atomic(u16).init(0);
    var wg = WaitGroupT.init(rt.getSched());
    const batch_size = @max(batch, 1);

    const Feeder = struct {
        wg: *WaitGroupT,
        src: SrcPtr,
        chan: *ChannelT,

        fn run(_: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            defer ctx.chan.close();
            if (is_inf) {
                while (try ctx.src.nextOrNull()) |item| {
                    try ctx.chan.push(item);
                }
            } else {
                while (try ctx.src.next()) |item| {
                    try ctx.chan.push(item);
                }
            }
        }
    };

    const Worker = struct {
        wg: *WaitGroupT,
        chan: *ChannelT,
        err: *Atomic(u16),
        batch_size: usize,
        user_ctx: ?*anyopaque,

        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const worker_rt = @as(*RuntimeT, @ptrCast(@alignCast(raw_rt)));
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            while (try ctx.chan.pop()) |first| {
                var item = first;
                var n: usize = 0;
                while (true) : (n += 1) {
                    eachFn(worker_rt, ctx.user_ctx, item) catch |e| {
                        _ = ctx.err.cmpxchgStrong(0, @intFromError(e), .seq_cst, .seq_cst);
                        break;
                    };
                    if (n + 1 >= ctx.batch_size) break;
                    item = (try ctx.chan.pop()) orelse break;
                }
                worker_rt.checkYield();
            }
        }
    };

    const MAX_WORKERS: usize = 64;
    const actual_workers = @min(if (workers == 0) @as(usize, 1) else workers, MAX_WORKERS);
    var feeder_ctx = Feeder{ .wg = &wg, .src = src, .chan = &chan };
    var worker_ctxs: [MAX_WORKERS]Worker = undefined;
    wg.add(1 + actual_workers);

    try localSpawnFn(wg.sched, @ptrCast(&Feeder.run), &feeder_ctx, task_cfg);

    for (0..actual_workers) |i| {
        worker_ctxs[i] = .{
            .wg = &wg,
            .chan = &chan,
            .err = &err_code,
            .batch_size = batch_size,
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

// List-source variants of the concurrent helpers. They mirror
// concurrentBoundedSelect/Where/Each but accept an already-materialized
// slice (`items: []const T`) instead of a fixed-size promise array.
// No feeder fiber, no channel -- workers race on an atomic index against
// the slice length. Used for `[]T s> CONCURRENT SELECT/WHERE/EACH`
// where the source is a plain list (already-materialized data).

pub fn concurrentListSelect(
    comptime WaitGroupT: type,
    comptime T: type,
    comptime R: type,
    comptime mapFn: anytype,
    comptime localSpawnFn: anytype,
    comptime parallelSpawnFn: anytype,
    comptime cleanupResultFn: anytype,
    alloc: std.mem.Allocator,
    rt: anytype,
    items: []const T,
    workers: usize,
    batch: usize,
    parallel: bool,
    task_cfg: anytype,
    user_ctx: ?*anyopaque,
) !std.ArrayListUnmanaged(R) {
    const RuntimeT = @TypeOf(rt.*);
    const Slot = ?R;

    const slots = try alloc.alloc(Slot, items.len);
    defer alloc.free(slots);
    for (slots) |*slot| slot.* = null;
    errdefer {
        for (slots) |*slot| {
            if (slot.*) |*value| cleanupResultFn(alloc, value);
        }
    }

    var err_code = Atomic(u16).init(0);
    var next_idx = Atomic(usize).init(0);
    var wg = WaitGroupT.init(rt.getSched());
    const batch_size = @max(batch, 1);

    const Worker = struct {
        wg: *WaitGroupT,
        items: []const T,
        slots: []Slot,
        next_idx: *Atomic(usize),
        batch_size: usize,
        err_code: *Atomic(u16),
        user_ctx: ?*anyopaque,

        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const worker_rt = @as(*RuntimeT, @ptrCast(@alignCast(raw_rt)));
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            while (true) {
                const start = ctx.next_idx.fetchAdd(ctx.batch_size, .monotonic);
                if (start >= ctx.items.len) break;
                const end = @min(start + ctx.batch_size, ctx.items.len);
                for (start..end) |idx| {
                    const item = ctx.items[idx];
                    const mapped = mapFn(worker_rt, ctx.user_ctx, item) catch |err| {
                        _ = ctx.err_code.cmpxchgStrong(0, @intFromError(err), .seq_cst, .seq_cst);
                        continue;
                    };
                    ctx.slots[idx] = mapped;
                }
                worker_rt.checkYield();
            }
        }
    };

    var worker_ctxs: [64]Worker = undefined;
    const actual_workers = @min(if (workers == 0) @as(usize, 1) else workers, @as(usize, 64));
    if (actual_workers == 0) return .{ .items = &.{}, .capacity = 0 };
    wg.add(actual_workers);
    for (0..actual_workers) |i| {
        worker_ctxs[i] = .{
            .wg = &wg,
            .items = items,
            .slots = slots,
            .next_idx = &next_idx,
            .batch_size = batch_size,
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

pub fn concurrentListWhere(
    comptime WaitGroupT: type,
    comptime T: type,
    comptime predFn: anytype,
    comptime localSpawnFn: anytype,
    comptime parallelSpawnFn: anytype,
    comptime cleanupItemFn: anytype,
    alloc: std.mem.Allocator,
    rt: anytype,
    items: []const T,
    workers: usize,
    batch: usize,
    parallel: bool,
    task_cfg: anytype,
    user_ctx: ?*anyopaque,
) !std.ArrayListUnmanaged(T) {
    const RuntimeT = @TypeOf(rt.*);
    const Slot = ?T;

    const slots = try alloc.alloc(Slot, items.len);
    defer alloc.free(slots);
    for (slots) |*slot| slot.* = null;
    errdefer {
        for (slots) |*slot| {
            if (slot.*) |*value| cleanupItemFn(alloc, value);
        }
    }

    var err_code = Atomic(u16).init(0);
    var next_idx = Atomic(usize).init(0);
    var wg = WaitGroupT.init(rt.getSched());
    const batch_size = @max(batch, 1);

    const Worker = struct {
        wg: *WaitGroupT,
        items: []const T,
        slots: []Slot,
        next_idx: *Atomic(usize),
        batch_size: usize,
        err_code: *Atomic(u16),
        user_ctx: ?*anyopaque,

        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const worker_rt = @as(*RuntimeT, @ptrCast(@alignCast(raw_rt)));
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            while (true) {
                const start = ctx.next_idx.fetchAdd(ctx.batch_size, .monotonic);
                if (start >= ctx.items.len) break;
                const end = @min(start + ctx.batch_size, ctx.items.len);
                for (start..end) |idx| {
                    const item = ctx.items[idx];
                    const keep = predFn(worker_rt, ctx.user_ctx, item) catch |err| {
                        _ = ctx.err_code.cmpxchgStrong(0, @intFromError(err), .seq_cst, .seq_cst);
                        continue;
                    };
                    if (keep) ctx.slots[idx] = item;
                }
                worker_rt.checkYield();
            }
        }
    };

    var worker_ctxs: [64]Worker = undefined;
    const actual_workers = @min(if (workers == 0) @as(usize, 1) else workers, @as(usize, 64));
    if (actual_workers == 0) return .{ .items = &.{}, .capacity = 0 };
    wg.add(actual_workers);
    for (0..actual_workers) |i| {
        worker_ctxs[i] = .{
            .wg = &wg,
            .items = items,
            .slots = slots,
            .next_idx = &next_idx,
            .batch_size = batch_size,
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

pub fn concurrentListEach(
    comptime WaitGroupT: type,
    comptime T: type,
    comptime eachFn: anytype,
    comptime localSpawnFn: anytype,
    comptime parallelSpawnFn: anytype,
    rt: anytype,
    items: []const T,
    workers: usize,
    batch: usize,
    parallel: bool,
    task_cfg: anytype,
    user_ctx: ?*anyopaque,
) !void {
    const RuntimeT = @TypeOf(rt.*);

    var err_code = Atomic(u16).init(0);
    var next_idx = Atomic(usize).init(0);
    var wg = WaitGroupT.init(rt.getSched());
    const batch_size = @max(batch, 1);

    const Worker = struct {
        wg: *WaitGroupT,
        items: []const T,
        next_idx: *Atomic(usize),
        batch_size: usize,
        err_code: *Atomic(u16),
        user_ctx: ?*anyopaque,

        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const worker_rt = @as(*RuntimeT, @ptrCast(@alignCast(raw_rt)));
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            while (true) {
                const start = ctx.next_idx.fetchAdd(ctx.batch_size, .monotonic);
                if (start >= ctx.items.len) break;
                const end = @min(start + ctx.batch_size, ctx.items.len);
                for (start..end) |idx| {
                    const item = ctx.items[idx];
                    eachFn(worker_rt, ctx.user_ctx, item) catch |err| {
                        _ = ctx.err_code.cmpxchgStrong(0, @intFromError(err), .seq_cst, .seq_cst);
                        continue;
                    };
                }
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
            .batch_size = batch_size,
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

// In-place variant of concurrentListEach: items is a *mutable* slice
// and the body fn receives `*T` so it can update each element through
// the pointer. Used for `[]T s> CONCURRENT EACH { _.field = X; }` where
// the body directly mutates each item.
pub fn concurrentListEachInPlace(
    comptime WaitGroupT: type,
    comptime T: type,
    comptime eachFn: anytype,
    comptime localSpawnFn: anytype,
    comptime parallelSpawnFn: anytype,
    rt: anytype,
    items: []T,
    workers: usize,
    batch: usize,
    parallel: bool,
    task_cfg: anytype,
    user_ctx: ?*anyopaque,
) !void {
    const RuntimeT = @TypeOf(rt.*);

    var err_code = Atomic(u16).init(0);
    var next_idx = Atomic(usize).init(0);
    var wg = WaitGroupT.init(rt.getSched());
    const batch_size = @max(batch, 1);

    const Worker = struct {
        wg: *WaitGroupT,
        items: []T,
        next_idx: *Atomic(usize),
        batch_size: usize,
        err_code: *Atomic(u16),
        user_ctx: ?*anyopaque,

        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const worker_rt = @as(*RuntimeT, @ptrCast(@alignCast(raw_rt)));
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            while (true) {
                const start = ctx.next_idx.fetchAdd(ctx.batch_size, .monotonic);
                if (start >= ctx.items.len) break;
                const end = @min(start + ctx.batch_size, ctx.items.len);
                for (start..end) |idx| {
                    const item_ptr = &ctx.items[idx];
                    eachFn(worker_rt, ctx.user_ctx, item_ptr) catch |err| {
                        _ = ctx.err_code.cmpxchgStrong(0, @intFromError(err), .seq_cst, .seq_cst);
                        continue;
                    };
                }
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
            .batch_size = batch_size,
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

pub const ConcurrentReduceKind = enum { sum, average, min, max };

pub fn concurrentListCount(
    comptime WaitGroupT: type,
    comptime T: type,
    comptime predFn: anytype,
    comptime localSpawnFn: anytype,
    comptime parallelSpawnFn: anytype,
    rt: anytype,
    items: []const T,
    workers: usize,
    batch: usize,
    parallel: bool,
    task_cfg: anytype,
    user_ctx: ?*anyopaque,
) !i64 {
    const RuntimeT = @TypeOf(rt.*);

    const Partial = struct { value: i64 align(64) = 0 };
    var partials: [64]Partial = [_]Partial{.{}} ** 64;
    var err_code = Atomic(u16).init(0);
    var next_idx = Atomic(usize).init(0);
    var wg = WaitGroupT.init(rt.getSched());
    const batch_size = @max(batch, 1);

    const Worker = struct {
        wg: *WaitGroupT,
        items: []const T,
        next_idx: *Atomic(usize),
        batch_size: usize,
        err_code: *Atomic(u16),
        partial: *i64,
        user_ctx: ?*anyopaque,

        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const worker_rt = @as(*RuntimeT, @ptrCast(@alignCast(raw_rt)));
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            while (true) {
                const start = ctx.next_idx.fetchAdd(ctx.batch_size, .monotonic);
                if (start >= ctx.items.len) break;
                const end = @min(start + ctx.batch_size, ctx.items.len);
                for (start..end) |idx| {
                    const item = ctx.items[idx];
                    const keep = predFn(worker_rt, ctx.user_ctx, item) catch |err| {
                        _ = ctx.err_code.cmpxchgStrong(0, @intFromError(err), .seq_cst, .seq_cst);
                        continue;
                    };
                    if (keep) ctx.partial.* += 1;
                }
                worker_rt.checkYield();
            }
        }
    };

    var worker_ctxs: [64]Worker = undefined;
    const actual_workers = @min(if (workers == 0) @as(usize, 1) else workers, @as(usize, 64));
    if (actual_workers == 0) return 0;
    wg.add(actual_workers);
    for (0..actual_workers) |i| {
        worker_ctxs[i] = .{
            .wg = &wg,
            .items = items,
            .next_idx = &next_idx,
            .batch_size = batch_size,
            .err_code = &err_code,
            .partial = &partials[i].value,
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

    var result: i64 = 0;
    for (0..actual_workers) |i| result += partials[i].value;
    return result;
}

pub fn concurrentListReduce(
    comptime WaitGroupT: type,
    comptime T: type,
    comptime R: type,
    comptime mapFn: anytype,
    comptime localSpawnFn: anytype,
    comptime parallelSpawnFn: anytype,
    rt: anytype,
    items: []const T,
    workers: usize,
    batch: usize,
    parallel: bool,
    task_cfg: anytype,
    user_ctx: ?*anyopaque,
    initial: R,
    comptime kind: ConcurrentReduceKind,
) !R {
    const RuntimeT = @TypeOf(rt.*);

    const Partial = struct { value: R align(64) = undefined };
    var partials: [64]Partial = undefined;
    for (&partials) |*partial| partial.value = initial;
    var err_code = Atomic(u16).init(0);
    var next_idx = Atomic(usize).init(0);
    var wg = WaitGroupT.init(rt.getSched());
    const batch_size = @max(batch, 1);

    const Worker = struct {
        wg: *WaitGroupT,
        items: []const T,
        next_idx: *Atomic(usize),
        batch_size: usize,
        err_code: *Atomic(u16),
        partial: *R,
        user_ctx: ?*anyopaque,

        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const worker_rt = @as(*RuntimeT, @ptrCast(@alignCast(raw_rt)));
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            while (true) {
                const start = ctx.next_idx.fetchAdd(ctx.batch_size, .monotonic);
                if (start >= ctx.items.len) break;
                const end = @min(start + ctx.batch_size, ctx.items.len);
                for (start..end) |idx| {
                    const item = ctx.items[idx];
                    const value = mapFn(worker_rt, ctx.user_ctx, item) catch |err| {
                        _ = ctx.err_code.cmpxchgStrong(0, @intFromError(err), .seq_cst, .seq_cst);
                        continue;
                    };
                    switch (kind) {
                        .sum, .average => ctx.partial.* += value,
                        .min => {
                            if (value < ctx.partial.*) ctx.partial.* = value;
                        },
                        .max => {
                            if (value > ctx.partial.*) ctx.partial.* = value;
                        },
                    }
                }
                worker_rt.checkYield();
            }
        }
    };

    var worker_ctxs: [64]Worker = undefined;
    const actual_workers = @min(if (workers == 0) @as(usize, 1) else workers, @as(usize, 64));
    if (actual_workers == 0 or items.len == 0) return initial;
    wg.add(actual_workers);
    for (0..actual_workers) |i| {
        worker_ctxs[i] = .{
            .wg = &wg,
            .items = items,
            .next_idx = &next_idx,
            .batch_size = batch_size,
            .err_code = &err_code,
            .partial = &partials[i].value,
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

    var result: R = initial;
    for (0..actual_workers) |i| {
        const partial = partials[i].value;
        switch (kind) {
            .sum, .average => result += partial,
            .min => {
                if (partial < result) result = partial;
            },
            .max => {
                if (partial > result) result = partial;
            },
        }
    }
    if (comptime kind == .average) return result / @as(R, @floatFromInt(items.len));
    return result;
}
