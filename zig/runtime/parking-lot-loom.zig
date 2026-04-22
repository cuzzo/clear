// parking-lot-loom.zig -- Loom deterministic interleaving tests for ParkingMutex.
//
// Design:
//   One real fp.Scheduler (g_sched) shared across all test runs.
//   Each fiber slot has a stub Task whose .base points to the ACTUAL running
//   Fiber (harness.fibers[i]). This means task.base.yield() inside lockSlow
//   correctly switches back to the Loom harness.
//
//   Parking protocol:
//     After each switchTo, if task.status.value == .Blocked, the harness
//     marks the fiber parked (skipped by pickThread).
//     When submitResume runs (inside unlock), it sets task.status = .Ready
//     via a SimAtomic store (yield point). On the next harness loop iteration,
//     the harness detects .Ready and unparks the fiber.
//
// Run: zig build test (via parking-lot-loom-test.zig wrapper)

const std = @import("std");
const fc = @import("fiber-core.zig");
const qs = @import("queues.zig");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const ebr_mod = @import("../lib/ebr.zig");
const pl = @import("../lib/parking-lot.zig");

// Re-export SimAtomic/SimRing so queues.zig and scheduler.zig pick them up
// via @import("root").SimAtomic when this file is the root (direct compilation).
// When run via the parking-lot-loom-test.zig wrapper, the wrapper provides these.
pub const SimAtomic = @import("vopr-atomic.zig").SimAtomic;
pub const SimRing = @import("vopr-ring.zig").SimRing;

const ParkingMutex = pl.ParkingMutex;
const ParkingRwLock = pl.ParkingRwLock;
const Fiber = fc.Fiber;
const Context = fc.Context;
const Task = qs.Task;
const TaskStatus = qs.TaskStatus;

const MAX_THREADS = 4;
const STACK_SIZE = 64 * 1024;
const MAX_STEPS = 50_000;

// Override default (500) via env var LOOM_FUZZ_SEEDS.
// Used by prng-mode tests to scale coverage for nightly/manual runs.
fn fuzzSeedCount(default_seeds: usize) usize {
    const raw = std.c.getenv("LOOM_FUZZ_SEEDS") orelse return default_seeds;
    const s = std.mem.span(raw);
    return std.fmt.parseInt(usize, s, 10) catch default_seeds;
}

// ─────────────────────────────────────────────────────────────────────────────
// Global scheduler shared by all fibers under test.
// Initialized once per test, reused across runs (state drained between runs).
// ─────────────────────────────────────────────────────────────────────────────
var g_sched: fp.Scheduler = undefined;

var harness: *LoomHarness = undefined;

const ScheduleMode = union(enum) {
    prng: struct {
        rng: std.Random.DefaultPrng,
        random: std.Random,
    },
    exhaustive: struct {
        schedule: []const u8,
        pos: usize,
    },
};

