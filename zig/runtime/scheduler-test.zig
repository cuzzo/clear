//! Tests extracted from runtime/scheduler.zig (V33).
//!
//! Pre-V33 these tests + their helpers lived inline at
//! lines 2414-2734 and 2961-3085 of scheduler.zig.

const std = @import("std");
const ebr_mod = @import("../lib/ebr.zig");
const EbrContext = ebr_mod.EbrContext;

const fc = @import("fiber-core.zig");
const Fiber = fc.Fiber;
const Stack = fc.Stack;
const StackSize = fc.StackSize;

const qs = @import("queues.zig");
const Task = qs.Task;

const fsm_mod = @import("fsm.zig");
const YieldReason = fsm_mod.YieldReason;

const fp = @import("scheduler.zig");
const Scheduler = fp.Scheduler;
const SpscMessage = fp.SpscMessage;
const SmartEventFd = fp.SmartEventFd;

const spsc = @import("spsc.zig");

const rt_profile = @import("runtime.zig");

test "migrated stack free routes back to owning scheduler" {
    const alloc = std.testing.allocator;
    var global_ebr: EbrContext = .{};
    defer global_ebr.deinit(alloc);

    var owner = try Scheduler.init(alloc, &global_ebr, null);
    defer owner.deinit();
    owner.index = 0;

    var thief = try Scheduler.init(alloc, &global_ebr, null);
    defer thief.deinit();
    thief.index = 1;

    const memory = try owner.allocStack(.Standard);
    const stack = Stack{ .memory = memory, .owner = &owner };

    fp.active_scheduler = &thief;
    fp.scheduler_running = true;
    defer {
        fp.scheduler_running = false;
        fp.active_scheduler = undefined;
    }

    thief.freeStack(stack);
    try std.testing.expectEqual(@as(usize, 0), thief.stack_cache.items.len);
    try std.testing.expect(owner.dirty_mask.load(.acquire) != 0);

    owner.drainChannels();
    try std.testing.expectEqual(@as(usize, 1), owner.stack_cache.items.len);
}

fn makeDeinitCleanupTask(sched: *Scheduler, size: StackSize) !*Task {
    const memory = try sched.allocStack(size);
    const fiber = try sched.allocator.create(Fiber);
    errdefer sched.allocator.destroy(fiber);
    fiber.* = Fiber.initWithOwner(memory, @intFromPtr(&dummyTaskFn), size, sched);
    const task = try sched.task_slab.create();
    task.* = Task{ .base = fiber, .user_fn = @ptrCast(&dummyTaskFn) };
    return task;
}

test "Scheduler.deinit releases task stacks left in internal queues" {
    const alloc = std.testing.allocator;
    var global_ebr: EbrContext = .{};
    defer global_ebr.deinit(alloc);

    var sched = try Scheduler.init(alloc, &global_ebr, null);
    sched.index = 0;

    try sched.fiber_pool.append(alloc, try makeDeinitCleanupTask(&sched, .Micro));
    try sched.ready_queue.push(alloc, try makeDeinitCleanupTask(&sched, .Micro));
    try sched.pinned_queue.append(alloc, try makeDeinitCleanupTask(&sched, .Micro));

    sched.deinit();
}

test "remote FSM ctx free routes slab128 back to owning scheduler" {
    const alloc = std.testing.allocator;
    var global_ebr: EbrContext = .{};
    defer global_ebr.deinit(alloc);

    var owner = try Scheduler.init(alloc, &global_ebr, null);
    defer owner.deinit();
    owner.index = 0;

    var thief = try Scheduler.init(alloc, &global_ebr, null);
    defer thief.deinit();
    thief.index = 1;

    const task = try owner.allocFsmTask(&dummyFsmResume);
    const ctx = try owner.allocFsmCtx(Scheduler.FsmCtx128, task);

    fp.active_scheduler = &thief;
    fp.scheduler_running = true;
    defer {
        fp.scheduler_running = false;
        fp.active_scheduler = undefined;
    }

    thief.freeFsmCtx(Scheduler.FsmCtx128, task, ctx);
    try std.testing.expect(owner.dirty_mask.load(.acquire) != 0);
    owner.drainChannels();
    owner.fsm_task_slab.destroy(task);
}

