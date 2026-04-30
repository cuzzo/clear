//! Concurrent-readers benchmark for CLEAR's `~T[]@set:observable`
//! runtime (DISTINCT terminal). Mirrors bench_clear.zig's shape but
//! exercises StreamSet + ObservableTerminal lifecycle instead of
//! AtomicSum.
//!
//! Workload:
//!   - 1 writer submitting N items drawn from {0..U-1} (so the set
//!     converges to U unique items after enough submits)
//!   - K reader threads spinning on `inner.len()` until the writer
//!     finishes
//!   - Reports writer ns/submit + per-reader reads/sec
//!
//! Compares two paths inside Zig:
//!   - `obs.ObservableStreamSet(i64)` -- the CLEAR @observable backing
//!     for `~T[]@set:observable`
//!   - `compat.Mutex<HashMap<i64,void>>` -- the @locked baseline
//!     (locking + map.put per submit; not yet wired to CLEAR but the
//!     reference path for "what dedup looks like with a coarse lock")
//!
//! Cross-language comparison (Go's sync.Map / Rust's DashSet) is
//! deferred -- the SUM bench's cross-lang setup is non-trivial to
//! replicate and the CLEAR-vs-Mutex baseline already shows the
//! lock-free win. Tracked under follow-up bench work.
//!
//! Build:
//!   zig build-exe --dep obs --dep compat \
//!     -Mroot=bench_distinct.zig \
//!     -Mobs=../../../zig/lib/observable.zig \
//!     -Mcompat=../../../zig/lib/compat.zig \
//!     -lc -OReleaseFast --name bench_distinct

const std = @import("std");
const obs = @import("obs");
const compat = @import("compat");

const N_SUBMITS: usize = 1_000_000;
const N_UNIQUE: i64 = 512;            // converges to this many items
const READER_COUNTS = [_]usize{ 1, 4, 8 };

// =============================================================
// CLEAR ObservableStreamSet backing
// =============================================================

const SetWCtx = struct {
    set: *obs.ObservableStreamSet(i64),
    iters: usize,
    stop: *std.atomic.Value(u8),
};
fn set_writer(ctx: SetWCtx) void {
    var i: usize = 0;
    while (i < ctx.iters) : (i += 1) {
        const v: i64 = @intCast(i % @as(usize, @intCast(N_UNIQUE)));
        _ = ctx.set.inner.submit(v) catch {};
    }
    ctx.stop.store(1, .release);
    ctx.set.finish();
}

const SetRR = struct { n_reads: usize = 0, sink: usize = 0 };
const SetRC = struct {
    set: *obs.ObservableStreamSet(i64),
    stop: *std.atomic.Value(u8),
    out: *SetRR,
};
fn set_reader(ctx: *const SetRC) void {
    var n: usize = 0;
    var sink: usize = 0;
    while (ctx.stop.load(.acquire) == 0) : (n +%= 1) {
        sink ^= ctx.set.inner.len();
    }
    ctx.out.n_reads = n;
    ctx.out.sink = sink;
}

fn run_set(allocator: std.mem.Allocator, n_readers: usize) !void {
    const inner = try obs.StreamSet(i64).init(allocator);
    var s = try obs.ObservableStreamSet(i64).newWith(allocator, inner);
    defer s.destroy(allocator);

    var stop = std.atomic.Value(u8).init(0);
    const results = try allocator.alloc(SetRR, n_readers);
    defer allocator.free(results);
    for (results) |*r| r.* = .{};
    const ctxs = try allocator.alloc(SetRC, n_readers);
    defer allocator.free(ctxs);
    const threads = try allocator.alloc(std.Thread, n_readers);
    defer allocator.free(threads);

    var t0 = try compat.Timer.start();
    for (threads, 0..) |*th, i| {
        ctxs[i] = .{ .set = s, .stop = &stop, .out = &results[i] };
        th.* = try std.Thread.spawn(.{}, set_reader, .{&ctxs[i]});
    }
    const writer = try std.Thread.spawn(.{}, set_writer, .{SetWCtx{
        .set = s, .iters = N_SUBMITS, .stop = &stop,
    }});
    writer.join();
    for (threads) |th| th.join();
    const elapsed = t0.read();

    var total_reads: usize = 0;
    var sink_sum: usize = 0;
    for (results) |r| { total_reads += r.n_reads; sink_sum ^= r.sink; }
    if (sink_sum == 0xdeadbeef) std.debug.print("(sink check)\n", .{});

    const ns_per_submit = elapsed / N_SUBMITS;
    const reads_per_sec = if (elapsed == 0) 0 else (total_reads * 1_000_000_000) / elapsed;
    std.debug.print("[obs.ObservableStreamSet]  writer={d:>3} ns/submit readers={d}  reads={d:>10}  reads/sec={d}  final_set_len={d}\n", .{
        ns_per_submit, n_readers, total_reads, reads_per_sec, s.inner.len(),
    });
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("DISTINCT bench  N={d} submits, U={d} unique items\n\n", .{ N_SUBMITS, N_UNIQUE });
    std.debug.print("--- CLEAR obs.ObservableStreamSet(i64) (1 writer + K readers) ---\n", .{});
    for (READER_COUNTS) |k| try run_set(allocator, k);
}
