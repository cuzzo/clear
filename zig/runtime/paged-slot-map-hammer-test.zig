// Randomized model test for the affine PagedSlotMap. This deliberately mixes
// steady churn with graph-like burst growth/collapse across reclamation
// boundaries. Loom/VOPR are not useful here: the type has no atomics or
// scheduler-visible operations and is intentionally confined to one owner.
const std = @import("std");
const CheatLib = @import("runtime-header.zig").CheatLib;

fn noDrop(_: std.mem.Allocator, _: *u64) void {}
const Map = CheatLib.PagedSlotMapWithDrop(u64, noDrop);
const capacity: usize = Map.region_capacity * 2;

const DiscardCounter = struct {
    calls: usize = 0,

    fn discard(raw: ?*anyopaque, _: [*]align(std.heap.page_size_min) u8, _: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        return true;
    }
};

fn validate(
    map: *const Map,
    live: *const [capacity]bool,
    handles: *const [capacity]Map.Handle,
    values: *const [capacity]u64,
    expected_count: usize,
) !void {
    try std.testing.expect(map.debugValidate());
    try std.testing.expectEqual(expected_count, map.length());

    var model_sum: u64 = 0;
    var slot: usize = 0;
    while (slot < capacity) : (slot += 1) {
        if (!live[slot]) continue;
        const value = map.getConst(handles[slot]) orelse return error.MissingLiveHandle;
        try std.testing.expectEqual(values[slot], value.*);
        model_sum +%= values[slot];
    }

    var dense_sum: u64 = 0;
    for (map.denseItemsConst(), 0..) |value, dense_index| {
        const handle = map.idAtDense(dense_index) orelse return error.MissingDenseHandle;
        const logical_slot = Map.handleSlot(handle);
        try std.testing.expect(live[logical_slot]);
        try std.testing.expectEqual(handles[logical_slot], handle);
        try std.testing.expectEqual(values[logical_slot], value);
        dense_sum +%= value;
    }
    try std.testing.expectEqual(model_sum, dense_sum);
}

test "PagedSlotMap randomized model hammer" {
    var discards = DiscardCounter{};
    var map = try Map.initWithAllocators(
        std.testing.allocator,
        std.heap.page_allocator,
        capacity,
        &discards,
        DiscardCounter.discard,
    );
    defer map.deinit();

    var live = [_]bool{false} ** capacity;
    var handles: [capacity]Map.Handle = undefined;
    var stale: [capacity]?Map.Handle = [_]?Map.Handle{null} ** capacity;
    var values: [capacity]u64 = undefined;
    var expected_count: usize = 0;
    var prng = std.Random.DefaultPrng.init(0x4752_4150_485f_4d50);
    const random = prng.random();

    var step: usize = 0;
    while (step < 25_000) : (step += 1) {
        const action = random.intRangeAtMost(u8, 0, 99);
        if (action < 38 and expected_count < capacity) {
            const value = random.int(u64);
            const handle = try map.insert(value);
            const slot = Map.handleSlot(handle);
            try std.testing.expect(!live[slot]);
            live[slot] = true;
            handles[slot] = handle;
            values[slot] = value;
            expected_count += 1;
            if (stale[slot]) |old| try std.testing.expect(map.get(old) == null);
        } else if (action < 68 and expected_count != 0) {
            var slot = random.intRangeLessThan(usize, 0, capacity);
            while (!live[slot]) slot = (slot + 1) % capacity;
            const removed = handles[slot];
            try std.testing.expect(map.remove(removed));
            try std.testing.expect(!map.remove(removed));
            try std.testing.expect(map.get(removed) == null);
            stale[slot] = removed;
            live[slot] = false;
            expected_count -= 1;
        } else if (action < 87 and expected_count != 0) {
            var slot = random.intRangeLessThan(usize, 0, capacity);
            while (!live[slot]) slot = (slot + 1) % capacity;
            const value = random.int(u64);
            map.get(handles[slot]).?.* = value;
            values[slot] = value;
        } else if (action < 91) {
            map.clear();
            for (&live, 0..) |*is_live, slot| {
                if (is_live.*) stale[slot] = handles[slot];
                is_live.* = false;
            }
            expected_count = 0;
        } else if (action == 99) {
            // Worst-case graph phase: allocate to peak, then retain only 32
            // vertices. This repeatedly exercises both dense swap repair and
            // physical tail-region reclamation.
            while (expected_count < capacity) {
                const handle = try map.insert(step + expected_count);
                const slot = Map.handleSlot(handle);
                live[slot] = true;
                handles[slot] = handle;
                values[slot] = step + expected_count;
                expected_count += 1;
            }
            var slot: usize = 0;
            while (expected_count > 32) : (slot = (slot + 1) % capacity) {
                if (!live[slot]) continue;
                const removed = handles[slot];
                try std.testing.expect(map.remove(removed));
                stale[slot] = removed;
                live[slot] = false;
                expected_count -= 1;
            }
        } else {
            // Invalid/out-of-range and stale reads must remain harmless under
            // arbitrary churn.
            const invalid = Map.makeHandle(Map.max_capacity - 1, random.intRangeAtMost(u32, 0, Map.generation_mask));
            try std.testing.expect(map.get(invalid) == null);
            try std.testing.expect(!map.remove(invalid));
        }

        if (step % 127 == 0) try validate(&map, &live, &handles, &values, expected_count);
    }

    try validate(&map, &live, &handles, &values, expected_count);
    try std.testing.expect(discards.calls != 0);
}
