// pool-test.zig
// Unit tests for CheatLib.Pool(T) — Phase 1 generational pool.
//
// Tests exercise the Zig runtime directly, independent of the CLEAR compiler.
// Run with:
//   zig test zig/pool-test.zig -lc zig/switch.S zig/onRoot.S
const std = @import("std");
const CheatLib = @import("runtime-header.zig").CheatLib;

const Point = struct { x: f64, y: f64 };

// ---------------------------------------------------------------------------
// insert + get: basic round-trip
// ---------------------------------------------------------------------------

test "Pool.insert returns a valid handle and get retrieves the value" {
    var pool = try CheatLib.Pool(Point).initCapacity(std.testing.allocator, 16);
    defer pool.deinit(std.testing.allocator);

    const id = try pool.insert(std.testing.allocator, Point{ .x = 1.0, .y = 2.0 });
    const ptr = pool.get(id);

    try std.testing.expect(ptr != null);
    try std.testing.expectApproxEqAbs(1.0, ptr.?.x, 1e-9);
    try std.testing.expectApproxEqAbs(2.0, ptr.?.y, 1e-9);
}

test "Pool.get returns null for an out-of-range handle" {
    var pool = try CheatLib.Pool(Point).initCapacity(std.testing.allocator, 16);
    defer pool.deinit(std.testing.allocator);

    // Handle with index 99 — pool is empty, so index is out of range.
    const stale_id: u64 = 99;
    try std.testing.expect(pool.get(stale_id) == null);
}

// ---------------------------------------------------------------------------
// remove: invalidates the handle
// ---------------------------------------------------------------------------

test "Pool.remove makes get return null (stale handle)" {
    var pool = try CheatLib.Pool(Point).initCapacity(std.testing.allocator, 16);
    defer pool.deinit(std.testing.allocator);

    const id = try pool.insert(std.testing.allocator, Point{ .x = 3.0, .y = 4.0 });
    try std.testing.expect(pool.get(id) != null);

    pool.remove(id);
    try std.testing.expect(pool.get(id) == null);
}

test "Pool.remove is a no-op for a stale handle" {
    var pool = try CheatLib.Pool(Point).initCapacity(std.testing.allocator, 16);
    defer pool.deinit(std.testing.allocator);

    const id = try pool.insert(std.testing.allocator, Point{ .x = 0.0, .y = 0.0 });
    pool.remove(id);
    // Second remove should not panic or corrupt state
    pool.remove(id);
    try std.testing.expect(pool.get(id) == null);
}

// ---------------------------------------------------------------------------
// ABA protection: generation prevents stale-handle reuse
// ---------------------------------------------------------------------------

test "Pool.insert reuses a removed slot and generation changes (ABA safety)" {
    var pool = try CheatLib.Pool(Point).initCapacity(std.testing.allocator, 16);
    defer pool.deinit(std.testing.allocator);

    const id1 = try pool.insert(std.testing.allocator, Point{ .x = 10.0, .y = 0.0 });
    pool.remove(id1);

    // Insert again — should reuse slot 0 with generation 1
    const id2 = try pool.insert(std.testing.allocator, Point{ .x = 20.0, .y = 0.0 });

    // Old handle is stale (different generation)
    try std.testing.expect(pool.get(id1) == null);

    // New handle is valid
    const ptr = pool.get(id2);
    try std.testing.expect(ptr != null);
    try std.testing.expectApproxEqAbs(20.0, ptr.?.x, 1e-9);

    // Generation in id2 must differ from id1
    try std.testing.expect(id1 != id2);
}

// ---------------------------------------------------------------------------
// count: tracks live slots
// ---------------------------------------------------------------------------

