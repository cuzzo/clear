const std = @import("std");
const builtin = @import("builtin");
const CheatLib = @import("runtime-header.zig").CheatLib;

fn noDrop(_: std.mem.Allocator, _: *u64) void {}
const Map = CheatLib.PagedSlotMapWithDrop(u64, noDrop);

const DiscardProbe = struct {
    calls: usize = 0,
    bytes: usize = 0,
    fail_calls_remaining: usize = 0,

    fn discard(raw: ?*anyopaque, _: [*]align(std.heap.page_size_min) u8, len: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        self.bytes += len;
        if (self.fail_calls_remaining != 0) {
            self.fail_calls_remaining -= 1;
            return false;
        }
        return true;
    }
};

fn testMap(capacity: u32, probe: *DiscardProbe) !Map {
    return Map.initWithAllocators(
        std.testing.allocator,
        std.heap.page_allocator,
        capacity,
        probe,
        DiscardProbe.discard,
    );
}

test "PagedSlotMap rejects impossible layouts" {
    try std.testing.expectError(error.ZeroCapacity, Map.initCapacity(std.testing.allocator, 0));
    try std.testing.expectError(error.CapacityTooLarge, Map.initCapacity(std.testing.allocator, Map.max_capacity + 1));

    const Zero = struct {};
    const ZeroMap = CheatLib.PagedSlotMapWithDrop(Zero, struct {
        fn drop(_: std.mem.Allocator, _: *Zero) void {}
    }.drop);
    try std.testing.expectError(error.ZeroSizedPayload, ZeroMap.initCapacity(std.testing.allocator, 1));
}

test "PagedSlotMap inserts resolves mutates and fills" {
    var probe = DiscardProbe{};
    var map = try testMap(3, &probe);
    defer map.deinit();

    const a = try map.insert(10);
    const b = try map.insert(20);
    const c = try map.insert(30);
    try std.testing.expectEqual(@as(i64, 3), map.count());
    try std.testing.expectEqual(@as(usize, 3), map.length());
    try std.testing.expectEqual(@as(u64, 10), map.get(a).?.*);
    map.get(b).?.* = 21;
    const const_map: *const Map = &map;
    try std.testing.expectEqual(@as(u64, 21), const_map.getConst(b).?.*);
    try std.testing.expect(const_map.contains(c));
    try std.testing.expectError(error.Full, map.insert(40));
    try std.testing.expect(map.debugValidate());

    const invalid = Map.makeHandle(100, 0);
    try std.testing.expect(map.get(invalid) == null);
    try std.testing.expect(!map.contains(invalid));
    try std.testing.expect(!map.remove(invalid));
    try std.testing.expectEqual(Map.handleSlot(a), 0);
    try std.testing.expectEqual(Map.handleGeneration(a), 0);
}

test "PagedSlotMap grows without invalidating handles or dropping moved payloads" {
    var probe = DiscardProbe{};
    var drops: usize = 0;
    var map = try OwnedMap.initWithAllocators(
        std.testing.allocator,
        std.heap.page_allocator,
        2,
        &probe,
        DiscardProbe.discard,
    );
    defer map.deinit();

    const first = try map.insert(.{ .value = 10, .drops = &drops });
    const second = try map.insert(.{ .value = 20, .drops = &drops });
    try map.growCapacity(5);
    try std.testing.expectEqual(@as(usize, 5), map.nodes.len);
    try std.testing.expectEqual(@as(usize, 0), drops);
    try std.testing.expectEqual(@as(u64, 10), map.get(first).?.value);
    try std.testing.expectEqual(@as(u64, 20), map.get(second).?.value);

    const third = try map.insert(.{ .value = 30, .drops = &drops });
    try std.testing.expectEqual(@as(u64, 30), map.get(third).?.value);
    try std.testing.expect(map.debugValidate());
    try map.growCapacity(5); // same capacity is a no-op
    try std.testing.expectError(error.CapacityTooLarge, map.growCapacity(Map.max_capacity + 1));
}

