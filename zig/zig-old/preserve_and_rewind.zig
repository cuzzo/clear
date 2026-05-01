// Removed from runtime.zig.
// preserveAndRewind was used by the CLEAR compiler to copy a heap string back to
// the frame arena at function return. Replaced by returning heap strings directly
// (caller owns and frees). See heap-string-return-bench-test.zig for benchmarks.

/// Preserve a slice across a frame mark rewind. Resets the arena cursor
/// to the saved mark, re-allocates the result at the rewound position,
/// then trims excess blocks. All intermediate allocations are reclaimed;
/// only the returned slice survives.
pub fn preserveAndRewind(self: *Runtime, mark: FrameMark, data: []const u8) ![]const u8 {
    if (self.arena_mode) return data; // fiber arena mode - no rewind
    if (data.len == 0) {
        self.restoreFrameMark(mark);
        return data;
    }
    // 1. Soft rewind: move cursor back, keep blocks alive
    self.overflow_arena.softRewind(mark.overflow_mark);
    // 2. Allocate at the rewound position via raw arena alloc (NOT std Allocator,
    //    which @memset's to undefined and would destroy the data when same-address).
    const raw_ptr = self.overflow_arena.alloc(data.len, 1, 0) orelse return error.OutOfMemory;
    const new_buf = raw_ptr[0..data.len];
    // 3. Copy from old location (still physically present in arena blocks).
    //    Skip when pointers match (result was the first alloc after mark).
    if (@intFromPtr(new_buf.ptr) != @intFromPtr(data.ptr)) {
        // copyForwards is safe when dest < src (always true: dest is at mark, src is later).
        std.mem.copyForwards(u8, new_buf, data);
    }
    // 4. Trim excess blocks and large objects
    self.overflow_arena.trimExcess(mark.overflow_mark);
    return new_buf;
}
