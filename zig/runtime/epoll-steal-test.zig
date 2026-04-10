// ═══════════════════════════════════════════════════════════════════════════
// Epoll Steal Test — fd registration corruption when fibers are stolen
//
// Reproduces: a fiber registers its client fd with scheduler A's epoll.
// The fiber yields, gets stolen to scheduler B. On the next read(),
// WouldBlock registers the fd with scheduler B's epoll. Now TWO epoll
// instances watch the same fd. Both wake the fiber → double-push → crash.
//
// The test creates a TCP server on the main scheduler, spawns UNPINNED
// handler fibers, and uses multiple worker schedulers to force stealing.
//
// PASS: all clients complete without crash or starvation
// FAIL: segfault, timeout, or incorrect results
//
// Build: zig build-exe epoll-steal-test.zig switch.S onRoot.S -lc -OReleaseFast
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

const NUM_CLIENTS = 50;
const MSGS_PER_CLIENT = 50;
const PORT: u16 = 16393;
const TIMEOUT_MS: u64 = 10000;

var total_done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

fn sizeForId(id: i64) i64 {
    return @mod((CheatLib.intMul(id, 7) + 13), 997) + 10;
}

// Generate JSON using frame allocator — same as CLEAR's generateJson
fn generateJson(rt: *Runtime, id: i64) ![]const u8 {
    const sz = sizeForId(id);
    var parts = std.ArrayListUnmanaged([]const u8){};
    defer parts.deinit(rt.frameAlloc());
    var i: i64 = 1;
    while (i <= sz) : (i += 1) {
        try parts.append(rt.frameAlloc(), try CheatLib.intToString(rt.frameAlloc(), i));
        rt.checkYield();
    }
    return try std.mem.concat(rt.frameAlloc(), u8, &.{
        "{\"id\":", try CheatLib.intToString(rt.frameAlloc(), id),
        ",\"data\":[", try CheatLib.join(rt.frameAlloc(), parts, @as([]const u8, ",")),
        "]}",
    });
}

// Handler: read, generateJson (heavy frame alloc + checkYield), respond.
// UNPINNED — can be stolen between schedulers.
fn handlerFn(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
    const rt: *Runtime = @ptrCast(@alignCast(raw_rt));
    // Frame mark at function entry (what CLEAR's transpiler emits)
    const frame_mark = rt.saveFrameMark();
    defer rt.restoreFrameMark(frame_mark);

    const client_fd: i32 = @intCast(@intFromPtr(raw_args.?));
    defer std.posix.close(client_fd);

    var buf: [4096]u8 = undefined;
    var total_msgs: usize = 0;
    while (total_msgs < MSGS_PER_CLIENT) {
        // saveLoopMark (what CLEAR emits)
        const mark = rt.saveLoopMark();

        const n = CheatLib.read(client_fd, &buf) catch break;
        if (n == 0) break;

        // Parse "SET:N\r\n" and generate JSON (heavy frame alloc work)
        const msgs = n / 6;
        for (0..msgs) |m| {
            const json = try generateJson(rt, @as(i64, @intCast(m + total_msgs)));
            std.mem.doNotOptimizeAway(json.len);
        }

        // Respond
        var resp_buf: [4096]u8 = undefined;
        const pong = "+PONG\r\n";
        var resp_len: usize = 0;
        for (0..msgs) |_| {
            @memcpy(resp_buf[resp_len..][0..pong.len], pong);
            resp_len += pong.len;
        }
        _ = CheatLib.socketWrite(client_fd, resp_buf[0..resp_len]) catch break;
        total_msgs += msgs;

        // restoreLoopMark (what CLEAR emits)
        rt.restoreLoopMark(mark);
        rt.checkYield();
    }
    _ = total_done.fetchAdd(1, .release);
}

fn acceptFn(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
    _ = raw_rt;
    const server_fd: i32 = @intCast(@intFromPtr(raw_args.?));
    const sched = fp.active_scheduler;
    for (0..NUM_CLIENTS) |_| {
        const client_fd = try CheatLib.socketAccept(server_fd);
        // UNPINNED spawn — fibers CAN be stolen
        try sched.submitSpawn(
            @intFromPtr(&Runtime.entryWrapper),
            @as(qs.TaskFn, @ptrCast(&handlerFn)),
            @ptrFromInt(@as(usize, @intCast(client_fd))),
            .{ .stack_size = .Large, .pinned = false },
        );
    }
}

fn clientThread(id: usize) void {
    _ = id;
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
    const msg = "PING\r\n";
    var buf: [4096]u8 = undefined;
    // Send ONE message at a time with a small delay between.
    // This forces the server fiber to hit WouldBlock on the next read(),
    // registering the fd with epoll. If the fiber gets stolen to another
    // scheduler, the fd ends up in two epoll instances.
    for (0..MSGS_PER_CLIENT) |_| {
        _ = std.posix.write(fd, msg) catch return;
        // Small delay: enough for server to process and re-enter read()
        // before we send the next message, causing WouldBlock.
        std.posix.nanosleep(0, 100 * std.time.ns_per_us);
        var got: usize = 0;
        while (got < 7) { // "+PONG\r\n" = 7 bytes
            const n = std.posix.read(fd, &buf) catch return;
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

    var sched = fp.Scheduler.init(allocator, &global_ctx, &stack_pool) catch return;
    defer sched.deinit();
    sched.shutdown_on_idle = false;
    sched.global_shutdown = &shutdown;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;

    // 3 worker schedulers (4 total) to force stealing
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
        std.debug.print("FAIL: {d}/{d} clients. Epoll steal corruption.\n", .{ d, NUM_CLIENTS });
        std.process.exit(1);
    }
    std.debug.print("PASS: {d}/{d} clients completed.\n", .{ d, NUM_CLIENTS });
}
