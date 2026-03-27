// routing-crash-test.zig — Hammer test for cross-scheduler map routing.
//
// Reproduces the EXACT transpiled CLEAR pattern:
//   - entryWrapper (per-fiber Runtime with stack-carved frame arena)
//   - Promise + WaitGroup for BG block join
//   - spawnPinned for fiber distribution
//   - PartitionedStringMap with cold-path routing
//   - GPA allocator (thread_safe = true)
//
// Runs N iterations, each spawning 4 pinned fibers that put+get keys on
// a shared map. Validates correctness after every iteration.
//
// Build: zig build-exe routing-crash-test.zig -lc switch.S onRoot.S -OReleaseFast
// Run:   ./routing-crash-test

const std = @import("std");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const rt_mod = @import("runtime.zig");
const ebr = @import("ebr.zig");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = rt_mod.Runtime;

var global_ebr: ebr.EbrContext = .{};
var stack_pool: fm.StackPool = undefined;
var global_shutdown = std.atomic.Value(bool).init(false);

const Map = CheatLib.PartitionedStringMap(i64, 4);
const KEYS_PER_FIBER = 500;
const FIBERS = 4;
const ITERATIONS = 5;

// ── Worker function (runs inside entryWrapper, like transpiled CLEAR) ──
fn doWork(rt: *Runtime, map: anytype, start: i64, count: i64) !i64 {
    var i: i64 = start;
    while (i < start + count) : (i += 1) {
        // Build key using heapAlloc (same as transpiled CLEAR: rt.heapAlloc())
        const key = try CheatLib.intToString(rt.heapAlloc(), i);
        try map.put(rt.heapAlloc(), rt.heapAlloc(), key, i);
        rt.checkYield();
    }
    var hits: i64 = 0;
    i = start;
    while (i < start + count) : (i += 1) {
        const key = try CheatLib.intToString(rt.heapAlloc(), i);
        if (map.get(key)) |_| hits += 1;
        rt.checkYield();
    }
    return hits;
}

// ── BG context (mirrors transpiler output exactly) ──
const BgCtx = struct {
    inner: *CheatLib.Promise(i64).Inner,
    alloc: std.mem.Allocator,
    map: *Map,
    start: i64,
    count: i64,

    fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
        const rt: *Runtime = @ptrCast(@alignCast(raw_rt));
        const ctx: *@This() = @ptrCast(@alignCast(raw_args.?));
        defer ctx.alloc.destroy(ctx);
        defer ctx.inner.wg.done();
        ctx.inner.result = try doWork(rt, ctx.map, ctx.start, ctx.count);
    }
};

// ── cheatMain equivalent ──
fn cheatMain(rt: *Runtime) !void {
    for (0..ITERATIONS) |iter| {
        var map: Map = .{};

        // Spawn FIBERS pinned fibers, each doing KEYS_PER_FIBER ops
        var promises: [FIBERS]CheatLib.Promise(i64) = undefined;
        for (0..FIBERS) |fi| {
            const sched_alloc = rt.getSched().allocator;
            const promise = try CheatLib.Promise(i64).spawn(sched_alloc, rt.getSched());
            const ctx = try sched_alloc.create(BgCtx);
            ctx.* = .{
                .inner = promise.inner,
                .alloc = sched_alloc,
                .map = &map,
                .start = @as(i64, @intCast(fi)) * KEYS_PER_FIBER,
                .count = KEYS_PER_FIBER,
            };
            try CheatHeader.spawnPinned(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&BgCtx.run)),
                ctx,
                .{ .stack_size = .Xl, .pinned = true },
            );
            promises[fi] = promise;
        }

        // Collect results
        var total_hits: i64 = 0;
        for (&promises) |*p| total_hits += p.next();

        const expected: i64 = FIBERS * KEYS_PER_FIBER;
        if (total_hits != expected) {
            std.debug.print("FAIL iter {d}: {d}/{d} hits\n", .{ iter, total_hits, expected });
            return error.CorruptData;
        }

        // Clean up map (use c_allocator since PartitionedStringMap uses remote_alloc internally)
        map.deinit(std.heap.c_allocator, std.heap.c_allocator);
    }
    std.debug.print("PASS — {d} iterations, {d} fibers x {d} keys each, all verified\n", .{
        ITERATIONS, FIBERS, KEYS_PER_FIBER,
    });
}

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

pub fn main() !void {
    // Use GPA with thread_safe (same as transpiled CLEAR runtime)
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    global_shutdown.store(false, .release);

    // Parse worker count from argv or default to 2
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const num_workers: usize = if (args.len > 1) std.fmt.parseInt(usize, args[1], 10) catch 2 else 2;

    std.debug.print("Workers: {d}\n", .{num_workers});

    var threads: [8]std.Thread = undefined;
    for (0..num_workers) |i| {
        threads[i] = try std.Thread.spawn(.{}, schedulerThread, .{allocator});
    }
    if (num_workers > 0) {
        while (fp.global_registry.count() < num_workers) {
            std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
        }
    }

    // Main scheduler
    var sched = try fp.Scheduler.init(allocator, &global_ebr, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(allocator);
    }
    sched.global_shutdown = &global_shutdown;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;

    // Run cheatMain as a fiber (same as runtime-footer.zig)
    const MainRunner = struct {
        outer_rt: *Runtime,
        fn run(_: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw_args.?));
            try cheatMain(self.outer_rt);
        }
    };
    var rt = try Runtime.init(allocator, 4 * 1024 * 1024, &global_ebr);
    defer rt.deinit();
    rt.wireAllocator();

    var main_runner = MainRunner{ .outer_rt = &rt };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&MainRunner.run)),
        &main_runner,
        .{ .stack_size = .Large },
    );
    sched.run();

    global_shutdown.store(true, .release);
    fp.global_registry.notifyAll();
    for (0..num_workers) |i| threads[i].join();
}
