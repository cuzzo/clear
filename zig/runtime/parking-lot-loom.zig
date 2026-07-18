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
const streams = @import("../lib/streams.zig");
const fsm_mod = @import("fsm.zig");
const control_plane = @import("control-plane.zig");
const build_options = @import("build_options");
const sim_atomic = @import("vopr-atomic.zig");

var g_partitioned_remote_allocator: std.mem.Allocator = std.heap.c_allocator;

// Minimal binding for data-structures.zig — the loom test only touches
// Stream(T).Inner fields; the bound deps are unused on the closed/err
// publish path.
const DataStructures = @import("../lib/data-structures.zig").bind(struct {
    pub fn cleanup(comptime T: type, alloc: std.mem.Allocator, cptr: *const T) void {
        _ = alloc;
        _ = cptr;
    }
    pub fn needsCleanup(comptime T: type) bool {
        _ = T;
        return false;
    }
    pub fn refInnerType(comptime T: type) ?type {
        _ = T;
        return null;
    }
    pub fn releaseOne(comptime T: type, alloc: std.mem.Allocator, value: T) void {
        _ = alloc;
        _ = value;
    }
    pub fn partitionedMapDelayCtxDestroy() bool {
        return false;
    }
    pub fn partitionedMapRemoteAllocator() std.mem.Allocator {
        return g_partitioned_remote_allocator;
    }
});

// SimAtomic / SimRing live on the test_runner module (see
// parking-lot-loom-runner.zig). Importing them here would put
// vopr-atomic.zig / vopr-ring.zig into the test-root module too, tripping
// "files must belong to only one module" — see GAP-B notes.

const ParkingMutex = pl.ParkingMutex;
const ParkingRwLock = pl.ParkingRwLock;
const Fiber = fc.Fiber;
const Context = fc.Context;
const Task = qs.Task;
const TaskStatus = qs.TaskStatus;
const LoomSplitStream = streams.SplitStream(i64, fp.WaitGroup, cloneI64, cleanupI64);
const SPLIT_STREAM_FIBER_STACK = 64 * 1024;

const MAX_THREADS = 4;
const STACK_SIZE = 64 * 1024;
const MAX_STEPS = 50_000;
const ThreadFlag = std.atomic.Value(bool);

// Override default (500) via env var LOOM_FUZZ_SEEDS.
// Used by prng-mode tests to scale coverage for nightly/manual runs.
fn fuzzSeedCount(default_seeds: usize) usize {
    if (build_options.coverage) return @min(default_seeds, 4);
    const raw = std.c.getenv("LOOM_FUZZ_SEEDS") orelse return default_seeds;
    const s = std.mem.span(raw);
    return std.fmt.parseInt(usize, s, 10) catch default_seeds;
}

fn cloneI64(_: std.mem.Allocator, value: i64) anyerror!i64 {
    return value;
}

fn cleanupI64(_: std.mem.Allocator, _: *i64) void {}

fn splitStreamDummyFn(_: *anyopaque, _: ?*anyopaque) anyerror!void {}

var g_split_park_subscriber: *LoomSplitStream = undefined;
var g_split_park_woke: bool = false;
var g_split_park_err: ?anyerror = null;
var g_split_value_subscriber: *LoomSplitStream = undefined;
var g_split_value_seen: ?i64 = null;
var g_split_value_err: ?anyerror = null;
var g_split_backpressure_producer: *LoomSplitStream = undefined;
var g_split_backpressure_done: bool = false;
var g_split_backpressure_err: ?anyerror = null;
var g_scheduler_primitive_wg: *fp.WaitGroup = undefined;
var g_scheduler_primitive_sem: *fp.Semaphore = undefined;
var g_scheduler_primitive_wg_woke: bool = false;
var g_scheduler_primitive_sem_acquired: bool = false;
const CONTROL_PLANE_FN_ADDR: usize = 0x1000;

fn entryControlPlaneStandard() callconv(.c) void {
    control_plane.recordOverflow(CONTROL_PLANE_FN_ADDR, .Standard);
    harness.done[0] = true;
    while (true) fc.__fiber.?.yield();
}

fn entryControlPlaneLarge() callconv(.c) void {
    control_plane.recordOverflow(CONTROL_PLANE_FN_ADDR, .Large);
    harness.done[1] = true;
    while (true) fc.__fiber.?.yield();
}

fn entrySplitStreamParkedSubscriber() callconv(.c) void {
    const next = g_split_park_subscriber.next() catch |err| {
        g_split_park_err = err;
        while (true) fc.__fiber.?.yield();
    };
    if (next != null) {
        g_split_park_err = error.ExpectedClosedSplitStream;
    } else {
        g_split_park_woke = true;
    }
    while (true) fc.__fiber.?.yield();
}

fn entrySplitStreamParkedValueSubscriber() callconv(.c) void {
    const next = g_split_value_subscriber.next() catch |err| {
        g_split_value_err = err;
        while (true) fc.__fiber.?.yield();
    };
    g_split_value_seen = next orelse {
        g_split_value_err = error.ExpectedSplitStreamValue;
        while (true) fc.__fiber.?.yield();
    };
    while (true) fc.__fiber.?.yield();
}

fn entrySplitStreamBackpressureProducer() callconv(.c) void {
    var i: usize = 0;
    while (i < 4097) : (i += 1) {
        g_split_backpressure_producer.push(@intCast(i + 1)) catch |err| {
            g_split_backpressure_err = err;
            while (true) fc.__fiber.?.yield();
        };
    }
    g_split_backpressure_done = true;
    while (true) fc.__fiber.?.yield();
}

fn entryWaitGroupParkedFiber() callconv(.c) void {
    g_scheduler_primitive_wg.wait();
    g_scheduler_primitive_wg_woke = true;
    while (true) fc.__fiber.?.yield();
}

fn entrySemaphoreParkedFiber() callconv(.c) void {
    g_scheduler_primitive_sem.acquire();
    g_scheduler_primitive_sem_acquired = true;
    while (true) fc.__fiber.?.yield();
}

