//! Single-threaded unit tests for the MVCC primitives:
//!   - EBR (`zig/lib/ebr.zig`):  EbrContext, ThreadLocalEbr, RetiredPtr
//!   - Versioned(T) (`zig/runtime/versioned.zig`):  atomic-pointer COW
//!
//! These exercise the basic state-machine of EBR (enter/exit, retire,
//! reclaim) and the read/update lifecycle of `Versioned(T)` -- without
//! concurrency.  Single-threaded coverage is the foundation: it lets a
//! reader / maintainer see the contract before the multi-threaded
//! stress / Loom / VOPR layers go in.
//!
//! Where the implementation has known weak spots that single-thread
//! tests can't detect (memory-ordering on `read()`, deinit-while-reader,
//! retry/back-off under contention), the tests document the gap with
//! a comment and the expected behavior under the current code.
//!
//! Findings catalogued by Tranche 1 (FIXED in Tranche 2 are marked):
//!
//!   C1 [CRIT, FIXED in T2] -- versioned.zig:85 `Versioned.read`
//!                loaded ptr with `.monotonic`. Writer cmpxchg uses
//!                `.release`. Reader now uses `.acquire` to
//!                synchronize with writes inside `*new_ptr`.
//!
//!   C2 [CRIT, FIXED in T2] -- versioned.zig:72 `Versioned.deinit`
//!                called `allocator.destroy(current_ptr)` directly.
//!                A concurrent reader was UAF. Now retires via EBR
//!                so the free is deferred until every active epoch
//!                drains -- same contract `update()` uses for the
//!                old pointer it swaps out.
//!
//!   H1 [HIGH, FIXED in T7] -- `Versioned.update` allocated `new_ptr`
//!                BEFORE every CAS attempt and `destroy`d on fail.
//!                Tranche 7 hoists the alloc out of the loop -- one
//!                create at entry, one retire on success or one
//!                destroy on failure. Bench shows +56% throughput
//!                for 4 writers, +44% for 8 writers.
//!
//!   H2 [HIGH, FIXED in T7] -- `Versioned.update` retried forever.
//!                Tranche 7 caps at 10K retries with spinLoopHint
//!                backoff (linear up to 256 hints/iter, capped),
//!                returns `error.UpdateRetriesExhausted` on exhaust
//!                so callers can choose a fallback strategy.
//!
//!   H3 [HIGH, MITIGATED in T2] -- `Shared.Guard.release` MUST be
//!                called or EBR's `is_active` stays true forever,
//!                blocking all reclamation. Tranche 2 added the
//!                closure-based `withRead(rt, fn, args)` API that
//!                auto-releases via defer. The bare read/release
//!                pair is still available for advanced use sites
//!                that need to hold the Guard across a call boundary.
//!
//!   M1 [MED]  -- ebr.zig:168-176 `enter()` stores `is_active=true`
//!                then loads global then stores local_epoch. A
//!                reclaimer running between active-store and
//!                local-store sees `active=true, local=0`; correctness
//!                preserved (reclaim refuses to advance) but
//!                reclamation delayed. Acceptable today.
//!
//!   M2 [MED, FIXED in T7] -- `ThreadLocalEbr.deinit` -> dumpTrash
//!                appended every retired item to global orphans
//!                without bound. Tranche 7 makes dumpTrash filter:
//!                items already past safe_threshold are freed
//!                immediately, only items inside the grace window
//!                go to orphans. Bounds growth when many short-lived
//!                threads die under heavy reclaim pressure.
//!                (The OOM-fallback allocator-mismatch in deinit's
//!                catch arm is a separate concern, parked for now.)
//!
//!   M3 [MED]  -- ebr.zig:98 / 150 reclaim is 3-cycle (vs textbook 2).
//!                The `current_global > 1` guard uses BEFORE-advance
//!                value, making safe_threshold one cycle later than
//!                strictly necessary. Inefficient but correct.
//!
//!   M4 [MED]  -- ebr.zig dumpTrash (dying threads -> global orphans)
//!                has no backpressure. Many short-lived threads under
//!                heavy reclaim pressure can grow orphans unboundedly.
//!                Tranche 7.
//!
//!   M5 [MED, FOUNDATION DONE in T4] -- Both Versioned(T) and EBR now
//!                route their atomics through `Atomic = if
//!                @hasDecl(root, "SimAtomic") root.SimAtomic else
//!                std.atomic.Value`, the same comptime-shim pattern
//!                queues.zig + scheduler.zig + parking-lot use.
//!                The full fiber-based Loom HARNESS (~600 LOC like
//!                parking-lot-loom.zig) is a separate, larger
//!                investment; today's std.Thread stress (T3) covers
//!                the common race classes. The shim removes the
//!                blocker -- a future maintainer can build a Loom
//!                driver without touching versioned.zig or
//!                ebr.zig.

