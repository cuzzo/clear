// socket-test.zig
// Unit tests for the TCP socket primitives (Phase 2):
//   CheatLib.socketListen  — create non-blocking server socket
//   CheatLib.socketAccept  — fiber-yielding accept
//   CheatLib.socketWrite   — fiber-yielding send
//   CheatLib.socketClose   — deregister + close
//
// The echo test spawns a server fiber and a client fiber inside the same
// scheduler, exercises the full EAGAIN→yield→wake path end-to-end.
const std = @import("std");
const CheatLib = @import("runtime-header.zig").CheatLib;
const CheatHeader = @import("runtime-header.zig");
const Runtime = @import("runtime.zig").Runtime;
const EbrContext = @import("ebr.zig").EbrContext;
const fm = @import("fiber-memory.zig");
const fp = @import("scheduler.zig");

// Comptime linker shims (matches pattern used in other test files).
comptime {
    _ = @import("scheduler.zig");
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Set up a single-threaded scheduler around a test closure and run it.
/// The closure receives *Runtime so it can call rt.getSched(), etc.
fn runWithScheduler(allocator: std.mem.Allocator, comptime func: anytype) !void {
    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    var rt = try Runtime.init(allocator, 512 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(allocator);
    }
    fp.active_scheduler = &sched;

    const Runner = struct {
        fn run(raw_rt: *anyopaque, _: ?*anyopaque) anyerror!void {
            const rt_ptr: *Runtime = @ptrCast(@alignCast(raw_rt));
            try func(rt_ptr);
        }
    };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&Runner.run)),
        null,
        .{},
    );
    sched.run();
}

// ---------------------------------------------------------------------------
// Test 1: socketListen creates a valid bound socket
// ---------------------------------------------------------------------------

test "socketListen: returns a valid server fd" {
    const allocator = std.testing.allocator;

    try runWithScheduler(allocator, struct {
        fn body(_: *Runtime) !void {
            // Port 0 → OS picks an ephemeral port; no hard-coded conflict risk.
            const server_fd = try CheatLib.socketListen(0);
            defer CheatLib.socketClose(server_fd);

            // Verify it is a valid fd by querying the bound address.
            var addr: std.posix.sockaddr = undefined;
            var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
            try std.posix.getsockname(server_fd, &addr, &addr_len);
        }
    }.body);
}

// ---------------------------------------------------------------------------
// Test 2: SO_REUSEADDR — bind the same port twice (sequential, not concurrent)
// ---------------------------------------------------------------------------

test "socketListen: SO_REUSEADDR lets us rebind after close" {
    const allocator = std.testing.allocator;

    try runWithScheduler(allocator, struct {
        fn body(_: *Runtime) !void {
            // Bind on an ephemeral port, then query the actual port so we can
            // rebind to it. SO_REUSEADDR is the feature we're testing.
            const fd1 = try CheatLib.socketListen(0);
            var sa: std.posix.sockaddr.in = undefined;
            var sa_len: std.posix.socklen_t = @sizeOf(@TypeOf(sa));
            try std.posix.getsockname(fd1, @ptrCast(&sa), &sa_len);
            const port = std.mem.bigToNative(u16, sa.port);
            CheatLib.socketClose(fd1);

            // Rebind the same port — should succeed with SO_REUSEADDR.
            const fd2 = try CheatLib.socketListen(port);
            defer CheatLib.socketClose(fd2);
        }
    }.body);
}

// ---------------------------------------------------------------------------
// Test 3: Full fiber echo cycle
//   Server fiber: listen → accept → read → write back → close client fd
//   Client thread (plain OS thread): connect → write → read response → assert
//
// The server runs inside the fiber scheduler (exercises registerFd / yield /
// wake paths for accept and write).  The client runs in a plain OS thread so
// its blocking connect/read/write don't stall the scheduler.
// ---------------------------------------------------------------------------

const EchoShared = struct {
    server_fd: i32,
    port: u16,         // filled in after bind via getsockname
    server_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    server_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    echo_correct: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn clientThread(shared: *EchoShared) void {
    // Wait until the server fiber has called socketAccept and registered with epoll.
    while (!shared.server_ready.load(.seq_cst)) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    const fd = std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
    ) catch return;
    defer std.posix.close(fd);

    const addr = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port   = std.mem.nativeToBig(u16, shared.port),
        .addr   = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
        .zero   = [_]u8{0} ** 8,
    };
    std.posix.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) catch return;

    const msg = "hello cheat";
    _ = std.posix.write(fd, msg) catch return;

    // Read the echo back (server must respond before we close).
    var buf: [64]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch return;

    if (std.mem.eql(u8, buf[0..n], msg)) {
        shared.echo_correct.store(true, .seq_cst);
    }
}

