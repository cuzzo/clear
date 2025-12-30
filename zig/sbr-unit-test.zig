const std = @import("std");
const testing = std.testing;
const ScopeTracker = @import("sbr.zig").ScopeTracker;
const ObjectHeader = @import("sbr.zig").ObjectHeader;
const Alignment = std.mem.Alignment;

fn createObject(allocator: std.mem.Allocator, comptime T: type) !*T {
    // Layout: [Header (16 bytes)] [Data (sizeof T)]
    // We enforce 16-byte alignment to match Runtime/SBR assumptions.
    const header_size = @sizeOf(ObjectHeader);
    const total_size = header_size + @sizeOf(T);
    const slice = try allocator.alignedAlloc(u8, Alignment.fromByteUnits(16), total_size);

    const header = @as(*ObjectHeader, @ptrCast(slice.ptr));
    header.* = .{
        .parent = header,
        .len = @intCast(@sizeOf(T)),
        .log2_align = 4, // 16-byte alignment
        .anchored = false,
        .tracker_index = 0,
    };

    const user_ptr_val = @intFromPtr(slice.ptr) + header_size;
    return @as(*T, @ptrFromInt(user_ptr_val));
}

fn createSlice(allocator: std.mem.Allocator, comptime T: type, n: usize) ![]T {
    const header_size = @sizeOf(ObjectHeader);
    const total_size = header_size + (@sizeOf(T) * n);
    const slice = try allocator.alignedAlloc(u8, Alignment.fromByteUnits(16), total_size);

    const header = @as(*ObjectHeader, @ptrCast(slice.ptr));
    header.* = .{
        .parent = header,
        .len = @intCast(@sizeOf(T) * n),
        .log2_align = 4,
        .anchored = false,
        .tracker_index = 0,
    };

    const user_ptr_val = @intFromPtr(slice.ptr) + header_size;
    return @as([*]T, @ptrFromInt(user_ptr_val))[0..n];
}

test "ScopeTracker: basic add and restore (pointer)" {
    var tracker = try ScopeTracker.init(testing.allocator);
    defer tracker.deinit(testing.allocator);

    const ptr = try createObject(testing.allocator, u64);
    ptr.* = 0xDEADBEEF;

    try tracker.add(testing.allocator, ObjectHeader.fromUserPtr(ptr));
    tracker.closeAndCompact(testing.allocator, 0, null);
}

test "ScopeTracker: basic add and restore (slice)" {
    var tracker = try ScopeTracker.init(testing.allocator);
    defer tracker.deinit(testing.allocator);

    const slice = try createSlice(testing.allocator, u8, 128);
    @memset(slice, 0xFF);

    try tracker.add(testing.allocator, ObjectHeader.fromUserPtr(slice));
    tracker.closeAndCompact(testing.allocator, 0, null);
}

test "ScopeTracker: nested scopes" {
    var tracker = try ScopeTracker.init(testing.allocator);
    defer tracker.deinit(testing.allocator);

    const root_item = try createObject(testing.allocator, u64);
    try tracker.add(testing.allocator, ObjectHeader.fromUserPtr(root_item));

    const mark_scope_1 = tracker.save();

    const child_item = try createSlice(testing.allocator, u16, 10);
    try tracker.add(testing.allocator, ObjectHeader.fromUserPtr(child_item));

    tracker.closeAndCompact(testing.allocator, mark_scope_1, null);
    tracker.closeAndCompact(testing.allocator, 0, null);
}

test "ScopeTracker: closeAndCompact (Survivor Logic)" {
    var tracker = try ScopeTracker.init(testing.allocator);
    defer tracker.deinit(testing.allocator);

    const mark = tracker.save();

    const trash_1 = try createObject(testing.allocator, u32);
    try tracker.add(testing.allocator, ObjectHeader.fromUserPtr(trash_1));

    const survivor = try createObject(testing.allocator, i64);
    survivor.* = 12345;
    try tracker.add(testing.allocator, ObjectHeader.fromUserPtr(survivor));

    const trash_2 = try createSlice(testing.allocator, u8, 32);
    try tracker.add(testing.allocator, ObjectHeader.fromUserPtr(trash_2));

    tracker.closeAndCompact(testing.allocator, mark, ObjectHeader.fromUserPtr(survivor));

    try testing.expectEqual(@as(i64, 12345), survivor.*);
}

test "ScopeTracker: aligned types (max 16)" {
    var tracker = try ScopeTracker.init(testing.allocator);
    defer tracker.deinit(testing.allocator);

    const AlignedData = struct {
        data: [64]u8 align(16),
    };

    const ptr = try createObject(testing.allocator, AlignedData);

    try tracker.add(testing.allocator, ObjectHeader.fromUserPtr(ptr));
    tracker.closeAndCompact(testing.allocator, 0, null);
}

test "ScopeTracker: closeAndCompact with slice survivor" {
    var tracker = try ScopeTracker.init(testing.allocator);
    defer tracker.deinit(testing.allocator);

    const mark = tracker.save();

    const trash = try createObject(testing.allocator, u32);
    try tracker.add(testing.allocator, ObjectHeader.fromUserPtr(trash));

    const survivor_slice = try createSlice(testing.allocator, u8, 100);
    try tracker.add(testing.allocator, ObjectHeader.fromUserPtr(survivor_slice));

    tracker.closeAndCompact(testing.allocator, mark, ObjectHeader.fromUserPtr(survivor_slice));
}

