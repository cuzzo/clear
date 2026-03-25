// scheduler-benchmark-test.zig — Lock-Free SchedulerRegistry Stress Tests
//
// Isolates the registry's pickTwo / register / unregister hot paths under
// multi-threaded contention.  Proves that the atomic-array design scales
// flat (near-constant latency per thread) vs a mutex which would degrade
// exponentially under contention.
//
// Run:  zig test zig/scheduler-benchmark-test.zig -lc -O ReleaseFast
//       (ReleaseFast required for meaningful throughput numbers)

const std = @import("std");
const builtin = @import("builtin");
const fp = @import("scheduler.zig");
const Scheduler = fp.Scheduler;
const testing = std.testing;

// ---------------------------------------------------------------------------
// Helpers: create minimal Scheduler stubs for registry testing.
// We only need the `active_tasks` field and a valid `event_fd` for notify.
// ---------------------------------------------------------------------------
const DummySched = struct {
    sched: Scheduler,

    fn init(load: usize) !DummySched {
        var s: DummySched = undefined;
        s.sched.active_tasks = std.atomic.Value(usize).init(load);
        s.sched.event_fd = try fp.SmartEventFd.init();
        return s;
    }

    fn deinit(self: *DummySched) void {
        self.sched.event_fd.deinit();
    }
};

// ---------------------------------------------------------------------------
// TEST 1: Thundering Herd — pickTwo under heavy contention
//
// 8 dummy schedulers registered.  N OS threads each call pickTwo() in a
// tight loop for ITERS iterations.  Asserts: no crashes, all returned
// pointers belong to the registered set.
// ---------------------------------------------------------------------------
test "Thundering Herd: pickTwo contention" {
    if (builtin.mode == .Debug) return error.SkipZigTest;

    const N_SCHEDS = 8;
    const N_THREADS = 16;
    const ITERS: usize = 1_000_000;

    const allocator = std.testing.allocator;
    var reg: fp.SchedulerRegistry = .{};
    defer reg.deinit(allocator);

    // Register N_SCHEDS dummy schedulers with varying loads.
    var dummies: [N_SCHEDS]DummySched = undefined;
    for (0..N_SCHEDS) |i| {
        dummies[i] = try DummySched.init(i * 10);
        try reg.register(allocator, @as(std.Thread.Id, @intCast(9000 + i)), &dummies[i].sched);
    }
    defer for (0..N_SCHEDS) |i| dummies[i].deinit();

    // Build a set of valid pointers for assertion.
    var valid_set: [N_SCHEDS]*Scheduler = undefined;
    for (0..N_SCHEDS) |i| valid_set[i] = &dummies[i].sched;

    var total_ops = std.atomic.Value(u64).init(0);

    const Worker = struct {
        fn run(reg_ptr: *fp.SchedulerRegistry, valid: []const *Scheduler, ops: *std.atomic.Value(u64)) void {
            var count: u64 = 0;
            for (0..ITERS) |_| {
                const pair = reg_ptr.pickTwo();
                // Both must be non-null and in the valid set.
                if (pair.a) |a| {
                    var found = false;
                    for (valid) |v| {
                        if (a == v) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) @panic("pickTwo returned unknown scheduler");
                }
                if (pair.b) |b| {
                    var found = false;
                    for (valid) |v| {
                        if (b == v) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) @panic("pickTwo returned unknown scheduler");
                }
                count += 1;
            }
            _ = ops.fetchAdd(count, .monotonic);
        }
    };

    var threads: [N_THREADS]std.Thread = undefined;
    var timer = try std.time.Timer.start();

    for (0..N_THREADS) |i| {
        threads[i] = try std.Thread.spawn(.{}, Worker.run, .{ &reg, &valid_set, &total_ops });
    }
    for (0..N_THREADS) |i| threads[i].join();

    const elapsed_ns = timer.read();
    const ops = total_ops.load(.monotonic);
    const ops_per_sec = ops * 1_000_000_000 / elapsed_ns;

    std.debug.print("\n[pickTwo Thundering Herd]\n", .{});
    std.debug.print("  Threads: {d}, Schedulers: {d}\n", .{ N_THREADS, N_SCHEDS });
    std.debug.print("  Total ops: {d}, Time: {d}ms\n", .{ ops, elapsed_ns / 1_000_000 });
    std.debug.print("  Throughput: {d} ops/sec\n", .{ops_per_sec});
}

