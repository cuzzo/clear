pub const CLEAR_FRAME_DEBUG = false;

// parking-lot-benchmark-test.zig — raw-thread throughput comparison vs pthread.
//
// Benchmarks the NON-FIBER path of ParkingMutex / ParkingRwLock against
// libc pthread_mutex_t / pthread_rwlock_t under equivalent contention.
// The in-fiber path is not what we're comparing here -- the fiber version
// never enters the kernel under contention (yield to scheduler) whereas
// pthread always does. The interesting apples-to-apples comparison is the
// raw-thread path where both use futex-style parking.
//
// Run:  zig build benchmark 2>&1 | grep -E "PARKING|PTHREAD"
// Or:   zig test parking-lot-benchmark-test.zig -lc -O ReleaseFast
//       (ReleaseFast required for meaningful numbers)

const std = @import("std");
const pl = @import("lib/parking-lot.zig");
const compat = @import("lib/compat.zig");

// Link libc pthread. We use pthread_mutex directly because Zig 0.16 has no
// std.Thread.Mutex wrapper, and pthread_mutex is what the OS provides anyway.
const c = @cImport({
    @cInclude("pthread.h");
});

const N_THREADS: usize = 8;
const OPS_PER_THREAD: usize = 200_000;

// Shared counter protected by a lock. Each thread increments it N times.
fn parkingMutexWorker(mu: *pl.ParkingMutex, counter: *usize) void {
    var i: usize = 0;
    while (i < OPS_PER_THREAD) : (i += 1) {
        mu.lock() catch unreachable;
        counter.* += 1;
        mu.unlock();
    }
}

fn pthreadMutexWorker(mu: *c.pthread_mutex_t, counter: *usize) void {
    var i: usize = 0;
    while (i < OPS_PER_THREAD) : (i += 1) {
        _ = c.pthread_mutex_lock(mu);
        counter.* += 1;
        _ = c.pthread_mutex_unlock(mu);
    }
}

test "mutex throughput: ParkingMutex vs pthread_mutex_t (8 threads, 200K ops each)" {
    // Warm up the allocator / thread creation path so first-run noise is
    // charged to neither side.
    {
        var junk: std.Thread = undefined;
        junk = try std.Thread.spawn(.{}, struct {
            fn f() void {}
        }.f, .{});
        junk.join();
    }

    // ── ParkingMutex (our impl) ─────────────────────────────────────────────
    var pk_mutex = pl.ParkingMutex{};
    var pk_counter: usize = 0;
    var pk_threads: [N_THREADS]std.Thread = undefined;

    const pk_start = compat.nanoTimestamp();
    for (&pk_threads) |*t| {
        t.* = try std.Thread.spawn(.{}, parkingMutexWorker, .{ &pk_mutex, &pk_counter });
    }
    for (&pk_threads) |*t| t.join();
    const pk_elapsed_ns = compat.nanoTimestamp() - pk_start;

    try std.testing.expectEqual(N_THREADS * OPS_PER_THREAD, pk_counter);

    // ── pthread_mutex_t (baseline) ──────────────────────────────────────────
    var pt_mutex: c.pthread_mutex_t = std.mem.zeroes(c.pthread_mutex_t);
    _ = c.pthread_mutex_init(&pt_mutex, null);
    defer _ = c.pthread_mutex_destroy(&pt_mutex);

    var pt_counter: usize = 0;
    var pt_threads: [N_THREADS]std.Thread = undefined;

    const pt_start = compat.nanoTimestamp();
    for (&pt_threads) |*t| {
        t.* = try std.Thread.spawn(.{}, pthreadMutexWorker, .{ &pt_mutex, &pt_counter });
    }
    for (&pt_threads) |*t| t.join();
    const pt_elapsed_ns = compat.nanoTimestamp() - pt_start;

    try std.testing.expectEqual(N_THREADS * OPS_PER_THREAD, pt_counter);

    // ── Report ──────────────────────────────────────────────────────────────
    const total_ops = N_THREADS * OPS_PER_THREAD;
    const pk_ms: f64 = @as(f64, @floatFromInt(pk_elapsed_ns)) / 1_000_000.0;
    const pt_ms: f64 = @as(f64, @floatFromInt(pt_elapsed_ns)) / 1_000_000.0;
    const pk_ops_per_sec: f64 = @as(f64, @floatFromInt(total_ops)) * 1_000_000_000.0 / @as(f64, @floatFromInt(pk_elapsed_ns));
    const pt_ops_per_sec: f64 = @as(f64, @floatFromInt(total_ops)) * 1_000_000_000.0 / @as(f64, @floatFromInt(pt_elapsed_ns));
    const ratio: f64 = pt_ms / pk_ms;

    std.debug.print(
        "\n  PARKING ParkingMutex:    {d:>8.1} ms  ({d:>10.0} ops/sec)\n",
        .{ pk_ms, pk_ops_per_sec },
    );
    std.debug.print(
        "  PTHREAD pthread_mutex_t: {d:>8.1} ms  ({d:>10.0} ops/sec)\n",
        .{ pt_ms, pt_ops_per_sec },
    );
    std.debug.print("  Ratio: ParkingMutex is {d:.2}x pthread speed\n", .{ratio});
}

