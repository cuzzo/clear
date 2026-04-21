//! freeze_bench.zig -- Measure cache-locality speedup from freezing a BST.
//!
//! The benchmark builds a balanced binary search tree with individually
//! heap-allocated nodes (scattered across RAM).  It then freezes the tree into
//! a single contiguous buffer (DFS pre-order layout) and compares traversal
//! time before and after.
//!
//! Expected result:
//!   Small trees  (N <= 50K)  : ~1–2x  (data fits in L3 either way)
//!   Large trees  (N >= 500K) : ~3–8x  (scattered tree chases pointers across RAM;
//!                                       frozen tree is sequential → prefetcher wins)
//!
//! Run: zig test zig/experimental/freeze_bench.zig --test-filter bench

const std = @import("std");
const compat = @import("compat");
const freeze_mod = @import("freeze.zig");

const Timer = compat.Timer;

// ─────────────────────────────────────────────────────────────────────────────
// Data type
// ─────────────────────────────────────────────────────────────────────────────

/// Binary search tree node.  key is a 14-byte heap-allocated string:
/// "node_XXXXXXXXX" (14 chars).  Each node is a separate alloc.create().
const Node = struct {
    key: []const u8,
    value: i64,
    left: ?*Node,
    right: ?*Node,
};

// ─────────────────────────────────────────────────────────────────────────────
// Tree construction / destruction
// ─────────────────────────────────────────────────────────────────────────────

fn buildBalanced(alloc: std.mem.Allocator, n: usize, base: i64) !*Node {
    std.debug.assert(n > 0);
    const mid = n / 2;
    const node = try alloc.create(Node);
    const v = base + @as(i64, @intCast(mid));
    node.* = .{
        .key   = try std.fmt.allocPrint(alloc, "node_{d:09}", .{v}),
        .value = v,
        .left  = if (mid > 0)     try buildBalanced(alloc, mid,       base)      else null,
        .right = if (n - mid - 1 > 0) try buildBalanced(alloc, n-mid-1, base+@as(i64,@intCast(mid))+1) else null,
    };
    return node;
}

fn destroyTree(alloc: std.mem.Allocator, n: ?*Node) void {
    const node = n orelse return;
    destroyTree(alloc, node.left);
    destroyTree(alloc, node.right);
    alloc.free(node.key);
    alloc.destroy(node);
}

// ─────────────────────────────────────────────────────────────────────────────
// Workload: sum all values (pointer-chasing traversal)
// ─────────────────────────────────────────────────────────────────────────────

fn sumValues(n: ?*const Node) i64 {
    const node = n orelse return 0;
    return node.value + sumValues(node.left) + sumValues(node.right);
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

fn nsPerOp(total_ns: u64, iters: usize) u64 {
    return total_ns / @as(u64, @intCast(iters));
}

fn formatBytes(bytes: usize, buf: []u8) []const u8 {
    if (bytes >= 1024 * 1024)
        return std.fmt.bufPrint(buf, "{d:.1}MB", .{@as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0)}) catch "?";
    if (bytes >= 1024)
        return std.fmt.bufPrint(buf, "{d:.1}KB", .{@as(f64, @floatFromInt(bytes)) / 1024.0}) catch "?";
    return std.fmt.bufPrint(buf, "{d}B", .{bytes}) catch "?";
}

// ─────────────────────────────────────────────────────────────────────────────
// Benchmark
// ─────────────────────────────────────────────────────────────────────────────

