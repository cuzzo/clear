// test_preserve_rewind.zig — Correctness tests for preserveAndRewind / loopPreserve* APIs.
//
// Tests are organised into sections:
//   A. preserveAndRewind (function-level, single-value, trim excess)
//   B. loopPreserveAndRewind (loop-level, single-value, no trim)
//   C. Multi-variable preserve: naive broken case + fixed sequential pack
//   D. Edge cases: empty strings, pre-loop buffers, cross-iteration sources
//   E. The ordering constraint: fixed order (alloc order) is always correct;
//      wrong order can destroy source data before it is copied — documented
//      so it is not silently relied upon.

const std = @import("std");
const Runtime = @import("runtime-header.zig").Runtime;
const EbrContext = @import("runtime-header.zig").EbrContext;
const CheatLib = @import("runtime-header.zig").CheatLib;

/// Create a Runtime with an 8KB frame arena.
/// IMPORTANT: call rt.wireAllocator() on the CALLER'S stack-local rt,
/// not inside a helper — wireAllocator stores &rt and the pointer must
/// remain valid for the test's lifetime.
fn makeRuntime(allocator: std.mem.Allocator, ctx: *EbrContext) !Runtime {
    return Runtime.init(allocator, 8 * 1024, ctx);
}

// ============================================================
// A. preserveAndRewind (existing tests, preserved verbatim)
// ============================================================

test "preserveAndRewind: simple string" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var ctx = EbrContext{};
    defer ctx.deinit(allocator);
    var rt = try Runtime.init(allocator, 4 * 1024, &ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const mark = rt.saveFrameMark();
    const result = try std.mem.concat(rt.frameAlloc(), u8, &.{ "Hello, ", "World!" });
    const kept = try rt.preserveAndRewind(mark, result);
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
    for (0..100) |i| {
        const tmp = try std.fmt.allocPrint(rt.frameAlloc(), "tmp_{d}", .{i});
        _ = tmp;
    }
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

    const cursor_before = rt.overflow_arena.cursor;
    for (0..1000) |i| {
        const mark = rt.saveFrameMark();
        for (0..10) |_| {
            _ = rt.overflow_arena.alloc(20, 1, 0);
        }
        const raw = rt.overflow_arena.alloc(10, 1, 0) orelse unreachable;
        const result = raw[0..10];
        @memcpy(result, "result_XXX");
        result[7] = '0' + @as(u8, @intCast(i % 10));
        const kept = try rt.preserveAndRewind(mark, result);
        try std.testing.expectEqual(@as(usize, 10), kept.len);
    }
    const cursor_after = rt.overflow_arena.cursor;
    std.debug.print("preserveAndRewind loop: cursor before={d} after={d} growth={d}\n",
        .{ cursor_before, cursor_after, cursor_after - cursor_before });
    try std.testing.expect(cursor_after - cursor_before < 15000);
}

// ============================================================
// B. loopPreserveAndRewind — single variable, per-iteration
// ============================================================

test "loopPreserveAndRewind: single var, with intermediates" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var ctx = EbrContext{};
    defer ctx.deinit(allocator);
    var rt = try makeRuntime(allocator, &ctx);
    defer rt.deinit();
    rt.wireAllocator();

    // Simulate 20 iterations: allocate tmp bytes + a "result" string each iteration.
    // loopPreserveAndRewind should keep only result, reclaim tmp each iteration.
    var result: []const u8 = "";
    for (0..20) |i| {
        const mark = rt.saveLoopMark();
        // Frame-local tmp (simulates CLEAR's per-iteration locals)
        _ = try std.fmt.allocPrint(rt.frameAlloc(), "tmp_{d}_padding_bytes", .{i});
        // Outer var: reassigned each iteration
        result = try std.fmt.allocPrint(rt.frameAlloc(), "result_{d}", .{i});
        result = try rt.loopPreserveAndRewind(mark, result);
    }
    try std.testing.expectEqualStrings("result_19", result);
}

