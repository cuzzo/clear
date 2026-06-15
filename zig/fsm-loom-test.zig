pub const CLEAR_FRAME_DEBUG = false;

pub const SimAtomic = @import("runtime/testing/fsm-loom.zig").SimAtomic;
pub const SimRing = @import("runtime/testing/fsm-loom.zig").SimRing;

pub fn main() !void {
    try @import("runtime/testing/fsm-loom.zig").runAll(std.heap.c_allocator);
}

const std = @import("std");

test {
    _ = @import("runtime/testing/fsm-loom.zig");
}
