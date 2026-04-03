// Native module demonstrating EFFECTS Alloc and error returns.

const std = @import("std");

/// Allocates a string using the provided allocator. Caller owns the memory.
pub fn zigDupe(allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    return try allocator.dupe(u8, src);
}

/// Joins two strings with a separator, using the provided allocator.
pub fn zigConcat(allocator: std.mem.Allocator, a: []const u8, sep: []const u8, b: []const u8) ![]const u8 {
    const total = a.len + sep.len + b.len;
    const buf = try allocator.alloc(u8, total);
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..][0..sep.len], sep);
    @memcpy(buf[a.len + sep.len..][0..b.len], b);
    return buf;
}

/// Simple non-allocating function that returns an error union.
pub fn safeDivide(a: i64, b: i64) !i64 {
    if (b == 0) return error.DivisionByZero;
    return @divTrunc(a, b);
}
