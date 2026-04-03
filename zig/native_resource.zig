// Native module with a resource type that requires cleanup.

const std = @import("std");

pub const Buffer = struct {
    data: []const u8,

    pub fn deinit(self: *Buffer) void {
        if (self.data.len > 0) {
            std.heap.c_allocator.free(@constCast(self.data));
        }
        self.data = &.{};
    }
};

pub fn createBuffer(content: []const u8) Buffer {
    const copy = std.heap.c_allocator.dupe(u8, content) catch &.{};
    return Buffer{ .data = copy };
}

pub fn bufferLength(buf: Buffer) i64 {
    return @intCast(buf.data.len);
}