test "loopPreserveAndRewind: source is raw pointer (pre-loop buffer, below mark)" {
    // Models the kvstore RESP parser where val = substrRaw(data, pos, len)
    // returns a pointer into the pre-loop tcpRead buffer — never arena-allocated
    // inside the loop. The source is always below the current loop mark.
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var ctx = EbrContext{};
    defer ctx.deinit(allocator);
    var rt = try makeRuntime(allocator, &ctx);
    defer rt.deinit();
    rt.wireAllocator();

    // Allocate the "incoming data buffer" before the loop — this simulates tcpRead.
    const data = try rt.frameAlloc().dupe(u8, "SET key123 value456");
    _ = rt.saveLoopMark(); // mark for documentation: everything above this is "below the loop"

    var arg: []const u8 = "";
    for (0..3) |i| {
        const mark = rt.saveLoopMark();
        // Simulate intermediate per-iteration allocations
        _ = try std.fmt.allocPrint(rt.frameAlloc(), "padding_{d}", .{i});
        // substrRaw: pointer into data, which is BELOW the current loop mark.
        // data was allocated before pre_loop_mark was taken, so its address is
        // strictly before anything allocated inside the loop body.
        // "SET key123 value456": SET=[0,3), key123=[4,10), value456=[11,19)
        const offsets = [_][2]usize{ .{0,3}, .{4,10}, .{11,19} };
        const slice = data[offsets[i][0]..offsets[i][1]];
        arg = try rt.loopPreserveAndRewind(mark, slice);
    }
    // arg should hold the last iteration's slice: "value456"
    try std.testing.expectEqualStrings("value456", arg);
}

// ============================================================
// C. Multi-variable preserve: naive vs fixed
// ============================================================

// C.1: Demonstrate the naive bug.
//
// The pre-fix transpiler emitted:
//   r0 = loopPreserveAndRewind(mark, v0)  <- rewinds to mark, writes v0 at mark
//   r1 = loopPreserveAndRewind(mark, v1)  <- rewinds AGAIN to mark, overwrites v0, writes v1 at mark
//   r2 = loopPreserveAndRewind(mark, v2)  <- rewinds AGAIN, overwrites both, writes v2 at mark
//
// Result: r0 and r1 are aliases of r2's memory (last write wins).
// All three slices point to the same arena region, containing only v2's bytes.
test "loopPreserve naive bug: multiple rewinds to same mark alias all vars to same slot" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var ctx = EbrContext{};
    defer ctx.deinit(allocator);
    var rt = try makeRuntime(allocator, &ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const mark = rt.saveLoopMark();
    // Allocate three distinct strings sequentially in the frame arena.
    // They land at consecutive positions: [mark, mark+3), [mark+3, mark+7), [mark+7, mark+12).
    const s0 = try rt.frameAlloc().dupe(u8, "AAA");   // 3 bytes
    const s1 = try rt.frameAlloc().dupe(u8, "BBBB");  // 4 bytes
    const s2 = try rt.frameAlloc().dupe(u8, "CCCCC"); // 5 bytes

    // Naive: every call rewinds to the same mark → each overwrites the previous.
    const r0 = try rt.loopPreserveAndRewind(mark, s0);
    const r1 = try rt.loopPreserveAndRewind(mark, s1);
    const r2 = try rt.loopPreserveAndRewind(mark, s2);

    // After the naive sequence, all three pointers point to the same arena region
    // starting at mark.  r0 and r1 are truncated views of r2's data.
    try std.testing.expectEqual(r0.ptr, r2.ptr); // same base address
    try std.testing.expectEqual(r1.ptr, r2.ptr);
    // r0 (len=3) reads first 3 bytes of "CCCCC" → "CCC"
    try std.testing.expectEqualStrings("CCC",   r0); // corrupted: should be "AAA"
    // r1 (len=4) reads first 4 bytes of "CCCCC" → "CCCC"
    try std.testing.expectEqualStrings("CCCC",  r1); // corrupted: should be "BBBB"
    // r2 is the only correct result (last write wins)
    try std.testing.expectEqualStrings("CCCCC", r2);
}

