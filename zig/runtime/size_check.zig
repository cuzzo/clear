const spsc = @import("spsc.zig");
const fm = @import("fiber-memory.zig");
const fp = @import("scheduler.zig");
const std = @import("std");
const posix = std.posix;

pub fn main() !void {
    const fd = posix.STDOUT_FILENO;
    var buf: [512]u8 = undefined;

    var n = std.fmt.bufPrint(&buf, "Message size:       {} bytes\n", .{@sizeOf(spsc.Message)}) catch unreachable;
    _ = posix.write(fd, n) catch {};
    n = std.fmt.bufPrint(&buf, "DefaultRing size:   {} bytes ({} KB)\n", .{@sizeOf(spsc.DefaultRing), @sizeOf(spsc.DefaultRing) / 1024}) catch unreachable;
    _ = posix.write(fd, n) catch {};
    n = std.fmt.bufPrint(&buf, "64 rings:           {} bytes ({} MB)\n", .{@sizeOf([64]spsc.DefaultRing), @sizeOf([64]spsc.DefaultRing) / 1024 / 1024}) catch unreachable;
    _ = posix.write(fd, n) catch {};
    n = std.fmt.bufPrint(&buf, "Scheduler size:     {} bytes ({} KB)\n", .{@sizeOf(fp.Scheduler), @sizeOf(fp.Scheduler) / 1024}) catch unreachable;
    _ = posix.write(fd, n) catch {};
    n = std.fmt.bufPrint(&buf, "StackPool size:     {} bytes\n", .{@sizeOf(fm.StackPool)}) catch unreachable;
    _ = posix.write(fd, n) catch {};
}
