// scheduler-race-test.zig — Isolate which scheduler component races.
//
// Tests each cross-scheduler primitive independently:
//   Test 1: submitSpawn across schedulers (no RemoteCall, no WaitGroup)
//   Test 2: submitResume across schedulers (task parking/waking)
//   Test 3: RemoteCall only (no map, just func+wg)
//   Test 4: RemoteCall + WaitGroup (the full cold-path pattern)
//   Test 5: Multiple concurrent RemoteCalls from different fibers
//
// Build: zig build-exe scheduler-race-test.zig -lc switch.S onRoot.S -OReleaseFast
// Run:   ./scheduler-race-test

const std = @import("std");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const rt_mod = @import("runtime.zig");
const ebr = @import("ebr.zig");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = rt_mod.Runtime;
const WaitGroup = fp.WaitGroup;

var global_ebr: ebr.EbrContext = .{};
var stack_pool: fm.StackPool = undefined;
var global_shutdown = std.atomic.Value(bool).init(false);
const alloc = std.heap.c_allocator;

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

// ========================================================================
// Test 1: Cross-scheduler submitSpawn via Promise — spawn and join
// ========================================================================
const Test1BgCtx = struct {
    inner: *CheatLib.Promise(i64).Inner,
    bg_alloc: std.mem.Allocator,
    val: i64,
    fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
        const ctx: *@This() = @ptrCast(@alignCast(raw.?));
        defer ctx.bg_alloc.destroy(ctx);
        defer ctx.inner.wg.done();
        ctx.inner.result = ctx.val + 1;
    }
};

fn test1_cross_spawn(rt: *Runtime) !void {
    const N = 20;
    var promises: [N]CheatLib.Promise(i64) = undefined;
    for (0..N) |i| {
        const sa = rt.getSched().allocator;
        const promise = try CheatLib.Promise(i64).spawn(sa, rt.getSched());
        const ctx = try sa.create(Test1BgCtx);
        ctx.* = .{ .inner = promise.inner, .bg_alloc = sa, .val = @intCast(i) };
        try CheatHeader.spawnPinned(
            @intFromPtr(&Runtime.entryWrapper),
            @as(CheatHeader.TaskFn, @ptrCast(&Test1BgCtx.run)),
            ctx, .{ .pinned = true },
        );
        promises[i] = promise;
    }
    var sum: i64 = 0;
    for (&promises) |*p| sum += p.next();
    // sum = 1+2+...+20 = 210
    if (sum != 210) {
        std.debug.print("TEST1 FAIL: sum={d}, expected 210\n", .{sum});
        return error.TestFailed;
    }
}

// ========================================================================
// Test 2: RemoteCall only — no map, just func(ctx) + wg.done()
// ========================================================================
const Test2Bundle = struct {
    rc: fp.RemoteCall,
    wg: WaitGroup,
    result: i32 = 0,

    fn execute(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.result = 42;
    }
};

fn test2_remote_call(rt: *Runtime) !void {
    const count = fp.global_registry.count();
    if (count < 2) return; // need at least 2 schedulers

    const N = 50;
    for (0..N) |_| {
        const b = try alloc.create(Test2Bundle);
        b.wg = WaitGroup.init(fp.active_scheduler);
        b.wg.add(1);
        b.result = 0;
        b.rc = .{
            .func = &Test2Bundle.execute,
            .ctx = @ptrCast(b),
            .wg = &b.wg,
        };
        // Pick a different scheduler
        const target_idx = (fp.active_scheduler.index +% 1) % count;
        const target = fp.global_registry.slots[target_idx].load(.acquire) orelse continue;
        target.inbox.push(&b.rc.inbox_link);
        target.event_fd.notify();
        b.wg.wait();
        if (b.result != 42) {
            std.debug.print("TEST2 FAIL: result={d}\n", .{b.result});
            alloc.destroy(b);
            return error.TestFailed;
        }
        alloc.destroy(b);
        rt.checkYield();
    }
}

// ========================================================================
// Test 3: Promise + spawnPinned — BG fiber pattern without map
// ========================================================================
const Test3BgCtx = struct {
    inner: *CheatLib.Promise(i64).Inner,
    bg_alloc: std.mem.Allocator,
    input: i64,

    fn run(raw_rt: *anyopaque, raw: ?*anyopaque) anyerror!void {
        _ = raw_rt;
        const ctx: *@This() = @ptrCast(@alignCast(raw.?));
        defer ctx.bg_alloc.destroy(ctx);
        defer ctx.inner.wg.done();
        ctx.inner.result = ctx.input * 2;
    }
};