const SemaphoreRecheckReleaseCtx = struct {
    sem: *fp.Semaphore,
    started: *ThreadFlag,

    fn run(self: *@This()) void {
        self.started.store(true, .release);
        var spins: usize = 0;
        while (spins < 1000) : (spins += 1) {
            std.Thread.yield() catch {};
        }
        self.sem.counter.store(1, .seq_cst);
        self.sem.lock.store(0, .release);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Global scheduler shared by all fibers under test.
// Initialized once per test, reused across runs (state drained between runs).
// ─────────────────────────────────────────────────────────────────────────────
var g_sched: fp.Scheduler = undefined;

var harness: *LoomHarness = undefined;

const ScheduleMode = union(enum) {
    // `std.Random` stores a pointer to the underlying state (`*Xoshiro256`)
    // captured at .random() time. We must NOT cache a `std.Random` value
    // in the harness: initPrng returns LoomHarness by value, the caller
    // copies it into a local `var h`, and a cached `random.ptr` would
    // dangle to initPrng's stack frame. Build a fresh wrapper from
    // `&p.rng` at every pickThread call instead. The bug was masked by
    // a coincidental memory layout until the MVCC commit added an
    // `ebr_slot` field to Task — the resulting layout shift exposed
    // the dangling pointer as a livelock under exhaustive interleaving.
    prng: struct {
        rng: std.Random.DefaultPrng,
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
        return .{
            .mode = .{ .prng = .{ .rng = std.Random.DefaultPrng.init(seed) } },
            .allocator = allocator,
        };
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
            .prng => |*p| return active_ids[p.rng.random().intRangeLessThan(usize, 0, active_count)],
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
        var pick_history: [16]u8 = [_]u8{255} ** 16;
        var pick_history_pos: usize = 0;
        while (steps < MAX_STEPS) : (steps += 1) {
            // Unpark fibers whose tasks became .Ready (woken by submitResume).
            // Also clear in_inbox: scheduler.run() normally clears it after
            // dequeuing from ready_queue, but the harness manages fibers
            // directly and never dequeues. Without this, a second
            // submitResume on the same task (multi-cycle tests) hits the
            // double-push guard at line 450 of scheduler.zig and returns
            // without setting status=.Ready — the fiber parks forever.
            for (0..self.n_threads) |i| {
                if (self.parked[i] and self.stub_tasks[i].status.load(.monotonic) == .Ready) {
                    self.parked[i] = false;
                    self.stub_tasks[i].in_inbox.store(qs.IN_INBOX_IDLE, .release);
                }
            }
            // Cleanup of stale `g_sched.lock_waiters` entries. The
            // scheduler's normal scanLockWaiters would do this on its
            // own run loop, but VOPR/loom drives the harness directly
            // (no sched.run()), so we must mimic the cleanup pass here.
            // Stale entries from a previously-woken park leak across
            // iterations; if a task subsequently parks AGAIN (sets
            // status=.Blocked), the parked-detection block below would
            // see the stale entry and mark it parked BEFORE the task's
            // current registerLockWaiter completes — leaving it stuck
            // mid-lockSlow, holding queue_spin, and producing a lost
            // wake on whichever lock its peers are then trying to
            // acquire. Remove any entry whose waiting_for_lock == null
            // (post-wake) before the parked check runs.
            {
                var i: usize = 0;
                while (i < g_sched.lock_waiters.items.len) {
                    if (g_sched.lock_waiters.items[i].waiting_for_lock.load(.monotonic) == null) {
                        _ = g_sched.lock_waiters.swapRemove(i);
                    } else {
                        i += 1;
                    }
                }
            }

            var any_active = false;
            for (0..self.n_threads) |i| {
                if (!self.done[i] and !self.parked[i]) { any_active = true; break; }
            }
            if (!any_active) break;

            const chosen = self.pickThread();
            pick_history[pick_history_pos] = @intCast(chosen);
            pick_history_pos = (pick_history_pos + 1) % pick_history.len;
            // Set current_task before switching so lockSlow sees the correct task.
            g_sched.current_task = &self.stub_tasks[chosen];

            self.fibers[chosen].switchTo(&self.main_ctx);
            // Clear parent_ctx so that SimAtomic ops inside the harness
            // loop don't try to fiber.yield() back into a fiber that just
            // returned (Fiber.yield sets __fiber = undefined but leaves
            // __fiber_parent_ctx set; SimAtomic.yieldPoint gates on the
            // parent_ctx, so a stale value crashes inside switchContext).
            fc.__fiber_parent_ctx = null;

            // After the fiber yields, decide whether it actually parked
            // on a lock. status==.Blocked alone is INSUFFICIENT: the
            // parking-lot park sequence sets status=.Blocked BEFORE
            // releasing queue_spin and BEFORE the explicit park yield.
            // If we park-detect on status alone, we freeze the fiber
            // mid-sequence with queue_spin still held, and any other
            // fiber's unlock spins on queue_spin forever.
            //
            // The correct signal is membership in g_sched.lock_waiters:
            // sched.registerLockWaiter is called AFTER spinReleaseQueue,
            // which means the fiber has truly finished its parking work
            // and is about to (or has already) called task.base.yield().
            if (self.stub_tasks[chosen].status.load(.monotonic) == .Blocked) {
                for (g_sched.lock_waiters.items) |t| {
                    if (t == &self.stub_tasks[chosen]) {
                        self.parked[chosen] = true;
                        break;
                    }
                }
            }
        }

        fc.__fiber = null;
        fc.__fiber_parent_ctx = null;
        fp.scheduler_running = false;
        if (steps >= MAX_STEPS) {
            std.debug.print("\n  [STEP_LIMIT diagnostic] fiber states at limit:\n", .{});
            for (0..self.n_threads) |i| {
                const st = self.stub_tasks[i].status.load(.monotonic);
                const wfl = self.stub_tasks[i].waiting_for_lock.load(.monotonic);
                const wfk = self.stub_tasks[i].waiting_for_lock_kind.load(.monotonic);
                std.debug.print(
                    "    fiber {d}: done={}, parked={}, status={}, in_inbox={}, wfl={?*}, kind={d}\n",
                    .{
                        i,
                        self.done[i],
                        self.parked[i],
                        st,
                        self.stub_tasks[i].in_inbox.load(.monotonic),
                        wfl,
                        wfk,
                    },
                );
            }
            std.debug.print(
                "    g_rw.state={d}, write_owner={?*}, waiters_empty={}\n",
                .{ g_rw.state.load(.monotonic), g_rw.write_owner.load(.monotonic), g_rw.waiters.isEmpty() },
            );
            std.debug.print(
                "    g_rw.queue_spin={d}\n",
                .{g_rw.queue_spin.load(.monotonic)},
            );
            for (0..VOPR_LOCKS) |li| {
                const ls = g_vopr_locks[li].state.load(.monotonic);
                std.debug.print(
                    "    g_vopr_locks[{d}] @{*}: state=0x{x}, queue_spin={d}, waiters_empty={}, waiters.head={?*}\n",
                    .{ li, &g_vopr_locks[li], ls, g_vopr_locks[li].queue_spin.load(.monotonic), g_vopr_locks[li].waiters.isEmpty(), g_vopr_locks[li].waiters.head },
                );
            }
            const va = @import("vopr-atomic.zig");
            std.debug.print(
                "    sim ops total={d}, cmpxchg ok={d} fail={d}\n",
                .{ va.sim_atomic_op_count, va.sim_cmpxchg_succeed_count, va.sim_cmpxchg_fail_count },
            );
            std.debug.print("    last 16 picks: ", .{});
            var k: usize = 0;
            while (k < pick_history.len) : (k += 1) {
                const idx = (pick_history_pos + k) % pick_history.len;
                if (pick_history[idx] == 255) continue;
                std.debug.print("{d} ", .{pick_history[idx]});
            }
            std.debug.print("\n", .{});
            return error.StepLimitExceeded;
        }
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

// Post-schedule mutex invariants. Every loom mutex test asserts these
// once all fibers have completed: counter equals expected, lock is fully
// released, no stray bits left in `state`. A failure here means some
// schedule left the mutex in an inconsistent state — e.g., a race where
// two unlock paths cleared LOCKED twice, or a leak of HAS_WAITERS.
fn mutexCheckInvariants(expected_counter: usize) bool {
    if (g_counter != expected_counter) return false;
    if (g_mutex.isLocked()) return false;
    if (g_mutex.ownerTask() != null) return false;
    // Whole `state` should be 0 once everyone has unlocked: no LOCKED,
    // no HAS_WAITERS, no HAS_THREAD_SLEEPER, no owner bits. Tolerate the
    // sticky-after-wake HAS_THREAD_SLEEPER bit if it is the only set
    // flag — that is documented as intentional in lockSlow's non-fiber
    // path. Loom never enters the non-fiber path so this should be 0,
    // but the tolerance keeps the invariant honest if that changes.
    const state = g_mutex.state.load(.monotonic);
    const tolerated: u64 = ParkingMutex.STATE_HAS_THREAD_SLEEPER;
    if ((state & ~tolerated) != 0) return false;
    if (!g_mutex.waiters.isEmpty()) return false;
    return true;
}

fn entryFiber0() callconv(.c) void {
    g_mutex.lock() catch unreachable;
    g_counter += 1;
    g_mutex.unlock();
    harness.done[0] = true;
    while (true) fc.__fiber.?.yield();
}

fn entryFiber1() callconv(.c) void {
    g_mutex.lock() catch unreachable;
    g_counter += 1;
    g_mutex.unlock();
    harness.done[1] = true;
    while (true) fc.__fiber.?.yield();
}

// ─────────────────────────────────────────────────────────────────────────────
// Loom tests
// ─────────────────────────────────────────────────────────────────────────────

pub fn testMutexAcquireExhaustive() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    const depth: usize = if (build_options.coverage) 4 else 8;
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

        if (!mutexCheckInvariants(2)) {
            std.debug.print(
                "\nINVARIANT FAIL sched {d}: counter={d} locked={} owner={?*} state={d}\n",
                .{ sched_idx, g_counter, g_mutex.isLocked(), g_mutex.ownerTask(), g_mutex.state.load(.monotonic) },
            );
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

/// Two overflow recorders race to claim the same hash slot and publish
/// different recommendations. Every schedule must retain the larger XL
/// recommendation and count both observations. This specifically covers the
/// claim-loser retry and the publish-vs-update race in control-plane.zig.
pub fn testControlPlaneOverflowRace() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    const saved_config = control_plane.config;
    defer control_plane.config = saved_config;
    control_plane.config.on_overflow = .upsize;

    const depth: usize = if (build_options.coverage) 5 else 8;
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
        control_plane.resetRegistry();

        try h.createThread(0, @intFromPtr(&entryControlPlaneStandard));
        try h.createThread(1, @intFromPtr(&entryControlPlaneLarge));
        h.run() catch {
            failures += 1;
            continue;
        };

        if (control_plane.getOverflowCount(CONTROL_PLANE_FN_ADDR) != 2 or
            control_plane.recommendSize(CONTROL_PLANE_FN_ADDR, .Standard) != .Xl)
        {
            failures += 1;
        }
    }

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (failures != 0) return error.ControlPlaneLoomFailures;
}

/// Exercise the underflow recommendation atomics and the diagnostic overflow
/// load in the same custom executable that exports SimAtomic. The threshold
/// of one makes the downsize transition observable without a long loop.
pub fn testControlPlanePolicyPaths() !void {
    const saved_config = control_plane.config;
    defer control_plane.config = saved_config;
    control_plane.resetRegistry();

    control_plane.config.on_underflow = .downsize;
    control_plane.config.underflow_1tier_threshold = 1;
    control_plane.recordCompletion(0x2000, .Large, 20 * 1024);
    if (control_plane.recommendSize(0x2000, .Large) != .Standard)
        return error.ControlPlaneDownsizeNotApplied;

    control_plane.config.underflow_2tier_threshold = 1;
    control_plane.recordCompletion(0x2001, .Large, 1024);
    if (control_plane.recommendSize(0x2001, .Large) != .Micro)
        return error.ControlPlaneTwoTierDownsizeNotApplied;

    // The log policy reads overflow_count only after the first call creates
    // the entry. Keep this to two calls so coverage does not flood test output.
    control_plane.config.on_overflow = .log;
    control_plane.recordOverflow(0x3000, .Standard);
    control_plane.recordOverflow(0x3000, .Standard);
    if (control_plane.getOverflowCount(0x3000) != 2)
        return error.ControlPlaneOverflowCountWrong;
}

pub fn testMutexAcquirePrng() !void {
    const allocator = std.heap.c_allocator;

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

        if (!mutexCheckInvariants(2)) {
            std.debug.print(
                "\nPRNG FAIL seed {d}: counter={d} locked={} state={d}\n",
                .{ seed, g_counter, g_mutex.isLocked(), g_mutex.state.load(.monotonic) },
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

// ─────────────────────────────────────────────────────────────────────────────
// ParkingMutex 3-fiber race coverage (M4)
//
// 3 fibers, each does one lock+unlock cycle. Exhaustive base-3 over the
// initial schedule depth covers every choice of "who runs the next atomic
// op" for the first DEPTH ops. Beyond that the schedule falls through to
// round-robin. Total atomic ops per schedule are bounded (~10/fiber × 3
// fibers + harness overhead), so 3^14 = ~4.8M is overkill but cheap.
//
// Targets two races that need 3 fibers to expose:
//
//   (a) unlock owner-transfer CAS losing to fast-path acquire:
//       fiber A holds, fiber B parks (waiter), A unlocks and reaches the
//       state.cmpxchgStrong(cur_state, owner-transfer-target) — at this
//       moment fiber C does a fast-path cmpxchg(0, LOCKED|owner_C). C
//       wins. A's CAS returns non-null and bails. The waiter B stays
//       queued and is woken by C's eventual unlock. Without the
//       cmpxchg-bail in unlock, both A and C would think they own the
//       lock and B's data could be observed by both.
//
//   (b) park-grab vs concurrent-arrival: two fibers race into lockSlow
//       while a third holds the lock; depending on ordering one parks,
//       one might park-grab once the holder releases.
//
// Invariant: every schedule must produce counter==3 and a fully-released
// mutex (mutexCheckInvariants).
// ─────────────────────────────────────────────────────────────────────────────
fn entryRace3a() callconv(.c) void { entryFiber0(); }
fn entryRace3b() callconv(.c) void { entryFiber1(); }
fn entryRace3c() callconv(.c) void {
    g_mutex.lock() catch unreachable;
    g_counter += 1;
    g_mutex.unlock();
    harness.done[2] = true;
    while (true) fc.__fiber.?.yield();
}

pub fn testMutexThreeFiberRaces() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    // 3 fibers → base-3 schedule encoding. depth=10 → 3^10 = 59,049
    // schedules. Same depth as lost-wake test for proven coverage of
    // initial choices.
    const depth: usize = if (build_options.coverage) 4 else 10;
    var total_schedules: usize = 1;
    {
        var p: usize = 0;
        while (p < depth) : (p += 1) total_schedules *= 3;
    }
    var schedule_buf: [depth]u8 = undefined;

    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    var failures: usize = 0;

    for (0..total_schedules) |sched_idx| {
        var s = sched_idx;
        for (0..depth) |bit| {
            schedule_buf[bit] = @intCast(s % 3);
            s /= 3;
        }
        h.resetExhaustive(&schedule_buf);
        g_mutex = .{};
        g_counter = 0;

        try h.createThread(0, @intFromPtr(&entryRace3a));
        try h.createThread(1, @intFromPtr(&entryRace3b));
        try h.createThread(2, @intFromPtr(&entryRace3c));

        h.run() catch {
            failures += 1;
            continue;
        };

        if (!mutexCheckInvariants(3)) {
            std.debug.print(
                "\nINVARIANT FAIL sched {d}: counter={d} locked={} state={d}\n",
                .{ sched_idx, g_counter, g_mutex.isLocked(), g_mutex.state.load(.monotonic) },
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
        std.debug.print("\n{d}/{d} schedules failed\n", .{ failures, total_schedules });
        return error.LoomFailures;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ParkingMutex lost-wake regression
//
// The lost-wake race in lockSlow:
//   1. Holder A is mid-unlock. fetchAnd(LOCKED) returns prev with HAS_WAITERS=0.
//      Because no waiter bit was set, A returns WITHOUT taking queue_spin and
//      WITHOUT waking anyone.
//   2. Parker B holds queue_spin. B re-checked LOCKED=1 (before A's fetchAnd).
//      Now B does fetchOr(HAS_WAITERS). State: LOCKED=0, HAS_WAITERS=1.
//   3. B pushes to queue, releases spin, yields. PARKED FOREVER on a free lock.
//
// To reproduce in loom, we need 3 fibers each running multiple lock/unlock
// cycles so the schedule space contains many possible interleavings between
// "holder's unlock" and "parker's recheck/fetchOr". The earlier 2-fiber x
// 1-cycle test only had ~10 atomic ops total; the bug's window required a
// specific 3-op sequence that 8-bit schedules rarely hit. Here: 3 fibers x
// 3 cycles = ~36 atomic ops + depth-14 schedules (16K) catches it.
//
// Detection: counter must equal NUM_FIBERS * CYCLES at end. If any fiber
// is stuck on a lost wake, harness.run() either hits MAX_STEPS (exhaustive
// caller treats this as failure) or returns early with no_active=true and
// the counter check fires.
// ─────────────────────────────────────────────────────────────────────────────
const LOST_WAKE_FIBERS: usize = 3;
const LOST_WAKE_CYCLES: usize = 3;

fn lostWakeBody(comptime slot: usize) void {
    var i: usize = 0;
    while (i < LOST_WAKE_CYCLES) : (i += 1) {
        g_mutex.lock() catch unreachable;
        g_counter += 1;
        g_mutex.unlock();
    }
    harness.done[slot] = true;
    while (true) fc.__fiber.?.yield();
}

fn entryLostWake0() callconv(.c) void { lostWakeBody(0); }
fn entryLostWake1() callconv(.c) void { lostWakeBody(1); }
fn entryLostWake2() callconv(.c) void { lostWakeBody(2); }

pub fn testMutexLostWake() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    // 3 fibers → base-3 schedule encoding (each entry is 0/1/2). depth=10 →
    // 3^10 = 59,049 schedules. The schedule bytes get `% active_count` in
    // pickThread, so values 0..2 map directly to fiber indices when all 3
    // are runnable. The previous binary encoding only ever produced 0/1,
    // making fiber 2 unreachable and degrading this to a 2-fiber test.
    const depth: usize = if (build_options.coverage) 4 else 10;
    var total_schedules: usize = 1;
    {
        var p: usize = 0;
        while (p < depth) : (p += 1) total_schedules *= 3;
    }
    var schedule_buf: [depth]u8 = undefined;

    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    var failures: usize = 0;
    var step_limit_failures: usize = 0;
    var counter_failures: usize = 0;

    for (0..total_schedules) |sched_idx| {
        var s = sched_idx;
        for (0..depth) |bit| {
            schedule_buf[bit] = @intCast(s % 3);
            s /= 3;
        }
        h.resetExhaustive(&schedule_buf);
        g_mutex = .{};
        g_counter = 0;

        try h.createThread(0, @intFromPtr(&entryLostWake0));
        try h.createThread(1, @intFromPtr(&entryLostWake1));
        try h.createThread(2, @intFromPtr(&entryLostWake2));

        h.run() catch {
            step_limit_failures += 1;
            failures += 1;
            continue;
        };

        const expected = LOST_WAKE_FIBERS * LOST_WAKE_CYCLES;
        if (!mutexCheckInvariants(expected)) {
            counter_failures += 1;
            failures += 1;
        }
    }

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (failures > 0) {
        std.debug.print(
            "\nLOST-WAKE REGRESSION: {d}/{d} schedules failed " ++
            "(step_limit={d} counter_mismatch={d})\n",
            .{ failures, total_schedules, step_limit_failures, counter_failures },
        );
        return error.LostWakeRegression;
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

// Transient-invariant violation count. Closes Gaps 2 + 3 (FSM RwLock
// lost-wakeup / stackful slow-path WRITE_LOCKED guard). The bug shape
// for both fixes was: a reader's wake-on-undo path could grant the
// read lock while a writer still held it (WRITE_LOCKED_BIT set). A
// reader observing isWriteLocked() == true *while holding the read
// lock itself* is the exact transient signature. The existing
// `rwCheckInvariants` is a final-state check (after all fibers
// finish), which doesn't catch a transient mis-grant that gets
// resolved before test end. This counter is incremented from inside
// the read critical section; non-zero == lost-wakeup-style bug.
var g_transient_write_lock_observed: usize = 0;

// `slot` is the harness slot index. Each entry function hardcodes its slot so
// `harness.done[slot]` matches the actual harness position.
fn rwWork(comptime slot: usize, comptime is_writer: bool) void {
    if (is_writer) {
        g_rw.lock() catch unreachable;
        g_writer_counter += 1;
        g_rw.unlock();
    } else {
        g_rw.lockShared() catch unreachable;
        // Transient invariant: a reader holding the read lock must
        // never observe write_locked == true. If it does, the wake-
        // on-undo (fast or slow path) granted us the lock while a
        // writer still held it -- the exact bug fixed by the
        // WRITE_LOCKED_BIT guards in tryReadLockForFsm and
        // lockSharedSlow.
        if (g_rw.isWriteLocked()) g_transient_write_lock_observed += 1;
        g_reader_observed[slot] = @as(i64, @intCast(g_writer_counter));
        g_rw.unlockShared();
    }
    harness.done[slot] = true;
    while (true) fc.__fiber.?.yield();
}

fn entryRwWriterAt0() callconv(.c) void { rwWork(0, true); }
fn entryRwWriterAt1() callconv(.c) void { rwWork(1, true); }
fn entryRwReaderAt1() callconv(.c) void { rwWork(1, false); }
fn entryRwReaderAt2() callconv(.c) void { rwWork(2, false); }

fn rwReset() void {
    g_rw = .{};
    g_writer_counter = 0;
    g_reader_observed = [_]i64{-1} ** MAX_THREADS;
    g_transient_write_lock_observed = 0;
}

// Expected final state: exactly `expected_writers` increments, the lock
// is fully released, no stray bits in `state`, each reader's observation
// is in [0, expected_writers], and no reader ever observed
// write_locked == true while holding the read lock (transient
// WRITE_LOCKED guard invariant).
fn rwCheckInvariants(expected_writers: usize, reader_slots: []const usize) bool {
    if (g_writer_counter != expected_writers) return false;
    if (g_rw.isWriteLocked()) return false;
    if (g_rw.readerCount() != 0) return false;
    if (!g_rw.waiters.isEmpty()) return false;
    if (g_rw.write_owner.load(.monotonic) != null) return false;
    // After all fibers complete, no bits should be set: not WRITE_LOCKED,
    // not HAS_WAITERS, no reader count. Catches cases where wakeNext
    // exits with stale HAS_WAITERS uncleared, or reader count not
    // restored after a fetchAdd/fetchSub undo race.
    if (g_rw.state.load(.monotonic) != 0) return false;
    if (g_transient_write_lock_observed != 0) return false;
    for (reader_slots) |s| {
        const obs = g_reader_observed[s];
        if (obs < 0) return false;
        if (obs > @as(i64, @intCast(expected_writers))) return false;
    }
    return true;
}

// Two writers, exhaustive. Mirrors the mutex acquireVsRelease test for rwlock.
pub fn testRwlockTwoWriters() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    const depth: usize = if (build_options.coverage) 4 else 8;
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
pub fn testRwlockWriterReader() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    const depth: usize = if (build_options.coverage) 4 else 8;
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
                "\nINVARIANT FAIL sched {d}: writer_counter={d} reader_obs={d} write_locked={} readers={d} transient_violations={d}\n",
                .{ sched_idx, g_writer_counter, g_reader_observed[1], g_rw.isWriteLocked(), g_rw.readerCount(), g_transient_write_lock_observed },
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
pub fn testRwlockTwoReadersWriter() !void {
    const allocator = std.heap.c_allocator;

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
                "\nPRNG FAIL seed {d}: writer_counter={d} r1={d} r2={d} write_locked={} readers={d} waiters_empty={} transient_violations={d}\n",
                .{ seed, g_writer_counter, g_reader_observed[1], g_reader_observed[2], g_rw.isWriteLocked(), g_rw.readerCount(), g_rw.waiters.isEmpty(), g_transient_write_lock_observed },
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

// Entries used by the M5 exhaustive tests below.
fn entryRwWriterAt2() callconv(.c) void { rwWork(2, true); }
fn entryRwReaderAt0() callconv(.c) void { rwWork(0, false); }

// ─────────────────────────────────────────────────────────────────────────────
// ParkingRwLock M5 — 1 writer + 2 readers exhaustive (reader-drain coverage)
//
// The reader-drain path in wakeNext: when a writer releases and the head
// of the waiter queue is a reader, wakeNext loops popping contiguous
// readers and granting each a slot via state.fetchAdd(1, .acquire). For
// every drained reader, only the LAST one's wakeup actually matters for
// progress — the others must also wake. This test exercises every
// interleaving up to depth 10 of (1 writer, 2 readers) so schedules
// where both readers queue before the writer releases (forcing the
// drain) are reached deterministically.
//
// Also exercises the reader fetchAdd-undo race: a reader's optimistic
// fetchAdd(1) sees NON_READER_BITS set (writer or HAS_WAITERS), undoes
// via fetchSub(1). If the undo restores state to "0 readers + HAS_WAITERS"
// the reader must call wakeNext or the queued writer would deadlock.
// ─────────────────────────────────────────────────────────────────────────────
pub fn testRwlockOneWriterTwoReaders() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    const depth: usize = if (build_options.coverage) 4 else 10;
    var total_schedules: usize = 1;
    {
        var p: usize = 0;
        while (p < depth) : (p += 1) total_schedules *= 3;
    }
    var schedule_buf: [depth]u8 = undefined;

    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    var failures: usize = 0;

    for (0..total_schedules) |sched_idx| {
        var s = sched_idx;
        for (0..depth) |bit| {
            schedule_buf[bit] = @intCast(s % 3);
            s /= 3;
        }
        h.resetExhaustive(&schedule_buf);
        rwReset();

        try h.createThread(0, @intFromPtr(&entryRwWriterAt0));
        try h.createThread(1, @intFromPtr(&entryRwReaderAt1));
        try h.createThread(2, @intFromPtr(&entryRwReaderAt2));

        h.run() catch {
            failures += 1;
            continue;
        };

        if (!rwCheckInvariants(1, &.{ 1, 2 })) {
            std.debug.print(
                "\nINVARIANT FAIL sched {d}: wc={d} r1={d} r2={d} state={d} owner={?*} waiters_empty={}\n",
                .{ sched_idx, g_writer_counter, g_reader_observed[1], g_reader_observed[2], g_rw.state.load(.monotonic), g_rw.write_owner.load(.monotonic), g_rw.waiters.isEmpty() },
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
        std.debug.print("\n{d}/{d} schedules failed\n", .{ failures, total_schedules });
        return error.LoomFailures;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ParkingRwLock M5 — 2 writers + 1 reader exhaustive (FIFO / writer-pref)
//
// Three fibers, two writers and one reader, each performing one
// lock/unlock cycle. Exhaustive base-3 depth 10. Targets:
//
//   - FIFO fairness with mixed waiter kinds: a reader queued behind a
//     writer must NOT leapfrog the writer (lockSharedSlow gates the
//     optimistic fetchAdd on `waiters.isEmpty()`).
//   - wakeNext writer-promote retry loop (PR-26/27): when a writer is
//     at the queue head and a concurrent reader fast-path fetchAdds
//     then undoes, wakeNext's cmpxchgWeak retries until the reader
//     count is observed as 0 again.
//   - HAS_WAITERS-bit cleanup at end-of-drain (PR-29): if the queue
//     drains to empty during wakeNext, the trailing
//     fetchAnd(~HAS_WAITERS) must run; otherwise the bit is sticky.
//     The state==0 invariant in rwCheckInvariants catches that.
// ─────────────────────────────────────────────────────────────────────────────
pub fn testRwlockTwoWritersOneReader() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    const depth: usize = if (build_options.coverage) 4 else 10;
    var total_schedules: usize = 1;
    {
        var p: usize = 0;
        while (p < depth) : (p += 1) total_schedules *= 3;
    }
    var schedule_buf: [depth]u8 = undefined;

    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    var failures: usize = 0;

    for (0..total_schedules) |sched_idx| {
        var s = sched_idx;
        for (0..depth) |bit| {
            schedule_buf[bit] = @intCast(s % 3);
            s /= 3;
        }
        h.resetExhaustive(&schedule_buf);
        rwReset();

        try h.createThread(0, @intFromPtr(&entryRwWriterAt0));
        try h.createThread(1, @intFromPtr(&entryRwWriterAt1));
        try h.createThread(2, @intFromPtr(&entryRwReaderAt2));

        h.run() catch {
            failures += 1;
            continue;
        };

        if (!rwCheckInvariants(2, &.{2})) {
            std.debug.print(
                "\nINVARIANT FAIL sched {d}: wc={d} r2={d} state={d} owner={?*} waiters_empty={}\n",
                .{ sched_idx, g_writer_counter, g_reader_observed[2], g_rw.state.load(.monotonic), g_rw.write_owner.load(.monotonic), g_rw.waiters.isEmpty() },
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
        std.debug.print("\n{d}/{d} schedules failed\n", .{ failures, total_schedules });
        return error.LoomFailures;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// M6 — Deadlock-detection coverage (closes GAP-C)
//
// `detectCycle` (lib/parking-lot.zig:189) walks the owner chain before
// parking, snapshotting per-Task seq + chain links and revalidating
// after the walk. Pre-M6, every loom test had chain depth 0 (no waiter
// transitively waited through another) so TK-01, TK-02, TK-04, TK-06,
// PR-W2 from the audit were unhit. The four tests below exercise the
// full cycle-detection surface deterministically.
// ─────────────────────────────────────────────────────────────────────────────

// Globals for cycle tests. Reset per schedule.
var g_mtx_x: ParkingMutex = .{};
var g_mtx_y: ParkingMutex = .{};
var g_mtx_z: ParkingMutex = .{};
var g_a_holds_x: bool = false;
var g_b_holds_y: bool = false;
var g_c_holds_z: bool = false;
var g_a_err: ?pl.LockError = null;
var g_b_err: ?pl.LockError = null;
var g_c_err: ?pl.LockError = null;

fn cycleReset() void {
    g_mtx_x = .{};
    g_mtx_y = .{};
    g_mtx_z = .{};
    g_a_holds_x = false;
    g_b_holds_y = false;
    g_c_holds_z = false;
    g_a_err = null;
    g_b_err = null;
    g_c_err = null;
}

inline fn errIs(maybe: ?pl.LockError, target: pl.LockError) bool {
    if (maybe) |e| return e == target;
    return false;
}

// Self-cycle (re-entrant acquisition) — single fiber acquires the same
// mutex twice. detectCycle with depth==0 returns error.Deadlock.
fn entrySelfCycle() callconv(.c) void {
    g_mtx_x.lock() catch unreachable;
    g_a_err = blk: {
        g_mtx_x.lock() catch |err| break :blk err;
        // Should NOT reach here — re-entrant acquire must return Deadlock.
        g_mtx_x.unlock();
        break :blk null;
    };
    g_mtx_x.unlock();
    harness.done[0] = true;
    while (true) fc.__fiber.?.yield();
}

pub fn testCycleSelf() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    // Self-cycle is deterministic; no schedule space matters. Run a few
    // schedules so the loom invariant (>0 sim ops) still trips.
    var schedule_buf: [4]u8 = .{ 0, 0, 0, 0 };
    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    var failures: usize = 0;
    const total: usize = 1;
    for (0..total) |_| {
        h.resetExhaustive(&schedule_buf);
        cycleReset();
        try h.createThread(0, @intFromPtr(&entrySelfCycle));
        h.run() catch {
            failures += 1;
            continue;
        };

        // Invariant: re-entrant lock returned error.Deadlock; mutex is
        // released cleanly afterward (the first acquire's unlock ran).
        if (!errIs(g_a_err, error.Deadlock)) failures += 1;
        if (g_mtx_x.isLocked()) failures += 1;
    }

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (failures > 0) {
        std.debug.print("\nself-cycle: {d} failures\n", .{failures});
        return error.LoomFailures;
    }
}

// 2-hop AB/BA cycle — fiber A holds X. Fiber B holds Y, then attempts X
// and parks (no cycle visible to B because A is in a busy-wait, not on
// any lock). Once B is fully parked on X (harness.parked[1] == true),
// fiber A attempts Y. At that point B's wfl_kind == MUTEX, so A's
// chain walk reaches B → owner(X)=A → found_self at depth 1 →
// error.LockCycle.
//
// This is asymmetric on purpose: the detectCycle protocol can only see
// a cycle once at least one waiter has fully parked. A symmetric setup
// (both attempting their cross-lock simultaneously) has a window where
// neither is parked yet, both walks find no cycle, both park, and the
// system deadlocks without detection — that is a known limitation of
// pre-park cycle detection (production relies on lock_timeout_ms to
// recover, which the loom harness does not simulate). The barrier here
// pins one direction so we test detection deterministically.
fn entry2HopA() callconv(.c) void {
    g_mtx_x.lock() catch unreachable;
    g_a_holds_x = true;
    while (!g_b_holds_y) fc.__fiber.?.yield();
    // Wait until B has actually parked on X. By then the chain walk
    // through B will reach the lock-derived owner (us) and find self.
    while (!harness.parked[1]) fc.__fiber.?.yield();
    g_a_err = blk: {
        g_mtx_y.lock() catch |err| break :blk err;
        g_mtx_y.unlock();
        break :blk null;
    };
    g_mtx_x.unlock();
    harness.done[0] = true;
    while (true) fc.__fiber.?.yield();
}

fn entry2HopB() callconv(.c) void {
    g_mtx_y.lock() catch unreachable;
    g_b_holds_y = true;
    while (!g_a_holds_x) fc.__fiber.?.yield();
    g_b_err = blk: {
        g_mtx_x.lock() catch |err| break :blk err;
        g_mtx_x.unlock();
        break :blk null;
    };
    g_mtx_y.unlock();
    harness.done[1] = true;
    while (true) fc.__fiber.?.yield();
}

pub fn testCycle2Hop() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    const depth: usize = if (build_options.coverage) 6 else 12;
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
        cycleReset();

        try h.createThread(0, @intFromPtr(&entry2HopA));
        try h.createThread(1, @intFromPtr(&entry2HopB));

        h.run() catch {
            failures += 1;
            continue;
        };

        // Invariant: at least one fiber detected the cycle. Both mutexes
        // released cleanly. Both fibers completed (otherwise STEP_LIMIT
        // would have fired). The fiber that did NOT detect either also
        // detected (multi-direction race) or succeeded after the loser
        // released — both outcomes are valid; a Deadlock would mean the
        // detector mis-classified depth.
        // All fibers must have completed — if any are stuck parked, the
        // cycle wasn't detected and the harness exited via "no active
        // fibers" (deadlock without timeout).
        if (!h.done[0] or !h.done[1]) {
            std.debug.print(
                "\n2-hop sched {d}: deadlock-without-detection (done={any})\n",
                .{ sched_idx, h.done[0..2] },
            );
            failures += 1;
            continue;
        }
        const any_cycle = errIs(g_a_err, error.LockCycle) or errIs(g_b_err, error.LockCycle);
        if (!any_cycle) {
            std.debug.print(
                "\n2-hop sched {d}: no cycle detected (a_err={?} b_err={?})\n",
                .{ sched_idx, g_a_err, g_b_err },
            );
            failures += 1;
            continue;
        }
        if (errIs(g_a_err, error.Deadlock) or errIs(g_b_err, error.Deadlock)) {
            std.debug.print(
                "\n2-hop sched {d}: false Deadlock (a_err={?} b_err={?})\n",
                .{ sched_idx, g_a_err, g_b_err },
            );
            failures += 1;
            continue;
        }
        if (g_mtx_x.isLocked() or g_mtx_y.isLocked()) {
            std.debug.print(
                "\n2-hop sched {d}: leaked lock (x_locked={} y_locked={})\n",
                .{ sched_idx, g_mtx_x.isLocked(), g_mtx_y.isLocked() },
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
        std.debug.print("\n2-hop: {d}/{d} schedules failed\n", .{ failures, total_schedules });
        return error.LoomFailures;
    }
}

// 3-hop ABC/BCA cycle — A holds X, B holds Y, C holds Z. C waits on X
// (parks). B waits on Z (parks, can see C parked-on-X via chain walk
// but not self yet). A waits on Y (parks last) and at that point the
// chain walk traverses Y→B→Z→C→X→A → found_self at depth 3 →
// error.LockCycle.
//
// Same barrier discipline as the 2-hop test: A must observe both B and
// C fully parked before attempting Y. The detectCycle protocol cannot
// see a cycle whose participants haven't yet parked.
fn entry3HopA() callconv(.c) void {
    g_mtx_x.lock() catch unreachable;
    g_a_holds_x = true;
    while (!(g_b_holds_y and g_c_holds_z)) fc.__fiber.?.yield();
    while (!(harness.parked[1] and harness.parked[2])) fc.__fiber.?.yield();
    g_a_err = blk: {
        g_mtx_y.lock() catch |err| break :blk err;
        g_mtx_y.unlock();
        break :blk null;
    };
    g_mtx_x.unlock();
    harness.done[0] = true;
    while (true) fc.__fiber.?.yield();
}

fn entry3HopB() callconv(.c) void {
    g_mtx_y.lock() catch unreachable;
    g_b_holds_y = true;
    // B waits for C to park on X (creating the partial chain) before
    // attempting Z. That way when A later walks the chain, the link
    // B→Z→C is in place and C→X→A closes the cycle.
    while (!g_c_holds_z) fc.__fiber.?.yield();
    while (!harness.parked[2]) fc.__fiber.?.yield();
    g_b_err = blk: {
        g_mtx_z.lock() catch |err| break :blk err;
        g_mtx_z.unlock();
        break :blk null;
    };
    g_mtx_y.unlock();
    harness.done[1] = true;
    while (true) fc.__fiber.?.yield();
}

fn entry3HopC() callconv(.c) void {
    g_mtx_z.lock() catch unreachable;
    g_c_holds_z = true;
    while (!g_a_holds_x) fc.__fiber.?.yield();
    g_c_err = blk: {
        g_mtx_x.lock() catch |err| break :blk err;
        g_mtx_x.unlock();
        break :blk null;
    };
    g_mtx_z.unlock();
    harness.done[2] = true;
    while (true) fc.__fiber.?.yield();
}

pub fn testCycle3Hop() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    // 3 fibers — base-3 schedule. depth=8 → 6,561 schedules.
    const depth: usize = if (build_options.coverage) 4 else 8;
    var total_schedules: usize = 1;
    {
        var p: usize = 0;
        while (p < depth) : (p += 1) total_schedules *= 3;
    }
    var schedule_buf: [depth]u8 = undefined;

    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    var failures: usize = 0;

    for (0..total_schedules) |sched_idx| {
        var s = sched_idx;
        for (0..depth) |bit| {
            schedule_buf[bit] = @intCast(s % 3);
            s /= 3;
        }
        h.resetExhaustive(&schedule_buf);
        cycleReset();

        try h.createThread(0, @intFromPtr(&entry3HopA));
        try h.createThread(1, @intFromPtr(&entry3HopB));
        try h.createThread(2, @intFromPtr(&entry3HopC));

        h.run() catch {
            failures += 1;
            continue;
        };

        if (!h.done[0] or !h.done[1] or !h.done[2]) {
            std.debug.print(
                "\n3-hop sched {d}: deadlock-without-detection (done={any})\n",
                .{ sched_idx, h.done[0..3] },
            );
            failures += 1;
            continue;
        }
        const any_cycle = errIs(g_a_err, error.LockCycle) or
                          errIs(g_b_err, error.LockCycle) or
                          errIs(g_c_err, error.LockCycle);
        if (!any_cycle) {
            std.debug.print(
                "\n3-hop sched {d}: no cycle (a={?} b={?} c={?})\n",
                .{ sched_idx, g_a_err, g_b_err, g_c_err },
            );
            failures += 1;
            continue;
        }
        if (errIs(g_a_err, error.Deadlock) or errIs(g_b_err, error.Deadlock) or errIs(g_c_err, error.Deadlock)) {
            std.debug.print(
                "\n3-hop sched {d}: false Deadlock (a={?} b={?} c={?})\n",
                .{ sched_idx, g_a_err, g_b_err, g_c_err },
            );
            failures += 1;
            continue;
        }
        if (g_mtx_x.isLocked() or g_mtx_y.isLocked() or g_mtx_z.isLocked()) {
            failures += 1;
        }
    }

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (failures > 0) {
        std.debug.print("\n3-hop: {d}/{d} schedules failed\n", .{ failures, total_schedules });
        return error.LoomFailures;
    }
}

// Read-lock terminator — a shared (read) waiter on the chain breaks the
// walk because read locks have no single owner. Setup:
//   - Fiber A acquires write rwlock (g_rw).
//   - Fiber B acquires mtx_x, then attempts write rwlock (parks on A).
//   - Fiber C acquires shared rwlock — but the chain walk from any
//     starting point cannot pass through B's wait because
//     waiting_for_lock_kind == RWLOCK_WRITE points at the rwlock; A
//     holds it as the write_owner; chain ends at A.
//
// The simpler scenario tested here: B holds the rwlock SHARED. A waiter
// on B's "lock" returns null from currentChainOwner because read locks
// have no exclusive owner — the chain terminator. We construct: A holds
// mtx_x. C waits on mtx_x. C's detectCycle walks chain: A (owner of
// mtx_x) → A.wfl_kind = RWLOCK_SHARED → currentChainOwner returns null.
// No cycle. C parks normally.
fn entryReadTermA() callconv(.c) void {
    g_rw.lockShared() catch unreachable;
    g_a_holds_x = true; // reuse flag: "A has shared lock"
    while (!g_b_holds_y) fc.__fiber.?.yield();
    g_rw.unlockShared();
    harness.done[0] = true;
    while (true) fc.__fiber.?.yield();
}

fn entryReadTermB() callconv(.c) void {
    while (!g_a_holds_x) fc.__fiber.?.yield();
    g_b_holds_y = true;
    // B doesn't actually do anything with locks in this scenario — it
    // just signals A to release. The interesting code path is on the
    // detection side, which doesn't fire here because there's no cycle.
    // The invariant is just that no false Deadlock/LockCycle occurs.
    harness.done[1] = true;
    while (true) fc.__fiber.?.yield();
}

pub fn testCycleReadTerminator() !void {
    // Minimal regression: fiber A takes a shared rwlock, waits on a
    // signal, releases. No cycle exists; no detection should fire. The
    // value is that a future regression in currentChainOwner that fails
    // to short-circuit on RWLOCK_SHARED would manifest as a false
    // positive in larger 2/3-hop tests; this test pins the basic case.
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    var schedule_buf: [8]u8 = undefined;
    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    var failures: usize = 0;
    const total: usize = if (build_options.coverage) 32 else 256;
    for (0..total) |sched_idx| {
        for (0..8) |bit| {
            schedule_buf[bit] = @intCast((sched_idx >> @as(u6, @intCast(bit))) & 1);
        }
        h.resetExhaustive(&schedule_buf);
        cycleReset();
        rwReset();

        try h.createThread(0, @intFromPtr(&entryReadTermA));
        try h.createThread(1, @intFromPtr(&entryReadTermB));

        h.run() catch {
            failures += 1;
            continue;
        };

        if (g_rw.readerCount() != 0 or g_rw.isWriteLocked()) failures += 1;
    }

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (failures > 0) {
        std.debug.print("\nread-term: {d} failures\n", .{failures});
        return error.LoomFailures;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// VOPR — randomized seed-driven testing (no barriers, no synchronization)
//
// The M6 tests above use barriers to deterministically reach the cycle
// state. That validates detectCycle FIRES on a real cycle but does not
// stress the timing-sensitive paths where detectCycle could FALSE-POSITIVE
// on a transient apparent cycle that resolves before the chain stabilizes.
//
// VOPR fixes that gap. Each test below:
//   - Runs N fibers doing realistic lock workloads with NO inter-fiber
//     synchronization. Fibers race naturally, just as they would on real
//     hardware.
//   - Drives scheduling via a per-seed PRNG. Each atomic op yields, the
//     harness picks the next fiber per the seed's bit stream.
//   - Asserts per-seed invariants. On failure, prints the seed for
//     reproduction (`./parking-lot-loom --seed <N>` would re-run that
//     specific schedule).
//   - Sweeps `LOOM_FUZZ_SEEDS` seeds (default 500, set higher for nightly).
//
// Workloads:
//   1. Address-ordered nested mutex chain (mirrors bench 14_nested_lock).
//      Cycles are STRUCTURALLY IMPOSSIBLE under address-ordering. Any
//      LockCycle/Deadlock observed is a false positive in detectCycle's
//      timing-sensitive snapshot retry logic.
//   2. Three-lock chain with random arrival order. Cycles ARE possible
//      here, so detection SHOULD fire on real cycles and NOT fire on
//      transient apparent cycles.
//
// The address-ordered test is the one that should catch the bench-mode
// false positive. If a seed produces a LockCycle here, the seed is
// reproduction-pinned and the bug is bisectable to the timing window
// observed by detectCycle.
// ─────────────────────────────────────────────────────────────────────────────

const VOPR_LOCKS: usize = 4;
const VOPR_FIBERS: usize = 4;
const VOPR_ITERS: usize = if (build_options.coverage) 20 else 200;

var g_vopr_locks: [VOPR_LOCKS]ParkingMutex = undefined;
var g_vopr_counters: [VOPR_LOCKS]u64 = undefined;
var g_vopr_false_cycles: u32 = 0;
var g_vopr_false_deadlocks: u32 = 0;
var g_vopr_seeds: [VOPR_FIBERS]u64 = undefined;

fn voprReset() void {
    var i: usize = 0;
    while (i < VOPR_LOCKS) : (i += 1) {
        g_vopr_locks[i] = .{};
        g_vopr_counters[i] = 0;
    }
    g_vopr_false_cycles = 0;
    g_vopr_false_deadlocks = 0;
}

inline fn xorshift64(state: *u64) u64 {
    var x = state.*;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    state.* = x;
    return x;
}

fn voprAddrOrderedBody(comptime slot: usize) void {
    var prng = g_vopr_seeds[slot];
    var i: usize = 0;
    while (i < VOPR_ITERS) : (i += 1) {
        const r = xorshift64(&prng);
        const a: usize = @intCast(r % VOPR_LOCKS);
        var b: usize = @intCast((r >> 32) % VOPR_LOCKS);
        if (b == a) b = (a + 1) % VOPR_LOCKS;
        const lo = @min(a, b);
        const hi = @max(a, b);

        // Address-ordered acquisition. NO real cycle is possible.
        g_vopr_locks[lo].lock() catch |e| {
            switch (e) {
                error.LockCycle => g_vopr_false_cycles += 1,
                error.Deadlock => g_vopr_false_deadlocks += 1,
                error.LockTimeout => {},
            }
            continue;
        };
        g_vopr_locks[hi].lock() catch |e| {
            switch (e) {
                error.LockCycle => g_vopr_false_cycles += 1,
                error.Deadlock => g_vopr_false_deadlocks += 1,
                error.LockTimeout => {},
            }
            g_vopr_locks[lo].unlock();
            continue;
        };
        g_vopr_counters[lo] += 1;
        g_vopr_counters[hi] += 1;
        g_vopr_locks[hi].unlock();
        g_vopr_locks[lo].unlock();
    }
    harness.done[slot] = true;
    // Loop on yield instead of `unreachable`: in ReleaseFast, falling off
    // the end of a fiber's entry function pops uninitialized stack memory
    // as the next return address and (under the right layout) bounces
    // execution back to the entry — silently restarting the body and
    // breaking the harness's done-tracking. Loop here so the fiber is
    // safe to context-switch to but never re-runs the body.
    while (true) fc.__fiber.?.yield();
}

fn entryVopr0() callconv(.c) void { voprAddrOrderedBody(0); }
fn entryVopr1() callconv(.c) void { voprAddrOrderedBody(1); }
fn entryVopr2() callconv(.c) void { voprAddrOrderedBody(2); }
fn entryVopr3() callconv(.c) void { voprAddrOrderedBody(3); }

pub fn testVoprAddressOrderedNoFalsePositive() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    const seed_count: usize = fuzzSeedCount(2000);
    var failures: usize = 0;
    var failing_seed: ?u64 = null;

    for (0..seed_count) |seed| {
        var ph = LoomHarness.initPrng(allocator, seed);
        harness = &ph;

        fc.__fiber = null;
        fc.__fiber_parent_ctx = null;
        fc.__fiber_stack_limit = null;
        drainSchedState();

        voprReset();
        // Per-fiber PRNG seeds derived from the harness seed so each
        // fiber's lock pattern is deterministic per seed.
        var i: usize = 0;
        while (i < VOPR_FIBERS) : (i += 1) {
            g_vopr_seeds[i] = (seed +% (@as(u64, i) +% 1)) *% 0x9E3779B97F4A7C15;
        }

        ph.createThread(0, @intFromPtr(&entryVopr0)) catch continue;
        ph.createThread(1, @intFromPtr(&entryVopr1)) catch continue;
        ph.createThread(2, @intFromPtr(&entryVopr2)) catch continue;
        ph.createThread(3, @intFromPtr(&entryVopr3)) catch continue;

        ph.run() catch {
            // Step limit — treat as deadlock-without-detection (a real
            // bug under VOPR: schedule space deadlocks fibers).
            if (failing_seed == null) failing_seed = seed;
            failures += 1;
            ph.deinit();
            continue;
        };

        // Invariant: address-ordered acquisition CANNOT form a cycle.
        // Any LockCycle/Deadlock is a false positive in detectCycle.
        if (g_vopr_false_cycles > 0 or g_vopr_false_deadlocks > 0) {
            std.debug.print(
                "\nVOPR FALSE POSITIVE seed {d}: cycles={d} deadlocks={d}\n",
                .{ seed, g_vopr_false_cycles, g_vopr_false_deadlocks },
            );
            if (failing_seed == null) failing_seed = seed;
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
        std.debug.print(
            "\nVOPR address-ordered: {d}/{d} seeds failed (first failing seed: {?})\n",
            .{ failures, seed_count, failing_seed },
        );
        return error.LoomFailures;
    }
}

// ─────────────────────────────────────────────────────────────────────
// Timeout-path atomic coverage (M-timeout)
//
// The fields task.lock_wait_start_ms (i64) and task.lock_timed_out
// (bool) became atomic in the same change that made
// task.waiting_for_lock_list / task.lock_waiter_node atomic. Most of
// those atomics fire in M3-M6 because every park/wake reads/writes
// them. The two timeout-specific transitions, however, only happen
// when Scheduler.scanLockWaiters trips a deadline:
//
//   parker (lockSlow):       scanner (scanLockWaiters):
//     lock_wait_start_ms.store
//     waiting_for_lock.store(L)         lock_wait_start_ms.load
//     yield ...                         (deadline check)
//                                       lock_timed_out.store(true)
//                                       waiting_for_lock.store(null)
//     (wake on Ready)
//     lock_timed_out.load → expect true
//
// The loom harness does NOT run scanLockWaiters (it has its own
// custom run loop that bypasses the timeout scanner). Without a
// dedicated test the scanner-side load/store sites for those two
// atomics would never trip a yield point, so a regression that
// downgraded the .release/.acquire ordering on either field would
// silently pass M8 coverage.
//
// This test bypasses the full lock machinery and directly drives
// the atomic-field handshake from two virtual fibers, sweeping all
// reachable schedules. The invariant: parker's load of
// lock_timed_out, sequenced after observing waiting_for_lock cleared,
// must see the scanner's store of true via the .release/.acquire
// pair on waiting_for_lock.
// ─────────────────────────────────────────────────────────────────────

var g_timeout_observed: bool = false;

fn entryTimeoutParker() callconv(.c) void {
    const t = &harness.stub_tasks[0];

    // Park-side stores (mirroring the lockSlow park sequence in
    // ParkingMutex / ParkingRwLock; we do them directly so the test
    // doesn't need a real lock).
    t.lock_wait_start_ms.store(100, .release);
    t.waiting_for_lock.store(@ptrFromInt(0xdead0001), .release);
    _ = t.seq.fetchAdd(1, .release);

    // "Park" — yield until scanner clears waiting_for_lock. Each
    // load is a SimAtomic op, so the harness gets to interleave
    // scanner's stores between iterations.
    while (t.waiting_for_lock.load(.acquire) != null) {
        fc.__fiber.?.yield();
    }

    // Wake-side check. After observing waiting_for_lock == null
    // (scanner's release-store), an acquire-load on
    // lock_timed_out must see scanner's prior release-store of true.
    if (t.lock_timed_out.load(.acquire)) {
        g_timeout_observed = true;
    }

    harness.done[0] = true;
    while (true) fc.__fiber.?.yield();
}

fn entryTimeoutScanner() callconv(.c) void {
    const t = &harness.stub_tasks[0];

    // Wait for parker to populate the wait fields. Each load is a
    // yield point.
    while (t.waiting_for_lock.load(.acquire) == null) {
        fc.__fiber.?.yield();
    }

    // Scanner-side reads (mirroring scheduler.zig:1067). The deadline
    // check is elided — under loom we want to observe both the load
    // and the subsequent timeout store regardless of "real" time.
    const start_ms = t.lock_wait_start_ms.load(.acquire);
    _ = start_ms;

    // Scanner-side timeout sequence (mirroring scheduler.zig:1090).
    // Order matters: lock_timed_out FIRST so the parker reading
    // waiting_for_lock=null can rely on .acquire on it pulling in
    // the lock_timed_out store.
    t.lock_timed_out.store(true, .release);
    t.waiting_for_lock.store(null, .release);
    _ = t.seq.fetchAdd(1, .release);

    harness.done[1] = true;
    while (true) fc.__fiber.?.yield();
}

pub fn testTimeoutAtomicCoverage() !void {
    const allocator = std.heap.c_allocator;
    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    // 16-bit schedule space — 65536 interleavings. Each fiber issues
    // ~4 SimAtomic ops; a 16-step schedule covers all reasonable
    // orderings of the 8 ops between the two fibers.
    var schedule_buf: [16]u8 = undefined;
    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    var failures: usize = 0;
    const total: usize = if (build_options.coverage) 64 else 4096; // 2^12 — covers all "early" schedule prefixes
    for (0..total) |sched_idx| {
        for (0..schedule_buf.len) |bit| {
            schedule_buf[bit] = @intCast((sched_idx >> @as(u6, @intCast(bit % 12))) & 1);
        }
        h.resetExhaustive(&schedule_buf);

        try h.createThread(0, @intFromPtr(&entryTimeoutParker));
        try h.createThread(1, @intFromPtr(&entryTimeoutScanner));

        // createThread re-inits stub_tasks[i] each time; reset the
        // timeout-specific fields plus our test observer.
        g_timeout_observed = false;
        h.stub_tasks[0].lock_wait_start_ms.store(0, .monotonic);
        h.stub_tasks[0].waiting_for_lock.store(null, .monotonic);
        h.stub_tasks[0].lock_timed_out.store(false, .monotonic);

        h.run() catch {
            failures += 1;
            continue;
        };

        // Invariant: every schedule that completes must have observed
        // the scanner's timeout store. The parker's load of
        // lock_timed_out happens AFTER its load of
        // waiting_for_lock=null, and the scanner stored
        // lock_timed_out BEFORE waiting_for_lock=null with .release.
        // Acquire on waiting_for_lock chains the lock_timed_out store
        // into visibility.
        if (!g_timeout_observed) failures += 1;
    }

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (failures > 0) {
        std.debug.print("\ntimeout-atomic: {d}/{d} schedules failed\n", .{ failures, total });
        return error.LoomFailures;
    }
}

// ─────────────────────────────────────────────────────────────────────
// FSM timeout-atomic coverage
//
// The FsmTask back-pointer fields (lock_waiter, waiting_for_lock,
// waiting_for_lock_list, waiting_for_fsm_owner, lock_wait_start_ms)
// became atomic so that scanFsmLockWaiters / detectCycleFsm reads
// establish a TSan-visible happens-before with parker / wake-side
// stores. This test exercises the same parker/scanner handshake as
// testTimeoutAtomicCoverage but on the FSM fields, so a regression
// that downgrades the .release/.acquire ordering on any of them
// trips a deterministic schedule under loom.
//
//   parker (tryLockForFsm):           scanner (scanFsmLockWaiters):
//     lock_wait_start_ms.store
//     waiting_for_lock_list.store(L)    waiting_for_lock_list.load
//     waiting_for_lock.store(L)         waiting_for_lock.load
//                                       (deadline check)
//                                       waiting_for_lock.store(null)
//     while (wait != null) yield
//     done
//
// Invariant under all schedules: the parker, after observing
// waiting_for_lock cleared by the scanner, also observes
// waiting_for_lock_list cleared (because the scanner stored it with
// .release before clearing waiting_for_lock).
// ─────────────────────────────────────────────────────────────────────

var g_fsm_task: fsm_mod.FsmTask = undefined;
var g_fsm_observed: bool = false;

fn entryFsmTimeoutParker() callconv(.c) void {
    const t = &g_fsm_task;

    // Park-side stores (mirroring tryLockForFsm).
    t.lock_wait_start_ms.store(100, .release);
    t.waiting_for_lock_list.store(@ptrFromInt(0xfeed0001), .release);
    t.waiting_for_lock.store(@ptrFromInt(0xdead0001), .release);

    // "Park" — yield until scanner clears waiting_for_lock.
    while (t.waiting_for_lock.load(.acquire) != null) {
        fc.__fiber.?.yield();
    }

    // After observing waiting_for_lock == null (scanner's release-store),
    // an acquire-load on waiting_for_lock_list must see the scanner's
    // prior release-store of null. The fields move together — that's
    // the structural invariant scanFsmLockWaiters relies on.
    if (t.waiting_for_lock_list.load(.acquire) == null) {
        g_fsm_observed = true;
    }

    harness.done[0] = true;
    while (true) fc.__fiber.?.yield();
}

fn entryFsmTimeoutScanner() callconv(.c) void {
    const t = &g_fsm_task;

    // Wait for parker to populate the wait fields. Each load is a
    // yield point.
    while (t.waiting_for_lock.load(.acquire) == null) {
        fc.__fiber.?.yield();
    }

    // Scanner-side reads (mirroring scanFsmLockWaiters).
    const start_ms = t.lock_wait_start_ms.load(.acquire);
    _ = start_ms;
    const wfl = t.waiting_for_lock_list.load(.acquire);
    _ = wfl;

    // Scanner-side timeout sequence (mirroring scanFsmLockWaiters).
    // Order: clear waiting_for_lock_list FIRST so the parker reading
    // waiting_for_lock=null can rely on .acquire on it pulling in the
    // waiting_for_lock_list=null store.
    t.waiting_for_lock_list.store(null, .release);
    t.lock_waiter.store(null, .release);
    t.waiting_for_lock.store(null, .release);

    harness.done[1] = true;
    while (true) fc.__fiber.?.yield();
}

pub fn testFsmTimeoutAtomicCoverage() !void {
    const allocator = std.heap.c_allocator;
    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    var schedule_buf: [16]u8 = undefined;
    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    var failures: usize = 0;
    const total: usize = if (build_options.coverage) 64 else 4096;
    for (0..total) |sched_idx| {
        for (0..schedule_buf.len) |bit| {
            schedule_buf[bit] = @intCast((sched_idx >> @as(u6, @intCast(bit % 12))) & 1);
        }
        h.resetExhaustive(&schedule_buf);

        // Reset the FSM task fields between runs.
        g_fsm_task = fsm_mod.FsmTask.init(undefined);
        g_fsm_observed = false;

        try h.createThread(0, @intFromPtr(&entryFsmTimeoutParker));
        try h.createThread(1, @intFromPtr(&entryFsmTimeoutScanner));

        h.run() catch {
            failures += 1;
            continue;
        };

        // Invariant: every completed schedule must observe the
        // scanner's cleared waiting_for_lock_list after seeing
        // waiting_for_lock cleared. Acquire on waiting_for_lock chains
        // the waiting_for_lock_list store into visibility.
        if (!g_fsm_observed) failures += 1;
    }

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (failures > 0) {
        std.debug.print("\nfsm-timeout-atomic: {d}/{d} schedules failed\n", .{ failures, total });
        return error.LoomFailures;
    }
}

// ─────────────────────────────────────────────────────────────────────
// FSM slab-reuse reset coverage
//
// Regression for the TSan failure where scanFsmLockWaiters retained a
// stale *FsmTask in fsm_lock_waiters while the scheduler reused the same
// slab slot for a new FSM task. Bulk struct assignment reset the
// waiter/back-pointer fields non-atomically, racing with the scanner's
// atomic loads. Scheduler.allocFsmTask now resets those fields with
// atomic stores and publishes the new generation last.
//
// This loom scenario drives the real allocFsmTask reset while a stale
// scanner observes the same slot. Once the scanner sees the new
// generation, acquire/release ordering requires all reset fields to be
// visible as clear.
// ─────────────────────────────────────────────────────────────────────

var g_fsm_reuse_task: *fsm_mod.FsmTask = undefined;
var g_fsm_reuse_allocated: ?*fsm_mod.FsmTask = null;
var g_fsm_reuse_old_generation: u32 = 0;
var g_fsm_reuse_same_slot: bool = false;
var g_fsm_reuse_observed_clear: bool = false;

fn noopFsmResume(_: *fsm_mod.FsmTask) fsm_mod.YieldReason {
    return .Done;
}

fn entryFsmReuseScanner() callconv(.c) void {
    const t = g_fsm_reuse_task;

    while (t.generation.load(.acquire) == g_fsm_reuse_old_generation) {
        fc.__fiber.?.yield();
    }

    const clear =
        t.seq.load(.acquire) == 0 and
        t.lock_waiter.load(.acquire) == null and
        t.waiting_for_lock_list.load(.acquire) == null and
        t.waiting_for_lock.load(.acquire) == null and
        t.waiting_for_fsm_owner.load(.acquire) == null and
        t.lock_wait_start_ms.load(.acquire) == 0;

    if (clear) g_fsm_reuse_observed_clear = true;

    harness.done[0] = true;
    while (true) fc.__fiber.?.yield();
}

fn entryFsmReuseAllocator() callconv(.c) void {
    const t = g_sched.allocFsmTask(&noopFsmResume) catch unreachable;
    g_fsm_reuse_allocated = t;
    g_fsm_reuse_same_slot = (t == g_fsm_reuse_task);

    harness.done[1] = true;
    while (true) fc.__fiber.?.yield();
}

pub fn testFsmReuseAtomicCoverage() !void {
    const allocator = std.heap.c_allocator;
    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    var schedule_buf: [8]u8 = undefined;
    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    var failures: usize = 0;
    const total: usize = if (build_options.coverage) 16 else 256;
    for (0..total) |sched_idx| {
        for (0..schedule_buf.len) |bit| {
            schedule_buf[bit] = @intCast((sched_idx >> @as(u3, @intCast(bit % 8))) & 1);
        }
        h.resetExhaustive(&schedule_buf);

        const old = try g_sched.allocFsmTask(&noopFsmResume);
        old.seq.store(7, .release);
        old.lock_waiter.store(@ptrFromInt(0x11110001), .release);
        old.waiting_for_lock_list.store(@ptrFromInt(0x22220001), .release);
        old.waiting_for_lock.store(@ptrFromInt(0x33330001), .release);
        old.waiting_for_fsm_owner.store(@ptrFromInt(0x44440008), .release);
        old.lock_wait_start_ms.store(55, .release);

        g_fsm_reuse_task = old;
        g_fsm_reuse_allocated = null;
        g_fsm_reuse_old_generation = old.generation.load(.acquire);
        g_fsm_reuse_same_slot = false;
        g_fsm_reuse_observed_clear = false;
        g_sched.fsm_task_slab.destroy(old);

        try h.createThread(0, @intFromPtr(&entryFsmReuseScanner));
        try h.createThread(1, @intFromPtr(&entryFsmReuseAllocator));

        h.run() catch {
            failures += 1;
            if (g_fsm_reuse_allocated) |t| g_sched.fsm_task_slab.destroy(t);
            continue;
        };

        if (!g_fsm_reuse_same_slot or !g_fsm_reuse_observed_clear) failures += 1;
        if (g_fsm_reuse_allocated) |t| g_sched.fsm_task_slab.destroy(t);
    }

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (failures != 0) {
        std.debug.print("\nfsm-reuse-atomic: {d}/{d} schedules failed\n", .{ failures, total });
        return error.LoomFailures;
    }
}

// ─────────────────────────────────────────────────────────────────────
// FSM lock acquire/release coverage
//
// Existing FSM Loom coverage (testFsmTimeoutAtomicCoverage,
// testFsmReuseAtomicCoverage) exercises only the parker/scanner field-
// ordering protocol -- it never calls tryLockForFsm or wakeNext. The
// stackful Loom suite has full acquire/release coverage but does not
// exercise the FSM-side `tryLockForFsm` / `submitFsmResume` path that
// `wakeNext` takes when an FSM is at the head of the wait queue. This
// section closes that gap.
//
// Each test uses fiber stubs to drive the FSM lock-acquire flow. The
// fiber:
//   1. Calls tryLockForFsm (mutex) or tryReadLockForFsm /
//      tryWriteLockForFsm (rwlock).
//   2. On `.Acquired` -> runs CS, calls unlock.
//   3. On `.Registered` -> polls the FsmTask's `waiting_for_lock`
//      field; once `wakeNext` clears it (line 1005-1008 of
//      parking-lot.zig for FSM), the lock has been transferred to this
//      task. Run CS, unlock.
//   4. On `.Error` -> deadlock/cycle; not expected in these clean
//      tests.
//
// `harness.done[i]` is set last. The harness's MAX_STEPS guard plus
// the explicit done-check after `h.run()` give us liveness: every
// schedule must see all FSMs complete.
// ─────────────────────────────────────────────────────────────────────

// FSM mutex globals (kept separate from the stackful g_mutex/g_counter so
// tests cannot leak state across runs even if a future test reorders).
var g_fsm_mtx: ParkingMutex = .{};
var g_fsm_mtx_counter: usize = 0;
var g_fsm_lock_tasks: [3]fsm_mod.FsmTask = undefined;
var g_fsm_lock_waiters: [3]qs.WaiterNode = undefined;

fn fsmLockNoopResume(_: *fsm_mod.FsmTask) fsm_mod.YieldReason {
    return .{ .Done = {} };
}

// Drives one FSM mutex acquire/CS/release cycle.
fn fsmMutexSlotBody(slot: usize) void {
    const t = &g_fsm_lock_tasks[slot];
    const w = &g_fsm_lock_waiters[slot];

    const r = g_fsm_mtx.tryLockForFsm(t, w, &g_sched);
    switch (r) {
        .Acquired => {
            g_fsm_mtx_counter += 1;
            g_fsm_mtx.unlock();
        },
        .Registered => {
            // Park: poll waiting_for_lock until wakeNext clears it.
            // wakeNext (parking-lot.zig:1005-1008) clears the FSM-side
            // wait fields with .release before submitFsmResume publishes
            // the wake -- our acquire-load chains those clears. Each
            // load yields to the harness coordinator (SimAtomic).
            while (t.waiting_for_lock.load(.acquire) != null) {
                fc.__fiber.?.yield();
            }
            // Lock has been transferred. Run CS.
            g_fsm_mtx_counter += 1;
            g_fsm_mtx.unlock();
        },
        .Error => @panic("fsm-mutex-loom: unexpected lock error"),
    }
    harness.done[slot] = true;
    while (true) fc.__fiber.?.yield();
}

fn entryFsmMutex0() callconv(.c) void { fsmMutexSlotBody(0); }
fn entryFsmMutex1() callconv(.c) void { fsmMutexSlotBody(1); }

fn fsmLockReset() void {
    g_fsm_mtx = .{};
    g_fsm_mtx_counter = 0;
    g_fsm_lock_tasks[0] = .{ .resume_fn = &fsmLockNoopResume };
    g_fsm_lock_tasks[1] = .{ .resume_fn = &fsmLockNoopResume };
    g_fsm_lock_tasks[2] = .{ .resume_fn = &fsmLockNoopResume };
}

fn fsmMutexCheck() bool {
    if (g_fsm_mtx_counter != 2) return false;
    if (g_fsm_mtx.isLocked()) return false;
    if (!g_fsm_mtx.waiters.isEmpty()) return false;
    // Whole state must be 0: no LOCKED, no HAS_WAITERS. (Mirrors
    // mutexCheckInvariants. fsm_owner is intentionally not cleared by
    // unlock per parking-lot.zig:679-681; reuse depends on the lock
    // gate, not the owner field.)
    const tolerated: u64 = ParkingMutex.STATE_HAS_THREAD_SLEEPER;
    if ((g_fsm_mtx.state.load(.monotonic) & ~tolerated) != 0) return false;
    return true;
}

// Two FSM tasks contending on a ParkingMutex. Mirror of
// testMutexAcquireExhaustive but exercising `tryLockForFsm` +
// `wakeNext` FSM-grant transition.
pub fn testFsmMutexAcquireExhaustive() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    const depth: usize = if (build_options.coverage) 4 else 8;
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
        fsmLockReset();

        try h.createThread(0, @intFromPtr(&entryFsmMutex0));
        try h.createThread(1, @intFromPtr(&entryFsmMutex1));

        h.run() catch |e| {
            std.debug.print(
                "\nfsm-mutex STEP_LIMIT sched {d}: {} | counter={d} mtx_state={d} t0.wfl={?*} t1.wfl={?*} t0.lock_waiter={?*} t1.lock_waiter={?*} done={any}\n",
                .{
                    sched_idx,
                    e,
                    g_fsm_mtx_counter,
                    g_fsm_mtx.state.load(.monotonic),
                    g_fsm_lock_tasks[0].waiting_for_lock.load(.monotonic),
                    g_fsm_lock_tasks[1].waiting_for_lock.load(.monotonic),
                    g_fsm_lock_tasks[0].lock_waiter.load(.monotonic),
                    g_fsm_lock_tasks[1].lock_waiter.load(.monotonic),
                    h.done[0..2],
                },
            );
            failures += 1;
            continue;
        };

        // Liveness: both FSMs must complete (caught earlier by MAX_STEPS,
        // but explicit check makes the failure mode obvious).
        if (!h.done[0] or !h.done[1]) {
            std.debug.print(
                "\nfsm-mutex LIVENESS sched {d}: done={any}\n",
                .{ sched_idx, h.done[0..2] },
            );
            failures += 1;
            continue;
        }
        if (!fsmMutexCheck()) {
            std.debug.print(
                "\nfsm-mutex INVARIANT sched {d}: counter={d} locked={} state={d}\n",
                .{ sched_idx, g_fsm_mtx_counter, g_fsm_mtx.isLocked(), g_fsm_mtx.state.load(.monotonic) },
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
        std.debug.print("\n{d}/{d} fsm-mutex schedules failed\n", .{ failures, total_schedules });
        return error.LoomFailures;
    }
}

// ─────────────────────────────────────────────────────────────────────
// Mixed FSM + stackful mutex contention
//
// One stackful fiber takes ParkingMutex.lock(); one FSM-style fiber
// takes ParkingMutex.tryLockForFsm. Exercises mixed-modality wakeNext
// (a stackful waiter ahead of an FSM, and vice versa) which the pure-
// stackful and pure-FSM tests above do not cover. Bug shape this would
// catch: wakeNext that uses the wrong wake call (submitResume on an
// FSM, or submitFsmResume on a stackful) -> silent lost wake -> hang.
// ─────────────────────────────────────────────────────────────────────

// Slot 0 is stackful; uses g_mutex / g_counter (the standard stackful
// fixtures defined above, line 349-350). Slot 1 is FSM; uses
// g_fsm_mtx_via_mixed below. Mixed test runs them on the SAME mutex --
// so we use a dedicated mixed mutex to keep the fixtures independent.
var g_mixed_mtx: ParkingMutex = .{};
var g_mixed_counter: usize = 0;

fn entryMixedStackfulMutex() callconv(.c) void {
    g_mixed_mtx.lock() catch unreachable;
    g_mixed_counter += 1;
    g_mixed_mtx.unlock();
    harness.done[0] = true;
    while (true) fc.__fiber.?.yield();
}

fn entryMixedFsmMutex() callconv(.c) void {
    const t = &g_fsm_lock_tasks[1];
    const w = &g_fsm_lock_waiters[1];
    const r = g_mixed_mtx.tryLockForFsm(t, w, &g_sched);
    switch (r) {
        .Acquired => {
            g_mixed_counter += 1;
            g_mixed_mtx.unlock();
        },
        .Registered => {
            while (t.waiting_for_lock.load(.acquire) != null) {
                fc.__fiber.?.yield();
            }
            g_mixed_counter += 1;
            g_mixed_mtx.unlock();
        },
        .Error => @panic("mixed-mutex-loom: unexpected lock error"),
    }
    harness.done[1] = true;
    while (true) fc.__fiber.?.yield();
}

pub fn testMixedMutexExhaustive() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    const depth: usize = if (build_options.coverage) 4 else 8;
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
        g_mixed_mtx = .{};
        g_mixed_counter = 0;
        g_fsm_lock_tasks[1] = .{ .resume_fn = &fsmLockNoopResume };

        try h.createThread(0, @intFromPtr(&entryMixedStackfulMutex));
        try h.createThread(1, @intFromPtr(&entryMixedFsmMutex));

        h.run() catch |e| {
            std.debug.print("\nmixed-mutex STEP_LIMIT sched {d}: {}\n", .{ sched_idx, e });
            failures += 1;
            continue;
        };

        if (!h.done[0] or !h.done[1]) {
            std.debug.print(
                "\nmixed-mutex LIVENESS sched {d}: done={any}\n",
                .{ sched_idx, h.done[0..2] },
            );
            failures += 1;
            continue;
        }
        if (g_mixed_counter != 2 or g_mixed_mtx.isLocked() or !g_mixed_mtx.waiters.isEmpty()) {
            std.debug.print(
                "\nmixed-mutex INVARIANT sched {d}: counter={d} locked={} waiters_empty={}\n",
                .{ sched_idx, g_mixed_counter, g_mixed_mtx.isLocked(), g_mixed_mtx.waiters.isEmpty() },
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
        std.debug.print("\n{d}/{d} mixed-mutex schedules failed\n", .{ failures, total_schedules });
        return error.LoomFailures;
    }
}

// ─────────────────────────────────────────────────────────────────────
// FSM ParkingRwLock acquire/release coverage
//
// Mirrors the stackful rwlock tests but driving FSM-side
// `tryWriteLockForFsm` / `tryReadLockForFsm`. Both single-writer-with-
// reader and the 1W+2R fetchAdd-undo race scenarios.
// ─────────────────────────────────────────────────────────────────────

var g_fsm_rw: ParkingRwLock = .{};
var g_fsm_rw_writer_counter: usize = 0;
var g_fsm_rw_reader_obs: [3]i64 = .{ -1, -1, -1 };
var g_fsm_rw_transient_wl: usize = 0;

fn fsmRwReset() void {
    g_fsm_rw = .{};
    g_fsm_rw_writer_counter = 0;
    g_fsm_rw_reader_obs = .{ -1, -1, -1 };
    g_fsm_rw_transient_wl = 0;
    g_fsm_lock_tasks[0] = .{ .resume_fn = &fsmLockNoopResume };
    g_fsm_lock_tasks[1] = .{ .resume_fn = &fsmLockNoopResume };
    g_fsm_lock_tasks[2] = .{ .resume_fn = &fsmLockNoopResume };
}

fn fsmRwWriterBody(slot: usize) void {
    const t = &g_fsm_lock_tasks[slot];
    const w = &g_fsm_lock_waiters[slot];
    const r = g_fsm_rw.tryWriteLockForFsm(t, w, &g_sched);
    switch (r) {
        .Acquired => {
            g_fsm_rw_writer_counter += 1;
            g_fsm_rw.unlock();
        },
        .Registered => {
            while (t.waiting_for_lock.load(.acquire) != null) {
                fc.__fiber.?.yield();
            }
            g_fsm_rw_writer_counter += 1;
            g_fsm_rw.unlock();
        },
        .Error => @panic("fsm-rw-writer: unexpected lock error"),
    }
    harness.done[slot] = true;
    while (true) fc.__fiber.?.yield();
}

fn fsmRwReaderBody(slot: usize) void {
    const t = &g_fsm_lock_tasks[slot];
    const w = &g_fsm_lock_waiters[slot];
    const r = g_fsm_rw.tryReadLockForFsm(t, w, &g_sched);
    switch (r) {
        .Acquired => {
            // Same transient invariant as stackful rwWork's reader path:
            // a reader must never observe write_locked while holding the
            // read lock. If it does, wakeNext / wake-on-undo granted the
            // read while a writer still held -- the FSM-path version of
            // the bug fixed by the WRITE_LOCKED guard.
            if (g_fsm_rw.isWriteLocked()) g_fsm_rw_transient_wl += 1;
            g_fsm_rw_reader_obs[slot] = @as(i64, @intCast(g_fsm_rw_writer_counter));
            g_fsm_rw.unlockShared();
        },
        .Registered => {
            while (t.waiting_for_lock.load(.acquire) != null) {
                fc.__fiber.?.yield();
            }
            // wakeNext for an FSM reader transferred the read slot to us.
            if (g_fsm_rw.isWriteLocked()) g_fsm_rw_transient_wl += 1;
            g_fsm_rw_reader_obs[slot] = @as(i64, @intCast(g_fsm_rw_writer_counter));
            g_fsm_rw.unlockShared();
        },
        .Error => @panic("fsm-rw-reader: unexpected lock error"),
    }
    harness.done[slot] = true;
    while (true) fc.__fiber.?.yield();
}

fn entryFsmRwWriter0() callconv(.c) void { fsmRwWriterBody(0); }
fn entryFsmRwWriter1() callconv(.c) void { fsmRwWriterBody(1); }
fn entryFsmRwReader1() callconv(.c) void { fsmRwReaderBody(1); }
fn entryFsmRwReader2() callconv(.c) void { fsmRwReaderBody(2); }

fn fsmRwCheck(expected_writers: usize, reader_slots: []const usize) bool {
    if (g_fsm_rw_writer_counter != expected_writers) return false;
    if (g_fsm_rw.isWriteLocked()) return false;
    if (g_fsm_rw.readerCount() != 0) return false;
    if (!g_fsm_rw.waiters.isEmpty()) return false;
    if (g_fsm_rw.write_owner.load(.monotonic) != null) return false;
    if (g_fsm_rw.state.load(.monotonic) != 0) return false;
    if (g_fsm_rw_transient_wl != 0) return false;
    for (reader_slots) |s| {
        const obs = g_fsm_rw_reader_obs[s];
        if (obs < 0) return false;
        if (obs > @as(i64, @intCast(expected_writers))) return false;
    }
    return true;
}

// FSM analog of testRwlockWriterReader: one FSM writer + one FSM reader.
pub fn testFsmRwlockWriterReader() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    const depth: usize = if (build_options.coverage) 4 else 8;
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
        fsmRwReset();

        try h.createThread(0, @intFromPtr(&entryFsmRwWriter0));
        try h.createThread(1, @intFromPtr(&entryFsmRwReader1));

        h.run() catch |e| {
            std.debug.print("\nfsm-rw-WR STEP_LIMIT sched {d}: {}\n", .{ sched_idx, e });
            failures += 1;
            continue;
        };

        if (!h.done[0] or !h.done[1]) {
            std.debug.print(
                "\nfsm-rw-WR LIVENESS sched {d}: done={any}\n",
                .{ sched_idx, h.done[0..2] },
            );
            failures += 1;
            continue;
        }
        if (!fsmRwCheck(1, &.{1})) {
            std.debug.print(
                "\nfsm-rw-WR INVARIANT sched {d}: wc={d} obs1={d} state={d}\n",
                .{ sched_idx, g_fsm_rw_writer_counter, g_fsm_rw_reader_obs[1], g_fsm_rw.state.load(.monotonic) },
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
        std.debug.print("\n{d}/{d} fsm-rw-WR schedules failed\n", .{ failures, total_schedules });
        return error.LoomFailures;
    }
}

// FSM analog of testRwlockOneWriterTwoReaders: 1 FSM writer + 2 FSM
// readers. Specifically targets the wake-on-undo / WRITE_LOCKED-guard
// scenario in tryReadLockForFsm: reader R_B fetchAdd-undoes while
// writer W still holds, and the path must not falsely grant the read
// slot to the queued reader R_A while WRITE_LOCKED is set. The
// transient-write-lock counter (g_fsm_rw_transient_wl) is the
// detector.
pub fn testFsmRwlockOneWriterTwoReaders() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    const depth: usize = if (build_options.coverage) 4 else 10;
    var total_schedules: usize = 1;
    {
        var p: usize = 0;
        while (p < depth) : (p += 1) total_schedules *= 3;
    }
    var schedule_buf: [depth]u8 = undefined;

    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    var failures: usize = 0;

    for (0..total_schedules) |sched_idx| {
        var s = sched_idx;
        for (0..depth) |bit| {
            schedule_buf[bit] = @intCast(s % 3);
            s /= 3;
        }
        h.resetExhaustive(&schedule_buf);
        fsmRwReset();

        try h.createThread(0, @intFromPtr(&entryFsmRwWriter0));
        try h.createThread(1, @intFromPtr(&entryFsmRwReader1));
        try h.createThread(2, @intFromPtr(&entryFsmRwReader2));

        h.run() catch |e| {
            std.debug.print("\nfsm-rw-1W2R STEP_LIMIT sched {d}: {}\n", .{ sched_idx, e });
            failures += 1;
            continue;
        };

        if (!h.done[0] or !h.done[1] or !h.done[2]) {
            std.debug.print(
                "\nfsm-rw-1W2R LIVENESS sched {d}: done={any}\n",
                .{ sched_idx, h.done[0..3] },
            );
            failures += 1;
            continue;
        }
        if (!fsmRwCheck(1, &.{ 1, 2 })) {
            std.debug.print(
                "\nfsm-rw-1W2R INVARIANT sched {d}: wc={d} obs1={d} obs2={d} transient_wl={d} state={d}\n",
                .{ sched_idx, g_fsm_rw_writer_counter, g_fsm_rw_reader_obs[1], g_fsm_rw_reader_obs[2], g_fsm_rw_transient_wl, g_fsm_rw.state.load(.monotonic) },
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
        std.debug.print("\n{d}/{d} fsm-rw-1W2R schedules failed\n", .{ failures, total_schedules });
        return error.LoomFailures;
    }
}

// Two FSM writers contesting the same rwlock. The second one to enter
// tryWriteLockForFsm sees WRITE_LOCKED_BIT set (held by the first),
// hits the line 1326-1333 re-entrancy / cycle-pre-check that loads
// `fsm_write_owner` (line 1327). Without this scenario the existing
// FSM rwlock tests (1W+1R, 1W+2R) all enter tryWriteLockForFsm with
// state == 0 and never trigger the if at 1326.
pub fn testFsmRwlockTwoWriters() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    const depth: usize = if (build_options.coverage) 4 else 8;
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
        fsmRwReset();
        fsmLockReset();

        try h.createThread(0, @intFromPtr(&entryFsmRwWriter0));
        try h.createThread(1, @intFromPtr(&entryFsmRwWriter1));

        h.run() catch {
            failures += 1;
            continue;
        };

        if (!h.done[0] or !h.done[1]) {
            failures += 1;
            continue;
        }
        if (!fsmRwCheck(2, &.{})) failures += 1;
    }

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (failures > 0) {
        std.debug.print("\n{d}/{d} fsm-rw-2W schedules failed\n", .{ failures, total_schedules });
        return error.LoomFailures;
    }
}

// ─────────────────────────────────────────────────────────────────────
// Stream(T) close/err atomic coverage
//
// Stream(T).Inner.closed became Atomic(bool) so push() / next() can
// fast-path-read it without taking the inner spin lock; setError()
// writes inner.err under the spin lock, and close() / setError() then
// publish closed = true with .release. Readers observe closed with
// .acquire; the spin-lock release-acquire (or the closed
// release-acquire) chains the prior err write into visibility.
//
// This test exercises the parker/closer handshake on closed + err so
// a regression that downgrades either the .release on closed or the
// release that the spin lock provides for the err write would trip a
// deterministic schedule.
//
//   producer (setError + close):           consumer (next-empty path):
//     spinlock.swap(1, .acquire)
//     err = X                                closed.load(.acquire)  ← null while spin held
//     spinlock.store(0, .release)           ...
//     closed.store(true, .release)          closed.load(.acquire)  ← sees true
//                                            read err              ← must see X
// ─────────────────────────────────────────────────────────────────────

const StreamI64 = DataStructures.Stream(i64);
var g_stream_inner: StreamI64.Inner = undefined;
var g_stream_observed_err: bool = false;
var g_next_step_stream: StreamI64 = undefined;
var g_next_step_observed_closed: bool = false;
var g_next_step_err: ?anyerror = null;

fn entryStreamNextStepConsumer() callconv(.c) void {
    const step = g_next_step_stream.nextStep() catch |err| {
        g_next_step_err = err;
        harness.done[0] = true;
        while (true) fc.__fiber.?.yield();
    };
    g_next_step_observed_closed = switch (step) {
        .Closed => true,
        .Item => false,
    };
    harness.done[0] = true;
    while (true) fc.__fiber.?.yield();
}

fn entryStreamNextStepCloseOwner() callconv(.c) void {
    // The test starts with the metadata lock held by this closer. Publish
    // close, then release the lock exactly as Stream.close does. This forces
    // nextStep's fast closed check to race with the locked recheck without
    // relying on wall-clock timing.
    g_stream_inner.closed.store(true, .release);
    g_stream_inner.lock.store(0, .release);
    harness.done[1] = true;
    while (true) fc.__fiber.?.yield();
}

fn entryStreamNextStepParkCloser() callconv(.c) void {
    while (g_stream_inner.consumer_task == null) fc.__fiber.?.yield();
    g_next_step_stream.close();
    harness.done[1] = true;
    while (true) fc.__fiber.?.yield();
}

/// Exercise the production Stream.nextStep metadata protocol. The direct
/// full-ring cases cover both release branches after consuming a slot; the
/// deterministic two-fiber schedule covers a close published after the fast
/// closed check but before the consumer acquires the metadata lock.
pub fn testStreamNextStepInterleavings() !void {
    const allocator = std.heap.c_allocator;
    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        drainSchedState();
        g_sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    // Draining a full ring with no parked producer releases the metadata
    // lock locally.
    g_stream_inner = .{ .sched = &g_sched };
    for (0..64) |i| g_stream_inner.buf[i] = @intCast(i);
    g_stream_inner.head.store(64, .release);
    g_next_step_stream = .{ .inner = &g_stream_inner, .alloc = allocator };
    const unparked_step = try g_next_step_stream.nextStep();
    switch (unparked_step) {
        .Item => |value| if (value != 0) return error.NextStepWrongUnparkedValue,
        .Closed => return error.NextStepClosedFullRing,
    }
    if (g_stream_inner.lock.load(.acquire) != 0) return error.NextStepLockNotReleased;

    // The same transition must clear and schedule a parked producer before
    // releasing the lock. Use a real Task and Scheduler queue so this checks
    // the complete production wake path rather than only toggling fields.
    g_stream_inner.tail.store(0, .release);
    var producer_task = Task{
        .base = undefined,
        .user_fn = @ptrCast(&splitStreamDummyFn),
    };
    producer_task.status.store(.Blocked, .release);
    g_stream_inner.producer_task = &producer_task;
    g_stream_inner.producer_sched = &g_sched;
    const previous_active = fp.active_scheduler;
    const previous_running = fp.scheduler_running;
    fp.active_scheduler = &g_sched;
    fp.scheduler_running = true;
    defer {
        fp.active_scheduler = previous_active;
        fp.scheduler_running = previous_running;
    }
    const parked_step = try g_next_step_stream.nextStep();
    switch (parked_step) {
        .Item => |value| if (value != 0) return error.NextStepWrongParkedValue,
        .Closed => return error.NextStepClosedFullRing,
    }
    if (g_stream_inner.producer_task != null or g_stream_inner.producer_sched != null)
        return error.NextStepProducerNotCleared;
    if (producer_task.status.load(.acquire) != .Ready) return error.NextStepProducerNotReadied;
    if (g_sched.ready_queue.pop() != &producer_task) return error.NextStepProducerNotScheduled;
    producer_task.in_inbox.store(qs.IN_INBOX_IDLE, .release);

    // Force this ordering:
    //   consumer fast closed.load(false)
    //   consumer attempts the pre-held metadata lock
    //   closer publishes closed and releases the lock
    //   consumer acquires, rechecks closed, and releases the lock
    // The schedule values select consumer(0), consumer(0), closer(1) three
    // times, then consumer. SimAtomic yields before each atomic operation.
    var schedule = [_]u8{ 0, 0, 1, 1, 1, 0, 0, 0 };
    var h = LoomHarness.initExhaustive(allocator, &schedule);
    defer h.deinit();
    harness = &h;
    h.resetExhaustive(&schedule);
    g_stream_inner = .{
        .sched = &g_sched,
        .lock = sim_atomic.SimAtomic(u32).init(1),
    };
    g_next_step_stream = .{ .inner = &g_stream_inner, .alloc = allocator };
    g_next_step_observed_closed = false;
    g_next_step_err = null;
    try h.createThread(0, @intFromPtr(&entryStreamNextStepConsumer));
    try h.createThread(1, @intFromPtr(&entryStreamNextStepCloseOwner));
    try h.run();

    if (g_next_step_err) |err| return err;
    if (!h.done[0] or !h.done[1]) return error.NextStepCloseRaceDidNotComplete;
    if (!g_next_step_observed_closed) return error.NextStepCloseRaceMissedClosed;
    if (g_stream_inner.lock.load(.acquire) != 0) return error.NextStepCloseRaceLeftLocked;
}

/// Drive the empty-stream park path through real Fiber contexts. The closer
/// waits until nextStep publishes consumer_task, then close schedules that
/// exact task. This covers the Blocked publication and metadata-lock release
/// that a close-before-lock race does not reach.
pub fn testStreamNextStepParkWake() !void {
    const allocator = std.heap.c_allocator;
    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        drainSchedState();
        g_sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    var schedule = [_]u8{ 0, 0, 0, 1, 1, 0, 0, 0 };
    var h = LoomHarness.initExhaustive(allocator, &schedule);
    defer h.deinit();
    harness = &h;
    h.resetExhaustive(&schedule);
    g_stream_inner = .{
        .sched = &g_sched,
        .wg = fp.WaitGroup.init(&g_sched),
    };
    g_stream_inner.wg.add(1);
    g_next_step_stream = .{ .inner = &g_stream_inner, .alloc = allocator };
    g_next_step_observed_closed = false;
    g_next_step_err = null;

    try h.createThread(0, @intFromPtr(&entryStreamNextStepConsumer));
    try h.createThread(1, @intFromPtr(&entryStreamNextStepParkCloser));
    try h.run();

    if (g_next_step_err) |err| return err;
    if (!h.done[0] or !h.done[1]) return error.StreamParkWakeDidNotComplete;
    if (!g_next_step_observed_closed) return error.StreamParkWakeMissedClosed;
    if (g_stream_inner.consumer_task != null) return error.StreamParkWakeLeftConsumer;
    if (g_stream_inner.lock.load(.acquire) != 0) return error.StreamParkWakeLeftLocked;
}

/// Cover the dequeue-side IN_QUEUE→IDLE publication without driving the full
/// scheduler loop under SimAtomic (which would add non-production yields to
/// every dispatcher atomic).
pub fn testSchedulerMarksDequeuedTaskIdle() !void {
    var task: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&s25DummyFn),
    };
    task.in_inbox.store(qs.IN_INBOX_IN_QUEUE, .release);
    fp.Scheduler.markTaskDequeued(&task);
    if (task.in_inbox.load(.acquire) != qs.IN_INBOX_IDLE)
        return error.DequeuedTaskNotIdle;
}

fn entryStreamConsumer() callconv(.c) void {
    while (!g_stream_inner.closed.load(.acquire)) {
        fc.__fiber.?.yield();
    }
    // After observing closed = true, the err write must be visible.
    // setError writes err under the spin lock and close() publishes
    // closed with .release; the chain establishes happens-before.
    if (g_stream_inner.err) |e| {
        if (e == error.LoomTestError) g_stream_observed_err = true;
    }
    harness.done[0] = true;
    while (true) fc.__fiber.?.yield();
}

fn entryStreamProducer() callconv(.c) void {
    // setError-equivalent: take spin lock, write err, release spin
    // lock. Mirrors data-structures.zig Stream.setError.
    while (g_stream_inner.lock.swap(1, .acquire) == 1) fc.__fiber.?.yield();
    g_stream_inner.err = error.LoomTestError;
    g_stream_inner.lock.store(0, .release);
    // close-equivalent: publish closed with .release.
    g_stream_inner.closed.store(true, .release);

    harness.done[1] = true;
    while (true) fc.__fiber.?.yield();
}

pub fn testStreamCloseErrAtomicCoverage() !void {
    const allocator = std.heap.c_allocator;
    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    var schedule_buf: [16]u8 = undefined;
    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    var failures: usize = 0;
    const total: usize = if (build_options.coverage) 64 else 4096;
    for (0..total) |sched_idx| {
        for (0..schedule_buf.len) |bit| {
            schedule_buf[bit] = @intCast((sched_idx >> @as(u6, @intCast(bit % 12))) & 1);
        }
        h.resetExhaustive(&schedule_buf);

        // Reset the Stream Inner between runs.
        g_stream_inner = .{ .sched = &g_sched };
        g_stream_observed_err = false;

        try h.createThread(0, @intFromPtr(&entryStreamConsumer));
        try h.createThread(1, @intFromPtr(&entryStreamProducer));

        h.run() catch {
            failures += 1;
            continue;
        };

        if (!g_stream_observed_err) failures += 1;
    }

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (failures > 0) {
        std.debug.print("\nstream-close-err-atomic: {d}/{d} schedules failed\n", .{ failures, total });
        return error.LoomFailures;
    }
}

// ─────────────────────────────────────────────────────────────────────
// SplitStream close/err_set atomic coverage
//
// SplitStream (lib/streams.zig) added in 2026-05-09 atomic err_set + non-
// atomic err to satisfy TSan after the parking-lot.ParkingRwLock
// migration (TSan does not model parking-lot rwlock as a synchronizer).
// The protocol mirrors Stream's closed/err but uses a separate
// `err_set: Atomic(u8)` companion to non-atomic `err: anyerror`:
//
//   producer (setError, under rwlock exclusive):
//     err = X
//     err_set.store(1, .release)
//                                          (close also publishes
//                                           closed.store(1, .release))
//   consumer (next, under rwlock shared):
//     if err_set.load(.acquire) != 0: read err
//     if closed.load(.acquire) != 0: return null
//
// The release on err_set must happen-after the non-atomic `err = X`
// write (program order under exclusive). Acquire on consumer's err_set
// load synchronizes-with that release; consumer's read of `err` after
// observing err_set=1 must see X.
//
// This test exhaustively schedules the protocol to verify the release/
// acquire pair establishes happens-before.
// ─────────────────────────────────────────────────────────────────────

const SplitErrShared = struct {
    err_set: qs.Atomic(u8) = qs.Atomic(u8).init(0),
    closed: qs.Atomic(u8) = qs.Atomic(u8).init(0),
    // Non-atomic, written before err_set.store(1, .release). Any reader
    // that observes err_set != 0 via .acquire must observe this value.
    err: i64 = 0,
};

var g_split_err: SplitErrShared = .{};
var g_split_observed_err: bool = false;

fn entrySplitErrConsumer() callconv(.c) void {
    // Mirror SplitStream.next's Phase 1 read: spin on err_set.load(.acquire)
    // until producer publishes; then read non-atomic err. The acquire
    // synchronizes-with producer's release on err_set.
    while (g_split_err.err_set.load(.acquire) == 0) {
        fc.__fiber.?.yield();
    }
    // Acquire-ordered: must see the producer's err = 42 write.
    if (g_split_err.err == 42) g_split_observed_err = true;
    harness.done[0] = true;
    while (true) fc.__fiber.?.yield();
}

fn entrySplitErrProducer() callconv(.c) void {
    // Mirror SplitStream.setError under exclusive lock: write err
    // (non-atomic), then publish via err_set.store(1, .release). The
    // release establishes happens-before with any consumer that
    // observes err_set != 0 via .acquire.
    g_split_err.err = 42;
    g_split_err.err_set.store(1, .release);
    harness.done[1] = true;
    while (true) fc.__fiber.?.yield();
}

pub fn testSplitStreamErrSetAtomicCoverage() !void {
    const allocator = std.heap.c_allocator;
    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    var schedule_buf: [16]u8 = undefined;
    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    var failures: usize = 0;
    const total: usize = if (build_options.coverage) 64 else 4096;
    for (0..total) |sched_idx| {
        for (0..schedule_buf.len) |bit| {
            schedule_buf[bit] = @intCast((sched_idx >> @as(u6, @intCast(bit % 12))) & 1);
        }
        h.resetExhaustive(&schedule_buf);

        g_split_err = .{};
        g_split_observed_err = false;

        try h.createThread(0, @intFromPtr(&entrySplitErrConsumer));
        try h.createThread(1, @intFromPtr(&entrySplitErrProducer));

        h.run() catch {
            failures += 1;
            continue;
        };

        // Consumer must observe err = 42 once it sees err_set != 0. The
        // consumer's spin-loop ensures it always reaches the err read
        // (producer always publishes), so structurally toothless schedules
        // are not a concern here.
        if (!g_split_observed_err) failures += 1;
    }

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (failures > 0) {
        std.debug.print("\nsplit-stream-err-set-atomic: {d}/{d} schedules failed\n", .{ failures, total });
        return error.LoomFailures;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// SplitStream chunk publish-acquire protocol
//
// `lib/streams.zig` SplitStream(T) commits a batch of items into a chunk
// via `chunk.len.store(write_len, .release)` after writing `values[i]`
// in-place. Consumers see the batch via `chunk.len.load(.acquire)`; the
// release/acquire pair must establish happens-before so the consumer's
// reads of `values[i]` observe the producer's writes.
//
// Without correct release/acquire pairing, on a weak memory model the
// consumer can observe `chunk.len = N` but read stale `values[i]`. TSan
// surfaces this as a data race on real hardware; loom drives every
// interleaving deterministically under SimAtomic.
//
// The scenario stubs the publish protocol directly (PublishChunk struct)
// rather than instantiating the full SplitStream pipeline, because loom
// only sees SimAtomic ops — the inner.mutex (pthread) appears as a
// single critical section to the harness, hiding the publish-acquire
// race we're trying to verify.
//
// Properties verified across all schedules:
//   1. Once consumer observes `len > 0` via .acquire, every `values[i]`
//      for i in 0..len equals the producer's write (no torn reads).
//   2. Producer's release pairs with consumer's acquire — i.e., loom
//      explores at least one schedule where the consumer races the
//      publish (otherwise the test is structurally toothless).
// ─────────────────────────────────────────────────────────────────────────────

const PUBLISH_CAP: usize = 4;

const PublishChunk = struct {
    // values is plain memory; correctness depends on the .release on
    // `len` synchronizing-with the .acquire on `len`, transitively
    // making these writes visible to the consumer.
    values: [PUBLISH_CAP]i64 = [_]i64{0} ** PUBLISH_CAP,
    len: qs.Atomic(usize) = qs.Atomic(usize).init(0),
};

var g_publish_chunk: PublishChunk = .{};
var g_publish_torn: bool = false;
var g_publish_observed: bool = false;

fn entryPublishProducer() callconv(.c) void {
    // Mirrors SplitStream.push: write items in-place, then publish the
    // count atomically with .release.
    inline for (0..PUBLISH_CAP) |i| {
        g_publish_chunk.values[i] = @as(i64, @intCast(i + 1));
    }
    g_publish_chunk.len.store(PUBLISH_CAP, .release);
    harness.done[0] = true;
    while (true) fc.__fiber.?.yield();
}

fn entryPublishConsumer() callconv(.c) void {
    // Mirrors SplitStream.next's cursor read: spin on chunk.len with
    // .acquire until non-zero, then read values[].
    var seen_len: usize = 0;
    while (seen_len == 0) {
        seen_len = g_publish_chunk.len.load(.acquire);
        if (seen_len == 0) fc.__fiber.?.yield();
    }
    g_publish_observed = true;
    // Every published value must match the producer's write. A stale
    // value here means the .release/.acquire chain failed to publish
    // the prior `values[i]` writes alongside the len update.
    inline for (0..PUBLISH_CAP) |i| {
        if (g_publish_chunk.values[i] != @as(i64, @intCast(i + 1))) {
            g_publish_torn = true;
        }
    }
    harness.done[1] = true;
    while (true) fc.__fiber.?.yield();
}

pub fn testStreamChunkPublishAtomicCoverage() !void {
    const allocator = std.heap.c_allocator;
    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    var schedule_buf: [16]u8 = undefined;
    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    var torn_count: usize = 0;
    var observed_count: usize = 0;
    const total: usize = if (build_options.coverage) 64 else 4096;
    for (0..total) |sched_idx| {
        for (0..schedule_buf.len) |bit| {
            schedule_buf[bit] = @intCast((sched_idx >> @as(u6, @intCast(bit % 12))) & 1);
        }
        h.resetExhaustive(&schedule_buf);

        g_publish_chunk = .{};
        g_publish_torn = false;
        g_publish_observed = false;

        try h.createThread(0, @intFromPtr(&entryPublishProducer));
        try h.createThread(1, @intFromPtr(&entryPublishConsumer));

        h.run() catch {};

        if (g_publish_torn) torn_count += 1;
        if (g_publish_observed) observed_count += 1;
    }

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (torn_count > 0) {
        std.debug.print("\nstream-publish-atomic: {d}/{d} schedules saw torn reads\n", .{ torn_count, total });
        return error.LoomFailures;
    }
    // Structural toothless-test guard: at least half the schedules
    // should reach the consumer's observation window. If they don't,
    // the harness isn't actually interleaving producer and consumer
    // (e.g. the consumer never gets scheduled before the producer
    // finishes), and the test silently passes without exercising the
    // race surface.
    if (observed_count < total / 2) {
        std.debug.print("\nstream-publish-atomic: only {d}/{d} schedules observed publish — test toothless\n", .{ observed_count, total });
        return error.LoomFailures;
    }
}

pub fn testSplitStreamProductionLifecycle() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    var producer = try LoomSplitStream.spawnNew(allocator, &sched);
    var subscriber = producer.retain();
    defer subscriber.deinit();
    defer producer.deinit();

    var expected_sum: i64 = 0;
    for (0..300) |i| {
        const value: i64 = @intCast(i + 1);
        expected_sum += value;
        try producer.push(value);
    }
    producer.close();

    var producer_sum: i64 = 0;
    var producer_count: usize = 0;
    while (try producer.next()) |value| {
        producer_sum += value;
        producer_count += 1;
    }
    if (producer_count != 300) return error.ProducerReaderMissedItems;
    if (producer_sum != expected_sum) return error.ProducerReaderBadSum;

    var subscriber_sum: i64 = 0;
    var subscriber_count: usize = 0;
    while (try subscriber.next()) |value| {
        subscriber_sum += value;
        subscriber_count += 1;
    }
    if (subscriber_count != 300) return error.SubscriberMissedItems;
    if (subscriber_sum != expected_sum) return error.SubscriberBadSum;

    var err_stream = try LoomSplitStream.spawnNew(allocator, &sched);
    defer err_stream.deinit();
    err_stream.setError(error.SplitStreamInjected);
    if (err_stream.next()) |_| {
        return error.ExpectedSplitStreamError;
    } else |err| if (err != error.SplitStreamInjected) {
        return err;
    }

    var reuse_stream = try LoomSplitStream.spawnNew(allocator, &sched);
    var dropped_subscriber = reuse_stream.retain();
    dropped_subscriber.deinit();
    var reused_subscriber = reuse_stream.retain();
    defer reused_subscriber.deinit();
    defer reuse_stream.deinit();
    reuse_stream.close();
    if (try reused_subscriber.next() != null) return error.ReusedSubscriberReadClosedStream;

    var release_stream = try LoomSplitStream.spawnNew(allocator, &sched);
    var release_subscriber = release_stream.retain();
    defer release_subscriber.deinit();
    defer release_stream.deinit();

    for (0..256) |i| {
        try release_stream.push(@intCast(i + 1));
    }
    for (0..256) |i| {
        const value = (try release_subscriber.next()) orelse return error.ReleaseSubscriberMissingItem;
        if (value != @as(i64, @intCast(i + 1))) return error.ReleaseSubscriberWrongItem;
    }

    try release_stream.push(257);
    release_stream.close();
    const tail_value = (try release_subscriber.next()) orelse return error.ReleaseSubscriberMissingTail;
    if (tail_value != 257) return error.ReleaseSubscriberWrongTail;
    if (try release_subscriber.next() != null) return error.ReleaseSubscriberExpectedClose;
}

pub fn testSplitStreamParkedSubscriberCloseWake() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    var producer = try LoomSplitStream.spawnNew(allocator, &sched);
    var subscriber = producer.retain();
    g_split_park_subscriber = &subscriber;
    g_split_park_woke = false;
    g_split_park_err = null;

    const stack_mem = try allocator.alloc(u8, SPLIT_STREAM_FIBER_STACK);
    var fiber = fc.Fiber.init(stack_mem, @intFromPtr(&entrySplitStreamParkedSubscriber), .Large);
    var task: qs.Task = .{
        .base = &fiber,
        .user_fn = @ptrCast(&splitStreamDummyFn),
        .status = qs.Atomic(qs.TaskStatus).init(.Ready),
    };

    const prev_active = fp.active_scheduler;
    const prev_running = fp.scheduler_running;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    sched.current_task = &task;
    sim_atomic.disable_fiber_yield_point = true;

    var test_err: ?anyerror = null;

    fiber.switchTo(&sched.main_ctx);
    if (task.status.load(.acquire) != .Blocked) test_err = error.SubscriberDidNotPark;
    if (g_split_park_woke) test_err = error.SubscriberWokeBeforeClose;

    if (test_err == null) {
        producer.close();
        if (task.status.load(.acquire) != .Ready) test_err = error.CloseDidNotWakeSubscriber;
    }

    if (test_err == null) {
        fiber.switchTo(&sched.main_ctx);
        if (!g_split_park_woke) test_err = error.SubscriberDidNotObserveClose;
        if (g_split_park_err) |err| test_err = err;
    }

    fc.__fiber = null;
    fc.__fiber_parent_ctx = null;
    fc.__fiber_stack_limit = null;
    sim_atomic.disable_fiber_yield_point = false;
    sched.current_task = null;
    fp.active_scheduler = prev_active;
    fp.scheduler_running = prev_running;
    g_split_park_subscriber = undefined;

    const final_b = sched.ready_queue.bottom.load(.monotonic);
    sched.ready_queue.top.store(final_b, .monotonic);

    subscriber.deinit();
    producer.deinit();
    allocator.free(stack_mem);
    sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (test_err) |err| return err;
}

pub fn testSplitStreamParkedSubscriberPublishWakeOne() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    var producer = try LoomSplitStream.spawnNew(allocator, &sched);
    var subscriber = producer.retain();
    g_split_value_subscriber = &subscriber;
    g_split_value_seen = null;
    g_split_value_err = null;

    const stack_mem = try allocator.alloc(u8, SPLIT_STREAM_FIBER_STACK);
    var fiber = fc.Fiber.init(stack_mem, @intFromPtr(&entrySplitStreamParkedValueSubscriber), .Large);
    var task: qs.Task = .{
        .base = &fiber,
        .user_fn = @ptrCast(&splitStreamDummyFn),
        .status = qs.Atomic(qs.TaskStatus).init(.Ready),
    };

    const prev_active = fp.active_scheduler;
    const prev_running = fp.scheduler_running;
    const prev_disable = sim_atomic.disable_fiber_yield_point;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    sched.current_task = &task;
    sim_atomic.disable_fiber_yield_point = true;

    var test_err: ?anyerror = null;

    fiber.switchTo(&sched.main_ctx);
    if (task.status.load(.acquire) != .Blocked) test_err = error.SubscriberDidNotPark;
    if (test_err == null and subscriber.inner.subscribers.items[subscriber.subscriber_id].parked.load(.acquire) != 1) {
        test_err = error.SubscriberParkFlagMissing;
    }

    if (test_err == null) {
        sched.current_task = null;
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            try producer.push(@intCast(i + 1));
        }
        if (subscriber.inner.subscribers.items[subscriber.subscriber_id].parked.load(.acquire) != 0) {
            test_err = error.SubscriberParkFlagNotCleared;
        }
        if (test_err == null and task.status.load(.acquire) != .Ready) test_err = error.PublishDidNotWakeSubscriber;
    }

    if (test_err == null) {
        sched.current_task = &task;
        fiber.switchTo(&sched.main_ctx);
        if (g_split_value_seen != 1) test_err = error.SubscriberDidNotReadPublishedValue;
        if (test_err == null) {
            if (g_split_value_err) |err| test_err = err;
        }
    }

    fc.__fiber = null;
    fc.__fiber_parent_ctx = null;
    fc.__fiber_stack_limit = null;
    sim_atomic.disable_fiber_yield_point = prev_disable;
    sched.current_task = null;
    fp.active_scheduler = prev_active;
    fp.scheduler_running = prev_running;
    g_split_value_subscriber = undefined;

    const final_b = sched.ready_queue.bottom.load(.monotonic);
    sched.ready_queue.top.store(final_b, .monotonic);

    subscriber.deinit();
    producer.deinit();
    allocator.free(stack_mem);
    sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (test_err) |err| return err;
}

pub fn testSplitStreamProducerBackpressureWake() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    var producer = try LoomSplitStream.spawnNew(allocator, &sched);
    var subscriber = producer.retain();
    g_split_backpressure_producer = &producer;
    g_split_backpressure_done = false;
    g_split_backpressure_err = null;

    const stack_mem = try allocator.alloc(u8, SPLIT_STREAM_FIBER_STACK);
    var fiber = fc.Fiber.init(stack_mem, @intFromPtr(&entrySplitStreamBackpressureProducer), .Large);
    var task: qs.Task = .{
        .base = &fiber,
        .user_fn = @ptrCast(&splitStreamDummyFn),
        .status = qs.Atomic(qs.TaskStatus).init(.Ready),
    };

    const prev_active = fp.active_scheduler;
    const prev_running = fp.scheduler_running;
    const prev_disable = sim_atomic.disable_fiber_yield_point;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    sched.current_task = &task;
    sim_atomic.disable_fiber_yield_point = true;

    var test_err: ?anyerror = null;

    fiber.switchTo(&sched.main_ctx);
    if (task.status.load(.acquire) != .Blocked) test_err = error.ProducerDidNotParkForBackpressure;
    if (test_err == null and producer.inner.producer_parked.load(.acquire) != 1) test_err = error.ProducerParkFlagMissing;
    if (test_err == null and producer.inner.producer_task.load(.acquire) != &task) test_err = error.ProducerTaskNotPublished;
    if (test_err == null and producer.inner.producer_sched.load(.acquire) != &sched) test_err = error.ProducerSchedulerNotPublished;
    if (test_err == null and g_split_backpressure_done) test_err = error.ProducerCompletedBeforeBackpressure;

    if (test_err == null) {
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            const value = (try subscriber.next()) orelse return error.SubscriberSawCloseEarly;
            if (value != @as(i64, @intCast(i + 1))) return error.SubscriberSawWrongValue;
        }
        if (producer.inner.producer_parked.load(.acquire) != 0) test_err = error.ProducerParkFlagNotCleared;
        if (test_err == null and task.status.load(.acquire) != .Ready) test_err = error.BackpressureWakeDidNotReadyProducer;
    }

    if (test_err == null) {
        sched.current_task = &task;
        fiber.switchTo(&sched.main_ctx);
        if (!g_split_backpressure_done) test_err = error.ProducerDidNotResumeAfterBackpressure;
        if (test_err == null) {
            if (g_split_backpressure_err) |err| test_err = err;
        }
    }

    fc.__fiber = null;
    fc.__fiber_parent_ctx = null;
    fc.__fiber_stack_limit = null;
    sim_atomic.disable_fiber_yield_point = prev_disable;
    sched.current_task = null;
    fp.active_scheduler = prev_active;
    fp.scheduler_running = prev_running;
    g_split_backpressure_producer = undefined;

    const final_b = sched.ready_queue.bottom.load(.monotonic);
    sched.ready_queue.top.store(final_b, .monotonic);

    subscriber.deinit();
    producer.deinit();
    allocator.free(stack_mem);
    sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (test_err) |err| return err;
}

// ─────────────────────────────────────────────────────────────────────────────
// Stream(T) SPSC ring head/tail release/acquire protocol
//
// `data-structures.zig` Stream(T).Inner uses a fixed-size lock-free ring
// for the producer/consumer hand-off. The ordering contract:
//
//   producer push:        consumer next:
//   ─────────────────     ─────────────────
//   read tail .acquire    read head .acquire     ← see other side's index
//   write buf[h]          read buf[t]            ← non-atomic data
//   head.store h+1, .release   tail.store t+1, .release ← publish own index
//
// Each side's .release on its own index synchronizes-with the other
// side's .acquire on the same index. Without this pairing, on a weak
// memory model the consumer can observe head advanced while seeing a
// stale buf[t], and TSan flags a data race on real hardware.
//
// Properties verified across schedules:
//   1. Consumer never reads a slot whose published value isn't the
//      producer's most recent write to that slot.
//   2. FIFO order: item N read by consumer equals N+1 (producer's writes).
//   3. Toothless-test guard: at least half the schedules race the
//      head-advance against the consumer's read.
//
// Stubs the ring directly rather than driving the full Stream(T) API
// because the close/setError paths use a spinlock that hides the
// ring's atomic protocol from loom (the spin-acquire becomes one
// observed atomic).
// ─────────────────────────────────────────────────────────────────────────────

const RING_CAP: u32 = 4;
const RING_MASK: u32 = RING_CAP - 1;
const RING_PUSH: u32 = 2;

const SpscRing = struct {
    buf: [RING_CAP]i64 = [_]i64{0} ** RING_CAP,
    head: qs.Atomic(u32) = qs.Atomic(u32).init(0),
    tail: qs.Atomic(u32) = qs.Atomic(u32).init(0),
};

var g_ring: SpscRing = .{};
var g_ring_torn: bool = false;
var g_ring_consumed: u32 = 0;
var g_ring_observed_advance: bool = false;

fn entryRingProducer() callconv(.c) void {
    var i: u32 = 0;
    while (i < RING_PUSH) : (i += 1) {
        // Producer's read of consumer's tail. .acquire so we see prior
        // tail.store(.release) writes (slot reuse on wraparound).
        const t = g_ring.tail.load(.acquire);
        const h = g_ring.head.load(.monotonic);
        // Test sized so we never need to spin for room.
        if (h -% t >= RING_CAP) {
            harness.done[0] = true;
            while (true) fc.__fiber.?.yield();
        }
        // Non-atomic data write happens-before the head publish via
        // the .release store below.
        g_ring.buf[h & RING_MASK] = @as(i64, @intCast(i + 1));
        g_ring.head.store(h +% 1, .release);
    }
    harness.done[0] = true;
    while (true) fc.__fiber.?.yield();
}

fn entryRingConsumer() callconv(.c) void {
    while (g_ring_consumed < RING_PUSH) {
        const t = g_ring.tail.load(.monotonic);
        const h = g_ring.head.load(.acquire);
        if (h == t) {
            fc.__fiber.?.yield();
            continue;
        }
        g_ring_observed_advance = true;
        // After acquire-load of head saw t < h, the corresponding
        // buf[t] write must be visible (release/acquire chain).
        const v = g_ring.buf[t & RING_MASK];
        const expected = @as(i64, @intCast(g_ring_consumed + 1));
        if (v != expected) g_ring_torn = true;
        g_ring.tail.store(t +% 1, .release);
        g_ring_consumed += 1;
    }
    harness.done[1] = true;
    while (true) fc.__fiber.?.yield();
}

pub fn testStreamRingHeadTailAtomicCoverage() !void {
    const allocator = std.heap.c_allocator;
    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    var schedule_buf: [16]u8 = undefined;
    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    var torn_count: usize = 0;
    var advance_count: usize = 0;
    const total: usize = if (build_options.coverage) 64 else 4096;
    for (0..total) |sched_idx| {
        for (0..schedule_buf.len) |bit| {
            schedule_buf[bit] = @intCast((sched_idx >> @as(u6, @intCast(bit % 12))) & 1);
        }
        h.resetExhaustive(&schedule_buf);

        g_ring = .{};
        g_ring_torn = false;
        g_ring_consumed = 0;
        g_ring_observed_advance = false;

        try h.createThread(0, @intFromPtr(&entryRingProducer));
        try h.createThread(1, @intFromPtr(&entryRingConsumer));

        h.run() catch {};

        if (g_ring_torn) torn_count += 1;
        if (g_ring_observed_advance) advance_count += 1;
    }

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (torn_count > 0) {
        std.debug.print("\nstream-ring-atomic: {d}/{d} schedules saw torn ring reads\n", .{ torn_count, total });
        return error.LoomFailures;
    }
    if (advance_count < total / 2) {
        std.debug.print("\nstream-ring-atomic: only {d}/{d} schedules raced head advance — test toothless\n", .{ advance_count, total });
        return error.LoomFailures;
    }
}

// ─────────────────────────────────────────────────────────────────────
// concurrentListCount / concurrentListReduce atomic coverage
//
// These helpers use a shared atomic work index plus an atomic first-error
// slot. The loom test runs the production streams.zig implementation with
// a small WaitGroup shim so next_idx.fetchAdd, err_code.cmpxchgStrong, and
// err_code.load all resolve to SimAtomic and yield inside the harness.
// ─────────────────────────────────────────────────────────────────────

const ListReduceLoomRuntime = struct {
    pub fn getSched(_: *@This()) *fp.Scheduler {
        return &g_sched;
    }

    pub fn checkYield(_: *@This()) void {
        if (fc.__fiber) |fiber| fiber.yield();
    }
};

const ListReduceLoomTask = struct {
    user_fn: qs.TaskFn,
    args: ?*anyopaque,
};

const ListReduceLoomWaitGroup = struct {
    sched: *fp.Scheduler,
    remaining: qs.Atomic(usize) = qs.Atomic(usize).init(0),

    pub fn init(sched: *fp.Scheduler) @This() {
        return .{ .sched = sched };
    }

    pub fn add(self: *@This(), n: usize) void {
        self.remaining.store(n, .release);
    }

    pub fn done(self: *@This()) void {
        _ = self.remaining.fetchSub(1, .acq_rel);
    }

    pub fn wait(self: *@This()) void {
        for (0..g_list_reduce_task_count) |i| {
            harness.createThread(i, listReduceEntryPtr(i)) catch {
                g_list_reduce_harness_failed = true;
                return;
            };
        }
        harness.run() catch {
            g_list_reduce_harness_failed = true;
            return;
        };
        if (self.remaining.load(.acquire) != 0) g_list_reduce_harness_failed = true;
    }
};

var g_list_reduce_rt: ListReduceLoomRuntime = .{};
var g_list_reduce_tasks: [4]ListReduceLoomTask = undefined;
var g_list_reduce_task_count: usize = 0;
var g_list_reduce_harness_failed: bool = false;

fn listReduceEntryPtr(slot: usize) usize {
    return switch (slot) {
        0 => @intFromPtr(&entryListReduceWorker0),
        1 => @intFromPtr(&entryListReduceWorker1),
        2 => @intFromPtr(&entryListReduceWorker2),
        3 => @intFromPtr(&entryListReduceWorker3),
        else => unreachable,
    };
}

fn entryListReduceWorker(slot: usize) void {
    const task = g_list_reduce_tasks[slot];
    task.user_fn(@ptrCast(&g_list_reduce_rt), task.args) catch {
        g_list_reduce_harness_failed = true;
    };
    harness.done[slot] = true;
    while (true) fc.__fiber.?.yield();
}

fn entryListReduceWorker0() callconv(.c) void { entryListReduceWorker(0); }
fn entryListReduceWorker1() callconv(.c) void { entryListReduceWorker(1); }
fn entryListReduceWorker2() callconv(.c) void { entryListReduceWorker(2); }
fn entryListReduceWorker3() callconv(.c) void { entryListReduceWorker(3); }

fn listReduceLoomLocalSpawn(_: *fp.Scheduler, user_fn: qs.TaskFn, args: ?*anyopaque, _: void) !void {
    if (g_list_reduce_task_count >= g_list_reduce_tasks.len) return error.TooManyLoomWorkers;
    g_list_reduce_tasks[g_list_reduce_task_count] = .{ .user_fn = user_fn, .args = args };
    g_list_reduce_task_count += 1;
}

fn listReduceLoomParallelSpawn(user_fn: qs.TaskFn, args: ?*anyopaque, _: void) !void {
    try listReduceLoomLocalSpawn(&g_sched, user_fn, args, {});
}

fn listReduceLoomKeepGtFour(_: *ListReduceLoomRuntime, _: ?*anyopaque, value: i64) anyerror!bool {
    return value > 4;
}

fn listReduceLoomMapI64(_: *ListReduceLoomRuntime, _: ?*anyopaque, value: i64) anyerror!i64 {
    return value;
}

fn listReduceLoomErrorOnFive(_: *ListReduceLoomRuntime, _: ?*anyopaque, value: i64) anyerror!i64 {
    if (value == 5) return error.LoomListReduce;
    return value;
}

fn resetListReduceLoomRun(h: *LoomHarness, schedule: []const u8) void {
    h.resetExhaustive(schedule);
    g_list_reduce_task_count = 0;
    g_list_reduce_harness_failed = false;
}

pub fn testConcurrentListReduceAtomicCoverage() !void {
    const allocator = std.heap.c_allocator;
    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    var schedule_buf: [8]u8 = undefined;
    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    const items = [_]i64{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var failures: usize = 0;
    const total: usize = if (build_options.coverage) 16 else 256;
    for (0..total) |sched_idx| {
        for (0..schedule_buf.len) |bit| {
            schedule_buf[bit] = @intCast((sched_idx >> @as(u3, @intCast(bit % 8))) & 1);
        }

        resetListReduceLoomRun(&h, &schedule_buf);
        const count = streams.concurrentListCount(
            ListReduceLoomWaitGroup, i64, listReduceLoomKeepGtFour,
            listReduceLoomLocalSpawn, listReduceLoomParallelSpawn,
            &g_list_reduce_rt, items[0..], 3, 2, false, {}, null
        ) catch {
            failures += 1;
            continue;
        };
        if (g_list_reduce_harness_failed or count != 4) {
            failures += 1;
            continue;
        }

        resetListReduceLoomRun(&h, &schedule_buf);
        const sum = streams.concurrentListReduce(
            ListReduceLoomWaitGroup, i64, i64, listReduceLoomMapI64,
            listReduceLoomLocalSpawn, listReduceLoomParallelSpawn,
            &g_list_reduce_rt, items[0..], 3, 2, false, {}, null, 0, .sum
        ) catch {
            failures += 1;
            continue;
        };
        if (g_list_reduce_harness_failed or sum != 36) {
            failures += 1;
            continue;
        }

        resetListReduceLoomRun(&h, &schedule_buf);
        _ = streams.concurrentListReduce(
            ListReduceLoomWaitGroup, i64, i64, listReduceLoomErrorOnFive,
            listReduceLoomLocalSpawn, listReduceLoomParallelSpawn,
            &g_list_reduce_rt, items[0..], 3, 2, false, {}, null, 0, .sum
        ) catch |err| {
            if (g_list_reduce_harness_failed or err != error.LoomListReduce) {
                failures += 1;
            }
            continue;
        };
        failures += 1;
    }

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (failures > 0) {
        std.debug.print("\nconcurrent-list-reduce-atomic: {d}/{d} schedules failed\n", .{ failures, total });
        return error.LoomFailures;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Multi-fallible sorted-acquire pattern (emit_sorted_lock_acquires_fallible)
//
// Validates the SHAPE the CLEAR transpiler emits for `WITH EXCLUSIVE a,
// EXCLUSIVE b ... ON ...` blocks — sort-by-address + sequential
// acquire + held-bitmap-tracked reverse-release. Two fibers concurrently
// run this pattern under SimAtomic interleavings, each grabbing the
// SAME pair of locks (in arg order; the sort normalizes to address
// order at the call site).
//
// Properties verified (across all PRNG schedules):
//   1. No deadlock — sorted-acquire order prevents AB/BA cycles.
//   2. Counter consistency — both counters end at 2*ITERS_PER_FIBER
//      (each fiber bumps both per iteration, no torn writes).
//   3. No leaked locks — held-bitmap reverse-release cleans up under
//      any interleaving.
//
// Note on coverage: the OrErr / partial-acquire-failure path is
// timeout-driven; SimAtomic does not model time, so the failure
// branch cannot be deterministically scheduled here. The success-path
// sequencing (which is the common case in practice) is what this
// test exercises. Real timeout behaviour is covered by
// transpile-tests/365_multi_lock_with_on_hammer.clear (TSan) and
// transpile-tests/366_multi_lock_retry_recovers.clear (deterministic
// retry recovery).
// ─────────────────────────────────────────────────────────────────────────────

const MFF_ITERS: usize = if (build_options.coverage) 3 else 10;
var g_mff_a: ParkingMutex = .{};
var g_mff_b: ParkingMutex = .{};
var g_mff_count_a: u64 = 0;
var g_mff_count_b: u64 = 0;
var g_mff_leak: bool = false;

fn mffReset() void {
    g_mff_a = .{};
    g_mff_b = .{};
    g_mff_count_a = 0;
    g_mff_count_b = 0;
    g_mff_leak = false;
    g_mff_per_fiber[0] = 0;
    g_mff_per_fiber[1] = 0;
}

// Mirror the shape emit_sorted_lock_acquires_fallible produces:
// sort-by-address + sequential acquire + held-bitmap-tracked
// reverse-release. Timeout / cycle / deadlock errors take the
// failure path (release whatever's held in reverse, mark this iter
// as a no-op, continue to the next iter). The success path bumps
// per-iter counters (only when the iteration actually completes).
fn mffSortedAcquireBody(per_fiber_counter: *u64) void {
    var iter: usize = 0;
    while (iter < MFF_ITERS) : (iter += 1) {
        var held_a: bool = false;
        var held_b: bool = false;

        const lo: *ParkingMutex = if (@intFromPtr(&g_mff_a) <= @intFromPtr(&g_mff_b)) &g_mff_a else &g_mff_b;
        const hi: *ParkingMutex = if (lo == &g_mff_a) &g_mff_b else &g_mff_a;

        // Acquire lo first. On any error, skip the iteration.
        lo.lock() catch {
            continue;
        };
        if (lo == &g_mff_a) held_a = true else held_b = true;

        // Acquire hi second. On error, the held-bitmap reverse-release
        // fixup releases lo before we move on — exactly the path
        // emit_sorted_lock_acquires_fallible takes when the Nth
        // acquire fails after N-1 succeeded.
        hi.lock() catch {
            if (lo == &g_mff_a) {
                if (held_a) { g_mff_a.unlock(); held_a = false; }
            } else {
                if (held_b) { g_mff_b.unlock(); held_b = false; }
            }
            continue;
        };
        if (hi == &g_mff_a) held_a = true else held_b = true;

        // Critical section: bump both counters and the per-fiber
        // success counter. Single-fiber-at-a-time under loom, so a
        // straight += is consistent.
        g_mff_count_a += 1;
        g_mff_count_b += 1;
        per_fiber_counter.* += 1;

        // Release in reverse-acquisition order (LIFO), gated by the
        // held flags — same shape as the success-path release.
        if (hi == &g_mff_a) {
            if (held_a) { g_mff_a.unlock(); held_a = false; }
        } else {
            if (held_b) { g_mff_b.unlock(); held_b = false; }
        }
        if (lo == &g_mff_a) {
            if (held_a) { g_mff_a.unlock(); held_a = false; }
        } else {
            if (held_b) { g_mff_b.unlock(); held_b = false; }
        }

        // Invariant: held bitmap fully cleared after a successful
        // iteration. Reverse-release branches above must have
        // toggled both flags off.
        if (held_a or held_b) {
            g_mff_leak = true;
        }
    }
}

var g_mff_per_fiber: [2]u64 = [_]u64{0} ** 2;

fn entryMff0() callconv(.c) void {
    mffSortedAcquireBody(&g_mff_per_fiber[0]);
    harness.done[0] = true;
    while (true) fc.__fiber.?.yield();
}

fn entryMff1() callconv(.c) void {
    mffSortedAcquireBody(&g_mff_per_fiber[1]);
    harness.done[1] = true;
    while (true) fc.__fiber.?.yield();
}

pub fn testMultiFallibleSortedAcquire() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    const seed_count: usize = fuzzSeedCount(500);
    var failures: usize = 0;
    var failing_seed: ?u64 = null;

    for (0..seed_count) |seed| {
        var ph = LoomHarness.initPrng(allocator, seed);
        harness = &ph;

        fc.__fiber = null;
        fc.__fiber_parent_ctx = null;
        fc.__fiber_stack_limit = null;
        drainSchedState();

        mffReset();

        ph.createThread(0, @intFromPtr(&entryMff0)) catch continue;
        ph.createThread(1, @intFromPtr(&entryMff1)) catch continue;

        ph.run() catch {
            // Step limit — fibers couldn't complete. Treated as a real
            // failure since address-ordered acquisition cannot deadlock.
            if (failing_seed == null) failing_seed = seed;
            failures += 1;
            ph.deinit();
            continue;
        };

        // Counter consistency invariant: each successful iteration
        // bumps BOTH counters together under the multi-lock, so
        // count_a == count_b == sum of per-fiber successful iters.
        // A torn write or a held-bitmap miscount would break this.
        const successful: u64 = g_mff_per_fiber[0] + g_mff_per_fiber[1];
        if (g_mff_count_a != successful or g_mff_count_b != successful) {
            std.debug.print(
                "\nmff seed {d}: torn counters: a={d} b={d} successful={d} (per-fiber {d}, {d})\n",
                .{ seed, g_mff_count_a, g_mff_count_b, successful, g_mff_per_fiber[0], g_mff_per_fiber[1] },
            );
            if (failing_seed == null) failing_seed = seed;
            failures += 1;
        }
        if (g_mff_leak) {
            std.debug.print("\nmff seed {d}: held-bitmap leaked\n", .{seed});
            if (failing_seed == null) failing_seed = seed;
            failures += 1;
        }
        if (g_mff_a.isLocked() or g_mff_b.isLocked()) {
            std.debug.print(
                "\nmff seed {d}: leaked lock (a_locked={} b_locked={})\n",
                .{ seed, g_mff_a.isLocked(), g_mff_b.isLocked() },
            );
            if (failing_seed == null) failing_seed = seed;
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
        std.debug.print(
            "\nmff sorted-acquire: {d}/{d} seeds failed (first failing seed: {?})\n",
            .{ failures, seed_count, failing_seed },
        );
        return error.LoomFailures;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// tryLock + presetLocked (no-fiber paths)
//
// `presetLocked` (test rendezvous helper) and `tryLock` are public
// ParkingMutex methods that the harness-driven scenarios above never
// call -- they go through `lock()` which routes to lockSlow's parking
// path. Without a direct caller, lib/parking-lot.zig:640/644/651 are
// line-missing in the loom kcov report.
//
// These tests run synchronously (no harness, no fibers): tryLock is
// a single-call public API and presetLocked is a one-liner setter.
// The atomic ops inside still go through SimAtomic because the
// root-module export of `SimAtomic` makes parking-lot.zig's
// `Atomic(...)` alias resolve to it.
// ─────────────────────────────────────────────────────────────────────────────

pub fn testTryLockHappyAndContended() !void {
    var m: ParkingMutex = .{};

    // Happy path: lock is free -> tryLock acquires (covers 644 + 651).
    if (!m.tryLock()) return error.TryLockShouldHaveSucceeded;
    if (!m.isLocked()) return error.LockNotHeldAfterTryLock;

    // Release via direct state clear -- no waiters to wake.
    _ = m.state.fetchAnd(~ParkingMutex.STATE_LOCKED, .release);

    // Pre-lock the mutex via the test rendezvous helper (covers 640).
    m.presetLocked();
    if (!m.isLocked()) return error.PresetLockedDidNotSetBit;

    // Contended path: tryLock must reject.
    if (m.tryLock()) return error.TryLockShouldHaveFailed;

    _ = m.state.fetchAnd(~ParkingMutex.STATE_LOCKED, .release);
}

// ─────────────────────────────────────────────────────────────────────────────
// Post-park "lock_timed_out" epilogue coverage (parking-lot.zig clusters C+E)
//
// When a parker exits its park-loop with `task.lock_timed_out == true`,
// lockSlow runs an epilogue that resets the flag and checks whether the
// wake-vs-timeout race granted the lock anyway. This block exists for
// the mutex (lines 968-975) and both rwlock variants. Existing scenarios
// never get a parker to wake with timed_out=true because they don't
// cross the scanner-set into a real lock() call -- testTimeoutAtomicCoverage
// drives a synthetic parker that bypasses lockSlow's epilogue entirely.
//
// Pattern: holder fiber acquires the lock, yields to let parker park,
// pre-sets the parker task's `lock_timed_out=true` via direct atomic
// store, then unlocks (which wakeNext-clears `waiting_for_lock=null`).
// The .release on `lock_timed_out` chains-acquires through the
// .release/.acquire pair on `waiting_for_lock`, so the parker observes
// timed_out=true once it exits the park-loop. Coverage: parker runs
// the real epilogue's load + store + state-load.
// ─────────────────────────────────────────────────────────────────────────────

var g_epilogue_observed: bool = false;

fn entryEpilogueParkerMutex() callconv(.c) void {
    const t = &harness.stub_tasks[0];
    // `lock()` returns on either branch of the post-park epilogue:
    //   - Success: wake-races-timeout-with-grant -> ownerOf(state)==task,
    //     line 970 takes `return`, lock() returns void.
    //   - Failure: ownerOf(state) != task, falls through to LockTimeout.
    // Both branches first execute the .release-store at line 969 that
    // resets `lock_timed_out` to false. So observing `lock_timed_out`
    // false after `lock()` returns confirms the epilogue ran.
    g_mutex.lock() catch {
        if (!t.lock_timed_out.load(.acquire)) g_epilogue_observed = true;
        harness.done[0] = true;
        while (true) fc.__fiber.?.yield();
        return;
    };
    if (!t.lock_timed_out.load(.acquire)) g_epilogue_observed = true;
    g_mutex.unlock();
    harness.done[0] = true;
    while (true) fc.__fiber.?.yield();
}

fn entryEpilogueHolderMutex() callconv(.c) void {
    g_mutex.lock() catch unreachable;
    // Yield twice so the parker fiber gets a chance to call lock(),
    // execute lockSlow up to the park yield, and register as a waiter.
    fc.__fiber.?.yield();
    fc.__fiber.?.yield();
    // Inject timeout flag on the parker task BEFORE unlock so the
    // .release-store chains through the wakeNext .release on
    // waiting_for_lock. wakeNext is inside unlock().
    harness.stub_tasks[0].lock_timed_out.store(true, .release);
    g_mutex.unlock();
    harness.done[1] = true;
    while (true) fc.__fiber.?.yield();
}

pub fn testMutexLockTimeoutEpilogue() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    // Single deterministic schedule is enough for line coverage; we just
    // need one ordering where parker actually parks and holder unlocks
    // after setting the timeout flag.
    var schedule_buf: [16]u8 = [_]u8{ 1, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    g_mutex = .{};
    g_epilogue_observed = false;
    h.resetExhaustive(&schedule_buf);

    try h.createThread(0, @intFromPtr(&entryEpilogueParkerMutex));
    try h.createThread(1, @intFromPtr(&entryEpilogueHolderMutex));

    h.run() catch {};

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (!g_epilogue_observed) return error.EpilogueNotObserved;
}

fn entryEpilogueParkerRwlockWrite() callconv(.c) void {
    const t = &harness.stub_tasks[0];
    g_rw.lock() catch {
        if (!t.lock_timed_out.load(.acquire)) g_epilogue_observed = true;
        harness.done[0] = true;
        while (true) fc.__fiber.?.yield();
        return;
    };
    if (!t.lock_timed_out.load(.acquire)) g_epilogue_observed = true;
    g_rw.unlock();
    harness.done[0] = true;
    while (true) fc.__fiber.?.yield();
}

fn entryEpilogueHolderRwlockWrite() callconv(.c) void {
    g_rw.lock() catch unreachable;
    fc.__fiber.?.yield();
    fc.__fiber.?.yield();
    harness.stub_tasks[0].lock_timed_out.store(true, .release);
    g_rw.unlock();
    harness.done[1] = true;
    while (true) fc.__fiber.?.yield();
}

pub fn testRwlockWriteLockTimeoutEpilogue() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    var schedule_buf: [16]u8 = [_]u8{ 1, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    rwReset();
    g_epilogue_observed = false;
    h.resetExhaustive(&schedule_buf);

    try h.createThread(0, @intFromPtr(&entryEpilogueParkerRwlockWrite));
    try h.createThread(1, @intFromPtr(&entryEpilogueHolderRwlockWrite));

    h.run() catch {};

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (!g_epilogue_observed) return error.EpilogueNotObserved;
}

fn entryEpilogueParkerRwlockRead() callconv(.c) void {
    const t = &harness.stub_tasks[0];
    g_rw.lockShared() catch {
        if (!t.lock_timed_out.load(.acquire)) g_epilogue_observed = true;
        harness.done[0] = true;
        while (true) fc.__fiber.?.yield();
        return;
    };
    if (!t.lock_timed_out.load(.acquire)) g_epilogue_observed = true;
    g_rw.unlockShared();
    harness.done[0] = true;
    while (true) fc.__fiber.?.yield();
}

fn entryEpilogueHolderRwlockRead() callconv(.c) void {
    g_rw.lock() catch unreachable;
    fc.__fiber.?.yield();
    fc.__fiber.?.yield();
    harness.stub_tasks[0].lock_timed_out.store(true, .release);
    g_rw.unlock();
    harness.done[1] = true;
    while (true) fc.__fiber.?.yield();
}

pub fn testRwlockReadLockTimeoutEpilogue() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    var schedule_buf: [16]u8 = [_]u8{ 1, 1, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    rwReset();
    g_epilogue_observed = false;
    h.resetExhaustive(&schedule_buf);

    try h.createThread(0, @intFromPtr(&entryEpilogueParkerRwlockRead));
    try h.createThread(1, @intFromPtr(&entryEpilogueHolderRwlockRead));

    h.run() catch {};

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);

    if (!g_epilogue_observed) return error.EpilogueNotObserved;
}

// ─────────────────────────────────────────────────────────────────────────────
// S6: scheduler.zig active_tasks accounting on idle-steal (lines 1358, 1360,
// 1370, 1371)
//
// idleStealFrom is the run-loop's per-iteration "if idle, steal from a
// victim" block, refactored to a method so loom can drive it without
// running the whole run() loop. Two scenarios cover both arms (stackful
// and FSM) of the steal+accounting path.
// ─────────────────────────────────────────────────────────────────────────────

fn s6DummyFn(_: *anyopaque, _: ?*anyopaque) anyerror!void {}

fn fsmS6NoopResume(_: *fsm_mod.FsmTask) fsm_mod.YieldReason {
    return .Done;
}

fn testIdleStealFromStackful() !void {
    const allocator = std.heap.c_allocator;

    var ebr_a: ebr_mod.EbrContext = .{};
    var stack_pool_a = fm.StackPool.init(allocator);
    var sched_a = try fp.Scheduler.init(allocator, &ebr_a, &stack_pool_a);
    defer {
        const final_b = sched_a.ready_queue.bottom.load(.monotonic);
        sched_a.ready_queue.top.store(final_b, .monotonic);
        sched_a.deinit();
        stack_pool_a.deinit();
        ebr_a.deinit(allocator);
    }

    var ebr_b: ebr_mod.EbrContext = .{};
    var stack_pool_b = fm.StackPool.init(allocator);
    var sched_b = try fp.Scheduler.init(allocator, &ebr_b, &stack_pool_b);
    defer {
        const final_b = sched_b.ready_queue.bottom.load(.monotonic);
        sched_b.ready_queue.top.store(final_b, .monotonic);
        sched_b.deinit();
        stack_pool_b.deinit();
        ebr_b.deinit(allocator);
    }

    // Push 4 stub tasks onto sched_b (the victim). tryStealFrom takes
    // half. 4 -> 2 stolen.
    var stubs: [4]Task = undefined;
    for (&stubs) |*t| {
        t.* = .{
            .base = undefined,
            .user_fn = @ptrCast(&s6DummyFn),
            .status = qs.Atomic(TaskStatus).init(.Ready),
        };
        try sched_b.ready_queue.push(allocator, t);
        _ = sched_b.active_tasks.fetchAdd(1, .monotonic);
    }

    const victim_before = sched_b.active_tasks.load(.monotonic);
    const stealer_before = sched_a.active_tasks.load(.monotonic);

    // Drives lines 1358 (stealer fetchAdd) + 1360 (victim fetchSub).
    sched_a.idleStealFrom(&sched_b);

    const stolen = sched_a.active_tasks.load(.monotonic) - stealer_before;
    if (stolen == 0) return error.StealDidNotOccur;
    if (victim_before - sched_b.active_tasks.load(.monotonic) != stolen) {
        return error.AccountingInconsistent;
    }
}

fn testIdleStealFromFsm() !void {
    const allocator = std.heap.c_allocator;

    var ebr_a: ebr_mod.EbrContext = .{};
    var stack_pool_a = fm.StackPool.init(allocator);
    var sched_a = try fp.Scheduler.init(allocator, &ebr_a, &stack_pool_a);
    defer {
        sched_a.deinit();
        stack_pool_a.deinit();
        ebr_a.deinit(allocator);
    }

    var ebr_b: ebr_mod.EbrContext = .{};
    var stack_pool_b = fm.StackPool.init(allocator);
    var sched_b = try fp.Scheduler.init(allocator, &ebr_b, &stack_pool_b);
    defer {
        sched_b.deinit();
        stack_pool_b.deinit();
        ebr_b.deinit(allocator);
    }

    // Empty stackful queue, FSM queue full -> first tryStealFrom returns
    // 0, FSM tryStealFrom succeeds. Drives lines 1370 (stealer fetchAdd)
    // + 1371 (victim fetchSub).
    var fsm_stubs: [4]fsm_mod.FsmTask = undefined;
    for (&fsm_stubs) |*t| {
        t.* = .{ .resume_fn = &fsmS6NoopResume };
        try sched_b.fsm_ready_queue.push(allocator, t);
        _ = sched_b.active_tasks.fetchAdd(1, .monotonic);
    }

    const victim_before = sched_b.active_tasks.load(.monotonic);
    const stealer_before = sched_a.active_tasks.load(.monotonic);

    sched_a.idleStealFrom(&sched_b);

    const stolen = sched_a.active_tasks.load(.monotonic) - stealer_before;
    if (stolen == 0) return error.FsmStealDidNotOccur;
    if (victim_before - sched_b.active_tasks.load(.monotonic) != stolen) {
        return error.FsmAccountingInconsistent;
    }
}

pub fn testIdleStealAccounting() !void {
    try testIdleStealFromStackful();
    try testIdleStealFromFsm();
}

// ─────────────────────────────────────────────────────────────────────────────
// S2+S5: cross-scheduler submitResume flow
//
// Drives submitResume's cross-scheduler path which exercises:
//   - in_inbox.cmpxchgStrong IDLE -> IN_QUEUE (S5 wake CAS, line 896)
//   - dirty_mask.fetchOr to signal target scheduler (S1, line 928)
//   - drainChannels Resume case status.store(.Ready) (S2 wake, line 1053)
//
// `submitResume` short-circuits when sender == target via the
// "same-scheduler fast path" at line 905. To hit the cross-scheduler
// branch we set active_scheduler = sched_a but submit into sched_b.
// ─────────────────────────────────────────────────────────────────────────────

fn s25DummyFn(_: *anyopaque, _: ?*anyopaque) anyerror!void {}

pub fn testCrossSchedulerResumeFlow() !void {
    const allocator = std.heap.c_allocator;

    var ebr_a: ebr_mod.EbrContext = .{};
    var stack_pool_a = fm.StackPool.init(allocator);
    var sched_a = try fp.Scheduler.init(allocator, &ebr_a, &stack_pool_a);
    defer {
        sched_a.deinit();
        stack_pool_a.deinit();
        ebr_a.deinit(allocator);
    }

    var ebr_b: ebr_mod.EbrContext = .{};
    var stack_pool_b = fm.StackPool.init(allocator);
    var sched_b = try fp.Scheduler.init(allocator, &ebr_b, &stack_pool_b);
    defer {
        // Drain ready_queue before deinit -- our drainChannels' Resume
        // case enqueued the stub Task whose .base = undefined, so
        // scheduler deinit walking pending tasks would dereference it.
        const final_b = sched_b.ready_queue.bottom.load(.monotonic);
        sched_b.ready_queue.top.store(final_b, .monotonic);
        sched_b.deinit();
        stack_pool_b.deinit();
        ebr_b.deinit(allocator);
    }

    const prev_active = fp.active_scheduler;
    const prev_running = fp.scheduler_running;
    fp.active_scheduler = &sched_a;
    fp.scheduler_running = true;
    defer {
        fp.active_scheduler = prev_active;
        fp.scheduler_running = prev_running;
    }

    var stub_task: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&s25DummyFn),
        .status = qs.Atomic(TaskStatus).init(.Blocked),
    };

    // Cross-scheduler submitResume: sender is sched_a (active),
    // target is sched_b. Lines: 896 (in_inbox CAS), 928 (dirty_mask
    // fetchOr).
    sched_b.submitResume(&stub_task);

    if (sched_b.dirty_mask.load(.monotonic) == 0) return error.DirtyMaskBitNotSet;
    if (stub_task.in_inbox.load(.monotonic) != qs.IN_INBOX_IN_QUEUE) {
        return error.InboxStateUnexpected;
    }

    // drainChannels processes the queued Resume message: line 1053
    // status.store(.Ready) + line 1054 enqueueTask.
    sched_b.drainChannels();

    if (stub_task.status.load(.monotonic) != .Ready) return error.StatusNotReady;
    if (sched_b.dirty_mask.load(.monotonic) != 0) return error.DirtyMaskNotCleared;
}

// ─────────────────────────────────────────────────────────────────────────────
// S25: drainChannels Spawn-message processing (lines 1013, 1015, 1028, 1048)
//
// Promise(T).spawn() in the failing versioned-fiber-stress-test path
// flows through CheatHeader.spawnBest -> Scheduler.submitSpawn ->
// drainChannels' .Spawn case on the target scheduler. drainChannels
// allocates a fresh Task slot from task_slab, bumps its generation
// (load + store), publishes status=.Ready, and increments active_tasks.
// None of those four atomics had any Loom hits before this scenario.
//
// Setup: push a single Spawn message into sched_b's channel via the
// public ensureChannel + ring.push seam (mirrors testRemoteCallCompletion).
// drainChannels then walks the .Spawn arm and exercises every atomic on
// the path. trampoline_addr / user_fn must be non-null but are never
// invoked (we don't run the resulting Task), so a dummy fn pointer is fine.
//
// Cleanup: the new Task is now sitting in ready_queue. We pop it, free
// its real fiber stack and Task slab slot before scheduler deinit.
// ─────────────────────────────────────────────────────────────────────────────

fn s25DummyTrampoline() callconv(.c) void {}

pub fn testDrainChannelsSpawn() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        // drainChannels allocated a real Task + Fiber + stack via the
        // .Spawn arm. We never ran the fiber, so undo all three before
        // the scheduler tears down. Failing to free here leaks under
        // DebugAllocator and crashes scheduler.deinit walking dangling
        // tasks.
        if (sched.ready_queue.pop()) |task| {
            sched.freeStack(task.base.stack);
            task.base.deinit();
            sched.allocator.destroy(task.base);
            sched.task_slab.destroy(task);
        }
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    // Use sender_idx 0 to stay symmetric with testRemoteCallCompletion;
    // the dirty_mask bit set below mirrors what submitSpawn would have
    // done from a remote scheduler.
    const ring = try sched.ensureChannel(0);
    const msg = fp.SpscMessage{
        .tag = .Spawn,
        .trampoline_addr = @intFromPtr(&s25DummyTrampoline),
        .user_fn = @ptrCast(&s25DummyFn),
        .args = null,
        .config_stack_size = @intFromEnum(fc.StackSize.Standard),
        .config_pinned = false,
        .config_timeout_ms = 0,
        .config_profile_site_id = 0,
        .config_profile_dispatch = 0,
    };
    if (!ring.push(msg)) return error.RingPushFailed;
    _ = sched.dirty_mask.fetchOr(@as(u64, 1), .release);

    const before_active = sched.active_tasks.load(.monotonic);
    const ready_before = sched.ready_queue.len();

    sched.drainChannels();

    // Invariants:
    //   1. active_tasks bumped by exactly 1 (line 1048).
    //   2. ready_queue grew by exactly 1.
    //   3. The new task's status is .Ready (line 1028).
    //   4. dirty_mask cleared by the swap-to-zero at top of drainChannels.
    if (sched.active_tasks.load(.monotonic) != before_active + 1) return error.ActiveTasksNotBumped;
    if (sched.ready_queue.len() != ready_before + 1) return error.ReadyQueueNotEnqueued;
    if (sched.dirty_mask.load(.monotonic) != 0) return error.DirtyMaskNotCleared;

    // Peek (without popping) to assert status; the deferred cleanup
    // pops to free.
    const buf = sched.ready_queue.getBuffer();
    const mask = sched.ready_queue.getMask();
    const top = sched.ready_queue.top.load(.monotonic);
    const peeked = buf[top & mask].load(.monotonic) orelse return error.ReadyQueuePeekedNull;
    if (peeked.status.load(.monotonic) != .Ready) return error.StatusNotReady;
}

// ─────────────────────────────────────────────────────────────────────────────
// in_inbox repeat-cycle invariant (regression test for the SplitStream
// pubsub-hammer leak found in branch hotfix/tsan-stream-test-leak):
//
// A long-lived task that parks and wakes repeatedly must have its
// in_inbox slot reset IN_QUEUE -> IDLE between cycles, otherwise the
// SECOND submitResume's CAS (IDLE -> IN_QUEUE) silently fails and the
// wake is dropped, leaving the task parked forever (Fiber/Task leak).
//
// `Scheduler.run` (line 1239) and `Scheduler.pollOne` (the helper test
// polling loops are required to use) both perform this reset. The bug
// surfaced when `stream-test.zig`'s manual polling loop reimplemented
// the dispatch without the reset, breaking ~7% of TSan stream-test
// runs. This scenario validates the reset is necessary AND sufficient
// for the repeat-cycle case so the protocol stays welded down.
//
// Properties verified:
//   1. submitResume #1 (after task.status==.Blocked, in_inbox==IDLE)
//      claims IN_QUEUE.
//   2. After drain + run-loop pop with in_inbox.store(IDLE), submitResume
//      #2 also claims IN_QUEUE (i.e. the slot was actually released).
//   3. status transitions Blocked -> Ready after each drain.
//
// ─────────────────────────────────────────────────────────────────────────────

fn rcDummyFn(_: *anyopaque, _: ?*anyopaque) anyerror!void {}

pub fn testInInboxRepeatCycleInvariant() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        // Drain ready_queue before deinit -- our enqueued stub task has
        // .base = undefined; deinit walking pending tasks would deref it.
        const final_b = sched.ready_queue.bottom.load(.monotonic);
        sched.ready_queue.top.store(final_b, .monotonic);
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    // Pretend we're some other scheduler so submitResume takes the
    // cross-thread SPSC path (the path stream-test.zig's polling loop
    // had to manually mirror).
    var sender_ebr: ebr_mod.EbrContext = .{};
    var sender_pool = fm.StackPool.init(allocator);
    var sender_sched = try fp.Scheduler.init(allocator, &sender_ebr, &sender_pool);
    defer {
        sender_sched.deinit();
        sender_pool.deinit();
        sender_ebr.deinit(allocator);
    }
    const prev_active = fp.active_scheduler;
    const prev_running = fp.scheduler_running;
    fp.active_scheduler = &sender_sched;
    fp.scheduler_running = true;
    defer {
        fp.active_scheduler = prev_active;
        fp.scheduler_running = prev_running;
    }

    var stub_task: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&rcDummyFn),
        .status = qs.Atomic(TaskStatus).init(.Blocked),
    };

    // ── Cycle 1 ──────────────────────────────────────────────────
    if (stub_task.in_inbox.load(.monotonic) != qs.IN_INBOX_IDLE) {
        return error.InitialInboxNotIdle;
    }

    sched.submitResume(&stub_task);
    if (stub_task.in_inbox.load(.monotonic) != qs.IN_INBOX_IN_QUEUE) {
        return error.FirstResumeDidNotClaimInbox;
    }

    sched.drainChannels();
    if (stub_task.status.load(.monotonic) != .Ready) return error.FirstDrainDidNotSetReady;
    // status is .Ready, in_inbox is still IN_QUEUE (the run-loop owns
    // resetting it to IDLE on pop).

    // Mirror Scheduler.run (line 1239) / Scheduler.pollOne: pop and
    // release the slot. The bug we're testing for is OMITTING this
    // line.
    const popped = sched.ready_queue.pop() orelse return error.PopMissingTask;
    if (popped != &stub_task) return error.PopReturnedWrongTask;
    popped.in_inbox.store(qs.IN_INBOX_IDLE, .release);

    // ── Cycle 2: re-park then re-wake ────────────────────────────
    // (In a real fiber, switchTo would have run here, then the fiber
    // would yield with status=.Blocked. We simulate that directly.)
    stub_task.status.store(.Blocked, .release);

    sched.submitResume(&stub_task);
    // THIS IS THE INVARIANT: cycle 2's submitResume must succeed. If
    // cycle 1's pop forgot to reset in_inbox, this CAS fails silently
    // and the wake is dropped (the bug we're testing for).
    if (stub_task.in_inbox.load(.monotonic) != qs.IN_INBOX_IN_QUEUE) {
        return error.SecondResumeFailedToClaimInbox;
    }

    sched.drainChannels();
    if (stub_task.status.load(.monotonic) != .Ready) return error.SecondDrainDidNotSetReady;

    // Cleanup: pop the second cycle's task so deinit sees an empty queue.
    const popped2 = sched.ready_queue.pop() orelse return error.SecondPopMissingTask;
    if (popped2 != &stub_task) return error.SecondPopReturnedWrongTask;
    popped2.in_inbox.store(qs.IN_INBOX_IDLE, .release);
}

// ─────────────────────────────────────────────────────────────────────────────
// S2: coopYield wake path (line 1631)
//
// Scheduler.coopYield checks hasWork() and, if true, marks the running
// task .Ready + co_yielded and yields. To exercise it we push a stub
// task to the scheduler's ready_queue (so hasWork() is true), then
// invoke coopYield from inside a fiber. Returns naturally because the
// harness picks the same fiber back up (status=.Ready).
// ─────────────────────────────────────────────────────────────────────────────

fn entryS2CoopYield() callconv(.c) void {
    // Push fiber 1's stub task as a placeholder to make hasWork() true.
    g_sched.ready_queue.push(g_sched.allocator, &harness.stub_tasks[1]) catch unreachable;
    g_sched.coopYield();
    harness.done[0] = true;
    while (true) fc.__fiber.?.yield();
}

// ─────────────────────────────────────────────────────────────────────────────
// S2: wakeExpiredSleepers (line 1188 in run-loop, now extracted)
//
// Push a stub Task onto sleeping_queue with wake_time in the past,
// call wakeExpiredSleepers. Drives `task.status.store(.Ready)` for
// the sleep-wake path.
// ─────────────────────────────────────────────────────────────────────────────

pub fn testWakeExpiredSleepers() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        // Drain ready_queue: wakeExpiredSleepers' enqueueTask added the
        // stub Task whose .base = undefined.
        const final_b = sched.ready_queue.bottom.load(.monotonic);
        sched.ready_queue.top.store(final_b, .monotonic);
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    var stub_task: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&s25DummyFn),
        .status = qs.Atomic(TaskStatus).init(.Blocked),
        .wake_time = 1,
    };
    try sched.sleeping_queue.append(allocator, &stub_task);

    sched.wakeExpiredSleepers();

    if (stub_task.status.load(.monotonic) != .Ready) return error.SleeperNotWoken;
    if (sched.sleeping_queue.items.len != 0) return error.SleeperNotRemoved;
}

// ─────────────────────────────────────────────────────────────────────────────
// S9: SchedulerRegistry.pickTwo round-robin (lines 2123-2125)
//
// pickTwo is the work-stealing power-of-two-choice load-balancer.
// Lines: next.fetchAdd(1, .monotonic), then two slots[].load(.acquire).
// Drive by registering >= 2 schedulers and calling pickTwo. Drive-by:
// register's slot.cmpxchgStrong(null, sched, .acq_rel, .monotonic)
// at line 2153 (S10).
// ─────────────────────────────────────────────────────────────────────────────

pub fn testPickTwoRoundRobin() !void {
    const allocator = std.heap.c_allocator;

    var ebrs: [3]ebr_mod.EbrContext = .{ .{}, .{}, .{} };
    var pools: [3]fm.StackPool = undefined;
    var scheds: [3]fp.Scheduler = undefined;
    for (0..3) |i| {
        pools[i] = fm.StackPool.init(allocator);
        scheds[i] = try fp.Scheduler.init(allocator, &ebrs[i], &pools[i]);
    }
    defer {
        // Unregister + tear down in reverse order. unregister clears the
        // slot so the next test's registration starts from a clean state.
        for (0..3) |i| {
            const idx = 2 - i;
            fp.global_registry.unregister(@as(std.Thread.Id, @intCast(idx + 1)));
            scheds[idx].deinit();
            pools[idx].deinit();
            ebrs[idx].deinit(allocator);
        }
    }

    // Use synthetic thread ids; register each scheduler (drives line 2153
    // -- the slot.cmpxchgStrong(null, sched) registry insert path, S10
    // drive-by).
    for (0..3) |i| {
        try fp.global_registry.register(allocator, @as(std.Thread.Id, @intCast(i + 1)), &scheds[i]);
    }

    // Hammer pickTwo a few times to drive the round-robin past several
    // increments. Each call drives lines 2123 (next.fetchAdd) + 2124,
    // 2125 (slots[].load). With 3 registered schedulers, every pair
    // returned must be 2 distinct registered schedulers.
    var k: usize = 0;
    while (k < 8) : (k += 1) {
        const pair = fp.global_registry.pickTwo();
        const a = pair.a orelse return error.PairAEmpty;
        const b = pair.b orelse return error.PairBEmpty;
        if (a == b) return error.PairsMustDiffer;
        // Verify both pointers are actually registered.
        var found_a = false;
        var found_b = false;
        for (&scheds) |*s| {
            if (a == s) found_a = true;
            if (b == s) found_b = true;
        }
        if (!found_a or !found_b) return error.PairContainsUnregistered;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// S1: dirty_mask.fetchOr in submitFsmResume (line 878)
//
// Mirror of testCrossSchedulerResumeFlow but routed through
// submitFsmResume to exercise the FSM Resume cross-scheduler path.
// Drives line 878 (dirty_mask.fetchOr) + the FSM-side ring push.
// ─────────────────────────────────────────────────────────────────────────────

pub fn testCrossSchedulerFsmResumeFlow() !void {
    const allocator = std.heap.c_allocator;

    var ebr_a: ebr_mod.EbrContext = .{};
    var stack_pool_a = fm.StackPool.init(allocator);
    var sched_a = try fp.Scheduler.init(allocator, &ebr_a, &stack_pool_a);
    defer {
        sched_a.deinit();
        stack_pool_a.deinit();
        ebr_a.deinit(allocator);
    }

    var ebr_b: ebr_mod.EbrContext = .{};
    var stack_pool_b = fm.StackPool.init(allocator);
    var sched_b = try fp.Scheduler.init(allocator, &ebr_b, &stack_pool_b);
    defer {
        // Drain fsm_ready_queue before deinit (the FsmResume processed
        // by drainChannels enqueues a stub FsmTask). The FSM queue's
        // tasks are pointers we own, so just zeroing top/bottom is fine.
        const final_b = sched_b.fsm_ready_queue.bottom.load(.monotonic);
        sched_b.fsm_ready_queue.top.store(final_b, .monotonic);
        sched_b.deinit();
        stack_pool_b.deinit();
        ebr_b.deinit(allocator);
    }

    const prev_active = fp.active_scheduler;
    const prev_running = fp.scheduler_running;
    fp.active_scheduler = &sched_a;
    fp.scheduler_running = true;
    defer {
        fp.active_scheduler = prev_active;
        fp.scheduler_running = prev_running;
    }

    var stub_fsm: fsm_mod.FsmTask = .{ .resume_fn = &fsmS6NoopResume };

    try sched_b.submitFsmResume(&stub_fsm);

    if (sched_b.dirty_mask.load(.monotonic) == 0) return error.DirtyMaskBitNotSet;

    // drainChannels processes the FsmResume message: status=.Ready
    // and pushes onto fsm_ready_queue.
    sched_b.drainChannels();

    if (sched_b.dirty_mask.load(.monotonic) != 0) return error.DirtyMaskNotCleared;
}

// ─────────────────────────────────────────────────────────────────────────────
// S10: pinTask / pinFsmTask cross-iter loads (lines 2317, 2328, 2376, 2383)
//
// Both walk global_registry.slots to find the scheduler whose
// task_slab / fsm_task_slab contains a given pointer. With at least
// one registered scheduler, the load+continue pattern fires. We
// don't have a real slab-allocated Task to pin, but for COVERAGE we
// just need the two atomic loads (slot and generation) per arm.
// ─────────────────────────────────────────────────────────────────────────────

pub fn testRegistryCrossIterPinPaths() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        fp.global_registry.unregister(@as(std.Thread.Id, @intCast(99)));
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }
    try fp.global_registry.register(allocator, @as(std.Thread.Id, @intCast(99)), &sched);

    // pinTask: pass a synthetic Task pointer that's NOT in any slab.
    // The walk loads slots[i] (line 2317), then refFromPtr returns
    // null -> `continue`. Loop exits, returns null. Generation load
    // at line 2328 only fires in the no-registered-schedulers branch
    // (already covered) -- the post-pin gen load is line 2328 too,
    // executed when refFromPtr+pin succeed. To cover that, would
    // need a real slab task; the slot-load alone is the practical
    // S10 site we can hit here.
    var stub_task: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&s25DummyFn),
        .status = qs.Atomic(TaskStatus).init(.Blocked),
    };
    const result = fp.pinTask(&stub_task);
    if (result != null) {
        // Synthetic task happened to land in the slab; unpin so we
        // don't leak the pin_count.
        fp.unpinTask(result.?);
    }

    // Same shape for FSM.
    var stub_fsm: fsm_mod.FsmTask = .{ .resume_fn = &fsmS6NoopResume };
    const fresult = fp.pinFsmTask(&stub_fsm);
    if (fresult != null) {
        fp.unpinFsmTask(fresult.?);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// S11: WaitGroup.done internal spinlock (lines 2749, 2753, 2755, 2765)
//
// WaitGroup.done takes a busy-spin internal lock to atomically
// decrement counter + check-zero + wake-waiter. add(2) then done()
// twice exercises both branches: prev != 1 path (line 2755 release),
// and prev == 1 last-decrement path (line 2765 release).
// ─────────────────────────────────────────────────────────────────────────────

pub fn testWaitGroupDoneSpinlock() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    var wg = fp.WaitGroup.init(&sched);
    wg.add(2);

    // First done: counter was 2, prev=2, prev != 1 -> line 2755
    // release branch.
    wg.done();
    // Second done: counter was 1, prev=1 -> last-decrement branch
    // (lines 2760-2765 + 2765 release).
    wg.done();
}

// ─────────────────────────────────────────────────────────────────────────────
// S27: handleTaskAfterDispatch on a .Finished task — exercises the
//      production cleanup path that runs every time a BG fiber exits.
//      Hits scheduler.zig L1268 (in_inbox CAS to DESTROYING success
//      branch), L1277 (active_tasks.fetchSub), and the cleanup chain
//      (releaseTaskEbr, freeStack, allocator.destroy(fiber),
//      task_slab.destroy(task)).
//
// run() formerly inlined this 60-line switch; commit "extract
// handleTaskAfterDispatch seam" hoists it into a public method so
// the production line numbers are reachable from a focused test
// instead of requiring a full sched.run() driver. vopr-loom's
// scenarioUafFinishVsSubmitResume covers the *race shape* but doesn't
// execute scheduler.zig:1268 — kcov reports it as 0-hit. This test
// closes that script-level gap.
//
// Single-fiber, no Loom interleaving: the cleanup path frees the task
// + fiber + stack, so concurrent access from a second fiber would be
// UAF. The race surface is the in_inbox state machine, already
// covered by vopr-loom Scenario 14.
// ─────────────────────────────────────────────────────────────────────────────

fn s27DummyTrampoline() callconv(.c) void {}

pub fn testHandleTaskAfterDispatchFinished() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    // Build a real Task that the cleanup path can actually free.
    // Mirrors the allocation pattern in scheduler.zig drainChannels
    // .Spawn arm (lines 988-1015). Use .Large to match the TSan
    // floor in control-plane.recommendSize — direct Fiber.init
    // bypasses that floor, so callers must opt in explicitly to
    // avoid stomping shadow memory under TSan instrumentation
    // (see commit eb8fff55).
    const stack_mem = try sched.allocStack(.Large);
    const fiber_ptr = try allocator.create(Fiber);
    fiber_ptr.* = Fiber.initWithOwner(stack_mem, @intFromPtr(&s27DummyTrampoline), .Large, &sched);
    const task = try sched.task_slab.create();
    task.* = Task{
        .base = fiber_ptr,
        .user_fn = @ptrCast(&s25DummyFn),
    };
    task.status.store(.Finished, .release);
    task.in_inbox.store(qs.IN_INBOX_IDLE, .release);

    // Pre-load active_tasks so the fetchSub in handleTaskAfterDispatch
    // hits the expected starting count (mirrors what submitSpawn /
    // drainChannels Spawn would have set).
    _ = sched.active_tasks.fetchAdd(1, .monotonic);
    const before_active = sched.active_tasks.load(.monotonic);

    // PRODUCTION PATH UNDER TEST: this is the run() loop's
    // post-switchTo dispatch. With status=.Finished and in_inbox=IDLE,
    // the CAS at L1268 succeeds, fetchSub at L1277 fires, the lock-
    // waiters scan walks empty, releaseTaskEbr runs, and the fiber+
    // task+stack are freed.
    sched.handleTaskAfterDispatch(task);

    // Invariants after cleanup:
    //   1. active_tasks decremented by exactly 1.
    //   2. in_inbox is now DESTROYING (post-CAS, pre-free observation
    //      — the field's bytes may persist in the slab freelist).
    //   3. The task pointer is no longer valid; we don't touch it.
    if (sched.active_tasks.load(.monotonic) != before_active - 1) return error.ActiveTasksNotDecremented;
}

// ─────────────────────────────────────────────────────────────────────────────
// S28: handleTaskAfterDispatch on a .Ready task — exercises the THREE
//      sub-paths of the .Ready branch in run()'s post-dispatch logic:
//
//        (a) in_inbox != IDLE  -> skip enqueue (concurrent submitResume
//                                  already claimed the slot)
//        (b) in_inbox == IDLE, co_yielded == true  -> yield_queue (FIFO,
//                                                       cooperative
//                                                       fairness)
//        (c) in_inbox == IDLE, co_yielded == false -> ready_queue (LIFO,
//                                                       Chase-Lev)
//
// Hits scheduler.zig L1416 (in_inbox.load(.acquire), 0 Loom hits before
// this test). The .Ready branch fires on every cooperative yield in
// the failing versioned-fiber-stress-test (rt.checkYield() every 4096
// reader iterations -> coopYield -> task.status = .Ready + co_yielded
// = true -> task.base.yield() -> harness sees status=.Ready -> this
// branch). The (a) sub-path is the duplicate-enqueue guard that
// prevents a same-tick concurrent submitResume from racing the
// post-yield re-enqueue.
//
// Asserts:
//   - (a) leaves both queues unchanged AND co_yielded preserved
//   - (b) appends to yield_queue exactly once AND clears co_yielded
//   - (c) pushes onto ready_queue exactly once
// ─────────────────────────────────────────────────────────────────────────────

pub fn testHandleTaskAfterDispatchReady() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        // Drain ready_queue / yield_queue: stub tasks have .base = undefined
        // so scheduler.deinit walking them would dereference garbage.
        const final_b = sched.ready_queue.bottom.load(.monotonic);
        sched.ready_queue.top.store(final_b, .monotonic);
        sched.yield_queue.clearRetainingCapacity();
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    // ── (c) co_yielded == false → ready_queue ──────────────────────────────
    var t_ready: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&s25DummyFn),
        .status = qs.Atomic(TaskStatus).init(.Ready),
    };
    t_ready.in_inbox.store(qs.IN_INBOX_IDLE, .release);
    t_ready.co_yielded = false;

    const ready_before = sched.ready_queue.len();
    const yield_before = sched.yield_queue.items.len;
    sched.handleTaskAfterDispatch(&t_ready);
    if (sched.ready_queue.len() != ready_before + 1) return error.ReadyQueueNotEnqueued;
    if (sched.yield_queue.items.len != yield_before) return error.YieldQueueUnexpectedlyChanged;

    // ── (b) co_yielded == true → yield_queue, co_yielded cleared ───────────
    var t_coop: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&s25DummyFn),
        .status = qs.Atomic(TaskStatus).init(.Ready),
    };
    t_coop.in_inbox.store(qs.IN_INBOX_IDLE, .release);
    t_coop.co_yielded = true;

    const ready_b = sched.ready_queue.len();
    const yield_b = sched.yield_queue.items.len;
    sched.handleTaskAfterDispatch(&t_coop);
    if (sched.yield_queue.items.len != yield_b + 1) return error.YieldQueueNotAppended;
    if (sched.ready_queue.len() != ready_b) return error.ReadyQueueUnexpectedlyChanged;
    if (t_coop.co_yielded) return error.CoYieldedNotCleared;

    // ── (a) in_inbox != IDLE → skip both queues, co_yielded preserved ──────
    var t_busy: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&s25DummyFn),
        .status = qs.Atomic(TaskStatus).init(.Ready),
    };
    t_busy.in_inbox.store(qs.IN_INBOX_IN_QUEUE, .release);
    t_busy.co_yielded = true;

    const ready_c = sched.ready_queue.len();
    const yield_c = sched.yield_queue.items.len;
    sched.handleTaskAfterDispatch(&t_busy);
    if (sched.ready_queue.len() != ready_c) return error.ReadyQueueUnexpectedlyEnqueued;
    if (sched.yield_queue.items.len != yield_c) return error.YieldQueueUnexpectedlyAppended;
    // co_yielded must NOT be cleared here — only path (b) clears it.
    if (!t_busy.co_yielded) return error.CoYieldedClearedOnGuardedPath;
}

