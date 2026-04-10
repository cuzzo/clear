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

var main_ctx: Context = undefined;
var test_recursion_depth: usize = 0;

// The recursive function that consumes stack
fn recurseDeeply() callconv(.c) void {
    // Consume stack (~64 bytes per frame + overhead)
    var buf: [64]u8 = undefined;
    std.mem.doNotOptimizeAway(&buf);

    if (test_recursion_depth > 0) {
        test_recursion_depth -= 1;
        recurseDeeply();
    } else {
        fc.__fiber.?.yield();
    }
}

test "Fiber: Segmented Stack (Real Memory)" {
    try fc.test_setup_segment_pool(std.testing.allocator);
    defer fc.test_teardown_segment_pool(std.testing.allocator);

    // 1. Alloc small stack (5KB)
    const stack_mem = try std.testing.allocator.alloc(u8, 5 * 1024);
    defer std.testing.allocator.free(stack_mem);

    // 2. Initialize main_ctx with current stack
    main_ctx = Context{ .sp = 0 }; // Will be filled by switchTo

    // 3. Init Fiber with a wrapper function
    var fiber = fc.Fiber.init(stack_mem, @intFromPtr(&recurseDeeply), .Large);

    // 4. Run
    test_recursion_depth = 100;

    std.debug.print("\n[Test] Segmented Stack (Initial 5KB)...\n", .{});
    fiber.switchTo(&main_ctx);

    std.debug.print("[Test] Success\n", .{});
}

