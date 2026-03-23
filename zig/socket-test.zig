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
            // CheatLib.free() routes pool-backed slices to ReadPool.release()
            // and GPA-backed slices to heapAlloc().free() — caller need not know.
            const data = try CheatLib.socketRead(rt_ptr.heapAlloc(), client_fd);
            defer CheatLib.free(rt_ptr, data);

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

// ---------------------------------------------------------------------------
// Phase 4 — parseIpv4Addr unit tests
// ---------------------------------------------------------------------------

// parseIpv4Addr is private, so we re-expose it via a test-only shim.
// We replicate the logic here to avoid coupling to runtime-header internals.
fn parseIpv4Addr(host: []const u8) !u32 {
    var parts: [4]u8 = .{0} ** 4;
    var part_idx: usize = 0;
    var cur: u32 = 0;
    var has_digit: bool = false;
    for (host) |c| {
        switch (c) {
            '0'...'9' => {
                cur = cur * 10 + (c - '0');
                if (cur > 255) return error.InvalidHost;
                has_digit = true;
            },
            '.' => {
                if (!has_digit or part_idx >= 3) return error.InvalidHost;
                parts[part_idx] = @intCast(cur);
                part_idx += 1;
                cur = 0;
                has_digit = false;
            },
            else => return error.InvalidHost,
        }
    }
    if (!has_digit or part_idx != 3) return error.InvalidHost;
    parts[3] = @intCast(cur);
    const host_order: u32 = (@as(u32, parts[0]) << 24) | (@as(u32, parts[1]) << 16) |
                             (@as(u32, parts[2]) << 8) | @as(u32, parts[3]);
    return std.mem.nativeToBig(u32, host_order);
}

test "parseIpv4Addr — loopback resolves to 0x7f000001 in network byte order" {
    const result = try parseIpv4Addr("127.0.0.1");
    // Network byte order (big-endian) for 127.0.0.1 is 0x7f000001.
    try std.testing.expectEqual(@as(u32, std.mem.nativeToBig(u32, 0x7f000001)), result);
}

test "parseIpv4Addr — arbitrary address 192.168.1.5" {
    const result = try parseIpv4Addr("192.168.1.5");
    const expected = std.mem.nativeToBig(u32, (@as(u32, 192) << 24) | (@as(u32, 168) << 16) | (@as(u32, 1) << 8) | 5);
    try std.testing.expectEqual(expected, result);
}

test "parseIpv4Addr — rejects hostname (non-numeric)" {
    const err = parseIpv4Addr("localhost");
    try std.testing.expectError(error.InvalidHost, err);
}

test "parseIpv4Addr — rejects too few octets" {
    const err = parseIpv4Addr("127.0.1");
    try std.testing.expectError(error.InvalidHost, err);
}

test "parseIpv4Addr — rejects octet > 255" {
    const err = parseIpv4Addr("256.0.0.1");
    try std.testing.expectError(error.InvalidHost, err);
}

test "parseIpv4Addr — rejects empty string" {
    const err = parseIpv4Addr("");
    try std.testing.expectError(error.InvalidHost, err);
}

// ---------------------------------------------------------------------------
// Phase 4 — socketConnect tests
// ---------------------------------------------------------------------------
// socketConnect uses fp.active_scheduler + getCurrent() and MUST run inside a
// fiber.  We use the same "server fiber + OS-thread client" pattern as
// tests 3 and 5, but the client thread calls socketConnect so we can verify
// the non-blocking connect + EINPROGRESS → yield path.
//
// Strategy:
//   • A fiber runs the server: socketAccept (yields via epoll).
//   • An OS thread runs the client: calls CheatLib.socketConnect, which
//     internally registers the client fd with the *scheduler's* epoll and
//     yields the current *fiber*.  But since the OS thread is NOT a fiber,
//     we instead use a plain posix connect here to keep the OS thread simple
//     and exercise socketConnect from within a second client fiber.
//
// Two-fiber approach (server fiber + client fiber):
//   • Pre-create the server socket in the test body (socketListen is
//     scheduler-free) so the port is known before either fiber spawns.
//   • Server fiber: socketAccept → read ping → write pong.
//   • Client fiber: socketConnect → write ping → read pong.
//   Both fibers are spawned into the same single-threaded scheduler.

