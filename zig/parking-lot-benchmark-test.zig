pub const CLEAR_FRAME_DEBUG = false;

// parking-lot-benchmark-test.zig
//
// Comprehensive 3 x 2 x 3 = 18 benchmark matrix vs pthread:
//   - 3 access patterns: read-heavy (1% writes), write-heavy (99% writes),
//                         mixed (50/50). For Mutex these collapse; we run
//                         all three for matrix symmetry.
//   - 2 lock types:      ParkingMutex/pthread_mutex_t,
//                         ParkingRwLock/pthread_rwlock_t.
//   - 3 contention levels:
//       uncontended (1 thread, no work in CS)  — pure overhead.
//       heavy       (16 threads, no work in CS) — max contention.
//       realistic   (8 threads, busyWork(100) in CS) — typical workload.
//
// Run:  zig build benchmark -Doptimize=ReleaseFast
//
// All numbers are ms wall-clock for the workload (lower is better).
// Ratio column = pthread_ms / parking_ms; > 1.0 means parking is faster.

const std = @import("std");
const pl = @import("lib/parking-lot.zig");
const compat = @import("lib/compat.zig");

const c = @cImport({
    @cInclude("pthread.h");
});

const Pattern = enum { read_heavy, write_heavy, mixed };
const Contention = enum { uncontended, heavy, realistic };
const LockKind = enum { mutex, rwlock };

const ContentionParams = struct {
    n_threads: usize,
    ops_per_thread: usize,
    work_iters: usize,
};

// Use the actual CPU count for "heavy" / "realistic" so we measure true
// scaling. uncontended stays at 1 thread. Iteration counts are sized so
// each cell runs >= 500ms for meaningful measurement (per-op times around
// 15-30ns uncontended, 30-400ns under contention).
fn coreCount() usize {
    return std.Thread.getCpuCount() catch 8;
}

fn paramsFor(level: Contention) ContentionParams {
    const cores = coreCount();
    return switch (level) {
        .uncontended => .{ .n_threads = 1,     .ops_per_thread = 30_000_000, .work_iters = 0 },
        .heavy       => .{ .n_threads = cores, .ops_per_thread = 500_000,    .work_iters = 0 },
        .realistic   => .{ .n_threads = cores, .ops_per_thread = 100_000,    .work_iters = 100 },
    };
}

fn writeProbPct(p: Pattern) u32 {
    return switch (p) {
        .read_heavy  => 1,
        .write_heavy => 99,
        .mixed       => 50,
    };
}

inline fn busyWork(n: usize) usize {
    var acc: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) acc +%= i;
    return acc;
}

const Shared = struct {
    counter: usize = 0,
    sink: usize align(64) = 0,
};

// ─── Workers ────────────────────────────────────────────────────────────────

fn parkingMutexWorker(mu: *pl.ParkingMutex, sh: *Shared, ops: usize, write_pct: u32, work: usize, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    var rnd = prng.random();
    var i: usize = 0;
    while (i < ops) : (i += 1) {
        const is_write = rnd.uintLessThan(u32, 100) < write_pct;
        mu.lock() catch unreachable;
        if (is_write) sh.counter += 1 else sh.sink +%= sh.counter;
        if (work > 0) sh.sink +%= busyWork(work);
        mu.unlock();
    }
}

fn pthreadMutexWorker(mu: *c.pthread_mutex_t, sh: *Shared, ops: usize, write_pct: u32, work: usize, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    var rnd = prng.random();
    var i: usize = 0;
    while (i < ops) : (i += 1) {
        const is_write = rnd.uintLessThan(u32, 100) < write_pct;
        _ = c.pthread_mutex_lock(mu);
        if (is_write) sh.counter += 1 else sh.sink +%= sh.counter;
        if (work > 0) sh.sink +%= busyWork(work);
        _ = c.pthread_mutex_unlock(mu);
    }
}

fn parkingRwLockWorker(rw: *pl.ParkingRwLock, sh: *Shared, ops: usize, write_pct: u32, work: usize, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    var rnd = prng.random();
    var i: usize = 0;
    while (i < ops) : (i += 1) {
        const is_write = rnd.uintLessThan(u32, 100) < write_pct;
        if (is_write) {
            rw.lock() catch unreachable;
            sh.counter += 1;
            if (work > 0) sh.sink +%= busyWork(work);
            rw.unlock();
        } else {
            rw.lockShared() catch unreachable;
            sh.sink +%= sh.counter;
            if (work > 0) sh.sink +%= busyWork(work);
            rw.unlockShared();
        }
    }
}

fn pthreadRwLockWorker(rw: *c.pthread_rwlock_t, sh: *Shared, ops: usize, write_pct: u32, work: usize, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    var rnd = prng.random();
    var i: usize = 0;
    while (i < ops) : (i += 1) {
        const is_write = rnd.uintLessThan(u32, 100) < write_pct;
        if (is_write) {
            _ = c.pthread_rwlock_wrlock(rw);
            sh.counter += 1;
            if (work > 0) sh.sink +%= busyWork(work);
            _ = c.pthread_rwlock_unlock(rw);
        } else {
            _ = c.pthread_rwlock_rdlock(rw);
            sh.sink +%= sh.counter;
            if (work > 0) sh.sink +%= busyWork(work);
            _ = c.pthread_rwlock_unlock(rw);
        }
    }
}

// ─── Runners ────────────────────────────────────────────────────────────────