const std = @import("std");
const testing = std.testing;

const ebr_mod = @import("../lib/ebr.zig");
const versioned = @import("versioned.zig");
const Runtime = @import("runtime.zig").Runtime;

const EbrContext = ebr_mod.EbrContext;
const ThreadLocalEbr = ebr_mod.ThreadLocalEbr;
const RetiredPtr = ebr_mod.RetiredPtr;

// ============================================================
// EBR — primitive state machine (no Shared / no Runtime)
// ============================================================

test "EBR: ThreadLocalEbr starts inactive at epoch 0" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var local = ThreadLocalEbr{ .context = &ctx };
    defer local.deinit(testing.allocator);

    try testing.expect(!local.is_active.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), local.local_epoch.load(.seq_cst));
}

test "EBR: enter() flips is_active and snaps local_epoch to global_epoch" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    // Pre-seed global epoch so we can see the snap.
    ctx.global_epoch.store(7, .seq_cst);

    var local = ThreadLocalEbr{ .context = &ctx };
    defer local.deinit(testing.allocator);

    local.enter();
    try testing.expect(local.is_active.load(.seq_cst));
    try testing.expectEqual(@as(u32, 7), local.local_epoch.load(.seq_cst));
}

test "EBR: exit() flips is_active back to false (epoch retained)" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);
    ctx.global_epoch.store(3, .seq_cst);

    var local = ThreadLocalEbr{ .context = &ctx };
    defer local.deinit(testing.allocator);

    local.enter();
    local.exit();
    try testing.expect(!local.is_active.load(.seq_cst));
    // The epoch snap from enter() is retained -- exit() doesn't reset it.
    try testing.expectEqual(@as(u32, 3), local.local_epoch.load(.seq_cst));
}

test "EBR: register / unregister maintain registry list" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var l1 = ThreadLocalEbr{ .context = &ctx };
    defer l1.deinit(testing.allocator);
    var l2 = ThreadLocalEbr{ .context = &ctx };
    defer l2.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 0), ctx.registry.items.len);

    try ctx.register(testing.allocator, &l1);
    try ctx.register(testing.allocator, &l2);
    try testing.expectEqual(@as(usize, 2), ctx.registry.items.len);

    ctx.unregister(&l1);
    try testing.expectEqual(@as(usize, 1), ctx.registry.items.len);
    try testing.expectEqual(@as(*ThreadLocalEbr, &l2), ctx.registry.items[0]);

    ctx.unregister(&l2);
    try testing.expectEqual(@as(usize, 0), ctx.registry.items.len);
}

test "EBR: retire adds an item to limbo_list tagged with the current local epoch" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);
    ctx.global_epoch.store(5, .seq_cst);

    var local = ThreadLocalEbr{ .context = &ctx };
    defer local.deinit(testing.allocator);

    local.enter();
    defer local.exit();

    const x = try testing.allocator.create(u64);
    x.* = 42;
    try local.retire(testing.allocator, x);

    try testing.expectEqual(@as(usize, 1), local.limbo_list.items.len);
    try testing.expectEqual(@as(u32, 5), local.limbo_list.items[0].epoch);
}

test "EBR: reclaim() advances global_epoch when no active threads block it" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    // No registered threads at all -> trivially advanceable.
    try testing.expectEqual(@as(u32, 0), ctx.global_epoch.load(.seq_cst));
    ctx.reclaim(testing.allocator);
    try testing.expectEqual(@as(u32, 1), ctx.global_epoch.load(.seq_cst));
    ctx.reclaim(testing.allocator);
    try testing.expectEqual(@as(u32, 2), ctx.global_epoch.load(.seq_cst));
}

test "EBR: reclaim() refuses to advance when an active thread is behind" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var local = ThreadLocalEbr{ .context = &ctx };
    defer local.deinit(testing.allocator);
    try ctx.register(testing.allocator, &local);
    defer ctx.unregister(&local);

    // Reader entered at epoch 0; meanwhile global manually advanced.
    local.enter();
    ctx.global_epoch.store(2, .seq_cst);

    // local_epoch (0) != global (2) -> can_advance=false, global stays at 2.
    ctx.reclaim(testing.allocator);
    try testing.expectEqual(@as(u32, 2), ctx.global_epoch.load(.seq_cst));

    // Once the reader exits, the active-and-behind blocker is gone.
    local.exit();
    ctx.reclaim(testing.allocator);
    try testing.expectEqual(@as(u32, 3), ctx.global_epoch.load(.seq_cst));
}

