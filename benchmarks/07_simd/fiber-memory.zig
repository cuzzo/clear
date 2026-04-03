const std = @import("std");

const fc = @import("fiber-core.zig");

const SlabAllocator = @import("slab-alloc.zig").SlabAllocator;
const StackSize = fc.StackSize;
const Fiber = fc.Fiber;

// ---------------------------------------------------------------------------
// Stack size tier constants (total bytes per fiber allocation).
// These are also used by the Scheduler to route the L1 stack cache.
// ---------------------------------------------------------------------------
pub const MICRO_STACK_SIZE:    usize =   4 * 1024;   //   4 KB
pub const STANDARD_STACK_SIZE: usize =  16 * 1024;   //  16 KB  (default)
pub const LARGE_STACK_SIZE:    usize =  64 * 1024;   //  64 KB
pub const XL_STACK_SIZE:       usize = 256 * 1024;   // 256 KB

// Typed array aliases — each SlabAllocator is parameterized by a fixed-size type.
const MicroArray    = [MICRO_STACK_SIZE]u8;
const StandardArray = [STANDARD_STACK_SIZE]u8;
const LargeArray    = [LARGE_STACK_SIZE]u8;
const XlArray       = [XL_STACK_SIZE]u8;

// Slab block sizes (must be powers of 2 and larger than one element + header).
// Each block holds multiple stacks of the corresponding tier.
const MICRO_SLAB_BLOCK:    usize = 256 * 1024;       //  64 micro stacks / block
const STANDARD_SLAB_BLOCK: usize = 512 * 1024;       //  32 standard stacks / block
const LARGE_SLAB_BLOCK:    usize =   2 * 1024 * 1024; //  32 large stacks / block
const XL_SLAB_BLOCK:       usize =   4 * 1024 * 1024; //  16 XL stacks / block

// ---------------------------------------------------------------------------
// StackPool — one SlabAllocator per size class.
// The Scheduler holds a pointer to a single StackPool shared across threads;
// each thread also maintains an L1 cache of recently freed Standard stacks
// (see Scheduler.allocStack / freeStack).
// ---------------------------------------------------------------------------
pub const StackPool = struct {
    allocator:     std.mem.Allocator,
    micro_slab:    SlabAllocator(MicroArray),
    standard_slab: SlabAllocator(StandardArray),
    large_slab:    SlabAllocator(LargeArray),
    xl_slab:       SlabAllocator(XlArray),

    pub fn init(allocator: std.mem.Allocator) StackPool {
        return .{
            .allocator     = allocator,
            .micro_slab    = SlabAllocator(MicroArray).init(allocator,    MICRO_SLAB_BLOCK),
            .standard_slab = SlabAllocator(StandardArray).init(allocator, STANDARD_SLAB_BLOCK),
            .large_slab    = SlabAllocator(LargeArray).init(allocator,    LARGE_SLAB_BLOCK),
            .xl_slab       = SlabAllocator(XlArray).init(allocator,       XL_SLAB_BLOCK),
        };
    }

    pub fn deinit(self: *StackPool) void {
        self.micro_slab.deinit();
        self.standard_slab.deinit();
        self.large_slab.deinit();
        self.xl_slab.deinit();
    }

    pub fn flushLocalCache(self: *StackPool) void {
        self.micro_slab.flushThreadCache();
        self.standard_slab.flushThreadCache();
        self.large_slab.flushThreadCache();
        self.xl_slab.flushThreadCache();
    }

    /// Allocate a stack of the requested size class.
    /// Returns a []u8 slice whose .len equals the stack size constant.
    pub fn alloc(self: *StackPool, size: StackSize) ![]u8 {
        return switch (size) {
            .Micro    => blk: { const p = try self.micro_slab.create();    break :blk p[0..]; },
            .Standard => blk: { const p = try self.standard_slab.create(); break :blk p[0..]; },
            .Large    => blk: { const p = try self.large_slab.create();    break :blk p[0..]; },
            .Xl       => blk: { const p = try self.xl_slab.create();       break :blk p[0..]; },
        };
    }

    /// Return a previously-allocated stack to the right slab.
    /// Size class is determined from stack.len — no extra tag needed.
    pub fn free(self: *StackPool, stack: []u8) void {
        switch (stack.len) {
            MICRO_STACK_SIZE    => { const p: *MicroArray    = @ptrCast(stack.ptr); self.micro_slab.destroy(p); },
            STANDARD_STACK_SIZE => { const p: *StandardArray = @ptrCast(stack.ptr); self.standard_slab.destroy(p); },
            LARGE_STACK_SIZE    => { const p: *LargeArray    = @ptrCast(stack.ptr); self.large_slab.destroy(p); },
            XL_STACK_SIZE       => { const p: *XlArray       = @ptrCast(stack.ptr); self.xl_slab.destroy(p); },
            else => unreachable,
        }
    }
};

// Kept for the scheduler import that references it; will be removed later.
pub const VirtualArena = void;
