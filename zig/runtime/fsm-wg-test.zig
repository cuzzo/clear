// FSM Phase B2 — runtime validation of WaitGroup FSM-waiter support.
//
// Proves the protocol that the compiler-side CPS transform will emit:
// an FSM task spawns a child FSM, registers on the child's WaitGroup
// via registerFsmWaiter, returns WaitForLock, and is woken by the
// child's wg.done() via submitFsmResume.
//
// The hand-written state machines here mirror exactly what the
// compiler will generate in Phase B2:
//   - producer: 1-state FSM that writes a result and signals wg.done()
//   - consumer: 2-state FSM that suspends on wg, then reads result

const std = @import("std");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const ebr = @import("../lib/ebr.zig");
const fsm_mod = @import("fsm.zig");
const FsmTask = fsm_mod.FsmTask;
const YieldReason = fsm_mod.YieldReason;
const WaitGroup = fp.WaitGroup;
const Scheduler = fp.Scheduler;

const alloc = std.testing.allocator;

// Promise(i64) inner — mirrors data-structures.zig Promise(T).Inner.
const PromiseInner = struct {
    result: anyerror!i64 = error.BgNotReady,
    wg: WaitGroup,
};

// Producer FSM — writes 42 and signals wg.done().
const ProducerState = struct {
    task: FsmTask,
    inner: *PromiseInner,

    fn resumeFn(t: *FsmTask) YieldReason {
        const self: *@This() = @fieldParentPtr("task", t);
        self.inner.result = 42;
        self.inner.wg.done();
        return .{ .Done = {} };
    }
};

// Consumer FSM — 2-state machine that awaits the producer.
//   step 0: spawn producer, register on producer.inner.wg, yield.
//   step 1: read producer result, write own result, done.
const ConsumerState = struct {
    task: FsmTask,
    inner: *PromiseInner,
    sched: *Scheduler,
    step: u8 = 0,
    child_inner: *PromiseInner,
    producer: *ProducerState,

    fn resumeFn(t: *FsmTask) YieldReason {
        const self: *@This() = @fieldParentPtr("task", t);
        switch (self.step) {
            0 => {
                // Pre-stmts: spawn producer FSM.
                self.child_inner = self.producer.inner;
                self.sched.submitFsmSpawn(&self.producer.task) catch unreachable;

                // Suspend on the child's wg if not yet done.
                if (self.child_inner.wg.registerFsmWaiter(&self.task)) {
                    self.step = 1;
                    return .{ .WaitForLock = {} };
                }
                // Producer raced ahead; fall through to step 1 inline.
                self.step = 1;
            },
            1 => {},
            else => unreachable,
        }
        // Step 1: read child result, compute own result.
        const child_result = self.child_inner.result;
        if (child_result) |val| {
            self.inner.result = val + 1;
        } else |err| {
            self.inner.result = err;
        }
        self.inner.wg.done();
        return .{ .Done = {} };
    }
};

test "FSM-NEXT: consumer awaits producer via WaitGroup, gets result + 1" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &ebr_ctx, &pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.active_scheduler = undefined;
    // Mark scheduler running so submitFsmSpawn takes the same-scheduler
    // fast path (enqueueFsm) instead of the SPSC channel path that needs
    // a separate drainChannels call.
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;

    var producer_inner: PromiseInner = .{ .wg = WaitGroup.init(&sched) };
    producer_inner.wg.add(1);
    var consumer_inner: PromiseInner = .{ .wg = WaitGroup.init(&sched) };
    consumer_inner.wg.add(1);

    var producer: ProducerState = .{ .task = undefined, .inner = &producer_inner };
    producer.task = FsmTask.init(&ProducerState.resumeFn, &producer);

    var consumer: ConsumerState = .{
        .task = undefined,
        .inner = &consumer_inner,
        .sched = &sched,
        .step = 0,
        .child_inner = undefined,
        .producer = &producer,
    };
    consumer.task = FsmTask.init(&ConsumerState.resumeFn, &consumer);

    sched.enqueueFsm(&consumer.task);

    // Drain repeatedly until both promises are settled. drainFsmQueue
    // runs up to FSM_DRAIN_BATCH=64 tasks per call; we need at most a
    // few drains to settle: consumer step 0 → producer → consumer step 1.
    var drains: u8 = 0;
    while ((consumer_inner.wg.counter.load(.seq_cst) != 0 or
            producer_inner.wg.counter.load(.seq_cst) != 0) and drains < 16) : (drains += 1)
    {
        sched.drainFsmQueue();
    }

    try std.testing.expectEqual(@as(usize, 0), producer_inner.wg.counter.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), consumer_inner.wg.counter.load(.seq_cst));
    try std.testing.expectEqual(@as(i64, 43), try consumer_inner.result);
}