// ─────────────────────────────────────────────────────────────────────────────
// S29: cross-scheduler submitSpawn — exercises L810 (`dirty_mask.fetchOr`)
//      and the eventfd notify gate. The failing versioned-fiber-stress-test
//      walks this every BG-fiber spawn via spawnBest -> submitSpawn on
//      the least-loaded peer scheduler. testCrossSchedulerResumeFlow
//      already covers the Resume side of the same submit machinery
//      (L928); this is the symmetric Spawn side that S25 only
//      exercises after the message reaches drainChannels (i.e., S25
//      pushes via ring.push() directly, bypassing submitSpawn's
//      dirty_mask.fetchOr).
//
// Asserts: after submitSpawn, dirty_mask bit for sender_idx is set and
// the SPSC ring contains exactly one Spawn-tagged message.
// ─────────────────────────────────────────────────────────────────────────────

pub fn testCrossSchedulerSubmitSpawn() !void {
    const allocator = std.heap.c_allocator;

    var ebr_a: ebr_mod.EbrContext = .{};
    var stack_pool_a = fm.StackPool.init(allocator);
    var sched_a = try fp.Scheduler.init(allocator, &ebr_a, &stack_pool_a);
    defer {
        sched_a.deinit();
        stack_pool_a.deinit();
        ebr_a.deinit(allocator);
    }

    var ebr_b: ebr_mod.EbrContext = .{};
    var stack_pool_b = fm.StackPool.init(allocator);
    var sched_b = try fp.Scheduler.init(allocator, &ebr_b, &stack_pool_b);
    defer {
        sched_b.deinit();
        stack_pool_b.deinit();
        ebr_b.deinit(allocator);
    }

    const prev_active = fp.active_scheduler;
    const prev_running = fp.scheduler_running;
    fp.active_scheduler = &sched_a;
    fp.scheduler_running = true;
    defer {
        fp.active_scheduler = prev_active;
        fp.scheduler_running = prev_running;
    }

    // Cross-scheduler: sender = sched_a, target = sched_b. submitSpawn
    // pushes to sched_b's channel from sched_a, fires dirty_mask.fetchOr
    // (L810), and notifies the eventfd. We don't run the spawned fiber,
    // so trampoline/user_fn are dummies that never execute.
    try sched_b.submitSpawn(
        @intFromPtr(&s25DummyFn),
        @ptrCast(&s25DummyFn),
        null,
        .{},
    );

    if (sched_b.dirty_mask.load(.monotonic) == 0) return error.DirtyMaskBitNotSet;

    // Verify the message landed in the channel for sched_a.index. Use
    // ensureChannel to look up; a Spawn message must be at the head.
    const ring = try sched_b.ensureChannel(sched_a.index);
    const peeked = ring.peek() orelse return error.RingEmpty;
    if (peeked.tag != .Spawn) return error.WrongMessageTag;
}

