const std = @import("std");

pub const CLEAR_FRAME_DEBUG = false;
pub const SimClock = @import("runtime/testing/vopr-clock.zig").SimClock;
pub const SimRandom = @import("runtime/testing/vopr-random.zig").SimRandom;

const fv = @import("runtime/fsm-vopr.zig");
const gate = @import("runtime/vopr-gate.zig");

const Test = struct {
    name: []const u8,
    func: *const fn () anyerror!void,
};

const tests = [_]Test{
    .{ .name = "GAP-B gate: SimClock + SimRandom active under this executable",        .func = &gate.assertGapBActive },
    .{ .name = "FSM VOPR: 128 seeds of PRNG-driven fuzzing",                          .func = &fv.testManySeeds },
    .{ .name = "FSM VOPR: single targeted seed with final state checks",              .func = &fv.testTargetedSeed },
    .{ .name = "FSM VOPR: enqueue -> drain round-trip preserves active_tasks",        .func = &fv.testEnqueueDrainRoundTrip },
    .{ .name = "FSM VOPR: remote ctx slab frees drain through owner scheduler",       .func = &fv.testRemoteCtxSlabFrees },
};

pub fn main() !void {
    var passed: u64 = 0;
    var failed: u64 = 0;
    for (tests) |t| {
        std.debug.print("{s} ... ", .{t.name});
        if (t.func()) |_| {
            if (fv.checkLeaksAndReset()) |_| {
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
