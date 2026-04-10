// ═══════════════════════════════════════════════════════════════════════════
// onRootStack Overhead Test
//
// Measures the cost of the fiber-to-OS-stack trampoline (onRootStack) in
// isolation, separating trampoline overhead from the work done on the
// root stack.
//
// Three measurements:
//   1. Direct call (no trampoline) - baseline
//   2. onRootStack call (trampoline) - measures switch cost
//   3. readFile via onRootStack - realistic I/O workload
//
// Build: zig build-exe test_onRootStack.zig switch.S onRoot.S -lc
// Run:   ./test_onRootStack
// ═══════════════════════════════════════════════════════════════════════════

const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = @import("runtime.zig").Runtime;
const EbrContext = @import("ebr").EbrContext;
const fc = @import("fiber-core.zig");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const qs = @import("queues.zig");

var global_ebr: EbrContext = .{};
var stack_pool: fm.StackPool = undefined;

// ── Trivial work function: just increment a counter ──
const WorkCtx = struct {
    counter: u64 = 0,
    fn run(raw: ?*anyopaque) callconv(.c) void {
        const self: *WorkCtx = @ptrCast(@alignCast(raw));
        self.counter += 1;
    }
};

// ── File I/O context: readFile via onRootStack (the bench 24 pattern) ──
const ReadCtx = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    result_len: usize = 0,
    err: ?anyerror = null,
    fn run(raw: ?*anyopaque) callconv(.c) void {
        const self: *ReadCtx = @ptrCast(@alignCast(raw));
        // Null-terminate path for openatZ
        var pathbuf: [256]u8 = undefined;
        @memcpy(pathbuf[0..self.path.len], self.path);
        pathbuf[self.path.len] = 0;
        const fd = std.posix.openatZ(std.fs.cwd().fd, pathbuf[0..self.path.len :0], .{ .ACCMODE = .RDONLY }, 0) catch |e| {
            self.err = e;
            return;
        };
        defer std.posix.close(fd);
        const stat = std.posix.fstat(fd) catch |e| {
            self.err = e;
            return;
        };
        const size: usize = @intCast(stat.size);
        const buf = self.allocator.alloc(u8, size) catch |e| {
            self.err = e;
            return;
        };
        var total: usize = 0;
        while (total < size) {
            const n = std.posix.read(fd, buf[total..]) catch |e| {
                self.err = e;
                return;
            };
            if (n == 0) break;
            total += n;
        }
        self.result_len = total;
    }
};

