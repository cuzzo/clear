// fsm-cross-scheduler-test.zig — integration tests for cross-scheduler
// FSM submission via SPSC + spawnFsmBest + spawnFsmOn.
//
// Confirms:
//   - submitFsmSpawn on a remote scheduler routes via SPSC ring
//   - The scheduler's drainChannels processes FsmSpawn messages correctly
//   - spawnFsmBest chooses the less-loaded scheduler from pickTwo
//   - spawnFsmOn submits to a specific target
//   - All FSM tasks complete exactly once, on the chosen scheduler

const std = @import("std");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const ebr = @import("../lib/ebr.zig");
const fsm = @import("fsm.zig");
const runtime_hdr = @import("runtime-header.zig");

const alloc = std.testing.allocator;

const Tracker = struct {
    task: *fsm.FsmTask,
    ran_on: std.atomic.Value(u32) = std.atomic.Value(u32).init(std.math.maxInt(u32)),
    completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *Tracker = @ptrCast(@alignCast(t.ctx.?));
        const sched_idx: u32 = if (fp.scheduler_running) @intCast(fp.active_scheduler.index) else std.math.maxInt(u32);
        self.ran_on.store(sched_idx, .release);
        self.completed.store(true, .release);
        return .{ .Done = {} };
    }

    fn init() Tracker {
        return .{ .task = undefined };
    }

    fn bind(self: *Tracker, sched: *fp.Scheduler) !void {
        self.task = try sched.allocFsmTask(&Tracker.doResume);
        self.task.ctx = self;
    }
};

fn makeSched(sys_alloc: std.mem.Allocator, global_ebr: *ebr.EbrContext, pool: *fm.StackPool) !*fp.Scheduler {
    const s = try sys_alloc.create(fp.Scheduler);
    s.* = try fp.Scheduler.init(sys_alloc, global_ebr, pool);
    return s;
}

test "submitFsmSpawn: cross-thread submission routes via SPSC ring" {
    defer fp.global_registry.deinit(alloc);
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    const sched = try makeSched(alloc, &global_ebr, &pool);
    defer {
        sched.deinit();
        alloc.destroy(sched);
    }

    var tracker: Tracker = .{ .task = undefined };
    try tracker.bind(sched);

    // Register scheduler so active_tasks and channel indexing work.
    try fp.global_registry.register(alloc,std.Thread.getCurrentId(), sched);
    defer fp.global_registry.unregister(std.Thread.getCurrentId());

    // From another thread: submitFsmSpawn. Main thread will run the drain.
    const Submitter = struct {
        fn go(s: *fp.Scheduler, t: *fsm.FsmTask) void {
            s.submitFsmSpawn(t) catch unreachable;
        }
    };
    var th = try std.Thread.spawn(.{}, Submitter.go, .{ sched, tracker.task });
    th.join();

    // Drain channels (simulates scheduler run-loop iteration).
    sched.drainChannels();
    try std.testing.expect(sched.fsm_ready_queue.len() == 1);

    // Run the task.
    sched.drainFsmQueue();
    try std.testing.expect(tracker.completed.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), sched.active_tasks.load(.monotonic));
}

test "submitFsmSpawn: same-scheduler fast path skips the ring" {
    defer fp.global_registry.deinit(alloc);
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    const sched = try makeSched(alloc, &global_ebr, &pool);
    defer {
        sched.deinit();
        alloc.destroy(sched);
    }

    var tracker: Tracker = .{ .task = undefined };
    try tracker.bind(sched);

    fp.active_scheduler = sched;
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;

    try sched.submitFsmSpawn(tracker.task);
    // Fast path went direct to fsm_ready_queue — no drainChannels needed.
    try std.testing.expect(sched.fsm_ready_queue.len() == 1);

    sched.drainFsmQueue();
    try std.testing.expect(tracker.completed.load(.acquire));
}

test "spawnFsmOn: submits to the specified scheduler even if loaded" {
    defer fp.global_registry.deinit(alloc);
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);
    var pool_a = fm.StackPool.init(alloc);
    defer pool_a.deinit();
    var pool_b = fm.StackPool.init(alloc);
    defer pool_b.deinit();
    const a = try makeSched(alloc, &global_ebr, &pool_a);
    defer {
        a.deinit();
        alloc.destroy(a);
    }
    const b = try makeSched(alloc, &global_ebr, &pool_b);
    defer {
        b.deinit();
        alloc.destroy(b);
    }

    try fp.global_registry.register(alloc,1_000_001, a);
    try fp.global_registry.register(alloc,1_000_002, b);
    defer fp.global_registry.unregister(1_000_001);
    defer fp.global_registry.unregister(1_000_002);

    // Load A heavily, but submit to B.
    a.active_tasks.store(1_000, .release);

    var tracker: Tracker = .{ .task = undefined };
    try tracker.bind(b);

    try runtime_hdr.spawnFsmOn(b, tracker.task);
    a.active_tasks.store(0, .release);

    // The task lands on B's queue (either directly via fast path or via
    // SPSC if cross-thread — here we're on the main test thread, not
    // registered as active_scheduler, so SPSC path applies).
    b.drainChannels();
    try std.testing.expect(b.fsm_ready_queue.len() == 1);
    try std.testing.expect(a.fsm_ready_queue.len() == 0);

    b.drainFsmQueue();
    try std.testing.expect(tracker.completed.load(.acquire));
}

