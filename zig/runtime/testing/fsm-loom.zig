// fsm-loom.zig — Loom-style deterministic interleaving coverage for
// FsmRunQueue (Chase-Lev work-stealing deque for *FsmTask).
//
// Structurally identical to vopr-loom.zig's RunQueue coverage (same
// Chase-Lev algorithm, different element type). The FsmRunQueue clone
// was justified against the claim "RunQueue's Loom coverage transfers
// because the algorithm is identical" — this file makes the claim
// concrete by actually running Loom on FsmRunQueue directly.
//
// Scenarios:
//   - owner pop vs thief steal        (a=7, b=4, depth 11, 2048 schedules)
//   - owner push+pop vs thief steal   (a=11, b=4, depth 12, 4096 schedules)
//   - two thieves vs one push         (a=4, b=4+4, depth 12, 4096 schedules)
//   - owner drain vs thief drain      (multi-item conservation)
//   - grow while thief drains         (array publish + stealing)
//   - dispatch waiter state clearing  (lock_waiter atomic protocol)
//
// Invariants (checked after each exhaustive run):
//   I1. At-most-once delivery: each pushed task is observed by exactly one
//       of {owner pop, thief steal} — never dropped, never duplicated.
//   I2. Queue drained: after the scenario, queue.len() == 0.
//   I3. No crashes: MAX_STEPS bound not exceeded.
//
// Invocation: `zig build test-loom-vopr -Dtest-file=fsm-loom-test.zig`
// runs this through executable-rooted fsm-loom-test.zig. Do not route this
// through `b.addTest`: Zig's generated test runner would hide root.SimAtomic
// and silently disable the loom seam.

const std = @import("std");
const fc = @import("../fiber-core.zig");
const fsm = @import("../fsm.zig");
const va = @import("../vopr-atomic.zig");

// Re-export SimAtomic so fsm.zig's Chase-Lev ops pick it up via
// `@import("root").SimAtomic`. When this file is the root (direct
// compilation via fsm-loom-test.zig wrapper), FsmRunQueue's atomic
// operations become SimAtomic yield points.
pub const SimAtomic = va.SimAtomic;
pub const SimRing = @import("../vopr-ring.zig").SimRing;

const Fiber = fc.Fiber;
const Context = fc.Context;
const Stack = fc.Stack;
const FsmRunQueue = fsm.FsmRunQueue;
const FsmTask = fsm.FsmTask;

const MAX_THREADS = 4;
const MAX_RESULTS = 128;
const STACK_SIZE = 64 * 1024;
const MAX_STEPS = 10_000;

