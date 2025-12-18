const std = @import("std");
const Stack = @import("runtime-header.zig").Stack;
const Fiber = @import("runtime-header.zig").Fiber;
const Context = @import("runtime-header.zig").Context;

// Stack

test "Stack Allocation and Permissions" {
    // 1. Create a 1MB Stack
    var stack = try Stack.init(1024 * 1024);
    defer stack.deinit();

    std.debug.print("\nStack allocated at: {X} -> {X}\n", .{
        @intFromPtr(stack.memory.ptr),
        @intFromPtr(stack.memory.ptr) + stack.memory.len
    });

    // 2. Prove we can use the top (Where the stack starts)
    const top = stack.getStackTop();
    const ptr = @as(*u64, @ptrFromInt(top));
    ptr.* = 0xDEADBEEF;

    try std.testing.expectEqual(@as(u64, 0xDEADBEEF), ptr.*);
    std.debug.print("Successfully wrote to stack top: {X}\n", .{top});

    // 3. Prove the Guard Page exists
    // The bottom of the memory slice is protected.
    // WARNING: Uncommenting this line will crash the test with a Segfault!
    // stack.memory[0] = 1;
}

// Fiber

// Global to store the main thread's context
var main_ctx: Context = undefined;
var my_fiber: Fiber = undefined;

// The function our fiber will run
fn fiberEntry() void {
    std.debug.print("\n[Fiber] Hello from the fiber stack!", .{});

    // Jump back to main
    std.debug.print("\n[Fiber] Yielding back...", .{});
    my_fiber.yield();

    // If we get here, main switched to us again!
    std.debug.print("\n[Fiber] I am back again!", .{});
    my_fiber.yield();
}

test "Context Switching" {
    std.debug.print("\n[Main] Initializing Fiber...", .{});

    // 1. Create Fiber pointing to our function
    // We cast the function pointer to usize to write it to the stack
    my_fiber = try Fiber.init(1024 * 1024, @intFromPtr(&fiberEntry));
    defer my_fiber.deinit();

    std.debug.print("\n[Main] Switching to Fiber...", .{});

    // 2. Switch to it (Save main_ctx, Load my_fiber.ctx)
    my_fiber.switchTo(&main_ctx);

    std.debug.print("\n[Main] Back in Main! Switching again...", .{});

    // 3. Switch back to resume where it left off
    my_fiber.switchTo(&main_ctx);

    std.debug.print("\n[Main] Done.", .{});
}

