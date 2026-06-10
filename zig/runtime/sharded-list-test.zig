// sharded-list-test.zig
// Unit tests for CheatLib.ShardedList(T, N) — Phase 2 sharded list.
//
// Tests exercise the Zig runtime directly, independent of the CLEAR compiler.
// Run with:
//   zig test zig/sharded-list-test.zig -lc zig/switch.S zig/onRoot.S
const std = @import("std");
const CheatLib = @import("runtime-header.zig").CheatLib;

// ---------------------------------------------------------------------------
// Basic round-trip: append + len
// ---------------------------------------------------------------------------

test "ShardedList.append increases len" {
    var sl = CheatLib.ShardedList(f64, 2){};
    defer sl.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), sl.len());

    try sl.append(std.testing.allocator, 1.0);
    try sl.append(std.testing.allocator, 2.0);
    try sl.append(std.testing.allocator, 3.0);

    try std.testing.expectEqual(@as(usize, 3), sl.len());
}

test "ShardedList items are accessible via shards" {
    var sl = CheatLib.ShardedList(f64, 2){};
    defer sl.deinit(std.testing.allocator);

    try sl.append(std.testing.allocator, 10.0);
    try sl.append(std.testing.allocator, 20.0);
    try sl.append(std.testing.allocator, 30.0);
    try sl.append(std.testing.allocator, 40.0);

    // With N=2 and 4 appends, round-robin distributes 2 items per shard.
    try std.testing.expectEqual(@as(usize, 2), sl.shards[0].items.len);
    try std.testing.expectEqual(@as(usize, 2), sl.shards[1].items.len);

    // Items alternate: shard[0]={10,30}, shard[1]={20,40}
    try std.testing.expectApproxEqAbs(10.0, sl.shards[0].items[0], 1e-9);
    try std.testing.expectApproxEqAbs(30.0, sl.shards[0].items[1], 1e-9);
    try std.testing.expectApproxEqAbs(20.0, sl.shards[1].items[0], 1e-9);
    try std.testing.expectApproxEqAbs(40.0, sl.shards[1].items[1], 1e-9);
}

// ---------------------------------------------------------------------------
// round-robin distribution
// ---------------------------------------------------------------------------

test "ShardedList round-robin distributes evenly with N=4" {
    var sl = CheatLib.ShardedList(i32, 4){};
    defer sl.deinit(std.testing.allocator);

    // Insert 8 items — 2 per shard.
    for (0..8) |i| {
        try sl.append(std.testing.allocator, @intCast(i));
    }

    try std.testing.expectEqual(@as(usize, 8), sl.len());
    for (0..4) |s| {
        try std.testing.expectEqual(@as(usize, 2), sl.shards[s].items.len);
    }
}

test "ShardedList odd count distributes as evenly as possible" {
    var sl = CheatLib.ShardedList(i32, 3){};
    defer sl.deinit(std.testing.allocator);

    // 5 items into 3 shards: shards[0]=2, shards[1]=2, shards[2]=1
    for (0..5) |i| {
        try sl.append(std.testing.allocator, @intCast(i));
    }

    try std.testing.expectEqual(@as(usize, 5), sl.len());
    try std.testing.expectEqual(@as(usize, 2), sl.shards[0].items.len);
    try std.testing.expectEqual(@as(usize, 2), sl.shards[1].items.len);
    try std.testing.expectEqual(@as(usize, 1), sl.shards[2].items.len);
}

// ---------------------------------------------------------------------------
// mutation via shard pointer (EACH use-case)
// ---------------------------------------------------------------------------

test "ShardedList shard items can be mutated via pointer" {
    var sl = CheatLib.ShardedList(f64, 2){};
    defer sl.deinit(std.testing.allocator);

    try sl.append(std.testing.allocator, 5.0);
    try sl.append(std.testing.allocator, 6.0);

    // Simulate what EACH does: mutate via pointer to each shard.
    for (&sl.shards) |*shard| {
        for (shard.items) |*item| {
            item.* = 0.0;
        }
    }

    // All items should now be 0.
    var total: f64 = 0;
    for (&sl.shards) |*shard| {
        for (shard.items) |v| total += v;
    }
    try std.testing.expectApproxEqAbs(0.0, total, 1e-9);
}

// ---------------------------------------------------------------------------
// deinit: no double-free (empty list)
// ---------------------------------------------------------------------------

test "ShardedList.deinit on an empty list is safe" {
    var sl = CheatLib.ShardedList(f64, 2){};
    // No appends — deinit must not crash on zero-allocation shards.
    sl.deinit(std.testing.allocator);
}

test "ShardedList.empty initializes empty shards" {
    var sl = CheatLib.ShardedList(f64, 2).empty;
    defer sl.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), sl.len());
    try std.testing.expectEqual(@as(usize, 0), sl.shards[0].items.len);
    try std.testing.expectEqual(@as(usize, 0), sl.shards[1].items.len);

    try sl.append(std.testing.allocator, 4.0);
    try std.testing.expectEqual(@as(usize, 1), sl.len());
    try std.testing.expectApproxEqAbs(4.0, sl.shards[0].items[0], 1e-9);
}

// ---------------------------------------------------------------------------
// large N: ShardedList with N=8
// ---------------------------------------------------------------------------

test "ShardedList(T, 8) works with 8 shards" {
    var sl = CheatLib.ShardedList(f64, 8){};
    defer sl.deinit(std.testing.allocator);

    for (0..16) |i| {
        try sl.append(std.testing.allocator, @floatFromInt(i));
    }

    try std.testing.expectEqual(@as(usize, 16), sl.len());
    for (0..8) |s| {
        try std.testing.expectEqual(@as(usize, 2), sl.shards[s].items.len);
    }
}

// ---------------------------------------------------------------------------
// struct element type
// ---------------------------------------------------------------------------

const Item = struct { value: f64 };

test "ShardedList works with struct elements" {
    var sl = CheatLib.ShardedList(Item, 2){};
    defer sl.deinit(std.testing.allocator);

    try sl.append(std.testing.allocator, Item{ .value = 1.0 });
    try sl.append(std.testing.allocator, Item{ .value = 2.0 });
    try sl.append(std.testing.allocator, Item{ .value = 3.0 });

    try std.testing.expectEqual(@as(usize, 3), sl.len());

    // Verify values across shards.
    var sum: f64 = 0;
    for (&sl.shards) |*shard| {
        for (shard.items) |it| sum += it.value;
    }
    try std.testing.expectApproxEqAbs(6.0, sum, 1e-9);
}