test "socketAccept + socketWrite: fiber echo roundtrip" {
    const allocator = std.testing.allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    var rt = try Runtime.init(allocator, 512 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(allocator);
    }
    fp.active_scheduler = &sched;

    // Bind on port 0 — OS assigns an ephemeral port to avoid conflicts.
    const server_fd = try CheatLib.socketListen(0);
    defer CheatLib.socketClose(server_fd);

    // Discover the actual bound port via getsockname.
    var bound_addr: std.posix.sockaddr.in = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(@TypeOf(bound_addr));
    try std.posix.getsockname(server_fd, @ptrCast(&bound_addr), &addr_len);
    const actual_port = std.mem.bigToNative(u16, bound_addr.port);

    var shared = EchoShared{ .server_fd = server_fd, .port = actual_port };

    // --- Server fiber: accept one connection, echo, close ---
    const ServerFiber = struct {
        fn run(_: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const s: *EchoShared = @ptrCast(@alignCast(raw_args.?));

            // Signal the client thread that we are about to accept.
            s.server_ready.store(true, .seq_cst);

            // Accept one connection (yields via epoll until client connects).
            const client_fd = try CheatLib.socketAccept(s.server_fd);
            defer CheatLib.socketClose(client_fd);

            // Read the client's message (yields via epoll until data arrives).
            var buf: [64]u8 = undefined;
            const n = try CheatLib.read(client_fd, &buf);

            // Echo it back (yields via epoll if send buffer is full).
            _ = try CheatLib.socketWrite(client_fd, buf[0..n]);

            s.server_done.store(true, .seq_cst);
        }
    };

    // Spawn the server fiber.
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&ServerFiber.run)),
        &shared,
        .{},
    );

    // Launch the client in a plain OS thread (blocking I/O; won't stall scheduler).
    const thread = try std.Thread.spawn(.{}, clientThread, .{&shared});

    // Run the scheduler until the server fiber finishes.
    sched.run();
    thread.join();

    try std.testing.expect(shared.server_done.load(.seq_cst));
    try std.testing.expect(shared.echo_correct.load(.seq_cst));
}

// ---------------------------------------------------------------------------
// Test 4: socketClose removes fd from epoll (no crash / stale event)
// ---------------------------------------------------------------------------

test "socketClose: safe to call on freshly-opened server fd" {
    const allocator = std.testing.allocator;

    try runWithScheduler(allocator, struct {
        fn body(_: *Runtime) !void {
            const fd = try CheatLib.socketListen(0);
            // socketClose must not crash — it calls unregisterFd (CTL_DEL) then close.
            // The fd was never registered with epoll, so CTL_DEL is expected to be a no-op.
            CheatLib.socketClose(fd);
        }
    }.body);
}

// ---------------------------------------------------------------------------
// Test 5: socketRead + socketWriteVoid — Phase 3 echo with higher-level helpers
// ---------------------------------------------------------------------------
// These are the functions the CLEAR compiler calls for tcpRead() / tcpWrite().
// socketRead allocates a heap String; socketWriteVoid discards the byte count.

const EchoShared2 = struct {
    server_fd: i32,
    port: u16,
    server_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    server_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    echo_correct: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn clientThread2(shared: *EchoShared2) void {
    while (!shared.server_ready.load(.seq_cst)) {
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    const fd = std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
    ) catch return;
    defer std.posix.close(fd);

    const addr = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port   = std.mem.nativeToBig(u16, shared.port),
        .addr   = std.mem.nativeToBig(u32, 0x7F000001),
        .zero   = [_]u8{0} ** 8,
    };
    std.posix.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) catch return;

    const msg = "hello from phase3";
    _ = std.posix.write(fd, msg) catch return;

    var buf: [64]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch return;
    if (std.mem.eql(u8, buf[0..n], msg)) {
        shared.echo_correct.store(true, .seq_cst);
    }
}

test "socketRead + socketWriteVoid: heap-string echo roundtrip" {
    const allocator = std.testing.allocator;

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    var rt = try Runtime.init(allocator, 512 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(allocator);
    }
    fp.active_scheduler = &sched;

    const server_fd = try CheatLib.socketListen(0);
    defer CheatLib.socketClose(server_fd);

    var bound_addr: std.posix.sockaddr.in = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(@TypeOf(bound_addr));
    try std.posix.getsockname(server_fd, @ptrCast(&bound_addr), &addr_len);
    const actual_port = std.mem.bigToNative(u16, bound_addr.port);

    var shared2 = EchoShared2{ .server_fd = server_fd, .port = actual_port };

    const ServerFiber2 = struct {
        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const rt_ptr: *Runtime = @ptrCast(@alignCast(raw_rt));
            const s: *EchoShared2 = @ptrCast(@alignCast(raw_args.?));

            s.server_ready.store(true, .seq_cst);

            const client_fd = try CheatLib.socketAccept(s.server_fd);
            defer CheatLib.socketClose(client_fd);

            // Use the Phase 3 CLEAR-facing helpers instead of raw read/write.
            const data = try CheatLib.socketRead(rt_ptr.heapAlloc(), client_fd);
            defer rt_ptr.heapAlloc().free(data);

            try CheatLib.socketWriteVoid(client_fd, data);

            s.server_done.store(true, .seq_cst);
        }
    };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&ServerFiber2.run)),
        &shared2,
        .{},
    );

    const thread = try std.Thread.spawn(.{}, clientThread2, .{&shared2});
    sched.run();
    thread.join();

    try std.testing.expect(shared2.server_done.load(.seq_cst));
    try std.testing.expect(shared2.echo_correct.load(.seq_cst));
}
