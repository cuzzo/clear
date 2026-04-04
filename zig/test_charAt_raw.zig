// test_charAt_raw.zig -- Reproduce charAt (byte-level) stall under ReleaseFast.
//
// The hypothesis: CheatLib.charAt returns a slice into the original string.
// Under ReleaseFast, LLVM optimizes the comparison away or reorders reads
// across a yield/arena-rewind boundary, causing an infinite loop or stall.
//
// Build: zig build-exe test_charAt_raw.zig switch.S onRoot.S -lc -O ReleaseFast
// Run:   ./test_charAt_raw

const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = @import("runtime.zig").Runtime;
const EbrContext = @import("ebr.zig").EbrContext;
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");

var global_ebr: EbrContext = .{};
var stack_pool: fm.StackPool = undefined;

var total_ok: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var total_fail: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

const WorkerCtx = struct {
    rt_ptr: *anyopaque,
    fn run(raw_rt: *anyopaque, raw: ?*anyopaque) anyerror!void {
        _ = raw;
        const rt: *Runtime = @ptrCast(@alignCast(raw_rt));

        const ROUNDS = 10_000;
        var ok: u64 = 0;

        for (0..ROUNDS) |_| {
            const mark = rt.saveLoopMark();
            defer rt.restoreLoopMark(mark);

            const data = try std.mem.concat(rt.frameAlloc(), u8, &.{"*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n$3\r\nbar\r\n"});

            var pos: i64 = 0;
            const ch = CheatLib.charAt(data, pos);
            if (CheatLib.eql(ch, "*")) {
                pos += 1;
                var countStr: []const u8 = "";
                while (pos < CheatLib.len(data) and !CheatLib.eql(CheatLib.charAt(data, pos), "\r")) {
                    countStr = try std.mem.concat(rt.frameAlloc(), u8, &.{ countStr, CheatLib.charAt(data, pos) });
                    pos += 1;
                    
                }
                pos += 2;
                const count = std.fmt.parseInt(i64, countStr, 10) catch 0;
                var ai: i64 = 0;
                while (ai < count and pos < CheatLib.len(data)) : (ai += 1) {
                    if (CheatLib.eql(CheatLib.charAt(data, pos), "$")) {
                        pos += 1;
                        var lenStr: []const u8 = "";
                        while (pos < CheatLib.len(data) and !CheatLib.eql(CheatLib.charAt(data, pos), "\r")) {
                            lenStr = try std.mem.concat(rt.frameAlloc(), u8, &.{ lenStr, CheatLib.charAt(data, pos) });
                            pos += 1;
                        }
                        pos += 2;
                        const blen = std.fmt.parseInt(i64, lenStr, 10) catch 0;
                        pos += blen + 2;
                    }
                }
                ok += 1;
            }
        }

        if (ok == ROUNDS) {
            _ = total_ok.fetchAdd(1, .monotonic);
        } else {
            _ = total_fail.fetchAdd(1, .monotonic);
        }
    }
};

fn cheatMain(rt: *Runtime) !void {
    const NUM_WORKERS = 50;
    const sa = rt.getSched().allocator;

    // Spawn 50 concurrent parser fibers (like 50 TCP connections)
    for (0..NUM_WORKERS) |_| {
        const ctx = try sa.create(WorkerCtx);
        ctx.* = .{ .rt_ptr = @ptrCast(rt) };
        try CheatHeader.spawnBest(
            @intFromPtr(&Runtime.entryWrapper),
            @as(CheatHeader.TaskFn, @ptrCast(&WorkerCtx.run)),
            ctx,
            .{},
        );
    }

    // Wait for all to finish
    while (total_ok.load(.monotonic) + total_fail.load(.monotonic) < NUM_WORKERS) {
        const task = fp.active_scheduler.getCurrent();
        task.status.store(.Ready, .release);
        task.base.yield();
        
    }

    const ok = total_ok.load(.monotonic);
    const fail = total_fail.load(.monotonic);
    if (fail == 0) {
        std.debug.print("PASS: {d} workers x 10000 rounds\n", .{ok});
    } else {
        std.debug.print("FAIL: {d} ok, {d} fail\n", .{ ok, fail });
        std.process.exit(1);
    }
}

pub fn main() !void {
    const a = std.heap.c_allocator;
    stack_pool = fm.StackPool.init(a);
    defer stack_pool.deinit();

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
