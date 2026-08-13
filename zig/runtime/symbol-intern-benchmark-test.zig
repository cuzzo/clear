// Benchmark: what does interning a symbol cost, and does the lock matter?
//
// `Runtime.internSymbol` takes `symbol_pool_lock` on every `.to_sym()`. The
// pool is a field on Runtime, and a fiber-local Runtime is touched by one
// thread at a time, so the question is whether that atomic can be skipped --
// and whether skipping it is worth diverging from how Rust does this.
//
// The comparison isolates the SYNCHRONIZATION strategy: every variant uses the
// same hash map, the same allocator, and the same workload, so the delta is the
// locking discipline and nothing else.
//
//   local_unlocked  -- per-Runtime pool, no atomic       (the proposal)
//   local_locked    -- per-Runtime pool, uncontended mutex (CLEAR today)
//   global_1t       -- one shared pool, one thread       (ustr/rustc, best case)
//   global_nt       -- one shared pool, N threads         (ustr/rustc, real case)
//
// Run it optimized -- in Debug the hash map dominates and the lock delta
// vanishes into noise:
//
//   zig build benchmark -Doptimize=ReleaseFast
//
// Rust counterpart with the same workload and strategies is
// symbol-intern-benchmark.rs, for checking these numbers against a baseline.
//
// Measured (ReleaseFast, 8 cores), ns/op, Zig vs Rust:
//
//   local_unlocked   12.9 / 20.4     local_locked (today)  18.6 / 25.8
//   global_1t        18.3 / 26.6     global_8t            138.7 / 228.3
//
// Two conclusions. An uncontended mutex costs ~5.5 ns/op in BOTH languages, so
// that is a property of the atomic, not of Zig. And moving to ONE shared pool
// -- which a u32 index handle would require, since an index only means
// anything relative to its table -- costs 7.5x under 8-thread contention.
// That is the finding that matters: the per-Runtime pool is worth more than
// any handle-width saving.
//
// Workload is hit-dominated on purpose. In the self-hosted compiler 11,309 of
// 11,424 symbol uses are literals emitted as constants, and the 115 dynamic
// `symbol(expr)` sites re-intern names that almost always already exist. A
// miss-heavy benchmark would measure hash-map insertion, not interning.

const std = @import("std");
const compat = @import("../lib/compat.zig");

const HITS_PER_THREAD = 200_000;
const DISTINCT = 1352; // distinct symbols in the self-hosted compiler
const AVG_LEN = 17; // measured average symbol length, in bytes

/// The pool as it exists today, minus the Runtime it hangs off.
const Pool = struct {
    map: std.StringHashMapUnmanaged(void) = .empty,
    lock: compat.Mutex = .{},
    alloc: std.mem.Allocator,

    fn deinit(self: *Pool) void {
        var it = self.map.iterator();
        while (it.next()) |e| self.alloc.free(e.key_ptr.*);
        self.map.deinit(self.alloc);
    }

    fn internLocked(self: *Pool, value: []const u8) ![]const u8 {
        self.lock.lock();
        defer self.lock.unlock();
        return self.internRaw(value);
    }

    fn internUnlocked(self: *Pool, value: []const u8) ![]const u8 {
        return self.internRaw(value);
    }

    fn internRaw(self: *Pool, value: []const u8) ![]const u8 {
        if (self.map.getKey(value)) |canonical| return canonical;
        const canonical = try self.alloc.dupe(u8, value);
        try self.map.put(self.alloc, canonical, {});
        return canonical;
    }
};

fn makeNames(alloc: std.mem.Allocator) ![]const []const u8 {
    const names = try alloc.alloc([]const u8, DISTINCT);
    for (names, 0..) |*slot, i| {
        var buf: [AVG_LEN]u8 = undefined;
        for (&buf, 0..) |*c, j| c.* = 'a' + @as(u8, @intCast((i + j) % 26));
        // Keep them distinct: stamp the index over the tail.
        _ = std.fmt.bufPrint(buf[AVG_LEN - 5 ..], "{d:0>5}", .{i}) catch unreachable;
        slot.* = try alloc.dupe(u8, &buf);
    }
    return names;
}