// C.2: Fixed API — loopPreserveAndRewind for first var, loopPreserveVar for the rest.
//
// The fixed transpiler emits:
//   r0 = loopPreserveAndRewind(mark, v0)  <- rewinds once, packs v0 at mark
//   r1 = loopPreserveVar(v1)              <- packs v1 right after v0 (no rewind)
//   r2 = loopPreserveVar(v2)              <- packs v2 right after v1 (no rewind)
//
// All three slices are distinct and correct.
test "loopPreserve fixed: sequential pack produces correct independent slices" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var ctx = EbrContext{};
    defer ctx.deinit(allocator);
    var rt = try makeRuntime(allocator, &ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const mark = rt.saveLoopMark();
    const s0 = try rt.frameAlloc().dupe(u8, "AAA");
    const s1 = try rt.frameAlloc().dupe(u8, "BBBB");
    const s2 = try rt.frameAlloc().dupe(u8, "CCCCC");

    const r0 = try rt.loopPreserveAndRewind(mark, s0); // rewind + pack at mark
    const r1 = try rt.loopPreserveVar(s1);             // pack after r0, no rewind
    const r2 = try rt.loopPreserveVar(s2);             // pack after r1, no rewind

    try std.testing.expectEqualStrings("AAA",   r0);
    try std.testing.expectEqualStrings("BBBB",  r1);
    try std.testing.expectEqualStrings("CCCCC", r2);

    // Sequential layout: r0 ends where r1 begins, r1 ends where r2 begins.
    try std.testing.expectEqual(r0.ptr + r0.len, r1.ptr);
    try std.testing.expectEqual(r1.ptr + r1.len, r2.ptr);
}

// C.3: Source overlap — the case that LOOKS dangerous but is safe in correct order.
//
// Scenario: the source of v1 starts inside the pack region of v0 (their arena
// allocations are adjacent/overlapping).  copyForwards is safe here because
// destination starts BEFORE source (dst < src), so left-to-right copy always
// reads source bytes before writing over them.
test "loopPreserve fixed: overlapping sources (dst < src) handled correctly by copyForwards" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var ctx = EbrContext{};
    defer ctx.deinit(allocator);
    var rt = try makeRuntime(allocator, &ctx);
    defer rt.deinit();
    rt.wireAllocator();

    // Allocate a frame-local "tmp" of 1 byte before v0 so v0 is at mark+1.
    // This creates a 1-byte gap between mark and v0, making dst=[mark] < src=[mark+1]
    // with true overlap when v0.len > 1.
    const mark = rt.saveLoopMark();
    _ = rt.overflow_arena.alloc(1, 1, 0); // 1-byte gap (simulates tmp allocation)

    // v0 at mark+1, 5 bytes → source = [mark+1, mark+6)
    const v0 = (rt.overflow_arena.alloc(5, 1, 0) orelse unreachable)[0..5];
    @memcpy(v0, "hello");
    // v1 at mark+6, 5 bytes → source = [mark+6, mark+11)
    const v1 = (rt.overflow_arena.alloc(5, 1, 0) orelse unreachable)[0..5];
    @memcpy(v1, "world");

    // After rewind to mark, r0 lands at [mark, mark+5) — overlaps v0's source [mark+1, mark+6).
    // dst.ptr = mark < src.ptr = mark+1.  copyForwards reads left-to-right: safe.
    const r0 = try rt.loopPreserveAndRewind(mark, v0);
    // r1 lands at [mark+5, mark+10) — no overlap with v1's source [mark+6, mark+11).
    const r1 = try rt.loopPreserveVar(v1);

    try std.testing.expectEqualStrings("hello", r0);
    try std.testing.expectEqualStrings("world", r1);
    try std.testing.expectEqual(r0.ptr + r0.len, r1.ptr); // sequential
}

// C.4: Source is entirely below the pack range (previous iteration, or pre-loop buffer).
//
// When a var's source was preserved in a PREVIOUS iteration, it lives below the
// current loop mark.  No overlap is possible: the pack writes at [mark, mark+len)
// and the source is at some position < mark.
test "loopPreserve fixed: source from previous iteration (below current mark)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var ctx = EbrContext{};
    defer ctx.deinit(allocator);
    var rt = try makeRuntime(allocator, &ctx);
    defer rt.deinit();
    rt.wireAllocator();

    // Simulate three outer vars that are only assigned in specific iterations
    // (like arg0/arg1/arg2 in a RESP parser: each assigned in a different inner-loop pass).
    var a: []const u8 = "";
    var b: []const u8 = "";
    var c: []const u8 = "";

    // Outer loop simulates three inner-loop passes.
    for (0..3) |pass| {
        const mark = rt.saveLoopMark();
        _ = try std.fmt.allocPrint(rt.frameAlloc(), "pad_{d}", .{pass}); // per-iter intermediate

        switch (pass) {
            0 => { a = try rt.frameAlloc().dupe(u8, "SET"); },
            1 => { b = try rt.frameAlloc().dupe(u8, "key001"); },
            2 => { c = try rt.frameAlloc().dupe(u8, "value"); },
            else => unreachable,
        }

        // Preserve all three each iteration.
        // a's source: in pass 0 it's current-iter; in passes 1 and 2 it's from a prior iter (below mark).
        // b's source: in pass 1 it's current-iter; in pass 2 it's from prior iter.
        // c's source: only current in pass 2.
        a = try rt.loopPreserveAndRewind(mark, a);
        b = try rt.loopPreserveVar(b);
        c = try rt.loopPreserveVar(c);
    }

    try std.testing.expectEqualStrings("SET",    a);
    try std.testing.expectEqualStrings("key001", b);
    try std.testing.expectEqualStrings("value",  c);
}