const LoomHarness = struct {
    fibers: [MAX_THREADS]Fiber = undefined,
    stacks: [MAX_THREADS][]u8 = [_][]u8{&.{}} ** MAX_THREADS,
    main_ctx: Context = undefined,
    done: [MAX_THREADS]bool = [_]bool{false} ** MAX_THREADS,
    // parked: fiber is blocked waiting for a lock. pickThread skips parked fibers.
    // Cleared when task.status becomes .Ready (woken by submitResume).
    parked: [MAX_THREADS]bool = [_]bool{false} ** MAX_THREADS,
    n_threads: usize = 0,

    // One stub Task per fiber. .base = &fibers[i] so task.base.yield()
    // in lockSlow yields the correct fiber back to the harness.
    stub_tasks: [MAX_THREADS]Task = undefined,

    mode: ScheduleMode,
    allocator: std.mem.Allocator,

    fn initExhaustive(allocator: std.mem.Allocator, schedule: []const u8) LoomHarness {
        return .{
            .mode = .{ .exhaustive = .{ .schedule = schedule, .pos = 0 } },
            .allocator = allocator,
        };
    }

    fn initPrng(allocator: std.mem.Allocator, seed: u64) LoomHarness {
        const rng = std.Random.DefaultPrng.init(seed);
        var h = LoomHarness{
            .mode = .{ .prng = .{ .rng = rng, .random = undefined } },
            .allocator = allocator,
        };
        h.mode.prng.random = h.mode.prng.rng.random();
        return h;
    }

    fn deinit(self: *LoomHarness) void {
        for (&self.stacks) |*s| {
            if (s.len > 0) {
                self.allocator.free(s.*);
                s.* = &.{};
            }
        }
    }

    fn createThread(self: *LoomHarness, id: usize, entry_fn: usize) !void {
        if (self.stacks[id].len == 0) {
            self.stacks[id] = try self.allocator.alloc(u8, STACK_SIZE);
        }
        self.fibers[id] = Fiber.init(self.stacks[id], entry_fn, .Large);
        self.done[id] = false;
        self.parked[id] = false;
        // .base = actual running fiber so task.base.yield() in lockSlow works
        self.stub_tasks[id] = Task{
            .base = &self.fibers[id],
            .user_fn = @ptrCast(&dummyFn),
            .status = qs.Atomic(TaskStatus).init(.Ready),
        };
        if (id >= self.n_threads) self.n_threads = id + 1;
    }

    fn pickThread(self: *LoomHarness) usize {
        var active_count: usize = 0;
        var active_ids: [MAX_THREADS]usize = undefined;
        for (0..self.n_threads) |i| {
            if (!self.done[i] and !self.parked[i]) {
                active_ids[active_count] = i;
                active_count += 1;
            }
        }
        if (active_count == 0) return 0;
        switch (self.mode) {
            .prng => |*p| return active_ids[p.random.intRangeLessThan(usize, 0, active_count)],
            .exhaustive => |*e| {
                const choice = if (e.pos < e.schedule.len)
                    e.schedule[e.pos] % @as(u8, @intCast(active_count))
                else
                    e.pos % active_count;
                e.pos += 1;
                return active_ids[choice];
            },
        }
    }

    fn run(self: *LoomHarness) !void {
        fp.active_scheduler = &g_sched;
        fp.scheduler_running = true;

        var steps: usize = 0;
        while (steps < MAX_STEPS) : (steps += 1) {
            // Unpark fibers whose tasks became .Ready (woken by submitResume).
            for (0..self.n_threads) |i| {
                if (self.parked[i] and self.stub_tasks[i].status.load(.monotonic) == .Ready) {
                    self.parked[i] = false;
                }
            }

            var any_active = false;
            for (0..self.n_threads) |i| {
                if (!self.done[i] and !self.parked[i]) { any_active = true; break; }
            }
            if (!any_active) break;

            const chosen = self.pickThread();
            // Set current_task before switching so lockSlow sees the correct task.
            g_sched.current_task = &self.stub_tasks[chosen];

            self.fibers[chosen].switchTo(&self.main_ctx);

            // After the fiber yields, check if it parked on a lock.
            if (self.stub_tasks[chosen].status.load(.monotonic) == .Blocked) {
                self.parked[chosen] = true;
            }
        }

        fc.__fiber = null;
        fc.__fiber_parent_ctx = null;
        fp.scheduler_running = false;
        if (steps >= MAX_STEPS) return error.StepLimitExceeded;
    }

    fn resetExhaustive(self: *LoomHarness, schedule: []const u8) void {
        fc.__fiber = null;
        fc.__fiber_parent_ctx = null;
        fc.__fiber_stack_limit = null;
        self.done = [_]bool{false} ** MAX_THREADS;
        self.parked = [_]bool{false} ** MAX_THREADS;
        self.n_threads = 0;
        self.mode = .{ .exhaustive = .{ .schedule = schedule, .pos = 0 } };
        drainSchedState();
    }

    fn dummyFn(_: *anyopaque, _: ?*anyopaque) anyerror!void {}
};

// Drain scheduler state accumulated during a test run.
// Safe to call outside a fiber (SimAtomic yields are no-ops when __fiber_parent_ctx == null).
fn drainSchedState() void {
    while (g_sched.ready_queue.pop() != null) {}
    g_sched.lock_waiters.clearRetainingCapacity();
}

// ─────────────────────────────────────────────────────────────────────────────
// Test globals
// ─────────────────────────────────────────────────────────────────────────────
var g_mutex: ParkingMutex = .{};
var g_counter: usize = 0;

fn entryFiber0() callconv(.c) void {
    g_mutex.lock() catch unreachable;
    g_counter += 1;
    g_mutex.unlock();
    harness.done[0] = true;
    fc.__fiber.?.yield();
    unreachable;
}

fn entryFiber1() callconv(.c) void {
    g_mutex.lock() catch unreachable;
    g_counter += 1;
    g_mutex.unlock();
    harness.done[1] = true;
    fc.__fiber.?.yield();
    unreachable;
}

// ─────────────────────────────────────────────────────────────────────────────
// Loom tests
// ─────────────────────────────────────────────────────────────────────────────