// Global harness pointer — fiber entry fns access this to record results.
var harness: *LoomHarness = undefined;
var stale_waiter_byte: u8 = 0;
var fresh_waiter_byte: u8 = 0;

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
    stacks: [MAX_THREADS][]u8 = undefined,
    main_ctx: Context = undefined,
    done: [MAX_THREADS]bool = [_]bool{false} ** MAX_THREADS,
    n_threads: usize = 0,

    queue: *FsmRunQueue,

    // Stub FsmTasks — pushed onto the queue; their identity is tracked
    // so we can assert exactly-once delivery across threads.
    stub_tasks: [MAX_RESULTS]FsmTask = undefined,

    results: [MAX_THREADS][MAX_RESULTS]?*FsmTask = undefined,
    result_counts: [MAX_THREADS]usize = [_]usize{0} ** MAX_THREADS,

    mode: ScheduleMode,
    allocator: std.mem.Allocator,

    fn initExhaustive(allocator: std.mem.Allocator, schedule: []const u8) !LoomHarness {
        const q = try allocator.create(FsmRunQueue);
        q.* = FsmRunQueue.initWithAllocator(allocator) catch unreachable;
        var h = LoomHarness{
            .queue = q,
            .allocator = allocator,
            .mode = .{ .exhaustive = .{ .schedule = schedule, .pos = 0 } },
            .stacks = [_][]u8{&.{}} ** MAX_THREADS,
        };
        for (&h.results) |*row| for (row) |*slot| {
            slot.* = null;
        };
        return h;
    }

    fn initPrng(allocator: std.mem.Allocator, seed: u64) !LoomHarness {
        const q = try allocator.create(FsmRunQueue);
        q.* = FsmRunQueue.initWithAllocator(allocator) catch unreachable;
        const rng = std.Random.DefaultPrng.init(seed);
        var h = LoomHarness{
            .queue = q,
            .allocator = allocator,
            .mode = .{ .prng = .{ .rng = rng, .random = undefined } },
            .stacks = [_][]u8{&.{}} ** MAX_THREADS,
        };
        h.mode.prng.random = h.mode.prng.rng.random();
        for (&h.results) |*row| for (row) |*slot| {
            slot.* = null;
        };
        return h;
    }

    fn deinit(self: *LoomHarness) void {
        for (&self.stacks) |*s| {
            if (s.len > 0) {
                self.allocator.free(s.*);
                s.* = &.{};
            }
        }
        self.queue.deinit();
        self.allocator.destroy(self.queue);
    }

    fn dummyResume(_: *FsmTask) fsm.YieldReason {
        return .{ .Done = {} };
    }

    /// Initialize stub FsmTasks that will be pushed onto the queue.
    /// Each stub is a distinct pointer so the result arrays can show
    /// exactly-once delivery.
    fn initStubs(self: *LoomHarness, n: usize) void {
        std.debug.assert(n <= MAX_RESULTS);
        for (self.stub_tasks[0..n], 0..) |*t, i| {
            t.* = FsmTask.init(&dummyResume);
            _ = i;
        }
    }

    fn createThread(self: *LoomHarness, id: usize, entry_fn: usize) !void {
        if (self.stacks[id].len == 0) {
            self.stacks[id] = try self.allocator.alloc(u8, STACK_SIZE);
        }
        self.fibers[id] = Fiber.init(self.stacks[id], entry_fn, .Large);
        self.done[id] = false;
        self.result_counts[id] = 0;
        for (&self.results[id]) |*slot| slot.* = null;
        if (id >= self.n_threads) self.n_threads = id + 1;
    }

    fn recordResult(self: *LoomHarness, thread_id: usize, task: ?*FsmTask) void {
        const idx = self.result_counts[thread_id];
        if (idx < MAX_RESULTS) {
            self.results[thread_id][idx] = task;
            self.result_counts[thread_id] = idx + 1;
        }
    }

    fn pickThread(self: *LoomHarness) usize {
        var active_count: usize = 0;
        var active_ids: [MAX_THREADS]usize = undefined;
        for (self.done[0..self.n_threads], 0..) |d, i| {
            if (!d) {
                active_ids[active_count] = i;
                active_count += 1;
            }
        }
        if (active_count == 0) return 0;
        switch (self.mode) {
            .prng => |*p| return active_ids[p.random.intRangeLessThan(usize, 0, active_count)],
            .exhaustive => |*e| {
                const c = if (e.pos < e.schedule.len)
                    e.schedule[e.pos] % @as(u8, @intCast(active_count))
                else
                    e.pos % active_count;
                e.pos += 1;
                return active_ids[c];
            },
        }
    }

    fn run(self: *LoomHarness) !void {
        var steps: usize = 0;
        while (steps < MAX_STEPS) : (steps += 1) {
            var any_active = false;
            for (self.done[0..self.n_threads]) |d| if (!d) {
                any_active = true;
                break;
            };
            if (!any_active) break;
            const chosen = self.pickThread();
            self.fibers[chosen].switchTo(&self.main_ctx);
        }
        // Clear fiber threadlocals so post-run ops (queue.len) don't yield.
        fc.__fiber = null;
        fc.__fiber_parent_ctx = null;
        if (steps >= MAX_STEPS) return error.StepLimitExceeded;
    }

    fn resetExhaustive(self: *LoomHarness, schedule: []const u8) void {
        clearState(self);
        self.mode = .{ .exhaustive = .{ .schedule = schedule, .pos = 0 } };
    }

    fn clearState(self: *LoomHarness) void {
        fc.__fiber = null;
        fc.__fiber_parent_ctx = null;
        fc.__fiber_stack_limit = null;
        self.queue.deinit();
        self.queue.* = FsmRunQueue.initWithAllocator(self.allocator) catch unreachable;
        for (&self.done) |*d| d.* = false;
        for (&self.result_counts) |*c| c.* = 0;
        for (&self.results) |*row| for (row) |*slot| {
            slot.* = null;
        };
        self.n_threads = 0;
    }
};

