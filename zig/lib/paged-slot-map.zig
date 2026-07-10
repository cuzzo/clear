const std = @import("std");
const builtin = @import("builtin");

/// Dense, generational storage for graph vertices.
///
/// Handles name logical slots while payloads remain tightly packed. Removal
/// swaps the last payload into the hole, so iteration has no tombstone branch.
/// Empty tail regions are discarded with MADV_DONTNEED/VirtualAlloc RESET;
/// their virtual addresses remain valid and fault pages back in on reuse.
pub fn PagedSlotMap(
    comptime T: type,
    comptime dropFn: fn (std.mem.Allocator, *T) void,
) type {
    return struct {
        const Self = @This();

        pub const is_paged_slot_map = true;
        pub const Handle = u32;
        pub const region_capacity: u32 = 4096;
        pub const slot_bits = 20;
        pub const slot_mask: u32 = (@as(u32, 1) << slot_bits) - 1;
        pub const generation_mask: u32 = (@as(u32, 1) << (32 - slot_bits)) - 1;
        pub const max_capacity: u32 = slot_mask;
        const dead_dense = slot_mask;

        pub const DiscardFn = *const fn (?*anyopaque, [*]align(std.heap.page_size_min) u8, usize) bool;

        metadata_allocator: std.mem.Allocator,
        dense_allocator: std.mem.Allocator,
        nodes: []T,
        dense_to_slot: []u32,
        slot_meta: []u32,
        free_slots: []u32,
        live_count: u32 = 0,
        free_count: u32,
        committed_capacity: u32 = 0,
        discard_context: ?*anyopaque = null,
        discard_fn: DiscardFn = nativeDiscard,
        discard_failure_count: u32 = 0,

        pub fn initCapacity(allocator: std.mem.Allocator, capacity: u32) !Self {
            return initWithAllocators(allocator, std.heap.page_allocator, capacity, null, nativeDiscard);
        }

        /// Dependency-injection seam used by allocator and page-reclamation
        /// tests. Production callers should use initCapacity.
        pub fn initWithAllocators(
            metadata_allocator: std.mem.Allocator,
            dense_allocator: std.mem.Allocator,
            capacity: u32,
            discard_context: ?*anyopaque,
            discard_fn: DiscardFn,
        ) !Self {
            if (capacity == 0) return error.ZeroCapacity;
            if (capacity > max_capacity) return error.CapacityTooLarge;
            if (@sizeOf(T) == 0) return error.ZeroSizedPayload;

            const page_alignment = comptime std.mem.Alignment.fromByteUnits(@max(std.heap.page_size_min, @alignOf(T)));
            const nodes = try dense_allocator.alignedAlloc(T, page_alignment, capacity);
            errdefer dense_allocator.free(nodes);
            const dense_to_slot = try dense_allocator.alignedAlloc(u32, .fromByteUnits(std.heap.page_size_min), capacity);
            errdefer dense_allocator.free(dense_to_slot);
            const slot_meta = try metadata_allocator.alloc(u32, capacity);
            errdefer metadata_allocator.free(slot_meta);
            const free_slots = try metadata_allocator.alloc(u32, capacity);
            errdefer metadata_allocator.free(free_slots);

            for (0..capacity) |raw_index| {
                const index: u32 = @intCast(raw_index);
                slot_meta[raw_index] = dead_dense;
                // Pop order starts at slot zero, making handles deterministic.
                free_slots[raw_index] = capacity - 1 - index;
            }

            return .{
                .metadata_allocator = metadata_allocator,
                .dense_allocator = dense_allocator,
                .nodes = nodes,
                .dense_to_slot = dense_to_slot,
                .slot_meta = slot_meta,
                .free_slots = free_slots,
                .free_count = capacity,
                .discard_context = discard_context,
                .discard_fn = discard_fn,
            };
        }

        pub fn deinit(self: *Self) void {
            self.cleanupLive();
            self.metadata_allocator.free(self.free_slots);
            self.metadata_allocator.free(self.slot_meta);
            self.dense_allocator.free(self.dense_to_slot);
            self.dense_allocator.free(self.nodes);
            self.* = undefined;
        }

        pub inline fn makeHandle(slot: u32, generation: u32) Handle {
            return (generation << slot_bits) | slot;
        }

        pub inline fn handleSlot(handle: Handle) u32 {
            return handle & slot_mask;
        }

        pub inline fn handleGeneration(handle: Handle) u32 {
            return handle >> slot_bits;
        }

        pub fn insert(self: *Self, value: T) !Handle {
            if (self.free_count == 0) return error.Full;
            self.free_count -= 1;
            const slot = self.free_slots[self.free_count];
            const dense_index = self.live_count;
            self.markCommitted(dense_index);
            self.nodes[dense_index] = value;
            self.dense_to_slot[dense_index] = slot;
            const generation = self.slot_meta[slot] >> slot_bits;
            self.slot_meta[slot] = packMeta(generation, dense_index);
            self.live_count += 1;
            return makeHandle(slot, generation);
        }

        pub inline fn get(self: *Self, handle: Handle) ?*T {
            const dense_index = self.resolve(handle) orelse return null;
            return &self.nodes[dense_index];
        }

        pub inline fn getConst(self: *const Self, handle: Handle) ?*const T {
            const dense_index = self.resolve(handle) orelse return null;
            return &self.nodes[dense_index];
        }

        pub inline fn contains(self: *const Self, handle: Handle) bool {
            return self.resolve(handle) != null;
        }

        pub fn remove(self: *Self, handle: Handle) bool {
            const removed_dense = self.resolve(handle) orelse return false;
            const slot = handleSlot(handle);
            const generation = handleGeneration(handle);
            const last_dense = self.live_count - 1;

            dropFn(self.metadata_allocator, &self.nodes[removed_dense]);
            if (removed_dense != last_dense) {
                self.nodes[removed_dense] = self.nodes[last_dense];
                const moved_slot = self.dense_to_slot[last_dense];
                self.dense_to_slot[removed_dense] = moved_slot;
                self.slot_meta[moved_slot] = packMeta(
                    self.slot_meta[moved_slot] >> slot_bits,
                    removed_dense,
                );
            }

            self.live_count -= 1;
            self.retireOrRecycle(slot, generation);
            self.discardEmptyTail();
            return true;
        }

        pub fn clear(self: *Self) void {
            self.cleanupLive();
            const old_live = self.live_count;
            self.live_count = 0;
            var dense_index: u32 = 0;
            while (dense_index < old_live) : (dense_index += 1) {
                const slot = self.dense_to_slot[dense_index];
                const generation = self.slot_meta[slot] >> slot_bits;
                self.retireOrRecycle(slot, generation);
            }
            self.discardEmptyTail();
        }

        pub inline fn count(self: *const Self) i64 {
            return @intCast(self.live_count);
        }

        pub inline fn length(self: *const Self) usize {
            return self.live_count;
        }

        pub inline fn denseItems(self: *Self) []T {
            return self.nodes[0..self.live_count];
        }

        pub inline fn denseItemsConst(self: *const Self) []const T {
            return self.nodes[0..self.live_count];
        }

        pub fn idAtDense(self: *const Self, dense_index: usize) ?Handle {
            if (dense_index >= self.live_count) return null;
            const slot = self.dense_to_slot[dense_index];
            return makeHandle(slot, self.slot_meta[slot] >> slot_bits);
        }

        pub fn virtualReservedBytes(self: *const Self) usize {
            return self.nodes.len * @sizeOf(T) +
                self.dense_to_slot.len * @sizeOf(u32) +
                self.slot_meta.len * @sizeOf(u32) +
                self.free_slots.len * @sizeOf(u32);
        }

        pub fn committedBytesEstimate(self: *const Self) usize {
            return self.slot_meta.len * @sizeOf(u32) +
                self.free_slots.len * @sizeOf(u32) +
                @as(usize, self.committed_capacity) * (@sizeOf(T) + @sizeOf(u32));
        }

        pub inline fn committedPayloadCapacity(self: *const Self) u32 {
            return self.committed_capacity;
        }

        pub inline fn discardFailures(self: *const Self) u32 {
            return self.discard_failure_count;
        }

        /// Expensive invariant checker intended for tests and debug builds.
        pub fn debugValidate(self: *const Self) bool {
            if (self.live_count > self.nodes.len or self.free_count > self.free_slots.len) return false;
            var dense_index: u32 = 0;
            while (dense_index < self.live_count) : (dense_index += 1) {
                const slot = self.dense_to_slot[dense_index];
                if (slot >= self.slot_meta.len) return false;
                if ((self.slot_meta[slot] & slot_mask) != dense_index) return false;
            }
            var free_index: u32 = 0;
            while (free_index < self.free_count) : (free_index += 1) {
                const slot = self.free_slots[free_index];
                if (slot >= self.slot_meta.len) return false;
                if ((self.slot_meta[slot] & slot_mask) != dead_dense) return false;
            }
            return true;
        }

        inline fn resolve(self: *const Self, handle: Handle) ?u32 {
            const slot = handleSlot(handle);
            if (slot >= self.slot_meta.len) return null;
            const entry = self.slot_meta[slot];
            const dense_index = entry & slot_mask;
            if (dense_index == dead_dense or
                entry >> slot_bits != handleGeneration(handle) or
                dense_index >= self.live_count)
            {
                return null;
            }
            return dense_index;
        }

        inline fn packMeta(generation: u32, dense_index: u32) u32 {
            return (generation << slot_bits) | dense_index;
        }

        inline fn markCommitted(self: *Self, dense_index: u32) void {
            if (dense_index < self.committed_capacity) return;
            self.committed_capacity = @min(
                @as(u32, @intCast(self.nodes.len)),
                ((dense_index / region_capacity) + 1) * region_capacity,
            );
        }

        fn cleanupLive(self: *Self) void {
            var dense_index: u32 = 0;
            while (dense_index < self.live_count) : (dense_index += 1) {
                dropFn(self.metadata_allocator, &self.nodes[dense_index]);
            }
        }

        inline fn retireOrRecycle(self: *Self, slot: u32, generation: u32) void {
            if (generation == generation_mask) {
                self.slot_meta[slot] = packMeta(generation, dead_dense);
                return;
            }
            self.slot_meta[slot] = packMeta(generation + 1, dead_dense);
            self.free_slots[self.free_count] = slot;
            self.free_count += 1;
        }

        fn discardEmptyTail(self: *Self) void {
            if (self.live_count % region_capacity != 0) return;
            const start = self.live_count;
            const end = self.committed_capacity;
            if (start >= end) return;
            if (!self.discardSlice(T, self.nodes, start, end) or
                !self.discardSlice(u32, self.dense_to_slot, start, end))
            {
                self.discard_failure_count += 1;
                return;
            }
            self.committed_capacity = start;
        }

        fn discardSlice(self: *Self, comptime E: type, slice: []E, start: u32, end: u32) bool {
            const raw: [*]u8 = @ptrCast(slice.ptr + start);
            const aligned: [*]align(std.heap.page_size_min) u8 = @alignCast(raw);
            const byte_len = @as(usize, end - start) * @sizeOf(E);
            return self.discard_fn(self.discard_context, aligned, byte_len);
        }

        fn nativeDiscard(_: ?*anyopaque, ptr: [*]align(std.heap.page_size_min) u8, len: usize) bool {
            if (len == 0) return true;
            // A region is measured in elements, so its byte boundary need not
            // match a target's runtime page size (for example 64 KiB Linux
            // pages). Discard only the full physical pages inside the range.
            const page_size = std.heap.pageSize();
            const raw_start = @intFromPtr(ptr);
            const start = std.mem.alignForward(usize, raw_start, page_size);
            const end = std.mem.alignBackward(usize, raw_start + len, page_size);
            if (start >= end) return true;
            const aligned_ptr: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(start);
            const aligned_len = end - start;
            switch (builtin.os.tag) {
                .linux, .freebsd, .netbsd, .openbsd, .dragonfly, .macos => {
                    std.posix.madvise(aligned_ptr, aligned_len, std.c.MADV.DONTNEED) catch return false;
                    return true;
                },
                .windows => {
                    const windows = std.os.windows;
                    const ntdll = windows.ntdll;
                    var address: ?*anyopaque = aligned_ptr;
                    var size: windows.SIZE_T = aligned_len;
                    const status = ntdll.NtAllocateVirtualMemory(
                        windows.GetCurrentProcess(),
                        @ptrCast(&address),
                        0,
                        &size,
                        .{ .RESET = true },
                        .{ .NOACCESS = true },
                    );
                    return status == .SUCCESS;
                },
                else => return false,
            }
        }
    };
}
