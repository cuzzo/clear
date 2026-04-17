const std = @import("std");
const compat = @import("../lib/compat.zig");
const SlabAllocator = @import("slab-alloc.zig").SlabAllocator;

const BenchObj = struct {
    // 32 bytes payload
    a: u64, b: u64, c: u64, d: u64,
};

test "BENCHMARK: Slab vs GPA (Run with -O ReleaseFast)" {
    const allocator = std.testing.allocator;
    const ITERATIONS = 1_000_000;
    const thread_counts = [_]usize{ 1, 2, 4, 8, 16 };

    std.debug.print("\n\n{s:-<75}\n", .{""});
    std.debug.print("{s:<10} | {s:<20} | {s:<20} | {s:<20}\n", .{ "Threads", "GPA (ops/sec)", "Malloc (ops/sec)", "Slab (ops/sec)" });
    std.debug.print("{s:-<75}\n", .{""});

    for (thread_counts) |t_count| {
        // --- 1. Measure GPA ---
        var gpa = std.heap.DebugAllocator(.{}){};
        defer _ = gpa.deinit();

        const gpa_ops = try runBenchGPA(gpa.allocator(), t_count, ITERATIONS);

        // --- 2. Measure C Malloc ---
        // std.heap.c_allocator wraps libc malloc/free
        const c_ops = try runBenchGeneric(std.heap.c_allocator, t_count, ITERATIONS);

        // --- 3. Measure Slab ---
        var slab = SlabAllocator(BenchObj).init(allocator, 64 * 1024);
        defer slab.deinit();
        const slab_ops = try runBenchSlab(&slab, t_count, ITERATIONS);

        std.debug.print("{d:<10} | {d:<20} | {d:<20} | {d:<20}\n", .{ t_count, gpa_ops, c_ops, slab_ops });
    }
    std.debug.print("{s:-<75}\n\n", .{""});
}

fn runBenchGPA(allocator: std.mem.Allocator, thread_count: usize, total_iters: usize) !u64 {
    // Fix: Use ArrayListUnmanaged explicitly
    var threads = try std.ArrayListUnmanaged(std.Thread).initCapacity(std.testing.allocator, thread_count);
    defer threads.deinit(std.testing.allocator);

    const ops_per_thread = total_iters / thread_count;
    var timer = try compat.Timer.start();

    for (0..thread_count) |_| {
        const t = try std.Thread.spawn(.{}, workerGPA, .{ allocator, ops_per_thread });
        threads.appendAssumeCapacity(t);
    }

    for (threads.items) |t| t.join();

    const elapsed_ns = timer.read();
    if (elapsed_ns == 0) return 0;
    return @divTrunc((ops_per_thread * thread_count) * 1_000_000_000, elapsed_ns);
}

fn workerGPA(allocator: std.mem.Allocator, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const obj = allocator.create(BenchObj) catch @panic("GPA OOM");
        obj.a = i;
        allocator.destroy(obj);
    }
}

// Generic worker for GPA and C Allocator (they share the Allocator interface)
fn runBenchGeneric(allocator: std.mem.Allocator, thread_count: usize, total_iters: usize) !u64 {
    var threads = try std.ArrayListUnmanaged(std.Thread).initCapacity(std.testing.allocator, thread_count);
    defer threads.deinit(std.testing.allocator);

    const ops_per_thread = total_iters / thread_count;
    var timer = try compat.Timer.start();

    for (0..thread_count) |_| {
        const t = try std.Thread.spawn(.{}, workerGeneric, .{ allocator, ops_per_thread });
        threads.appendAssumeCapacity(t);
    }

    for (threads.items) |t| t.join();

    const elapsed_ns = timer.read();
    if (elapsed_ns == 0) return 0;
    return @divTrunc((ops_per_thread * thread_count) * 1_000_000_000, elapsed_ns);
}

fn workerGeneric(allocator: std.mem.Allocator, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const obj = allocator.create(BenchObj) catch @panic("OOM");
        obj.a = i;
        allocator.destroy(obj);
    }
}

fn runBenchSlab(slab: *SlabAllocator(BenchObj), thread_count: usize, total_iters: usize) !u64 {
    // Fix: Use ArrayListUnmanaged explicitly
    var threads = try std.ArrayListUnmanaged(std.Thread).initCapacity(std.testing.allocator, thread_count);
    defer threads.deinit(std.testing.allocator);

    const ops_per_thread = total_iters / thread_count;
    var timer = try compat.Timer.start();

    for (0..thread_count) |_| {
        const t = try std.Thread.spawn(.{}, workerSlab, .{ slab, ops_per_thread });
        threads.appendAssumeCapacity(t);
    }

    for (threads.items) |t| t.join();

    const elapsed_ns = timer.read();

    slab.flushThreadCache();

    if (elapsed_ns == 0) return 0;
    return @divTrunc((ops_per_thread * thread_count) * 1_000_000_000, elapsed_ns);
}

fn workerSlab(slab: *SlabAllocator(BenchObj), count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const obj = slab.create() catch @panic("Slab OOM");
        obj.a = i;
        slab.destroy(obj);
    }
}

