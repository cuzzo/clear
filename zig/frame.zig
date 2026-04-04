const std = @import("std");

pub const CheatArena = struct {
    // Growth Strategy
    const MIN_PAGE_SIZE = 4 * 1024;
    const MAX_PAGE_SIZE = 256 * 1024;

    const LargeObject = struct {
        slice: []u8,
        alignment: std.mem.Alignment,
    };

    // We store raw slices now
    blocks: std.ArrayListUnmanaged([]u8),
    large_objects: std.ArrayListUnmanaged(LargeObject),

    current_block_index: usize = 0,
    cursor: usize = 0,

    child_allocator: std.mem.Allocator,

    // An optional pre-allocated buffer (e.g. the 4KB Frame)
    static_block: []u8 = &[_]u8{},

    pub fn init(child_allocator: std.mem.Allocator, static_block: []u8) CheatArena {
        return .{
            .blocks = .{},
            .large_objects = .{},
            .child_allocator = child_allocator,
            .static_block = static_block,
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
            self.child_allocator.rawFree(obj.slice, obj.alignment, @returnAddress());
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

        // 1. Check active block (either Static or Dynamic)
        // If we have dynamic blocks, use the last one. Otherwise use static.
        const use_dynamic = (self.blocks.items.len > 0);

        if (use_dynamic or self.static_block.len > 0) {
            const block = if (use_dynamic) self.blocks.items[self.current_block_index] else self.static_block;
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
                // Store struct: { .slice, .alignment }
                self.large_objects.append(self.child_allocator, .{
                    .slice = slice,
                    .alignment = final_align
                }) catch {
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
        const shift: usize = if (self.static_block.len > 0 and self.blocks.items.len > 0) 1 else 0;

        return .{
            .block_index = self.current_block_index + shift,
            .cursor = self.cursor,
            .large_obj_count = self.large_objects.items.len,
        };
    }

    pub fn rewind(self: *CheatArena, mark: Mark) void {
        self.softRewind(mark);
        self.trimExcess(mark);
    }

    /// Reset cursor and block index to mark position WITHOUT freeing blocks.
    /// Used by preserveAndRewind to keep source data alive during copy.
    pub fn softRewind(self: *CheatArena, mark: Mark) void {
        const has_static = (self.static_block.len > 0);
        if (has_static) {
            self.current_block_index = if (mark.block_index == 0) 0 else mark.block_index - 1;
        } else {
            self.current_block_index = mark.block_index;
        }
        self.cursor = mark.cursor;
    }

    /// Free blocks and large objects allocated after the current position.
    pub fn trimExcess(self: *CheatArena, mark: Mark) void {
        const has_static = (self.static_block.len > 0);
        // Keep blocks up to current_block_index (which may have advanced from softRewind
        // if a new allocation overflowed into the next block).
        const keep_count = if (self.blocks.items.len == 0)
            @as(usize, 0)
        else if (has_static)
            self.current_block_index + 1
        else
            self.current_block_index + 1;

        const large_align = std.mem.Alignment.fromByteUnits(16);

        // Free Large Objects
        while (self.large_objects.items.len > mark.large_obj_count) {
            const popped = self.large_objects.pop().?;
            self.child_allocator.rawFree(popped.slice, popped.alignment, @returnAddress());
        }

        // Trim Blocks
        while (self.blocks.items.len > keep_count) {
            const popped = self.blocks.pop().?;
            self.child_allocator.rawFree(popped, large_align, @returnAddress());
        }
    }
};

