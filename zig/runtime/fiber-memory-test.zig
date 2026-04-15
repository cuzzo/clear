const std = @import("std");
const fm = @import("fiber-memory.zig");
const fc = @import("fiber-core.zig");

const alloc = std.testing.allocator;

test "StackPool alloc returns expected sizes for each tier" {
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();

    const sizes = [_]fc.StackSize{ .Micro, .Standard, .Large, .Xl, .Huge };
    const expected = [_]usize{
        fm.MICRO_STACK_SIZE,
        fm.STANDARD_STACK_SIZE,
        fm.LARGE_STACK_SIZE,
        fm.XL_STACK_SIZE,
        fm.HUGE_STACK_SIZE,
    };

    for (sizes, expected) |size_class, want| {
        const stack = try pool.alloc(size_class);
        defer pool.free(stack);
        try std.testing.expectEqual(want, stack.len);
        stack[stack.len - 1] = 0xAB;
    }
}

test "StackPool free and flushLocalCache support reuse across tiers" {
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();

    const micro = try pool.alloc(.Micro);
    const standard = try pool.alloc(.Standard);
    const large = try pool.alloc(.Large);

    pool.free(micro);
    pool.free(standard);
    pool.free(large);
    pool.flushLocalCache();

    const micro2 = try pool.alloc(.Micro);
    defer pool.free(micro2);
    const standard2 = try pool.alloc(.Standard);
    defer pool.free(standard2);
    const large2 = try pool.alloc(.Large);
    defer pool.free(large2);

    try std.testing.expectEqual(@as(usize, fm.MICRO_STACK_SIZE), micro2.len);
    try std.testing.expectEqual(@as(usize, fm.STANDARD_STACK_SIZE), standard2.len);
    try std.testing.expectEqual(@as(usize, fm.LARGE_STACK_SIZE), large2.len);
}
