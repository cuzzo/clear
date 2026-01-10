const std = @import("std");
const fc = @import("fiber-core.zig");

pub const RegisterState = extern struct {
    rax: u64 = 0,
    rbx: u64 = 0,
    rcx: u64 = 0,
    rdx: u64 = 0,
    rdi: u64 = 0,
    rsi: u64 = 0,
    rbp: u64 = 0,
    rsp: u64 = 0,
    r8: u64 = 0,
    r9: u64 = 0,
    r10: u64 = 0,
    r11: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
    rip: u64 = 0,
};

pub const MockContext = extern struct {
    sp: u64 = 0,
};

var safe_stack_buffer: [1024]u8 = undefined;

pub export threadlocal var test_parent_ctx: *MockContext = undefined;

export var debug_capture: RegisterState = .{};
export var capture_pivot: RegisterState = .{};
export var capture_restore: RegisterState = .{};

extern fn __lessstack() callconv(.c) void;
extern fn test_morestack_simple() void;
extern fn test_morestack_stop() void;
extern fn test_lessstack_harness(mock_rsp: usize) void;

// Global target for the 'ret' in __lessstack to hit
extern var test_saved_rsp: usize;
extern fn test_restore_point() void;
extern fn test_restore_done() void;

extern var entry_rbx: u64;
extern var entry_rsp: u64;
extern var entry_rbp: u64;
extern var entry_r12: u64;
extern var entry_r13: u64;
extern var entry_r14: u64;
extern var entry_r15: u64;
extern var fake_stack: [2048]u8;
extern fn test_before_switch() void;

pub export threadlocal var test_stack_limit: u64 = 0;

export fn abi_panic(code: u64) noreturn {
    std.debug.print("ABI PANIC: {}\n", .{code});
    std.debug.print("Entry RBX: 0x{x}\n", .{entry_rbx});
    @panic("ABI violation");
}


var allocator_run_sp: usize = 0;

// The "Sticky" segment for the test.
// In real code, this lives in the Fiber struct.
var test_overflow_segment: ?[]u8 = null;

// Helper to check if a pointer is inside a slice
fn is_inside(ptr: usize, slice: []u8) bool {
    const start = @intFromPtr(slice.ptr);
    const end = start + slice.len;
    return ptr >= start and ptr < end;
}

// Runs on emergency stack
export fn __zig_stack_overflow_handler() callconv(.c) noreturn {
    // 1. Log the error
    std.debug.print("FATAL: Fiber Stack Overflow (Double Fault)\n", .{});

    // 2. Kill the current fiber
    // In a real scheduler, this would be:
    // scheduler.kill_current_fiber(error.StackOverflow);
    // scheduler.schedule_next();

    // For the test, we just exit or loop
    @panic("Fiber Double Stack Overflow");
}

// Runs on emergency stack
export fn __mock_zig_alloc_segment(old_sp: usize) callconv(.c) usize {
    @setRuntimeSafety(false);

    // 1. Verify we received the correct argument (RDI)
    // We expect old_sp to be the snapshot pointer.
    // For this test, we can just print it or assert it's not 0.
    if (old_sp == 0) @panic("Received NULL old_sp in mock_alloc");

    allocator_run_sp = @intFromPtr(&old_sp); // Approximate SP

    // ---------------------------------------------------------
    // STICKY SEGMENT LOGIC
    // ---------------------------------------------------------

    if (test_overflow_segment) |seg| {
        // [CRITICAL] Check for Double Overflow
        if (is_inside(old_sp, seg)) {
             // Tell the fiber it's time to die.
             return 0;
        }

        // Reuse (Sticky Strategy)
        // We aren't currently ON it, so we must be switching TO it.
        // Return the existing top.
        return @intFromPtr(seg.ptr) + seg.len;
    }

    // ---------------------------------------------------------
    // FIRST TIME ALLOCATION
    // ---------------------------------------------------------

    // Simulate Malloc: point to our 'fake_stack' buffer
    const new_slice = &fake_stack;
    test_overflow_segment = new_slice;

    // 2. Return the top of our fake stack (simulating a new segment)
    // Remember: Stack grows down, so return the END of the buffer.
    return @intFromPtr(&fake_stack) + 2048;
}

extern var breadcrumb_counter: u64;
extern var breadcrumbs: [64]u64;

pub fn printBreadcrumbs() void {
    std.debug.print("Breadcrumbs: ", .{});
    for (0..breadcrumb_counter) |i| {
        std.debug.print("{} ", .{breadcrumbs[i]});
    }
    std.debug.print("\n", .{});
}

