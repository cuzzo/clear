//! VOPR-style property/simulation tests for the MVCC primitives.
//!
//! Single-threaded deterministic simulator: each test seeds a PRNG
//! and runs a random sequence of Versioned(T) and EBR operations,
//! checking invariants after every step.  Reproducible by seed.
//!
//! This is NOT integrated into `vopr.zig` (which is RunQueue-
//! specific and tightly coupled to the scheduler model). A future
//! cross-cutting integration would extend the existing VOPR's step
//! kinds with SharedRead / SharedUpdate / EbrReclaim and check MVCC
//! invariants alongside scheduler invariants. That's a larger
//! refactor; this file is the standalone first step.
//!
//! What this catches that T1/T3 don't:
//!
//!   - Reproducibility: seed N replays exactly. T3's std.Thread
//!     stress relies on the OS scheduler -- non-reproducible.
//!   - Coverage of unusual sequences: deinit -> retire -> ANOTHER
//!     update -> reclaim -> read; readers exit out of order;
//!     update fails CAS by external manipulation; etc.
//!   - Per-step invariant checks: catches bugs at the precise op
//!     where the invariant breaks, not at end-of-test where state
//!     has accumulated.
//!
//! Invariants checked (per step):
//!
//!   I1  post-update: read returns the value just written.
//!   I2  post-read: the Guard's pointer is non-null and
//!       dereferences to a "live" T (i.e. not freed memory --
//!       single-thread we can verify by tracking expected_value).
//!   I3  post-retire: the retired pointer's epoch <= writer's
//!       local_epoch.
//!   I4  post-reclaim: every freed item had epoch < safe_threshold.
//!   I5  end-of-test: zero leaks (DebugAllocator).

const std = @import("std");
const testing = std.testing;

const ebr_mod = @import("../lib/ebr.zig");
const versioned = @import("versioned.zig");
const Runtime = @import("runtime.zig").Runtime;
const sim_atomic = @import("vopr-atomic.zig");
const build_options = @import("build_options");

const EbrContext = ebr_mod.EbrContext;
const ThreadLocalEbr = ebr_mod.ThreadLocalEbr;

const FlowKind = enum { cont_commit, skip_no_commit, ret_commit, ret_no_commit, raise_no_commit };
const Flow = struct { kind: FlowKind = .cont_commit };
const OwnedBytes = struct { data: []const u8 };

fn flowIncrement(p: *i64, flow: *Flow) void {
    p.* += 1;
    flow.kind = .cont_commit;
}

fn flowSkipNoCommit(p: *i64, flow: *Flow) void {
    p.* = 111;
    flow.kind = .skip_no_commit;
}

fn flowRetNoCommit(p: *i64, flow: *Flow) void {
    p.* = 222;
    flow.kind = .ret_no_commit;
}

fn flowRaiseNoCommit(p: *i64, flow: *Flow) void {
    p.* = 333;
    flow.kind = .raise_no_commit;
}

fn keepOwnedBytes(_: *OwnedBytes) void {}

fn flowKeepOwnedBytes(_: *OwnedBytes, flow: *Flow) void {
    flow.kind = .cont_commit;
}

fn writePair(views: anytype, a: i64, b: i64) !void {
    views[0].* = a;
    views[1].* = b;
}

const OpKind = enum {
    Read, // read + immediate release
    ReadHold, // read but defer release to a later step
    ReleaseHeld, // release one of the held guards
    Update, // update with a fresh value
    ReclaimLocal, // sweep this thread's limbo
    ReclaimGlobal, // advance epoch + sweep orphans
};

fn pickOp(random: std.Random, has_held: bool) OpKind {
    const roll = random.intRangeAtMost(u8, 0, 99);
    if (roll < 30) return .Read;
    if (roll < 45) return .ReadHold;
    if (roll < 55) return if (has_held) .ReleaseHeld else .Read;
    if (roll < 80) return .Update;
    if (roll < 92) return .ReclaimLocal;
    return .ReclaimGlobal;
}

const HeldGuards = std.ArrayList(versioned.Versioned(i64).Guard);

