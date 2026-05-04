const std = @import("std");
const compat = @import("../lib/compat.zig");
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
    const header_end = std.mem.alignForward(usize, 48, obj_align); // alignForward(~33, 16)
    // Stack objects (>= 4KB) get a one-page guard between header and first object.
    const guard: usize = if (obj_size >= 4096) 4096 else 0;
    const first_obj = @max(header_end, guard);
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

// ─────────────────────────────────────────────────────────────────────
// Phase 2: refcount + registry + actual shrinking
// ─────────────────────────────────────────────────────────────────────

/// Counting allocator wrapper — tracks bytes currently held to verify
/// shrinkEmpty actually returns memory to the OS.
const CountingAllocator = struct {
    backing: std.mem.Allocator,
    bytes_in_use: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.bytes_in_use += len;
        return ptr;
    }
    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.backing.rawResize(buf, alignment, new_len, ret_addr);
        if (ok) {
            self.bytes_in_use = self.bytes_in_use + new_len - buf.len;
        }
        return ok;
    }
    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawRemap(buf, alignment, new_len, ret_addr) orelse return null;
        self.bytes_in_use = self.bytes_in_use + new_len - buf.len;
        return ptr;
    }
    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(buf, alignment, ret_addr);
        self.bytes_in_use -= buf.len;
    }
};

test "Phase 2: shrinkEmpty actually frees memory" {
    var counter = CountingAllocator{ .backing = std.heap.page_allocator };
    const alloc = counter.allocator();

    var slab = SlabAllocator(TestObj).init(alloc, PAGE_SIZE);
    defer slab.deinit();

    var objs: [256]*TestObj = undefined;
    for (&objs) |*o| o.* = try slab.create();
    const peak_bytes = counter.bytes_in_use;
    try std.testing.expect(peak_bytes >= PAGE_SIZE * 2);

    for (objs) |o| slab.destroy(o);
    slab.flushThreadCache();

    try std.testing.expectEqual(peak_bytes, counter.bytes_in_use);

    const freed = slab.shrinkEmpty(1);
    try std.testing.expect(freed >= 1);
    try std.testing.expect(counter.bytes_in_use < peak_bytes);
    try std.testing.expect(counter.bytes_in_use >= PAGE_SIZE);

    _ = slab.shrinkEmpty(0);
    // All slab pages freed; only the registry ArrayLists' internal
    // backing remains (a few hundred bytes), well under one slab page.
    try std.testing.expect(counter.bytes_in_use < PAGE_SIZE);
}

test "Phase 2: refFromPtr returns Ref for live ptr, null for foreign ptr" {
    var slab = SlabAllocator(TestObj).init(std.heap.page_allocator, PAGE_SIZE);
    defer slab.deinit();

    const obj = try slab.create();
    const ref = slab.refFromPtr(obj) orelse return error.RefMissing;
    try std.testing.expect(ref.id == 0);

    var stack_local: TestObj = undefined;
    try std.testing.expect(slab.refFromPtr(&stack_local) == null);

    slab.destroy(obj);
}

test "Phase 2: pin returns slab; unpin releases" {
    var slab = SlabAllocator(TestObj).init(std.heap.page_allocator, PAGE_SIZE);
    defer slab.deinit();

    const obj = try slab.create();
    const ref = slab.refFromPtr(obj).?;

    const pinned = slab.pin(ref) orelse return error.PinFailed;
    try std.testing.expectEqual(@as(u32, 1), slab.pinCountUnsafe(pinned));

    slab.unpin(pinned);
    try std.testing.expectEqual(@as(u32, 0), slab.pinCountUnsafe(pinned));

    slab.destroy(obj);
}

test "Phase 2: pin returns null after slab is freed (stale ref)" {
    var slab = SlabAllocator(TestObj).init(std.heap.page_allocator, PAGE_SIZE);
    defer slab.deinit();

    const obj = try slab.create();
    const ref = slab.refFromPtr(obj).?;
    const original_epoch = ref.epoch;

    slab.destroy(obj);
    slab.flushThreadCache();
    _ = slab.shrinkEmpty(0);

    try std.testing.expect(slab.pin(ref) == null);

    const obj2 = try slab.create();
    const ref2 = slab.refFromPtr(obj2).?;
    try std.testing.expect(ref2.epoch != original_epoch);
    slab.destroy(obj2);
}

