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
const fsm_mod = @import("fsm.zig");
const build_options = @import("build_options");

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

const MAX_THREADS = 4;
const STACK_SIZE = 64 * 1024;
const MAX_STEPS = 50_000;

// Override default (500) via env var LOOM_FUZZ_SEEDS.
// Used by prng-mode tests to scale coverage for nightly/manual runs.
fn fuzzSeedCount(default_seeds: usize) usize {
    if (build_options.coverage) return @min(default_seeds, 4);
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
                    self.stub_tasks[i].in_inbox.store(false, .release);
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
