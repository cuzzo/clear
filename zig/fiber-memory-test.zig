const std = @import("std");
const StackMemory = @import("fiber-memory.zig").StackMemory;

test "StackMemory: Bitmask Recovery" {
    const allocator = std.testing.allocator;
    var mem = StackMemory.init(allocator);
    defer mem.deinit();

    const seg = try mem.alloc();
    defer mem.free(seg);

    // 1. Pretend SP is somewhere inside the data
    const sp = @intFromPtr(&seg.data[1000]);

    // 2. Recover
    const recovered = StackMemory.fromSP(sp);

    // 3. Verify
    try std.testing.expectEqual(seg, recovered);
}