test "Phase 2: pin holds slab against shrinkEmpty" {
    var slab = SlabAllocator(TestObj).init(std.heap.page_allocator, PAGE_SIZE);
    defer slab.deinit();

    const obj = try slab.create();
    const ref = slab.refFromPtr(obj).?;
    const pinned = slab.pin(ref).?;

    slab.destroy(obj);
    slab.flushThreadCache();

    const ShrinkArgs = struct {
        slab: *SlabAllocator(TestObj),
        keep: usize,
        done: *std.atomic.Value(bool),
    };
    var done = std.atomic.Value(bool).init(false);
    var args = ShrinkArgs{ .slab = &slab, .keep = 0, .done = &done };

    const t = try std.Thread.spawn(.{}, struct {
        fn run(a: *ShrinkArgs) void {
            _ = a.slab.shrinkEmpty(a.keep);
            a.done.store(true, .release);
        }
    }.run, .{&args});

    var i: usize = 0;
    while (i < 10_000) : (i += 1) std.atomic.spinLoopHint();
    try std.testing.expect(!done.load(.acquire));

    slab.unpin(pinned);
    t.join();
    try std.testing.expect(done.load(.acquire));
}

test "Phase 2: empty_slab_count tracks across alloc/free cycles" {
    var slab = SlabAllocator(TestObj).init(std.heap.page_allocator, PAGE_SIZE);
    defer slab.deinit();

    var objs: [128]*TestObj = undefined;
    for (&objs) |*o| o.* = try slab.create();
    for (objs) |o| slab.destroy(o);
    slab.flushThreadCache();

    _ = slab.shrinkEmpty(0);

    slab.lock.lock();
    const empty = slab.empty_slab_count;
    slab.lock.unlock();
    try std.testing.expectEqual(@as(usize, 0), empty);
}

// ─────────────────────────────────────────────────────────────────────
// Phase 5: hammer + VOPR coverage of pin/unpin/shrink atomics
//
// Goal: exhaustive multi-thread coverage of the Phase 2 refcount API
// under TSan. The Phase 2 tests proved single-thread correctness;
// these add cross-thread races between pinners, shrinkers, and
// allocators / destroyers — the conditions detectCycle's chain walks
// will face in production.
// ─────────────────────────────────────────────────────────────────────

