// benchmark-test.zig — Tests for CheatLib.benchmark and generateSkewKeys.
const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = @import("runtime.zig").Runtime;
const ebr_mod = @import("../lib/ebr.zig");

fn trivialWork(rt: *Runtime) f64 {
    _ = rt;
    var sum: f64 = 0;
    for (0..100) |i| {
        sum += @floatFromInt(i);
    }
    return sum;
}

fn allocatingWork(rt: *Runtime) ![]const u8 {
    // Force a frame allocation
    return try rt.heapAlloc().dupe(u8, "hello");
}

test "benchmark: runs iterations and returns valid timing" {
    var arena_buf: [4096]u8 = undefined;
    const gpa = std.heap.page_allocator;
    var global_ebr = ebr_mod.EbrContext{};
    defer global_ebr.deinit(gpa);

    var rt = try Runtime.initFromSlice(&arena_buf, &global_ebr, gpa, 0);
    defer rt.deinit();
    rt.wireAllocator();

    const result = CheatLib.benchmark(trivialWork, &rt, .{}, 100);

    try std.testing.expect(result.iterations == 100);
    try std.testing.expect(result.total_ns > 0);
    try std.testing.expect(result.avg_ns > 0);
    try std.testing.expect(result.min_ns <= result.avg_ns);
    try std.testing.expect(result.avg_ns <= result.max_ns);
    try std.testing.expect(result.p50_ns > 0);
    try std.testing.expect(result.p50_ns <= result.p99_ns);
}

test "benchmark: prints report without crashing" {
    const result = CheatLib.BenchmarkResult{
        .iterations = 1000,
        .total_ns = 12_300_000,
        .min_ns = 10_000,
        .max_ns = 50_000,
        .avg_ns = 12_300,
        .p50_ns = 11_000,
        .p99_ns = 45_000,
        .alloc_count = 2100,
        .alloc_bytes = 100_800,
        .arena_high_water = 65536,
    };
    CheatLib.printBenchmarkResult("test_fn", result);
}

test "generateSkewKeys: all keys route to target shard" {
    const N = 8;
    const target: usize = 3;
    const gpa = std.heap.page_allocator;

    const keys = try CheatLib.generateSkewKeys(N, target, 100, gpa);
    defer CheatLib.freeSkewKeys(keys, gpa);

    try std.testing.expect(keys.len == 100);

    for (keys) |key| {
        const h = std.hash_map.hashString(key);
        const shard = @as(usize, h) % N;
        try std.testing.expectEqual(target, shard);
    }
}

test "generateSkewKeys: works for 4, 16, and 32 shards" {
    const gpa = std.heap.page_allocator;

    inline for ([_]usize{ 4, 16, 32 }) |n| {
        const keys = try CheatLib.generateSkewKeys(n, 0, 50, gpa);
        defer CheatLib.freeSkewKeys(keys, gpa);
        try std.testing.expect(keys.len == 50);

        for (keys) |key| {
            const h = std.hash_map.hashString(key);
            try std.testing.expectEqual(@as(usize, 0), @as(usize, h) % n);
        }
    }
}

test "generateSkewKeys: keys are unique" {
    const gpa = std.heap.page_allocator;
    const keys = try CheatLib.generateSkewKeys(8, 0, 200, gpa);
    defer CheatLib.freeSkewKeys(keys, gpa);

    // Check uniqueness via a set
    var seen = std.StringHashMap(void).init(gpa);
    defer seen.deinit();

    for (keys) |key| {
        const result = try seen.getOrPut(key);
        try std.testing.expect(!result.found_existing);
    }
}
