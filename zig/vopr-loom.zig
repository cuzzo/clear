// vopr-loom.zig -- Loom-style deterministic interleaving for Chase-Lev deque.
//
// Runs N virtual threads (fibers) executing REAL RunQueue.push()/pop()/stealOne()
// code, with a coordinator controlling which thread's next atomic operation runs.
// Every atomic op in SimAtomic yields to the coordinator, creating a deterministic
// interleaving driven by a seeded PRNG.
//
// Usage:
//   zig build loom                                          # 100K seeds
//   zig build-exe vopr-loom.zig switch.S onRoot.S -lc -OReleaseFast
//   ./vopr-loom --seeds 1000000                             # 1M seeds
//   ./vopr-loom --start 42 --seeds 1                        # reproduce seed 42

const std = @import("std");
const fc = @import("fiber-core.zig");
const qs = @import("queues.zig");

// Re-export SimAtomic so queues.zig picks it up via @import("root").SimAtomic
pub const SimAtomic = @import("vopr-atomic.zig").SimAtomic;

const Fiber = fc.Fiber;
const Context = fc.Context;
const Stack = fc.Stack;
const RunQueue = qs.RunQueue;
const Task = qs.Task;
const TaskConfig = qs.TaskConfig;

const MAX_THREADS = 4;
const MAX_RESULTS = 8;
const STACK_SIZE = 64 * 1024;
const MAX_STEPS = 10_000; // safety limit per scenario

// -----------------------------------------------------------------------
// Global harness pointer — fibers access this to record results and
// signal completion.  Set by the coordinator before running scenarios.
// -----------------------------------------------------------------------
var harness: *LoomHarness = undefined;

