//! Multi-threaded stress tests for the MVCC primitives:
//!   - Versioned(T) (zig/runtime/versioned.zig) atomic-pointer COW
//!   - EBR (zig/lib/ebr.zig) epoch-based reclamation
//!
//! Strategy: spawn N reader threads + M writer threads. Each thread
//! runs its own Runtime with an EBR registered against the shared
//! EbrContext. Readers verify the value's structural invariant on
//! every read; writers update via COW; periodic reclaim flushes
//! retired pointers.
//!
//! What these tests catch:
//!   - Torn reads under .monotonic load (validates C1 .acquire fix).
//!   - UAF on concurrent reader holding a Guard while another path
//!     retires/reclaims (validates C2 retire-via-EBR fix).
//!   - Lost / leaked retires under CAS contention.
//!   - Reclamation stuck because the active-thread check is wrong.
//!
//! DebugAllocator (`std.testing.allocator`) catches any pointer that
//! survives `ctx.deinit` in normal runs. TSan runs use libc allocation
//! so sanitizer allocation/free ownership is visible across threads.

const std = @import("std");
const testing = std.testing;
const builtin = @import("builtin");

const ebr_mod = @import("../lib/ebr.zig");
const versioned = @import("versioned.zig");
const Runtime = @import("runtime.zig").Runtime;

const EbrContext = ebr_mod.EbrContext;
const ThreadLocalEbr = ebr_mod.ThreadLocalEbr;

fn stressAllocator() std.mem.Allocator {
    return if (builtin.sanitize_thread) std.heap.c_allocator else testing.allocator;
}

// ============================================================
// Shared payload with a structural invariant
// ============================================================
// Writer flips both fields in lock-step inside the COW closure.
// `b == a * 2` is the invariant a reader must observe -- if the
// reader sees a torn state (new `a` with old `b`, or vice versa),
// the test fails. In the COW model, writer constructs a NEW *T
// before publishing the pointer atomically, so a reader's *T
// only points at one consistent version. The invariant is the
// trip-wire that catches an ordering regression.

const Sample = struct {
    a: i64,
    b: i64,
};

fn writeSample(p: *Sample, n: i64) void {
    p.a = n;
    p.b = n * 2;
}

// ============================================================
// Per-thread runtime fixtures
// ============================================================

const ReaderArgs = struct {
    ctx: *EbrContext,
    s: *versioned.Versioned(Sample),
    iters: usize,
    done: *std.atomic.Value(bool),
    invariant_violations: *std.atomic.Value(usize),
};

