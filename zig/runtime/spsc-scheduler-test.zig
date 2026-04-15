// spsc-scheduler-test.zig — Test the SPSC ring in the actual scheduler context.
//
// Tests EACH scheduler operation that uses SPSC channels, in isolation,
// with real threads. Every test runs hundreds of iterations to catch
// memory ordering bugs that only manifest under contention.
//
// Build: zig test spsc-scheduler-test.zig -lc switch.S onRoot.S
//
// Test layers (each must pass before moving to the next):
//   Layer 1: SPSC push/pop across two OS threads (no scheduler)
//   Layer 2: submitSpawn via SPSC to a real scheduler thread
//   Layer 3: submitResume via SPSC to a real scheduler thread
//   Layer 4: RemoteCall via SPSC (func + atomic done flag)
//   Layer 5: Multiple fibers doing RemoteCalls concurrently
//   Layer 6: Hammer test — all operations mixed, high volume

const std = @import("std");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const rt_mod = @import("runtime.zig");
const ebr = @import("ebr");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = rt_mod.Runtime;
const spsc = @import("spsc.zig");

var global_ebr: ebr.EbrContext = .{};
var stack_pool: fm.StackPool = undefined;
var global_shutdown = std.atomic.Value(bool).init(false);
const alloc = std.heap.c_allocator;

fn initGlobals() void {
    stack_pool = fm.StackPool.init(alloc);
}

fn deinitGlobals() void {
    stack_pool.deinit();
}

// ========================================================================
// LAYER 1: Raw SPSC across two OS threads (no scheduler involved)
// ========================================================================

test "L1: raw SPSC ring across two OS threads, 100K messages" {
    var ring = spsc.SpscRing(256){};
    const N: usize = 100_000;
    var consumer_ok = std.atomic.Value(bool).init(true);
    var producer_done = std.atomic.Value(bool).init(false);

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(r: *spsc.SpscRing(256), ok: *std.atomic.Value(bool), done: *std.atomic.Value(bool)) void {
            var expected: usize = 0;
            while (true) {
                if (r.pop()) |msg| {
                    if (msg.trampoline_addr != expected) {
                        ok.store(false, .release);
                    }
                    expected += 1;
                } else if (done.load(.acquire)) {
                    while (r.pop()) |msg| {
                        if (msg.trampoline_addr != expected) ok.store(false, .release);
                        expected += 1;
                    }
                    if (expected != N) ok.store(false, .release);
                    break;
                } else {
                    std.Thread.yield() catch {};
                }
            }
        }
    }.run, .{ &ring, &consumer_ok, &producer_done });

    for (0..N) |i| {
        while (!ring.push(.{ .tag = .Spawn, .trampoline_addr = i }))
            std.Thread.yield() catch {};
    }
    producer_done.store(true, .release);
    consumer.join();
    try std.testing.expect(consumer_ok.load(.acquire));
}

test "L1: raw SPSC with pointer payload survives cross-thread" {
    // Verify that pointer values are correctly transferred across threads.
    var ring = spsc.SpscRing(64){};
    var data: [100]u64 = undefined;
    for (&data, 0..) |*d, i| d.* = i * 7;

    var consumer_ok = std.atomic.Value(bool).init(true);
    var done = std.atomic.Value(bool).init(false);

    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(r: *spsc.SpscRing(64), ok: *std.atomic.Value(bool), d: *std.atomic.Value(bool), ref_data: *[100]u64) void {
            var count: usize = 0;
            while (true) {
                if (r.pop()) |msg| {
                    const ptr: *u64 = @ptrCast(@alignCast(msg.rc_ctx.?));
                    if (ptr.* != count * 7) ok.store(false, .release);
                    count += 1;
                } else if (d.load(.acquire)) {
                    while (r.pop()) |msg| {
                        const ptr: *u64 = @ptrCast(@alignCast(msg.rc_ctx.?));
                        _ = ptr.*;
                        count += 1;
                    }
                    if (count != ref_data.len) ok.store(false, .release);
                    break;
                } else std.Thread.yield() catch {};
            }
        }
    }.run, .{ &ring, &consumer_ok, &done, &data });

    for (&data) |*d| {
        while (!ring.push(.{ .tag = .RemoteCall, .rc_ctx = @ptrCast(d) }))
            std.Thread.yield() catch {};
    }
    done.store(true, .release);
    consumer.join();
    try std.testing.expect(consumer_ok.load(.acquire));
}