const LoomHarness = struct {
    // Fibers (virtual threads)
    fibers: [MAX_THREADS]Fiber = undefined,
    stacks: [MAX_THREADS][]u8 = undefined,
    main_ctx: Context = undefined,
    done: [MAX_THREADS]bool = [_]bool{false} ** MAX_THREADS,
    n_threads: usize = 0,

    // Shared state under test
    queue: *RunQueue,

    // Stub tasks for push/pop/steal operations
    stub_tasks: [MAX_RESULTS]Task = undefined,
    stub_fibers: [MAX_RESULTS]Fiber = undefined,
    stub_stacks: [MAX_RESULTS][64]u8 = undefined,

    // Results: what each thread got from pop/steal
    results: [MAX_THREADS][MAX_RESULTS]?*Task = undefined,
    result_counts: [MAX_THREADS]usize = [_]usize{0} ** MAX_THREADS,

    // PRNG
    rng: std.Random.DefaultPrng = undefined,
    random: std.Random = undefined,

    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, seed: u64) !LoomHarness {
        const q = try allocator.create(RunQueue);
        q.* = RunQueue.init();

        var h = LoomHarness{
            .queue = q,
            .allocator = allocator,
        };
        h.rng = std.Random.DefaultPrng.init(seed);
        h.random = h.rng.random();

        // Clear results
        for (&h.results) |*row| {
            for (row) |*slot| slot.* = null;
        }

        return h;
    }

    fn deinit(self: *LoomHarness) void {
        for (self.stacks[0..self.n_threads]) |stack| {
            self.allocator.free(stack);
        }
        self.allocator.destroy(self.queue);
    }

    /// Initialize a stub task (no real fiber, just a valid Task struct).
    fn initStubTask(self: *LoomHarness, idx: usize, pinned: bool) *Task {
        @memset(&self.stub_stacks[idx], 0);
        self.stub_fibers[idx] = Fiber{
            .stack = Stack{ .memory = &self.stub_stacks[idx] },
            .ctx = Context{ .sp = 0 },
            .parent_ctx = undefined,
            .size_class = .Standard,
            .stack_limit = 0,
            .stack_guard_head = null,
        };
        self.stub_tasks[idx] = Task{
            .base = &self.stub_fibers[idx],
            .user_fn = @ptrCast(&dummyFn),
            .status = .Ready,
            .config = .{ .pinned = pinned },
        };
        return &self.stub_tasks[idx];
    }

    /// Create a fiber for virtual thread `id` with the given entry function.
    fn createThread(self: *LoomHarness, id: usize, entry_fn: usize) !void {
        const stack = try self.allocator.alloc(u8, STACK_SIZE);
        self.stacks[id] = stack;
        self.fibers[id] = Fiber.init(stack, entry_fn, .Large);
        self.done[id] = false;
        self.result_counts[id] = 0;
        for (&self.results[id]) |*slot| slot.* = null;
        if (id >= self.n_threads) self.n_threads = id + 1;
    }

    /// Record a result for the current thread.
    fn recordResult(self: *LoomHarness, thread_id: usize, task: ?*Task) void {
        const idx = self.result_counts[thread_id];
        if (idx < MAX_RESULTS) {
            self.results[thread_id][idx] = task;
            self.result_counts[thread_id] = idx + 1;
        }
    }

    /// Run the coordinator loop: interleave fibers until all done.
    fn run(self: *LoomHarness) !void {
        var steps: usize = 0;
        while (steps < MAX_STEPS) : (steps += 1) {
            // Count active threads
            var active: usize = 0;
            for (self.done[0..self.n_threads]) |d| {
                if (!d) active += 1;
            }
            if (active == 0) break;

            // Pick a random active thread
            var pick = self.random.intRangeLessThan(usize, 0, active);
            var chosen: usize = 0;
            for (self.done[0..self.n_threads], 0..) |d, i| {
                if (!d) {
                    if (pick == 0) {
                        chosen = i;
                        break;
                    }
                    pick -= 1;
                }
            }

            // Switch to that fiber — it runs until the next SimAtomic yield
            self.fibers[chosen].switchTo(&self.main_ctx);
        }

        if (steps >= MAX_STEPS) {
            std.debug.print("LOOM: hit step limit ({d}) — possible deadlock\n", .{MAX_STEPS});
            return error.StepLimitExceeded;
        }
    }

    /// Reset for next scenario (reuse allocations).
    /// Clears fiber threadlocals to prevent stale state from previous run.
    fn reset(self: *LoomHarness, seed: u64) void {
        fc.__fiber = null;
        fc.__fiber_parent_ctx = null;
        fc.__fiber_stack_limit = null;
        self.queue.* = RunQueue.init();
        self.rng = std.Random.DefaultPrng.init(seed);
        self.random = self.rng.random();
        for (&self.done) |*d| d.* = false;
        for (&self.result_counts) |*c| c.* = 0;
        for (&self.results) |*row| {
            for (row) |*slot| slot.* = null;
        }
        self.n_threads = 0;
    }

    fn dummyFn(_: *anyopaque, _: ?*anyopaque) anyerror!void {}
};

// -----------------------------------------------------------------------
// Thread entry functions
//
// Each is a naked-like function that reads its scenario from `harness`,
// executes real RunQueue operations, records results, marks done, and yields.
// Must NOT return (fiber stack has no valid return address).
// -----------------------------------------------------------------------

/// Thread 0: owner pop
fn entryOwnerPop() callconv(.c) void {
    const h = harness;
    const result = h.queue.pop();
    h.recordResult(0, result);
    h.done[0] = true;
    fc.__fiber.?.yield();
    unreachable;
}

/// Thread 1: thief stealOne
fn entryThiefSteal() callconv(.c) void {
    const h = harness;
    const result = h.queue.stealOne();
    h.recordResult(1, result);
    h.done[1] = true;
    fc.__fiber.?.yield();
    unreachable;
}

/// Thread 0: owner push + pop
fn entryOwnerPushPop() callconv(.c) void {
    const h = harness;
    const task = h.initStubTask(7, false); // use slot 7 for the extra task
    h.queue.push(std.heap.c_allocator, task) catch {};
    const result = h.queue.pop();
    h.recordResult(0, result);
    h.done[0] = true;
    fc.__fiber.?.yield();
    unreachable;
}

/// Thread 0: owner double pop
fn entryOwnerDoublePop() callconv(.c) void {
    const h = harness;
    const r1 = h.queue.pop();
    h.recordResult(0, r1);
    const r2 = h.queue.pop();
    h.recordResult(0, r2);
    h.done[0] = true;
    fc.__fiber.?.yield();
    unreachable;
}

