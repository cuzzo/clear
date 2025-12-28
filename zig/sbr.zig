const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ScopeTracker = struct {
    headers: std.ArrayListUnmanaged(*ObjectHeader),

    pub fn init() ScopeTracker {
        return .{ .headers = .{} };
    }

    pub fn deinit(self: *ScopeTracker, allocator: Allocator) void {
        for (self.headers.items) |header| {
             const total_len = @sizeOf(ObjectHeader) + header.len;
             const raw_ptr = @as([*]u8, @ptrCast(header));
             const slice = raw_ptr[0..total_len];
             allocator.rawFree(slice, @enumFromInt(header.log2_align), @returnAddress());
        }
        self.headers.deinit(allocator);
    }

    pub fn add(self: *ScopeTracker, allocator: Allocator, header: *ObjectHeader) !void {
        try self.headers.append(allocator, header);
    }

    pub fn save(self: *ScopeTracker) usize {
        return self.headers.items.len;
    }

    pub fn forget(self: *ScopeTracker, header: *ObjectHeader) void {
        var i = self.headers.items.len;
        while (i > 0) {
            i -= 1;
            if (self.headers.items[i] == header) {
                _ = self.headers.swapRemove(i);
                return;
            }
        }
    }

    pub fn closeAndCompact(self: *ScopeTracker, allocator: Allocator, mark: usize, survivor: ?*ObjectHeader) void {
        // 1. Anchor the Root Survivor
        if (survivor) |s| {
            s.find().anchored = true;
        }

        // 2. COMPACT IN-PLACE
        var write_idx = mark;
        var read_idx = mark;
        const len = self.headers.items.len;

        while (read_idx < len) : (read_idx += 1) {
            const header = self.headers.items[read_idx];

            // Check if this object is part of the survivor graph
            if (header.find().anchored) {
                // SURVIVOR: Move it to the write position
                if (read_idx != write_idx) {
                    self.headers.items[write_idx] = header;
                }
                write_idx += 1;
            } else {
                // DEAD: Free it immediately
                const total_len = @sizeOf(ObjectHeader) + header.len;
                const raw_ptr = @as([*]u8, @ptrCast(header));
                const slice = raw_ptr[0..total_len];
                allocator.rawFree(slice, @enumFromInt(header.log2_align), @returnAddress());
            }
        }

        // 3. Shrink the list
        self.headers.shrinkRetainingCapacity(write_idx);

        // 4. Reset Anchor Flags for the survivors
        for (self.headers.items[mark..write_idx]) |h| {
            h.find().anchored = false;
        }
    }
};

/// The Hidden Header that lives immediately before the user pointer.
/// 64-bit Layout: [ 8b Parent | 4b Len | 1b Align | 1b Anchor | 2b Pad ] = 16 Bytes
pub const ObjectHeader = struct {
    parent: *ObjectHeader,
    len: u32,              // Optimized: 4GB max object size is plenty
    log2_align: u8,
    anchored: bool,

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