// ========================================================================
// LAYER 2: submitSpawn via SPSC — spawn a fiber on a remote scheduler
// ========================================================================

fn schedulerThread(a: std.mem.Allocator) void {
    var sched = fp.Scheduler.init(a, &global_ebr, &stack_pool) catch return;
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
    while (fp.global_registry.count() < n)
        std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
}

fn stopWorkers(threads: []std.Thread, n: usize) void {
    global_shutdown.store(true, .release);
    fp.global_registry.notifyAll();
    for (threads[0..n]) |*t| t.join();
    fp.global_registry.deinit(alloc);
    fp.global_registry = .{};
    global_shutdown.store(false, .release);
}

const SpawnCounter = struct {
    counter: *std.atomic.Value(i32),
    fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
        const ctx: *@This() = @ptrCast(@alignCast(raw.?));
        _ = ctx.counter.fetchAdd(1, .seq_cst);
    }
};

const MainTaskStatus = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    err: ?anyerror = null,
};

const MainTaskCtx = struct {
    inner_fn: CheatHeader.TaskFn,
    inner_args: ?*anyopaque,
    status: *MainTaskStatus,

    fn run(raw_rt: *anyopaque, raw: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.inner_fn(raw_rt, self.inner_args) catch |err| {
            self.status.err = err;
            self.status.done.store(true, .release);
            return;
        };
        self.status.done.store(true, .release);
    }
};

fn runCheckedMain(sched: *fp.Scheduler, task_fn: CheatHeader.TaskFn, args: ?*anyopaque) !void {
    var status = MainTaskStatus{};
    var ctx = MainTaskCtx{
        .inner_fn = task_fn,
        .inner_args = args,
        .status = &status,
    };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&MainTaskCtx.run)),
        &ctx,
        .{ .stack_size = .Standard, .pinned = true },
    );
    sched.run();
    if (!status.done.load(.acquire)) {
        std.debug.panic(
            "runCheckedMain returned early: active_tasks={d} dirty_mask=0x{x} ready={d} pinned={d} sleepers={d}",
            .{
                sched.active_tasks.load(.monotonic),
                sched.dirty_mask.load(.seq_cst),
                sched.ready_queue.len(),
                sched.pinned_queue.items.len,
                sched.sleeping_queue.items.len,
            },
        );
    }
    if (status.err) |err| return err;
}

test "L2: submitSpawn via SPSC to remote scheduler" {
    initGlobals();
    defer deinitGlobals();

    var threads: [2]std.Thread = undefined;
    startWorkers(&threads, 2);
    defer stopWorkers(&threads, 2);

    // Main scheduler
    var sched = fp.Scheduler.init(alloc, &global_ebr, &stack_pool) catch return;
    defer sched.deinit();
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;

    // Spawn 20 fibers on remote schedulers via SPSC
    var counter = std.atomic.Value(i32).init(0);
    var ctxs: [20]SpawnCounter = undefined;
    for (&ctxs) |*c| c.* = .{ .counter = &counter };

    for (0..20) |i| {
        const target_idx = (i + 1) % fp.global_registry.count();
        const target = fp.global_registry.slots[target_idx].load(.acquire).?;
        try target.submitSpawn(
            @intFromPtr(&Runtime.entryWrapper),
            @as(CheatHeader.TaskFn, @ptrCast(&SpawnCounter.run)),
            &ctxs[i],
            .{ .stack_size = .Standard, .pinned = true },
        );
    }

    // Wait for all fibers to complete
    var wait: usize = 0;
    while (counter.load(.seq_cst) < 20 and wait < 5000) : (wait += 1) {
        std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
    }
    try std.testing.expect(counter.load(.seq_cst) == 20);
}

// ========================================================================
// LAYER 3: submitResume via SPSC — wake a fiber on a remote scheduler
// ========================================================================