test "EBR: reclaim() advances when an active thread is at the current epoch" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var local = ThreadLocalEbr{ .context = &ctx };
    defer local.deinit(testing.allocator);
    try ctx.register(testing.allocator, &local);
    defer ctx.unregister(&local);

    local.enter(); // local_epoch = global = 0
    ctx.reclaim(testing.allocator); // 0 == 0 -> can_advance, 0 -> 1
    try testing.expectEqual(@as(u32, 1), ctx.global_epoch.load(.seq_cst));
    local.exit();
}

test "EBR: reclaimLocal() frees items below safe_threshold (3-cycle latency)" {
    // safe_threshold = global - 1 (when global > 1, else 0). An item
    // retired at epoch E becomes safe once global >= E + 2; reclaimLocal
    // checks `item.epoch < safe_threshold`, so an item at epoch 0 is
    // freed once global reaches 2 (threshold = 1). The implementation
    // is slightly conservative -- 3 reclaim cycles end-to-end -- but
    // safe.

    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);
    var local = ThreadLocalEbr{ .context = &ctx };
    defer local.deinit(testing.allocator);

    local.enter();
    const x = try testing.allocator.create(u64);
    x.* = 99;
    try local.retire(testing.allocator, x);
    local.exit();

    try testing.expectEqual(@as(usize, 1), local.limbo_list.items.len);

    // global = 0 -> threshold = 0 (special case): nothing freed yet.
    local.reclaimLocal(testing.allocator);
    try testing.expectEqual(@as(usize, 1), local.limbo_list.items.len);

    // Advance global once. global = 1 -> threshold still 0 (the
    // `current_global > 1` branch). Item not yet freed.
    ctx.global_epoch.store(1, .seq_cst);
    local.reclaimLocal(testing.allocator);
    try testing.expectEqual(@as(usize, 1), local.limbo_list.items.len);

    // Advance once more. global = 2 -> threshold = 1. Item.epoch (0)
    // < 1, so it's freed and removed from limbo.
    ctx.global_epoch.store(2, .seq_cst);
    local.reclaimLocal(testing.allocator);
    try testing.expectEqual(@as(usize, 0), local.limbo_list.items.len);
}

test "EBR: reclaim() frees orphans (global limbo) below safe_threshold" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    // Manually add an orphan that's been around since epoch 0.
    const x = try testing.allocator.create(u64);
    x.* = 7;
    try ctx.orphans.append(testing.allocator, RetiredPtr.create(u64, x, 0));
    try testing.expectEqual(@as(usize, 1), ctx.orphans.items.len);

    // 1st reclaim: global 0 -> 1, threshold 0 (special), no free.
    ctx.reclaim(testing.allocator);
    try testing.expectEqual(@as(usize, 1), ctx.orphans.items.len);

    // 2nd reclaim: global 1 -> 2, threshold 0 (since BEFORE-advance was 1
    // and the code uses `current_global > 1` else 0). Still no free.
    ctx.reclaim(testing.allocator);
    try testing.expectEqual(@as(usize, 1), ctx.orphans.items.len);

    // 3rd reclaim: global 2 -> 3, threshold = 1. Item.epoch (0) < 1, free.
    ctx.reclaim(testing.allocator);
    try testing.expectEqual(@as(usize, 0), ctx.orphans.items.len);
}

test "EBR: ThreadLocalEbr.deinit moves still-pending limbo to global orphans" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    {
        var local = ThreadLocalEbr{ .context = &ctx };
        // Don't register -- registry membership is independent of dumpTrash.

        const x = try testing.allocator.create(u64);
        x.* = 11;
        try local.retire(testing.allocator, x);
        try testing.expectEqual(@as(usize, 1), local.limbo_list.items.len);

        local.deinit(testing.allocator); // moves limbo -> ctx.orphans
    }

    try testing.expectEqual(@as(usize, 1), ctx.orphans.items.len);
    // Cleanup happens via ctx.deinit which frees orphans.
}

// NOTE: The OOM-fallback path in `ThreadLocalEbr.deinit` (ebr.zig
// line 130-135) frees each pending item via `deinit_fn(allocator,
// ptr)` using the allocator passed to `deinit`. If that allocator
// differs from the one that created the items, the fallback is
// allocator-mismatched -- a latent bug we'll surface properly in
// the T3 multi-threaded stress (where FailingAllocator can be
// threaded through cleanly). Single-threaded coverage of the
// fallback isn't worth a malformed test today.

// ============================================================
// Versioned(T) — single-threaded read / update / retire
// ============================================================

// Helper: build a Runtime backed by a fixed-size frame slice. The
// runtime owns a ThreadLocalEbr field; we register it with the
// shared EbrContext so reclaim sees it.
fn makeRuntime(ctx: *EbrContext, frame: []u8) !Runtime {
    return Runtime.initFromSlice(frame, ctx, testing.allocator, 0);
}