test "Scheduler.init cleans up thread EBR on later allocation failures" {
    const backing = std.testing.allocator;

    var fail_after_thread_ebr = std.testing.FailingAllocator.init(backing, .{ .fail_index = 1 });
    var ebr_after_thread: EbrContext = .{};
    try std.testing.expectError(
        error.OutOfMemory,
        Scheduler.init(fail_after_thread_ebr.allocator(), &ebr_after_thread, null),
    );
    defer ebr_after_thread.deinit(backing);

    var fail_after_register = std.testing.FailingAllocator.init(backing, .{ .fail_index = 2 });
    var ebr_after_register: EbrContext = .{};
    try std.testing.expectError(
        error.OutOfMemory,
        Scheduler.init(fail_after_register.allocator(), &ebr_after_register, null),
    );
    defer ebr_after_register.deinit(backing);
    try std.testing.expectEqual(@as(usize, 0), ebr_after_register.registry.items.len);
}

test "drainChannels releases stack memory when spawn allocation steps fail" {
    const backing = std.testing.allocator;

    var offset: usize = 0;
    while (offset < 64) : (offset += 1) {
        var failing = std.testing.FailingAllocator.init(backing, .{});
        const alloc = failing.allocator();
        var global_ebr: EbrContext = .{};
        defer global_ebr.deinit(alloc);

        var sched = try Scheduler.init(alloc, &global_ebr, null);
        defer sched.deinit();
        sched.index = 0;

        try sched.submitSpawn(@intFromPtr(&dummyTaskFn), @ptrCast(&dummyTaskFn), null, .{});
        failing.fail_index = failing.alloc_index + offset;
        sched.drainChannels();
    }

}

fn prewarmSpawnAllocations(sched: *Scheduler) !void {
    const stack_mem = try sched.stack_pool.alloc(.Standard);
    try sched.stack_cache.append(sched.allocator, stack_mem);
    const task = try sched.task_slab.create();
    sched.task_slab.destroy(task);
}

test "drainChannels releases stack memory when pinned queue append fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing.allocator();
    var global_ebr: EbrContext = .{};
    defer global_ebr.deinit(alloc);

    var sched = try Scheduler.init(alloc, &global_ebr, null);
    defer sched.deinit();
    sched.index = 0;
    try prewarmSpawnAllocations(&sched);

    try sched.submitSpawn(
        @intFromPtr(&dummyTaskFn),
        @ptrCast(&dummyTaskFn),
        null,
        .{ .pinned = true },
    );
    failing.fail_index = failing.alloc_index + 1;
    sched.drainChannels();
}

test "drainChannels releases stack memory when ready queue growth fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const alloc = failing.allocator();
    var global_ebr: EbrContext = .{};
    defer global_ebr.deinit(alloc);

    var sched = try Scheduler.init(alloc, &global_ebr, null);
    defer sched.deinit();
    sched.index = 0;
    try prewarmSpawnAllocations(&sched);

    var i: usize = 0;
    while (i < 64) : (i += 1) {
        try sched.ready_queue.push(alloc, try makeDeinitCleanupTask(&sched, .Micro));
    }

    try sched.submitSpawn(@intFromPtr(&dummyTaskFn), @ptrCast(&dummyTaskFn), null, .{});
    failing.fail_index = failing.alloc_index + 1;
    sched.drainChannels();
}

fn finishWhileRegisteredAsLockWaiter(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
    const sched: *Scheduler = @ptrCast(@alignCast(raw.?));
    sched.registerLockWaiter(sched.getCurrent());
}

test "Scheduler.run removes finished tasks from lock waiter scan list" {
    const alloc = std.heap.smp_allocator;
    var global_ebr: EbrContext = .{};
    defer global_ebr.deinit(alloc);

    var sched = try Scheduler.init(alloc, &global_ebr, null);
    defer sched.deinit();
    sched.index = 0;

    try sched.submitSpawn(
        @intFromPtr(&rt_profile.Runtime.entryWrapper),
        @ptrCast(&finishWhileRegisteredAsLockWaiter),
        &sched,
        .{},
    );
    sched.run();

    try std.testing.expectEqual(@as(usize, 0), sched.lock_waiters.items.len);
}

const RemoteFreeDrainArgs = struct {
    owner: *Scheduler,
    start: *std.atomic.Value(bool),
    waiting: *std.atomic.Value(bool),
};

fn drainRemoteFreeAfterStart(args: *RemoteFreeDrainArgs) void {
    while (!args.start.load(.acquire)) {
        args.waiting.store(true, .release);
        std.Thread.yield() catch {};
    }
    args.owner.drainChannels();
}

