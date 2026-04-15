// frame-cache-bench-test.zig
//
// Question: does the frame arena's block structure give better random-read
// cache performance than individually scattered heap allocations?
//
// The frame stores objects in contiguous blocks (each block is one allocation
// from the child allocator). Objects within a block share cache lines and TLB
// pages. Heap allocations are individually malloc'd and spread across the heap.
//
// Adversarial condition: random access across ALL blocks of the frame arena,
// not just the hot latest block. This is the worst case for the frame and the
// best case for proving its advantage over heap scatter.
//
// Three strategies compared:
//   Frame   - records allocated one at a time into the arena (multi-block)
//   Heap    - records allocated one at a time via malloc (scattered)
//   Contig  - records in one contiguous array (oracle, best possible layout)
//
// Expected behavior:
//   - Contig always wins (no block boundaries, best prefetcher behavior)
//   - Frame beats heap for small N (records fit in fewer, warmer blocks)
//   - Gap between frame and heap grows as N exceeds cache levels:
//     frame blocks are large contiguous regions; heap allocations are
//     individually scattered across many separate pages
//
// Frame arena block schedule (4KB static block in this benchmark):
//   static:     4KB
//   dynamic[0]: 4KB
//   dynamic[1]: 16KB
//   dynamic[2]: 64KB
//   dynamic[3+]: 256KB each

const std = @import("std");
const Runtime    = @import("runtime-header.zig").Runtime;
const EbrContext = @import("runtime-header.zig").EbrContext;

// 64 bytes = 1 cache line. tag at offset 0 so the read touches the line.
const Record = struct {
    tag: usize,
    pad: [56]u8,
};
comptime {
    std.debug.assert(@sizeOf(Record) == 64);
    std.debug.assert(@alignOf(Record) <= 8);
}

// LCG - reproducible shuffle without std.rand
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

// 4KB static block forces the frame to grow through many dynamic blocks quickly,
// maximizing the number of block boundaries in adversarial random-access tests.
const FRAME_STATIC_BYTES = 4 * 1024;

fn makeRuntime(alloc: std.mem.Allocator, ctx: *EbrContext) !Runtime {
    return Runtime.init(alloc, FRAME_STATIC_BYTES, ctx);
}