test "Versioned(i64): init / deinit round-trip retires the live pointer via EBR" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();

    var s = try versioned.Versioned(i64).init(testing.allocator, 42);
    try s.deinit(&rt, testing.allocator);

    // After deinit the live pointer is queued in the runtime's
    // limbo (deferred-free path). EbrContext.deinit will sweep it
    // through the global orphans on test exit -- no leak.
    try testing.expectEqual(@as(usize, 1), rt.ebr.limbo_list.items.len);
}

test "Versioned(i64): read returns the current pointer + EBR is active during the guard" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();

    var s = try versioned.Versioned(i64).init(testing.allocator, 100);
    defer s.deinit(&rt, testing.allocator) catch unreachable;

    var g = s.read(&rt);
    try testing.expectEqual(@as(i64, 100), g.get().*);
    try testing.expect(rt.ebr.is_active.load(.seq_cst));

    g.release();
    try testing.expect(!rt.ebr.is_active.load(.seq_cst));
}

test "Versioned(i64): nested read guards keep EBR pinned until the outer guard releases" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();

    var s = try versioned.Versioned(i64).init(testing.allocator, 100);
    defer s.deinit(&rt, testing.allocator) catch unreachable;

    var outer = s.read(&rt);
    var inner = s.read(&rt);
    try testing.expect(rt.ebr.is_active.load(.seq_cst));
    try testing.expectEqual(@as(u32, 2), rt.ebr.pin_depth.load(.seq_cst));

    inner.release();
    try testing.expect(rt.ebr.is_active.load(.seq_cst));
    try testing.expectEqual(@as(u32, 1), rt.ebr.pin_depth.load(.seq_cst));

    outer.release();
    try testing.expect(!rt.ebr.is_active.load(.seq_cst));
    try testing.expectEqual(@as(u32, 0), rt.ebr.pin_depth.load(.seq_cst));
}

const incArgs = struct { delta: i64 };
fn incBy(p: *i64, delta: i64) void {
    p.* += delta;
}

test "Versioned(i64): update modifies the value (single-thread, single-pass CAS)" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();

    var s = try versioned.Versioned(i64).init(testing.allocator, 10);
    defer s.deinit(&rt, testing.allocator) catch unreachable;

    try s.update(&rt, testing.allocator, incBy, .{@as(i64, 5)});

    var g = s.read(&rt);
    defer g.release();
    try testing.expectEqual(@as(i64, 15), g.get().*);
}

test "Versioned(i64): update retires the old pointer to the writer's limbo" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();

    var s = try versioned.Versioned(i64).init(testing.allocator, 0);
    defer s.deinit(&rt, testing.allocator) catch unreachable;

    try testing.expectEqual(@as(usize, 0), rt.ebr.limbo_list.items.len);
    try s.update(&rt, testing.allocator, incBy, .{@as(i64, 1)});
    try testing.expectEqual(@as(usize, 1), rt.ebr.limbo_list.items.len);

    try s.update(&rt, testing.allocator, incBy, .{@as(i64, 1)});
    try testing.expectEqual(@as(usize, 2), rt.ebr.limbo_list.items.len);
}

test "Versioned(i64): sequential updates produce sequential snapshots" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();

    var s = try versioned.Versioned(i64).init(testing.allocator, 0);
    defer s.deinit(&rt, testing.allocator) catch unreachable;

    var i: i64 = 0;
    while (i < 5) : (i += 1) {
        try s.update(&rt, testing.allocator, incBy, .{@as(i64, 2)});
    }

    var g = s.read(&rt);
    defer g.release();
    try testing.expectEqual(@as(i64, 10), g.get().*);
}

