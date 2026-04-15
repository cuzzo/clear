const std = @import("std");

const rt_mod = @import("../runtime/runtime.zig");
const fp = @import("../runtime/scheduler.zig");
const qs = @import("../runtime/queues.zig");
const fm = @import("../runtime/fiber-memory.zig");
const ebr = @import("ebr");
const header = @import("../runtime/runtime-header.zig");

const CheatLib = header.CheatLib;
const Runtime = rt_mod.Runtime;
const alloc = std.heap.c_allocator;
const root = @import("root");

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
        std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
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

const RunWatchdogCtx = struct {
    sched: *fp.Scheduler,
    status: *MainTaskStatus,
    timeout_ms: usize,

    fn run(raw: *@This()) void {
        std.Thread.sleep(raw.timeout_ms * std.time.ns_per_ms);
        if (raw.status.done.load(.acquire)) return;

        const current_status = if (raw.sched.current_task) |task| task.status.load(.acquire) else null;
        std.debug.print(
            "partitioned-map watchdog timeout: active_tasks={d} dirty_mask=0x{x} ready={d} pinned={d} sleepers={d} current_task={?} current_status={?}\n",
            .{
                raw.sched.active_tasks.load(.monotonic),
                raw.sched.dirty_mask.load(.seq_cst),
                raw.sched.ready_queue.len(),
                raw.sched.pinned_queue.items.len,
                raw.sched.sleeping_queue.items.len,
                raw.sched.current_task,
                current_status,
            },
        );
        dumpPartitionedMapEventLogTail();
        @panic("partitioned-map watchdog timeout");
    }
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
    const watchdog_timeout_ms = if (@hasDecl(root, "partitioned_map_watchdog_timeout_ms"))
        root.partitioned_map_watchdog_timeout_ms
    else
        0;
    var watchdog_ctx = RunWatchdogCtx{
        .sched = sched,
        .status = &status,
        .timeout_ms = watchdog_timeout_ms,
    };
    var watchdog: ?std.Thread = null;
    if (watchdog_timeout_ms > 0) {
        watchdog = try std.Thread.spawn(.{}, RunWatchdogCtx.run, .{&watchdog_ctx});
    }
    defer if (watchdog) |t| t.join();
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&MainTaskCtx.run)),
        &ctx,
        .{ .stack_size = .Standard, .pinned = true },
    );
    sched.run();
    if (!status.done.load(.acquire)) {
        dumpPartitionedMapEventLogTail();
        const current_task_ptr: usize = if (sched.current_task) |task| @intFromPtr(task) else 0;
        std.debug.panic(
            "runCheckedMain returned early: active_tasks={d} dirty_mask=0x{x} ready={d} pinned={d} sleepers={d} current_task=0x{x}",
            .{
                sched.active_tasks.load(.monotonic),
                sched.dirty_mask.load(.seq_cst),
                sched.ready_queue.len(),
                sched.pinned_queue.items.len,
                sched.sleeping_queue.items.len,
                current_task_ptr,
            },
        );
    }
    if (status.err) |err| return err;
}

const Map = CheatLib.PartitionedStringMap(i64, 4);

const MapMode = enum {
    put_get,
    put_only,
    get_only,
    contains_only,
    remove_only,
    remove_blind_only,
    get_remove,
    get_yield_remove,
};

const KeyMode = enum {
    get_remove,
};

const MapFiberCtx = struct {
    inner: *CheatLib.Promise(i64).Inner,
    bg_alloc: std.mem.Allocator,
    map: *Map,
    start: i64,
    count: i64,
    mode: MapMode,

    fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
        const rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
        const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
        defer ctx.bg_alloc.destroy(ctx);
        defer ctx.inner.wg.done();

        var buf: [32]u8 = undefined;
        var total: i64 = 0;

        switch (ctx.mode) {
            .put_get => {
                var i: i64 = ctx.start;
                while (i < ctx.start + ctx.count) : (i += 1) {
                    const key = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch continue;
                    try ctx.map.put(std.heap.c_allocator, std.heap.c_allocator, key, i);
                    rt.checkYield();
                }

                i = ctx.start;
                while (i < ctx.start + ctx.count) : (i += 1) {
                    const key = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch continue;
                    if (ctx.map.get(key)) |_| total += 1;
                    rt.checkYield();
                }
            },
            .put_only => {
                var i: i64 = ctx.start;
                while (i < ctx.start + ctx.count) : (i += 1) {
                    const key = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch continue;
                    try ctx.map.put(std.heap.c_allocator, std.heap.c_allocator, key, i);
                    rt.checkYield();
                }
            },
            .get_only => {
                var i: i64 = ctx.start;
                while (i < ctx.start + ctx.count) : (i += 1) {
                    const key = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch continue;
                    if (ctx.map.get(key)) |_| total += 1;
                    rt.checkYield();
                }
            },
            .contains_only => {
                var i: i64 = ctx.start;
                while (i < ctx.start + ctx.count) : (i += 1) {
                    const key = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch continue;
                    if (ctx.map.contains(key)) total += 1;
                    rt.checkYield();
                }
            },
            .remove_only => {
                var i: i64 = ctx.start;
                while (i < ctx.start + ctx.count) : (i += 1) {
                    const key = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch continue;
                    if (ctx.map.contains(key)) {
                        ctx.map.remove(std.heap.c_allocator, key);
                        total += 1;
                    }
                    rt.checkYield();
                }
            },
            .remove_blind_only => {
                var i: i64 = ctx.start;
                while (i < ctx.start + ctx.count) : (i += 1) {
                    const key = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch continue;
                    ctx.map.remove(std.heap.c_allocator, key);
                    rt.checkYield();
                }
            },
            .get_remove => {
                var i: i64 = ctx.start;
                while (i < ctx.start + ctx.count) : (i += 1) {
                    const key = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch continue;
                    if (ctx.map.get(key) != null) {
                        ctx.map.remove(std.heap.c_allocator, key);
                        total += 1;
                    }
                    rt.checkYield();
                }
            },
            .get_yield_remove => {
                var i: i64 = ctx.start;
                while (i < ctx.start + ctx.count) : (i += 1) {
                    const key = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch continue;
                    if (ctx.map.get(key) != null) {
                        rt.checkYield();
                        ctx.map.remove(std.heap.c_allocator, key);
                        total += 1;
                    }
                    rt.checkYield();
                }
            },
        }

        ctx.inner.result = total;
    }
};

