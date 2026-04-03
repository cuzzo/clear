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

fn heavyCompute(seed: i64, n: i64) i64 {
    var x: i64 = seed;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        x = x *% 6364136223846793005 +% 1442695040888963407;
        x = x *% x +% 1;
    }
    return @mod(x, 1000000000);
}

// Hand-written: same logic as transpiled handleClient, but using
// direct byte operations instead of charAtCodepoint/substr/concat.
fn handleClient(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
    const rt: *Runtime = @ptrCast(@alignCast(raw_rt));
    const client_fd: i32 = @intCast(@intFromPtr(raw_args.?));
    defer CheatLib.socketClose(client_fd);

    const frame_mark = rt.saveFrameMark();
    defer rt.restoreFrameMark(frame_mark);

    var buf: [4096]u8 = undefined;
    while (true) {
        const loop_mark = rt.saveLoopMark();
        defer rt.restoreLoopMark(loop_mark);

        const n = CheatLib.read(client_fd, &buf) catch break;
        if (n == 0) break;
        const data = rt.frameAlloc().dupe(u8, buf[0..n]) catch break;

        // coopYield (like socketRead does)
        rt.checkYield();

        var resp_buf: [8192]u8 = undefined;
        var resp_len: usize = 0;
        var pos: usize = 0;

        while (pos < data.len) {
            var eol = pos;
            while (eol < data.len and data[eol] != '\r' and data[eol] != '\n') eol += 1;
            const line = data[pos..eol];
            pos = eol;
            while (pos < data.len and (data[pos] == '\r' or data[pos] == '\n')) pos += 1;

            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "WORK:")) {
                const rest = line[5..];
                const colon = std.mem.indexOf(u8, rest, ":") orelse continue;
                const id = std.fmt.parseInt(i64, rest[0..colon], 10) catch continue;
                var cnt = std.fmt.parseInt(i64, rest[colon + 1 ..], 10) catch continue;
                if (cnt < 1) cnt = 1;
                const result = heavyCompute(id, cnt);
                const w = std.fmt.bufPrint(resp_buf[resp_len..], ":{d}\r\n", .{result}) catch break;
                resp_len += w.len;
            } else if (std.mem.eql(u8, line, "QUIT")) {
                const w = std.fmt.bufPrint(resp_buf[resp_len..], "+OK\r\n", .{}) catch break;
                resp_len += w.len;
                if (resp_len > 0) _ = CheatLib.socketWrite(client_fd, resp_buf[0..resp_len]) catch break;
                return;
            } else if (std.mem.eql(u8, line, "READY?")) {
                const w = std.fmt.bufPrint(resp_buf[resp_len..], "+READY\r\n", .{}) catch break;
                resp_len += w.len;
            }
            rt.checkYield();
        }
        if (resp_len > 0) _ = CheatLib.socketWrite(client_fd, resp_buf[0..resp_len]) catch break;
    }
}

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