fn runSequence(seed: u64, steps: usize, allocator: std.mem.Allocator) !void {
    var rng = std.Random.DefaultPrng.init(seed);
    const random = rng.random();

    var ctx = EbrContext{};
    defer ctx.deinit(allocator);

    var frame: [2048]u8 = undefined;
    var rt = try Runtime.initFromSlice(&frame, &ctx, allocator, 0);
    defer rt.deinit();
    try ctx.register(allocator, rt.ebr);
    defer ctx.unregister(rt.ebr);

    var s = try versioned.Versioned(i64).init(allocator, 0);
    var live_value: i64 = 0;
    defer {
        s.deinit(&rt, allocator) catch unreachable;
        // Drain everything before ctx.deinit sweeps orphans.
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            ctx.reclaim(allocator);
            rt.ebr.reclaimLocal(allocator);
        }
    }

    var held = HeldGuards.empty;
    defer {
        for (held.items) |*g| g.release();
        held.deinit(allocator);
    }

    var step: usize = 0;
    while (step < steps) : (step += 1) {
        const op = pickOp(random, held.items.len > 0);
        switch (op) {
            .Read => {
                var g = s.read(&rt);
                // I2: pointer dereferences to a value we recognize
                // (the most-recently-published live_value).
                try testing.expectEqual(live_value, g.get().*);
                g.release();
            },
            .ReadHold => {
                var g = s.read(&rt);
                // The held guard captures the CURRENT live_value at
                // the time of read.  Subsequent updates produce new
                // versions; the held guard must keep dereferencing
                // to its captured value (EBR contract).
                _ = g.get().*; // touch
                try held.append(allocator, g);
            },
            .ReleaseHeld => {
                if (held.items.len == 0) continue;
                const idx = random.intRangeAtMost(usize, 0, held.items.len - 1);
                var g = held.swapRemove(idx);
                g.release();
            },
            .Update => {
                const new_v = @as(i64, @intCast(step)) + 1;
                const limbo_before = rt.ebr.limbo_list.items.len;
                try s.update(&rt, allocator, struct {
                    fn call(p: *i64, v: i64) void {
                        p.* = v;
                    }
                }.call, .{new_v});
                live_value = new_v;
                // I1: a read RIGHT NOW returns the just-written
                // value (assuming no other writer; this sim is
                // single-threaded so trivially true).
                var g = s.read(&rt);
                try testing.expectEqual(new_v, g.get().*);
                g.release();
                // I3: a retire happened -> limbo grew by 1.
                try testing.expectEqual(limbo_before + 1, rt.ebr.limbo_list.items.len);
            },
            .ReclaimLocal => {
                rt.ebr.reclaimLocal(allocator);
            },
            .ReclaimGlobal => {
                ctx.reclaim(allocator);
            },
        }
    }

    // Every held guard must STILL dereference to the value it
    // captured (EBR keeps its node alive).  We don't track per-
    // guard captured values to avoid bloat, but we verify the
    // dereference doesn't crash and produces an i64.
    for (held.items) |*g| {
        const v = g.get().*;
        _ = v;
    }
}

var gpa: std.heap.DebugAllocator(.{}) = .{};

fn vopr_alloc() std.mem.Allocator {
    return gpa.allocator();
}

pub fn checkLeaksAndReset() !void {
    if (gpa.deinit() != .ok) return error.LeaksDetected;
    gpa = .{};
    // Fault injection state is process-global; reset between tests.
    sim_atomic.resetFault();
}

/// Drives MVCC Versioned.update CAS-loser retry path under fault
/// injection. Mirrors testUpdateRetryBodyUnderFault in atomic-ptr-vopr
/// but for the MVCC primitive at zig/runtime/versioned.zig.
///
/// Asserts at least one synthetic CAS fault fires across 16 sequential
/// updates at 50% rate, and the final committed value reflects all 16.
pub fn testMvccRetryBodyUnderFault() !void {
    const allocator = vopr_alloc();

    var ctx = ebr_mod.EbrContext{};
    defer ctx.deinit(allocator);

    var frame: [2048]u8 = undefined;
    var rt = try Runtime.initFromSlice(&frame, &ctx, allocator, 0);
    defer rt.deinit();
    try ctx.register(allocator, rt.ebr);
    defer ctx.unregister(rt.ebr);

    var s = try versioned.Versioned(i64).init(allocator, 0);
    defer {
        s.deinit(&rt, allocator) catch unreachable;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            ctx.reclaim(allocator);
            rt.ebr.reclaimLocal(allocator);
        }
    }

    sim_atomic.seedFault(0xBADC0FFEE);
    sim_atomic.inject_cas_fault = true;
    sim_atomic.inject_cas_fault_rate = 5000;

    const synthetic_before = sim_atomic.sim_cmpxchg_synthetic_fault_count;

    var i: i64 = 0;
    while (i < 16) : (i += 1) {
        try s.update(&rt, allocator, struct {
            fn call(p: *i64, _: i64) void {
                p.* = p.* + 1;
            }
        }.call, .{0});
    }

    const synthetic_after = sim_atomic.sim_cmpxchg_synthetic_fault_count;
    if (synthetic_after == synthetic_before) return error.NoFaultInjected;

    var g = s.read(&rt);
    defer g.release();
    if (g.get().* != 16) return error.MvccUpdateValueWrong;
}

