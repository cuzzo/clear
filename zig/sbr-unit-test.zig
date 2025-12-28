const std = @import("std");
const testing = std.testing;
const ScopeTracker = @import("sbr.zig").ScopeTracker;

test "ScopeTracker: basic add and restore (pointer)" {
    var tracker = ScopeTracker.init();
    defer tracker.deinit(testing.allocator);

    const ptr = try testing.allocator.create(u32);
    ptr.* = 0xDEADBEEF;

    try tracker.add(testing.allocator, ptr);
    tracker.restore(testing.allocator, 0);
}

test "ScopeTracker: basic add and restore (slice)" {
    var tracker = ScopeTracker.init();
    defer tracker.deinit(testing.allocator);

    const slice = try testing.allocator.alloc(u8, 128);
    @memset(slice, 0xFF);

    try tracker.add(testing.allocator, slice);
    tracker.restore(testing.allocator, 0);
}

test "ScopeTracker: nested scopes" {
    var tracker = ScopeTracker.init();
    defer tracker.deinit(testing.allocator);

    const root_item = try testing.allocator.create(u64);
    try tracker.add(testing.allocator, root_item);

    const mark_scope_1 = tracker.save();

    const child_item = try testing.allocator.alloc(u16, 10);
    try tracker.add(testing.allocator, child_item);

    tracker.restore(testing.allocator, mark_scope_1);
    tracker.restore(testing.allocator, 0);
}

test "ScopeTracker: closeAndKeep (Survivor Logic)" {
    var tracker = ScopeTracker.init();
    defer tracker.deinit(testing.allocator);

    const mark = tracker.save();

    const trash_1 = try testing.allocator.create(u32);
    try tracker.add(testing.allocator, trash_1);

    const survivor = try testing.allocator.create(i64);
    survivor.* = 12345;
    try tracker.add(testing.allocator, survivor);

    const trash_2 = try testing.allocator.alloc(u8, 32);
    try tracker.add(testing.allocator, trash_2);

    tracker.closeAndKeep(testing.allocator, mark, survivor);

    try testing.expectEqual(@as(i64, 12345), survivor.*);
    testing.allocator.destroy(survivor);
}

test "ScopeTracker: high alignment types" {
    var tracker = ScopeTracker.init();
    defer tracker.deinit(testing.allocator);

    const AlignedData = struct {
        data: [64]u8 align(128),
    };

    const ptr = try testing.allocator.create(AlignedData);

    // FIX: Switch with lowercase .pointer
    switch (@typeInfo(@TypeOf(ptr))) {
        .pointer => |p| try testing.expectEqual(128, p.alignment),
        else => unreachable,
    }

    try tracker.add(testing.allocator, ptr);
    tracker.restore(testing.allocator, 0);
}

test "ScopeTracker: closeAndKeep with slice survivor" {
    var tracker = ScopeTracker.init();
    defer tracker.deinit(testing.allocator);

    const mark = tracker.save();

    const trash = try testing.allocator.create(u32);
    try tracker.add(testing.allocator, trash);

    const survivor_slice = try testing.allocator.alloc(u8, 100);
    try tracker.add(testing.allocator, survivor_slice);

    tracker.closeAndKeep(testing.allocator, mark, survivor_slice);

    testing.allocator.free(survivor_slice);
}

