const std = @import("std");
const is_debug = @import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe;

// ── Debug Mode ────────────────────────────────────────────────────────────────
// CheatArenaType(true) routes every allocation through large_objects (individual
// heap allocs). rewind() frees them individually, so any use-after-rewind faults
// immediately. This is the same bump-and-rewind semantics as the production arena
// but without the bump buffer, which makes the individual free visible to GPA/ASAN.
//
// Enabled automatically in Debug/ReleaseSafe builds via `CheatArena` (see below).
// Override at compile time with pub const CLEAR_FRAME_DEBUG = false in root.

pub fn CheatArenaType(comptime debug_mode: bool) type {
    return struct {
        const Self = @This();

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
        // Debug-only: high-water mark for frame arena usage. Compiled away in ReleaseFast.
        peak_bytes: if (is_debug) usize else void = if (is_debug) 0 else {},

        // child_allocator: used for all allocations — ArrayList metadata, data blocks,
        // and large objects. In production, this is c_allocator (libc malloc), which
        // supports jemalloc/tcmalloc via LD_PRELOAD for page-return behavior.
        child_allocator: std.mem.Allocator,

        // An optional pre-allocated buffer (e.g. the 4KB Frame)
        static_block: []u8 = &[_]u8{},

        pub fn init(child_allocator: std.mem.Allocator, static_block: []u8) Self {
            return .{
                .blocks = .{},
                .large_objects = .{},
                .child_allocator = child_allocator,
                .static_block = static_block,
            };
        }

        pub fn deinit(self: *Self) void {
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
            // Debug mode: return 0 to force every allocation through large_objects.
            // Each alloc is individually tracked and freed by trimExcess/rewind,
            // making use-after-rewind immediately detectable by GPA/ASAN.
            if (debug_mode) return 0;

            if (current_count == 0) return 4 * 1024;
            if (current_count == 1) return 16 * 1024;
            if (current_count == 2) return 64 * 1024;
            return MAX_PAGE_SIZE;
        }

        /// Total bytes currently used in the arena. Debug/ReleaseSafe only.
        pub fn currentBytes(self: *const Self) usize {
            if (!is_debug) return 0;
            var total: usize = 0;
            for (0..self.current_block_index) |i| {
                if (i < self.blocks.items.len) total += self.blocks.items[i].len;
            }
            total += self.cursor;
            for (self.large_objects.items) |lo| total += lo.slice.len;
            return total;
        }

        /// Peak bytes ever allocated. Debug/ReleaseSafe only. Returns 0 in release.
        pub fn getPeakBytes(self: *const Self) usize {
            if (!is_debug) return 0;
            return self.peak_bytes;
        }

        fn updatePeak(self: *Self) void {
            if (!is_debug) return;
            const cur = self.currentBytes();
            if (cur > self.peak_bytes) self.peak_bytes = cur;
        }

        pub fn alloc(self: *Self, n: usize, alignment: u8, _: usize) ?[*]u8 {
            // Convert u8 -> std.mem.Alignment
            const align_enum = std.mem.Alignment.fromByteUnits(alignment);
            const align_usize = align_enum.toByteUnits();

            // 1. Check active block (either Static or Dynamic)
            // Debug mode: skip bump allocation entirely — force all allocs to large_objects
            // so every allocation is individually tracked and freed on rewind.
            if (!debug_mode) {
                const use_dynamic = (self.blocks.items.len > 0);

                if (use_dynamic or self.static_block.len > 0) {
                    const block = if (use_dynamic) self.blocks.items[self.current_block_index] else self.static_block;
                    const start = @intFromPtr(block.ptr);
                    const curr = start + self.cursor;
                    const aligned_addr = std.mem.alignForward(usize, curr, align_usize);
                    const offset = aligned_addr - start;

                    if (offset + n <= block.len) {
                        self.cursor = offset + n;
                        self.updatePeak();
                        return @as([*]u8, @ptrFromInt(aligned_addr));
                    }
                }
            }

            // 2. Determine Next Page Size
            const next_idx = if (self.blocks.items.len == 0) 0 else self.current_block_index + 1;
            const next_cap = getNextPageSize(next_idx);

            // 3. OVERFLOW CHECK (also triggered when debug_mode forces next_cap=0)
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
                    self.updatePeak();
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

        pub fn getMark(self: *Self) Mark {
            const shift: usize = if (self.static_block.len > 0 and self.blocks.items.len > 0) 1 else 0;

            return .{
                .block_index = self.current_block_index + shift,
                .cursor = self.cursor,
                .large_obj_count = self.large_objects.items.len,
            };
        }

        pub fn rewind(self: *Self, mark: Mark) void {
            self.softRewind(mark);
            self.trimExcess(mark);
        }

        /// Per-iteration loop rewind: reset cursor + free large objects allocated
        /// after the mark, but keep overflow blocks for reuse next iteration.
        /// Large objects (allocs larger than the next page size, e.g. 80KB ArrayLists)
        /// must be freed each iteration or they accumulate unboundedly. Overflow
        /// blocks are kept because freeing and re-allocating them every iteration
        /// adds unnecessary malloc pressure for tight string loops.
        /// restoreFrameMark calls full rewind() at function exit to release blocks.
        pub fn loopRewind(self: *Self, mark: Mark) void {
            self.softRewind(mark);
            // softRewind already frees large_objects in debug_mode.
            // In production mode, free them here to prevent unbounded accumulation.
            if (!debug_mode) {
                while (self.large_objects.items.len > mark.large_obj_count) {
                    const popped = self.large_objects.pop().?;
                    self.child_allocator.rawFree(popped.slice, popped.alignment, @returnAddress());
                }
            }
        }

        /// Reset cursor and block index to mark position WITHOUT freeing blocks or
        /// large objects. Internal implementation step used by rewind() and loopRewind().
        fn softRewind(self: *Self, mark: Mark) void {
            const has_static = (self.static_block.len > 0);
            if (has_static) {
                self.current_block_index = if (mark.block_index == 0) 0 else mark.block_index - 1;
            } else {
                self.current_block_index = mark.block_index;
            }
            self.cursor = mark.cursor;
            if (debug_mode) {
                // Debug mode routes every alloc through large_objects. Blocks are
                // never used, so the "keep blocks alive" reason for softRewind doesn't
                // apply. Free large objects now so loop marks actually reclaim memory.
                const large_align = std.mem.Alignment.fromByteUnits(16);
                _ = large_align;
                while (self.large_objects.items.len > mark.large_obj_count) {
                    const popped = self.large_objects.pop().?;
                    self.child_allocator.rawFree(popped.slice, popped.alignment, @returnAddress());
                }
            }
        }

        /// Free blocks and large objects allocated after the current position.
        /// Uses mark.block_index (not current_block_index) to compute keep_count,
        /// matching the original rewind logic: when has_static && mark.block_index==0,
        /// ALL dynamic blocks are freed (keep_count=0).
        pub fn trimExcess(self: *Self, mark: Mark) void {
            const has_static = (self.static_block.len > 0);
            const keep_count = if (self.blocks.items.len == 0)
                @as(usize, 0)
            else if (has_static)
                if (mark.block_index == 0) @as(usize, 0) else mark.block_index
            else
                if (self.blocks.items.len > 0) self.current_block_index + 1 else @as(usize, 0);

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

        /// Returns true if ptr was allocated as a large object and has not yet been
        /// freed via rewind(). Used by cleanupFree in debug mode to avoid double-freeing
        /// frame allocations that will be reclaimed by the next rewind().
        /// In production mode this is never called (cleanupFree uses static_block range check).
        pub fn isLargeObject(self: *const Self, ptr: [*]const u8) bool {
            for (self.large_objects.items) |a| {
                if (a.slice.ptr == ptr) return true;
            }
            return false;
        }

    };
}

// Default production arena (bump allocator with page blocks).
pub const CheatArena = CheatArenaType(false);
