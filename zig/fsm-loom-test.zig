pub const CLEAR_FRAME_DEBUG = false;

pub const SimAtomic = @import("runtime/fsm-loom.zig").SimAtomic;
pub const SimRing = @import("runtime/fsm-loom.zig").SimRing;

test {
    _ = @import("runtime/fsm-loom.zig");
}