// C.5: Empty vars interspersed.
//
// Vars that are still "" (empty) at preserve time are no-ops (loopPreserveVar
// returns the original empty slice, cursor unchanged).  Non-empty vars pack
// correctly in the gaps.
test "loopPreserve fixed: empty vars mixed with non-empty" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var ctx = EbrContext{};
    defer ctx.deinit(allocator);
    var rt = try makeRuntime(allocator, &ctx);
    defer rt.deinit();
    rt.wireAllocator();

    var a: []const u8 = "";
    var b: []const u8 = "";
    var c: []const u8 = "";

    for (0..5) |i| {
        const mark = rt.saveLoopMark();
        _ = try std.fmt.allocPrint(rt.frameAlloc(), "pad_{d}", .{i});
        b = try std.fmt.allocPrint(rt.frameAlloc(), "b_{d}", .{i}); // only b is reassigned
        a = try rt.loopPreserveAndRewind(mark, a); // a = "" throughout
        b = try rt.loopPreserveVar(b);
        c = try rt.loopPreserveVar(c); // c = "" throughout
    }

    try std.testing.expectEqualStrings("",    a);
    try std.testing.expectEqualStrings("b_4", b);
    try std.testing.expectEqualStrings("",    c);
}

// C.6: Many variables — stress test with N=8 vars.
//
// Each iteration allocates 8 strings of varying lengths and preserves them all.
// Verifies that the final state after 50 iterations is correct for every var.
test "loopPreserve fixed: 8 vars, 50 iterations, all correct" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var ctx = EbrContext{};
    defer ctx.deinit(allocator);
    var rt = try makeRuntime(allocator, &ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const N = 8;
    var vars: [N][]const u8 = .{""} ** N;

    for (0..50) |iter| {
        const mark = rt.saveLoopMark();
        _ = try std.fmt.allocPrint(rt.frameAlloc(), "tmp_{d}", .{iter}); // per-iter intermediate

        // Allocate all N vars for this iteration
        var bufs: [N][]const u8 = undefined;
        for (0..N) |k| {
            bufs[k] = try std.fmt.allocPrint(rt.frameAlloc(), "v{d}_{d}", .{k, iter});
        }
        for (0..N) |k| { vars[k] = bufs[k]; }

        // Fixed preserve: first uses loopPreserveAndRewind, rest use loopPreserveVar
        vars[0] = try rt.loopPreserveAndRewind(mark, vars[0]);
        for (1..N) |k| {
            vars[k] = try rt.loopPreserveVar(vars[k]);
        }
    }

    // After 50 iterations, every var should hold its iter=49 value
    for (0..N) |k| {
        const expected = try std.fmt.allocPrint(allocator, "v{d}_49", .{k});
        defer allocator.free(expected);
        try std.testing.expectEqualStrings(expected, vars[k]);
    }
}

// ============================================================
// D. Edge cases
// ============================================================

// D.1: var source is at the exact pack boundary (ptr check detects same address → no copy).
test "loopPreserve fixed: source exactly at pack position (ptr-equal, no-copy fast path)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var ctx = EbrContext{};
    defer ctx.deinit(allocator);
    var rt = try makeRuntime(allocator, &ctx);
    defer rt.deinit();
    rt.wireAllocator();

    // No intermediate allocations: v0 is allocated at exactly mark.
    // After rewind, the new_buf is also at mark → same pointer → copy is skipped.
    const mark = rt.saveLoopMark();
    const v0 = (rt.overflow_arena.alloc(4, 1, 0) orelse unreachable)[0..4];
    @memcpy(v0, "abcd");
    const v1 = (rt.overflow_arena.alloc(3, 1, 0) orelse unreachable)[0..3];
    @memcpy(v1, "xyz");

    const r0 = try rt.loopPreserveAndRewind(mark, v0);
    const r1 = try rt.loopPreserveVar(v1);

    try std.testing.expectEqualStrings("abcd", r0);
    try std.testing.expectEqualStrings("xyz",  r1);
    // r0 must be at mark (same as original v0, no copy performed)
    try std.testing.expectEqual(v0.ptr, r0.ptr);
}

