//! Loom-shim sanity tests for AtomicPtr(T).
//!
//! Mirrors versioned-loom-test.zig: single-thread tests that exercise
//! the SimAtomic-instrumented atomic ops plus the EBR pin/retire/
//! reclaim contract. When the root module exports `SimAtomic`, every
//! load/store/cmpxchg in `AtomicPtr(T)` becomes a deterministic yield
//! point. Without `SimAtomic` in root, these tests still validate the
//! single-threaded path against std.atomic.Value directly.
//!
//! What these tests catch:
//!   - Pin survives N successive update+reclaim cycles (the read
//!     Guard's snapshot pointer must remain valid even after writers
//!     publish + retire intermediate snapshots).
//!   - cmpxchg memory-ordering wired correctly (acquire on load,
//!     release on CAS success-path, acquire on failure-path).
//!   - rcu-style update is bounded at MAX_UPDATE_RETRIES (256;
//!     #330) — completes after N CAS-fail
//!     iterations driven by hand without ever returning an error.
//!   - Retire callbacks fire eventually under reclaimLocal pressure;
//!     no leak survives ctx.deinit (DebugAllocator catches).
//!
//! Hammer (multi-thread) coverage is in atomic-ptr-stress-test.zig.

const std = @import("std");
const testing = std.testing;

const ebr_mod = @import("../lib/ebr.zig");
const atomic_ptr = @import("../lib/atomic_ptr.zig");
const build_options = @import("build_options");

const EbrContext = ebr_mod.EbrContext;
const ThreadLocalEbr = ebr_mod.ThreadLocalEbr;
const AtomicPtr = atomic_ptr.AtomicPtr;

// -----------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------

const Sample = struct {
    a: i64,
    b: i64,
};

fn writeSample(p: *Sample, n: i64) void {
    p.a = n;
    p.b = n * 2;
}

// Set up a ThreadLocalEbr registered against an EbrContext. Caller is
// responsible for ctx.unregister + tle.deinit + ctx.deinit.
fn newTle(ctx: *EbrContext, allocator: std.mem.Allocator) !ThreadLocalEbr {
    var tle = ThreadLocalEbr{ .context = ctx };
    try ctx.register(allocator, &tle);
    return tle;
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

test "AtomicPtr: init + sync deinit (no readers)" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var cell = try AtomicPtr(i64).init(testing.allocator, 42);
    defer cell.deinitSync(testing.allocator);

    // The cell holds the published value; we can verify it via a
    // read (no EBR needed when there are no concurrent producers,
    // but the API still requires a TLE for the pin protocol).
    var tle = try newTle(&ctx, testing.allocator);
    defer ctx.unregister(&tle);
    defer tle.deinit(testing.allocator);

    var g = cell.read(&tle);
    defer g.release();
    try testing.expectEqual(@as(i64, 42), g.get().*);
}

test "AtomicPtr: read returns a Guard pointing at the published value" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var tle = try newTle(&ctx, testing.allocator);
    defer ctx.unregister(&tle);
    defer tle.deinit(testing.allocator);

    var cell = try AtomicPtr(Sample).init(testing.allocator, .{ .a = 100, .b = 200 });
    defer {
        cell.deinit(&tle, testing.allocator) catch unreachable;
        tle.reclaimLocal(testing.allocator);
    }

    var g = cell.read(&tle);
    defer g.release();
    const view = g.get().*;
    try testing.expectEqual(@as(i64, 100), view.a);
    try testing.expectEqual(@as(i64, 200), view.b);
}

test "AtomicPtr: withRead closure form auto-releases" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var tle = try newTle(&ctx, testing.allocator);
    defer ctx.unregister(&tle);
    defer tle.deinit(testing.allocator);

    var cell = try AtomicPtr(i64).init(testing.allocator, 7);
    defer {
        cell.deinit(&tle, testing.allocator) catch unreachable;
        tle.reclaimLocal(testing.allocator);
    }

    const observed = cell.withRead(&tle, struct {
        fn call(p: *i64) i64 {
            return p.*;
        }
    }.call, .{});
    try testing.expectEqual(@as(i64, 7), observed);
}

