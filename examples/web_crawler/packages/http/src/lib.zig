// http — thin Zig wrapper over std.net for CLEAR FFI.
//
// Provides:
//   httpGet(url)         → []const u8   (fetch page body over TCP)
//   startTestServer(port) → void        (spawn canned-page server on OS thread)
//   stopTestServer()      → void        (signal shutdown)
//   freeString(ptr, len)  → void        (free a string returned by httpGet)
//
// All returned strings are allocated with c_allocator so they survive
// CLEAR's frame rewind. Caller is responsible for freeing via freeString.

const std = @import("std");
const alloc = std.heap.c_allocator;

// -------------------------------------------------------------------------
// HTTP Client — minimal GET request over raw TCP
// -------------------------------------------------------------------------

/// Fetch a page body from "host:port/path".
/// URL format: "localhost:PORT/path" (no scheme).
/// Returns the HTTP response body (heap-allocated via c_allocator).
/// Returns empty slice on any error.
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

    // Connect
    const addr = try std.net.Address.resolveIp(host, port);
    const stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();

    // Send GET request
    const req = try std.fmt.allocPrint(alloc, "GET {s} HTTP/1.0\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ path, host });
    defer alloc.free(req);
    try stream.writeAll(req);

    // Read full response
    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&tmp) catch break;
        if (n == 0) break;
        try buf.appendSlice(tmp[0..n]);
    }

    // Find body after \r\n\r\n
    const response = buf.items;
    const sep = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return try alloc.dupe(u8, "");
    const body = response[sep + 4 ..];
    return try alloc.dupe(u8, body);
}

/// Free a string previously returned by httpGet.
pub fn freeString(ptr: [*]const u8, len: i64) void {
    if (len <= 0) return;
    const n: usize = @intCast(len);
    alloc.free(ptr[0..n]);
}

// -------------------------------------------------------------------------
// Test Server — canned HTML pages on an OS thread
// -------------------------------------------------------------------------

var server_shutdown = std.atomic.Value(bool).init(false);
var server_thread: ?std.Thread = null;

/// Start a test HTTP server on `port` in a background OS thread.
/// Serves 3 canned pages:
///   /           → index with links to /about and /blog
///   /about      → about page with link to /
///   /blog       → blog page with links to /about and /
///   everything else → 404
pub fn startTestServer(port: i64) void {
    server_shutdown.store(false, .release);
    const p: u16 = @intCast(port);
    server_thread = std.Thread.spawn(.{}, serverLoop, .{p}) catch return;
}

/// Signal the test server to shut down and wait for its thread.
pub fn stopTestServer() void {
    server_shutdown.store(true, .release);
    if (server_thread) |t| {
        t.join();
        server_thread = null;
    }
}

fn serverLoop(port: u16) void {
    const addr = std.net.Address.parseIp4("127.0.0.1", port) catch return;
    var server = addr.listen(.{ .reuse_address = true }) catch return;
    defer server.deinit();

    // Set a short timeout so we can check shutdown flag
    if (std.posix.setsockopt(server.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &std.mem.toBytes(std.posix.timeval{
        .sec = 0,
        .usec = 200_000, // 200ms
    }))) {} else |_| {}

    while (!server_shutdown.load(.acquire)) {
        const conn = server.accept() catch continue;
        handleConnection(conn.stream) catch {};
    }
}

fn handleConnection(stream: std.net.Stream) !void {
    defer stream.close();

    // Read request line
    var buf: [1024]u8 = undefined;
    const n = stream.read(&buf) catch return;
    if (n == 0) return;

    // Extract path from "GET /path HTTP/1.x"
    const request = buf[0..n];
    const get_end = std.mem.indexOf(u8, request, " HTTP/") orelse return;
    const path = if (get_end > 4) request[4..get_end] else "/";

    // Route to canned pages
    const body = route(path);
    const status = if (body.len > 0) "200 OK" else "404 Not Found";
    const response_body = if (body.len > 0) body else "<html><body>Not Found</body></html>";

    const response = std.fmt.allocPrint(alloc, "HTTP/1.0 {s}\r\nContent-Length: {d}\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n{s}", .{ status, response_body.len, response_body }) catch return;
    defer alloc.free(response);
    stream.writeAll(response) catch {};
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
