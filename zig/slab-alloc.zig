const std = @import("std");

pub fn SlabAllocator(comptime T: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            next: ?*Node,
        };

        const Magazine = struct {
            objects: [MAGAZINE_SIZE]?*T = [_]?*T{null} ** MAGAZINE_SIZE,
            count: usize = 0,
            owner: ?*Self = null, // which instance owns these objects
        };
        // Scale magazine size inversely with object size to keep total
        // pre-allocated memory per thread roughly constant (~1 MB).
        // Standard 16KB x 64 = 1MB; Large 64KB x 16 = 1MB; XL 256KB x 4 = 1MB.
        const MAGAZINE_SIZE = blk: {
            const obj_size = @sizeOf(T);
            const target_bytes = 64 * 16 * 1024; // 1 MB baseline (64 x Standard)
            const computed = target_bytes / obj_size;
            break :blk if (computed < 4) 4 else if (computed > 64) 64 else computed;
        };

        threadlocal var local_alloc_mag: Magazine = .{};
        threadlocal var local_free_mag: Magazine = .{};

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
        const object_align = @max(16, @max(@alignOf(T), @alignOf(Node)));

        pub fn init(allocator: std.mem.Allocator, slab_size: usize) Self {
            std.debug.assert(std.math.isPowerOfTwo(slab_size));
            const header_size = @sizeOf(SlabHeader);
            const first_obj_offset = std.mem.alignForward(usize, header_size, object_align);
            std.debug.assert(slab_size > first_obj_offset + object_size);

            local_alloc_mag.count = 0;
            local_free_mag.count = 0;

            return .{
                .allocator = allocator,
                .slab_size = slab_size,
            };
        }

        pub fn deinit(self: *Self) void {
            // Clear threadlocal magazines completely — prevents stale pointers
            // from being used by a future SlabAllocator(T) instance on this thread.
            local_alloc_mag = .{};
            local_free_mag = .{};
            self.flushThreadCache();

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

        /// If the threadlocal magazine belongs to a different instance, flush it.
        fn ensureMagazineOwnership(self: *Self) void {
            if (local_alloc_mag.owner != null and local_alloc_mag.owner != self) {
                // Magazine has objects from a different instance — flush them
                // back to their owner before we use the magazine.
                const old_owner = local_alloc_mag.owner.?;
                old_owner.lock.lock();
                for (local_alloc_mag.objects[0..local_alloc_mag.count]) |o| {
                    old_owner.destroyToDepot(o.?);
                }
                old_owner.lock.unlock();
                local_alloc_mag = .{};
            }
            if (local_free_mag.owner != null and local_free_mag.owner != self) {
                const old_owner = local_free_mag.owner.?;
                old_owner.lock.lock();
                for (local_free_mag.objects[0..local_free_mag.count]) |o| {
                    old_owner.destroyToDepot(o.?);
                }
                old_owner.lock.unlock();
                local_free_mag = .{};
            }
            local_alloc_mag.owner = self;
            local_free_mag.owner = self;
        }

        pub fn create(self: *Self) !*T {
            self.ensureMagazineOwnership();
            // Try local magazine first (no lock!)
            if (local_free_mag.count > 0) {
                local_free_mag.count -= 1;
                return local_free_mag.objects[local_free_mag.count].?;
            }

            if (local_alloc_mag.count > 0) {
                local_alloc_mag.count -= 1;
                return local_alloc_mag.objects[local_alloc_mag.count].?;
            }

            // Magazine empty, refill from depot
            return self.createSlow();
        }

        noinline fn createSlow(self: *Self) !*T {
            self.lock.lock();
            defer self.lock.unlock();

            // Refill magazine with a batch
            var refilled: usize = 0;
            while (refilled < MAGAZINE_SIZE) {
                const obj = self.createFromDepot() catch break;
                local_alloc_mag.objects[refilled] = obj;
                refilled += 1;
            }

            if (refilled == 0) {
                // Couldn't refill, need to grow
                const obj = try self.growAndAlloc();
                return obj;
            }

            const result = local_alloc_mag.objects[refilled - 1].?;
            local_alloc_mag.count = refilled - 1;

            return result;
        }

        fn createFromDepot(self: *Self) !*T {
            if (self.partial_slabs) |slab| {
                const node = slab.free_head.?;
                slab.free_head = node.next;
                slab.used_count += 1;

                if (slab.free_head == null) {
                    self.removeSlab(slab, &self.partial_slabs);
                    self.prependSlab(slab, &self.full_slabs);
                    slab.is_full = true;
                }
                return @ptrCast(@alignCast(node));
            }

            const new_slab = try self.grow();
            const node = new_slab.free_head.?;
            new_slab.free_head = node.next;
            new_slab.used_count += 1;

            return @ptrCast(@alignCast(node));
        }

        fn growAndAlloc(self: *Self) !*T {
            const new_slab = try self.grow();
            const node = new_slab.free_head.?;
            new_slab.free_head = node.next;
            new_slab.used_count += 1;
            return @ptrCast(@alignCast(node));
        }

        pub fn destroy(self: *Self, obj: *T) void {
            self.ensureMagazineOwnership();
            // Try local free magazine first (no lock!)
            if (local_free_mag.count < MAGAZINE_SIZE) {
                local_free_mag.objects[local_free_mag.count] = obj;
                local_free_mag.count += 1;
                return;
            }

            // Magazine full, flush to depot
            self.destroySlow(obj);
        }

        fn destroySlow(self: *Self, obj: *T) void {
            self.lock.lock();
            defer self.lock.unlock();

            // Magazine is full — flush all objects back to depot
            for (local_free_mag.objects[0..local_free_mag.count]) |o| {
                self.destroyToDepot(o.?);
            }
            local_free_mag = .{ .owner = self };

            self.destroyToDepot(obj);
        }

        fn destroyToDepot(self: *Self, obj: *T) void {
            const ptr_addr = @intFromPtr(obj);
            const mask = ~(self.slab_size - 1);
            const header_addr = ptr_addr & mask;
            const slab = @as(*SlabHeader, @ptrFromInt(header_addr));

            const node: *Node = @ptrCast(@alignCast(obj));
            node.next = slab.free_head;
            slab.free_head = node;
            slab.used_count -= 1;

            if (slab.used_count == 0) {
                // Instead of freeing immediately, move to a "to be cleaned" list
                // or simply leave it in partial_slabs until deinit.
                // Freeing here is dangerous while thread-local magazines might still have pointers.
                if (slab.is_full) {
                    self.removeSlab(slab, &self.full_slabs);
                    self.prependSlab(slab, &self.partial_slabs);
                    slab.is_full = false;
                }
            } else if (slab.is_full) {
                self.removeSlab(slab, &self.full_slabs);
                self.prependSlab(slab, &self.partial_slabs);
                slab.is_full = false;
            }
        }

        noinline fn grow(self: *Self) !*SlabHeader {
            // Allocate raw memory with correct alignment
            const bytes = try self.allocAligned(self.slab_size);

            // If the allocator ignores our alignment request, the mask logic
            // in destroyToDepot will segfault. Catch it here.
            const addr = @intFromPtr(bytes.ptr);
            if (addr & (self.slab_size - 1) != 0) {
                // If we can't get aligned memory, we can't function.
                // We could try to free and retry, but for now, panic or error.
                std.debug.print("SlabAllocator: Underlying allocator returned unaligned memory! Expected {d}, got ptr {x}\n", .{self.slab_size, addr});
                return error.OutOfMemory;
            }

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
            const Alignment = std.mem.Alignment;

            return switch (size) {
                4096 => self.allocator.alignedAlloc(u8, Alignment.fromByteUnits(4096), 4096),
                8192 => self.allocator.alignedAlloc(u8, Alignment.fromByteUnits(8192), 8192),
                16384 => self.allocator.alignedAlloc(u8, Alignment.fromByteUnits(16384), 16384),
                32768 => self.allocator.alignedAlloc(u8, Alignment.fromByteUnits(32768), 32768),
                65536 => self.allocator.alignedAlloc(u8, Alignment.fromByteUnits(65536), 65536),
                131072 => self.allocator.alignedAlloc(u8, Alignment.fromByteUnits(131072), 131072),
                262144 => self.allocator.alignedAlloc(u8, Alignment.fromByteUnits(262144), 262144),
                524288 => self.allocator.alignedAlloc(u8, Alignment.fromByteUnits(524288), 524288),
                1048576 => self.allocator.alignedAlloc(u8, Alignment.fromByteUnits(1048576), 1048576),
                2097152 => self.allocator.alignedAlloc(u8, Alignment.fromByteUnits(2097152), 2097152),
                4194304 => self.allocator.alignedAlloc(u8, Alignment.fromByteUnits(4194304), 4194304),
                else => error.InvalidSlabSize,
            };
        }

        fn freeSlabMemory(self: *Self, slab: *SlabHeader) void {
            const raw_ptr: [*]u8 = @ptrCast(slab);

            // We cast to `[*]align(...)` (Many-Pointer), NOT `*align(...)` (Single-Pointer).
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
                2097152 => {
                    const p: [*]align(2097152) u8 = @alignCast(raw_ptr);
                    self.allocator.free(p[0..2097152]);
                },
                4194304 => {
                    const p: [*]align(4194304) u8 = @alignCast(raw_ptr);
                    self.allocator.free(p[0..4194304]);
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

        /// Check if an object's slab header belongs to this instance.
        fn ownsSlab(self: *Self, obj: *T) bool {
            const mask = ~(self.slab_size - 1);
            const slab: *SlabHeader = @ptrFromInt(@intFromPtr(obj) & mask);
            // Check partial_slabs list
            var it = self.partial_slabs;
            while (it) |s| : (it = s.next) { if (s == slab) return true; }
            // Check full_slabs list
            it = self.full_slabs;
            while (it) |s| : (it = s.next) { if (s == slab) return true; }
            return false;
        }

        pub fn flushThreadCache(self: *Self) void {
            self.lock.lock();
            defer self.lock.unlock();

            // Only flush if this thread's magazine belongs to this instance.
            if (local_alloc_mag.owner == self) {
                for (local_alloc_mag.objects[0..local_alloc_mag.count]) |o| {
                    self.destroyToDepot(o.?);
                }
                local_alloc_mag = .{};
            }
            if (local_free_mag.owner == self) {
                for (local_free_mag.objects[0..local_free_mag.count]) |o| {
                    self.destroyToDepot(o.?);
                }
                local_free_mag = .{};
            }
        }
    };
}

