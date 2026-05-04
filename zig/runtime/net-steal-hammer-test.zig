// ═══════════════════════════════════════════════════════════════════════════
// Network + Work-Stealing Hammer Test
//
// Reproduces the exact code path that crashes benchmarks 24/25:
//   - Fibers spawned via spawnBest (distributed across schedulers)
//   - socketRead (epoll + coopYield after each read)
//   - socketWrite (epoll on EAGAIN)
//   - onRootStack calls between reads (like readFile)
//   - Frame arena alloc + loop rewind (like transpiled WHILE loops)
//   - Clients send bursts to force WouldBlock/immediate-read alternation
//
// Every message carries a sequence number. The server computes a hash
// and responds. The client verifies every response. Any corruption —
// wrong result, stale data, truncated read — is detected.
//
// Build: zig build-exe net-steal-hammer-test.zig switch.S onRoot.S -lc -OReleaseFast
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
const NUM_CLIENTS = if (build_options.coverage) 4 else 100;
const MSGS_PER_CLIENT = if (build_options.coverage) 5 else 200;
const BURST_SIZE = if (build_options.coverage) 2 else 5;
const PORT: u16 = 16395;
const TIMEOUT_S: u64 = if (build_options.coverage) 5 else 30;

var total_done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var total_verified: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var total_corrupt: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// Deterministic hash — same as benchmark 25's heavyCompute.
fn compute(seed: u64, n: u64) u64 {
    var x: u64 = seed;
    for (0..n) |_| {
        x = x *% 6364136223846793005 +% 1442695040888963407;
        x ^= x >> 17;
    }
    return x;
}

// Context for onRootStack — simulates readFile/writeFile.
const RootWorkCtx = struct {
    seed: u64,
    result: u64 = 0,
    fn run(ptr: ?*anyopaque) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.result = compute(self.seed, 50);
    }
};

// ── Server handler (runs as an unpinned fiber) ──────────────────────────
// Mirrors the transpiled CLEAR benchmark handler:
//   WHILE running DO
//     data = tcpRead(client);          ← epoll + coopYield
//     parse lines from data            ← frame alloc + loop mark
//     onRootStack work                 ← like readFile
//     compute result                   ← like parseJsonArraySum
//     tcpWrite(client, response);      ← epoll on EAGAIN
//   END
fn handlerFn(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
    const rt: *Runtime = @ptrCast(@alignCast(raw_rt));
    const frame_mark = rt.saveFrameMark();
    defer rt.restoreFrameMark(frame_mark);

    const client_fd: i32 = @intCast(@intFromPtr(raw_args.?));
    defer CheatLib.socketClose(client_fd);

    var buf: [4096]u8 = undefined;
    var msgs: u32 = 0;

    while (msgs < MSGS_PER_CLIENT) {
        // ── Loop mark (like transpiled WHILE body) ──
        const loop_mark = rt.saveLoopMark();

        // ── socketRead path: epoll register + coopYield ──
        const n = CheatLib.read(client_fd, &buf) catch break;
        if (n == 0) break;

        // Dupe into frame arena (like socketRead does)
        const data = rt.frameAlloc().dupe(u8, buf[0..n]) catch break;

        // coopYield after read (like socketRead does)
        rt.checkYield();

        // ── Parse lines from data ──
        // Protocol: "WORK:<seed>\n" → respond "<hash>\n"
        var resp_len: usize = 0;
        var resp_buf: [8192]u8 = undefined;
        var pos: usize = 0;

        while (pos < data.len) {
            // Find newline
            var eol = pos;
            while (eol < data.len and data[eol] != '\n') eol += 1;
            if (eol >= data.len) break; // partial line — skip

            const line = data[pos..eol];
            pos = eol + 1;

            if (line.len < 6) continue; // "WORK:" + at least 1 digit
            if (!std.mem.startsWith(u8, line, "WORK:")) continue;

            const seed_str = line[5..];
            const seed = std.fmt.parseInt(u64, seed_str, 10) catch continue;

            // ── onRootStack (like readFile) ──
            var root_ctx = RootWorkCtx{ .seed = seed };
            rt.onRootStack(
                @as(*const fn (?*anyopaque) callconv(.c) void, &RootWorkCtx.run),
                @ptrCast(&root_ctx),
            );

            // ── Compute (like parseJsonArraySum) ──
            const result = compute(seed, 100) ^ root_ctx.result;

            // Format response
            const written = std.fmt.bufPrint(resp_buf[resp_len..], "{d}\n", .{result}) catch break;
            resp_len += written.len;
            msgs += 1;

            rt.checkYield();
        }

        // ── socketWrite ──
        if (resp_len > 0) {
            _ = CheatLib.socketWrite(client_fd, resp_buf[0..resp_len]) catch break;
        }

        // ── Restore loop mark (rewind arena) ──
        rt.restoreLoopMark(loop_mark);
    }
    _ = total_done.fetchAdd(1, .release);
}