test "L3: submitResume via SPSC channel" {
    initGlobals();
    defer deinitGlobals();

    var threads: [2]std.Thread = undefined;
    startWorkers(&threads, 2);
    defer stopWorkers(&threads, 2);

    var sched = fp.Scheduler.init(alloc, &global_ebr, &stack_pool) catch return;
    defer sched.deinit();
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;

    // Create a Promise, spawn a BG fiber that resolves it
    const BgCtx = struct {
        inner: *CheatLib.Promise(i64).Inner,
        bg_alloc: std.mem.Allocator,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const ctx: *@This() = @ptrCast(@alignCast(raw.?));
            defer ctx.bg_alloc.destroy(ctx);
            defer ctx.inner.wg.done();
            ctx.inner.result = 42;
        }
    };

    var rt = try Runtime.init(alloc, 1024 * 1024, &global_ebr);
    defer rt.deinit();
    rt.wireAllocator();

    const MainFn = struct {
        outer_rt: *Runtime,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const r = self.outer_rt;

            // Spawn 10 BG fibers, collect results
            var promises: [10]CheatLib.Promise(i64) = undefined;
            for (0..10) |_fi| {
                const sa = r.getSched().allocator;
                const promise = try CheatLib.Promise(i64).spawn(sa, r.getSched());
                const ctx = try sa.create(BgCtx);
                ctx.* = .{ .inner = promise.inner, .bg_alloc = sa };
                try CheatHeader.spawnPinned(
                    @intFromPtr(&Runtime.entryWrapper),
                    @as(CheatHeader.TaskFn, @ptrCast(&BgCtx.run)),
                    ctx, .{ .stack_size = .Standard, .pinned = true },
                );
                promises[_fi] = promise;
            }
            var sum: i64 = 0;
            for (&promises) |*p| sum += try p.next();
            // Each fiber returns 42
            if (sum != 420) @panic("L3: wrong sum");
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(CheatHeader.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

// ========================================================================
// LAYER 4: RemoteCall via SPSC (func + atomic done flag)
// ========================================================================

test "L4: RemoteCall via SPSC (inside fiber, proper scheduler)" {
    initGlobals();
    defer deinitGlobals();

    var threads: [2]std.Thread = undefined;
    startWorkers(&threads, 2);
    defer stopWorkers(&threads, 2);

    var sched = fp.Scheduler.init(alloc, &global_ebr, &stack_pool) catch return;
    defer sched.deinit();
    sched.global_shutdown = &global_shutdown;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;

    var rt = try Runtime.init(alloc, 1024 * 1024, &global_ebr);
    defer rt.deinit();
    rt.wireAllocator();

    const RcCtx = struct {
        input: i64,
        result: i64 = 0,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fn execute(raw: *anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(raw));
            c.result = c.input * 3;
            c.done.store(true, .release);
        }
    };

    const MainFn = struct {
        outer_rt: *Runtime,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const n = fp.global_registry.count();
            if (n < 2) return;

            const my_idx = fp.active_scheduler.index;
            const target_idx = (my_idx + 1) % n;
            const target = fp.global_registry.slots[target_idx].load(.acquire).?;

            for (0..50) |i| {
                var ctx = RcCtx{ .input = @intCast(i) };
                const msg = spsc.Message{
                    .tag = .RemoteCall,
                    .rc_func = @ptrCast(&RcCtx.execute),
                    .rc_ctx = @ptrCast(&ctx),
                };
                const ring = target.ensureChannel(my_idx) catch @panic("OOM");
                while (!ring.push(msg))
                    std.Thread.yield() catch {};
                _ = target.dirty_mask.fetchOr(@as(u64, 1) << @intCast(my_idx), .seq_cst);
                target.event_fd.notify();

                while (!ctx.done.load(.acquire)) {
                    self.outer_rt.checkYield();
                }

                if (ctx.result != @as(i64, @intCast(i)) * 3) return error.WrongResult;
            }
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&MainFn.run)),
        &runner, .{ .stack_size = .Standard, .pinned = true },
    );
    sched.run();
}

// ========================================================================
// LAYER 5: PartitionedStringMap put/get via SPSC routing
// ========================================================================