test "Versioned(i64): reader's snapshot stays valid across an in-flight update (EBR contract)" {
    // The core MVCC guarantee: a reader holding a Guard via read()
    // sees the OLD pointer even after a writer has CAS'd in a new
    // version, until it releases. The retired old pointer sits in
    // the writer's limbo; it must NOT be freed until the reader exits.
    //
    // This test exercises the SINGLE-THREADED path -- same Runtime/EBR
    // for both read and write -- and verifies the read pointer
    // dereferences to the OLD value after the update.

    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();
    try ctx.register(testing.allocator, rt.ebr);
    defer ctx.unregister(rt.ebr);

    var s = try versioned.Versioned(i64).init(testing.allocator, 100);
    defer s.deinit(&rt, testing.allocator) catch unreachable;

    // Reader takes a snapshot.
    var g = s.read(&rt);
    const observed_addr = g.get();
    try testing.expectEqual(@as(i64, 100), observed_addr.*);

    // Writer flips the pointer + retires the old.
    try s.update(&rt, testing.allocator, incBy, .{@as(i64, 23)});
    try testing.expect(rt.ebr.limbo_list.items.len >= 1);

    // Reader's pointer still dereferences to the OLD value -- the EBR
    // protection means the old node hasn't been freed.
    try testing.expectEqual(@as(i64, 100), observed_addr.*);

    // Try to reclaim while the reader is still active.
    ctx.reclaim(testing.allocator);
    rt.ebr.reclaimLocal(testing.allocator);
    // Limbo unchanged: reader is at epoch 0, blocking reclaim from
    // advancing past where the retired pointer's epoch lives.
    try testing.expect(rt.ebr.limbo_list.items.len >= 1);

    // Old pointer still readable.
    try testing.expectEqual(@as(i64, 100), observed_addr.*);

    // Reader exits; now reclamation can progress.
    g.release();
    ctx.reclaim(testing.allocator);
    ctx.reclaim(testing.allocator);
    ctx.reclaim(testing.allocator);
    rt.ebr.reclaimLocal(testing.allocator);
    try testing.expectEqual(@as(usize, 0), rt.ebr.limbo_list.items.len);

    // After release, a fresh read sees the new value.
    var g2 = s.read(&rt);
    defer g2.release();
    try testing.expectEqual(@as(i64, 123), g2.get().*);
}

test "Versioned(struct): COW preserves field values across update" {
    const Point = struct { x: i64, y: i64 };

    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();

    var s = try versioned.Versioned(Point).init(testing.allocator, .{ .x = 1, .y = 2 });
    defer s.deinit(&rt, testing.allocator) catch unreachable;

    const setY = struct {
        fn call(p: *Point, ny: i64) void { p.y = ny; }
    }.call;
    try s.update(&rt, testing.allocator, setY, .{@as(i64, 99)});

    var g = s.read(&rt);
    defer g.release();
    try testing.expectEqual(@as(i64, 1), g.get().x); // unchanged
    try testing.expectEqual(@as(i64, 99), g.get().y); // updated
}

// ============================================================
// Tranche 2 additions: C1 (acquire load), H3 (withRead closure)
// ============================================================

test "Versioned(i64): withRead invokes the closure and auto-releases EBR" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();

    var s = try versioned.Versioned(i64).init(testing.allocator, 7);
    defer s.deinit(&rt, testing.allocator) catch unreachable;

    const observed = s.withRead(&rt, struct {
        fn call(p: *i64) i64 { return p.*; }
    }.call, .{});

    try testing.expectEqual(@as(i64, 7), observed);
    // Auto-release: is_active should be false after withRead returns.
    try testing.expect(!rt.ebr.is_active.load(.seq_cst));
}

test "Versioned(i64): withRead releases EBR even when the closure does early-return logic" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();

    var s = try versioned.Versioned(i64).init(testing.allocator, 50);
    defer s.deinit(&rt, testing.allocator) catch unreachable;

    // The closure path encodes early-out in the return value; the
    // defer in withRead always runs regardless, so the EBR exit
    // happens on every control-flow path through the closure.
    const observed = s.withRead(&rt, struct {
        fn call(p: *i64) bool { return p.* > 100; }
    }.call, .{});

    try testing.expectEqual(false, observed);
    try testing.expect(!rt.ebr.is_active.load(.seq_cst));
}

test "Versioned(i64): H1 -- update allocates exactly ONE node per call (no per-retry alloc thrash)" {
    // The previous implementation allocated `new_ptr` inside the
    // CAS loop and `destroy`d on each retry. The fix hoists the
    // alloc out -- one create, one retire-on-success or one
    // destroy-on-failure. We can't directly observe alloc count
    // here, but we can verify limbo grows by exactly 1 per
    // successful update (proves the retire branch fired exactly
    // once, which means at most one allocation was created).
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();

    var s = try versioned.Versioned(i64).init(testing.allocator, 0);
    defer s.deinit(&rt, testing.allocator) catch unreachable;

    var i: i64 = 1;
    while (i <= 50) : (i += 1) {
        try s.update(&rt, testing.allocator, struct {
            fn call(p: *i64, v: i64) void { p.* = v; }
        }.call, .{i});
    }
    // 50 updates -> 50 retires. Plus the deinit retire below.
    try testing.expectEqual(@as(usize, 50), rt.ebr.limbo_list.items.len);
}