test "bench: freeze BST traversal speedup" {
    const out = std.debug.print;

    // c_allocator gives realistic fragmentation (same as CLEAR's runtime heap).
    // Use c_allocator for realistic heap fragmentation (same as CLEAR's runtime).
    const alloc = std.heap.c_allocator;

    // How many traversals to time.
    // Small N: more iters for stable timing.  Large N: fewer to keep wall time sane.
    const sizes = [_]struct { n: usize, iters: usize }{
        .{ .n = 10_000,     .iters = 500  },
        .{ .n = 100_000,    .iters = 100  },
        .{ .n = 500_000,    .iters = 20   },
        .{ .n = 1_000_000,  .iters = 10   },
    };

    out("\n\n=== freeze: BST sum-traversal benchmark ===\n", .{});
    out("Layout: each node = heap alloc (scattered) vs DFS-packed single buffer (frozen)\n\n", .{});
    out("{s:>10}  {s:>12}  {s:>12}  {s:>12}  {s:>10}  {s:>12}\n",
        .{ "N", "scattered", "frozen", "freeze cost", "speedup", "buf size" });
    out("{s}\n", .{"-" ** 75});

    for (sizes) |cfg| {
        const n = cfg.n;
        const ITERS = cfg.iters;

        // ── Build scattered tree ──────────────────────────────────────────
        const root = try buildBalanced(alloc, n, 0);
        defer destroyTree(alloc, root);

        // ── Benchmark scattered traversal ─────────────────────────────────
        // One warmup pass so instruction cache is hot for both variants.
        var anti_dce: i64 = 0;
        anti_dce +%= sumValues(root);

        var timer = try Timer.start();
        for (0..ITERS) |_| anti_dce +%= sumValues(root);
        const scattered_ns = nsPerOp(timer.read(), ITERS);

        // ── Freeze ────────────────────────────────────────────────────────
        timer.reset();
        const frozen = try freeze_mod.freeze(Node, alloc, root);
        const freeze_us = timer.read() / 1000;
        defer frozen.deinit(alloc);

        // ── Benchmark frozen traversal ────────────────────────────────────
        anti_dce +%= sumValues(frozen.root());  // warmup

        timer.reset();
        for (0..ITERS) |_| anti_dce +%= sumValues(frozen.root());
        const frozen_ns = nsPerOp(timer.read(), ITERS);

        // Anti-DCE sink
        const sink: *volatile i64 = @ptrCast(&anti_dce);
        sink.* = anti_dce;

        const speedup_x10 = if (frozen_ns > 0) scattered_ns * 10 / frozen_ns else 0;
        const buf_size = frozen._buf.len;

        var size_buf: [16]u8 = undefined;
        out("{d:>10}  {d:>9}ns/t  {d:>9}ns/t  {d:>9}µs    {d}.{d}x  {s:>12}\n",
            .{
                n,
                scattered_ns,
                frozen_ns,
                freeze_us,
                speedup_x10 / 10,
                speedup_x10 % 10,
                formatBytes(buf_size, &size_buf),
            });
    }

    out("\n", .{});
    out("scattered = pointer-chasing through individually malloc'd nodes\n", .{});
    out("frozen    = single alloc, DFS pre-order, all pointers intra-buffer\n", .{});
    out("freeze cost = one-time compaction (amortized over any read-heavy workload)\n", .{});
    out("\n", .{});
}

// ─────────────────────────────────────────────────────────────────────────────
// Quick correctness check (runs under `zig build test`, not just bench)
// ─────────────────────────────────────────────────────────────────────────────

test "freeze bench: frozen sum matches scattered sum" {
    // Use c_allocator for realistic heap fragmentation (same as CLEAR's runtime).
    const alloc = std.heap.c_allocator;
    const N = 1023; // 10 balanced levels
    const root = try buildBalanced(alloc, N, 0);
    defer destroyTree(alloc, root);

    const expected = sumValues(root);

    const frozen = try freeze_mod.freeze(Node, alloc, root);
    defer frozen.deinit(alloc);

    const got = sumValues(frozen.root());
    try std.testing.expectEqual(expected, got);
}

// ─────────────────────────────────────────────────────────────────────────────
// Linked-list helpers for cycle-detection benchmarks
// ─────────────────────────────────────────────────────────────────────────────

// ListNode is a recursive type: isRecursive(ListNode) == true.
// NOTE: recursive traversal depth = chain length.  Keep chains short (≤2000)
// to avoid stack overflow.  BST benchmarks are safe at any N because tree
// depth is O(log N).
const ListNode = struct { val: i64, next: ?*ListNode };

// ─────────────────────────────────────────────────────────────────────────────
// Benchmark: cycle-detection overhead on valid acyclic graphs
// ─────────────────────────────────────────────────────────────────────────────