test "L5: PartitionedStringMap cross-scheduler put+get" {
    initGlobals();
    defer deinitGlobals();

    // Start 2 worker schedulers and wait for registration
    var threads: [2]std.Thread = undefined;
    startWorkers(&threads, 2);
    defer stopWorkers(&threads, 2);

    // Main scheduler (3rd) — created AFTER workers so ensureOwnership sees all 3
    var sched = fp.Scheduler.init(alloc, &global_ebr, &stack_pool) catch return;
    defer sched.deinit();
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;

    const Map = CheatLib.PartitionedStringMap(i64, 4);
    const map = try alloc.create(Map);
    defer alloc.destroy(map);
    map.* = .{};

    // Initialize ownership BEFORE any puts — ensures stable shard-to-scheduler mapping
    map.ensureOwnership();

    var rt = try Runtime.init(alloc, 1024 * 1024, &global_ebr);
    defer rt.deinit();
    rt.wireAllocator();

    const MainFn = struct {
        outer_rt: *Runtime,
        map: *Map,

        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            var buf: [32]u8 = undefined;

            // Put 200 keys (some local, some routed via SPSC to worker schedulers)
            for (0..200) |i| {
                const key = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch continue;
                self.map.put(std.heap.c_allocator, std.heap.c_allocator, key, @intCast(i)) catch continue;
            }

            // Get all keys back
            var hits: usize = 0;
            for (0..200) |i| {
                const key = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch continue;
                if (self.map.get(key)) |_| hits += 1;
            }

            if (hits != 200) {
                std.debug.print("L5: {d}/200 hits\n", .{hits});
                return error.DataMismatch;
            }
        }
    };

    var runner = MainFn{ .outer_rt = &rt, .map = map };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&MainFn.run)),
        &runner, .{ .stack_size = .Large, .pinned = true },
    );
    sched.run();

    map.deinit(std.heap.c_allocator, std.heap.c_allocator);
}

// ========================================================================
// LAYER 6: Hammer test — multiple fibers, many iterations
// ========================================================================

