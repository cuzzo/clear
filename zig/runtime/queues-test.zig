const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const queues = @import("queues.zig");

const RunQueue = queues.RunQueue;
const Task = queues.Task;

// -------------------------------------------------------------------------
// RunQueue (Chase-Lev) Tests
// -------------------------------------------------------------------------

// Helper to create dummy tasks
fn createTask(id: usize) *Task {
    const t = std.testing.allocator.create(Task) catch unreachable;
    // We only care about the pointer address for the queue,
    // but we can store ID in the context or similar if Task structure allows.
    // Assuming Task has a `context` field we can abuse for ID verification:
    t.context = @ptrFromInt(id);
    t.status.store(.Ready, .release);
    return t;
}

fn destroyTask(t: *Task) void {
    std.testing.allocator.destroy(t);
}

test "RunQueue: FIFO/LIFO Semantics" {
    var q = RunQueue.initWithAllocator(std.testing.allocator) catch unreachable;
    defer q.deinit();

    const t1 = createTask(1);
    const t2 = createTask(2);
    const t3 = createTask(3);
    defer { destroyTask(t1); destroyTask(t2); destroyTask(t3); }

    // Owner Pushes
    try q.push(std.testing.allocator, t1);
    try q.push(std.testing.allocator, t2);
    try q.push(std.testing.allocator, t3);

    // Owner Pops (LIFO - Stack behavior)
    // Expect: 3, 2, 1
    try testing.expectEqual(t3, q.pop().?);
    try testing.expectEqual(t2, q.pop().?);
    try testing.expectEqual(t1, q.pop().?);
    try testing.expect(q.pop() == null);
}

test "RunQueue: Stealing (FIFO)" {
    var owner_q = RunQueue.initWithAllocator(std.testing.allocator) catch unreachable;
    defer owner_q.deinit();
    var thief_q = RunQueue.initWithAllocator(std.testing.allocator) catch unreachable;
    defer thief_q.deinit();
    // inbox removed — tryStealFrom no longer needs it

    // Push 10 items
    var tasks: [10]*Task = undefined;
    for (0..10) |i| {
        tasks[i] = createTask(i);
        try owner_q.push(std.testing.allocator, tasks[i]);
    }
    defer for (tasks) |t| destroyTask(t);

    // Steal! (Should take half: 5 items)
    // Stealing happens from the TOP (FIFO), so we expect 0, 1, 2, 3, 4
    const stolen = thief_q.tryStealFrom(&owner_q, std.testing.allocator);

    try testing.expectEqual(@as(usize, 5), stolen);

    // Verify Thief got the *oldest* tasks (0..4)
    // Note: Thief pushes them into its own queue.
    // If thief pops them now, it pops in LIFO order relative to how it pushed them.
    // Implementation detail: tryStealFrom usually pushes loop-style.

    // Let's just check ID of what's in thief_q by popping
    var count: usize = 0;
    while (thief_q.pop()) |t| {
        const id = @intFromPtr(t.context);
        try testing.expect(id < 5); // Should be from the first half
        count += 1;
    }
    try testing.expectEqual(@as(usize, 5), count);

    // Verify Owner keeps the *newest* tasks (5..9)
    count = 0;
    while (owner_q.pop()) |t| {
        const id = @intFromPtr(t.context);
        try testing.expect(id >= 5);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 5), count);
}

// -------------------------------------------------------------------------
// 3. The "Torture Test" (Concurrency)
// -------------------------------------------------------------------------
// Scenario:
// 1 Owner thread pushing items and randomly popping some.
// N Thief threads constantly trying to steal.
// Goal: Ensure every Item pushed is processed exactly ONCE.

const TOTAL_ITEMS = 100_000;
const THIEF_COUNT = 4;

var processed_mask: [TOTAL_ITEMS]std.atomic.Value(bool) = undefined;
var torture_tasks: [TOTAL_ITEMS]*Task = undefined;

fn markProcessed(t: *Task) void {
    const id = @intFromPtr(t.context);
    // atomic swap. If it returns true, we double-processed!
    if (processed_mask[id].swap(true, .seq_cst)) {
        std.debug.panic("Duplicate processing of Task {d}!", .{id});
    }
}

fn thiefWorker(my_q: *RunQueue, victim_q: *RunQueue, done: *std.atomic.Value(bool)) void {
    while (!done.load(.monotonic) or victim_q.len() > 0) {
        // 1. Try to process my own tasks
        while (my_q.pop()) |t| {
            markProcessed(t);
        }

        // 2. Try to steal
        _ = my_q.tryStealFrom(victim_q, std.heap.c_allocator);

        // Yield to let others run
        std.Thread.yield() catch {};
    }

    // Cleanup any leftovers
    while (my_q.pop()) |t| markProcessed(t);
}

