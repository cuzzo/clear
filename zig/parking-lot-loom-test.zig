// parking-lot-loom-test — top-level executable that drives the Loom
// deterministic-interleaving suite for ParkingMutex / ParkingRwLock.
//
// Built as an executable (NOT a `b.addTest`) so `@import("root")` from
// inside lib/parking-lot.zig and runtime/queues.zig resolves to *this*
// file. The comptime alias
//   `if (@hasDecl(root, "SimAtomic")) root.SimAtomic else std.atomic.Value`
// then picks SimAtomic, and every atomic op in the lock implementations
// becomes a yield point under the Loom harness.
//
// History: prior to 2026-05, this file was a `b.addTest` wrapper. Under
// the test runner, `@import("root")` resolves to Zig's auto-generated
// test_runner module, so `@hasDecl(root, "SimAtomic")` was false and the
// alias silently fell through to `std.atomic.Value` — meaning the entire
// loom suite ran on real atomics with zero interleaving simulation.
// See GAP-B in docs/agents/parking-lot-loom-coverage.md.

pub const SimAtomic = @import("runtime/vopr-atomic.zig").SimAtomic;
pub const SimRing = @import("runtime/vopr-ring.zig").SimRing;
pub const CLEAR_FRAME_DEBUG = false;

const std = @import("std");
const ploom = @import("runtime/parking-lot-loom.zig");
const va = @import("runtime/vopr-atomic.zig");

const Test = struct {
    name: []const u8,
    func: *const fn () anyerror!void,
};

const tests = [_]Test{
    .{ .name = "parking mutex loom: acquireVsRelease exhaustive 256 schedules",            .func = &ploom.testMutexAcquireExhaustive },
    .{ .name = "parking mutex loom: acquireVsRelease prng seeds",                          .func = &ploom.testMutexAcquirePrng },
    .{ .name = "parking mutex loom: 3-fiber race coverage 3^10 base-3 exhaustive (M4)",    .func = &ploom.testMutexThreeFiberRaces },
    .{ .name = "parking mutex loom: lost-wake regression 3x3 base-3 exhaustive",           .func = &ploom.testMutexLostWake },
    .{ .name = "parking rwlock loom: two writers exhaustive 256 schedules",                .func = &ploom.testRwlockTwoWriters },
    .{ .name = "parking rwlock loom: writer vs reader exhaustive 256 schedules",           .func = &ploom.testRwlockWriterReader },
    .{ .name = "parking rwlock loom: two readers + one writer prng seeds",                 .func = &ploom.testRwlockTwoReadersWriter },
    .{ .name = "parking rwlock loom: 1W+2R exhaustive 3^10 base-3 (M5 reader-drain)",      .func = &ploom.testRwlockOneWriterTwoReaders },
    .{ .name = "parking rwlock loom: 2W+1R exhaustive 3^10 base-3 (M5 FIFO/writer-pref)",  .func = &ploom.testRwlockTwoWritersOneReader },
    .{ .name = "parking cycle loom: self-cycle returns Deadlock (M6)",                     .func = &ploom.testCycleSelf },
    .{ .name = "parking cycle loom: 2-hop AB/BA returns LockCycle (M6, 4096 schedules)",   .func = &ploom.testCycle2Hop },
    .{ .name = "parking cycle loom: 3-hop ABC/BCA returns LockCycle (M6, 6561 schedules)", .func = &ploom.testCycle3Hop },
    .{ .name = "parking cycle loom: read-lock terminator (M6, 256 schedules)",             .func = &ploom.testCycleReadTerminator },
    .{ .name = "parking VOPR: address-ordered nested mutex, no false positive (2000 seeds)", .func = &ploom.testVoprAddressOrderedNoFalsePositive },
};

pub fn main() !void {
    var passed: u64 = 0;
    var failed: u64 = 0;
    const ops_at_start = va.sim_atomic_op_count;

    for (tests) |t| {
        const before = va.sim_atomic_op_count;
        std.debug.print("{s} ... ", .{t.name});
        if (t.func()) |_| {
            const delta = va.sim_atomic_op_count - before;
            std.debug.print("OK ({d} sim ops)\n", .{delta});
            passed += 1;
            // Loom invariant (M2): every loom test must drive >0 SimAtomic
            // ops. Zero means the comptime Atomic alias resolved to
            // std.atomic.Value and the test ran on real atomics — see
            // GAP-B. Fail loudly so we never regress to a theatrical suite.
            if (delta == 0) {
                std.debug.print(
                    "FATAL: '{s}' ran zero SimAtomic ops — loom is not active\n",
                    .{t.name},
                );
                std.process.exit(2);
            }
        } else |err| {
            std.debug.print("FAIL: {}\n", .{err});
            failed += 1;
        }
    }

    const ops_total = va.sim_atomic_op_count - ops_at_start;
    std.debug.print(
        "\n{d} passed, {d} failed ({d} total sim atomic ops)\n",
        .{ passed, failed, ops_total },
    );

    // M8 coverage gate. Each SimAtomic method records its caller's
    // return address (one unique IP per source line that issues an
    // atomic op). The audit doc enumerates ~53 loom-eligible parking-
    // lot sites + ~40 task-field site classes; the suite must hit a
    // healthy fraction or coverage has silently regressed.
    //
    // The threshold is set deliberately on the conservative side. It
    // is a structural backstop: if M3-M6 tests pass but the unique-IP
    // count drops, some test stopped exercising a code path. Update
    // the threshold upward when adding tests that intentionally extend
    // coverage; never downward without surfacing what was lost.
    // Tuned at 110 so it is a meaningful regression gate without being
    // brittle to harmless test reorganization. Current hit count: ~129
    // (parking-lot.zig sites + queues.zig RunQueue/Task-field sites
    // reached transitively through the loom suite).
    const M8_COVERAGE_MIN: usize = 110;
    std.debug.print(
        "\n[M8 coverage] {d} unique SimAtomic call sites hit (threshold: {d})\n",
        .{ va.sim_unique_site_count, M8_COVERAGE_MIN },
    );
    if (va.sim_unique_site_count < M8_COVERAGE_MIN) {
        std.debug.print(
            "FATAL: coverage below threshold — at least {d} sites are unhit. " ++
            "See docs/agents/parking-lot-loom-coverage.md for the per-site audit.\n",
            .{M8_COVERAGE_MIN - va.sim_unique_site_count},
        );
        std.process.exit(3);
    }

    if (failed != 0) std.process.exit(1);
}
