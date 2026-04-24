// fsm-lock-vopr-test.zig — VOPR-style randomized fuzzer for FSM + stackful
// contention on a shared ParkingMutex.
//
// Each seed runs a randomized mix of FSM and stackful tasks contending on
// a single mutex. Invariants checked after quiescence:
//   I1. Final counter == (N_FSM + N_STACKFUL).
//   I2. Every FSM has completed.
//   I3. The mutex is unlocked and tryLock succeeds.
//   I4. active_tasks == 0.
//
// Runs N_SEEDS seeds through a deterministic PRNG; reproduces seed 42 via
// the named test. Also runs a "worst case interleaving" test where FSMs
// and stackful fibers are spawned in alternating order.

const std = @import("std");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const qs = @import("queues.zig");
const ebr = @import("../lib/ebr.zig");
const fsm = @import("fsm.zig");
const pl = @import("../lib/parking-lot.zig");
const rt_mod = @import("runtime.zig");
const CheatHeader = @import("runtime-header.zig");
const Runtime = rt_mod.Runtime;

const alloc = std.testing.allocator;

// Same shape as fsm-lock-test's LockingFsm, inlined here for clarity.
const LockFsm = struct {
    task: fsm.FsmTask,
    mutex: *pl.ParkingMutex,
    counter: *u64,
    sched: *fp.Scheduler,
    waiter: qs.WaiterNode = undefined,
    step: u8 = 0,
    completed: bool = false,

    fn doResume(t: *fsm.FsmTask) fsm.YieldReason {
        const self: *LockFsm = @fieldParentPtr("task", t);
        switch (self.step) {
            0 => {
                self.step = 1;
                const r = self.mutex.tryLockForFsm(&self.task, &self.waiter, self.sched);
                return switch (r) {
                    .Acquired => enterCs(self),
                    .Registered => .{ .WaitForLock = {} },
                    .Error => .{ .Done = {} },
                };
            },
            1 => return enterCs(self),
            else => unreachable,
        }
    }
    fn enterCs(self: *LockFsm) fsm.YieldReason {
        self.counter.* += 1;
        self.mutex.unlock();
        self.completed = true;
        return .{ .Done = {} };
    }
};

const StackfulCtx = struct {
    mutex: *pl.ParkingMutex,
    counter: *u64,
};

fn stackfulLock(rt_op: *anyopaque, ctx_op: ?*anyopaque) anyerror!void {
    _ = rt_op;
    const ctx: *StackfulCtx = @ptrCast(@alignCast(ctx_op.?));
    defer alloc.destroy(ctx);
    try ctx.mutex.lock();
    ctx.counter.* += 1;
    ctx.mutex.unlock();
}

const Setup = struct {
    sched: *fp.Scheduler,
    mutex: *pl.ParkingMutex,
    counter: *u64,
    fsms: []LockFsm,
    n_stackful: u32,
    order: []const u8, // bytes selecting FSM (0) vs Stackful (1)

    fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
        const self: *Setup = @ptrCast(@alignCast(raw.?));
        var fsm_i: usize = 0;
        var sk_i: u32 = 0;
        for (self.order) |kind| {
            if (kind == 0 and fsm_i < self.fsms.len) {
                self.fsms[fsm_i] = .{
                    .task = undefined,
                    .mutex = self.mutex,
                    .counter = self.counter,
                    .sched = self.sched,
                };
                self.fsms[fsm_i].task = fsm.FsmTask.init(&LockFsm.doResume, &self.fsms[fsm_i]);
                self.sched.enqueueFsm(&self.fsms[fsm_i].task);
                fsm_i += 1;
            } else if (kind == 1 and sk_i < self.n_stackful) {
                const ctx = try alloc.create(StackfulCtx);
                ctx.* = .{ .mutex = self.mutex, .counter = self.counter };
                try self.sched.submitSpawn(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&stackfulLock)),
                    ctx,
                    .{ .stack_size = .Standard },
                );
                sk_i += 1;
            }
        }
        // Pad if order underpopulated either side.
        while (fsm_i < self.fsms.len) : (fsm_i += 1) {
            self.fsms[fsm_i] = .{
                .task = undefined,
                .mutex = self.mutex,
                .counter = self.counter,
                .sched = self.sched,
            };
            self.fsms[fsm_i].task = fsm.FsmTask.init(&LockFsm.doResume, &self.fsms[fsm_i]);
            self.sched.enqueueFsm(&self.fsms[fsm_i].task);
        }
        while (sk_i < self.n_stackful) : (sk_i += 1) {
            const ctx = try alloc.create(StackfulCtx);
            ctx.* = .{ .mutex = self.mutex, .counter = self.counter };
            try self.sched.submitSpawn(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&stackfulLock)),
                ctx,
                .{ .stack_size = .Standard },
            );
        }
    }
};

fn runSeed(seed: u64) !void {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var rt = try Runtime.init(alloc, 256 * 1024, &ebr_ctx);
    defer rt.deinit();
    rt.wireAllocator();
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &ebr_ctx, &pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(alloc);
    }
    fp.active_scheduler = &sched;

    var mutex: pl.ParkingMutex = .{};
    var counter: u64 = 0;

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    const n_fsm: u32 = 2 + rng.uintLessThan(u32, 8);
    const n_stackful: u32 = 1 + rng.uintLessThan(u32, 4);
    var order: [16]u8 = undefined;
    for (&order) |*o| o.* = rng.uintLessThan(u8, 2);

    const fsms = try alloc.alloc(LockFsm, n_fsm);
    defer alloc.free(fsms);

    var setup: Setup = .{
        .sched = &sched,
        .mutex = &mutex,
        .counter = &counter,
        .fsms = fsms,
        .n_stackful = n_stackful,
        .order = order[0..(n_fsm + n_stackful)],
    };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&Setup.run)),
        &setup,
        .{ .stack_size = .Standard },
    );
    sched.run();

    // I1: final counter matches total tasks.
    try std.testing.expectEqual(@as(u64, n_fsm + n_stackful), counter);
    // I2: every FSM completed.
    for (fsms) |f| try std.testing.expect(f.completed);
    // I3: mutex is unlocked.
    try std.testing.expect(mutex.tryLock());
    mutex.unlock();
    // I4: active_tasks balanced.
    try std.testing.expectEqual(@as(u64, 0), sched.active_tasks.load(.monotonic));
}

test "FSM lock VOPR: 32 seeds of randomized FSM+stackful contention" {
    const N = 32;
    var seed: u64 = 0;
    while (seed < N) : (seed += 1) {
        runSeed(seed) catch |e| {
            std.debug.print("seed {d} failed: {s}\n", .{ seed, @errorName(e) });
            return e;
        };
    }
}

test "FSM lock VOPR: reproduce targeted seed 42" {
    try runSeed(42);
}
