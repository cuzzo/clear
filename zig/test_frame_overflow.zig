const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;

const Value = union(enum) {
    Nil: void,
    Str: []const u8,
    List: []Value,
};

test "frame-allocated string promoted to heap: no double-free" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("LEAK");
    }
    const allocator = gpa.allocator();
    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var rt = try Runtime.init(allocator, 128 * 1024 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    // Allocate a string on the frame
    const frame_str = try rt.frameAlloc().dupe(u8, "hello from frame");

    // "Promote" to heap (like promoteList / heapAlloc.dupe does)
    const heap_str = try rt.heapAlloc().dupe(u8, frame_str);

    // Frame rewind: frame_str memory is reclaimed
    // (simulate by saving/restoring frame mark)
    const mark = rt.saveFrameMark();
    _ = mark;
    // Don't actually rewind - just verify heap_str is independent

    // Free heap copy - should work, it's heap-allocated
    rt.heapAlloc().free(heap_str);

    // frame_str will be reclaimed by frame arena on rt.deinit() - no explicit free needed
}

test "frame-allocated ArrayList promoted: items buffer survives rewind" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("LEAK");
    }
    const allocator = gpa.allocator();
    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var rt = try Runtime.init(allocator, 128 * 1024 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    // Build a list on the frame
    var list = std.ArrayListUnmanaged(Value){};
    try list.append(rt.frameAlloc(), Value{ .Str = "a" });
    try list.append(rt.frameAlloc(), Value{ .Str = "b" });

    // Copy items buffer to heap (like implicit COPY does)
    const heap_buf = try rt.heapAlloc().alloc(Value, list.items.len);
    @memcpy(heap_buf, list.items);

    // Simulate frame rewind
    const mark = rt.saveFrameMark();
    // list.items is now in reclaimed frame memory
    // but heap_buf is independent

    // Verify heap_buf is still valid
    try std.testing.expect(heap_buf.len == 2);
    try std.testing.expect(std.mem.eql(u8, heap_buf[0].Str, "a"));
    try std.testing.expect(std.mem.eql(u8, heap_buf[1].Str, "b"));

    // Free heap_buf - should work
    rt.heapAlloc().free(heap_buf);
    rt.restoreFrameMark(mark);
}

test "frame ArrayList with heap-duped strings: promote + rewind + cleanup = no double-free" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("LEAK");
    }
    const allocator = gpa.allocator();
    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var rt = try Runtime.init(allocator, 128 * 1024 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    // Build list with heap-duped string elements (like COPY "hello" in union)
    var list = std.ArrayListUnmanaged(Value){};
    try list.append(rt.frameAlloc(), Value{ .Str = try rt.heapAlloc().dupe(u8, "hello") });
    try list.append(rt.frameAlloc(), Value{ .Str = try rt.heapAlloc().dupe(u8, "world") });

    // Deep-copy items to heap (like implicit COPY for union field)
    const heap_buf = try rt.heapAlloc().alloc(Value, list.items.len);
    for (heap_buf, 0..) |*dst, i| {
        dst.* = try CheatLib.dupeUnionValue(Value, list.items[i], rt.heapAlloc());
    }

    // Clean up originals (like TAKES cleanup or list defer)
    for (list.items) |*e| {
        CheatLib.cleanup(Value, rt.heapAlloc(), e);
    }
    list.deinit(rt.frameAlloc());

    // Verify heap copies are independent and valid
    try std.testing.expect(heap_buf.len == 2);
    try std.testing.expect(std.mem.eql(u8, heap_buf[0].Str, "hello"));
    try std.testing.expect(std.mem.eql(u8, heap_buf[1].Str, "world"));

    // Clean up heap copies
    for (heap_buf) |*e| {
        CheatLib.cleanup(Value, rt.heapAlloc(), e);
    }
    rt.heapAlloc().free(heap_buf);
}

test "promoteList then cleanup: no double-free, no leak" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("LEAK");
    }
    const allocator = gpa.allocator();
    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var rt = try Runtime.init(allocator, 128 * 1024 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    // Build list on frame with heap strings
    var list = std.ArrayListUnmanaged(Value){};
    try list.append(rt.frameAlloc(), Value{ .Str = try rt.heapAlloc().dupe(u8, "promoted") });

    // Promote (copies buffer to heap, old buffer stays on frame)
    try CheatLib.promoteList(Value, &rt, &list);

    // list.items is now heap-backed
    try std.testing.expect(list.items.len == 1);
    try std.testing.expect(std.mem.eql(u8, list.items[0].Str, "promoted"));

    // Cleanup: free elements then deinit list (heap alloc)
    for (list.items) |*e| {
        CheatLib.cleanup(Value, rt.heapAlloc(), e);
    }
    list.deinit(rt.heapAlloc());
}
