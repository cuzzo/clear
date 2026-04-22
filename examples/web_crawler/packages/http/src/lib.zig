// http — thin wrapper over libc sockets for CLEAR FFI.
//
// Provides:
//   httpGet(url)          -> []const u8  (fetch page body over TCP)
//   startTestServer(port) -> void        (spawn canned-page server on OS thread)
//   stopTestServer()      -> void        (signal shutdown)
//   freeString(ptr, len)  -> void        (free a string returned by httpGet)
//
// All returned strings are allocated with c_allocator so they survive
// CLEAR's frame rewind. Caller is responsible for freeing via freeString.

const std = @import("std");
const c = std.c;
const alloc = std.heap.c_allocator;

fn makeSockAddr(ip: u32, port: u16) c.sockaddr.in {
    return c.sockaddr.in{
        .family = c.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = ip,
        .zero = std.mem.zeroes([8]u8),
    };
}

// -------------------------------------------------------------------------
// HTTP Client
// -------------------------------------------------------------------------

pub fn httpGet(url: []const u8) []const u8 {
    return doGet(url) catch "";
}

fn doGet(url: []const u8) ![]const u8 {
    // Parse "host:port/path"
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return error.BadUrl;
    const host = url[0..colon];
    const rest = url[colon + 1 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const port = std.fmt.parseInt(u16, rest[0..slash], 10) catch return error.BadUrl;
    const path = if (slash < rest.len) rest[slash..] else "/";

    // Resolve "localhost" / "127.0.0.1"
    const ip: u32 = if (std.mem.eql(u8, host, "localhost") or std.mem.eql(u8, host, "127.0.0.1"))
        std.mem.nativeToBig(u32, 0x7f000001)
    else
        return error.UnsupportedHost;

    const fd = c.socket(c.AF.INET, c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    defer _ = c.close(fd);

    var addr = makeSockAddr(ip, port);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0)
        return error.ConnectFailed;

    const req = try std.fmt.allocPrint(alloc, "GET {s} HTTP/1.0\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ path, host });
    defer alloc.free(req);
    _ = c.send(fd, req.ptr, req.len, 0);

    var buf: [65536]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const n = c.recv(fd, buf[total..].ptr, buf.len - total, 0);
        if (n <= 0) break;
        total += @intCast(n);
    }

    const response = buf[0..total];
    const sep = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return try alloc.dupe(u8, "");
    const body = response[sep + 4 ..];
    return try alloc.dupe(u8, body);
}

pub fn freeString(ptr: [*]const u8, len: i64) void {
    if (len <= 0) return;
    const n: usize = @intCast(len);
    alloc.free(ptr[0..n]);
}

// -------------------------------------------------------------------------
// Test Server
// -------------------------------------------------------------------------

var server_shutdown = std.atomic.Value(bool).init(false);
var server_thread: ?std.Thread = null;

pub fn startTestServer(port: i64) void {
    server_shutdown.store(false, .release);
    const p: u16 = @intCast(port);
    server_thread = std.Thread.spawn(.{}, serverLoop, .{p}) catch return;
}

pub fn stopTestServer() void {
    server_shutdown.store(true, .release);
    if (server_thread) |t| {
        t.join();
        server_thread = null;
    }
}

fn serverLoop(port: u16) void {
    const server_fd = c.socket(c.AF.INET, c.SOCK.STREAM | c.SOCK.CLOEXEC, 0);
    if (server_fd < 0) return;
    defer _ = c.close(server_fd);

    const yes: i32 = 1;
    _ = c.setsockopt(server_fd, c.SOL.SOCKET, c.SO.REUSEADDR, @ptrCast(&yes), @sizeOf(i32));

    // 200ms receive timeout so we can poll shutdown flag
    const tv = c.timeval{ .sec = 0, .usec = 200_000 };
    _ = c.setsockopt(server_fd, c.SOL.SOCKET, c.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(c.timeval));

    const ip = std.mem.nativeToBig(u32, 0x7f000001);
    var addr = makeSockAddr(ip, port);
    if (c.bind(server_fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) return;
    if (c.listen(server_fd, 16) != 0) return;

    while (!server_shutdown.load(.acquire)) {
        const client_fd = c.accept(server_fd, null, null);
        if (client_fd < 0) continue;
        handleConnection(client_fd) catch {};
        _ = c.close(client_fd);
    }
}

fn handleConnection(fd: i32) !void {
    var buf: [1024]u8 = undefined;
    const n = c.recv(fd, &buf, buf.len, 0);
    if (n <= 0) return;

    const request = buf[0..@intCast(n)];
    const get_end = std.mem.indexOf(u8, request, " HTTP/") orelse return;
    const path = if (get_end > 4) request[4..get_end] else "/";

    const body = route(path);
    const status = if (body.len > 0) "200 OK" else "404 Not Found";
    const response_body = if (body.len > 0) body else "<html><body>Not Found</body></html>";

    const response = try std.fmt.allocPrint(alloc, "HTTP/1.0 {s}\r\nContent-Length: {d}\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n{s}", .{ status, response_body.len, response_body });
    defer alloc.free(response);
    _ = c.send(fd, response.ptr, response.len, 0);
}

fn route(path: []const u8) []const u8 {
    if (std.mem.eql(u8, path, "/")) {
        return
            \\<html><head><title>Home</title></head><body>
            \\<h1>Welcome</h1>
            \\<a href="/about">About</a>
            \\<a href="/blog">Blog</a>
            \\</body></html>
        ;
    } else if (std.mem.eql(u8, path, "/about")) {
        return
            \\<html><head><title>About</title></head><body>
            \\<h1>About Us</h1>
            \\<a href="/">Home</a>
            \\</body></html>
        ;
    } else if (std.mem.eql(u8, path, "/blog")) {
        return
            \\<html><head><title>Blog</title></head><body>
            \\<h1>Blog Posts</h1>
            \\<a href="/about">About</a>
            \\<a href="/">Home</a>
            \\</body></html>
        ;
    }
    return "";
}