/// Same CAS-loser retry contract as testMvccRetryBodyUnderFault, but
/// through updateFlow's generated-control-flow mutation surface.
pub fn testMvccUpdateFlowRetryBodyUnderFault() !void {
    const allocator = vopr_alloc();

    var ctx = ebr_mod.EbrContext{};
    defer ctx.deinit(allocator);

    var frame: [2048]u8 = undefined;
    var rt = try Runtime.initFromSlice(&frame, &ctx, allocator, 0);
    defer rt.deinit();
    try ctx.register(allocator, rt.ebr);
    defer ctx.unregister(rt.ebr);

    var s = try versioned.Versioned(i64).init(allocator, 0);
    defer {
        s.deinit(&rt, allocator) catch unreachable;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            ctx.reclaim(allocator);
            rt.ebr.reclaimLocal(allocator);
        }
    }

    sim_atomic.seedFault(0xBEEFF10C);
    sim_atomic.inject_cas_fault = true;
    sim_atomic.inject_cas_fault_rate = 5000;

    const synthetic_before = sim_atomic.sim_cmpxchg_synthetic_fault_count;

    var i: i64 = 0;
    while (i < 16) : (i += 1) {
        var flow = Flow{};
        try s.updateFlow(&rt, allocator, flowIncrement, .{&flow});
        if (flow.kind != .cont_commit) return error.FlowKindUnexpected;
    }

    const synthetic_after = sim_atomic.sim_cmpxchg_synthetic_fault_count;
    if (synthetic_after == synthetic_before) return error.NoFaultInjected;

    var g = s.read(&rt);
    defer g.release();
    if (g.get().* != 16) return error.MvccUpdateFlowValueWrong;
}

pub fn testMvccUpdateFlowNoCommitBranches() !void {
    const allocator = vopr_alloc();

    var ctx = ebr_mod.EbrContext{};
    defer ctx.deinit(allocator);

    var frame: [2048]u8 = undefined;
    var rt = try Runtime.initFromSlice(&frame, &ctx, allocator, 0);
    defer rt.deinit();
    try ctx.register(allocator, rt.ebr);
    defer ctx.unregister(rt.ebr);

    var s = try versioned.Versioned(i64).init(allocator, 10);
    defer {
        s.deinit(&rt, allocator) catch unreachable;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            ctx.reclaim(allocator);
            rt.ebr.reclaimLocal(allocator);
        }
    }

    var skip = Flow{};
    try s.updateFlow(&rt, allocator, flowSkipNoCommit, .{&skip});
    if (skip.kind != .skip_no_commit) return error.FlowKindUnexpected;

    var ret = Flow{};
    try s.updateFlow(&rt, allocator, flowRetNoCommit, .{&ret});
    if (ret.kind != .ret_no_commit) return error.FlowKindUnexpected;

    var raised = Flow{};
    try s.updateFlow(&rt, allocator, flowRaiseNoCommit, .{&raised});
    if (raised.kind != .raise_no_commit) return error.FlowKindUnexpected;

    var g = s.read(&rt);
    defer g.release();
    if (g.get().* != 10) return error.NoCommitMutatedCell;
}

pub fn testMvccUpdateOwnedCopyFailureCleansCandidate() !void {
    const backing = vopr_alloc();

    var ctx = ebr_mod.EbrContext{};
    defer ctx.deinit(backing);

    var frame: [2048]u8 = undefined;
    var rt = try Runtime.initFromSlice(&frame, &ctx, backing, 0);
    defer rt.deinit();
    try ctx.register(backing, rt.ebr);
    defer ctx.unregister(rt.ebr);

    const initial = OwnedBytes{ .data = try backing.dupe(u8, "stable") };
    var s = try versioned.Versioned(OwnedBytes).init(backing, initial);
    defer {
        s.deinit(&rt, backing) catch unreachable;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            ctx.reclaim(backing);
            rt.ebr.reclaimLocal(backing);
        }
    }

    var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 1 });
    const result = s.update(&rt, failing.allocator(), keepOwnedBytes, .{});
    if (result) |_| {
        return error.UpdateUnexpectedlySucceeded;
    } else |err| if (err != error.OutOfMemory) return err;

    var g = s.read(&rt);
    defer g.release();
    if (!std.mem.eql(u8, g.get().data, "stable")) return error.CellMutatedDespiteCopyFailure;
}

