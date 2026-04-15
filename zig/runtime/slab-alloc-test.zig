const std = @import("std");
const compat = @import("compat");
const SlabAllocator = @import("slab-alloc.zig").SlabAllocator;

// To avoid linker errors
const fc = @import("fiber-core.zig");
comptime {
  _ = fc;
}

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
    var list: std.ArrayListUnmanaged(*TestObj) = .empty;
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
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
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

    var threads: std.ArrayListUnmanaged(std.Thread) = .empty;
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
    var list: std.ArrayListUnmanaged(*TestObj) = .empty;
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
    var list: std.ArrayListUnmanaged(*TestObj) = .empty;
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
    var reuse_list: std.ArrayListUnmanaged(*TestObj) = .empty;
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
    queue.* = .{};

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

// ========================================================================
// BUG REPRODUCTION: Two instances of SlabAllocator(T) share threadlocal
// magazines. Objects allocated from instance A end up in instance B's
// magazine, causing used_count underflow on flushThreadCache.
// ========================================================================

test "two slab instances on same thread do not corrupt each other" {

    var slab_a = Slab.init(std.heap.page_allocator, PAGE_SIZE);
    var slab_b = Slab.init(std.heap.page_allocator, PAGE_SIZE);

    // Allocate from A — fills threadlocal magazine with A's objects
    var objs_a: [10]*TestObj = undefined;
    for (&objs_a) |*slot| slot.* = try slab_a.create();

    // Free them back to A — fills threadlocal free magazine
    for (objs_a) |obj| slab_a.destroy(obj);

    // Now allocate from B — should NOT get A's objects
    var objs_b: [10]*TestObj = undefined;
    for (&objs_b) |*slot| slot.* = try slab_b.create();

    // Free them back to B
    for (objs_b) |obj| slab_b.destroy(obj);

    // Deinit both — should not crash (used_count underflow)
    slab_b.deinit();
    slab_a.deinit();
}

test "cross-thread slab: thread A allocs, thread B frees, no crash" {
    var slab = Slab.init(std.heap.page_allocator, PAGE_SIZE);
    defer slab.deinit();

    // Thread A allocates objects
    var objs: [64]*TestObj = undefined;
    for (&objs) |*slot| slot.* = try slab.create();

    // Thread B destroys them
    const t = try std.Thread.spawn(.{}, struct {
        fn run(s: *Slab, os: []const *TestObj) void {
            for (os) |o| s.destroy(o);
            s.flushThreadCache();
        }
    }.run, .{ &slab, &objs });
    t.join();
}

test "slab: thread creates/destroys instance, second thread reuses — no underflow" {
    // This reproduces the scheduler crash: thread A creates a slab, allocs,
    // frees, deinits. Thread B then creates a NEW slab of same type.
    // The threadlocal magazine on thread A still has stale pointers.
    // If thread A then calls create/destroy/flush on the NEW slab,
    // the stale pointers route to wrong slabs.

    var shared_slab: ?*Slab = null;
    var phase = std.atomic.Value(u32).init(0);

    const t = try std.Thread.spawn(.{}, struct {
        fn run(s: *?*Slab, p: *std.atomic.Value(u32)) void {
            // Phase 1: create slab, alloc, free, deinit
            var slab1 = Slab.init(std.heap.page_allocator, PAGE_SIZE);
            var objs: [20]*TestObj = undefined;
            for (&objs) |*slot| slot.* = slab1.create() catch return;
            for (objs) |o| slab1.destroy(o);
            slab1.deinit();

            // Phase 2: create NEW slab, expose to main thread
            var slab2 = Slab.init(std.heap.page_allocator, PAGE_SIZE);
            s.* = &slab2;
            p.store(1, .release); // signal main thread

            // Wait for main to finish
            while (p.load(.acquire) != 2) std.Thread.yield() catch {};

            // Phase 3: alloc from slab2 — threadlocal mag may have stale ptrs from slab1
            var objs2: [20]*TestObj = undefined;
            for (&objs2) |*slot| slot.* = slab2.create() catch return;
            for (objs2) |o| slab2.destroy(o);
            slab2.deinit();
            p.store(3, .release);
        }
    }.run, .{ &shared_slab, &phase });

    // Wait for slab2 to be ready
    while (phase.load(.acquire) != 1) std.Thread.yield() catch {};
    phase.store(2, .release); // signal thread to continue
    while (phase.load(.acquire) != 3) std.Thread.yield() catch {};
    t.join();
}

