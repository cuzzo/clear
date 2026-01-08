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
    const new_sp = fc.__zig_alloc_segment();

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

// Global variables to capture addresses for assertion
export var sp_before_morestack: u64 = 0;
export var sp_inside_morestack: u64 = 0;

extern fn test_victim_fn() callconv(.c) void;

test "ASM: Actual __morestack Integration" {
    try fc.test_setup_segment_pool(std.testing.allocator);
    defer fc.test_teardown_segment_pool(std.testing.allocator);

    // Create a dummy parent context with a valid stack buffer.
    // __morestack needs this to switch stacks safely before calling the allocator.
    var temp_stack: [16 * 1024]u8 = undefined;
    var dummy_ctx: fc.Context = undefined;

    // Set SP to the top of our temp buffer (aligned 16 bytes)
    const stack_top = @intFromPtr(&temp_stack) + temp_stack.len;
    dummy_ctx.sp = (stack_top & ~@as(usize, 15)) - 16;

    // Set the thread-local variable so the Assembly can find it
    fc.__fiber_parent_ctx = &dummy_ctx;

    // We use a wrapper to save R12/Registers because __morestack
    // will clobber them, and we don't want to crash the Test Runner.
    asm volatile (
        \\ push %%rbp
        \\ push %%rbx
        \\ push %%r12
        \\ call *%[func]
        \\ pop %%r12
        \\ pop %%rbx
        \\ pop %%rbp
        :
        : [func] "r" (&test_victim_fn),
        : .{ .memory = true, .cc = true, .rax = true, .rcx = true, .rdx = true, .rsi = true, .rdi = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true });

    std.debug.print("Old Stack: 0x{x}\n", .{sp_before_morestack});
    std.debug.print("New Stack: 0x{x}\n", .{sp_inside_morestack});

    // 1. Verify we switched stacks
    // The "inside" SP should be far away (heap) from the "before" SP (stack)
    const diff = if (sp_inside_morestack > sp_before_morestack)
        sp_inside_morestack - sp_before_morestack
    else
        sp_before_morestack - sp_inside_morestack;

    try std.testing.expect(diff > 1024 * 1024); // At least 1MB away

}

extern fn minimal_pivot_asm(func: *const fn () callconv(.c) void, stack: usize) callconv(.c) void;

export var sp_after_return: u64 = 0;

var pivot_worked: bool = false;
fn pivotTarget() callconv(.c) void {
    pivot_worked = true;
}

test "Level 1: Minimal Stack Pivot" {
    try fc.test_setup_segment_pool(std.testing.allocator);
    defer fc.test_teardown_segment_pool(std.testing.allocator);

    pivot_worked = false;

    // Allocate a small buffer to act as a "fake" stack
    var fake_stack: [1024]u8 align(16) = undefined;
    const stack_top = @intFromPtr(&fake_stack) + 1024;

    // Try to run pivotTarget on fake_stack
    minimal_pivot_asm(pivotTarget, stack_top);

    try @import("std").testing.expect(pivot_worked);
}

extern fn level2_snapshot_asm(func: *const fn () callconv(.c) void, stack: usize) callconv(.c) void;

var l2_worked: bool = false;

fn l2Target() callconv(.c) void {
    // Modify registers to prove restoration works
    asm volatile (
        \\ movq $0xDEADBEEF, %%r12
        \\ movq $0xCAFEBABE, %%r13
        ::: .{ .r12 = true, .r13 = true });
    l2_worked = true;
}

test "Level 2: Register Preservation & Linkage" {
    try fc.test_setup_segment_pool(std.testing.allocator);
    defer fc.test_teardown_segment_pool(std.testing.allocator);

    l2_worked = false;

    var fake_stack: [1024]u8 align(16) = undefined;
    const stack_top = @intFromPtr(&fake_stack) + 1024;

    var r12_out: u64 = 0;
    var r13_out: u64 = 0;

    // Corrected Zig ASM Syntax
    asm volatile (
        \\ movq $0xAAAA, %%r12
        \\ movq $0xBBBB, %%r13
        \\ call *%[func_ptr]
        \\ movq %%r12, %[out1]
        \\ movq %%r13, %[out2]
        : [out1] "=r" (r12_out),
          [out2] "=r" (r13_out),
        : [func_ptr] "r" (&level2_snapshot_asm),
          [target] "{rdi}" (&l2Target), // Explicitly put target in RDI
          [stack] "{rsi}" (stack_top), // Explicitly put stack in RSI
        : .{ .r12 = true, .r13 = true, .r15 = true, .r14 = true, .rax = true, .rcx = true, .rdx = true, .rbx = true, .memory = true });

    try @import("std").testing.expect(l2_worked);
    // If restoration works, these should be the original 0xAAAA/0xBBBB,
    // NOT the 0xDEADBEEF set inside the target function.
    try @import("std").testing.expectEqual(@as(u64, 0xAAAA), r12_out);
    try @import("std").testing.expectEqual(@as(u64, 0xBBBB), r13_out);
}