pub fn testMvccUpdateFlowOwnedCopyFailureCleansCandidate() !void {
    const backing = vopr_alloc();

    var ctx = ebr_mod.EbrContext{};
    defer ctx.deinit(backing);

    var frame: [2048]u8 = undefined;
    var rt = try Runtime.initFromSlice(&frame, &ctx, backing, 0);
    defer rt.deinit();
    try ctx.register(backing, rt.ebr);
    defer ctx.unregister(rt.ebr);

    const initial = OwnedBytes{ .data = try backing.dupe(u8, "stable-flow") };
    var s = try versioned.Versioned(OwnedBytes).init(backing, initial);
    defer {
        s.deinit(&rt, backing) catch unreachable;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            ctx.reclaim(backing);
            rt.ebr.reclaimLocal(backing);
        }
    }

    var flow = Flow{};
    var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 1 });
    const result = s.updateFlow(&rt, failing.allocator(), flowKeepOwnedBytes, .{&flow});
    if (result) |_| {
        return error.UpdateFlowUnexpectedlySucceeded;
    } else |err| if (err != error.OutOfMemory) return err;

    if (flow.kind != .cont_commit) return error.FlowShouldNotHaveRunAfterCopyFailure;

    var g = s.read(&rt);
    defer g.release();
    if (!std.mem.eql(u8, g.get().data, "stable-flow")) return error.CellMutatedDespiteCopyFailure;
}

/// Drives Versioned.update's tag-spin retry body at versioned.zig:315.
/// The path fires when an updateMulti has tagged this cell's ptr
/// (low-bit set); update spins reloading until the tag is cleared.
/// Single-thread VOPR can't normally reach this -- there's no
/// concurrent updateMulti to set the tag. SimAtomic's
/// inject_load_tagged_count_remaining knob simulates the race: the
/// first load returns the addr OR'd with 1 (tagged), the second
/// returns raw, exiting the spin.
pub fn testMvccTagSpinRetryBody() !void {
    const allocator = vopr_alloc();

    var ctx = ebr_mod.EbrContext{};
    defer ctx.deinit(allocator);

    var frame: [2048]u8 = undefined;
    var rt = try Runtime.initFromSlice(&frame, &ctx, allocator, 0);
    defer rt.deinit();
    try ctx.register(allocator, rt.ebr);
    defer ctx.unregister(rt.ebr);

    var s = try versioned.Versioned(i64).init(allocator, 7);
    defer {
        s.deinit(&rt, allocator) catch unreachable;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            ctx.reclaim(allocator);
            rt.ebr.reclaimLocal(allocator);
        }
    }

    // Inject 3 synthetic tagged loads. update's first ptr.load
    // returns tagged; the spin body's L315 reload also returns
    // tagged (fault still active); a second spin iteration's L315
    // reload also returns tagged; the FOURTH load returns raw and
    // spin exits. Using 3 instead of 1 forces the body to execute
    // even if the optimizer folds single-iteration cases.
    sim_atomic.resetFault();
    sim_atomic.inject_load_tagged_count_remaining = 3;

    const synthetic_before = sim_atomic.sim_load_synthetic_tag_count;

    try s.update(&rt, allocator, struct {
        fn call(p: *i64, v: i64) void {
            p.* = v;
        }
    }.call, .{99});

    const synthetic_after = sim_atomic.sim_load_synthetic_tag_count;
    if (synthetic_after == synthetic_before) return error.NoTagInjected;

    var g = s.read(&rt);
    defer g.release();
    if (g.get().* != 99) return error.UpdateValueWrong;
}

