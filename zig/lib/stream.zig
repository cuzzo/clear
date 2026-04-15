const std = @import("std");
const rt_mod = @import("../runtime.zig");
const fp = @import("../scheduler.zig");
const queues = @import("../queues.zig");

const Runtime = rt_mod.Runtime;
const TaskFn = queues.TaskFn;

pub fn concurrentBoundedSelect(
    comptime T: type,
    comptime R: type,
    comptime N: usize,
    comptime mapFn: fn (*Runtime, ?*anyopaque, T) anyerror!R,
    comptime localSpawnFn: fn (*fp.Scheduler, TaskFn, ?*anyopaque, fp.TaskConfig) anyerror!void,
    comptime parallelSpawnFn: fn (TaskFn, ?*anyopaque, fp.TaskConfig) anyerror!void,
    comptime cleanupResultFn: fn (std.mem.Allocator, *R) void,
    alloc: std.mem.Allocator,
    rt: *Runtime,
    items: anytype,
    workers: usize,
    parallel: bool,
    task_cfg: fp.TaskConfig,
    user_ctx: ?*anyopaque,
) !std.ArrayListUnmanaged(R) {
    const ItemsPtr = @TypeOf(items);
    const PromiseT = @typeInfo(@typeInfo(ItemsPtr).pointer.child).array.child;
    const Slot = ?R;

    const slots = try alloc.alloc(Slot, N);
    defer alloc.free(slots);
    for (slots) |*slot| slot.* = null;
    errdefer {
        for (slots) |*slot| {
            if (slot.*) |*value| cleanupResultFn(alloc, value);
        }
    }

    var err_code = std.atomic.Value(u16).init(0);
    var next_idx = std.atomic.Value(usize).init(0);
    var wg = fp.WaitGroup.init(rt.getSched());

    const Worker = struct {
        wg: *fp.WaitGroup,
        items: *[N]PromiseT,
        slots: []Slot,
        next_idx: *std.atomic.Value(usize),
        err_code: *std.atomic.Value(u16),
        user_ctx: ?*anyopaque,

        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const worker_rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            while (true) {
                const idx = ctx.next_idx.fetchAdd(1, .monotonic);
                if (idx >= N) break;
                const item = try ctx.items[idx].next();
                const mapped = mapFn(worker_rt, ctx.user_ctx, item) catch |err| {
                    _ = ctx.err_code.cmpxchgStrong(0, @intFromError(err), .seq_cst, .seq_cst);
                    continue;
                };
                ctx.slots[idx] = mapped;
                worker_rt.checkYield();
            }
        }
    };

    var worker_ctxs: [64]Worker = undefined;
    const actual_workers = @min(if (workers == 0) @as(usize, 1) else workers, @as(usize, 64));
    if (actual_workers == 0) return .{};
    wg.add(actual_workers);
    for (0..actual_workers) |i| {
        worker_ctxs[i] = .{
            .wg = &wg,
            .items = items,
            .slots = slots,
            .next_idx = &next_idx,
            .err_code = &err_code,
            .user_ctx = user_ctx,
        };
        if (parallel) {
            try parallelSpawnFn(@as(TaskFn, @ptrCast(&Worker.run)), &worker_ctxs[i], task_cfg);
        } else {
            try localSpawnFn(wg.sched, @as(TaskFn, @ptrCast(&Worker.run)), &worker_ctxs[i], task_cfg);
        }
    }
    wg.wait();

    const err_int = err_code.load(.seq_cst);
    if (err_int != 0) return @errorFromInt(err_int);

    var count: usize = 0;
    for (slots) |slot| {
        if (slot != null) count += 1;
    }
    var out = try std.ArrayListUnmanaged(R).initCapacity(alloc, count);
    errdefer {
        for (out.items) |*value| cleanupResultFn(alloc, value);
        out.deinit(alloc);
    }
    for (slots) |*slot| {
        if (slot.*) |value| {
            out.appendAssumeCapacity(value);
            slot.* = null;
        }
    }
    return out;
}