test "PagedSlotMap swap remove keeps dense storage and moved handle valid" {
    var probe = DiscardProbe{};
    var map = try testMap(8, &probe);
    defer map.deinit();

    const a = try map.insert(11);
    const b = try map.insert(22);
    const c = try map.insert(33);
    try std.testing.expect(map.remove(b));
    try std.testing.expect(!map.remove(b));
    try std.testing.expect(map.get(b) == null);
    try std.testing.expectEqual(@as(u64, 11), map.get(a).?.*);
    try std.testing.expectEqual(@as(u64, 33), map.get(c).?.*);
    try std.testing.expectEqualSlices(u64, &.{ 11, 33 }, map.denseItemsConst());
    try std.testing.expectEqual(c, map.idAtDense(1).?);
    try std.testing.expect(map.idAtDense(2) == null);

    map.denseItems()[0] = 12;
    try std.testing.expectEqual(@as(u64, 12), map.get(a).?.*);
    try std.testing.expect(map.debugValidate());
}

test "PagedSlotMap generation prevents ABA and exhausted slots retire" {
    var probe = DiscardProbe{};
    var map = try testMap(1, &probe);
    defer map.deinit();

    var previous = try map.insert(0);
    var generation: u32 = 0;
    while (generation < Map.generation_mask) : (generation += 1) {
        try std.testing.expect(map.remove(previous));
        const next = try map.insert(generation + 1);
        try std.testing.expect(next != previous);
        try std.testing.expect(map.get(previous) == null);
        previous = next;
    }
    try std.testing.expectEqual(Map.generation_mask, Map.handleGeneration(previous));
    try std.testing.expect(map.remove(previous));
    try std.testing.expectError(error.Full, map.insert(999));
    try std.testing.expect(map.debugValidate());
}

const Owned = struct {
    value: u64,
    drops: *usize,
};

fn countDrop(_: std.mem.Allocator, value: *Owned) void {
    value.drops.* += 1;
}

const OwnedMap = CheatLib.PagedSlotMapWithDrop(Owned, countDrop);

test "PagedSlotMap drops removed moved cleared and remaining payloads exactly once" {
    var probe = DiscardProbe{};
    var drops: usize = 0;
    var map = try OwnedMap.initWithAllocators(
        std.testing.allocator,
        std.heap.page_allocator,
        8,
        &probe,
        DiscardProbe.discard,
    );

    const first = try map.insert(.{ .value = 1, .drops = &drops });
    const middle = try map.insert(.{ .value = 2, .drops = &drops });
    const last = try map.insert(.{ .value = 3, .drops = &drops });
    try std.testing.expect(map.remove(middle));
    try std.testing.expectEqual(@as(usize, 1), drops);
    try std.testing.expectEqual(@as(u64, 3), map.get(last).?.value);
    try std.testing.expect(map.remove(first));
    try std.testing.expectEqual(@as(usize, 2), drops);

    _ = try map.insert(.{ .value = 4, .drops = &drops });
    map.clear();
    try std.testing.expectEqual(@as(usize, 4), drops);
    try std.testing.expectEqual(@as(usize, 0), map.length());
    try std.testing.expect(map.get(last) == null);

    _ = try map.insert(.{ .value = 5, .drops = &drops });
    map.deinit();
    try std.testing.expectEqual(@as(usize, 5), drops);
}

test "PagedSlotMap default CLEAR cleanup releases owned payload fields" {
    const Payload = struct { text: []u8 };
    var map = try CheatLib.PagedSlotMap(Payload).initCapacity(std.testing.allocator, 2);
    _ = try map.insert(.{ .text = try std.testing.allocator.dupe(u8, "graph") });
    CheatLib.cleanup(@TypeOf(map), std.testing.allocator, &map);
    // std.testing.allocator reports a leak if compiler cleanup failed to reach
    // the payload or if it tried to destroy the SlotMap with the wrong allocator.
}

test "PagedSlotMap native reclamation safely ignores sub-page tails" {
    var map = try Map.initCapacity(std.testing.allocator, 1);
    defer map.deinit();
    const handle = try map.insert(1);
    try std.testing.expect(map.remove(handle));
    try std.testing.expectEqual(@as(u32, 0), map.discardFailures());
    try std.testing.expectEqual(@as(u32, 0), map.committedPayloadCapacity());
}

test "PagedSlotMap clear invalidates every live handle and permits reuse" {
    var probe = DiscardProbe{};
    var map = try testMap(32, &probe);
    defer map.deinit();
    var handles: [16]Map.Handle = undefined;
    for (&handles, 0..) |*handle, index| handle.* = try map.insert(index);
    map.clear();
    for (handles) |handle| try std.testing.expect(map.get(handle) == null);
    try std.testing.expect(map.debugValidate());
    const replacement = try map.insert(1234);
    try std.testing.expectEqual(@as(u32, 1), Map.handleGeneration(replacement));
}