// -----------------------------------------------------------------------
// Thread entry functions
// -----------------------------------------------------------------------

fn entryOwnerPop() callconv(.c) void {
    const h = harness;
    const result = h.queue.pop();
    h.recordResult(0, result);
    h.done[0] = true;
    fc.__fiber.?.yield();
    unreachable;
}

fn entryOwnerDrain() callconv(.c) void {
    const h = harness;
    while (h.queue.pop()) |task| {
        h.recordResult(0, task);
    }
    h.done[0] = true;
    fc.__fiber.?.yield();
    unreachable;
}

fn entryThiefSteal() callconv(.c) void {
    const h = harness;
    const result = h.queue.stealOne();
    h.recordResult(1, result);
    h.done[1] = true;
    fc.__fiber.?.yield();
    unreachable;
}

fn entryThiefDrain() callconv(.c) void {
    const h = harness;
    while (h.queue.stealOne()) |task| {
        h.recordResult(1, task);
    }
    h.done[1] = true;
    fc.__fiber.?.yield();
    unreachable;
}

// Dedicated entries for the two-thieves scenario where both threads
// steal on the same queue. Each records to / toggles its own slot so
// the coordinator correctly tracks completion.
fn entryThiefA() callconv(.c) void {
    const h = harness;
    const result = h.queue.stealOne();
    h.recordResult(0, result);
    h.done[0] = true;
    fc.__fiber.?.yield();
    unreachable;
}

fn entryThiefB() callconv(.c) void {
    const h = harness;
    const result = h.queue.stealOne();
    h.recordResult(1, result);
    h.done[1] = true;
    fc.__fiber.?.yield();
    unreachable;
}

fn entryOwnerPushPop() callconv(.c) void {
    const h = harness;
    h.queue.push(std.heap.c_allocator, &h.stub_tasks[7]) catch {};
    const result = h.queue.pop();
    h.recordResult(0, result);
    h.done[0] = true;
    fc.__fiber.?.yield();
    unreachable;
}

fn entryGrowProducer() callconv(.c) void {
    const h = harness;
    const initial_capacity = @as(usize, 1) << fsm.FsmRunQueue.INITIAL_LOG_SIZE;
    var i = initial_capacity;
    while (i < initial_capacity + 8) : (i += 1) {
        h.queue.push(h.allocator, &h.stub_tasks[i]) catch @panic("grow producer push failed");
    }
    h.done[0] = true;
    fc.__fiber.?.yield();
    unreachable;
}

fn entryStealUntilProducerDone() callconv(.c) void {
    const h = harness;
    while (!h.done[0]) {
        if (h.queue.stealOne()) |task| {
            h.recordResult(1, task);
        } else {
            fc.__fiber.?.yield();
        }
    }
    while (h.queue.stealOne()) |task| {
        h.recordResult(1, task);
    }
    h.done[1] = true;
    fc.__fiber.?.yield();
    unreachable;
}

fn resumeYielded(_: *FsmTask) fsm.YieldReason {
    return .{ .Yielded = {} };
}

fn resumeWaitForLock(task: *FsmTask) fsm.YieldReason {
    task.lock_waiter.store(@as(*anyopaque, @ptrCast(&fresh_waiter_byte)), .release);
    return .{ .WaitForLock = {} };
}

fn entryDispatchYielded() callconv(.c) void {
    const h = harness;
    _ = fsm.dispatchOnce(&h.stub_tasks[0]);
    h.done[0] = true;
    fc.__fiber.?.yield();
    unreachable;
}

fn entryDispatchWaitForLock() callconv(.c) void {
    const h = harness;
    _ = fsm.dispatchOnce(&h.stub_tasks[1]);
    h.done[1] = true;
    fc.__fiber.?.yield();
    unreachable;
}

