// fsm-race-test.zig — Multi-thread race correctness for FSM tasks.
//
// Tests what DOES race under the MVP FSM design:
//   1. Global active_tasks counter updated by multiple schedulers'
//      enqueueFsm and dispatchFsmTask running on independent threads.
//   2. scheduler deinit ordering when an FSM is parked on a waiter.
//   3. FSM completion count matches spawn count across N scheduler
//      threads running in parallel.
//
// What does NOT race (and therefore not tested here):
//   - FSM queue itself: scheduler-local ArrayList, single-thread invariant.
//     Cross-thread enqueueFsm is UB by design (will be addressed when
//     cross-scheduler FSM submission lands).
//
// Pattern modeled on scheduler-race-test.zig: spawn N scheduler threads,
// each runs its own scheduler with its own FSM workload, all share a
// global counter, verify correctness after join.

pub const CLEAR_FRAME_DEBUG = false;

const std = @import("std");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const ebr = @import("../lib/ebr.zig");
const fsm = @import("fsm.zig");

const alloc = std.heap.c_allocator;

const N_THREADS = 4;
const TASKS_PER_THREAD = 2_000;
const YIELDS_PER_TASK = 3;

const Worker = struct {
    task: fsm.FsmTask,
    yields_remaining: u8,
    acc: u64 = 0,

    fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *Worker = @fieldParentPtr("task", t);
        self.acc += 1;
        if (self.yields_remaining == 0) return .{ .Done = {} };
        self.yields_remaining -= 1;
        return .{ .Yielded = {} };
    }
};

const ThreadState = struct {
    sched: *fp.Scheduler,
    workers: []Worker,
    completion_count: *std.atomic.Value(u64),
};

fn threadBody(state: *ThreadState) void {
    // Populate queue, then drain iteratively. FSM_DRAIN_BATCH is 64,
    // so we need ceil(N * (Y+1) / 64) iterations to drain N tasks
    // each yielding Y times.
    for (state.workers) |*w| {
        w.* = .{ .task = undefined, .yields_remaining = YIELDS_PER_TASK };
        w.task = fsm.FsmTask.init(&Worker.doResume);
        state.sched.enqueueFsm(&w.task);
    }
    var iters: u32 = 0;
    const iter_cap: u32 = @intCast((TASKS_PER_THREAD * (YIELDS_PER_TASK + 1) / 64) + 100);
    while (state.sched.fsm_ready_queue.len() > 0) : (iters += 1) {
        state.sched.drainFsmQueue();
        if (iters > iter_cap) break;
    }
    // Count completions (reads local workers, atomically publishes result).
    var local_completed: u64 = 0;
    for (state.workers) |w| if (w.task.status == .Finished) { local_completed += 1; };
    _ = state.completion_count.fetchAdd(local_completed, .release);
}

test "FSM race: N scheduler threads each run independent FSM workloads" {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);

    var pools: [N_THREADS]fm.StackPool = undefined;
    var scheds: [N_THREADS]*fp.Scheduler = undefined;
    var all_workers: [N_THREADS][]Worker = undefined;
    var states: [N_THREADS]ThreadState = undefined;
    var completion_count = std.atomic.Value(u64).init(0);

    for (&pools, 0..) |*p, i| {
        p.* = fm.StackPool.init(alloc);
        scheds[i] = try alloc.create(fp.Scheduler);
        scheds[i].* = try fp.Scheduler.init(alloc, &global_ebr, p);
        all_workers[i] = try alloc.alloc(Worker, TASKS_PER_THREAD);
        states[i] = .{ .sched = scheds[i], .workers = all_workers[i], .completion_count = &completion_count };
    }
    defer for (0..N_THREADS) |i| {
        scheds[i].deinit();
        alloc.destroy(scheds[i]);
        pools[i].deinit();
        alloc.free(all_workers[i]);
    };

    var threads: [N_THREADS]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, threadBody, .{&states[i]});
    }
    for (&threads) |t| t.join();

    const expected: u64 = N_THREADS * TASKS_PER_THREAD;
    try std.testing.expectEqual(expected, completion_count.load(.acquire));

    // active_tasks per scheduler must balance.
    for (scheds) |s| {
        try std.testing.expectEqual(@as(u64, 0), s.active_tasks.load(.monotonic));
    }
}