fn runParkingMutex(alloc: std.mem.Allocator, params: ContentionParams, write_pct: u32) !u64 {
    var mu = pl.ParkingMutex{};
    var sh = Shared{};
    const threads = try alloc.alloc(std.Thread, params.n_threads);
    defer alloc.free(threads);

    const start = compat.nanoTimestamp();
    for (threads, 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{}, parkingMutexWorker, .{
            &mu, &sh, params.ops_per_thread, write_pct, params.work_iters,
            @as(u64, idx) + 1,
        });
    }
    for (threads) |*t| t.join();
    return @intCast(compat.nanoTimestamp() - start);
}

fn runPthreadMutex(alloc: std.mem.Allocator, params: ContentionParams, write_pct: u32) !u64 {
    var mu: c.pthread_mutex_t = std.mem.zeroes(c.pthread_mutex_t);
    _ = c.pthread_mutex_init(&mu, null);
    defer _ = c.pthread_mutex_destroy(&mu);
    var sh = Shared{};
    const threads = try alloc.alloc(std.Thread, params.n_threads);
    defer alloc.free(threads);

    const start = compat.nanoTimestamp();
    for (threads, 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{}, pthreadMutexWorker, .{
            &mu, &sh, params.ops_per_thread, write_pct, params.work_iters,
            @as(u64, idx) + 1,
        });
    }
    for (threads) |*t| t.join();
    return @intCast(compat.nanoTimestamp() - start);
}

fn runParkingRwLock(alloc: std.mem.Allocator, params: ContentionParams, write_pct: u32) !u64 {
    var rw = pl.ParkingRwLock{};
    var sh = Shared{};
    const threads = try alloc.alloc(std.Thread, params.n_threads);
    defer alloc.free(threads);

    const start = compat.nanoTimestamp();
    for (threads, 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{}, parkingRwLockWorker, .{
            &rw, &sh, params.ops_per_thread, write_pct, params.work_iters,
            @as(u64, idx) + 1,
        });
    }
    for (threads) |*t| t.join();
    return @intCast(compat.nanoTimestamp() - start);
}

fn runPthreadRwLock(alloc: std.mem.Allocator, params: ContentionParams, write_pct: u32) !u64 {
    // Default reader-preferring on glibc would starve writers; ours is fair.
    // Use writer-preferring for an apples-to-apples comparison.
    var attr: c.pthread_rwlockattr_t = undefined;
    _ = c.pthread_rwlockattr_init(&attr);
    defer _ = c.pthread_rwlockattr_destroy(&attr);
    _ = c.pthread_rwlockattr_setkind_np(&attr, c.PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP);
    var rw: c.pthread_rwlock_t = std.mem.zeroes(c.pthread_rwlock_t);
    _ = c.pthread_rwlock_init(&rw, &attr);
    defer _ = c.pthread_rwlock_destroy(&rw);
    var sh = Shared{};
    const threads = try alloc.alloc(std.Thread, params.n_threads);
    defer alloc.free(threads);

    const start = compat.nanoTimestamp();
    for (threads, 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{}, pthreadRwLockWorker, .{
            &rw, &sh, params.ops_per_thread, write_pct, params.work_iters,
            @as(u64, idx) + 1,
        });
    }
    for (threads) |*t| t.join();
    return @intCast(compat.nanoTimestamp() - start);
}

// ─── Matrix ─────────────────────────────────────────────────────────────────

fn nameKind(k: LockKind) []const u8 {
    return switch (k) { .mutex => "Mutex ", .rwlock => "RwLock" };
}
fn nameP(p: Pattern) []const u8 {
    return switch (p) { .read_heavy => "read-heavy ", .write_heavy => "write-heavy", .mixed => "mixed      " };
}
fn nameC(level: Contention) []const u8 {
    return switch (level) { .uncontended => "uncontended", .heavy => "heavy      ", .realistic => "realistic  " };
}

test "lock matrix: ParkingMutex/RwLock vs pthread (3 patterns x 2 locks x 3 contention)" {
    const alloc = std.testing.allocator;

    // Warm thread spawn so the first row isn't penalized.
    {
        var t = try std.Thread.spawn(.{}, struct { fn f() void {} }.f, .{});
        t.join();
    }

    std.debug.print(
        "\n  Lock   | Pattern     | Contention  |  Parking ms |  pthread ms |  Ratio\n" ++
          "  -------|-------------|-------------|-------------|-------------|-------\n",
        .{},
    );

    inline for ([_]LockKind{ .mutex, .rwlock }) |kind| {
        inline for ([_]Pattern{ .read_heavy, .write_heavy, .mixed }) |p| {
            inline for ([_]Contention{ .uncontended, .heavy, .realistic }) |level| {
                const params = paramsFor(level);
                const wp = writeProbPct(p);
                std.debug.print(
                    "  > {s} | {s} | {s} ... ",
                    .{ nameKind(kind), nameP(p), nameC(level) },
                );
                const pk_ns = switch (kind) {
                    .mutex  => try runParkingMutex(alloc, params, wp),
                    .rwlock => try runParkingRwLock(alloc, params, wp),
                };
                const pt_ns = switch (kind) {
                    .mutex  => try runPthreadMutex(alloc, params, wp),
                    .rwlock => try runPthreadRwLock(alloc, params, wp),
                };
                const pk_ms: f64 = @as(f64, @floatFromInt(pk_ns)) / 1_000_000.0;
                const pt_ms: f64 = @as(f64, @floatFromInt(pt_ns)) / 1_000_000.0;
                const ratio: f64 = pt_ms / pk_ms;
                std.debug.print(
                    "park={d:.1}ms pthr={d:.1}ms ratio={d:.2}x\n",
                    .{ pk_ms, pt_ms, ratio },
                );
            }
        }
    }
}
