//! Benchmarks for the MVCC primitives:
//!   - Versioned(T) read throughput (1 / 4 / 16 readers)
//!   - Versioned(T) write throughput under CAS contention (1 / 4 / 8 writers)
//!   - Mixed workload (readers + writers concurrently)
//!   - Reclaim overhead (cost of EbrContext.reclaim per call)
//!
//! Run:  zig build benchmark   (the wrapper file lands in build.zig's
//!                              benchmark step alongside parking-lot's
//!                              benchmarks).
//!
//! Output: ms wall-clock per cell + ops/sec. Lower ms is better.
//! These are reference numbers, not regression gates -- machine-
//! dependent. The takeaway is the SHAPE of the numbers (read scales
//! linearly with cores; writes degrade at high contention).

const std = @import("std");
const testing = std.testing;
const compat = @import("../lib/compat.zig");

const ebr_mod = @import("../lib/ebr.zig");
const versioned = @import("versioned.zig");
const Runtime = @import("runtime.zig").Runtime;

const EbrContext = ebr_mod.EbrContext;
const ThreadLocalEbr = ebr_mod.ThreadLocalEbr;

const Sample = struct {
    a: i64,
    b: i64,
};

fn writeSample(p: *Sample, n: i64) void {
    p.a = n;
    p.b = n * 2;
}

const allocator = std.heap.page_allocator;

// ============================================================
// Read throughput
// ============================================================

const ReadBenchArgs = struct {
    ctx: *EbrContext,
    s: *versioned.Versioned(Sample),
    iters: usize,
    sink: *std.atomic.Value(i64),
};

fn readerWorker(args: *ReadBenchArgs) void {
    var frame: [4096]u8 = undefined;
    var rt = Runtime.initFromSlice(&frame, args.ctx, allocator, 0) catch return;
    defer rt.deinit();
    args.ctx.register(allocator, rt.ebr) catch return;
    defer args.ctx.unregister(rt.ebr);

    var local_acc: i64 = 0;
    var i: usize = 0;
    while (i < args.iters) : (i += 1) {
        var g = args.s.read(&rt);
        local_acc +%= g.get().a;
        g.release();
    }
    _ = args.sink.fetchAdd(local_acc, .monotonic);
}

fn benchReadThroughput(n_readers: usize, ops_per_reader: usize) !u64 {
    var ctx = EbrContext{};
    defer ctx.deinit(allocator);

    var main_frame: [4096]u8 = undefined;
    var main_rt = try Runtime.initFromSlice(&main_frame, &ctx, allocator, 0);
    defer main_rt.deinit();
    try ctx.register(allocator, main_rt.ebr);
    defer ctx.unregister(main_rt.ebr);

    var s = try versioned.Versioned(Sample).init(allocator, .{ .a = 7, .b = 14 });
    defer {
        s.deinit(&main_rt, allocator) catch unreachable;
        var k: usize = 0;
        while (k < 6) : (k += 1) {
            ctx.reclaim(allocator);
            main_rt.ebr.reclaimLocal(allocator);
        }
    }

    var sink = std.atomic.Value(i64).init(0);
    const threads = try allocator.alloc(std.Thread, n_readers);
    defer allocator.free(threads);
    const args = try allocator.alloc(ReadBenchArgs, n_readers);
    defer allocator.free(args);

    for (args) |*a| a.* = .{ .ctx = &ctx, .s = &s, .iters = ops_per_reader, .sink = &sink };

    var timer = try compat.Timer.start();
    for (threads, args) |*t, *a| {
        t.* = try std.Thread.spawn(.{}, readerWorker, .{a});
    }
    for (threads) |t| t.join();
    const elapsed_ns = timer.read();

    // Prevent the compiler from optimizing the workload away.
    std.mem.doNotOptimizeAway(sink.load(.monotonic));
    return elapsed_ns;
}

// ============================================================
// Write throughput under contention
// ============================================================

const WriteBenchArgs = struct {
    ctx: *EbrContext,
    s: *versioned.Versioned(Sample),
    iters: usize,
    base: i64,
};

fn writerWorker(args: *WriteBenchArgs) void {
    var frame: [4096]u8 = undefined;
    var rt = Runtime.initFromSlice(&frame, args.ctx, allocator, 0) catch return;
    defer rt.deinit();
    args.ctx.register(allocator, rt.ebr) catch return;
    defer args.ctx.unregister(rt.ebr);

    var i: usize = 0;
    while (i < args.iters) : (i += 1) {
        const v = args.base + @as(i64, @intCast(i));
        args.s.update(&rt, allocator, writeSample, .{v}) catch continue;
        // Reclaim periodically so limbo doesn't grow without bound
        // and skew the timing with allocator pressure.
        if ((i & 0xFFF) == 0xFFF) {
            rt.ebr.reclaimLocal(allocator);
            args.ctx.reclaim(allocator);
        }
    }
}

