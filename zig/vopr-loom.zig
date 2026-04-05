// vopr-loom.zig -- Loom-style deterministic interleaving for Chase-Lev deque.
//
// Runs N virtual threads (fibers) executing REAL RunQueue.push()/pop()/stealOne()
// code, with a coordinator controlling which thread's next atomic operation runs.
// Every atomic op in SimAtomic yields to the coordinator, creating a deterministic
// interleaving driven by either:
//   - Exhaustive enumeration (2-thread scenarios, complete proof)
//   - PRNG sampling (3+ thread scenarios, statistical coverage)
//
// Usage:
//   zig build loom                       # 100K PRNG seeds + exhaustive
//   zig build test                       # includes exhaustive Loom tests
//   ./vopr-loom --seeds 1000000          # 1M PRNG seeds
//   ./vopr-loom --start 42 --seeds 1     # reproduce seed 42
//
// -----------------------------------------------------------------------
// MAINTAINING EXHAUSTIVE DEPTH
// -----------------------------------------------------------------------
// The exhaustive enumerator uses a binary schedule of depth D, trying all
// 2^D possible thread-selection sequences. This must cover every unique
// interleaving of the two threads' atomic operations.
//
// Unique interleavings = C(a + b, b), where:
//   a = max atomic ops in thread A (owner: pop/push)
//   b = max atomic ops in thread B (thief: stealOne)
//
// Current op counts (from queues.zig + task.status via SimAtomic):
//   pop()      = 7 ops max  (2 loads, 1 store, 2 loads, 1 CAS, 1 store)
//   stealOne() = 4 ops max  (2 loads, 1 load, 1 CAS)
//   push()     = 4 ops max  (1 load, 1 load, 1 store, 1 store)
//   epollWake  = 5 ops max  (1 status CAS, 4 push ops)
//   epollWake+pop = 12 ops  (1 status CAS, 4 push, 7 pop)
//
// Scenario               | a  | b  | C(a+b,b) | Depth needed
// -----------------------+----+----+----------+-------------
// pop vs steal           |  7 |  4 |      330 | 11 (2048)
// pinned steal           |  7 |  8 |    6435* | 15 (32768)
// push during steal      | 11 |  4 |     1365 | 12 (4096)
// epoll wake vs pop      |  5 |  7 |      792 | 10 (1024)
// epoll wake vs steal    |  5 |  4 |      126 |  8 (256)
// double epoll fire      |  5 |  5 |      252 |  9 (512)
// epoll wake+pop vs steal| 12 |  4 |     1820 | 11 (2048)
//
// * pinned steal: stealOne hits pinned path, calls push() internally (4 more ops)
//
// We use depth 10-14 for unit tests and depth 14 for the main binary,
// which covers all scenarios with margin.
//
// WHEN TO INCREASE DEPTH:
//   - You add atomic operations to pop(), push(), or stealOne()
//   - You add a new code path with more ops (e.g., dynamic buffer resize)
//   - A scenario calls multiple RunQueue methods per thread
//
// HOW TO VERIFY: count the SimAtomic yield points (load/store/CAS calls)
// in the longest code path for each thread. Compute C(a+b, b). Ensure
// 2^depth >= C(a+b, b). When in doubt, increase depth -- the cost is
// 2x per extra bit, and the tests are fast.

const std = @import("std");
const fc = @import("fiber-core.zig");
const qs = @import("queues.zig");

// Re-export SimAtomic so queues.zig picks it up via @import("root").SimAtomic
pub const SimAtomic = @import("vopr-atomic.zig").SimAtomic;
// Re-export SimPoller so scheduler.zig picks it up via @import("root").SimPoller
pub const SimPoller = @import("vopr-poller.zig").SimPoller;

const Fiber = fc.Fiber;
const Context = fc.Context;
const Stack = fc.Stack;
const RunQueue = qs.RunQueue;
const Task = qs.Task;

const MAX_THREADS = 4;
const MAX_RESULTS = 8;
const STACK_SIZE = 64 * 1024;
const MAX_STEPS = 10_000;

// -----------------------------------------------------------------------
// Global harness pointer — fibers access this to record results.
// -----------------------------------------------------------------------
var harness: *LoomHarness = undefined;

