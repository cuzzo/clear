// ═══════════════════════════════════════════════════════════════════════════
// FFI Concurrency Test — onRootStack + std.json from multiple schedulers
//
// Reproduces the bench 24 crash: multiple fibers on different schedulers
// call readFile + std.json.parseFromSliceLeaky concurrently via onRootStack.
//
// Build: zig build-exe ffi-concurrency-test.zig switch.S onRoot.S -lc -OReleaseFast
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

const NUM_FIBERS = 20;
const ITERS_PER_FIBER = 50;
const TIMEOUT_MS: u64 = 10000;

var total_done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

const JsonRecord = struct {
    id: i64,
    data: []const i64,
};

// Worker fiber: read a JSON file and parse it, repeatedly
fn workerFn(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
    const rt: *Runtime = @ptrCast(@alignCast(raw_rt));
    const id: usize = @intFromPtr(raw_args.?);

    // Each fiber reads and parses the same file repeatedly
    const filename = "data/1.json";

    for (0..ITERS_PER_FIBER) |_| {
        // readFile via onRootStack (same path as CLEAR's readFile)
        const content = try CheatLib.readFile(rt.frameAlloc(), filename);

        // JSON parse via onRootStack (same path as CLEAR's EXTERN FN)
        const ParseCtx = struct {
            alloc: std.mem.Allocator,
            input: []const u8,
            result: ?i64 = null,
            err: ?anyerror = null,

            fn run(ptr: ?*anyopaque) callconv(.c) void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                const parsed = std.json.parseFromSliceLeaky(
                    JsonRecord,
                    self.alloc,
                    self.input,
                    .{},
                ) catch |e| {
                    self.err = e;
                    return;
                };
                var sum: i64 = 0;
                for (parsed.data) |v| sum += v;
                self.result = sum;
            }
        };
        var ctx = ParseCtx{ .alloc = rt.heapAlloc(), .input = content };
        rt.onRootStack(@as(*const fn (?*anyopaque) callconv(.c) void, &ParseCtx.run), @ptrCast(&ctx));
        if (ctx.err) |e| return e;

        // Verify result
        if (ctx.result) |sum| {
            if (sum <= 0) return error.BadResult;
        }
    }
    _ = total_done.fetchAdd(1, .release);
    _ = id;
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Create test file
    {
        const dir = try std.fs.cwd().openDir("data", .{});
        _ = dir;
    }
    {
        const sz: usize = 100;
        var buf: [4096]u8 = undefined;
        var pos: usize = 0;
        const prefix = "{\"id\":1,\"data\":[";
        @memcpy(buf[pos..][0..prefix.len], prefix);
        pos += prefix.len;
        for (1..sz + 1) |i| {
            if (i > 1) { buf[pos] = ','; pos += 1; }
            const n = std.fmt.bufPrint(buf[pos..], "{d}", .{i}) catch unreachable;
            pos += n.len;
        }
        const suffix = "]}";
        @memcpy(buf[pos..][0..suffix.len], suffix);
        pos += suffix.len;
        const file = try std.fs.cwd().createFile("data/1.json", .{});
        defer file.close();
        try file.writeAll(buf[0..pos]);
    }

    // Set up scheduler infrastructure
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

    // Spawn 3 worker schedulers (4 total = multi-scheduler)
    const WorkerCtx = struct {
        allocator: std.mem.Allocator,
        global_ctx: *EbrContext,
        stack_pool: *fm.StackPool,
        shutdown: *std.atomic.Value(bool),
    };
    var worker_ctx = WorkerCtx{
        .allocator = allocator,
        .global_ctx = &global_ctx,
        .stack_pool = &stack_pool,
        .shutdown = &shutdown,
    };

    const num_workers: usize = 3;
    var workers: [3]std.Thread = undefined;
    for (0..num_workers) |i| {
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
        }.run, .{&worker_ctx}) catch break;
    }

    while (fp.global_registry.count() < num_workers) {
        std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
    }

    // Spawn fibers (unpinned — will be distributed/stolen across schedulers)
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
            std.posix.nanosleep(TIMEOUT_MS / 1000, (TIMEOUT_MS % 1000) * std.time.ns_per_ms);
            sd.store(true, .release);
            fp.global_registry.notifyAll();
        }
    }.run, .{&shutdown});

    sched.run();

    shutdown.store(true, .release);
    fp.global_registry.notifyAll();
    for (0..num_workers) |i| workers[i].join();

    const done = total_done.load(.acquire);
    if (done < NUM_FIBERS) {
        std.debug.print("FAIL: {d}/{d} fibers completed. Crash or hang.\n", .{ done, NUM_FIBERS });
        std.process.exit(1);
    } else {
        std.debug.print("PASS: {d}/{d} fibers completed.\n", .{ done, NUM_FIBERS });
    }
}
