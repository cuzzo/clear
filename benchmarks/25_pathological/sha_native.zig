// sha_native.zig -- SHA256 iterated hashing for CLEAR FFI.
// hashN(seed, iterations) -> 16-char hex string (first 8 bytes of final hash).

const std = @import("std");

/// Compute SHA256(SHA256(...SHA256(seed)...)) iterated `n` times.
/// Returns the first 8 bytes of the final hash as a 16-char hex string.
pub fn hashN(allocator: std.mem.Allocator, seed: []const u8, n: i64) ![]const u8 {
    var buf: [32]u8 = undefined;

    // First hash: seed string
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(seed);
    h.final(&buf);

    // Subsequent iterations: hash the previous hash
    var i: i64 = 1;
    while (i < n) : (i += 1) {
        var h2 = std.crypto.hash.sha2.Sha256.init(.{});
        h2.update(&buf);
        h2.final(&buf);
    }

    // Encode first 8 bytes as hex
    const hex = try allocator.alloc(u8, 16);
    const charset = "0123456789abcdef";
    for (buf[0..8], 0..) |b, idx| {
        hex[idx * 2] = charset[b >> 4];
        hex[idx * 2 + 1] = charset[b & 0x0f];
    }
    return hex;
}