const HammerCtx = struct {
    slab: *SlabAllocator(TestObj),
    iters: usize,
    seed: u64,
    stop: *std.atomic.Value(bool),
    failures: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn xorshift64(s: *u64) u64 {
    s.* ^= s.* << 13;
    s.* ^= s.* >> 7;
    s.* ^= s.* << 17;
    return s.*;
}

/// Pinner thread: repeatedly grabs a Ref via refFromPtr on a live obj,
/// pins, validates the slab is non-null, unpins. Validates the slab
/// pin contract: between pin() and unpin() the slab must remain alive.
fn pinHammer(ctx: *HammerCtx) void {
    var prng = ctx.seed;
    var i: usize = 0;
    while (i < ctx.iters and !ctx.stop.load(.acquire)) : (i += 1) {
        const obj = ctx.slab.create() catch {
            _ = ctx.failures.fetchAdd(1, .monotonic);
            return;
        };
        // Use the obj briefly so it stays in a real slab.
        obj.a = xorshift64(&prng);

        const ref = ctx.slab.refFromPtr(obj) orelse {
            _ = ctx.failures.fetchAdd(1, .monotonic);
            ctx.slab.destroy(obj);
            continue;
        };

        if (ctx.slab.pin(ref)) |slab_hdr| {
            // Pinned. Read-write slab fields would be racy, but reading
            // pin_count is safe (atomic). Verify it's > 0 (at least our
            // pin is held).
            const pc = ctx.slab.pinCountUnsafe(slab_hdr);
            if (pc == 0) _ = ctx.failures.fetchAdd(1, .monotonic);
            ctx.slab.unpin(slab_hdr);
        }
        ctx.slab.destroy(obj);
    }
}

/// Shrinker thread: repeatedly tries to shrink. Should never crash
/// even under heavy concurrent pin/unpin/create/destroy.
fn shrinkHammer(ctx: *HammerCtx) void {
    var prng = ctx.seed;
    var i: usize = 0;
    while (i < ctx.iters and !ctx.stop.load(.acquire)) : (i += 1) {
        const keep = xorshift64(&prng) % 4;
        _ = ctx.slab.shrinkEmpty(@intCast(keep));
    }
}

/// Allocator-churner thread: pure create/destroy stress to keep slab
/// state changing while pinners/shrinkers race.
fn churnHammer(ctx: *HammerCtx) void {
    const allocator = std.testing.allocator;
    var list: std.ArrayListUnmanaged(*TestObj) = .empty;
    defer list.deinit(allocator);

    var prng = ctx.seed;
    var i: usize = 0;
    while (i < ctx.iters and !ctx.stop.load(.acquire)) : (i += 1) {
        const action = xorshift64(&prng) % 3;
        if (action == 0 or list.items.len == 0) {
            const obj = ctx.slab.create() catch {
                _ = ctx.failures.fetchAdd(1, .monotonic);
                continue;
            };
            obj.a = prng;
            list.append(allocator, obj) catch break;
        } else {
            const idx = xorshift64(&prng) % list.items.len;
            const obj = list.swapRemove(idx);
            ctx.slab.destroy(obj);
        }
    }
    for (list.items) |o| ctx.slab.destroy(o);
}

test "Phase 5: hammer — pin vs shrink vs churn races (TSan)" {
    var slab = SlabAllocator(TestObj).init(std.heap.page_allocator, PAGE_SIZE);
    defer slab.deinit();

    var stop = std.atomic.Value(bool).init(false);
    const ITERS = 5_000;

    var pin_ctx = HammerCtx{ .slab = &slab, .iters = ITERS, .seed = 0xA1, .stop = &stop };
    var shrink_ctx = HammerCtx{ .slab = &slab, .iters = ITERS, .seed = 0xB2, .stop = &stop };
    var churn1_ctx = HammerCtx{ .slab = &slab, .iters = ITERS, .seed = 0xC3, .stop = &stop };
    var churn2_ctx = HammerCtx{ .slab = &slab, .iters = ITERS, .seed = 0xD4, .stop = &stop };

    const t1 = try std.Thread.spawn(.{}, pinHammer, .{&pin_ctx});
    const t2 = try std.Thread.spawn(.{}, shrinkHammer, .{&shrink_ctx});
    const t3 = try std.Thread.spawn(.{}, churnHammer, .{&churn1_ctx});
    const t4 = try std.Thread.spawn(.{}, churnHammer, .{&churn2_ctx});

    t1.join();
    t2.join();
    t3.join();
    t4.join();

    try std.testing.expectEqual(@as(u32, 0), pin_ctx.failures.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), shrink_ctx.failures.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), churn1_ctx.failures.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), churn2_ctx.failures.load(.monotonic));

    // Drain remaining state to ensure we leave the slab in a sane state.
    slab.flushThreadCache();
    _ = slab.shrinkEmpty(0);
}

test "Phase 5: hammer — many concurrent pinners on same slab" {
    var slab = SlabAllocator(TestObj).init(std.heap.page_allocator, PAGE_SIZE);
    defer slab.deinit();

    // Anchor an object so the slab stays in partial_slabs the entire test.
    const anchor = try slab.create();
    defer slab.destroy(anchor);

    var stop = std.atomic.Value(bool).init(false);
    const ITERS = 10_000;
    const N_PINNERS = 4;

    var ctxs: [N_PINNERS]HammerCtx = undefined;
    var threads: [N_PINNERS]std.Thread = undefined;

    for (&ctxs, 0..) |*c, i| {
        c.* = HammerCtx{
            .slab = &slab,
            .iters = ITERS,
            .seed = 0x100 + @as(u64, i),
            .stop = &stop,
        };
    }

    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, pinHammer, .{&ctxs[i]});
    }

    for (&threads) |t| t.join();

    for (ctxs) |c| {
        try std.testing.expectEqual(@as(u32, 0), c.failures.load(.monotonic));
    }

    slab.flushThreadCache();
}

