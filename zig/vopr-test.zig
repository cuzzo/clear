const std = @import("std");

pub const CLEAR_FRAME_DEBUG = false;
pub const SimClock = @import("runtime/vopr-clock.zig").SimClock;
pub const SimRandom = @import("runtime/vopr-random.zig").SimRandom;

const vopr = @import("runtime/vopr.zig");
const gate = @import("runtime/vopr-gate.zig");

const Test = struct {
    name: []const u8,
    func: *const fn () anyerror!void,
};

const tests = [_]Test{
    .{ .name = "GAP-B gate: SimClock + SimRandom active under this executable",               .func = &gate.assertGapBActive },
    .{ .name = "vopr: task conservation and pinned affinity",                                  .func = &vopr.testTaskConservation },
    .{ .name = "vopr: ready queue starves the older of two co-located cooperative tasks",     .func = &vopr.testCooperativeFairness },
    .{ .name = "vopr: submitResume after .Finished destroy is rejected by in_inbox state",    .func = &vopr.testSubmitResumeAfterFinished },
    .{ .name = "vopr: submitResume that wins the CAS race -- destroyer skips destroy",        .func = &vopr.testSubmitResumeWinsCasRace },
    .{ .name = "vopr: stolen task with pending remote shard op triggers ShardConcurrentAccess", .func = &vopr.testStolenTaskShardConcurrentAccess },
};

pub fn main() !void {
    var passed: u64 = 0;
    var failed: u64 = 0;
    for (tests) |t| {
        std.debug.print("{s} ... ", .{t.name});
        if (t.func()) |_| {
            if (vopr.checkLeaksAndReset()) |_| {
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