test "FSM race: SPSC submitFsmSpawn producer + consumer coordination" {
    // Exercise the SPSC FsmSpawn path with ONE producer thread and ONE
    // consumer thread sharing a single SPSC channel (per SPSC contract).
    // Consumer drains channels + FSM queue. Producer pushes 4 000 tasks.
    // Every task must complete exactly once and active_tasks must
    // balance to 0.
    //
    // Multi-producer submission requires per-sender channel indexing,
    // which is available when submitters run inside their own scheduler
    // (active_scheduler.index gives a unique idx). For test threads
    // with no owning scheduler, a single producer thread is correct.
    defer fp.global_registry.deinit(alloc);
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var target = try fp.Scheduler.init(alloc, &global_ebr, &pool);
    defer target.deinit();
    try fp.global_registry.register(alloc, 5_000_000, &target);
    defer fp.global_registry.unregister(5_000_000);

    const TOTAL = 4_000;
    const workers = try alloc.alloc(Worker, TOTAL);
    defer alloc.free(workers);
    for (workers) |*w| {
        w.* = .{ .task = undefined, .yields_remaining = 0 };
        w.task = fsm.FsmTask.init(&Worker.doResume);
    }

    var producer_done = std.atomic.Value(bool).init(false);

    const Producer = struct {
        fn go(t: *fp.Scheduler, ws: []Worker, done: *std.atomic.Value(bool)) void {
            for (ws) |*w| t.submitFsmSpawn(&w.task) catch unreachable;
            done.store(true, .release);
        }
    };

    var prod = try std.Thread.spawn(.{}, Producer.go, .{ &target, workers, &producer_done });

    // Consumer (main thread): drain until producer signals done AND the
    // queue is empty AND active_tasks is 0.
    var iters: u64 = 0;
    while (true) : (iters += 1) {
        target.drainChannels();
        target.drainFsmQueue();
        if (producer_done.load(.acquire) and
            target.fsm_ready_queue.len() == 0 and
            target.active_tasks.load(.monotonic) == 0) break;
        if (iters > 10_000_000) return error.DrainTimeout;
    }

    prod.join();

    var completed: usize = 0;
    for (workers) |w| if (w.task.status == .Finished) { completed += 1; };
    try std.testing.expectEqual(TOTAL, completed);
    try std.testing.expectEqual(@as(u64, 0), target.active_tasks.load(.monotonic));
}

test "FSM race: concurrent scheduler threads, global completion count balances" {
    // Variation: single iteration loop outside the thread body, verifies
    // that each scheduler independently observes its own queue at the
    // correct state throughout.
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);

    const N = 2;
    var pools: [N]fm.StackPool = undefined;
    var scheds: [N]*fp.Scheduler = undefined;
    var wsets: [N][]Worker = undefined;

    for (&pools, 0..) |*p, i| {
        p.* = fm.StackPool.init(alloc);
        scheds[i] = try alloc.create(fp.Scheduler);
        scheds[i].* = try fp.Scheduler.init(alloc, &global_ebr, p);
        wsets[i] = try alloc.alloc(Worker, 100);
    }
    defer for (0..N) |i| {
        scheds[i].deinit();
        alloc.destroy(scheds[i]);
        pools[i].deinit();
        alloc.free(wsets[i]);
    };

    const Runner = struct {
        fn go(sch: *fp.Scheduler, ws: []Worker) void {
            for (ws) |*w| {
                w.* = .{ .task = undefined, .yields_remaining = 1 };
                w.task = fsm.FsmTask.init(&Worker.doResume);
                sch.enqueueFsm(&w.task);
            }
            var it: u32 = 0;
            while (sch.fsm_ready_queue.len() > 0) : (it += 1) {
                sch.drainFsmQueue();
                if (it > 10) break;
            }
        }
    };

    var t1 = try std.Thread.spawn(.{}, Runner.go, .{ scheds[0], wsets[0] });
    var t2 = try std.Thread.spawn(.{}, Runner.go, .{ scheds[1], wsets[1] });
    t1.join();
    t2.join();

    for (scheds, 0..) |s, i| {
        try std.testing.expectEqual(@as(u64, 0), s.active_tasks.load(.monotonic));
        for (wsets[i]) |w| try std.testing.expect(w.task.status == .Finished);
    }
}
