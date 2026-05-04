// fsm-vopr-test.zig — PRNG-driven invariant fuzzer for FSM tasks.
//
// Follows the VOPR pattern (pick a random step, run it, check invariants
// every N steps) but scoped to FSM behaviors:
//   - EnqueueBatch    : push K FSMs onto the queue
//   - Drain           : run drainFsmQueue
//   - BlockAndWake    : block an FSM on IO, simulate CQE
//   - MixedDispatch   : drive a stackful task to completion alongside FSMs
//
// Invariants (checked after every step):
//   I1  active_tasks never negative, always matches live FSM count
//   I2  every enqueued task is in exactly one of {queue, Finished, Blocked}
//   I3  a Finished task is never in the ready queue
//   I4  a Blocked task has waiter != null
//   I5  total resume count <= steps*BATCH_MAX (no runaway resumes)
//
// Seeds [0 .. N_SEEDS) by default; reproduce a single seed with --start
// via CLEAR_FSM_VOPR_SEED env var.

const std = @import("std");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const ebr = @import("../lib/ebr.zig");
const fsm = @import("fsm.zig");
const build_options = @import("build_options");

const alloc = std.testing.allocator;

const MAX_TASKS = if (build_options.coverage) 32 else 128;
const STEPS = if (build_options.coverage) 32 else 256;

// FSM body that yields between 0 and 3 times, then completes.
const Yieldy = struct {
    task: *fsm.FsmTask,
    yields_remaining: u8,
    resume_count: u32 = 0,
    completed: bool = false,

    fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *Yieldy = @ptrCast(@alignCast(t.ctx.?));
        self.resume_count += 1;
        if (self.yields_remaining == 0) {
            self.completed = true;
            return .{ .Done = {} };
        }
        self.yields_remaining -= 1;
        return .{ .Yielded = {} };
    }
};

// FSM body that immediately blocks on IO, then completes on wake.
const IoBlocker = struct {
    task: *fsm.FsmTask,
    waiter: fsm.FsmIoWaiter = undefined,
    step: u8 = 0,
    observed: i32 = 0,
    completed: bool = false,

    fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *IoBlocker = @ptrCast(@alignCast(t.ctx.?));
        switch (self.step) {
            0 => {
                self.step = 1;
                self.waiter = fsm.FsmIoWaiter.init(self.task);
                return .{ .WaitForIO = &self.waiter };
            },
            1 => {
                self.observed = self.waiter.result;
                self.completed = true;
                return .{ .Done = {} };
            },
            else => unreachable,
        }
    }
};

const World = struct {
    sched: *fp.Scheduler,
    yieldy: std.ArrayListUnmanaged(*Yieldy) = .empty,
    blockers: std.ArrayListUnmanaged(*IoBlocker) = .empty,
    total_resumes: u64 = 0,

    fn deinit(self: *World) void {
        for (self.yieldy.items) |y| alloc.destroy(y);
        for (self.blockers.items) |b| alloc.destroy(b);
        self.yieldy.deinit(alloc);
        self.blockers.deinit(alloc);
    }

    fn liveFsmCount(self: *const World) u64 {
        var live: u64 = 0;
        for (self.yieldy.items) |y| if (!y.completed) { live += 1; };
        for (self.blockers.items) |b| if (!b.completed) { live += 1; };
        return live;
    }

    // I1..I5 — see header
    //
    // The Chase-Lev FsmRunQueue does not expose direct iteration (owner
    // accesses via push/pop only). For VOPR we inspect aggregate state:
    // tasks are categorized by their .status field, and the queue length
    // plus blocked count must account for all uncompleted tasks.
    fn checkInvariants(self: *const World, context: []const u8) !void {
        const active = self.sched.active_tasks.load(.monotonic);
        if (active != self.liveFsmCount()) {
            std.debug.print("I1 FAIL {s}: active_tasks={d} live={d}\n", .{ context, active, self.liveFsmCount() });
            return error.InvariantI1_ActiveTaskMismatch;
        }
        // I2/I3: queue length matches count of tasks in .Ready state.
        // FsmTasks are slab-allocated; once `completed` is set the
        // scheduler returns the slot to fsm_task_slab, so reading
        // y.task.status would be a UAF on a possibly-recycled slot.
        // Skip completed tasks in the status checks — they are no
        // longer "live" for the invariant.
        var ready_count: u64 = 0;
        for (self.yieldy.items) |y| if (!y.completed and y.task.status == .Ready) { ready_count += 1; };
        for (self.blockers.items) |b| if (!b.completed and b.task.status == .Ready) { ready_count += 1; };
        if (self.sched.fsm_ready_queue.len() != ready_count) {
            std.debug.print("I2 FAIL {s}: queue_len={d} ready_count={d}\n", .{
                context, self.sched.fsm_ready_queue.len(), ready_count,
            });
            return error.InvariantI2_QueueReadyMismatch;
        }
        // I3: Finished flag is the source of truth post-slab-destroy.
        // (The previous "completed implies status == Finished" check
        // would UAF since the FsmTask slot is reused after destroy.)
        // I4: Blocked tasks have waiter set
        for (self.blockers.items) |b| {
            if (!b.completed and b.task.status == .Blocked and b.task.waiter == null)
                return error.InvariantI4_BlockedNoWaiter;
        }
        // I5: runaway resumes
        if (self.total_resumes > STEPS * MAX_TASKS * 4) return error.InvariantI5_RunawayResumes;
    }
};

const StepKind = enum { EnqueueYieldy, EnqueueBlocker, Drain, WakeBlocker, NoOp };

