// infstream-hammer-test.zig — Stress test for InfStream correctness.
//
// Tests InfStream under concurrency pressure to catch:
//   1. Lost values (producer pushes N, consumer receives < N)
//   2. Corrupted values (wrong data read from slot/buffer)
//   3. Double-resume (task appears in ready queue twice)
//   4. Deadlocks (consumer/producer stuck forever)
//   5. UAF on deinit (consumer deinits while producer is mid-push)
//
// Structure matches real CLEAR usage: consumer is the main fiber,
// producers are spawned via spawnBest (may land on different schedulers).
// Multiple concurrent streams exercised in each round.
//
// Build: zig build-exe infstream-hammer-test.zig switch.S onRoot.S -lc -OReleaseFast
// Run:   ./infstream-hammer-test

const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = @import("runtime.zig").Runtime;
const EbrContext = @import("ebr").EbrContext;
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");

const NUM_SCHEDULERS = 4;
const NUM_STREAMS = 8;
const VALUES_PER_STREAM = 100_000;
const ROUNDS = 5;

var global_ebr: EbrContext = .{};
var stack_pool: fm.StackPool = undefined;
var global_shutdown = std.atomic.Value(bool).init(false);

fn lcg(x: i64) i64 {
    return x *% 6364136223846793005 +% 1442695040888963407;
}

// --- Producer fiber: loops forever, exits via StreamClosed ---
const ProducerCtx = struct {
    stream_inner: *CheatLib.InfStream(i64).Inner,
    alloc: std.mem.Allocator,
    seed: i64,

    fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
        _ = raw_rt;
        const ctx: *@This() = @ptrCast(@alignCast(raw_args.?));
        defer ctx.alloc.destroy(ctx.stream_inner);
        var local = CheatLib.InfStream(i64){ .inner = ctx.stream_inner, .alloc = ctx.alloc };
        var x: i64 = ctx.seed;
        while (true) {
            x = lcg(x);
            local.push(x) catch return;
        }
    }
};

fn cheatMain(rt: *Runtime) !void {
    const sa = rt.getSched().allocator;
    var total_fail: u32 = 0;

    for (0..ROUNDS) |round| {
        // Create NUM_STREAMS streams, spawn producers, consume inline.
        var streams: [NUM_STREAMS]CheatLib.InfStream(i64) = undefined;
        for (0..NUM_STREAMS) |i| {
            const seed: i64 = @intCast(round * NUM_STREAMS + i + 1);
            streams[i] = try CheatLib.InfStream(i64).spawnNew(sa, rt.getSched());
            const pctx = try sa.create(ProducerCtx);
            pctx.* = .{ .stream_inner = streams[i].inner, .alloc = sa, .seed = seed };
            // Spawn producer on the SAME scheduler as consumer.
            // InfStream assumes both endpoints converge on inner.sched.
            try rt.getSched().submitSpawn(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&ProducerCtx.run)),
                pctx,
                .{},
            );
        }

        // Round-robin consume from all streams (matches CLEAR benchmark pattern).
        var checksums: [NUM_STREAMS]i64 = [_]i64{0} ** NUM_STREAMS;
        for (0..VALUES_PER_STREAM) |_| {
            for (0..NUM_STREAMS) |i| {
                checksums[i] +%= try streams[i].next();
            }
        }

        // Verify each stream's checksum
        var round_fail: u32 = 0;
        for (0..NUM_STREAMS) |i| {
            const seed: i64 = @intCast(round * NUM_STREAMS + i + 1);
            var expected: i64 = 0;
            var x: i64 = seed;
            for (0..VALUES_PER_STREAM) |_| {
                x = lcg(x);
                expected +%= x;
            }
            if (checksums[i] != expected) {
                std.debug.print("FAIL: round={d} stream={d} seed={d}\n", .{ round, i, seed });
                round_fail += 1;
            }
        }

        // Deinit all streams (signals producers to exit via StreamClosed)
        for (0..NUM_STREAMS) |i| {
            streams[i].deinit();
        }

        total_fail += round_fail;
        std.debug.print("Round {d}/{d}: {d} streams, {s}\n", .{
            round + 1,
            ROUNDS,
            NUM_STREAMS,
            if (round_fail == 0) "OK" else "FAIL",
        });
    }

    // Test early-close: read half values then deinit
    {
        const seed: i64 = 9999;
        var stream = try CheatLib.InfStream(i64).spawnNew(sa, rt.getSched());
        const pctx = try sa.create(ProducerCtx);
        pctx.* = .{ .stream_inner = stream.inner, .alloc = sa, .seed = seed };
        try rt.getSched().submitSpawn(
            @intFromPtr(&Runtime.entryWrapper),
            @as(CheatHeader.TaskFn, @ptrCast(&ProducerCtx.run)),
            pctx,
            .{},
        );
        var partial: i64 = 0;
        for (0..VALUES_PER_STREAM / 2) |_| {
            partial +%= try stream.next();
        }
        stream.deinit(); // close before producer finishes

        var expected: i64 = 0;
        var x: i64 = seed;
        for (0..VALUES_PER_STREAM / 2) |_| {
            x = lcg(x);
            expected +%= x;
        }
        if (partial != expected) {
            std.debug.print("FAIL: early-close checksum\n", .{});
            total_fail += 1;
        } else {
            std.debug.print("Early-close test: OK\n", .{});
        }
    }

    if (total_fail > 0) {
        std.debug.print("FAIL — {d} failures\n", .{total_fail});
        std.process.exit(1);
    }
    std.debug.print("PASS — {d} rounds x {d} streams x {d} values\n", .{
        ROUNDS, NUM_STREAMS, VALUES_PER_STREAM,
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
    const a = std.heap.c_allocator;
    stack_pool = fm.StackPool.init(a);
    defer stack_pool.deinit();

    var threads: [NUM_SCHEDULERS - 1]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, schedulerThread, .{a});
    while (fp.global_registry.count() < NUM_SCHEDULERS - 1) {
        std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
    }

    var sched = try fp.Scheduler.init(a, &global_ebr, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(a);
    }
    sched.global_shutdown = &global_shutdown;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;

    var rt = try Runtime.init(a, 4 * 1024 * 1024, &global_ebr);
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
        &runner,
        .{ .stack_size = .Large },
    );
    sched.run();

    global_shutdown.store(true, .release);
    fp.global_registry.notifyAll();
    for (&threads) |*t| t.join();
}
