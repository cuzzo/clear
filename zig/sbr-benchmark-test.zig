const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const EbrContext = @import("ebr.zig").EbrContext;
const ObjectHeader = @import("sbr.zig").ObjectHeader;

// -------------------------------------------------------------------------
// DOMAIN OBJECTS
// -------------------------------------------------------------------------

const User = struct {
    id: i64,
    score: i32,
    // We use a dummy field to make the object size realistic (e.g. 64 bytes)
    padding: [40]u8 = undefined,
};

const TreeNode = struct {
    val: i64,
    left: ?*TreeNode = null,
    right: ?*TreeNode = null,
};

// -------------------------------------------------------------------------
// BENCHMARK HARNESS
// -------------------------------------------------------------------------

pub fn main() !void {
    // 1. Setup Global Resources
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Setup Runtime Memory (10MB Stack for Benchmarks)
    const frame_mem = try allocator.alloc(u8, 10 * 1024 * 1024);
    defer allocator.free(frame_mem);

    var global_ctx = EbrContext{};
    var rt = try Runtime.initFromSlice(frame_mem, &global_ctx, allocator, allocator, 0);
    rt.wireAllocator();
    defer rt.deinit();

    const ITERATIONS = 1_000_000;

    std.debug.print("\n{s:-<92}\n", .{""});
    std.debug.print("{s:^92}\n", .{"RUNTIME vs NATIVE BENCHMARK (-O ReleaseFast)"});
    std.debug.print("{s:-<92}\n", .{""});
    std.debug.print("{s:<35} | {s:<15} | {s:<15} | {s:<10}\n", .{ "Test Case", "Native (ns/op)", "Runtime (ns/op)", "Overhead" });
    std.debug.print("{s:-<92}\n", .{""});

    // ---------------------------------------------------------------------
    // 1. PURE MATH (Function Call Overhead)
    // ---------------------------------------------------------------------
    {
        const native_t = try measure(ITERATIONS, 100, benchMathNative, .{}, true);
        const rt_t = try measure(ITERATIONS, 100, benchMathRuntime, .{&rt}, true);
        printResult("1. Pure Math (100x)", native_t, rt_t);
    }

    // ---------------------------------------------------------------------
    // 2. DETERMINATE STACK RETURN (Frame Alloc vs Stack Return)
    // ---------------------------------------------------------------------
    {
        const native_t = try measure(ITERATIONS, 100, benchStackNative, .{}, false);
        const rt_t = try measure(ITERATIONS, 100, benchStackRuntime, .{&rt}, false);
        printResult("2a. Stack Return Native (100x)", native_t, rt_t);
    }

    // ---------------------------------------------------------------------
    // 2b. DETERMINATE STACK RETURN (Destination Passing)
    // ---------------------------------------------------------------------
    {
        var user: User = undefined;
        const native_t = try measure(ITERATIONS, 100, benchStackDPSNative, .{&user}, false);
        const rt_t = try measure(ITERATIONS, 100, benchStackDPSRuntime, .{&rt, &user}, false);
        printResult("2b. Stack Return DPS (100x)", native_t, rt_t);
    }

    // ---------------------------------------------------------------------
    // 2c. DETERMINATE STACK RETURN (Destination Passing, logic)
    // ---------------------------------------------------------------------
    {
        var user: User = undefined;
        const native_t = try measure(ITERATIONS, 100, benchStackDPSLogicNative, .{&user}, true);
        const rt_t = try measure(ITERATIONS, 100, benchStackDPSLogicRuntime, .{&rt, &user}, true);
        printResult("2c. Stack Return DPS - Logic (100x)", native_t, rt_t);
    }

    // ---------------------------------------------------------------------
    // 3. MAYBE RETURN (Conditional Free / Affine Move)
    // ---------------------------------------------------------------------
    {
        // Native uses c_allocator (malloc) for fairness against Slab/Block alloc
        const native_t = try measure(ITERATIONS, 1, benchMaybeNative, .{std.heap.c_allocator}, false);
        const rt_t = try measure(ITERATIONS, 1, benchMaybeRuntime, .{&rt}, false);
        printResult("3. Maybe Return", native_t, rt_t);
    }

    // ---------------------------------------------------------------------
    // 4. WRITE BARRIER (UF Connect vs Pointer Assign)
    // ---------------------------------------------------------------------
    {
        // We pre-allocate objects to measure ONLY the write cost
        const p_native = try std.heap.c_allocator.create(TreeNode);
        const c_native = try std.heap.c_allocator.create(TreeNode);

        const mark = rt.saveHeapMark();
        const p_rt = try rt.heapCreate(TreeNode);
        const c_rt = try rt.heapCreate(TreeNode);

        const native_t = try measure(ITERATIONS, 100, benchBarrierNative, .{ p_native, c_native }, false);
        const rt_t = try measure(ITERATIONS, 100, benchBarrierRuntime, .{ &rt, p_rt, c_rt }, false);

        printResult("4. Write Barrier / UF (100x)", native_t, rt_t);

        // Cleanup
        std.heap.c_allocator.destroy(p_native);
        std.heap.c_allocator.destroy(c_native);
        rt.restoreHeapMark(mark);
    }

    // ---------------------------------------------------------------------
    // 5. REALISTIC (Binary Tree Insert - Alloc + Link)
    // ---------------------------------------------------------------------
    {
        // For this test, we reduce iterations because it allocates LOTS of memory
        // We perform 1000 inserts per batch
        const TREE_ITERS = 5_000;

        const native_t = try measure(TREE_ITERS, 1, benchTreeNative, .{std.heap.c_allocator}, false);
        const rt_t = try measure(TREE_ITERS, 1, benchTreeRuntime, .{&rt}, false);

        printResult("5. Tree Insert (1k)", native_t, rt_t);
    }

    std.debug.print("{s:-<90}\n\n", .{""});
}

