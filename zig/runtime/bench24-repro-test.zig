// Exact reproduction of bench 24 crash using the CLEAR-generated code.
// This file contains the EXACT handleClient, generateJson, parseJsonArraySum,
// and sizeForId functions from the transpiler output, with a minimal
// multi-scheduler TCP harness.

const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;
const fc = @import("fiber-core.zig");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const qs = @import("queues.zig");

const NUM_CLIENTS = 10;
const MSGS_PER_CLIENT = 20; // mix of SET and GET
const PORT: u16 = 16394;
const TIMEOUT_MS: u64 = 15000;

var total_done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// ---- EXACT CLEAR-generated code (copy-pasted from bench24_src.zig) ----

const JsonRecord = struct { id: i64, data: []i64 };
const std_json = @import("std").json;
const std_fs = @import("std").fs;
const Dir = std_fs.Dir;

fn sizeForId(id: i64) i64 {
    return CheatLib.intAdd(@mod(CheatLib.intAdd(CheatLib.intMul(id, 7), 13), 997), 10);
}

fn generateJson(rt: *Runtime, id: i64) ![]const u8 {
    _ = &rt;
    const sz: i64 = sizeForId(id);
    var parts = std.ArrayListUnmanaged([]const u8){};
    _ = &parts;
    defer parts.deinit(rt.frameAlloc());
    {
        var __for_1: i64 = 1;
        while (__for_1 <= sz) : (__for_1 += 1) {
            const i: i64 = __for_1;
            _ = &i;
            try parts.append(rt.frameAlloc(), try CheatLib.intToString(rt.frameAlloc(), i));
            rt.checkYield();
        }
    }
    return try std.mem.concat(rt.frameAlloc(), u8, &.{
        "{\"id\":",
        try CheatLib.intToString(rt.frameAlloc(), id),
        ",\"data\":[",
        try CheatLib.join(rt.frameAlloc(), parts, @as([]const u8, ",")),
        "]}",
    });
}

fn handleClient(rt: *Runtime, client: i32) !void {
    const frame_mark = rt.saveFrameMark();
    defer rt.restoreFrameMark(frame_mark);

    var running: bool = true;
    while (running) {
        const __loop_mark_1 = rt.saveLoopMark();
        defer rt.restoreLoopMark(__loop_mark_1);

        const data: []const u8 = try CheatLib.socketRead(rt.frameAlloc(), client);
        if (CheatLib.len(data) == 0) {
            running = false;
        } else {
            var resp: []const u8 = "";
            var pos: i64 = 0;
            while (pos < CheatLib.len(data)) {
                var eol: i64 = pos;
                while (eol < CheatLib.len(data) and
                    !CheatLib.eql(try CheatLib.charAtCodepoint(rt.frameAlloc(), data, eol), "\r") and
                    !CheatLib.eql(try CheatLib.charAtCodepoint(rt.frameAlloc(), data, eol), "\n"))
                {
                    eol = CheatLib.intAdd(eol, 1);
                    rt.checkYield();
                }
                const line: []const u8 = try CheatLib.substr(rt.frameAlloc(), data, pos, CheatLib.intSub(eol, pos));
                pos = eol;
                while (pos < CheatLib.len(data) and
                    (CheatLib.eql(try CheatLib.charAtCodepoint(rt.frameAlloc(), data, pos), "\r") or
                    CheatLib.eql(try CheatLib.charAtCodepoint(rt.frameAlloc(), data, pos), "\n")))
                {
                    pos = CheatLib.intAdd(pos, 1);
                    rt.checkYield();
                }
                if (CheatLib.len(line) == 0) {} else if (std.mem.startsWith(u8, line, "SET:")) {
                    const idStr = try CheatLib.substr(rt.frameAlloc(), line, 4, CheatLib.intSub(CheatLib.len(line), 4));
                    const id: i64 = @intFromFloat(((std.fmt.parseFloat(f64, idStr) catch null) orelse 0.0));
                    const json = try generateJson(rt, id);
                    const __n = std.fmt.count("data/{d}.json", .{id});
                    const __buf = try rt.frameAlloc().alloc(u8, __n);
                    _ = std.fmt.bufPrint(__buf, "data/{d}.json", .{id}) catch unreachable;
                    try CheatLib.writeFile(__buf, json);
                    resp = try std.mem.concat(rt.frameAlloc(), u8, &.{ resp, "+OK\r\n" });
                } else if (CheatLib.eql(line, "QUIT")) {
                    resp = try std.mem.concat(rt.frameAlloc(), u8, &.{ resp, "+OK\r\n" });
                    running = false;
                } else if (CheatLib.eql(line, "READY?")) {
                    resp = try std.mem.concat(rt.frameAlloc(), u8, &.{ resp, "+READY\r\n" });
                } else {
                    resp = try std.mem.concat(rt.frameAlloc(), u8, &.{ resp, "-ERR unknown\r\n" });
                }
                rt.checkYield();
            }
            if (CheatLib.len(resp) > 0) {
                try CheatLib.socketWriteVoid(client, resp);
            }
        }
        rt.checkYield();
    }
}