extern fn test_simple_stack_switch() void;
extern fn test_breadcrumbs() void;
extern var abi_error_code: u64;

test "breadcrumbs work" {
    var parent_stack: [1024]u8 align(16) = [_]u8{0} ** 1024;
    var parent_ctx = fc.Context{ .sp = @intFromPtr(&parent_stack) + 1024 - 64 };
    fc.__fiber_parent_ctx = &parent_ctx;

    // Reset breadcrumbs
    breadcrumb_counter = 0;

    test_breadcrumbs();

    printBreadcrumbs();
    try std.testing.expectEqual(3, breadcrumb_counter);
    try std.testing.expectEqual(100, breadcrumbs[0]);
    try std.testing.expectEqual(200, breadcrumbs[1]);
    try std.testing.expectEqual(300, breadcrumbs[2]);
}

extern fn test_fake_return() void;

test "fake return" {
    // Reset breadcrumbs
    breadcrumb_counter = 0;

    test_fake_return();

    printBreadcrumbs();
    try std.testing.expectEqual(@as(u64, 5), breadcrumb_counter);
    try std.testing.expectEqual(@as(u64, 1000), breadcrumbs[0]);
    try std.testing.expectEqual(@as(u64, 1001), breadcrumbs[1]);
    try std.testing.expectEqual(@as(u64, 1002), breadcrumbs[2]);
    try std.testing.expectEqual(@as(u64, 3000), breadcrumbs[3]);
    try std.testing.expectEqual(@as(u64, 2000), breadcrumbs[4]);
}

extern fn test_snapshot_survives() void;

test "snapshot survives" {
    breadcrumb_counter = 0;

    test_snapshot_survives();

    printBreadcrumbs();
    try std.testing.expectEqual(@as(u64, 11), breadcrumb_counter);
    try std.testing.expectEqual(@as(u64, 1000), breadcrumbs[0]);
    try std.testing.expectEqual(@as(u64, 1001), breadcrumbs[1]);
    try std.testing.expectEqual(@as(u64, 1002), breadcrumbs[2]);
    try std.testing.expectEqual(@as(u64, 1003), breadcrumbs[3]);
    try std.testing.expectEqual(@as(u64, 1004), breadcrumbs[4]);
    try std.testing.expectEqual(@as(u64, 1005), breadcrumbs[5]);
    try std.testing.expectEqual(@as(u64, 3000), breadcrumbs[6]);
    try std.testing.expectEqual(@as(u64, 2000), breadcrumbs[7]);
    try std.testing.expectEqual(@as(u64, 2001), breadcrumbs[8]);
    try std.testing.expectEqual(@as(u64, 2002), breadcrumbs[9]);
    try std.testing.expectEqual(@as(u64, 2003), breadcrumbs[10]);
}

extern fn test_stack_switch() void;

