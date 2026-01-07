const std = @import("std");
const StackMemory = @import("fiber-memory.zig").StackMemory;

// To avoid linker errors
const fc = @import("fiber-core.zig");
comptime {
  _ = fc;
}

test "StackSlab: Pointer Integrity" {
    const allocator = std.testing.allocator;
    var stack_slab = try @import("fiber-memory.zig").StackSlab.init(allocator);
    defer stack_slab.deinit();

    const stack = try stack_slab.alloc();

    // Ensure we got exactly 16KB
    try std.testing.expectEqual(@as(usize, 16 * 1024), stack.len);

    // Verify pointer casting safety
    _ = stack.ptr;
    stack_slab.free(stack);

    // Note: We can't easily verify 'free' worked without looking at
    // SlabAllocator internals, but we can verify it doesn't crash
    // on the ptrCast.
}

