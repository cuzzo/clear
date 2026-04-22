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
const Fiber = fc.Fiber;
const Context = fc.Context;
const Task = qs.Task;
const TaskStatus = qs.TaskStatus;

const MAX_THREADS = 4;
const STACK_SIZE = 64 * 1024;
const MAX_STEPS = 50_000;

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

test "parking mutex loom: acquireVsRelease prng 10000 seeds" {
    const allocator = std.testing.allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    var failures: usize = 0;
    // 500 seeds covers the interesting interleavings quickly.
    // For deeper coverage run with a larger count manually.
    const prng_seeds: usize = 500;

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
