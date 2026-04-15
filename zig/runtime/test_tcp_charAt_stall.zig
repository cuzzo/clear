// ═══════════════════════════════════════════════════════════════════════════
// TCP charAt Stall Reproducer
//
// Tests String@raw charAt (O(1) byte indexing) under concurrent TCP load
// with MULTIPLE SCHEDULERS to trigger fiber migration and expose epoll fd
// corruption.
//
// The handler parses RESP-like protocol using CheatLib.charAt (same as
// benchmark 25). With fast charAt, fibers cycle through read-parse-write
// quickly, increasing the chance of fiber migration between schedulers.
//
// PASS: all clients complete within timeout
// FAIL: stall due to epoll fd corruption on fiber migration
//
// Build: zig build-exe test_tcp_charAt_stall.zig switch.S onRoot.S -lc
// Run:   ./test_tcp_charAt_stall
// ═══════════════════════════════════════════════════════════════════════════

const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = @import("runtime.zig").Runtime;
const EbrContext = @import("../lib/ebr.zig").EbrContext;
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const qs = @import("queues.zig");

const NUM_CLIENTS = 32;
const MSGS_PER_CLIENT = 1000;
const PORT: u16 = 16499;
const TIMEOUT_MS: u64 = 15000;
const NUM_WORKER_SCHEDULERS = 7; // Total = 8 schedulers (triggers fiber migration)

var total_done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var global_ebr: EbrContext = .{};

// ── Handler fiber: read TCP data, parse with charAt (fast O(1)), respond ──
fn handlerFn(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
    const rt: *Runtime = @ptrCast(@alignCast(raw_rt));
    const client_fd: i32 = @intCast(@intFromPtr(raw_args.?));
    defer std.posix.close(client_fd);

    var total_msgs: u32 = 0;
    while (total_msgs < MSGS_PER_CLIENT) {
        const mark = rt.saveLoopMark();
        defer rt.restoreLoopMark(mark);

        // Read from TCP (yields fiber via epoll if no data ready)
        const data = CheatLib.socketRead(rt.frameAlloc(), client_fd) catch break;
        if (data.len == 0) break;

        // Parse RESP with charAt — the exact pattern from bench 25.
        // Each command is "PING\r\n" (6 bytes). We parse character by character.
        var pos: i64 = 0;
        var msgs_in_batch: u32 = 0;
        while (pos < CheatLib.len(data)) {
            // Skip to end of line using charAt (the fast path)
            var eol: i64 = pos;
            while (eol < CheatLib.len(data) and
                !CheatLib.eql(CheatLib.charAt(data, eol), "\r") and
                !CheatLib.eql(CheatLib.charAt(data, eol), "\n"))
            {
                eol += 1;
            }
            const line_len = eol - pos;
            // Skip \r\n
            while (pos < CheatLib.len(data) and
                (CheatLib.eql(CheatLib.charAt(data, eol), "\r") or
                CheatLib.eql(CheatLib.charAt(data, eol), "\n")))
            {
                eol += 1;
            }
            pos = eol;
            if (line_len > 0) msgs_in_batch += 1;
        }

        // Respond
        var resp_buf: [4096]u8 = undefined;
        const pong = "+PONG\r\n";
        var resp_len: usize = 0;
        for (0..msgs_in_batch) |_| {
            if (resp_len + pong.len > resp_buf.len) break;
            @memcpy(resp_buf[resp_len..][0..pong.len], pong);
            resp_len += pong.len;
        }
        _ = CheatLib.socketWrite(client_fd, resp_buf[0..resp_len]) catch break;
        total_msgs += msgs_in_batch;
    }
    _ = total_done.fetchAdd(1, .release);
}

// ── Accept loop fiber ──
fn acceptFn(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
    _ = raw_rt;
    const server_fd: i32 = @intCast(@intFromPtr(raw_args.?));
    const sched = fp.active_scheduler;

    for (0..NUM_CLIENTS) |_| {
        const client_fd = try CheatLib.socketAccept(server_fd);
        // Do NOT pin — allow work-stealing to trigger epoll fd migration
        try sched.submitSpawn(
            @intFromPtr(&Runtime.entryWrapper),
            @as(qs.TaskFn, @ptrCast(&handlerFn)),
            @ptrFromInt(@as(usize, @intCast(client_fd))),
            .{ .stack_size = .Standard },
        );
    }
}

