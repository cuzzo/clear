//! VOPR-style property/simulation tests for the AtomicPtr primitive.
//!
//! Single-threaded deterministic simulator. Seeded PRNG drives a
//! random sequence of read / readHold / releaseHeld / update / reclaim
//! ops; invariants checked after each step.
//!
//! Mirrors versioned-vopr-test.zig. Goal: import lib/atomic_ptr.zig
//! into the VOPR coverage tree so the file gets kcov instrumentation.
//! Without this, atomic_ptr.zig is FILE-NOT-LOADED in the VOPR report.
//!
//! Invariants:
//!   I1  post-update: read returns the value just written.
//!   I2  held guard: dereferences to the value captured at read-time
//!       (EBR keeps the old node alive).
//!   I3  post-update: limbo grew by exactly 1 retire.

const std = @import("std");
const testing = std.testing;

const ebr_mod = @import("../lib/ebr.zig");
const atomic_ptr = @import("../lib/atomic_ptr.zig");
const sim_atomic = @import("vopr-atomic.zig");
const build_options = @import("build_options");

const EbrContext = ebr_mod.EbrContext;
const ThreadLocalEbr = ebr_mod.ThreadLocalEbr;

const FlowKind = enum { cont_commit, skip_no_commit, ret_commit, ret_no_commit, raise_no_commit };
const Flow = struct { kind: FlowKind = .cont_commit };

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

const OpKind = enum {
    Read,
    ReadHold,
    ReleaseHeld,
    Update,
    ReclaimLocal,
    ReclaimGlobal,
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

const HeldEntry = struct {
    guard: atomic_ptr.AtomicPtr(i64).Guard,
    captured: i64,
};

fn runSequence(seed: u64, steps: usize, allocator: std.mem.Allocator) !void {
    var rng = std.Random.DefaultPrng.init(seed);
    const random = rng.random();

    var ctx = EbrContext{};
    defer ctx.deinit(allocator);

    var ebr = try allocator.create(ThreadLocalEbr);
    ebr.* = ThreadLocalEbr{ .context = &ctx };
    try ctx.register(allocator, ebr);

    var held = std.ArrayList(HeldEntry).empty;
    var cell = try atomic_ptr.AtomicPtr(i64).init(allocator, 0);
    var live_value: i64 = 0;
    // One unified teardown so destruction order is unambiguous:
    // release held guards (drop EBR pins) -> deinit cell (retire current) ->
    // drain limbo -> deinit + free ebr.
    defer {
        for (held.items) |*e| e.guard.release();
        held.deinit(allocator);
        cell.deinit(ebr, allocator) catch unreachable;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            ctx.reclaim(allocator);
            ebr.reclaimLocal(allocator);
        }
        ctx.unregister(ebr);
        ebr.deinit(allocator);
        allocator.destroy(ebr);
    }

    var step: usize = 0;
    while (step < steps) : (step += 1) {
        const op = pickOp(random, held.items.len > 0);
        switch (op) {
            .Read => {
                var g = cell.read(ebr);
                try testing.expectEqual(live_value, g.get().*);
                g.release();
            },
            .ReadHold => {
                var g = cell.read(ebr);
                const captured = g.get().*;
                try held.append(allocator, .{ .guard = g, .captured = captured });
            },
            .ReleaseHeld => {
                if (held.items.len == 0) continue;
                const idx = random.intRangeAtMost(usize, 0, held.items.len - 1);
                var e = held.swapRemove(idx);
                e.guard.release();
            },
            .Update => {
                const new_v = @as(i64, @intCast(step)) + 1;
                const limbo_before = ebr.limbo_list.items.len;
                try cell.update(ebr, allocator, struct {
                    fn call(p: *i64, v: i64) void {
                        p.* = v;
                    }
                }.call, .{new_v});
                live_value = new_v;
                // I1
                var g = cell.read(ebr);
                try testing.expectEqual(new_v, g.get().*);
                g.release();
                // I3
                try testing.expectEqual(limbo_before + 1, ebr.limbo_list.items.len);
            },
            .ReclaimLocal => ebr.reclaimLocal(allocator),
            .ReclaimGlobal => ctx.reclaim(allocator),
        }
    }

    // I2: every held guard still dereferences to the captured value.
    for (held.items) |*e| {
        try testing.expectEqual(e.captured, e.guard.get().*);
    }
}

var gpa: std.heap.DebugAllocator(.{}) = .{};

fn vopr_alloc() std.mem.Allocator {
    return gpa.allocator();
}

