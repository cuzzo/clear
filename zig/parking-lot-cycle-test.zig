// parking-lot-cycle-test.zig — Regression tests for detectCycle false positives.
//
// Background:
//   `parking-lot.zig:detectCycle` walks a chain
//     waiter → owner_of_waiter's_lock → owner_of_that_lock's_lock → ...
//   reading two atomic fields (`waiting_for_lock`, `waiting_for_lock_owner`)
//   per Task per hop. Per-hop reads are pair-ordered (release/acquire), so
//   each hop sees a consistent snapshot — but N hops are NOT a single atomic
//   snapshot. Between hops K and K+1, hop K's holder can park on a different
//   lock, unpark, become an owner, etc. The walk assembles a chain that no
//   fiber actually reached simultaneously.
//
//   At THREADS≥4 with multi-OS-thread contention, the system reliably enters
//   apparent-cycle intermediate states long enough for the walker to grab one
//   and panic with `error.LockCycle`.
//
//   Reproduces benchmarks/concurrent/14_nested_lock at unit-test scale.
//   These tests MUST pass — any LockCycle/Deadlock here is the false-positive
//   bug. The existing parking-lot-test.zig has cycle tests that verify
//   detectCycle FIRES on a real cycle; the gap was the inverse: tests that
//   verify detectCycle DOES NOT FIRE when no cycle exists.
//
// The test gap that let this ship:
//   - parking-lot-loom-test.zig: 5 tests, 2 fibers, single mutex/rwlock.
//   - parking-lot-test.zig: 26 tests, single-scheduler (loom-style fibers).
//     Cross-thread tests use tryLock (no parking, no detectCycle).
//   - parking-lot-hammer-test.zig: 1 test, single mutex (no chains).
//   None exercised detectCycle's chain walk under multi-OS-thread contention.

pub const CLEAR_FRAME_DEBUG = false;

const std = @import("std");
const fm = @import("runtime/fiber-memory.zig");
const fp = @import("runtime/scheduler.zig");
const ebr_mod = @import("lib/ebr.zig");
const CheatHeader = @import("runtime/runtime-header.zig");
const pl = @import("lib/parking-lot.zig");
const compat = @import("lib/compat.zig");

const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;
const ParkingMutex = pl.ParkingMutex;
const ParkingRwLock = pl.ParkingRwLock;

// Tunables. Need ≥4 schedulers to reproduce on contemporary hardware.
// 8 fibers per scheduler × 32 fibers × 2K iters × 2 acquires = 128K paired
// acquires per test. Empirically reproduces the false positive in <1s when
// the bug is present.
const NUM_LOCKS: usize = 8;
const NUM_SCHEDULERS: usize = 4;
const FIBERS_PER_SCHEDULER: usize = 8;
const NUM_FIBERS: usize = NUM_SCHEDULERS * FIBERS_PER_SCHEDULER;
const ITERS_PER_FIBER: usize = 2_000;

// xorshift64* for deterministic-but-distinct fiber seeds.
fn nextRand(state: *u64) u64 {
    var x = state.*;
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    state.* = x;
    return x *% 0x2545F4914F6CDD1D;
}

// ─────────────────────────────────────────────────────────────────────────────
// Multi-scheduler infra: one OS thread per worker scheduler + main scheduler.
// Mirrors the steal-hammer-test.zig / inbox-race-smoke-test.zig pattern.
// ─────────────────────────────────────────────────────────────────────────────

const ThreadCtx = struct {
    alloc: std.mem.Allocator,
    ebr: *EbrContext,
    pool: *fm.StackPool,
    shutdown: *std.atomic.Value(bool),
};

fn schedulerThread(ctx: *ThreadCtx) void {
    var sched = fp.Scheduler.init(ctx.alloc, ctx.ebr, ctx.pool) catch return;
    defer sched.deinit();
    sched.global_shutdown = ctx.shutdown;
    sched.shutdown_on_idle = false;
    // Generous timeout: 30s. The bug typically panics well under 1s, and
    // this prevents legitimate slow iterations from spuriously timing out.
    sched.lock_timeout_ms = 30_000;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    sched.run();
    fp.scheduler_running = false;
}

// ─────────────────────────────────────────────────────────────────────────────
// ParkingMutex address-ordered chain test.
// ─────────────────────────────────────────────────────────────────────────────

const SharedMu = struct {
    locks: [NUM_LOCKS]ParkingMutex = [_]ParkingMutex{.{}} ** NUM_LOCKS,
    counters: [NUM_LOCKS]u64 = [_]u64{0} ** NUM_LOCKS,
    false_cycles: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    false_deadlocks: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    timeouts: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    wg: CheatHeader.WaitGroup,
};

const FiberCtxMu = struct {
    s: *SharedMu,
    seed: u64,
};

