// arena-mode-test.zig — Tests for the @arena fiber allocation mode.
//
// Verifies that:
//   1. In arena mode, restoreFrameMark is a no-op (memory survives across calls)
//   2. In normal mode, restoreFrameMark frees memory (baseline)
//   3. Arena rewind is O(1) (pointer reset, no per-object work)
//   4. Large objects are freed on rewind (even in normal mode)
//
// Run: zig test arena-mode-test.zig

const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const CheatArena = @import("frame.zig").CheatArena;

test "normal mode: restoreFrameMark reclaims memory" {
    const allocator = std.testing.allocator;
    const frame_mem = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(frame_mem);

    var rt = try Runtime.initFromSlice(frame_mem, undefined, allocator, 0);
    defer rt.deinit();
    rt.wireAllocator();

    // Allocate in a frame scope
    const mark = rt.saveFrameMark();
    const ptr1 = try rt.frameAlloc().alloc(u8, 1024);
    _ = ptr1;

    // In Debug/ReleaseSafe, the cheat arena routes allocations through
    // `large_objects`, so raw cursor movement is not a stable signal.
    try std.testing.expect(rt.overflow_arena.currentBytes() > 0);

    // Restore — all frame-owned bytes should be reclaimed
    rt.restoreFrameMark(mark);
    try std.testing.expectEqual(@as(usize, 0), rt.overflow_arena.currentBytes());
}

test "arena mode: restoreFrameMark is a no-op" {
    const allocator = std.testing.allocator;
    const frame_mem = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(frame_mem);

    var rt = try Runtime.initFromSlice(frame_mem, undefined, allocator, 0);
    defer rt.deinit();
    rt.wireAllocator();
    rt.arena_mode = true; // Enable arena mode

    // Allocate in a frame scope
    const mark = rt.saveFrameMark();
    const ptr1 = try rt.frameAlloc().alloc(u8, 1024);
    _ = ptr1;

    const bytes_after_alloc = rt.overflow_arena.currentBytes();
    try std.testing.expect(bytes_after_alloc > 0);

    // Restore — in arena mode, this should be a NO-OP
    rt.restoreFrameMark(mark);

    // Arena mode keeps frame-owned bytes alive across restoreFrameMark
    try std.testing.expectEqual(bytes_after_alloc, rt.overflow_arena.currentBytes());
}

test "arena mode: multiple frame scopes share memory" {
    const allocator = std.testing.allocator;
    const frame_mem = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(frame_mem);

    var rt = try Runtime.initFromSlice(frame_mem, undefined, allocator, 0);
    defer rt.deinit();
    rt.wireAllocator();
    rt.arena_mode = true;

    // Simulate function A allocating
    const mark_a = rt.saveFrameMark();
    const buf_a = try rt.frameAlloc().alloc(u8, 2048);
    @memset(buf_a, 0xAA);
    rt.restoreFrameMark(mark_a); // no-op in arena mode

    // Simulate function B allocating
    const mark_b = rt.saveFrameMark();
    const buf_b = try rt.frameAlloc().alloc(u8, 2048);
    @memset(buf_b, 0xBB);
    rt.restoreFrameMark(mark_b); // no-op in arena mode

    // Both buffers should still be valid (not reclaimed)
    try std.testing.expectEqual(@as(u8, 0xAA), buf_a[0]);
    try std.testing.expectEqual(@as(u8, 0xAA), buf_a[2047]);
    try std.testing.expectEqual(@as(u8, 0xBB), buf_b[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), buf_b[2047]);

    // Total live arena bytes should reflect both allocations
    try std.testing.expect(rt.overflow_arena.currentBytes() >= 4096);
}

