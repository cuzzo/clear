//! Concurrent-readers benchmark for CLEAR's `@observable` runtime.
//!
//! Workload (matches bench.go and bench.rs):
//!   - 1 writer fiber/thread doing N increments
//!   - K reader threads each calling view() until the writer finishes
//!   - reports writer ns/op + per-reader reads/sec
//!
//! Two variants:
//!   - `obs.AtomicSum(i64)`  -- the CLEAR @observable backing
//!   - `compat.Mutex<i64>`   -- the @locked Int64 baseline
//!
//! Build: `zig build-exe bench_clear.zig --dep obs --dep compat ... -OReleaseFast`
//! Run:   `./bench_clear`

const std = @import("std");
const obs = @import("obs");
const compat = @import("compat");

const N_WRITES: usize = 5_000_000;
const READER_COUNTS = [_]usize{ 1, 4, 8 };

// ---------------- @observable: obs.AtomicSum ----------------

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

fn obs_reader(ctx: ObsCtx) usize {
    var n: usize = 0;
    while (ctx.stop.load(.acquire) == 0) : (n +%= 1) {
        _ = ctx.counter.view();
    }
    return n;
}

const ObsReaderResult = struct {
    n_reads: usize = 0,
    sink: i64 = 0,
};

const ObsReaderCtx = struct {
    counter: *obs.AtomicSum(i64),
    stop: *std.atomic.Value(u8),
    out: *ObsReaderResult,
};

fn obs_reader_thread(ctx: ObsReaderCtx) void {
    var n: usize = 0;
    var sink: i64 = 0;
    while (ctx.stop.load(.acquire) == 0) : (n +%= 1) {
        sink ^= ctx.counter.view(); // data-dependent so compiler can't elide
    }
    ctx.out.n_reads = n;
    ctx.out.sink = sink;
}

fn run_obs(allocator: std.mem.Allocator, n_readers: usize) !void {
    var counter = obs.AtomicSum(i64){};
    var stop = std.atomic.Value(u8).init(0);

    const reader_results = try allocator.alloc(ObsReaderResult, n_readers);
    defer allocator.free(reader_results);
    for (reader_results) |*r| r.* = .{};

    const reader_threads = try allocator.alloc(std.Thread, n_readers);
    defer allocator.free(reader_threads);

    var t0 = try compat.Timer.start();
    for (reader_threads, 0..) |*th, i| {
        th.* = try std.Thread.spawn(.{}, obs_reader_thread, .{ObsReaderCtx{
            .counter = &counter, .stop = &stop, .out = &reader_results[i],
        }});
    }
    const writer = try std.Thread.spawn(.{}, obs_writer, .{ObsCtx{
        .counter = &counter, .iters = N_WRITES, .stop = &stop,
    }});
    writer.join();
    for (reader_threads) |th| th.join();
    const elapsed_ns = t0.read();

    var total_reads: usize = 0;
    var sink_sum: i64 = 0;
    for (reader_results) |r| { total_reads += r.n_reads; sink_sum ^= r.sink; }

    const ns_per_inc = elapsed_ns / N_WRITES;
    const reads_per_sec = if (elapsed_ns == 0) 0 else (total_reads * 1_000_000_000) / elapsed_ns;
    std.debug.print("[CLEAR obs.AtomicSum]  writer={d:>3} ns/inc  readers={d}  total_reads={d}  reads/sec={d}\n", .{
        ns_per_inc, n_readers, total_reads, reads_per_sec,
    });
    if (counter.view() != @as(i64, @intCast(N_WRITES))) {
        std.debug.print("  !! counter view {d} != expected {d}\n", .{ counter.view(), N_WRITES });
    }
    if (sink_sum == 0xdeadbeef) std.debug.print("  (sink check)\n", .{});
}

// ---------------- @locked baseline: compat.Mutex<i64> ----------------

const LockedI64 = struct {
    value: i64 = 0,
    mtx: compat.Mutex = .{},

    pub fn add(self: *@This(), n: i64) void {
        self.mtx.lock();
        defer self.mtx.unlock();
        self.value += n;
    }
    pub fn view(self: *@This()) i64 {
        self.mtx.lock();
        defer self.mtx.unlock();
        return self.value;
    }
};

const LockedWCtx = struct {
    counter: *LockedI64,
    iters: usize,
    stop: *std.atomic.Value(u8),
};

fn locked_writer(ctx: LockedWCtx) void {
    var i: usize = 0;
    while (i < ctx.iters) : (i += 1) ctx.counter.add(1);
    ctx.stop.store(1, .release);
}

const LockedRCtx = struct {
    counter: *LockedI64,
    stop: *std.atomic.Value(u8),
    out: *ObsReaderResult,
};

fn locked_reader_thread(ctx: LockedRCtx) void {
    var n: usize = 0;
    var sink: i64 = 0;
    while (ctx.stop.load(.acquire) == 0) : (n +%= 1) {
        sink ^= ctx.counter.view();
    }
    ctx.out.n_reads = n;
    ctx.out.sink = sink;
}

fn run_locked(allocator: std.mem.Allocator, n_readers: usize) !void {
    var counter = LockedI64{};
    var stop = std.atomic.Value(u8).init(0);

    const reader_results = try allocator.alloc(ObsReaderResult, n_readers);
    defer allocator.free(reader_results);
    for (reader_results) |*r| r.* = .{};

    const reader_threads = try allocator.alloc(std.Thread, n_readers);
    defer allocator.free(reader_threads);

    var t0 = try compat.Timer.start();
    for (reader_threads, 0..) |*th, i| {
        th.* = try std.Thread.spawn(.{}, locked_reader_thread, .{LockedRCtx{
            .counter = &counter, .stop = &stop, .out = &reader_results[i],
        }});
    }
    const writer = try std.Thread.spawn(.{}, locked_writer, .{LockedWCtx{
        .counter = &counter, .iters = N_WRITES, .stop = &stop,
    }});
    writer.join();
    for (reader_threads) |th| th.join();
    const elapsed_ns = t0.read();

    var total_reads: usize = 0;
    var sink_sum: i64 = 0;
    for (reader_results) |r| { total_reads += r.n_reads; sink_sum ^= r.sink; }

    const ns_per_inc = elapsed_ns / N_WRITES;
    const reads_per_sec = if (elapsed_ns == 0) 0 else (total_reads * 1_000_000_000) / elapsed_ns;
    std.debug.print("[CLEAR @locked Int64]  writer={d:>3} ns/inc  readers={d}  total_reads={d}  reads/sec={d}\n", .{
        ns_per_inc, n_readers, total_reads, reads_per_sec,
    });
    if (counter.view() != @as(i64, @intCast(N_WRITES))) {
        std.debug.print("  !! counter view {d} != expected {d}\n", .{ counter.view(), N_WRITES });
    }
    if (sink_sum == 0xdeadbeef) std.debug.print("  (sink check)\n", .{});
}

// ---------------- driver ----------------

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Concurrent observable benchmark — N={d} writes, readers={any}\n", .{ N_WRITES, READER_COUNTS });
    for (READER_COUNTS) |k| try run_obs(allocator, k);
    std.debug.print("\n", .{});
    for (READER_COUNTS) |k| try run_locked(allocator, k);
}