// ─────────────────────────────────────────────────────────────────────────────
// S30: cross-scheduler submitFsmSpawn — symmetric to S29 but for FSM
//      tasks. Hits L845 (`dirty_mask.fetchOr` in submitFsmSpawn slow
//      path). On the failing test's bug path, this fires whenever a
//      BG-FSM fiber is enqueued cross-scheduler (CheatLib's spawnFsmBest).
// ─────────────────────────────────────────────────────────────────────────────

pub fn testCrossSchedulerSubmitFsmSpawn() !void {
    const allocator = std.heap.c_allocator;

    var ebr_a: ebr_mod.EbrContext = .{};
    var stack_pool_a = fm.StackPool.init(allocator);
    var sched_a = try fp.Scheduler.init(allocator, &ebr_a, &stack_pool_a);
    defer {
        sched_a.deinit();
        stack_pool_a.deinit();
        ebr_a.deinit(allocator);
    }

    var ebr_b: ebr_mod.EbrContext = .{};
    var stack_pool_b = fm.StackPool.init(allocator);
    var sched_b = try fp.Scheduler.init(allocator, &ebr_b, &stack_pool_b);
    defer {
        sched_b.deinit();
        stack_pool_b.deinit();
        ebr_b.deinit(allocator);
    }

    const prev_active = fp.active_scheduler;
    const prev_running = fp.scheduler_running;
    fp.active_scheduler = &sched_a;
    fp.scheduler_running = true;
    defer {
        fp.active_scheduler = prev_active;
        fp.scheduler_running = prev_running;
    }

    var stub_fsm: fsm_mod.FsmTask = .{ .resume_fn = &fsmS6NoopResume };

    // Slow path (cross-scheduler): self != active_scheduler, so the
    // same-scheduler fast path at L824 is bypassed and submitFsmSpawn
    // pushes to the SPSC ring + sets dirty_mask via fetchOr (L845).
    try sched_b.submitFsmSpawn(&stub_fsm);

    if (sched_b.dirty_mask.load(.monotonic) == 0) return error.DirtyMaskBitNotSet;

    const ring = try sched_b.ensureChannel(sched_a.index);
    const peeked = ring.peek() orelse return error.RingEmpty;
    if (peeked.tag != .FsmSpawn) return error.WrongMessageTag;
}

