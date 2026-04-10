// Native JSON module for FFI struct test.
// All functions take JsonDoc by value (CLEAR passes structs by value).

const std = @import("std");

pub const JsonDoc = struct {
    id: i64,
    data: []const i64,
};

/// Parse JSON into a JsonDoc. Caller owns the data slice (must call freeDoc).
pub fn parseJson(content: []const u8) JsonDoc {
    const parsed = std.json.parseFromSlice(
        struct { id: i64, data: []const i64 },
        std.heap.c_allocator,
        content,
        .{},
    ) catch return JsonDoc{ .id = 0, .data = &.{} };

    const data_copy = std.heap.c_allocator.dupe(i64, parsed.value.data) catch &.{};
    const result = JsonDoc{ .id = parsed.value.id, .data = data_copy };
    parsed.deinit();
    return result;
}

/// Free the data slice allocated by parseJson.
pub fn freeDoc(doc: JsonDoc) void {
    if (doc.data.len > 0) {
        std.heap.c_allocator.free(@constCast(doc.data));
    }
}

/// Return the length of the data array.
pub fn dataLength(doc: JsonDoc) i64 {
    return @intCast(doc.data.len);
}

/// Return element at index.
pub fn dataGet(doc: JsonDoc, index: i64) i64 {
    const i: usize = @intCast(index);
    if (i >= doc.data.len) return 0;
    return doc.data[i];
}