// D.2: All vars have the same source — each gets its own arena slot.
test "loopPreserve fixed: same source string for all vars produces independent copies" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var ctx = EbrContext{};
    defer ctx.deinit(allocator);
    var rt = try makeRuntime(allocator, &ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const mark = rt.saveLoopMark();
    const shared = try rt.frameAlloc().dupe(u8, "same");

    const r0 = try rt.loopPreserveAndRewind(mark, shared);
    const r1 = try rt.loopPreserveVar(shared); // shared's ptr = mark (r0's ptr); r1 goes after
    const r2 = try rt.loopPreserveVar(shared);

    try std.testing.expectEqualStrings("same", r0);
    try std.testing.expectEqualStrings("same", r1);
    try std.testing.expectEqualStrings("same", r2);
    // r0 and r1 must NOT alias: they are independent copies
    try std.testing.expect(r0.ptr != r1.ptr);
    try std.testing.expect(r1.ptr != r2.ptr);
}

// ============================================================
// E. The ordering constraint
//
// loopPreserveAndRewind + loopPreserveVar is CORRECT when preserve order
// matches allocation order (source addresses are monotonically increasing
// with pack positions).  This is guaranteed by the CLEAR transpiler because
// outer_string_reassigns collects variables in source/assignment order, which
// matches arena allocation order for sequential CLEAR code.
//
// WRONG ORDER can silently corrupt data: if a large var is preserved first
// (gets packed at low addresses) but a small var was allocated BEFORE it
// (source at a lower address), the large var's pack writes over the small
// var's source before the small var is read.
//
// The test below DOCUMENTS this behaviour so it is not relied upon silently.
// It uses std.testing.expect with inverted logic to confirm corruption occurs.
// ============================================================

test "loopPreserve ordering constraint: WRONG order corrupts source data (documented failure)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var ctx = EbrContext{};
    defer ctx.deinit(allocator);
    var rt = try makeRuntime(allocator, &ctx);
    defer rt.deinit();
    rt.wireAllocator();

    // Allocation order: small ("XY") first, then large ("ABCDEFGHIJ").
    // CORRECT preserve order: small first, then large (matches allocation order).
    // WRONG preserve order: large first, then small.
    //
    // Wrong order: packing large at [mark, mark+10) overwrites the source of small
    // at [mark, mark+2) before small is copied — small gets the first 2 bytes of
    // large's data instead of its own.

    const mark = rt.saveLoopMark();
    const small = (rt.overflow_arena.alloc(2, 1, 0) orelse unreachable)[0..2];
    @memcpy(small, "XY");
    const large = (rt.overflow_arena.alloc(10, 1, 0) orelse unreachable)[0..10];
    @memcpy(large, "ABCDEFGHIJ");

    // WRONG order: large first
    const r_large = try rt.loopPreserveAndRewind(mark, large);
    const r_small = try rt.loopPreserveVar(small);

    // r_large is correct (it is the first preserve — nothing has overwritten it yet).
    try std.testing.expectEqualStrings("ABCDEFGHIJ", r_large);
    // r_small is CORRUPTED: small.ptr = mark, but [mark..mark+2) now contains
    // the first 2 bytes of large's copy ("AB"), not the original "XY".
    // We assert the CORRUPTED value to document expected wrong-order behaviour.
    try std.testing.expectEqualStrings("AB", r_small); // was "XY" — corrupted by large's pack

    // ---- Verify that CORRECT order (small first, then large) gives right answer ----
    rt.overflow_arena.softRewind(mark); // reset for second experiment

    const small2 = (rt.overflow_arena.alloc(2, 1, 0) orelse unreachable)[0..2];
    @memcpy(small2, "XY");
    const large2 = (rt.overflow_arena.alloc(10, 1, 0) orelse unreachable)[0..10];
    @memcpy(large2, "ABCDEFGHIJ");

    // CORRECT order: small first (matches allocation order)
    const r_small2 = try rt.loopPreserveAndRewind(mark, small2);
    const r_large2 = try rt.loopPreserveVar(large2);

    try std.testing.expectEqualStrings("XY",         r_small2); // correct
    try std.testing.expectEqualStrings("ABCDEFGHIJ", r_large2); // correct
}