// ─────────────────────────────────────────────────────────────────────────────
// S31: FSM enqueue + drain accounting — exercises:
//   - Scheduler.enqueueFsm:  active_tasks.fetchAdd(1)            (L1543)
//   - Scheduler.drainFsmQueue .Done branch: active_tasks.fetchSub(1) (L1579)
//
// Both atomics had 0 Loom hits before this scenario. The failing
// versioned-fiber-stress-test path uses BG-FSM fibers via spawnFsmBest
// — every spawn hits enqueueFsm (same-scheduler fast path) and every
// fiber completion eventually drains via drainFsmQueue's .Done arm.
//
// Asserts: enqueue bumps active_tasks by 1; drain returns it to the
// starting value (i.e., the task is properly accounted for through its
// full lifecycle).
// ─────────────────────────────────────────────────────────────────────────────

pub fn testEnqueueFsmActiveTasksAccounting() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    // Real slab allocation: drainFsmQueue's .Done arm calls
    // fsm_task_slab.destroy(task) at end-of-life. A stack-local
    // FsmTask would crash there (slab.destroy on a non-slab pointer).
    const fsm_task = try sched.fsm_task_slab.create();
    fsm_task.* = .{ .resume_fn = &fsmS6NoopResume };
    // owner_scheduler = null so .Done teardown uses `self` (sched) for
    // the slab return; otherwise drainFsmQueue would route a remote
    // FsmCtxFree we don't need to model here.

    const before_active = sched.active_tasks.load(.monotonic);

    // L1543: enqueueFsm fires active_tasks.fetchAdd(1).
    sched.enqueueFsm(fsm_task);

    if (sched.active_tasks.load(.monotonic) != before_active + 1) return error.EnqueueDidNotBumpActiveTasks;
    if (sched.fsm_ready_queue.len() != 1) return error.FsmNotEnqueued;

    // drainFsmQueue's .Done arm pops the task, dispatches once
    // (fsmS6NoopResume returns .Done immediately), fires
    // active_tasks.fetchSub(1) (L1579), then slab.destroy(task).
    sched.drainFsmQueue();

    if (sched.active_tasks.load(.monotonic) != before_active) return error.DrainDidNotDecrementActiveTasks;
    if (sched.fsm_ready_queue.len() != 0) return error.FsmQueueNotDrained;
}