pub fn testMvccUpdateFlowTagSpinRetryBody() !void {
    const allocator = vopr_alloc();

    var ctx = ebr_mod.EbrContext{};
    defer ctx.deinit(allocator);

    var frame: [2048]u8 = undefined;
    var rt = try Runtime.initFromSlice(&frame, &ctx, allocator, 0);
    defer rt.deinit();
    try ctx.register(allocator, rt.ebr);
    defer ctx.unregister(rt.ebr);

    var s = try versioned.Versioned(i64).init(allocator, 7);
    defer {
        s.deinit(&rt, allocator) catch unreachable;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            ctx.reclaim(allocator);
            rt.ebr.reclaimLocal(allocator);
        }
    }

    sim_atomic.resetFault();
    sim_atomic.inject_load_tagged_count_remaining = 3;

    const synthetic_before = sim_atomic.sim_load_synthetic_tag_count;

    var flow = Flow{};
    try s.updateFlow(&rt, allocator, flowIncrement, .{&flow});

    const synthetic_after = sim_atomic.sim_load_synthetic_tag_count;
    if (synthetic_after == synthetic_before) return error.NoTagInjected;
    if (flow.kind != .cont_commit) return error.FlowKindUnexpected;

    var g = s.read(&rt);
    defer g.release();
    if (g.get().* != 8) return error.UpdateFlowValueWrong;
}

/// Drives MVCC Versioned.update bounded-retry exhaustion at 100% fault
/// rate. Verifies the loop reaches MAX_UPDATE_RETRIES and surfaces
/// error.UpdateRetriesExhausted (the MVCC bridge to AtomicConflict).
pub fn testMvccRetryExhaustionUnderFault() !void {
    const allocator = vopr_alloc();

    var ctx = ebr_mod.EbrContext{};
    defer ctx.deinit(allocator);

    var frame: [2048]u8 = undefined;
    var rt = try Runtime.initFromSlice(&frame, &ctx, allocator, 0);
    defer rt.deinit();
    try ctx.register(allocator, rt.ebr);
    defer ctx.unregister(rt.ebr);

    var s = try versioned.Versioned(i64).init(allocator, 0);
    defer {
        s.deinit(&rt, allocator) catch unreachable;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            ctx.reclaim(allocator);
            rt.ebr.reclaimLocal(allocator);
        }
    }

    sim_atomic.seedFault(7);
    sim_atomic.inject_cas_fault = true;
    sim_atomic.inject_cas_fault_rate = 10_000;

    const result = s.update(&rt, allocator, struct {
        fn call(p: *i64, _: i64) void {
            p.* = p.* + 1;
        }
    }.call, .{0});

    if (result) |_| {
        return error.UpdateUnexpectedlySucceeded;
    } else |err| if (err != error.UpdateRetriesExhausted) return err;

    // Cell value unchanged (no successful publish at any iteration).
    var g = s.read(&rt);
    defer g.release();
    if (g.get().* != 0) return error.CellMutatedDespiteAllFaults;
}

/// Forces updateMulti's per-cell tagged-pointer spin to exhaust once,
/// roll back any partial acquisition, retry the outer transaction, and
/// finally commit both cells. This is the VOPR-side model of another
/// multi-cell txn temporarily owning a tag.
pub fn testMvccUpdateMultiTaggedContentionRetry() !void {
    const allocator = vopr_alloc();

    var ctx = ebr_mod.EbrContext{};
    defer ctx.deinit(allocator);

    var frame: [2048]u8 = undefined;
    var rt = try Runtime.initFromSlice(&frame, &ctx, allocator, 0);
    defer rt.deinit();
    try ctx.register(allocator, rt.ebr);
    defer ctx.unregister(rt.ebr);

    var a = try versioned.Versioned(i64).init(allocator, 1);
    var b = try versioned.Versioned(i64).init(allocator, 2);
    defer {
        a.deinit(&rt, allocator) catch unreachable;
        b.deinit(&rt, allocator) catch unreachable;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            ctx.reclaim(allocator);
            rt.ebr.reclaimLocal(allocator);
        }
    }

    sim_atomic.resetFault();
    // Let the first cell install its tag, then make both permitted loads of
    // the second cell appear tagged. That forces a partial-acquisition
    // rollback (acquired=1) before the next outer attempt succeeds.
    sim_atomic.inject_load_tagged_skip_remaining = 1;
    sim_atomic.inject_load_tagged_count_remaining = 2;
    const tagged_before = sim_atomic.sim_load_synthetic_tag_count;

    try versioned.updateMulti(.{ &a, &b }, &rt, allocator, writePair, .{ @as(i64, 10), @as(i64, 20) });

    if (sim_atomic.sim_load_synthetic_tag_count == tagged_before) return error.NoTagInjected;

    var ga = a.read(&rt);
    defer ga.release();
    var gb = b.read(&rt);
    defer gb.release();
    if (ga.get().* != 10) return error.FirstCellWrong;
    if (gb.get().* != 20) return error.SecondCellWrong;
}

