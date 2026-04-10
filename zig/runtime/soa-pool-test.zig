// soa-pool-test.zig — Unit tests for SoaPool (Structure of Arrays generational pool).
//
// Run: zig test soa-pool-test.zig

const std = @import("std");
const CheatLib = @import("runtime-header.zig").CheatLib;

const Entity = struct {
    x: f64,
    y: f64,
    vx: f64,
    vy: f64,
    health: f64,
};

test "SoaPool: insert + get round-trip" {
    var pool = try CheatLib.SoaPool(Entity).initCapacity(std.testing.allocator, 16);
    defer pool.deinit(std.testing.allocator);

    const id = try pool.insert(std.testing.allocator, .{
        .x = 1.0, .y = 2.0, .vx = 0.5, .vy = -0.5, .health = 100.0,
    });

    const val = pool.get(id).?;
    try std.testing.expectEqual(@as(f64, 1.0), val.x);
    try std.testing.expectEqual(@as(f64, 2.0), val.y);
    try std.testing.expectEqual(@as(f64, 100.0), val.health);
}

test "SoaPool: stale handle returns null" {
    var pool = try CheatLib.SoaPool(Entity).initCapacity(std.testing.allocator, 16);
    defer pool.deinit(std.testing.allocator);

    const id = try pool.insert(std.testing.allocator, .{
        .x = 1.0, .y = 2.0, .vx = 0.0, .vy = 0.0, .health = 50.0,
    });
    pool.remove(id);

    try std.testing.expect(pool.get(id) == null);
}

test "SoaPool: remove + reinsert reuses slot" {
    var pool = try CheatLib.SoaPool(Entity).initCapacity(std.testing.allocator, 16);
    defer pool.deinit(std.testing.allocator);

    const id1 = try pool.insert(std.testing.allocator, .{
        .x = 1.0, .y = 0.0, .vx = 0.0, .vy = 0.0, .health = 10.0,
    });
    pool.remove(id1);

    const id2 = try pool.insert(std.testing.allocator, .{
        .x = 99.0, .y = 0.0, .vx = 0.0, .vy = 0.0, .health = 200.0,
    });

    // Old handle is stale.
    try std.testing.expect(pool.get(id1) == null);

    // New handle works.
    const val = pool.get(id2).?;
    try std.testing.expectEqual(@as(f64, 99.0), val.x);
    try std.testing.expectEqual(@as(f64, 200.0), val.health);
}

test "SoaPool: count tracks live entries" {
    var pool = try CheatLib.SoaPool(Entity).initCapacity(std.testing.allocator, 16);
    defer pool.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 0), pool.count());

    const id1 = try pool.insert(std.testing.allocator, .{
        .x = 0, .y = 0, .vx = 0, .vy = 0, .health = 0,
    });
    const id2 = try pool.insert(std.testing.allocator, .{
        .x = 0, .y = 0, .vx = 0, .vy = 0, .health = 0,
    });

    try std.testing.expectEqual(@as(i64, 2), pool.count());

    pool.remove(id1);
    try std.testing.expectEqual(@as(i64, 1), pool.count());

    pool.remove(id2);
    try std.testing.expectEqual(@as(i64, 0), pool.count());
}

test "SoaPool: multiple inserts maintain SOA layout" {
    var pool = try CheatLib.SoaPool(Entity).initCapacity(std.testing.allocator, 16);
    defer pool.deinit(std.testing.allocator);

    var ids: [10]u64 = undefined;
    for (0..10) |i| {
        ids[i] = try pool.insert(std.testing.allocator, .{
            .x = @floatFromInt(i),
            .y = @as(f64, @floatFromInt(i)) * 2.0,
            .vx = 0.0,
            .vy = 0.0,
            .health = 100.0 - @as(f64, @floatFromInt(i)),
        });
    }

    for (0..10) |i| {
        const val = pool.get(ids[i]).?;
        try std.testing.expectEqual(@as(f64, @floatFromInt(i)), val.x);
        try std.testing.expectEqual(@as(f64, @floatFromInt(i)) * 2.0, val.y);
        try std.testing.expectEqual(100.0 - @as(f64, @floatFromInt(i)), val.health);
    }
}

test "SoaPool: iteration skips dead slots" {
    var pool = try CheatLib.SoaPool(Entity).initCapacity(std.testing.allocator, 16);
    defer pool.deinit(std.testing.allocator);

    const id0 = try pool.insert(std.testing.allocator, .{ .x = 10, .y = 0, .vx = 0, .vy = 0, .health = 0 });
    _ = try pool.insert(std.testing.allocator, .{ .x = 20, .y = 0, .vx = 0, .vy = 0, .health = 0 });
    _ = try pool.insert(std.testing.allocator, .{ .x = 30, .y = 0, .vx = 0, .vy = 0, .health = 0 });

    pool.remove(id0); // Remove first

    // Iterate live entries, sum x values.
    var sum: f64 = 0;
    for (0..pool.data.len) |i| {
        if (!pool.alive[i]) continue;
        const val = pool.data.get(i);
        sum += val.x;
    }

    try std.testing.expectEqual(@as(f64, 50.0), sum); // 20 + 30
}
