const std = @import("std");
const Allocator = std.mem.Allocator;

// TODO: Eventually, 95% of this will move to compile time.
// Overhead here will be almost completlely eliminated.
// Transpiler MUST insert anchor and unanchor for collections.
// If a collection is passed into a function, and it's pruned, data will NOT be freed in place
// Unanchor only affects survivors, the calling function will free data when it collapses.
// Anchor must be called on collections when adding or setting a heap alloc only!
// Unanchor must be called when removing or setting (previous item).
pub const ScopeTracker = struct {
    headers: std.ArrayListUnmanaged(*ObjectHeader),
    anchored_bits: std.DynamicBitSetUnmanaged,

    pub fn init(allocator: Allocator) !ScopeTracker {
        var bits = std.DynamicBitSetUnmanaged{};
        // PRE-ALLOCATE MAX SIZE (8KB)
        // We use 'false' to initialize them all to unanchored
        // This is way too big for green fibers.
        // We need to set the starting size at something like 128 bytes / 1024 bits.
        // We currently only support scope tracking up to ~55k scope heap variables.
        // The transpiler should take care of >90% of heap variables.
        // That would mean you'd need >1M heap objects in a single fiber to overflow
        // If you refuse to lifetime annotate anything.
        try bits.resize(allocator, std.math.maxInt(u16), false);

        return .{
            .headers = .{},
            .anchored_bits = bits,
        };
    }

    pub fn deinit(self: *ScopeTracker, object_allocator: Allocator, internal_allocator: Allocator) void {

        // 1. Free the TRACKED OBJECTS using the Object Allocator (Slab)
        for (self.headers.items) |header| {
            const total_len = @sizeOf(ObjectHeader) + header.len;
            const raw_ptr = @as([*]u8, @ptrCast(header));
            const slice = raw_ptr[0..total_len];

            // Use object_allocator here!
            object_allocator.rawFree(slice, @enumFromInt(header.log2_align), @returnAddress());
        }

        // 2. Free the INTERNAL LISTS using the Internal Allocator (Backing)
        self.headers.deinit(internal_allocator);
        self.anchored_bits.deinit(internal_allocator);
    }

    pub fn add(self: *ScopeTracker, allocator: Allocator, header: *ObjectHeader) !void {
        if (self.headers.items.len >= std.math.maxInt(u16)) {
             return error.ScopeTooLarge;
        }

        const idx = self.headers.items.len;
        header.tracker_index = @intCast(idx);

        self.anchored_bits.unset(idx);
        try self.headers.append(allocator, header);
    }

    // O(1) Anchor Operation (No object access needed if we had the index,
    // but here we set the bit in the tracker instead of the header)
    pub fn setAnchor(self: *ScopeTracker, header: *ObjectHeader, active: bool) void {
        const idx = header.tracker_index;
        // Safety check
        if (idx < self.headers.items.len and self.headers.items[idx] == header) {
            self.anchored_bits.setValue(idx, active);
        }
    }

    pub fn save(self: *ScopeTracker) usize {
        return self.headers.items.len;
    }

    pub fn forget(self: *ScopeTracker, header: *ObjectHeader) void {
        const idx = header.tracker_index;
        if (idx < self.headers.items.len and self.headers.items[idx] == header) {
            // Swap Remove is O(1)
            // Returns the removed element. We ignore it.
            _ = self.headers.swapRemove(idx);

            // If we removed from the middle, the last element was moved to 'idx'.
            // We must update its tracker_index to match its new location.
            if (idx < self.headers.items.len) {
                const swapped_in = self.headers.items[idx];
                swapped_in.tracker_index = @intCast(idx);
            }
        }

    }

    pub fn closeAndCompact(self: *ScopeTracker, allocator: Allocator, mark: usize, survivor: ?*ObjectHeader) void {
        if (survivor) |s| self.setAnchor(s, true);

        const len = self.headers.items.len;

        for (mark..len) |i| {
            const h = self.headers.items[i];
            if (h.find().anchored) {
                self.anchored_bits.set(i);
            }
        }

        var write_idx = mark;
        var read_idx = mark;

        while (read_idx < len) : (read_idx += 1) {
            const is_anchored = self.anchored_bits.isSet(read_idx);
            const header = self.headers.items[read_idx];

            if (is_anchored) {
                // SURVIVOR: Move to new position
                if (read_idx != write_idx) {
                    self.headers.items[write_idx] = header;
                    header.tracker_index = @intCast(write_idx);
                }

                // RESET: Clear the UF flag for the next scope
                // This is safe now because we know the parent wasn't freed in this pass.
                header.find().anchored = false;

                write_idx += 1;
            } else {
                 // TRASH logic
                 const total_len = @sizeOf(ObjectHeader) + header.len;
                 const raw_ptr = @as([*]u8, @ptrCast(header));
                 const slice = raw_ptr[0..total_len];
                 allocator.rawFree(slice, @enumFromInt(header.log2_align), @returnAddress());
            }
        }

        self.headers.shrinkRetainingCapacity(write_idx);

        // Clear bits for the survivors
        for (mark..write_idx) |i| {
            self.anchored_bits.unset(i);
        }
    }
};

/// The Hidden Header that lives immediately before the user pointer.
/// 64-bit Layout: [ 8b Parent | 4b Len | 1b Align | 1b Anchor | 2b tracker index ] = 16 Bytes
pub const ObjectHeader = struct {
    parent: *ObjectHeader,
    len: u32,              // Optimized: 4GB max object size is plenty
    log2_align: u8,
    anchored: bool,
    tracker_index: u16,

    pub fn find(self: *ObjectHeader) *ObjectHeader {
        var root = self;
        while (root.parent != root) {
            root.parent = root.parent.parent;
            root = root.parent;
        }
        return root;
    }

    pub fn connect(parent_hdr: *ObjectHeader, child_hdr: *ObjectHeader) void {
        // FAST PATH: If child is already a root and unanchored (freshly created),
        // just blindly link it. 90% of cases in 'Tree Insert' hit this.
        if (child_hdr.parent == child_hdr) {
            child_hdr.parent = parent_hdr; // Direct attach (no find needed for child)
            // We still need to find Parent's root to propagate 'anchored' status,
            // but we skip half the work.
            const root_p = parent_hdr.find();
            if (root_p.anchored) {
                 // If parent is anchored, we don't need to propagate anything
                 // because child is now part of parent's set.
            } else {
                 // Only if parent is NOT anchored do we worry about child's status
                 root_p.anchored = root_p.anchored or child_hdr.anchored;
            }
            return;
        }

        // SLOW PATH
        const root_p = parent_hdr.find();
        const root_c = child_hdr.find();
        if (root_p != root_c) {
            root_c.parent = root_p;
            root_p.anchored = root_p.anchored or root_c.anchored;
        }
    }

    pub fn fromUserPtr(ptr: anytype) *ObjectHeader {
        const T = @TypeOf(ptr);
        const info = @typeInfo(T);
        var raw_addr: usize = 0;

        switch (info) {
            .pointer => |ptr_info| {
                switch (ptr_info.size) {
                    .slice => raw_addr = @intFromPtr(ptr.ptr), // Extract .ptr from slice
                    else => raw_addr = @intFromPtr(ptr),       // Use pointer directly
                }
            },
            else => @compileError("ObjectHeader.fromUserPtr expects a pointer or slice"),
        }

        const header_addr = raw_addr - @sizeOf(ObjectHeader);
        return @as(*ObjectHeader, @ptrFromInt(header_addr));
    }
};

