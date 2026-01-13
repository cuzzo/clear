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

var allocator_run_sp: usize = 0;

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
export fn abi_panic(code: u64) noreturn {
    std.debug.print("ABI PANIC: {}\n", .{code});
    std.debug.print("Entry RBX: 0x{x}\n", .{entry_rbx});
    @panic("ABI violation");
}

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


/// ACTUAL TEST

var switched_defer = false;
var boundary_defer = false;
var boundary_err_defer = false;

fn function_that_switches() !void {
    asm volatile ("# >>> FUNCTION_THAT_ERRORS  <<<");
    defer switched_defer = true;
    // Now on new stack
    try function_that_errors();
}

fn function_that_errors() !void {
    return error.Test;
}

fn function_that_errors_through_switch() !void {
    defer boundary_defer = true;
    errdefer boundary_err_defer = true;
    try @call(.never_inline, function_that_switches, .{});
    //try function_that_switches();
}

pub fn main() !void {
    allocator_run_sp = 0;
    test_stack_limit = 0xAAAA_BBBB_CCCC_DDDD;
    breadcrumb_counter = 0;

    var ctx = MockContext{
        // Point to top of safe stack (aligned)
        .sp = @intFromPtr(&safe_stack_buffer) + SAFE_STACK_BUFFER_SIZE - 16,
    };
    test_parent_ctx = &ctx;

    // TODO: Remove
    var parent_stack: [4096]u8 align(16) = [_]u8{0} ** 4096;
    var parent_ctx = fc.Context{ .sp = @intFromPtr(&parent_stack) + 4096 - 64 };
    fc.__fiber_parent_ctx = &parent_ctx;

    function_that_errors_through_switch() catch |e| {
        std.debug.print("SUCCESS: Error propagated: {s}\n", .{@errorName(e)});
        std.debug.print("SWITCHED DEFER: {}\n", .{switched_defer});
        std.debug.print("ERROR DEFER: {}\n", .{boundary_err_defer});
        std.debug.print("BOUNDARY DEFER: {}\n", .{boundary_defer});
        return;
    };

    std.debug.print("FAILURE!!!", .{});
}