fn workerMu(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
    const ctx: *FiberCtxMu = @ptrCast(@alignCast(raw.?));
    defer ctx.s.wg.done();

    var prng = ctx.seed;
    var i: usize = 0;
    while (i < ITERS_PER_FIBER) : (i += 1) {
        const r = nextRand(&prng);
        const a: usize = @intCast(r % NUM_LOCKS);
        var b: usize = @intCast((r >> 32) % NUM_LOCKS);
        if (b == a) b = (a + 1) % NUM_LOCKS;
        const lo = @min(a, b);
        const hi = @max(a, b);

        // Address-ordered acquisition (lo < hi). Cannot form a cycle.
        ctx.s.locks[lo].lock() catch |e| {
            switch (e) {
                error.LockCycle => _ = ctx.s.false_cycles.fetchAdd(1, .monotonic),
                error.Deadlock => _ = ctx.s.false_deadlocks.fetchAdd(1, .monotonic),
                error.LockTimeout => _ = ctx.s.timeouts.fetchAdd(1, .monotonic),
            }
            continue;
        };
        ctx.s.locks[hi].lock() catch |e| {
            switch (e) {
                error.LockCycle => _ = ctx.s.false_cycles.fetchAdd(1, .monotonic),
                error.Deadlock => _ = ctx.s.false_deadlocks.fetchAdd(1, .monotonic),
                error.LockTimeout => _ = ctx.s.timeouts.fetchAdd(1, .monotonic),
            }
            ctx.s.locks[lo].unlock();
            continue;
        };
        ctx.s.counters[lo] += 1;
        ctx.s.counters[hi] += 1;
        ctx.s.locks[hi].unlock();
        ctx.s.locks[lo].unlock();
    }
}

test "ParkingMutex: address-ordered multi-acquire under multi-OS-thread contention does not falsely detect cycle" {
    const t_alloc = std.testing.allocator;
    var ebr = EbrContext{};
    defer ebr.deinit(t_alloc);
    var pool = fm.StackPool.init(t_alloc);
    defer pool.deinit();
    var shutdown = std.atomic.Value(bool).init(false);

    var tctx = ThreadCtx{ .alloc = t_alloc, .ebr = &ebr, .pool = &pool, .shutdown = &shutdown };

    // Worker schedulers (NUM_SCHEDULERS-1; main thread runs the last one).
    var workers: [NUM_SCHEDULERS - 1]std.Thread = undefined;
    var spawned: usize = 0;
    for (&workers) |*t| {
        t.* = std.Thread.spawn(.{}, schedulerThread, .{&tctx}) catch break;
        spawned += 1;
    }
    // Wait for workers to register.
    while (fp.global_registry.count() < spawned) {
        compat.sleepNs(1 * std.time.ns_per_ms);
    }

    // Main scheduler.
    var sched = try fp.Scheduler.init(t_alloc, &ebr, &pool);
    defer { sched.deinit(); fp.global_registry.deinit(t_alloc); }
    sched.lock_timeout_ms = 30_000;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;

    var shared = SharedMu{ .wg = CheatHeader.WaitGroup.init(&sched) };
    var ctxs: [NUM_FIBERS]FiberCtxMu = undefined;
    for (&ctxs, 0..) |*c, i| {
        c.* = .{
            .s = &shared,
            .seed = (@as(u64, i) +% 1) *% 0x9E3779B97F4A7C15,
        };
    }

    // Spawn from a fiber on the main scheduler so spawnBest's distribution
    // sees all schedulers (including main).
    const Main = struct {
        sh: *SharedMu,
        cs: *[NUM_FIBERS]FiberCtxMu,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            self.sh.wg.add(NUM_FIBERS);
            for (self.cs) |*c| {
                try CheatHeader.spawnBest(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&workerMu)),
                    c,
                    .{ .stack_size = .Large },
                );
            }
            self.sh.wg.wait();
        }
    };
    var main_ctx = Main{ .sh = &shared, .cs = &ctxs };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&Main.run)),
        &main_ctx,
        .{ .stack_size = .Large },
    );
    sched.run();

    // Stop workers.
    shutdown.store(true, .release);
    fp.global_registry.notifyAll();
    for (workers[0..spawned]) |*t| t.join();

    const fc = shared.false_cycles.load(.acquire);
    const fd = shared.false_deadlocks.load(.acquire);
    const to = shared.timeouts.load(.acquire);
    if (fc > 0 or fd > 0) {
        std.debug.print(
            "\nFALSE POSITIVE: cycles={} deadlocks={} timeouts={} (over {} iters)\n",
            .{ fc, fd, to, NUM_FIBERS * ITERS_PER_FIBER },
        );
    }
    try std.testing.expectEqual(@as(u32, 0), fc);
    try std.testing.expectEqual(@as(u32, 0), fd);
}

// ─────────────────────────────────────────────────────────────────────────────
// ParkingRwLock address-ordered chain test (exclusive/write side).
// detectCycle is invoked from lockSlow (writer path); shared/read does not
// run cycle detection. So we test the write path here.
// ─────────────────────────────────────────────────────────────────────────────