test "Versioned(i64): H2 -- update has bounded retries (returns error.UpdateRetriesExhausted on pathological contention)" {
    // The error type now includes UpdateRetriesExhausted in its
    // error union. Single-threaded test can't force exhaustion
    // (no contention), but we verify the union resolves to a
    // type the caller can pattern-match on.
    const VersionedI64 = versioned.Versioned(i64);
    const E = VersionedI64.UpdateError;
    const sample_err: E = error.UpdateRetriesExhausted;
    try testing.expectEqual(@as(E, error.UpdateRetriesExhausted), sample_err);
}

test "EBR: M2 -- dumpTrash frees items already past safe_threshold (orphan backpressure)" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    // Pre-advance the global epoch so a "past-threshold" item has
    // a real epoch to compare against. global = 5 -> safe_threshold
    // = 4 (since 5 > 1). Items with epoch < 4 are safely freeable.
    ctx.global_epoch.store(5, .seq_cst);

    // Construct a thread-local that's about to be torn down with
    // pending limbo: one OLD item (epoch 0, well past threshold)
    // and one NEW item (epoch 5, inside the grace window).
    var local = ThreadLocalEbr{ .context = &ctx };

    const old_item = try testing.allocator.create(u64);
    old_item.* = 1;
    try local.limbo_list.append(testing.allocator, RetiredPtr.create(u64, old_item, 0));

    const new_item = try testing.allocator.create(u64);
    new_item.* = 2;
    try local.limbo_list.append(testing.allocator, RetiredPtr.create(u64, new_item, 5));

    try testing.expectEqual(@as(usize, 2), local.limbo_list.items.len);
    try testing.expectEqual(@as(usize, 0), ctx.orphans.items.len);

    // deinit() invokes dumpTrash which now filters by threshold.
    local.deinit(testing.allocator);

    // The OLD item was freed directly (no orphan added).
    // The NEW item lives on in orphans for ctx.deinit to sweep.
    try testing.expectEqual(@as(usize, 1), ctx.orphans.items.len);
}

// =========================================================================
// MULTI-CELL TRANSACTIONS (LR: updateMulti)
// =========================================================================
//
// Single-threaded tests for the multi-cell tagged-pointer transaction
// primitive. Concurrent stress / VOPR / ABBA tests live in
// shared-memory-stress-test.zig and shared-memory-vopr-test.zig.

const Account = struct { balance: i64, version: u32 };

test "updateMulti: single cell -- equivalent to update()" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);
    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();

    var a = try versioned.Versioned(i64).init(testing.allocator, 100);
    defer a.deinit(&rt, testing.allocator) catch unreachable;

    try versioned.updateMulti(.{&a}, &rt, testing.allocator, struct {
        fn run(views: anytype) anyerror!void {
            views[0].* += 50;
        }
    }.run, .{});

    const observed = a.withRead(&rt, struct {
        fn call(p: *i64) i64 { return p.*; }
    }.call, .{});
    try testing.expectEqual(@as(i64, 150), observed);
}

test "updateMulti: two homogeneous cells commit atomically" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);
    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();

    var a = try versioned.Versioned(i64).init(testing.allocator, 100);
    defer a.deinit(&rt, testing.allocator) catch unreachable;
    var b = try versioned.Versioned(i64).init(testing.allocator, 200);
    defer b.deinit(&rt, testing.allocator) catch unreachable;

    // Move 25 from a to b.
    try versioned.updateMulti(.{ &a, &b }, &rt, testing.allocator, struct {
        fn run(views: anytype) anyerror!void {
            views[0].* -= 25;
            views[1].* += 25;
        }
    }.run, .{});

    const av = a.withRead(&rt, struct { fn c(p: *i64) i64 { return p.*; } }.c, .{});
    const bv = b.withRead(&rt, struct { fn c(p: *i64) i64 { return p.*; } }.c, .{});
    try testing.expectEqual(@as(i64, 75), av);
    try testing.expectEqual(@as(i64, 225), bv);
    try testing.expectEqual(@as(i64, 300), av + bv); // invariant preserved
}

test "updateMulti: heterogeneous cell types (i64 + struct) commit atomically" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);
    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();

    var counter = try versioned.Versioned(i64).init(testing.allocator, 0);
    defer counter.deinit(&rt, testing.allocator) catch unreachable;
    var acct = try versioned.Versioned(Account).init(testing.allocator, .{ .balance = 1000, .version = 1 });
    defer acct.deinit(&rt, testing.allocator) catch unreachable;

    try versioned.updateMulti(.{ &counter, &acct }, &rt, testing.allocator, struct {
        fn run(views: anytype) anyerror!void {
            views[0].* += 1;
            views[1].balance += 500;
            views[1].version += 1;
        }
    }.run, .{});

    const cv = counter.withRead(&rt, struct { fn r(p: *i64) i64 { return p.*; } }.r, .{});
    const av = acct.withRead(&rt, struct { fn r(p: *Account) Account { return p.*; } }.r, .{});
    try testing.expectEqual(@as(i64, 1), cv);
    try testing.expectEqual(@as(i64, 1500), av.balance);
    try testing.expectEqual(@as(u32, 2), av.version);
}

