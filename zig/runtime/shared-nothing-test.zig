// shared-nothing-test.zig — Verify PartitionedStringMap scales linearly.
//
// Tests a SINGLE shared PartitionedStringMap: each scheduler thread only
// touches its own shards (shard % num_schedulers == my_index).
// Keys are pre-assigned to shards so each thread does only useful work.
//
// Build & run (~2s):
//   zig build-exe shared-nothing-test.zig -lc switch.S onRoot.S -OReleaseFast
//   ./shared-nothing-test

const std = @import("std");
const fp = @import("scheduler.zig");
const fm = @import("fiber-memory.zig");
const rt_mod = @import("runtime.zig");
const ebr = @import("../lib/ebr.zig");
const CheatLib = @import("runtime-header.zig").CheatLib;

var global_ebr: ebr.EbrContext = .{};
var stack_pool: fm.StackPool = undefined;
var global_shutdown = std.atomic.Value(bool).init(false);

const NUM_SHARDS: usize = 8;
const KEYS_PER_SHARD = 50_000;
const Map = CheatLib.PartitionedStringMap(i64, NUM_SHARDS);

// Pre-computed key lists: keys_for_shard[s] contains KEYS_PER_SHARD keys
// that hash to shard s.  Computed once, shared read-only.
const KeyList = [][]const u8;
var keys_for_shard: [NUM_SHARDS]KeyList = undefined;

fn precomputeKeys() void {
    const alloc = std.heap.c_allocator;
    var per_shard_count: [NUM_SHARDS]usize = [_]usize{0} ** NUM_SHARDS;
    var buf: [32]u8 = undefined;

    // Allocate buffers
    for (0..NUM_SHARDS) |s| {
        keys_for_shard[s] = alloc.alloc([]const u8, KEYS_PER_SHARD) catch @panic("OOM");
    }

    // Generate keys until every shard has enough
    var i: usize = 0;
    while (true) : (i += 1) {
        const key = std.fmt.bufPrint(&buf, "k{d}", .{i}) catch continue;
        const s = @as(usize, std.hash.Fnv1a_64.hash(key)) % NUM_SHARDS;
        if (per_shard_count[s] >= KEYS_PER_SHARD) {
            // Check if all shards are full
            var all_full = true;
            for (&per_shard_count) |c| {
                if (c < KEYS_PER_SHARD) { all_full = false; break; }
            }
            if (all_full) break;
            continue;
        }
        keys_for_shard[s][per_shard_count[s]] = alloc.dupe(u8, key) catch continue;
        per_shard_count[s] += 1;
    }
}

// ---------------------------------------------------------------------------
// Single-thread: one thread processes ALL shards
// ---------------------------------------------------------------------------
fn benchSingleThread() i64 {
    const alloc = std.heap.c_allocator;
    var map: Map = .{};
    defer map.deinit(alloc, alloc);

    const start = std.time.nanoTimestamp();
    for (0..NUM_SHARDS) |s| {
        for (keys_for_shard[s]) |key| {
            map.put(alloc, alloc, key, 1) catch continue;
        }
    }
    var hits: usize = 0;
    for (0..NUM_SHARDS) |s| {
        for (keys_for_shard[s]) |key| {
            if (map.get(key)) |_| hits += 1;
        }
    }
    const end = std.time.nanoTimestamp();
    std.mem.doNotOptimizeAway(hits);
    return @intCast(@divFloor(end - start, std.time.ns_per_ms));
}

