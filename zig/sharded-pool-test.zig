// sharded-pool-test.zig
// Unit tests for CheatLib.ShardedPool(T, N) — Phase 2 sharded generational pool.
//
// Tests exercise the Zig runtime directly, independent of the CLEAR compiler.
// Run with:
//   zig test zig/sharded-pool-test.zig -lc zig/switch.S zig/onRoot.S
const std = @import("std");
const CheatLib = @import("runtime-header.zig").CheatLib;

const Score = struct { value: f64 };

// ---------------------------------------------------------------------------
// Basic round-trip: insert + get
// ---------------------------------------------------------------------------

test "ShardedPool.insert returns a valid handle and get retrieves the value" {
    var sp = CheatLib.ShardedPool(Score, 4){};
    defer sp.deinit(std.testing.allocator);

    const id = try sp.insert(std.testing.allocator, Score{ .value = 42.0 });
    const ptr = sp.get(id);

    try std.testing.expect(ptr != null);
    try std.testing.expectApproxEqAbs(42.0, ptr.?.value, 1e-9);
}

test "ShardedPool.get returns null for an out-of-range handle" {
    var sp = CheatLib.ShardedPool(Score, 4){};
    defer sp.deinit(std.testing.allocator);

    // Handle encodes shard_idx=0, slot_index=999 — pool is empty.
    const stale_id: u64 = 999;
    try std.testing.expect(sp.get(stale_id) == null);
}

// ---------------------------------------------------------------------------
// remove: invalidates the handle
// ---------------------------------------------------------------------------

test "ShardedPool.remove makes get return null (stale handle)" {
    var sp = CheatLib.ShardedPool(Score, 4){};
    defer sp.deinit(std.testing.allocator);

    const id = try sp.insert(std.testing.allocator, Score{ .value = 10.0 });
    try std.testing.expect(sp.get(id) != null);

    sp.remove(id);
    try std.testing.expect(sp.get(id) == null);
}

// ---------------------------------------------------------------------------
// count: tracks live items across all shards
// ---------------------------------------------------------------------------

test "ShardedPool.count reflects insertions and removals" {
    var sp = CheatLib.ShardedPool(Score, 4){};
    defer sp.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), sp.count());

    const id_a = try sp.insert(std.testing.allocator, Score{ .value = 1.0 });
    const id_b = try sp.insert(std.testing.allocator, Score{ .value = 2.0 });
    const id_c = try sp.insert(std.testing.allocator, Score{ .value = 3.0 });

    try std.testing.expectEqual(@as(usize, 3), sp.count());

    sp.remove(id_b);
    try std.testing.expectEqual(@as(usize, 2), sp.count());

    sp.remove(id_a);
    sp.remove(id_c);
    try std.testing.expectEqual(@as(usize, 0), sp.count());
}

// ---------------------------------------------------------------------------
// round-robin distribution: inserts spread across shards
// ---------------------------------------------------------------------------

test "ShardedPool round-robin distributes items across N shards" {
    var sp = CheatLib.ShardedPool(Score, 4){};
    defer sp.deinit(std.testing.allocator);

    // Insert 8 items — should go 2 per shard with round-robin.
    var ids: [8]u64 = undefined;
    for (&ids, 0..) |*id, i| {
        id.* = try sp.insert(std.testing.allocator, Score{ .value = @floatFromInt(i) });
    }

    try std.testing.expectEqual(@as(usize, 8), sp.count());

    // Each item must be retrievable by its handle.
    for (ids, 0..) |id, i| {
        const ptr = sp.get(id);
        try std.testing.expect(ptr != null);
        try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(i)), ptr.?.value, 1e-9);
    }
}

// ---------------------------------------------------------------------------
// stale handle safety: removed item's handle returns null
// ---------------------------------------------------------------------------

test "ShardedPool removed handle does not alias a later insert" {
    var sp = CheatLib.ShardedPool(Score, 4){};
    defer sp.deinit(std.testing.allocator);

    const id_first = try sp.insert(std.testing.allocator, Score{ .value = 100.0 });
    sp.remove(id_first);

    // Insert another item — may reuse the slot, but with a new generation.
    _ = try sp.insert(std.testing.allocator, Score{ .value = 200.0 });

    // The old handle must NOT return the new value (ABA safety).
    try std.testing.expect(sp.get(id_first) == null);
}

// ---------------------------------------------------------------------------
// multi-shard get: handles encode shard index correctly
// ---------------------------------------------------------------------------

test "ShardedPool handles for different shards are independent" {
    var sp = CheatLib.ShardedPool(Score, 4){};
    defer sp.deinit(std.testing.allocator);

    // Insert 4 items — one per shard (round-robin with N=4).
    const id0 = try sp.insert(std.testing.allocator, Score{ .value = 10.0 });
    const id1 = try sp.insert(std.testing.allocator, Score{ .value = 20.0 });
    const id2 = try sp.insert(std.testing.allocator, Score{ .value = 30.0 });
    const id3 = try sp.insert(std.testing.allocator, Score{ .value = 40.0 });

    // All 4 handles must be valid and return the correct values.
    try std.testing.expectApproxEqAbs(10.0, sp.get(id0).?.value, 1e-9);
    try std.testing.expectApproxEqAbs(20.0, sp.get(id1).?.value, 1e-9);
    try std.testing.expectApproxEqAbs(30.0, sp.get(id2).?.value, 1e-9);
    try std.testing.expectApproxEqAbs(40.0, sp.get(id3).?.value, 1e-9);

    // Removing one shard's item does not affect the others.
    sp.remove(id1);
    try std.testing.expect(sp.get(id1) == null);
    try std.testing.expect(sp.get(id0) != null);
    try std.testing.expect(sp.get(id2) != null);
    try std.testing.expect(sp.get(id3) != null);
}

// ---------------------------------------------------------------------------
// large N: ShardedPool with N=8
// ---------------------------------------------------------------------------

test "ShardedPool(T, 8) works with 8 shards" {
    var sp = CheatLib.ShardedPool(Score, 8){};
    defer sp.deinit(std.testing.allocator);

    var ids: [16]u64 = undefined;
    for (&ids, 0..) |*id, i| {
        id.* = try sp.insert(std.testing.allocator, Score{ .value = @floatFromInt(i * 10) });
    }

    try std.testing.expectEqual(@as(usize, 16), sp.count());

    // Verify all retrievable.
    for (ids, 0..) |id, i| {
        const ptr = sp.get(id);
        try std.testing.expect(ptr != null);
        try std.testing.expectApproxEqAbs(@as(f64, @floatFromInt(i * 10)), ptr.?.value, 1e-9);
    }
}