const SharedRw = struct {
    locks: [NUM_LOCKS]ParkingRwLock = [_]ParkingRwLock{.{}} ** NUM_LOCKS,
    counters: [NUM_LOCKS]u64 = [_]u64{0} ** NUM_LOCKS,
    false_cycles: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    false_deadlocks: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    timeouts: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    wg: CheatHeader.WaitGroup,
};

const FiberCtxRw = struct {
    s: *SharedRw,
    seed: u64,
};

fn workerRw(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
    const ctx: *FiberCtxRw = @ptrCast(@alignCast(raw.?));
    defer ctx.s.wg.done();

    var prng = ctx.seed;
    var i: usize = 0;
    while (i < ITERS_PER_FIBER) : (i += 1) {
        const r = nextRand(&prng);
        const a: usize = @intCast(r % NUM_LOCKS);
        var b: usize = @intCast((r >> 32) % NUM_LOCKS);
        if (b == a) b = (a + 1) % NUM_LOCKS;
        const lo = @min(a, b);
        const hi = @max(a, b);

        ctx.s.locks[lo].lock() catch |e| {
            switch (e) {
                error.LockCycle => _ = ctx.s.false_cycles.fetchAdd(1, .monotonic),
                error.Deadlock => _ = ctx.s.false_deadlocks.fetchAdd(1, .monotonic),
                error.LockTimeout => _ = ctx.s.timeouts.fetchAdd(1, .monotonic),
            }
            continue;
        };
        ctx.s.locks[hi].lock() catch |e| {
            switch (e) {
                error.LockCycle => _ = ctx.s.false_cycles.fetchAdd(1, .monotonic),
                error.Deadlock => _ = ctx.s.false_deadlocks.fetchAdd(1, .monotonic),
                error.LockTimeout => _ = ctx.s.timeouts.fetchAdd(1, .monotonic),
            }
            ctx.s.locks[lo].unlock();
            continue;
        };
        ctx.s.counters[lo] += 1;
        ctx.s.counters[hi] += 1;
        ctx.s.locks[hi].unlock();
        ctx.s.locks[lo].unlock();
    }
}

test "ParkingRwLock: address-ordered multi-write-acquire under multi-OS-thread contention does not falsely detect cycle" {
    const t_alloc = std.testing.allocator;
    var ebr = EbrContext{};
    defer ebr.deinit(t_alloc);
    var pool = fm.StackPool.init(t_alloc);
    defer pool.deinit();
    var shutdown = std.atomic.Value(bool).init(false);

    var tctx = ThreadCtx{ .alloc = t_alloc, .ebr = &ebr, .pool = &pool, .shutdown = &shutdown };

    var workers: [NUM_SCHEDULERS - 1]std.Thread = undefined;
    var spawned: usize = 0;
    for (&workers) |*t| {
        t.* = std.Thread.spawn(.{}, schedulerThread, .{&tctx}) catch break;
        spawned += 1;
    }
    while (fp.global_registry.count() < spawned) {
        compat.sleepNs(1 * std.time.ns_per_ms);
    }

    var sched = try fp.Scheduler.init(t_alloc, &ebr, &pool);
    defer { sched.deinit(); fp.global_registry.deinit(t_alloc); }
    sched.lock_timeout_ms = 30_000;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;

    var shared = SharedRw{ .wg = CheatHeader.WaitGroup.init(&sched) };
    var ctxs: [NUM_FIBERS]FiberCtxRw = undefined;
    for (&ctxs, 0..) |*c, i| {
        c.* = .{
            .s = &shared,
            .seed = (@as(u64, i) +% 1) *% 0xBF58476D1CE4E5B9,
        };
    }

    const Main = struct {
        sh: *SharedRw,
        cs: *[NUM_FIBERS]FiberCtxRw,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            self.sh.wg.add(NUM_FIBERS);
            for (self.cs) |*c| {
                try CheatHeader.spawnBest(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&workerRw)),
                    c,
                    .{ .stack_size = .Large },
                );
            }
            self.sh.wg.wait();
        }
    };
    var main_ctx = Main{ .sh = &shared, .cs = &ctxs };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&Main.run)),
        &main_ctx,
        .{ .stack_size = .Large },
    );
    sched.run();

    shutdown.store(true, .release);
    fp.global_registry.notifyAll();
    for (workers[0..spawned]) |*t| t.join();

    const fc = shared.false_cycles.load(.acquire);
    const fd = shared.false_deadlocks.load(.acquire);
    const to = shared.timeouts.load(.acquire);
    if (fc > 0 or fd > 0) {
        std.debug.print(
            "\nFALSE POSITIVE (rwlock): cycles={} deadlocks={} timeouts={} (over {} iters)\n",
            .{ fc, fd, to, NUM_FIBERS * ITERS_PER_FIBER },
        );
    }
    try std.testing.expectEqual(@as(u32, 0), fc);
    try std.testing.expectEqual(@as(u32, 0), fd);
}
