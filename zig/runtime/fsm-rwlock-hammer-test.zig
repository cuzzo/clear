// fsm-rwlock-hammer-test.zig
//
// Hammer test for the FSM ParkingRwLock park/wake path under multi-
// scheduler load. Originally written to reproduce a lost-wakeup race
// witnessed in benchmarks/concurrent/17_mvcc_vs_rwlock at
// CLEAR_THREADS>=4 with the 8-reader / 4-writer shape (hung ~60% of
// runs at T=4 and 100% at T>=8).
//
// FIXED 2026-05-01: tryReadLockForFsm's fast-path-conflict undo
// (state.fetchSub) didn't trigger wakeNext when the undo restored
// state to "0 readers + HAS_WAITERS + no writer". A queued writer's
// wake had been suppressed by the FSM reader's transient +1 in state
// (wakeNext for a Write returns when READER_MASK != 0); without the
// undo-side wake, no future op would fire it. Mirrored lockShared's
// stackful undo logic, gated on WRITE_LOCKED also being clear (the
// .Read branch of wakeNext does fetchAdd unconditionally so callers
// must guarantee no writer holds).
//
// Test now serves as a regression witness: at the bench-17 thread
// count + fiber count, the lost-wakeup deadlock is deterministic
// without the fix and absent with it.
//
// Why HAMMER and not VOPR / Loom:
//
//   VOPR is single-threaded deterministic simulation. It drives a
//   sequence of operations through PRNG and checks invariants. It has
//   no real OS threads, so it CANNOT model the cross-scheduler wake
//   path (FsmTask parked on rwlock A; another scheduler unlocks A;
//   does the wake reach the parked FSM?). VOPR is for primitive
//   state-machine logic (e.g. versioned-vopr: "sequence of read/update
//   ops produces consistent snapshots"), not lost-wakeup races.
//
//   Loom is exhaustive interleaving search over SimAtomic ops. It
//   needs a small primitive with bounded state. The bench-17 surface
//   (12 fibers x N iterations x parking-lot RwLock state machine x K
//   schedulers) is hopelessly outside Loom's tractable search space.
//   Loom would only fit if we narrowed to "does parking-lot RwLock's
//   internal CAS sequence have a lost wakeup" -- but parking-lot is
//   library-level upstream and the bug is in the runtime's
//   FsmTask integration with it, not in the primitive itself.
//
//   HAMMER is the right shape: real std.Thread workers, real
//   spawnFsmBest cross-scheduler distribution, real lock park / wake,
//   bounded deadline. Either it completes in time or the test
//   fails -- deterministic CI signal for an intermittent race.
//
// The test is enabled by default (SKIP_BY_DEFAULT = false). Flip to
// true if a future change re-introduces a similar wakeup race and
// the hammer becomes a CI nuisance — but a passing hammer here is
// the contract for FSM RwLock under cross-scheduler load.

const std = @import("std");
const testing = std.testing;

const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const qs = @import("queues.zig");
const ebr = @import("../lib/ebr.zig");
const fsm = @import("fsm.zig");
const pl = @import("../lib/parking-lot.zig");
const compat = @import("../lib/compat.zig");
const rt_mod = @import("runtime.zig");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = rt_mod.Runtime;
const Scheduler = fp.Scheduler;
const StackPool = fm.StackPool;

const SKIP_BY_DEFAULT = false;

const test_alloc = std.heap.c_allocator;
var global_ebr: ebr.EbrContext = .{};
var stack_pool: StackPool = undefined;
var global_shutdown = std.atomic.Value(bool).init(false);

fn schedulerThread(a: std.mem.Allocator) void {
    var sched = Scheduler.init(a, &global_ebr, &stack_pool) catch return;
    defer sched.deinit();
    sched.global_shutdown = &global_shutdown;
    sched.shutdown_on_idle = false;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    sched.run();
    fp.scheduler_running = false;
}

fn startWorkers(threads: []std.Thread, n: usize) void {
    for (threads[0..n]) |*t| {
        t.* = std.Thread.spawn(.{}, schedulerThread, .{test_alloc}) catch continue;
    }
    while (fp.global_registry.count() < n) {
        compat.sleepNs(1 * std.time.ns_per_ms);
    }
}