test "RunQueue: Concurrent Thieves" {
    // Initialize Mask
    for (0..TOTAL_ITEMS) |i| processed_mask[i] = std.atomic.Value(bool).init(false);

    // Pre-allocate tasks to avoid allocator noise during test
    for (0..TOTAL_ITEMS) |i| torture_tasks[i] = createTask(i);
    defer for (torture_tasks) |t| destroyTask(t);

    var owner_q = RunQueue.initWithAllocator(std.testing.allocator) catch unreachable;
    defer owner_q.deinit();
    var thief_queues: [THIEF_COUNT]RunQueue = undefined;

    var done_flag = std.atomic.Value(bool).init(false);

    for (0..THIEF_COUNT) |i| thief_queues[i] = RunQueue.initWithAllocator(std.testing.allocator) catch unreachable;
    defer for (&thief_queues) |*tq| tq.deinit();

    // Spawn Thieves
    var threads: [THIEF_COUNT]std.Thread = undefined;
    for (0..THIEF_COUNT) |i| {
        threads[i] = try std.Thread.spawn(.{}, thiefWorker, .{
            &thief_queues[i],
            &owner_q,
            &done_flag,
        });
    }

    // Owner Loop
    var rng = std.Random.DefaultPrng.init(0x12345678);
    const random = rng.random();

    for (0..TOTAL_ITEMS) |i| {
        try owner_q.push(std.testing.allocator, torture_tasks[i]);

        // Randomly process one myself (simulate mixed load)
        if (random.boolean()) {
            if (owner_q.pop()) |t| {
                markProcessed(t);
            }
        }
    }

    // Signal Done
    done_flag.store(true, .seq_cst);

    // Owner clean up his own queue
    while (owner_q.pop()) |t| markProcessed(t);

    // Join
    for (threads) |t| t.join();

    // VERIFICATION
    for (0..TOTAL_ITEMS) |i| {
        if (!processed_mask[i].load(.seq_cst)) {
            std.debug.panic("Task {d} was NEVER processed! (Lost update)", .{i});
        }
    }
}

test "RunQueue: Steal when thief is full" {
    // When the thief queue is full, tryStealFrom steals one item from the victim
    // (via stealOne), then push fails (queue full), so it breaks and returns 0.
    // NOTE: This is a known task-loss edge case — the stolen task is dropped.
    // Tracked for v0.2 fix (should put back on victim or use overflow list).
    var owner_q = RunQueue.initWithAllocator(std.testing.allocator) catch unreachable;
    defer owner_q.deinit();
    var thief_q = RunQueue.initWithAllocator(std.testing.allocator) catch unreachable;
    defer thief_q.deinit();

    // With growable deque, push never fails — buffer doubles. Push 128 items
    // to trigger multiple grows, then verify steal still works.
    var dummies: [128]*Task = undefined;
    for (0..128) |i| dummies[i] = createTask(i);
    defer for (dummies) |d| destroyTask(d);
    for (dummies) |d| try thief_q.push(std.testing.allocator, d);

    const t_steal = createTask(999);
    defer destroyTask(t_steal);
    try owner_q.push(std.testing.allocator, t_steal);

    const stolen = thief_q.tryStealFrom(&owner_q, std.testing.allocator);
    try testing.expectEqual(@as(usize, 1), stolen);
}

test "RunQueue: Index Wrapping Behavior" {
    var q = RunQueue.initWithAllocator(std.testing.allocator) catch unreachable;
    defer q.deinit();

    // 1. Force near overflow
    const near_max = std.math.maxInt(u32) - 1;
    q.top.store(near_max, .seq_cst);
    q.bottom.store(near_max, .seq_cst);

    const t1 = createTask(1);
    defer destroyTask(t1);

    // 2. Push (bottom: MAX-1 -> MAX)
    try q.push(std.testing.allocator, t1);

    const t2 = createTask(2);
    defer destroyTask(t2);

    // 3. Push (bottom: MAX -> 0)
    try q.push(std.testing.allocator, t2);

    // 4. Verify Len (Should be 2)
    try testing.expectEqual(@as(usize, 2), q.len());

    // 5. Pop Verify
    // LIFO Order: t2, then t1
    try testing.expectEqual(t2, q.pop().?);
    try testing.expectEqual(t1, q.pop().?);
    try testing.expect(q.pop() == null);
}

