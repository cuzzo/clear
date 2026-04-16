// sha_native.zig -- SHA256 primitives for CLEAR FFI.
//
// Two-function design: sha256Once does a single hash (fast, yields between
// iterations via CLEAR's FOR loop checkYield), toHex encodes the final result.
// This prevents one heavy request from starving the fiber scheduler.

const std = @import("std");

/// Single SHA256 hash. Input: arbitrary bytes. Output: 32-byte hash as []u8.
/// Called from CLEAR in a FOR loop so the scheduler can yield between iterations.
pub fn sha256Once(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const result = try allocator.alloc(u8, 32);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(data);
    h.final(result[0..32]);
    return result;
}

/// Encode first 8 bytes of a hash as a 16-char hex string.
pub fn toHex(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const hex = try allocator.alloc(u8, 16);
    const charset = "0123456789abcdef";
    const len = if (data.len < 8) data.len else 8;
    for (data[0..len], 0..) |b, idx| {
        hex[idx * 2] = charset[b >> 4];
        hex[idx * 2 + 1] = charset[b & 0x0f];
    }
    return hex;
}