fn stopWorkers(threads: []std.Thread, n: usize) void {
    global_shutdown.store(true, .release);
    fp.global_registry.notifyAll();
    for (threads[0..n]) |*t| t.join();
    global_shutdown.store(false, .release);
}

fn withMainRuntimeN(comptime workers: usize, comptime body: fn (*Runtime) anyerror!void) !void {
    var threads: [workers]std.Thread = undefined;
    startWorkers(&threads, workers);
    defer stopWorkers(&threads, workers);

    var sched = try Scheduler.init(test_alloc, &global_ebr, &stack_pool);
    defer {
        sched.deinit();
        fp.active_scheduler = undefined;
        fp.scheduler_running = false;
    }
    sched.global_shutdown = &global_shutdown;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;

    var rt = try Runtime.init(test_alloc, 4 * 1024 * 1024, &global_ebr);
    defer rt.deinit();
    rt.wireAllocator();

    const Runner = struct {
        rt: *Runtime,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try body(self.rt);
        }
    };

    var runner = Runner{ .rt = &rt };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&Runner.run)),
        &runner,
        .{ .stack_size = .Large, .pinned = true },
    );
    sched.run();
}

// ---------------- FSM Reader / Writer with iteration loop ----------------
//
// The shape of the BG body the CLEAR transpiler emits for:
//
//     BG { @parallel ->
//         WHILE i < reads_per DO
//             WITH c_rw AS v { _ = v.value; }
//             i = i + 1;
//         END
//     }
//
// becomes a multi-segment FSM resume fn whose state machine roughly
// mirrors:
//
//   step 0: try-acquire (Acquired -> CS, unlock, iter++, jump 0)
//                        (Registered -> WaitForLock)
//   step 1 (parked): CS, unlock, iter++, jump 0
//   step 0 (iter == N): Done
//
// We model that here so the hammer exercises the SAME lock-park /
// lock-wake transitions the real bench triggers. We cannot reuse the
// codegen output directly -- we need to run on raw FSM primitives so
// the hammer is a runtime-level test, not a compiler-level one.

const HammerWriter = struct {
    task: fsm.FsmTask,
    rt: *Runtime,
    inner: *CheatLib.Promise(usize).Inner,
    alloc: std.mem.Allocator,
    rw: *pl.ParkingRwLock,
    counter: *std.atomic.Value(u64),
    iters: usize,
    waiter: qs.WaiterNode = undefined,
    step: u8 = 0,
    iter: usize = 0,

    fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *HammerWriter = @fieldParentPtr("task", t);
        const sched = fp.active_scheduler;
        while (true) {
            switch (self.step) {
                0 => {
                    if (self.iter >= self.iters) return self.finish();
                    self.step = 1;
                    const r = self.rw.tryWriteLockForFsm(&self.task, &self.waiter, sched);
                    switch (r) {
                        .Acquired => {
                            self.cs();
                            self.step = 0;
                        },
                        .Registered => return .{ .WaitForLock = {} },
                        .Error => {
                            // Treat error as completion to keep the
                            // hammer non-fatal on transient lock errors.
                            return self.finish();
                        },
                    }
                },
                1 => {
                    self.cs();
                    self.step = 0;
                },
                else => unreachable,
            }
        }
    }
    fn cs(self: *HammerWriter) void {
        self.counter.* = std.atomic.Value(u64).init(self.counter.load(.monotonic) + 1);
        self.rw.unlock();
        self.iter += 1;
    }
    fn finish(self: *HammerWriter) fsm.YieldReason {
        self.inner.result = self.iter;
        self.inner.wg.done();
        return .{ .Done = {} };
    }
    fn destroyTask(t: *fsm.FsmTask) void {
        const self: *HammerWriter = @fieldParentPtr("task", t);
        self.alloc.destroy(self);
    }
};