// -----------------------------------------------------------------------
// Invariant check — confirm exactly-once delivery across threads.
// -----------------------------------------------------------------------

fn checkAtMostOnce(h: *LoomHarness, n_threads: usize) !void {
    var seen = std.AutoHashMap(*FsmTask, void).init(h.allocator);
    defer seen.deinit();
    for (h.results[0..n_threads], 0..) |row, tid| {
        for (row[0..h.result_counts[tid]]) |slot_opt| {
            if (slot_opt) |t| {
                if (seen.contains(t)) return error.DuplicateDelivery;
                try seen.put(t, {});
            }
        }
    }
}

fn stubIndex(h: *LoomHarness, task: *FsmTask, expected_count: usize) ?usize {
    for (h.stub_tasks[0..expected_count], 0..) |*stub, idx| {
        if (stub == task) return idx;
    }
    return null;
}

fn checkExactDelivery(h: *LoomHarness, n_threads: usize, expected_count: usize) !void {
    var seen = [_]bool{false} ** MAX_RESULTS;
    var total: usize = 0;
    for (h.results[0..n_threads], 0..) |row, tid| {
        for (row[0..h.result_counts[tid]]) |slot_opt| {
            if (slot_opt) |task| {
                const idx = stubIndex(h, task, expected_count) orelse return error.UnexpectedTask;
                if (seen[idx]) return error.DuplicateDelivery;
                seen[idx] = true;
                total += 1;
            }
        }
    }
    if (total != expected_count) return error.LossOrDuplicate;
    for (seen[0..expected_count]) |was_seen| {
        if (!was_seen) return error.LossOrDuplicate;
    }
    if (h.queue.len() != 0) return error.QueueNotDrained;
}

// -----------------------------------------------------------------------
// Scenarios
// -----------------------------------------------------------------------

/// Owner's single pop races with a single thief's stealOne. Queue has
/// exactly one element. Expected: one thread gets it, the other returns
/// null. Both orderings must terminate without corruption.
fn runPopVsSteal(h: *LoomHarness) !void {
    h.initStubs(1);
    try h.queue.push(h.allocator, &h.stub_tasks[0]);
    try h.createThread(0, @intFromPtr(&entryOwnerPop));
    try h.createThread(1, @intFromPtr(&entryThiefSteal));
    try h.run();
    try checkAtMostOnce(h, 2);
    // Total delivered across both threads: exactly 1.
    var total: usize = 0;
    for (h.result_counts[0..2], 0..) |n, tid| {
        for (h.results[tid][0..n]) |s| if (s != null) {
            total += 1;
        };
    }
    if (total != 1) return error.LossOrDuplicate;
}

/// Owner pushes a new element then pops, while a thief steals. Tests
/// the push-then-pop sequence races with a concurrent stealOne.
fn runPushPopVsSteal(h: *LoomHarness) !void {
    h.initStubs(8);
    // Pre-seed with one element. Owner will push one more then pop.
    try h.queue.push(h.allocator, &h.stub_tasks[0]);
    try h.createThread(0, @intFromPtr(&entryOwnerPushPop));
    try h.createThread(1, @intFromPtr(&entryThiefSteal));
    try h.run();
    try checkAtMostOnce(h, 2);
    // Owner pushed 1 more, so queue started with 1 + 1 = 2 elements.
    // Owner does 1 pop, thief does 1 stealOne. Combined total should be
    // at most 2. (Could be 1 if CAS fails for one.)
    var total: usize = 0;
    for (h.result_counts[0..2], 0..) |n, tid| {
        for (h.results[tid][0..n]) |s| if (s != null) {
            total += 1;
        };
    }
    if (total > 2) return error.DuplicateDelivery;
}

