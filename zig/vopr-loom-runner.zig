// Top-level wrapper for runtime/vopr-loom.zig.
//
// Built as the `loom` executable. Module root must sit at `zig/` (rather
// than `zig/runtime/`) because `runtime/foo.zig` files do
// `@import("../lib/bar.zig")` and Zig 0.16 forbids walking outside the
// module root. Mirrors the parking-lot-loom-test.zig pattern.
//
// Re-exports `SimAtomic` / `SimRing` at root so the comptime Atomic alias
// in queues.zig / scheduler.zig / parking-lot.zig (`@import("root")`)
// resolves to SimAtomic when this binary runs.

pub const SimAtomic = @import("runtime/vopr-atomic.zig").SimAtomic;
pub const SimRing = @import("runtime/vopr-ring.zig").SimRing;

const vl = @import("runtime/vopr-loom.zig");

pub fn main() !void {
    return vl.main();
}