extern fn level3_parent_switch_asm(func: *const fn () callconv(.c) void, new_stack: usize, parent_stack_ptr: *usize) callconv(.c) void;

var l3_worked: bool = false;

var helper_called: bool = false;
var target_called: bool = false;

export fn level3_zig_helper() callconv(.c) void {
  // DO NOT PRINT HERE. Just set the flag.
  @as(*volatile bool, @ptrCast(&helper_called)).* = true;
}

fn l3Target() callconv(.c) void {
    @as(*volatile bool, @ptrCast(&target_called)).* = true;
}

test "Level 3: Hardened Transition" {
    try fc.test_setup_segment_pool(std.testing.allocator);
    defer fc.test_teardown_segment_pool(std.testing.allocator);

    helper_called = false;
    target_called = false;

    var segment_stack: [2048]u8 align(16) = undefined;
    const segment_top = @intFromPtr(&segment_stack) + 2048;

    var parent_stack: [2048]u8 align(16) = undefined;
    var parent_sp = @intFromPtr(&parent_stack) + 2048;

    level3_parent_switch_asm(l3Target, segment_top, &parent_sp);

    try std.testing.expect(helper_called);
    try std.testing.expect(target_called);
}

extern fn level4_tls_test_asm() callconv(.c) *fc.Context;

test "Level 4: TLS Resolution Integrity" {
    try fc.test_setup_segment_pool(std.testing.allocator);
    defer fc.test_teardown_segment_pool(std.testing.allocator);

    var dummy_ctx = fc.Context{ .sp = 0x12345678 };
    fc.__fiber_parent_ctx = &dummy_ctx;

    const zig_address = @intFromPtr(fc.__fiber_parent_ctx);
    const asm_address = @intFromPtr(level4_tls_test_asm());

    std.debug.print("\nZig TLS Address: 0x{x}\n", .{zig_address});
    std.debug.print("Asm TLS Address: 0x{x}\n", .{asm_address});

    try std.testing.expectEqual(zig_address, asm_address);
}

test "switch_context_asm basic functionality" {
    try fc.test_setup_segment_pool(std.testing.allocator);
    defer fc.test_teardown_segment_pool(std.testing.allocator);

    var ctx1 = Context{ .sp = 0 };
    const ctx2 = Context{ .sp = 0 };

    std.debug.print("\nBefore switch:\n", .{});
    std.debug.print("  ctx1.sp = 0x{x}\n", .{ctx1.sp});
    std.debug.print("  ctx2.sp = 0x{x}\n", .{ctx2.sp});

    // Save current context to ctx1
    // This should just save and restore immediately
    switch_context_asm(&ctx1, &ctx1);

    std.debug.print("After switch to self:\n", .{});
    std.debug.print("  ctx1.sp = 0x{x}\n", .{ctx1.sp});
    std.debug.print("  Should be valid stack address\n", .{});

    // Verify SP looks reasonable
    try std.testing.expect(ctx1.sp != 0);
    try std.testing.expect(ctx1.sp > 0x7000_0000_0000); // Reasonable stack address
}

var test_function_called = false;

fn simpleTestFunction() callconv(.c) void {
    test_function_called = true;
    std.debug.print("simpleTestFunction called!\n", .{});

    // Switch back to main_ctx
    var dummy: Context = undefined;
    switch_context_asm(&dummy, &main_ctx);
}