// -------------------------------------------------------------------------
// TEST IMPLS
// -------------------------------------------------------------------------

// --- 1. Pure Math ---
noinline fn benchMathNative(val: u64) u64 {
    const a: u64 = 100;
    const b: u64 = 200;
    var x: u64 = a + b +% val;
    x *= 2;
    x /= 3;

    return x;
}

noinline fn benchMathRuntime(rt: *Runtime, val: u64) u64 {
    _ = rt;

    const a: u64 = 100;
    const b: u64 = 200;
    var x: u64 = a + b +% val;
    x *= 2;
    x /= 3;

    return x;
}

// --- 2a. Stack Return ---

fn benchStackNative() User {
    var u = User{ .id = 1, .score = 100 };
    std.mem.doNotOptimizeAway(&u);
    return u;
}

fn benchStackRuntime(rt: *Runtime) *User {
    const mark = rt.saveFrameMark();
    defer rt.restoreFrameMark(mark);

    const u = rt.frameAlloc().create(User) catch unreachable;
    u.* = User{ .id = 1, .score = 100 };
    std.mem.doNotOptimizeAway(u);

    // In a real runtime, we might copy this out or return the pointer.
    // Here we return the pointer, but the defer technically invalidates it immediately
    // (mimicking the cost of scope setup/teardown).
    return u;
}

// --- 2b. Stack Return (Destination Passing) ---

// Caller provides the memory (on native stack or frame)
fn benchStackDPSNative(out: *User) void {
    out.* = User{ .id = 1, .score = 100 };
    std.mem.doNotOptimizeAway(out.*);
}

fn benchStackDPSRuntime(rt: *Runtime, out: *User) void {
    const mark = rt.saveFrameMark();
    defer rt.restoreFrameMark(mark);

    // Write result to caller's memory
    out.* = User{ .id = 1, .score = 100 };
    std.mem.doNotOptimizeAway(out.*);
}

// --- 2c. Stack Return (Destination Passing, with logic) ---

// Caller provides the memory (on native stack or frame)
fn benchStackDPSLogicNative(u: *User, i: usize) void {
    var h = @as(i64, @intCast(i));
    h ^= 0xDEADBEEF;
    h *%= 1640531527; // simple mix
    u.id = h;

    // Simulate validation logic (Branching)
    const raw_score = @as(i32, @intCast(i % 1000));
    u.score = if (raw_score > 500) 500 else raw_score;

    std.mem.doNotOptimizeAway(u.*);
}

fn benchStackDPSLogicRuntime(rt: *Runtime, u: *User, i: usize) void {
    const mark = rt.saveFrameMark();
    defer rt.restoreFrameMark(mark);

    var h = @as(i64, @intCast(i));
    h ^= 0xDEADBEEF;
    h *%= 1640531527; // simple mix
    u.id = h;

    // Simulate validation logic (Branching)
    const raw_score = @as(i32, @intCast(i % 1000));
    u.score = if (raw_score > 500) 500 else raw_score;

    // Write result to caller's memory
    std.mem.doNotOptimizeAway(u.*);
}

// --- 3. Maybe Return (Affine) ---

fn benchMaybeNative(alloc: std.mem.Allocator) !*User {
    const us1 = try alloc.create(User);
    const us2 = try alloc.create(User);

    us1.id = 10;
    us2.id = 20;

    // Logic: Return u2, Free u1
    alloc.destroy(us1);
    return us2; // Caller would free u2, but we don't in the loop to avoid measuring caller cost
}

fn benchMaybeRuntime(rt: *Runtime) !*User {
    const mark = rt.saveHeapMark();
    // Note: We don't defer restoreHeapMark here because heapReturn does the cleanup logic.

    const us1 = try rt.heapCreate(User);
    const us2 = try rt.heapCreate(User);

    us1.id = 10;
    us2.id = 20;

    // Logic: Return u2, Runtime Auto-Frees u1
    // This measures: Anchor Scan + Compaction + Freeing u1
    return rt.heapReturn(mark, us2);
}