const KeyWorkerCtx = struct {
    inner: *CheatLib.Promise(i64).Inner,
    bg_alloc: std.mem.Allocator,
    map: *Map,
    keys: []const []const u8,
    mode: KeyMode,

    fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
        const rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
        const ctx = @as(*@This(), @ptrCast(@alignCast(raw_args.?)));
        defer ctx.bg_alloc.destroy(ctx);
        defer ctx.inner.wg.done();

        var total: i64 = 0;
        switch (ctx.mode) {
            .get_remove => {
                for (ctx.keys) |key| {
                    if (ctx.map.get(key) != null) {
                        ctx.map.remove(std.heap.c_allocator, key);
                        total += 1;
                    }
                    rt.checkYield();
                }
            },
        }

        ctx.inner.result = total;
    }
};

fn spawnMapWorkerWithStack(rt: *Runtime, map: *Map, start: i64, count: i64, mode: MapMode, stack_size: anytype) !CheatLib.Promise(i64) {
    const sched_alloc = rt.getSched().allocator;
    const promise = try CheatLib.Promise(i64).spawn(sched_alloc, rt.getSched());
    const ctx = try sched_alloc.create(MapFiberCtx);
    ctx.* = .{
        .inner = promise.inner,
        .bg_alloc = sched_alloc,
        .map = map,
        .start = start,
        .count = count,
        .mode = mode,
    };
    try header.spawnPinned(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&MapFiberCtx.run)),
        ctx,
        .{ .stack_size = stack_size, .pinned = true },
    );
    return promise;
}

fn spawnMapWorker(rt: *Runtime, map: *Map, start: i64, count: i64, mode: MapMode) !CheatLib.Promise(i64) {
    return spawnMapWorkerWithStack(rt, map, start, count, mode, .Standard);
}

fn spawnKeyWorker(rt: *Runtime, map: *Map, keys: []const []const u8, mode: KeyMode) !CheatLib.Promise(i64) {
    const sched_alloc = rt.getSched().allocator;
    const promise = try CheatLib.Promise(i64).spawn(sched_alloc, rt.getSched());
    const ctx = try sched_alloc.create(KeyWorkerCtx);
    ctx.* = .{
        .inner = promise.inner,
        .bg_alloc = sched_alloc,
        .map = map,
        .keys = keys,
        .mode = mode,
    };
    try header.spawnPinned(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&KeyWorkerCtx.run)),
        ctx,
        .{ .stack_size = .Standard, .pinned = true },
    );
    return promise;
}

fn waitForPromises(promises: []CheatLib.Promise(i64)) !i64 {
    var total: i64 = 0;
    for (promises) |*promise| total += try promise.next();
    return total;
}

fn findKeyForShard(comptime T: type, shard: usize, buf: []u8) ![]const u8 {
    var i: usize = 0;
    while (true) : (i += 1) {
        const key = try std.fmt.bufPrint(buf, "remote-key-{d}", .{i});
        if (T.shardIndex(key) == shard) return key;
    }
}

fn findShardOwnedBy(map: *const Map, owner: *fp.Scheduler) ?usize {
    for (0..map.owners.len) |i| {
        if (map.owners[i] == owner) return i;
    }
    return null;
}

fn findRemoteShard(map: *const Map) ?usize {
    for (0..map.owners.len) |i| {
        if (map.owners[i] != fp.active_scheduler) return i;
    }
    return null;
}

fn allocKeysForShard(a: std.mem.Allocator, shard: usize, count: usize, prefix: []const u8) ![][]u8 {
    const keys = try a.alloc([]u8, count);
    errdefer a.free(keys);

    var found: usize = 0;
    var i: usize = 0;
    var buf: [96]u8 = undefined;
    errdefer {
        for (keys[0..found]) |key| a.free(key);
    }

    while (found < count) : (i += 1) {
        const candidate = try std.fmt.bufPrint(&buf, "{s}-{d}", .{ prefix, i });
        if (Map.shardIndex(candidate) != shard) continue;
        keys[found] = try a.dupe(u8, candidate);
        found += 1;
    }

    return keys;
}

fn freeKeys(a: std.mem.Allocator, keys: [][]u8) void {
    for (keys) |key| a.free(key);
    a.free(keys);
}

fn resetPartitionedMapCounters() void {
    if (!@hasDecl(root, "partitioned_map_counters")) return;
    root.partitioned_map_counters.get_created.store(0, .seq_cst);
    root.partitioned_map_counters.get_destroyed.store(0, .seq_cst);
    root.partitioned_map_counters.get_inflight.store(0, .seq_cst);
    root.partitioned_map_counters.remove_created.store(0, .seq_cst);
    root.partitioned_map_counters.remove_destroyed.store(0, .seq_cst);
    root.partitioned_map_counters.remove_inflight.store(0, .seq_cst);
    for (&root.partitioned_map_counters.per_shard_get_inflight) |*c| c.store(0, .seq_cst);
    for (&root.partitioned_map_counters.per_shard_remove_inflight) |*c| c.store(0, .seq_cst);
}

fn expectPartitionedMapCountersDrained() !void {
    if (!@hasDecl(root, "partitioned_map_counters")) return;
    try std.testing.expectEqual(
        root.partitioned_map_counters.get_created.load(.seq_cst),
        root.partitioned_map_counters.get_destroyed.load(.seq_cst),
    );
    try std.testing.expectEqual(
        root.partitioned_map_counters.remove_created.load(.seq_cst),
        root.partitioned_map_counters.remove_destroyed.load(.seq_cst),
    );
    try std.testing.expectEqual(@as(usize, 0), root.partitioned_map_counters.get_inflight.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), root.partitioned_map_counters.remove_inflight.load(.seq_cst));
    for (root.partitioned_map_counters.per_shard_get_inflight) |c|
        try std.testing.expectEqual(@as(usize, 0), c.load(.seq_cst));
    for (root.partitioned_map_counters.per_shard_remove_inflight) |c|
        try std.testing.expectEqual(@as(usize, 0), c.load(.seq_cst));
}

const EventStage = struct {
    const created = 0;
    const wait_begin = 1;
    const remote_start = 2;
    const remote_done = 3;
    const wait_return = 4;
    const ctx_destroy = 5;
    const key_free = 6;
    const completion_destroy = 7;
};

fn resetPartitionedMapEventLog() void {
    if (!@hasDecl(root, "partitioned_map_event_log")) return;
    root.partitioned_map_event_log.enabled.store(false, .seq_cst);
    root.partitioned_map_event_log.next_op_id.store(1, .seq_cst);
    root.partitioned_map_event_log.count.store(0, .seq_cst);
    root.partitioned_map_event_log.dropped.store(0, .seq_cst);
}

fn setPartitionedMapEventLogEnabled(enabled: bool) void {
    if (!@hasDecl(root, "partitioned_map_event_log")) return;
    root.partitioned_map_event_log.enabled.store(enabled, .seq_cst);
}