test "Pool.count reflects live slot count after insert and remove" {
    var pool = try CheatLib.Pool(Point).initCapacity(std.testing.allocator, 16);
    defer pool.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 0), pool.count());

    const a = try pool.insert(std.testing.allocator, Point{ .x = 1.0, .y = 0.0 });
    try std.testing.expectEqual(@as(i64, 1), pool.count());

    const b = try pool.insert(std.testing.allocator, Point{ .x = 2.0, .y = 0.0 });
    _ = b;
    try std.testing.expectEqual(@as(i64, 2), pool.count());

    pool.remove(a);
    try std.testing.expectEqual(@as(i64, 1), pool.count());
}

// ---------------------------------------------------------------------------
// Multiple items: independent handles
// ---------------------------------------------------------------------------

test "Pool handles multiple items with independent handles" {
    var pool = try CheatLib.Pool(Point).initCapacity(std.testing.allocator, 16);
    defer pool.deinit(std.testing.allocator);

    const id_a = try pool.insert(std.testing.allocator, Point{ .x = 1.0, .y = 1.0 });
    const id_b = try pool.insert(std.testing.allocator, Point{ .x = 2.0, .y = 2.0 });
    const id_c = try pool.insert(std.testing.allocator, Point{ .x = 3.0, .y = 3.0 });

    // All handles valid and independent
    try std.testing.expectApproxEqAbs(1.0, pool.get(id_a).?.x, 1e-9);
    try std.testing.expectApproxEqAbs(2.0, pool.get(id_b).?.x, 1e-9);
    try std.testing.expectApproxEqAbs(3.0, pool.get(id_c).?.x, 1e-9);

    // Remove middle item — others unaffected
    pool.remove(id_b);
    try std.testing.expect(pool.get(id_a) != null);
    try std.testing.expect(pool.get(id_b) == null);
    try std.testing.expect(pool.get(id_c) != null);
}

// ---------------------------------------------------------------------------
// Mutation via get: pointer allows in-place update
// ---------------------------------------------------------------------------

test "Pool.get returns a mutable pointer — value can be updated in place" {
    var pool = try CheatLib.Pool(Point).initCapacity(std.testing.allocator, 16);
    defer pool.deinit(std.testing.allocator);

    const id = try pool.insert(std.testing.allocator, Point{ .x = 0.0, .y = 0.0 });
    pool.get(id).?.x = 99.0;

    try std.testing.expectApproxEqAbs(99.0, pool.get(id).?.x, 1e-9);
}

// ---------------------------------------------------------------------------
// RAII pattern: mirrors compiler-emitted code for `MUTABLE p: User[]@pool = []`
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Type confusion: a stale handle from a removed item cannot read data from
// the new item that reuses the same slot.  This is the "User → Projectile"
// scenario: delete a User, allocate a Projectile in the same slot, try to
// read the old User handle — generational check returns null.
// ---------------------------------------------------------------------------

test "Generational safety prevents type confusion after slot reuse" {
    const User = struct { name: u64 };
    var pool = try CheatLib.Pool(User).initCapacity(std.testing.allocator, 16);
    defer pool.deinit(std.testing.allocator);

    // Insert a "User" and save the handle.
    const user_id = try pool.insert(std.testing.allocator, User{ .name = 0xDEAD });
    try std.testing.expect(pool.get(user_id) != null);
    try std.testing.expectEqual(@as(u64, 0xDEAD), pool.get(user_id).?.name);

    // Delete the User — slot becomes free, generation increments.
    pool.remove(user_id);

    // Insert a "new item" (in a real app, a different type reusing the same pool slot).
    const new_id = try pool.insert(std.testing.allocator, User{ .name = 0xBEEF });

    // The old User handle is stale — generation mismatch returns null.
    try std.testing.expect(pool.get(user_id) == null);

    // The new handle works and reads the correct data.
    try std.testing.expect(pool.get(new_id) != null);
    try std.testing.expectEqual(@as(u64, 0xBEEF), pool.get(new_id).?.name);

    // Verify the handles differ (different generation despite same slot index).
    try std.testing.expect(user_id != new_id);
}

