const std = @import("std");
const safety = @import("safety");

// -------------------------------------------------------------------------
// 1. TRIVIAL: Fibonacci (Tight Loop Recursion)
// -------------------------------------------------------------------------

// A. Baseline (No Guard)
fn fibNoGuard(n: usize) usize {
    if (n <= 1) return n;
    return fibNoGuard(n - 1) + fibNoGuard(n - 2);
}

// B. Depth Guard (SP Check)
fn fibDepthGuard(n: usize) usize {
    safety.depthGuard(); // <--- Low Overhead
    if (n <= 1) return n;
    return fibDepthGuard(n - 1) + fibDepthGuard(n - 2);
}

/// -------------------------------------------------------------------------
// 2. NON-TRIVIAL: Tree Traversal (Heap Access + Recursion)
// -------------------------------------------------------------------------

const JsonNode = struct {
    value: usize,
    left: ?*JsonNode = null,
    right: ?*JsonNode = null,
};

// Allocate a perfectly balanced tree of depth D
fn buildTree(allocator: std.mem.Allocator, depth: usize) !*JsonNode {
    const node = try allocator.create(JsonNode);
    node.value = depth;
    node.left = null;
    node.right = null;

    if (depth > 0) {
        node.left = try buildTree(allocator, depth - 1);
        node.right = try buildTree(allocator, depth - 1);
    }
    return node;
}

fn freeTree(allocator: std.mem.Allocator, node: *JsonNode) void {
    if (node.left) |l| freeTree(allocator, l);
    if (node.right) |r| freeTree(allocator, r);
    allocator.destroy(node);
}

// A. Walk Tree No Guard
fn walkTreeNoGuard(node: *JsonNode) usize {
    var sum = node.value;
    if (node.left) |l| sum += walkTreeNoGuard(l);
    if (node.right) |r| sum += walkTreeNoGuard(r);
    return sum;
}

// B. Walk Tree Depth Guard
fn walkTreeDepthGuard(node: *JsonNode) usize {
    safety.depthGuard();
    var sum = node.value;
    if (node.left) |l| sum += walkTreeDepthGuard(l);
    if (node.right) |r| sum += walkTreeDepthGuard(r);
    return sum;
}

