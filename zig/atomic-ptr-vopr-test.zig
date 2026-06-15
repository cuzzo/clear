//! Top-level executable wrapper for runtime/atomic-ptr-vopr.zig.
//!
//! Built as `atomic-ptr-vopr` executable so SimClock + SimRandom seams
//! in lib/compat.zig activate (see GAP-B comment in
//! scheduler-timeout-vopr-test.zig).

const std = @import("std");

pub const CLEAR_FRAME_DEBUG = false;
pub const SimClock = @import("runtime/testing/vopr-clock.zig").SimClock;
pub const SimRandom = @import("runtime/testing/vopr-random.zig").SimRandom;
// SimAtomic activates atomic-side fault injection for VOPR retry-body
// coverage. The comptime `Atomic` alias in lib/atomic_ptr.zig (and any
// other file using the `if (@hasDecl(root, "SimAtomic"))` seam) picks
// up SimAtomic instead of std.atomic.Value, so cmpxchg ops can be
// synthetically failed under sim_atomic.inject_cas_fault.
pub const SimAtomic = @import("runtime/vopr-atomic.zig").SimAtomic;
pub const SimRing = @import("runtime/vopr-ring.zig").SimRing;

const apv = @import("runtime/atomic-ptr-vopr.zig");
const gate = @import("runtime/vopr-gate.zig");

const Test = struct {
    name: []const u8,
    func: *const fn () anyerror!void,
};

const tests = [_]Test{
    .{ .name = "GAP-B gate: SimClock + SimRandom active under this executable", .func = &gate.assertGapBActive },
    .{ .name = "atomic-ptr-vopr: update retry-body fires under SimAtomic fault injection (50% rate)", .func = &apv.testUpdateRetryBodyUnderFault },
    .{ .name = "atomic-ptr-vopr: updateFlow retry-body fires under SimAtomic fault injection (50% rate)", .func = &apv.testUpdateFlowRetryBodyUnderFault },
    .{ .name = "atomic-ptr-vopr: updateFlow no-commit branches clean candidates", .func = &apv.testUpdateFlowNoCommitBranches },
    .{ .name = "atomic-ptr-vopr: update bounded-retry exhaustion at 100% fault -> AtomicConflict", .func = &apv.testUpdateRetryExhaustionUnderFault },
    .{ .name = "atomic-ptr-vopr: 100 seeds x 200 steps, no UAF, no leak", .func = &apv.testManySeedsShortSteps },
    .{ .name = "atomic-ptr-vopr: 30 seeds x 1000 steps (longer sequences)", .func = &apv.testFewSeedsLongSteps },
    .{ .name = "atomic-ptr-vopr: reproducibility -- seed 42 stable across runs", .func = &apv.testReproducibility },
};

pub fn main() !void {
    var passed: u64 = 0;
    var failed: u64 = 0;
    for (tests) |t| {
        std.debug.print("{s} ... ", .{t.name});
        if (t.func()) |_| {
            // Test fn returned; its defers have fired. Now safe to
            // gpa.deinit() and check for leaks across runs.
            if (apv.checkLeaksAndReset()) |_| {
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
