// v3: Hand-written handler doing same operations as transpiled code.
// If this passes, the bug is in how the transpiler generates the handler.
const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;
const fc = @import("fiber-core.zig");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const qs = @import("queues.zig");
fn transpiled_heavyCompute(seed: i64, n: i64) i64 {
    var x: i64 = seed;
    { var __for_1: i64 = 0; while (__for_1 < n) : (__for_1 += 1) { const i: i64 = __for_1; _ = &i;
        x = CheatLib.wrapAdd(CheatLib.wrapMul(x, 6364136223846793005), 1442695040888963407);
        x = CheatLib.wrapAdd(CheatLib.wrapMul(x, x), 1);
    } }
    return @mod(x, 1000000000);
}

fn transpiled_handleClient(rt: *Runtime, client: i32) !void {
    const frame_mark = rt.saveFrameMark();
    defer rt.restoreFrameMark(frame_mark);
    var running: bool = true;
    while (running) {
        const __loop_mark_1 = rt.saveLoopMark(); defer rt.restoreLoopMark(__loop_mark_1);
        var __buf: [4096]u8 = undefined; const __n = CheatLib.read(client, &__buf) catch break; if (__n == 0) break; const data: []const u8 = rt.frameAlloc().dupe(u8, __buf[0..__n]) catch break;
        { // data is non-empty
            var resp: []const u8 = "";
            var pos: i64 = 0;
            while ((pos < CheatLib.len(data))) {
                var eol: i64 = pos;
                while ((((eol < CheatLib.len(data)) and !CheatLib.eql(try CheatLib.charAtCodepoint(rt.frameAlloc(), data, eol), "\r")) and !CheatLib.eql(try CheatLib.charAtCodepoint(rt.frameAlloc(), data, eol), "\n"))) {
                    eol = CheatLib.intAdd(eol, 1);
                }
                const line: []const u8 = try CheatLib.substr(rt.frameAlloc(), data, pos, CheatLib.intSub(eol, pos));
                pos = eol;
                while (((pos < CheatLib.len(data)) and (CheatLib.eql(try CheatLib.charAtCodepoint(rt.frameAlloc(), data, pos), "\r") or CheatLib.eql(try CheatLib.charAtCodepoint(rt.frameAlloc(), data, pos), "\n")))) {
                    pos = CheatLib.intAdd(pos, 1);
                }
                if ((CheatLib.len(line) == 0)) {} else {
                    if (std.mem.startsWith(u8, line, @as([]const u8, "WORK:"))) {
                        const rest: []const u8 = try CheatLib.substr(rt.frameAlloc(), line, 5, CheatLib.intSub(CheatLib.len(line), 5));
                        var colonPos: i64 = 0;
                        while (((colonPos < CheatLib.len(rest)) and !CheatLib.eql(try CheatLib.charAtCodepoint(rt.frameAlloc(), rest, colonPos), ":"))) { colonPos = CheatLib.intAdd(colonPos, 1); }
                        const idStr: []const u8 = try CheatLib.substr(rt.frameAlloc(), rest, 0, colonPos);
                        const nStr: []const u8 = try CheatLib.substr(rt.frameAlloc(), rest, CheatLib.intAdd(colonPos, 1), CheatLib.intSub(CheatLib.intSub(CheatLib.len(rest), colonPos), 1));
                        const id: i64 = @intFromFloat((((std.fmt.parseFloat(f64, idStr) catch null)) orelse 1.0));
                        var n: i64 = @intFromFloat((((std.fmt.parseFloat(f64, nStr) catch null)) orelse 1.0));
                        if ((n < 1)) { n = 1; }
                        const result: i64 = transpiled_heavyCompute(id, n);
                        resp = @as([]const u8, try std.mem.concat(rt.frameAlloc(), u8, &.{ resp, ":", try CheatLib.intToString(rt.frameAlloc(), result), "\r\n" }));
                    } else if (CheatLib.eql(line, "QUIT")) {
                        resp = try std.mem.concat(rt.frameAlloc(), u8, &.{ resp, "+OK\r\n" }); running = false;
                    } else if (CheatLib.eql(line, "READY?")) {
                        resp = try std.mem.concat(rt.frameAlloc(), u8, &.{ resp, "+READY\r\n" });
                    } else {
                        resp = try std.mem.concat(rt.frameAlloc(), u8, &.{ resp, "-ERR unknown command\r\n" });
                    }
                }
                rt.checkYield();
            }
            if ((CheatLib.len(@as([]const u8, resp)) > 0)) { try CheatLib.socketWriteVoid(client, @as([]const u8, resp)); }
        }
        rt.checkYield();
    }
}

