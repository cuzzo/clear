//! Observable runtime microbenchmark.
//!
//! Isolates the perf gap between CLEAR's `obs.AtomicSum(T)` and the
//! raw `std.atomic.Value(T)` that backs Go's `atomic.Int64` and Rust's
//! `AtomicI64`. Same workload as bench.go/bench.rs/bench_clear.zig:
//! 1 writer + K readers, N=5_000_000 increments.
//!
//! Reports writer ns/inc and reader reads/sec for both variants.
//! Run via:
//!   zig build-exe --dep obs --dep compat \
//!     -Mroot=observable-microbench.zig \
//!     -Mobs=lib/observable.zig -Mcompat=lib/compat.zig \
//!     -lc -OReleaseFast --name obsmb
//!   ./obsmb

const std = @import("std");
const obs = @import("obs");
const compat = @import("compat");

const N_WRITES: usize = 5_000_000;
const READER_COUNTS = [_]usize{ 1, 2, 4, 8, 16, 31 };

// ============================================================
// CLEAR obs.AtomicSum baseline
// ============================================================

const ObsCtx = struct {
    counter: *obs.AtomicSum(i64),
    iters: usize,
    stop: *std.atomic.Value(u8),
};
fn obs_writer(ctx: ObsCtx) void {
    var i: usize = 0;
    while (i < ctx.iters) : (i += 1) ctx.counter.add(1);
    ctx.stop.store(1, .release);
}

const ObsRR = struct { n_reads: usize = 0, sink: i64 = 0 };
const ObsRC = struct {
    counter: *obs.AtomicSum(i64),
    stop: *std.atomic.Value(u8),
    out: *ObsRR,
};
fn obs_reader(ctx: *const ObsRC) void {
    const counter = ctx.counter;
    const stop = ctx.stop;
    var n: usize = 0;
    var sink: i64 = 0;
    while (stop.load(.acquire) == 0) : (n +%= 1) {
        sink ^= counter.view();
    }
    ctx.out.n_reads = n;
    ctx.out.sink = sink;
}

fn run_obs(allocator: std.mem.Allocator, n_readers: usize) !void {
    var counter = obs.AtomicSum(i64){};
    var stop = std.atomic.Value(u8).init(0);
    const results = try allocator.alloc(ObsRR, n_readers);
    defer allocator.free(results);
    for (results) |*r| r.* = .{};
    const threads = try allocator.alloc(std.Thread, n_readers);
    defer allocator.free(threads);
    const ctxs = try allocator.alloc(ObsRC, n_readers);
    defer allocator.free(ctxs);

    var t0 = try compat.Timer.start();
    for (threads, 0..) |*th, i| {
        ctxs[i] = .{ .counter = &counter, .stop = &stop, .out = &results[i] };
        th.* = try std.Thread.spawn(.{}, obs_reader, .{&ctxs[i]});
    }
    const writer = try std.Thread.spawn(.{}, obs_writer, .{ObsCtx{
        .counter = &counter, .iters = N_WRITES, .stop = &stop,
    }});
    writer.join();
    for (threads) |th| th.join();
    const elapsed = t0.read();

    var total: usize = 0;
    var sink_sum: i64 = 0;
    for (results) |r| { total += r.n_reads; sink_sum ^= r.sink; }
    if (sink_sum == 0xdeadbeef) std.debug.print("  (sink check)\n", .{});
    const ns_per_inc = elapsed / N_WRITES;
    const rps = if (elapsed == 0) 0 else (total * 1_000_000_000) / elapsed;
    std.debug.print("[obs.AtomicSum]   writer={d:>3} ns/inc readers={d}  reads={d:>11}  reads/sec={d}\n",
        .{ ns_per_inc, n_readers, total, rps });
}

// ============================================================
// Raw std.atomic.Value(i64) — equivalent to Go atomic.Int64 / Rust AtomicI64
// ============================================================

const RawCtx = struct {
    counter: *std.atomic.Value(i64),
    iters: usize,
    stop: *std.atomic.Value(u8),
};
fn raw_writer(ctx: RawCtx) void {
    var i: usize = 0;
    while (i < ctx.iters) : (i += 1) _ = ctx.counter.fetchAdd(1, .monotonic);
    ctx.stop.store(1, .release);
}