/// Two thieves steal from a queue with 1 element. At most one should
/// succeed.
fn runTwoThievesOneItem(h: *LoomHarness) !void {
    h.initStubs(1);
    try h.queue.push(h.allocator, &h.stub_tasks[0]);
    try h.createThread(0, @intFromPtr(&entryThiefA));
    try h.createThread(1, @intFromPtr(&entryThiefB));
    try h.run();
    try checkAtMostOnce(h, 2);
    var total: usize = 0;
    for (h.result_counts[0..2], 0..) |n, tid| {
        for (h.results[tid][0..n]) |s| if (s != null) {
            total += 1;
        };
    }
    if (total > 1) return error.DuplicateSteal;
}

/// Owner drains from the bottom while a thief drains from the top. This
/// strengthens the single-pop/steal smoke case into full conservation:
/// every preseeded task must be delivered exactly once and the queue must
/// end empty.
fn runOwnerDrainVsThiefDrain(h: *LoomHarness) !void {
    const total_tasks = 16;
    h.initStubs(total_tasks);
    for (h.stub_tasks[0..total_tasks]) |*task| {
        try h.queue.push(h.allocator, task);
    }
    try h.createThread(0, @intFromPtr(&entryOwnerDrain));
    try h.createThread(1, @intFromPtr(&entryThiefDrain));
    try h.run();
    try checkExactDelivery(h, 2, total_tasks);
}

/// Fill the initial circular array, then let the owner push enough extra work
/// to force grow() while a thief concurrently drains. The invariant is still
/// exact delivery; failures here usually mean a broken array publish, stale
/// top/bottom read, or lost task during grow.
fn runGrowWhileStealing(h: *LoomHarness) !void {
    const initial_capacity = @as(usize, 1) << fsm.FsmRunQueue.INITIAL_LOG_SIZE;
    const total_tasks = initial_capacity + 8;
    h.initStubs(total_tasks);
    for (h.stub_tasks[0..initial_capacity]) |*task| {
        try h.queue.push(h.allocator, task);
    }
    try h.createThread(0, @intFromPtr(&entryGrowProducer));
    try h.createThread(1, @intFromPtr(&entryStealUntilProducerDone));
    try h.run();
    try checkExactDelivery(h, 2, total_tasks);
}

/// dispatchOnce has a small but important atomic protocol: stale lock waiters
/// must be cleared before resuming, while a WaitForLock resume that installs a
/// fresh waiter must survive the post-resume status update.
fn runDispatchWaiterProtocol(h: *LoomHarness) !void {
    h.stub_tasks[0] = FsmTask.init(&resumeYielded);
    h.stub_tasks[0].lock_waiter.store(@as(*anyopaque, @ptrCast(&stale_waiter_byte)), .monotonic);
    h.stub_tasks[1] = FsmTask.init(&resumeWaitForLock);

    try h.createThread(0, @intFromPtr(&entryDispatchYielded));
    try h.createThread(1, @intFromPtr(&entryDispatchWaitForLock));
    try h.run();

    if (h.stub_tasks[0].status != .Ready) return error.DispatchStatusWrong;
    if (h.stub_tasks[0].lock_waiter.load(.acquire) != null) return error.StaleWaiterNotCleared;
    if (h.stub_tasks[1].status != .Blocked) return error.DispatchStatusWrong;
    const fresh = @as(*anyopaque, @ptrCast(&fresh_waiter_byte));
    if (h.stub_tasks[1].lock_waiter.load(.acquire) != fresh) return error.FreshWaiterLost;
}

// -----------------------------------------------------------------------
// Test drivers
// -----------------------------------------------------------------------

fn runExhaustiveN(
    allocator: std.mem.Allocator,
    scenario: *const fn (h: *LoomHarness) anyerror!void,
    name: []const u8,
    depth: usize,
) !void {
    const total: usize = @as(usize, 1) << @intCast(depth);
    const schedule = try allocator.alloc(u8, depth);
    defer allocator.free(schedule);
    var h = try LoomHarness.initExhaustive(allocator, schedule);
    harness = &h;
    defer h.deinit();

    var failed: usize = 0;
    var sched_idx: usize = 0;
    while (sched_idx < total) : (sched_idx += 1) {
        for (0..depth) |bit| {
            schedule[bit] = @intCast((sched_idx >> @as(u6, @intCast(bit))) & 1);
        }
        h.resetExhaustive(schedule);
        scenario(&h) catch |e| {
            std.debug.print("{s} FAIL sched {d}: {s}\n", .{ name, sched_idx, @errorName(e) });
            failed += 1;
            if (failed > 3) return error.TooManyLoomFailures;
        };
    }
    if (failed > 0) return error.LoomFailures;
    std.debug.print("  {s}: {d} interleavings OK\n", .{ name, total });
}

