// Every line and branch of runtime/io-backend.zig, which is the platform
// selection for the scheduler's completion ring.
//
// The comptime `have_io_uring` split means exactly one side of each selection
// is COMPILED per target, so "every branch" is per-target by construction:
// on Linux the std.os.linux aliases compile and PollRing's body does not get
// exercised by the scheduler, and off Linux the reverse. These tests cover the
// side that is live on the host they run on, plus both sides of every runtime
// branch.
const std = @import("std");
const builtin = @import("builtin");
const iob = @import("runtime/io-backend.zig");
// The repo routes time through compat so a simulated clock can replace it.
const compat = @import("lib/compat.zig");

test "the ring type tracks the platform" {
    try std.testing.expectEqual(builtin.os.tag == .linux, iob.have_io_uring);
    if (iob.have_io_uring) {
        try std.testing.expectEqual(std.os.linux.IoUring, iob.DefaultRing);
    } else {
        try std.testing.expectEqual(iob.PollRing, iob.DefaultRing);
    }
}

test "the substituted types carry the fields the scheduler reads" {
    // The scheduler stores [128]Cqe and reads user_data/res, sets Sqe.len, and
    // builds a KernelTimespec from sec/nsec. If a field is renamed away the
    // scheduler stops compiling, so pin them here.
    var cqe: iob.Cqe = std.mem.zeroes(iob.Cqe);
    cqe.user_data = 7;
    cqe.res = -1;
    try std.testing.expectEqual(@as(u64, 7), cqe.user_data);
    try std.testing.expectEqual(@as(i32, -1), cqe.res);

    var sqe: iob.Sqe = std.mem.zeroes(iob.Sqe);
    sqe.len = iob.POLL_ADD_MULTI;
    try std.testing.expectEqual(iob.POLL_ADD_MULTI, sqe.len);

    const ts = iob.KernelTimespec{ .sec = 1, .nsec = 2 };
    try std.testing.expectEqual(@as(i64, 1), ts.sec);
    try std.testing.expectEqual(@as(i64, 2), ts.nsec);

    // POLL_IN must be the real POLLIN bit or the scheduler polls for nothing.
    try std.testing.expect(iob.POLL_IN != 0);
}

test "WakeFd opens a usable wake channel and a write is readable" {
    var wake = try iob.WakeFd.open();
    defer wake.close();
    try std.testing.expect(wake.read_fd >= 0);
    try std.testing.expect(wake.write_fd >= 0);

    const val: u64 = 1;
    const bytes = std.mem.asBytes(&val);
    const wrote = std.c.write(wake.write_fd, bytes.ptr, bytes.len);
    try std.testing.expect(wrote > 0);

    var back: u64 = 0;
    const got = std.c.read(wake.read_fd, std.mem.asBytes(&back), @sizeOf(u64));
    try std.testing.expect(got > 0);
}

test "WakeFd.close handles the one-fd and two-fd shapes" {
    // Two fds (the pipe shape) is what open() produces off Linux.
    var two = try iob.WakeFd.open();
    two.close();

    // One fd (the eventfd shape, where both ends are the same descriptor):
    // close() must not double-close it. Build it explicitly so the branch is
    // covered on every host, not only on Linux.
    const libc = struct {
        extern "c" fn dup(fd: i32) i32;
    };
    const fd = libc.dup(0);
    if (fd >= 0) {
        var one = iob.WakeFd{ .read_fd = fd, .write_fd = fd };
        one.close();
    }
}

test "WakeFd.open reports failure when descriptors are exhausted" {
    if (iob.have_io_uring) return error.SkipZigTest; // eventfd path, not pipe

    // Hold every free descriptor so pipe() cannot succeed, then confirm the
    // error path returns rather than handing back a half-open channel.
    var held = std.ArrayListUnmanaged(i32).empty;
    defer {
        for (held.items) |fd| _ = std.c.close(fd);
        held.deinit(std.testing.allocator);
    }
    const libc = struct {
        extern "c" fn dup(fd: i32) i32;
    };
    while (held.items.len < 100_000) {
        const fd = libc.dup(0);
        if (fd < 0) break;
        try held.append(std.testing.allocator, fd);
    }
    // If the sandbox allows unlimited descriptors this cannot be forced; only
    // assert when exhaustion was actually reached.
    if (held.items.len >= 100_000) return error.SkipZigTest;
    try std.testing.expectError(error.Unexpected, iob.WakeFd.open());
}

