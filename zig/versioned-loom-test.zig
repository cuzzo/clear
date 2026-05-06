pub const CLEAR_FRAME_DEBUG = false;

pub const SimAtomicState = @import("runtime/vopr-atomic.zig");
pub const SimAtomic = SimAtomicState.SimAtomic;
const std = @import("std");
const versioned_loom = @import("runtime/versioned-loom-test.zig");

pub fn main() !void {
    const before = SimAtomicState.sim_atomic_op_count;
    try versioned_loom.testNestedEbrPinDepthLoom(std.heap.c_allocator, true);
    try versioned_loom.testSchedulerWakeGateLoom(std.heap.c_allocator, true);
    const delta = SimAtomicState.sim_atomic_op_count - before;
    std.debug.print(
        "versioned loom: nested EBR pin-depth + scheduler wake gate passed ({d} sim ops)\n",
        .{delta},
    );
}

test {
    _ = @import("runtime/versioned-loom-test.zig");
}