fn expectPartitionedMapEventLogValid() !void {
    if (!@hasDecl(root, "partitioned_map_event_log")) return;

    const count = root.partitioned_map_event_log.count.load(.seq_cst);
    try std.testing.expectEqual(@as(usize, 0), root.partitioned_map_event_log.dropped.load(.seq_cst));

    var last_stage = std.AutoHashMap(u64, u8).init(alloc);
    defer last_stage.deinit();
    var saw_remote_done = std.AutoHashMap(u64, bool).init(alloc);
    defer saw_remote_done.deinit();
    var saw_wait_return = std.AutoHashMap(u64, bool).init(alloc);
    defer saw_wait_return.deinit();
    var saw_ctx_destroy = std.AutoHashMap(u64, bool).init(alloc);
    defer saw_ctx_destroy.deinit();
    var saw_key_free = std.AutoHashMap(u64, bool).init(alloc);
    defer saw_key_free.deinit();
    var saw_completion_destroy = std.AutoHashMap(u64, bool).init(alloc);
    defer saw_completion_destroy.deinit();

    for (root.partitioned_map_event_log.events[0..count]) |event| {
        if (event.kind != 1 and event.kind != 2) continue;
        if (event.op_id == 0) continue;

        const entry = try last_stage.getOrPut(event.op_id);
        if (!entry.found_existing) {
            try std.testing.expectEqual(@as(u8, EventStage.created), event.stage);
            entry.value_ptr.* = event.stage;
        } else {
            try std.testing.expect(event.stage >= entry.value_ptr.*);
            entry.value_ptr.* = event.stage;
        }

        switch (event.stage) {
            EventStage.remote_done => {
                try saw_remote_done.put(event.op_id, true);
            },
            EventStage.wait_return => {
                try std.testing.expect(saw_remote_done.contains(event.op_id));
                try saw_wait_return.put(event.op_id, true);
            },
            EventStage.ctx_destroy => {
                try std.testing.expect(saw_wait_return.contains(event.op_id));
                try saw_ctx_destroy.put(event.op_id, true);
            },
            EventStage.key_free => {
                try std.testing.expect(saw_ctx_destroy.contains(event.op_id));
                try saw_key_free.put(event.op_id, true);
            },
            EventStage.completion_destroy => {
                try std.testing.expect(saw_wait_return.contains(event.op_id));
                try saw_completion_destroy.put(event.op_id, true);
            },
            else => {},
        }
    }

    var it = last_stage.iterator();
    while (it.next()) |entry| {
        const op_id = entry.key_ptr.*;
        try std.testing.expect(saw_remote_done.contains(op_id));
        try std.testing.expect(saw_wait_return.contains(op_id));
        try std.testing.expect(saw_completion_destroy.contains(op_id));
        try std.testing.expect(saw_ctx_destroy.contains(op_id));
        try std.testing.expect(saw_key_free.contains(op_id));
    }
}