fn fillRemoteFsmCtxFreeRing(owner: *Scheduler, sender_idx: usize) !void {
    const ring = try owner.ensureChannel(sender_idx);
    var i: usize = 0;
    while (i < spsc.DefaultRing.capacity) : (i += 1) {
        const task = try owner.allocFsmTask(&dummyFsmResume);
        const ctx = try owner.allocFsmCtx(Scheduler.FsmCtx128, task);
        task.ctx = ctx;
        const msg = SpscMessage{
            .tag = .RemoteFsmCtxFree,
            .fsm_ctx_ptr = @intFromPtr(ctx),
            .fsm_ctx_class = @intFromEnum(fsm_mod.FsmCtxAllocClass.slab128),
        };
        try std.testing.expect(ring.push(msg));
        owner.fsm_task_slab.destroy(task);
    }
    const bit = @as(u64, 1) << @intCast(sender_idx);
    _ = owner.dirty_mask.fetchOr(bit, .release);
}

const RemoteStackFreeArgs = struct {
    thief: *Scheduler,
    stack: Stack,
    started: *std.atomic.Value(bool),
};

fn remoteStackFreeProducer(args: *RemoteStackFreeArgs) void {
    fp.active_scheduler = args.thief;
    fp.scheduler_running = true;
    defer {
        fp.scheduler_running = false;
        fp.active_scheduler = undefined;
    }

    args.started.store(true, .release);
    args.thief.freeStack(args.stack);
}

test "remote FSM ctx free backpressure drains while scheduler is running" {
    const alloc = std.testing.allocator;
    var global_ebr: EbrContext = .{};
    defer global_ebr.deinit(alloc);

    var owner = try Scheduler.init(alloc, &global_ebr, null);
    defer owner.deinit();
    owner.index = 0;

    var thief = try Scheduler.init(alloc, &global_ebr, null);
    defer thief.deinit();
    thief.index = 1;

    try fillRemoteFsmCtxFreeRing(&owner, thief.index);
    const task = try owner.allocFsmTask(&dummyFsmResume);
    const ctx = try owner.allocFsmCtx(Scheduler.FsmCtx128, task);

    var start = std.atomic.Value(bool).init(false);
    var waiting = std.atomic.Value(bool).init(false);
    var args = RemoteFreeDrainArgs{ .owner = &owner, .start = &start, .waiting = &waiting };
    var drainer = try std.Thread.spawn(.{}, drainRemoteFreeAfterStart, .{&args});
    while (!waiting.load(.acquire)) {
        std.Thread.yield() catch {};
    }

    fp.active_scheduler = &thief;
    fp.scheduler_running = true;
    defer {
        fp.scheduler_running = false;
        fp.active_scheduler = undefined;
    }

    start.store(true, .release);
    thief.freeFsmCtx(Scheduler.FsmCtx128, task, ctx);
    drainer.join();
    owner.drainChannels();
    owner.fsm_task_slab.destroy(task);
}

test "remote stack free backpressure drains while scheduler is running" {
    const alloc = std.testing.allocator;
    var global_ebr: EbrContext = .{};
    defer global_ebr.deinit(alloc);

    var owner = try Scheduler.init(alloc, &global_ebr, null);
    defer owner.deinit();
    owner.index = 0;

    var thief = try Scheduler.init(alloc, &global_ebr, null);
    defer thief.deinit();
    thief.index = 1;

    try fillRemoteFsmCtxFreeRing(&owner, thief.index);
    const memory = try owner.allocStack(.Micro);
    const stack = Stack{ .memory = memory, .owner = &owner };

    var started = std.atomic.Value(bool).init(false);
    var args = RemoteStackFreeArgs{ .thief = &thief, .stack = stack, .started = &started };
    var producer = try std.Thread.spawn(.{}, remoteStackFreeProducer, .{&args});
    while (!started.load(.acquire)) {
        std.Thread.yield() catch {};
    }
    var spins: usize = 0;
    while (spins < 1024) : (spins += 1) {
        std.Thread.yield() catch {};
    }
    owner.drainChannels();
    producer.join();
    owner.drainChannels();
}

