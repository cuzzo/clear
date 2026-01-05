const std = @import("std");

const fc = @import("fiber-core.zig");

const SlabAllocator = @import("slab-alloc.zig").SlabAllocator;
const StackSize = fc.StackSize;
const Fiber = fc.Fiber;

const STACK_SIZE: usize = 16 * 1024; // 16KB -> 12KB Stack, 4KB Frame
const StackArray = [STACK_SIZE]u8;

// Calculate a Slab Size that is larger than the Stack Size.
// The SlabAllocator puts a header at the start of every chunk.
// If we used 16KB slabs for 16KB stacks, the header would displace the stack.
// Let's use 1MB chunks to hold ~63 stacks per chunk.
const SLAB_MEMORY_BLOCK = 1 * 1024 * 1024;

pub const StackSlab = struct {
    slab: SlabAllocator(StackArray),

    pub fn init(allocator: std.mem.Allocator) !StackSlab {
        return .{
            .slab = SlabAllocator(StackArray).init(
                allocator,
                SLAB_MEMORY_BLOCK,
            ),
        };
    }

    pub fn deinit(self: *StackSlab) void {
        self.slab.deinit();
    }

    pub fn alloc(self: *StackSlab) ![]u8 {
        // Map .alloc() -> .create()
        // .create() returns a pointer to the array (*[16KB]u8)
        const ptr = try self.slab.create();
        return ptr[0..];
    }

    pub fn free(self: *StackSlab, stack: []u8) void {
        // Recover the pointer to the array
        // We know the slice ptr points to the start of our StackArray
        const ptr: *StackArray = @ptrCast(stack.ptr);
        self.slab.destroy(ptr);
    }

    pub fn flushLocalCache(self: *StackSlab) void {
        self.slab.flushThreadCache();
    }
};

pub const StackPool = struct {
    allocator: std.mem.Allocator,
    stack_slab: StackSlab,

    pub fn init(allocator: std.mem.Allocator) StackPool {
        return .{
            .allocator = allocator,
            .stack_slab = try StackSlab.init(allocator),
        };
    }

    pub fn deinit(self: *StackPool) void {
        self.stack_slab.deinit();
    }

    pub fn flushLocalCache(self: *StackPool) void {
        self.stack_slab.flushLocalCache();
    }

    // The "Cache Check" happens inside Scheduler before calling this.
    pub fn get(self: *StackPool, entry_fn: usize, size: StackSize) !*Fiber {
        _ = size; // For now, only standard size is supported.
        const memory = try self.stack_slab.alloc();

        const fiber = try self.allocator.create(Fiber);
        fiber.* = Fiber.init(memory, entry_fn);
        return fiber;
    }

    // This function is deprecated in the new flow.
    pub fn put(self: *StackPool, fiber: *Fiber) void {
        self.stack_slab.free(fiber.stack.memory);
        self.allocator.destroy(fiber);
    }
};