// --- 4. Write Barrier ---

fn benchBarrierNative(parent: *TreeNode, child: *TreeNode) void {
    // Pure pointer assignment
    parent.left = child;
    // To be fair to UF, we touch the child too
    child.val = 1;
}

fn benchBarrierRuntime(rt: *Runtime, parent: *TreeNode, child: *TreeNode) void {
    // UF Connect: Find Root + Union + Rank Update
    rt.ufConnect(parent, child);
}

// --- 5. Tree Insert (Batch) ---

fn benchTreeNative(alloc: std.mem.Allocator) !void {
    var root: ?*TreeNode = null;

    // Insert 1000 nodes
    var i: i64 = 0;
    var rng = std.Random.DefaultPrng.init(0x12345678);
    while (i < 1000) : (i += 1) {
        const node = try alloc.create(TreeNode);
        // 2. Random value prevents linked-list degeneracy
        node.val = rng.random().int(i64);
        node.left = null;
        node.right = null;

        if (root == null) {
            root = node;
        } else {
            // 3. Iterative BST Insert
            var curr = root.?;
            while (true) {
                if (node.val < curr.val) {
                    if (curr.left) |l| { curr = l; } else { curr.left = node; break; }
                } else {
                    if (curr.right) |r| { curr = r; } else { curr.right = node; break; }
                }
            }
        }
    }
    // Cleanup entire tree
    destroyTree(alloc, root);
}

fn destroyTree(alloc: std.mem.Allocator, node: ?*TreeNode) void {
    var stack = std.ArrayListUnmanaged(*TreeNode){};
    defer stack.deinit(alloc);

    if (node) |n| stack.append(alloc, n) catch unreachable;

    // 2. Iterative cleanup (prevents Stack Overflow)
    while (stack.items.len > 0) {
        const n = stack.pop().?;
        if (n.left) |l| stack.append(alloc, l) catch unreachable;
        if (n.right) |r| stack.append(alloc, r) catch unreachable;
        alloc.destroy(n);
    }
}

fn benchTreeRuntime(rt: *Runtime) !void {
    const mark = rt.saveHeapMark();
    // We wipe everything at end of batch
    defer rt.restoreHeapMark(mark);

    var root: ?*TreeNode = null;

    var i: i64 = 0;
    var rng = std.Random.DefaultPrng.init(0x12345678);
    while (i < 1000) : (i += 1) {
        const node = try rt.heapCreate(TreeNode);
        // Randomize value to create a balanced-ish tree, preventing O(N) stack depth
        node.val = rng.random().int(i64);
        node.left = null;
        node.right = null;

        if (root == null) {
            root = node;
        } else {
            var curr = root.?;
            while (true) {
                if (node.val < curr.val) {
                    if (curr.left) |l| {
                        curr = l;
                    } else {
                        curr.left = node;
                        rt.ufConnect(curr, node); // Barrier
                        break;
                    }
                } else {
                    if (curr.right) |r| {
                        curr = r;
                    } else {
                        curr.right = node;
                        rt.ufConnect(curr, node); // Barrier
                        break;
                    }
                }
            }
        }
    }
    // No manual cleanup needed! restoreHeapMark handles it.
}


// -------------------------------------------------------------------------
// TIMING HELPERS
// -------------------------------------------------------------------------

fn measure(iters: usize, batch_size: usize, func: anytype, args: anytype, comptime pass_index: bool) !u64 {
    // Warmup
    if (pass_index) {
        runOne(func, args ++ .{0});
    } else {
        runOne(func, args);
    }

    var timer = try std.time.Timer.start();

    var i: usize = 0;
    if (pass_index) {
        while (i < iters * batch_size) : (i += 1) {
            runOne(func, args ++ .{i});
        }
    }
    else {
        while (i < iters * batch_size) : (i += 1) {
            runOne(func, args);
        }
    }

    const elapsed = timer.read(); // nanoseconds
    return elapsed / iters;
}

// Inline helper to handle the return type variance
inline fn runOne(func: anytype, args: anytype) void {
    const ResT = @TypeOf(@call(.auto, func, args));
    if (@typeInfo(ResT) == .error_union) {
        const val = @call(.auto, func, args) catch unreachable;
        std.mem.doNotOptimizeAway(val);
    } else {
        const val = @call(.auto, func, args);
        std.mem.doNotOptimizeAway(val);
    }
}

fn printResult(name: []const u8, native_ns: u64, rt_ns: u64) void {
    const ratio = @as(f64, @floatFromInt(rt_ns)) / @as(f64, @floatFromInt(native_ns));
    std.debug.print("{s:<35} | {d:<12} ns | {d:<12} ns | {d:>8.2}x\n",
        .{ name, native_ns, rt_ns, ratio });
}