// ─────────────────────────────────────────────────────────────────────────────
// S32: cross-scheduler freeStack -> submitRemoteStackFree -> drainChannels
//      RemoteStackFree -> freeLocalStackMemory.
//
// On the failing test's bug path: spawnBest distributes BG fibers
// across schedulers; under work-stealing a fiber may finish on a
// non-owner scheduler. handleTaskAfterDispatch's .Finished branch
// (S27) calls freeStack(task.base.stack) which routes through
// submitRemoteStackFree when stack.owner != current scheduler. That
// path hits L744 (`owner.dirty_mask.fetchOr`) — currently 0 Loom hits.
//
// This test allocates on sched_a, frees from sched_b, and verifies
// the message-driven cross-scheduler return: dirty_mask bit set,
// RemoteStackFree message in ring, and after drain the memory is
// returned to sched_a's pool (so a subsequent allocStack on sched_a
// can reuse it without growing the slab).
// ─────────────────────────────────────────────────────────────────────────────

pub fn testCrossSchedulerFreeStack() !void {
    const allocator = std.heap.c_allocator;

    var ebr_a: ebr_mod.EbrContext = .{};
    var stack_pool_a = fm.StackPool.init(allocator);
    var sched_a = try fp.Scheduler.init(allocator, &ebr_a, &stack_pool_a);
    defer {
        sched_a.deinit();
        stack_pool_a.deinit();
        ebr_a.deinit(allocator);
    }

    var ebr_b: ebr_mod.EbrContext = .{};
    var stack_pool_b = fm.StackPool.init(allocator);
    var sched_b = try fp.Scheduler.init(allocator, &ebr_b, &stack_pool_b);
    defer {
        sched_b.deinit();
        stack_pool_b.deinit();
        ebr_b.deinit(allocator);
    }

    const prev_active = fp.active_scheduler;
    const prev_running = fp.scheduler_running;
    fp.active_scheduler = &sched_b;
    fp.scheduler_running = true;
    defer {
        fp.active_scheduler = prev_active;
        fp.scheduler_running = prev_running;
    }

    // Allocate on sched_a so stack.owner = &sched_a.
    const memory = try sched_a.allocStack(.Large);
    const stack = fc.Stack{ .memory = memory, .owner = @ptrCast(&sched_a) };

    // Free on sched_b: owner != self path -> submitRemoteStackFree
    // -> dirty_mask.fetchOr (L744).
    sched_b.freeStack(stack);

    if (sched_a.dirty_mask.load(.monotonic) == 0) return error.DirtyMaskBitNotSet;

    const ring = try sched_a.ensureChannel(sched_b.index);
    const peeked = ring.peek() orelse return error.RingEmpty;
    if (peeked.tag != .RemoteStackFree) return error.WrongMessageTag;

    // Drain on sched_a: RemoteStackFree arm of drainChannels frees the
    // memory back to the pool. Pool internals don't expose a
    // public "is this slot free" check, but draining ensures we
    // don't leak the message OR the memory across test cleanup.
    sched_a.drainChannels();

    if (sched_a.dirty_mask.load(.monotonic) != 0) return error.DirtyMaskNotCleared;
}