fn handleClient(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
    const rt: *Runtime = @ptrCast(@alignCast(raw_rt));
    const client_fd: i32 = @intCast(@intFromPtr(raw_args.?));
    defer CheatLib.socketClose(client_fd);
    try transpiled_handleClient(rt, client_fd);
}


// Hand-written: same logic as transpiled handleClient, but using
// direct byte operations instead of charAtCodepoint/substr/concat.

fn acceptFn(raw_rt: *anyopaque, _: ?*anyopaque) anyerror!void {
    _ = raw_rt;
    const server_fd = try CheatLib.socketListen(6390);
    defer CheatLib.socketClose(server_fd);
    std.debug.print("listening on 6390\n", .{});
    while (true) {
        const client_fd = try CheatLib.socketAccept(server_fd);
        try CheatHeader.spawnBest(
            @intFromPtr(&Runtime.entryWrapper),
            @as(qs.TaskFn, @ptrCast(&handleClient)),
            @ptrFromInt(@as(usize, @intCast(client_fd))),
            .{ .stack_size = .Large, .pinned = false },
        );
    }
}

const NUM_SCHEDULERS = 8;
const NUM_CLIENTS = 50;
const REQS_PER_CLIENT = 50;

fn clientThread(id: usize) void {
    std.posix.nanosleep(0, 200 * std.time.ns_per_ms);
    const fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0) catch return;
    defer std.posix.close(fd);
    const addr = std.posix.sockaddr.in{
        .family = std.posix.AF.INET, .port = std.mem.nativeToBig(u16, 6390),
        .addr = std.mem.nativeToBig(u32, 0x7f000001), .zero = [_]u8{0} ** 8,
    };
    std.posix.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) catch return;
    var buf: [4096]u8 = undefined;
    for (0..REQS_PER_CLIENT) |r| {
        const msg = std.fmt.bufPrint(&buf, "WORK:{d}:100\r\n", .{id * 10000 + r}) catch return;
        _ = std.posix.write(fd, msg) catch return;
        var got: usize = 0;
        while (got == 0 or buf[got - 1] != '\n') {
            const nr = std.posix.read(fd, buf[got..]) catch return;
            if (nr == 0) return;
            got += nr;
        }
    }
    _ = std.posix.write(fd, "QUIT\r\n") catch {};
    _ = std.posix.read(fd, &buf) catch {};
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
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

    const WorkerCtx = struct { a: std.mem.Allocator, g: *EbrContext, s: *fm.StackPool, sd: *std.atomic.Value(bool) };
    var wctx = WorkerCtx{ .a = allocator, .g = &global_ctx, .s = &stack_pool, .sd = &shutdown };
    var workers: [NUM_SCHEDULERS - 1]std.Thread = undefined;
    var nw: usize = 0;
    for (0..NUM_SCHEDULERS - 1) |i| {
        workers[i] = std.Thread.spawn(.{}, struct {
            fn run(ctx: *WorkerCtx) void {
                var ws = fp.Scheduler.init(ctx.a, ctx.g, ctx.s) catch return;
                defer ws.deinit();
                ws.shutdown_on_idle = false; ws.global_shutdown = ctx.sd;
                fp.active_scheduler = &ws; fp.scheduler_running = true;
                ws.run(); fp.scheduler_running = false;
            }
        }.run, .{&wctx}) catch break;
        nw += 1;
    }
    while (fp.global_registry.count() < nw) std.posix.nanosleep(0, std.time.ns_per_ms);

    try sched.submitSpawn(@intFromPtr(&Runtime.entryWrapper), @as(qs.TaskFn, @ptrCast(&acceptFn)), null, .{ .stack_size = .Large });

    var clients: [NUM_CLIENTS]std.Thread = undefined;
    var nc: usize = 0;
    for (0..NUM_CLIENTS) |i| { clients[i] = std.Thread.spawn(.{}, clientThread, .{i}) catch break; nc += 1; }
    _ = std.Thread.spawn(.{}, struct {
        fn run(sd: *std.atomic.Value(bool)) void { std.posix.nanosleep(15, 0); sd.store(true, .release); fp.global_registry.notifyAll(); }
    }.run, .{&shutdown}) catch {};
    sched.run();
    for (0..nc) |i| clients[i].join();
    shutdown.store(true, .release); fp.global_registry.notifyAll();
    for (0..nw) |i| workers[i].join();
    std.debug.print("done\n", .{});
}
