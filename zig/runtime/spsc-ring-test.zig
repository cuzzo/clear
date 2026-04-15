const std = @import("std");
const spsc = @import("spsc.zig");

test "SpscRing push pop preserves FIFO order and len" {
    var ring: spsc.SpscRing(4) = .{};

    try std.testing.expect(ring.push(.{ .tag = .Spawn, .trampoline_addr = 1 }));
    try std.testing.expect(ring.push(.{ .tag = .Spawn, .trampoline_addr = 2 }));
    try std.testing.expectEqual(@as(usize, 2), ring.len());

    const first = ring.pop().?;
    const second = ring.pop().?;

    try std.testing.expectEqual(@as(usize, 1), first.trampoline_addr);
    try std.testing.expectEqual(@as(usize, 2), second.trampoline_addr);
    try std.testing.expect(ring.isEmpty());
}

test "SpscRing full boundary rejects push until consumer pops" {
    var ring: spsc.SpscRing(2) = .{};

    try std.testing.expect(ring.push(.{ .tag = .Resume }));
    try std.testing.expect(ring.push(.{ .tag = .RemoteCall }));
    try std.testing.expect(!ring.push(.{ .tag = .Spawn }));

    _ = ring.pop().?;
    try std.testing.expect(ring.push(.{ .tag = .Spawn, .trampoline_addr = 9 }));
    try std.testing.expectEqual(@as(usize, 2), ring.len());
}

test "SpscRing peek does not consume and wraparound stays ordered" {
    var ring: spsc.SpscRing(4) = .{};

    try std.testing.expect(ring.push(.{ .tag = .Spawn, .trampoline_addr = 10 }));
    try std.testing.expect(ring.push(.{ .tag = .Spawn, .trampoline_addr = 11 }));
    try std.testing.expectEqual(@as(usize, 10), ring.peek().?.trampoline_addr);
    try std.testing.expectEqual(@as(usize, 10), ring.peek().?.trampoline_addr);

    _ = ring.pop().?;
    _ = ring.pop().?;
    try std.testing.expect(ring.isEmpty());

    try std.testing.expect(ring.push(.{ .tag = .Spawn, .trampoline_addr = 20 }));
    try std.testing.expect(ring.push(.{ .tag = .Spawn, .trampoline_addr = 21 }));
    try std.testing.expect(ring.push(.{ .tag = .Spawn, .trampoline_addr = 22 }));

    try std.testing.expectEqual(@as(usize, 20), ring.pop().?.trampoline_addr);
    try std.testing.expectEqual(@as(usize, 21), ring.pop().?.trampoline_addr);
    try std.testing.expectEqual(@as(usize, 22), ring.pop().?.trampoline_addr);
    try std.testing.expect(ring.isEmpty());
}