/// Wrapper main() calls this AFTER each test fn returns, so the
/// test's `defer` cleanup has already fired. Detects leaks across
/// scenarios and resets the allocator for hermeticity.
pub fn checkLeaksAndReset() !void {
    if (gpa.deinit() != .ok) return error.LeaksDetected;
    gpa = .{};
    // Fault injection state is process-global; reset between tests so
    // a scenario that sets inject_cas_fault doesn't bleed into the next.
    sim_atomic.resetFault();
}

/// Drives the AtomicPtr.update CAS-loser retry path under deterministic
/// fault injection. Without this scenario the retry-loop BODY (the
/// `if (cmpxchgWeak) |_| { spinLoopHint; continue; }` branch in
/// lib/atomic_ptr.zig:237-242) never executes -- single-threaded VOPR
/// can't lose a CAS to itself. Fault injection forces a synthetic loser
/// at the configured rate so the retry path runs.
///
/// Asserts:
///   - At least one synthetic CAS fault fires
///   - update() eventually succeeds (didn't exhaust retries at 50% rate)
///   - The published value matches what the closure wrote
pub fn testUpdateRetryBodyUnderFault() !void {
    const allocator = vopr_alloc();

    var ctx = EbrContext{};
    defer ctx.deinit(allocator);

    var ebr = try allocator.create(ThreadLocalEbr);
    ebr.* = ThreadLocalEbr{ .context = &ctx };
    try ctx.register(allocator, ebr);

    var cell = try atomic_ptr.AtomicPtr(i64).init(allocator, 0);

    // Hermetic teardown: cell.deinit retires the current ptr, then drain
    // EBR limbo so allocator stays clean for checkLeaksAndReset.
    defer {
        cell.deinit(ebr, allocator) catch unreachable;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            ctx.reclaim(allocator);
            ebr.reclaimLocal(allocator);
        }
        ctx.unregister(ebr);
        ebr.deinit(allocator);
        allocator.destroy(ebr);
    }

    // 50% fault rate. With one update() call the first roll might be
    // a success (no fault fires); drive 16 sequential updates so the
    // probability of every single first-roll succeeding is ~2^-16.
    // Each successful update increments by 1; final value should be 16.
    sim_atomic.seedFault(0xC0FFEE);
    sim_atomic.inject_cas_fault = true;
    sim_atomic.inject_cas_fault_rate = 5000;

    const synthetic_before = sim_atomic.sim_cmpxchg_synthetic_fault_count;

    var i: i64 = 0;
    while (i < 16) : (i += 1) {
        try cell.update(ebr, allocator, struct {
            fn call(p: *i64, _: i64) void {
                p.* = p.* + 1;
            }
        }.call, .{0});
    }

    const synthetic_after = sim_atomic.sim_cmpxchg_synthetic_fault_count;
    if (synthetic_after == synthetic_before) return error.NoFaultInjected;

    // The updates eventually all succeeded; observe via read.
    var g = cell.read(ebr);
    defer g.release();
    if (g.get().* != 16) return error.UpdateValueWrong;
}

/// Same fault-injection contract as testUpdateRetryBodyUnderFault, but
/// through updateFlow's separate retry loop. This catches regressions
/// where generated flow-control mutation paths stop honoring CAS-loser
/// retry behavior even though plain update() still works.
pub fn testUpdateFlowRetryBodyUnderFault() !void {
    const allocator = vopr_alloc();

    var ctx = EbrContext{};
    defer ctx.deinit(allocator);

    var ebr = try allocator.create(ThreadLocalEbr);
    ebr.* = ThreadLocalEbr{ .context = &ctx };
    try ctx.register(allocator, ebr);

    var cell = try atomic_ptr.AtomicPtr(i64).init(allocator, 0);
    defer {
        cell.deinit(ebr, allocator) catch unreachable;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            ctx.reclaim(allocator);
            ebr.reclaimLocal(allocator);
        }
        ctx.unregister(ebr);
        ebr.deinit(allocator);
        allocator.destroy(ebr);
    }

    sim_atomic.seedFault(0xF10CF10C);
    sim_atomic.inject_cas_fault = true;
    sim_atomic.inject_cas_fault_rate = 5000;

    const synthetic_before = sim_atomic.sim_cmpxchg_synthetic_fault_count;

    var i: i64 = 0;
    while (i < 16) : (i += 1) {
        var flow = Flow{};
        try cell.updateFlow(ebr, allocator, flowIncrement, .{&flow});
        if (flow.kind != .cont_commit) return error.FlowKindUnexpected;
    }

    const synthetic_after = sim_atomic.sim_cmpxchg_synthetic_fault_count;
    if (synthetic_after == synthetic_before) return error.NoFaultInjected;

    var g = cell.read(ebr);
    defer g.release();
    if (g.get().* != 16) return error.UpdateFlowValueWrong;
}