const ScheduleMode = union(enum) {
    /// PRNG-driven: random thread selection at each yield point.
    prng: struct {
        rng: std.Random.DefaultPrng,
        random: std.Random,
    },
    /// Exhaustive: schedule[step] picks the thread for each yield point.
    /// When schedule is exhausted, round-robin the remaining active threads.
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

    queue: *RunQueue,

    stub_tasks: [MAX_RESULTS]Task = undefined,
    stub_fibers: [MAX_RESULTS]Fiber = undefined,
    stub_stacks: [MAX_RESULTS][64]u8 = undefined,

    results: [MAX_THREADS][MAX_RESULTS]?*Task = undefined,
    result_counts: [MAX_THREADS]usize = [_]usize{0} ** MAX_THREADS,

    mode: ScheduleMode,
    allocator: std.mem.Allocator,

    fn initPrng(allocator: std.mem.Allocator, seed: u64) !LoomHarness {
        const q = try allocator.create(RunQueue);
        q.* = RunQueue.initWithAllocator(allocator) catch unreachable;
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

    fn initExhaustive(allocator: std.mem.Allocator, schedule: []const u8) !LoomHarness {
        const q = try allocator.create(RunQueue);
        q.* = RunQueue.initWithAllocator(allocator) catch unreachable;
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

    fn deinit(self: *LoomHarness) void {
        for (&self.stacks) |*stack| {
            if (stack.len > 0) {
                self.allocator.free(stack.*);
                stack.* = &.{};
            }
        }
        self.queue.deinit();
        self.allocator.destroy(self.queue);
    }

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
            .status = qs.Atomic(qs.TaskStatus).init(.Ready),
            .config = .{ .pinned = pinned },
        };
        return &self.stub_tasks[idx];
    }

    fn createThread(self: *LoomHarness, id: usize, entry_fn: usize) !void {
        // Allocate stack on first use, reuse on subsequent calls
        if (self.stacks[id].len == 0) {
            self.stacks[id] = try self.allocator.alloc(u8, STACK_SIZE);
        }
        self.fibers[id] = Fiber.init(self.stacks[id], entry_fn, .Large);
        self.done[id] = false;
        self.result_counts[id] = 0;
        for (&self.results[id]) |*slot| slot.* = null;
        if (id >= self.n_threads) self.n_threads = id + 1;
    }

    fn recordResult(self: *LoomHarness, thread_id: usize, task: ?*Task) void {
        const idx = self.result_counts[thread_id];
        if (idx < MAX_RESULTS) {
            self.results[thread_id][idx] = task;
            self.result_counts[thread_id] = idx + 1;
        }
    }

    /// Pick the next thread to run based on mode.
    fn pickThread(self: *LoomHarness) usize {
        var active_count: usize = 0;
        var active_ids: [MAX_THREADS]usize = undefined;
        for (self.done[0..self.n_threads], 0..) |d, i| {
            if (!d) {
                active_ids[active_count] = i;
                active_count += 1;
            }
        }
        if (active_count == 0) return 0; // shouldn't happen

        switch (self.mode) {
            .prng => |*p| {
                const pick = p.random.intRangeLessThan(usize, 0, active_count);
                return active_ids[pick];
            },
            .exhaustive => |*e| {
                if (e.pos < e.schedule.len) {
                    const choice = e.schedule[e.pos] % @as(u8, @intCast(active_count));
                    e.pos += 1;
                    return active_ids[choice];
                }
                // Schedule exhausted: round-robin (drain remaining work)
                const choice = e.pos % active_count;
                e.pos += 1;
                return active_ids[choice];
            },
        }
    }

    fn run(self: *LoomHarness) !void {
        var steps: usize = 0;
        while (steps < MAX_STEPS) : (steps += 1) {
            var any_active = false;
            for (self.done[0..self.n_threads]) |d| {
                if (!d) {
                    any_active = true;
                    break;
                }
            }
            if (!any_active) break;

            const chosen = self.pickThread();
            self.fibers[chosen].switchTo(&self.main_ctx);
        }
        // Clear fiber threadlocals so post-run SimAtomic operations
        // (e.g., queue.len() in invariant checks) don't try to yield
        // on a dead fiber context.
        fc.__fiber = null;
        fc.__fiber_parent_ctx = null;

        if (steps >= MAX_STEPS) {
            std.debug.print("LOOM: hit step limit ({d})\n", .{MAX_STEPS});
            return error.StepLimitExceeded;
        }
    }

    fn resetPrng(self: *LoomHarness, seed: u64) void {
        clearState(self);
        self.mode = .{ .prng = .{ .rng = std.Random.DefaultPrng.init(seed), .random = undefined } };
        self.mode.prng.random = self.mode.prng.rng.random();
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
        self.queue.* = RunQueue.initWithAllocator(self.allocator) catch unreachable;
        for (&self.done) |*d| d.* = false;
        for (&self.result_counts) |*c| c.* = 0;
        for (&self.results) |*row| for (row) |*slot| {
            slot.* = null;
        };
        self.n_threads = 0;
    }

    fn dummyFn(_: *anyopaque, _: ?*anyopaque) anyerror!void {}
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

fn entryThiefSteal() callconv(.c) void {
    const h = harness;
    const result = h.queue.stealOne();
    h.recordResult(1, result);
    h.done[1] = true;
    fc.__fiber.?.yield();
    unreachable;
}

fn entryOwnerPushPop() callconv(.c) void {
    const h = harness;
    const task = h.initStubTask(7, false);
    h.queue.push(std.heap.c_allocator, task) catch {};
    const result = h.queue.pop();
    h.recordResult(0, result);
    h.done[0] = true;
    fc.__fiber.?.yield();
    unreachable;
}

fn entryOwnerDoublePop() callconv(.c) void {
    const h = harness;
    h.recordResult(0, h.queue.pop());
    h.recordResult(0, h.queue.pop());
    h.done[0] = true;
    fc.__fiber.?.yield();
    unreachable;
}

fn entryThiefDoubleSteal1() callconv(.c) void {
    const h = harness;
    h.recordResult(1, h.queue.stealOne());
    h.recordResult(1, h.queue.stealOne());
    h.done[1] = true;
    fc.__fiber.?.yield();
    unreachable;
}

fn entryThiefDoubleSteal2() callconv(.c) void {
    const h = harness;
    h.recordResult(2, h.queue.stealOne());
    h.recordResult(2, h.queue.stealOne());
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

fn countResults(h: *LoomHarness) usize {
    var total: usize = 0;
    for (h.results[0..h.n_threads]) |row| {
        for (row) |slot| {
            if (slot != null) total += 1;
        }
    }
    return total;
}

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

fn checkPinnedNotStolen(h: *LoomHarness) LoomError!void {
    for (h.results[1..h.n_threads]) |row| {
        for (row) |slot| {
            if (slot) |task| {
                if (task.config.pinned) return LoomError.PinnedStolen;
            }
        }
    }
}

/// Thread 0: owner double pop for aggressive pinned scenario
fn entryOwnerDoublePop2() callconv(.c) void {
    const h = harness;
    h.recordResult(0, h.queue.pop());
    h.recordResult(0, h.queue.pop());
    h.done[0] = true;
    fc.__fiber.?.yield();
    unreachable;
}

/// Thread 1: thief double steal for aggressive pinned scenario
fn entryThiefDoubleSteal() callconv(.c) void {
    const h = harness;
    h.recordResult(1, h.queue.stealOne());
    h.recordResult(1, h.queue.stealOne());
    h.done[1] = true;
    fc.__fiber.?.yield();
    unreachable;
}

// -----------------------------------------------------------------------
// Scenarios
// -----------------------------------------------------------------------

fn scenarioPopVsSteal(h: *LoomHarness) !void {
    const task = h.initStubTask(0, false);
    h.queue.push(std.heap.c_allocator, task) catch unreachable;
    try h.createThread(0, @intFromPtr(&entryOwnerPop));
    try h.createThread(1, @intFromPtr(&entryThiefSteal));
    try h.run();
    const total = countResults(h);
    if (total != 1) {
        if (total == 0) return LoomError.TaskLost;
        return LoomError.TaskDuplicated;
    }
    try checkNoDuplicates(h);
}

// Pinned tasks no longer enter the RunQueue. This scenario tests
// steal with 2 non-pinned tasks (replaces old pinned+unpinned mix).
fn scenarioPinnedSteal(h: *LoomHarness) !void {
    const t0 = h.initStubTask(0, false);
    const t1 = h.initStubTask(1, false);
    h.queue.push(std.heap.c_allocator, t0) catch unreachable;
    h.queue.push(std.heap.c_allocator, t1) catch unreachable;
    try h.createThread(0, @intFromPtr(&entryOwnerPop));
    try h.createThread(1, @intFromPtr(&entryThiefSteal));
    try h.run();
    try checkNoDuplicates(h);
    const total = countResults(h) + h.queue.len();
    if (total < 2) return LoomError.TaskLost;
    if (total > 2) return LoomError.TaskDuplicated;
}

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
    const total = countResults(h) + h.queue.len();
    if (total < 4) return LoomError.TaskLost;
    if (total > 4) return LoomError.TaskDuplicated;
}

fn scenarioPushDuringSteal(h: *LoomHarness) !void {
    const task = h.initStubTask(0, false);
    h.queue.push(std.heap.c_allocator, task) catch unreachable;
    try h.createThread(0, @intFromPtr(&entryOwnerPushPop));
    try h.createThread(1, @intFromPtr(&entryThiefSteal));
    try h.run();
    try checkNoDuplicates(h);
    const total = countResults(h) + h.queue.len();
    if (total < 2) return LoomError.TaskLost;
    if (total > 2) return LoomError.TaskDuplicated;
}

/// Scenario 5: Aggressive pinned push-back under contention.
/// 3 pinned + 2 unpinned tasks. Owner pops twice, thief steals twice.
/// Scenario 5: Heavy contention — 5 non-pinned tasks (replaces aggressive pinned).
fn scenarioAggressivePinned(h: *LoomHarness) !void {
    for (0..5) |i| {
        const task = h.initStubTask(i, false);
        h.queue.push(std.heap.c_allocator, task) catch unreachable;
    }
    try h.createThread(0, @intFromPtr(&entryOwnerDoublePop2));
    try h.createThread(1, @intFromPtr(&entryThiefDoubleSteal));
    try h.run();
    try checkNoDuplicates(h);
    const total = countResults(h) + h.queue.len();
    if (total < 5) return LoomError.TaskLost;
    if (total > 5) return LoomError.TaskDuplicated;
}

/// Scenario 6: 4 non-pinned tasks (replaces all-pinned).
fn scenarioAllPinned(h: *LoomHarness) !void {
    for (0..4) |i| {
        const task = h.initStubTask(i, false);
        h.queue.push(std.heap.c_allocator, task) catch unreachable;
    }
    try h.createThread(0, @intFromPtr(&entryOwnerDoublePop2));
    try h.createThread(1, @intFromPtr(&entryThiefDoubleSteal));
    try h.run();
    try checkNoDuplicates(h);
    const total = countResults(h) + h.queue.len();
    if (total < 4) return LoomError.TaskLost;
    if (total > 4) return LoomError.TaskDuplicated;
}

// -----------------------------------------------------------------------
// Epoll integration: thread entry functions
// -----------------------------------------------------------------------
// These model the scheduler's epoll wakeup path: CAS Blocked->Ready,
// then push to queue.  This is the code extracted as wakeTaskFromEpoll()
// in scheduler.zig.  By running it under Loom's SimAtomic, we get
// deterministic interleaving at the CAS and push yield points.

/// Thread A: simulate epoll waking a Blocked task (CAS + push).
/// This is the hot path from scheduler.zig processEpollEvents().
/// Does NOT record the task as a "result" -- the waker produces the task
/// into the queue, it doesn't consume it.  Only poppers/stealers consume.
fn entryEpollWake() callconv(.c) void {
    const h = harness;
    const task = &h.stub_tasks[0];
    // CAS Blocked -> Ready.  Only the CAS winner pushes.
    if (task.status.cmpxchgStrong(.Blocked, .Ready, .acq_rel, .monotonic) == null) {
        h.queue.push(std.heap.c_allocator, task) catch {};
    }
    h.done[0] = true;
    fc.__fiber.?.yield();
    unreachable;
}

/// Thread B: owner pops from queue (races with epoll wake push).
fn entryEpollPop() callconv(.c) void {
    const h = harness;
    const result = h.queue.pop();
    h.recordResult(1, result);
    h.done[1] = true;
    fc.__fiber.?.yield();
    unreachable;
}

/// Thread B: thief steals from queue (races with epoll wake push).
fn entryEpollSteal() callconv(.c) void {
    const h = harness;
    const result = h.queue.stealOne();
    h.recordResult(1, result);
    h.done[1] = true;
    fc.__fiber.?.yield();
    unreachable;
}

/// Thread B: simulate second epoll fire on same task (double-fire race).
/// Both threads try to CAS Blocked->Ready on the same task.
/// Neither records a consumed result -- they're both producers.
fn entryEpollWake2() callconv(.c) void {
    const h = harness;
    const task = &h.stub_tasks[0];
    if (task.status.cmpxchgStrong(.Blocked, .Ready, .acq_rel, .monotonic) == null) {
        h.queue.push(std.heap.c_allocator, task) catch {};
    }
    h.done[1] = true;
    fc.__fiber.?.yield();
    unreachable;
}

/// Thread A: epoll wake + push, then pop (models a scheduler that wakes
/// a task from epoll and immediately runs it in the same iteration).
fn entryEpollWakeThenPop() callconv(.c) void {
    const h = harness;
    const task = &h.stub_tasks[0];
    if (task.status.cmpxchgStrong(.Blocked, .Ready, .acq_rel, .monotonic) == null) {
        h.queue.push(std.heap.c_allocator, task) catch {};
    }
    // Now pop (may get the task we just pushed, or null if thief stole it)
    h.recordResult(0, h.queue.pop());
    h.done[0] = true;
    fc.__fiber.?.yield();
    unreachable;
}

// -----------------------------------------------------------------------
// Epoll integration: scenarios
// -----------------------------------------------------------------------

/// Scenario 7: Epoll wake vs pop.
/// Thread A (waker): CAS Blocked->Ready + push (epoll wakeup path)
/// Thread B (popper): pop() from the queue
/// Task 0 starts Blocked (not in queue). Task 1 starts in queue.
/// The waker produces task 0 into the queue; the popper consumes.
/// Invariant: no task appears twice, popped + queue <= 2.
fn scenarioEpollWakeVsPop(h: *LoomHarness) !void {
    const blocked_task = h.initStubTask(0, false);
    blocked_task.status.store(.Blocked, .release);
    const ready_task = h.initStubTask(1, false);
    h.queue.push(std.heap.c_allocator, ready_task) catch unreachable;

    try h.createThread(0, @intFromPtr(&entryEpollWake));
    try h.createThread(1, @intFromPtr(&entryEpollPop));
    try h.run();
    // Only thread 1 (popper) records consumed results.
    // Thread 0 (waker) is a producer -- no results.
    try checkNoDuplicates(h);
    const popped = countResults(h);
    const in_queue = h.queue.len();
    // 2 tasks total (task 0 Blocked + task 1 in queue). Waker may or may
    // not have pushed task 0 (CAS could succeed). Popper may or may not
    // have popped. But consumed + remaining can't exceed 2.
    if (popped + in_queue > 2) return LoomError.TaskDuplicated;
}

/// Scenario 8: Epoll wake vs steal.
/// Thread A (waker): CAS Blocked->Ready + push
/// Thread B (stealer): stealOne() from the queue
/// Task 0 starts Blocked. Task 1 starts in queue.
fn scenarioEpollWakeVsSteal(h: *LoomHarness) !void {
    const blocked_task = h.initStubTask(0, false);
    blocked_task.status.store(.Blocked, .release);
    const ready_task = h.initStubTask(1, false);
    h.queue.push(std.heap.c_allocator, ready_task) catch unreachable;

    try h.createThread(0, @intFromPtr(&entryEpollWake));
    try h.createThread(1, @intFromPtr(&entryEpollSteal));
    try h.run();
    try checkNoDuplicates(h);
    const stolen = countResults(h);
    const in_queue = h.queue.len();
    if (stolen + in_queue > 2) return LoomError.TaskDuplicated;
}

/// Scenario 9: Double epoll fire.
/// Two threads both try CAS Blocked->Ready on the SAME task.
/// Exactly one must win; the task must appear in the queue exactly once.
/// Neither thread records results -- both are producers.
fn scenarioDoubleEpollFire(h: *LoomHarness) !void {
    const task = h.initStubTask(0, false);
    task.status.store(.Blocked, .release);

    try h.createThread(0, @intFromPtr(&entryEpollWake));
    try h.createThread(1, @intFromPtr(&entryEpollWake2));
    try h.run();

    const in_queue = h.queue.len();
    // Task must be pushed exactly once (one CAS winner, ONESHOT semantics)
    if (in_queue == 0) return LoomError.TaskLost;
    if (in_queue > 1) return LoomError.TaskDuplicated;
}

/// Scenario 10: Epoll wake-then-pop vs steal.
/// Thread A: CAS + push, then immediately pop (scheduler fast path)
/// Thread B: stealOne() concurrently
/// Tests the case where the scheduler wakes a task and tries to run it
/// in the same iteration, racing with a thief.
fn scenarioEpollWakePopVsSteal(h: *LoomHarness) !void {
    const blocked_task = h.initStubTask(0, false);
    blocked_task.status.store(.Blocked, .release);

    try h.createThread(0, @intFromPtr(&entryEpollWakeThenPop));
    try h.createThread(1, @intFromPtr(&entryEpollSteal));
    try h.run();
    try checkNoDuplicates(h);
    // Thread A wakes task (CAS + push) then pops.
    // Thread B may steal between push and pop.
    // At most 1 thread ends up with the task.
    const results = countResults(h);
    const in_queue = h.queue.len();
    if (results + in_queue > 1) return LoomError.TaskDuplicated;
}

// -----------------------------------------------------------------------
// Exhaustive driver -- enumerate all 2-thread interleavings
// -----------------------------------------------------------------------

/// Run a scenario under every possible 2-thread interleaving.
/// A schedule is a sequence of choices (0 or 1) at each yield point,
/// selecting which thread runs next.  We enumerate all 2^MAX_DEPTH
/// schedules.  Most terminate early (thread finishes and only one
/// remains), so redundant schedules are harmless.
fn runExhaustiveN(
    allocator: std.mem.Allocator,
    scenario: *const fn (*LoomHarness) anyerror!void,
    name: []const u8,
    comptime depth: u5,
) !usize {
    var schedule_buf: [depth]u8 = undefined;
    var count: usize = 0;

    var h = try LoomHarness.initExhaustive(allocator, &schedule_buf);
    defer h.deinit();
    harness = &h;

    var sched_id: u32 = 0;
    while (sched_id < (@as(u32, 1) << depth)) : (sched_id += 1) {
        for (0..depth) |i| {
            schedule_buf[i] = @intCast((sched_id >> @intCast(i)) & 1);
        }

        h.resetExhaustive(&schedule_buf);
        harness = &h;

        scenario(&h) catch |err| {
            std.debug.print("LOOM EXHAUSTIVE FAILED: schedule={d} scenario={s}: {}\n", .{ sched_id, name, err });
            return err;
        };
        count += 1;
    }
    return count;
}

/// Full exhaustive (2^14 = 16384 schedules). Used by main().
fn runExhaustive(
    allocator: std.mem.Allocator,
    scenario: *const fn (*LoomHarness) anyerror!void,
    name: []const u8,
) !usize {
    return runExhaustiveN(allocator, scenario, name, 14);
}

// -----------------------------------------------------------------------
// Unit tests -- run during `zig build test`
// -----------------------------------------------------------------------

test "loom: exhaustive pop vs steal" {
    // pop=7 ops, steal=4 ops. C(11,4)=330. Depth 12 = 4096 schedules.
    const count = try runExhaustiveN(std.testing.allocator, &scenarioPopVsSteal, "pop_vs_steal", 12);
    std.debug.print("  pop_vs_steal: {d} interleavings OK\n", .{count});
}

test "loom: exhaustive pinned steal" {
    // pop=7 ops, steal+push_back=8 ops. C(15,8)=6435. Depth 14 = 16384 schedules.
    const count = try runExhaustiveN(std.testing.allocator, &scenarioPinnedSteal, "pinned_steal", 14);
    std.debug.print("  pinned_steal: {d} interleavings OK\n", .{count});
}

test "loom: exhaustive push during steal" {
    // push+pop=11 ops, steal=4 ops. C(15,4)=1365. Depth 12 = 4096 schedules.
    const count = try runExhaustiveN(std.testing.allocator, &scenarioPushDuringSteal, "push_during_steal", 12);
    std.debug.print("  push_during_steal: {d} interleavings OK\n", .{count});
}

test "loom: exhaustive aggressive pinned" {
    // pop=7*2=14 ops, steal+push_back=8*2=16 ops. Depth 14 for coverage.
    const count = try runExhaustiveN(std.testing.allocator, &scenarioAggressivePinned, "aggressive_pinned", 14);
    std.debug.print("  aggressive_pinned: {d} interleavings OK\n", .{count});
}

test "loom: exhaustive all-pinned queue" {
    // Same ops as aggressive pinned. Every steal hits pinned path.
    const count = try runExhaustiveN(std.testing.allocator, &scenarioAllPinned, "all_pinned", 14);
    std.debug.print("  all_pinned: {d} interleavings OK\n", .{count});
}

// -----------------------------------------------------------------------
// Epoll integration: exhaustive tests
// -----------------------------------------------------------------------
// Op counts for epoll scenarios (task.status now uses SimAtomic):
//   entryEpollWake:        1 CAS + 4 push ops = 5 ops
//   entryEpollPop:         7 ops (pop)
//   entryEpollSteal:       4 ops (stealOne)
//   entryEpollWake2:       1 CAS + 4 push ops = 5 ops
//   entryEpollWakeThenPop: 1 CAS + 4 push + 7 pop = 12 ops

test "loom: exhaustive epoll wake vs pop" {
    // wake=5 ops, pop=7 ops. C(12,5)=792. Depth 12 = 4096 schedules.
    const count = try runExhaustiveN(std.testing.allocator, &scenarioEpollWakeVsPop, "epoll_wake_vs_pop", 12);
    std.debug.print("  epoll_wake_vs_pop: {d} interleavings OK\n", .{count});
}

test "loom: exhaustive epoll wake vs steal" {
    // wake=5 ops, steal=4 ops. C(9,4)=126. Depth 10 = 1024 schedules.
    const count = try runExhaustiveN(std.testing.allocator, &scenarioEpollWakeVsSteal, "epoll_wake_vs_steal", 10);
    std.debug.print("  epoll_wake_vs_steal: {d} interleavings OK\n", .{count});
}

test "loom: exhaustive double epoll fire" {
    // Both threads: 5 ops each. C(10,5)=252. Depth 10 = 1024 schedules.
    const count = try runExhaustiveN(std.testing.allocator, &scenarioDoubleEpollFire, "double_epoll_fire", 10);
    std.debug.print("  double_epoll_fire: {d} interleavings OK\n", .{count});
}

test "loom: exhaustive epoll wake-pop vs steal" {
    // wake+pop=12 ops, steal=4 ops. C(16,4)=1820. Depth 14 = 16384 schedules.
    const count = try runExhaustiveN(std.testing.allocator, &scenarioEpollWakePopVsSteal, "epoll_wake_pop_vs_steal", 14);
    std.debug.print("  epoll_wake_pop_vs_steal: {d} interleavings OK\n", .{count});
}

test "loom: queue wraparound" {
    // Push/pop enough to wrap the u32 bottom index near max.
    // Verifies modular arithmetic in pop() and stealOne().
    const allocator = std.testing.allocator;
    const q = try allocator.create(RunQueue);
    defer {
        q.deinit();
        allocator.destroy(q);
    }
    q.* = RunQueue.initWithAllocator(allocator) catch unreachable;

    // Advance bottom/top near u32 max to test wrapping
    const near_max: u32 = std.math.maxInt(u32) - 10;
    q.bottom.store(near_max, .monotonic);
    q.top.store(near_max, .monotonic);

    // Stub tasks
    var stub_fibers: [4]Fiber = undefined;
    var stub_stacks: [4][64]u8 = undefined;
    var stub_tasks: [4]Task = undefined;
    for (0..4) |i| {
        @memset(&stub_stacks[i], 0);
        stub_fibers[i] = Fiber{
            .stack = Stack{ .memory = &stub_stacks[i] },
            .ctx = Context{ .sp = 0 },
            .parent_ctx = undefined,
            .size_class = .Standard,
            .stack_limit = 0,
            .stack_guard_head = null,
        };
        stub_tasks[i] = Task{
            .base = &stub_fibers[i],
            .user_fn = @ptrCast(&LoomHarness.dummyFn),
            .status = qs.Atomic(qs.TaskStatus).init(.Ready),
            .config = .{},
        };
        // Push wraps around u32 max
        try q.push(allocator, &stub_tasks[i]);
    }

    if (q.len() != 4) return error.TestUnexpectedResult;

    // Pop all -- exercises wrapping arithmetic in pop()
    var popped: usize = 0;
    while (q.pop()) |_| popped += 1;
    if (popped != 4) return error.TestUnexpectedResult;
    if (q.len() != 0) return error.TestUnexpectedResult;

    // Push again and steal -- exercises wrapping in stealOne()
    for (0..2) |i| {
        try q.push(allocator, &stub_tasks[i]);
    }
    const stolen = q.stealOne();
    if (stolen == null) return error.TestUnexpectedResult;
    if (q.len() != 1) return error.TestUnexpectedResult;
}

// -----------------------------------------------------------------------
// Main -- PRNG mode for 3+ thread scenarios + exhaustive for 2-thread
// -----------------------------------------------------------------------

fn runSeed(allocator: std.mem.Allocator, seed: u64) !void {
    var h = try LoomHarness.initPrng(allocator, seed);
    defer h.deinit();
    harness = &h;

    const scenarios = [_]struct {
        name: []const u8,
        func: *const fn (*LoomHarness) anyerror!void,
    }{
        .{ .name = "pop_vs_steal", .func = &scenarioPopVsSteal },
        .{ .name = "pinned_steal", .func = &scenarioPinnedSteal },
        .{ .name = "multi_thief", .func = &scenarioMultiThief },
        .{ .name = "push_during_steal", .func = &scenarioPushDuringSteal },
        .{ .name = "aggressive_pinned", .func = &scenarioAggressivePinned },
        .{ .name = "all_pinned", .func = &scenarioAllPinned },
        .{ .name = "epoll_wake_vs_pop", .func = &scenarioEpollWakeVsPop },
        .{ .name = "epoll_wake_vs_steal", .func = &scenarioEpollWakeVsSteal },
        .{ .name = "double_epoll_fire", .func = &scenarioDoubleEpollFire },
        .{ .name = "epoll_wake_pop_vs_steal", .func = &scenarioEpollWakePopVsSteal },
    };

    for (scenarios) |s| {
        h.resetPrng(seed +% std.hash.Wyhash.hash(0, s.name));
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

    // Exhaustive 2-thread scenarios first
    std.debug.print("LOOM exhaustive (2-thread, all interleavings):\n", .{});
    const exhaustive_scenarios = [_]struct {
        name: []const u8,
        func: *const fn (*LoomHarness) anyerror!void,
    }{
        .{ .name = "pop_vs_steal", .func = &scenarioPopVsSteal },
        .{ .name = "pinned_steal", .func = &scenarioPinnedSteal },
        .{ .name = "push_during_steal", .func = &scenarioPushDuringSteal },
        .{ .name = "aggressive_pinned", .func = &scenarioAggressivePinned },
        .{ .name = "all_pinned", .func = &scenarioAllPinned },
        .{ .name = "epoll_wake_vs_pop", .func = &scenarioEpollWakeVsPop },
        .{ .name = "epoll_wake_vs_steal", .func = &scenarioEpollWakeVsSteal },
        .{ .name = "double_epoll_fire", .func = &scenarioDoubleEpollFire },
        .{ .name = "epoll_wake_pop_vs_steal", .func = &scenarioEpollWakePopVsSteal },
    };
    for (exhaustive_scenarios) |s| {
        const count = runExhaustive(allocator, s.func, s.name) catch |err| {
            std.debug.print("LOOM EXHAUSTIVE FAILED: {s}: {}\n", .{ s.name, err });
            std.process.exit(1);
        };
        std.debug.print("  {s}: {d} interleavings OK\n", .{ s.name, count });
    }

    // PRNG mode for all scenarios (including 3-thread multi_thief)
    std.debug.print("LOOM PRNG: {d} seeds starting at {d}\n", .{ seed_count, seed_start });
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

    std.debug.print("LOOM: PASSED -- exhaustive + {d} PRNG seeds OK\n", .{seed_count});
}
