// json_native.zig — Native JSON helpers for CLEAR FFI.
// Provides optimized JSON operations using Zig's std.json.

const std = @import("std");

/// Parse a JSON document of the form {"id":N,"data":[1,2,...,N]} and return
/// the sum of the "data" array. Uses std.json for parsing.
/// Returns 0 on parse error.
pub fn parseJsonArraySum(content: []const u8) i64 {
    const parsed = std.json.parseFromSlice(
        struct { id: i64, data: []const i64 },
        std.heap.c_allocator,
        content,
        .{},
    ) catch return 0;
    defer parsed.deinit();

    var sum: i64 = 0;
    for (parsed.value.data) |v| {
        sum += v;
    }
    return sum;
}