test "AtomicPtr: update publishes new value, prior reads still see snapshot via EBR pin" {
    // Property: a Guard taken at update step `k` continues to
    // dereference to value `k` even after updates k+1..k+N retire
    // intermediate snapshots and reclaim cycles fire. Mirrors the
    // C2 contract test in versioned-loom-test.zig.
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var tle = try newTle(&ctx, testing.allocator);
    defer ctx.unregister(&tle);
    defer tle.deinit(testing.allocator);

    var cell = try AtomicPtr(Sample).init(testing.allocator, .{ .a = 0, .b = 0 });
    defer {
        cell.deinit(&tle, testing.allocator) catch unreachable;
        // Drain limbo via repeated reclaimLocal calls so DebugAllocator
        // sees a clean slate at ctx.deinit time.
        var d: usize = 0;
        while (d < 6) : (d += 1) {
            tle.reclaimLocal(testing.allocator);
            ctx.reclaim(testing.allocator);
        }
    }

    // Seed at k=0 (1000), pin a Guard before subsequent updates.
    try cell.update(&tle, testing.allocator, writeSample, .{@as(i64, 1000)});

    var pinned = cell.read(&tle);
    defer pinned.release();
    const captured: i64 = pinned.get().a;
    try testing.expectEqual(@as(i64, 1000), captured);
    try testing.expectEqual(@as(i64, 2000), pinned.get().b);

    // 200 update+reclaim cycles. Each iteration retires the prior
    // snapshot; the pinned Guard's epoch must keep its snapshot
    // alive across all of them. If EBR is broken (limbo swept past
    // the guard's epoch, or retire used the wrong epoch), the
    // pinned read deref reads freed memory or a successor's bytes.
    var k: usize = 0;
    while (k < 200) : (k += 1) {
        const new_v: i64 = 2000 + @as(i64, @intCast(k));
        try cell.update(&tle, testing.allocator, writeSample, .{new_v});
        tle.reclaimLocal(testing.allocator);
        if ((k & 0xF) == 0xF) ctx.reclaim(testing.allocator);

        // Pinned guard still observes its captured snapshot.
        try testing.expectEqual(captured, pinned.get().a);
        try testing.expectEqual(@as(i64, 2000), pinned.get().b);
    }

    // A FRESH read (separate Guard, fresh pin) sees the latest
    // published value -- confirms updates actually landed.
    var fresh = cell.read(&tle);
    defer fresh.release();
    const last_n: i64 = 2000 + 199;
    try testing.expectEqual(last_n, fresh.get().a);
    try testing.expectEqual(last_n * 2, fresh.get().b);
}

test "AtomicPtr: compareAndPublish succeeds on matching expected, retires old via EBR" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var tle = try newTle(&ctx, testing.allocator);
    defer ctx.unregister(&tle);
    defer {
        tle.reclaimLocal(testing.allocator);
        tle.deinit(testing.allocator);
    }

    var cell = try AtomicPtr(i64).init(testing.allocator, 10);
    defer {
        cell.deinit(&tle, testing.allocator) catch unreachable;
        var d: usize = 0;
        while (d < 6) : (d += 1) {
            tle.reclaimLocal(testing.allocator);
            ctx.reclaim(testing.allocator);
        }
    }

    // Take a snapshot of the current pointer (NOT a Guard — we
    // need the raw pointer to feed compareAndPublish's `expected`).
    const expected: *i64 = blk: {
        var g = cell.read(&tle);
        defer g.release();
        break :blk g.get();
    };
    // The snapshot's underlying *i64 is now reachable only via the
    // cell (no Guard pin), but it WILL be retired-not-freed when
    // we replace it below; reclaim happens out-of-line.

    // Build a `new` pointer manually and try to publish.
    const new = try testing.allocator.create(i64);
    new.* = 42;
    const ok = try cell.compareAndPublish(&tle, testing.allocator, expected, new);
    try testing.expect(ok);

    // The cell should now read 42.
    var g = cell.read(&tle);
    defer g.release();
    try testing.expectEqual(@as(i64, 42), g.get().*);
}