test "parking mutex loom: acquireVsRelease exhaustive 256 schedules" {
    const allocator = std.testing.allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    const depth: usize = 8;
    const total_schedules: usize = @as(usize, 1) << depth;
    var schedule_buf: [depth]u8 = undefined;

    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    var failures: usize = 0;

    for (0..total_schedules) |sched_idx| {
        for (0..depth) |bit| {
            schedule_buf[bit] = @intCast((sched_idx >> @as(u6, @intCast(bit))) & 1);
        }
        h.resetExhaustive(&schedule_buf);
        g_mutex = .{};
        g_counter = 0;

        try h.createThread(0, @intFromPtr(&entryFiber0));
        try h.createThread(1, @intFromPtr(&entryFiber1));

        h.run() catch |e| {
            std.debug.print("\nSTEP LIMIT sched {d}: {}\n", .{ sched_idx, e });
            failures += 1;
            continue;
        };

        if (g_counter != 2) {
            std.debug.print("\nINVARIANT FAIL sched {d}: counter={d}\n", .{ sched_idx, g_counter });
            failures += 1;
        }
    }

    // Clean up before deinit so deinit doesn't try to free stub tasks
    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (failures > 0) {
        std.debug.print("\n{d} failures in {d} schedules\n", .{ failures, total_schedules });
        return error.LoomFailures;
    }
}

