// heap-string-return-bench-test.zig
//
// Compares three string-accumulator loop patterns that arise from the parseLine
// workload (loop carry vars + function return):
//
//   Old     — frame concat each iter + loopPreserveAndRewind (inlined; removed from runtime)
//             + preserveAndRewind on return.  The "frame" is backed by the SAME allocator
//             as heap (c_allocator / jemalloc) so the comparison is fair.
//
//   Current — heap concat + heap free each iter + restoreLoopMark
//             + preserveAndRewind (frame copy) on return + heap free of carry var.
//
//   Future  — heap concat + heap free each iter + restoreLoopMark
//             + return heap ptr directly (no frame copy, caller owns).
//             Implements task #40.
//
// All three approaches use c_allocator (= jemalloc when LD_PRELOAD is set) for
// every allocation including the Runtime backing store.  This was NOT true in the
// original loop-preserve-bench-test.zig where loopPreserveAndRewind used intra-
// frame copies backed by c_allocator but the heap baseline used c_allocator
// separately — semantically the same but the original benchmark didn't make this
// explicit.
//
// Run with jemalloc for production-realistic numbers:
//   LD_PRELOAD=/lib/x86_64-linux-gnu/libjemalloc.so.2 zig build benchmark -Doptimize=ReleaseFast

const std    = @import("std");
const Runtime    = @import("runtime-header.zig").Runtime;
const EbrContext = @import("runtime-header.zig").EbrContext;
const CheatArena = @import("frame.zig").CheatArena;

// All allocations — frame backing store, heap concat, temp buffers — go through
// c_allocator.  With LD_PRELOAD=libjemalloc.so.2 this becomes jemalloc.
const alloc = std.heap.c_allocator;