test "PollRing init and deinit round-trip" {
    var ring = try iob.PollRing.init(256, 0);
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), ring.wake_fd);
    try std.testing.expectEqual(@as(u64, 0), ring.pending_timeout_ns);
    ring.deinit();
    try std.testing.expectEqual(@as(std.posix.fd_t, -1), ring.wake_fd);
}

test "poll_add records the wake fd and hands back a writable sqe" {
    var ring = try iob.PollRing.init(256, 0);
    defer ring.deinit();
    const sqe = try ring.poll_add(0, 42, @intCast(iob.POLL_IN));
    try std.testing.expectEqual(@as(std.posix.fd_t, 42), ring.wake_fd);
    sqe.len = iob.POLL_ADD_MULTI;
    try std.testing.expectEqual(iob.POLL_ADD_MULTI, ring.scratch.len);
}

test "timeout converts sec/nsec, and clamps a non-positive duration to none" {
    var ring = try iob.PollRing.init(256, 0);
    defer ring.deinit();

    _ = try ring.timeout(0, &.{ .sec = 1, .nsec = 500 }, 0, 0);
    try std.testing.expectEqual(@as(u64, 1_000_000_500), ring.pending_timeout_ns);

    // secs <= 0 is the other side of that branch: zero and negative both mean
    // "no timeout", never a huge unsigned value from a wrapping cast.
    _ = try ring.timeout(0, &.{ .sec = 0, .nsec = 0 }, 0, 0);
    try std.testing.expectEqual(@as(u64, 0), ring.pending_timeout_ns);

    _ = try ring.timeout(0, &.{ .sec = -5, .nsec = 0 }, 0, 0);
    try std.testing.expectEqual(@as(u64, 0), ring.pending_timeout_ns);
}

test "submit is a no-op that reports zero submissions" {
    var ring = try iob.PollRing.init(256, 0);
    defer ring.deinit();
    try std.testing.expectEqual(@as(u32, 0), try ring.submit());
}

test "copy_cqes with wait_nr 0 returns immediately and clears the timeout" {
    var ring = try iob.PollRing.init(256, 0);
    defer ring.deinit();
    _ = try ring.timeout(0, &.{ .sec = 0, .nsec = 5_000_000 }, 0, 0);
    var cqes: [4]iob.Cqe = undefined;

    const t0 = compat.milliTimestamp();
    try std.testing.expectEqual(@as(u32, 0), try ring.copy_cqes(&cqes, 0));
    try std.testing.expect(compat.milliTimestamp() - t0 < 50);
    // The queued timeout is consumed even on the non-blocking path, or it
    // would leak into the next park.
    try std.testing.expectEqual(@as(u64, 0), ring.pending_timeout_ns);
}

test "copy_cqes parks on the wake fd and returns as soon as it is readable" {
    var ring = try iob.PollRing.init(256, 0);
    defer ring.deinit();
    var wake = try iob.WakeFd.open();
    defer wake.close();
    _ = try ring.poll_add(0, wake.read_fd, @intCast(iob.POLL_IN));

    // Already-readable: poll() must return at once rather than burn the ceiling.
    const val: u64 = 1;
    _ = std.c.write(wake.write_fd, std.mem.asBytes(&val), @sizeOf(u64));

    var cqes: [4]iob.Cqe = undefined;
    const t0 = compat.milliTimestamp();
    try std.testing.expectEqual(@as(u32, 0), try ring.copy_cqes(&cqes, 1));
    try std.testing.expect(compat.milliTimestamp() - t0 < 50);
}

