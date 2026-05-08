//! SimClock: deterministic virtual clock for VOPR tests.
//!
//! Pattern parallel to SimAtomic / SimRing: when a VOPR test's root
//! module re-exports `pub const SimClock = vopr_clock.SimClock`,
//! every `compat.milliTimestamp()` / `compat.nanoTimestamp()` call
//! returns the simulator's virtual clock instead of the OS monotonic
//! clock. Production builds (no SimClock decl on root) inline to
//! direct clock_gettime -- zero runtime overhead.
//!
//! Usage in a VOPR test:
//!
//!     pub const SimClock = @import("runtime/vopr-clock.zig").SimClock;
//!
//!     test "VOPR scenario" {
//!         SimClock.reset();
//!         // ... run scenario ...
//!         SimClock.advanceMs(100);
//!         // ... time-dependent code observes the advance ...
//!     }
//!
//! Single-threaded by design. The runtime's VOPR tests are all
//! single-threaded; cross-thread clock semantics under VOPR would
//! require a different shim. The clock state is package-global so
//! the comptime seam in compat.zig can read it without threading
//! a context pointer through every milliTimestamp call site.

const std = @import("std");

pub const SimClock = struct {
    /// Virtual time in nanoseconds. Starts at 0; tests advance it
    /// explicitly. Single-thread, no atomics needed.
    var virtual_ns: i128 = 0;

    pub fn reset() void {
        virtual_ns = 0;
    }

    /// Advance the virtual clock by `ms` milliseconds.
    pub fn advanceMs(ms: i64) void {
        virtual_ns += @as(i128, ms) * 1_000_000;
    }

    /// Advance the virtual clock by `ns` nanoseconds.
    pub fn advanceNs(ns: i128) void {
        virtual_ns += ns;
    }

    /// Mirrors `compat.milliTimestamp` signature.
    pub fn milliTimestamp() i64 {
        return @intCast(@divFloor(virtual_ns, 1_000_000));
    }

    /// Mirrors `compat.nanoTimestamp` signature (u64).
    pub fn nanoTimestamp() u64 {
        return @intCast(virtual_ns);
    }
};

test "SimClock: advance / read symmetry" {
    SimClock.reset();
    try std.testing.expectEqual(@as(i64, 0), SimClock.milliTimestamp());
    SimClock.advanceMs(1500);
    try std.testing.expectEqual(@as(i64, 1500), SimClock.milliTimestamp());
    try std.testing.expectEqual(@as(u64, 1_500_000_000), SimClock.nanoTimestamp());
    SimClock.advanceNs(250);
    try std.testing.expectEqual(@as(u64, 1_500_000_250), SimClock.nanoTimestamp());
    // ms only sees floor(ns/1e6), so the +250ns doesn't bump the ms read.
    try std.testing.expectEqual(@as(i64, 1500), SimClock.milliTimestamp());
}