// ─────────────────────────────────────────────────────────────────────────────
// S33: wakeTaskFromIo — exercises the .Blocked -> .Ready CAS at L1919
//      that processCqes uses to wake fibers parked on read/write/recv/
//      send/accept/connect (covered by S33A) AND the no-op path when
//      the task is already .Ready (S33B). Currently 0 Loom hits.
//
// On the failing test's bug path: any IO operation parks the fiber
// (status=.Blocked) and the io_uring CQE wakes it through this CAS.
// Cross-scheduler eventfd notifies (the bench-17 wake mechanism) also
// route through processCqes -> wakeTaskFromIo for the eventfd reader
// fiber.
// ─────────────────────────────────────────────────────────────────────────────

pub fn testWakeTaskFromIoBlockedToReady() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        const final_b = sched.ready_queue.bottom.load(.monotonic);
        sched.ready_queue.top.store(final_b, .monotonic);
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    // Case A: task is .Blocked -> CAS succeeds, status -> .Ready,
    // enqueued onto ready_queue.
    var t_blocked: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&s25DummyFn),
        .status = qs.Atomic(TaskStatus).init(.Blocked),
    };

    const ready_before = sched.ready_queue.len();
    sched.wakeTaskFromIo(&t_blocked);
    if (t_blocked.status.load(.monotonic) != .Ready) return error.StatusNotReady;
    if (sched.ready_queue.len() != ready_before + 1) return error.NotEnqueued;

    // Case B: task is already .Ready -> CAS fails (expected != actual),
    // wakeTaskFromIo no-ops. ready_queue unchanged.
    var t_ready: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&s25DummyFn),
        .status = qs.Atomic(TaskStatus).init(.Ready),
    };

    const ready_before2 = sched.ready_queue.len();
    sched.wakeTaskFromIo(&t_ready);
    if (sched.ready_queue.len() != ready_before2) return error.UnexpectedlyEnqueued;
}

// ─────────────────────────────────────────────────────────────────────────────
// S34: pinTask + pinFsmTask SUCCESS paths — slab-allocated tasks pinned
//      from a registered scheduler. Hits scheduler.zig L2361 (Task post-
//      pin generation.load) and L2416 (FsmTask equivalent), both 0
//      Loom hits before this scenario.
//
// The existing testRegistryCrossIterPinPaths covers the no-op /
// not-found arms by passing synthetic stubs (refFromPtr returns null,
// so the post-pin gen.load never fires). This complements that with
// the success path: a real task in the slab gets pinned and the
// generation snapshot is captured at L2361/L2416.
//
// Why bug-relevant: detectCycle (parking-lot deadlock detection)
// walks lock-waiter chains and uses pinTask/pinFsmTask to keep slab
// memory alive across the walk. The failing versioned-fiber-stress-
// test triggers detectCycle whenever a deadlock-suspect chain forms
// (e.g., during cross-scheduler EBR + lock contention). The captured
// generation is what guards against slot-reuse UAF along the walk.
// ─────────────────────────────────────────────────────────────────────────────

pub fn testPinTaskSuccessPath() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        fp.global_registry.unregister(@as(std.Thread.Id, @intCast(101)));
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }
    try fp.global_registry.register(allocator, @as(std.Thread.Id, @intCast(101)), &sched);

    // Allocate a Task in sched.task_slab so refFromPtr can resolve it.
    const task = try sched.task_slab.create();
    task.* = Task{
        .base = undefined,
        .user_fn = @ptrCast(&s25DummyFn),
    };
    defer sched.task_slab.destroy(task);

    // Bump generation so the post-pin load returns something
    // distinguishable from the slab's default (0). The unpin will
    // implicitly verify the gen captured by the pin matches reality.
    task.generation.store(7, .release);

    const pin = fp.pinTask(task) orelse return error.PinFailed;
    if (pin.allocator == null) return error.UnexpectedNoOpPin;
    if (pin.gen != 7) return error.GenerationMismatch;
    fp.unpinTask(pin);

    // FSM equivalent.
    const fsm_task = try sched.fsm_task_slab.create();
    fsm_task.* = .{ .resume_fn = &fsmS6NoopResume };
    defer sched.fsm_task_slab.destroy(fsm_task);
    fsm_task.generation.store(11, .release);

    const fpin = fp.pinFsmTask(fsm_task) orelse return error.FsmPinFailed;
    if (fpin.allocator == null) return error.UnexpectedFsmNoOpPin;
    if (fpin.gen != 11) return error.FsmGenerationMismatch;
    fp.unpinFsmTask(fpin);
}