/// Thread N: thief double steal
fn entryThiefDoubleSteal1() callconv(.c) void {
    const h = harness;
    const r1 = h.queue.stealOne();
    h.recordResult(1, r1);
    const r2 = h.queue.stealOne();
    h.recordResult(1, r2);
    h.done[1] = true;
    fc.__fiber.?.yield();
    unreachable;
}

fn entryThiefDoubleSteal2() callconv(.c) void {
    const h = harness;
    const r1 = h.queue.stealOne();
    h.recordResult(2, r1);
    const r2 = h.queue.stealOne();
    h.recordResult(2, r2);
    h.done[2] = true;
    fc.__fiber.?.yield();
    unreachable;
}

// -----------------------------------------------------------------------
// Invariant checks
// -----------------------------------------------------------------------

const LoomError = error{
    TaskLost,
    TaskDuplicated,
    PinnedStolen,
    StepLimitExceeded,
};

/// Count non-null results across all threads.
fn countResults(h: *LoomHarness) usize {
    var total: usize = 0;
    for (h.results[0..h.n_threads]) |row| {
        for (row) |slot| {
            if (slot != null) total += 1;
        }
    }
    return total;
}

/// Check that no task appears in more than one result slot.
fn checkNoDuplicates(h: *LoomHarness) LoomError!void {
    var seen: [MAX_THREADS * MAX_RESULTS]?*Task = [_]?*Task{null} ** (MAX_THREADS * MAX_RESULTS);
    var seen_count: usize = 0;

    for (h.results[0..h.n_threads]) |row| {
        for (row) |slot| {
            if (slot) |task| {
                for (seen[0..seen_count]) |s| {
                    if (s == task) return LoomError.TaskDuplicated;
                }
                seen[seen_count] = task;
                seen_count += 1;
            }
        }
    }
}

/// Check that pinned tasks were never returned by a thief (thread != 0).
fn checkPinnedNotStolen(h: *LoomHarness) LoomError!void {
    // Threads 1+ are thieves -- they should never get pinned tasks
    for (h.results[1..h.n_threads]) |row| {
        for (row) |slot| {
            if (slot) |task| {
                if (task.config.pinned) return LoomError.PinnedStolen;
            }
        }
    }
}

// -----------------------------------------------------------------------
// Test scenarios
// -----------------------------------------------------------------------

/// Scenario 1: Pop vs Steal on 1-element queue (bug 1 TOCTOU).
/// Owner calls pop(), thief calls stealOne(). Exactly one should get the task.
fn scenarioPopVsSteal(h: *LoomHarness) !void {
    const task = h.initStubTask(0, false);
    h.queue.push(std.heap.c_allocator, task) catch unreachable;

    try h.createThread(0, @intFromPtr(&entryOwnerPop));
    try h.createThread(1, @intFromPtr(&entryThiefSteal));

    try h.run();

    // Invariant: exactly one gets the task
    const total = countResults(h);
    if (total != 1) {
        std.debug.print("LOOM scenarioPopVsSteal: expected 1 result, got {d}\n", .{total});
        if (total == 0) return LoomError.TaskLost;
        return LoomError.TaskDuplicated;
    }
    try checkNoDuplicates(h);
}

/// Scenario 2: Pinned steal (bug 4).
/// Push 1 pinned + 1 unpinned task. Owner pops, thief steals.
/// Thief must never get the pinned task.
fn scenarioPinnedSteal(h: *LoomHarness) !void {
    const pinned = h.initStubTask(0, true);
    const unpinned = h.initStubTask(1, false);
    h.queue.push(std.heap.c_allocator, pinned) catch unreachable;
    h.queue.push(std.heap.c_allocator, unpinned) catch unreachable;

    try h.createThread(0, @intFromPtr(&entryOwnerPop));
    try h.createThread(1, @intFromPtr(&entryThiefSteal));

    try h.run();

    // Pinned task must not be returned by thief
    try checkPinnedNotStolen(h);
    try checkNoDuplicates(h);

    // Conservation: up to 2 results (some may be null if queue appeared empty)
    const total = countResults(h);
    if (total > 2) return LoomError.TaskDuplicated;
}

