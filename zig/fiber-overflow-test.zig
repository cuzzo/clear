const std = @import("std");

const Runtime = @import("runtime.zig").Runtime;
const fc = @import("fiber-core.zig");

const Context = fc.Context;
const Fiber = fc.Fiber;

// to avoid linker errors
comptime {
  _ = fc;
}

var main_ctx: Context = undefined;

fn recurseUntilDeath() callconv(.c) void {
    // Allocate on stack to consume space
    var buf: [20]u8 = undefined;

    // Recursive call
    recurseUntilDeath();

    // This forces the compiler to preserve 'buf' (and the stack frame)
    // until *after* the call returns. It disables Tail Call Optimization.
    std.mem.doNotOptimizeAway(&buf);
}

test "Fiber: Software Stack Overflow Detection" {
    const allocator = std.testing.allocator;

    // 1. Setup minimal runtime components
    // We use a small stack (16KB) to hit the limit quickly
    const stack_memory = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(stack_memory);

    // 2. Initialize a Fiber manually
    // We point it to our recursion function
    var fiber = fc.Fiber.init(stack_memory, @intFromPtr(&recurseUntilDeath));

    // 3. Jump into the fiber
    // WARNING: This test is EXPECTED to exit the process with status 1
    // because your current panic_stack_overflow_asm calls std.process.exit(1).
    std.debug.print("\n[Test] Entering recursive fiber (Stack: 16KB, Limit: Bottom + 288B)\n", .{});
    fiber.switchTo(&main_ctx);

    // If we reach here, the test FAILED because it didn't catch the overflow.
    try std.testing.expect(false);
}