// ── Fiber entry: runs the benchmark from within a fiber context ──
fn benchFiber(raw_rt: *anyopaque, _: ?*anyopaque) anyerror!void {
    const rt: *Runtime = @ptrCast(@alignCast(raw_rt));
    const ITERS = 10_000;

    // --- Setup: create a small test file ---
    const test_path = "/tmp/clear_onroot_test.json";
    {
        const f = try std.fs.cwd().createFile(test_path, .{});
        defer f.close();
        try f.writeAll("{\"id\":1,\"data\":[1,2,3,4,5,6,7,8,9,10]}");
    }

    // --- 1. Direct call (no trampoline) ---
    var ctx = WorkCtx{};
    var timer = try std.time.Timer.start();
    for (0..ITERS) |_| {
        WorkCtx.run(@ptrCast(&ctx));
    }
    const direct_ns = timer.read();
    std.debug.print("Direct call:    {d} iters in {d:.3} ms ({d:.0} ns/call)\n", .{
        ITERS,
        @as(f64, @floatFromInt(direct_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(direct_ns)) / @as(f64, ITERS),
    });

    // --- 2. onRootStack call (trampoline, trivial work) ---
    ctx.counter = 0;
    timer.reset();
    for (0..ITERS) |_| {
        rt.onRootStack(
            @as(*const fn (?*anyopaque) callconv(.c) void, &WorkCtx.run),
            @ptrCast(&ctx),
        );
    }
    const trampoline_ns = timer.read();
    std.debug.print("onRootStack:    {d} iters in {d:.3} ms ({d:.0} ns/call)\n", .{
        ITERS,
        @as(f64, @floatFromInt(trampoline_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(trampoline_ns)) / @as(f64, ITERS),
    });
    std.debug.print("  trampoline overhead: {d:.0} ns/call\n", .{
        (@as(f64, @floatFromInt(trampoline_ns)) - @as(f64, @floatFromInt(direct_ns))) / @as(f64, ITERS),
    });

    // --- 3. readFile via onRootStack (realistic I/O) ---
    timer.reset();
    for (0..ITERS) |_| {
        var rctx = ReadCtx{ .allocator = rt.frameAlloc(), .path = test_path };
        rt.onRootStack(
            @as(*const fn (?*anyopaque) callconv(.c) void, &ReadCtx.run),
            @ptrCast(&rctx),
        );
        if (rctx.err) |e| {
            std.debug.print("readFile error: {}\n", .{e});
            break;
        }
    }
    const readfile_ns = timer.read();
    std.debug.print("readFile(g0):   {d} iters in {d:.3} ms ({d:.0} ns/call)\n", .{
        ITERS,
        @as(f64, @floatFromInt(readfile_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(readfile_ns)) / @as(f64, ITERS),
    });
    std.debug.print("  I/O overhead:      {d:.0} ns/call (minus trampoline)\n", .{
        (@as(f64, @floatFromInt(readfile_ns)) - @as(f64, @floatFromInt(trampoline_ns))) / @as(f64, ITERS),
    });

    // --- 4. Direct readFile (no trampoline, for comparison) ---
    timer.reset();
    for (0..ITERS) |_| {
        var rctx = ReadCtx{ .allocator = rt.frameAlloc(), .path = test_path };
        ReadCtx.run(@ptrCast(&rctx));
    }
    const direct_read_ns = timer.read();
    std.debug.print("readFile(direct):{d} iters in {d:.3} ms ({d:.0} ns/call)\n", .{
        ITERS,
        @as(f64, @floatFromInt(direct_read_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(direct_read_ns)) / @as(f64, ITERS),
    });

    std.debug.print("\nSummary:\n", .{});
    std.debug.print("  trampoline cost:  {d:.0} ns ({d:.1} us)\n", .{
        (@as(f64, @floatFromInt(trampoline_ns)) - @as(f64, @floatFromInt(direct_ns))) / @as(f64, ITERS),
        (@as(f64, @floatFromInt(trampoline_ns)) - @as(f64, @floatFromInt(direct_ns))) / @as(f64, ITERS) / 1000.0,
    });
    std.debug.print("  readFile I/O:     {d:.0} ns ({d:.1} us)\n", .{
        @as(f64, @floatFromInt(direct_read_ns)) / @as(f64, ITERS),
        @as(f64, @floatFromInt(direct_read_ns)) / @as(f64, ITERS) / 1000.0,
    });
    std.debug.print("  readFile on g0:   {d:.0} ns ({d:.1} us)\n", .{
        @as(f64, @floatFromInt(readfile_ns)) / @as(f64, ITERS),
        @as(f64, @floatFromInt(readfile_ns)) / @as(f64, ITERS) / 1000.0,
    });

    std.fs.cwd().deleteFile(test_path) catch {};
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = fp.Scheduler.init(allocator, &global_ebr, &stack_pool) catch return;
    defer {
        sched.deinit();
        fp.global_registry.deinit(allocator);
    }
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;

    var rt = try Runtime.init(allocator, 4 * 1024, &global_ebr);
    defer rt.deinit();
    rt.wireAllocator();

    const Runner = struct {
        outer_rt: *Runtime,
        fn run(_: *anyopaque, raw: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try benchFiber(@ptrCast(self.outer_rt), null);
        }
    };
    var runner = Runner{ .outer_rt = &rt };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&Runner.run)),
        &runner,
        .{ .stack_size = .Large },
    );
    sched.run();
}
