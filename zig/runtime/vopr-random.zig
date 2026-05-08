//! SimRandom: deterministic PRNG for VOPR tests.
//!
//! Pattern parallel to SimClock: when a VOPR test's root module
//! re-exports `pub const SimRandom = vopr_random.SimRandom`, every
//! `compat.randomBytes(buf)` call fills `buf` from a deterministic
//! seeded PRNG instead of the OS getrandom syscall. Production
//! builds keep the direct getrandom path with zero overhead.
//!
//! Contract: `pub fn fill(buf: []u8) void`. The shim is single-
//! threaded by design (matches the runtime's VOPR tests). Tests
//! seed via `SimRandom.seed(N)` before each scenario for
//! reproducibility.
//!
//! Usage:
//!
//!     pub const SimRandom = @import("runtime/vopr-random.zig").SimRandom;
//!
//!     test "VOPR scenario seed=N" {
//!         SimRandom.seed(42);
//!         // ... compat.randomBytes(...) returns deterministic bytes ...
//!     }

const std = @import("std");

pub const SimRandom = struct {
    var prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0);

    pub fn seed(s: u64) void {
        prng = std.Random.DefaultPrng.init(s);
    }

    pub fn fill(buf: []u8) void {
        prng.random().bytes(buf);
    }
};

test "SimRandom: same seed -> same bytes" {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    SimRandom.seed(42);
    SimRandom.fill(&a);
    SimRandom.seed(42);
    SimRandom.fill(&b);
    try std.testing.expectEqualSlices(u8, &a, &b);
}

test "SimRandom: different seeds -> different bytes" {
    var a: [32]u8 = undefined;
    var b: [32]u8 = undefined;
    SimRandom.seed(1);
    SimRandom.fill(&a);
    SimRandom.seed(2);
    SimRandom.fill(&b);
    // Cosmically improbable to collide on 256 bits with two seeds.
    try std.testing.expect(!std.mem.eql(u8, &a, &b));
}