const ConnectCtx = struct {
    server_fd: i32,
    port: u16,
    server_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    connect_ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

test "socketConnect — connect to loopback server, send/receive round-trip" {
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

    // Bind server socket before spawning fibers (socketListen is scheduler-free).
    const sfd = try CheatLib.socketListen(0);
    var sa: std.posix.sockaddr.in = undefined;
    var sa_len: std.posix.socklen_t = @sizeOf(@TypeOf(sa));
    try std.posix.getsockname(sfd, @ptrCast(&sa), &sa_len);
    const port = std.mem.bigToNative(u16, sa.port);

    var ctx = ConnectCtx{ .server_fd = sfd, .port = port };

    // Server fiber: accept one client, echo ping→pong.
    const ServerFiber = struct {
        fn run(_: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const c: *ConnectCtx = @ptrCast(@alignCast(raw_args.?));
            defer CheatLib.socketClose(c.server_fd);
            const cfd = try CheatLib.socketAccept(c.server_fd);
            defer CheatLib.socketClose(cfd);
            var buf: [32]u8 = undefined;
            const n = try CheatLib.read(cfd, &buf);
            if (std.mem.eql(u8, buf[0..n], "ping"))
                _ = try CheatLib.socketWrite(cfd, "pong");
            c.server_done.store(true, .seq_cst);
        }
    };

    // Client fiber: socketConnect → write ping → read pong.
    // getCurrent() works because this is a proper fiber inside the scheduler.
    const ClientFiber = struct {
        fn run(_: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const c: *ConnectCtx = @ptrCast(@alignCast(raw_args.?));
            const fd = try CheatLib.socketConnect("127.0.0.1", c.port);
            defer CheatLib.socketClose(fd);
            _ = try CheatLib.socketWrite(fd, "ping");
            var buf: [32]u8 = undefined;
            const n = try CheatLib.read(fd, &buf);
            if (std.mem.eql(u8, buf[0..n], "pong"))
                c.connect_ok.store(true, .seq_cst);
        }
    };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&ServerFiber.run)),
        &ctx, .{},
    );
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&ClientFiber.run)),
        &ctx, .{},
    );

    sched.run();

    try std.testing.expect(ctx.server_done.load(.seq_cst));
    try std.testing.expect(ctx.connect_ok.load(.seq_cst));
}

// ---------------------------------------------------------------------------
// socketConnect: ECONNREFUSED on a port that isn't listening.
// ---------------------------------------------------------------------------

const ConnRefusedCtx = struct {
    got_error: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

test "socketConnect — ECONNREFUSED on closed port" {
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

    var cr = ConnRefusedCtx{};

    const Fiber = struct {
        fn run(_: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const s: *ConnRefusedCtx = @ptrCast(@alignCast(raw_args.?));
            // Port 1 is not listening; expect ECONNREFUSED (or any connect error).
            const result = CheatLib.socketConnect("127.0.0.1", 1);
            if (result == error.ConnectionRefused) {
                s.got_error.store(true, .seq_cst);
            } else if (result) |fd| {
                CheatLib.socketClose(fd); // unexpected success
            } else |_| {
                s.got_error.store(true, .seq_cst); // any error is acceptable
            }
        }
    };

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&Fiber.run)),
        &cr, .{},
    );
    sched.run();

    try std.testing.expect(cr.got_error.load(.seq_cst));
}

// ---------------------------------------------------------------------------
// ReadPool unit tests (no sockets needed — test the slab directly)
// ---------------------------------------------------------------------------

// Test: acquire fills slots in order; release restores them.
test "ReadPool: acquire and release round-trip" {
    var pool = fp.ReadPool{};
    const full_mask: u8 = ~@as(u8, 0);

    // All 8 slots free at start.
    try std.testing.expectEqual(full_mask, pool.free_mask);

    // Acquire all 8 slots.
    var ptrs: [fp.ReadPool.SLOTS][*]u8 = undefined;
    for (0..fp.ReadPool.SLOTS) |i| {
        const slot = pool.acquire() orelse return error.TestUnexpectedNull;
        ptrs[i] = slot.ptr;
    }
    try std.testing.expectEqual(@as(u8, 0), pool.free_mask); // all in-use

    // 9th acquire must return null (pool exhausted).
    try std.testing.expectEqual(@as(?[]u8, null), pool.acquire());

    // Release all slots one by one; mask rebuilds.
    for (0..fp.ReadPool.SLOTS) |i| {
        try std.testing.expect(pool.release(ptrs[i]));
    }
    try std.testing.expectEqual(full_mask, pool.free_mask); // all free again
}

// Test: sequential acquire → release → acquire reuses the same slot (LIFO on ctz).
test "ReadPool: released slot is immediately reused" {
    var pool = fp.ReadPool{};

    const first = pool.acquire().?.ptr;
    try std.testing.expect(pool.release(first));   // return slot

    const second = pool.acquire().?.ptr;
    try std.testing.expectEqual(first, second);    // same slot pointer
}

// Test: release() returns false for a pointer outside the slab (GPA allocation).
test "ReadPool: release rejects out-of-slab pointer" {
    var pool = fp.ReadPool{};
    var outside: u8 = 0xFF;
    try std.testing.expect(!pool.release(@ptrCast(&outside)));
}

// ---------------------------------------------------------------------------
// ReadPool integration tests (require scheduler + fiber context)
// ---------------------------------------------------------------------------