test "RAII pattern: Pool zero-init + deinit (mirrors compiler output)" {
    // This mirrors exactly what `MUTABLE p: User[]@pool = []` produces in Zig:
    //   var p = CheatLib.Pool(Point){};
    //   _ = &p;
    //   defer p.deinit(rt.heapAlloc());
    var p = try CheatLib.Pool(Point).initCapacity(std.testing.allocator, 16);
    _ = &p;
    defer p.deinit(std.testing.allocator);

    const id = try p.insert(std.testing.allocator, Point{ .x = 5.0, .y = 6.0 });
    try std.testing.expect(p.get(id) != null);
}

const CountedResource = struct {
    drops: *usize,

    pub fn deinit(self: *@This(), _: std.mem.Allocator) void {
        self.drops.* += 1;
    }
};

test "Pool.remove destroys a cleanup-bearing payload immediately and exactly once" {
    var drops: usize = 0;
    var pool = try CheatLib.Pool(CountedResource).initCapacity(std.testing.allocator, 2);
    const id = try pool.insert(std.testing.allocator, .{ .drops = &drops });
    pool.remove(id);
    try std.testing.expectEqual(@as(usize, 1), drops);
    pool.remove(id);
    try std.testing.expectEqual(@as(usize, 1), drops);
    pool.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), drops);
}

test "Pool.deinit finds high-index survivors after sparse removals" {
    var drops: usize = 0;
    var pool = try CheatLib.Pool(CountedResource).initCapacity(std.testing.allocator, 4);
    var ids: [4]u64 = undefined;
    for (&ids) |*id| id.* = try pool.insert(std.testing.allocator, .{ .drops = &drops });
    pool.remove(ids[0]);
    pool.remove(ids[1]);
    pool.remove(ids[2]);
    try std.testing.expectEqual(@as(usize, 3), drops);
    pool.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), drops);
}

test "Pool compact sidecars expose live direct slots without padded Slot structs" {
    var pool = try CheatLib.Pool(Point).initCapacity(std.testing.allocator, 3);
    defer pool.deinit(std.testing.allocator);
    const id = try pool.insert(std.testing.allocator, .{ .x = 7, .y = 8 });
    try std.testing.expect(pool.isAliveIndex(0));
    try std.testing.expect(!pool.isAliveIndex(1));
    try std.testing.expect(!pool.isAliveIndex(99));
    try std.testing.expectEqual(@as(f64, 7), pool.valueAtIndex(0).?.x);
    try std.testing.expect(pool.valueAtIndex(1) == null);
    try std.testing.expectEqual(@as(f64, 8), pool.valueAtIndexConst(0).?.y);
    pool.remove(id);
    try std.testing.expect(pool.valueAtIndexConst(0) == null);
}

test "Pool reports Full and permanently retires an exhausted generation" {
    var pool = try CheatLib.Pool(Point).initCapacity(std.testing.allocator, 1);
    defer pool.deinit(std.testing.allocator);
    pool.states[0] = std.math.maxInt(u32) - 1;
    const last = try pool.insert(std.testing.allocator, .{ .x = 1, .y = 2 });
    try std.testing.expectEqual(std.math.maxInt(u32), @as(u32, @truncate(last >> 32)));
    try std.testing.expectError(error.Full, pool.insert(std.testing.allocator, .{ .x = 3, .y = 4 }));
    pool.remove(last);
    try std.testing.expectError(error.Full, pool.insert(std.testing.allocator, .{ .x = 5, .y = 6 }));
}

test "Pool init frees every successful partial allocation after OOM" {
    var fail_index: usize = 0;
    while (fail_index < 3) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, CheatLib.Pool(Point).initCapacity(failing.allocator(), 4));
    }
}

test "Pool supports an empty capacity" {
    var pool = try CheatLib.Pool(Point).initCapacity(std.testing.allocator, 0);
    defer pool.deinit(std.testing.allocator);
    try std.testing.expectError(error.Full, pool.insert(std.testing.allocator, .{ .x = 0, .y = 0 }));
}