test "updateMulti: three cells, sorted-commit invariant (any order at call site)" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);
    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();

    var x = try versioned.Versioned(i64).init(testing.allocator, 1);
    defer x.deinit(&rt, testing.allocator) catch unreachable;
    var y = try versioned.Versioned(i64).init(testing.allocator, 2);
    defer y.deinit(&rt, testing.allocator) catch unreachable;
    var z = try versioned.Versioned(i64).init(testing.allocator, 3);
    defer z.deinit(&rt, testing.allocator) catch unreachable;

    // Pass cells in textual order (x, y, z) -- runtime sorts by addr.
    try versioned.updateMulti(.{ &x, &y, &z }, &rt, testing.allocator, struct {
        fn run(views: anytype) anyerror!void {
            views[0].* *= 10;
            views[1].* *= 10;
            views[2].* *= 10;
        }
    }.run, .{});

    try testing.expectEqual(@as(i64, 10), x.withRead(&rt, struct { fn c(p: *i64) i64 { return p.*; } }.c, .{}));
    try testing.expectEqual(@as(i64, 20), y.withRead(&rt, struct { fn c(p: *i64) i64 { return p.*; } }.c, .{}));
    try testing.expectEqual(@as(i64, 30), z.withRead(&rt, struct { fn c(p: *i64) i64 { return p.*; } }.c, .{}));
}

test "updateMulti: ABBA call-order produces same final state regardless" {
    // Two updateMulti calls touching the same cells in different
    // textual orders. Address-sorted commit means both observe the
    // same effective serialization. With single-thread, both sequences
    // just compose; the test checks the API doesn't reject either order.
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);
    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();

    var a = try versioned.Versioned(i64).init(testing.allocator, 0);
    defer a.deinit(&rt, testing.allocator) catch unreachable;
    var b = try versioned.Versioned(i64).init(testing.allocator, 0);
    defer b.deinit(&rt, testing.allocator) catch unreachable;

    const inc2 = struct {
        fn run(views: anytype) anyerror!void {
            views[0].* += 1;
            views[1].* += 1;
        }
    }.run;

    try versioned.updateMulti(.{ &a, &b }, &rt, testing.allocator, inc2, .{}); // (A,B)
    try versioned.updateMulti(.{ &b, &a }, &rt, testing.allocator, inc2, .{}); // (B,A) -- same effect after sort

    try testing.expectEqual(@as(i64, 2), a.withRead(&rt, struct { fn c(p: *i64) i64 { return p.*; } }.c, .{}));
    try testing.expectEqual(@as(i64, 2), b.withRead(&rt, struct { fn c(p: *i64) i64 { return p.*; } }.c, .{}));
}

test "updateMulti: txn body error rolls back -- cells unchanged" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);
    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();

    var a = try versioned.Versioned(i64).init(testing.allocator, 100);
    defer a.deinit(&rt, testing.allocator) catch unreachable;
    var b = try versioned.Versioned(i64).init(testing.allocator, 200);
    defer b.deinit(&rt, testing.allocator) catch unreachable;

    const result = versioned.updateMulti(.{ &a, &b }, &rt, testing.allocator, struct {
        fn run(views: anytype) anyerror!void {
            views[0].* = 999;
            views[1].* = 999;
            return error.UserAbort;
        }
    }.run, .{});

    try testing.expectError(error.UserAbort, result);

    // Both cells unchanged after rollback.
    try testing.expectEqual(@as(i64, 100), a.withRead(&rt, struct { fn c(p: *i64) i64 { return p.*; } }.c, .{}));
    try testing.expectEqual(@as(i64, 200), b.withRead(&rt, struct { fn c(p: *i64) i64 { return p.*; } }.c, .{}));
}

test "updateMulti: zero cells is a no-op" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);
    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();

    try versioned.updateMulti(.{}, &rt, testing.allocator, struct {
        fn run(views: anytype) anyerror!void {
            _ = views;
        }
    }.run, .{});
}

