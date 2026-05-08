pub const CLEAR_FRAME_DEBUG = false;

pub const SimAtomic = @import("runtime/testing/fsm-loom.zig").SimAtomic;
pub const SimRing = @import("runtime/testing/fsm-loom.zig").SimRing;

test {
    _ = @import("runtime/testing/fsm-loom.zig");
}