fn dumpPartitionedMapEventLogTail() void {
    if (!@hasDecl(root, "partitioned_map_event_log")) return;
    const count = root.partitioned_map_event_log.count.load(.seq_cst);
    const start = if (count > 24) count - 24 else 0;
    std.debug.print("partitioned-map event tail count={d} dropped={d}\n", .{
        count,
        root.partitioned_map_event_log.dropped.load(.seq_cst),
    });
    for (root.partitioned_map_event_log.events[start..count], start..) |event, idx| {
        std.debug.print(
            "  [{d}] kind={d} stage={d} shard={d} op={d} ctx=0x{x} key=0x{x}\n",
            .{ idx, event.kind, event.stage, event.shard, event.op_id, event.ctx_ptr, event.key_ptr },
        );
    }
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

fn runTinyGetRemoveLoopWithDelays(get_ctx_delay: bool, remove_ctx_delay: bool, key_free_delay: bool, completion_delay: bool) !void {
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

    const FIBERS = 2;
    const KEYS = 2;
    const ITERS = 256;

    const MainFn = struct {
        outer_rt: *Runtime,
        get_ctx_delay: bool,
        remove_ctx_delay: bool,
        key_free_delay: bool,
        completion_delay: bool,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            resetPartitionedMapCounters();

            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            if (@hasDecl(root, "partitioned_map_delay_get_ctx_destroy")) root.partitioned_map_delay_get_ctx_destroy = self.get_ctx_delay;
            if (@hasDecl(root, "partitioned_map_delay_remove_ctx_destroy")) root.partitioned_map_delay_remove_ctx_destroy = self.remove_ctx_delay;
            if (@hasDecl(root, "partitioned_map_delay_key_free")) root.partitioned_map_delay_key_free = self.key_free_delay;
            if (@hasDecl(root, "partitioned_map_delay_completion_destroy")) root.partitioned_map_delay_completion_destroy = self.completion_delay;
            defer {
                if (@hasDecl(root, "partitioned_map_delay_get_ctx_destroy")) root.partitioned_map_delay_get_ctx_destroy = false;
                if (@hasDecl(root, "partitioned_map_delay_remove_ctx_destroy")) root.partitioned_map_delay_remove_ctx_destroy = false;
                if (@hasDecl(root, "partitioned_map_delay_key_free")) root.partitioned_map_delay_key_free = false;
                if (@hasDecl(root, "partitioned_map_delay_completion_destroy")) root.partitioned_map_delay_completion_destroy = false;
            }

            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();

            const shard = findRemoteShard(map) orelse return error.SkipZigTest;
            const keys = try allocKeysForShard(alloc, shard, FIBERS * KEYS, "tiny-delay");
            defer freeKeys(alloc, keys);

            for (0..ITERS) |_| {
                for (keys) |key| try map.put(std.heap.c_allocator, std.heap.c_allocator, key, 1);
                var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
                for (0..FIBERS) |i| {
                    const begin = i * KEYS;
                    promises[i] = try spawnKeyWorker(rt_ptr, map, keys[begin .. begin + KEYS], .get_remove);
                }
                try std.testing.expectEqual(@as(i64, FIBERS * KEYS), try waitForPromises(&promises));
                try std.testing.expectEqual(@as(i64, 0), map.count());
                try expectPartitionedMapCountersDrained();
            }
        }
    };

    var runner = MainFn{
        .outer_rt = &rt,
        .get_ctx_delay = get_ctx_delay,
        .remove_ctx_delay = remove_ctx_delay,
        .key_free_delay = key_free_delay,
        .completion_delay = completion_delay,
    };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

fn runTinyGetRemoveLoopWithEventLog(iters: usize) !void {
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

    const FIBERS = 2;
    const KEYS = 2;

    const MainFn = struct {
        outer_rt: *Runtime,
        iters: usize,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            resetPartitionedMapCounters();
            resetPartitionedMapEventLog();
            setPartitionedMapEventLogEnabled(true);
            if (@hasDecl(root, "partitioned_map_watchdog_timeout_ms")) root.partitioned_map_watchdog_timeout_ms = 750;
            defer {
                if (@hasDecl(root, "partitioned_map_watchdog_timeout_ms")) root.partitioned_map_watchdog_timeout_ms = 0;
                setPartitionedMapEventLogEnabled(false);
                resetPartitionedMapEventLog();
            }

            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();

            const shard = findRemoteShard(map) orelse return error.SkipZigTest;
            const keys = try allocKeysForShard(alloc, shard, FIBERS * KEYS, "tiny-events");
            defer freeKeys(alloc, keys);

            for (0..self.iters) |_| {
                for (keys) |key| try map.put(std.heap.c_allocator, std.heap.c_allocator, key, 1);
                var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
                for (0..FIBERS) |i| {
                    const begin = i * KEYS;
                    promises[i] = try spawnKeyWorker(rt_ptr, map, keys[begin .. begin + KEYS], .get_remove);
                }
                try std.testing.expectEqual(@as(i64, FIBERS * KEYS), try waitForPromises(&promises));
                try std.testing.expectEqual(@as(i64, 0), map.count());
                try expectPartitionedMapCountersDrained();
            }

            try expectPartitionedMapEventLogValid();
        }
    };

    var runner = MainFn{ .outer_rt = &rt, .iters = iters };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
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

fn prepopulateRange(map: *Map, start: i64, count: i64) !void {
    var buf: [32]u8 = undefined;
    var i: i64 = start;
    while (i < start + count) : (i += 1) {
        const key = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch continue;
        try map.put(std.heap.c_allocator, std.heap.c_allocator, key, i);
    }
}

test "Promise(i64): repeated concurrent worker batches survive reuse" {
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

    const FIBERS = 4;
    const ITERS = 8;

    const Ctx = struct {
        inner: *CheatLib.Promise(i64).Inner,
        bg_alloc: std.mem.Allocator,
        value: i64,
        steps: usize,

        fn run(raw_rt: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const r: *Runtime = @ptrCast(@alignCast(raw_rt));
            const ctx: *@This() = @ptrCast(@alignCast(raw.?));
            defer ctx.bg_alloc.destroy(ctx);
            defer ctx.inner.wg.done();
            for (0..ctx.steps) |_| r.checkYield();
            ctx.inner.result = ctx.value;
        }
    };

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            for (0..ITERS) |_| {
                var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
                for (0..FIBERS) |i| {
                    const promise = try CheatLib.Promise(i64).spawn(sa, rt_ptr.getSched());
                    const ctx = try sa.create(Ctx);
                    ctx.* = .{
                        .inner = promise.inner,
                        .bg_alloc = sa,
                        .value = @as(i64, @intCast(i + 1)),
                        .steps = 128,
                    };
                    try header.spawnPinned(
                        @intFromPtr(&Runtime.entryWrapper),
                        @as(qs.TaskFn, @ptrCast(&Ctx.run)),
                        ctx,
                        .{ .stack_size = .Standard, .pinned = true },
                    );
                    promises[i] = promise;
                }

                try std.testing.expectEqual(@as(i64, 10), try waitForPromises(&promises));
            }
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "RemoteCall: repeated concurrent batches survive reuse" {
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

    const FIBERS = 4;
    const ITERS = 8;
    const OPS = 200;

    const RemoteCtx = struct {
        value: i64,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fn run(raw: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(raw));
            ctx.value += 1;
            ctx.done.store(true, .release);
        }
    };

    const WorkerCtx = struct {
        inner: *CheatLib.Promise(i64).Inner,
        bg_alloc: std.mem.Allocator,
        target: *fp.Scheduler,
        ops: usize,

        fn run(raw_rt: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const r: *Runtime = @ptrCast(@alignCast(raw_rt));
            const ctx: *@This() = @ptrCast(@alignCast(raw.?));
            defer ctx.bg_alloc.destroy(ctx);
            defer ctx.inner.wg.done();

            var total: i64 = 0;
            for (0..ctx.ops) |_| {
                const remote = try alloc.create(RemoteCtx);
                remote.* = .{ .value = 41 };
                sendTestRemoteCall(ctx.target, @ptrCast(&RemoteCtx.run), @ptrCast(remote), &remote.done);
                total += remote.value;
                alloc.destroy(remote);
                r.checkYield();
            }
            ctx.inner.result = total;
        }
    };

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;
            const target = pickRemoteScheduler() orelse return error.SkipZigTest;

            for (0..ITERS) |_| {
                var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
                for (0..FIBERS) |i| {
                    const promise = try CheatLib.Promise(i64).spawn(sa, rt_ptr.getSched());
                    const ctx = try sa.create(WorkerCtx);
                    ctx.* = .{
                        .inner = promise.inner,
                        .bg_alloc = sa,
                        .target = target,
                        .ops = OPS,
                    };
                    try header.spawnPinned(
                        @intFromPtr(&Runtime.entryWrapper),
                        @as(qs.TaskFn, @ptrCast(&WorkerCtx.run)),
                        ctx,
                        .{ .stack_size = .Standard, .pinned = true },
                    );
                    promises[i] = promise;
                }

                try std.testing.expectEqual(@as(i64, FIBERS * OPS * 42), try waitForPromises(&promises));
            }
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "PartitionedStringMap: lazy ensureOwnership survives concurrent first-touch" {
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

    const FIBERS = 4;
    const KEYS = 250;

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};

            var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
            for (0..FIBERS) |i| {
                promises[i] = try spawnMapWorker(rt_ptr, map, @as(i64, @intCast(i * KEYS)), KEYS, .put_get);
            }

            try std.testing.expectEqual(@as(i64, FIBERS * KEYS), try waitForPromises(&promises));
            try std.testing.expectEqual(@as(i64, FIBERS * KEYS), map.count());
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "PartitionedStringMap: remote overwrite keeps latest value" {
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

    var rt = try Runtime.init(alloc, 1024 * 1024, &global_ebr_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const MainFn = struct {
        fn run(_: *anyopaque, _: ?*anyopaque) anyerror!void {
            var map: Map = .{};
            defer map.deinit(std.heap.c_allocator, std.heap.c_allocator);
            map.ensureOwnership();

            var remote_shard: ?usize = null;
            for (0..map.owners.len) |i| {
                if (map.owners[i] != fp.active_scheduler) {
                    remote_shard = i;
                    break;
                }
            }
            try std.testing.expect(remote_shard != null);

            var key_buf: [64]u8 = undefined;
            const key = try findKeyForShard(Map, remote_shard.?, &key_buf);

            try map.put(std.heap.c_allocator, std.heap.c_allocator, key, 1);
            try map.put(std.heap.c_allocator, std.heap.c_allocator, key, 2);
            try std.testing.expectEqual(@as(?i64, 2), map.get(key));
            try std.testing.expectEqual(@as(i64, 1), map.count());
            try std.testing.expect(map.contains(key));

            map.remove(std.heap.c_allocator, key);
            try std.testing.expect(!map.contains(key));
            try std.testing.expectEqual(@as(i64, 0), map.count());
        }
    };

    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), null);
}

test "PartitionedStringMap: stack-local remote ops are complete before deinit" {
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

    var rt = try Runtime.init(alloc, 1024 * 1024, &global_ebr_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const ITERS = 2000;

    const MainFn = struct {
        fn run(_: *anyopaque, _: ?*anyopaque) anyerror!void {
            var key_buf: [64]u8 = undefined;

            for (0..ITERS) |iter| {
                var map: Map = .{};
                map.ensureOwnership();

                var remote_shard: ?usize = null;
                for (0..map.owners.len) |i| {
                    if (map.owners[i] != fp.active_scheduler) {
                        remote_shard = i;
                        break;
                    }
                }
                try std.testing.expect(remote_shard != null);
                const key = try findKeyForShard(Map, remote_shard.?, &key_buf);

                try map.put(std.heap.c_allocator, std.heap.c_allocator, key, @as(i64, @intCast(iter)));
                try std.testing.expectEqual(@as(?i64, @intCast(iter)), map.get(key));
                try std.testing.expect(map.contains(key));
                map.remove(std.heap.c_allocator, key);
                try std.testing.expect(!map.contains(key));
                try std.testing.expectEqual(@as(i64, 0), map.count());

                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
            }
        }
    };

    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), null);
}

