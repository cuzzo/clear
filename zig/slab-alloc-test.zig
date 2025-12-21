const std = @import("std");
const SlabAllocator = @import("slab-alloc.zig").SlabAllocator;

const TestObj = struct {
    a: u64,
    b: u64,
    c: u64,
};

test "single-thread alloc/free works" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var ts = std.heap.ThreadSafeAllocator{
        .child_allocator = gpa.allocator(),
    };

    var slab = SlabAllocator(TestObj).init(
        ts.allocator(),
        64 * 1024,
    );
    defer slab.deinit();

    const obj = try slab.create();
    obj.a = 1;
    obj.b = 2;
    obj.c = 3;

    try std.testing.expectEqual(@as(u64, 1), obj.a);
    try std.testing.expectEqual(@as(u64, 2), obj.b);
    try std.testing.expectEqual(@as(u64, 3), obj.c);

    slab.destroy(obj);
}

test "objects are reused from freelist" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var ts = std.heap.ThreadSafeAllocator{
        .child_allocator = gpa.allocator(),
    };

    var slab = SlabAllocator(TestObj).init(
        ts.allocator(),
        64 * 1024,
    );
    defer slab.deinit();

    const obj1 = try slab.create();
    slab.destroy(obj1);

    const obj2 = try slab.create();

    // Reuse is not guaranteed in theory, but in this implementation it should reuse
    try std.testing.expect(obj1 == obj2);

    slab.destroy(obj2);
}

test "alignment is respected" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var ts = std.heap.ThreadSafeAllocator{
        .child_allocator = gpa.allocator(),
    };

    var slab = SlabAllocator(TestObj).init(
        ts.allocator(),
        64 * 1024,
    );
    defer slab.deinit();

    const obj = try slab.create();
    const addr = @intFromPtr(obj);

    try std.testing.expect(addr % @alignOf(TestObj) == 0);

    slab.destroy(obj);
}

const Slab = SlabAllocator(TestObj);

fn stressWorker(slab: *Slab, loops: usize, allocs_per_loop: usize) !void {
    const allocator = std.testing.allocator;

    // Each thread gets its own random seed if needed, or just churns memory
    var list = std.ArrayListUnmanaged(*TestObj){};
    defer list.deinit(allocator);

    for (0..loops) |_| {
        // 1. Allocate a batch
        for (0..allocs_per_loop) |_| {
            const obj = try slab.create();
            // Scribble to prove exclusive access
            obj.a = 0xDEADBEEF;
            try list.append(allocator, obj);
        }

        // 2. Free a batch (churn)
        while (list.items.len > 0) {
            const obj = list.pop().?;
            // Verify our data wasn't corrupted by another thread
            if (obj.a != 0xDEADBEEF) @panic("Data Corruption detected!");
            slab.destroy( obj);
        }
    }
}

test "multi-threaded stress test" {
    // 1. Setup
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const check = gpa.deinit();
        if (check == .leak) @panic("Leak detected in Stress Test");
    }
    const allocator = gpa.allocator();

    // Use a small slab size to force frequent grow() calls under contention
    var slab = Slab.init(allocator, 4096);
    defer slab.deinit();

    // 2. Config
    const thread_count = 8;
    const loops = 1000;
    const batch_size = 50;

    var threads = std.ArrayListUnmanaged(std.Thread){};
    defer threads.deinit(allocator);

    // 3. Spawn "Hammer" Threads
    for (0..thread_count) |_| {
        const t = try std.Thread.spawn(.{}, stressWorker, .{ &slab, loops, batch_size });
        try threads.append(allocator, t);
    }

    // 4. Wait
    for (threads.items) |t| {
        t.join();
    }
}