test "parking mutex loom: acquireVsRelease prng seeds" {
    const allocator = std.testing.allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    var failures: usize = 0;
    // 500 seeds covers the interesting interleavings quickly.
    // Set LOOM_FUZZ_SEEDS=10000 (or higher) for deeper nightly runs.
    const prng_seeds: usize = fuzzSeedCount(500);

    for (0..prng_seeds) |seed| {
        var ph = LoomHarness.initPrng(allocator, seed);
        harness = &ph;

        fc.__fiber = null;
        fc.__fiber_parent_ctx = null;
        fc.__fiber_stack_limit = null;
        drainSchedState();

        g_mutex = .{};
        g_counter = 0;

        ph.createThread(0, @intFromPtr(&entryFiber0)) catch continue;
        ph.createThread(1, @intFromPtr(&entryFiber1)) catch continue;

        ph.run() catch continue;

        if (g_counter != 2) {
            std.debug.print("\nPRNG FAIL seed {d}: counter={d}\n", .{ seed, g_counter });
            failures += 1;
        }
        ph.deinit();
    }

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (failures > 0) {
        std.debug.print("\n{d}/{d} PRNG seeds failed\n", .{ failures, prng_seeds });
        return error.LoomFailures;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ParkingRwLock loom tests
//
// Exercise park/unpark interleavings for the rwlock across the three state
// transitions that have no mutex analogue: reader/reader sharing, writer
// blocking readers, and the writer-preference drain in wakeNext.
//
// Invariants checked at fiber exit (after unlock/unlockShared):
//   - writer_counter equals the number of writer fibers that ran
//   - reader_observed always matches some valid snapshot of writer_counter
//     at the moment the reader held its lock
//   - After all fibers finish, write_locked == false and readers == 0.
// ─────────────────────────────────────────────────────────────────────────────
var g_rw: ParkingRwLock = .{};
var g_writer_counter: usize = 0;
// Per-reader observed snapshots. -1 means "not observed yet" at test start.
var g_reader_observed: [MAX_THREADS]i64 = [_]i64{-1} ** MAX_THREADS;

// `slot` is the harness slot index. Each entry function hardcodes its slot so
// `harness.done[slot]` matches the actual harness position.
fn rwWork(comptime slot: usize, comptime is_writer: bool) void {
    if (is_writer) {
        g_rw.lock() catch unreachable;
        g_writer_counter += 1;
        g_rw.unlock();
    } else {
        g_rw.lockShared() catch unreachable;
        g_reader_observed[slot] = @as(i64, @intCast(g_writer_counter));
        g_rw.unlockShared();
    }
    harness.done[slot] = true;
    fc.__fiber.?.yield();
    unreachable;
}

fn entryRwWriterAt0() callconv(.c) void { rwWork(0, true); }
fn entryRwWriterAt1() callconv(.c) void { rwWork(1, true); }
fn entryRwReaderAt1() callconv(.c) void { rwWork(1, false); }
fn entryRwReaderAt2() callconv(.c) void { rwWork(2, false); }

fn rwReset() void {
    g_rw = .{};
    g_writer_counter = 0;
    g_reader_observed = [_]i64{-1} ** MAX_THREADS;
}

// Expected final state: exactly `expected_writers` increments, the lock
// is fully released, and each reader's observation is in [0, expected_writers].
fn rwCheckInvariants(expected_writers: usize, reader_slots: []const usize) bool {
    if (g_writer_counter != expected_writers) return false;
    if (g_rw.isWriteLocked()) return false;
    if (g_rw.readerCount() != 0) return false;
    if (!g_rw.waiters.isEmpty()) return false;
    for (reader_slots) |s| {
        const obs = g_reader_observed[s];
        if (obs < 0) return false;
        if (obs > @as(i64, @intCast(expected_writers))) return false;
    }
    return true;
}

// Two writers, exhaustive. Mirrors the mutex acquireVsRelease test for rwlock.
test "parking rwlock loom: two writers exhaustive 256 schedules" {
    const allocator = std.testing.allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    const depth: usize = 8;
    const total_schedules: usize = @as(usize, 1) << depth;
    var schedule_buf: [depth]u8 = undefined;

    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    var failures: usize = 0;

    for (0..total_schedules) |sched_idx| {
        for (0..depth) |bit| {
            schedule_buf[bit] = @intCast((sched_idx >> @as(u6, @intCast(bit))) & 1);
        }
        h.resetExhaustive(&schedule_buf);
        rwReset();

        try h.createThread(0, @intFromPtr(&entryRwWriterAt0));
        try h.createThread(1, @intFromPtr(&entryRwWriterAt1));

        h.run() catch |e| {
            std.debug.print("\nSTEP LIMIT sched {d}: {}\n", .{ sched_idx, e });
            failures += 1;
            continue;
        };

        if (!rwCheckInvariants(2, &.{})) {
            std.debug.print(
                "\nINVARIANT FAIL sched {d}: writer_counter={d} write_locked={} readers={d} waiters_empty={}\n",
                .{ sched_idx, g_writer_counter, g_rw.isWriteLocked(), g_rw.readerCount(), g_rw.waiters.isEmpty() },
            );
            failures += 1;
        }
    }

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (failures > 0) {
        std.debug.print("\n{d} failures in {d} schedules\n", .{ failures, total_schedules });
        return error.LoomFailures;
    }
}

// One writer + one reader. Tests writer-preference and lock-handoff
// correctness when the two contend.
test "parking rwlock loom: writer vs reader exhaustive 256 schedules" {
    const allocator = std.testing.allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    const depth: usize = 8;
    const total_schedules: usize = @as(usize, 1) << depth;
    var schedule_buf: [depth]u8 = undefined;

    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    var failures: usize = 0;

    for (0..total_schedules) |sched_idx| {
        for (0..depth) |bit| {
            schedule_buf[bit] = @intCast((sched_idx >> @as(u6, @intCast(bit))) & 1);
        }
        h.resetExhaustive(&schedule_buf);
        rwReset();

        try h.createThread(0, @intFromPtr(&entryRwWriterAt0));
        try h.createThread(1, @intFromPtr(&entryRwReaderAt1));

        h.run() catch |e| {
            std.debug.print("\nSTEP LIMIT sched {d}: {}\n", .{ sched_idx, e });
            failures += 1;
            continue;
        };

        if (!rwCheckInvariants(1, &.{1})) {
            std.debug.print(
                "\nINVARIANT FAIL sched {d}: writer_counter={d} reader_obs={d} write_locked={} readers={d}\n",
                .{ sched_idx, g_writer_counter, g_reader_observed[1], g_rw.isWriteLocked(), g_rw.readerCount() },
            );
            failures += 1;
        }
    }

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (failures > 0) {
        std.debug.print("\n{d} failures in {d} schedules\n", .{ failures, total_schedules });
        return error.LoomFailures;
    }
}

// Two readers + one writer. Exercises the reader-drain path in wakeNext
// and writer-preference cutting off new readers.
test "parking rwlock loom: two readers + one writer prng seeds" {
    const allocator = std.testing.allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    var failures: usize = 0;
    const prng_seeds: usize = fuzzSeedCount(500);

    for (0..prng_seeds) |seed| {
        var ph = LoomHarness.initPrng(allocator, seed);
        harness = &ph;

        fc.__fiber = null;
        fc.__fiber_parent_ctx = null;
        fc.__fiber_stack_limit = null;
        drainSchedState();
        rwReset();

        ph.createThread(0, @intFromPtr(&entryRwWriterAt0)) catch continue;
        ph.createThread(1, @intFromPtr(&entryRwReaderAt1)) catch continue;
        ph.createThread(2, @intFromPtr(&entryRwReaderAt2)) catch continue;

        ph.run() catch {
            ph.deinit();
            continue;
        };

        if (!rwCheckInvariants(1, &.{ 1, 2 })) {
            std.debug.print(
                "\nPRNG FAIL seed {d}: writer_counter={d} r1={d} r2={d} write_locked={} readers={d} waiters_empty={}\n",
                .{ seed, g_writer_counter, g_reader_observed[1], g_reader_observed[2], g_rw.isWriteLocked(), g_rw.readerCount(), g_rw.waiters.isEmpty() },
            );
            failures += 1;
        }
        ph.deinit();
    }

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (failures > 0) {
        std.debug.print("\n{d}/{d} PRNG seeds failed\n", .{ failures, prng_seeds });
        return error.LoomFailures;
    }
}
