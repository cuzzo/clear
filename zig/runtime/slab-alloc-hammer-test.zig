const std = @import("std");
const SlabAllocator = @import("slab-alloc.zig").SlabAllocator;

const PAGE_SIZE = 4096;
const PAIRS = 16;
const ITERS_PER_PAIR = 2048;

const HammerObj = struct {
    a: u64,
    b: u64,
    c: u64,
    d: u64,
};

const Slab = SlabAllocator(HammerObj);

const RemotePair = struct {
    owner: *Slab,
    remote: *Slab,
    slot: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    failures: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn waitForEmpty(slot: *std.atomic.Value(usize)) void {
    while (slot.load(.acquire) != 0) {
        std.atomic.spinLoopHint();
    }
}

fn waitForFull(slot: *std.atomic.Value(usize)) usize {
    while (true) {
        const value = slot.load(.acquire);
        if (value != 0) return value;
        std.atomic.spinLoopHint();
    }
}

fn producer(pair: *RemotePair) void {
    var i: usize = 0;
    while (i < ITERS_PER_PAIR) : (i += 1) {
        waitForEmpty(&pair.slot);
        const obj = pair.owner.create() catch {
            _ = pair.failures.fetchAdd(1, .monotonic);
            return;
        };
        obj.* = .{
            .a = @as(u64, @intCast(i)),
            .b = 0xBADC0FFEE0DDF00D,
            .c = @intFromPtr(obj),
            .d = 0x123456789ABCDEF0,
        };
        pair.slot.store(@intFromPtr(obj), .release);
    }
    pair.owner.flushThreadCache();
}

fn consumer(pair: *RemotePair) void {
    var i: usize = 0;
    while (i < ITERS_PER_PAIR) : (i += 1) {
        const ptr_value = waitForFull(&pair.slot);
        const obj: *HammerObj = @ptrFromInt(ptr_value);
        if (obj.b != 0xBADC0FFEE0DDF00D or obj.d != 0x123456789ABCDEF0) {
            _ = pair.failures.fetchAdd(1, .monotonic);
        }
        pair.remote.destroy(obj);
        pair.slot.store(0, .release);
    }
    pair.remote.flushThreadCache();
}

test "slab remote-free mailbox hammer: 16 producer-consumer pairs" {
    var owner = Slab.init(std.heap.page_allocator, PAGE_SIZE);
    defer owner.deinit();
    var remote = Slab.init(std.heap.page_allocator, PAGE_SIZE);
    defer remote.deinit();

    var pairs: [PAIRS]RemotePair = undefined;
    for (&pairs) |*pair| {
        pair.* = .{
            .owner = &owner,
            .remote = &remote,
        };
    }

    var producers: [PAIRS]std.Thread = undefined;
    var consumers: [PAIRS]std.Thread = undefined;

    for (&pairs, 0..) |*pair, idx| {
        producers[idx] = try std.Thread.spawn(.{}, producer, .{pair});
        consumers[idx] = try std.Thread.spawn(.{}, consumer, .{pair});
    }

    for (producers) |thread| thread.join();
    for (consumers) |thread| thread.join();

    for (pairs) |pair| {
        try std.testing.expectEqual(@as(u32, 0), pair.failures.load(.monotonic));
        try std.testing.expectEqual(@as(usize, 0), pair.slot.load(.acquire));
    }

    owner.flushThreadCache();
    remote.flushThreadCache();
    _ = owner.shrinkEmpty(0);
    _ = remote.shrinkEmpty(0);
}