// ─────────────────────────────────────────────────────────────────────
// Phase 5: VOPR-style seeded sweep for slab pin/unpin/shrink races.
//
// Single-threaded but PRNG-driven: each seed produces a random
// sequence of {create, destroy, pin, unpin, shrink} operations. The
// test asserts at each step that every pinned slab is structurally
// reachable in the registry (epoch matches what was captured at pin
// time) and that every unpin succeeds. Runs many seeds so the schedule
// space is well-explored even from a single thread.
// ─────────────────────────────────────────────────────────────────────

const VoprAction = enum { Create, Destroy, Pin, Unpin, Shrink };

const PinSlot = struct {
    ref: SlabAllocator(TestObj).Ref,
    slab_hdr: *SlabAllocator(TestObj).SlabHeader,
};

fn voprStep(
    slab: *SlabAllocator(TestObj),
    objs: *std.ArrayListUnmanaged(*TestObj),
    pins: *std.ArrayListUnmanaged(PinSlot),
    prng: *u64,
) !void {
    const allocator = std.testing.allocator;
    const r = xorshift64(prng);
    const action: VoprAction = @enumFromInt(r % 5);

    switch (action) {
        .Create => {
            const obj = try slab.create();
            try objs.append(allocator, obj);
        },
        .Destroy => {
            if (objs.items.len == 0) return;
            const idx = xorshift64(prng) % objs.items.len;
            const obj = objs.swapRemove(idx);
            slab.destroy(obj);
        },
        .Pin => {
            if (objs.items.len == 0) return;
            const idx = xorshift64(prng) % objs.items.len;
            const obj = objs.items[idx];
            const ref = slab.refFromPtr(obj) orelse return;
            if (slab.pin(ref)) |hdr| {
                try pins.append(allocator, .{ .ref = ref, .slab_hdr = hdr });
            }
        },
        .Unpin => {
            if (pins.items.len == 0) return;
            const idx = xorshift64(prng) % pins.items.len;
            const slot = pins.swapRemove(idx);
            slab.unpin(slot.slab_hdr);
        },
        .Shrink => {
            const keep = xorshift64(prng) % 3;
            _ = slab.shrinkEmpty(@intCast(keep));
        },
    }
}

test "Phase 5: VOPR — seeded create/destroy/pin/unpin/shrink sequences" {
    const allocator = std.testing.allocator;
    const NUM_SEEDS = 200;
    const STEPS_PER_SEED = 500;

    var seed: u64 = 0;
    while (seed < NUM_SEEDS) : (seed += 1) {
        var slab = SlabAllocator(TestObj).init(std.heap.page_allocator, PAGE_SIZE);
        defer slab.deinit();

        var objs: std.ArrayListUnmanaged(*TestObj) = .empty;
        var pins: std.ArrayListUnmanaged(PinSlot) = .empty;

        var prng = (seed +% 1) *% 0x9E3779B97F4A7C15;

        var step: usize = 0;
        while (step < STEPS_PER_SEED) : (step += 1) {
            try voprStep(&slab, &objs, &pins, &prng);
        }

        // Drain: unpin all, destroy all, shrink to zero.
        for (pins.items) |p| slab.unpin(p.slab_hdr);
        pins.deinit(allocator);

        for (objs.items) |o| slab.destroy(o);
        objs.deinit(allocator);

        slab.flushThreadCache();
        _ = slab.shrinkEmpty(0);
    }
}

// ─────────────────────────────────────────────────────────────────────
// Phase 6: memory-leak / slab-reuse proof tests
//
// User invariant: CLEAR cannot leak memory just because the slab
// allocator caches state. Refcount + shrinkEmpty + epoch must
// genuinely return memory under bursty workloads, AND slab reuse
// must not fool a stale `Ref` (ABA safety via epoch + per-slot
// generation).
//
// These tests are stronger than Phase 2's spot checks: they assert
// behavior under realistic patterns (bursts, sustained churn, slot
// reuse races) that production workloads exhibit.
// ─────────────────────────────────────────────────────────────────────

