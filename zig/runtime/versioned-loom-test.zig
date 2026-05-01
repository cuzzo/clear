//! Loom-shim sanity test for the MVCC primitives.
//!
//! This file exercises the SimAtomic comptime shim in versioned.zig
//! and ebr.zig.  When the root module exports `SimAtomic`, every
//! atomic load/store/cmpxchg in `Versioned(T)` and `EbrContext` /
//! `ThreadLocalEbr` becomes a deterministic yield point.  Without
//! `SimAtomic` in root, the shim resolves to `std.atomic.Value` and
//! these tests just exercise the same single-threaded path as T1.
//!
//! Why this file exists in addition to T1's `shared-memory-test.zig`:
//!   - T1 uses std.atomic.Value directly (compiles under either alias).
//!   - This file has the test infrastructure ready for a future
//!     full-fiber Loom harness like `parking-lot-loom.zig` (~600 LOC),
//!     where:
//!       1. The wrapper file (e.g. `shared-memory-loom-driver.zig`)
//!          re-exports SimAtomic at root.
//!       2. A LoomHarness fires N virtual fibers running mvcc ops.
//!       3. Each SimAtomic op yields via fiber.yield(), letting the
//!          coordinator pick which fiber runs next.
//!       4. PRNG / exhaustive enumeration drives interleaving coverage.
//!
//! The shim is the foundation step; the harness is the next investment.
//! T3's std.Thread stress tests are sufficient for catching the
//! common race classes today; Loom adds value for the rare
//! interleavings the OS scheduler doesn't naturally hit (e.g. EBR's
//! `enter()` 2-step active+local race window).

const std = @import("std");
const testing = std.testing;

const ebr_mod = @import("../lib/ebr.zig");
const versioned = @import("versioned.zig");
const Runtime = @import("runtime.zig").Runtime;

const EbrContext = ebr_mod.EbrContext;
const ThreadLocalEbr = ebr_mod.ThreadLocalEbr;

test "Loom-shim sanity: shared-memory.Atomic resolves to std.atomic.Value when SimAtomic absent" {
    // No `pub const SimAtomic = ...` at root, so the comptime
    // resolution should land on std.atomic.Value(*T).  Verify by
    // checking the underlying type's API surface (load/store/cmpxchg).
    const PtrT = versioned.Atomic(*u64);
    var v: u64 = 0;
    var a = PtrT.init(&v);
    _ = a.load(.acquire);
    a.store(&v, .release);
    _ = a.cmpxchgWeak(&v, &v, .release, .monotonic);
    // If we got here, the shim type provided the std.atomic.Value
    // API. (Pin against accidental shim-type narrowing.)
}

test "Loom-shim sanity: ebr.Atomic resolves to std.atomic.Value when SimAtomic absent" {
    const U32A = ebr_mod.Atomic(u32);
    var x = U32A.init(0);
    _ = x.load(.acquire);
    x.store(7, .release);
    _ = x.cmpxchgWeak(@as(u32, 7), @as(u32, 8), .release, .monotonic);
}

// Smoke test: full Versioned(T) + EBR lifecycle with the shim in place.
// Same test as in T1 but routed through the shim — proves the shim
// doesn't break the protocol under the default (real-atomic) build.
test "Loom-shim sanity: full Versioned(T) lifecycle through the shim" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var frame: [1024]u8 = undefined;
    var rt = try Runtime.initFromSlice(&frame, &ctx, testing.allocator, 0);
    defer rt.deinit();

    var s = try versioned.Versioned(i64).init(testing.allocator, 100);
    defer s.deinit(&rt, testing.allocator) catch unreachable;

    const observed = s.withRead(&rt, struct {
        fn call(p: *i64) i64 { return p.*; }
    }.call, .{});
    try testing.expectEqual(@as(i64, 100), observed);

    try s.update(&rt, testing.allocator, struct {
        fn call(p: *i64, v: i64) void { p.* = v; }
    }.call, .{@as(i64, 200)});

    const after = s.withRead(&rt, struct {
        fn call(p: *i64) i64 { return p.*; }
    }.call, .{});
    try testing.expectEqual(@as(i64, 200), after);
}