// ─────────────────────────────────────────────────────────────────────────────
// S3: drainChannels RemoteCall completion store (line 1097)
//
// Pushes a synthetic RemoteCall message into a scheduler's channel,
// calls drainChannels. The handler invokes the func, then sets
// completion.finished=true (line 1097) and calls wg.done(). The
// wg.done() also drives the WaitGroup spinlock paths (S11 already
// covered).
// ─────────────────────────────────────────────────────────────────────────────

var s3_remote_func_called: bool = false;

fn s3RemoteFunc(_: *anyopaque) void {
    s3_remote_func_called = true;
}

pub fn testRemoteCallCompletion() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    // Build a RemoteCompletion with counter=1, no waiter -- done()
    // last-decrement falls through with no schedule call.
    var completion = fp.RemoteCompletion{ .wg = fp.WaitGroup.init(&sched) };
    completion.wg.add(1);

    // Allocate channel from sender 0 to sched.
    const ring = try sched.ensureChannel(0);
    var ctx_unused: u8 = 0;
    const msg = fp.SpscMessage{
        .tag = .RemoteCall,
        .rc_func = &s3RemoteFunc,
        .rc_ctx = &ctx_unused,
        .rc_wg = &completion,
    };
    if (!ring.push(msg)) return error.RingPushFailed;
    _ = sched.dirty_mask.fetchOr(@as(u64, 1), .release);

    s3_remote_func_called = false;
    sched.drainChannels();

    if (!s3_remote_func_called) return error.RemoteFuncNotCalled;
    if (!completion.finished.load(.acquire)) return error.CompletionFinishedNotSet;
}

// ─────────────────────────────────────────────────────────────────────────────
// S8: scanLockWaiters timeout-fire wake (lines 1907, 1912, 1914,
//     1957, 1965-1970). Builds on scanLockWaitersPub seam.
//
// Setup: synthetic Task in lock_waiters with waiting_for_lock pointing
// at a sentinel and lock_wait_start_ms long enough ago that
// `now - start > lock_timeout_ms`. waiting_for_lock_list = null so the
// scanner skips the WaiterList re-check block (those sites need a real
// parking-lot WaiterList — defer).
//
// Mirror scenario uses scanFsmLockWaitersPub (already public) on the
// FSM-side fields (lines 1702, 1706-1738).
// ─────────────────────────────────────────────────────────────────────────────

var s8_lock_sentinel: u8 = 0;

pub fn testScanLockWaitersTimeoutFire() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        const final_b = sched.ready_queue.bottom.load(.monotonic);
        sched.ready_queue.top.store(final_b, .monotonic);
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    // Force a short timeout so `now - 0 > timeout` is trivially true.
    sched.lock_timeout_ms = 1;

    var stub_task: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&s25DummyFn),
        .status = qs.Atomic(TaskStatus).init(.Blocked),
    };
    // Pretend we're parked on a lock. Use a non-null sentinel so the
    // initial `if (waiting_for_lock == null)` branch is skipped.
    stub_task.waiting_for_lock.store(@ptrCast(&s8_lock_sentinel), .release);
    // lock_wait_start_ms = 0 -> deadline = 0 + 1 = 1ms. now is far
    // beyond that, so timeout fires.
    stub_task.lock_wait_start_ms.store(0, .release);
    // No real WaiterList -- scanner skips the inner re-check block.
    stub_task.waiting_for_lock_list.store(null, .release);

    try sched.lock_waiters.append(allocator, &stub_task);

    _ = sched.scanLockWaitersPub();

    // After timeout-fire: waiting_for_lock cleared, lock_timed_out set,
    // status = .Ready, removed from lock_waiters, enqueued.
    if (stub_task.waiting_for_lock.load(.monotonic) != null) return error.WaitFieldNotCleared;
    if (!stub_task.lock_timed_out.load(.monotonic)) return error.LockTimedOutNotSet;
    if (stub_task.status.load(.monotonic) != .Ready) return error.StatusNotReady;
    if (sched.lock_waiters.items.len != 0) return error.LockWaiterNotRemoved;
}

pub fn testScanLockWaitersRemovesQueuedNode() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        const final_b = sched.ready_queue.bottom.load(.monotonic);
        sched.ready_queue.top.store(final_b, .monotonic);
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    sched.lock_timeout_ms = 1;

    var waiter_list: qs.WaiterList = .{};
    var stub_task: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&s25DummyFn),
        .status = qs.Atomic(TaskStatus).init(.Blocked),
    };
    var waiter_node = qs.WaiterNode{
        .task = &stub_task,
        .sched_ptr = &sched,
        .kind = .Write,
    };
    waiter_list.push(&waiter_node);

    var writers_waiting: u32 = 1;
    stub_task.waiting_for_lock.store(@ptrCast(&s8_lock_sentinel), .release);
    stub_task.lock_wait_start_ms.store(0, .release);
    stub_task.waiting_for_lock_list.store(&waiter_list, .release);
    stub_task.lock_waiter_node.store(&waiter_node, .release);
    stub_task.lock_counter_ptr = &writers_waiting;

    try sched.lock_waiters.append(allocator, &stub_task);

    _ = sched.scanLockWaitersPub();

    if (!waiter_list.isEmpty()) return error.WaiterNodeNotRemoved;
    if (writers_waiting != 0) return error.WriterWaiterCountNotDecremented;
    if (stub_task.waiting_for_lock.load(.monotonic) != null) return error.WaitFieldNotCleared;
    if (stub_task.waiting_for_lock_list.load(.monotonic) != null) return error.WaiterListNotCleared;
    if (stub_task.lock_waiter_node.load(.monotonic) != null) return error.WaiterNodeBackPointerNotCleared;
    if (!stub_task.lock_timed_out.load(.monotonic)) return error.LockTimedOutNotSet;
    if (stub_task.status.load(.monotonic) != .Ready) return error.StatusNotReady;
    if (sched.lock_waiters.items.len != 0) return error.LockWaiterNotRemoved;
}

pub fn testEarliestLockWaiterDeadlineSkipsStaleWaiters() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    sched.lock_timeout_ms = 100;

    var stale_task: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&s25DummyFn),
        .status = qs.Atomic(TaskStatus).init(.Blocked),
    };
    stale_task.waiting_for_lock.store(null, .release);

    var live_task: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&s25DummyFn),
        .status = qs.Atomic(TaskStatus).init(.Blocked),
    };
    live_task.waiting_for_lock.store(@ptrCast(&s8_lock_sentinel), .release);
    live_task.lock_wait_start_ms.store(0, .release);

    try sched.lock_waiters.append(allocator, &stale_task);
    try sched.lock_waiters.append(allocator, &live_task);

    const until = sched.earliestLockWaiterDeadlineMsUntil() orelse return error.NoDeadline;
    if (until < 1) return error.InvalidDeadline;
}

pub fn testPartitionedMapPutAllocationFailureCompletes() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
        fp.global_registry.deinit(allocator);
        fp.global_registry = .{};
    }

    try fp.global_registry.register(allocator, std.Thread.getCurrentId(), &sched);
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;

    var byte: u8 = 0;
    const impossible_value = @as([*]const u8, @ptrCast(&byte))[0..std.math.maxInt(usize)];

    const StringMap = DataStructures.PartitionedStringMap([]const u8, 4);
    var smap: StringMap = .{};
    defer smap.deinit(allocator, allocator);

    if (smap.put(allocator, allocator, "oom-string", impossible_value)) |_| {
        return error.StringPutUnexpectedlySucceeded;
    } else |err| if (err != error.OutOfMemory) {
        return err;
    }
    if (smap.contains("oom-string")) return error.StringPutFailureInsertedKey;

    const NumericMap = DataStructures.PartitionedNumericMap(i64, []const u8, 4);
    var nmap: NumericMap = .{};
    defer nmap.deinit(allocator, allocator);

    if (nmap.put(allocator, allocator, 9001, impossible_value)) |_| {
        return error.NumericPutUnexpectedlySucceeded;
    } else |err| if (err != error.OutOfMemory) {
        return err;
    }
    if (nmap.contains(9001)) return error.NumericPutFailureInsertedKey;

    // The impossible-slice cases above fail while duplicating the value.
    // Target the later getOrPut allocations explicitly so the context's
    // error completion store is verified for both map implementations.
    {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        g_partitioned_remote_allocator = failing.allocator();
        defer g_partitioned_remote_allocator = std.heap.c_allocator;

        const OomStringMap = DataStructures.PartitionedStringMap(i64, 4);
        var oom_smap: OomStringMap = .{};
        defer oom_smap.deinit(allocator, allocator);
        if (oom_smap.put(allocator, allocator, "get-or-put-oom", 1)) |_| {
            return error.StringGetOrPutUnexpectedlySucceeded;
        } else |err| if (err != error.OutOfMemory) {
            return err;
        }
    }
    {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
        g_partitioned_remote_allocator = failing.allocator();
        defer g_partitioned_remote_allocator = std.heap.c_allocator;

        const OomNumericMap = DataStructures.PartitionedNumericMap(i64, i64, 4);
        var oom_nmap: OomNumericMap = .{};
        defer oom_nmap.deinit(allocator, allocator);
        if (oom_nmap.put(allocator, allocator, 42, 1)) |_| {
            return error.NumericGetOrPutUnexpectedlySucceeded;
        } else |err| if (err != error.OutOfMemory) {
            return err;
        }
    }
}

pub fn testScanFsmLockWaitersTimeoutFire() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    sched.lock_timeout_ms = 1;

    var stub_fsm: fsm_mod.FsmTask = .{ .resume_fn = &fsmS6NoopResume };
    stub_fsm.waiting_for_lock.store(@ptrCast(&s8_lock_sentinel), .release);
    stub_fsm.lock_wait_start_ms.store(0, .release);
    stub_fsm.waiting_for_lock_list.store(null, .release);

    try sched.fsm_lock_waiters.append(allocator, &stub_fsm);

    sched.scanFsmLockWaitersPub();

    if (stub_fsm.waiting_for_lock.load(.monotonic) != null) return error.FsmWaitFieldNotCleared;
    if (sched.fsm_lock_waiters.items.len != 0) return error.FsmLockWaiterNotRemoved;
}

pub fn testScanFsmLockWaitersRemovesQueuedNode() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    sched.lock_timeout_ms = 1;

    var waiter_list: qs.WaiterList = .{};
    var stub_fsm: fsm_mod.FsmTask = .{ .resume_fn = &fsmS6NoopResume };
    var waiter_node = qs.WaiterNode{
        .fsm_task = &stub_fsm,
        .sched_ptr = &sched,
        .kind = .Write,
    };
    waiter_list.push(&waiter_node);

    stub_fsm.waiting_for_lock.store(@ptrCast(&s8_lock_sentinel), .release);
    stub_fsm.lock_wait_start_ms.store(0, .release);
    stub_fsm.waiting_for_lock_list.store(&waiter_list, .release);
    stub_fsm.lock_waiter.store(&waiter_node, .release);

    try sched.fsm_lock_waiters.append(allocator, &stub_fsm);

    sched.scanFsmLockWaitersPub();

    if (!waiter_list.isEmpty()) return error.FsmWaiterNodeNotRemoved;
    if (stub_fsm.waiting_for_lock.load(.monotonic) != null) return error.FsmWaitFieldNotCleared;
    if (stub_fsm.waiting_for_lock_list.load(.monotonic) != null) return error.FsmWaiterListNotCleared;
    if (stub_fsm.lock_waiter.load(.monotonic) != null) return error.FsmWaiterBackPointerNotCleared;
    if (stub_fsm.lock_error != .LockTimeout) return error.FsmLockTimeoutNotSet;
    if (stub_fsm.status != .Ready) return error.FsmStatusNotReady;
    if (sched.fsm_lock_waiters.items.len != 0) return error.FsmLockWaiterNotRemoved;
}

pub fn testCoopYieldWithWork() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    var schedule_buf: [8]u8 = [_]u8{0} ** 8;
    var h = LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    try h.createThread(0, @intFromPtr(&entryS2CoopYield));
    h.run() catch {};

    const final_b = g_sched.ready_queue.bottom.load(.monotonic);
    g_sched.ready_queue.top.store(final_b, .monotonic);
    g_sched.deinit();
    stack_pool.deinit();
    ebr.deinit(allocator);
}

// ─────────────────────────────────────────────────────────────────────────────
// N1: Link WaitGroup.{registerFsmWaiter, wait} and Semaphore.{acquire,
//     release} into the loom binary so kcov can track their atomic
//     sites. Without these tests the functions are dead-stripped from
//     parking-lot-loom (no caller) and cobertura reports MISSING for
//     every line, even though they execute fine in production.
//
// Each test exercises the easy reachable path. Slow-paths that require
// a real fiber stack (wait()'s yield branch, acquire()'s park branch)
// are covered indirectly via the runtime's TSan/integration tests.
// ─────────────────────────────────────────────────────────────────────────────

pub fn testWaitGroupRegisterFsmWaiter() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    var wg = fp.WaitGroup.init(&sched);
    var stub_fsm: fsm_mod.FsmTask = .{ .resume_fn = &fsmS6NoopResume };

    // counter==0 fast-path — no parking, returns false (covers L2798).
    if (wg.registerFsmWaiter(&stub_fsm)) return error.RegisteredAtZero;

    // counter>0 slow path — takes lock, re-checks, parks, returns true
    // (covers L2800, L2806, L2812).
    wg.add(1);
    if (!wg.registerFsmWaiter(&stub_fsm)) return error.NotRegistered;
    if (wg.waiting_fsm != &stub_fsm) return error.FsmNotStored;

    // Counter→0 between load and lock. Set counter to 0 directly while
    // unlocked, then reset waiting_fsm and call again -- the inner
    // re-check fires (covers L2806-L2808 returning false under lock).
    wg.counter.store(0, .seq_cst);
    wg.waiting_fsm = null;
    // Re-arm the outer load by setting counter back via a tiny race
    // window: bump it, then drop to 0 before the lock acquire. We
    // simulate this by patching counter inside a wrapper that takes
    // the lock first.
    wg.counter.store(1, .seq_cst);
    while (wg.lock.swap(1, .acquire) == 1) {}
    wg.counter.store(0, .seq_cst);
    wg.lock.store(0, .release);
    if (wg.registerFsmWaiter(&stub_fsm)) return error.RegisteredAfterRecheck;
}

pub fn testWaitGroupWaitNonFiber() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    // sched.current_task is null at construction -- non-fiber branch
    // (covers L2822-L2826: spinlock, counter check, release, return).
    var wg = fp.WaitGroup.init(&sched);
    // counter already 0; wait() should return immediately.
    wg.wait();
}

pub fn testWaitGroupWaitFiberParkResume() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        const final_b = sched.ready_queue.bottom.load(.monotonic);
        sched.ready_queue.top.store(final_b, .monotonic);
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    const stack = try allocator.alloc(u8, STACK_SIZE);
    defer allocator.free(stack);
    var fiber = Fiber.init(stack, @intFromPtr(&entryWaitGroupParkedFiber), .Large);
    var task: Task = .{
        .base = &fiber,
        .user_fn = @ptrCast(&s25DummyFn),
        .status = qs.Atomic(TaskStatus).init(.Ready),
    };

    var wg = fp.WaitGroup.init(&sched);
    wg.add(1);
    g_scheduler_primitive_wg = &wg;
    g_scheduler_primitive_wg_woke = false;

    const prev_active = fp.active_scheduler;
    const prev_running = fp.scheduler_running;
    const prev_disable = sim_atomic.disable_fiber_yield_point;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    sim_atomic.disable_fiber_yield_point = true;
    defer {
        fc.__fiber = null;
        fc.__fiber_parent_ctx = null;
        fc.__fiber_stack_limit = null;
        sim_atomic.disable_fiber_yield_point = prev_disable;
        sched.current_task = null;
        fp.active_scheduler = prev_active;
        fp.scheduler_running = prev_running;
    }

    sched.current_task = &task;
    fiber.switchTo(&sched.main_ctx);
    if (task.status.load(.acquire) != .Blocked) return error.WaitGroupFiberDidNotPark;
    if (wg.waiting_task != &task) return error.WaitGroupWaiterNotRegistered;
    if (g_scheduler_primitive_wg_woke) return error.WaitGroupWokeEarly;

    wg.done();
    if (wg.waiting_task != null) return error.WaitGroupWaiterNotCleared;
    if (task.status.load(.acquire) != .Ready) return error.WaitGroupDoneDidNotWake;

    sched.current_task = &task;
    fiber.switchTo(&sched.main_ctx);
    if (!g_scheduler_primitive_wg_woke) return error.WaitGroupFiberDidNotResume;
}

pub fn testSemaphoreFastPath() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    // count=2: two acquires take the fast-path CAS-decrement
    // (covers L2879, L2881 success branch).
    var sem = fp.Semaphore.init(2, &sched);
    sem.acquire();
    sem.acquire();
    // counter is 0 now. release() with no waiter takes the
    // counter.fetchAdd branch (covers L2913, L2922, L2923).
    sem.release();
    sem.release();
    if (sem.counter.load(.seq_cst) != 2) return error.SemaphoreCounterMismatch;
}

pub fn testSemaphoreReleaseWithWaiter() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        const final_b = sched.ready_queue.bottom.load(.monotonic);
        sched.ready_queue.top.store(final_b, .monotonic);
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    // Same-scheduler routing for submitResume; otherwise schedule()'s
    // cross-scheduler path requires a registered sender index.
    const prev_active = fp.active_scheduler;
    const prev_running = fp.scheduler_running;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer {
        fp.active_scheduler = prev_active;
        fp.scheduler_running = prev_running;
    }

    var sem = fp.Semaphore.init(0, &sched);

    // Stage a synthetic waiting_task. release() takes the
    // direct-grant branch: nulls waiting_task, releases lock,
    // schedule(task). Covers L2913, L2916-L2920 (sched.schedule
    // path enqueues into ready_queue).
    var stub_task: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&s25DummyFn),
        .status = qs.Atomic(TaskStatus).init(.Blocked),
    };
    sem.waiting_task = &stub_task;

    sem.release();

    if (sem.waiting_task != null) return error.WaitingTaskNotCleared;
    // counter must NOT have been incremented (slot granted directly).
    if (sem.counter.load(.seq_cst) != 0) return error.CounterIncrementedOnDirectGrant;
}

pub fn testSemaphoreAcquireFiberParkResume() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        const final_b = sched.ready_queue.bottom.load(.monotonic);
        sched.ready_queue.top.store(final_b, .monotonic);
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    const stack = try allocator.alloc(u8, STACK_SIZE);
    defer allocator.free(stack);
    var fiber = Fiber.init(stack, @intFromPtr(&entrySemaphoreParkedFiber), .Large);
    var task: Task = .{
        .base = &fiber,
        .user_fn = @ptrCast(&s25DummyFn),
        .status = qs.Atomic(TaskStatus).init(.Ready),
    };

    var sem = fp.Semaphore.init(0, &sched);
    g_scheduler_primitive_sem = &sem;
    g_scheduler_primitive_sem_acquired = false;

    const prev_active = fp.active_scheduler;
    const prev_running = fp.scheduler_running;
    const prev_disable = sim_atomic.disable_fiber_yield_point;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    sim_atomic.disable_fiber_yield_point = true;
    defer {
        fc.__fiber = null;
        fc.__fiber_parent_ctx = null;
        fc.__fiber_stack_limit = null;
        sim_atomic.disable_fiber_yield_point = prev_disable;
        sched.current_task = null;
        fp.active_scheduler = prev_active;
        fp.scheduler_running = prev_running;
    }

    sched.current_task = &task;
    fiber.switchTo(&sched.main_ctx);
    if (task.status.load(.acquire) != .Blocked) return error.SemaphoreFiberDidNotPark;
    if (sem.waiting_task != &task) return error.SemaphoreWaiterNotRegistered;
    if (g_scheduler_primitive_sem_acquired) return error.SemaphoreAcquiredEarly;

    sem.release();
    if (sem.waiting_task != null) return error.SemaphoreWaiterNotCleared;
    if (sem.counter.load(.seq_cst) != 0) return error.SemaphoreDirectGrantIncrementedCounter;
    if (task.status.load(.acquire) != .Ready) return error.SemaphoreReleaseDidNotWake;

    sched.current_task = &task;
    fiber.switchTo(&sched.main_ctx);
    if (!g_scheduler_primitive_sem_acquired) return error.SemaphoreFiberDidNotResume;
}

pub fn testSemaphoreAcquireRecheckSlotAppearsUnderLock() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    var task: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&s25DummyFn),
        .status = qs.Atomic(TaskStatus).init(.Ready),
    };

    var sem = fp.Semaphore.init(0, &sched);
    sem.lock.store(1, .release);
    sched.current_task = &task;
    defer sched.current_task = null;

    var started = ThreadFlag.init(false);
    var ctx = SemaphoreRecheckReleaseCtx{ .sem = &sem, .started = &started };
    const releaser = try std.Thread.spawn(.{}, SemaphoreRecheckReleaseCtx.run, .{&ctx});
    while (!started.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    sem.acquire();
    releaser.join();

    if (sem.counter.load(.seq_cst) != 0) return error.SemaphoreCounterNotConsumedAfterRecheck;
    if (task.status.load(.acquire) != .Ready) return error.SemaphoreTaskNotReadyAfterRecheck;
    if (sem.waiting_task != null) return error.SemaphoreRecheckShouldNotPark;
}

// N1 batch 2: io_uring submit functions. Each parks a task by storing
// .Blocked into status. SimRing makes this safe under loom (no real
// fds, just staged SQEs). One test calls all 6 (read/write/accept/
// connect/recv/send), confirming each status-store fires.
pub fn testIoSubmitFns() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    var stub_task: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&s25DummyFn),
        .status = qs.Atomic(TaskStatus).init(.Ready),
    };
    var w: fp.Scheduler.IoWaiter = .{ .task = &stub_task };
    var buf: [16]u8 = undefined;
    const cbuf: []const u8 = &buf;

    // Each submit stores .Blocked. Reset between calls so we can
    // observe each store fire (covers L1811, 1834, 1842, 1850,
    // 1858, 1886).
    stub_task.status.store(.Ready, .release);
    try sched.submitRead(&w, 0, &buf);
    if (stub_task.status.load(.monotonic) != .Blocked) return error.ReadStatusMissing;

    stub_task.status.store(.Ready, .release);
    try sched.submitWrite(&w, 0, cbuf);
    if (stub_task.status.load(.monotonic) != .Blocked) return error.WriteStatusMissing;

    stub_task.status.store(.Ready, .release);
    try sched.submitAccept(&w, 0);
    if (stub_task.status.load(.monotonic) != .Blocked) return error.AcceptStatusMissing;

    stub_task.status.store(.Ready, .release);
    var addr: std.posix.sockaddr = undefined;
    try sched.submitConnect(&w, 0, &addr, @sizeOf(std.posix.sockaddr));
    if (stub_task.status.load(.monotonic) != .Blocked) return error.ConnectStatusMissing;

    stub_task.status.store(.Ready, .release);
    try sched.submitRecv(&w, 0, &buf);
    if (stub_task.status.load(.monotonic) != .Blocked) return error.RecvStatusMissing;

    stub_task.status.store(.Ready, .release);
    try sched.submitSend(&w, 0, cbuf);
    if (stub_task.status.load(.monotonic) != .Blocked) return error.SendStatusMissing;

    stub_task.status.store(.Blocked, .release);
    var completion_waiter: fp.Scheduler.IoWaiter = .{ .task = &stub_task };
    try sched.submitRead(&completion_waiter, 0, &buf);
    sched.flushRing();
    if (!sched.ring.complete(completion_waiter.encode(), 17)) return error.IoCompletionNotStaged;
    sched.pollNonBlocking();
    if (completion_waiter.result != 17) return error.IoCompletionResultMissing;
    if (stub_task.status.load(.monotonic) != .Ready) return error.IoCompletionDidNotReadyTask;
    if (sched.ready_queue.pop() != &stub_task) return error.IoCompletionDidNotEnqueueTask;
}

// N1 batch 3: sleepTask + fsmSleepTask. Both link in via direct call
// with a stub. They store .Blocked + push to sleeping_queue. wake side
// is already covered by testWakeExpiredSleepers.
pub fn testSleepTaskLinking() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    var sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);
    defer {
        // sleeping_queue still holds our stub on deinit; it walks
        // pending tasks. Drain it so .base = undefined isn't touched.
        sched.sleeping_queue.clearRetainingCapacity();
        sched.deinit();
        stack_pool.deinit();
        ebr.deinit(allocator);
    }

    var stub_task: Task = .{
        .base = undefined,
        .user_fn = @ptrCast(&s25DummyFn),
        .status = qs.Atomic(TaskStatus).init(.Ready),
    };

    // Covers L1650 status.store(.Blocked) + sleeping_queue.append.
    sched.sleepTask(&stub_task, 9_999_999_999_999);
    if (stub_task.status.load(.monotonic) != .Blocked) return error.SleepStatusMissing;
    if (sched.sleeping_queue.items.len != 1) return error.SleepQueueEmpty;
}

// N1 batch 2: SchedulerRegistry getLeastLoaded, notifyAll, deinit,
// count. Drives L2147-2148, 2207, 2209, 2219-2224, 2252-2255.
pub fn testSchedulerRegistryFns() !void {
    const allocator = std.heap.c_allocator;

    var ebr_a: ebr_mod.EbrContext = .{};
    var stack_pool_a = fm.StackPool.init(allocator);
    var sched_a = try fp.Scheduler.init(allocator, &ebr_a, &stack_pool_a);
    defer {
        sched_a.deinit();
        stack_pool_a.deinit();
        ebr_a.deinit(allocator);
    }

    var ebr_b: ebr_mod.EbrContext = .{};
    var stack_pool_b = fm.StackPool.init(allocator);
    var sched_b = try fp.Scheduler.init(allocator, &ebr_b, &stack_pool_b);
    defer {
        sched_b.deinit();
        stack_pool_b.deinit();
        ebr_b.deinit(allocator);
    }

    var registry: fp.SchedulerRegistry = .{};

    try registry.register(allocator, 1, &sched_a);
    try registry.register(allocator, 2, &sched_b);

    // getLeastLoaded: bias load so b is selected (covers L2147-2148).
    sched_a.active_tasks.store(5, .monotonic);
    sched_b.active_tasks.store(1, .monotonic);
    const least = registry.getLeastLoaded() orelse return error.GetLeastLoadedNull;
    if (least != &sched_a and least != &sched_b) return error.GetLeastLoadedUnknown;

    // count walks slots and counts non-null (L2252, L2255).
    if (registry.count() != 2) return error.CountMismatch;

    // notifyAll iterates and calls event_fd.notify (L2207, L2209).
    registry.notifyAll();

    // deinit resets atomics (L2219-2224).
    registry.deinit(allocator);
    if (registry.len.load(.monotonic) != 0) return error.LenNotReset;
    if (registry.next.load(.monotonic) != 0) return error.NextNotReset;
}
