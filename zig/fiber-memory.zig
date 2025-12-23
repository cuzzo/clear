const std = @import("std");

const fc = @import("fiber-core.zig");

const StackSize = fc.StackSize;
const Fiber = fc.Fiber;

const linux = std.os.linux;
const posix = std.posix;

// We reserve 1TB of virtual address space.
// 0 syscalls to sub-divide this. It's just math.
const ARENA_SIZE: usize = 1 * 1024 * 1024 * 1024 * 1024;
const STACK_SIZE: usize = 2 * 1024 * 1024; // 2MB
const MAX_STACKS: usize = ARENA_SIZE / STACK_SIZE;

pub const VirtualArena = struct {
    base_addr: ?[*]u8,

    // Global atomic counter for the "Watermark" of allocated stacks.
    // We only increment this. We never "free" an index back to the global pool
    // to keep it lock-free. Freed stacks go to Thread-Local caches.
    stack_watermark: std.atomic.Value(usize),

    pub fn init() !VirtualArena {
        // HUGE mmap. NO_RESERVE means we don't commit swap/ram.
        // PROT_READ|WRITE means no mprotect needed later.
        const addr = try posix.mmap(
            null,
            ARENA_SIZE,
            posix.PROT.READ | posix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true },
            -1,
            0,
        );

        return VirtualArena{
            .base_addr = addr.ptr,
            .stack_watermark = std.atomic.Value(usize).init(0),
        };
    }

    // Returns a POINTER to the start of the stack memory.
    // Hot Path: 1 atomic increment.
    pub fn allocGlobalSlot(self: *VirtualArena) ![]u8 {
        const index = self.stack_watermark.fetchAdd(1, .monotonic);
        if (index >= MAX_STACKS) return error.OutOfMemory;

        const offset = index * STACK_SIZE;
        return self.base_addr.?[offset..offset+STACK_SIZE];
    }
};

pub var global_arena: VirtualArena = .{
    .base_addr = null,
    .stack_watermark = std.atomic.Value(usize).init(0),
};


// TODO: Deprecate, replaced by Arena
pub const StackPool = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StackPool {
        return .{ .allocator = allocator };
    }

    pub fn deinit(_: *StackPool) void {
    }

    pub fn flushLocalCache(_: *StackPool) void {
    }

    // The "Cache Check" happens inside Scheduler before calling this.
    pub fn get(self: *StackPool, entry_fn: usize, size: StackSize) !*Fiber {
        _ = size; // We only support 2MB now

        // Atomic Alloc from Arena
        const memory = try global_arena.allocGlobalSlot();

        // We still allocate the Fiber struct itself.
        // Ideally this comes from a SlabAllocator, but using standard allocator for now as per your code.
        const fiber = try self.allocator.create(Fiber);
        fiber.* = Fiber.init(memory, entry_fn);
        return fiber;
    }

    // This function is deprecated in the new flow.
    pub fn put(self: *StackPool, fiber: *Fiber) void {
        // Scheduler puts memory into its local cache.
        // If we must destroy a fiber struct:
        self.allocator.destroy(fiber);
    }
};

