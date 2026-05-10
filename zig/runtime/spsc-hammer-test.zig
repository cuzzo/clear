// spsc-hammer-test.zig -- TSan hammer coverage for scheduler SPSC wait loops.

const std = @import("std");
const spsc = @import("spsc.zig");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const fc = @import("fiber-core.zig");
const fsm = @import("fsm.zig");
const qs = @import("queues.zig");
const ebr = @import("../lib/ebr.zig");

const allocator = std.heap.c_allocator;

// HAMMER-COVERS: spsc.push-lock
test "Hammer: SpscRing push lock wait-loop yields under producer contention" {
    const PRODUCERS = 8;
    const PER_PRODUCER = 2_000;
    const Ring = spsc.SpscRing(1024);

    var ring = Ring{};
    var started = std.atomic.Value(usize).init(0);
    var done = std.atomic.Value(usize).init(0);
    var consumed = std.atomic.Value(usize).init(0);

    // Hold the push lock before producer startup so every producer must enter
    // the wait-loop at least once. The rest of the test then drains the ring
    // normally to keep this a real producer/consumer hammer, not just a lock
    // probe.
    try std.testing.expectEqual(@as(u8, 0), ring.push_lock.swap(1, .acquire));

    const Consumer = struct {
        fn run(r: *Ring, done_count: *std.atomic.Value(usize), consumed_count: *std.atomic.Value(usize)) void {
            while (true) {
                if (r.pop()) |_| {
                    _ = consumed_count.fetchAdd(1, .monotonic);
                } else if (done_count.load(.acquire) == PRODUCERS) {
                    while (r.pop()) |_| {
                        _ = consumed_count.fetchAdd(1, .monotonic);
                    }
                    break;
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    };

    const ProducerCtx = struct {
        ring: *Ring,
        started: *std.atomic.Value(usize),
        done: *std.atomic.Value(usize),
        producer_id: usize,

        fn run(ctx: *@This()) void {
            _ = ctx.started.fetchAdd(1, .release);
            for (0..PER_PRODUCER) |i| {
                const value = ctx.producer_id * PER_PRODUCER + i + 1;
                while (!ctx.ring.push(.{ .tag = .Resume, .trampoline_addr = value })) {
                    std.Thread.yield() catch {};
                }
            }
            _ = ctx.done.fetchAdd(1, .release);
        }
    };

    const consumer = try std.Thread.spawn(.{}, Consumer.run, .{ &ring, &done, &consumed });

    var ctxs: [PRODUCERS]ProducerCtx = undefined;
    var producers: [PRODUCERS]std.Thread = undefined;
    for (&ctxs, 0..) |*ctx, i| {
        ctx.* = .{
            .ring = &ring,
            .started = &started,
            .done = &done,
            .producer_id = i,
        };
        producers[i] = try std.Thread.spawn(.{}, ProducerCtx.run, .{ctx});
    }

    while (started.load(.acquire) != PRODUCERS) {
        std.Thread.yield() catch {};
    }

    // Give the producers a scheduling window to block in push() before the
    // lock is released. Under TSan this also increases instrumentation
    // pressure on the wait-loop path this hammer covers.
    for (0..1024) |_| {
        std.Thread.yield() catch {};
    }
    ring.push_lock.store(0, .release);

    for (&producers) |*producer| producer.join();
    consumer.join();

    try std.testing.expectEqual(@as(usize, PRODUCERS * PER_PRODUCER), consumed.load(.acquire));
}

const SubmitKind = enum {
    spawn,
    task_resume,
    fsm_spawn,
    fsm_resume,
    stack_free,
    fsm_ctx_free,
};

const SubmitResult = struct {
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    err: ?anyerror = null,
};

const SchedulerPair = struct {
    owner: fp.Scheduler,
    sender: fp.Scheduler,
};

fn noopTask(_: *anyopaque, _: ?*anyopaque) anyerror!void {}

fn noopFsm(_: *fsm.FsmTask) fsm.YieldReason {
    return .Done;
}

const TinyFsmCtx = extern struct {
    value: u64,
};

const SubmitCtx = struct {
    kind: SubmitKind,
    target: *fp.Scheduler,
    sender: *fp.Scheduler,
    result: *SubmitResult,
    task: *qs.Task,
    fsm_task: *fsm.FsmTask,
    stack: fc.Stack,
    fsm_ctx_task: *fsm.FsmTask,
    fsm_ctx: *TinyFsmCtx,

    fn run(ctx: *@This()) void {
        fp.active_scheduler = ctx.sender;
        fp.scheduler_running = true;
        defer fp.scheduler_running = false;

        ctx.result.started.store(true, .release);
        switch (ctx.kind) {
            .spawn => {
                ctx.target.submitSpawn(
                    @intFromPtr(&noopTask),
                    @as(qs.TaskFn, @ptrCast(&noopTask)),
                    @ptrFromInt(@as(usize, 0x5150_0001)),
                    .{ .stack_size = .Large, .pinned = true },
                ) catch |err| {
                    ctx.result.err = err;
                };
            },
            .task_resume => ctx.target.submitResume(ctx.task),
            .fsm_spawn => {
                ctx.target.submitFsmSpawn(ctx.fsm_task) catch |err| {
                    ctx.result.err = err;
                };
            },
            .fsm_resume => {
                ctx.target.submitFsmResume(ctx.fsm_task) catch |err| {
                    ctx.result.err = err;
                };
            },
            .stack_free => ctx.sender.freeStack(ctx.stack),
            .fsm_ctx_free => ctx.sender.freeFsmCtx(TinyFsmCtx, ctx.fsm_ctx_task, ctx.fsm_ctx),
        }
        ctx.result.finished.store(true, .release);
    }
};

fn fillInboundRing(target: *fp.Scheduler, sender_idx: usize) !*spsc.DefaultRing {
    const ring = try target.ensureChannel(sender_idx);
    for (0..spsc.DefaultRing.capacity) |i| {
        try std.testing.expect(ring.push(.{
            .tag = .RemoteCall,
            .rc_ctx = @ptrFromInt(i + 1),
        }));
    }
    try std.testing.expect(!ring.push(.{ .tag = .RemoteCall, .rc_ctx = @ptrFromInt(@as(usize, 0xdead)) }));
    return ring;
}

fn waitStarted(result: *SubmitResult) !void {
    for (0..10_000) |_| {
        if (result.started.load(.acquire)) return;
        std.Thread.yield() catch {};
    }
    return error.SubmitThreadDidNotStart;
}

fn proveStillBlocked(result: *SubmitResult) !void {
    for (0..1_000) |_| {
        if (result.finished.load(.acquire)) return error.SubmitDidNotBlockOnFullRing;
        std.Thread.yield() catch {};
    }
}

fn setupSchedulers(global_ebr: *ebr.EbrContext, stack_pool: *fm.StackPool) !SchedulerPair {
    var pair = SchedulerPair{
        .owner = try fp.Scheduler.init(allocator, global_ebr, stack_pool),
        .sender = try fp.Scheduler.init(allocator, global_ebr, stack_pool),
    };
    pair.sender.index = 0;
    pair.owner.index = 1;
    return pair;
}

fn expectSubmittedMessage(kind: SubmitKind, msg: spsc.Message, ctx: *SubmitCtx) !void {
    switch (kind) {
        .spawn => {
            try std.testing.expectEqual(spsc.MessageTag.Spawn, msg.tag);
            try std.testing.expectEqual(@intFromPtr(&noopTask), msg.trampoline_addr);
            try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(@as(usize, 0x5150_0001))), msg.args);
        },
        .task_resume => {
            try std.testing.expectEqual(spsc.MessageTag.Resume, msg.tag);
            try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(ctx.task)), msg.task);
            try std.testing.expectEqual(qs.IN_INBOX_IN_QUEUE, ctx.task.in_inbox.load(.acquire));
        },
        .fsm_spawn => {
            try std.testing.expectEqual(spsc.MessageTag.FsmSpawn, msg.tag);
            try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(ctx.fsm_task)), msg.fsm_task);
        },
        .fsm_resume => {
            try std.testing.expectEqual(spsc.MessageTag.FsmResume, msg.tag);
            try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(ctx.fsm_task)), msg.fsm_task);
        },
        .stack_free => {
            try std.testing.expectEqual(spsc.MessageTag.RemoteStackFree, msg.tag);
            try std.testing.expectEqual(@intFromPtr(ctx.stack.memory.ptr), msg.stack_ptr);
            try std.testing.expectEqual(ctx.stack.memory.len, msg.stack_len);
        },
        .fsm_ctx_free => {
            try std.testing.expectEqual(spsc.MessageTag.RemoteFsmCtxFree, msg.tag);
            try std.testing.expectEqual(@intFromPtr(ctx.fsm_ctx), msg.fsm_ctx_ptr);
            try std.testing.expectEqual(@intFromEnum(fsm.FsmCtxAllocClass.slab64), msg.fsm_ctx_class);
            try std.testing.expectEqual(fsm.FsmCtxAllocClass.none, ctx.fsm_ctx_task.ctx_alloc_class);
            try std.testing.expectEqual(@as(?*anyopaque, null), ctx.fsm_ctx_task.ctx);
        },
    }
}