test "manual stack setup" {
    try fc.test_setup_segment_pool(std.testing.allocator);
    defer fc.test_teardown_segment_pool(std.testing.allocator);

    test_function_called = false;

    // Allocate stack
    const stack_mem = try std.testing.allocator.alloc(u8, 8 * 1024);
    defer std.testing.allocator.free(stack_mem);

    // Fill with recognizable pattern
    @memset(stack_mem, 0xCC);

    // Get stack top
    const stack_top = @intFromPtr(stack_mem.ptr) + stack_mem.len;
    std.debug.print("\nStack: 0x{x} - 0x{x}\n", .{ @intFromPtr(stack_mem.ptr), stack_top });

    // Align down to 16 bytes
    const aligned_top = stack_top & ~@as(usize, 0xF);
    std.debug.print("Aligned top: 0x{x}\n", .{aligned_top});

    // Put return address at aligned_top - 8
    const return_addr_location = aligned_top - 8;
    const return_ptr = @as(*usize, @ptrFromInt(return_addr_location));
    return_ptr.* = @intFromPtr(&simpleTestFunction);

    std.debug.print("Entry function: 0x{x}\n", .{@intFromPtr(&simpleTestFunction)});
    std.debug.print("Stored at: 0x{x}\n", .{return_addr_location});
    std.debug.print("Value stored: 0x{x}\n", .{return_ptr.*});

    // Create context with SP pointing at the return address
    var fiber_ctx = Context{
        .sp = return_addr_location,
    };

    std.debug.print("Initial SP: 0x{x}\n", .{fiber_ctx.sp});

    // Switch!
    std.debug.print("Switching...\n", .{});
    switch_context_asm(&main_ctx, &fiber_ctx);

    std.debug.print("Back from switch\n", .{});
    try std.testing.expect(test_function_called);
}

// --- Hardware Breakpoints for debugging ---
extern fn test_harness() callconv(.c) void;

export var debug_step: u64 = 0;
export var saved_rsp_val: u64 = 0;

test "ASM: Conclusive Stitched Stack Test" {
    try fc.test_setup_segment_pool(std.testing.allocator);
    defer fc.test_teardown_segment_pool(std.testing.allocator);

    // 1. Setup Parent Context (The "Scheduler" stack for allocator execution)
    var dummy_stack: [4096]u8 align(16) = undefined;
    var parent_ctx = fc.Context{ .sp = @intFromPtr(&dummy_stack) + 2048 };
    fc.__fiber_parent_ctx = &parent_ctx;

    // 2. Run the Harness
    // We use an extern function to ensure the compiler doesn't
    // mess with our stack frames during the test.
    asm volatile (
        \\ push %%rbp
        \\ push %%rbx
        \\ push %%r12
        \\ call *%[func]
        \\ pop %%r12
        \\ pop %%rbx
        \\ pop %%rbp
        :
        : [func] "r" (&test_harness),
        : .{ .memory = true, .rax = true, .rcx = true, .rdx = true, .rsi = true, .rdi = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true });
    //test_harness();

    // 3. Validation Logic

    // Check Phase 1 -> 2: Did we move to the heap?
    const heap_diff = if (sp_inside_morestack > sp_before_morestack)
        sp_inside_morestack - sp_before_morestack
    else
        sp_before_morestack - sp_inside_morestack;

    std.debug.print("\nStack Transition: 0x{x} -> 0x{x} (Stitch)\n", .{ sp_before_morestack, sp_inside_morestack });
    try std.testing.expect(heap_diff > 1024 * 1024); // Verify heap jump

    // Check Phase 2 -> 3: Did __lessstack restore the stack pointer?
    // Note: sp_after_return should be exactly 8 bytes higher than sp_before_morestack
    // (because the 'push %rax' in the harness was popped/dropped)
    std.debug.print("Final Restore: 0x{x}\n", .{sp_after_return});
    try std.testing.expect(sp_after_return == sp_before_morestack + 16);
}

// Assembly Hooks
extern fn run_microscope(fake_stack_top: usize) callconv(.c) void;
extern var microscope_new_sp: u64;
extern var microscope_old_sp_ref: u64;