fn stdout(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

// Anti-DCE sink
var gsink: u64 = 0;
fn sink(v: u64) void { (@as(*volatile u64, &gsink)).* ^= v; }

fn makeRuntime(ctx: *EbrContext) !Runtime {
    return Runtime.init(alloc, 64 * 1024, ctx);
}

// ---------------------------------------------------------------------------
// Inline loopPreserveAndRewind — matches the removed runtime function exactly.
// softRewind moves cursor back to mark (keeps blocks alive), allocates the
// result at the rewound position, copies if addresses differ.
// ---------------------------------------------------------------------------
fn loopPreserveInline(rt: *Runtime, mark: CheatArena.Mark, data: []const u8) ![]const u8 {
    if (data.len == 0) {
        rt.overflow_arena.rewind(mark);
        return data;
    }
    rt.overflow_arena.softRewind(mark);
    const raw = (rt.overflow_arena.alloc(data.len, 1, 0) orelse return error.OutOfMemory)[0..data.len];
    if (@intFromPtr(raw.ptr) != @intFromPtr(data.ptr)) {
        std.mem.copyForwards(u8, raw, data);
    }
    return raw;
}

// ---------------------------------------------------------------------------
// Three pattern implementations of "build a string by appending N pieces
// of piece_size bytes, then return/present the result".
//
// All share the same frame work: each iteration frame-allocs a piece (simulates
// substr/charAtCodepoint overhead that exists in both old and new codegen).
// ---------------------------------------------------------------------------

/// Old: frame concat + inline loopPreserveAndRewind + preserveAndRewind return.
/// loopPreserveAndRewind replaces restoreLoopMark (it does the rewind itself).
fn accum_old(rt: *Runtime, n_pieces: usize, piece_size: usize) ![]const u8 {
    const fn_mark  = rt.saveFrameMark();
    var result: []const u8 = "";

    for (0..n_pieces) |i| {
        const loop_mark = rt.saveLoopMark();
        // Simulate frame work: alloc piece from frame arena
        const piece = (rt.overflow_arena.alloc(piece_size, 1, 0) orelse return error.OutOfMemory)[0..piece_size];
        @memset(piece, @as(u8, @truncate(i + 1)));
        // Frame concat (uses frameAlloc — same as old codegen)
        const new_result = try std.mem.concat(rt.frameAlloc(), u8, &.{ result, piece });
        // loopPreserveAndRewind replaces restoreLoopMark
        result = try loopPreserveInline(rt, loop_mark, new_result);
    }

    // preserveAndRewind: soft-rewind to fn_mark, copy result there, trim excess.
    // Returns a frame-owned slice valid until next frame operation on rt.
    return try rt.preserveAndRewind(fn_mark, result);
    // Note: caller does NOT free — result is frame-owned.
}

/// Current: heap concat + heap free + restoreLoopMark + preserveAndRewind return
/// + heap free of carry var after copy.  This is what the CLEAR compiler generates
/// for parseLine after the loopPreserveAndRewind removal.
fn accum_current(rt: *Runtime, n_pieces: usize, piece_size: usize) ![]const u8 {
    const fn_mark  = rt.saveFrameMark();
    var result: []const u8 = "";
    var result_heap = false; // track whether result needs heap free

    for (0..n_pieces) |i| {
        const loop_mark = rt.saveLoopMark();
        defer rt.restoreLoopMark(loop_mark);
        // Simulate frame work
        const piece = (rt.overflow_arena.alloc(piece_size, 1, 0) orelse return error.OutOfMemory)[0..piece_size];
        @memset(piece, @as(u8, @truncate(i + 1)));
        // Heap concat (uses heapAlloc — new codegen)
        const new_result = try std.mem.concat(rt.heapAlloc(), u8, &.{ result, piece });
        // Cleanup old result (no-op for zero-len empty string first iter)
        if (result_heap) rt.heapAlloc().free(result);
        result = new_result;
        result_heap = true;
    }

    // preserveAndRewind: copies heap string to frame, then free heap copy.
    const frame_result = try rt.preserveAndRewind(fn_mark, result);
    if (result_heap) rt.heapAlloc().free(result);
    return frame_result;
    // Caller does NOT free — frame-owned.
}

/// Future (task #40): heap concat + heap free + restoreLoopMark + return heap
/// directly.  No frame copy on return.  Caller owns the returned slice and must
/// free it.
fn accum_future(rt: *Runtime, n_pieces: usize, piece_size: usize) ![]const u8 {
    var result: []const u8 = "";
    var result_heap = false;

    for (0..n_pieces) |i| {
        const loop_mark = rt.saveLoopMark();
        defer rt.restoreLoopMark(loop_mark);
        const piece = (rt.overflow_arena.alloc(piece_size, 1, 0) orelse return error.OutOfMemory)[0..piece_size];
        @memset(piece, @as(u8, @truncate(i + 1)));
        const new_result = try std.mem.concat(rt.heapAlloc(), u8, &.{ result, piece });
        if (result_heap) rt.heapAlloc().free(result);
        result = new_result;
        result_heap = true;
    }

    return result; // caller frees
}

// ---------------------------------------------------------------------------
// Timing harness
// ---------------------------------------------------------------------------

const CALLS = 5_000; // calls per measurement

fn bench(
    label: []const u8,
    comptime f: fn (*Runtime, usize, usize) anyerror![]const u8,
    n_pieces: usize,
    piece_size: usize,
    caller_frees: bool, // true for future (heap return)
) !void {
    var ctx = EbrContext{};
    var rt = try makeRuntime(&ctx);
    defer rt.deinit();
    rt.wireAllocator();

    // Warmup
    for (0..100) |_| {
        const s = try f(&rt, n_pieces, piece_size);
        sink(s.len);
        if (caller_frees) rt.heapAlloc().free(s);
    }

    var timer = try std.time.Timer.start();
    for (0..CALLS) |_| {
        const s = try f(&rt, n_pieces, piece_size);
        sink(s.len);
        if (caller_frees) rt.heapAlloc().free(s);
    }
    const ns = timer.read();
    const ns_per_call = ns / CALLS;
    const result_size = n_pieces * piece_size;
    stdout("  {s:<10}  pieces={d:<3} size={d:<5} result={d:<6}B  {d:>6} ns/call\n",
        .{ label, n_pieces, piece_size, result_size, ns_per_call });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "string accumulator: old vs current vs future" {
    stdout("\n=== String accumulator benchmark ===\n", .{});
    stdout("({d} calls per measurement; run with LD_PRELOAD=libjemalloc.so.2 for production numbers)\n\n",
        .{CALLS});

    const configs = [_][2]usize{
        .{ 1,  32  },  // single-iter, small (best case for old approach)
        .{ 5,  32  },  // few iters, small
        .{ 10, 32  },  // moderate iters, small
        .{ 50, 32  },  // many iters, small
        .{ 5,  128 },  // few iters, medium
        .{ 10, 128 },  // moderate iters, medium
        .{ 50, 128 },  // many iters, medium — where old memcpy cost dominates
        .{ 10, 512 },  // larger strings
    };

    for (configs) |cfg| {
        const n = cfg[0];
        const sz = cfg[1];
        try bench("old",     accum_old,     n, sz, false);
        try bench("current", accum_current, n, sz, false);
        try bench("future",  accum_future,  n, sz, true);
        stdout("\n", .{});
    }

    stdout("sink={d}\n", .{gsink}); // prevent DCE of entire loop
}
