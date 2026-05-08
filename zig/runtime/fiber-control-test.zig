const std = @import("std");

const Runtime = @import("runtime.zig").Runtime;
const fc = @import("fiber-core.zig");

const Context = fc.Context;
const Fiber = fc.Fiber;

// to avoid linker errors
comptime {
    _ = fc;
}

extern fn switch_context_asm(from: *Context, to: *Context) callconv(.c) void;
extern fn __morestack() callconv(.c) void;

var main_ctx: Context = undefined;

test "Component: Stack Segment Allocator" {
    try fc.test_setup_segment_pool(std.testing.allocator);
    defer fc.test_teardown_segment_pool(std.testing.allocator);

    // 1. Call the allocator manually
    // Mock a stack pointer (just a random number for now, or 0)
    const new_sp = fc.__zig_alloc_segment(42);

    // 2. Verify Alignment (Must be 16-byte aligned for C ABI)
    try std.testing.expect((new_sp & 15) == 0);

    // 3. Verify Writeability
    // The SP points to the "top" (end) of the allocation.
    // Try writing to the bytes immediately below it.
    const ptr = @as(*u64, @ptrFromInt(new_sp - 8));
    ptr.* = 0xDEADBEEF;
    try std.testing.expect(ptr.* == 0xDEADBEEF);

    fc.__zig_free_segment(new_sp);
    // 4. (Optional) Manual Free check if you implemented __zig_free_segment
    // fc.__zig_free_segment(new_sp);
}

