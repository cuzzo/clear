// preserve-rewind-bench-test.zig
//
// Compares two strategies for preserving N outer mutable string variables
// across per-iteration frame arena rewinds in a CLEAR loop:
//
//   Frame-pack:  loopPreserveAndRewind (1x rewind) + loopPreserveVar (N-1x, no rewind)
//                Total work: 1 arena cursor reset + sum(len) bytes copied.
//
//   Heap-alloc:  N x heapAlloc.dupe + N x heapAlloc.free + 1 arena rewind
//                Total work: N malloc + N free + N copies + 1 cursor reset.
//
// The benchmark runs both strategies for N in {1, 2, 3, 5, 8} and reports
// ns/iter so the constant-factor difference is visible at each N.
//
// A "shuffled order" variant of frame-pack confirms that performance is O(N)
// regardless of which variable is selected as the first (rewind) operand.

const std = @import("std");
const Runtime = @import("runtime-header.zig").Runtime;
const EbrContext = @import("runtime-header.zig").EbrContext;

const ITERS = 200_000;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Create a Runtime with a 64KB frame arena.
/// Call rt.wireAllocator() in the CALLER after var rt = try makeRuntime(...).
fn makeRuntime(allocator: std.mem.Allocator, ctx: *EbrContext) !Runtime {
    return Runtime.init(allocator, 64 * 1024, ctx);
}

/// Simple LCG pseudo-random for shuffle (no std.rand import needed).
const Lcg = struct {
    state: u64,
    fn next(self: *Lcg) u64 {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        return self.state >> 33;
    }
    fn shuffle(self: *Lcg, arr: []usize) void {
        var i = arr.len;
        while (i > 1) {
            i -= 1;
            const j = self.next() % (i + 1);
            const tmp = arr[i];
            arr[i] = arr[j];
            arr[j] = tmp;
        }
    }
};

/// Prevent DCE: return the total byte-length of all preserved strings.
fn sumLens(comptime N: usize, vars: [N][]const u8) usize {
    var s: usize = 0;
    for (vars) |v| s += v.len;
    return s;
}

// ---------------------------------------------------------------------------
// Frame-pack benchmark (sequential, correct order = allocation order)
// ---------------------------------------------------------------------------

fn runFramePack(comptime N: usize, rt: *Runtime, iters: usize) !struct { ns: u64, anti_dce: usize } {
    var vars: [N][]const u8 = .{""} ** N;
    var anti_dce: usize = 0;

    var timer = try std.time.Timer.start();

    for (0..iters) |iter| {
        const mark = rt.saveLoopMark();

        // Per-iteration frame allocs (simulate realistic loop locals)
        _ = try std.fmt.allocPrint(rt.frameAlloc(), "tmp_{d}", .{iter & 0xfff});

        // Allocate N strings on the frame arena — one per outer var.
        // All strings have slightly varying lengths to stress the pack.
        var bufs: [N][]const u8 = undefined;
        for (0..N) |k| {
            bufs[k] = try std.fmt.allocPrint(rt.frameAlloc(), "var{d}_{d}", .{ k, iter & 0xffff });
        }
        for (0..N) |k| vars[k] = bufs[k];

        // Frame-pack: first var rewinds, rest sequentially pack behind it.
        vars[0] = try rt.loopPreserveAndRewind(mark, vars[0]);
        for (1..N) |k| {
            vars[k] = try rt.loopPreserveVar(vars[k]);
        }
    }

    const elapsed = timer.read();
    anti_dce = sumLens(N, vars);
    return .{ .ns = elapsed, .anti_dce = anti_dce };
}

// ---------------------------------------------------------------------------
// Frame-pack benchmark (shuffled order)
//
// Each iteration a fresh permutation of [0..N) is generated.
// Vars are ALLOCATED in that order, and PRESERVED in that same order —
// so allocation order == preservation order (correctness holds).
// The variable that happens to be first in the permutation calls
// loopPreserveAndRewind; the rest call loopPreserveVar.
//
// This proves that performance is invariant to which variable is "first":
// total work is always sum(len(vi)) bytes + 1 O(1) rewind.
// ---------------------------------------------------------------------------

fn runFramePackShuffled(comptime N: usize, rt: *Runtime, iters: usize, seed: u64) !struct { ns: u64, anti_dce: usize } {
    var vars: [N][]const u8 = .{""} ** N;
    var rng = Lcg{ .state = seed };
    var perm: [N]usize = undefined;
    for (0..N) |i| perm[i] = i;
    var anti_dce: usize = 0;

    var timer = try std.time.Timer.start();

    for (0..iters) |iter| {
        const mark = rt.saveLoopMark();

        _ = try std.fmt.allocPrint(rt.frameAlloc(), "tmp_{d}", .{iter & 0xfff});

        // Shuffle determines both allocation order AND preservation order.
        rng.shuffle(&perm);

        // Allocate in shuffled order.
        var bufs: [N][]const u8 = undefined;
        for (perm) |k| {
            bufs[k] = try std.fmt.allocPrint(rt.frameAlloc(), "var{d}_{d}", .{ k, iter & 0xffff });
        }
        for (0..N) |k| vars[k] = bufs[k];

        // Preserve in the same shuffled order (matches allocation order → correct).
        vars[perm[0]] = try rt.loopPreserveAndRewind(mark, vars[perm[0]]);
        for (1..N) |j| {
            vars[perm[j]] = try rt.loopPreserveVar(vars[perm[j]]);
        }
    }

    const elapsed = timer.read();
    anti_dce = sumLens(N, vars);
    return .{ .ns = elapsed, .anti_dce = anti_dce };
}