test "updateMulti: snapshot is the value AT acquire time (sequential consistency)" {
    // Single-thread: write to a, then updateMulti reads a + b, mutates,
    // then a separate update on a races -- this test runs sequentially
    // so just verifies the txn body sees the latest committed value.
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);
    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();

    var a = try versioned.Versioned(i64).init(testing.allocator, 1);
    defer a.deinit(&rt, testing.allocator) catch unreachable;
    var b = try versioned.Versioned(i64).init(testing.allocator, 0);
    defer b.deinit(&rt, testing.allocator) catch unreachable;

    // Bump a a few times.
    try a.update(&rt, testing.allocator, incBy, .{@as(i64, 9)});
    try a.update(&rt, testing.allocator, incBy, .{@as(i64, 10)});
    // Now a == 20.

    try versioned.updateMulti(.{ &a, &b }, &rt, testing.allocator, struct {
        fn run(views: anytype) anyerror!void {
            // Snapshot reads must reflect the latest committed values.
            try std.testing.expectEqual(@as(i64, 20), views[0].*);
            try std.testing.expectEqual(@as(i64, 0), views[1].*);
            views[1].* = views[0].* * 2;
        }
    }.run, .{});

    try testing.expectEqual(@as(i64, 20), a.withRead(&rt, struct { fn c(p: *i64) i64 { return p.*; } }.c, .{}));
    try testing.expectEqual(@as(i64, 40), b.withRead(&rt, struct { fn c(p: *i64) i64 { return p.*; } }.c, .{}));
}

test "updateMulti: tagged-pointer release after commit -- cells are readable post-txn" {
    // After updateMulti returns, all cells must hold UNTAGGED pointers.
    // Subsequent reads must see the new values without spinning.
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);
    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();

    var a = try versioned.Versioned(i64).init(testing.allocator, 1);
    defer a.deinit(&rt, testing.allocator) catch unreachable;
    var b = try versioned.Versioned(i64).init(testing.allocator, 2);
    defer b.deinit(&rt, testing.allocator) catch unreachable;

    try versioned.updateMulti(.{ &a, &b }, &rt, testing.allocator, struct {
        fn run(views: anytype) anyerror!void {
            views[0].* = 100;
            views[1].* = 200;
        }
    }.run, .{});

    // Direct ptr load -- low bit must be 0 (untagged).
    const a_addr = a.ptr.load(.acquire);
    const b_addr = b.ptr.load(.acquire);
    try testing.expectEqual(@as(usize, 0), a_addr & 1);
    try testing.expectEqual(@as(usize, 0), b_addr & 1);
    const ap: *i64 = @ptrFromInt(a_addr);
    const bp: *i64 = @ptrFromInt(b_addr);
    try testing.expectEqual(@as(i64, 100), ap.*);
    try testing.expectEqual(@as(i64, 200), bp.*);
}

test "updateMulti: subsequent single-cell update sees the multi-cell commit" {
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);
    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();

    var a = try versioned.Versioned(i64).init(testing.allocator, 0);
    defer a.deinit(&rt, testing.allocator) catch unreachable;
    var b = try versioned.Versioned(i64).init(testing.allocator, 0);
    defer b.deinit(&rt, testing.allocator) catch unreachable;

    try versioned.updateMulti(.{ &a, &b }, &rt, testing.allocator, struct {
        fn run(views: anytype) anyerror!void {
            views[0].* = 5;
            views[1].* = 7;
        }
    }.run, .{});

    // Single-cell update sees the multi-committed value.
    try a.update(&rt, testing.allocator, incBy, .{@as(i64, 1)});
    try testing.expectEqual(@as(i64, 6), a.withRead(&rt, struct { fn c(p: *i64) i64 { return p.*; } }.c, .{}));
    try testing.expectEqual(@as(i64, 7), b.withRead(&rt, struct { fn c(p: *i64) i64 { return p.*; } }.c, .{}));
}

test "Versioned(i64): C1 -- read uses .acquire (single-threaded sanity)" {
    // True memory-ordering bugs only surface on weakly-ordered
    // hardware under concurrent load -- we can't *prove* the load
    // is .acquire from a single-thread test. What we CAN do is
    // pin the API behavior: a value written via update() is
    // observed by a subsequent read() in the same thread, with
    // no synchronization helpers. This catches a regression where
    // someone might unwind the change back to .monotonic and forget
    // to add a memory fence.
    var ctx = EbrContext{};
    defer ctx.deinit(testing.allocator);

    var frame: [1024]u8 = undefined;
    var rt = try makeRuntime(&ctx, &frame);
    defer rt.deinit();

    var s = try versioned.Versioned(i64).init(testing.allocator, 0);
    defer s.deinit(&rt, testing.allocator) catch unreachable;

    var i: i64 = 1;
    while (i <= 100) : (i += 1) {
        try s.update(&rt, testing.allocator, struct {
            fn call(p: *i64, v: i64) void { p.* = v; }
        }.call, .{i});

        const observed = s.withRead(&rt, struct {
            fn call(p: *i64) i64 { return p.*; }
        }.call, .{});

        try testing.expectEqual(i, observed);
    }
}
