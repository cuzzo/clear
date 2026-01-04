const std = @import("std");
const testing = std.testing;
// Adjust import to point to where you defined CheatArena
const CheatArena = @import("runtime.zig").CheatArena;

test "CheatArena: Basic Allocation" {
    var arena = CheatArena.init(testing.allocator);
    defer arena.deinit();

    // 1. Allocate a small integer
    const ptr = arena.alloc(8, 8, 0);
    try testing.expect(ptr != null);

    // 2. Write to it to ensure memory is valid
    const int_ptr: *u64 = @ptrCast(@alignCast(ptr));
    int_ptr.* = 0xDEADBEEF;
    try testing.expectEqual(@as(u64, 0xDEADBEEF), int_ptr.*);

    // 3. Verify Internal State (First alloc creates Block 0)
    try testing.expectEqual(@as(usize, 1), arena.blocks.items.len);
    try testing.expectEqual(@as(usize, 8), arena.cursor);
}

test "CheatArena: Growth Strategy (4KB -> 16KB -> 64KB)" {
    var arena = CheatArena.init(testing.allocator);
    defer arena.deinit();

    // 1. Fill Page 0 (4KB)
    // Alloc 4096 bytes. Should fit exactly in first block.
    _ = arena.alloc(4096, 1, 0);
    try testing.expectEqual(@as(usize, 1), arena.blocks.items.len);
    try testing.expectEqual(@as(usize, 4096), arena.blocks.items[0].len);

    // 2. Force Page 1 (16KB)
    // Alloc 1 more byte. Should trigger new block.
    _ = arena.alloc(1, 1, 0);
    try testing.expectEqual(@as(usize, 2), arena.blocks.items.len);
    try testing.expectEqual(@as(usize, 16 * 1024), arena.blocks.items[1].len);

    // 3. Force Page 2 (64KB)
    // Alloc remaining 16KB (minus 1) to fill Page 1, then alloc again.
    // Easier way: just alloc 17KB. It won't fit in the current Page 1 remainder,
    // so it forces a skip or new block.
    // Since our logic blindly moves to next cached block or creates new,
    // let's just force a huge alloc that fits in Page 2 (64KB) but not Page 1.
    _ = arena.alloc(20 * 1024, 1, 0);
    try testing.expectEqual(@as(usize, 3), arena.blocks.items.len);
    try testing.expectEqual(@as(usize, 64 * 1024), arena.blocks.items[2].len);
}

test "CheatArena: Large Object Overflow" {
    var arena = CheatArena.init(testing.allocator);
    defer arena.deinit();

    // 1. Alloc something massive (300KB).
    // The growth curve is 4 -> 16 -> 64 -> 256.
    // 300KB is > 256KB (the max page size).
    // It should go directly to large_objects.
    const ptr = arena.alloc(300 * 1024, 16, 0);
    try testing.expect(ptr != null);

    // Verify it bypassed the blocks
    // Note: Blocks might have 0 items if we went straight to large object
    // depending on if we alloc'd small stuff before. Here we didn't.
    // However, our code checks `blocks.items.len` to calculate next page size.
    // If blocks is 0, next is 4KB. 300KB > 4KB, so it overflows. Correct.
    try testing.expectEqual(@as(usize, 0), arena.blocks.items.len);
    try testing.expectEqual(@as(usize, 1), arena.large_objects.items.len);

    // 2. Verify Size of the allocation
    const lo_slice = arena.large_objects.items[0];
    try testing.expect(lo_slice.len >= 300 * 1024);
}

test "CheatArena: Rewind Logic (Standard & Large Objects)" {
    var arena = CheatArena.init(testing.allocator);
    defer arena.deinit();

    // 1. Setup State: 2 Blocks + 1 Large Object
    _ = arena.alloc(100, 1, 0); // Block 0

    // Mark point!
    const mark = arena.getMark();

    _ = arena.alloc(5000, 1, 0); // Force Block 1 (4KB filled by previous logic? No, just force growth)
    // Actually, to force block 1 we need to fill block 0.
    _ = arena.alloc(4000, 1, 0); // Fill Block 0
    _ = arena.alloc(100, 1, 0);  // Trigger Block 1

    _ = arena.alloc(1024 * 1024, 16, 0); // Large Object (1MB)

    try testing.expectEqual(@as(usize, 2), arena.blocks.items.len);
    try testing.expectEqual(@as(usize, 1), arena.large_objects.items.len);

    // 2. Rewind
    arena.rewind(mark);

    // 3. Verify Reset
    // Block count should NOT decrease (we cache blocks), but cursor should reset.
    // AND Large Objects should be freed (count 0).
    try testing.expectEqual(@as(usize, 1), arena.blocks.items.len); // Trimmed back to 1
    try testing.expectEqual(@as(usize, 0), arena.large_objects.items.len); // Freed
    try testing.expectEqual(mark.cursor, arena.cursor);
    try testing.expectEqual(mark.block_index, arena.current_block_index);
}