// ─── RwLock throughput ──────────────────────────────────────────────────────

const N_WRITERS: usize = 2;
const N_READERS: usize = 6;
const RW_OPS_PER_THREAD: usize = 100_000;

fn parkingRwWriter(rw: *pl.ParkingRwLock, counter: *usize) void {
    var i: usize = 0;
    while (i < RW_OPS_PER_THREAD) : (i += 1) {
        rw.lock() catch unreachable;
        counter.* += 1;
        rw.unlock();
    }
}

fn parkingRwReader(rw: *pl.ParkingRwLock, counter: *const usize, sink: *usize) void {
    var i: usize = 0;
    while (i < RW_OPS_PER_THREAD) : (i += 1) {
        rw.lockShared() catch unreachable;
        sink.* +%= counter.*;
        rw.unlockShared();
    }
}

fn pthreadRwWriter(rw: *c.pthread_rwlock_t, counter: *usize) void {
    var i: usize = 0;
    while (i < RW_OPS_PER_THREAD) : (i += 1) {
        _ = c.pthread_rwlock_wrlock(rw);
        counter.* += 1;
        _ = c.pthread_rwlock_unlock(rw);
    }
}

fn pthreadRwReader(rw: *c.pthread_rwlock_t, counter: *const usize, sink: *usize) void {
    var i: usize = 0;
    while (i < RW_OPS_PER_THREAD) : (i += 1) {
        _ = c.pthread_rwlock_rdlock(rw);
        sink.* +%= counter.*;
        _ = c.pthread_rwlock_unlock(rw);
    }
}

test "rwlock throughput: ParkingRwLock vs pthread_rwlock_t (2W+6R, 100K ops each)" {
    var pk_sink: [N_READERS]usize = [_]usize{0} ** N_READERS;
    var pk_counter: usize = 0;
    var pk_rw = pl.ParkingRwLock{};
    var pk_threads: [N_WRITERS + N_READERS]std.Thread = undefined;

    const pk_start = compat.nanoTimestamp();
    for (pk_threads[0..N_WRITERS]) |*t| {
        t.* = try std.Thread.spawn(.{}, parkingRwWriter, .{ &pk_rw, &pk_counter });
    }
    for (pk_threads[N_WRITERS..], 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{}, parkingRwReader, .{ &pk_rw, &pk_counter, &pk_sink[idx] });
    }
    for (&pk_threads) |*t| t.join();
    const pk_elapsed_ns = compat.nanoTimestamp() - pk_start;
    try std.testing.expectEqual(N_WRITERS * RW_OPS_PER_THREAD, pk_counter);

    // pthread rwlock baseline
    var pt_rw: c.pthread_rwlock_t = std.mem.zeroes(c.pthread_rwlock_t);
    _ = c.pthread_rwlock_init(&pt_rw, null);
    defer _ = c.pthread_rwlock_destroy(&pt_rw);

    var pt_sink: [N_READERS]usize = [_]usize{0} ** N_READERS;
    var pt_counter: usize = 0;
    var pt_threads: [N_WRITERS + N_READERS]std.Thread = undefined;

    const pt_start = compat.nanoTimestamp();
    for (pt_threads[0..N_WRITERS]) |*t| {
        t.* = try std.Thread.spawn(.{}, pthreadRwWriter, .{ &pt_rw, &pt_counter });
    }
    for (pt_threads[N_WRITERS..], 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{}, pthreadRwReader, .{ &pt_rw, &pt_counter, &pt_sink[idx] });
    }
    for (&pt_threads) |*t| t.join();
    const pt_elapsed_ns = compat.nanoTimestamp() - pt_start;
    try std.testing.expectEqual(N_WRITERS * RW_OPS_PER_THREAD, pt_counter);

    const total_ops = (N_WRITERS + N_READERS) * RW_OPS_PER_THREAD;
    const pk_ms: f64 = @as(f64, @floatFromInt(pk_elapsed_ns)) / 1_000_000.0;
    const pt_ms: f64 = @as(f64, @floatFromInt(pt_elapsed_ns)) / 1_000_000.0;
    const pk_ops_per_sec: f64 = @as(f64, @floatFromInt(total_ops)) * 1_000_000_000.0 / @as(f64, @floatFromInt(pk_elapsed_ns));
    const pt_ops_per_sec: f64 = @as(f64, @floatFromInt(total_ops)) * 1_000_000_000.0 / @as(f64, @floatFromInt(pt_elapsed_ns));
    const ratio: f64 = pt_ms / pk_ms;

    std.debug.print(
        "\n  PARKING ParkingRwLock:    {d:>8.1} ms  ({d:>10.0} ops/sec)\n",
        .{ pk_ms, pk_ops_per_sec },
    );
    std.debug.print(
        "  PTHREAD pthread_rwlock_t: {d:>8.1} ms  ({d:>10.0} ops/sec)\n",
        .{ pt_ms, pt_ops_per_sec },
    );
    std.debug.print("  Ratio: ParkingRwLock is {d:.2}x pthread speed\n", .{ratio});
}