// Gap 5: pin-survives-retire ordering validation through the SimAtomic shim.
//
// The C2 contract test in versioned-stress-test.zig validates that a held
// Guard's pointer keeps dereferencing across concurrent retire+reclaim
// cycles. That's a real-thread test; under the OS scheduler, the producer
// fiber drives writer iterations the natural way (mostly forward).
//
// This deterministic version sequences pin / update / reclaim cycles
// tightly through the same SimAtomic-instrumented path. It catches a
// different class of regression: an ordering bug in the EBR contract
// itself (e.g. retire stamping the wrong epoch, reclaimLocal sweeping
// items still inside a held thread's grace window) that only surfaces
// when many short cycles run back-to-back without the OS rescheduling.
//
// Property: a Guard taken at update step `k` continues to dereference
// to value `k` even after updates k+1..k+N retire intermediate snapshots
// and reclaim cycles fire. The expectation flows from the EBR pin
// preventing reclamation past `local_epoch[k]`.
test "Versioned: pin survives N successive update+reclaim cycles (single-thread EBR contract)" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var frame: [2048]u8 = undefined;
    var rt = try Runtime.initFromSlice(&frame, &ctx, testing.allocator, 0);
    defer rt.deinit();
    try ctx.register(testing.allocator, rt.ebr);
    defer ctx.unregister(rt.ebr);

    var s = try versioned.Versioned(i64).init(testing.allocator, 0);
    defer {
        s.deinit(&rt, testing.allocator) catch unreachable;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            ctx.reclaim(testing.allocator);
            rt.ebr.reclaimLocal(testing.allocator);
        }
    }

    // Seed with a known value at "epoch 0" of the test, then pin
    // a Guard. The pin must hold this value alive across all
    // subsequent updates + reclaims.
    try s.update(&rt, testing.allocator, struct {
        fn call(p: *i64, v: i64) void { p.* = v; }
    }.call, .{@as(i64, 1000)});

    var pinned = s.read(&rt);
    defer pinned.release();
    const captured: i64 = pinned.get().*;
    try testing.expectEqual(@as(i64, 1000), captured);

    // 200 update+reclaim cycles. Each iteration:
    //   1. Update: writes a new value, retires the prior snapshot.
    //   2. ReclaimLocal: drains thread-local limbo (skips items
    //      below safe_threshold; the held Guard's epoch is the
    //      threshold, so items at/after that epoch stay alive).
    //   3. Re-check the pinned guard's value -- must still be 1000.
    //
    // If the EBR contract were broken (e.g. limbo swept past the
    // guard's epoch, or retire used the wrong epoch), `pinned.get().*`
    // would either dereference freed memory (DebugAllocator catches
    // post-test) or read whatever new value happens to live where
    // the freed node sat (caught by the inline equality check).
    var k: usize = 0;
    while (k < 200) : (k += 1) {
        const new_v: i64 = 2000 + @as(i64, @intCast(k));
        try s.update(&rt, testing.allocator, struct {
            fn call(p: *i64, v: i64) void { p.* = v; }
        }.call, .{new_v});
        rt.ebr.reclaimLocal(testing.allocator);
        // Every 16 iterations, also drive the global reclaim path so
        // both the local-limbo and orphan-list paths get exercised.
        if ((k & 0xF) == 0xF) ctx.reclaim(testing.allocator);

        // Pinned guard still observes its captured value.
        try testing.expectEqual(captured, pinned.get().*);
    }

    // A FRESH read sees the latest published value (sanity that
    // updates actually landed, not just bypassed).
    var fresh = s.read(&rt);
    defer fresh.release();
    try testing.expectEqual(@as(i64, 2000 + 199), fresh.get().*);
}