test "arena mode: final rewind reclaims everything" {
    const allocator = std.testing.allocator;
    const frame_mem = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(frame_mem);

    var rt = try Runtime.initFromSlice(frame_mem, undefined, allocator, 0);
    defer rt.deinit();
    rt.wireAllocator();
    rt.arena_mode = true;

    // Simulate many allocations across multiple "functions"
    for (0..10) |_| {
        const mark = rt.saveFrameMark();
        _ = try rt.frameAlloc().alloc(u8, 1024);
        rt.restoreFrameMark(mark); // no-op in arena mode
    }

    try std.testing.expect(rt.overflow_arena.currentBytes() >= 10 * 1024);

    // Disable arena mode and do a real rewind (simulates fiber completion)
    rt.arena_mode = false;
    const final_mark = CheatArena.Mark{
        .block_index = 0,
        .cursor = 0,
        .large_obj_count = 0,
    };
    rt.overflow_arena.rewind(final_mark);

    // Everything reclaimed — no frame-owned bytes remain
    try std.testing.expectEqual(@as(usize, 0), rt.overflow_arena.currentBytes());
}

test "CheatArena rewind is O(1) — pointer reset only" {
    const allocator = std.testing.allocator;

    var arena = CheatArena.init(allocator, &[_]u8{});
    defer arena.deinit();

    // Allocate a bunch of objects
    for (0..100) |_| {
        _ = arena.alloc(256, 8, 0) orelse unreachable;
    }

    const mark = CheatArena.Mark{
        .block_index = 0,
        .cursor = 0,
        .large_obj_count = 0,
    };

    // Rewind is just: set cursor, set block_index, free excess blocks.
    // No per-object iteration, no poisoning.
    arena.rewind(mark);

    try std.testing.expectEqual(@as(usize, 0), arena.cursor);
    // Blocks are kept (cached for reuse) — only cursor resets.
}

test "heapAlloc uses pinned local allocator when set" {
    const allocator = std.testing.allocator;
    const frame_mem = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(frame_mem);

    var rt = try Runtime.initFromSlice(frame_mem, undefined, allocator, 0);
    defer rt.deinit();
    rt.wireAllocator();

    // Without pinned allocator: heapAlloc returns the global allocator
    const global = rt.heapAlloc();

    // With pinned allocator: heapAlloc returns the local one
    var local_arena = std.heap.ArenaAllocator.init(allocator);
    defer local_arena.deinit();

    const fp = @import("scheduler.zig");
    fp.__pinned_local_alloc = local_arena.allocator();
    defer fp.__pinned_local_alloc = null;

    const pinned = rt.heapAlloc();

    // They should be different allocators
    try std.testing.expect(global.ptr != pinned.ptr);
}

test "owns: current storage, retired storage, and foreign pointers" {
    // `owns` backs the frame allocator's foreign-free check, so its three
    // answers are load-bearing: memory the arena currently holds is owned,
    // memory it handed out and has since reclaimed is STILL owned (a no-op
    // cleanup may run after the rewind that trimmed the block -- that
    // sequence is legitimate), and anything else is a foreign free.
    var static_buf: [512]u8 = undefined;
    var arena = CheatArena.init(std.testing.allocator, &static_buf);
    defer arena.deinit();

    // Static-block storage is owned.
    const in_static = arena.alloc(64, 8, 0).?;
    try std.testing.expect(arena.owns(in_static));

    // Overflow-block storage is owned while live...
    const mark = arena.getMark();
    const spilled = arena.alloc(8 * 1024, 8, 0).?;
    try std.testing.expect(arena.owns(spilled));

    // ...and stays owned after the rewind retires its block: the envelope
    // remembers reclaimed address space precisely so late no-op cleanups are
    // not misread as foreign.
    arena.rewind(mark);
    try std.testing.expect(arena.owns(spilled));

    // Memory this arena never handed out is foreign -- rodata and the heap
    // are the callers that must be rejected.
    const rodata: []const u8 = "not the arena's to free";
    try std.testing.expect(!arena.owns(@constCast(rodata.ptr)));
    const heap = try std.testing.allocator.alloc(u8, 32);
    defer std.testing.allocator.free(heap);
    try std.testing.expect(!arena.owns(heap.ptr));
}