test "CheatArena: Hybrid Trim (Rewind Far Back)" {
    var arena = CheatArena.init(testing.allocator);
    defer arena.deinit();

    // 1. Create 5 Blocks of growth
    // 4KB, 16KB, 64KB, 256KB, 256KB
    // We do this by filling them sequentially.
    const sizes = [_]usize{ 4096, 16384, 65536, 262144, 262144 };

    for (sizes) |s| {
        // Alloc s - 10 to fit comfortably? No, we need to fill the PREVIOUS one.
        // Actually, just allocating 's' usually triggers the check against NEXT capacity.
        // Let's just blindly alloc the exact size of the *current* page to fill it.
        _ = arena.alloc(s, 1, 0);
    }

    // We likely have 5 or 6 blocks now depending on exact fit.
    const high_water_mark_count = arena.blocks.items.len;
    try testing.expect(high_water_mark_count >= 5);

    // 2. Rewind all the way to start
    const start_mark = CheatArena.Mark{ .block_index = 0, .cursor = 0, .large_obj_count = 0 };
    arena.rewind(start_mark);

    // 3. Verify Trimming
    // The logic says: "Keep current block (0), free blocks AFTER it".
    // However, the code provided has: `keep_count = self.current_block_index + 1`.
    // So if we go to index 0, keep_count is 1. We keep Block 0.
    // We free Block 1, 2, 3, 4...
    try testing.expectEqual(@as(usize, 1), arena.blocks.items.len);

    // This proves we don't hold 1MB of memory if we aren't using it.
}

test "CheatArena: Integration with ArrayList (Dynamic Growth)" {
    var arena = CheatArena.init(testing.allocator);
    defer arena.deinit();

    // Define the Wrapper to match Zig 0.15 Allocator.VTable
    const Wrapper = struct {
        // Changed: alignment is now std.mem.Alignment, not u8
        fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, r: usize) ?[*]u8 {
            const self: *CheatArena = @ptrCast(@alignCast(ctx));
            // Convert Alignment enum back to u8 (byte units) for CheatArena.alloc
            const align_u8 = @as(u8, @intCast(alignment.toByteUnits()));
            return self.alloc(n, align_u8, r);
        }

        // Changed: alignment is std.mem.Alignment
        fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, r: usize) bool {
            _ = ctx; _ = buf; _ = alignment; _ = new_len; _ = r;
            // Frame allocator cannot resize in place usually
            return false;
        }

        // Changed: alignment is std.mem.Alignment
        fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {
            // No-op for frame allocator
        }

        fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
             return null;
        }
    };

    const allocator = std.mem.Allocator{
        .ptr = &arena,
        .vtable = &.{
            .alloc = Wrapper.alloc,
            .resize = Wrapper.resize,
            .free = Wrapper.free,
            .remap = Wrapper.remap,
        },
    };

    // 1. Start List
    var list = std.ArrayListUnmanaged(u64){};

    // 2. Add items until we grow significantly
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try list.append(allocator, @intCast(i));
    }

    try testing.expectEqual(@as(usize, 1000), list.items.len);
    try testing.expectEqual(@as(u64, 999), list.items[999]);

    // 3. Force Overflow
    while (i < 100000) : (i += 1) {
        try list.append(allocator, @intCast(i));
    }

    try testing.expect(arena.large_objects.items.len > 0);

    // 4. Rewind
    const mark = CheatArena.Mark{ .block_index = 0, .cursor = 0, .large_obj_count = 0 };
    arena.rewind(mark);

    // Verify large object backing the list was freed
    try testing.expectEqual(@as(usize, 0), arena.large_objects.items.len);
}

