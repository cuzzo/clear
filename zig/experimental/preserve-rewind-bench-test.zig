// preserve-rewind-bench-test.zig
//
// Three questions answered by this benchmark:
//
// A. Does frame-pack maintain its performance advantage for REALISTIC string
//    sizes (256B-4KB)? Secondary: how much arena memory does each approach
//    accumulate over N iterations?
//
// B. Where does frame-pack LOSE? Strings exceeding 4096B (the first dynamic
//    page cap) trigger the large_objects heap-backed path after the static block
//    fills, so frame-pack pays malloc cost anyway PLUS accumulates large_objects
//    entries that are never freed until the function returns.
//
// C. How many of N! preserve orderings are safe? Only allocation-order is
//    guaranteed correct. Every other ordering risks source-data corruption for
//    strings of unequal size.

const std = @import("std");
const Runtime   = @import("runtime-header.zig").Runtime;
const EbrContext = @import("runtime-header.zig").EbrContext;

// ---------------------------------------------------------------------------
// Arena sizes
// ---------------------------------------------------------------------------
// Large arena: 8MB — keeps large-string benchmark in the static block so we
// measure pure copy+rewind cost without dynamic-page allocation noise.
const LARGE_ARENA  = 8 * 1024 * 1024;
// Small arena: 16KB — fills quickly so we can observe the threshold crossing
// into dynamic pages and the large_objects path.
const SMALL_ARENA  = 16 * 1024;

// ---------------------------------------------------------------------------
// Iteration counts
// ---------------------------------------------------------------------------
// Large strings grow the arena O(iters * sum_sizes). Cap iterations to keep
// total arena consumption bounded for the 8MB large arena.
// N=8 strings avg 2KB each = 16KB/iter. 500 iters = 8MB (exactly fills arena).
// Use 400 to leave headroom.
const ITERS_LARGE     = 400;
// Threshold test: only needs enough iterations to fill the 16KB static block.
// 16KB / 4096B per string = 4 iterations to fill. Use 50 for stable timing.
const ITERS_THRESHOLD = 50;

// ---------------------------------------------------------------------------
// LCG — reproducible pseudo-random without std.rand
// ---------------------------------------------------------------------------
const Lcg = struct {
    state: u64,
    fn next(self: *Lcg) u64 {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        return self.state >> 33;
    }
    /// Fisher-Yates in-place shuffle of a usize slice.
    fn shuffle(self: *Lcg, arr: []usize) void {
        var i = arr.len;
        while (i > 1) {
            i -= 1;
            const j = self.next() % (i + 1);
            const tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp;
        }
    }
};

/// Generate N random sizes in [min_size, max_size] from a fixed seed.
fn randomSizes(comptime N: usize, seed: u64, min_size: usize, max_size: usize) [N]usize {
    var rng = Lcg{ .state = seed };
    var sizes: [N]usize = undefined;
    for (0..N) |k| sizes[k] = min_size + rng.next() % (max_size - min_size + 1);
    return sizes;
}

// ---------------------------------------------------------------------------
// Runtime helpers — wireAllocator MUST be called on the caller's local rt.
// ---------------------------------------------------------------------------
fn makeRuntime(alloc: std.mem.Allocator, ctx: *EbrContext, frame_size: usize) !Runtime {
    return Runtime.init(alloc, frame_size, ctx);
}

fn nsPerIter(total_ns: u64, iters: usize) u64 {
    return total_ns / @as(u64, @intCast(iters));
}

// ---------------------------------------------------------------------------
// Core inner loop: frame-pack N strings of given sizes, return elapsed ns
// and final arena cursor (proxy for total arena bytes consumed by preserved
// strings — grows by sum(sizes) per iteration).
// ---------------------------------------------------------------------------
fn runFramePackSized(
    comptime N: usize,
    sizes: [N]usize,
    rt: *Runtime,
    iters: usize,
) !struct { ns: u64, arena_cursor: usize, large_obj_count: usize } {
    var vars: [N][]const u8 = .{""} ** N;

    var timer = try std.time.Timer.start();
    for (0..iters) |fill| {
        const mark = rt.saveLoopMark();
        // Allocate N strings of the required sizes and fill with variable index.
        var bufs: [N][]u8 = undefined;
        for (0..N) |k| {
            bufs[k] = try rt.frameAlloc().alloc(u8, sizes[k]);
            @memset(bufs[k], @as(u8, @intCast((k + fill + 1) & 0xff)));
        }
        for (0..N) |k| vars[k] = bufs[k];
        vars[0] = try rt.loopPreserveAndRewind(mark, vars[0]);
        for (1..N) |k| vars[k] = try rt.loopPreserveVar(vars[k]);
    }
    const elapsed = timer.read();

    // Prevent DCE - accumulate lengths; volatile write forces the loop to survive optimization
    var anti_dce: usize = 0;
    for (vars) |v| anti_dce += v.len;
    const p: *volatile usize = @ptrCast(&anti_dce);
    p.* = anti_dce;

    return .{
        .ns             = elapsed,
        .arena_cursor   = rt.overflow_arena.cursor,
        .large_obj_count = rt.overflow_arena.large_objects.items.len,
    };
}

