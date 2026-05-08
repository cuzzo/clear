const std = @import("std");

pub const CLEAR_FRAME_DEBUG = false;
pub const SimClock = @import("runtime/vopr-clock.zig").SimClock;
pub const SimRandom = @import("runtime/vopr-random.zig").SimRandom;

const flv = @import("runtime/fsm-lock-vopr.zig");
const gate = @import("runtime/vopr-gate.zig");

const Test = struct {
    name: []const u8,
    func: *const fn () anyerror!void,
};

const tests = [_]Test{
    .{ .name = "GAP-B gate: SimClock + SimRandom active under this executable",   .func = &gate.assertGapBActive },
    .{ .name = "FSM lock VOPR: 32 seeds of randomized FSM+stackful contention", .func = &flv.testManySeeds },
    .{ .name = "FSM lock VOPR: reproduce targeted seed 42",                     .func = &flv.testTargetedSeed42 },
};

pub fn main() !void {
    var passed: u64 = 0;
    var failed: u64 = 0;
    for (tests) |t| {
        std.debug.print("{s} ... ", .{t.name});
        if (t.func()) |_| {
            if (flv.checkLeaksAndReset()) |_| {
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