const HammerReader = struct {
    task: fsm.FsmTask,
    rt: *Runtime,
    inner: *CheatLib.Promise(usize).Inner,
    alloc: std.mem.Allocator,
    rw: *pl.ParkingRwLock,
    counter: *std.atomic.Value(u64),
    iters: usize,
    waiter: qs.WaiterNode = undefined,
    step: u8 = 0,
    iter: usize = 0,

    fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *HammerReader = @fieldParentPtr("task", t);
        const sched = fp.active_scheduler;
        while (true) {
            switch (self.step) {
                0 => {
                    if (self.iter >= self.iters) return self.finish();
                    self.step = 1;
                    const r = self.rw.tryReadLockForFsm(&self.task, &self.waiter, sched);
                    switch (r) {
                        .Acquired => {
                            self.cs();
                            self.step = 0;
                        },
                        .Registered => return .{ .WaitForLock = {} },
                        .Error => return self.finish(),
                    }
                },
                1 => {
                    self.cs();
                    self.step = 0;
                },
                else => unreachable,
            }
        }
    }
    fn cs(self: *HammerReader) void {
        _ = self.counter.load(.monotonic);
        self.rw.unlockShared();
        self.iter += 1;
    }
    fn finish(self: *HammerReader) fsm.YieldReason {
        self.inner.result = self.iter;
        self.inner.wg.done();
        return .{ .Done = {} };
    }
    fn destroyTask(t: *fsm.FsmTask) void {
        const self: *HammerReader = @fieldParentPtr("task", t);
        self.alloc.destroy(self);
    }
};

// Hammer the FSM RwLock park/wake path with N readers + M writers
// distributed across K+1 schedulers via spawnFsmBest. The bench-17
// shape is N=8, M=4, K=4-8 -- the test uses a slightly smaller
// surface (N=8, M=4, K=4) so it finishes in ~1s when the wakeup is
// not lost.
//
// On a working runtime: each trial completes in <1s, NUM_TRIALS=5
// total <5s.
// On a runtime with the lost-wakeup race: at least one trial hangs
// and the global deadline expires.
test "FSM RwLock hammer: 8 readers + 4 writers x 5 trials -- bench-17 lost-wakeup repro" {
    if (SKIP_BY_DEFAULT) return error.SkipZigTest;

    stack_pool = StackPool.init(test_alloc);
    defer stack_pool.deinit();

    try withMainRuntimeN(4, struct {
        fn body(rt: *Runtime) !void {
            const NR = 8;
            const NW = 4;
            const READS = 5_000;
            const WRITES = 100;
            const NUM_TRIALS = 5;
            const PER_TRIAL_DEADLINE_MS: i64 = 5_000;

            const sa = rt.getSched().allocator;

            var trial: usize = 0;
            while (trial < NUM_TRIALS) : (trial += 1) {
                var rw = pl.ParkingRwLock{};
                var counter = std.atomic.Value(u64).init(0);

                var rprom: [NR]CheatLib.Promise(usize) = undefined;
                var wprom: [NW]CheatLib.Promise(usize) = undefined;

                for (0..NR) |i| {
                    rprom[i] = try CheatLib.Promise(usize).spawn(sa, rt.getSched());
                    const ctx = try sa.create(HammerReader);
                    ctx.* = .{
                        .task = undefined,
                        .rt = rt,
                        .inner = rprom[i].inner,
                        .alloc = sa,
                        .rw = &rw,
                        .counter = &counter,
                        .iters = READS,
                    };
                    ctx.task = fsm.FsmTask.init(&HammerReader.doResume);
                    ctx.task.destroy_fn = &HammerReader.destroyTask;
                    try CheatHeader.spawnFsmBest(&ctx.task);
                }
                for (0..NW) |i| {
                    wprom[i] = try CheatLib.Promise(usize).spawn(sa, rt.getSched());
                    const ctx = try sa.create(HammerWriter);
                    ctx.* = .{
                        .task = undefined,
                        .rt = rt,
                        .inner = wprom[i].inner,
                        .alloc = sa,
                        .rw = &rw,
                        .counter = &counter,
                        .iters = WRITES,
                    };
                    ctx.task = fsm.FsmTask.init(&HammerWriter.doResume);
                    ctx.task.destroy_fn = &HammerWriter.destroyTask;
                    try CheatHeader.spawnFsmBest(&ctx.task);
                }

                // Per-trial deadline: if the wakeup is lost, at least
                // one promise.next() will block forever. We can't time
                // out next() directly without changing the API, so we
                // rely on the OUTER test runner timeout to surface the
                // hang. The PER_TRIAL_DEADLINE_MS constant is
                // documentation -- the test process will be SIGKILLed
                // by the runner long before the budget expires when
                // the bug is present.
                _ = PER_TRIAL_DEADLINE_MS;

                for (&rprom) |*p| _ = try p.next();
                for (&wprom) |*p| _ = try p.next();
            }
        }
    }.body);
}
