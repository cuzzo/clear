// Socket Throughput Benchmark — CLEAR Runtime (ReadPool path)
//
// Compiled from the zig/ directory so relative @import paths resolve:
//   cp benchmarks/04_socket_throughput/bench.zig zig/bench.zig
//   cd zig && zig build-exe bench.zig switch.S onRoot.S --name bench_clear -O ReleaseFast -lc
//
// This is the code path CLEAR generates for tcpRead inside a fiber task.
// Two fibers share a Unix socketpair:
//
//   Writer fiber: CheatLib.socketWrite (non-blocking, yields on EAGAIN)
//   Reader fiber: CheatLib.socketRead  (ReadPool fast path — zero GPA malloc)
//
// OLD path (before ReadPool):
//   socketRead → allocator.dupe(u8, buf[0..n])
//   = 1 GPA malloc per read × N reads → lock + header bookkeeping every call
//
// NEW path (ReadPool):
//   socketRead → pool.acquire() = @ctz(free_mask) — single bitmask instruction
//   slot released by restoreFrameMark() at frame boundary — O(1) bitmask OR
//   = 0 GPA malloc calls in the hot path

const std = @import("std");
const CheatLib = @import("runtime-header.zig").CheatLib;
const CheatHeader = @import("runtime-header.zig");
const Runtime = @import("runtime.zig").Runtime;
const EbrContext = @import("ebr.zig").EbrContext;
const fm = @import("fiber-memory.zig");
const fp = @import("scheduler.zig");

// Pull in the exported panic symbols from fiber-core.
comptime {
    _ = @import("fiber-core.zig");
}

const N: usize = 100_000;
const MSG_SIZE: usize = 256;

// Shared state between writer and reader fibers.
const Ctx = struct {
    reader_fd: i32,
    writer_fd: i32,
    start_ns: i128 = 0,
    end_ns: i128 = 0,
};

// Writer fiber: sends N × MSG_SIZE bytes through the socketpair.
// CheatLib.socketWriteVoid handles EAGAIN by yielding to the scheduler.
fn writerBody(raw_rt: *anyopaque, raw_ctx: ?*anyopaque) anyerror!void {
    _ = raw_rt;
    const ctx: *Ctx = @ptrCast(@alignCast(raw_ctx.?));

    const msg = [_]u8{'X'} ** MSG_SIZE;
    var i: usize = 0;
    while (i < N) : (i += 1) {
        try CheatLib.socketWriteVoid(ctx.writer_fd, &msg);
    }
    // Close the write end so the reader sees EOF if it reads past N.
    CheatLib.socketClose(ctx.writer_fd);
}

// Reader fiber: reads N messages via CheatLib.socketRead (ReadPool path).
// Each call acquires a pool slot (bitmask ctz), reads into it, and returns
// a slice backed by the slot.  The slot is released when the frame mark is
// restored at scope exit — no explicit free needed in generated CLEAR code.
fn readerBody(raw_rt: *anyopaque, raw_ctx: ?*anyopaque) anyerror!void {
    const rt: *Runtime = @ptrCast(@alignCast(raw_rt));
    const ctx: *Ctx = @ptrCast(@alignCast(raw_ctx.?));

    ctx.start_ns = std.time.nanoTimestamp();

    var i: usize = 0;
    while (i < N) : (i += 1) {
        // This is the line the transpiler emits for `tcpRead(client)`.
        // With ReadPool: zero GPA malloc per call.
        const data = try CheatLib.socketRead(rt.frameAlloc(), ctx.reader_fd);
        _ = data.len; // prevent dead-code elimination
    }

    ctx.end_ns = std.time.nanoTimestamp();
    CheatLib.socketClose(ctx.reader_fd);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Unix socketpair — both ends non-blocking so the scheduler can epoll them.
    // std.posix.socketpair is not available in Zig 0.15; use the libc wrapper.
    var raw_fds: [2]std.c.fd_t = undefined;
    const sp_rc = std.c.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
        0,
        &raw_fds,
    );
    if (sp_rc != 0) return error.SocketpairFailed;

    var ctx = Ctx{
        .reader_fd = @intCast(raw_fds[0]),
        .writer_fd = @intCast(raw_fds[1]),
    };

    // ── Scheduler setup (same as runtime-footer.zig + socket-test.zig) ──────
    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(allocator);
    }
    fp.active_scheduler = &sched;

    // Spawn writer fiber (runs first in FIFO order).
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&writerBody)),
        &ctx,
        .{},
    );
    // Spawn reader fiber.
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&readerBody)),
        &ctx,
        .{},
    );

    // Drive both fibers to completion.
    sched.run();

    // ── Results ──────────────────────────────────────────────────────────────
    const elapsed_ns = ctx.end_ns - ctx.start_ns;
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;

    std.debug.print("reads = {d}\n", .{N});
    std.debug.print("Time: {d:.4} seconds\n", .{elapsed_s});
    std.debug.print("Throughput: {d:.2} M reads/sec\n", .{
        @as(f64, @floatFromInt(N)) / elapsed_s / 1e6,
    });
}