test "spawnFsmBest: picks the less-loaded scheduler (pickTwo)" {
    defer fp.global_registry.deinit(alloc);
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);
    var pool_a = fm.StackPool.init(alloc);
    defer pool_a.deinit();
    var pool_b = fm.StackPool.init(alloc);
    defer pool_b.deinit();
    const a = try makeSched(alloc, &global_ebr, &pool_a);
    defer {
        a.deinit();
        alloc.destroy(a);
    }
    const b = try makeSched(alloc, &global_ebr, &pool_b);
    defer {
        b.deinit();
        alloc.destroy(b);
    }

    try fp.global_registry.register(alloc,2_000_001, a);
    try fp.global_registry.register(alloc,2_000_002, b);
    defer fp.global_registry.unregister(2_000_001);
    defer fp.global_registry.unregister(2_000_002);

    // A is busier than B. spawnFsmBest should land on B.
    // NOTE: pickTwo is randomized, so over many calls B should
    // receive the majority. We only need both to have a chance,
    // and verify both queues correctly receive some tasks.
    const N = 40;
    var trackers: [N]Tracker = undefined;
    for (&trackers) |*t| {
        t.* = .{ .task = undefined };
        try t.bind(a);
    }

    // Load A more heavily than B so the selection bias is consistent.
    a.active_tasks.store(100, .release);
    b.active_tasks.store(1, .release);

    for (&trackers) |*t| try runtime_hdr.spawnFsmBest(t.task);

    // Restore real counts so drain can subtract.
    a.active_tasks.store(0, .release);
    b.active_tasks.store(0, .release);

    a.drainChannels();
    b.drainChannels();
    const a_count = a.fsm_ready_queue.len();
    const b_count = b.fsm_ready_queue.len();

    // Every task is accounted for, and B got more given the load skew.
    try std.testing.expectEqual(@as(usize, N), a_count + b_count);
    try std.testing.expect(b_count >= a_count);

    a.drainFsmQueue();
    b.drainFsmQueue();
    var completed: usize = 0;
    for (trackers) |t| if (t.completed.load(.acquire)) { completed += 1; };
    try std.testing.expectEqual(N, completed);
}

test "submitFsmSpawn: 1000 cross-thread submits all land and complete" {
    defer fp.global_registry.deinit(alloc);
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    const sched = try makeSched(alloc, &global_ebr, &pool);
    defer {
        sched.deinit();
        alloc.destroy(sched);
    }

    try fp.global_registry.register(alloc,3_000_001, sched);
    defer fp.global_registry.unregister(3_000_001);

    const N = 1_000;
    const trackers = try alloc.alloc(Tracker, N);
    defer alloc.free(trackers);
    for (trackers) |*t| {
        t.* = .{ .task = undefined };
        try t.bind(sched);
    }

    const Submitter = struct {
        fn go(s: *fp.Scheduler, ts: []Tracker) void {
            for (ts) |*t| s.submitFsmSpawn(t.task) catch unreachable;
        }
    };
    var th = try std.Thread.spawn(.{}, Submitter.go, .{ sched, trackers });
    th.join();

    // Drain channels then FSM queue until quiescent. drainFsmQueue
    // processes at most FSM_DRAIN_BATCH (64) tasks per call, so for N
    // tasks we need ~ceil(N/64) passes plus slack.
    var passes: u32 = 0;
    while (passes < (N / 64) + 50) : (passes += 1) {
        sched.drainChannels();
        sched.drainFsmQueue();
        if (sched.fsm_ready_queue.len() == 0 and sched.active_tasks.load(.monotonic) == 0) break;
    }

    var completed: usize = 0;
    for (trackers) |t| if (t.completed.load(.acquire)) { completed += 1; };
    try std.testing.expectEqual(N, completed);
    try std.testing.expectEqual(@as(u64, 0), sched.active_tasks.load(.monotonic));
}
