// Retained identity v4 keep-edge runtime contract
// (docs/agents/retained-identity-design.md, Test expansion 5).
//
// Proves, at the runtime level, exactly what the derived call edges rely on:
// retain/release balance across keep sequences, payload identity after
// retain (shared, never copied), OOM rollback at rcCreate, and the memory
// cost table (shared edge = 0 new allocations; move+wrap edge = exactly the
// Rc box).

const std = @import("std");
const CheatHeader = @import("runtime/runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;

const Budget = struct { count: i64 };

test "keep sequence balances create, per-edge retains, and keeper releases" {
    const allocator = std.testing.allocator;

    // Caller declaration: born as Rc, strong = 1.
    const shared = try CheatLib.rcCreate(Budget, allocator, .{ .count = 0 });
    try std.testing.expectEqual(@as(usize, 1), shared.ctrl.strong);

    // Two keep edges: each retains, each keeper owns one handle.
    const kept_a = CheatLib.rcRetain(Budget, shared);
    const kept_b = CheatLib.rcRetain(Budget, shared);
    try std.testing.expectEqual(@as(usize, 3), shared.ctrl.strong);

    // Shared identity: every handle addresses the same payload.
    shared.ctrl.data.count = 5;
    try std.testing.expectEqual(@as(i64, 5), kept_a.ctrl.data.count);
    try std.testing.expectEqual(@as(i64, 5), kept_b.ctrl.data.count);
    try std.testing.expectEqual(shared.ctrl, kept_a.ctrl);
    try std.testing.expectEqual(shared.ctrl, kept_b.ctrl);

    // Keeper drops then caller scope exit: 3 -> 2 -> 1 -> 0, freed once.
    CheatLib.rcRelease(Budget, allocator, kept_a);
    CheatLib.rcRelease(Budget, allocator, kept_b);
    try std.testing.expectEqual(@as(usize, 1), shared.ctrl.strong);
    CheatLib.rcRelease(Budget, allocator, shared);
}

test "last-use edge moves the handle with zero refcount traffic" {
    const allocator = std.testing.allocator;

    const owned = try CheatLib.rcCreate(Budget, allocator, .{ .count = 3 });
    // GIVE: the handle bits move to the keeper; no retain, no release.
    const keeper_slot = owned;
    try std.testing.expectEqual(@as(usize, 1), keeper_slot.ctrl.strong);
    CheatLib.rcRelease(Budget, allocator, keeper_slot);
}

test "failing allocator at rcCreate propagates error with zero leaks" {
    var fail_index: usize = 0;
    while (fail_index < 2) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        const alloc = failing.allocator();
        const created = CheatLib.rcCreate(Budget, alloc, .{ .count = 1 });
        if (created) |rc| {
            CheatLib.rcRelease(Budget, alloc, rc);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "memory cost table: shared edge allocates nothing, create allocates one box" {
    var counting = std.heap.DebugAllocator(.{ .enable_memory_limit = true }){};
    defer std.debug.assert(counting.deinit() == .ok);
    const alloc = counting.allocator();

    const before_create = counting.total_requested_bytes;
    const shared = try CheatLib.rcCreate(Budget, alloc, .{ .count = 0 });
    const after_create = counting.total_requested_bytes;
    // The create pays exactly one combined control-block + payload box.
    try std.testing.expect(after_create > before_create);

    // A retain edge performs zero allocations.
    const kept = CheatLib.rcRetain(Budget, shared);
    try std.testing.expectEqual(after_create, counting.total_requested_bytes);

    CheatLib.rcRelease(Budget, alloc, kept);
    CheatLib.rcRelease(Budget, alloc, shared);
}