// ── Client threads (run outside the fiber scheduler) ──
fn clientThread(id: usize) void {
    _ = id;
    // Small delay to let server start
    std.posix.nanosleep(0, 200 * std.time.ns_per_ms);

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

    // Pipeline: send batch, read responses
    const BATCH = 16;
    const msg = "PING\r\n";
    var buf: [4096]u8 = undefined;
    var sent: usize = 0;
    while (sent < MSGS_PER_CLIENT) {
        const remaining = MSGS_PER_CLIENT - sent;
        const batch_size: usize = if (remaining < BATCH) remaining else BATCH;
        for (0..batch_size) |_| {
            _ = std.posix.write(fd, msg) catch return;
        }
        var batch_read: usize = 0;
        const expected: usize = batch_size * 7; // "+PONG\r\n" = 7 bytes
        while (batch_read < expected) {
            const n = std.posix.read(fd, &buf) catch return;
            if (n == 0) return;
            batch_read += n;
        }
        sent += batch_size;
    }
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var shutdown = std.atomic.Value(bool).init(false);

    // ── Main scheduler ──
    var sched = fp.Scheduler.init(allocator, &global_ebr, &stack_pool) catch return;
    defer {
        sched.deinit();
        fp.global_registry.deinit(allocator);
    }
    sched.shutdown_on_idle = false;
    sched.global_shutdown = &shutdown;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;

    // ── Worker schedulers (to trigger work-stealing + fiber migration) ──
    const WorkerCtx = struct {
        allocator: std.mem.Allocator,
        global_ebr: *EbrContext,
        stack_pool: *fm.StackPool,
        shutdown: *std.atomic.Value(bool),
    };
    var worker_ctx = WorkerCtx{
        .allocator = allocator,
        .global_ebr = &global_ebr,
        .stack_pool = &stack_pool,
        .shutdown = &shutdown,
    };

    const workerMain = struct {
        fn run(ctx: *WorkerCtx) void {
            var worker_sched = fp.Scheduler.init(ctx.allocator, ctx.global_ebr, ctx.stack_pool) catch return;
            defer worker_sched.deinit();
            worker_sched.shutdown_on_idle = false;
            worker_sched.global_shutdown = ctx.shutdown;
            fp.active_scheduler = &worker_sched;
            fp.scheduler_running = true;
            worker_sched.run();
            fp.scheduler_running = false;
        }
    }.run;

    var workers: [NUM_WORKER_SCHEDULERS]std.Thread = undefined;
    for (0..NUM_WORKER_SCHEDULERS) |i| {
        workers[i] = std.Thread.spawn(.{}, workerMain, .{&worker_ctx}) catch break;
    }

    // Wait for workers to register
    while (fp.global_registry.count() < NUM_WORKER_SCHEDULERS) {
        std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
    }

    // ── Start TCP server ──
    const server_fd = try CheatLib.socketListen(PORT);

    var rt = try Runtime.init(allocator, 4 * 1024, &global_ebr);
    defer rt.deinit();
    rt.wireAllocator();

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&acceptFn)),
        @ptrFromInt(@as(usize, @intCast(server_fd))),
        .{ .stack_size = .Standard },
    );

    // ── Client threads ──
    var client_threads: [NUM_CLIENTS]std.Thread = undefined;
    for (0..NUM_CLIENTS) |i| {
        client_threads[i] = try std.Thread.spawn(.{}, clientThread, .{i});
    }

    // ── Watchdog: detect stall ──
    const watchdog = try std.Thread.spawn(.{}, struct {
        fn run(sd: *std.atomic.Value(bool)) void {
            std.posix.nanosleep(TIMEOUT_MS / 1000, (TIMEOUT_MS % 1000) * std.time.ns_per_ms);
            sd.store(true, .release);
            fp.global_registry.notifyAll();
        }
    }.run, .{&shutdown});
    _ = watchdog;

    // ── Run main scheduler ──
    sched.run();

    // ── Join ──
    for (0..NUM_CLIENTS) |i| client_threads[i].join();
    shutdown.store(true, .release);
    fp.global_registry.notifyAll();
    for (0..NUM_WORKER_SCHEDULERS) |i| workers[i].join();
    std.posix.close(server_fd);

    const done = total_done.load(.acquire);
    if (done < NUM_CLIENTS) {
        std.debug.print("FAIL: {d}/{d} clients completed in {d}ms. Epoll fd migration stall.\n", .{ done, NUM_CLIENTS, TIMEOUT_MS });
        std.process.exit(1);
    } else {
        std.debug.print("PASS: All {d} clients completed ({d} msgs each). No stall.\n", .{ done, MSGS_PER_CLIENT });
    }
}
