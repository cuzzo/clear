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

const SAFE_STACK_BUFFER_SIZE: usize = 4096;
var safe_stack_buffer: [SAFE_STACK_BUFFER_SIZE]u8 = undefined;

pub export threadlocal var test_parent_ctx: *MockContext = undefined;

export var debug_capture: RegisterState = .{};
export var capture_pivot: RegisterState = .{};
export var capture_restore: RegisterState = .{};

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

    allocator_run_sp = @intFromPtr(&old_sp);
    var aligned_top: usize = 0;

    // 1. Determine the Segment Top
    if (test_overflow_segment) |seg| {
        // [CRITICAL] Check for Double Overflow
        if (is_inside(old_sp, seg)) {
             return 0; // Poison Pill
        }
        // REUSE: Calculate Top
        const seg_top = @intFromPtr(seg.ptr) + seg.len;
        aligned_top = seg_top & ~@as(usize, 15);
    } else {
        // FIRST TIME: Malloc
        // ... (Call internal_alloc or use fake_stack) ...
        const new_slice = &fake_stack;
        test_overflow_segment = new_slice;

        const seg_top = @intFromPtr(new_slice.ptr) + new_slice.len;
        aligned_top = seg_top & ~@as(usize, 15);
    }

    return aligned_top;
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

extern var abi_error_code: u64;

extern fn run_stack_stitch_harness() i64;
test "stack switch" {
    allocator_run_sp = 0;
    test_stack_limit = 0xAAAA_BBBB_CCCC_DDDD;
    breadcrumb_counter = 0;

    var ctx = MockContext{
        // Point to top of safe stack (aligned)
        .sp = @intFromPtr(&safe_stack_buffer) + SAFE_STACK_BUFFER_SIZE - 16,
    };
    test_parent_ctx = &ctx;

    // TODO: Remove
    var parent_stack: [1024]u8 align(16) = [_]u8{0} ** 1024;
    var parent_ctx = fc.Context{ .sp = @intFromPtr(&parent_stack) + 1024 - 64 };
    fc.__fiber_parent_ctx = &parent_ctx;

    const res = run_stack_stitch_harness();

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

    try std.testing.expectEqual(res, 111142);

    //try std.testing.expectEqual(false, true);
    // 1. Validate State at Pivot
    // Verify RIP matches the label
    try std.testing.expectEqual(@intFromPtr(&test_before_switch), capture_pivot.rip);

    // Verify Callee-Saved Registers (Should match entry state)
    try std.testing.expectEqual(entry_rbx, capture_pivot.rbx);
    try std.testing.expectEqual(@as(u64, 0xAAAA_BBBB_CCCC_DDDD), capture_pivot.r13);  // This is the fake from above
    try std.testing.expectEqual(entry_r14, capture_pivot.r14);
    try std.testing.expectEqual(entry_r15, capture_pivot.r15);

    // Verify R12 (The Critical One - Old Stack Pointer)
    // Logic: push all 6 volatile registers
    // Therefore: R12 must be exactly (entry_rsp - 6 * 8 (48) ).
    const expected_r12 = entry_rsp - 48;
    try std.testing.expectEqual(expected_r12, capture_pivot.r12);

    // Verify RSP (New Stack Pointer)
    // Logic:
    // 1. We took the address of `fake_stack` + 2048.
    // 2. We aligned it down to 16 bytes (`andq $-16`).
    // 3. We added 32 bytes for state (to preserve old stack pointer & limit, and new unwind frame)
    // 5. SNAPSHOT happened right here.
    const stack_end = @intFromPtr(&fake_stack) + 2048;

    // Perform bitwise AND with -16 (which is ~15 for unsigned 64-bit)
    const aligned_end = stack_end & ~@as(u64, 15);
    const expected_rsp = aligned_end - 32;

    // We push the return address AFTER snapshotting, subtract 8 to account for that.
    const resume_rsp = expected_rsp - 8;
    try std.testing.expectEqual(expected_rsp, capture_pivot.rsp);
    try std.testing.expectEqual(@as(u64, 8), resume_rsp & 15);           // Guarantee rsp at resume is 8-byte aligned
    try std.testing.expectEqual(expected_rsp + 16, capture_pivot.rbp);

    // Verify Stack Content
    // The value at the top of the new stack (fake stack) should be the link (R12)
    const val_on_stack = @as(*u64, @ptrFromInt(capture_pivot.rsp)).*;
    try std.testing.expectEqual(capture_pivot.r12, val_on_stack);

    // 2. Validate State at Restore
    // Verify Execution Location
    // Prove we actually reached the end label
    try std.testing.expectEqual(@intFromPtr(&test_restore_done), capture_restore.rip);

    // Verify RSP (Stack Pointer)
    // At the moment of snapshot(before 'ret'), RSP points to the return address.
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
    const safe_stack_end = safe_stack_start + SAFE_STACK_BUFFER_SIZE;

    try std.testing.expect(allocator_run_sp >= safe_stack_start);
    try std.testing.expect(allocator_run_sp <= safe_stack_end);

    std.debug.print("✓ Exact stack addresses verified\n", .{});
}

