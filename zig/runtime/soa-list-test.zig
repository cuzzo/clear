// soa-list-test.zig — Unit tests for SoaList (Structure of Arrays dynamic list).

const std = @import("std");
const CheatLib = @import("runtime-header.zig").CheatLib;

const Entity = struct {
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
    health: f64,
};

test "SoaList: append + get round-trip" {
    var list = CheatLib.SoaList(Entity){};
    defer list.deinit(std.testing.allocator);

    try list.append(std.testing.allocator, .{ .x = 1, .y = 2, .vx = 3, .vy = 4, .health = 100 });
    try list.append(std.testing.allocator, .{ .x = 10, .y = 20, .vx = 30, .vy = 40, .health = 200 });

    try std.testing.expectEqual(@as(i64, 2), list.length());

    const e0 = list.get(0);
    try std.testing.expectApproxEqAbs(@as(f64, 1), e0.x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 100), e0.health, 1e-9);

    const e1 = list.get(1);
    try std.testing.expectApproxEqAbs(@as(f64, 10), e1.x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 200), e1.health, 1e-9);
}

test "SoaList: field-slice iteration (the SOA win)" {
    var list = CheatLib.SoaList(Entity){};
    defer list.deinit(std.testing.allocator);

    for (0..100) |i| {
        try list.append(std.testing.allocator, .{
            .x = @floatFromInt(i),
            .y = 0, .vx = 0, .vy = 0,
            .health = @as(f64, @floatFromInt(i)) * 2.0,
        });
    }

    // Iterate only the health field slice — contiguous f64 array
    const health_slice = list.data.items(.health);
    var sum: f64 = 0;
    for (health_slice) |h| sum += h;

    // sum of 0*2 + 1*2 + ... + 99*2 = 2 * (99*100/2) = 9900
    try std.testing.expectApproxEqAbs(@as(f64, 9900), sum, 1e-9);
}

test "SoaList: set modifies individual element" {
    var list = CheatLib.SoaList(Entity){};
    defer list.deinit(std.testing.allocator);

    try list.append(std.testing.allocator, .{ .x = 1, .y = 2, .vx = 0, .vy = 0, .health = 50 });
    list.set(0, .{ .x = 99, .y = 2, .vx = 0, .vy = 0, .health = 999 });

    const e = list.get(0);
    try std.testing.expectApproxEqAbs(@as(f64, 99), e.x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 999), e.health, 1e-9);
}

test "SoaList: empty list" {
    var list = CheatLib.SoaList(Entity){};
    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 0), list.length());
    try std.testing.expectEqual(@as(i64, 0), list.count());
}

test "SoaList.empty initializes an empty list" {
    var list = CheatLib.SoaList(Entity).empty;
    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 0), list.length());
    try list.append(std.testing.allocator, .{ .x = 5, .y = 6, .vx = 0, .vy = 0, .health = 7 });
    try std.testing.expectEqual(@as(i64, 1), list.count());
    try std.testing.expectApproxEqAbs(@as(f64, 7), list.get(0).health, 1e-9);
}