fn runSubmitWaitLoopHammer(kind: SubmitKind) !void {
    var global_ebr = ebr.EbrContext{};
    defer global_ebr.deinit(allocator);
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var scheds = try setupSchedulers(&global_ebr, &stack_pool);
    defer {
        scheds.sender.deinit();
        scheds.owner.deinit();
    }

    const ring = try fillInboundRing(&scheds.owner, scheds.sender.index);

    const dummy_fiber = try allocator.create(fc.Fiber);
    defer allocator.destroy(dummy_fiber);
    dummy_fiber.* = undefined;

    var resume_task = qs.Task{
        .base = dummy_fiber,
        .user_fn = @as(qs.TaskFn, @ptrCast(&noopTask)),
    };
    resume_task.in_inbox.store(qs.IN_INBOX_IDLE, .release);

    var fsm_task = fsm.FsmTask.init(noopFsm);
    const stack = fc.Stack{ .memory = try scheds.owner.allocStack(.Standard), .owner = &scheds.owner };

    var fsm_ctx_task = try scheds.owner.allocFsmTask(noopFsm);
    const fsm_ctx = try scheds.owner.allocFsmCtx(TinyFsmCtx, fsm_ctx_task);
    fsm_ctx.* = .{ .value = 0xfeed_face };
    fsm_ctx_task.ctx = fsm_ctx;

    var result = SubmitResult{};
    var ctx = SubmitCtx{
        .kind = kind,
        .target = &scheds.owner,
        .sender = &scheds.sender,
        .result = &result,
        .task = &resume_task,
        .fsm_task = &fsm_task,
        .stack = stack,
        .fsm_ctx_task = fsm_ctx_task,
        .fsm_ctx = fsm_ctx,
    };

    const producer = try std.Thread.spawn(.{}, SubmitCtx.run, .{&ctx});
    try waitStarted(&result);
    try proveStillBlocked(&result);

    _ = ring.pop() orelse return error.FullRingUnexpectedlyEmpty;

    producer.join();
    if (result.err) |err| return err;
    try std.testing.expect(result.finished.load(.acquire));

    var submitted: ?spsc.Message = null;
    while (ring.pop()) |msg| submitted = msg;
    try expectSubmittedMessage(kind, submitted orelse return error.SubmitMessageMissing, &ctx);

    if (kind == .stack_free) {
        scheds.owner.stack_pool.free(stack.memory);
        ctx.stack.memory = &.{};
    }
    if (kind == .fsm_ctx_free) {
        // The remote-free path only enqueues the ctx-free message in this
        // hammer; free the slot here because we intentionally inspect the
        // message instead of draining it.
        scheds.owner.fsm_ctx_64_slab.destroy(@ptrCast(@alignCast(fsm_ctx)));
    } else {
        // Keep the allocated FSM ctx from leaking in the non-ctx-free cases.
        scheds.owner.freeFsmCtx(TinyFsmCtx, fsm_ctx_task, fsm_ctx);
    }
}

