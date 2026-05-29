//! Top-level executable wrapper for runtime/data-structures-vopr.zig.

const std = @import("std");

pub const CLEAR_FRAME_DEBUG = false;
pub const SimClock = @import("runtime/testing/vopr-clock.zig").SimClock;
pub const SimRandom = @import("runtime/testing/vopr-random.zig").SimRandom;
pub const SimAtomic = @import("runtime/vopr-atomic.zig").SimAtomic;
pub const SimRing = @import("runtime/vopr-ring.zig").SimRing;

const dsv = @import("runtime/data-structures-vopr.zig");
const gate = @import("runtime/vopr-gate.zig");

const Test = struct {
    name: []const u8,
    func: *const fn () anyerror!void,
};

const tests = [_]Test{
    .{ .name = "GAP-B gate: SimClock + SimRandom active under this executable",         .func = &gate.assertGapBActive },
    .{ .name = "data-structures-vopr: Stream(i64) file-load + setError smoke",                .func = &dsv.testStreamFileLoad },
    .{ .name = "data-structures-vopr: InfStream(i64) push + close smoke",                     .func = &dsv.testInfStreamPushCloseFileLoad },
    .{ .name = "data-structures-vopr: partitioned map ownership local ops",                    .func = &dsv.testPartitionedMapOwnershipLocalOps },
    .{ .name = "data-structures-vopr: partitioned map ownership waiters",                      .func = &dsv.testPartitionedMapOwnershipWaiters },
    .{ .name = "data-structures-vopr: partitioned map remote ops",                             .func = &dsv.testPartitionedMapRemoteOps },
    // Stream + InfStream spinlock fault-injection scenarios removed:
    // routing Stream.Inner head/tail/lock through the comptime Atomic
    // alias (so SimAtomic could fault-inject the swap-spinlocks)
    // amplified TSan flake on stream-test SplitStream pubsub hammer
    // (V31). The migration is semantically a no-op under TSan but
    // timing-perturbing enough to amplify a pre-existing race.
};

pub fn main() !void {
    var passed: u64 = 0;
    var failed: u64 = 0;
    for (tests) |t| {
        std.debug.print("{s} ... ", .{t.name});
        if (t.func()) |_| {
            if (dsv.checkLeaksAndReset()) |_| {
                std.debug.print("OK\n", .{});
                passed += 1;
            } else |err| {
                std.debug.print("FAIL (post-test leak check): {}\n", .{err});
                failed += 1;
            }
        } else |err| {
            std.debug.print("FAIL: {}\n", .{err});
            failed += 1;
        }
    }
    std.debug.print("\n{d} passed, {d} failed\n", .{ passed, failed });
    if (failed != 0) std.process.exit(1);
}
