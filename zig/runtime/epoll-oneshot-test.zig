// ═══════════════════════════════════════════════════════════════════════════
// Epoll ONESHOT Race Test
//
// Reproduces the fiber-steal epoll race condition:
//   1. Fiber on scheduler A registers fd with A's epoll (edge-triggered)
//   2. Data arrives → A wakes fiber → fiber coopYields (fd still on A's epoll)
//   3. Scheduler B steals the fiber
//   4. New data arrives → A's stale epoll fires → A pushes task to its queue
//   5. Fiber is now on BOTH A's and B's ready queues → double-execute → crash
//
// The fix is EPOLLONESHOT: after each event fires, the fd is disabled.
// Stale registrations on old schedulers can never fire.
//
// Strategy: 8 schedulers, 100 clients, rapid-fire messages. Handlers do
// enough work per message to trigger coopYield (making them stealable
// while their fd is still registered). Clients send in bursts so the
// handler alternates between immediate reads and WouldBlock — maximizing
// the window where the fd is registered but the task is in the ready queue.
//
// PASS: all clients complete, total_done == NUM_CLIENTS
// FAIL: segfault, timeout (10s), or total_done < NUM_CLIENTS
//
// Build: zig build-exe epoll-oneshot-test.zig switch.S onRoot.S -lc -OReleaseFast
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

const NUM_SCHEDULERS = 8;
const NUM_CLIENTS = 100;
const MSGS_PER_CLIENT = 200;
const BURST_SIZE = 5; // send 5 messages before reading responses
const PORT: u16 = 16394;
const TIMEOUT_MS: u64 = 10000;

var total_done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var total_msgs: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// Handler: read messages, do CPU-heavy work (forces coopYield while fd is
// still registered with epoll), write response. UNPINNED — can be stolen.
fn handlerFn(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
    const rt: *Runtime = @ptrCast(@alignCast(raw_rt));
    const frame_mark = rt.saveFrameMark();
    defer rt.restoreFrameMark(frame_mark);

    const client_fd: i32 = @intCast(@intFromPtr(raw_args.?));
    defer CheatLib.socketClose(client_fd);

    var buf: [4096]u8 = undefined;
    var msgs_processed: u32 = 0;

    while (msgs_processed < MSGS_PER_CLIENT) {
        const mark = rt.saveLoopMark();
        defer rt.restoreLoopMark(mark);

        const n = CheatLib.read(client_fd, &buf) catch break;
        if (n == 0) break;

        // Count "PING\n" messages in this read
        var count: u32 = 0;
        for (0..n) |i| {
            if (buf[i] == '\n') count += 1;
        }

        // CPU-heavy work per message — triggers coopYield, which puts this
        // fiber in the ready queue where it CAN be stolen. Meanwhile, the
        // fd is still registered with the current scheduler's epoll.
        var hash: u64 = 0;
        for (0..count) |_| {
            for (0..2000) |j| {
                hash ^= hash *% 6364136223846793005 +% @as(u64, @intCast(j));
            }
            rt.checkYield(); // may yield — fiber becomes stealable
        }
        std.mem.doNotOptimizeAway(hash);

        // Write responses
        var resp_buf: [4096]u8 = undefined;
        const pong = "PONG\n";
        var resp_len: usize = 0;
        for (0..count) |_| {
            if (resp_len + pong.len > resp_buf.len) break;
            @memcpy(resp_buf[resp_len..][0..pong.len], pong);
            resp_len += pong.len;
        }
        _ = CheatLib.socketWrite(client_fd, resp_buf[0..resp_len]) catch break;
        msgs_processed += count;
        _ = total_msgs.fetchAdd(count, .monotonic);
    }
    _ = total_done.fetchAdd(1, .release);
}

fn acceptFn(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
    _ = raw_rt;
    const server_fd: i32 = @intCast(@intFromPtr(raw_args.?));
    for (0..NUM_CLIENTS) |_| {
        const client_fd = try CheatLib.socketAccept(server_fd);
        // UNPINNED spawn — fibers CAN be stolen between schedulers
        try fp.active_scheduler.submitSpawn(
            @intFromPtr(&Runtime.entryWrapper),
            @as(qs.TaskFn, @ptrCast(&handlerFn)),
            @ptrFromInt(@as(usize, @intCast(client_fd))),
            .{ .stack_size = .Large, .pinned = false },
        );
    }
}

fn clientThread(id: usize) void {
    _ = id;
    // Stagger startup slightly
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

    const msg = "PING\n";
    var recv_buf: [8192]u8 = undefined;
    var sent: usize = 0;

    while (sent < MSGS_PER_CLIENT) {
        // Send a burst of messages — this fills the socket buffer so the
        // server fiber can read multiple messages without WouldBlock, then
        // coopYield (putting it in the ready queue, stealable), then hit
        // WouldBlock on the next read (registering with new scheduler's epoll).
        const burst = @min(BURST_SIZE, MSGS_PER_CLIENT - sent);
        for (0..burst) |_| {
            _ = std.posix.write(fd, msg) catch return;
        }
        sent += burst;

        // Read all responses for this burst
        var got: usize = 0;
        const expect = burst * 5; // "PONG\n" = 5 bytes each
        while (got < expect) {
            const n = std.posix.read(fd, &recv_buf) catch return;
            if (n == 0) return;
            got += n;
        }
    }
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var global_ctx = EbrContext{};
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var shutdown = std.atomic.Value(bool).init(false);

    // Main scheduler
    var sched = fp.Scheduler.init(allocator, &global_ctx, &stack_pool) catch return;
    defer sched.deinit();
    sched.shutdown_on_idle = false;
    sched.global_shutdown = &shutdown;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;

    // Worker schedulers
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

    // Wait for all schedulers to register
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

    // Client threads
    var client_threads: [NUM_CLIENTS]std.Thread = undefined;
    var spawned_clients: usize = 0;
    for (0..NUM_CLIENTS) |i| {
        client_threads[i] = std.Thread.spawn(.{}, clientThread, .{i}) catch break;
        spawned_clients += 1;
    }

    // Timeout watchdog
    _ = std.Thread.spawn(.{}, struct {
        fn run(sd: *std.atomic.Value(bool)) void {
            std.posix.nanosleep(TIMEOUT_MS / 1000, (TIMEOUT_MS % 1000) * std.time.ns_per_ms);
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

    const d = total_done.load(.acquire);
    const m = total_msgs.load(.acquire);
    if (d < NUM_CLIENTS) {
        std.debug.print("FAIL: {d}/{d} clients done, {d} msgs. Epoll steal race.\n", .{ d, NUM_CLIENTS, m });
        std.process.exit(1);
    }
    std.debug.print("PASS: {d}/{d} clients, {d} msgs processed.\n", .{ d, NUM_CLIENTS, m });
}