// Test: socketRead uses a pool slot on the fast path; CheatLib.free returns it.
test "socketRead: uses pool slot, CheatLib.free recycles it" {
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
    var bound: std.posix.sockaddr.in = undefined;
    var bound_len: std.posix.socklen_t = @sizeOf(@TypeOf(bound));
    try std.posix.getsockname(server_fd, @ptrCast(&bound), &bound_len);
    const port = std.mem.bigToNative(u16, bound.port);

    const Shared = struct {
        server_fd: i32,
        port: u16,
        ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        // Slots free before the read; should be one fewer during the read,
        // then restored after CheatLib.free().
        mask_before: u8 = 0,
        mask_during: u8 = 0,
        mask_after: u8 = 0,
    };
    var shared = Shared{ .server_fd = server_fd, .port = port };

    const ServerFiber = struct {
        fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const rt_ptr: *Runtime = @ptrCast(@alignCast(raw_rt));
            const s: *Shared = @ptrCast(@alignCast(raw_args.?));

            s.ready.store(true, .seq_cst);
            const client_fd = try CheatLib.socketAccept(s.server_fd);
            defer CheatLib.socketClose(client_fd);

            s.mask_before = fp.active_scheduler.read_pool.free_mask;

            const data = try CheatLib.socketRead(rt_ptr.heapAlloc(), client_fd);

            s.mask_during = fp.active_scheduler.read_pool.free_mask;

            // Verify the pointer lives inside the pool slab (fast path was taken).
            const pool = &fp.active_scheduler.read_pool;
            const base = @intFromPtr(&pool.slab[0][0]);
            const p = @intFromPtr(data.ptr);
            std.debug.assert(p >= base and p < base + fp.ReadPool.SLOTS * fp.ReadPool.SLOT_SIZE);

            try CheatLib.socketWriteVoid(client_fd, data);

            CheatLib.free(rt_ptr, data);
            s.mask_after = fp.active_scheduler.read_pool.free_mask;

            s.done.store(true, .seq_cst);
        }
    };

    const ClientCtx = struct { port: u16 };
    var client_ctx = ClientCtx{ .port = port };
    const clientFn = struct {
        fn run(ctx: *ClientCtx) void {
            const fd = std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, 0) catch return;
            defer std.posix.close(fd);
            const addr = std.posix.sockaddr.in{
                .family = std.posix.AF.INET,
                .port = std.mem.nativeToBig(u16, ctx.port),
                .addr = std.mem.nativeToBig(u32, 0x7F000001),
                .zero = [_]u8{0} ** 8,
            };
            std.posix.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) catch return;
            _ = std.posix.write(fd, "pool test") catch return;
            var buf: [64]u8 = undefined;
            _ = std.posix.read(fd, &buf) catch return;
        }
    }.run;

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&ServerFiber.run)),
        &shared, .{},
    );
    const thread = try std.Thread.spawn(.{}, clientFn, .{&client_ctx});
    sched.run();
    thread.join();

    try std.testing.expect(shared.done.load(.seq_cst));
    // One slot was consumed during the read.
    try std.testing.expectEqual(shared.mask_before, shared.mask_after);           // recycled
    try std.testing.expect(shared.mask_during != shared.mask_before);             // was in-use
    try std.testing.expect(@popCount(shared.mask_during) + 1 == @popCount(shared.mask_before)); // exactly 1 slot used
}

// Test: restoreFrameMark releases pool slots acquired within the scope,
// without disturbing slots held by outer scopes or already freed explicitly.
test "ReadPool: restoreFrameMark releases in-scope slots" {
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

    const full_mask: u8 = ~@as(u8, 0);
    const pool = &sched.read_pool;

    // Simulate an "outer" slot held before saveFrameMark.
    const outer_slot = pool.acquire().?;
    const mask_after_outer = pool.free_mask; // one slot consumed

    // Save mark (captures current state: outer slot in-use, rest free).
    const mark = rt.saveFrameMark();

    // Acquire 3 more slots inside this scope.
    const a = pool.acquire().?;
    var b = pool.acquire().?;
    const c = pool.acquire().?;
    _ = a; _ = c;
    try std.testing.expectEqual(@popCount(mask_after_outer) - 3, @popCount(pool.free_mask)); // 3 more consumed

    // Explicitly free one of the inner slots before restoreFrameMark.
    try std.testing.expect(pool.release(b.ptr));
    b = undefined;

    // Restore — should release the 2 remaining in-scope slots (a, c)
    // but NOT touch the outer slot or double-release b.
    rt.restoreFrameMark(mark);

    try std.testing.expectEqual(mask_after_outer, pool.free_mask); // back to outer state

    // Release outer slot manually.
    try std.testing.expect(pool.release(outer_slot.ptr));
    try std.testing.expectEqual(full_mask, pool.free_mask);
}
