//! Multi-threaded stress test for AtomicPtr(T).
//!
//! Mirrors versioned-stress-test.zig's strategy: spawn N reader threads
//! + M writer threads. Each thread runs its own ThreadLocalEbr
//! registered against the shared EbrContext. Readers verify the
//! payload's structural invariant on every read (`b == a * 2`);
//! writers update via rcu; periodic reclaim flushes retired pointers.
//!
//! What this catches:
//!   - Torn reads under .monotonic load (validates the .acquire on
//!     `read()`).
//!   - UAF on a concurrent reader holding a Guard while another path
//!     retires/reclaims (validates the EBR-retire contract in
//!     `compareAndPublish` and `update`).
//!   - Lost / leaked retires under CAS contention.
//!   - Reclamation stuck because the active-thread check misses a
//!     concurrent reader.
//!
//! DebugAllocator (`testing.allocator`) catches any pointer that
//! survives `ctx.deinit`, so leaks show up as test failures.

const std = @import("std");
const testing = std.testing;

const ebr_mod = @import("../lib/ebr.zig");
const atomic_ptr = @import("../lib/atomic_ptr.zig");

const EbrContext = ebr_mod.EbrContext;
const ThreadLocalEbr = ebr_mod.ThreadLocalEbr;
const AtomicPtr = atomic_ptr.AtomicPtr;

// =====================================================================
// Shared payload with a structural invariant
// =====================================================================
// Writer flips both fields in lock-step inside the rcu closure so a
// torn read (mismatched a / b) is the trip-wire that catches an
// ordering regression. The whole-T copy in `update`'s clone+func
// step preserves the invariant per published snapshot.

const Sample = struct {
    a: i64,
    b: i64,
};

fn writeSample(p: *Sample, n: i64) void {
    p.a = n;
    p.b = n * 2;
}

// =====================================================================
// Per-thread fixtures
// =====================================================================

const ReaderArgs = struct {
    ctx: *EbrContext,
    cell: *AtomicPtr(Sample),
    iters: usize,
    invariant_violations: *std.atomic.Value(usize),
};

