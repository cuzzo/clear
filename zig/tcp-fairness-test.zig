// ═══════════════════════════════════════════════════════════════════════════
// TCP Fairness Test — Scheduler I/O Multiplexing
//
// Tests that multiple concurrent client fibers get fair scheduling when
// all have data available simultaneously. Reproduces the starvation bug
// where one fiber with pipelined data monopolizes the scheduler because
// posix.read() never returns WouldBlock.
//
// Setup:
//   - Server fiber accepts N connections, spawns N handler fibers
//   - N client OS threads send M messages each simultaneously
//   - All handler fibers are on ONE scheduler (pinned, like the kvstore)
//
// Pass criteria:
//   - All N clients complete within TIMEOUT_MS
//   - If starvation occurs, one handler hogs the scheduler while others
//     starve, and the test times out
//
// Build: zig build-exe tcp-fairness-test.zig switch.S onRoot.S -lc -OReleaseFast
// Run:   ./tcp-fairness-test
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

const NUM_CLIENTS = 10;
const MSGS_PER_CLIENT = 500;
const PORT: u16 = 16391;
const TIMEOUT_MS: u64 = 5000;

var total_done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// Handler fiber: read data, respond with "+PONG\r\n" for each "PING\r\n" received
fn handlerFn(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
    _ = raw_rt;
    const client_fd: i32 = @intCast(@intFromPtr(raw_args.?));
    defer std.posix.close(client_fd);

    var buf: [4096]u8 = undefined;
    var total_msgs: u32 = 0;
    while (total_msgs < MSGS_PER_CLIENT) {
        const n = CheatLib.read(client_fd, &buf) catch break;
        if (n == 0) break;
        // Count PING messages in this batch (each is 6 bytes: "PING\r\n")
        const msgs_in_batch = @as(u32, @intCast(n / 6));
        // Build response: one "+PONG\r\n" per PING
        var resp_buf: [4096]u8 = undefined;
        const pong = "+PONG\r\n";
        var resp_len: usize = 0;
        for (0..msgs_in_batch) |_| {
            @memcpy(resp_buf[resp_len..][0..pong.len], pong);
            resp_len += pong.len;
        }
        _ = CheatLib.socketWrite(client_fd, resp_buf[0..resp_len]) catch break;
        total_msgs += msgs_in_batch;
    }
    _ = total_done.fetchAdd(1, .release);
}

// Accept loop fiber
fn acceptFn(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
    _ = raw_rt;
    const server_fd: i32 = @intCast(@intFromPtr(raw_args.?));
    const sched = fp.active_scheduler;

    for (0..NUM_CLIENTS) |_| {
        const client_fd = try CheatLib.socketAccept(server_fd);
        try sched.submitSpawn(
            @intFromPtr(&Runtime.entryWrapper),
            @as(qs.TaskFn, @ptrCast(&handlerFn)),
            @ptrFromInt(@as(usize, @intCast(client_fd))),
            .{ .stack_size = .Standard },
        );
    }
    // After accepting all clients, close the server socket so the accept
    // loop doesn't keep the scheduler alive.
}

fn clientThread(id: usize) void {
    _ = id;
    std.posix.nanosleep(0, 100 * std.time.ns_per_ms);

    // Raw posix connect — no scheduler needed on client threads
    const fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0) catch return;
    defer std.posix.close(fd);
    const addr = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, PORT),
        .addr = std.mem.nativeToBig(u32, 0x7f000001), // 127.0.0.1
        .zero = [_]u8{0} ** 8,
    };
    std.posix.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) catch return;

    // Pipeline in batches of 16 (like redis-benchmark -P 16).
    // Send 16 messages, read 16 responses, repeat. This keeps the server-side
    // socket buffer continuously filled, preventing WouldBlock.
    const BATCH = 16;
    const msg = "PING\r\n";
    var buf: [4096]u8 = undefined;
    var sent: usize = 0;
    while (sent < MSGS_PER_CLIENT) {
        const batch_size = @min(BATCH, MSGS_PER_CLIENT - sent);
        // Send batch
        for (0..batch_size) |_| {
            _ = std.posix.write(fd, msg) catch return;
        }
        // Read responses for this batch
        var batch_read: usize = 0;
        const expected = batch_size * 7; // "+PONG\r\n" = 7 bytes
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

    const server_fd = try CheatLib.socketListen(PORT);

    // Spawn accept fiber
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&acceptFn)),
        @ptrFromInt(@as(usize, @intCast(server_fd))),
        .{ .stack_size = .Standard },
    );

    // Spawn client OS threads
    var client_threads: [NUM_CLIENTS]std.Thread = undefined;
    for (0..NUM_CLIENTS) |i| {
        client_threads[i] = try std.Thread.spawn(.{}, clientThread, .{i});
    }

    // Watchdog: kill the scheduler after timeout
    const watchdog = try std.Thread.spawn(.{}, struct {
        fn run(sd: *std.atomic.Value(bool)) void {
            std.posix.nanosleep(TIMEOUT_MS / 1000, (TIMEOUT_MS % 1000) * std.time.ns_per_ms);
            sd.store(true, .release);
            // Wake the scheduler from epoll_wait
            fp.global_registry.notifyAll();
        }
    }.run, .{&shutdown});
    _ = watchdog;

    // Run scheduler (blocks until shutdown)
    sched.run();

    // Join clients
    for (0..NUM_CLIENTS) |i| client_threads[i].join();

    std.posix.close(server_fd);

    const done = total_done.load(.acquire);
    if (done < NUM_CLIENTS) {
        std.debug.print("FAIL: {d}/{d} clients completed in {d}ms. I/O starvation detected.\n", .{ done, NUM_CLIENTS, TIMEOUT_MS });
        std.process.exit(1);
    } else {
        std.debug.print("PASS: All {d} clients completed. No starvation.\n", .{done});
    }
}