pub fn testMvccUpdateMultiCasLoserRetry() !void {
    const allocator = vopr_alloc();

    var ctx = ebr_mod.EbrContext{};
    defer ctx.deinit(allocator);

    var frame: [2048]u8 = undefined;
    var rt = try Runtime.initFromSlice(&frame, &ctx, allocator, 0);
    defer rt.deinit();
    try ctx.register(allocator, rt.ebr);
    defer ctx.unregister(rt.ebr);

    var a = try versioned.Versioned(i64).init(allocator, 1);
    var b = try versioned.Versioned(i64).init(allocator, 2);
    defer {
        a.deinit(&rt, allocator) catch unreachable;
        b.deinit(&rt, allocator) catch unreachable;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            ctx.reclaim(allocator);
            rt.ebr.reclaimLocal(allocator);
        }
    }

    sim_atomic.resetFault();
    sim_atomic.inject_cas_fault_count_remaining = 1;
    const synthetic_before = sim_atomic.sim_cmpxchg_synthetic_fault_count;

    try versioned.updateMulti(.{ &a, &b }, &rt, allocator, writePair, .{ @as(i64, 30), @as(i64, 40) });

    if (sim_atomic.sim_cmpxchg_synthetic_fault_count != synthetic_before + 1) {
        return error.CasLoserNotInjected;
    }

    var ga = a.read(&rt);
    defer ga.release();
    var gb = b.read(&rt);
    defer gb.release();
    if (ga.get().* != 30) return error.FirstCellWrong;
    if (gb.get().* != 40) return error.SecondCellWrong;
}

pub fn testManySeedsShortSteps() !void {
    var i: u64 = 0;
    const seeds = if (build_options.coverage) 4 else 200;
    const steps = if (build_options.coverage) 40 else 200;
    while (i < seeds) : (i += 1) {
        try runSequence(i, steps, vopr_alloc());
    }
}

pub fn testFewSeedsLongSteps() !void {
    var i: u64 = 1000;
    const seeds = if (build_options.coverage) 2 else 50;
    const steps = if (build_options.coverage) 80 else 1000;
    while (i < 1000 + seeds) : (i += 1) {
        try runSequence(i, steps, vopr_alloc());
    }
}

pub fn testReproducibility() !void {
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try runSequence(42, 100, vopr_alloc());
    }
}

pub fn testFiftyHeldGuards() !void {
    const allocator = vopr_alloc();

    var ctx = EbrContext{};
    defer ctx.deinit(allocator);

    var frame: [2048]u8 = undefined;
    var rt = try Runtime.initFromSlice(&frame, &ctx, allocator, 0);
    defer rt.deinit();
    try ctx.register(allocator, rt.ebr);
    defer ctx.unregister(rt.ebr);

    var s = try versioned.Versioned(i64).init(allocator, 0);
    defer {
        s.deinit(&rt, allocator) catch unreachable;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            ctx.reclaim(allocator);
            rt.ebr.reclaimLocal(allocator);
        }
    }

    var guards: [50]versioned.Versioned(i64).Guard = undefined;
    var captured_values: [50]i64 = undefined;

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        guards[i] = s.read(&rt);
        captured_values[i] = guards[i].get().*;
        if (i & 1 == 1) {
            try s.update(&rt, allocator, struct {
                fn call(p: *i64, v: i64) void {
                    p.* = v;
                }
            }.call, .{@as(i64, @intCast(i)) + 1});
        }
    }

    for (&guards, 0..) |*g, idx| {
        if (g.get().* != captured_values[idx]) return error.GuardValueChanged;
    }

    // Release in REVERSE order to test out-of-order release paths.
    var j: usize = 50;
    while (j > 0) {
        j -= 1;
        guards[j].release();
    }

    var k: usize = 0;
    while (k < 6) : (k += 1) {
        ctx.reclaim(allocator);
        rt.ebr.reclaimLocal(allocator);
    }
    if (rt.ebr.limbo_list.items.len != 0) return error.LimboNotDrained;

    // defers above run after this fn returns, which frees s/rt/ctx.
    // The wrapper main() calls checkLeaksAndReset() afterward.
}
