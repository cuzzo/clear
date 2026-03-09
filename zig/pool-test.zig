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
    var pool = CheatLib.Pool(Point){};
    defer pool.deinit(std.testing.allocator);

    const id = try pool.insert(std.testing.allocator, Point{ .x = 1.0, .y = 2.0 });
    const ptr = pool.get(id);

    try std.testing.expect(ptr != null);
    try std.testing.expectApproxEqAbs(1.0, ptr.?.x, 1e-9);
    try std.testing.expectApproxEqAbs(2.0, ptr.?.y, 1e-9);
}

test "Pool.get returns null for an out-of-range handle" {
    var pool = CheatLib.Pool(Point){};
    defer pool.deinit(std.testing.allocator);

    // Handle with index 99 — pool is empty, so index is out of range.
    const stale_id: u64 = 99;
    try std.testing.expect(pool.get(stale_id) == null);
}

// ---------------------------------------------------------------------------
// remove: invalidates the handle
// ---------------------------------------------------------------------------

test "Pool.remove makes get return null (stale handle)" {
    var pool = CheatLib.Pool(Point){};
    defer pool.deinit(std.testing.allocator);

    const id = try pool.insert(std.testing.allocator, Point{ .x = 3.0, .y = 4.0 });
    try std.testing.expect(pool.get(id) != null);

    pool.remove(id);
    try std.testing.expect(pool.get(id) == null);
}

test "Pool.remove is a no-op for a stale handle" {
    var pool = CheatLib.Pool(Point){};
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
    var pool = CheatLib.Pool(Point){};
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
    var pool = CheatLib.Pool(Point){};
    defer pool.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), pool.count());

    const a = try pool.insert(std.testing.allocator, Point{ .x = 1.0, .y = 0.0 });
    try std.testing.expectEqual(@as(usize, 1), pool.count());

    const b = try pool.insert(std.testing.allocator, Point{ .x = 2.0, .y = 0.0 });
    _ = b;
    try std.testing.expectEqual(@as(usize, 2), pool.count());

    pool.remove(a);
    try std.testing.expectEqual(@as(usize, 1), pool.count());
}

// ---------------------------------------------------------------------------
// Multiple items: independent handles
// ---------------------------------------------------------------------------

test "Pool handles multiple items with independent handles" {
    var pool = CheatLib.Pool(Point){};
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
    var pool = CheatLib.Pool(Point){};
    defer pool.deinit(std.testing.allocator);

    const id = try pool.insert(std.testing.allocator, Point{ .x = 0.0, .y = 0.0 });
    pool.get(id).?.x = 99.0;

    try std.testing.expectApproxEqAbs(99.0, pool.get(id).?.x, 1e-9);
}

// ---------------------------------------------------------------------------
// RAII pattern: mirrors compiler-emitted code for `MUTABLE p: User[]@pool = []`
// ---------------------------------------------------------------------------

test "RAII pattern: Pool zero-init + deinit (mirrors compiler output)" {
    // This mirrors exactly what `MUTABLE p: User[]@pool = []` produces in Zig:
    //   var p = CheatLib.Pool(Point){};
    //   _ = &p;
    //   defer p.deinit(rt.heapAlloc());
    var p = CheatLib.Pool(Point){};
    _ = &p;
    defer p.deinit(std.testing.allocator);

    const id = try p.insert(std.testing.allocator, Point{ .x = 5.0, .y = 6.0 });
    try std.testing.expect(p.get(id) != null);
}
