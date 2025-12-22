const std = @import("std");

pub fn SlabAllocator(comptime T: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            next: ?*Node,
        };

        const SlabHeader = struct {
            prev: ?*SlabHeader,
            next: ?*SlabHeader,
            free_head: ?*Node,
            used_count: usize,
            is_full: bool,
        };

        allocator: std.mem.Allocator,
        slab_size: usize,

        partial_slabs: ?*SlabHeader = null,
        full_slabs: ?*SlabHeader = null,

        lock: std.Thread.Mutex = .{},

        const object_size = @sizeOf(T);
        const object_align = @alignOf(T);

        pub fn init(allocator: std.mem.Allocator, slab_size: usize) Self {
            std.debug.assert(std.math.isPowerOfTwo(slab_size));
            const header_size = @sizeOf(SlabHeader);
            const first_obj_offset = std.mem.alignForward(usize, header_size, object_align);
            std.debug.assert(slab_size > first_obj_offset + object_size);

            return .{
                .allocator = allocator,
                .slab_size = slab_size,
            };
        }

        pub fn deinit(self: *Self) void {
            self.lock.lock();
            defer self.lock.unlock();

            var it = self.partial_slabs;
            while (it) |slab| {
                const next = slab.next;
                self.freeSlabMemory(slab);
                it = next;
            }
            it = self.full_slabs;
            while (it) |slab| {
                const next = slab.next;
                self.freeSlabMemory(slab);
                it = next;
            }
            self.partial_slabs = null;
            self.full_slabs = null;
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
            defer self.lock.unlock();

            if (self.partial_slabs) |slab| {
                const node = slab.free_head.?;
                slab.free_head = node.next;
                slab.used_count += 1;

                if (slab.free_head == null) {
                    self.removeSlab(slab, &self.partial_slabs);
                    self.prependSlab(slab, &self.full_slabs);
                    slab.is_full = true;
                }
                return @ptrCast(node);
            }

            const new_slab = try self.grow();
            const node = new_slab.free_head.?;
            new_slab.free_head = node.next;
            new_slab.used_count += 1;

            return @ptrCast(node);
        }

        pub fn destroy(self: *Self, obj: *T) void {
            self.lock.lock();
            defer self.lock.unlock();

            const ptr_addr = @intFromPtr(obj);
            const mask = ~(self.slab_size - 1);
            const header_addr = ptr_addr & mask;
            const slab = @as(*SlabHeader, @ptrFromInt(header_addr));

            const node: *Node = @ptrCast(obj);
            node.next = slab.free_head;
            slab.free_head = node;
            slab.used_count -= 1;

            if (slab.used_count == 0) {
                if (slab.is_full) {
                    self.removeSlab(slab, &self.full_slabs);
                } else {
                    self.removeSlab(slab, &self.partial_slabs);
                }
                self.freeSlabMemory(slab);
            } else if (slab.is_full) {
                self.removeSlab(slab, &self.full_slabs);
                self.prependSlab(slab, &self.partial_slabs);
                slab.is_full = false;
            }
        }

        fn grow(self: *Self) !*SlabHeader {
            // Allocate raw memory with correct alignment
            const bytes = try self.allocAligned(self.slab_size);

            // Cast Chain:
            // 1. [*]u8 (slice ptr) -> *u8 (single ptr)
            const raw_single_ptr: *u8 = @ptrCast(bytes.ptr);
            // 2. Assert Alignment (*u8 -> *align(8) u8)
            const aligned_ptr: *align(@alignOf(SlabHeader)) u8 = @alignCast(raw_single_ptr);
            // 3. Cast to Struct (*align(8) u8 -> *SlabHeader)
            const slab: *SlabHeader = @ptrCast(aligned_ptr);

            slab.* = .{
                .prev = null,
                .next = null,
                .free_head = null,
                .used_count = 0,
                .is_full = false,
            };

            const header_size = @sizeOf(SlabHeader);
            var offset = std.mem.alignForward(usize, header_size, object_align);

            while (offset + object_size <= self.slab_size) {
                const node_addr = @intFromPtr(slab) + offset;
                const node: *Node = @ptrFromInt(node_addr);
                node.next = slab.free_head;
                slab.free_head = node;
                offset += std.mem.alignForward(usize, object_size, object_align);
            }

            self.prependSlab(slab, &self.partial_slabs);
            return slab;
        }

        fn allocAligned(self: *Self, size: usize) ![]u8 {
            return switch (size) {
                4096 => self.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), 4096),
                8192 => self.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(8192), 8192),
                16384 => self.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(16384), 16384),
                32768 => self.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(32768), 32768),
                65536 => self.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(65536), 65536),
                131072 => self.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(131072), 131072),
                262144 => self.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(262144), 262144),
                524288 => self.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(524288), 524288),
                1048576 => self.allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(1048576), 1048576),
                else => error.InvalidSlabSize,
            };
        }

        fn freeSlabMemory(self: *Self, slab: *SlabHeader) void {
            const raw_ptr: [*]u8 = @ptrCast(slab);

            // BUG FIX: We cast to `[*]align(...)` (Many-Pointer), NOT `*align(...)` (Single-Pointer).
            // This allows us to perform the slice syntax `[0..size]` below.
            switch (self.slab_size) {
                4096 => {
                    const p: [*]align(4096) u8 = @alignCast(raw_ptr);
                    self.allocator.free(p[0..4096]);
                },
                8192 => {
                    const p: [*]align(8192) u8 = @alignCast(raw_ptr);
                    self.allocator.free(p[0..8192]);
                },
                16384 => {
                    const p: [*]align(16384) u8 = @alignCast(raw_ptr);
                    self.allocator.free(p[0..16384]);
                },
                32768 => {
                    const p: [*]align(32768) u8 = @alignCast(raw_ptr);
                    self.allocator.free(p[0..32768]);
                },
                65536 => {
                    const p: [*]align(65536) u8 = @alignCast(raw_ptr);
                    self.allocator.free(p[0..65536]);
                },
                131072 => {
                    const p: [*]align(131072) u8 = @alignCast(raw_ptr);
                    self.allocator.free(p[0..131072]);
                },
                262144 => {
                    const p: [*]align(262144) u8 = @alignCast(raw_ptr);
                    self.allocator.free(p[0..262144]);
                },
                524288 => {
                    const p: [*]align(524288) u8 = @alignCast(raw_ptr);
                    self.allocator.free(p[0..524288]);
                },
                1048576 => {
                    const p: [*]align(1048576) u8 = @alignCast(raw_ptr);
                    self.allocator.free(p[0..1048576]);
                },
                else => unreachable,
            }
        }

        fn prependSlab(_: *Self, slab: *SlabHeader, list_head: *?*SlabHeader) void {
            slab.next = list_head.*;
            slab.prev = null;
            if (list_head.*) |head| {
                head.prev = slab;
            }
            list_head.* = slab;
        }

        fn removeSlab(_: *Self, slab: *SlabHeader, list_head: *?*SlabHeader) void {
            if (slab.prev) |p| {
                p.next = slab.next;
            } else {
                list_head.* = slab.next;
            }
            if (slab.next) |n| {
                n.prev = slab.prev;
            }
            slab.next = null;
            slab.prev = null;
        }

        pub fn scanUnsafe(self: *Self, context: anytype, comptime func: fn(ctx: @TypeOf(context), ptr: *T) void) void {
            // Iterate Partial List
            var it = self.partial_slabs;
            while (it) |slab| {
                self.scanSlab(slab, context, func);
                it = slab.next;
            }
            // Iterate Full List
            it = self.full_slabs;
            while (it) |slab| {
                self.scanSlab(slab, context, func);
                it = slab.next;
            }
        }

        fn scanSlab(self: *Self, slab: *SlabHeader, context: anytype, comptime func: fn(ctx: @TypeOf(context), ptr: *T) void) void {
             const header_size = @sizeOf(SlabHeader);
             // Re-calculate offset logic matching grow()
             var offset = std.mem.alignForward(usize, header_size, object_align);

             while (offset + object_size <= self.slab_size) {
                 const node_addr = @intFromPtr(slab) + offset;
                 const ptr: *T = @ptrFromInt(node_addr);

                 func(context, ptr);

                 offset += std.mem.alignForward(usize, object_size, object_align);
             }
        }
    };
}

