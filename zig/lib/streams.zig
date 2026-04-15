const std = @import("std");

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

        const ItemNode = struct {
            value: T,
            remaining_readers: usize,
            next: ?*ItemNode = null,
        };

        pub const Inner = struct {
            alloc: std.mem.Allocator,
            items_head: ?*ItemNode = null,
            items_tail: ?*ItemNode = null,
            wg: WaitGroupType = undefined,
            err: ?anyerror = null,
            owner_count: usize = 0,
            closed: bool = false,
            mutex: std.Thread.Mutex = .{},
        };

        inner: *Inner,
        alloc: std.mem.Allocator,
        next_node: ?*ItemNode = null,
        started: bool = false,
        active: bool = true,

        fn firstUnread(self: Self) ?*ItemNode {
            return if (self.started) self.next_node else self.inner.items_head;
        }

        fn destroyNode(inner: *Inner, node: *ItemNode) void {
            cleanupValue(inner.alloc, &node.value);
            inner.alloc.destroy(node);
        }

        fn releaseConsumedPrefix(inner: *Inner) void {
            while (inner.items_head) |head| {
                if (head.remaining_readers != 0) break;
                inner.items_head = head.next;
                if (inner.items_head == null) inner.items_tail = null;
                destroyNode(inner, head);
            }
        }

        fn releaseUnreadFrom(_: *Self, start: ?*ItemNode) void {
            var cur = start;
            while (cur) |node| : (cur = node.next) {
                std.debug.assert(node.remaining_readers > 0);
                node.remaining_readers -= 1;
            }
        }

        fn clearAllItems(inner: *Inner) void {
            var cur = inner.items_head;
            while (cur) |node| {
                const next_node = node.next;
                destroyNode(inner, node);
                cur = next_node;
            }
            inner.items_head = null;
            inner.items_tail = null;
        }

        fn destroyInner(inner: *Inner) void {
            inner.alloc.destroy(inner);
        }

        pub fn spawnNew(alloc: std.mem.Allocator, sched: anytype) !Self {
            const inner = try alloc.create(Inner);
            inner.* = .{
                .alloc = alloc,
                .wg = WaitGroupType.init(sched),
                .owner_count = 1,
            };
            inner.wg.add(1);
            return .{
                .inner = inner,
                .alloc = alloc,
            };
        }

        pub fn push(self: *Self, val: T) !void {
            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();

            if (self.inner.owner_count == 0) {
                var tmp = val;
                cleanupValue(self.inner.alloc, &tmp);
                return;
            }

            const node = try self.inner.alloc.create(ItemNode);
            node.* = .{
                .value = val,
                .remaining_readers = self.inner.owner_count,
            };
            if (self.inner.items_tail) |tail| {
                tail.next = node;
            } else {
                self.inner.items_head = node;
            }
            self.inner.items_tail = node;
        }

        pub fn close(self: *Self) void {
            self.inner.mutex.lock();
            self.inner.closed = true;
            const should_destroy = self.inner.owner_count == 0;
            self.inner.mutex.unlock();

            self.inner.wg.done();

            if (should_destroy) {
                self.inner.mutex.lock();
                clearAllItems(self.inner);
                self.inner.mutex.unlock();
                destroyInner(self.inner);
            }
        }

        pub fn setError(self: *Self, err: anyerror) void {
            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();
            self.inner.err = err;
        }

        pub fn retain(self: Self) Self {
            std.debug.assert(self.active);

            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();

            self.inner.owner_count += 1;
            var cur = self.firstUnread();
            while (cur) |node| : (cur = node.next) {
                node.remaining_readers += 1;
            }

            return .{
                .inner = self.inner,
                .alloc = self.alloc,
                .next_node = self.next_node,
                .started = self.started,
            };
        }

        pub fn next(self: *Self) anyerror!?T {
            std.debug.assert(self.active);

            if (!self.inner.closed and self.firstUnread() == null and self.inner.err == null) {
                self.inner.wg.wait();
            }

            self.inner.mutex.lock();
            defer self.inner.mutex.unlock();

            if (self.inner.err) |err| return err;

            const current = self.firstUnread() orelse return null;
            const out = try cloneValue(self.inner.alloc, current.value);
            self.started = true;
            self.next_node = current.next;
            std.debug.assert(current.remaining_readers > 0);
            current.remaining_readers -= 1;
            releaseConsumedPrefix(self.inner);
            return out;
        }

        pub fn deinit(self: *Self) void {
            if (!self.active) return;

            var should_destroy = false;
            self.inner.mutex.lock();
            self.releaseUnreadFrom(self.firstUnread());
            std.debug.assert(self.inner.owner_count > 0);
            self.inner.owner_count -= 1;
            self.active = false;
            self.started = true;
            self.next_node = null;

            if (self.inner.owner_count == 0) {
                clearAllItems(self.inner);
                should_destroy = self.inner.closed;
            } else {
                releaseConsumedPrefix(self.inner);
            }
            self.inner.mutex.unlock();

            if (should_destroy) destroyInner(self.inner);
        }
    };
}
