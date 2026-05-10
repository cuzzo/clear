//! Top-level executable wrapper for runtime/scheduler-timeout-vopr.zig.
//!
//! Built as the `scheduler-timeout-vopr` executable (NOT a `b.addTest`).
//! Module root must sit at `zig/` because runtime/foo.zig files do
//! `@import("../lib/bar.zig")` and Zig 0.16 forbids walking outside
//! the module root. Mirrors parking-lot-loom-test.zig.
//!
//! The `pub const SimClock` decl at this file's root is what makes the
//! `@hasDecl(@import("root"), "SimClock")` seam in lib/compat.zig pick
//! up SimClock under VOPR. Under `b.addTest`, root resolves to Zig's
//! auto-generated test_runner module instead -- the SimClock decl is
//! invisible from there, the seam falls through to OS clock_gettime,
//! and the timeout assertions become real-time-dependent.
//!
//! The first scenario (testSimClockActive) is the GAP-B regression
//! gate: if the SimClock seam is silently disabled, that scenario
//! fails immediately, so we never re-run the suite against real time.

const std = @import("std");

pub const CLEAR_FRAME_DEBUG = false;
pub const SimClock = @import("runtime/testing/vopr-clock.zig").SimClock;
pub const SimRandom = @import("runtime/testing/vopr-random.zig").SimRandom;
// SimAtomic activates atomic fault injection for spin-retry coverage.
// scheduler.zig's WaitGroup / Semaphore primitives use swap-based
// spinlocks; the swap-fault knob (inject_swap_busy_fault) in
// runtime/vopr-atomic.zig drives those retry bodies single-threaded.
pub const SimAtomic = @import("runtime/vopr-atomic.zig").SimAtomic;
pub const SimRing = @import("runtime/vopr-ring.zig").SimRing;

const stv = @import("runtime/scheduler-timeout-vopr.zig");
const gate = @import("runtime/vopr-gate.zig");

const Test = struct {
    name: []const u8,
    func: *const fn () anyerror!void,
};

const tests = [_]Test{
    .{ .name = "GAP-B gate: SimClock + SimRandom active under this executable",                      .func = &gate.assertGapBActive },
    .{ .name = "compat.nanoTimestamp + Timer track SimClock virtual time",                           .func = &stv.testCompatTimerSimClock },
    .{ .name = "Runtime.checkpoint deadline fires under SimClock advance",                           .func = &stv.testRuntimeCheckpointTimeout },
    .{ .name = "WaitGroup/Semaphore scheduler primitives: register, wait, acquire, release",         .func = &stv.testWaitGroupSemaphoreSchedulerPrimitives },
    .{ .name = "WaitGroup/Semaphore fiber park/resume paths",                                        .func = &stv.testWaitGroupSemaphoreFiberParkResume },
    // WaitGroup / Semaphore swap-spinlock fault scenarios dropped:
    // routing WaitGroup/Semaphore counter+lock through the comptime
    // Atomic alias destabilized stream-test's TSan SplitStream
    // pubsub hammer (3% master flake -> 17% with the migration).
    // The migration is semantically a no-op under TSan but timing-
    // sensitive enough to amplify a pre-existing race. Reverted to
    // keep TSan stable. See V29 commit + audit doc.
    .{ .name = "WaiterList.spinAcquire CAS retry-body fires under SimAtomic CAS fault",             .func = &stv.testWaiterListSpinlockUnderFault },
    // observable.SpinLock + profile-lock SpinLock fault scenarios were
    // removed: routing those production types through the comptime
    // Atomic alias (so SimAtomic could fault-inject) amplified TSan
    // flake rate on stream-test SplitStream pubsub hammer + parking-
    // rwlock-fiber-hammer (V31). See V31 commit + audit doc.
    .{ .name = "SmartEventFd.consume drains via posix.read",                                        .func = &stv.testSmartEventFdConsume },
    .{ .name = "Scheduler io_uring submit fns (read/write/accept/connect/recv/send) via SimRing",   .func = &stv.testIoSubmitFns },
    .{ .name = "Profile files load + nanoTimestamp tracks SimClock (fiber-profile, lock-profile)",  .func = &stv.testProfileFilesLoad },
    .{ .name = "wakeExpiredFsmSleepers (FSM sleep wake)",                                           .func = &stv.testWakeExpiredFsmSleepers },
    .{ .name = "earliestLockWaiterDeadlineMsUntil (run-loop idle-arming math)",                     .func = &stv.testEarliestLockWaiterDeadline },
    .{ .name = "registerLockWaiter stamps wait_start_ms and appends to lock_waiters",               .func = &stv.testRegisterLockWaiter },
    .{ .name = "fiber harness minimal: switchTo -> yield -> switchTo -> yield",       .func = &stv.testFiberHarnessMinimal },
    .{ .name = "Runtime.sleep end-to-end (real fiber, sleep -> wake -> resume)",      .func = &stv.testRuntimeSleepEndToEnd },
    .{ .name = "scanLockWaiters timeout-fire under SimClock advance",                                .func = &stv.testScanLockWaitersTimeoutFire },
    .{ .name = "wakeExpiredSleepers under SimClock advance",                                         .func = &stv.testWakeExpiredSleepers },
    .{ .name = "scanFsmLockWaiters timeout-fire under SimClock advance",                             .func = &stv.testScanFsmLockWaitersTimeoutFire },
};

pub fn main() !void {
    var passed: u64 = 0;
    var failed: u64 = 0;

    for (tests) |t| {
        std.debug.print("{s} ... ", .{t.name});
        if (t.func()) |_| {
            std.debug.print("OK\n", .{});
            passed += 1;
        } else |err| {
            std.debug.print("FAIL: {}\n", .{err});
            failed += 1;
        }
    }

    std.debug.print("\n{d} passed, {d} failed\n", .{ passed, failed });
    if (failed != 0) std.process.exit(1);
}