pub fn concurrentBoundedWhere(
    comptime T: type,
    comptime N: usize,
    comptime predFn: fn (*Runtime, ?*anyopaque, T) anyerror!bool,
    comptime localSpawnFn: fn (*fp.Scheduler, TaskFn, ?*anyopaque, fp.TaskConfig) anyerror!void,
    comptime parallelSpawnFn: fn (TaskFn, ?*anyopaque, fp.TaskConfig) anyerror!void,
    comptime cleanupItemFn: fn (std.mem.Allocator, *T) void,
    alloc: std.mem.Allocator,
    rt: *Runtime,
    items: anytype,
    workers: usize,
    parallel: bool,
    task_cfg: fp.TaskConfig,
    user_ctx: ?*anyopaque,
) !std.ArrayListUnmanaged(T) {
    const ItemsPtr = @TypeOf(items);
    const PromiseT = @typeInfo(@typeInfo(ItemsPtr).pointer.child).array.child;
    const Slot = ?T;

    const slots = try alloc.alloc(Slot, N);
    defer alloc.free(slots);
    for (slots) |*slot| slot.* = null;
    errdefer {
        for (slots) |*slot| {
            if (slot.*) |*value| cleanupItemFn(alloc, value);
        }
    }

    var err_code = std.atomic.Value(u16).init(0);
    var next_idx = std.atomic.Value(usize).init(0);
    var wg = fp.WaitGroup.init(rt.getSched());

    const Worker = struct {
        wg: *fp.WaitGroup,
        items: *[N]PromiseT,
        slots: []Slot,
        alloc: std.mem.Allocator,
        next_idx: *std.atomic.Value(usize),
        err_code: *std.atomic.Value(u16),
        user_ctx: ?*anyopaque,

        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const worker_rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            while (true) {
                const idx = ctx.next_idx.fetchAdd(1, .monotonic);
                if (idx >= N) break;
                var item = try ctx.items[idx].next();
                const keep = predFn(worker_rt, ctx.user_ctx, item) catch |err| {
                    _ = ctx.err_code.cmpxchgStrong(0, @intFromError(err), .seq_cst, .seq_cst);
                    continue;
                };
                if (keep) {
                    ctx.slots[idx] = item;
                } else {
                    cleanupItemFn(ctx.alloc, &item);
                }
                worker_rt.checkYield();
            }
        }
    };

    var worker_ctxs: [64]Worker = undefined;
    const actual_workers = @min(if (workers == 0) @as(usize, 1) else workers, @as(usize, 64));
    if (actual_workers == 0) return .{};
    wg.add(actual_workers);
    for (0..actual_workers) |i| {
        worker_ctxs[i] = .{
            .wg = &wg,
            .items = items,
            .slots = slots,
            .alloc = alloc,
            .next_idx = &next_idx,
            .err_code = &err_code,
            .user_ctx = user_ctx,
        };
        if (parallel) {
            try parallelSpawnFn(@as(TaskFn, @ptrCast(&Worker.run)), &worker_ctxs[i], task_cfg);
        } else {
            try localSpawnFn(wg.sched, @as(TaskFn, @ptrCast(&Worker.run)), &worker_ctxs[i], task_cfg);
        }
    }
    wg.wait();

    const err_int = err_code.load(.seq_cst);
    if (err_int != 0) return @errorFromInt(err_int);

    var count: usize = 0;
    for (slots) |slot| {
        if (slot != null) count += 1;
    }
    var out = try std.ArrayListUnmanaged(T).initCapacity(alloc, count);
    errdefer {
        for (out.items) |*value| cleanupItemFn(alloc, value);
        out.deinit(alloc);
    }
    for (slots) |*slot| {
        if (slot.*) |value| {
            out.appendAssumeCapacity(value);
            slot.* = null;
        }
    }
    return out;
}

pub fn concurrentBoundedEach(
    comptime T: type,
    comptime N: usize,
    comptime eachFn: fn (*Runtime, ?*anyopaque, T) anyerror!void,
    comptime localSpawnFn: fn (*fp.Scheduler, TaskFn, ?*anyopaque, fp.TaskConfig) anyerror!void,
    comptime parallelSpawnFn: fn (TaskFn, ?*anyopaque, fp.TaskConfig) anyerror!void,
    rt: *Runtime,
    items: anytype,
    workers: usize,
    parallel: bool,
    task_cfg: fp.TaskConfig,
    user_ctx: ?*anyopaque,
) !void {
    const ItemsPtr = @TypeOf(items);
    const PromiseT = @typeInfo(@typeInfo(ItemsPtr).pointer.child).array.child;

    var err_code = std.atomic.Value(u16).init(0);
    var next_idx = std.atomic.Value(usize).init(0);
    var wg = fp.WaitGroup.init(rt.getSched());

    const Worker = struct {
        wg: *fp.WaitGroup,
        items: *[N]PromiseT,
        next_idx: *std.atomic.Value(usize),
        err_code: *std.atomic.Value(u16),
        user_ctx: ?*anyopaque,

        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const worker_rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
            const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
            defer ctx.wg.done();
            while (true) {
                const idx = ctx.next_idx.fetchAdd(1, .monotonic);
                if (idx >= N) break;
                const item = try ctx.items[idx].next();
                eachFn(worker_rt, ctx.user_ctx, item) catch |err| {
                    _ = ctx.err_code.cmpxchgStrong(0, @intFromError(err), .seq_cst, .seq_cst);
                    continue;
                };
                worker_rt.checkYield();
            }
        }
    };

    var worker_ctxs: [64]Worker = undefined;
    const actual_workers = @min(if (workers == 0) @as(usize, 1) else workers, @as(usize, 64));
    if (actual_workers == 0) return;
    wg.add(actual_workers);
    for (0..actual_workers) |i| {
        worker_ctxs[i] = .{
            .wg = &wg,
            .items = items,
            .next_idx = &next_idx,
            .err_code = &err_code,
            .user_ctx = user_ctx,
        };
        if (parallel) {
            try parallelSpawnFn(@as(TaskFn, @ptrCast(&Worker.run)), &worker_ctxs[i], task_cfg);
        } else {
            try localSpawnFn(wg.sched, @as(TaskFn, @ptrCast(&Worker.run)), &worker_ctxs[i], task_cfg);
        }
    }
    wg.wait();

    const err_int = err_code.load(.seq_cst);
    if (err_int != 0) return @errorFromInt(err_int);
}