test "Microscope: Verify Stack Stitching Layout" {
    try fc.test_setup_segment_pool(std.testing.allocator);
    defer fc.test_teardown_segment_pool(std.testing.allocator);

    // 1. Setup Scheduler Stack (Essential for __morestack)
    var parent_stack: [4096]u8 align(16) = undefined;
    var parent_ctx = fc.Context{
        .sp = @intFromPtr(&parent_stack) + 2048,
    };
    fc.__fiber_parent_ctx = &parent_ctx;

    // 2. Setup Fake Stack
    const fake_stack = try std.testing.allocator.alloc(u8, 1024);
    defer std.testing.allocator.free(fake_stack);
    @memset(fake_stack, 0xAA);

    const fake_stack_top = @intFromPtr(fake_stack.ptr) + fake_stack.len;
    const aligned_top = fake_stack_top & ~@as(usize, 15);

    // 3. Run Microscope
    run_microscope(aligned_top);

    std.debug.print("\n=== Microscope Results ===\n", .{});
    std.debug.print("Fake Stack Top: 0x{x}\n", .{aligned_top});
    std.debug.print("New Stack SP:   0x{x}\n", .{microscope_new_sp});
    std.debug.print("Allocated Seg:  0x{x} - 0x{x}\n", .{ @intFromPtr(fc.__test_last_allocation.ptr), @intFromPtr(fc.__test_last_allocation.ptr) + fc.__test_last_allocation.len });

    // --- ASSERTIONS ---

    // A. Verify New SP is INSIDE the newly allocated segment
    // This proves we switched to the memory we requested.
    const seg_start = @intFromPtr(fc.__test_last_allocation.ptr);
    const seg_end = seg_start + fc.__test_last_allocation.len;

    try std.testing.expect(microscope_new_sp >= seg_start);
    try std.testing.expect(microscope_new_sp < seg_end);

    // B. Verify Linkage to Old Stack
    // Expected: Top - 8(restore) - 8(gadget) - 56(regs) = -72
    const expected_old_sp = aligned_top - 72;
    try std.testing.expectEqual(expected_old_sp, microscope_old_sp_ref);

    // C. Verify ABI Alignment
    // RSP inside function must end in 0x8
    try std.testing.expect((microscope_new_sp & 15) == 8);
}

test "Manual __morestack Simulation" {
    std.debug.print("\n=== Test: Manual Stack Extension ===\n", .{});

    // 1. Setup the segment pool (simulating main thread init)
    //    If we don't do this, alloc_segment_impl should @trap() safely, not segfault.
    try fc.test_setup_segment_pool(std.testing.allocator);
    defer fc.test_teardown_segment_pool(std.testing.allocator);

    // 2. Validate Pool State
    //    Ensure the pool is actually populated with valid heap pointers.
    //    We check the first slot (index 0).
    const pool = fc.pool_addr_cache.?; // Force unwrap to prove it exists
    const first_slot = pool[0];

    std.debug.print("Pool[0] info: ptr=0x{x}, len={}\n", .{ @intFromPtr(first_slot.ptr), first_slot.len });

    // Sanity check: The pool should NOT point to debug garbage (0xCC/0xAA usually < 0x1000)
    try std.testing.expect(@intFromPtr(first_slot.ptr) > 0x1000);
    try std.testing.expect(first_slot.len == 32 * 1024);

    // 3. Manually trigger the allocation logic
    //    This is exactly what the assembly *should* be calling.
    const new_sp = fc.__zig_alloc_segment();

    std.debug.print("Allocated Segment SP: 0x{x}\n", .{new_sp});

    // 4. Verify the returned SP is valid
    //    It should point to the TOP of the allocated memory (minus alignment).
    const top_addr = @intFromPtr(first_slot.ptr) + first_slot.len;
    // Expected: (top & ~15)
    const expected_sp = top_addr & ~@as(usize, 15);

    try std.testing.expectEqual(expected_sp, new_sp);

    // 5. Verify Write Access (The "memset" test)
    //    We try to write to the stack pointer to ensure it's mapped and writable.
    const ptr = @as(*usize, @ptrFromInt(new_sp - 16)); // Back off a bit
    ptr.* = 0xDEAD_BEEF;
    try std.testing.expectEqual(@as(usize, 0xDEAD_BEEF), ptr.*);

    std.debug.print("Write verification successful.\n", .{});

    // 6. Cleanup (Simulate __zig_free_segment)
    fc.__zig_free_segment(new_sp);
}

//extern fn test_abi_clobber_asm() callconv(.c) void;
//
//test "ABI: Argument Preservation (The Fix)" {
//    try fc.test_setup_segment_pool(std.testing.allocator);
//    defer fc.test_teardown_segment_pool(std.testing.allocator);
//
//    // Setup dummy context for the switch
//    var dummy_stack: [4096]u8 align(16) = undefined;
//    var parent_ctx = fc.Context{ .sp = @intFromPtr(&dummy_stack) + 2048 };
//    fc.__fiber_parent_ctx = &parent_ctx;
//
//    // Run the ASM test directly.
//    // The function now handles its own register preservation.
//    test_abi_clobber_asm();
//
//    std.debug.print("\nABI Test Passed (Registers verified in ASM)\n", .{});
//}

