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
                    self.stub_tasks[i].in_inbox.store(false, .release);
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

pub fn testMutexAcquireExhaustive() !void {
    const allocator = std.heap.c_allocator;

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
    fc.__fiber.?.yield();
    unreachable;
}

pub fn testMutexThreeFiberRaces() !void {
    const allocator = std.heap.c_allocator;

    var ebr: ebr_mod.EbrContext = .{};
    var stack_pool = fm.StackPool.init(allocator);
    g_sched = try fp.Scheduler.init(allocator, &ebr, &stack_pool);

    // 3 fibers → base-3 schedule encoding. depth=10 → 3^10 = 59,049
    // schedules. Same depth as lost-wake test for proven coverage of
    // initial choices.
    const depth: usize = 10;
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
    fc.__fiber.?.yield();
    unreachable;
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
    const depth: usize = 10;
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
pub fn testRwlockTwoWriters() !void {
    const allocator = std.heap.c_allocator;

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
pub fn testRwlockWriterReader() !void {
    const allocator = std.heap.c_allocator;

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
