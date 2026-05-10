const std = @import("std");

pub const CLEAR_FRAME_DEBUG = false;
pub const SimClock = @import("runtime/testing/vopr-clock.zig").SimClock;
pub const SimRandom = @import("runtime/testing/vopr-random.zig").SimRandom;
pub const SimAtomic = @import("runtime/vopr-atomic.zig").SimAtomic;
pub const SimRing = @import("runtime/vopr-ring.zig").SimRing;
pub const CLEAR_MVCC_MAX_INNER_RETRIES_MULTI: usize = 2;

const vv = @import("runtime/versioned-vopr.zig");
const gate = @import("runtime/vopr-gate.zig");

const Test = struct {
    name: []const u8,
    func: *const fn () anyerror!void,
};

const tests = [_]Test{
    .{ .name = "GAP-B gate: SimClock + SimRandom active under this executable",         .func = &gate.assertGapBActive },
    .{ .name = "mvcc-vopr: update retry-body fires under SimAtomic fault injection",   .func = &vv.testMvccRetryBodyUnderFault },
    .{ .name = "mvcc-vopr: updateFlow retry-body fires under SimAtomic fault injection", .func = &vv.testMvccUpdateFlowRetryBodyUnderFault },
    .{ .name = "mvcc-vopr: update tag-spin retry body fires under load-tag injection", .func = &vv.testMvccTagSpinRetryBody },
    .{ .name = "mvcc-vopr: update bounded-retry exhaustion at 100% fault",              .func = &vv.testMvccRetryExhaustionUnderFault },
    .{ .name = "mvcc-vopr: updateMulti tagged contention rolls back and retries",       .func = &vv.testMvccUpdateMultiTaggedContentionRetry },
    .{ .name = "mvcc-vopr: 200 seeds x 200 steps each, no UAF, no leak, no torn read", .func = &vv.testManySeedsShortSteps },
    .{ .name = "mvcc-vopr: 50 seeds x 1000 steps each (longer sequences)",             .func = &vv.testFewSeedsLongSteps },
    .{ .name = "mvcc-vopr: reproducibility -- seed 42 produces identical state",       .func = &vv.testReproducibility },
    .{ .name = "mvcc-vopr: 50 held guards across 100 updates, all release cleanly",    .func = &vv.testFiftyHeldGuards },
};

pub fn main() !void {
    var passed: u64 = 0;
    var failed: u64 = 0;
    for (tests) |t| {
        std.debug.print("{s} ... ", .{t.name});
        if (t.func()) |_| {
            if (vv.checkLeaksAndReset()) |_| {
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
