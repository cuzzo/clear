//! freeze_bench.zig -- Measure cache-locality speedup from freezing a BST.
//!
//! Run: zig test zig/experimental/freeze_bench.zig --test-filter bench

const std = @import("std");
const freeze_mod = @import("freeze.zig");
const Timer = struct {
    start_ns: u64,
    pub fn start() error{}!@This() { return .{ .start_ns = nanoNow() }; }
    pub fn read(self: *@This()) u64 { return nanoNow() - self.start_ns; }
    pub fn reset(self: *@This()) void { self.start_ns = nanoNow(); }
    fn nanoNow() u64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Data types
// ─────────────────────────────────────────────────────────────────────────────

const Node = struct {
    key: []const u8,
    value: i64,
    left: ?*Node,
    right: ?*Node,
};

// Recursive linked-list node for cycle benchmarks.
// NOTE: keep chain lengths <= 2000 — traversal is recursive and will stack-
// overflow at larger depths.
const ListNode = struct { val: i64, next: ?*ListNode };

// ─────────────────────────────────────────────────────────────────────────────
// Tree / list helpers
// ─────────────────────────────────────────────────────────────────────────────

fn buildBalanced(alloc: std.mem.Allocator, n: usize, base: i64) !*Node {
    std.debug.assert(n > 0);
    const mid = n / 2;
    const node = try alloc.create(Node);
    const v = base + @as(i64, @intCast(mid));
    node.* = .{
        .key   = try std.fmt.allocPrint(alloc, "node_{d:09}", .{v}),
        .value = v,
        .left  = if (mid > 0)             try buildBalanced(alloc, mid, base) else null,
        .right = if (n - mid - 1 > 0)     try buildBalanced(alloc, n - mid - 1, base + @as(i64, @intCast(mid)) + 1) else null,
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

fn sumValues(n: ?*const Node) i64 {
    const node = n orelse return 0;
    return node.value + sumValues(node.left) + sumValues(node.right);
}

// Sum `steps` values following next pointers; handles cycles.
fn sumList(start: ?*const ListNode, steps: usize) i64 {
    var acc: i64 = 0;
    var cur = start;
    var i: usize = 0;
    while (cur != null and i < steps) : (i += 1) {
        acc += cur.?.val;
        cur = cur.?.next;
    }
    return acc;
}

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
// Benchmark 1: scattered vs frozen BST traversal
// ─────────────────────────────────────────────────────────────────────────────

test "bench: freeze BST traversal speedup" {
    const out = std.debug.print;
    const alloc = std.heap.c_allocator;

    const sizes = [_]struct { n: usize, iters: usize }{
        .{ .n = 10_000,    .iters = 500 },
        .{ .n = 100_000,   .iters = 100 },
        .{ .n = 500_000,   .iters = 20  },
        .{ .n = 1_000_000, .iters = 10  },
    };

    out("\n\n=== freeze: BST sum-traversal benchmark ===\n", .{});
    out("scattered = individually malloc'd nodes  |  frozen = single DFS-packed buffer\n\n", .{});
    out("{s:>10}  {s:>12}  {s:>12}  {s:>12}  {s:>10}  {s:>12}\n",
        .{ "N", "scattered", "frozen", "freeze cost", "speedup", "buf size" });
    out("{s}\n", .{"-" ** 78});

    for (sizes) |cfg| {
        const root = try buildBalanced(alloc, cfg.n, 0);
        defer destroyTree(alloc, root);

        var anti_dce: i64 = 0;
        anti_dce +%= sumValues(root); // warmup

        var timer = try Timer.start();
        for (0..cfg.iters) |_| anti_dce +%= sumValues(root);
        const scattered_ns = nsPerOp(timer.read(), cfg.iters);

        timer.reset();
        const frozen = try freeze_mod.freeze(Node, alloc, root);
        const freeze_us = timer.read() / 1000;
        defer frozen.deinit(alloc);

        anti_dce +%= sumValues(frozen._root); // warmup
        timer.reset();
        for (0..cfg.iters) |_| anti_dce +%= sumValues(frozen._root);
        const frozen_ns = nsPerOp(timer.read(), cfg.iters);

        const sink: *volatile i64 = @ptrCast(&anti_dce);
        sink.* = anti_dce;

        const speedup_x10 = if (frozen_ns > 0) scattered_ns * 10 / frozen_ns else 0;
        var size_buf: [16]u8 = undefined;
        out("{d:>10}  {d:>9}ns/t  {d:>9}ns/t  {d:>9}µs    {d}.{d}x  {s:>12}\n", .{
            cfg.n, scattered_ns, frozen_ns, freeze_us,
            speedup_x10 / 10, speedup_x10 % 10,
            formatBytes(frozen._buf.len, &size_buf),
        });
    }
    out("\n", .{});
}

// ─────────────────────────────────────────────────────────────────────────────
// Benchmark 2: cyclic linked list — scattered vs frozen traversal
//
// Each LabelNode owns a heap-allocated label string, so building a chain of N
// nodes requires 2N allocs interleaved across the heap.  Sequential traversal
// (0→1→…→N-1→0) chases pointers into cache-cold memory.  After freeze the
// entire graph — nodes + strings — lives in one contiguous buffer, so the same
// traversal is a warm sequential scan.
//
// freeze() uses recursive DFS, so for large N we run it in a thread with a
// big stack (512 MB covers up to ~500K nodes at ~300 B/frame).
// ─────────────────────────────────────────────────────────────────────────────

// Linked-list node with a heap-allocated label to force real heap scatter.
const LabelNode = struct { val: i64, label: []const u8, next: ?*@This() };

fn sumLabelList(start: ?*const LabelNode, steps: usize) i64 {
    var acc: i64 = 0;
    var cur = start;
    var i: usize = 0;
    while (cur != null and i < steps) : (i += 1) {
        acc += cur.?.val + @as(i64, @intCast(cur.?.label.len));
        cur = cur.?.next;
    }
    return acc;
}

const CyclicBenchResult = struct {
    scattered_ns: u64 = 0,
    frozen_ns: u64 = 0,
    freeze_us: u64 = 0,
    buf_len: usize = 0,
    err: ?anyerror = null,
};

const CyclicBenchArgs = struct {
    alloc: std.mem.Allocator,
    n: usize,
    iters: usize,
    result: CyclicBenchResult = .{},
};

fn runCyclicBench(args: *CyclicBenchArgs) void {
    runCyclicBenchImpl(args) catch |e| { args.result.err = e; };
}

fn runCyclicBenchImpl(args: *CyclicBenchArgs) !void {
    const alloc = args.alloc;
    const n     = args.n;
    const iters = args.iters;

    // ── Build scattered cyclic chain ─────────────────────────────────────────
    // Each node is a separate alloc.create(); each label is a separate alloc.dupe().
    // Two interleaved allocations per node → real heap fragmentation.
    const ptrs = try alloc.alloc(*LabelNode, n);
    defer alloc.free(ptrs);

    var label_buf: [32]u8 = undefined;
    for (0..n) |i| {
        ptrs[i] = try alloc.create(LabelNode);
        const label = try alloc.dupe(u8, std.fmt.bufPrint(&label_buf, "node_{d:07}", .{i}) catch unreachable);
        ptrs[i].* = .{ .val = @intCast(i), .label = label, .next = null };
    }
    // Link into cycle: 0→1→2→…→n-1→0
    for (0..n) |i| ptrs[i].next = ptrs[(i + 1) % n];

    defer {
        for (ptrs) |p| {
            alloc.free(p.label);
            alloc.destroy(p);
        }
    }

    // ── Scattered traversal ───────────────────────────────────────────────────
    var anti_dce: i64 = 0;
    anti_dce +%= sumLabelList(ptrs[0], n);

    var timer = try Timer.start();
    for (0..iters) |_| anti_dce +%= sumLabelList(ptrs[0], n);
    args.result.scattered_ns = nsPerOp(timer.read(), iters);

    // ── Freeze (cycles supported; runs in this large-stack thread) ────────────
    timer.reset();
    const frozen = try freeze_mod.freeze(LabelNode, alloc, ptrs[0]);
    args.result.freeze_us = timer.read() / 1000;
    args.result.buf_len    = frozen._buf.len;
    defer frozen.deinit(alloc);

    // Sanity: after n steps the cycle wraps back to root.
    var cur: ?*const LabelNode = frozen._root;
    for (0..n) |_| cur = cur.?.next;
    std.debug.assert(cur.? == frozen._root);

    // ── Frozen traversal ──────────────────────────────────────────────────────
    anti_dce +%= sumLabelList(frozen._root, n);

    timer.reset();
    for (0..iters) |_| anti_dce +%= sumLabelList(frozen._root, n);
    args.result.frozen_ns = nsPerOp(timer.read(), iters);

    const sink: *volatile i64 = @ptrCast(&anti_dce);
    sink.* = anti_dce;
}

test "bench: cyclic linked list (scattered allocs) — scattered vs frozen traversal" {
    const out = std.debug.print;

    const sizes = [_]struct { n: usize, iters: usize }{
        .{ .n = 10_000,  .iters = 2_000 },
        .{ .n = 50_000,  .iters = 500   },
        .{ .n = 100_000, .iters = 200   },
        .{ .n = 500_000, .iters = 50    },
    };

    out("\n\n=== freeze: cyclic linked list — scattered allocs vs frozen  ===\n", .{});
    out("Each node: alloc.create(LabelNode) + alloc.dupe(label) → 2 allocs, real scatter.\n", .{});
    out("Cycle: node[n-1].next = node[0].  freeze() runs in 512MB-stack thread.\n\n", .{});
    out("{s:>10}  {s:>12}  {s:>12}  {s:>12}  {s:>10}  {s:>12}\n",
        .{ "N", "scattered", "frozen", "freeze cost", "speedup", "buf size" });
    out("{s}\n", .{"-" ** 78});

    for (sizes) |cfg| {
        var args = CyclicBenchArgs{
            .alloc = std.heap.c_allocator,
            .n     = cfg.n,
            .iters = cfg.iters,
        };
        // Run in a 512MB-stack thread: freeze() DFS depth = N frames.
        const t = try std.Thread.spawn(.{ .stack_size = 512 * 1024 * 1024 }, runCyclicBench, .{&args});
        t.join();
        if (args.result.err) |e| return e;

        const r = args.result;
        const speedup_x10 = if (r.frozen_ns > 0) r.scattered_ns * 10 / r.frozen_ns else 0;
        var size_buf: [16]u8 = undefined;
        out("{d:>10}  {d:>9}ns/t  {d:>9}ns/t  {d:>9}µs    {d}.{d}x  {s:>12}\n", .{
            cfg.n, r.scattered_ns, r.frozen_ns, r.freeze_us,
            speedup_x10 / 10, speedup_x10 % 10,
            formatBytes(r.buf_len, &size_buf),
        });
    }
    out("\n", .{});
}

// ─────────────────────────────────────────────────────────────────────────────
// Benchmark 3: placement-map overhead (acyclic recursive type)
// ─────────────────────────────────────────────────────────────────────────────

test "bench: placement-map overhead on acyclic recursive trees" {
    const out = std.debug.print;
    const alloc = std.heap.c_allocator;

    const sizes = [_]struct { n: usize, iters: usize }{
        .{ .n = 10_000,    .iters = 100 },
        .{ .n = 100_000,   .iters = 20  },
        .{ .n = 500_000,   .iters = 5   },
        .{ .n = 1_000_000, .iters = 3   },
    };

    out("\n\n=== freeze: placement-map overhead (acyclic BST, recursive Node type) ===\n", .{});
    out("Node is recursive (?*Node fields) so placement map is active for all sizes.\n\n", .{});
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

        anti_dce +%= sumValues(frozen._root);
        timer.reset();
        for (0..cfg.iters) |_| anti_dce +%= sumValues(frozen._root);
        const frozen_ns = nsPerOp(timer.read(), cfg.iters);

        const sink: *volatile i64 = @ptrCast(&anti_dce);
        sink.* = anti_dce;

        const speedup_x10 = if (frozen_ns > 0) scattered_ns * 10 / frozen_ns else 0;
        out("{d:>10}  {d:>9}ns/t  {d:>9}ns/t  {d:>9}µs    {d}.{d}x\n", .{
            cfg.n, scattered_ns, frozen_ns, freeze_us,
            speedup_x10 / 10, speedup_x10 % 10,
        });
    }
    out("\n(freeze cost includes placement map HashMap for cycle support)\n\n", .{});
}

// ─────────────────────────────────────────────────────────────────────────────
// Benchmark 4: freeze time by cycle position (how early the cycle is)
// ─────────────────────────────────────────────────────────────────────────────

test "bench: freeze time by cycle position" {
    const out = std.debug.print;
    const alloc = std.heap.c_allocator;

    const CHAIN_LEN: usize = 2_000;
    const ITERS: usize = 20_000;

    const Scenario = struct { label: []const u8, cycle_at: usize };
    const scenarios = [_]Scenario{
        .{ .label = "depth=1   (immediate)",  .cycle_at = 1          },
        .{ .label = "depth=10  (very early)", .cycle_at = 10         },
        .{ .label = "depth=1%  (20)",         .cycle_at = CHAIN_LEN / 100 },
        .{ .label = "depth=10% (200)",        .cycle_at = CHAIN_LEN / 10  },
        .{ .label = "depth=50% (1000)",       .cycle_at = CHAIN_LEN / 2   },
        .{ .label = "depth=99% (1980)",       .cycle_at = CHAIN_LEN * 99 / 100 },
        .{ .label = "no cycle  (acyclic)",    .cycle_at = 0          },
    };

    const nodes = try alloc.alloc(ListNode, CHAIN_LEN);
    defer alloc.free(nodes);

    out("\n=== freeze: time by cycle position  (chain N={d}, {d} iters) ===\n",
        .{ CHAIN_LEN, ITERS });
    out("{s:<30}  {s:>12}  {s:>8}  {s}\n", .{ "scenario", "avg_time", "buf_size", "result" });
    out("{s}\n", .{"-" ** 68});

    for (scenarios) |s| {
        const is_acyclic = (s.cycle_at == 0);
        var total_ns: u64 = 0;
        var last_buf_len: usize = 0;

        for (0..ITERS) |_| {
            for (0..CHAIN_LEN) |i|
                nodes[i] = .{ .val = @intCast(i), .next = if (i + 1 < CHAIN_LEN) &nodes[i + 1] else null };
            if (!is_acyclic) nodes[s.cycle_at - 1].next = &nodes[0];

            var timer = try Timer.start();
            const frozen = try freeze_mod.freeze(ListNode, alloc, &nodes[0]);
            total_ns += timer.read();
            last_buf_len = frozen._buf.len;
            frozen.deinit(alloc);
        }

        const avg_ns = total_ns / ITERS;
        var size_buf: [16]u8 = undefined;
        const result_str: []const u8 = if (is_acyclic) "acyclic" else "cyclic (preserved)";
        out("{s:<30}  {d:>9}ns/op  {s:>8}  {s}\n", .{
            s.label, avg_ns, formatBytes(last_buf_len, &size_buf), result_str,
        });
    }
    out("\n", .{});
}

// ─────────────────────────────────────────────────────────────────────────────
// Correctness check
// ─────────────────────────────────────────────────────────────────────────────

test "freeze bench: frozen sum matches scattered sum" {
    const alloc = std.heap.c_allocator;
    const N = 1023;
    const root = try buildBalanced(alloc, N, 0);
    defer destroyTree(alloc, root);

    const expected = sumValues(root);
    const frozen = try freeze_mod.freeze(Node, alloc, root);
    defer frozen.deinit(alloc);

    try std.testing.expectEqual(expected, sumValues(frozen._root));
}