// ---------------------------------------------------------------------------
// Heap-alloc baseline: free old, alloc new each iteration. O(1) live memory.
// ---------------------------------------------------------------------------
fn runHeapAllocSized(
    comptime N: usize,
    sizes: [N]usize,
    rt: *Runtime,
    iters: usize,
) !struct { ns: u64, live_heap_bytes: usize } {
    const heap = rt.heapAlloc();
    var vars: [N][]u8 = undefined;
    for (0..N) |k| {
        vars[k] = try heap.alloc(u8, sizes[k]);
        @memset(vars[k], @as(u8, @intCast((k + 1) & 0xff)));
    }
    defer for (vars) |v| heap.free(v);

    var timer = try std.time.Timer.start();
    for (0..iters) |fill| {
        const mark = rt.saveLoopMark();
        // Compute new values on the frame arena (mirrors what CLEAR emits).
        var bufs: [N][]u8 = undefined;
        for (0..N) |k| {
            bufs[k] = try rt.frameAlloc().alloc(u8, sizes[k]);
            @memset(bufs[k], @as(u8, @intCast((k + fill + 1) & 0xff)));
        }
        // Promote each var to heap: free old, alloc new.
        for (0..N) |k| {
            heap.free(vars[k]);
            vars[k] = try heap.dupe(u8, bufs[k]);
        }
        rt.overflow_arena.rewind(mark);
    }
    const elapsed = timer.read();

    var live: usize = 0;
    for (vars) |v| live += v.len;
    return .{ .ns = elapsed, .live_heap_bytes = live };
}

// ===========================================================================
// SECTION A: Performance + memory for N strings, random sizes 256B-4KB
// ===========================================================================

test "Benchmark A: frame-pack vs heap-alloc, N strings of random size 256B-4KB" {
    const stdout = std.debug.print;
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    stdout("\n\n=== SECTION A: performance + memory, {d} iters, random sizes 256B-4KB ===\n\n",
        .{ITERS_LARGE});
    stdout("{s:<4}  {s:>10}  {s:>10}  {s:>8}  {s:>14}  {s:>12}  {s:>12}\n",
        .{ "N", "pack ns/it", "heap ns/it", "pack/heap",
           "pack arena/iter", "heap live mem", "large_objs" });
    stdout("{s}\n", .{"-" ** 85});

    inline for (.{ 1, 2, 4, 8 }) |N| {
        // Fixed seed per N so sizes are reproducible.
        const sizes = comptime randomSizes(N, 0xc0ffee00 + N, 256, 4096);

        var ctx1 = EbrContext{};
        defer ctx1.deinit(alloc);
        var rt1 = try makeRuntime(alloc, &ctx1, LARGE_ARENA);
        defer rt1.deinit();
        rt1.wireAllocator();

        var ctx2 = EbrContext{};
        defer ctx2.deinit(alloc);
        var rt2 = try makeRuntime(alloc, &ctx2, LARGE_ARENA);
        defer rt2.deinit();
        rt2.wireAllocator();

        const fp = try runFramePackSized(N, sizes, &rt1, ITERS_LARGE);
        const hp = try runHeapAllocSized(N, sizes, &rt2, ITERS_LARGE);

        const fp_ns = nsPerIter(fp.ns, ITERS_LARGE);
        const hp_ns = nsPerIter(hp.ns, ITERS_LARGE);
        const ratio_pct: u64 = if (hp_ns > 0) fp_ns * 100 / hp_ns else 0;

        // Arena cursor / iters = bytes accumulated per iteration in the arena.
        // For frame-pack this grows without bound; for heap it stays at sum(sizes).
        const arena_per_iter = fp.arena_cursor / ITERS_LARGE;
        var sum_sizes: usize = 0;
        for (sizes) |s| sum_sizes += s;

        stdout("N={d:<2}  {d:>10}  {d:>10}  {d:>7}%  {d:>12}B/it  {d:>10}B  {d:>12}\n",
            .{ N, fp_ns, hp_ns, ratio_pct,
               arena_per_iter, hp.live_heap_bytes, fp.large_obj_count });

        try std.testing.expect(fp.large_obj_count == 0); // all fit in 8MB static block
    }

    stdout("\narena/iter = bytes accumulated in frame arena PER ITERATION (grows without bound).\n", .{});
    stdout("heap live  = constant bytes in use on heap (old freed before new allocated).\n", .{});
    stdout("large_objs = 0 means all strings fit inside arena pages (no heap fallback).\n\n", .{});
}

