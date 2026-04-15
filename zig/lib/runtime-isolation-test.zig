const std = @import("std");

const rt_mod = @import("../runtime/runtime.zig");
const fp = @import("../runtime/scheduler.zig");
const qs = @import("../runtime/queues.zig");
const fm = @import("../runtime/fiber-memory.zig");
const ebr = @import("ebr.zig");
const header = @import("../runtime/runtime-header.zig");
const compat = @import("compat.zig");

const CheatLib = header.CheatLib;
const Runtime = rt_mod.Runtime;
const alloc = std.heap.c_allocator;

var global_ebr_ctx: ebr.EbrContext = .{};
var global_stack_pool: fm.StackPool = undefined;
var global_shutdown = std.atomic.Value(bool).init(false);

fn initWorkerGlobals() void {
    global_stack_pool = fm.StackPool.init(alloc);
}

fn deinitWorkerGlobals() void {
    global_stack_pool.deinit();
}

fn schedulerThread(a: std.mem.Allocator) void {
    var sched = fp.Scheduler.init(a, &global_ebr_ctx, &global_stack_pool) catch return;
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
        t.* = std.Thread.spawn(.{}, schedulerThread, .{alloc}) catch continue;
    }
    while (fp.global_registry.count() < n) {
        compat.sleepNs(1 * std.time.ns_per_ms);
    }
}

fn stopWorkers(threads: []std.Thread, n: usize) void {
    global_shutdown.store(true, .release);
    fp.global_registry.notifyAll();
    for (threads[0..n]) |*t| t.join();
    fp.global_registry.deinit(alloc);
    fp.global_registry = .{};
    global_shutdown.store(false, .release);
}

const MainTaskStatus = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    err: ?anyerror = null,
};

const MainTaskCtx = struct {
    inner_fn: qs.TaskFn,
    inner_args: ?*anyopaque,
    status: *MainTaskStatus,

    fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
        const ctx: *@This() = @ptrCast(@alignCast(raw_args.?));
        defer ctx.status.done.store(true, .release);
        ctx.inner_fn(raw_rt, ctx.inner_args) catch |err| {
            ctx.status.err = err;
        };
    }
};

fn runCheckedMain(sched: *fp.Scheduler, task_fn: qs.TaskFn, args: ?*anyopaque) !void {
    var status = MainTaskStatus{};
    var ctx = MainTaskCtx{
        .inner_fn = task_fn,
        .inner_args = args,
        .status = &status,
    };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&MainTaskCtx.run)),
        &ctx,
        .{ .stack_size = .Standard, .pinned = true },
    );
    sched.run();
    try std.testing.expect(status.done.load(.acquire));
    if (status.err) |err| return err;
}

fn pickRemoteScheduler() ?*fp.Scheduler {
    const active = fp.active_scheduler;
    const n = fp.global_registry.len.load(.acquire);
    for (fp.global_registry.slots[0..n]) |*slot| {
        if (slot.load(.acquire)) |sched| {
            if (sched != active) return sched;
        }
    }
    return null;
}

fn sendTestRemoteCall(target: *fp.Scheduler, func_ptr: *const fn (*anyopaque) void, ctx_ptr: *anyopaque, done_flag: *std.atomic.Value(bool)) void {
    if (target == fp.active_scheduler) {
        func_ptr(ctx_ptr);
        return;
    }

    const sender_idx = fp.active_scheduler.index;
    std.debug.assert(sender_idx < target.channels.len);
    const ring = target.ensureChannel(sender_idx) catch @panic("SPSC channel alloc failed");
    const completion = alloc.create(fp.RemoteCompletion) catch @panic("RemoteCall completion alloc failed");
    defer alloc.destroy(completion);
    completion.* = .{
        .wg = fp.WaitGroup.init(fp.active_scheduler),
        .finished = std.atomic.Value(bool).init(false),
    };
    completion.wg.add(1);
    const msg = fp.SpscMessage{
        .tag = .RemoteCall,
        .rc_func = @ptrCast(func_ptr),
        .rc_ctx = ctx_ptr,
        .rc_wg = @ptrCast(completion),
    };
    while (!ring.push(msg)) std.atomic.spinLoopHint();
    _ = target.dirty_mask.fetchOr(@as(u64, 1) << @intCast(sender_idx), .seq_cst);
    target.event_fd.notify();
    completion.wg.wait();
    while (!completion.finished.load(.acquire)) std.atomic.spinLoopHint();
    std.debug.assert(done_flag.load(.acquire));
}

