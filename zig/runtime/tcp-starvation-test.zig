// ═══════════════════════════════════════════════════════════════════════════
// TCP Starvation Reproducer
//
// Reproduces the exact stall seen in bench 20: multiple pipelined clients,
// heavy per-message CPU work in handlers, cooperative scheduler.
//
// The handler simulates RESP parsing: ~500 loop iterations per message
// (character-by-character scanning). With 16 pipelined messages per batch,
// that's ~8000 iterations between read() calls — enough to consume most
// of the checkYield budget (4096).
//
// PASS: all clients complete within TIMEOUT_MS
// FAIL: timeout (starvation)
//
// Build: zig build-exe tcp-starvation-test.zig switch.S onRoot.S -lc -OReleaseFast
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

const NUM_CLIENTS = 25;
const MSGS_PER_CLIENT = 200;
const PIPELINE_DEPTH = 16;
const PORT: u16 = 16392;
const TIMEOUT_MS: u64 = 5000;

var total_done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

// Shared map (like the CLEAR server's @sharded store)
var shared_map: CheatLib.MutexShardedStringMap([]const u8, 128) = CheatLib.MutexShardedStringMap([]const u8, 128){ .alloc = std.heap.c_allocator };

// Simulate RESP-style character-by-character parsing with string building.
// The real CLEAR server does `resp = resp + "+OK\r\n"` (string concat per
// command) and character-by-character WHILE loops for argument parsing.
// This produces thousands of inner loop iterations per read() call.
fn parseResp(data: []const u8, alloc: std.mem.Allocator) usize {
    var count: usize = 0;
    var pos: usize = 0;
    // Build response string character-by-character (like CLEAR's WHILE loops)
    var resp = std.ArrayListUnmanaged(u8){};
    defer resp.deinit(alloc);
    while (pos < data.len) {
        // Character-by-character scan for each command (like CLEAR's WHILE loops)
        const cmd_start = pos;
        while (pos < data.len and data[pos] != '\n') : (pos += 1) {
            // Simulate per-character branching (command parsing)
            var j = cmd_start;
            while (j < pos) : (j += 1) {
                // Inner loop — consumes checkYield budget rapidly
                std.mem.doNotOptimizeAway(data[j]);
            }
        }
        if (pos < data.len) pos += 1; // skip \n

        // String concatenation per command (like CLEAR's resp = resp + "+OK\r\n")
        resp.appendSlice(alloc, "+PONG\r\n") catch {};
        count += 1;
    }
    std.mem.doNotOptimizeAway(resp.items.len);
    return count;
}

// Handler fiber: read, parse (heavy CPU with checkYield), respond
// Matches CLEAR's generated code: checkYield in every WHILE loop.
fn handlerFn(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
    const rt: *Runtime = @ptrCast(@alignCast(raw_rt));
    const client_fd: i32 = @intCast(@intFromPtr(raw_args.?));
    defer std.posix.close(client_fd);

    var buf: [4096]u8 = undefined;
    var total_msgs: usize = 0;
    while (total_msgs < MSGS_PER_CLIENT) {
        const n = CheatLib.read(client_fd, &buf) catch break;
        if (n == 0) break;

        // Parse + build response with checkYield on every inner loop
        // (exactly what CLEAR's WHILE loops generate)
        var resp_buf: [4096]u8 = undefined;
        var resp_len: usize = 0;
        var msgs: usize = 0;
        var pos: usize = 0;
        while (pos < n) {
            rt.checkYield(); // CLEAR emits this in every WHILE
            // Character-by-character scan for command
            while (pos < n and buf[pos] != '\n') : (pos += 1) {
                rt.checkYield(); // inner WHILE
            }
            if (pos < n) pos += 1;
            // Map operation (like CLEAR's store[key] = value)
            shared_map.put(std.heap.c_allocator, std.heap.c_allocator, "testkey", "testval") catch {};
            _ = shared_map.get("testkey");

            const pong = "+PONG\r\n";
            @memcpy(resp_buf[resp_len..][0..pong.len], pong);
            resp_len += pong.len;
            msgs += 1;
        }
        _ = CheatLib.socketWrite(client_fd, resp_buf[0..resp_len]) catch break;
        total_msgs += msgs;
        rt.checkYield(); // outer WHILE
    }
    _ = total_done.fetchAdd(1, .release);
}

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
}

fn clientThread(id: usize) void {
    _ = id;
    std.posix.nanosleep(0, 100 * std.time.ns_per_ms);
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
    var sent: usize = 0;
    while (sent < MSGS_PER_CLIENT) {
        const remaining = MSGS_PER_CLIENT - sent;
        const batch: usize = if (remaining < PIPELINE_DEPTH) remaining else PIPELINE_DEPTH;
        for (0..batch) |_| {
            _ = std.posix.write(fd, msg) catch return;
        }
        var got: usize = 0;
        const expect: usize = batch * 7; // "+PONG\r\n"
        while (got < expect) {
            const n = std.posix.read(fd, &buf) catch return;
            if (n == 0) return;
            got += n;
        }
        sent += batch;
    }
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    var global_ctx = EbrContext{};
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var shutdown = std.atomic.Value(bool).init(false);

    // Use N worker schedulers to simulate multi-core (CLEAR_THREADS > 1)
    const num_workers: usize = blk: {
        if (std.posix.getenv("CLEAR_THREADS")) |env| {
            const n = std.fmt.parseInt(usize, env, 10) catch 1;
            break :blk if (n > 1) n - 1 else 0;
        }
        break :blk @as(usize, 1); // Default: 2 schedulers total
    };

    var sched = fp.Scheduler.init(allocator, &global_ctx, &stack_pool) catch return;
    defer sched.deinit();
    sched.shutdown_on_idle = false;
    sched.global_shutdown = &shutdown;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;

    // Spawn worker schedulers
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
    var workers: [64]std.Thread = undefined;
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

    if (num_workers > 0) {
        while (fp.global_registry.count() < num_workers) {
            std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
        }
    }

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

    // Watchdog
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
    for (0..num_workers) |i| workers[i].join();
    std.posix.close(server_fd);

    const done = total_done.load(.acquire);
    if (done < NUM_CLIENTS) {
        std.debug.print("FAIL: {d}/{d} clients in {d}ms. STARVATION.\n", .{ done, NUM_CLIENTS, TIMEOUT_MS });
        std.process.exit(1);
    } else {
        std.debug.print("PASS: {d}/{d} clients completed.\n", .{ done, NUM_CLIENTS });
    }
}
