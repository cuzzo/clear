//! GAP-B regression gate for VOPR executables.
//!
//! Verifies that the comptime SimClock + SimRandom seams in
//! lib/compat.zig are activated by the calling executable. If `root`
//! resolves to Zig's auto-generated test_runner module (the b.addTest
//! shape), the seams silently fall through to OS clock_gettime /
//! getrandom and "VOPR-deterministic" tests are actually
//! real-time-dependent + entropy-dependent.
//!
//! Every VOPR executable's wrapper main() should run these as the
//! first scenarios. If they fail, the rest of the VOPR suite is
//! running on real-clock / real-entropy and any "passes" are theatre.

const std = @import("std");
const compat = @import("../lib/compat.zig");
const SimClock = @import("testing/vopr-clock.zig").SimClock;
const SimRandom = @import("testing/vopr-random.zig").SimRandom;

/// `compat.milliTimestamp()` MUST track `SimClock.advanceMs()` exactly.
/// If it doesn't, the SimClock seam is silently disabled.
pub fn assertSimClockActive() !void {
    SimClock.reset();
    const t0 = compat.milliTimestamp();
    SimClock.advanceMs(1234);
    const t1 = compat.milliTimestamp();
    if (t1 - t0 != 1234) return error.SimClockNotActive;
    SimClock.reset();
}

/// `compat.randomBytes()` MUST be reproducible by SimRandom seed.
/// Two fills with the same seed produce identical bytes; fills with
/// different seeds diverge. If the seam is disabled, randomBytes
/// goes to OS getrandom and the seeded paths produce different bytes
/// across runs (the second fill diverges from the first because the
/// seed state isn't actually used).
pub fn assertSimRandomActive() !void {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;

    SimRandom.seed(42);
    try compat.randomBytes(&a);
    SimRandom.seed(42);
    try compat.randomBytes(&b);
    if (!std.mem.eql(u8, &a, &b)) return error.SimRandomNotActive_SameSeedDiverged;

    SimRandom.seed(99);
    try compat.randomBytes(&b);
    if (std.mem.eql(u8, &a, &b)) return error.SimRandomNotActive_DifferentSeedsCollided;
}

/// Combined gate -- run both as a single scenario.
pub fn assertGapBActive() !void {
    try assertSimClockActive();
    try assertSimRandomActive();
}
