const std = @import("std");
const CheatArena = @import("frame.zig").CheatArena;
const build_options = @import("build_options");

const Allocation = struct {
    ptr: [*]u8,
    len: usize,
    pattern: u8,
};

const Scope = struct {
    mark: CheatArena.Mark,
    allocation_count: usize,
};

/// Helper to efficiently check integrity.
/// 1. Checks boundaries (first/last bytes) - catches off-by-one/overflows cheaply.
/// 2. Probabilistically checks the full body.
fn verifyAllocation(alloc: Allocation, full_scan: bool) !void {
    const slice = alloc.ptr[0..alloc.len];
    if (slice.len == 0) return;

    // 1. Cheap Boundary Check (Always run)
    // Check first 16 bytes (or less)
    const head_len = @min(slice.len, 16);
    for (slice[0..head_len]) |b| {
        if (b != alloc.pattern) return error.MemoryCorruption;
    }

    // Check last 16 bytes (or less)
    const tail_start = if (slice.len > 16) slice.len - 16 else 0;
    for (slice[tail_start..]) |b| {
        if (b != alloc.pattern) return error.MemoryCorruption;
    }

    // 2. Expensive Full Scan (Only if requested)
    if (full_scan) {
        if (std.mem.indexOfNone(u8, slice, &[_]u8{alloc.pattern})) |_| {
            return error.MemoryCorruption;
        }
    }
}

test "CheatArena: Optimized Fuzz Test" {
    // CONFIGURATION
    const ITERATIONS = if (build_options.coverage) 500 else 50_000;
    const MAX_ALLOC_SIZE = if (build_options.coverage) 64 * 1024 else 512 * 1024;
    const CHECKPOINT_EVERY = if (build_options.coverage) 100 else 5000;

    // SETUP
    var prng = std.Random.DefaultPrng.init(0x12345678);
    const random = prng.random();
    var arena = CheatArena.init(std.testing.allocator, &[_]u8{});
    defer arena.deinit();

    var allocations = std.ArrayListUnmanaged(Allocation).empty;
    defer allocations.deinit(std.testing.allocator);

    var scopes = std.ArrayList(Scope).empty;
    defer scopes.deinit(std.testing.allocator);

    std.debug.print("\n[Fuzz] Running {d} iterations with optimized checks...\n", .{ITERATIONS});

    var i: usize = 0;
    while (i < ITERATIONS) : (i += 1) {
        const action = random.intRangeAtMost(u8, 0, 100);

        // --- PERIODIC FULL HEAP CHECK (Every 5,000 ops) ---
        // This ensures deep correctness without paying the cost every loop.
        if (i % CHECKPOINT_EVERY == 0 and allocations.items.len > 0) {
            std.debug.print("  [Checkpoint {d}/{d}] Verifying {d} allocations...\n", .{i, ITERATIONS, allocations.items.len});
            for (allocations.items) |alloc| {
                try verifyAllocation(alloc, true);
            }
        }

        if (action <= 70) {
            // --- ALLOCATE ---
            var size: usize = 0;
            // 90% Small, 10% Large (More realistic distribution)
            if (random.intRangeAtMost(u8, 0, 9) < 9) {
                size = random.intRangeAtMost(usize, 1, 512);
            } else {
                size = random.intRangeAtMost(usize, 513, MAX_ALLOC_SIZE);
            }

            const align_pow = random.intRangeAtMost(u4, 0, 5);
            const alignment: u8 = try std.math.powi(u8, 2, align_pow);

            if (arena.alloc(size, alignment, 0)) |ptr| {
                const addr = @intFromPtr(ptr);
                if (addr % alignment != 0) return error.AlignmentFail;

                const pattern = random.int(u8);
                const slice = ptr[0..size];
                @memset(slice, pattern);

                try allocations.append(std.testing.allocator, .{
                    .ptr = ptr,
                    .len = size,
                    .pattern = pattern,
                });
            }
        } else if (action <= 85) {
            // --- PUSH SCOPE ---
            try scopes.append(std.testing.allocator, .{
                .mark = arena.getMark(),
                .allocation_count = allocations.items.len,
            });
        } else {
            // --- POP SCOPE ---
            if (scopes.items.len > 0) {
                // VERIFICATION STRATEGY:
                // When popping, we are about to destroy state. This is a critical time to check integrity.
                // But checking 10,000 items is slow.

                // 1. Check ALL items for boundary corruption (fast)
                for (allocations.items) |alloc| {
                    try verifyAllocation(alloc, false);
                }

                // 2. Check a random 5% sample for DEEP corruption
                // (or just the last 100 items which are most likely to be corrupted by recent ops)
                const check_count = @max(10, allocations.items.len / 20); // 5%
                var checked: usize = 0;
                while (checked < check_count) : (checked += 1) {
                    const idx = random.uintLessThan(usize, allocations.items.len);
                    try verifyAllocation(allocations.items[idx], true);
                }

                const scope = scopes.pop().?;
                arena.rewind(scope.mark);
                allocations.shrinkRetainingCapacity(scope.allocation_count);
            }
        }
    }

    // Final comprehensive check
    std.debug.print("[Fuzz] Final Check of remaining {d} allocations...\n", .{allocations.items.len});
    for (allocations.items) |alloc| {
        try verifyAllocation(alloc, true);
    }
    std.debug.print("[Fuzz] Success.\n", .{});
}