test "stack switch" {
    allocator_run_sp = 0;
    test_stack_limit = 0xAAAA_BBBB_CCCC_DDDD;
    breadcrumb_counter = 0;

    var ctx = MockContext{
        // Point to top of safe stack (aligned)
        .sp = @intFromPtr(&safe_stack_buffer) + 1024 - 16,
    };
    test_parent_ctx = &ctx;

    test_stack_switch();

    printBreadcrumbs();
    try std.testing.expectEqual(@as(u64, 0), abi_error_code);
    try std.testing.expectEqual(@as(u64, 11), breadcrumb_counter);
    try std.testing.expectEqual(@as(u64, 1000), breadcrumbs[0]);
    try std.testing.expectEqual(@as(u64, 1001), breadcrumbs[1]);
    try std.testing.expectEqual(@as(u64, 1002), breadcrumbs[2]);
    try std.testing.expectEqual(@as(u64, 1003), breadcrumbs[3]);
    try std.testing.expectEqual(@as(u64, 1004), breadcrumbs[4]);
    try std.testing.expectEqual(@as(u64, 1005), breadcrumbs[5]);
    try std.testing.expectEqual(@as(u64, 1006), breadcrumbs[6]);
    try std.testing.expectEqual(@as(u64, 3000), breadcrumbs[7]);
    try std.testing.expectEqual(@as(u64, 2000), breadcrumbs[8]);
    try std.testing.expectEqual(@as(u64, 2001), breadcrumbs[9]);
    try std.testing.expectEqual(@as(u64, 2002), breadcrumbs[10]);

    // 1. Validate State at Pivot
    // Verify RIP matches the label
    try std.testing.expectEqual(@intFromPtr(&test_before_switch), capture_pivot.rip);

    // Verify Callee-Saved Registers (Should match entry state)
    try std.testing.expectEqual(entry_rbx, capture_pivot.rbx);
    try std.testing.expectEqual(entry_rbp, capture_pivot.rbp);
    try std.testing.expectEqual(@as(u64, 0xAAAA_BBBB_CCCC_DDDD), capture_pivot.r13); // This is the fake from above
    try std.testing.expectEqual(entry_r14, capture_pivot.r14);
    try std.testing.expectEqual(entry_r15, capture_pivot.r15);

    // Verify R12 (The Critical One - Old Stack Pointer)
    // Logic:
    // 1. entry_rsp points to the Return Address.
    // 2. We pushed RBX (8 bytes).
    // 3. We pushed R12 (8 bytes).
    // 4. We pushed R13 (8 bytes).
    // 5. We pushed R14 (8 bytes) - purely for alignment.
    // 4. Then we did `movq %rsp, %r12`.
    // Therefore: R12 must be exactly (entry_rsp - 32).
    const expected_r12 = entry_rsp - 32;
    try std.testing.expectEqual(expected_r12, capture_pivot.r12);

    // Verify RSP (New Stack Pointer)
    // Logic:
    // 1. We took the address of `fake_stack` + 2048.
    // 2. We aligned it down to 16 bytes (`andq $-16`).
    // 3. We pushed R12 (8 bytes).
    // 4. SNAPSHOT happened right here.
    const stack_end = @intFromPtr(&fake_stack) + 2048;
    // Perform bitwise AND with -16 (which is ~15 for unsigned 64-bit)
    const aligned_end = stack_end & ~@as(u64, 15);
    const expected_rsp = aligned_end - 8;
    try std.testing.expectEqual(expected_rsp, capture_pivot.rsp);

    // Verify Stack Content
    // The value at the top of the new stack (fake stack) should be the link (R12)
    const val_on_stack = @as(*u64, @ptrFromInt(capture_pivot.rsp)).*;
    try std.testing.expectEqual(capture_pivot.r12, val_on_stack);


    // 2. Validate State at Restore
    // Verify Execution Location
    // Prove we actually reached the end label
    try std.testing.expectEqual(@intFromPtr(&test_restore_done), capture_restore.rip);

    // Verify RSP (Stack Pointer)
    // At the moment of snapshot (before 'ret'), RSP points to the return address.
    // entry_rsp was captured at the very start, pointing to that same return address.
    // They must be identical.
    try std.testing.expectEqual(entry_rsp, capture_restore.rsp);

    // Verify Callee-Saved Registers
    // These MUST match the entry values. If they don't, you corrupted the parent's state.
    try std.testing.expectEqual(entry_rbx, capture_restore.rbx);
    try std.testing.expectEqual(entry_rbp, capture_restore.rbp);
    try std.testing.expectEqual(entry_r12, capture_restore.r12); // Crucial: R12 is back to original value
    try std.testing.expectEqual(entry_r13, capture_restore.r13);
    try std.testing.expectEqual(entry_r14, capture_restore.r14);
    try std.testing.expectEqual(entry_r15, capture_restore.r15);

    // Verify Stack Content (The Return Address)
    // RSP points to the return address. We want to verify that the value *at* RSP
    // is the same value that was there when we started.
    // This proves we didn't accidentally overwrite the return address while pivoting.
    const ret_addr_at_entry   = @as(*u64, @ptrFromInt(entry_rsp)).*;
    const ret_addr_at_restore = @as(*u64, @ptrFromInt(capture_restore.rsp)).*;
    try std.testing.expectEqual(ret_addr_at_entry, ret_addr_at_restore);

    // CRITICAL: Ensure old stack limit was preserved.
    try std.testing.expectEqual(@as(u64, 0xAAAA_BBBB_CCCC_DDDD), test_stack_limit);

    // CRITICAL: Ensure that we ran __alloc_new_segment on EMERGENCY STACK
    const safe_stack_start = @intFromPtr(&safe_stack_buffer);
    const safe_stack_end = safe_stack_start + 1024;

    try std.testing.expect(allocator_run_sp >= safe_stack_start);
    try std.testing.expect(allocator_run_sp <= safe_stack_end);

    std.debug.print("✓ Exact stack addresses verified\n", .{});
}

//test "simple stack switch" {
//    var parent_stack: [1024]u8 align(16) = [_]u8{0} ** 1024;
//    var parent_ctx = fc.Context{ .sp = @intFromPtr(&parent_stack) + 1024 - 64 };
//    fc.__fiber_parent_ctx = &parent_ctx;
//
//    test_simple_stack_switch();
//    printBreadcrumbs();
//    // Should see: 2000 2001 2002 2003 2004 3000 3001
//}