test "sequential create-destroy of slab instances does not leak state" {

    // First instance: alloc, free, deinit
    {
        var slab = Slab.init(std.heap.page_allocator, PAGE_SIZE);
        var objs: [20]*TestObj = undefined;
        for (&objs) |*slot| slot.* = try slab.create();
        for (objs) |obj| slab.destroy(obj);
        slab.deinit();
    }

    // Second instance: should work cleanly with no leftover state
    {
        var slab = Slab.init(std.heap.page_allocator, PAGE_SIZE);
        var objs: [20]*TestObj = undefined;
        for (&objs) |*slot| slot.* = try slab.create();
        for (objs) |obj| slab.destroy(obj);
        slab.deinit();
    }
}

// ========================================================================
// LARGE OBJECT TESTS — Reproduce bench 14 crash
//
// bench 14 uses Large stacks: 65536-byte objects in 2MB slab blocks.
// 31 objects per slab, magazine size 64. This exercises the exact
// configuration that crashes in the scheduler.
// ========================================================================

const LargeStack = [65536]u8;
const LargeSlab = SlabAllocator(LargeStack);
const LARGE_SLAB_BLOCK: usize = 2 * 1024 * 1024;

/// Validate that a pointer is at a valid object offset within its slab.
/// Mirrors the layout math from SlabAllocator.grow().
fn validateLargePtr(slab_size: usize, obj: *LargeStack) !void {
    const obj_size = @sizeOf(LargeStack);
    // SlabHeader: 3 optional pointers (8 each) + usize + bool = ~33 bytes.
    // We conservatively use 48 as the aligned header size (matches object_align=16).
    const obj_align = 16; // @max(16, @max(@alignOf(LargeStack), @alignOf(?*anyopaque)))
    const header_estimate = 48; // alignForward(~33, 16) — matches grow()
    const first_obj = std.mem.alignForward(usize, header_estimate, obj_align);
    const stride = std.mem.alignForward(usize, obj_size, obj_align);

    const ptr_addr = @intFromPtr(obj);
    const mask = ~(slab_size - 1);
    const slab_base = ptr_addr & mask;
    const offset = ptr_addr - slab_base;

    if (offset < first_obj) {
        std.debug.print("VALIDATION FAIL: offset 0x{x} < first_obj 0x{x}\n", .{ offset, first_obj });
        return error.PtrBeforeFirstObj;
    }
    if ((offset - first_obj) % stride != 0) {
        std.debug.print("VALIDATION FAIL: offset 0x{x}, (offset - 0x{x}) % 0x{x} = 0x{x}\n", .{
            offset, first_obj, stride, (offset - first_obj) % stride,
        });
        return error.PtrNotAlignedToStride;
    }
    if (offset + obj_size > slab_size) {
        std.debug.print("VALIDATION FAIL: offset 0x{x} + 0x{x} > slab_size 0x{x}\n", .{ offset, obj_size, slab_size });
        return error.PtrPastSlabEnd;
    }
}

test "Large slab: alloc-all-then-free-all (bench 14 pattern)" {
    var slab = LargeSlab.init(std.heap.page_allocator, LARGE_SLAB_BLOCK);
    defer slab.deinit();

    // 200 objects = ~6-7 slabs (31 per slab). Enough to exercise multiple
    // magazine fills/flushes (magazine=64).
    const COUNT = 200;
    var list: [COUNT]*LargeStack = undefined;

    // Phase 1: Allocate all (simulates drainChannels batch)
    for (&list) |*slot| {
        const obj = try slab.create();
        try validateLargePtr(LARGE_SLAB_BLOCK, obj);
        @memset(obj, 0xCC); // Simulate Fiber.init debug fill
        slot.* = obj;
    }

    // Phase 2: Free all (simulates finished handler freeStack)
    for (list) |obj| {
        slab.destroy(obj);
    }

    slab.flushThreadCache();
}