fn benchWriteThroughput(n_writers: usize, ops_per_writer: usize) !u64 {
    var ctx = EbrContext{};
    defer ctx.deinit(allocator);

    var main_frame: [4096]u8 = undefined;
    var main_rt = try Runtime.initFromSlice(&main_frame, &ctx, allocator, 0);
    defer main_rt.deinit();
    try ctx.register(allocator, main_rt.ebr);
    defer ctx.unregister(main_rt.ebr);

    var s = try versioned.Versioned(Sample).init(allocator, .{ .a = 0, .b = 0 });
    defer {
        s.deinit(&main_rt, allocator) catch unreachable;
        var k: usize = 0;
        while (k < 6) : (k += 1) {
            ctx.reclaim(allocator);
            main_rt.ebr.reclaimLocal(allocator);
        }
    }

    const threads = try allocator.alloc(std.Thread, n_writers);
    defer allocator.free(threads);
    const args = try allocator.alloc(WriteBenchArgs, n_writers);
    defer allocator.free(args);

    for (args, 0..) |*a, idx| a.* = .{
        .ctx = &ctx,
        .s = &s,
        .iters = ops_per_writer,
        .base = @as(i64, @intCast(idx)) * 1_000_000,
    };

    var timer = try compat.Timer.start();
    for (threads, args) |*t, *a| {
        t.* = try std.Thread.spawn(.{}, writerWorker, .{a});
    }
    for (threads) |t| t.join();
    return timer.read();
}

// ============================================================
// Reclaim overhead
// ============================================================

fn benchReclaimOverhead(n_iters: usize) !u64 {
    var ctx = EbrContext{};
    defer ctx.deinit(allocator);

    var main_frame: [4096]u8 = undefined;
    var main_rt = try Runtime.initFromSlice(&main_frame, &ctx, allocator, 0);
    defer main_rt.deinit();
    try ctx.register(allocator, main_rt.ebr);
    defer ctx.unregister(main_rt.ebr);

    var timer = try compat.Timer.start();
    var i: usize = 0;
    while (i < n_iters) : (i += 1) {
        // Empty-context reclaim: just checks the registry, possibly
        // advances the epoch, and sweeps an empty orphan list. This
        // is the steady-state cost when readers have been clean.
        ctx.reclaim(allocator);
    }
    return timer.read();
}

// ============================================================
// Reporting
// ============================================================

fn report(label: []const u8, elapsed_ns: u64, ops: usize) void {
    const ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const ns_per_op = @as(f64, @floatFromInt(elapsed_ns)) / @as(f64, @floatFromInt(ops));
    const ops_per_sec = @as(f64, @floatFromInt(ops)) * 1_000_000_000.0 / @as(f64, @floatFromInt(elapsed_ns));
    std.debug.print(
        "  {s:<48} {d:>10.2} ms   {d:>10.1} ns/op   {d:>14.0} ops/s\n",
        .{ label, ms, ns_per_op, ops_per_sec },
    );
}

// ============================================================
// Tests (printed reports; no assertions on timing)
// ============================================================

test "MVCC bench: Versioned(Sample) read throughput across thread counts" {
    std.debug.print("\n", .{});
    std.debug.print("Versioned(T).read throughput\n", .{});
    std.debug.print("  {s:<48} {s:>10}    {s:>10}    {s:>14}\n", .{ "case", "wall (ms)", "ns/op", "ops/sec" });
    std.debug.print("  {s:-<48} {s:->10}    {s:->10}    {s:->14}\n", .{ "", "", "", "" });

    const ops = 200_000;
    inline for (.{ 1, 4, 16 }) |n_readers| {
        const elapsed = try benchReadThroughput(n_readers, ops);
        var label_buf: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "{d} readers x {d} ops", .{ n_readers, ops });
        report(label, elapsed, n_readers * ops);
    }
}

test "MVCC bench: Versioned(Sample) write throughput under CAS contention" {
    std.debug.print("\n", .{});
    std.debug.print("Versioned(T).update throughput (single CAS object)\n", .{});
    std.debug.print("  {s:<48} {s:>10}    {s:>10}    {s:>14}\n", .{ "case", "wall (ms)", "ns/op", "ops/sec" });
    std.debug.print("  {s:-<48} {s:->10}    {s:->10}    {s:->14}\n", .{ "", "", "", "" });

    inline for (.{ 1, 4, 8 }) |n_writers| {
        const ops = if (n_writers == 1) @as(usize, 50_000) else @as(usize, 20_000);
        const elapsed = try benchWriteThroughput(n_writers, ops);
        var label_buf: [64]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "{d} writers x {d} ops", .{ n_writers, ops });
        report(label, elapsed, n_writers * ops);
    }
}

test "MVCC bench: EbrContext.reclaim steady-state cost (empty registry+orphans)" {
    std.debug.print("\n", .{});
    std.debug.print("EbrContext.reclaim() steady-state\n", .{});
    std.debug.print("  {s:<48} {s:>10}    {s:>10}    {s:>14}\n", .{ "case", "wall (ms)", "ns/op", "ops/sec" });
    std.debug.print("  {s:-<48} {s:->10}    {s:->10}    {s:->14}\n", .{ "", "", "", "" });

    const ops = 100_000;
    const elapsed = try benchReclaimOverhead(ops);
    report("reclaim x 100K (1 registered, 0 orphans)", elapsed, ops);
}