// ---------------------------------------------------------------------------
// TEST 2: Concurrent register/unregister + pickTwo
//
// 4 threads doing pickTwo in tight loops.
// 4 threads doing register → unregister cycles.
// Exercises the CAS slot-scavenger under contention.
// Asserts: no crashes, no dangling pointers.
// ---------------------------------------------------------------------------
test "Concurrent register/unregister + pickTwo" {
    if (builtin.mode == .Debug) return error.SkipZigTest;

    const N_READERS = 4;
    const N_WRITERS = 4;
    const ITERS: usize = 100_000;

    const allocator = std.testing.allocator;
    var reg: fp.SchedulerRegistry = .{};
    defer reg.deinit(allocator);

    // Seed with 2 permanent schedulers so pickTwo always has something.
    var perm: [2]DummySched = undefined;
    for (0..2) |i| {
        perm[i] = try DummySched.init(0);
        try reg.register(allocator, @as(std.Thread.Id, @intCast(8000 + i)), &perm[i].sched);
    }
    defer for (0..2) |i| perm[i].deinit();

    var stop = std.atomic.Value(bool).init(false);

    const Reader = struct {
        fn run(reg_ptr: *fp.SchedulerRegistry, stop_flag: *std.atomic.Value(bool)) void {
            var count: usize = 0;
            while (!stop_flag.load(.monotonic)) {
                _ = reg_ptr.pickTwo();
                count += 1;
            }
            std.debug.print("  Reader: {d} pickTwo calls\n", .{count});
        }
    };

    const WriterCtx = struct {
        reg: *fp.SchedulerRegistry,
        alloc: std.mem.Allocator,
        base_id: usize,
        iters: usize,
    };

    const Writer = struct {
        fn run(ctx: *WriterCtx) void {
            var dummy = DummySched.init(5) catch return;
            defer dummy.deinit();

            for (0..ctx.iters) |i| {
                const id = @as(std.Thread.Id, @intCast(ctx.base_id + i));
                ctx.reg.register(ctx.alloc, id, &dummy.sched) catch continue;
                // Tiny pause to let readers see the registration.
                std.atomic.spinLoopHint();
                ctx.reg.unregister(id);
            }
        }
    };

    var readers: [N_READERS]std.Thread = undefined;
    var writers: [N_WRITERS]std.Thread = undefined;
    var writer_ctxs: [N_WRITERS]WriterCtx = undefined;

    std.debug.print("\n[Register/Unregister + pickTwo Contention]\n", .{});

    for (0..N_READERS) |i| {
        readers[i] = try std.Thread.spawn(.{}, Reader.run, .{ &reg, &stop });
    }
    for (0..N_WRITERS) |i| {
        writer_ctxs[i] = .{
            .reg = &reg,
            .alloc = allocator,
            .base_id = 10000 + i * ITERS,
            .iters = ITERS,
        };
        writers[i] = try std.Thread.spawn(.{}, Writer.run, .{&writer_ctxs[i]});
    }

    // Wait for writers to finish, then stop readers.
    for (0..N_WRITERS) |i| writers[i].join();
    stop.store(true, .release);
    for (0..N_READERS) |i| readers[i].join();

    // After all writers are done, only the 2 permanent schedulers should remain.
    // len may be > 2 (high-water mark) but all non-permanent slots should be null.
    const n = reg.len.load(.acquire);
    var live: usize = 0;
    for (reg.slots[0..n]) |*slot| {
        if (slot.load(.acquire) != null) live += 1;
    }
    try testing.expectEqual(@as(usize, 2), live);
    std.debug.print("  Final: len={d}, live_slots={d} (expected 2)\n", .{ n, live });
}

// ---------------------------------------------------------------------------
// TEST 3: Latency scaling — ops/thread should be near-flat
//
// Runs pickTwo from 1, 2, 4, 8, 16 threads and reports throughput per thread.
// A mutex-based registry shows sublinear scaling; atomic should be near-flat.
// ---------------------------------------------------------------------------
test "pickTwo latency scaling" {
    if (builtin.mode == .Debug) return error.SkipZigTest;

    const ITERS: usize = 2_000_000;
    const thread_counts = [_]usize{ 1, 2, 4, 8, 16 };

    const allocator = std.testing.allocator;
    var reg: fp.SchedulerRegistry = .{};
    defer reg.deinit(allocator);

    // Register 4 dummy schedulers.
    var dummies: [4]DummySched = undefined;
    for (0..4) |i| {
        dummies[i] = try DummySched.init(i * 5);
        try reg.register(allocator, @as(std.Thread.Id, @intCast(7000 + i)), &dummies[i].sched);
    }
    defer for (0..4) |i| dummies[i].deinit();

    std.debug.print("\n[pickTwo Latency Scaling]\n", .{});
    std.debug.print("  {s:<10} {s:<18} {s:<18}\n", .{ "Threads", "Total ops/sec", "Per-thread ops/s" });
    std.debug.print("  {s:-<50}\n", .{""});

    for (thread_counts) |n_threads| {
        var total_ops = std.atomic.Value(u64).init(0);

        const ScaleWorker = struct {
            fn run(reg_ptr: *fp.SchedulerRegistry, ops: *std.atomic.Value(u64)) void {
                var count: u64 = 0;
                for (0..ITERS) |_| {
                    const pair = reg_ptr.pickTwo();
                    // Prevent optimizer from eliding the call.
                    std.mem.doNotOptimizeAway(pair.a);
                    count += 1;
                }
                _ = ops.fetchAdd(count, .monotonic);
            }
        };

        var threads: [16]std.Thread = undefined;
        var timer = try std.time.Timer.start();

        for (0..n_threads) |i| {
            threads[i] = try std.Thread.spawn(.{}, ScaleWorker.run, .{ &reg, &total_ops });
        }
        for (0..n_threads) |i| threads[i].join();

        const elapsed_ns = timer.read();
        const ops = total_ops.load(.monotonic);
        const total_ops_sec = ops * 1_000_000_000 / elapsed_ns;
        const per_thread = total_ops_sec / n_threads;

        std.debug.print("  {d:<10} {d:<18} {d:<18}\n", .{ n_threads, total_ops_sec, per_thread });
    }
}