// ─────────────────────────────────────────────────────────
// Tests for ioError, SmartEventFd, IoWaiter (originally at
// lines 2961-3085 of scheduler.zig).
// ─────────────────────────────────────────────────────────

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "ioError: common errno values" {
    // EINVAL = 22
    const err1 = Scheduler.ioError(-22);
    try std.testing.expectEqual(error.Unexpected, err1);

    // ENOMEM = 12
    const err2 = Scheduler.ioError(-12);
    try std.testing.expectEqual(error.Unexpected, err2);

    // ENOSPC = 28
    const err3 = Scheduler.ioError(-28);
    try std.testing.expectEqual(error.Unexpected, err3);

    // EIO = 5
    const err4 = Scheduler.ioError(-5);
    try std.testing.expectEqual(error.Unexpected, err4);
}

test "ioError: boundary errno values" {
    // -1 (EPERM) -- smallest valid errno
    const err1 = Scheduler.ioError(-1);
    try std.testing.expectEqual(error.Unexpected, err1);

    // -4095 -- largest errno the kernel returns (MAX_ERRNO)
    const err2 = Scheduler.ioError(-4095);
    try std.testing.expectEqual(error.Unexpected, err2);
}

test "ioError: i32 min does not overflow" {
    // This is the case that overflows with naive `-waiter.result` on i32.
    // The i64 widening in ioError prevents undefined behavior.
    const err = Scheduler.ioError(std.math.minInt(i32));
    try std.testing.expectEqual(error.Unexpected, err);
}

test "SmartEventFd: awake notify is consumed without kernel wake" {
    var efd = try SmartEventFd.init();
    defer efd.deinit();

    efd.notify();
    try std.testing.expect(!efd.prepareSleep());
    efd.finishSleep();

    try std.testing.expect(efd.prepareSleep());
    efd.finishSleep();
}

test "SmartEventFd: parked notify writes one wake token" {
    var efd = try SmartEventFd.init();
    defer efd.deinit();

    try std.testing.expect(efd.prepareSleep());
    efd.notify();
    efd.consume();
    efd.finishSleep();

    try std.testing.expect(efd.prepareSleep());
    efd.finishSleep();
}

test "SmartEventFd: prepareSleep is idempotent while parked" {
    var efd = try SmartEventFd.init();
    defer efd.deinit();

    try std.testing.expect(efd.prepareSleep());
    try std.testing.expect(efd.prepareSleep());
    efd.finishSleep();
}

test "IoWaiter: encode/decode roundtrip" {
    var dummy_fiber = fc.Fiber{
        .stack = fc.Stack{ .memory = &[_]u8{} },
        .ctx = fc.Context{ .sp = 0 },
        .parent_ctx = undefined,
        .size_class = .Standard,
        .stack_limit = 0,
        .stack_guard_head = null,
    };
    var task = qs.Task{
        .base = &dummy_fiber,
        .user_fn = @ptrCast(&dummyTaskFn),
        .status = qs.Atomic(qs.TaskStatus).init(.Ready),
        .config = .{},
    };
    var waiter = Scheduler.IoWaiter{ .task = &task };
    const encoded = waiter.encode();
    // Bit 0 must be set (IoWaiter tag)
    try std.testing.expect(encoded & 1 == 1);
    // Decode must recover the original pointer
    const decoded = Scheduler.IoWaiter.decode(encoded);
    try std.testing.expectEqual(&waiter, decoded);
    try std.testing.expectEqual(&task, decoded.task);
}

test "IoWaiter: encode is distinct from sentinels" {
    var dummy_fiber = fc.Fiber{
        .stack = fc.Stack{ .memory = &[_]u8{} },
        .ctx = fc.Context{ .sp = 0 },
        .parent_ctx = undefined,
        .size_class = .Standard,
        .stack_limit = 0,
        .stack_guard_head = null,
    };
    var task = qs.Task{
        .base = &dummy_fiber,
        .user_fn = @ptrCast(&dummyTaskFn),
        .status = qs.Atomic(qs.TaskStatus).init(.Ready),
        .config = .{},
    };
    var waiter = Scheduler.IoWaiter{ .task = &task };
    const encoded = waiter.encode();
    // Must not collide with EVENTFD_SENTINEL (0) or TIMEOUT_SENTINEL (1)
    try std.testing.expect(encoded != Scheduler.EVENTFD_SENTINEL);
    try std.testing.expect(encoded != Scheduler.TIMEOUT_SENTINEL);
}

fn dummyTaskFn(_: *anyopaque, _: ?*anyopaque) anyerror!void {}

fn dummyFsmResume(_: *fsm_mod.FsmTask) YieldReason {
    return .Done;
}
