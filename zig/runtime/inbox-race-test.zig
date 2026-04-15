// inbox-race-test.zig — Test for double-push of Task.inbox_link.
//
// The hypothesis: submitResume(task) can be called while task.inbox_link
// is already in the inbox (from a previous submitResume), creating a
// corrupted linked list that crashes in drainInbox.
//
// This test spawns fibers that complete very quickly, causing the
// Promise WaitGroup to fire submitResume on the parent task while
// the parent might already be in the inbox from a previous resume.
//
// Build: zig build-exe inbox-race-test.zig -lc switch.S onRoot.S -OReleaseFast
// Run:   ./inbox-race-test

const std = @import("std");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const rt_mod = @import("runtime.zig");
const ebr = @import("../lib/ebr.zig");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = rt_mod.Runtime;
const alloc = std.heap.c_allocator;

var global_ebr: ebr.EbrContext = .{};
var stack_pool: fm.StackPool = undefined;
var global_shutdown = std.atomic.Value(bool).init(false);

// Tiny BG fiber that completes immediately — maximizes the chance of
// submitResume racing with itself.
const TinyBg = struct {
    inner: *CheatLib.Promise(i64).Inner,
    bg_alloc: std.mem.Allocator,
    fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
        const ctx: *@This() = @ptrCast(@alignCast(raw.?));
        defer ctx.bg_alloc.destroy(ctx);
        defer ctx.inner.wg.done();
        ctx.inner.result = 1;
    }
};

fn cheatMain(rt: *Runtime) !void {
    // Spawn many tiny fibers in rapid succession and NEXT them.
    // Each NEXT blocks the parent, and the BG fiber's wg.done()
    // calls submitResume on the parent. If two complete close together,
    // both might call submitResume before the parent is dequeued.
    const ROUNDS = 50;
    const BATCH = 8;

    for (0..ROUNDS) |round| {
        var promises: [BATCH]CheatLib.Promise(i64) = undefined;
        for (0..BATCH) |i| {
            const sa = rt.getSched().allocator;
            const promise = try CheatLib.Promise(i64).spawn(sa, rt.getSched());
            const ctx = try sa.create(TinyBg);
            ctx.* = .{ .inner = promise.inner, .bg_alloc = sa };
            try CheatHeader.spawnPinned(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&TinyBg.run)),
                ctx, .{ .pinned = true },
            );
            promises[i] = promise;
        }
        // Collect all — each NEXT may trigger the race
        var sum: i64 = 0;
        for (&promises) |*p| sum += p.next();
        if (sum != BATCH) {
            std.debug.print("FAIL round {d}: sum={d}\n", .{ round, sum });
            return error.WrongResult;
        }
    }
    std.debug.print("PASS — {d} rounds x {d} fibers\n", .{ ROUNDS, BATCH });
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
    stack_pool = fm.StackPool.init(alloc);
    defer stack_pool.deinit();
    global_shutdown.store(false, .release);

    // 2 workers
    var threads: [2]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, schedulerThread, .{alloc});
    while (fp.global_registry.count() < 2) std.posix.nanosleep(0, 1 * std.time.ns_per_ms);

    var sched = try fp.Scheduler.init(alloc, &global_ebr, &stack_pool);
    defer { sched.deinit(); fp.global_registry.deinit(alloc); }
    sched.global_shutdown = &global_shutdown;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;

    var rt = try Runtime.init(alloc, 4 * 1024 * 1024, &global_ebr);
    defer rt.deinit();
    rt.wireAllocator();

    const Runner = struct {
        outer_rt: *Runtime,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try cheatMain(self.outer_rt);
        }
    };
    var runner = Runner{ .outer_rt = &rt };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&Runner.run)),
        &runner, .{ .stack_size = .Large },
    );
    sched.run();

    global_shutdown.store(true, .release);
    fp.global_registry.notifyAll();
    for (&threads) |*t| t.join();
}
