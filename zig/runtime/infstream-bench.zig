// infstream-bench.zig — InfStream throughput micro-benchmark.
//
// Measures raw YIELD/NEXT throughput for a single producer/consumer pair.
// Reports values/sec and ns/value.
//
// Build: zig build-exe infstream-bench.zig switch.S onRoot.S -lc -OReleaseFast
// Run:   ./infstream-bench

const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = @import("runtime.zig").Runtime;
const EbrContext = @import("ebr").EbrContext;
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");

const NUM_VALUES = 1_000_000;

var global_ebr: EbrContext = .{};
var stack_pool: fm.StackPool = undefined;

const ProducerCtx = struct {
    stream_inner: *CheatLib.InfStream(i64).Inner,
    alloc: std.mem.Allocator,

    fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
        _ = raw_rt;
        const ctx: *@This() = @ptrCast(@alignCast(raw_args.?));
        defer ctx.alloc.destroy(ctx.stream_inner);
        var local = CheatLib.InfStream(i64){ .inner = ctx.stream_inner, .alloc = ctx.alloc };
        var x: i64 = 42;
        while (true) {
            x = x *% 6364136223846793005 +% 1442695040888963407;
            local.push(x) catch return;
        }
    }
};

fn cheatMain(rt: *Runtime) !void {
    const sa = rt.getSched().allocator;

    var stream = try CheatLib.InfStream(i64).spawnNew(sa, rt.getSched());
    const pctx = try sa.create(ProducerCtx);
    pctx.* = .{ .stream_inner = stream.inner, .alloc = sa };
    try CheatHeader.spawnBest(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&ProducerCtx.run)),
        pctx,
        .{},
    );

    const t0 = std.time.nanoTimestamp();
    var total: i64 = 0;
    for (0..NUM_VALUES) |_| {
        total +%= try stream.next();
    }
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - t0);

    stream.deinit();

    const elapsed_ms = elapsed_ns / 1_000_000;
    const ns_per_val = elapsed_ns / NUM_VALUES;
    const vals_per_sec = if (elapsed_ns > 0) NUM_VALUES * 1_000_000_000 / elapsed_ns else 0;

    std.debug.print("InfStream throughput:\n", .{});
    std.debug.print("  Values:      {d}\n", .{NUM_VALUES});
    std.debug.print("  Time:        {d} ms\n", .{elapsed_ms});
    std.debug.print("  Throughput:  {d} vals/sec\n", .{vals_per_sec});
    std.debug.print("  Latency:     {d} ns/val\n", .{ns_per_val});
    std.debug.print("  Checksum:    {d}\n", .{total});
}

pub fn main() !void {
    const a = std.heap.c_allocator;
    stack_pool = fm.StackPool.init(a);
    defer stack_pool.deinit();

    // Single scheduler — producer and consumer on same thread.
    var sched = try fp.Scheduler.init(a, &global_ebr, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(a);
    }
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
}