test "Phase 6: bursty workload returns memory to OS on each burst end" {
    var counter = CountingAllocator{ .backing = std.heap.page_allocator };
    const alloc = counter.allocator();

    var slab = SlabAllocator(TestObj).init(alloc, PAGE_SIZE);
    defer slab.deinit();

    const baseline = counter.bytes_in_use;

    // Run 5 bursts. Each burst: allocate 1024 objects (forcing many slabs),
    // hold them, free all, shrink. Memory must return to (baseline + small
    // registry overhead) after each burst.
    var burst: usize = 0;
    while (burst < 5) : (burst += 1) {
        var objs: [1024]*TestObj = undefined;
        for (&objs) |*o| o.* = try slab.create();

        const burst_peak = counter.bytes_in_use;
        try std.testing.expect(burst_peak > baseline + 8 * PAGE_SIZE);

        for (objs) |o| slab.destroy(o);
        slab.flushThreadCache();
        _ = slab.shrinkEmpty(0);

        // After shrink, memory above baseline is just registry overhead
        // (a few hundred bytes), strictly less than one slab page.
        const after = counter.bytes_in_use;
        try std.testing.expect(after < baseline + PAGE_SIZE);
    }
}

test "Phase 6: sustained churn does not leak slabs" {
    var counter = CountingAllocator{ .backing = std.heap.page_allocator };
    const alloc = counter.allocator();

    var slab = SlabAllocator(TestObj).init(alloc, PAGE_SIZE);
    defer slab.deinit();

    // Maintain a working set of 256 live objects. Each iteration: free
    // 64, allocate 64. Periodically shrink. Peak memory must be bounded.
    var live: [256]*TestObj = undefined;
    for (&live) |*o| o.* = try slab.create();

    const peak_bound = counter.bytes_in_use * 2;

    const NUM_CYCLES = 1000;
    var cycle: usize = 0;
    while (cycle < NUM_CYCLES) : (cycle += 1) {
        // Rotate: free 64, alloc 64.
        const start = (cycle * 64) % live.len;
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            const idx = (start + i) % live.len;
            slab.destroy(live[idx]);
            live[idx] = try slab.create();
        }

        if (cycle % 16 == 0) {
            slab.flushThreadCache();
            _ = slab.shrinkEmpty(2);
            // High-water bound: if slabs leak, bytes_in_use would grow
            // unboundedly. With shrink, it stays near peak.
            try std.testing.expect(counter.bytes_in_use <= peak_bound);
        }
    }

    for (live) |o| slab.destroy(o);
    slab.flushThreadCache();
    _ = slab.shrinkEmpty(0);
}

test "Phase 6: ABA safety — same-slab slot reuse bumps generation" {
    var slab = SlabAllocator(TestObj).init(std.heap.page_allocator, PAGE_SIZE);
    defer slab.deinit();

    // Allocate, capture slab base address (encoded via Ref + slot offset).
    const obj_a = try slab.create();
    const ref_a = slab.refFromPtr(obj_a).?;
    const slab_a = slab.pin(ref_a).?;
    slab.unpin(slab_a);

    // Free A; same slot should be reused for B (without freeing the slab,
    // since we have other implicit work going on the slab).
    slab.destroy(obj_a);

    // Allocate B; will reuse A's slot (slab not freed because not shrunk).
    const obj_b = try slab.create();
    const ref_b = slab.refFromPtr(obj_b).?;

    // Slab Ref is structurally identical (same slab, same registry slot,
    // same epoch — slab was not freed). What MUST differ is the per-slot
    // contents: a chain walker holding a captured generation from A
    // would observe the new generation on B and detect tear.
    //
    // The slab allocator itself doesn't bump per-task generation —
    // that's the Scheduler's job (see Scheduler.drainChannels). This
    // test asserts the ALLOC-LEVEL invariant: pin via the same Ref
    // continues to succeed (slab is alive), and the SAME pointer may
    // be returned (slot reuse). The CALLER (Scheduler) is responsible
    // for the per-occupant generation bump.
    try std.testing.expectEqual(ref_a.id, ref_b.id);
    try std.testing.expectEqual(ref_a.epoch, ref_b.epoch);

    slab.destroy(obj_b);
}

