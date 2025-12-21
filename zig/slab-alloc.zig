const std = @import("std");

// Only ThreadSafe if allocator is ThreadSafeAllocator
pub fn SlabAllocator(comptime T: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            next: ?*Node,
        };

        allocator: std.mem.Allocator,
        slab_size: usize,
        free_list: ?*Node = null,
        slabs: std.ArrayListUnmanaged([]u8) = .{},
        lock: std.Thread.Mutex = .{},

        const object_size = @sizeOf(T);
        const object_align = @alignOf(T);

        pub fn init(
            allocator: std.mem.Allocator,
            slab_size: usize,
        ) Self {
            std.debug.assert(slab_size >= object_size);
            return .{
                .allocator = allocator,
                .slab_size = slab_size,
            };
        }

        pub fn deinit(self: *Self) void {
            self.lock.lock();
            defer self.lock.unlock();

            for (self.slabs.items) |slab| {
                self.allocator.free(slab);
            }
            self.slabs.deinit(self.allocator);
        }

        // ---------------------------------------------------------------------
        // TODO: Optimization for Another Day (High Contention)
        // ---------------------------------------------------------------------
        // Issue: Global Lock
        // Current implementation locks for every single alloc/free.
        // For < 50 threads, this is usually fine (nanosecond hold time).
        // For 100+ threads, this becomes a bottleneck.
        //
        // Fix: Thread-Local Caching
        // 1. Give every thread a small "local_free_list" (no lock needed).
        // 2. Only lock this global allocator when the local cache is empty or full.
        // ---------------------------------------------------------------------

        pub fn create(self: *Self) !*T {
            self.lock.lock();
            if (self.free_list) |node| {
                self.free_list = node.next;
                self.lock.unlock();
                const obj: *T = @ptrCast(node);
                return obj;
            }
            self.lock.unlock();

            try self.grow();

            self.lock.lock();
            defer self.lock.unlock();
            if (self.free_list) |node| {
                self.free_list = node.next;
                return @ptrCast(node);
            }

            return error.OutOfMemory;
        }

        // ---------------------------------------------------------------------
        // TODO: Feature for Another Day (Shrinking)
        // ---------------------------------------------------------------------
        // Issue: Memory Reclaim
        // Currently, we never return memory to the OS until deinit().
        // If the app spikes to 1GB usage, it stays at 1GB even if idle.
        //
        // Fix: Slab Headers & RefCounting
        // 1. Reserve the start of every slab for a Header { ref_count: usize, slab_ptr: ... }
        // 2. destroy(obj) calculates which slab owns 'obj', decrements ref_count.
        // 3. If ref_count == 0, free the slab.
        // ---------------------------------------------------------------------

        pub fn destroy(self: *Self, obj: *T) void {
            self.lock.lock();
            defer self.lock.unlock();

            const node: *Node = @ptrCast(obj);
            node.next = self.free_list;
            self.free_list = node;
        }

        fn grow(self: *Self) !void {
            const alignment = comptime std.mem.Alignment.fromByteUnits(object_align);
            const slab = try self.allocator.alignedAlloc(u8, alignment, self.slab_size);

            const stride = std.mem.alignForward(
                usize,
                object_size,
                object_align,
            );

            var chain_head: ?*Node = null;
            var chain_tail: ?*Node = null;
            var offset: usize = 0;

            while (offset + stride <= slab.len) {
                const raw_many: [*]u8 = slab.ptr + offset;

                // Convert many-pointer → single-pointer
                const raw_one: *u8 = @ptrCast(raw_many);

                // Prove alignment
                const aligned: *align(object_align) u8 = @alignCast(raw_one);

                // Reinterpret as Node
                const node: *Node = @ptrCast(aligned);

                node.next = chain_head;
                chain_head = node;

                if (chain_tail == null) chain_tail = node;

                offset += stride;
            }

            self.lock.lock();
            defer self.lock.unlock();

            // 1. Add slab to tracking list (Protected)
            self.slabs.append(self.allocator, slab) catch |err| {
                // If tracking fails, we must rollback allocations
                self.allocator.free(slab);
                return err;
            };

            // 2. Merge local chain into global free_list (Protected)
            if (chain_head) |head| {
                // The tail of our new chain points to the OLD global head
                chain_tail.?.next = self.free_list;
                // The global head becomes the START of our new chain
                self.free_list = head;
            }
        }
    };
}

