const std = @import("std");

pub const CheatArena = struct {
    // Growth Strategy
    const MIN_PAGE_SIZE = 4 * 1024;
    const MAX_PAGE_SIZE = 256 * 1024;

    // We store raw slices now
    blocks: std.ArrayListUnmanaged([]u8),
    large_objects: std.ArrayListUnmanaged([]u8),

    current_block_index: usize = 0,
    cursor: usize = 0,

    child_allocator: std.mem.Allocator,

    pub fn init(child_allocator: std.mem.Allocator) CheatArena {
        return .{
            .blocks = .{},
            .large_objects = .{},
            .child_allocator = child_allocator,
        };
    }

    pub fn deinit(self: *CheatArena) void {
        for (self.blocks.items) |block| {
            // rawFree requires the alignment we allocated with.
            // We always alloc blocks with 16-byte alignment.
            self.child_allocator.rawFree(block, std.mem.Alignment.fromByteUnits(16), @returnAddress());
        }
        self.blocks.deinit(self.child_allocator);

        for (self.large_objects.items) |obj| {
            // Large objects have variable alignment, but rawFree needs the exact one.
            // Since we don't track the alignment of large objects (only the slice),
            // we will just assume strict 16-byte alignment for all large allocations
            // to simplify freeing.
            self.child_allocator.rawFree(obj, std.mem.Alignment.fromByteUnits(16), @returnAddress());
        }
        self.large_objects.deinit(self.child_allocator);
    }

    fn getNextPageSize(current_count: usize) usize {
        if (current_count == 0) return 4 * 1024;
        if (current_count == 1) return 16 * 1024;
        if (current_count == 2) return 64 * 1024;
        return MAX_PAGE_SIZE;
    }

    pub fn alloc(self: *CheatArena, n: usize, alignment: u8, _: usize) ?[*]u8 {
        // Convert u8 -> std.mem.Alignment
        const align_enum = std.mem.Alignment.fromByteUnits(alignment);
        const align_usize = align_enum.toByteUnits();

        // 1. Check current block
        if (self.blocks.items.len > 0) {
            const block = self.blocks.items[self.current_block_index];
            const start = @intFromPtr(block.ptr);
            const curr = start + self.cursor;
            const aligned_addr = std.mem.alignForward(usize, curr, align_usize);
            const offset = aligned_addr - start;

            if (offset + n <= block.len) {
                self.cursor = offset + n;
                return @as([*]u8, @ptrFromInt(aligned_addr));
            }
        }

        // 2. Determine Next Page Size
        const next_idx = if (self.blocks.items.len == 0) 0 else self.current_block_index + 1;
        const next_cap = getNextPageSize(next_idx);

        // 3. OVERFLOW CHECK
        if (n > next_cap) {
            // Ensure strict 16-byte alignment so we can blindly free it later
            const large_align = std.mem.Alignment.fromByteUnits(16);
            // If requested alignment is huge (>16), we must respect it
            const final_align = if (align_usize > 16) align_enum else large_align;

            // Use rawAlloc for runtime alignment
            const ptr_opt = self.child_allocator.rawAlloc(n, final_align, @returnAddress());
            if (ptr_opt) |ptr| {
                const slice = ptr[0..n];
                self.large_objects.append(self.child_allocator, slice) catch {
                    self.child_allocator.rawFree(slice, final_align, @returnAddress());
                    return null;
                };
                return ptr;
            }
            return null;
        }

        // 4. Try Next Cached Block
        if (next_idx < self.blocks.items.len) {
            self.current_block_index = next_idx;
            self.cursor = 0;
            return self.alloc(n, alignment, 0);
        }

        // 5. Allocate New Block (Standard path)
        const block_align = std.mem.Alignment.fromByteUnits(16);
        const new_ptr_opt = self.child_allocator.rawAlloc(next_cap, block_align, @returnAddress());

        if (new_ptr_opt) |ptr| {
             const new_slice = ptr[0..next_cap];
             self.blocks.append(self.child_allocator, new_slice) catch {
                self.child_allocator.rawFree(new_slice, block_align, @returnAddress());
                return null;
            };

            self.current_block_index = self.blocks.items.len - 1;
            self.cursor = 0;
            return self.alloc(n, alignment, 0);
        }

        return null;
    }

    // --- REWIND ---

    pub const Mark = struct {
        block_index: usize,
        cursor: usize,
        large_obj_count: usize,
    };

    pub fn getMark(self: *CheatArena) Mark {
        if (self.blocks.items.len == 0) return .{ .block_index = 0, .cursor = 0, .large_obj_count = 0 };
        return .{
            .block_index = self.current_block_index,
            .cursor = self.cursor,
            .large_obj_count = self.large_objects.items.len,
        };
    }

    pub fn rewind(self: *CheatArena, mark: Mark) void {
        self.current_block_index = mark.block_index;
        self.cursor = mark.cursor;

        const large_align = std.mem.Alignment.fromByteUnits(16);

        // Free Large Objects
        while (self.large_objects.items.len > mark.large_obj_count) {
            const popped = self.large_objects.pop().?;
            // We assume 16-byte alignment (see Alloc logic)
            self.child_allocator.rawFree(popped, large_align, @returnAddress());
        }

        // Trim Blocks
        const keep_count = if (self.blocks.items.len > 0) self.current_block_index + 1 else 0;

        while (self.blocks.items.len > keep_count) {
            const popped = self.blocks.pop().?;
            self.child_allocator.rawFree(popped, large_align, @returnAddress());
        }
    }
};