fn fireRemoteCallNoCompletion(target: *fp.Scheduler, func_ptr: *const fn (*anyopaque) void, ctx_ptr: *anyopaque) void {
    if (target == fp.active_scheduler) {
        func_ptr(ctx_ptr);
        return;
    }

    const sender_idx = fp.active_scheduler.index;
    std.debug.assert(sender_idx < target.channels.len);
    const ring = target.ensureChannel(sender_idx) catch @panic("SPSC channel alloc failed");
    const msg = fp.SpscMessage{
        .tag = .RemoteCall,
        .rc_func = @ptrCast(func_ptr),
        .rc_ctx = ctx_ptr,
        .rc_wg = null,
    };
    while (!ring.push(msg)) std.atomic.spinLoopHint();
    _ = target.dirty_mask.fetchOr(@as(u64, 1) << @intCast(sender_idx), .seq_cst);
    target.event_fd.notify();
}

fn waitForPromises(promises: []CheatLib.Promise(i64)) !i64 {
    var total: i64 = 0;
    for (promises) |*promise| total += try promise.next();
    return total;
}

const HeapRemoteCtx = struct {
    value: i64 = 41,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(raw: *anyopaque) void {
        const ctx: *@This() = @ptrCast(@alignCast(raw));
        ctx.value += 1;
        ctx.done.store(true, .release);
    }
};

const StackRemoteCtx = struct {
    input: i64 = 0,
    output: i64 = 0,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(raw: *anyopaque) void {
        const ctx: *@This() = @ptrCast(@alignCast(raw));
        ctx.output = ctx.input + 1;
        ctx.done.store(true, .release);
    }
};

const ReadStateCtx = struct {
    state: *State,
    result: i64 = 0,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(raw: *anyopaque) void {
        const ctx: *@This() = @ptrCast(@alignCast(raw));
        ctx.result = ctx.state.value;
        _ = ctx.state.reads.fetchAdd(1, .seq_cst);
        ctx.done.store(true, .release);
    }
};

const MutateStateCtx = struct {
    state: *State,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(raw: *anyopaque) void {
        const ctx: *@This() = @ptrCast(@alignCast(raw));
        ctx.state.value += 1;
        _ = ctx.state.mutates.fetchAdd(1, .seq_cst);
        ctx.done.store(true, .release);
    }
};

const State = struct {
    value: i64 = 0,
    reads: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    mutates: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
};

const PromiseWorkerCtx = struct {
    const Mode = enum { heap_ctx, stack_ctx, read_mutate, wg_waiter };

    inner: *CheatLib.Promise(i64).Inner,
    bg_alloc: std.mem.Allocator,
    target: *fp.Scheduler,
    ops: usize,
    mode: Mode,
    state: ?*State = null,

    fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
        const rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
        const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
        defer ctx.bg_alloc.destroy(ctx);
        defer ctx.inner.wg.done();

        var total: i64 = 0;
        switch (ctx.mode) {
            .heap_ctx => {
                for (0..ctx.ops) |_| {
                    const remote = try alloc.create(HeapRemoteCtx);
                    remote.* = .{};
                    sendTestRemoteCall(ctx.target, @ptrCast(&HeapRemoteCtx.run), @ptrCast(remote), &remote.done);
                    total += remote.value;
                    alloc.destroy(remote);
                    rt.checkYield();
                }
            },
            .stack_ctx => {
                var remote: StackRemoteCtx = .{};
                for (0..ctx.ops) |i| {
                    remote = .{ .input = @as(i64, @intCast(i)) };
                    sendTestRemoteCall(ctx.target, @ptrCast(&StackRemoteCtx.run), @ptrCast(&remote), &remote.done);
                    try std.testing.expectEqual(@as(i64, @intCast(i + 1)), remote.output);
                    total += remote.output;
                    remote.input = -1;
                    remote.output = -1;
                    rt.checkYield();
                }
            },
            .read_mutate => {
                const state = ctx.state orelse return error.SkipZigTest;
                for (0..ctx.ops) |_| {
                    var read_ctx = ReadStateCtx{ .state = state };
                    sendTestRemoteCall(ctx.target, @ptrCast(&ReadStateCtx.run), @ptrCast(&read_ctx), &read_ctx.done);
                    total += read_ctx.result;

                    var mutate_ctx = MutateStateCtx{ .state = state };
                    sendTestRemoteCall(ctx.target, @ptrCast(&MutateStateCtx.run), @ptrCast(&mutate_ctx), &mutate_ctx.done);
                    rt.checkYield();
                }
            },
            .wg_waiter => {
                const remote_state = ctx.state orelse return error.SkipZigTest;
                for (0..ctx.ops) |i| {
                    var payload = struct {
                        value: i64 = -1,
                        done_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
                    }{};
                    var wg = fp.WaitGroup.init(fp.active_scheduler);
                    wg.add(1);
                    const WaitCtx = struct {
                        payload: *@TypeOf(payload),
                        wg: *fp.WaitGroup,
                        state: *State,
                        value: i64,
                        fn run(raw: *anyopaque) void {
                            const c: *@This() = @ptrCast(@alignCast(raw));
                            c.payload.value = c.value;
                            _ = c.payload.done_count.fetchAdd(1, .seq_cst);
                            _ = c.state.mutates.fetchAdd(1, .seq_cst);
                            c.wg.done();
                        }
                    };
                    var wait_ctx = WaitCtx{
                        .payload = &payload,
                        .wg = &wg,
                        .state = remote_state,
                        .value = @as(i64, @intCast(i)),
                    };
                    fireRemoteCallNoCompletion(ctx.target, @ptrCast(&WaitCtx.run), @ptrCast(&wait_ctx));
                    wg.wait();
                    try std.testing.expectEqual(@as(i64, @intCast(i)), payload.value);
                    try std.testing.expectEqual(@as(usize, 1), payload.done_count.load(.seq_cst));
                    payload.value = -999;
                    rt.checkYield();
                    total += 1;
                }
            },
        }

        ctx.inner.result = total;
    }
};