// ---------------------------------------------------------------------------
// Heap-alloc benchmark (naive: promote every outer var to heap each iteration)
// ---------------------------------------------------------------------------

fn runHeapAlloc(comptime N: usize, rt: *Runtime, iters: usize) !struct { ns: u64, anti_dce: usize } {
    const heap = rt.heapAlloc();

    // Start with heap-allocated outer vars (as CLEAR would in the heap-promotion path).
    var vars: [N][]u8 = undefined;
    for (0..N) |k| {
        vars[k] = try heap.dupe(u8, "init");
    }
    defer for (vars) |v| heap.free(v);

    var anti_dce: usize = 0;

    var timer = try std.time.Timer.start();

    for (0..iters) |iter| {
        const mark = rt.saveLoopMark();

        _ = try std.fmt.allocPrint(rt.frameAlloc(), "tmp_{d}", .{iter & 0xfff});

        // Compute new values on the frame arena, then promote to heap.
        var bufs: [N][]const u8 = undefined;
        for (0..N) |k| {
            bufs[k] = try std.fmt.allocPrint(rt.frameAlloc(), "var{d}_{d}", .{ k, iter & 0xffff });
        }

        // Heap-promote each var: free old, alloc new.
        for (0..N) |k| {
            heap.free(vars[k]);
            vars[k] = try heap.dupe(u8, bufs[k]);
        }

        // Rewind the frame arena (identical to what the runtime does).
        rt.overflow_arena.rewind(mark);
    }

    const elapsed = timer.read();
    anti_dce = 0;
    for (vars) |v| anti_dce += v.len;
    return .{ .ns = elapsed, .anti_dce = anti_dce };
}

// ---------------------------------------------------------------------------
// Report helper
// ---------------------------------------------------------------------------

fn nsPerIter(total_ns: u64, iters: usize) u64 {
    return total_ns / @as(u64, @intCast(iters));
}

// ---------------------------------------------------------------------------
// Test entry point
// ---------------------------------------------------------------------------

test "Benchmark: frame-pack vs heap-alloc for N outer string vars" {
    const stdout = std.debug.print;
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    stdout("\n\n=== preserve-and-rewind: frame-pack vs heap-alloc ({d} iters) ===\n\n",
        .{ITERS});
    stdout("{s:<6}  {s:>14}  {s:>14}  {s:>14}  {s:>10}  {s:>10}\n",
        .{ "N", "frame-pack", "frame-shuffled", "heap-alloc", "pack/heap", "shuf/heap" });
    stdout("{s}\n", .{"-" ** 80});

    // Run for each N value
    inline for (.{ 1, 2, 3, 5, 8 }) |N| {
        var ctx1 = EbrContext{};
        defer ctx1.deinit(allocator);
        var rt1 = try makeRuntime(allocator, &ctx1);
        rt1.wireAllocator();
        defer rt1.deinit();

        var ctx2 = EbrContext{};
        defer ctx2.deinit(allocator);
        var rt2 = try makeRuntime(allocator, &ctx2);
        rt2.wireAllocator();
        defer rt2.deinit();

        var ctx3 = EbrContext{};
        defer ctx3.deinit(allocator);
        var rt3 = try makeRuntime(allocator, &ctx3);
        rt3.wireAllocator();
        defer rt3.deinit();

        const fp  = try runFramePack(N, &rt1, ITERS);
        const fsh = try runFramePackShuffled(N, &rt2, ITERS, 0xdeadbeef_cafebabe);
        const hp  = try runHeapAlloc(N, &rt3, ITERS);

        const fp_ns  = nsPerIter(fp.ns,  ITERS);
        const fsh_ns = nsPerIter(fsh.ns, ITERS);
        const hp_ns  = nsPerIter(hp.ns,  ITERS);

        // Ratio as integer percentage (e.g. 42 = "42%")
        const pack_pct: u64 = if (hp_ns > 0) fp_ns  * 100 / hp_ns else 0;
        const shuf_pct: u64 = if (hp_ns > 0) fsh_ns * 100 / hp_ns else 0;

        stdout("N={d:<4}  {d:>12}ns  {d:>12}ns  {d:>12}ns  {d:>9}%  {d:>9}%\n",
            .{ N, fp_ns, fsh_ns, hp_ns, pack_pct, shuf_pct });

        // Sanity: anti-DCE sums must be non-zero
        try std.testing.expect(fp.anti_dce > 0);
        try std.testing.expect(fsh.anti_dce > 0);
        try std.testing.expect(hp.anti_dce > 0);
    }

    stdout("\npack/heap and shuf/heap < 100% = frame-pack faster than heap-alloc.\n", .{});
    stdout("shuf/heap ~= pack/heap confirms order does not affect performance.\n\n", .{});
}

// ---------------------------------------------------------------------------
// Correctness sanity test that runs under `zig build test` (not just benchmark)
// ---------------------------------------------------------------------------

test "frame-pack preserves correct values for all N" {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    var ctx = EbrContext{};
    defer ctx.deinit(allocator);
    var rt = try makeRuntime(allocator, &ctx);
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
        // After 50 iterations every var must hold its last-iteration value.
        for (0..N) |k| {
            const expected = try std.fmt.allocPrint(allocator, "v{d}_49", .{k});
            defer allocator.free(expected);
            try std.testing.expectEqualStrings(expected, vars[k]);
        }
    }
}