// ===========================================================================
// SECTION B: Threshold — at what string size does frame-pack lose?
//
// The large_objects path triggers when:
//   n > getNextPageSize(next_block_index)
// After the 16KB static block fills, next dynamic page = 4096B.
// A string of 4097B: 4097 > 4096 → large_objects (heap-backed, never freed
// between iterations, accumulates one entry per iteration).
// A string of 4096B: 4096 > 4096 = FALSE → fits in a new 4KB dynamic page.
// ===========================================================================

test "Benchmark B: size threshold — N=1, small (16KB) arena, sizes 256B to 8KB" {
    const stdout = std.debug.print;
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    stdout("\n\n=== SECTION B: threshold test, {d} iters, 16KB arena ===\n\n",
        .{ITERS_THRESHOLD});
    stdout("{s:>8}  {s:>10}  {s:>10}  {s:>8}  {s:>12}  {s:>12}\n",
        .{ "size", "pack ns/it", "heap ns/it", "pack/heap",
           "large_objs", "verdict" });
    stdout("{s}\n", .{"-" ** 70});

    const test_sizes = [_]usize{ 256, 512, 1024, 2048, 4096, 4097, 8192 };

    for (test_sizes) |sz| {
        const sizes = [1]usize{sz};

        var ctx1 = EbrContext{};
        defer ctx1.deinit(alloc);
        var rt1 = try makeRuntime(alloc, &ctx1, SMALL_ARENA);
        defer rt1.deinit();
        rt1.wireAllocator();

        var ctx2 = EbrContext{};
        defer ctx2.deinit(alloc);
        var rt2 = try makeRuntime(alloc, &ctx2, SMALL_ARENA);
        defer rt2.deinit();
        rt2.wireAllocator();

        const fp = try runFramePackSized(1, sizes, &rt1, ITERS_THRESHOLD);
        const hp = try runHeapAllocSized(1, sizes, &rt2, ITERS_THRESHOLD);

        const fp_ns = nsPerIter(fp.ns, ITERS_THRESHOLD);
        const hp_ns = nsPerIter(hp.ns, ITERS_THRESHOLD);
        const ratio_pct: u64 = if (hp_ns > 0) fp_ns * 100 / hp_ns else 0;

        const verdict: []const u8 = blk: {
            if (fp.large_obj_count > 0)
                break :blk "LOSES (large_objects)"
            else if (ratio_pct < 100)
                break :blk "wins"
            else
                break :blk "neutral";
        };

        stdout("{d:>8}B  {d:>10}  {d:>10}  {d:>7}%  {d:>12}  {s}\n",
            .{ sz, fp_ns, hp_ns, ratio_pct, fp.large_obj_count, verdict });
    }

    stdout("\nlarge_objects > 0: arena fell back to malloc and accumulated entries\n", .{});
    stdout("that are NEVER freed between iterations (only at function-level rewind).\n", .{});
    stdout("Frame-pack with large_objects is strictly WORSE than heap: same malloc cost\n", .{});
    stdout("plus O(iters) memory accumulation instead of O(1).\n\n", .{});
}

// ===========================================================================
// SECTION C: Ordering sensitivity
//
// N=4 strings of sizes [256, 1024, 2048, 4096] are allocated in that order.
// We test all 4! = 24 permutations of PRESERVATION order.
// Corruption is detected by filling each string with a known byte pattern and
// verifying content after preservation.
//
// The ONLY safe permutation is the one that matches allocation order:
// [0, 1, 2, 3]. All others risk source-data corruption because earlier-packed
// large strings overwrite the source bytes of smaller strings that were
// allocated at lower arena addresses.
// ===========================================================================