//test "Identify Morestack Hand-off" {
//    try fc.test_setup_segment_pool(std.testing.allocator);
//
//    var parent_stack: [1024]u8 align(16) = [_]u8{0} ** 1024;
//    var parent_ctx = fc.Context{ .sp = @intFromPtr(&parent_stack) + 1024 - 64 };
//    fc.__fiber_parent_ctx = &parent_ctx;
//
//    debug_capture = .{};
//    test_morestack_simple();
//
//    // 1. USE R11. This is where your assembly saved %rsp.
//    const old_frame_ptr = debug_capture.r11;
//    const mem = @as([*]u64, @ptrFromInt(old_frame_ptr));
//
//    std.debug.print("\n--- Stack Memory Map (from R11) ---\n", .{});
//    // We expect 7 items total: 6 registers + 1 return address
//    for (0..7) |i| {
//        std.debug.print("Offset {d:2}: 0x{x}\n", .{ i * 8, mem[i] });
//    }
//
//    std.debug.print("\n--- Old Stack Frame Verification ---\n", .{});
//
//    // 2. VERIFY INDICES (Stack grows down, so last push is index 0)
//    // Order pushed: RetAddr -> RBP -> R12 -> R13 -> R14 -> R15 -> RBX (Top)
//
//    // Index 0: RBX (Last pushed)
//    try std.testing.expectEqual(@as(u64, 0xBBBB_BBBB_BBBB_BBBB), mem[0]);
//
//    // Index 1..4: R15, R14, R13, R12 (Uninitialized in test, values undefined)
//
//    // Index 5: RBP
//    try std.testing.expectEqual(@as(u64, 0xAAAA_AAAA_AAAA_AAAA), mem[5]);
//
//    // Index 6: Return Address
//    // This is the address of 'test_morestack_stop' pushed manually in your setup
//    try std.testing.expectEqual(@intFromPtr(&test_morestack_stop), mem[6]);
//
//    std.debug.print("✓ Morestack setup verified perfectly.\n", .{});
//}


//test "Direct Lessstack Pivot" {
//    // Reset debug state
//    breadcrumb_counter = 0;
//    debug_capture = .{};
//
//    // 1. Construct the "Old Stack"
//    // This simulates the stack frame of the parent function.
//    // __lessstack expects to pop these values into registers.
//    var old_stack = [_]u64{
//        // ... (Higher addresses) ...
//        @intFromPtr(&test_restore_point), // The return address
//        0x5000_0000_0000_0001,            // Saved RBP
//        0x5000_0000_0000_0002,            // Saved R12
//        0x5000_0000_0000_0003,            // Saved R13
//        0x5000_0000_0000_0004,            // Saved R14
//        0x5000_0000_0000_0005,            // Saved R15
//        0x5000_0000_0000_0006,            // Saved RBX (First to be popped)
//    };
//
//    // The "Stack Pointer" points to the last element pushed (RBX at index 6)
//    const old_sp = @intFromPtr(&old_stack[6]);
//
//    // 2. Construct the "New Stack"
//    // __lessstack expects RSP to point to a link (the old_sp).
//    var new_stack: [2]u64 = undefined;
//    new_stack[0] = old_sp;
//
//    const mock_new_rsp = @intFromPtr(&new_stack[0]);
//
//    // 3. Run the test
//    test_lessstack_harness(mock_new_rsp);
//
//    // 4. Verify Breadcrumbs
//    // We expect: 2000 (Entry) -> 2001 (Pop old SP) -> 2002 (After restores)
//    printBreadcrumbs();
//    try std.testing.expectEqual(@as(u64, 3), breadcrumb_counter);
//    try std.testing.expectEqual(@as(u64, 2000), breadcrumbs[0]);
//    try std.testing.expectEqual(@as(u64, 2001), breadcrumbs[1]);
//    try std.testing.expectEqual(@as(u64, 2002), breadcrumbs[2]);
//
//    // 5. Verify Registers
//    try std.testing.expectEqual(@as(u64, 0x5000_0000_0000_0006), debug_capture.rbx);
//    try std.testing.expectEqual(@as(u64, 0x5000_0000_0000_0005), debug_capture.r15);
//    try std.testing.expectEqual(@as(u64, 0x5000_0000_0000_0004), debug_capture.r14);
//    try std.testing.expectEqual(@as(u64, 0x5000_0000_0000_0003), debug_capture.r13);
//    try std.testing.expectEqual(@as(u64, 0x5000_0000_0000_0002), debug_capture.r12);
//    try std.testing.expectEqual(@as(u64, 0x5000_0000_0000_0001), debug_capture.rbp);
//}

