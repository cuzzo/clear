// Reproduces bench 24 crash: generateJson called from unpinned fibers
// across multiple schedulers.

const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;
const fc = @import("fiber-core.zig");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const qs = @import("queues.zig");

const NUM_FIBERS = 20;
const ITERS = 100;

var done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

fn sizeForId(id: i64) i64 {
    return @mod((CheatLib.intMul(id, 7) + 13), 997) + 10;
}

// Exact replica of CLEAR's generateJson — uses frameAlloc for parts list,
// intToString, join, and concat. Includes checkYield in the loop.
fn generateJson(rt: *Runtime, id: i64) ![]const u8 {
    const sz = sizeForId(id);
    var parts = std.ArrayListUnmanaged([]const u8){};
    defer parts.deinit(rt.frameAlloc());

    var i: i64 = 1;
    while (i <= sz) : (i += 1) {
        try parts.append(rt.frameAlloc(), try CheatLib.intToString(rt.frameAlloc(), i));
        rt.checkYield(); // CLEAR emits this in every loop
    }

    return try std.mem.concat(rt.frameAlloc(), u8, &.{
        "{\"id\":",
        try CheatLib.intToString(rt.frameAlloc(), id),
        ",\"data\":[",
        try CheatLib.join(rt.frameAlloc(), parts, @as([]const u8, ",")),
        "]}",
    });
}

fn workerFn(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
    const rt: *Runtime = @ptrCast(@alignCast(raw_rt));
    const base_id: i64 = @intCast(@intFromPtr(raw_args.?));

    for (0..ITERS) |j| {
        const id = base_id * ITERS + @as(i64, @intCast(j)) + 1;
        const json = try generateJson(rt, id);
        if (json.len < 10) return error.TooShort;
        std.mem.doNotOptimizeAway(json.len);
    }
    _ = done.fetchAdd(1, .release);
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var global_ctx = EbrContext{};
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var shutdown = std.atomic.Value(bool).init(false);

    var sched = fp.Scheduler.init(allocator, &global_ctx, &stack_pool) catch return;
    defer sched.deinit();
    sched.shutdown_on_idle = false;
    sched.global_shutdown = &shutdown;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;

    // 3 worker schedulers (4 total)
    const WorkerCtx = struct {
        allocator: std.mem.Allocator,
        global_ctx: *EbrContext,
        stack_pool: *fm.StackPool,
        shutdown: *std.atomic.Value(bool),
    };
    var wctx = WorkerCtx{ .allocator = allocator, .global_ctx = &global_ctx, .stack_pool = &stack_pool, .shutdown = &shutdown };
    var workers: [3]std.Thread = undefined;
    for (0..3) |i| {
        workers[i] = std.Thread.spawn(.{}, struct {
            fn run(ctx: *WorkerCtx) void {
                var ws = fp.Scheduler.init(ctx.allocator, ctx.global_ctx, ctx.stack_pool) catch return;
                defer ws.deinit();
                ws.shutdown_on_idle = false;
                ws.global_shutdown = ctx.shutdown;
                fp.active_scheduler = &ws;
                fp.scheduler_running = true;
                ws.run();
                fp.scheduler_running = false;
            }
        }.run, .{&wctx}) catch break;
    }
    while (fp.global_registry.count() < 3) std.posix.nanosleep(0, std.time.ns_per_ms);

    // Spawn unpinned fibers
    for (0..NUM_FIBERS) |i| {
        try sched.submitSpawn(
            @intFromPtr(&Runtime.entryWrapper),
            @as(qs.TaskFn, @ptrCast(&workerFn)),
            @ptrFromInt(i),
            .{ .stack_size = .Large },
        );
    }

    // Watchdog
    _ = try std.Thread.spawn(.{}, struct {
        fn run(sd: *std.atomic.Value(bool)) void {
            std.posix.nanosleep(10, 0);
            sd.store(true, .release);
            fp.global_registry.notifyAll();
        }
    }.run, .{&shutdown});

    sched.run();
    shutdown.store(true, .release);
    fp.global_registry.notifyAll();
    for (0..3) |i| workers[i].join();

    const d = done.load(.acquire);
    if (d < NUM_FIBERS) {
        std.debug.print("FAIL: {d}/{d} fibers. Crash in generateJson.\n", .{ d, NUM_FIBERS });
        std.process.exit(1);
    }
    std.debug.print("PASS: {d}/{d} fibers completed.\n", .{ d, NUM_FIBERS });
}
