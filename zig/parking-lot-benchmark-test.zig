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
const fm = @import("runtime/fiber-memory.zig");
const fp = @import("runtime/scheduler.zig");
const CheatHeader = @import("runtime/runtime-header.zig");
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;

const c = @cImport({
    @cInclude("pthread.h");
});

const Pattern = enum { read_heavy, write_heavy, mixed };
const Contention = enum { uncontended, heavy, realistic, long_held };
const LockKind = enum { mutex, rwlock };

const ContentionParams = struct {
    n_threads: usize,
    ops_per_thread: usize,
    work_iters: usize,
    sleep_ns_in_cs: u64 = 0, // hold the lock for this long via std.Thread.sleep
};

// Use the actual CPU count for contended levels so we measure true
// scaling. uncontended stays at 1 thread. Iteration counts target
// ~500-1500ms per cell -- enough for measurement noise to wash out,
// short enough to keep total benchmark wallclock manageable.
fn coreCount() usize {
    return std.Thread.getCpuCount() catch 8;
}

fn paramsFor(level: Contention) ContentionParams {
    const cores = coreCount();
    return switch (level) {
        // 1 thread, no work: pure overhead measurement.
        .uncontended => .{ .n_threads = 1,     .ops_per_thread = 20_000_000, .work_iters = 0 },
        // All cores, no in-CS work: maximum lock-overhead contention.
        .heavy       => .{ .n_threads = cores, .ops_per_thread = 200_000,    .work_iters = 0 },
        // All cores, modest in-CS work (~100 cycles).
        .realistic   => .{ .n_threads = cores, .ops_per_thread = 50_000,     .work_iters = 100 },
        // All cores, lock held for 10ms in each CS via std.Thread.sleep.
        // This is where parking-lot's design SHINES for fibers (the OS
        // thread isn't blocked, the fiber yields to the scheduler) but
        // for raw threads we still futex-park, same as pthread.
        // Iter count low because each op takes ~10ms of wall time.
        .long_held   => .{ .n_threads = cores, .ops_per_thread = 5,          .work_iters = 0,
                            .sleep_ns_in_cs = 10 * std.time.ns_per_ms },
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

inline fn doCsWork(sh: *Shared, work: usize, sleep_ns: u64) void {
    if (work > 0) sh.sink +%= busyWork(work);
    if (sleep_ns > 0) compat.sleepNs(sleep_ns);
}

fn parkingMutexWorker(mu: *pl.ParkingMutex, sh: *Shared, ops: usize, write_pct: u32, work: usize, sleep_ns: u64, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    var rnd = prng.random();
    var i: usize = 0;
    while (i < ops) : (i += 1) {
        const is_write = rnd.uintLessThan(u32, 100) < write_pct;
        mu.lock() catch unreachable;
        if (is_write) sh.counter += 1 else sh.sink +%= sh.counter;
        doCsWork(sh, work, sleep_ns);
        mu.unlock();
    }
}

fn pthreadMutexWorker(mu: *c.pthread_mutex_t, sh: *Shared, ops: usize, write_pct: u32, work: usize, sleep_ns: u64, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    var rnd = prng.random();
    var i: usize = 0;
    while (i < ops) : (i += 1) {
        const is_write = rnd.uintLessThan(u32, 100) < write_pct;
        _ = c.pthread_mutex_lock(mu);
        if (is_write) sh.counter += 1 else sh.sink +%= sh.counter;
        doCsWork(sh, work, sleep_ns);
        _ = c.pthread_mutex_unlock(mu);
    }
}

fn parkingRwLockWorker(rw: *pl.ParkingRwLock, sh: *Shared, ops: usize, write_pct: u32, work: usize, sleep_ns: u64, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    var rnd = prng.random();
    var i: usize = 0;
    while (i < ops) : (i += 1) {
        const is_write = rnd.uintLessThan(u32, 100) < write_pct;
        if (is_write) {
            rw.lock() catch unreachable;
            sh.counter += 1;
            doCsWork(sh, work, sleep_ns);
            rw.unlock();
        } else {
            rw.lockShared() catch unreachable;
            sh.sink +%= sh.counter;
            doCsWork(sh, work, sleep_ns);
            rw.unlockShared();
        }
    }
}

fn pthreadRwLockWorker(rw: *c.pthread_rwlock_t, sh: *Shared, ops: usize, write_pct: u32, work: usize, sleep_ns: u64, seed: u64) void {
    var prng = std.Random.DefaultPrng.init(seed);
    var rnd = prng.random();
    var i: usize = 0;
    while (i < ops) : (i += 1) {
        const is_write = rnd.uintLessThan(u32, 100) < write_pct;
        if (is_write) {
            _ = c.pthread_rwlock_wrlock(rw);
            sh.counter += 1;
            doCsWork(sh, work, sleep_ns);
            _ = c.pthread_rwlock_unlock(rw);
        } else {
            _ = c.pthread_rwlock_rdlock(rw);
            sh.sink +%= sh.counter;
            doCsWork(sh, work, sleep_ns);
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
            params.sleep_ns_in_cs, @as(u64, idx) + 1,
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
            params.sleep_ns_in_cs, @as(u64, idx) + 1,
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
            params.sleep_ns_in_cs, @as(u64, idx) + 1,
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
            params.sleep_ns_in_cs, @as(u64, idx) + 1,
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
    return switch (level) {
        .uncontended => "uncontended",
        .heavy       => "heavy      ",
        .realistic   => "realistic  ",
        .long_held   => "long-held  ",
    };
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
            inline for ([_]Contention{ .uncontended, .heavy, .realistic, .long_held }) |level| {
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

// ─── In-fiber benchmark: many fibers per scheduler thread ──────────────────
//
// N fibers on 1 scheduler thread all loop { lock + brief work + unlock }.
// With brief CS and no mid-CS yields, the workload is effectively
// uncontended at the OS level (cooperative fibers take turns, holder
// always releases before yielding). This measures pure per-op overhead
// across two lock types:
//   - ParkingMutex
//   - pthread_mutex_t (from inside fibers; safe here because workload
//     is uncontended, no thread blocking)
//
// Note: this is NOT the scenario that shows parking-lot's M:N win. That
// needs contended fibers (one holds + yields mid-CS while others wait);
// doing that cleanly requires a multi-scheduler setup so a blocked fiber
// in a pthread variant doesn't deadlock the single OS thread.

const FIBER_BENCH_DURATION_MS: u64 = 500;
const LockChoice = enum { parking, pthread };

const FiberBenchShared = struct {
    mu_park: pl.ParkingMutex = .{},
    mu_pt:   c.pthread_mutex_t = std.mem.zeroes(c.pthread_mutex_t),
    choice: LockChoice = .parking,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    acquires: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    wg: CheatHeader.WaitGroup,
};

fn fiberBenchWorker(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
    const sh = @as(*FiberBenchShared, @ptrCast(@alignCast(raw.?)));
    defer sh.wg.done();
    var local: usize = 0;
    while (!sh.stop.load(.monotonic)) {
        switch (sh.choice) {
            .parking => {
                sh.mu_park.lock() catch unreachable;
                local +%= 1;
                sh.mu_park.unlock();
            },
            .pthread => {
                _ = c.pthread_mutex_lock(&sh.mu_pt);
                local +%= 1;
                _ = c.pthread_mutex_unlock(&sh.mu_pt);
            },
        }
        _ = sh.acquires.fetchAdd(1, .monotonic);
    }
}

fn runFiberBench(alloc: std.mem.Allocator, n_fibers: usize, choice: LockChoice) !usize {
    var ebr = EbrContext{};
    defer ebr.deinit(alloc);
    var rt = try Runtime.init(alloc, 512 * 1024, &ebr);
    defer rt.deinit();
    rt.wireAllocator();
    var sp = fm.StackPool.init(alloc);
    defer sp.deinit();
    var sched = try fp.Scheduler.init(alloc, &ebr, &sp);
    defer { sched.deinit(); fp.global_registry.deinit(alloc); }
    fp.active_scheduler = &sched;

    var shared = FiberBenchShared{ .wg = CheatHeader.WaitGroup.init(&sched), .choice = choice };
    if (choice == .pthread) {
        _ = c.pthread_mutex_init(&shared.mu_pt, null);
    }
    defer if (choice == .pthread) { _ = c.pthread_mutex_destroy(&shared.mu_pt); };

    // Stop from a separate OS thread so we don't accidentally suspend
    // the scheduler via compat.sleepNs.
    const Stopper = struct {
        fn run(s: *FiberBenchShared, ms: u64) void {
            compat.sleepNs(ms * std.time.ns_per_ms);
            s.stop.store(true, .release);
        }
    };
    var stop_thread = try std.Thread.spawn(.{}, Stopper.run, .{ &shared, FIBER_BENCH_DURATION_MS });

    const Main = struct {
        s: *FiberBenchShared, n: usize,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            self.s.wg.add(self.n);
            for (0..self.n) |_| {
                try fp.active_scheduler.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&fiberBenchWorker)), self.s, .{ .stack_size = .Large });
            }
            self.s.wg.wait();
        }
    };
    var main_ctx = Main{ .s = &shared, .n = n_fibers };
    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(CheatHeader.TaskFn, @ptrCast(&Main.run)), &main_ctx, .{ .stack_size = .Large });
    sched.run();
    stop_thread.join();
    return shared.acquires.load(.monotonic);
}

test "fiber benchmark: ParkingMutex vs pthread_mutex, N fibers on 1 scheduler" {
    const alloc = std.testing.allocator;

    std.debug.print(
        "\n  In-fiber lock throughput, 1 scheduler thread, {d}ms wallclock:\n" ++
          "  -------------------------------------------------------------\n" ++
          "  N fibers | ParkingMutex ops/sec | pthread_mutex ops/sec | ratio\n" ++
          "  ---------|----------------------|-----------------------|------\n",
        .{FIBER_BENCH_DURATION_MS},
    );
    inline for ([_]usize{ 1, 4, 16, 64, 256 }) |n| {
        const pk_acquires = try runFiberBench(alloc, n, .parking);
        const pt_acquires = try runFiberBench(alloc, n, .pthread);
        const pk_per_sec: f64 = @as(f64, @floatFromInt(pk_acquires)) * 1000.0
            / @as(f64, @floatFromInt(FIBER_BENCH_DURATION_MS));
        const pt_per_sec: f64 = @as(f64, @floatFromInt(pt_acquires)) * 1000.0
            / @as(f64, @floatFromInt(FIBER_BENCH_DURATION_MS));
        const ratio = pk_per_sec / pt_per_sec;
        std.debug.print(
            "  {d:>8} | {d:>20.0} | {d:>21.0} | {d:.2}x\n",
            .{ n, pk_per_sec, pt_per_sec, ratio },
        );
    }
    std.debug.print(
        "\n  Workload: fibers loop lock+unlock cooperatively. No actual\n" ++
          "  contention (holder always releases before yielding). This\n" ++
          "  measures pure per-op overhead. A parking-lot M:N win would\n" ++
          "  require contended fibers (yields mid-CS) across multiple\n" ++
          "  schedulers, which is a separate (multi-scheduler) benchmark.\n\n",
        .{},
    );
}
