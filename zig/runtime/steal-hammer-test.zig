// ═══════════════════════════════════════════════════════════════════════════
// Work-Stealing Hammer Test — NO I/O
//
// Tests whether work-stealing itself is broken, independent of networking.
// Spawns many unpinned fibers that do:
//   - Frame arena allocation + rewind (restoreLoopMark pattern)
//   - onRootStack calls (like readFile/writeFile)
//   - Frequent coopYield (makes fibers stealable)
//   - Compute work with verifiable results
//
// If work-stealing has a general bug, this test should crash or produce
// wrong results in ReleaseFast. If it passes, the bug is networking-specific.
//
// Build: zig build-exe steal-hammer-test.zig switch.S onRoot.S -lc -OReleaseFast
// ═══════════════════════════════════════════════════════════════════════════

const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;
const fc = @import("fiber-core.zig");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const qs = @import("queues.zig");
const build_options = @import("build_options");

const NUM_SCHEDULERS = if (build_options.coverage) 2 else 8;
const NUM_FIBERS = if (build_options.coverage) 16 else 200;
const ITERATIONS = if (build_options.coverage) 20 else 500;

var completed: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var correct: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// Pure compute with a verifiable result.
fn heavyCompute(seed: u64, n: usize) u64 {
    var x: u64 = seed;
    for (0..n) |_| {
        x = x *% 6364136223846793005 +% 1442695040888963407;
        x ^= x >> 17;
    }
    return x;
}

// Context for onRootStack call — simulates what readFile/writeFile do:
// run a function on the scheduler's OS stack, read/write through a pointer.
const RootCtx = struct {
    seed: u64,
    result: u64 = 0,
    fn run(ptr: ?*anyopaque) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        // Do compute on the root stack (like readFile does file I/O)
        self.result = heavyCompute(self.seed, 100);
    }
};

fn workerFn(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
    const rt: *Runtime = @ptrCast(@alignCast(raw_rt));
    const fiber_id: u64 = @intFromPtr(raw_args.?);

    const frame_mark = rt.saveFrameMark();
    defer rt.restoreFrameMark(frame_mark);

    var checksum: u64 = fiber_id;

    for (0..ITERATIONS) |iter| {
        // 1. Save loop mark (like transpiled WHILE loop)
        const loop_mark = rt.saveLoopMark();

        // 2. Allocate from frame arena (like socketRead's allocator.dupe)
        const alloc = rt.frameAlloc();
        const buf = alloc.alloc(u8, 128) catch {
            rt.restoreLoopMark(loop_mark);
            continue;
        };
        // Write a pattern we can verify
        for (buf, 0..) |*b, i| {
            b.* = @truncate(fiber_id +% iter +% i);
        }

        // 3. coopYield — makes this fiber stealable
        rt.checkYield();

        // 4. onRootStack call (like readFile)
        var root_ctx = RootCtx{ .seed = fiber_id +% iter };
        rt.onRootStack(@as(*const fn (?*anyopaque) callconv(.c) void, &RootCtx.run), @ptrCast(&root_ctx));
        checksum ^= root_ctx.result;

        // 5. More compute + coopYield
        checksum ^= heavyCompute(fiber_id +% iter, 50);
        rt.checkYield();

        // 6. Verify the arena buffer wasn't corrupted
        var ok = true;
        for (buf, 0..) |b, i| {
            const expected: u8 = @truncate(fiber_id +% iter +% i);
            if (b != expected) {
                ok = false;
                break;
            }
        }
        if (!ok) {
            std.debug.print("CORRUPT: fiber={d} iter={d}\n", .{ fiber_id, iter });
        }

        // 7. Restore loop mark (rewind arena)
        rt.restoreLoopMark(loop_mark);
    }

    // Verify checksum is deterministic (same result regardless of stealing)
    const expected = blk: {
        var c: u64 = fiber_id;
        for (0..ITERATIONS) |iter| {
            c ^= heavyCompute(fiber_id +% iter, 100); // onRootStack result
            c ^= heavyCompute(fiber_id +% iter, 50);  // inline compute
        }
        break :blk c;
    };
    if (checksum == expected) {
        _ = correct.fetchAdd(1, .monotonic);
    } else {
        std.debug.print("WRONG: fiber={d} got={x} expected={x}\n", .{ fiber_id, checksum, expected });
    }
    _ = completed.fetchAdd(1, .release);
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var global_ctx = EbrContext{};
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var shutdown = std.atomic.Value(bool).init(false);

    // Main scheduler
    var sched = fp.Scheduler.init(allocator, &global_ctx, &stack_pool) catch return;
    defer sched.deinit();
    sched.shutdown_on_idle = false;
    sched.global_shutdown = &shutdown;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;

    // Worker schedulers
    const WorkerCtx = struct {
        allocator: std.mem.Allocator,
        global_ctx: *EbrContext,
        stack_pool: *fm.StackPool,
        shutdown: *std.atomic.Value(bool),
    };
    var wctx = WorkerCtx{
        .allocator = allocator,
        .global_ctx = &global_ctx,
        .stack_pool = &stack_pool,
        .shutdown = &shutdown,
    };

    var workers: [NUM_SCHEDULERS - 1]std.Thread = undefined;
    var spawned: usize = 0;
    for (0..NUM_SCHEDULERS - 1) |i| {
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
        spawned += 1;
    }
    while (fp.global_registry.count() < spawned) {
        std.posix.nanosleep(0, std.time.ns_per_ms);
    }

    // Spawn all fibers via spawnBest (distributes across schedulers)
    for (0..NUM_FIBERS) |i| {
        try CheatHeader.spawnBest(
            @intFromPtr(&Runtime.entryWrapper),
            @as(qs.TaskFn, @ptrCast(&workerFn)),
            @ptrFromInt(i + 1),
            .{ .stack_size = .Large },
        );
    }

    // Run main scheduler until all fibers complete (no epoll, no I/O)
    const deadline = std.time.milliTimestamp() + 30_000;
    while (completed.load(.acquire) < NUM_FIBERS and std.time.milliTimestamp() < deadline) {
        sched.drainChannels();
        if (sched.ready_queue.len() > 0) {
            const task = sched.ready_queue.pop() orelse continue;
            sched.current_task = task;
            fc.__current_task_fn = @intFromPtr(task.user_fn);
            fc.__current_task_size = task.base.size_class;
            task.base.switchTo(&sched.main_ctx);
            switch (task.status.load(.acquire)) {
                .Finished => {
                    _ = sched.active_tasks.fetchSub(1, .monotonic);
                    sched.releaseTaskEbr(task);
                    sched.stack_pool.free(task.base.stack.memory);
                    sched.allocator.destroy(task.base);
                    sched.task_slab.destroy(task);
                },
                .Ready => {
                    sched.ready_queue.push(sched.allocator, task) catch unreachable;
                },
                .Blocked => {},
            }
        } else {
            std.Thread.yield() catch {};
        }
    }

    shutdown.store(true, .release);
    fp.global_registry.notifyAll();
    for (0..spawned) |i| workers[i].join();

    const done = completed.load(.acquire);
    const ok = correct.load(.acquire);
    if (done == NUM_FIBERS and ok == NUM_FIBERS) {
        std.debug.print("PASS: {d}/{d} fibers, all checksums correct.\n", .{ done, NUM_FIBERS });
    } else {
        std.debug.print("FAIL: {d}/{d} completed, {d}/{d} correct.\n", .{ done, NUM_FIBERS, ok, NUM_FIBERS });
        std.process.exit(1);
    }
}