fn test3_promise_spawn(rt: *Runtime) !void {
    const N = 20;
    var promises: [N]CheatLib.Promise(i64) = undefined;

    for (0..N) |i| {
        const sa = rt.getSched().allocator;
        const promise = try CheatLib.Promise(i64).spawn(sa, rt.getSched());
        const ctx = try sa.create(Test3BgCtx);
        ctx.* = .{ .inner = promise.inner, .bg_alloc = sa, .input = @intCast(i) };
        try CheatHeader.spawnPinned(
            @intFromPtr(&Runtime.entryWrapper),
            @as(CheatHeader.TaskFn, @ptrCast(&Test3BgCtx.run)),
            ctx,
            .{ .pinned = true },
        );
        promises[i] = promise;
    }

    var sum: i64 = 0;
    for (&promises) |*p| sum += p.next();

    // sum should be 0*2 + 1*2 + ... + 19*2 = 19*20 = 380
    if (sum != 380) {
        std.debug.print("TEST3 FAIL: sum={d}, expected 380\n", .{sum});
        return error.TestFailed;
    }
}

// ========================================================================
// Test 4: Multiple fibers doing RemoteCalls concurrently
// ========================================================================
const Test4BgCtx = struct {
    inner: *CheatLib.Promise(i64).Inner,
    bg_alloc: std.mem.Allocator,
    iterations: i64,

    fn run(raw_rt: *anyopaque, raw: ?*anyopaque) anyerror!void {
        const rt: *Runtime = @ptrCast(@alignCast(raw_rt));
        const ctx: *@This() = @ptrCast(@alignCast(raw.?));
        defer ctx.bg_alloc.destroy(ctx);
        defer ctx.inner.wg.done();

        const count = fp.global_registry.count();
        if (count < 2) { ctx.inner.result = ctx.iterations; return; }

        var hits: i64 = 0;
        for (0..@intCast(ctx.iterations)) |_| {
            const b = try alloc.create(Test2Bundle);
            b.wg = WaitGroup.init(fp.active_scheduler);
            b.wg.add(1);
            b.result = 0;
            b.rc = .{ .func = &Test2Bundle.execute, .ctx = @ptrCast(b), .wg = &b.wg };
            const target_idx = (fp.active_scheduler.index +% 1) % count;
            const target = fp.global_registry.slots[target_idx].load(.acquire) orelse continue;
            target.inbox.push(&b.rc.inbox_link);
            target.event_fd.notify();
            b.wg.wait();
            if (b.result == 42) hits += 1;
            alloc.destroy(b);
            rt.checkYield();
        }
        ctx.inner.result = hits;
    }
};

fn test4_concurrent_remote(rt: *Runtime) !void {
    const FIBERS = 4;
    const OPS = 20;
    var promises: [FIBERS]CheatLib.Promise(i64) = undefined;

    for (0..FIBERS) |_fi| {
        const sa = rt.getSched().allocator;
        const promise = try CheatLib.Promise(i64).spawn(sa, rt.getSched());
        const ctx = try sa.create(Test4BgCtx);
        ctx.* = .{ .inner = promise.inner, .bg_alloc = sa, .iterations = OPS };
        try CheatHeader.spawnPinned(
            @intFromPtr(&Runtime.entryWrapper),
            @as(CheatHeader.TaskFn, @ptrCast(&Test4BgCtx.run)),
            ctx,
            .{ .pinned = true },
        );
        promises[_fi] = promise;
    }

    var total: i64 = 0;
    for (&promises) |*p| total += p.next();

    const expected: i64 = FIBERS * OPS;
    if (total != expected) {
        std.debug.print("TEST4 FAIL: {d}/{d}\n", .{ total, expected });
        return error.TestFailed;
    }
}

// ========================================================================
// Test 5: PartitionedStringMap with cross-scheduler routing
// ========================================================================
const Map = CheatLib.PartitionedStringMap(i64, 4);

