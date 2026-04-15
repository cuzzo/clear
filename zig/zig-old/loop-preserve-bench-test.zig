// loop-preserve-bench-test.zig
//
// Benchmarks for frame arena loop preservation.
// Uses std.heap.c_allocator (raw malloc/free) for all heap comparisons.
// Run with jemalloc for production-realistic numbers:
//   LD_PRELOAD=/lib/x86_64-linux-gnu/libjemalloc.so.2 zig build benchmark
//
// Stage 1 — Allocation cost
//   Per-iteration cost of preserving N strings via the frame arena vs heap malloc+free.
//   Simulates a real loop body: each iteration allocates N strings in the frame,
//   then either preserves them (frame) or keeps the mallocs (heap).
//
//   N=1 uses loopPreserveAndRewind — the most common case (one carry-forward value
//   per iteration: last-seen key, accumulated result, etc.).
//   N>1 uses loopPreserveMulti — less common (key+value pairs, etc.).
//   For N>1, loopPreserveMulti pays a heap temp-alloc + two memcpy passes.
//   This benchmark reveals the crossover point where N>1 frame preserve costs
//   more than just using heap directly.
//
// Stage 2 — Access cost (common case)
//   Read latency of the preserved string, isolated from allocation cost.
//   Frame: preserved string always at mark address — same cache lines every iteration.
//   Heap:  malloc returns same address for same-size free/alloc (free-list reuse).
//   Both stay L1-hot in a tight loop. Frame has a structural advantage:
//   fixed address = more predictable prefetch, no allocator metadata nearby.

const std = @import("std");
const Runtime    = @import("runtime-header.zig").Runtime;
const EbrContext = @import("runtime-header.zig").EbrContext;

// All heap operations use raw malloc/free via libc.
// Run with LD_PRELOAD=libjemalloc.so.2 for jemalloc numbers.
const heap = std.heap.c_allocator;

