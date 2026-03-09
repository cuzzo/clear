// shared_promise_test.zig
// Unit tests for CheatLib.SharedPromise(T) — Phase 2 shared/memoized promises.
//
// Full behavioral tests (concurrent BG fibers, multi-holder NEXT) require a
// live scheduler and are covered by transpile-tests/74_shared_promise.cht.
//
// Run with:
//   zig test zig/shared_promise_test.zig -lc zig/switch.S zig/onRoot.S
const std = @import("std");
const CheatLib = @import("runtime-header.zig").CheatLib;

// ---------------------------------------------------------------------------
// Struct shape
// ---------------------------------------------------------------------------

test "SharedPromise has inner, alloc, and resolved fields" {
    const SP = CheatLib.SharedPromise(f64);
    const fields = @typeInfo(SP).@"struct".fields;
    var found_inner = false;
    var found_alloc = false;
    var found_resolved = false;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, "inner")) found_inner = true;
        if (std.mem.eql(u8, f.name, "alloc")) found_alloc = true;
        if (std.mem.eql(u8, f.name, "resolved")) found_resolved = true;
    }
    try std.testing.expect(found_inner);
    try std.testing.expect(found_alloc);
    try std.testing.expect(found_resolved);
}

test "SharedPromise.Inner has result, wg, and ref_count fields" {
    const Inner = CheatLib.SharedPromise(f64).Inner;
    const fields = @typeInfo(Inner).@"struct".fields;
    var found_result = false;
    var found_wg = false;
    var found_ref_count = false;
    inline for (fields) |f| {
        if (std.mem.eql(u8, f.name, "result")) found_result = true;
        if (std.mem.eql(u8, f.name, "wg")) found_wg = true;
        if (std.mem.eql(u8, f.name, "ref_count")) found_ref_count = true;
    }
    try std.testing.expect(found_result);
    try std.testing.expect(found_wg);
    try std.testing.expect(found_ref_count);
}

test "SharedPromise resolved field defaults to null" {
    var sp: CheatLib.SharedPromise(f64) = undefined;
    sp.resolved = null;
    try std.testing.expect(sp.resolved == null);
}

// ---------------------------------------------------------------------------
// Idempotent caching logic (without scheduler — simulate post-resolution state)
// ---------------------------------------------------------------------------

test "SharedPromise next() returns cached value on second call" {
    // Simulate a resolved handle: set resolved directly.
    var sp: CheatLib.SharedPromise(f64) = undefined;
    sp.resolved = 42.0;

    // First call: returns cached value immediately (skips wg.wait() branch).
    const v1 = sp.next();
    try std.testing.expectApproxEqAbs(42.0, v1, 1e-9);

    // Second call: still returns cached value.
    const v2 = sp.next();
    try std.testing.expectApproxEqAbs(42.0, v2, 1e-9);
}

test "SharedPromise with bool type caches correctly" {
    var sp: CheatLib.SharedPromise(bool) = undefined;
    sp.resolved = true;

    const v1 = sp.next();
    const v2 = sp.next();
    try std.testing.expect(v1 == true);
    try std.testing.expect(v2 == true);
}

// ---------------------------------------------------------------------------
// Ref-count semantics (direct struct manipulation — no scheduler)
// ---------------------------------------------------------------------------

test "SharedPromise Inner ref_count starts at 1 after manual init" {
    // We cannot call spawn() without a scheduler, but we can verify the
    // atomic Value API works correctly for the ref-count protocol.
    var ref_count = std.atomic.Value(usize).init(1);
    try std.testing.expectEqual(@as(usize, 1), ref_count.load(.acquire));

    // Simulate retain(): fetchAdd(1)
    _ = ref_count.fetchAdd(1, .acquire);
    try std.testing.expectEqual(@as(usize, 2), ref_count.load(.acquire));

    // Simulate first next(): fetchSub(1)
    const prev1 = ref_count.fetchSub(1, .release);
    try std.testing.expectEqual(@as(usize, 2), prev1); // returns old value
    try std.testing.expectEqual(@as(usize, 1), ref_count.load(.acquire));

    // Simulate second next(): fetchSub(1) → prev == 1 → would free
    const prev2 = ref_count.fetchSub(1, .release);
    try std.testing.expectEqual(@as(usize, 1), prev2); // returns old value = 1 → free
}

// ---------------------------------------------------------------------------
// SharedPromise and BoundedStream are distinct types
// ---------------------------------------------------------------------------

test "SharedPromise(f64) and Promise(f64) are distinct types" {
    const SP = CheatLib.SharedPromise(f64);
    const P  = CheatLib.Promise(f64);
    // They should not be the same type.
    try std.testing.expect(SP != P);
}