test "PartitionedStringMap: persistent heap-backed map survives repeated concurrent put-only batches" {
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

    const FIBERS = 4;
    const KEYS = 200;
    const ITERS = 8;

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();

            for (0..ITERS) |iter| {
                var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
                for (0..FIBERS) |i| {
                    promises[i] = try spawnMapWorker(
                        rt_ptr,
                        map,
                        @as(i64, @intCast(iter * FIBERS * KEYS + i * KEYS)),
                        KEYS,
                        .put_only,
                    );
                }
                try std.testing.expectEqual(@as(i64, 0), try waitForPromises(&promises));
            }

            try std.testing.expectEqual(@as(i64, ITERS * FIBERS * KEYS), map.count());
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "PartitionedStringMap: persistent heap-backed map survives repeated concurrent put+get batches" {
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

    const FIBERS = 4;
    const KEYS = 200;
    const ITERS = 8;

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();

            for (0..ITERS) |iter| {
                var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
                for (0..FIBERS) |i| {
                    promises[i] = try spawnMapWorker(
                        rt_ptr,
                        map,
                        @as(i64, @intCast(iter * FIBERS * KEYS + i * KEYS)),
                        KEYS,
                        .put_get,
                    );
                }
                try std.testing.expectEqual(@as(i64, FIBERS * KEYS), try waitForPromises(&promises));
            }

            try std.testing.expectEqual(@as(i64, ITERS * FIBERS * KEYS), map.count());
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "PartitionedStringMap: persistent heap-backed map survives repeated concurrent get-only batches" {
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

    const FIBERS = 4;
    const KEYS = 200;
    const ITERS = 8;

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();
            try prepopulateRange(map, 0, ITERS * FIBERS * KEYS);

            for (0..ITERS) |iter| {
                var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
                for (0..FIBERS) |i| {
                    promises[i] = try spawnMapWorker(
                        rt_ptr,
                        map,
                        @as(i64, @intCast(iter * FIBERS * KEYS + i * KEYS)),
                        KEYS,
                        .get_only,
                    );
                }
                try std.testing.expectEqual(@as(i64, FIBERS * KEYS), try waitForPromises(&promises));
            }
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "PartitionedStringMap: persistent heap-backed map survives repeated concurrent contains-only batches" {
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

    const FIBERS = 4;
    const KEYS = 200;
    const ITERS = 8;

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();
            try prepopulateRange(map, 0, ITERS * FIBERS * KEYS);

            for (0..ITERS) |iter| {
                var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
                for (0..FIBERS) |i| {
                    promises[i] = try spawnMapWorker(
                        rt_ptr,
                        map,
                        @as(i64, @intCast(iter * FIBERS * KEYS + i * KEYS)),
                        KEYS,
                        .contains_only,
                    );
                }
                try std.testing.expectEqual(@as(i64, FIBERS * KEYS), try waitForPromises(&promises));
            }
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "PartitionedStringMap: persistent heap-backed map survives repeated concurrent remove-only batches" {
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

    const FIBERS = 4;
    const KEYS = 200;
    const ITERS = 8;

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();

            for (0..ITERS) |iter| {
                const batch_start = @as(i64, @intCast(iter * FIBERS * KEYS));
                try prepopulateRange(map, batch_start, FIBERS * KEYS);

                var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
                for (0..FIBERS) |i| {
                    promises[i] = try spawnMapWorker(
                        rt_ptr,
                        map,
                        batch_start + @as(i64, @intCast(i * KEYS)),
                        KEYS,
                        .remove_only,
                    );
                }
                try std.testing.expectEqual(@as(i64, FIBERS * KEYS), try waitForPromises(&promises));
                try std.testing.expectEqual(@as(i64, 0), map.count());
            }
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "PartitionedStringMap: persistent heap-backed map survives repeated concurrent blind-remove batches" {
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

    const FIBERS = 4;
    const KEYS = 200;
    const ITERS = 8;

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();

            for (0..ITERS) |iter| {
                const batch_start = @as(i64, @intCast(iter * FIBERS * KEYS));
                try prepopulateRange(map, batch_start, FIBERS * KEYS);

                var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
                for (0..FIBERS) |i| {
                    promises[i] = try spawnMapWorker(
                        rt_ptr,
                        map,
                        batch_start + @as(i64, @intCast(i * KEYS)),
                        KEYS,
                        .remove_blind_only,
                    );
                }
                try std.testing.expectEqual(@as(i64, 0), try waitForPromises(&promises));
                try std.testing.expectEqual(@as(i64, 0), map.count());
            }
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "PartitionedStringMap: persistent heap-backed map survives repeated concurrent get-remove batches" {
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

    const FIBERS = 4;
    const KEYS = 200;
    const ITERS = 8;

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();

            for (0..ITERS) |_| {
                try prepopulateRange(map, 0, FIBERS * KEYS);

                var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
                for (0..FIBERS) |i| {
                    promises[i] = try spawnMapWorker(
                        rt_ptr,
                        map,
                        @as(i64, @intCast(i * KEYS)),
                        KEYS,
                        .get_remove,
                    );
                }
                try std.testing.expectEqual(@as(i64, FIBERS * KEYS), try waitForPromises(&promises));
                try std.testing.expectEqual(@as(i64, 0), map.count());
            }
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "PartitionedStringMap: persistent heap-backed map survives repeated concurrent get-yield-remove batches" {
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

    const FIBERS = 4;
    const KEYS = 200;
    const ITERS = 8;

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();

            for (0..ITERS) |_| {
                try prepopulateRange(map, 0, FIBERS * KEYS);

                var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
                for (0..FIBERS) |i| {
                    promises[i] = try spawnMapWorker(
                        rt_ptr,
                        map,
                        @as(i64, @intCast(i * KEYS)),
                        KEYS,
                        .get_yield_remove,
                    );
                }
                try std.testing.expectEqual(@as(i64, FIBERS * KEYS), try waitForPromises(&promises));
                try std.testing.expectEqual(@as(i64, 0), map.count());
            }
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "PartitionedStringMap: persistent heap-backed map survives repeated concurrent get-remove batches on large stacks" {
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

    const FIBERS = 4;
    const KEYS = 200;
    const ITERS = 8;

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();

            for (0..ITERS) |_| {
                try prepopulateRange(map, 0, FIBERS * KEYS);

                var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
                for (0..FIBERS) |i| {
                    promises[i] = try spawnMapWorkerWithStack(
                        rt_ptr,
                        map,
                        @as(i64, @intCast(i * KEYS)),
                        KEYS,
                        .get_remove,
                        .Large,
                    );
                }
                try std.testing.expectEqual(@as(i64, FIBERS * KEYS), try waitForPromises(&promises));
                try std.testing.expectEqual(@as(i64, 0), map.count());
            }
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "PartitionedStringMap: forced same-remote-shard get-remove batches" {
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

    const FIBERS = 4;
    const KEYS = 128;

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();

            const shard = findRemoteShard(map) orelse return error.SkipZigTest;
            const keys = try allocKeysForShard(alloc, shard, FIBERS * KEYS, "same-remote");
            defer freeKeys(alloc, keys);

            for (keys) |key| try map.put(std.heap.c_allocator, std.heap.c_allocator, key, 1);

            var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
            for (0..FIBERS) |i| {
                const begin = i * KEYS;
                promises[i] = try spawnKeyWorker(rt_ptr, map, keys[begin .. begin + KEYS], .get_remove);
            }

            try std.testing.expectEqual(@as(i64, FIBERS * KEYS), try waitForPromises(&promises));
            try std.testing.expectEqual(@as(i64, 0), map.count());
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "PartitionedStringMap: disjoint-shard get-remove batches" {
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

    const FIBERS = 4;
    const KEYS = 96;

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();

            const prefixes = [_][]const u8{ "disjoint-a", "disjoint-b", "disjoint-c", "disjoint-d" };
            var key_sets: [FIBERS][][]u8 = undefined;
            defer for (key_sets) |set| freeKeys(alloc, set);

            for (0..FIBERS) |i| {
                key_sets[i] = try allocKeysForShard(alloc, i % map.owners.len, KEYS, prefixes[i]);
            }

            for (key_sets) |set| {
                for (set) |key| try map.put(std.heap.c_allocator, std.heap.c_allocator, key, 1);
            }

            var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
            for (0..FIBERS) |i| {
                promises[i] = try spawnKeyWorker(rt_ptr, map, key_sets[i], .get_remove);
            }

            try std.testing.expectEqual(@as(i64, FIBERS * KEYS), try waitForPromises(&promises));
            try std.testing.expectEqual(@as(i64, 0), map.count());
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "PartitionedStringMap: local-owner and remote-owner get-remove batches" {
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

    const FIBERS = 4;
    const KEYS = 96;

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();

            const local_shard = findShardOwnedBy(map, fp.active_scheduler) orelse return error.SkipZigTest;
            const remote_shard = findRemoteShard(map) orelse return error.SkipZigTest;

            inline for ([_]usize{ local_shard, remote_shard }, 0..) |shard, phase| {
                const prefix = if (phase == 0) "local-owner" else "remote-owner";
                const keys = try allocKeysForShard(alloc, shard, FIBERS * KEYS, prefix);
                defer freeKeys(alloc, keys);

                for (keys) |key| try map.put(std.heap.c_allocator, std.heap.c_allocator, key, 1);

                var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
                for (0..FIBERS) |i| {
                    const begin = i * KEYS;
                    promises[i] = try spawnKeyWorker(rt_ptr, map, keys[begin .. begin + KEYS], .get_remove);
                }

                try std.testing.expectEqual(@as(i64, FIBERS * KEYS), try waitForPromises(&promises));
                try std.testing.expectEqual(@as(i64, 0), map.count());
            }
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "RemoteCall: back-to-back read then mutate calls are a reclamation barrier" {
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

    const FIBERS = 4;
    const OPS = 200;

    const State = struct { value: i64 };
    const ReadCtx = struct {
        state: *State,
        observed: i64 = -1,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fn run(raw: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(raw));
            ctx.observed = ctx.state.value;
            ctx.done.store(true, .release);
        }
    };
    const MutateCtx = struct {
        state: *State,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fn run(raw: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(raw));
            ctx.state.value += 1;
            ctx.done.store(true, .release);
        }
    };
    const WorkerCtx = struct {
        inner: *CheatLib.Promise(i64).Inner,
        bg_alloc: std.mem.Allocator,
        target: *fp.Scheduler,
        ops: usize,

        fn run(raw_rt: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const r: *Runtime = @ptrCast(@alignCast(raw_rt));
            const ctx: *@This() = @ptrCast(@alignCast(raw.?));
            defer ctx.bg_alloc.destroy(ctx);
            defer ctx.inner.wg.done();

            var total: i64 = 0;
            for (0..ctx.ops) |i| {
                const state = try alloc.create(State);
                defer alloc.destroy(state);
                state.* = .{ .value = @as(i64, @intCast(i)) };

                const read_ctx = try alloc.create(ReadCtx);
                read_ctx.* = .{ .state = state };
                sendTestRemoteCall(ctx.target, @ptrCast(&ReadCtx.run), @ptrCast(read_ctx), &read_ctx.done);
                try std.testing.expectEqual(state.value, read_ctx.observed);
                alloc.destroy(read_ctx);

                const mutate_ctx = try alloc.create(MutateCtx);
                mutate_ctx.* = .{ .state = state };
                sendTestRemoteCall(ctx.target, @ptrCast(&MutateCtx.run), @ptrCast(mutate_ctx), &mutate_ctx.done);
                alloc.destroy(mutate_ctx);

                try std.testing.expectEqual(@as(i64, @intCast(i + 1)), state.value);
                total += state.value;
                r.checkYield();
            }
            ctx.inner.result = total;
        }
    };

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;
            const target = pickRemoteScheduler() orelse return error.SkipZigTest;

            var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
            var expected_per_worker: i64 = 0;
            for (0..OPS) |i| expected_per_worker += @as(i64, @intCast(i + 1));
            for (0..FIBERS) |i| {
                const promise = try CheatLib.Promise(i64).spawn(sa, rt_ptr.getSched());
                const ctx = try sa.create(WorkerCtx);
                ctx.* = .{
                    .inner = promise.inner,
                    .bg_alloc = sa,
                    .target = target,
                    .ops = OPS,
                };
                try header.spawnPinned(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(qs.TaskFn, @ptrCast(&WorkerCtx.run)),
                    ctx,
                    .{ .stack_size = .Standard, .pinned = true },
                );
                promises[i] = promise;
            }

            try std.testing.expectEqual(@as(i64, FIBERS) * expected_per_worker, try waitForPromises(&promises));
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "Allocator: remote alloc then cross-scheduler free is safe" {
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

    const OPS = 2000;

    const Shared = struct {
        ptr: ?[*]u8 = null,
        len: usize = 64,
    };
    const AllocCtx = struct {
        shared: *Shared,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fn run(raw: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(raw));
            const mem = std.heap.c_allocator.alloc(u8, ctx.shared.len) catch @panic("alloc failed");
            @memset(mem, 0x5a);
            ctx.shared.ptr = mem.ptr;
            ctx.done.store(true, .release);
        }
    };
    const FreeCtx = struct {
        shared: *Shared,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fn run(raw: *anyopaque) void {
            const ctx: *@This() = @ptrCast(@alignCast(raw));
            const ptr = ctx.shared.ptr orelse @panic("missing ptr");
            std.heap.c_allocator.free(ptr[0..ctx.shared.len]);
            ctx.shared.ptr = null;
            ctx.done.store(true, .release);
        }
    };

    const MainFn = struct {
        fn run(_: *anyopaque, _: ?*anyopaque) anyerror!void {
            const alloc_target = pickRemoteScheduler() orelse return error.SkipZigTest;
            const free_target = fp.active_scheduler;

            for (0..OPS) |_| {
                var shared = Shared{};

                const alloc_ctx = try alloc.create(AllocCtx);
                alloc_ctx.* = .{ .shared = &shared };
                sendTestRemoteCall(alloc_target, @ptrCast(&AllocCtx.run), @ptrCast(alloc_ctx), &alloc_ctx.done);
                alloc.destroy(alloc_ctx);
                try std.testing.expect(shared.ptr != null);

                const free_ctx = try alloc.create(FreeCtx);
                free_ctx.* = .{ .shared = &shared };
                sendTestRemoteCall(free_target, @ptrCast(&FreeCtx.run), @ptrCast(free_ctx), &free_ctx.done);
                alloc.destroy(free_ctx);
                try std.testing.expect(shared.ptr == null);
            }
        }
    };

    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), null);
}

test "PartitionedStringMap: overlapping-key get-remove batches" {
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

    const FIBERS = 4;
    const KEYS = 64;

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            resetPartitionedMapCounters();

            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();

            const shard = findRemoteShard(map) orelse return error.SkipZigTest;
            const keys = try allocKeysForShard(alloc, shard, KEYS, "overlap");
            defer freeKeys(alloc, keys);

            for (keys) |key| try map.put(std.heap.c_allocator, std.heap.c_allocator, key, 1);

            var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
            for (0..FIBERS) |i| {
                promises[i] = try spawnKeyWorker(rt_ptr, map, keys, .get_remove);
            }

            const total = try waitForPromises(&promises);
            try std.testing.expect(total >= @as(i64, KEYS));
            try std.testing.expect(total <= @as(i64, FIBERS * KEYS));
            try std.testing.expectEqual(@as(i64, 0), map.count());
            try expectPartitionedMapCountersDrained();
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "PartitionedStringMap: single-worker repeated remote get-remove batches" {
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

    const KEYS = 128;
    const ITERS = 32;

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            resetPartitionedMapCounters();

            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();

            const shard = findRemoteShard(map) orelse return error.SkipZigTest;
            const keys = try allocKeysForShard(alloc, shard, KEYS, "single-worker");
            defer freeKeys(alloc, keys);

            for (0..ITERS) |_| {
                for (keys) |key| try map.put(std.heap.c_allocator, std.heap.c_allocator, key, 1);
                var promises: [1]CheatLib.Promise(i64) = .{try spawnKeyWorker(rt_ptr, map, keys, .get_remove)};
                try std.testing.expectEqual(@as(i64, KEYS), try waitForPromises(&promises));
                try std.testing.expectEqual(@as(i64, 0), map.count());
                try expectPartitionedMapCountersDrained();
            }
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "PartitionedStringMap: same-keys vs fresh-keys get-remove batches" {
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

    const FIBERS = 4;
    const KEYS = 64;
    const ITERS = 8;

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();

            const shard = findRemoteShard(map) orelse return error.SkipZigTest;
            const same_keys = try allocKeysForShard(alloc, shard, FIBERS * KEYS, "same-iter");
            defer freeKeys(alloc, same_keys);

            inline for ([_]bool{ true, false }, 0..) |reuse_keys, phase| {
                _ = phase;
                resetPartitionedMapCounters();

                for (0..ITERS) |iter| {
                    const maybe_label: ?[]u8 = if (reuse_keys) null else try std.fmt.allocPrint(alloc, "fresh-{d}", .{iter});
                    defer if (maybe_label) |label| alloc.free(label);
                    const keys = if (reuse_keys)
                        same_keys
                    else
                        try allocKeysForShard(alloc, shard, FIBERS * KEYS, maybe_label.?);
                    defer if (!reuse_keys) freeKeys(alloc, keys);

                    for (keys) |key| try map.put(std.heap.c_allocator, std.heap.c_allocator, key, 1);

                    var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
                    for (0..FIBERS) |i| {
                        const begin = i * KEYS;
                        promises[i] = try spawnKeyWorker(rt_ptr, map, keys[begin .. begin + KEYS], .get_remove);
                    }
                    try std.testing.expectEqual(@as(i64, FIBERS * KEYS), try waitForPromises(&promises));
                    try std.testing.expectEqual(@as(i64, 0), map.count());
                    try expectPartitionedMapCountersDrained();
                }
            }
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "PartitionedStringMap: get-remove ctx counters drain after each batch" {
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

    const FIBERS = 4;
    const KEYS = 64;
    const ITERS = 16;

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            resetPartitionedMapCounters();

            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();

            const shard = findRemoteShard(map) orelse return error.SkipZigTest;
            const keys = try allocKeysForShard(alloc, shard, FIBERS * KEYS, "counter-drain");
            defer freeKeys(alloc, keys);

            for (0..ITERS) |_| {
                for (keys) |key| try map.put(std.heap.c_allocator, std.heap.c_allocator, key, 1);

                var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
                for (0..FIBERS) |i| {
                    const begin = i * KEYS;
                    promises[i] = try spawnKeyWorker(rt_ptr, map, keys[begin .. begin + KEYS], .get_remove);
                }
                try std.testing.expectEqual(@as(i64, FIBERS * KEYS), try waitForPromises(&promises));
                try std.testing.expectEqual(@as(i64, 0), map.count());
                try expectPartitionedMapCountersDrained();
            }
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "PartitionedStringMap: phased get then remove batches" {
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

    const FIBERS = 4;
    const KEYS = 64;
    const ITERS = 8;

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            resetPartitionedMapCounters();

            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();

            const shard = findRemoteShard(map) orelse return error.SkipZigTest;
            const keys = try allocKeysForShard(alloc, shard, FIBERS * KEYS, "phased");
            defer freeKeys(alloc, keys);

            for (0..ITERS) |_| {
                for (keys) |key| try map.put(std.heap.c_allocator, std.heap.c_allocator, key, 1);

                var get_promises: [FIBERS]CheatLib.Promise(i64) = undefined;
                for (0..FIBERS) |i| {
                    const begin = i * KEYS;
                    get_promises[i] = try spawnKeyWorker(rt_ptr, map, keys[begin .. begin + KEYS], .get_remove);
                }

                const total = try waitForPromises(&get_promises);
                try std.testing.expect(total >= @as(i64, FIBERS * KEYS));
                try std.testing.expectEqual(@as(i64, 0), map.count());
            }
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "PartitionedStringMap: tiny 2-worker 2-key 1-remote-shard loop" {
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

    const FIBERS = 2;
    const KEYS = 2;
    const ITERS = 256;

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            resetPartitionedMapCounters();

            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();

            const shard = findRemoteShard(map) orelse return error.SkipZigTest;
            const keys = try allocKeysForShard(alloc, shard, FIBERS * KEYS, "tiny-loop");
            defer freeKeys(alloc, keys);

            for (0..ITERS) |_| {
                for (keys) |key| try map.put(std.heap.c_allocator, std.heap.c_allocator, key, 1);
                var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
                for (0..FIBERS) |i| {
                    const begin = i * KEYS;
                    promises[i] = try spawnKeyWorker(rt_ptr, map, keys[begin .. begin + KEYS], .get_remove);
                }
                try std.testing.expectEqual(@as(i64, FIBERS * KEYS), try waitForPromises(&promises));
                try std.testing.expectEqual(@as(i64, 0), map.count());
                try expectPartitionedMapCountersDrained();
            }
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "PartitionedStringMap: persistent map repeated get-remove with counters" {
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

    const FIBERS = 4;
    const KEYS = 64;
    const ITERS = 32;

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            resetPartitionedMapCounters();

            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();

            const shard = findRemoteShard(map) orelse return error.SkipZigTest;
            const keys = try allocKeysForShard(alloc, shard, FIBERS * KEYS, "persistent");
            defer freeKeys(alloc, keys);

            for (0..ITERS) |_| {
                for (keys) |key| try map.put(std.heap.c_allocator, std.heap.c_allocator, key, 1);
                var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
                for (0..FIBERS) |i| {
                    const begin = i * KEYS;
                    promises[i] = try spawnKeyWorker(rt_ptr, map, keys[begin .. begin + KEYS], .get_remove);
                }
                try std.testing.expectEqual(@as(i64, FIBERS * KEYS), try waitForPromises(&promises));
                try std.testing.expectEqual(@as(i64, 0), map.count());
                try expectPartitionedMapCountersDrained();
            }
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "PartitionedStringMap: delayed-destroy diagnostic for get-remove" {
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

    const FIBERS = 4;
    const KEYS = 64;
    const ITERS = 8;

    const MainFn = struct {
        outer_rt: *Runtime,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            resetPartitionedMapCounters();
            header.partitioned_map_delay_ctx_destroy = true;
            defer header.partitioned_map_delay_ctx_destroy = false;

            const self = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const rt_ptr = self.outer_rt;
            const sa = rt_ptr.getSched().allocator;

            const map = try sa.create(Map);
            defer {
                map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                sa.destroy(map);
            }
            map.* = .{};
            map.ensureOwnership();

            const shard = findRemoteShard(map) orelse return error.SkipZigTest;
            const keys = try allocKeysForShard(alloc, shard, FIBERS * KEYS, "delayed-destroy");
            defer freeKeys(alloc, keys);

            for (0..ITERS) |_| {
                for (keys) |key| try map.put(std.heap.c_allocator, std.heap.c_allocator, key, 1);
                var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
                for (0..FIBERS) |i| {
                    const begin = i * KEYS;
                    promises[i] = try spawnKeyWorker(rt_ptr, map, keys[begin .. begin + KEYS], .get_remove);
                }
                try std.testing.expectEqual(@as(i64, FIBERS * KEYS), try waitForPromises(&promises));
                try std.testing.expectEqual(@as(i64, 0), map.count());
            }
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(qs.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

test "PartitionedStringMap: delayed get-ctx destroy diagnostic for tiny get-remove" {
    try runTinyGetRemoveLoopWithDelays(true, false, false, false);
}

test "PartitionedStringMap: delayed remove-ctx destroy diagnostic for tiny get-remove" {
    try runTinyGetRemoveLoopWithDelays(false, true, false, false);
}

test "PartitionedStringMap: delayed key-free diagnostic for tiny get-remove" {
    try runTinyGetRemoveLoopWithDelays(false, false, true, false);
}

test "PartitionedStringMap: delayed completion-destroy diagnostic for tiny get-remove" {
    try runTinyGetRemoveLoopWithDelays(false, false, false, true);
}

test "PartitionedStringMap: tiny get-remove event log preserves per-op teardown ordering" {
    try runTinyGetRemoveLoopWithEventLog(16);
}

test "PartitionedStringMap: repeated tiny get-remove batches preserve event-log invariants" {
    try runTinyGetRemoveLoopWithEventLog(128);
}
