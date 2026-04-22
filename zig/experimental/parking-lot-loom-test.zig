pub const CLEAR_FRAME_DEBUG = false;
// Re-export SimAtomic and SimRing at the root so queues.zig and scheduler.zig
// use the Loom simulation types instead of real atomics / io_uring.
pub const SimAtomic = @import("runtime/vopr-atomic.zig").SimAtomic;
pub const SimRing = @import("runtime/vopr-ring.zig").SimRing;

test {
    _ = @import("runtime/parking-lot-loom.zig");
}
