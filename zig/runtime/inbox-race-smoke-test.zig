const std = @import("std");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const rt_mod = @import("runtime.zig");
const ebr = @import("ebr");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = rt_mod.Runtime;
const spsc = @import("spsc.zig");

const alloc = std.heap.c_allocator;

var global_ebr: ebr.EbrContext = .{};
var stack_pool: fm.StackPool = undefined;
var global_shutdown = std.atomic.Value(bool).init(false);

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
    while (fp.global_registry.count() < n) {
        std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
    }
}

fn stopWorkers(threads: []std.Thread, n: usize) void {
    global_shutdown.store(true, .release);
    fp.global_registry.notifyAll();
    for (threads[0..n]) |*t| t.join();
    global_shutdown.store(false, .release);
}

fn withMainRuntime(comptime body: fn (*Runtime) anyerror!void) !void {
    var threads: [2]std.Thread = undefined;
    startWorkers(&threads, 2);
    defer stopWorkers(&threads, 2);

    var sched = try fp.Scheduler.init(alloc, &global_ebr, &stack_pool);
    defer {
        sched.deinit();
        fp.active_scheduler = undefined;
        fp.scheduler_running = false;
    }
    sched.global_shutdown = &global_shutdown;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;

    var rt = try Runtime.init(alloc, 4 * 1024 * 1024, &global_ebr);
    defer rt.deinit();
    rt.wireAllocator();

    const Runner = struct {
        rt: *Runtime,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try body(self.rt);
        }
    };

    var runner = Runner{ .rt = &rt };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&Runner.run)),
        &runner,
        .{ .stack_size = .Large, .pinned = true },
    );
    sched.run();
}

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

test "Inbox race smoke: repeated tiny promise batches resume correctly" {
    stack_pool = fm.StackPool.init(alloc);
    defer stack_pool.deinit();

    try withMainRuntime(struct {
        fn body(rt: *Runtime) !void {
            const rounds = 12;
            const batch = 6;

            for (0..rounds) |_| {
                var promises: [batch]CheatLib.Promise(i64) = undefined;
                for (0..batch) |i| {
                    const sa = rt.getSched().allocator;
                    const promise = try CheatLib.Promise(i64).spawn(sa, rt.getSched());
                    const ctx = try sa.create(TinyBg);
                    ctx.* = .{ .inner = promise.inner, .bg_alloc = sa };
                    try CheatHeader.spawnPinned(
                        @intFromPtr(&Runtime.entryWrapper),
                        @as(CheatHeader.TaskFn, @ptrCast(&TinyBg.run)),
                        ctx,
                        .{ .pinned = true },
                    );
                    promises[i] = promise;
                }

                var sum: i64 = 0;
                for (&promises) |*p| sum += try p.next();
                try std.testing.expectEqual(@as(i64, batch), sum);
            }
        }
    }.body);
}

const RcBundle = struct {
    rc: fp.RemoteCall,
    completion: fp.RemoteCompletion,
    result: i32 = 0,

    fn execute(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.result = 42;
    }
};

test "Inbox race smoke: repeated remote call completion survives reuse" {
    stack_pool = fm.StackPool.init(alloc);
    defer stack_pool.deinit();

    try withMainRuntime(struct {
        fn body(rt: *Runtime) !void {
            const count = fp.global_registry.count();
            if (count < 2) return error.SkipZigTest;

            for (0..40) |_| {
                const bundle = try alloc.create(RcBundle);
                defer alloc.destroy(bundle);
                bundle.* = .{
                    .rc = undefined,
                    .completion = .{ .wg = fp.WaitGroup.init(fp.active_scheduler) },
                };
                bundle.completion.wg.add(1);
                bundle.rc = .{
                    .func = &RcBundle.execute,
                    .ctx = @ptrCast(bundle),
                    .wg = &bundle.completion.wg,
                };

                const target_idx = (fp.active_scheduler.index +% 1) % count;
                const target = fp.global_registry.slots[target_idx].load(.acquire).?;
                const sender_idx = fp.active_scheduler.index;
                const ring = try target.ensureChannel(sender_idx);
                while (!ring.push(spsc.Message{
                    .tag = .RemoteCall,
                    .rc_func = @ptrCast(bundle.rc.func),
                    .rc_ctx = bundle.rc.ctx,
                    .rc_wg = @ptrCast(&bundle.completion),
                })) {
                    rt.checkYield();
                }
                _ = target.dirty_mask.fetchOr(@as(u64, 1) << @intCast(sender_idx), .seq_cst);
                target.event_fd.notify();
                bundle.completion.wg.wait();

                try std.testing.expectEqual(@as(i32, 42), bundle.result);
                rt.checkYield();
            }
        }
    }.body);
}