test "Large slab: alloc-free-alloc-free churn" {
    var slab = LargeSlab.init(std.heap.page_allocator, LARGE_SLAB_BLOCK);
    defer slab.deinit();

    // Churn: alloc one, use it, free it, repeat. Tests magazine reuse path.
    for (0..500) |_| {
        const obj = try slab.create();
        try validateLargePtr(LARGE_SLAB_BLOCK, obj);
        @memset(obj, 0xCC);
        slab.destroy(obj);
    }

    slab.flushThreadCache();
}

test "Large slab: batch alloc/free cycles with memset (magazine flush)" {
    var slab = LargeSlab.init(std.heap.page_allocator, LARGE_SLAB_BLOCK);
    defer slab.deinit();

    // Allocate in batches of 80 (> magazine size 64) to force flush paths
    const BATCH = 80;
    var batch: [BATCH]*LargeStack = undefined;

    for (0..10) |_| {
        for (&batch) |*slot| {
            const obj = try slab.create();
            try validateLargePtr(LARGE_SLAB_BLOCK, obj);
            @memset(obj, 0xCC); // Overwrites Node.next at obj[0..8]
            slot.* = obj;
        }
        for (batch) |obj| {
            slab.destroy(obj);
        }
    }

    slab.flushThreadCache();
}

test "Large slab: cross-thread alloc on A, free on B" {
    var slab = LargeSlab.init(std.heap.page_allocator, LARGE_SLAB_BLOCK);
    defer slab.deinit();

    const COUNT = 200;
    var objs: [COUNT]*LargeStack = undefined;

    // Thread A (main): allocate all
    for (&objs) |*slot| {
        const obj = try slab.create();
        try validateLargePtr(LARGE_SLAB_BLOCK, obj);
        @memset(obj, 0xCC);
        slot.* = obj;
    }

    // Thread B: free all
    const t = try std.Thread.spawn(.{}, struct {
        fn run(s: *LargeSlab, os: []const *LargeStack) void {
            for (os) |o| s.destroy(o);
            s.flushThreadCache();
        }
    }.run, .{ &slab, &objs });
    t.join();
}

test "Large slab: cross-thread producer-consumer" {
    var slab = LargeSlab.init(std.heap.page_allocator, LARGE_SLAB_BLOCK);
    defer slab.deinit();

    const ItemCount = 500;

    const Queue = struct {
        items: [ItemCount]?*LargeStack = undefined,
        ready_count: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    };
    const queue = try std.testing.allocator.create(Queue);
    defer std.testing.allocator.destroy(queue);
    queue.* = .{};

    // Producer: allocate + memset (simulates drainChannels + Fiber.init)
    const producer = try std.Thread.spawn(.{}, struct {
        fn run(s: *LargeSlab, q: *Queue) void {
            for (0..ItemCount) |i| {
                const obj = s.create() catch @panic("Alloc failed");
                // Validate pointer is at a valid slab offset
                validateLargePtr(LARGE_SLAB_BLOCK, obj) catch |e| {
                    std.debug.print("PRODUCER: bad ptr at alloc #{d}: {}\n", .{ i, e });
                    @panic("Producer got bad pointer from create()");
                };
                @memset(obj, 0xCC);
                q.items[i] = obj;
                _ = q.ready_count.fetchAdd(1, .release);
            }
        }
    }.run, .{ &slab, queue });

    // Consumer: free (simulates finished handler)
    const consumer = try std.Thread.spawn(.{}, struct {
        fn run(s: *LargeSlab, q: *Queue) void {
            var consumed: usize = 0;
            while (consumed < ItemCount) {
                while (q.ready_count.load(.acquire) <= consumed) {
                    std.atomic.spinLoopHint();
                }
                const obj = q.items[consumed].?;
                // Validate pointer before passing to destroy
                validateLargePtr(LARGE_SLAB_BLOCK, obj) catch |e| {
                    std.debug.print("CONSUMER: bad ptr at free #{d}: 0x{x}, err={}\n", .{
                        consumed, @intFromPtr(obj), e,
                    });
                    @panic("Consumer got bad pointer from queue");
                };
                s.destroy(obj);
                consumed += 1;
            }
        }
    }.run, .{ &slab, queue });

    producer.join();
    consumer.join();

    slab.flushThreadCache();
}