fn stdout(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

// ---------------------------------------------------------------------------
// Allocation helpers (all heap-allocated ptrs so large N doesn't stack overflow)
// ---------------------------------------------------------------------------

// Tag is derived from the record's own runtime address XOR'd with index.
// This prevents the compiler from computing sum = N*(N-1)/2 at compile time,
// which would allow it to elide the entire timing loop via DCE.
fn recordTag(ptr: *const Record, i: usize) usize {
    return (@intFromPtr(ptr) >> 4) ^ i;
}

fn allocFrameRecords(N: usize, rt: *Runtime, ptrs: []*Record) !void {
    const fa = rt.frameAlloc();
    for (0..N) |i| {
        const buf = try fa.alloc(u8, @sizeOf(Record));
        const r: *Record = @ptrCast(@alignCast(buf.ptr));
        r.tag = recordTag(r, i);
        @memset(&r.pad, @as(u8, @intCast(i & 0xff)));
        ptrs[i] = r;
    }
}

fn allocHeapScatter(N: usize, alloc: std.mem.Allocator, ptrs: []*Record) !void {
    for (0..N) |i| {
        ptrs[i] = try alloc.create(Record);
        ptrs[i].tag = recordTag(ptrs[i], i);
        @memset(&ptrs[i].pad, @as(u8, @intCast(i & 0xff)));
    }
}

fn freeHeapScatter(N: usize, alloc: std.mem.Allocator, ptrs: []*Record) void {
    for (0..N) |i| alloc.destroy(ptrs[i]);
}

// ---------------------------------------------------------------------------
// Timing kernels
//
// Uses a multiply-add hash chain: each iteration's result feeds the next
// iteration's mix. This creates a true data dependency so the compiler cannot
// hoist or eliminate the loop. The xorshift makes the chain opaque.
//
// The hash chain adds ~1 multiply + 1 xor per read on top of the load. At
// ReleaseFast this is ~0.3-0.5ns overhead vs the memory latency we're
// measuring (2-30ns), so the measurement is dominated by actual cache behavior.
// ---------------------------------------------------------------------------
fn timePointerReads(ptrs: []*Record, indices: []usize, inner_iters: usize) !u64 {
    var acc: usize = 0x123456789abcdef0;
    var timer = try std.time.Timer.start();
    for (0..inner_iters) |_| {
        for (indices) |idx| {
            acc = acc *% 6364136223846793005 +% ptrs[idx].tag;
        }
    }
    const elapsed = timer.read();
    const vp: *volatile usize = @ptrCast(&acc);
    vp.* = acc;
    return elapsed;
}

fn timeContiguousReads(arr: []Record, indices: []usize, inner_iters: usize) !u64 {
    var acc: usize = 0x123456789abcdef0;
    var timer = try std.time.Timer.start();
    for (0..inner_iters) |_| {
        for (indices) |idx| {
            acc = acc *% 6364136223846793005 +% arr[idx].tag;
        }
    }
    const elapsed = timer.read();
    const vp: *volatile usize = @ptrCast(&acc);
    vp.* = acc;
    return elapsed;
}

// ---------------------------------------------------------------------------
// Benchmark test
// ---------------------------------------------------------------------------
test "Benchmark: frame arena cache footprint vs heap scatter" {
    const alloc = std.testing.allocator;

    stdout("\n=== Frame arena cache footprint vs heap scatter ===\n\n", .{});
    stdout("Record size: 64 bytes (1 cache line). Access: uniformly random over all N.\n", .{});
    stdout("Frame: 4KB static block -> dynamic blocks 4KB/16KB/64KB/256KB...\n", .{});
    stdout("Heap: one malloc per record (scattered).\n", .{});
    stdout("Contig: one malloc for all N (oracle best-case layout).\n\n", .{});

    // Typical x86-64 cache sizes for reference
    stdout("Reference: L1=32KB, L2=256KB, L3=8MB (varies by CPU)\n\n", .{});

    stdout("{s:<12} {s:>7} {s:>13} {s:>13} {s:>14}  {s:>9} {s:>9}\n", .{
        "N (size)", "iters", "frame ns/rd", "heap ns/rd", "contig ns/rd", "heap/frm", "frm/cntg",
    });
    stdout("{s}\n", .{"-" ** 85});

    // Target ~20M total reads per N so timing is stable at all sizes even in
    // ReleaseFast mode. For large N (RAM-bound) this is ~60ms per approach.
    const TOTAL_READS: usize = 20_000_000;

    const test_sizes = [_]usize{ 256, 1024, 4096, 16384, 65536, 131072 };

    for (test_sizes) |N| {
        const inner_iters = @max(1, TOTAL_READS / N);

        // --- Allocate pointers buffers on heap (N can be large) ---
        const frame_ptrs = try alloc.alloc(*Record, N);
        defer alloc.free(frame_ptrs);
        const heap_ptrs = try alloc.alloc(*Record, N);
        defer alloc.free(heap_ptrs);
        const contig_arr = try alloc.alloc(Record, N);
        defer alloc.free(contig_arr);
        const indices = try alloc.alloc(usize, N);
        defer alloc.free(indices);

        // --- Fill contiguous array ---
        for (0..N) |i| {
            contig_arr[i].tag = recordTag(&contig_arr[i], i);
            @memset(&contig_arr[i].pad, @as(u8, @intCast(i & 0xff)));
        }

        // --- Frame arena setup ---
        var ctx_f = EbrContext{};
        defer ctx_f.deinit(alloc);
        var rt_f = try makeRuntime(alloc, &ctx_f);
        defer rt_f.deinit();
        rt_f.wireAllocator();
        try allocFrameRecords(N, &rt_f, frame_ptrs);

        // --- Heap scatter setup ---
        try allocHeapScatter(N, alloc, heap_ptrs);
        defer freeHeapScatter(N, alloc, heap_ptrs);

        // --- Build shuffled index array (same order for all three) ---
        for (0..N) |i| indices[i] = i;
        var rng = Lcg{ .state = 0xc0ffee00 ^ @as(u64, @intCast(N)) };
        rng.shuffle(indices);

        // --- First-touch all records (page fault elimination) ---
        for (0..N) |i| {
            _ = frame_ptrs[i].tag;
            _ = heap_ptrs[i].tag;
            _ = contig_arr[i].tag;
        }

        // --- Time each approach: warm in random order immediately before timing ---
        // Each approach's data may be evicted by the previous approach's timing loop,
        // so we re-warm in shuffled order (matching the timing access pattern) right
        // before each measurement.
        for (indices) |idx| _ = frame_ptrs[idx].tag;
        const frame_ns  = try timePointerReads(frame_ptrs, indices, inner_iters);

        for (indices) |idx| _ = heap_ptrs[idx].tag;
        const heap_ns   = try timePointerReads(heap_ptrs, indices, inner_iters);

        for (indices) |idx| _ = contig_arr[idx].tag;
        const contig_ns = try timeContiguousReads(contig_arr, indices, inner_iters);

        const total = N * inner_iters;
        const frame_per  = frame_ns  / @as(u64, @intCast(total));
        const heap_per   = heap_ns   / @as(u64, @intCast(total));
        const contig_per = contig_ns / @as(u64, @intCast(total));

        const heap_vs_frame = heap_per  * 100 / @max(1, frame_per);
        const frame_vs_contig = frame_per * 100 / @max(1, contig_per);

        const data_kb = N * @sizeOf(Record) / 1024;
        stdout("{d:<6}({d:>5}KB) {d:>7} {d:>13} {d:>13} {d:>14}  {d:>8}% {d:>8}%\n", .{
            N, data_kb, inner_iters,
            frame_per, heap_per, contig_per,
            heap_vs_frame, frame_vs_contig,
        });
    }

    stdout("\n", .{});
    stdout("heap/frm  > 100%: heap scatter slower than frame (expected)\n", .{});
    stdout("heap/frm  = 100%: no spatial locality benefit from frame blocks\n", .{});
    stdout("frm/cntg  = 100%: frame matches oracle (block boundaries not hurting)\n", .{});
    stdout("frm/cntg  > 100%: block boundaries adding latency vs contiguous layout\n", .{});
}