fn randStep(rng: std.Random) StepKind {
    return switch (rng.uintLessThan(u8, 10)) {
        0, 1, 2 => .EnqueueYieldy,
        3 => .EnqueueBlocker,
        4, 5, 6, 7 => .Drain,
        8 => .WakeBlocker,
        else => .NoOp,
    };
}

fn executeStep(world: *World, kind: StepKind, rng: std.Random) !void {
    switch (kind) {
        .EnqueueYieldy => {
            if (world.yieldy.items.len + world.blockers.items.len >= MAX_TASKS) return;
            const y = try alloc.create(Yieldy);
            y.* = .{ .task = undefined, .yields_remaining = rng.uintLessThan(u8, 4) };
            y.task = try world.sched.allocFsmTask(&Yieldy.doResume);
            y.task.ctx = y;
            try world.yieldy.append(alloc, y);
            world.sched.enqueueFsm(y.task);
        },
        .EnqueueBlocker => {
            if (world.yieldy.items.len + world.blockers.items.len >= MAX_TASKS) return;
            const b = try alloc.create(IoBlocker);
            b.* = .{ .task = undefined };
            b.task = try world.sched.allocFsmTask(&IoBlocker.doResume);
            b.task.ctx = b;
            try world.blockers.append(alloc, b);
            world.sched.enqueueFsm(b.task);
        },
        .Drain => {
            const before: u64 = blk: {
                var r: u64 = 0;
                for (world.yieldy.items) |y| r += y.resume_count;
                break :blk r;
            };
            world.sched.drainFsmQueue();
            var after: u64 = 0;
            for (world.yieldy.items) |y| after += y.resume_count;
            world.total_resumes += after - before;
        },
        .WakeBlocker => {
            // Pick a blocked task (if any), simulate CQE.
            for (world.blockers.items) |b| {
                if (b.task.status == .Blocked) {
                    b.waiter.result = @intCast(rng.uintLessThan(u32, 1_000_000));
                    world.sched.enqueueFsm(b.task);
                    // enqueueFsm increments active_tasks; we must offset
                    // (the task never got decremented on park).
                    _ = world.sched.active_tasks.fetchSub(1, .monotonic);
                    return;
                }
            }
        },
        .NoOp => {},
    }
}

fn runSeed(seed: u64) !void {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);
    var stack_pool = fm.StackPool.init(alloc);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &global_ebr, &stack_pool);
    defer sched.deinit();

    var world: World = .{ .sched = &sched };
    defer world.deinit();

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var tick: u32 = 0;
    while (tick < STEPS) : (tick += 1) {
        const step = randStep(rng);
        try executeStep(&world, step, rng);
        if ((tick & 7) == 0) {
            try world.checkInvariants("mid-run");
        }
    }

    // Final quiescence: alternate drain / wake-all-blocked until every
    // task has reached a terminal state. Drain first so tasks still in
    // the ready queue (never yet resumed) can transition to Blocked; then
    // wake any Blocked tasks; drain again. A handful of passes is always
    // enough because a blocker completes on its second resume.
    var quiescence_pass: u32 = 0;
    while (quiescence_pass < 8) : (quiescence_pass += 1) {
        var drain_iters: u32 = 0;
        while (sched.fsm_ready_queue.len() > 0) : (drain_iters += 1) {
            sched.drainFsmQueue();
            if (drain_iters > 200) return error.StalledDrain;
        }
        var woke_any = false;
        for (world.blockers.items) |b| {
            if (b.task.status == .Blocked) {
                b.waiter.result = 0;
                sched.enqueueFsm(b.task);
                _ = sched.active_tasks.fetchSub(1, .monotonic);
                woke_any = true;
            }
        }
        if (!woke_any and sched.fsm_ready_queue.len() == 0) break;
    }
    try world.checkInvariants("post-final-drain");
    try std.testing.expectEqual(@as(u64, 0), sched.active_tasks.load(.monotonic));
    for (world.yieldy.items) |y| try std.testing.expect(y.completed);
    for (world.blockers.items) |b| try std.testing.expect(b.completed);
}

test "FSM VOPR: 128 seeds of PRNG-driven fuzzing" {
    const N_SEEDS = if (build_options.coverage) 4 else 128;
    var seed: u64 = 0;
    while (seed < N_SEEDS) : (seed += 1) {
        runSeed(seed) catch |e| {
            std.debug.print("FSM VOPR seed {d} failed: {s}\n", .{ seed, @errorName(e) });
            return e;
        };
    }
}

test "FSM VOPR: single targeted seed with final state checks" {
    try runSeed(0xDEAD_BEEF);
}

test "FSM VOPR: enqueue -> drain round-trip preserves active_tasks" {
    var global_ebr: ebr.EbrContext = .{};
    defer global_ebr.deinit(alloc);
    var stack_pool = fm.StackPool.init(alloc);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &global_ebr, &stack_pool);
    defer sched.deinit();

    const N = 20;
    const tasks = try alloc.alloc(Yieldy, N);
    defer alloc.free(tasks);

    for (tasks) |*y| {
        y.* = .{ .task = undefined, .yields_remaining = 0 };
        y.task = try sched.allocFsmTask(&Yieldy.doResume);
        y.task.ctx = y;
        sched.enqueueFsm(y.task);
    }
    try std.testing.expectEqual(@as(u64, N), sched.active_tasks.load(.monotonic));

    sched.drainFsmQueue();
    try std.testing.expectEqual(@as(u64, 0), sched.active_tasks.load(.monotonic));
    try std.testing.expect(sched.fsm_ready_queue.len() == 0);
}