test "Benchmark: Safety Guards Overhead" {
    const stdout = std.debug.print;
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x12345678);
    const random = prng.random();

    // -----------------------------------------------------------
    // TEST 1: RANDOMIZED FIBONACCI
    // -----------------------------------------------------------
    stdout("\n=== TRIVIAL (Fibonacci Randomized 20-25) ===\n", .{});

    // 1. Setup: Generate a random workload
    // We do this UP FRONT so both tests run the EXACT same "random" numbers.
    const num_runs = random.intRangeAtMost(usize, 1000, 1100);
    var inputs = try std.ArrayListUnmanaged(usize).initCapacity(allocator, num_runs);
    defer inputs.deinit(allocator);

    for (0..num_runs) |_| {
        inputs.appendAssumeCapacity(random.intRangeAtMost(usize, 20, 25));
    }

    var time_baseline: u64 = 0;

    // 2. Baseline Run
    {
        var timer = try std.time.Timer.start();
        var sum: usize = 0;

        for (inputs.items) |n| {
            sum += fibNoGuard(n);
        }

        time_baseline = timer.read();
        stdout("[None      ] {d} runs: {d}ms\n", .{num_runs, time_baseline / 1_000_000});
        std.mem.doNotOptimizeAway(sum);
    }

    // 3. Guard Run
    {
        safety.__min_depth = std.math.maxInt(usize);
        var timer = try std.time.Timer.start();
        var sum: usize = 0;

        for (inputs.items) |n| {
            sum += fibDepthGuard(n);
        }

        const time_guard = timer.read();
        stdout("[DepthGuard] {d} runs: {d}ms\n", .{num_runs, time_guard / 1_000_000});

        const diff = @as(f64, @floatFromInt(time_guard - time_baseline));
        const base = @as(f64, @floatFromInt(time_baseline));
        const pct = (diff / base) * 100.0;
        stdout("   >> Overhead: {d:.2}%\n", .{pct});

        std.mem.doNotOptimizeAway(sum);
    }

    // -----------------------------------------------------------
    // TEST 2: TREE TRAVERSAL (Memory Bound / Pointer Heavy)
    // -----------------------------------------------------------
    stdout("\n=== NON-TRIVIAL (Tree Walk Depth 15) ===\n", .{});
    var tree_depth: usize = 15;
    var root = try buildTree(allocator, tree_depth);
    defer freeTree(allocator, root);

    // Use volatile pointer to prevent optimization in ReleaseFast
    var root_ptr = @as(*volatile *JsonNode, &root);

    var TREE_RUNS: u64 = 1000;
    time_baseline = 0;

    // 1. Baseline
    {
        var timer = try std.time.Timer.start();
        var i: usize = 0;
        var sum: usize = 0;
        while (i < TREE_RUNS) : (i += 1) {
            sum += walkTreeNoGuard(root_ptr.*);
        }
        time_baseline = timer.read();
        const nodes = 65535 * TREE_RUNS;
        stdout("[None      ] {d} runs: {d}ms (Total Nodes: {d})\n", .{TREE_RUNS, time_baseline / 1_000_000, nodes});
        std.mem.doNotOptimizeAway(sum);
    }

    // 2. Depth Guard
    {
        safety.__min_depth = std.math.maxInt(usize);
        var timer = try std.time.Timer.start();
        var i: usize = 0;
        var sum: usize = 0;
        while (i < TREE_RUNS) : (i += 1) {
            sum += walkTreeDepthGuard(root_ptr.*);
        }
        const time_guard = timer.read();
        stdout("[DepthGuard] {d} runs: {d}ms\n", .{TREE_RUNS, time_guard / 1_000_000});

        const diff = @as(f64, @floatFromInt(time_guard - time_baseline));
        const base = @as(f64, @floatFromInt(time_baseline));
        const pct = (diff / base) * 100.0;
        stdout("   >> Overhead: {d:.2}%\n", .{pct});

        std.mem.doNotOptimizeAway(sum);
    }

    // -----------------------------------------------------------
    // TEST 3: TREE TRAVERSAL (Memory Bound / Pointer Heavy)
    // -----------------------------------------------------------
    // Depth 20 = ~1,048,575 nodes
    // Size in Memory = ~32MB (Far exceeds 32KB L1 and 12MB L3)
    stdout("\n=== REALISTIC (Tree Walk Depth 20 - RAM Bound) ===\n", .{});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    tree_depth = 20;

    // Note: Allocating 32MB might take a moment
    root = try buildTree(arena_allocator, tree_depth);
    defer freeTree(arena_allocator, root);

    // Prevent optimization
    root_ptr = @as(*volatile *JsonNode, &root);

    // Reduced runs because the tree is 32x larger now
    TREE_RUNS = 50;
    time_baseline = 0;

    // 1. Baseline
    {
        var timer = try std.time.Timer.start();
        var i: usize = 0;
        var sum: usize = 0;
        while (i < TREE_RUNS) : (i += 1) {
            sum += walkTreeNoGuard(root_ptr.*);
        }
        time_baseline = timer.read();

        const nodes_per_run = (@as(u64, 1) << @intCast(tree_depth)) - 1;
        const total_nodes = nodes_per_run * TREE_RUNS;
        stdout("[None      ] {d} runs: {d}ms (Total Nodes: {d})\n", .{TREE_RUNS, time_baseline / 1_000_000, total_nodes});
        std.mem.doNotOptimizeAway(sum);
    }

    // 2. Depth Guard
    {
        safety.__min_depth = std.math.maxInt(usize);
        var timer = try std.time.Timer.start();
        var i: usize = 0;
        var sum: usize = 0;
        while (i < TREE_RUNS) : (i += 1) {
            sum += walkTreeDepthGuard(root_ptr.*);
        }
        const time_guard = timer.read();
        stdout("[DepthGuard] {d} runs: {d}ms\n", .{TREE_RUNS, time_guard / 1_000_000});

        const diff = @as(f64, @floatFromInt(time_guard - time_baseline));
        const base = @as(f64, @floatFromInt(time_baseline));
        const pct = (diff / base) * 100.0;
        stdout("   >> Overhead: {d:.2}%\n", .{pct});

        std.mem.doNotOptimizeAway(sum);
    }
}

