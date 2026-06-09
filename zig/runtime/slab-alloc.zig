const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../lib/compat.zig");

const root = @import("root");
const Atomic = if (@hasDecl(root, "SimAtomic")) root.SimAtomic else std.atomic.Value;

pub fn SlabAllocator(comptime T: type) type {
    return struct {
        const Self = @This();

        const Node = struct {
            next: ?*Node,
        };

        /// Stable identity of a slab, used to safely pin a slab against
        /// concurrent reuse. `id` is a slot in the allocator's registry;
        /// `epoch` distinguishes successive occupants of that slot.
        pub const Ref = struct {
            id: u32,
            epoch: u32,
        };

        const Magazine = struct {
            objects: [MAGAZINE_SIZE]?*T = [_]?*T{null} ** MAGAZINE_SIZE,
            count: usize = 0,
            owner: ?*Self = null,
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

        pub const SlabHeader = struct {
            prev: ?*SlabHeader,
            next: ?*SlabHeader,
            free_head: ?*Node,
            thread_free: Atomic(?*Node),
            used_count: usize,
            is_full: bool,
            owner: *Self,
            /// Slot index into the allocator's `slabs` registry. Stable for
            /// the lifetime of this slab; recycled (with bumped epoch) when
            /// the slab is freed.
            id: u32,
            /// Copy of `epochs[id]` at the time this slab was created.
            /// A stale `Ref` whose epoch doesn't match the registry's
            /// current epoch is treated as referring to a freed slab.
            epoch: u32,
            /// Refcount held by chain walkers / external readers. Bumped
            /// under the allocator lock by `pin()`; decremented by
            /// `unpin()`. `shrinkOne()` waits for this to drain to 0
            /// before unmapping the slab.
            pin_count: Atomic(u32),
        };

        backing_allocator: std.mem.Allocator,
        slab_size: usize,

        partial_slabs: ?*SlabHeader = null,
        full_slabs: ?*SlabHeader = null,
        /// Number of slabs in `partial_slabs` whose `used_count == 0`.
        /// Used to decide whether `shrinkEmpty` has work to do.
        empty_slab_count: usize = 0,

        /// Registry: slot index → slab pointer. A null entry means the slot
        /// has been freed (or never occupied). Read under `lock`; written
        /// under `lock` from grow() and shrinkOne().
        slabs: std.ArrayListUnmanaged(?*SlabHeader) = .empty,
        /// Per-slot epoch counter. Incremented when a slot is freed, so a
        /// stale Ref captured before the free is rejected by `pin()`.
        epochs: std.ArrayListUnmanaged(u32) = .empty,
        /// Recyclable slot ids. Pop from here before extending `slabs`.
        free_slot_ids: std.ArrayListUnmanaged(u32) = .empty,

        lock: compat.Mutex = .{},

        const object_size = @sizeOf(T);
        const object_align = @max(16, @max(@alignOf(T), @alignOf(Node)));
        // For stack-sized objects (>= 4KB), leave at least one OS page between
        // the slab header and the first object. Stacks grow downward; a stack
        // overflow on the lowest object would otherwise corrupt the slab header.
        // Small-object slabs don't need this gap.
        const first_obj_offset: usize = blk: {
            const header_end = std.mem.alignForward(usize, @sizeOf(SlabHeader), object_align);
            const guard: usize = if (object_size >= 4096) 4096 else 0;
            break :blk @max(header_end, guard);
        };

        pub fn init(backing_allocator: std.mem.Allocator, slab_size: usize) Self {
            std.debug.assert(std.math.isPowerOfTwo(slab_size));
            std.debug.assert(slab_size > first_obj_offset + object_size);

            return .{
                .backing_allocator = backing_allocator,
                .slab_size = slab_size,
            };
        }

        pub fn deinit(self: *Self) void {
            self.clearThreadCacheForDeinit();

            self.lockSelf();
            defer self.unlockSelf();

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
            self.empty_slab_count = 0;
            self.slabs.deinit(self.backing_allocator);
            self.epochs.deinit(self.backing_allocator);
            self.free_slot_ids.deinit(self.backing_allocator);
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = allocBytes,
                    .resize = resizeBytes,
                    .remap = remapBytes,
                    .free = freeBytes,
                },
            };
        }

        fn allocBytes(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            _ = ret_addr;
            if (len != @sizeOf(T) or alignment.toByteUnits() > @alignOf(T)) return null;
            const self: *Self = @ptrCast(@alignCast(ctx));
            const obj = self.create() catch return null;
            return @ptrCast(obj);
        }

        fn resizeBytes(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
            return new_len == buf.len;
        }

        fn remapBytes(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
            return if (new_len == buf.len) buf.ptr else null;
        }

        fn freeBytes(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            _ = ret_addr;
            std.debug.assert(buf.len == @sizeOf(T));
            std.debug.assert(alignment.toByteUnits() <= @alignOf(T));
            const self: *Self = @ptrCast(@alignCast(ctx));
            const obj: *T = @ptrCast(@alignCast(buf.ptr));
            self.destroy(obj);
        }

        fn lockSelf(self: *Self) void {
            if (!builtin.single_threaded) self.lock.lock();
        }

        fn unlockSelf(self: *Self) void {
            if (!builtin.single_threaded) self.lock.unlock();
        }

        fn clearThreadCacheForDeinit(self: *Self) void {
            if (local_alloc_mag.owner == self) local_alloc_mag = .{};
            if (local_free_mag.owner == self) local_free_mag = .{};
        }

        /// Thread-local magazines are shared by all SlabAllocator(T)
        /// instances. When this thread switches instances, return the previous
        /// instance's cached objects through each slab's atomic mailbox instead
        /// of locking the previous allocator.
        fn ensureMagazineOwnership(self: *Self) void {
            if (local_alloc_mag.owner != null and local_alloc_mag.owner != self) {
                Self.releaseMagazineToMailbox(&local_alloc_mag);
            }
            if (local_free_mag.owner != null and local_free_mag.owner != self) {
                Self.releaseMagazineToMailbox(&local_free_mag);
            }
            local_alloc_mag.owner = self;
            local_free_mag.owner = self;
        }

        fn releaseMagazineToMailbox(mag: *Magazine) void {
            const owner = mag.owner orelse {
                mag.* = .{};
                return;
            };
            for (mag.objects[0..mag.count]) |maybe_obj| {
                owner.pushRemoteFree(maybe_obj.?);
            }
            mag.* = .{};
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
            self.lockSelf();
            defer self.unlockSelf();

            self.reclaimAllMailboxesLocked();

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
                const was_empty = slab.used_count == 0;
                const node = slab.free_head.?;
                slab.free_head = node.next;
                slab.used_count += 1;
                if (was_empty) {
                    std.debug.assert(self.empty_slab_count > 0);
                    self.empty_slab_count -= 1;
                }

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
            // grow() prepends a fresh slab to partial_slabs which counted
            // it as empty — consume that count now.
            std.debug.assert(self.empty_slab_count > 0);
            self.empty_slab_count -= 1;

            return @ptrCast(@alignCast(node));
        }

        fn growAndAlloc(self: *Self) !*T {
            const new_slab = try self.grow();
            const node = new_slab.free_head.?;
            new_slab.free_head = node.next;
            new_slab.used_count += 1;
            std.debug.assert(self.empty_slab_count > 0);
            self.empty_slab_count -= 1;
            return @ptrCast(@alignCast(node));
        }

        pub fn destroy(self: *Self, obj: *T) void {
            self.ensureMagazineOwnership();
            if (!self.ownsSlab(obj)) {
                self.pushRemoteFree(obj);
                return;
            }

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
            self.lockSelf();
            defer self.unlockSelf();

            // Magazine is full — flush all objects back to depot
            for (local_free_mag.objects[0..local_free_mag.count]) |o| {
                const owned = o.?;
                self.destroyOwnedToDepotLocked(self.slabForObject(owned), owned);
            }
            local_free_mag = .{ .owner = self };

            self.destroyOwnedToDepotLocked(self.slabForObject(obj), obj);
        }

        fn slabForObject(self: *Self, obj: *T) *SlabHeader {
            const ptr_addr = @intFromPtr(obj);
            const mask = ~(self.slab_size - 1);
            const header_addr = ptr_addr & mask;
            return @as(*SlabHeader, @ptrFromInt(header_addr));
        }

        fn destroyToDepot(self: *Self, obj: *T) void {
            const slab = self.slabForObject(obj);
            if (slab.owner != self) {
                self.pushRemoteFree(obj);
                return;
            }

            self.lockSelf();
            defer self.unlockSelf();
            self.destroyOwnedToDepotLocked(slab, obj);
        }

        fn destroyOwnedToDepotLocked(self: *Self, slab: *SlabHeader, obj: *T) void {
            const node: *Node = @ptrCast(@alignCast(obj));
            node.next = slab.free_head;
            slab.free_head = node;
            std.debug.assert(slab.used_count > 0);
            const was_full = slab.is_full;
            slab.used_count -= 1;

            if (slab.used_count == 0) {
                if (was_full) {
                    self.removeSlab(slab, &self.full_slabs);
                    self.prependSlab(slab, &self.partial_slabs);
                    slab.is_full = false;
                }
                // Slab is now empty (regardless of whether it was full or
                // partial before this destroy). Track for shrinkEmpty.
                self.empty_slab_count += 1;
            } else if (was_full) {
                self.removeSlab(slab, &self.full_slabs);
                self.prependSlab(slab, &self.partial_slabs);
                slab.is_full = false;
            }
        }

        fn pushRemoteFree(self: *Self, obj: *T) void {
            const slab = self.slabForObject(obj);
            const node: *Node = @ptrCast(@alignCast(obj));
            var head = slab.thread_free.load(.monotonic);
            while (true) {
                node.next = head;
                if (slab.thread_free.cmpxchgWeak(head, node, .release, .monotonic)) |actual| {
                    head = actual;
                } else {
                    break;
                }
            }
        }

        fn reclaimAllMailboxesLocked(self: *Self) void {
            var it = self.partial_slabs;
            while (it) |slab| {
                const next = slab.next;
                self.reclaimMailboxLocked(slab);
                it = next;
            }
            it = self.full_slabs;
            while (it) |slab| {
                const next = slab.next;
                self.reclaimMailboxLocked(slab);
                it = next;
            }
        }

        fn reclaimMailboxLocked(self: *Self, slab: *SlabHeader) void {
            var curr = slab.thread_free.swap(null, .acquire) orelse return;
            const was_full = slab.is_full;
            const old_used = slab.used_count;
            while (true) {
                const next = curr.next;
                curr.next = slab.free_head;
                slab.free_head = curr;
                std.debug.assert(slab.used_count > 0);
                slab.used_count -= 1;
                curr = next orelse break;
            }

            if (was_full and slab.free_head != null) {
                self.removeSlab(slab, &self.full_slabs);
                self.prependSlab(slab, &self.partial_slabs);
                slab.is_full = false;
            }
            if (old_used > 0 and slab.used_count == 0) {
                self.empty_slab_count += 1;
            }
        }

        noinline fn grow(self: *Self) !*SlabHeader {
            // Reserve a registry slot first, so a failed allocAligned doesn't
            // leave us with a half-initialized slab.
            const slot_id: u32 = if (self.free_slot_ids.pop()) |reused|
                reused
            else blk: {
                const new_id: u32 = @intCast(self.slabs.items.len);
                try self.slabs.append(self.backing_allocator, null);
                errdefer _ = self.slabs.pop();
                try self.epochs.append(self.backing_allocator, 0);
                break :blk new_id;
            };
            errdefer self.free_slot_ids.append(self.backing_allocator, slot_id) catch {};

            // Allocate raw memory with correct alignment
            const bytes = try self.allocAligned(self.slab_size);

            // If the allocator ignores our alignment request, the mask logic
            // in destroyToDepot will segfault. Catch it here.
            const addr = @intFromPtr(bytes.ptr);
            if (addr & (self.slab_size - 1) != 0) {
                std.debug.print("SlabAllocator: unaligned memory: expected {d}-byte alignment, got ptr 0x{x}\n", .{ self.slab_size, addr });
                self.backing_allocator.rawFree(
                    bytes,
                    std.mem.Alignment.fromByteUnits(self.slab_size),
                    @returnAddress(),
                );
                return error.OutOfMemory;
            }

            const raw_single_ptr: *u8 = @ptrCast(bytes.ptr);
            const aligned_ptr: *align(@alignOf(SlabHeader)) u8 = @alignCast(raw_single_ptr);
            const slab: *SlabHeader = @ptrCast(aligned_ptr);

            const slot_epoch = self.epochs.items[slot_id];

            slab.* = .{
                .prev = null,
                .next = null,
                .free_head = null,
                .thread_free = Atomic(?*Node).init(null),
                .used_count = 0,
                .is_full = false,
                .owner = self,
                .id = slot_id,
                .epoch = slot_epoch,
                .pin_count = Atomic(u32).init(0),
            };

            var offset = first_obj_offset;

            while (offset + object_size <= self.slab_size) {
                const node_addr = @intFromPtr(slab) + offset;
                const node: *Node = @ptrFromInt(node_addr);
                node.next = slab.free_head;
                slab.free_head = node;
                offset += std.mem.alignForward(usize, object_size, object_align);
            }

            self.slabs.items[slot_id] = slab;
            self.prependSlab(slab, &self.partial_slabs);
            // Freshly-grown slab has used_count == 0, so it counts as empty.
            self.empty_slab_count += 1;
            return slab;
        }

        fn allocAligned(self: *Self, size: usize) ![]u8 {
            const Alignment = std.mem.Alignment;

            return switch (size) {
                4096 => self.backing_allocator.alignedAlloc(u8, Alignment.fromByteUnits(4096), 4096),
                8192 => self.backing_allocator.alignedAlloc(u8, Alignment.fromByteUnits(8192), 8192),
                16384 => self.backing_allocator.alignedAlloc(u8, Alignment.fromByteUnits(16384), 16384),
                32768 => self.backing_allocator.alignedAlloc(u8, Alignment.fromByteUnits(32768), 32768),
                65536 => self.backing_allocator.alignedAlloc(u8, Alignment.fromByteUnits(65536), 65536),
                131072 => self.backing_allocator.alignedAlloc(u8, Alignment.fromByteUnits(131072), 131072),
                262144 => self.backing_allocator.alignedAlloc(u8, Alignment.fromByteUnits(262144), 262144),
                524288 => self.backing_allocator.alignedAlloc(u8, Alignment.fromByteUnits(524288), 524288),
                1048576 => self.backing_allocator.alignedAlloc(u8, Alignment.fromByteUnits(1048576), 1048576),
                2097152 => self.backing_allocator.alignedAlloc(u8, Alignment.fromByteUnits(2097152), 2097152),
                4194304 => self.backing_allocator.alignedAlloc(u8, Alignment.fromByteUnits(4194304), 4194304),
                else => error.InvalidSlabSize,
            };
        }

        fn freeSlabMemory(self: *Self, slab: *SlabHeader) void {
            const raw_ptr: [*]u8 = @ptrCast(slab);
            self.backing_allocator.rawFree(
                raw_ptr[0..self.slab_size],
                std.mem.Alignment.fromByteUnits(self.slab_size),
                @returnAddress(),
            );
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

        pub fn scanUnsafe(self: *Self, context: anytype, comptime func: fn (ctx: @TypeOf(context), ptr: *T) void) void {
            var it = self.partial_slabs;
            while (it) |slab| {
                self.scanSlab(slab, context, func);
                it = slab.next;
            }
            it = self.full_slabs;
            while (it) |slab| {
                self.scanSlab(slab, context, func);
                it = slab.next;
            }
        }

        fn scanSlab(self: *Self, slab: *SlabHeader, context: anytype, comptime func: fn (ctx: @TypeOf(context), ptr: *T) void) void {
            var offset = first_obj_offset;
            while (offset + object_size <= self.slab_size) {
                const node_addr = @intFromPtr(slab) + offset;
                const ptr: *T = @ptrFromInt(node_addr);
                func(context, ptr);
                offset += std.mem.alignForward(usize, object_size, object_align);
            }
        }

        /// Check if an object's slab header belongs to this instance.
        fn ownsSlab(self: *Self, obj: *T) bool {
            return self.slabForObject(obj).owner == self;
        }

        pub fn flushThreadCache(self: *Self) void {
            if (local_alloc_mag.owner != null and local_alloc_mag.owner != self) {
                Self.releaseMagazineToMailbox(&local_alloc_mag);
            }
            if (local_free_mag.owner != null and local_free_mag.owner != self) {
                Self.releaseMagazineToMailbox(&local_free_mag);
            }

            self.lockSelf();
            defer self.unlockSelf();

            if (local_alloc_mag.owner == self) {
                for (local_alloc_mag.objects[0..local_alloc_mag.count]) |o| {
                    const owned = o.?;
                    self.destroyOwnedToDepotLocked(self.slabForObject(owned), owned);
                }
                local_alloc_mag = .{};
            }
            if (local_free_mag.owner == self) {
                for (local_free_mag.objects[0..local_free_mag.count]) |o| {
                    const owned = o.?;
                    self.destroyOwnedToDepotLocked(self.slabForObject(owned), owned);
                }
                local_free_mag = .{};
            }
            self.reclaimAllMailboxesLocked();
        }

        // ────────────────────────────────────────────────────────────────
        // Refcount API
        //
        // These let an external chain walker (e.g., parking-lot
        // detectCycle) safely deref a `*T` whose lifetime it does not
        // own. The walker first turns the pointer into a `Ref` via
        // `refFromPtr`, then calls `pin(ref)` to bump the slab's
        // pin_count. As long as pin_count > 0, the slab won't be
        // unmapped by `shrinkOne`. The walker calls `unpin` to drop
        // its reference. A `Ref` captured before the slab is freed
        // becomes stale (the slot's epoch advances on free); `pin`
        // returns null in that case.
        //
        // refFromPtr only reads allocator-owned state (the `slabs`
        // registry), never the slab itself, so it is safe to call
        // even when the slab containing `ptr` has been freed.
        // ────────────────────────────────────────────────────────────────

        /// Find the live slab containing `ptr` and return its Ref.
        /// Returns null if `ptr` does not point into any live slab in
        /// this allocator (slab freed, or `ptr` was never from us).
        ///
        /// Cost: O(N_slabs) linear scan under the allocator lock.
        /// Used only from cold cycle-detection paths.
        pub fn refFromPtr(self: *Self, ptr: *T) ?Ref {
            const mask = ~(self.slab_size - 1);
            const slab_base: *SlabHeader = @ptrFromInt(@intFromPtr(ptr) & mask);

            self.lockSelf();
            defer self.unlockSelf();

            for (self.slabs.items, 0..) |maybe_slab, i| {
                if (maybe_slab) |s| {
                    if (s == slab_base) {
                        return Ref{
                            .id = @intCast(i),
                            .epoch = self.epochs.items[i],
                        };
                    }
                }
            }
            return null;
        }

        /// Pin the slab named by `ref`. Returns the slab header on
        /// success, or null if the ref is stale (slab was freed, or
        /// the slot has been recycled with a new epoch). The returned
        /// pointer remains valid until `unpin` is called.
        pub fn pin(self: *Self, ref: Ref) ?*SlabHeader {
            self.lockSelf();
            defer self.unlockSelf();

            if (ref.id >= self.slabs.items.len) return null;
            if (self.epochs.items[ref.id] != ref.epoch) return null;
            const slab = self.slabs.items[ref.id] orelse return null;
            // Bump under the lock so a racing shrinkOne() either sees
            // pin_count > 0 (and waits) or marks dead before we read.
            _ = slab.pin_count.fetchAdd(1, .acquire);
            return slab;
        }

        /// Drop a pin acquired via `pin`.
        pub fn unpin(_: *Self, slab: *SlabHeader) void {
            _ = slab.pin_count.fetchSub(1, .release);
        }

        /// Read pin count without acquiring the lock. Test-only.
        pub fn pinCountUnsafe(_: *Self, slab: *SlabHeader) u32 {
            return slab.pin_count.load(.acquire);
        }

        // ────────────────────────────────────────────────────────────────
        // Shrinking
        //
        // Empty slabs accumulate when a workload spikes and then
        // recedes. `shrinkEmpty` releases their backing memory to the
        // OS, retaining at most `keep_count` empty slabs as a buffer
        // for the next burst.
        //
        // shrinkEmpty does not run on the hot allocation path; call
        // it explicitly from a maintenance hook (scheduler idle, GC,
        // periodic timer). It blocks on each slab's pin_count
        // draining to 0 — uncontended (no chain walks in flight)
        // this is a cheap atomic load.
        // ────────────────────────────────────────────────────────────────

        /// Free empty slabs in `partial_slabs` until at most
        /// `keep_count` empty slabs remain. Returns the number of
        /// slabs freed.
        pub fn shrinkEmpty(self: *Self, keep_count: usize) usize {
            var freed: usize = 0;
            while (true) {
                const slab = self.popEmptyForShrink(keep_count) orelse return freed;
                // Wait for any in-flight pinners to release. Drained
                // outside the lock so pinners can complete.
                while (slab.pin_count.load(.acquire) > 0) {
                    std.atomic.spinLoopHint();
                }
                self.lockSelf();
                self.freeSlabMemory(slab);
                self.unlockSelf();
                freed += 1;
            }
        }

        /// Pop an empty slab from `partial_slabs` for shrinking, mark
        /// its registry slot dead and bump its epoch. Returns null if
        /// no empty slab can be freed (count <= keep_count) or if no
        /// empty slab exists. Holds the lock for the duration; the
        /// caller releases the slab's memory after pin_count drains.
        fn popEmptyForShrink(self: *Self, keep_count: usize) ?*SlabHeader {
            self.lockSelf();
            defer self.unlockSelf();

            self.reclaimAllMailboxesLocked();

            if (self.empty_slab_count <= keep_count) return null;

            // Find an empty slab in partial_slabs. Scan from head; in a
            // well-mixed workload most slabs near the head are partial
            // (recently allocated from), so empties tend to be older.
            var it = self.partial_slabs;
            while (it) |slab| : (it = slab.next) {
                if (slab.used_count == 0) {
                    self.removeSlab(slab, &self.partial_slabs);
                    self.empty_slab_count -= 1;

                    // Mark the registry slot dead and bump epoch so any
                    // outstanding Ref to this slab becomes stale.
                    self.slabs.items[slab.id] = null;
                    self.epochs.items[slab.id] +%= 1;
                    self.free_slot_ids.append(self.backing_allocator, slab.id) catch {
                        // Leak the slot id rather than the slab memory:
                        // appending fails only on OOM, which is fine here
                        // (next grow() falls back to slabs.append).
                    };
                    return slab;
                }
            }
            return null;
        }
    };
}