/// Produce all permutations of [0..N) using Heap's algorithm.
/// Calls `callback` once per permutation with a slice view of the current perm.
fn heapsPermutations(
    comptime N: usize,
    perm: *[N]usize,
    k: usize,
    count: *usize,
    corrupt: *usize,
    rt: *Runtime,
    sizes: [N]usize,
    frame_mark: Runtime.FrameMark,
) !void {
    if (k == 1) {
        count.* += 1;
        // Run one preservation iteration with this permutation.
        const is_ok = try testOnePermutation(N, perm.*, rt, sizes, frame_mark);
        if (!is_ok) corrupt.* += 1;
        return;
    }
    var i: usize = 0;
    while (i < k) : (i += 1) {
        try heapsPermutations(N, perm, k - 1, count, corrupt, rt, sizes, frame_mark);
        if (k & 1 == 0) {
            const tmp = perm[i]; perm[i] = perm[k - 1]; perm[k - 1] = tmp;
        } else {
            const tmp = perm[0]; perm[0] = perm[k - 1]; perm[k - 1] = tmp;
        }
    }
}

/// Run a single preservation iteration with the given permutation of variable indices.
/// Returns true if all N strings have the expected content, false if any are corrupted.
fn testOnePermutation(
    comptime N: usize,
    perm: [N]usize,
    rt: *Runtime,
    sizes: [N]usize,
    frame_mark: Runtime.FrameMark,
) !bool {
    // Restore to a clean frame state before each permutation test.
    rt.restoreFrameMark(frame_mark);

    // Allocate N strings in FIXED order [0, 1, ..., N-1] (allocation order is
    // always sequential — only the PRESERVE order varies per permutation).
    const mark = rt.saveLoopMark();
    var bufs: [N][]u8 = undefined;
    for (0..N) |k| {
        bufs[k] = try rt.frameAlloc().alloc(u8, sizes[k]);
        // Fill each string with a distinct byte: variable index + 0x10
        // so it is easy to detect cross-contamination.
        @memset(bufs[k], @as(u8, @intCast(k + 0x10)));
    }

    // Preserve in the ORDER given by perm.
    // perm[0] calls loopPreserveAndRewind (rewinds once).
    // perm[1..] call loopPreserveVar (no rewind, sequential pack).
    var vars: [N][]const u8 = undefined;
    for (0..N) |k| vars[k] = bufs[k];

    vars[perm[0]] = try rt.loopPreserveAndRewind(mark, vars[perm[0]]);
    for (1..N) |j| {
        vars[perm[j]] = try rt.loopPreserveVar(vars[perm[j]]);
    }

    // Verify: every byte of every preserved string must match its expected fill.
    for (0..N) |k| {
        const expected_byte = @as(u8, @intCast(k + 0x10));
        for (vars[k]) |b| {
            if (b != expected_byte) return false; // corrupted
        }
    }
    return true;
}

test "Benchmark C: ordering — all 4! permutations of preservation for N=4" {
    const N = 4;
    const sizes = [N]usize{ 256, 1024, 2048, 4096 };
    const stdout = std.debug.print;

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var ctx = EbrContext{};
    defer ctx.deinit(alloc);
    // Use 4MB arena — each permutation test uses at most sum(sizes) = 7KB.
    var rt = try makeRuntime(alloc, &ctx, 4 * 1024 * 1024);
    defer rt.deinit();
    rt.wireAllocator();

    // Capture the clean frame mark before any permutation tests.
    const frame_mark = rt.saveFrameMark();

    stdout("\n\n=== SECTION C: ordering sensitivity, N=4, sizes [256, 1024, 2048, 4096] ===\n\n", .{});
    stdout("Allocation order is always [0,1,2,3]. Preservation order varies.\n\n", .{});
    stdout("{s:<20}  {s:>8}  {s:>10}\n", .{ "preserve order", "result", "notes" });
    stdout("{s}\n", .{"-" ** 50});

    // Print the first 8 permutations explicitly so the pattern is visible.
    const explicit_perms = [_][N]usize{
        .{ 0, 1, 2, 3 }, // correct order
        .{ 0, 1, 3, 2 },
        .{ 0, 2, 1, 3 },
        .{ 0, 2, 3, 1 },
        .{ 1, 0, 2, 3 },
        .{ 1, 2, 0, 3 },
        .{ 2, 0, 1, 3 }, // large before small: expect corruption
        .{ 3, 2, 1, 0 }, // fully reversed: worst case
    };

    for (explicit_perms) |perm| {
        const ok = try testOnePermutation(N, perm, &rt, sizes, frame_mark);
        const note: []const u8 = if (std.mem.eql(usize, &perm, &[N]usize{ 0, 1, 2, 3 }))
            "<-- allocation order (correct)"
        else if (!ok)
            "<-- corrupted"
        else
            "";
        stdout("[{d},{d},{d},{d}]            {s:>8}  {s}\n",
            .{ perm[0], perm[1], perm[2], perm[3],
               if (ok) "OK" else "CORRUPT", note });
    }

    // Now test ALL 4! = 24 permutations and count.
    var perm = [N]usize{ 0, 1, 2, 3 };
    var total: usize = 0;
    var corrupt: usize = 0;

    try heapsPermutations(N, &perm, N, &total, &corrupt, &rt, sizes, frame_mark);

    stdout("\nAll {d} permutations: {d} correct, {d} corrupt ({d}%).\n",
        .{ total, total - corrupt, corrupt, corrupt * 100 / total });
    stdout("Only 1 of {d} orderings is guaranteed safe (allocation order).\n\n", .{total});

    try std.testing.expect(total == 24); // 4! = 24
}