fn readerThread(args: *ReaderArgs) void {
    var frame: [4096]u8 = undefined;
    var rt = Runtime.initFromSlice(&frame, args.ctx, stressAllocator(), 0) catch |err| {
        std.debug.print("readerThread: Runtime.initFromSlice failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer rt.deinit();
    args.ctx.register(stressAllocator(), rt.ebr) catch |err| {
        std.debug.print("readerThread: register failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer args.ctx.unregister(rt.ebr);

    var i: usize = 0;
    while (i < args.iters) : (i += 1) {
        var g = args.s.read(&rt);
        const view = g.get().*;
        if (view.b != view.a * 2) {
            _ = args.invariant_violations.fetchAdd(1, .seq_cst);
        }
        g.release();

        // Periodic local reclaim to keep limbo bounded for long runs.
        if ((i & 0xFFF) == 0xFFF) rt.ebr.reclaimLocal(stressAllocator());
    }
    _ = args.done;
}

const WriterArgs = struct {
    ctx: *EbrContext,
    s: *versioned.Versioned(Sample),
    iters: usize,
    base: i64,
    failed_updates: *std.atomic.Value(usize),
};

fn writerThread(args: *WriterArgs) void {
    var frame: [4096]u8 = undefined;
    var rt = Runtime.initFromSlice(&frame, args.ctx, stressAllocator(), 0) catch |err| {
        std.debug.print("writerThread: Runtime.initFromSlice failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer rt.deinit();
    args.ctx.register(stressAllocator(), rt.ebr) catch |err| {
        std.debug.print("writerThread: register failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer args.ctx.unregister(rt.ebr);

    var i: usize = 0;
    while (i < args.iters) : (i += 1) {
        const v = args.base + @as(i64, @intCast(i));
        args.s.update(&rt, stressAllocator(), writeSample, .{v}) catch |err| switch (err) {
            // 64-retry exhaustion is a contention signal under TSan
            // slowdown; not a torn-state failure.
            error.UpdateRetriesExhausted => continue,
            else => {
                _ = args.failed_updates.fetchAdd(1, .seq_cst);
                continue;
            },
        };

        if ((i & 0xFFF) == 0xFFF) {
            rt.ebr.reclaimLocal(stressAllocator());
            args.ctx.reclaim(stressAllocator());
        }
    }
}

// Fully drain limbo + orphans on a Runtime so normal runs can verify
// zero leaks at test exit through std.testing.allocator.
fn drain(ctx: *EbrContext, rt: *Runtime) void {
    // Bump global past any pending epoch so reclaimLocal frees.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        ctx.reclaim(stressAllocator());
        rt.ebr.reclaimLocal(stressAllocator());
    }
}

// ============================================================
// Stress: N readers + 1 writer
// ============================================================

test "Versioned(Sample): 4 readers + 1 writer, no torn reads, no leak" {
    var ctx = EbrContext{};
    defer ctx.deinit(stressAllocator());

    // The Shared lives on the heap so it has a stable address all
    // threads can share. The "main" runtime is what owns its
    // teardown via deinit-via-EBR.
    var main_frame: [4096]u8 = undefined;
    var main_rt = try Runtime.initFromSlice(&main_frame, &ctx, stressAllocator(), 0);
    defer main_rt.deinit();
    try ctx.register(stressAllocator(), main_rt.ebr);
    defer ctx.unregister(main_rt.ebr);

    var s = try versioned.Versioned(Sample).init(stressAllocator(), .{ .a = 0, .b = 0 });
    defer {
        // Final teardown: retire the live pointer + drain.
        s.deinit(&main_rt, stressAllocator()) catch unreachable;
        drain(&ctx, &main_rt);
    }

    var done = std.atomic.Value(bool).init(false);
    var violations = std.atomic.Value(usize).init(0);
    var failed = std.atomic.Value(usize).init(0);

    const ITERS_R = 5_000;
    const ITERS_W = 5_000;

    var r1_args = ReaderArgs{ .ctx = &ctx, .s = &s, .iters = ITERS_R, .done = &done, .invariant_violations = &violations };
    var r2_args = ReaderArgs{ .ctx = &ctx, .s = &s, .iters = ITERS_R, .done = &done, .invariant_violations = &violations };
    var r3_args = ReaderArgs{ .ctx = &ctx, .s = &s, .iters = ITERS_R, .done = &done, .invariant_violations = &violations };
    var r4_args = ReaderArgs{ .ctx = &ctx, .s = &s, .iters = ITERS_R, .done = &done, .invariant_violations = &violations };
    var w_args = WriterArgs{ .ctx = &ctx, .s = &s, .iters = ITERS_W, .base = 1, .failed_updates = &failed };

    const t1 = try std.Thread.spawn(.{}, readerThread, .{&r1_args});
    const t2 = try std.Thread.spawn(.{}, readerThread, .{&r2_args});
    const t3 = try std.Thread.spawn(.{}, readerThread, .{&r3_args});
    const t4 = try std.Thread.spawn(.{}, readerThread, .{&r4_args});
    const w = try std.Thread.spawn(.{}, writerThread, .{&w_args});

    t1.join();
    t2.join();
    t3.join();
    t4.join();
    w.join();

    try testing.expectEqual(@as(usize, 0), violations.load(.seq_cst));
    try testing.expectEqual(@as(usize, 0), failed.load(.seq_cst));
}

// ============================================================
// Stress: 1 reader + 4 writers (CAS contention)
// ============================================================

test "Versioned(Sample): 1 reader + 4 writers under CAS contention, no torn reads" {
    var ctx = EbrContext{};
    defer ctx.deinit(stressAllocator());

    var main_frame: [4096]u8 = undefined;
    var main_rt = try Runtime.initFromSlice(&main_frame, &ctx, stressAllocator(), 0);
    defer main_rt.deinit();
    try ctx.register(stressAllocator(), main_rt.ebr);
    defer ctx.unregister(main_rt.ebr);

    var s = try versioned.Versioned(Sample).init(stressAllocator(), .{ .a = 0, .b = 0 });
    defer {
        s.deinit(&main_rt, stressAllocator()) catch unreachable;
        drain(&ctx, &main_rt);
    }

    var done = std.atomic.Value(bool).init(false);
    var violations = std.atomic.Value(usize).init(0);
    var failed = std.atomic.Value(usize).init(0);

    const ITERS_R = 10_000;
    const ITERS_W = 2_500;

    var r_args = ReaderArgs{ .ctx = &ctx, .s = &s, .iters = ITERS_R, .done = &done, .invariant_violations = &violations };
    var w1 = WriterArgs{ .ctx = &ctx, .s = &s, .iters = ITERS_W, .base = 1_000, .failed_updates = &failed };
    var w2 = WriterArgs{ .ctx = &ctx, .s = &s, .iters = ITERS_W, .base = 2_000, .failed_updates = &failed };
    var w3 = WriterArgs{ .ctx = &ctx, .s = &s, .iters = ITERS_W, .base = 3_000, .failed_updates = &failed };
    var w4 = WriterArgs{ .ctx = &ctx, .s = &s, .iters = ITERS_W, .base = 4_000, .failed_updates = &failed };

    const r = try std.Thread.spawn(.{}, readerThread, .{&r_args});
    const t1 = try std.Thread.spawn(.{}, writerThread, .{&w1});
    const t2 = try std.Thread.spawn(.{}, writerThread, .{&w2});
    const t3 = try std.Thread.spawn(.{}, writerThread, .{&w3});
    const t4 = try std.Thread.spawn(.{}, writerThread, .{&w4});

    r.join();
    t1.join();
    t2.join();
    t3.join();
    t4.join();

    try testing.expectEqual(@as(usize, 0), violations.load(.seq_cst));
    try testing.expectEqual(@as(usize, 0), failed.load(.seq_cst));
}

// ============================================================
// Stress: chaos -- N readers + M writers
// ============================================================

test "Versioned(Sample): 3 readers + 3 writers chaos, invariant + no leak" {
    var ctx = EbrContext{};
    defer ctx.deinit(stressAllocator());

    var main_frame: [4096]u8 = undefined;
    var main_rt = try Runtime.initFromSlice(&main_frame, &ctx, stressAllocator(), 0);
    defer main_rt.deinit();
    try ctx.register(stressAllocator(), main_rt.ebr);
    defer ctx.unregister(main_rt.ebr);

    var s = try versioned.Versioned(Sample).init(stressAllocator(), .{ .a = 0, .b = 0 });
    defer {
        s.deinit(&main_rt, stressAllocator()) catch unreachable;
        drain(&ctx, &main_rt);
    }

    var done = std.atomic.Value(bool).init(false);
    var violations = std.atomic.Value(usize).init(0);
    var failed = std.atomic.Value(usize).init(0);

    const ITERS = 3_000;

    var ra = [_]ReaderArgs{
        .{ .ctx = &ctx, .s = &s, .iters = ITERS, .done = &done, .invariant_violations = &violations },
        .{ .ctx = &ctx, .s = &s, .iters = ITERS, .done = &done, .invariant_violations = &violations },
        .{ .ctx = &ctx, .s = &s, .iters = ITERS, .done = &done, .invariant_violations = &violations },
    };
    var wa = [_]WriterArgs{
        .{ .ctx = &ctx, .s = &s, .iters = ITERS, .base = 100_000, .failed_updates = &failed },
        .{ .ctx = &ctx, .s = &s, .iters = ITERS, .base = 200_000, .failed_updates = &failed },
        .{ .ctx = &ctx, .s = &s, .iters = ITERS, .base = 300_000, .failed_updates = &failed },
    };

    var threads: [6]std.Thread = undefined;
    threads[0] = try std.Thread.spawn(.{}, readerThread, .{&ra[0]});
    threads[1] = try std.Thread.spawn(.{}, readerThread, .{&ra[1]});
    threads[2] = try std.Thread.spawn(.{}, readerThread, .{&ra[2]});
    threads[3] = try std.Thread.spawn(.{}, writerThread, .{&wa[0]});
    threads[4] = try std.Thread.spawn(.{}, writerThread, .{&wa[1]});
    threads[5] = try std.Thread.spawn(.{}, writerThread, .{&wa[2]});

    for (&threads) |*t| t.join();

    try testing.expectEqual(@as(usize, 0), violations.load(.seq_cst));
    try testing.expectEqual(@as(usize, 0), failed.load(.seq_cst));
}

// ============================================================
// Direct C2 stress: reader holds a Guard while concurrent thread
// retires and reclaims. The OLD pointer the reader observes must
// remain valid until the reader's release.
// ============================================================

const HoldArgs = struct {
    ctx: *EbrContext,
    s: *versioned.Versioned(Sample),
    write_iters: usize,
    started: *std.atomic.Value(bool),
    end: *std.atomic.Value(bool),
};

fn writerWithReclaim(args: *HoldArgs) void {
    var frame: [4096]u8 = undefined;
    var rt = Runtime.initFromSlice(&frame, args.ctx, stressAllocator(), 0) catch return;
    defer rt.deinit();
    args.ctx.register(stressAllocator(), rt.ebr) catch return;
    defer args.ctx.unregister(rt.ebr);

    while (!args.started.load(.seq_cst)) std.Thread.yield() catch {};

    var i: usize = 0;
    while (i < args.write_iters) : (i += 1) {
        args.s.update(&rt, stressAllocator(), writeSample, .{@as(i64, @intCast(i + 1))}) catch continue;
        if ((i & 0xFF) == 0xFF) {
            rt.ebr.reclaimLocal(stressAllocator());
            args.ctx.reclaim(stressAllocator());
        }
    }
    args.end.store(true, .seq_cst);
}

test "Versioned(Sample): reader's snapshot survives concurrent retire+reclaim (C2 contract)" {
    var ctx = EbrContext{};
    defer ctx.deinit(stressAllocator());

    var main_frame: [4096]u8 = undefined;
    var main_rt = try Runtime.initFromSlice(&main_frame, &ctx, stressAllocator(), 0);
    defer main_rt.deinit();
    try ctx.register(stressAllocator(), main_rt.ebr);
    defer ctx.unregister(main_rt.ebr);

    var s = try versioned.Versioned(Sample).init(stressAllocator(), .{ .a = 42, .b = 84 });
    defer {
        s.deinit(&main_rt, stressAllocator()) catch unreachable;
        drain(&ctx, &main_rt);
    }

    var started = std.atomic.Value(bool).init(false);
    var end = std.atomic.Value(bool).init(false);

    var args = HoldArgs{
        .ctx = &ctx,
        .s = &s,
        .write_iters = 5_000,
        .started = &started,
        .end = &end,
    };

    // Reader takes a Guard BEFORE the writer thread starts.
    var g = s.read(&main_rt);

    const t = try std.Thread.spawn(.{}, writerWithReclaim, .{&args});
    started.store(true, .seq_cst);

    // While the writer churns + reclaims aggressively, our Guard's
    // pointer must keep dereferencing to the original (.a=42, .b=84)
    // value with its invariant intact.
    while (!end.load(.seq_cst)) {
        const view = g.get().*;
        try testing.expectEqual(@as(i64, 42), view.a);
        try testing.expectEqual(@as(i64, 84), view.b);
    }

    g.release();
    t.join();

    // Post-join: a fresh read sees the writer's last value.
    var g2 = s.read(&main_rt);
    defer g2.release();
    const view2 = g2.get().*;
    try testing.expect(view2.b == view2.a * 2);
    try testing.expect(view2.a >= 1); // writer wrote at least once
}

// ============================================================
// Multi-cell transaction stress (LR: updateMulti)
// ============================================================
// Two cells `a, b` with a strict invariant `a + b == constant`.
// N writer threads continuously transfer between them. K reader
// threads continuously verify the invariant. If `updateMulti`
// publishes the cells non-atomically, a reader will see a state
// where `a + b != constant` -- an invariant violation that fails
// the test. The tagged-pointer "soft lock" + sorted-acquire +
// EBR-pinned snapshot is the safety mechanism.

const TxnArgs = struct {
    ctx: *EbrContext,
    a: *versioned.Versioned(i64),
    b: *versioned.Versioned(i64),
    iters: usize,
    seed: u64,
    failed: *std.atomic.Value(usize),
};

fn txnTransferThread(args: *TxnArgs) void {
    var frame: [4096]u8 = undefined;
    var rt = Runtime.initFromSlice(&frame, args.ctx, stressAllocator(), 0) catch return;
    defer rt.deinit();
    args.ctx.register(stressAllocator(), rt.ebr) catch return;
    defer args.ctx.unregister(rt.ebr);

    var prng = std.Random.DefaultPrng.init(args.seed);
    const rng = prng.random();

    var i: usize = 0;
    while (i < args.iters) : (i += 1) {
        const amount: i64 = @intCast(rng.intRangeAtMost(u32, 1, 5));
        // Half of the calls pass cells in (a, b); half in (b, a).
        // Sorted commit means both produce the same address-ordered
        // commit -- this exercises the ABBA path under load.
        const reverse = (rng.int(u8) & 1) == 1;
        const Helper = struct {
            fn forward(views: anytype, amt: i64) anyerror!void {
                views[0].* -= amt;
                views[1].* += amt;
            }
            fn reverse_(views: anytype, amt: i64) anyerror!void {
                views[0].* += amt;
                views[1].* -= amt;
            }
        };
        const result = if (reverse)
            versioned.updateMulti(.{ args.b, args.a }, &rt, stressAllocator(), Helper.reverse_, .{amount})
        else
            versioned.updateMulti(.{ args.a, args.b }, &rt, stressAllocator(), Helper.forward, .{amount});
        result catch |err| switch (err) {
            // Retry-budget exhaustion is a contention signal, not an
            // invariant break. The 64-retry default (post-True-Sync-
            // Polymorphism #330) is reachable under TSan slowdown with
            // 4 writers contending the same cell-pair; the writer is
            // expected to back off and try again at a higher level.
            // Don't conflate it with a torn-state failure.
            error.UpdateRetriesExhausted => continue,
            else => {
                _ = args.failed.fetchAdd(1, .seq_cst);
                continue;
            },
        };
        if ((i & 0xFFF) == 0xFFF) {
            rt.ebr.reclaimLocal(stressAllocator());
            args.ctx.reclaim(stressAllocator());
        }
    }
}

const TxnReaderArgs = struct {
    ctx: *EbrContext,
    a: *versioned.Versioned(i64),
    b: *versioned.Versioned(i64),
    iters: usize,
    expected_total: i64,
    violations: *std.atomic.Value(usize),
};

fn txnReaderThread(args: *TxnReaderArgs) void {
    var frame: [4096]u8 = undefined;
    var rt = Runtime.initFromSlice(&frame, args.ctx, stressAllocator(), 0) catch return;
    defer rt.deinit();
    args.ctx.register(stressAllocator(), rt.ebr) catch return;
    defer args.ctx.unregister(rt.ebr);

    var i: usize = 0;
    while (i < args.iters) : (i += 1) {
        // To check the cross-cell invariant atomically we need a
        // snapshot taken across BOTH cells under one barrier.
        // `updateMulti` provides exactly that: it acquires tags on
        // every cell in sorted order, so during the body no other
        // writer can mid-commit. We use a no-op body that reads
        // both views and captures their sum. The "write" publishes
        // new ptrs identical to the old values -- functionally a
        // no-op, but it's sufficient to verify that the per-cell
        // invariant holds across N writers.
        //
        // (When CLEAR exposes `WITH SNAPSHOT a, b` as a pure read
        // with multi-cell semantics, this will lower to a similar
        // OCC pattern under the hood.)
        const ReadCheck = struct {
            fn run(views: anytype, expected: i64, vio: *std.atomic.Value(usize)) anyerror!void {
                if (views[0].* + views[1].* != expected) {
                    _ = vio.fetchAdd(1, .seq_cst);
                }
            }
        };
        versioned.updateMulti(.{ args.a, args.b }, &rt, stressAllocator(), ReadCheck.run, .{ args.expected_total, args.violations }) catch |err| switch (err) {
            // Same rationale as the writer side: 64-retry exhaustion is
            // a contention signal, not a torn-snapshot. Only the
            // ReadCheck.run body's vio.fetchAdd is authoritative for
            // the a+b invariant; that path runs INSIDE updateMulti
            // under all N tags held, where any inconsistency would be
            // a real correctness bug.
            error.UpdateRetriesExhausted => continue,
            else => _ = args.violations.fetchAdd(1, .seq_cst),
        };
        if ((i & 0xFFF) == 0xFFF) rt.ebr.reclaimLocal(stressAllocator());
    }
}

test "updateMulti: 4 writers + 2 readers preserve a + b invariant" {
    var ctx = EbrContext{};
    defer ctx.deinit(stressAllocator());

    var main_frame: [4096]u8 = undefined;
    var main_rt = try Runtime.initFromSlice(&main_frame, &ctx, stressAllocator(), 0);
    defer main_rt.deinit();
    try ctx.register(stressAllocator(), main_rt.ebr);
    defer ctx.unregister(main_rt.ebr);

    var a = try versioned.Versioned(i64).init(stressAllocator(), 500);
    defer {
        a.deinit(&main_rt, stressAllocator()) catch unreachable;
        drain(&ctx, &main_rt);
    }
    var b = try versioned.Versioned(i64).init(stressAllocator(), 500);
    defer {
        b.deinit(&main_rt, stressAllocator()) catch unreachable;
        drain(&ctx, &main_rt);
    }
    const TOTAL: i64 = 1000;

    var failed = std.atomic.Value(usize).init(0);
    var violations = std.atomic.Value(usize).init(0);

    const W_ITERS = 2_000;
    const R_ITERS = 5_000;

    var w1 = TxnArgs{ .ctx = &ctx, .a = &a, .b = &b, .iters = W_ITERS, .seed = 1, .failed = &failed };
    var w2 = TxnArgs{ .ctx = &ctx, .a = &a, .b = &b, .iters = W_ITERS, .seed = 2, .failed = &failed };
    var w3 = TxnArgs{ .ctx = &ctx, .a = &a, .b = &b, .iters = W_ITERS, .seed = 3, .failed = &failed };
    var w4 = TxnArgs{ .ctx = &ctx, .a = &a, .b = &b, .iters = W_ITERS, .seed = 4, .failed = &failed };
    var r1 = TxnReaderArgs{ .ctx = &ctx, .a = &a, .b = &b, .iters = R_ITERS, .expected_total = TOTAL, .violations = &violations };
    var r2 = TxnReaderArgs{ .ctx = &ctx, .a = &a, .b = &b, .iters = R_ITERS, .expected_total = TOTAL, .violations = &violations };

    const tw1 = try std.Thread.spawn(.{}, txnTransferThread, .{&w1});
    const tw2 = try std.Thread.spawn(.{}, txnTransferThread, .{&w2});
    const tw3 = try std.Thread.spawn(.{}, txnTransferThread, .{&w3});
    const tw4 = try std.Thread.spawn(.{}, txnTransferThread, .{&w4});
    const tr1 = try std.Thread.spawn(.{}, txnReaderThread, .{&r1});
    const tr2 = try std.Thread.spawn(.{}, txnReaderThread, .{&r2});

    tw1.join();
    tw2.join();
    tw3.join();
    tw4.join();
    tr1.join();
    tr2.join();

    try testing.expectEqual(@as(usize, 0), violations.load(.seq_cst));
    try testing.expectEqual(@as(usize, 0), failed.load(.seq_cst));

    // Sanity: post-test, total still preserved.
    var ga = a.read(&main_rt);
    defer ga.release();
    var gb = b.read(&main_rt);
    defer gb.release();
    try testing.expectEqual(TOTAL, ga.get().* + gb.get().*);
}

test "updateMulti: single-cell update racing multi-cell commit -- no torn state" {
    // Mixes single-cell `update` and multi-cell `updateMulti` on the
    // same cells. The tagged-pointer protocol must keep them
    // non-overlapping: single-cell spins past the tag, multi-cell
    // CAS-detects the single-cell race and retries.
    var ctx = EbrContext{};
    defer ctx.deinit(stressAllocator());

    var main_frame: [4096]u8 = undefined;
    var main_rt = try Runtime.initFromSlice(&main_frame, &ctx, stressAllocator(), 0);
    defer main_rt.deinit();
    try ctx.register(stressAllocator(), main_rt.ebr);
    defer ctx.unregister(main_rt.ebr);

    var a = try versioned.Versioned(i64).init(stressAllocator(), 0);
    defer {
        a.deinit(&main_rt, stressAllocator()) catch unreachable;
        drain(&ctx, &main_rt);
    }
    var b = try versioned.Versioned(i64).init(stressAllocator(), 0);
    defer {
        b.deinit(&main_rt, stressAllocator()) catch unreachable;
        drain(&ctx, &main_rt);
    }

    var failed = std.atomic.Value(usize).init(0);

    const ITERS = 2_000;

    const SingleArgs = struct {
        ctx: *EbrContext,
        s: *versioned.Versioned(i64),
        iters: usize,
        failed: *std.atomic.Value(usize),
    };
    const single_thread = struct {
        fn run(sa: *SingleArgs) void {
            var frame: [4096]u8 = undefined;
            var rt = Runtime.initFromSlice(&frame, sa.ctx, stressAllocator(), 0) catch return;
            defer rt.deinit();
            sa.ctx.register(stressAllocator(), rt.ebr) catch return;
            defer sa.ctx.unregister(rt.ebr);
            var i: usize = 0;
            while (i < sa.iters) : (i += 1) {
                sa.s.update(&rt, stressAllocator(), struct {
                    fn inc(p: *i64, _: u8) void {
                        p.* += 1;
                    }
                }.inc, .{@as(u8, 0)}) catch |err| switch (err) {
                    error.UpdateRetriesExhausted => {},
                    else => _ = sa.failed.fetchAdd(1, .seq_cst),
                };
                if ((i & 0xFFF) == 0xFFF) rt.ebr.reclaimLocal(stressAllocator());
            }
        }
    }.run;

    var sa1 = SingleArgs{ .ctx = &ctx, .s = &a, .iters = ITERS, .failed = &failed };
    var sb1 = SingleArgs{ .ctx = &ctx, .s = &b, .iters = ITERS, .failed = &failed };
    var multi_args = TxnArgs{ .ctx = &ctx, .a = &a, .b = &b, .iters = ITERS, .seed = 99, .failed = &failed };

    const ts1 = try std.Thread.spawn(.{}, single_thread, .{&sa1});
    const ts2 = try std.Thread.spawn(.{}, single_thread, .{&sb1});
    const tm = try std.Thread.spawn(.{}, txnTransferThread, .{&multi_args});

    ts1.join();
    ts2.join();
    tm.join();

    // No fatal failures.
    try testing.expectEqual(@as(usize, 0), failed.load(.seq_cst));

    // Post-test sanity: cells reflect single-cell increments + zero-net
    // multi-cell transfers (since each transfer is +x to one and -x to
    // the other, the multi-cell run preserves a + b - 2*ITERS).
    var ga = a.read(&main_rt);
    defer ga.release();
    var gb = b.read(&main_rt);
    defer gb.release();
    try testing.expectEqual(@as(i64, 2 * ITERS), ga.get().* + gb.get().*);
}

// ============================================================
// Gap 4: high-contention retry stress on Versioned.update
// ============================================================
//
// `update()` allocates the new T node ONCE outside the CAS retry
// loop and frees it via `defer if (!success) destroy(new_ptr)`
// (H1 fix). On `error.UpdateRetriesExhausted`, that defer runs.
//
// The single-thread H2 test in versioned-test.zig only verifies
// the error type is well-formed; it can't trigger the path. The
// existing 1+4-writer chaos test asserts `failed == 0`, so it
// also can't validate the exhaustion path runs leak-free.
//
// This test: 32 writer threads all hammer one cell with a no-op
// mutator. Some writers will lose enough CAS races to hit the
// 10K retry cap and return UpdateRetriesExhausted. We assert
// the test exits leak-free regardless of how many writers fail —
// the DebugAllocator catches a forgotten new_ptr.
//
// Reports the `failed_updates` count for visibility. A 0 count
// means the system was too fast for any single writer to lose
// 10K races in a row; the test still validates the contention
// path is leak-free, which is the primary safety property.

test "Versioned(i64): retry-path leak safety under 32-writer pathological contention" {
    var ctx = EbrContext{};
    defer ctx.deinit(stressAllocator());

    var main_frame: [4096]u8 = undefined;
    var main_rt = try Runtime.initFromSlice(&main_frame, &ctx, stressAllocator(), 0);
    defer main_rt.deinit();
    try ctx.register(stressAllocator(), main_rt.ebr);
    defer ctx.unregister(main_rt.ebr);

    var s = try versioned.Versioned(i64).init(stressAllocator(), 0);
    defer {
        s.deinit(&main_rt, stressAllocator()) catch unreachable;
        drain(&ctx, &main_rt);
    }

    var failed = std.atomic.Value(usize).init(0);
    var attempted = std.atomic.Value(usize).init(0);

    // 32 writers x 200 iters each = 6400 update attempts. With a
    // no-op mutator, the inner CAS loop is "load -> mutate -> CAS",
    // ~10ns per pass. 31 contending writers means each writer
    // typically loses 30 in a row before winning. The retry budget
    // is 10K, so a writer needs to be *very* unlucky to exhaust —
    // but it does happen on busy/loaded systems, and that's exactly
    // the tail we want to exercise.
    const N_WRITERS = 32;
    const ITERS_PER_WRITER = 200;

    const Args = struct {
        ctx: *EbrContext,
        s: *versioned.Versioned(i64),
        iters: usize,
        failed: *std.atomic.Value(usize),
        attempted: *std.atomic.Value(usize),
    };

    const writer_fn = struct {
        fn run(args: *Args) void {
            var frame: [4096]u8 = undefined;
            var rt = Runtime.initFromSlice(&frame, args.ctx, stressAllocator(), 0) catch return;
            defer rt.deinit();
            args.ctx.register(stressAllocator(), rt.ebr) catch return;
            defer args.ctx.unregister(rt.ebr);

            var i: usize = 0;
            while (i < args.iters) : (i += 1) {
                _ = args.attempted.fetchAdd(1, .monotonic);
                args.s.update(&rt, stressAllocator(), struct {
                    fn inc(p: *i64, _: u8) void {
                        p.* += 1;
                    }
                }.inc, .{@as(u8, 0)}) catch |e| {
                    // The ONLY error we expect under pathological
                    // contention. Allocator failures shouldn't fire
                    // on the test allocator at this size.
                    std.debug.assert(e == error.UpdateRetriesExhausted);
                    _ = args.failed.fetchAdd(1, .seq_cst);
                };
                if ((i & 0x1F) == 0x1F) rt.ebr.reclaimLocal(stressAllocator());
            }
        }
    }.run;

    var args_arr: [N_WRITERS]Args = undefined;
    var threads: [N_WRITERS]std.Thread = undefined;
    for (0..N_WRITERS) |i| {
        args_arr[i] = .{
            .ctx = &ctx,
            .s = &s,
            .iters = ITERS_PER_WRITER,
            .failed = &failed,
            .attempted = &attempted,
        };
        threads[i] = try std.Thread.spawn(.{}, writer_fn, .{&args_arr[i]});
    }
    for (&threads) |t| t.join();

    const total_attempted = attempted.load(.seq_cst);
    const total_failed = failed.load(.seq_cst);

    // Sanity: every writer ran to completion.
    try testing.expectEqual(N_WRITERS * ITERS_PER_WRITER, total_attempted);

    // The cell value reflects exactly the number of successful updates
    // (each successful update increments by 1). This catches lost
    // increments — if the retry-path leaked a new_ptr while still
    // succeeding, this would still pass; but combined with the
    // DebugAllocator leak check it pins both axes.
    var g = s.read(&main_rt);
    defer g.release();
    const cell_value = @as(usize, @intCast(g.get().*));
    try testing.expectEqual(total_attempted - total_failed, cell_value);

    // For visibility: report how many exhaustion errors fired.
    // A non-zero count means the retry path actually ran AND was
    // leak-free (the DebugAllocator at test exit would catch any
    // new_ptr that didn't get freed via the success defer).
    if (total_failed > 0) {
        std.debug.print(
            "\n  retry-exhaustion path exercised: {d}/{d} updates returned error.UpdateRetriesExhausted (leak-free)\n",
            .{ total_failed, total_attempted },
        );
    }
}
