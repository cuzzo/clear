const std = @import("std");

// Fibers

// The registers we need to save.
// This layout matches the assembly exactly.
pub const Context = extern struct {
    sp: u64, // Stack Pointer

    // Callee-saved registers for x86_64
    rbx: u64 = 0,
    rbp: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
};

// 1. Declare the external symbol
// Zig will look for this in the .s file we just created.
extern fn switch_context_asm(from: *Context, to: *Context) callconv(.c) void;

// 2. Public Wrapper
pub fn switchContext(from: *Context, to: *Context) void {
    switch_context_asm(from, to);
}

// CHEAT uses VMA Pooling with mprotect and madvise.
// 2MB is not the per-fiber stack memory usage. It's the limit.
// 4KB is the minimum (p95) size.
pub const StackSize = enum {
    Standard,  // 2MB (Fall back to mmap/mprotect)
};

pub const Stack = struct {
    // The raw slice of memory we own
    memory: []u8,

    // Add this helper. Fiber.reset() relies on it.
    pub fn getStackTop(self: Stack) usize {
        const addr = @intFromPtr(self.memory.ptr) + self.memory.len;
        // Align to 16 bytes and back off by 16 bytes
        return (addr & ~@as(usize, 15)) - 16;
    }
};

pub const Fiber = struct {
    stack: Stack,
    ctx: Context,
    parent_ctx: *Context, // Who to jump back to when we yield/finish
    size_class: StackSize,

    pub fn init(memory: []u8, entry_fn: usize) Fiber {
        const stack = Stack{ .memory = memory };

        // CALCULATION: Stack grows DOWN from the end of the memory block.
        const stack_top_addr = @intFromPtr(memory.ptr) + memory.len;

        // ---------------------------------------------------------------------
        // PERFORMANCE FIX: L1 Cache Staggering
        // ---------------------------------------------------------------------
        // Problem: 2MB strides cause every stack to alias to the same L1 Cache Set.
        // Fix: We shift the starting stack pointer by 64 bytes (1 cache line)
        // for every 2MB index. We wrap around every 16KB (half of L1 cache).
        //
        // Math: (Address >> 21) gives us the unique index of this 2MB block.
        // We multiply by 64 to shift one cache line per block.
        // We mask with 0x3FFF to limit the wasted space to 16KB max.
        // ---------------------------------------------------------------------
        const block_index = stack_top_addr >> 21;
        const stagger_offset = (block_index * 64) & 0x3FFF;

        // Align to 16 bytes (x64 requirement) and back off slightly
        // to ensure we don't start at the very edge.
        const stack_top = ((stack_top_addr - stagger_offset) & ~@as(usize, 15)) - 16;

        // THE TRAMPOLINE:
        // We simulate a "Return Address" on the top of the stack.
        // When switchContext executes 'ret', it will pop this address and jump to it.
        const ptr = @as(*usize, @ptrFromInt(stack_top));
        ptr.* = entry_fn;

        return Fiber{
            .stack = stack,
            // Point SP to the address we just wrote.
            // When 'ret' runs, it pops the value AT this pointer.
            .ctx = Context{ .sp = stack_top },
            .parent_ctx = undefined,
            .size_class = .Standard,
        };
    }

    // Switch FROM parent TO this fiber
    pub fn switchTo(self: *Fiber, parent: *Context) void {
        self.parent_ctx = parent;
        switchContext(parent, &self.ctx);
    }

    // Switch FROM this fiber BACK to parent
    pub fn yield(self: *Fiber) void {
        switchContext(&self.ctx, self.parent_ctx);
    }

    // Reset the stack pointer and put the entry function back at the top.
    pub fn reset(self: *Fiber, entry_fn: usize) void {
        const stack_top = self.stack.getStackTop();

        // 1. Rewrite the Trampoline (Return Address)
        const ptr = @as(*usize, @ptrFromInt(stack_top));
        ptr.* = entry_fn;

        // 2. Reset the Context Stack Pointer
        self.ctx.sp = stack_top;

        // No need to clear registers; they get overwritten on switchContext
    }
};