/// Scenario 3: Multi-thief (general correctness).
/// Push 4 tasks. Owner pops twice, two thieves steal twice each.
/// Each task should appear at most once.
fn scenarioMultiThief(h: *LoomHarness) !void {
    for (0..4) |i| {
        const task = h.initStubTask(i, false);
        h.queue.push(std.heap.c_allocator, task) catch unreachable;
    }

    try h.createThread(0, @intFromPtr(&entryOwnerDoublePop));
    try h.createThread(1, @intFromPtr(&entryThiefDoubleSteal1));
    try h.createThread(2, @intFromPtr(&entryThiefDoubleSteal2));

    try h.run();

    try checkNoDuplicates(h);
    const total = countResults(h);
    if (total > 4) return LoomError.TaskDuplicated;
}

/// Scenario 4: Push during steal.
/// Push 1 task, then owner pushes another + pops, thief steals.
fn scenarioPushDuringSteal(h: *LoomHarness) !void {
    const task = h.initStubTask(0, false);
    h.queue.push(std.heap.c_allocator, task) catch unreachable;

    try h.createThread(0, @intFromPtr(&entryOwnerPushPop));
    try h.createThread(1, @intFromPtr(&entryThiefSteal));

    try h.run();

    try checkNoDuplicates(h);
    // 2 tasks total (1 pre-pushed + 1 pushed by owner). Up to 2 results.
    const total = countResults(h);
    if (total > 2) return LoomError.TaskDuplicated;
}

// -----------------------------------------------------------------------
// Main
// -----------------------------------------------------------------------

fn runSeed(allocator: std.mem.Allocator, seed: u64) !void {
    var h = try LoomHarness.init(allocator, seed);
    defer h.deinit();
    harness = &h;

    // Run all scenarios with the same seed (different initial PRNG state per scenario)
    const scenarios = [_]struct {
        name: []const u8,
        func: *const fn (*LoomHarness) anyerror!void,
    }{
        .{ .name = "pop_vs_steal", .func = &scenarioPopVsSteal },
        .{ .name = "pinned_steal", .func = &scenarioPinnedSteal },
        .{ .name = "multi_thief", .func = &scenarioMultiThief },
        .{ .name = "push_during_steal", .func = &scenarioPushDuringSteal },
    };

    for (scenarios) |s| {
        h.reset(seed +% std.hash.Wyhash.hash(0, s.name));
        harness = &h;
        s.func(&h) catch |err| {
            std.debug.print("LOOM FAILED: seed={d} scenario={s}: {}\n", .{ seed, s.name, err });
            return err;
        };
    }
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var seed_start: u64 = 0;
    var seed_count: u64 = 100_000;

    var args = std.process.args();
    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--seeds")) {
            if (args.next()) |val|
                seed_count = std.fmt.parseInt(u64, val, 10) catch 100_000;
        } else if (std.mem.eql(u8, arg, "--start")) {
            if (args.next()) |val|
                seed_start = std.fmt.parseInt(u64, val, 10) catch 0;
        }
    }

    std.debug.print("LOOM: {d} seeds starting at {d}, 4 scenarios/seed\n", .{ seed_count, seed_start });

    var failures: u64 = 0;
    for (seed_start..seed_start + seed_count) |seed| {
        runSeed(allocator, seed) catch {
            failures += 1;
            if (failures >= 10) {
                std.debug.print("LOOM: {d} failures, stopping early\n", .{failures});
                std.process.exit(1);
            }
        };
        if (seed % 100_000 == 0 and seed > seed_start) {
            std.debug.print("LOOM: {d}/{d} seeds OK\n", .{ seed - seed_start, seed_count });
        }
    }

    if (failures > 0) {
        std.debug.print("LOOM: FAILED -- {d}/{d} seeds failed\n", .{ failures, seed_count });
        std.process.exit(1);
    }

    std.debug.print("LOOM: PASSED -- all {d} seeds OK\n", .{seed_count});
}