fn stdout(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

// LCG — fast reproducible randomness without std.rand overhead
const Lcg = struct {
    state: u64,
    fn next(self: *Lcg) u64 {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        return self.state >> 33;
    }
};

// 4KB static frame — forces dynamic block spillage for strings >= ~100 bytes.
// Runtime uses heap (c_allocator) as its backing allocator — same as the heap baseline.
fn makeRuntime(ctx: *EbrContext) !Runtime {
    return Runtime.init(heap, 4 * 1024, ctx);
}

// Anti-DCE sink
var global_sink: u64 = 0;
fn sink(v: u64) void {
    const p: *volatile u64 = &global_sink;
    p.* ^= v;
}

// ===========================================================================
// Stage 1 — Allocation cost
// ===========================================================================

fn timeFramePreserveN(
    rt:       *Runtime,
    rng:      *Lcg,
    n:        usize,
    str_size: usize,
    iters:    usize,
) !u64 {
    var acc: u64 = 0xdeadbeef;
    var timer = try std.time.Timer.start();

    if (n == 1) {
        for (0..iters) |i| {
            const mark = rt.saveLoopMark();
            const raw = (rt.overflow_arena.alloc(str_size, 1, 0) orelse return error.OutOfMemory)[0..str_size];
            @memset(raw, @as(u8, @truncate(i ^ (rng.next() & 0xFF))));
            const kept = try rt.loopPreserveAndRewind(mark, raw);
            acc = acc *% 6364136223846793005 +% kept[0];
        }
    } else {
        var preserved_buf: [16][]const u8 = undefined;
        const preserved = preserved_buf[0..n];
        for (0..iters) |i| {
            const mark = rt.saveLoopMark();
            var srcs_buf: [16][]const u8 = undefined;
            for (0..n) |k| {
                const raw = (rt.overflow_arena.alloc(str_size, 1, 0) orelse return error.OutOfMemory)[0..str_size];
                @memset(raw, @as(u8, @truncate(i ^ k ^ (rng.next() & 0xFF))));
                srcs_buf[k] = raw;
            }
            try rt.loopPreserveMulti(mark, srcs_buf[0..n], preserved);
            acc = acc *% 6364136223846793005 +% preserved[0][0];
        }
    }

    const elapsed = timer.read();
    sink(acc);
    return elapsed / @as(u64, @intCast(iters));
}

fn timeHeapPreserveN(
    rng:      *Lcg,
    n:        usize,
    str_size: usize,
    iters:    usize,
) !u64 {
    var prev_buf: [16]?[]u8 = .{null} ** 16;
    const prev = prev_buf[0..n];
    var acc: u64 = 0xdeadbeef;
    var timer = try std.time.Timer.start();

    for (0..iters) |i| {
        for (0..n) |k| {
            if (prev[k]) |p| heap.free(p);
        }
        for (0..n) |k| {
            const buf = try heap.alloc(u8, str_size);
            @memset(buf, @as(u8, @truncate(i ^ k ^ (rng.next() & 0xFF))));
            prev[k] = buf;
            acc = acc *% 6364136223846793005 +% buf[0];
        }
    }

    const elapsed = timer.read();
    for (0..n) |k| { if (prev[k]) |p| heap.free(p); }
    sink(acc);
    return elapsed / @as(u64, @intCast(iters));
}

test "Benchmark: allocation cost — frame preserve vs heap malloc" {
    var ctx = EbrContext{};
    defer ctx.deinit(heap);
    var rt = try makeRuntime(&ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const ITERS: usize = 200_000;
    const preserve_ns = [_]usize{ 1, 2, 4, 8 };
    const sizes       = [_]usize{ 64, 512, 2048 };

    stdout("\n=== Stage 1: Allocation cost — frame preserve vs heap malloc ===\n", .{});
    stdout("Heap allocator: std.heap.c_allocator (malloc/free via libc).\n", .{});
    stdout("Run with LD_PRELOAD=libjemalloc.so.2 for jemalloc numbers.\n", .{});
    stdout("ITERS={d}. Each iter: alloc N strings + preserve (frame) or malloc N + free prev (heap).\n", .{ITERS});
    stdout("N=1 uses loopPreserveAndRewind. N>1 uses loopPreserveMulti (1 heap temp-alloc + 2x memcpy).\n\n", .{});
    stdout("{s:<18} {s:>6} {s:>12} {s:>12} {s:>10}\n",
        .{ "size", "N", "frame ns/it", "heap ns/it", "frame/heap" });
    stdout("{s}\n", .{"-" ** 62});

    for (sizes) |sz| {
        for (preserve_ns) |n| {
            var rng_f = Lcg{ .state = 0x1111 ^ sz ^ n };
            var rng_h = Lcg{ .state = 0x2222 ^ sz ^ n };
            const frame_ns = try timeFramePreserveN(&rt, &rng_f, n, sz, ITERS);
            const heap_ns  = try timeHeapPreserveN(&rng_h, n, sz, ITERS);
            const ratio    = frame_ns * 100 / @max(1, heap_ns);
            stdout("{d:<8}B         {d:>6} {d:>12} {d:>12} {d:>9}%\n",
                .{ sz, n, frame_ns, heap_ns, ratio });
        }
    }
    stdout("\n", .{});
    stdout("frame/heap < 100%: frame cheaper (bump alloc + no-op rewind vs malloc+free).\n", .{});
    stdout("frame/heap > 100%: loopPreserveMulti temp-alloc overhead exceeds heap cost.\n", .{});
}

// ===========================================================================
// Stage 2 — Access cost (read latency isolated from allocation)
// ===========================================================================
//
// Allocation and read phases are timed separately.
// The "read" phase touches every byte of the preserved string via hash chain.
// Frame: string always lands at the mark address — same cache lines every iteration.
// Heap:  free + malloc of same size; allocator typically reuses the same address.
// Both should be L1-hot in a tight loop.
// Frame structural advantage: fixed address = more predictable hardware prefetch.

test "Benchmark: access cost — preserved string read latency (frame vs heap)" {
    var ctx = EbrContext{};
    defer ctx.deinit(heap);
    var rt = try makeRuntime(&ctx);
    defer rt.deinit();
    rt.wireAllocator();

    const sizes_iters = [_]struct { size: usize, iters: usize }{
        .{ .size = 64,    .iters = 2_000_000 },
        .{ .size = 512,   .iters = 500_000   },
        .{ .size = 4096,  .iters = 100_000   },
        .{ .size = 32768, .iters = 20_000    },
    };

    stdout("\n=== Stage 2: Access cost — read latency (alloc phase excluded) ===\n", .{});
    stdout("Each iteration: [alloc+preserve NOT timed] -> [read every byte TIMED].\n", .{});
    stdout("Frame string always at mark address. Heap reuses same free'd address.\n\n", .{});
    stdout("{s:<16} {s:>10} {s:>14} {s:>14} {s:>10}\n",
        .{ "string size", "iters", "frame ns/iter", "heap ns/iter", "frame/heap" });
    stdout("{s}\n", .{"-" ** 66});

    for (sizes_iters) |entry| {
        const sz    = entry.size;
        const iters = entry.iters;
        _ = Lcg{ .state = 0xC0FFEE ^ sz }; // seed reserved for future filler randomization

        // --- Frame ---
        var frame_read_ns: u64 = 0;
        {
            const mark = rt.saveLoopMark();
            // Warm up: one preserve before timing.
            {
                const raw = (rt.overflow_arena.alloc(sz, 1, 0) orelse unreachable)[0..sz];
                @memset(raw, 0xAA);
                _ = try rt.loopPreserveAndRewind(mark, raw);
            }
            var acc: u64 = 0xdeadbeef;
            var timer = try std.time.Timer.start();
            for (0..iters) |i| {
                // Alloc + preserve (NOT under timer — reset timer each iter would be too slow;
                // instead we time the full loop then subtract a calibrated alloc cost below).
                // Simpler: time the read-only pass after a single preserve per iteration.
                const inner_mark = rt.saveLoopMark();
                const raw = (rt.overflow_arena.alloc(sz, 1, 0) orelse unreachable)[0..sz];
                @memset(raw, @as(u8, @truncate(i)));
                const kept = try rt.loopPreserveAndRewind(inner_mark, raw);
                _ = timer.lap(); // reset timer AFTER alloc+preserve
                for (kept) |b| acc = acc *% 6364136223846793005 +% b;
                frame_read_ns += timer.lap();
            }
            sink(acc);
        }

        // --- Heap ---
        var heap_read_ns: u64 = 0;
        {
            var prev: ?[]u8 = null;
            var acc: u64 = 0xdeadbeef;
            var timer = try std.time.Timer.start();
            for (0..iters) |i| {
                if (prev) |p| heap.free(p);
                const buf = try heap.alloc(u8, sz);
                @memset(buf, @as(u8, @truncate(i)));
                prev = buf;
                _ = timer.lap(); // reset timer AFTER alloc
                for (buf) |b| acc = acc *% 6364136223846793005 +% b;
                heap_read_ns += timer.lap();
            }
            if (prev) |p| heap.free(p);
            sink(acc);
        }

        const f_per = frame_read_ns / @as(u64, @intCast(iters));
        const h_per = heap_read_ns  / @as(u64, @intCast(iters));
        const ratio = (f_per + 1) * 100 / @max(1, h_per + 1);

        stdout("{d:<8}B       {d:>10} {d:>14} {d:>14} {d:>9}%\n",
            .{ sz, iters, f_per, h_per, ratio });
    }

    stdout("\n", .{});
    stdout("frame/heap < 100%: frame access faster (fixed address, hot prefetch).\n", .{});
    stdout("frame/heap ~ 100%: parity — allocator reuses same address, both L1-hot.\n", .{});
}