fn spawnPromiseWorker(rt: *Runtime, target: *fp.Scheduler, ops: usize, mode: PromiseWorkerCtx.Mode, state: ?*State) !CheatLib.Promise(i64) {
    const sched_alloc = rt.getSched().allocator;
    const promise = try CheatLib.Promise(i64).spawn(sched_alloc, rt.getSched());
    const ctx = try sched_alloc.create(PromiseWorkerCtx);
    ctx.* = .{
        .inner = promise.inner,
        .bg_alloc = sched_alloc,
        .target = target,
        .ops = ops,
        .mode = mode,
        .state = state,
    };
    try header.spawnPinned(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&PromiseWorkerCtx.run)),
        ctx,
        .{ .stack_size = .Standard, .pinned = true },
    );
    return promise;
}

test "RemoteCall: repeated heap ctx immediate destroy survives tiny concurrent loops" {
    initWorkerGlobals();
    defer deinitWorkerGlobals();

    var threads: [2]std.Thread = undefined;
    startWorkers(&threads, 2);
    defer stopWorkers(&threads, 2);

    var sched = try fp.Scheduler.init(alloc, &global_ebr_ctx, &global_stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;

    var rt = try Runtime.init(alloc, 4 * 1024 * 1024, &global_ebr_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const target = pickRemoteScheduler() orelse return error.SkipZigTest;

            var promises: [2]CheatLib.Promise(i64) = undefined;
            for (0..promises.len) |i| {
                promises[i] = try spawnPromiseWorker(rt_ptr, target, 256, .heap_ctx, null);
            }
            try std.testing.expectEqual(@as(i64, 2 * 256 * 42), try waitForPromises(&promises));
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "RemoteCall: repeated stack ctx reuse survives tiny concurrent loops" {
    initWorkerGlobals();
    defer deinitWorkerGlobals();

    var threads: [2]std.Thread = undefined;
    startWorkers(&threads, 2);
    defer stopWorkers(&threads, 2);

    var sched = try fp.Scheduler.init(alloc, &global_ebr_ctx, &global_stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;

    var rt = try Runtime.init(alloc, 4 * 1024 * 1024, &global_ebr_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const target = pickRemoteScheduler() orelse return error.SkipZigTest;

            var promises: [2]CheatLib.Promise(i64) = undefined;
            for (0..promises.len) |i| {
                promises[i] = try spawnPromiseWorker(rt_ptr, target, 256, .stack_ctx, null);
            }
            const total = try waitForPromises(&promises);
            try std.testing.expectEqual(@as(i64, 2 * 256 * 257 / 2), total);
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "RemoteCall: tiny repeated read then mutate loops preserve remote state" {
    initWorkerGlobals();
    defer deinitWorkerGlobals();

    var threads: [2]std.Thread = undefined;
    startWorkers(&threads, 2);
    defer stopWorkers(&threads, 2);

    var sched = try fp.Scheduler.init(alloc, &global_ebr_ctx, &global_stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;

    var rt = try Runtime.init(alloc, 4 * 1024 * 1024, &global_ebr_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const target = pickRemoteScheduler() orelse return error.SkipZigTest;
            var state = State{};

            var promises: [2]CheatLib.Promise(i64) = undefined;
            for (0..promises.len) |i| {
                promises[i] = try spawnPromiseWorker(rt_ptr, target, 128, .read_mutate, &state);
            }
            _ = try waitForPromises(&promises);
            try std.testing.expectEqual(@as(i64, 256), state.value);
            try std.testing.expectEqual(@as(usize, 256), state.reads.load(.seq_cst));
            try std.testing.expectEqual(@as(usize, 256), state.mutates.load(.seq_cst));
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "WaitGroup: repeated cross-scheduler stack payload reuse survives immediate overwrite" {
    initWorkerGlobals();
    defer deinitWorkerGlobals();

    var threads: [2]std.Thread = undefined;
    startWorkers(&threads, 2);
    defer stopWorkers(&threads, 2);

    var sched = try fp.Scheduler.init(alloc, &global_ebr_ctx, &global_stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;

    var rt = try Runtime.init(alloc, 4 * 1024 * 1024, &global_ebr_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const MainFn = struct {
        fn run(_: *anyopaque, _: ?*anyopaque) anyerror!void {
            const target = pickRemoteScheduler() orelse return error.SkipZigTest;

            const WaitCtx = struct {
                value_ptr: *i64,
                wg: *fp.WaitGroup,
                value: i64,
                fn run(raw: *anyopaque) void {
                    const c: *@This() = @ptrCast(@alignCast(raw));
                    c.value_ptr.* = c.value;
                    c.wg.done();
                }
            };

            for (0..512) |i| {
                var value: i64 = -1;
                var wg = fp.WaitGroup.init(fp.active_scheduler);
                wg.add(1);
                var ctx = WaitCtx{
                    .value_ptr = &value,
                    .wg = &wg,
                    .value = @as(i64, @intCast(i)),
                };
                fireRemoteCallNoCompletion(target, @ptrCast(&WaitCtx.run), @ptrCast(&ctx));
                wg.wait();
                try std.testing.expectEqual(@as(i64, @intCast(i)), value);
                value = -999;
                fp.active_scheduler.coopYield();
            }
        }
    };

    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), null);
}

test "WaitGroup: blocked waiter resumes exactly once per remote done" {
    initWorkerGlobals();
    defer deinitWorkerGlobals();

    var threads: [2]std.Thread = undefined;
    startWorkers(&threads, 2);
    defer stopWorkers(&threads, 2);

    var sched = try fp.Scheduler.init(alloc, &global_ebr_ctx, &global_stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;

    var rt = try Runtime.init(alloc, 4 * 1024 * 1024, &global_ebr_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const target = pickRemoteScheduler() orelse return error.SkipZigTest;
            var state = State{};

            var promises: [2]CheatLib.Promise(i64) = undefined;
            for (0..promises.len) |i| {
                promises[i] = try spawnPromiseWorker(rt_ptr, target, 256, .wg_waiter, &state);
            }
            try std.testing.expectEqual(@as(i64, 512), try waitForPromises(&promises));
            try std.testing.expectEqual(@as(usize, 512), state.mutates.load(.seq_cst));
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "Scheduler wake path: repeated blocked waiters are not duplicate-queued" {
    initWorkerGlobals();
    defer deinitWorkerGlobals();

    var threads: [2]std.Thread = undefined;
    startWorkers(&threads, 2);
    defer stopWorkers(&threads, 2);

    var sched = try fp.Scheduler.init(alloc, &global_ebr_ctx, &global_stack_pool);
    defer sched.deinit();
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;

    var rt = try Runtime.init(alloc, 4 * 1024 * 1024, &global_ebr_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const target = pickRemoteScheduler() orelse return error.SkipZigTest;
            var state = State{};

            var promises: [4]CheatLib.Promise(i64) = undefined;
            for (0..promises.len) |i| {
                promises[i] = try spawnPromiseWorker(rt_ptr, target, 128, .wg_waiter, &state);
            }
            try std.testing.expectEqual(@as(i64, 4 * 128), try waitForPromises(&promises));
            try std.testing.expectEqual(@as(usize, 4 * 128), state.mutates.load(.seq_cst));
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}