test "bench: cycle-detection overhead on acyclic recursive trees" {
    const out = std.debug.print;
    const alloc = std.heap.c_allocator;

    const sizes = [_]struct { n: usize, iters: usize }{
        .{ .n = 10_000,    .iters = 100 },
        .{ .n = 100_000,   .iters = 20  },
        .{ .n = 500_000,   .iters = 5   },
        .{ .n = 1_000_000, .iters = 3   },
    };

    out("\n\n=== freeze: cycle-detection overhead (acyclic BST, recursive Node type) ===\n", .{});
    out("Node is recursive (?*Node fields) so in-progress set is active for all sizes.\n\n", .{});
    out("{s:>10}  {s:>12}  {s:>12}  {s:>12}  {s:>10}\n",
        .{ "N", "scattered", "frozen", "freeze_cost", "speedup" });
    out("{s}\n", .{"-" ** 65});

    for (sizes) |cfg| {
        const root = try buildBalanced(alloc, cfg.n, 0);
        defer destroyTree(alloc, root);

        var anti_dce: i64 = 0;
        anti_dce +%= sumValues(root);

        var timer = try Timer.start();
        for (0..cfg.iters) |_| anti_dce +%= sumValues(root);
        const scattered_ns = nsPerOp(timer.read(), cfg.iters);

        timer.reset();
        const frozen = try freeze_mod.freeze(Node, alloc, root);
        const freeze_us = timer.read() / 1000;
        defer frozen.deinit(alloc);

        anti_dce +%= sumValues(frozen.root());
        timer.reset();
        for (0..cfg.iters) |_| anti_dce +%= sumValues(frozen.root());
        const frozen_ns = nsPerOp(timer.read(), cfg.iters);

        const sink: *volatile i64 = @ptrCast(&anti_dce);
        sink.* = anti_dce;

        const speedup_x10 = if (frozen_ns > 0) scattered_ns * 10 / frozen_ns else 0;
        out("{d:>10}  {d:>9}ns/t  {d:>9}ns/t  {d:>9}µs    {d}.{d}x\n", .{
            cfg.n, scattered_ns, frozen_ns, freeze_us,
            speedup_x10 / 10, speedup_x10 % 10,
        });
    }
    out("\n(freeze cost now includes DFS in-progress set for cycle detection)\n\n", .{});
}

// ─────────────────────────────────────────────────────────────────────────────
// Benchmark: cycle detection time vs cycle position
// ─────────────────────────────────────────────────────────────────────────────

test "bench: cycle detection time vs cycle position" {
    const out = std.debug.print;
    const alloc = std.heap.c_allocator;

    // Chain length capped at 2000: recursive traversal depth = chain length,
    // so long chains overflow the stack.  BST benches (O(log N) depth) are
    // safe at any N; linked-list benches are not.
    const CHAIN_LEN: usize = 2_000;
    const ITERS: usize = 20_000;

    const Scenario = struct { label: []const u8, cycle_at: usize };
    const scenarios = [_]Scenario{
        .{ .label = "depth=1   (immediate)",  .cycle_at = 1          },
        .{ .label = "depth=10  (very early)", .cycle_at = 10         },
        .{ .label = "depth=1%  (200)",        .cycle_at = CHAIN_LEN / 100 },
        .{ .label = "depth=10% (200)",        .cycle_at = CHAIN_LEN / 10  },
        .{ .label = "depth=50% (1000)",       .cycle_at = CHAIN_LEN / 2   },
        .{ .label = "depth=99% (1980)",       .cycle_at = CHAIN_LEN * 99 / 100 },
        .{ .label = "no cycle  (acyclic)",    .cycle_at = 0          },  // 0 = no cycle
    };

    const nodes = try alloc.alloc(ListNode, CHAIN_LEN);
    defer alloc.free(nodes);

    out("\n=== freeze: cycle detection time vs cycle depth  (chain N={d}, {d} iters) ===\n",
        .{ CHAIN_LEN, ITERS });
    out("{s:<30}  {s:>12}  {s}\n", .{ "scenario", "avg_time", "result" });
    out("{s}\n", .{"-" ** 58});

    for (scenarios) |s| {
        const is_acyclic = (s.cycle_at == 0);
        var total_ns: u64 = 0;

        for (0..ITERS) |_| {
            for (0..CHAIN_LEN) |i|
                nodes[i] = .{ .val = @intCast(i), .next = if (i + 1 < CHAIN_LEN) &nodes[i + 1] else null };
            if (!is_acyclic) nodes[s.cycle_at - 1].next = &nodes[0];

            var timer = try Timer.start();
            const result = freeze_mod.freeze(ListNode, alloc, &nodes[0]);
            total_ns += timer.read();

            // Consume result either way (free on success, discard error).
            if (result) |f| f.deinit(alloc) else |_| {}
        }

        const avg_ns = total_ns / ITERS;
        const res_str: []const u8 = if (is_acyclic) "ok (Frozen)" else "error.Cycle";
        out("{s:<30}  {d:>9}ns/op  {s}\n", .{ s.label, avg_ns, res_str });
    }
    out("\n", .{});
}