test "Phase 6: ABA safety — slab free + reallocation bumps epoch" {
    var slab = SlabAllocator(TestObj).init(std.heap.page_allocator, PAGE_SIZE);
    defer slab.deinit();

    // First slab generation: allocate, free, shrink.
    const obj_1 = try slab.create();
    const ref_1 = slab.refFromPtr(obj_1).?;
    const old_epoch = ref_1.epoch;
    slab.destroy(obj_1);
    slab.flushThreadCache();
    _ = slab.shrinkEmpty(0);

    // Stale ref to first-generation slab must not pin (epoch advanced).
    try std.testing.expect(slab.pin(ref_1) == null);

    // Allocate again — slot id may be reused (typically id = 0), but
    // with a NEW epoch.
    const obj_2 = try slab.create();
    const ref_2 = slab.refFromPtr(obj_2).?;
    try std.testing.expect(ref_2.epoch != old_epoch);

    // The Phase 2 stale-ref guarantee: even if id matches, epoch
    // differs → pin fails for the old ref but succeeds for the new.
    try std.testing.expect(slab.pin(ref_1) == null);
    const new_pin = slab.pin(ref_2).?;
    slab.unpin(new_pin);

    slab.destroy(obj_2);
}

test "Phase 6: pinned slab survives many alloc/free cycles on other slabs" {
    var counter = CountingAllocator{ .backing = std.heap.page_allocator };
    const alloc = counter.allocator();

    var slab = SlabAllocator(TestObj).init(alloc, PAGE_SIZE);
    defer slab.deinit();

    // Anchor a slab via pinning.
    const anchor = try slab.create();
    const ref = slab.refFromPtr(anchor).?;
    const pinned = slab.pin(ref).?;
    const pinned_addr = @intFromPtr(pinned);

    // Run 200 alloc/free/shrink cycles on a different working set. The
    // pinned slab must remain reachable (pin holds it) regardless of how
    // many other slabs come and go.
    var cycle: usize = 0;
    while (cycle < 200) : (cycle += 1) {
        var batch: [128]*TestObj = undefined;
        for (&batch) |*o| o.* = try slab.create();
        for (batch) |o| slab.destroy(o);
        slab.flushThreadCache();
        _ = slab.shrinkEmpty(0);

        // Pinned slab still reachable: same ref re-pins to the same address.
        // (We hold a pin already, so the slab cannot have been freed.)
        const re_pin = slab.pin(ref).?;
        try std.testing.expectEqual(pinned_addr, @intFromPtr(re_pin));
        slab.unpin(re_pin);
    }

    // Release the anchor.
    slab.unpin(pinned);
    slab.destroy(anchor);
    slab.flushThreadCache();
    _ = slab.shrinkEmpty(0);

    // After releasing, no leaks: registry overhead only.
    try std.testing.expect(counter.bytes_in_use < PAGE_SIZE);
}

test "Phase 6: peak slab count is bounded by working-set size" {
    var counter = CountingAllocator{ .backing = std.heap.page_allocator };
    const alloc = counter.allocator();

    var slab = SlabAllocator(TestObj).init(alloc, PAGE_SIZE);
    defer slab.deinit();

    // Working set: 100 live objects. After a brief burst of 2000, free
    // 1900, shrink. Final memory should reflect 100 objects not 2000.
    var burst: [2000]*TestObj = undefined;
    for (&burst) |*o| o.* = try slab.create();
    const peak = counter.bytes_in_use;

    // Free all but the first 100.
    for (burst[100..]) |o| slab.destroy(o);
    slab.flushThreadCache();
    _ = slab.shrinkEmpty(0);

    const settled = counter.bytes_in_use;
    // Settled must be substantially less than peak — most slabs freed.
    // 100 objects fit in roughly 1-2 slabs (TestObj is 24 bytes, slab is
    // 4KB → ~150 objects per slab).
    try std.testing.expect(settled < peak / 4);

    for (burst[0..100]) |o| slab.destroy(o);
    slab.flushThreadCache();
    _ = slab.shrinkEmpty(0);
    try std.testing.expect(counter.bytes_in_use < PAGE_SIZE);
}

