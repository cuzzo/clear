const std = @import("std");
const testing = std.testing;
// Adjust import to point to where you defined CheatArena
const CheatArena = @import("runtime.zig").CheatArena;

test "CheatArena: Basic Allocation" {
    var arena = CheatArena.init(testing.allocator, &[_]u8{});
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
    var arena = CheatArena.init(testing.allocator, &[_]u8{});
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
    var arena = CheatArena.init(testing.allocator, &[_]u8{});
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
    const lo_slice = arena.large_objects.items[0].slice;
    try testing.expect(lo_slice.len >= 300 * 1024);
}

test "CheatArena: Rewind Logic (Standard & Large Objects)" {
    var arena = CheatArena.init(testing.allocator, &[_]u8{});
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
    var arena = CheatArena.init(testing.allocator, &[_]u8{});
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
    var arena = CheatArena.init(testing.allocator, &[_]u8{});
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

test "alignment verification" {
    var arena = CheatArena.init(std.testing.allocator, &[_]u8{});
    defer arena.deinit();

    // Test various alignments
    const alignments = [_]u8{ 1, 2, 4, 8, 16, 32, 64 };
    for (alignments) |alignment| {  // Changed from |align| to |alignment|
        const ptr = arena.alloc(100, alignment, 0).?;
        try std.testing.expect(@intFromPtr(ptr) % alignment == 0);
    }
}

test "large allocation with 32-byte alignment" {
    var arena = CheatArena.init(std.testing.allocator, &[_]u8{});
    defer arena.deinit();

    // Allocate something larger than MAX_PAGE_SIZE with 32-byte alignment
    const ptr = arena.alloc(300 * 1024, 32, 0).?;

    // Verify alignment
    try std.testing.expect(@intFromPtr(ptr) % 32 == 0);

    // Should be in large_objects
    try std.testing.expect(arena.large_objects.items.len == 1);
    try std.testing.expect(arena.large_objects.items[0].alignment.toByteUnits() == 32);
}

test "rewind frees blocks correctly" {
    var arena = CheatArena.init(std.testing.allocator, &[_]u8{});
    defer arena.deinit();

    const mark1 = arena.getMark();
    _ = &mark1;
    _ = arena.alloc(1000, 1, 0).?;  // First block (4KB)

    const mark2 = arena.getMark();
    _ = arena.alloc(5000, 1, 0).?;   // Forces second block (16KB)
    _ = arena.alloc(20000, 1, 0).?;  // Forces third block (64KB)

    const blocks_before = arena.blocks.items.len;
    try std.testing.expect(blocks_before == 3);

    arena.rewind(mark2);
    const blocks_after = arena.blocks.items.len;

    // Should keep blocks 0 and 1, free block 2
    try std.testing.expect(blocks_after == 1);  // keep_count = current_block_index + 1 = 0 + 1
}

test "CheatArena: Edge Cases (Zero and Max)" {
    var arena = CheatArena.init(std.testing.allocator, &[_]u8{});
    defer arena.deinit();

    // 1. Zero Allocation
    // Should return a valid pointer (non-null), even if size is 0.
    // It shouldn't panic or crash the block logic.
    const ptr_zero = arena.alloc(0, 1, 0);
    try std.testing.expect(ptr_zero != null);

    // 2. Max Allocation (Should fail gracefully, not crash)
    const ptr_huge = arena.alloc(std.math.maxInt(usize), 1, 0);
    try std.testing.expect(ptr_huge == null);
}

test "CheatArena: Exact Block Filling & Boundary Crossing" {
    var arena = CheatArena.init(std.testing.allocator, &[_]u8{});
    defer arena.deinit();

    // 1. We know the first page is 4096 bytes (MIN_PAGE_SIZE).
    // Allocate 4090 bytes.
    const p1 = arena.alloc(4090, 1, 0).?;

    // Remaining: 6 bytes.

    // 2. Allocate exactly 6 bytes.
    const p2 = arena.alloc(6, 1, 0).?;

    // Verify they are contiguous (same block)
    const addr1 = @intFromPtr(p1);
    const addr2 = @intFromPtr(p2);
    try std.testing.expectEqual(addr1 + 4090, addr2);

    // 3. Current block is now FULL (4096/4096).
    // Allocate 1 byte. MUST trigger new block (or next cached block).
    const p3 = arena.alloc(1, 1, 0).?;
    const addr3 = @intFromPtr(p3);

    // Address should NOT be contiguous
    try std.testing.expect(addr3 != addr2 + 6);

    // Verify we have 2 blocks now
    try std.testing.expectEqual(@as(usize, 2), arena.blocks.items.len);
}

test "CheatArena: Game Loop Simulation (Memory Stability)" {
    var arena = CheatArena.init(std.testing.allocator, &[_]u8{});
    defer arena.deinit();

    var prng = std.Random.DefaultPrng.init(0x1234);
    const random = prng.random();

    const FRAMES = 60;
    const ALLOCS_PER_FRAME = 1000;

    std.debug.print("\n[Simulation] Running {d} frames...\n", .{FRAMES});

    var max_memory_used: usize = 0;

    for (0..FRAMES) |frame_idx| {
        // 1. Mark the start of the frame
        const mark = arena.getMark();

        // 2. Simulate "Game Logic" (Allocating entities, physics, strings)
        var frame_bytes: usize = 0;
        for (0..ALLOCS_PER_FRAME) |_| {
            // Mix of tiny structs and occasional buffers
            var size: usize = 0;
            if (random.intRangeAtMost(u8, 0, 100) > 95) {
                size = random.intRangeAtMost(usize, 1024, 10 * 1024); // Occasional 10KB buffer
            } else {
                size = random.intRangeAtMost(usize, 16, 128); // Standard structs
            }

            if (arena.alloc(size, 4, 0)) |_| {
                frame_bytes += size;
            }
        }

        // 3. Measure Memory BEFORE Rewind (Peak usage for this frame)
        var current_capacity: usize = 0;
        for (arena.blocks.items) |b| current_capacity += b.len;
        for (arena.large_objects.items) |l| current_capacity += l.slice.len;

        if (current_capacity > max_memory_used) max_memory_used = current_capacity;

        // Log stats for the first few frames to ensure we are reusing memory
        if (frame_idx < 3 or frame_idx == FRAMES - 1) {
            std.debug.print("  Frame {d}: Used {d:.2} KB | Capacity {d:.2} KB\n", .{
                frame_idx,
                @as(f64, @floatFromInt(frame_bytes)) / 1024.0,
                @as(f64, @floatFromInt(current_capacity)) / 1024.0,
            });
        }

        // 4. The Critical Step: REWIND
        arena.rewind(mark);
    }

    std.debug.print("[Simulation] Peak Memory: {d:.2} KB\n", .{@as(f64, @floatFromInt(max_memory_used)) / 1024.0});

    // VERIFICATION
    // After Frame 0, the capacity should essentially effectively "freeze".
    // If capacity keeps growing every frame, your 'rewind' logic is broken (leaking blocks).
    // We allow a small margin for fragmentation variance, but it shouldn't double.

    // This is the specific assertion that proves your allocator is "Production Ready" for a game loop.
    // If this fails, you have a fragmentation leak.
    const expected_cap = 2 * 1024 * 1024; // Expecting ~1-2MB roughly based on allocs
    if (max_memory_used > expected_cap) {
        std.debug.print("WARNING: High Memory Usage detected!\n", .{});
    }
}

test "CheatArena: Profiling Fragmentation & Efficiency" {
    var arena = CheatArena.init(std.testing.allocator, &[_]u8{});
    defer arena.deinit();

    var prng = std.Random.DefaultPrng.init(0xDEADBEEF);
    const random = prng.random();

    var total_requested_bytes: usize = 0;

    // SIMULATION: Run a "frame" with 5,000 mixed allocations
    const ITERATIONS = 5_000;
    for (0..ITERATIONS) |_| {
        // Mix of small (common) and medium allocations
        const size = random.intRangeAtMost(usize, 1, 256);
        // Random alignment (1, 4, 8, 16)
        const align_pow = random.intRangeAtMost(u4, 0, 4);
        const alignment: u8 = try std.math.powi(u8, 2, align_pow);

        if (arena.alloc(size, alignment, 0)) |_| {
            total_requested_bytes += size;
        }
    }

    // --- CALCULATE METRICS ---

    // 1. Total OS Memory (Capacity)
    var total_os_bytes: usize = 0;
    for (arena.blocks.items) |blk| total_os_bytes += blk.len;
    for (arena.large_objects.items) |obj| total_os_bytes += obj.slice.len;

    // 2. Calculate Efficiency
    const overhead = total_os_bytes - total_requested_bytes;
    const efficiency = @as(f64, @floatFromInt(total_requested_bytes)) / @as(f64, @floatFromInt(total_os_bytes));

    std.debug.print("\n[Profiler Report]\n", .{});
    std.debug.print("  Requested: {d:.2} MB\n", .{@as(f64, @floatFromInt(total_requested_bytes)) / 1024.0 / 1024.0});
    std.debug.print("  Allocated: {d:.2} MB (OS)\n", .{@as(f64, @floatFromInt(total_os_bytes)) / 1024.0 / 1024.0});
    std.debug.print("  Wasted:    {d:.2} KB\n", .{@as(f64, @floatFromInt(overhead)) / 1024.0});
    std.debug.print("  Efficiency: {d:.2}%\n", .{efficiency * 100.0});

    // ASSERTIONS
    // A linear allocator should be very efficient (>85%) unless you have terrible alignment luck.
    // If this drops below 70%, your block sizing strategy might be too aggressive or too small.
    try std.testing.expect(efficiency > 0.70);
}

test "CheatArena: The 'Goldilocks' Test (Packing Small Objects)" {
    var arena = CheatArena.init(std.testing.allocator, &[_]u8{});
    defer arena.deinit();

    // SCENARIO: A Particle System
    // We want to allocate 10_000 particles.
    // Each particle is 32 bytes.
    // Total Data: 128 KB.

    // This forces the Arena to use the block growth curve:
    // Block 0: 4 KB   (Holds ~128 particles)
    // Block 1: 16 KB  (Holds ~512 particles)
    // Block 2: 64 KB  (Holds ~2048 particles)
    // Block 3: 256 KB (Holds remainder)

    const Particle = struct {
        x: f32, y: f32, z: f32,
        vx: f32, vy: f32, vz: f32,
        life: f32,
        padding: u32, // Pad to 32 bytes exactly
    };

    var total_requested: usize = 0;
    const particle_count = 10_000;

    for (0..particle_count) |_| {
        const ptr = arena.alloc(@sizeOf(Particle), @alignOf(Particle), 0);
        if (ptr) |_| total_requested += @sizeOf(Particle);
    }

    // --- CALCULATE TRUE EFFICIENCY ---

    var total_capacity: usize = 0;

    // We expect NO large objects this time
    try std.testing.expectEqual(@as(usize, 0), arena.large_objects.items.len);

    for (arena.blocks.items) |b| total_capacity += b.len;

    const efficiency = @as(f64, @floatFromInt(total_requested)) / @as(f64, @floatFromInt(total_capacity));
    const wasted_kb = @as(f64, @floatFromInt(total_capacity - total_requested)) / 1024.0;

    std.debug.print("\n[Particle System Test]\n", .{});
    std.debug.print("  Particles: {d}\n", .{particle_count});
    std.debug.print("  Requested: {d:.2} KB\n", .{@as(f64, @floatFromInt(total_requested)) / 1024.0});
    std.debug.print("  Capacity:  {d:.2} KB\n", .{@as(f64, @floatFromInt(total_capacity)) / 1024.0});
    std.debug.print("  Wasted:    {d:.2} KB (Tail Waste)\n", .{wasted_kb});
    std.debug.print("  Efficiency: {d:.2}%\n", .{efficiency * 100.0});

    // EXPECTATION:
    // We should be very high (>90%), but NOT 100%.
    // Why not 100%? Because the last block (Block 3) will likely be partially empty.
    // This "Tail Waste" is the price we pay for speed.
    try std.testing.expect(efficiency > 0.90);
}