const Test5BgCtx = struct {
    inner: *CheatLib.Promise(i64).Inner,
    bg_alloc: std.mem.Allocator,
    map: *Map,
    start: i64,
    count: i64,

    fn run(raw_rt: *anyopaque, raw: ?*anyopaque) anyerror!void {
        const rt: *Runtime = @ptrCast(@alignCast(raw_rt));
        const ctx: *@This() = @ptrCast(@alignCast(raw.?));
        defer ctx.bg_alloc.destroy(ctx);
        defer ctx.inner.wg.done();

        var buf: [32]u8 = undefined;
        var i: i64 = ctx.start;
        while (i < ctx.start + ctx.count) : (i += 1) {
            const key = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch continue;
            ctx.map.put(alloc, alloc, key, i) catch continue;
            rt.checkYield();
        }
        var hits: i64 = 0;
        var misses: i64 = 0;
        i = ctx.start;
        while (i < ctx.start + ctx.count) : (i += 1) {
            const key = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch continue;
            if (ctx.map.get(key)) |_| {
                hits += 1;
            } else {
                misses += 1;
                if (misses <= 3) std.debug.print("  MISS key={s} sched={d}\n", .{ key, fp.active_scheduler.index });
            }
            rt.checkYield();
        }
        ctx.inner.result = hits;
    }
};

fn test5_map_routing(rt: *Runtime) !void {
    const FIBERS = 4;
    const KEYS = 200;
    var map: Map = .{};
    defer map.deinit(alloc, alloc);

    var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
    for (0..FIBERS) |fi| {
        const sa = rt.getSched().allocator;
        const promise = try CheatLib.Promise(i64).spawn(sa, rt.getSched());
        const ctx = try sa.create(Test5BgCtx);
        ctx.* = .{
            .inner = promise.inner, .bg_alloc = sa, .map = &map,
            .start = @as(i64, @intCast(fi)) * KEYS, .count = KEYS,
        };
        try CheatHeader.spawnPinned(
            @intFromPtr(&Runtime.entryWrapper),
            @as(CheatHeader.TaskFn, @ptrCast(&Test5BgCtx.run)),
            ctx, .{ .pinned = true },
        );
        promises[fi] = promise;
    }
    var total: i64 = 0;
    for (&promises) |*p| total += p.next();
    const expected: i64 = FIBERS * KEYS;
    if (total != expected) {
        std.debug.print("TEST5 FAIL: {d}/{d} hits\n", .{ total, expected });
        return error.TestFailed;
    }
}

// ========================================================================
// Main: run cheatMain as a fiber on the main scheduler
// ========================================================================
fn cheatMain(rt: *Runtime) !void {
    std.debug.print("Test 1: cross-scheduler submitSpawn...\n", .{});
    try test1_cross_spawn(rt);
    std.debug.print("  PASS\n", .{});

    std.debug.print("Test 2: RemoteCall (func+wg, no map)...\n", .{});
    try test2_remote_call(rt);
    std.debug.print("  PASS\n", .{});

    std.debug.print("Test 3: Promise + spawnPinned...\n", .{});
    try test3_promise_spawn(rt);
    std.debug.print("  PASS\n", .{});

    std.debug.print("Test 4: concurrent RemoteCalls from 4 fibers...\n", .{});
    try test4_concurrent_remote(rt);
    std.debug.print("  PASS\n", .{});

    std.debug.print("Test 5: PartitionedStringMap with routing...\n", .{});
    try test5_map_routing(rt);
    std.debug.print("  PASS\n", .{});

    std.debug.print("\nALL TESTS PASSED\n", .{});
}

pub fn main() !void {
    stack_pool = fm.StackPool.init(alloc);
    defer stack_pool.deinit();
    global_shutdown.store(false, .release);

    var threads: [2]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, schedulerThread, .{alloc});
    while (fp.global_registry.count() < 2)
        std.posix.nanosleep(0, 1 * std.time.ns_per_ms);

    var sched = try fp.Scheduler.init(alloc, &global_ebr, &stack_pool);
    defer { sched.deinit(); fp.global_registry.deinit(alloc); }
    sched.global_shutdown = &global_shutdown;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;

    const MainRunner = struct {
        outer_rt: *Runtime,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try cheatMain(self.outer_rt);
        }
    };
    var rt = try Runtime.init(alloc, 4 * 1024 * 1024, &global_ebr);
    defer rt.deinit();
    rt.wireAllocator();

    var runner = MainRunner{ .outer_rt = &rt };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&MainRunner.run)),
        &runner, .{ .stack_size = .Large },
    );
    sched.run();

    global_shutdown.store(true, .release);
    fp.global_registry.notifyAll();
    for (&threads) |*t| t.join();
}
