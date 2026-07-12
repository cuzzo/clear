const std = @import("std");

pub const SimAtomic = @import("runtime/vopr-atomic.zig").SimAtomic;

const arc_weak = @import("runtime/arc-weak-vopr.zig");

pub fn main() !void {
    arc_weak.testArcWeakStateMachine() catch |err| {
        std.debug.print("arc-weak-vopr failed: {}\n", .{err});
        std.process.exit(1);
    };
    std.debug.print("arc-weak-vopr: 200 seeds x 1000 operations passed\n", .{});
}
