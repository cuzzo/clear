const std = @import("std");
const Runtime = @import("runtime-header.zig").Runtime;
const EbrContext = @import("runtime-header.zig").EbrContext;
const CheatLib = @import("runtime-header.zig").CheatLib;

fn makeTestRuntime(allocator: std.mem.Allocator, ctx: *EbrContext) !*Runtime {
    var rt = try Runtime.init(allocator, 4 * 1024, ctx);
    rt.wireAllocator();
    return &rt;
}

test "preserveAndRewind: simple string" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var ctx = EbrContext{};
    defer ctx.deinit(allocator);
    var rt = try Runtime.init(allocator, 4 * 1024, &ctx);
    defer rt.deinit();
    rt.wireAllocator();

    // Save mark
    const mark = rt.saveFrameMark();

    // Allocate a string in the frame arena (simulates std.mem.concat)
    const result = try std.mem.concat(rt.frameAlloc(), u8, &.{ "Hello, ", "World!" });

    std.debug.print("before PAR: \"{s}\" len={d}\n", .{ result, result.len });

    // preserveAndRewind
    const kept = try rt.preserveAndRewind(mark, result);

    std.debug.print("after PAR: \"{s}\" len={d}\n", .{ kept, kept.len });

    try std.testing.expectEqualStrings("Hello, World!", kept);
}

test "preserveAndRewind: with intermediates" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var ctx = EbrContext{};
    defer ctx.deinit(allocator);
    var rt = try Runtime.init(allocator, 4 * 1024, &ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const mark = rt.saveFrameMark();

    // Allocate intermediate data (simulates loop work)
    for (0..100) |i| {
        const tmp = try std.fmt.allocPrint(rt.frameAlloc(), "tmp_{d}", .{i});
        _ = tmp; // not used, just wasting arena space
    }

    // Allocate result
    const result = try std.mem.concat(rt.frameAlloc(), u8, &.{ "final", "_", "result" });

    const kept = try rt.preserveAndRewind(mark, result);

    try std.testing.expectEqualStrings("final_result", kept);
}

test "preserveAndRewind: empty string" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var ctx = EbrContext{};
    defer ctx.deinit(allocator);
    var rt = try Runtime.init(allocator, 4 * 1024, &ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const mark = rt.saveFrameMark();
    const result: []const u8 = "";
    const kept = try rt.preserveAndRewind(mark, result);
    try std.testing.expectEqualStrings("", kept);
}

test "preserveAndRewind: called in loop reclaims arena" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var ctx = EbrContext{};
    defer ctx.deinit(allocator);
    var rt = try Runtime.init(allocator, 4 * 1024, &ctx);
    defer rt.deinit();
    rt.wireAllocator();

    // Simulate calling a string-returning function 1000 times in a loop.
    // Each iteration: save mark, allocate intermediates + result, preserveAndRewind.
    // The caller's cursor should grow only by the result size each iteration,
    // not by the intermediates.
    const cursor_before = rt.overflow_arena.cursor;

    for (0..1000) |i| {
        const mark = rt.saveFrameMark();
        // Simulate function body: intermediate allocs via raw arena (avoid std @memset)
        for (0..10) |_| {
            _ = rt.overflow_arena.alloc(20, 1, 0);
        }
        // Final result via raw arena + manual fill
        const raw = rt.overflow_arena.alloc(10, 1, 0) orelse unreachable;
        const result = raw[0..10];
        @memcpy(result, "result_XXX");
        result[7] = '0' + @as(u8, @intCast(i % 10));

        const kept = try rt.preserveAndRewind(mark, result);
        try std.testing.expectEqual(@as(usize, 10), kept.len);
    }

    const cursor_after = rt.overflow_arena.cursor;
    // Each iteration rewinds to mark, then places 10 bytes. Cursor should advance
    // by ~10 bytes per iteration (with alignment), not 210.
    // 1000 * 10 = 10000 vs 1000 * 210 = 210000 without rewind.
    std.debug.print("cursor before={d} after={d} growth={d}\n", .{ cursor_before, cursor_after, cursor_after - cursor_before });
    try std.testing.expect(cursor_after - cursor_before < 15000);
}