pub fn testUpdateFlowNoCommitBranches() !void {
    const allocator = vopr_alloc();

    var ctx = EbrContext{};
    defer ctx.deinit(allocator);

    var ebr = try allocator.create(ThreadLocalEbr);
    ebr.* = ThreadLocalEbr{ .context = &ctx };
    try ctx.register(allocator, ebr);

    var cell = try atomic_ptr.AtomicPtr(i64).init(allocator, 10);
    defer {
        cell.deinit(ebr, allocator) catch unreachable;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            ctx.reclaim(allocator);
            ebr.reclaimLocal(allocator);
        }
        ctx.unregister(ebr);
        ebr.deinit(allocator);
        allocator.destroy(ebr);
    }

    var skip = Flow{};
    try cell.updateFlow(ebr, allocator, flowSkipNoCommit, .{&skip});
    if (skip.kind != .skip_no_commit) return error.FlowKindUnexpected;

    var ret = Flow{};
    try cell.updateFlow(ebr, allocator, flowRetNoCommit, .{&ret});
    if (ret.kind != .ret_no_commit) return error.FlowKindUnexpected;

    var raised = Flow{};
    try cell.updateFlow(ebr, allocator, flowRaiseNoCommit, .{&raised});
    if (raised.kind != .raise_no_commit) return error.FlowKindUnexpected;

    var g = cell.read(ebr);
    defer g.release();
    if (g.get().* != 10) return error.NoCommitMutatedCell;
}

/// Drives the AtomicPtr.update bounded-retry-exhaustion contract:
/// at 100% fault rate, every CAS becomes a synthetic failure and the
/// loop runs MAX_UPDATE_RETRIES times before returning
/// error.AtomicConflict. Verifies the bounded-retry escape path
/// surfaces the right error class.
pub fn testUpdateRetryExhaustionUnderFault() !void {
    const allocator = vopr_alloc();

    var ctx = EbrContext{};
    defer ctx.deinit(allocator);

    var ebr = try allocator.create(ThreadLocalEbr);
    ebr.* = ThreadLocalEbr{ .context = &ctx };
    try ctx.register(allocator, ebr);

    var cell = try atomic_ptr.AtomicPtr(i64).init(allocator, 0);

    defer {
        cell.deinit(ebr, allocator) catch unreachable;
        var i: usize = 0;
        while (i < 6) : (i += 1) {
            ctx.reclaim(allocator);
            ebr.reclaimLocal(allocator);
        }
        ctx.unregister(ebr);
        ebr.deinit(allocator);
        allocator.destroy(ebr);
    }

    // 100% fault rate: every cmpxchg synthetically fails.
    sim_atomic.seedFault(1);
    sim_atomic.inject_cas_fault = true;
    sim_atomic.inject_cas_fault_rate = 10_000;

    const result = cell.update(ebr, allocator, struct {
        fn call(p: *i64, v: i64) void {
            p.* = v;
        }
    }.call, .{99});

    if (result) |_| {
        return error.UpdateUnexpectedlySucceeded;
    } else |err| if (err != error.AtomicConflict) return err;

    // The CAS attempts equal MAX_UPDATE_RETRIES (256). Each iteration
    // does exactly one cmpxchg attempt, all synthetic-faulted.
    if (sim_atomic.sim_cmpxchg_synthetic_fault_count != 256) {
        std.debug.print(
            "expected 256 synthetic faults, got {d}\n",
            .{sim_atomic.sim_cmpxchg_synthetic_fault_count},
        );
        return error.UnexpectedFaultCount;
    }

    // Cell value unchanged (no successful publish).
    var g = cell.read(ebr);
    defer g.release();
    if (g.get().* != 0) return error.CellMutatedDespiteAllFaults;
}

pub fn testManySeedsShortSteps() !void {
    const seeds = if (build_options.coverage) 4 else 100;
    const steps = if (build_options.coverage) 40 else 200;
    var i: u64 = 0;
    while (i < seeds) : (i += 1) {
        try runSequence(i, steps, vopr_alloc());
    }
}

pub fn testFewSeedsLongSteps() !void {
    const seeds = if (build_options.coverage) 2 else 30;
    const steps = if (build_options.coverage) 80 else 1000;
    var i: u64 = 1000;
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