test "PagedSlotMap discards all newly empty tail regions and recommits lazily" {
    var probe = DiscardProbe{};
    var map = try testMap(Map.region_capacity * 3, &probe);
    defer map.deinit();

    var handles: [Map.region_capacity * 2]Map.Handle = undefined;
    for (&handles, 0..) |*handle, index| handle.* = try map.insert(index);
    try std.testing.expectEqual(Map.region_capacity * 2, map.committedPayloadCapacity());
    const peak = map.committedBytesEstimate();

    var index: usize = handles.len;
    while (index > Map.region_capacity) {
        index -= 1;
        try std.testing.expect(map.remove(handles[index]));
    }
    try std.testing.expectEqual(Map.region_capacity, map.committedPayloadCapacity());
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expect(probe.bytes > 0);
    try std.testing.expect(map.committedBytesEstimate() < peak);

    _ = try map.insert(9);
    try std.testing.expectEqual(Map.region_capacity * 2, map.committedPayloadCapacity());
    try std.testing.expect(map.virtualReservedBytes() > map.committedBytesEstimate());
}

test "PagedSlotMap retains conservative accounting after discard failure and retries" {
    var probe = DiscardProbe{ .fail_calls_remaining = 1 };
    var map = try testMap(Map.region_capacity, &probe);
    defer map.deinit();

    var handles: [Map.region_capacity]Map.Handle = undefined;
    for (&handles, 0..) |*handle, index| handle.* = try map.insert(index);
    for (handles) |handle| try std.testing.expect(map.remove(handle));
    try std.testing.expectEqual(@as(u32, 1), map.discardFailures());
    try std.testing.expectEqual(Map.region_capacity, map.committedPayloadCapacity());

    // Reaching an empty-region boundary again retries the complete tail.
    const replacement = try map.insert(1);
    try std.testing.expect(map.remove(replacement));
    try std.testing.expectEqual(@as(u32, 1), map.discardFailures());
    try std.testing.expectEqual(@as(u32, 0), map.committedPayloadCapacity());
    try std.testing.expectEqual(@as(usize, 3), probe.calls);
}

test "PagedSlotMap initialization releases every partial allocation on OOM" {
    var fail_index: usize = 0;
    while (fail_index < 2) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, Map.initWithAllocators(
            failing.allocator(),
            std.heap.page_allocator,
            8,
            null,
            DiscardProbe.discard,
        ));
    }
    fail_index = 0;
    while (fail_index < 2) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, Map.initWithAllocators(
            std.testing.allocator,
            failing.allocator(),
            8,
            null,
            DiscardProbe.discard,
        ));
    }
}

fn residentBytes(comptime E: type, slice: []E) !usize {
    const byte_len = slice.len * @sizeOf(E);
    const page_count = (byte_len + std.heap.page_size_min - 1) / std.heap.page_size_min;
    const residency = try std.testing.allocator.alloc(u8, page_count);
    defer std.testing.allocator.free(residency);
    const raw: [*]u8 = @ptrCast(slice.ptr);
    const aligned: [*]align(std.heap.page_size_min) u8 = @alignCast(raw);
    try std.posix.mincore(aligned, byte_len, residency.ptr);
    var pages: usize = 0;
    for (residency) |entry| pages += entry & 1;
    return pages * std.heap.page_size_min;
}

test "PagedSlotMap native reclamation drops physical tail residency" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const capacity = Map.region_capacity * 3;
    var map = try Map.initCapacity(std.testing.allocator, capacity);
    defer map.deinit();
    var handles: [capacity]Map.Handle = undefined;
    for (&handles, 0..) |*handle, index| handle.* = try map.insert(index);

    // Touch both dense mappings, then verify MADV_DONTNEED removes the two
    // empty tail regions from the resident set without unmapping addresses.
    const before = try residentBytes(u64, map.nodes) + try residentBytes(u32, map.dense_to_slot);
    var index: usize = handles.len;
    while (index > Map.region_capacity) {
        index -= 1;
        try std.testing.expect(map.remove(handles[index]));
    }
    const after = try residentBytes(u64, map.nodes) + try residentBytes(u32, map.dense_to_slot);
    try std.testing.expect(after + Map.region_capacity * (@sizeOf(u64) + @sizeOf(u32)) <= before);
}