const RawRC = struct {
    counter: *std.atomic.Value(i64),
    stop: *std.atomic.Value(u8),
    out: *ObsRR,
};
fn raw_reader(ctx: *const RawRC) void {
    const counter = ctx.counter;
    const stop = ctx.stop;
    var n: usize = 0;
    var sink: i64 = 0;
    while (stop.load(.acquire) == 0) : (n +%= 1) {
        sink ^= counter.load(.acquire);
    }
    ctx.out.n_reads = n;
    ctx.out.sink = sink;
}

fn run_raw(allocator: std.mem.Allocator, n_readers: usize) !void {
    var counter = std.atomic.Value(i64).init(0);
    var stop = std.atomic.Value(u8).init(0);
    const results = try allocator.alloc(ObsRR, n_readers);
    defer allocator.free(results);
    for (results) |*r| r.* = .{};
    const threads = try allocator.alloc(std.Thread, n_readers);
    defer allocator.free(threads);
    const ctxs = try allocator.alloc(RawRC, n_readers);
    defer allocator.free(ctxs);

    var t0 = try compat.Timer.start();
    for (threads, 0..) |*th, i| {
        ctxs[i] = .{ .counter = &counter, .stop = &stop, .out = &results[i] };
        th.* = try std.Thread.spawn(.{}, raw_reader, .{&ctxs[i]});
    }
    const writer = try std.Thread.spawn(.{}, raw_writer, .{RawCtx{
        .counter = &counter, .iters = N_WRITES, .stop = &stop,
    }});
    writer.join();
    for (threads) |th| th.join();
    const elapsed = t0.read();

    var total: usize = 0;
    var sink_sum: i64 = 0;
    for (results) |r| { total += r.n_reads; sink_sum ^= r.sink; }
    if (sink_sum == 0xdeadbeef) std.debug.print("  (sink check)\n", .{});
    const ns_per_inc = elapsed / N_WRITES;
    const rps = if (elapsed == 0) 0 else (total * 1_000_000_000) / elapsed;
    std.debug.print("[atomic.Value]    writer={d:>3} ns/inc readers={d}  reads={d:>11}  reads/sec={d}\n",
        .{ ns_per_inc, n_readers, total, rps });
}

// ============================================================
// Writer-only (no reader contention): isolates the per-add cost.
// ============================================================

fn writer_only_obs(N: usize) !u64 {
    var counter = obs.AtomicSum(i64){};
    var t0 = try compat.Timer.start();
    var i: usize = 0;
    while (i < N) : (i += 1) counter.add(1);
    return t0.read();
}
fn writer_only_raw(N: usize) !u64 {
    var counter = std.atomic.Value(i64).init(0);
    var t0 = try compat.Timer.start();
    var i: usize = 0;
    while (i < N) : (i += 1) _ = counter.fetchAdd(1, .monotonic);
    return t0.read();
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Observable microbench  N={d} writes\n\n", .{N_WRITES});

    std.debug.print("--- Writer-only (no readers) ---\n", .{});
    {
        const elapsed = try writer_only_obs(N_WRITES);
        std.debug.print("  obs.AtomicSum    {d:>3} ns/inc total={d}ms\n", .{ elapsed / N_WRITES, elapsed / 1_000_000 });
    }
    {
        const elapsed = try writer_only_raw(N_WRITES);
        std.debug.print("  atomic.Value     {d:>3} ns/inc total={d}ms\n", .{ elapsed / N_WRITES, elapsed / 1_000_000 });
    }

    std.debug.print("\n--- CLEAR obs.AtomicSum (1 writer + K readers) ---\n", .{});
    for (READER_COUNTS) |k| try run_obs(allocator, k);
    std.debug.print("\n--- raw std.atomic.Value (Go atomic.Int64 / Rust AtomicI64 equivalent) ---\n", .{});
    for (READER_COUNTS) |k| try run_raw(allocator, k);
}