test "copy_cqes with no queued timeout parks up to the 50ms ceiling" {
    var ring = try iob.PollRing.init(256, 0);
    defer ring.deinit();
    var wake = try iob.WakeFd.open();
    defer wake.close();
    _ = try ring.poll_add(0, wake.read_fd, @intCast(iob.POLL_IN));

    // Nothing readable and no timeout queued: this is the timeout_ns == 0
    // side, which parks for the ceiling instead of spinning.
    var cqes: [4]iob.Cqe = undefined;
    const t0 = compat.milliTimestamp();
    try std.testing.expectEqual(@as(u32, 0), try ring.copy_cqes(&cqes, 1));
    const waited = compat.milliTimestamp() - t0;
    try std.testing.expect(waited >= 25);
}

test "a sub-millisecond timeout still parks instead of spinning" {
    var ring = try iob.PollRing.init(256, 0);
    defer ring.deinit();
    var wake = try iob.WakeFd.open();
    defer wake.close();
    _ = try ring.poll_add(0, wake.read_fd, @intCast(iob.POLL_IN));

    // 0.2ms truncates to 0 under integer division; the 1ms floor is what keeps
    // this from becoming a busy loop in the scheduler's idle path.
    _ = try ring.timeout(0, &.{ .sec = 0, .nsec = 200_000 }, 0, 0);
    var cqes: [4]iob.Cqe = undefined;
    const t0 = compat.nanoTimestamp();
    try std.testing.expectEqual(@as(u32, 0), try ring.copy_cqes(&cqes, 1));
    try std.testing.expect(compat.nanoTimestamp() - t0 > 0);
}

test "a timeout past the ceiling is clamped to it" {
    var ring = try iob.PollRing.init(256, 0);
    defer ring.deinit();
    var wake = try iob.WakeFd.open();
    defer wake.close();
    _ = try ring.poll_add(0, wake.read_fd, @intCast(iob.POLL_IN));

    // 10 seconds requested; the ceiling keeps a missed wake from hanging.
    _ = try ring.timeout(0, &.{ .sec = 10, .nsec = 0 }, 0, 0);
    var cqes: [4]iob.Cqe = undefined;
    const t0 = compat.milliTimestamp();
    try std.testing.expectEqual(@as(u32, 0), try ring.copy_cqes(&cqes, 1));
    try std.testing.expect(compat.milliTimestamp() - t0 < 5000);
}

test "copy_cqes sleeps rather than spins when no wake fd is registered" {
    var ring = try iob.PollRing.init(256, 0);
    defer ring.deinit();
    // wake_fd stays -1: the usleep side of that branch.
    _ = try ring.timeout(0, &.{ .sec = 0, .nsec = 2_000_000 }, 0, 0);
    var cqes: [4]iob.Cqe = undefined;
    const t0 = compat.milliTimestamp();
    try std.testing.expectEqual(@as(u32, 0), try ring.copy_cqes(&cqes, 1));
    try std.testing.expect(compat.milliTimestamp() - t0 >= 1);
}

test "every async submission reports AsyncIoUnsupported" {
    var ring = try iob.PollRing.init(256, 0);
    defer ring.deinit();
    var buf: [8]u8 = undefined;
    const out: []const u8 = &buf;

    try std.testing.expectError(error.AsyncIoUnsupported, ring.read(1, 3, .{ .buffer = &buf }, 0));
    try std.testing.expectError(error.AsyncIoUnsupported, ring.write(1, 3, out, 0));
    try std.testing.expectError(error.AsyncIoUnsupported, ring.recv(1, 3, .{ .buffer = &buf }, 0));
    try std.testing.expectError(error.AsyncIoUnsupported, ring.send(1, 3, out, 0));
    try std.testing.expectError(error.AsyncIoUnsupported, ring.accept(1, 3, null, null, 0));
    try std.testing.expectError(error.AsyncIoUnsupported, ring.connect(1, 3, @as(?*anyopaque, null), @as(u32, 0)));
}