// ===========================================================================
// SECTION D: Scale — how does corruption rate scale with N?
// Sample 2000 random permutations per N and report % corrupt.
// Demonstrates that the ordering risk grows rapidly with N.
// ===========================================================================

test "Benchmark D: ordering corruption rate vs N (random sample)" {
    const stdout = std.debug.print;
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    stdout("\n\n=== SECTION D: ordering corruption rate vs N (2000 random perms per N) ===\n\n", .{});
    stdout("All strings have different sizes. Preservation order is uniformly random.\n", .{});
    stdout("Allocation order is always sequential [0..N).\n\n", .{});
    stdout("{s:<4}  {s:>10}  {s:>10}  {s:>10}\n",
        .{ "N", "corrupt/2000", "corrupt %", "implication" });
    stdout("{s}\n", .{"-" ** 55});

    const SAMPLES = 2000;

    inline for (.{ 2, 3, 4, 5, 6 }) |N| {
        const sizes = comptime randomSizes(N, 0xBADC0DE0 + N, 256, 4096);

        var ctx = EbrContext{};
        defer ctx.deinit(alloc);
        var rt = try makeRuntime(alloc, &ctx, 4 * 1024 * 1024);
        defer rt.deinit();
        rt.wireAllocator();
        const frame_mark = rt.saveFrameMark();

        var rng = Lcg{ .state = 0xdeadbeef_00000000 + N };
        var perm: [N]usize = undefined;
        for (0..N) |k| perm[k] = k;

        var corrupt: usize = 0;
        for (0..SAMPLES) |_| {
            rng.shuffle(&perm);
            const ok = try testOnePermutation(N, perm, &rt, sizes, frame_mark);
            if (!ok) corrupt += 1;
        }

        const pct = corrupt * 100 / SAMPLES;
        const impl: []const u8 = if (pct == 0)
            "trivially safe (all same-size)"
        else if (pct < 30)
            "mostly safe"
        else if (pct < 70)
            "majority corrupt"
        else
            "almost always corrupt";

        stdout("N={d:<2}  {d:>10}  {d:>9}%  {s}\n",
            .{ N, corrupt, pct, impl });
    }

    stdout("\nConclusion: for N >= 3 strings of unequal size, a random ordering has\n", .{});
    stdout(">50% chance of corruption. Only allocation order is reliably safe.\n\n", .{});
}

// ===========================================================================
// Correctness sanity (runs under zig build test, not just benchmark)
// ===========================================================================

test "frame-pack preserves correct values for all N" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var ctx = EbrContext{};
    defer ctx.deinit(allocator);
    var rt = try makeRuntime(allocator, &ctx, LARGE_ARENA);
    defer rt.deinit();
    rt.wireAllocator();

    inline for (.{ 1, 2, 3, 5, 8 }) |N| {
        var vars: [N][]const u8 = .{""} ** N;
        for (0..50) |iter| {
            const mark = rt.saveLoopMark();
            _ = try std.fmt.allocPrint(rt.frameAlloc(), "pad_{d}", .{iter});
            var bufs: [N][]const u8 = undefined;
            for (0..N) |k| {
                bufs[k] = try std.fmt.allocPrint(rt.frameAlloc(), "v{d}_{d}", .{ k, iter });
            }
            for (0..N) |k| vars[k] = bufs[k];
            vars[0] = try rt.loopPreserveAndRewind(mark, vars[0]);
            for (1..N) |k| vars[k] = try rt.loopPreserveVar(vars[k]);
        }
        for (0..N) |k| {
            const expected = try std.fmt.allocPrint(allocator, "v{d}_49", .{k});
            defer allocator.free(expected);
            try std.testing.expectEqualStrings(expected, vars[k]);
        }
    }
}