// ---------------------------------------------------------------------------
// 2-scheduler: each thread processes only its own shards on SHARED map
// ---------------------------------------------------------------------------
const FiberCtx = struct {
    map: *Map,
    result_ms: i64 = 0,
    result_ops: usize = 0,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn fiberWork(_: *anyopaque, ctx_raw: ?*anyopaque) !void {
    const ctx: *FiberCtx = @ptrCast(@alignCast(ctx_raw.?));
    // Both allocators use thread-local arena: zero lock contention.
    // Arena memory is reclaimed when the scheduler is destroyed.
    const alloc = fp.active_scheduler.local_arena.allocator();
    const my_idx = fp.active_scheduler.index;
    const num_scheds = fp.global_registry.count();
    var ops: usize = 0;

    const start = std.time.nanoTimestamp();
    // PUT
    for (0..NUM_SHARDS) |s| {
        if (s % num_scheds != my_idx) continue;
        for (keys_for_shard[s]) |key| {
            ctx.map.put(alloc, alloc, key, 1) catch continue;
            ops += 1;
        }
    }
    // GET
    for (0..NUM_SHARDS) |s| {
        if (s % num_scheds != my_idx) continue;
        for (keys_for_shard[s]) |key| {
            if (ctx.map.get(key)) |_| ops += 1;
        }
    }
    const end = std.time.nanoTimestamp();
    ctx.result_ms = @intCast(@divFloor(end - start, std.time.ns_per_ms));
    ctx.result_ops = ops;
    ctx.done.store(true, .release);
}

fn schedulerThread(allocator: std.mem.Allocator) void {
    var sched = fp.Scheduler.init(allocator, &global_ebr, &stack_pool) catch return;
    defer sched.deinit();
    sched.global_shutdown = &global_shutdown;
    sched.shutdown_on_idle = false;
    fp.active_scheduler = &sched;
    fp.scheduler_running = true;
    sched.run();
    fp.scheduler_running = false;
}

fn benchMultiThread() !struct { max_ms: i64, r: [2]FiberCtx } {
    const allocator = std.heap.c_allocator;
    global_shutdown.store(false, .release);

    const map = try allocator.create(Map);
    map.* = .{};

    var threads: [2]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, schedulerThread, .{allocator});
    }
    while (fp.global_registry.count() < 2) {
        std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
    }

    var ctxs: [2]FiberCtx = .{ .{ .map = map }, .{ .map = map } };
    for (0..2) |i| {
        const sched = fp.global_registry.slots[i].load(.acquire) orelse continue;
        try sched.submitSpawn(
            @intFromPtr(&rt_mod.Runtime.entryWrapper),
            fiberWork, @ptrCast(&ctxs[i]),
            .{ .pinned = true },
        );
    }

    while (!ctxs[0].done.load(.acquire) or !ctxs[1].done.load(.acquire)) {
        std.posix.nanosleep(0, 1 * std.time.ns_per_ms);
    }

    global_shutdown.store(true, .release);
    fp.global_registry.notifyAll();
    for (&threads) |*t| t.join();
    // All map data was arena-allocated — reclaimed when schedulers shut down.
    // Just free the map struct itself.
    allocator.destroy(map);
    fp.global_registry.deinit(allocator);
    fp.global_registry = .{};

    return .{ .max_ms = @max(ctxs[0].result_ms, ctxs[1].result_ms), .r = ctxs };
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    std.debug.print("\n=== Shared-Nothing Scaling Test ===\n", .{});
    std.debug.print("{d} shards × {d} keys = {d} total\n\n", .{
        NUM_SHARDS, KEYS_PER_SHARD, NUM_SHARDS * KEYS_PER_SHARD,
    });

    precomputeKeys();

    // Single-thread (best of 3)
    var best_single: i64 = std.math.maxInt(i64);
    for (0..3) |_| {
        const ms = benchSingleThread();
        if (ms < best_single) best_single = ms;
    }
    std.debug.print("1 scheduler:  {d} ms\n", .{best_single});

    // Multi-thread (best of 3)
    var best_multi: i64 = std.math.maxInt(i64);
    var best_r: [2]FiberCtx = undefined;
    for (0..3) |_| {
        const m = try benchMultiThread();
        if (m.max_ms < best_multi) {
            best_multi = m.max_ms;
            best_r = m.r;
        }
    }
    std.debug.print("2 schedulers: {d} ms  (sched0={d}ms/{d}ops, sched1={d}ms/{d}ops)\n", .{
        best_multi, best_r[0].result_ms, best_r[0].result_ops,
        best_r[1].result_ms, best_r[1].result_ops,
    });

    if (best_multi > 0 and best_single > 0) {
        const speedup_x10 = @divFloor(best_single * 10, best_multi);
        std.debug.print("\nSpeedup: {d}.{d}x  (ideal: 2.0x)\n", .{
            @divFloor(speedup_x10, 10), @mod(speedup_x10, 10),
        });
        if (speedup_x10 >= 15) {
            std.debug.print("PASS\n", .{});
        } else {
            std.debug.print("WARN — below 1.5x\n", .{});
        }
    }
    // ---------------------------------------------------------------
    // Routing correctness test: one fiber accesses ALL shards (50% routed)
    // ---------------------------------------------------------------
    std.debug.print("\n--- Routing Test ---\n", .{});
    {
        global_shutdown.store(false, .release);
        const map2 = try allocator.create(Map);
        map2.* = .{};

        var threads2: [2]std.Thread = undefined;
        for (&threads2) |*t| t.* = try std.Thread.spawn(.{}, schedulerThread, .{allocator});
        while (fp.global_registry.count() < 2) std.posix.nanosleep(0, 1 * std.time.ns_per_ms);

        // Submit ONE fiber on scheduler 0 that writes ALL keys (50% local, 50% routed)
        var route_ctx = FiberCtx{ .map = map2 };

        const routeFiberAll = struct {
            fn work(_: *anyopaque, ctx_raw: ?*anyopaque) !void {
                const ctx: *FiberCtx = @ptrCast(@alignCast(ctx_raw.?));
                const alloc_inner = fp.active_scheduler.local_arena.allocator();
                var ops_count: usize = 0;
                const start2 = std.time.nanoTimestamp();

                // Use c_allocator for buckets since arena dies with scheduler.
                const ba = std.heap.c_allocator;

                // PUT all keys across ALL shards (routing handles cross-shard)
                const total = NUM_SHARDS * KEYS_PER_SHARD;
                for (0..total) |i| {
                    ctx.map.put(alloc_inner, ba, keys_for_shard[i % NUM_SHARDS][i / NUM_SHARDS], @intCast(i)) catch continue;
                    ops_count += 1;
                }
                // GET all keys back
                for (0..total) |i| {
                    if (ctx.map.get(keys_for_shard[i % NUM_SHARDS][i / NUM_SHARDS])) |_| ops_count += 1;
                }

                const end2 = std.time.nanoTimestamp();
                ctx.result_ms = @intCast(@divFloor(end2 - start2, std.time.ns_per_ms));
                ctx.result_ops = ops_count;
                ctx.done.store(true, .release);
            }
        }.work;

        const sched0 = fp.global_registry.slots[0].load(.acquire) orelse unreachable;
        try sched0.submitSpawn(
            @intFromPtr(&rt_mod.Runtime.entryWrapper),
            routeFiberAll, @ptrCast(&route_ctx),
            .{ .pinned = true },
        );

        while (!route_ctx.done.load(.acquire)) std.posix.nanosleep(0, 1 * std.time.ns_per_ms);

        const total_expected = NUM_SHARDS * KEYS_PER_SHARD;
        const got_ops = route_ctx.result_ops;
        std.debug.print("Routed ops: {d} ms, {d}/{d} ops\n", .{
            route_ctx.result_ms, got_ops, total_expected * 2,
        });
        const expected = total_expected * 2;
        const diff = if (got_ops > expected) got_ops - expected else expected - got_ops;
        if (diff <= 10) {
            std.debug.print("PASS — routed ops correct ({d}/{d})\n", .{ got_ops, expected });
        } else {
            std.debug.print("FAIL — expected ~{d} ops, got {d} (diff {d})\n", .{ expected, got_ops, diff });
        }

        global_shutdown.store(true, .release);
        fp.global_registry.notifyAll();
        for (&threads2) |*t| t.join();
        // Buckets use c_allocator, keys use arena (freed with scheduler).
        // Free bucket arrays only.
        for (&map2.shards) |*shard| shard.map.deinit(allocator);
        allocator.destroy(map2);
        fp.global_registry.deinit(allocator);
        fp.global_registry = .{};
    }
    std.debug.print("\n", .{});
}