// ---- Test harness ----

fn bgRun(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
    const __rt = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
    const client_fd: i32 = @intCast(@intFromPtr(raw_args.?));
    defer CheatLib.socketClose(client_fd);
    try handleClient(__rt, client_fd);
    _ = total_done.fetchAdd(1, .release);
}

fn acceptFn(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
    _ = raw_rt;
    const server_fd: i32 = @intCast(@intFromPtr(raw_args.?));
    for (0..NUM_CLIENTS) |_| {
        const client_fd = try CheatLib.socketAccept(server_fd);
        // UNPINNED spawn — same as CLEAR's spawnBest
        try CheatHeader.spawnBest(
            @intFromPtr(&Runtime.entryWrapper),
            @as(qs.TaskFn, @ptrCast(&bgRun)),
            @ptrFromInt(@as(usize, @intCast(client_fd))),
            .{ .stack_size = .Standard },  // Same as CLEAR's default
        );
    }
}

fn clientThread(id: usize) void {
    std.posix.nanosleep(0, 200 * std.time.ns_per_ms);
    const fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0) catch return;
    defer std.posix.close(fd);
    const addr = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, PORT),
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
        .zero = [_]u8{0} ** 8,
    };
    std.posix.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) catch return;
    var buf: [4096]u8 = undefined;
    // Send SET commands (generates JSON files)
    for (0..MSGS_PER_CLIENT) |i| {
        const cmd = std.fmt.bufPrint(&buf, "SET:{d}\r\n", .{id * MSGS_PER_CLIENT + i + 1}) catch return;
        _ = std.posix.write(fd, cmd) catch return;
        // Read response
        var got: usize = 0;
        while (got < 5) { // "+OK\r\n"
            const n = std.posix.read(fd, buf[got..]) catch return;
            if (n == 0) return;
            got += n;
        }
    }
    _ = std.posix.write(fd, "QUIT\r\n") catch {};
    _ = std.posix.read(fd, &buf) catch {};
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // Create data directory
    std.fs.cwd().makePath("data") catch {};

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

    // 3 workers (4 schedulers total)
    const WorkerCtx = struct {
        allocator: std.mem.Allocator,
        global_ctx: *EbrContext,
        stack_pool: *fm.StackPool,
        shutdown: *std.atomic.Value(bool),
    };
    var wctx = WorkerCtx{ .allocator = allocator, .global_ctx = &global_ctx, .stack_pool = &stack_pool, .shutdown = &shutdown };
    var workers: [3]std.Thread = undefined;
    for (0..3) |i| {
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
    }
    while (fp.global_registry.count() < 3) std.posix.nanosleep(0, std.time.ns_per_ms);

    const server_fd = try CheatLib.socketListen(PORT);
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&acceptFn)),
        @ptrFromInt(@as(usize, @intCast(server_fd))),
        .{ .stack_size = .Standard },
    );

    var client_threads: [NUM_CLIENTS]std.Thread = undefined;
    for (0..NUM_CLIENTS) |i| {
        client_threads[i] = try std.Thread.spawn(.{}, clientThread, .{i});
    }

    _ = try std.Thread.spawn(.{}, struct {
        fn run(sd: *std.atomic.Value(bool)) void {
            std.posix.nanosleep(TIMEOUT_MS / 1000, (TIMEOUT_MS % 1000) * std.time.ns_per_ms);
            sd.store(true, .release);
            fp.global_registry.notifyAll();
        }
    }.run, .{&shutdown});

    sched.run();
    for (0..NUM_CLIENTS) |i| client_threads[i].join();
    shutdown.store(true, .release);
    fp.global_registry.notifyAll();
    for (0..3) |i| workers[i].join();
    std.posix.close(server_fd);

    const d = total_done.load(.acquire);
    if (d < NUM_CLIENTS) {
        std.debug.print("FAIL: {d}/{d} clients. Crash.\n", .{ d, NUM_CLIENTS });
        std.process.exit(1);
    }
    std.debug.print("PASS: {d}/{d} clients completed.\n", .{ d, NUM_CLIENTS });
}