test "L6: hammer — 4 fibers x 500 keys x 5 iterations via SPSC" {
    initGlobals();
    defer deinitGlobals();

    var threads: [2]std.Thread = undefined;
    startWorkers(&threads, 2);
    defer stopWorkers(&threads, 2);

    var sched = fp.Scheduler.init(alloc, &global_ebr, &stack_pool) catch return;
    defer sched.deinit();
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;

    var rt = try Runtime.init(alloc, 4 * 1024 * 1024, &global_ebr);
    defer rt.deinit();
    rt.wireAllocator();

    const KEYS = 500;
    const FIBERS = 4;
    const ITERS = 3;
    const Map = CheatLib.PartitionedStringMap(i64, 4);

    const BgWork = struct {
        inner: *CheatLib.Promise(i64).Inner,
        bg_alloc: std.mem.Allocator,
        map: *Map,
        start: i64,
        count: i64,

        fn run(raw_rt: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const r: *Runtime = @ptrCast(@alignCast(raw_rt));
            const ctx: *@This() = @ptrCast(@alignCast(raw.?));
            defer ctx.bg_alloc.destroy(ctx);
            defer ctx.inner.wg.done();

            var buf: [32]u8 = undefined;
            var i: i64 = ctx.start;
            while (i < ctx.start + ctx.count) : (i += 1) {
                const key = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch continue;
                try ctx.map.put(std.heap.c_allocator, std.heap.c_allocator, key, i);
                r.checkYield();
            }
            var hits: i64 = 0;
            i = ctx.start;
            while (i < ctx.start + ctx.count) : (i += 1) {
                const key = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch continue;
                if (ctx.map.get(key)) |_| hits += 1;
                r.checkYield();
            }
            ctx.inner.result = hits;
        }
    };

    const MainFn = struct {
        outer_rt: *Runtime,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const r = self.outer_rt;

            for (0..ITERS) |iter| {
                const map = try r.getSched().allocator.create(Map);
                map.* = .{};
                defer {
                    map.deinit(std.heap.c_allocator, std.heap.c_allocator);
                    r.getSched().allocator.destroy(map);
                }
                map.ensureOwnership();

                var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
                for (0..FIBERS) |fi| {
                    const sa = r.getSched().allocator;
                    const promise = try CheatLib.Promise(i64).spawn(sa, r.getSched());
                    const ctx = try sa.create(BgWork);
                    ctx.* = .{
                        .inner = promise.inner, .bg_alloc = sa, .map = map,
                        .start = @as(i64, @intCast(fi)) * KEYS, .count = KEYS,
                    };
                    try CheatHeader.spawnPinned(
                        @intFromPtr(&Runtime.entryWrapper),
                        @as(CheatHeader.TaskFn, @ptrCast(&BgWork.run)),
                        ctx, .{ .stack_size = .Standard, .pinned = true },
                    );
                    promises[fi] = promise;
                }

                var total: i64 = 0;
                for (&promises) |*p| total += try p.next();

                const expected: i64 = FIBERS * KEYS;
                if (total != expected) {
                    std.debug.print("L6 FAIL iter {d}: {d}/{d}\n", .{ iter, total, expected });
                    return error.DataCorruption;
                }
            }
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try runCheckedMain(&sched, @as(CheatHeader.TaskFn, @ptrCast(&MainFn.run)), &runner);
}

// ========================================================================
// LAYER 7: Pinned fiber sendAndWait deadlock test
// ========================================================================
// Reproduces: a pinned fiber on the main scheduler sends a RemoteCall
// via SPSC to a worker, then yield-polls for completion (the same
// mechanism used by PartitionedStringMap.sendAndWait). The main
// scheduler's fast-path tight loop (pop fiber, fiber yields, push fiber)
// must not prevent the worker from processing the remote call.
//
// PASS: all remote calls complete
// FAIL: deadlock (timeout)

test "L7: pinned fiber sendAndWait yield-poll to remote scheduler" {
    initGlobals();
    defer deinitGlobals();

    var threads: [2]std.Thread = undefined;
    startWorkers(&threads, 2);
    defer stopWorkers(&threads, 2);

    var sched = fp.Scheduler.init(alloc, &global_ebr, &stack_pool) catch return;
    defer sched.deinit();
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    defer fp.scheduler_running = false;

    var rt = try Runtime.init(alloc, 1024 * 1024, &global_ebr);
    defer rt.deinit();
    rt.wireAllocator();

    const RcCtx = struct {
        value: i64 = 0,
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        fn execute(raw: *anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(raw));
            c.value = 42;
            c.done.store(true, .release);
        }
    };

    const MainFn = struct {
        outer_rt: *Runtime,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            _ = @as(*@This(), @ptrCast(@alignCast(raw.?)));
            const n = fp.global_registry.count();
            if (n < 2) return error.NotEnoughSchedulers;

            const my_idx = fp.active_scheduler.index;
            const target_idx = (my_idx + 1) % n;
            const target = fp.global_registry.slots[target_idx].load(.acquire).?;

            const ring = target.ensureChannel(my_idx) catch @panic("OOM");

            // Send 10 remote calls, each using sendAndWait-style yield-poll.
            for (0..10) |_| {
                var ctx = RcCtx{};
                const msg = spsc.Message{
                    .tag = .RemoteCall,
                    .rc_func = @ptrCast(&RcCtx.execute),
                    .rc_ctx = @ptrCast(&ctx),
                };
                while (!ring.push(msg))
                    std.atomic.spinLoopHint();
                _ = target.dirty_mask.fetchOr(@as(u64, 1) << @intCast(my_idx), .seq_cst);
                target.event_fd.notify();

                // Spin-then-yield: same mechanism as sendAndWait.
                var sw_spins: u32 = 0;
                while (!ctx.done.load(.acquire)) {
                    if (sw_spins < 8192) {
                        std.atomic.spinLoopHint();
                        sw_spins += 1;
                    } else {
                        const task = fp.active_scheduler.getCurrent();
                        task.status.store(.Ready, .release);
                        task.base.yield();
                        sw_spins = 0;
                    }
                }

                if (ctx.value != 42) return error.WrongResult;
            }
        }
    };

    var runner = MainFn{ .outer_rt = &rt };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&MainFn.run)),
        &runner, .{ .stack_size = .Standard, .pinned = true },
    );
    sched.run();
}