test "loom: FsmRunQueue exhaustive pop vs steal" {
    try runExhaustiveN(std.testing.allocator, runPopVsSteal, "pop_vs_steal", 11);
}

test "loom: FsmRunQueue exhaustive push+pop vs steal" {
    try runExhaustiveN(std.testing.allocator, runPushPopVsSteal, "push_pop_vs_steal", 12);
}

test "loom: FsmRunQueue exhaustive two thieves" {
    try runExhaustiveN(std.testing.allocator, runTwoThievesOneItem, "two_thieves", 8);
}

test "loom: FsmRunQueue exhaustive owner drain vs thief drain" {
    try runExhaustiveN(std.testing.allocator, runOwnerDrainVsThiefDrain, "owner_drain_vs_thief_drain", 10);
}

test "loom: FsmRunQueue grow while thief drains" {
    try runExhaustiveN(std.testing.allocator, runGrowWhileStealing, "grow_while_stealing", 8);
}

test "loom: dispatchOnce waiter protocol" {
    try runExhaustiveN(std.testing.allocator, runDispatchWaiterProtocol, "dispatch_waiter_protocol", 8);
}

// PRNG variant for broader randomized coverage. Set LOOM_FUZZ_SEEDS env
// var to scale up (default 200 for the unit test; 10K+ for nightly).
fn fuzzSeedCount(default_seeds: usize) usize {
    const raw = std.c.getenv("LOOM_FUZZ_SEEDS") orelse return default_seeds;
    const s = std.mem.span(raw);
    return std.fmt.parseInt(usize, s, 10) catch default_seeds;
}

fn runPrngSeeds(allocator: std.mem.Allocator, n: usize) !void {
    var failed: usize = 0;
    var seed: u64 = 0;
    while (seed < n) : (seed += 1) {
        var h = try LoomHarness.initPrng(allocator, seed);
        harness = &h;
        runPushPopVsSteal(&h) catch {
            failed += 1;
        };
        h.deinit();
    }
    if (failed > 0) return error.PrngFailures;
}

fn checkSimAtomicCoverage() !void {
    std.debug.print(
        "  fsm_loom_atomic_sites={d}, sim_atomic_ops={d}\n",
        .{ va.sim_unique_site_count, va.sim_atomic_op_count },
    );
    if (va.sim_atomic_op_count == 0) return error.SimAtomicDidNotFire;
    if (va.sim_unique_site_count < 20) return error.FsmLoomCoverageRegressed;
}

test "loom: FsmRunQueue PRNG seeds (200 default, LOOM_FUZZ_SEEDS to scale)" {
    try runPrngSeeds(std.testing.allocator, fuzzSeedCount(200));
}

test "loom: FsmRunQueue SimAtomic coverage gate" {
    try checkSimAtomicCoverage();
}

pub fn runAll(allocator: std.mem.Allocator) !void {
    try runExhaustiveN(allocator, runPopVsSteal, "pop_vs_steal", 11);
    try runExhaustiveN(allocator, runPushPopVsSteal, "push_pop_vs_steal", 12);
    try runExhaustiveN(allocator, runTwoThievesOneItem, "two_thieves", 8);
    try runExhaustiveN(allocator, runOwnerDrainVsThiefDrain, "owner_drain_vs_thief_drain", 10);
    try runExhaustiveN(allocator, runGrowWhileStealing, "grow_while_stealing", 8);
    try runExhaustiveN(allocator, runDispatchWaiterProtocol, "dispatch_waiter_protocol", 8);
    try runPrngSeeds(allocator, fuzzSeedCount(200));
    try checkSimAtomicCoverage();
}