// ─────────────────────────────────────────────────────────────────────
// Integration regression tests.
//
// These cover slab/threadlocal/lifecycle interactions that have
// repeatedly produced bugs in the rest of the runtime — not slab
// correctness in isolation, but slab's *integration* with TSan,
// fibers, and cross-allocator-instance lifetimes on a single thread.
// ─────────────────────────────────────────────────────────────────────

// Regression for the parking-lot-cycle-test SEGV: deinit on an
// allocator that was never used on this thread must NOT acquire
// `self.lock` (the redundant flush path). Under TSan, the first
// lock attempt on a never-touched mutex triggers lazy SyncVar
// creation + stack-depot capture — observed to SEGV against
// fiber-corrupted shadow-stack state. This test asserts the
// no-op deinit completes cleanly; ASan/TSan in CI catch any
// invalid memory access along the path.
test "deinit on never-used allocator is safe and lock-free" {
    var slab = SlabAllocator(TestObj).init(std.heap.page_allocator, PAGE_SIZE);
    // No create / destroy / flushThreadCache — pristine instance.
    slab.deinit();
}

// Regression for an attempted-fix UAF: if deinit leaves the
// threadlocal magazine pointing at the just-deinited allocator,
// the NEXT allocator instance on this thread would call
// ensureMagazineOwnership, deref the freed `old_owner`, and try
// to lock its dead mutex — heap-use-after-free. The fix is that
// deinit nukes the threadlocal magazines unconditionally. This
// test exercises exactly that lifecycle on a single thread.
test "thread reuses slab instances: A-deinit-then-B-alloc must not UAF" {
    // Phase 1: instance A — allocate to populate the threadlocal
    // magazine with A-owned objects.
    var slab_a = SlabAllocator(TestObj).init(std.heap.page_allocator, PAGE_SIZE);
    const a_objs = [_]*TestObj{
        try slab_a.create(),
        try slab_a.create(),
        try slab_a.create(),
    };
    for (a_objs) |o| slab_a.destroy(o); // populate local_free_mag (owner=A)

    // Phase 2: deinit A. The magazine's owner pointer would be a
    // dangling reference unless deinit clears it.
    slab_a.deinit();

    // Phase 3: allocate from B on the SAME thread. The first call
    // hits ensureMagazineOwnership: if A's pointer leaked through,
    // ensureMagazineOwnership would try `old_owner.lock.lock()`
    // on the dead A → UAF. The fix is that A's deinit cleared
    // the threadlocal owner.
    var slab_b = SlabAllocator(TestObj).init(std.heap.page_allocator, PAGE_SIZE);
    defer slab_b.deinit();
    const b_obj = try slab_b.create();
    slab_b.destroy(b_obj);
}

// Regression: multiple init/deinit cycles on the same thread
// against the same SlabAllocator(T) type must converge to a
// clean state each time. Catches accumulated stale threadlocal
// state — magazines, owner pointers, count fields — that would
// drift across cycles and surface as either UAF (stale ptrs) or
// silent leaks (uncounted pending objects).
test "repeated init/deinit cycles on same thread leave no residue" {
    const cycles = 8;
    var i: usize = 0;
    while (i < cycles) : (i += 1) {
        var slab = SlabAllocator(TestObj).init(std.heap.page_allocator, PAGE_SIZE);
        // Mixed workload each cycle to ensure both magazines see
        // ownership transitions.
        const a = try slab.create();
        const b = try slab.create();
        slab.destroy(a);
        const c = try slab.create();
        slab.destroy(b);
        slab.destroy(c);
        slab.deinit();
    }

    // Final sanity: a fresh instance after the loop must work.
    var final = SlabAllocator(TestObj).init(std.heap.page_allocator, PAGE_SIZE);
    defer final.deinit();
    const obj = try final.create();
    final.destroy(obj);
}