fn hammer(pool: *Pool, names: []const []const u8, locked: bool) void {
    var i: usize = 0;
    while (i < HITS_PER_THREAD) : (i += 1) {
        const name = names[i % names.len];
        const got = if (locked) pool.internLocked(name) catch unreachable else pool.internUnlocked(name) catch unreachable;
        std.mem.doNotOptimizeAway(got.ptr);
    }
}

test "Benchmark: symbol interning -- lock elision vs shared pool" {
    const alloc = std.heap.c_allocator;
    const names = try makeNames(alloc);
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }

    const thread_count: usize = @max(2, @min(8, std.Thread.getCpuCount() catch 4));

    // 1. Per-Runtime pool, no lock. Only sound if a non-shared Runtime is
    //    provably touched by one thread at a time.
    var unlocked_ns: u64 = 0;
    {
        var pool = Pool{ .alloc = alloc };
        defer pool.deinit();
        for (names) |n| _ = try pool.internUnlocked(n); // warm: measure hits
        var timer = try compat.Timer.start();
        hammer(&pool, names, false);
        unlocked_ns = timer.read();
    }

    // 2. Per-Runtime pool with today's mutex, uncontended.
    var locked_ns: u64 = 0;
    {
        var pool = Pool{ .alloc = alloc };
        defer pool.deinit();
        for (names) |n| _ = try pool.internLocked(n);
        var timer = try compat.Timer.start();
        hammer(&pool, names, true);
        locked_ns = timer.read();
    }

    // 3. One shared pool, single thread: what ustr/rustc pay with no contention.
    var global_1t_ns: u64 = 0;
    {
        var pool = Pool{ .alloc = alloc };
        defer pool.deinit();
        for (names) |n| _ = try pool.internLocked(n);
        var timer = try compat.Timer.start();
        hammer(&pool, names, true);
        global_1t_ns = timer.read();
    }

    // 4. One shared pool, N threads: what ustr/rustc pay in practice, and what
    //    CLEAR would adopt by moving to a global table for u32 indices.
    var global_nt_ns: u64 = 0;
    {
        var pool = Pool{ .alloc = alloc };
        defer pool.deinit();
        for (names) |n| _ = try pool.internLocked(n);

        const threads = try alloc.alloc(std.Thread, thread_count);
        defer alloc.free(threads);

        var timer = try compat.Timer.start();
        for (threads) |*t| t.* = try std.Thread.spawn(.{}, hammer, .{ &pool, names, true });
        for (threads) |t| t.join();
        global_nt_ns = timer.read();
    }

    const per = struct {
        fn ns(total: u64, ops: u64) f64 {
            return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(ops));
        }
    };

    const one: u64 = HITS_PER_THREAD;
    const many: u64 = @as(u64, HITS_PER_THREAD) * @as(u64, thread_count);

    std.debug.print("\n=== symbol intern: {d} hits/thread over {d} distinct names ===\n", .{ HITS_PER_THREAD, DISTINCT });
    std.debug.print("local_unlocked (proposed)   {d:>7.2} ns/op\n", .{per.ns(unlocked_ns, one)});
    std.debug.print("local_locked   (today)      {d:>7.2} ns/op\n", .{per.ns(locked_ns, one)});
    std.debug.print("global_1t      (rust, 1T)   {d:>7.2} ns/op\n", .{per.ns(global_1t_ns, one)});
    std.debug.print("global_{d}t      (rust, {d}T)   {d:>7.2} ns/op  [{d} threads contending]\n", .{ thread_count, thread_count, per.ns(global_nt_ns, many), thread_count });
    std.debug.print("lock overhead (today vs proposed): {d:>5.2} ns/op\n", .{per.ns(locked_ns, one) - per.ns(unlocked_ns, one)});

    try std.testing.expect(unlocked_ns > 0 and global_nt_ns > 0);
}