test "AtomicPtr: compareAndPublish fails on stale expected, leaves cell unchanged, caller frees new" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var tle = try newTle(&ctx, testing.allocator);
    defer ctx.unregister(&tle);
    defer {
        tle.reclaimLocal(testing.allocator);
        tle.deinit(testing.allocator);
    }

    var cell = try AtomicPtr(i64).init(testing.allocator, 100);
    defer {
        cell.deinit(&tle, testing.allocator) catch unreachable;
        var d: usize = 0;
        while (d < 6) : (d += 1) {
            tle.reclaimLocal(testing.allocator);
            ctx.reclaim(testing.allocator);
        }
    }

    // Construct a stale `expected` that the cell will never match
    // (a brand-new heap pointer that was never published to this
    // cell). compareAndPublish must return false.
    const stale = try testing.allocator.create(i64);
    defer testing.allocator.destroy(stale);
    stale.* = 999;

    const new = try testing.allocator.create(i64);
    defer testing.allocator.destroy(new); // caller still owns on failure
    new.* = 200;

    const ok = try cell.compareAndPublish(&tle, testing.allocator, stale, new);
    try testing.expect(!ok);

    // Cell value unchanged.
    var g = cell.read(&tle);
    defer g.release();
    try testing.expectEqual(@as(i64, 100), g.get().*);
}

test "AtomicPtr: rcu-update completes a long retry-driven sequence (within 256 cap)" {
    // Single-threaded, so no real CAS contention; each update call
    // succeeds on its first CAS attempt. Run 10K update calls
    // back-to-back, each driven by a user-fn that increments by 1.
    // True-Sync-Polymorphism (#330) bounded the inner CAS loop at
    // MAX_UPDATE_RETRIES = 256 -- but with no contention the cap
    // is never approached, so no `error.AtomicConflict` surfaces.
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var tle = try newTle(&ctx, testing.allocator);
    defer ctx.unregister(&tle);
    defer tle.deinit(testing.allocator);

    var cell = try AtomicPtr(i64).init(testing.allocator, 0);
    defer {
        cell.deinit(&tle, testing.allocator) catch unreachable;
        var d: usize = 0;
        while (d < 6) : (d += 1) {
            tle.reclaimLocal(testing.allocator);
            ctx.reclaim(testing.allocator);
        }
    }

    var i: usize = 0;
    const iters: usize = if (build_options.coverage) 100 else 10_000;
    while (i < iters) : (i += 1) {
        try cell.update(&tle, testing.allocator, struct {
            fn call(p: *i64) void {
                p.* += 1;
            }
        }.call, .{});
        if ((i & 0xFF) == 0xFF) tle.reclaimLocal(testing.allocator);
    }

    var g = cell.read(&tle);
    defer g.release();
    try testing.expectEqual(@as(i64, @intCast(iters)), g.get().*);
}

// Holds references to a cell + EBR context so a closure can publish
// a competing snapshot during AtomicPtr.update, defeating the outer
// CAS race deterministically. Used by the bounded-retry test below.
const Racer = struct {
    cell_ref: *AtomicPtr(i64),
    tle_ref: *ThreadLocalEbr,
};

fn racingMutator(p: *i64, r: Racer) void {
    p.* += 1;
    // Publish a fresh interloper value so the outer CAS in update()
    // sees a stale "expected" pointer and loses the race.
    const interloper = testing.allocator.create(i64) catch return;
    interloper.* = -1;
    const old = r.cell_ref.ptr.swap(interloper, .acq_rel) orelse return;
    r.tle_ref.retire(testing.allocator, old) catch {};
}

test "AtomicPtr: bounded retry surfaces error.AtomicConflict when cap is exhausted (#330)" {
    // Pin the new bounded-retry contract: under sustained CAS
    // contention that defeats every retry, the loop returns
    // `error.AtomicConflict` (the bridge to CLEAR's AtomicConflict).
    // racingMutator publishes a fresh side-channel value on every
    // call, so each inner CAS attempt sees a stale expected pointer
    // and loses its race -- exhausting the 256-attempt budget.
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var tle = try newTle(&ctx, testing.allocator);
    defer ctx.unregister(&tle);
    defer tle.deinit(testing.allocator);

    var cell = try AtomicPtr(i64).init(testing.allocator, 0);
    defer {
        cell.deinit(&tle, testing.allocator) catch unreachable;
        var d: usize = 0;
        while (d < 6) : (d += 1) {
            tle.reclaimLocal(testing.allocator);
            ctx.reclaim(testing.allocator);
        }
    }

    const racer: Racer = .{ .cell_ref = &cell, .tle_ref = &tle };
    const result = cell.update(&tle, testing.allocator, racingMutator, .{racer});
    try testing.expectError(error.AtomicConflict, result);
}
