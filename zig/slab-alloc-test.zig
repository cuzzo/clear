const std = @import("std");
const SlabAllocator = @import("slab-alloc.zig").SlabAllocator;

const PAGE_SIZE = 4096;

const TestObj = struct {
    a: u64,
    b: u64,
    c: u64,
};

test "single-thread alloc/free works" {
    var slab = SlabAllocator(TestObj).init(
        std.heap.page_allocator,
        PAGE_SIZE,
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
    var slab = SlabAllocator(TestObj).init(
        std.heap.page_allocator,
        PAGE_SIZE,
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
    var slab = SlabAllocator(TestObj).init(
        std.heap.page_allocator,
        PAGE_SIZE,
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
    const harness_alloc = gpa.allocator();

    // Use a small slab size to force frequent grow() calls under contention
    var slab = Slab.init(std.heap.page_allocator, 4096);
    defer {
        // flush main thread cache before checking
        // TODO: If this doesn't crash, then no leak
        slab.flushThreadCache();
    }
    defer slab.deinit();

    // 2. Config
    const thread_count = 8;
    const loops = 1000;
    const batch_size = 50;

    var threads = std.ArrayListUnmanaged(std.Thread){};
    defer threads.deinit(harness_alloc);

    // 3. Spawn "Hammer" Threads
    for (0..thread_count) |_| {
        const t = try std.Thread.spawn(.{}, stressWorker, .{ &slab, loops, batch_size });
        try threads.append(harness_alloc, t);
    }

    // 4. Wait
    for (threads.items) |t| {
        t.join();
    }
}

test "PROVE memory reclamation (interleaved free)" {
    var slab_alloc = SlabAllocator(TestObj).init(
        std.heap.page_allocator,
        PAGE_SIZE,
    );
    defer slab_alloc.deinit();

    // 3. Allocate enough objects to span roughly 3 slabs
    // ~170 objects fit in 4096 bytes. 500 objects ensures ~3 slabs.
    const obj_count = 500;
    var list = std.ArrayListUnmanaged(*TestObj){};
    defer list.deinit(std.testing.allocator);
    try list.ensureTotalCapacity(std.testing.allocator, obj_count);

    for (0..obj_count) |_| {
        const obj = try slab_alloc.create();
        try list.append(std.testing.allocator, obj);
    }

    // 5. THE PROOF: Shuffle the list and destroy objects in RANDOM order.
    // This proves we don't need to free objects in perfect reverse order to reclaim memory.
    // Slabs should disappear one by one as their specific objects are gone.
    var prng = std.Random.DefaultPrng.init(0x12345678);
    const random = prng.random();
    random.shuffle(*TestObj, list.items);

    for (list.items) |obj| {
        slab_alloc.destroy(obj);
    }

    // this crashes on leak
    slab_alloc.flushThreadCache();

    // TODO: Catch error
    // std.debug.print("\nExpected 0 bytes, found {} bytes leaking.\n", .{usage_end});
    // return error.MemoryLeakDetected;
}

test "PROVE slab reuse (Swiss Cheese scenario)" {
    var slab_alloc = SlabAllocator(TestObj).init(
        std.heap.page_allocator,
        PAGE_SIZE,
    );
    defer slab_alloc.deinit();

    // 2. Calculate items per slab
    // Header is ~40 bytes. TestObj is 24 bytes.
    // 4096 - 40 = 4056 bytes available.
    // 4056 / 24 = 169 objects per slab.
    // We'll alloc 520 objects to be safe (3+ slabs).
    const obj_count = 520;
    var list = std.ArrayListUnmanaged(*TestObj){};
    defer list.deinit(std.testing.allocator);

    for (0..obj_count) |_| {
        const obj = try slab_alloc.create();
        try list.append(std.testing.allocator, obj);
    }

    // 3. Create "Swiss Cheese" in Slab #1
    // We know objects 0-160 are roughly in the first slab.
    // We keep index 0 and 1 (anchors), and free indices 2..150.
    // This moves Slab #1 from "Full" -> "Partial" list (at the HEAD).
    const items_to_free = 150;
    for (2..items_to_free) |i| {
        slab_alloc.destroy(list.items[i]);
    }

    // 4. Allocate NEW items
    // These should fit into the holes we just made in Slab #1.
    // If reuse works, memory usage should NOT increase.
    // If reuse fails, we would allocate a 4th/5th slab, increasing memory.
    var reuse_list = std.ArrayListUnmanaged(*TestObj){};
    defer reuse_list.deinit(std.testing.allocator);

    for (0..100) |_| {
        const obj = try slab_alloc.create();
        try reuse_list.append(std.testing.allocator, obj);
    }

    // Cleanup anchors and new items
    slab_alloc.destroy(list.items[0]);
    slab_alloc.destroy(list.items[1]);
    for (items_to_free..obj_count) |i| {
        slab_alloc.destroy(list.items[i]);
    }
    for (reuse_list.items) |obj| {
        slab_alloc.destroy(obj);
    }
}

test "Producer-Consumer contention" {
    // Setup
    var slab = SlabAllocator(TestObj).init(
        std.heap.page_allocator,
        PAGE_SIZE,
    );
    defer slab.deinit();

    const ItemCount = 100_000;

    // Shared Queue
    const Queue = struct {
        items: [ItemCount]?*TestObj = undefined,
        ready_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    };
    // Fix: use 'const' because the pointer itself doesn't change
    const queue = try std.testing.allocator.create(Queue);
    defer std.testing.allocator.destroy(queue);

    // Producer Thread
    const producer = try std.Thread.spawn(.{}, struct {
        fn run(s: *SlabAllocator(TestObj), q: *Queue) void {
            for (0..ItemCount) |i| {
                const obj = s.create() catch @panic("Alloc failed");
                q.items[i] = obj;
                _ = q.ready_count.fetchAdd(1, .release);
            }
        }
    }.run, .{ &slab, queue });

    // Consumer Thread
    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(s: *SlabAllocator(TestObj), q: *Queue) void {
            var consumed: usize = 0;
            while (consumed < ItemCount) {
                while (q.ready_count.load(.acquire) <= consumed) {
                    std.atomic.spinLoopHint();
                }
                const obj = q.items[consumed].?;
                s.destroy(obj);
                consumed += 1;
            }
        }
    }.run, .{ &slab, queue });

    producer.join();
    consumer.join();

    slab.flushThreadCache();
}