// HAMMER-COVERS: spsc-submit-spawn
test "Hammer: submitSpawn blocks on a full scheduler SPSC ring then delivers exactly one spawn" {
    try runSubmitWaitLoopHammer(.spawn);
}

// HAMMER-COVERS: spsc-submit-resume
test "Hammer: submitResume blocks on a full scheduler SPSC ring then preserves the task wake" {
    try runSubmitWaitLoopHammer(.task_resume);
}

// HAMMER-COVERS: spsc-submit-fsm-spawn
test "Hammer: submitFsmSpawn blocks on a full scheduler SPSC ring then delivers the FSM task" {
    try runSubmitWaitLoopHammer(.fsm_spawn);
}

// HAMMER-COVERS: spsc-submit-fsm-resume
test "Hammer: submitFsmResume blocks on a full scheduler SPSC ring then preserves the FSM wake" {
    try runSubmitWaitLoopHammer(.fsm_resume);
}

// HAMMER-COVERS: spsc-submit-stack-free
test "Hammer: remote stack free blocks on a full scheduler SPSC ring then delivers the stack" {
    try runSubmitWaitLoopHammer(.stack_free);
}

// HAMMER-COVERS: spsc-submit-fsm-ctx-free
test "Hammer: remote FSM ctx free blocks on a full scheduler SPSC ring then delivers the ctx slot" {
    try runSubmitWaitLoopHammer(.fsm_ctx_free);
}