// ── Accept fiber ────────────────────────────────────────────────────────
fn acceptFn(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
    _ = raw_rt;
    const server_fd: i32 = @intCast(@intFromPtr(raw_args.?));
    for (0..NUM_CLIENTS) |_| {
        const client_fd = try CheatLib.socketAccept(server_fd);
        // spawnBest — distributes across schedulers (matches benchmark pattern)
        try CheatHeader.spawnBest(
            @intFromPtr(&Runtime.entryWrapper),
            @as(qs.TaskFn, @ptrCast(&handlerFn)),
            @ptrFromInt(@as(usize, @intCast(client_fd))),
            .{ .stack_size = .Large, .pinned = false },
        );
    }
}

// ── Client thread (OS thread, not a fiber) ──────────────────────────────
fn clientThread(id: usize) void {
    // Stagger startup
    std.posix.nanosleep(0, 100 * std.time.ns_per_ms);

    const fd = std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
    ) catch return;
    defer std.posix.close(fd);

    const addr = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, PORT),
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
        .zero = [_]u8{0} ** 8,
    };
    std.posix.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) catch return;

    var send_buf: [4096]u8 = undefined;
    var recv_buf: [65536]u8 = undefined;
    var sent: usize = 0;

    while (sent < MSGS_PER_CLIENT) {
        // ── Send a burst ──
        const burst = @min(BURST_SIZE, MSGS_PER_CLIENT - sent);
        var send_len: usize = 0;
        for (0..burst) |b| {
            const seed = id * 10000 + sent + b;
            const n = std.fmt.bufPrint(send_buf[send_len..], "WORK:{d}\n", .{seed}) catch break;
            send_len += n.len;
        }
        const written = std.posix.write(fd, send_buf[0..send_len]) catch return;
        if (written == 0) return;
        sent += burst;

        // ── Receive and verify all responses for this burst ──
        var lines_got: usize = 0;
        var recv_total: usize = 0;
        while (lines_got < burst) {
            const nr = std.posix.read(fd, recv_buf[recv_total..]) catch return;
            if (nr == 0) return;
            recv_total += nr;
            // Count newlines
            var count: usize = 0;
            for (recv_buf[recv_total - nr .. recv_total]) |c| {
                if (c == '\n') count += 1;
            }
            lines_got += count;
        }

        // Verify each response
        var rpos: usize = 0;
        for (0..burst) |b| {
            const seed = id * 10000 + (sent - burst) + b;
            const expected = compute(seed, 100) ^ compute(seed, 50);

            // Find newline
            var eol = rpos;
            while (eol < recv_total and recv_buf[eol] != '\n') eol += 1;
            if (eol >= recv_total) break;

            const line = recv_buf[rpos..eol];
            rpos = eol + 1;

            const got = std.fmt.parseInt(u64, line, 10) catch {
                _ = total_corrupt.fetchAdd(1, .monotonic);
                continue;
            };
            if (got == expected) {
                _ = total_verified.fetchAdd(1, .monotonic);
            } else {
                _ = total_corrupt.fetchAdd(1, .monotonic);
            }
        }
    }
}

// ── Main ────────────────────────────────────────────────────────────────
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
    var spawned_workers: usize = 0;
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
        spawned_workers += 1;
    }
    while (fp.global_registry.count() < spawned_workers) {
        std.posix.nanosleep(0, std.time.ns_per_ms);
    }

    const server_fd = try CheatLib.socketListen(PORT);
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&acceptFn)),
        @ptrFromInt(@as(usize, @intCast(server_fd))),
        .{ .stack_size = .Standard },
    );

    var client_threads: [NUM_CLIENTS]std.Thread = undefined;
    var spawned_clients: usize = 0;
    for (0..NUM_CLIENTS) |i| {
        client_threads[i] = std.Thread.spawn(.{}, clientThread, .{i}) catch break;
        spawned_clients += 1;
    }

    // Timeout watchdog
    _ = std.Thread.spawn(.{}, struct {
        fn run(sd: *std.atomic.Value(bool)) void {
            std.posix.nanosleep(TIMEOUT_S, 0);
            sd.store(true, .release);
            fp.global_registry.notifyAll();
        }
    }.run, .{&shutdown}) catch {};

    sched.run();

    for (0..spawned_clients) |i| client_threads[i].join();
    shutdown.store(true, .release);
    fp.global_registry.notifyAll();
    for (0..spawned_workers) |i| workers[i].join();
    std.posix.close(server_fd);

    const done = total_done.load(.acquire);
    const verified = total_verified.load(.acquire);
    const corrupt = total_corrupt.load(.acquire);
    const expected_msgs = NUM_CLIENTS * MSGS_PER_CLIENT;

    if (done == NUM_CLIENTS and corrupt == 0 and verified == expected_msgs) {
        std.debug.print("PASS: {d}/{d} clients, {d}/{d} verified, 0 corrupt.\n", .{
            done, NUM_CLIENTS, verified, expected_msgs,
        });
    } else {
        std.debug.print("FAIL: {d}/{d} clients, {d}/{d} verified, {d} corrupt.\n", .{
            done, NUM_CLIENTS, verified, expected_msgs, corrupt,
        });
        std.process.exit(1);
    }
}