test "FSM-NEXT: count==0 inline path when producer wins the race" {
    // Producer finishes BEFORE consumer registers. registerFsmWaiter
    // observes count==0 and returns false; consumer falls through to
    // step 1 inline (no suspend).
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &ebr_ctx, &pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    defer fp.active_scheduler = undefined;

    var producer_inner: PromiseInner = .{ .wg = WaitGroup.init(&sched) };
    producer_inner.wg.add(1);
    var consumer_inner: PromiseInner = .{ .wg = WaitGroup.init(&sched) };
    consumer_inner.wg.add(1);

    var producer: ProducerState = .{ .task = undefined, .inner = &producer_inner };
    producer.task = FsmTask.init(&ProducerState.resumeFn, &producer);

    // Run producer to completion FIRST.
    _ = fsm_mod.dispatchOnce(&producer.task);
    try std.testing.expectEqual(@as(usize, 0), producer_inner.wg.counter.load(.seq_cst));

    // Build consumer pointing at the already-resolved producer.
    var consumer: ConsumerState = .{
        .task = undefined,
        .inner = &consumer_inner,
        .sched = &sched,
        .step = 0,
        .child_inner = undefined,
        .producer = &producer,
    };
    consumer.task = FsmTask.init(&ConsumerState.resumeFn, &consumer);

    // Single dispatch: step 0 spawns (no-op for already-Finished
    // producer), registerFsmWaiter sees count==0 and returns false,
    // resume fn falls through to step 1 and finishes.
    const r1 = fsm_mod.dispatchOnce(&consumer.task);
    try std.testing.expect(r1 == .Done);
    try std.testing.expectEqual(@as(i64, 43), try consumer_inner.result);
}

test "WaitGroup.registerFsmWaiter: returns false when count is already 0" {
    var ebr_ctx: ebr.EbrContext = .{};
    defer ebr_ctx.deinit(alloc);
    var pool = fm.StackPool.init(alloc);
    defer pool.deinit();
    var sched = try fp.Scheduler.init(alloc, &ebr_ctx, &pool);
    defer sched.deinit();

    var wg = WaitGroup.init(&sched);
    var dummy_task: FsmTask = undefined;

    // count = 0 → no need to wait.
    try std.testing.expect(wg.registerFsmWaiter(&dummy_task) == false);

    // count > 0 → registers as waiter.
    wg.add(1);
    try std.testing.expect(wg.registerFsmWaiter(&dummy_task) == true);
    try std.testing.expect(wg.waiting_fsm == &dummy_task);

    // done() at count==1 → wakes via submitFsmResume.
    // For this unit test we just verify the slot is cleared after wake.
    fp.active_scheduler = &sched;
    defer fp.active_scheduler = undefined;
    // Pre-mark the task with a resume fn that does nothing — submitFsmResume
    // will enqueue it on the FSM ready queue but we don't drain.
    dummy_task = FsmTask.init(&struct {
        fn r(_: *FsmTask) YieldReason { return .{ .Done = {} }; }
    }.r, undefined);
    wg.done();
    try std.testing.expect(wg.waiting_fsm == null);
    try std.testing.expect(wg.waiting_task == null);
}