fn readerThread(args: *ReaderArgs) void {
    var tle = ThreadLocalEbr{ .context = args.ctx };
    args.ctx.register(testing.allocator, &tle) catch |err| {
        std.debug.print("readerThread: register failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer args.ctx.unregister(&tle);
    defer tle.deinit(testing.allocator);

    var i: usize = 0;
    while (i < args.iters) : (i += 1) {
        var g = args.cell.read(&tle);
        const view = g.get().*;
        if (view.b != view.a * 2) {
            _ = args.invariant_violations.fetchAdd(1, .seq_cst);
        }
        g.release();

        // Periodic local reclaim to bound limbo across long runs.
        if ((i & 0xFFF) == 0xFFF) tle.reclaimLocal(testing.allocator);
    }
}

const WriterArgs = struct {
    ctx: *EbrContext,
    cell: *AtomicPtr(Sample),
    iters: usize,
    base: i64,
    failed_updates: *std.atomic.Value(usize),
};

fn writerThread(args: *WriterArgs) void {
    var tle = ThreadLocalEbr{ .context = args.ctx };
    args.ctx.register(testing.allocator, &tle) catch |err| {
        std.debug.print("writerThread: register failed: {s}\n", .{@errorName(err)});
        return;
    };
    defer args.ctx.unregister(&tle);
    defer tle.deinit(testing.allocator);

    var i: usize = 0;
    while (i < args.iters) : (i += 1) {
        const v = args.base + @as(i64, @intCast(i));
        args.cell.update(&tle, testing.allocator, writeSample, .{v}) catch {
            _ = args.failed_updates.fetchAdd(1, .seq_cst);
            continue;
        };

        // Drive global reclaim periodically so retired pointers do
        // not accumulate indefinitely. Cheap: only swept when the
        // global epoch can be safely advanced.
        if ((i & 0xFF) == 0xFF) args.ctx.reclaim(testing.allocator);
    }
}

// =====================================================================
// Tests
// =====================================================================

test "AtomicPtr stress: 4 readers + 2 writers, 50K reads / 10K updates each, no torn reads, no leaks" {
    var ctx = EbrContext{};
    var cell = try AtomicPtr(Sample).init(testing.allocator, .{ .a = 0, .b = 0 });

    var invariant_violations = std.atomic.Value(usize).init(0);
    var failed_updates = std.atomic.Value(usize).init(0);

    const reader_count: usize = 4;
    const writer_count: usize = 2;
    const reader_iters: usize = 50_000;
    const writer_iters: usize = 10_000;

    var reader_args: [4]ReaderArgs = undefined;
    var writer_args: [2]WriterArgs = undefined;
    var reader_threads: [4]std.Thread = undefined;
    var writer_threads: [2]std.Thread = undefined;

    var i: usize = 0;
    while (i < reader_count) : (i += 1) {
        reader_args[i] = .{
            .ctx = &ctx,
            .cell = &cell,
            .iters = reader_iters,
            .invariant_violations = &invariant_violations,
        };
        reader_threads[i] = try std.Thread.spawn(.{}, readerThread, .{&reader_args[i]});
    }

    var w: usize = 0;
    while (w < writer_count) : (w += 1) {
        writer_args[w] = .{
            .ctx = &ctx,
            .cell = &cell,
            .iters = writer_iters,
            .base = @as(i64, @intCast(w)) * 1_000_000,
            .failed_updates = &failed_updates,
        };
        writer_threads[w] = try std.Thread.spawn(.{}, writerThread, .{&writer_args[w]});
    }

    for (reader_threads) |t| t.join();
    for (writer_threads) |t| t.join();

    // No torn reads.
    try testing.expectEqual(@as(usize, 0), invariant_violations.load(.seq_cst));
    // rcu is unbounded — no failed updates expected (the only failure
    // mode would be allocator OOM, which DebugAllocator wouldn't
    // surface in this test profile).
    try testing.expectEqual(@as(usize, 0), failed_updates.load(.seq_cst));

    // Teardown. Every thread already unregistered + deinit'd its TLE,
    // so any retire still in limbo lives on ctx.orphans (drained by
    // ctx.deinit) -- assuming the unregister path migrated them.
    cell.deinitSync(testing.allocator);
    ctx.deinit(testing.allocator);
}

test "AtomicPtr stress: many short reader tasks against one writer (read-heavy)" {
    // Read-heavy profile: 8 readers, 1 writer. Validates the read
    // path's contention behaviour (every load must complete; writer
    // sees a steady drumbeat of EBR pins).
    var ctx = EbrContext{};
    var cell = try AtomicPtr(Sample).init(testing.allocator, .{ .a = 0, .b = 0 });

    var invariant_violations = std.atomic.Value(usize).init(0);
    var failed_updates = std.atomic.Value(usize).init(0);

    const reader_count: usize = 8;
    const reader_iters: usize = 100_000;
    const writer_iters: usize = 5_000;

    var reader_args: [8]ReaderArgs = undefined;
    var writer_args: [1]WriterArgs = undefined;
    var reader_threads: [8]std.Thread = undefined;
    var writer_threads: [1]std.Thread = undefined;

    var i: usize = 0;
    while (i < reader_count) : (i += 1) {
        reader_args[i] = .{
            .ctx = &ctx,
            .cell = &cell,
            .iters = reader_iters,
            .invariant_violations = &invariant_violations,
        };
        reader_threads[i] = try std.Thread.spawn(.{}, readerThread, .{&reader_args[i]});
    }

    writer_args[0] = .{
        .ctx = &ctx,
        .cell = &cell,
        .iters = writer_iters,
        .base = 100,
        .failed_updates = &failed_updates,
    };
    writer_threads[0] = try std.Thread.spawn(.{}, writerThread, .{&writer_args[0]});

    for (reader_threads) |t| t.join();
    for (writer_threads) |t| t.join();

    try testing.expectEqual(@as(usize, 0), invariant_violations.load(.seq_cst));
    try testing.expectEqual(@as(usize, 0), failed_updates.load(.seq_cst));

    cell.deinitSync(testing.allocator);
    ctx.deinit(testing.allocator);
}

test "AtomicPtr stress: write-heavy — 1 reader, 4 writers (CAS contention path)" {
    // Write-heavy profile: 4 writers all racing on the SAME cell. Each
    // CAS-success retires the prior pointer; CAS-failures retry. The
    // single reader holds Guards across the CAS storm to prove the
    // EBR pin still keeps a snapshot alive even under heavy contention.
    var ctx = EbrContext{};
    var cell = try AtomicPtr(Sample).init(testing.allocator, .{ .a = 0, .b = 0 });

    var invariant_violations = std.atomic.Value(usize).init(0);
    var failed_updates = std.atomic.Value(usize).init(0);

    const reader_iters: usize = 20_000;
    const writer_iters: usize = 25_000;

    var reader_args: [1]ReaderArgs = undefined;
    var writer_args: [4]WriterArgs = undefined;
    var reader_threads: [1]std.Thread = undefined;
    var writer_threads: [4]std.Thread = undefined;

    reader_args[0] = .{
        .ctx = &ctx,
        .cell = &cell,
        .iters = reader_iters,
        .invariant_violations = &invariant_violations,
    };
    reader_threads[0] = try std.Thread.spawn(.{}, readerThread, .{&reader_args[0]});

    var w: usize = 0;
    while (w < 4) : (w += 1) {
        writer_args[w] = .{
            .ctx = &ctx,
            .cell = &cell,
            .iters = writer_iters,
            .base = @as(i64, @intCast(w)) * 1_000_000,
            .failed_updates = &failed_updates,
        };
        writer_threads[w] = try std.Thread.spawn(.{}, writerThread, .{&writer_args[w]});
    }

    for (reader_threads) |t| t.join();
    for (writer_threads) |t| t.join();

    try testing.expectEqual(@as(usize, 0), invariant_violations.load(.seq_cst));
    try testing.expectEqual(@as(usize, 0), failed_updates.load(.seq_cst));

    cell.deinitSync(testing.allocator);
    ctx.deinit(testing.allocator);
}