// ─── Scaling test: how does throughput change with thread count? ─────────────
//
// This mirrors the CLEAR benchmark/concurrent/13_rwlock_starvation workload
// (N-1 readers spinning, busyWork(100) inside crit section) but as raw threads
// so we can see how our implementation scales vs pthread without involving
// the CLEAR scheduler / fiber layer.

const SCALE_OPS_PER_READER: usize = 200_000;
const SCALE_WRITE_OPS: usize = 100;

fn scaleBusyWork(n: usize) usize {
    var acc: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) acc +%= i;
    return acc;
}

fn scaleParkingReader(rw: *pl.ParkingRwLock, counter: *const usize, sink: *usize) void {
    var i: usize = 0;
    while (i < SCALE_OPS_PER_READER) : (i += 1) {
        rw.lockShared() catch unreachable;
        sink.* +%= counter.*;
        sink.* +%= scaleBusyWork(100);
        rw.unlockShared();
    }
}

fn scaleParkingWriter(rw: *pl.ParkingRwLock, counter: *usize, sink: *usize) void {
    var i: usize = 0;
    while (i < SCALE_WRITE_OPS) : (i += 1) {
        rw.lock() catch unreachable;
        counter.* += 1;
        sink.* +%= scaleBusyWork(100);
        rw.unlock();
    }
}

fn scalePthreadReader(rw: *c.pthread_rwlock_t, counter: *const usize, sink: *usize) void {
    var i: usize = 0;
    while (i < SCALE_OPS_PER_READER) : (i += 1) {
        _ = c.pthread_rwlock_rdlock(rw);
        sink.* +%= counter.*;
        sink.* +%= scaleBusyWork(100);
        _ = c.pthread_rwlock_unlock(rw);
    }
}

fn scalePthreadWriter(rw: *c.pthread_rwlock_t, counter: *usize, sink: *usize) void {
    var i: usize = 0;
    while (i < SCALE_WRITE_OPS) : (i += 1) {
        _ = c.pthread_rwlock_wrlock(rw);
        counter.* += 1;
        sink.* +%= scaleBusyWork(100);
        _ = c.pthread_rwlock_unlock(rw);
    }
}

fn runScaleParking(n_threads: usize, alloc: std.mem.Allocator) !u64 {
    var rw = pl.ParkingRwLock{};
    var counter: usize = 0;
    var w_sink: usize = 0;
    const sinks = try alloc.alloc(usize, n_threads - 1);
    defer alloc.free(sinks);
    for (sinks) |*s| s.* = 0;
    const threads = try alloc.alloc(std.Thread, n_threads);
    defer alloc.free(threads);

    const start = compat.nanoTimestamp();
    threads[0] = try std.Thread.spawn(.{}, scaleParkingWriter, .{ &rw, &counter, &w_sink });
    for (threads[1..], 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{}, scaleParkingReader, .{ &rw, &counter, &sinks[idx] });
    }
    for (threads) |*t| t.join();
    return @intCast(compat.nanoTimestamp() - start);
}

fn runScalePthread(n_threads: usize, alloc: std.mem.Allocator) !u64 {
    var rw: c.pthread_rwlock_t = std.mem.zeroes(c.pthread_rwlock_t);
    _ = c.pthread_rwlock_init(&rw, null);
    defer _ = c.pthread_rwlock_destroy(&rw);

    var counter: usize = 0;
    var w_sink: usize = 0;
    const sinks = try alloc.alloc(usize, n_threads - 1);
    defer alloc.free(sinks);
    for (sinks) |*s| s.* = 0;
    const threads = try alloc.alloc(std.Thread, n_threads);
    defer alloc.free(threads);

    const start = compat.nanoTimestamp();
    threads[0] = try std.Thread.spawn(.{}, scalePthreadWriter, .{ &rw, &counter, &w_sink });
    for (threads[1..], 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{}, scalePthreadReader, .{ &rw, &counter, &sinks[idx] });
    }
    for (threads) |*t| t.join();
    return @intCast(compat.nanoTimestamp() - start);
}

test "rwlock scaling: ParkingRwLock vs pthread_rwlock_t at 2,4,8,16 threads" {
    const alloc = std.testing.allocator;
    const counts = [_]usize{ 2, 4, 8, 16 };

    std.debug.print("\n  threads | ParkingRwLock |  pthread_rwlock_t | ratio\n", .{});
    std.debug.print("  --------|---------------|-------------------|------\n", .{});
    for (counts) |n| {
        const pk_ns = try runScaleParking(n, alloc);
        const pt_ns = try runScalePthread(n, alloc);
        const pk_ms: f64 = @as(f64, @floatFromInt(pk_ns)) / 1_000_000.0;
        const pt_ms: f64 = @as(f64, @floatFromInt(pt_ns)) / 1_000_000.0;
        const ratio: f64 = pt_ms / pk_ms;
        std.debug.print(
            "  {d:>7} | {d:>10.1} ms | {d:>14.1} ms | {d:>4.2}x\n",
            .{ n, pk_ms, pt_ms, ratio },
        );
    }
}
