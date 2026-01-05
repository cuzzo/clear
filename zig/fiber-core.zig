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

        // MAXIMIZE STACK USAGE:
        // 1. Align the absolute top to 16 bytes.
        // 2. Subtract 8 bytes. This is the slot for our "Trampoline" (Return Address).
        // Result: SP is 16-byte aligned - 8. When 'ret' runs, SP becomes 16-byte aligned.
        const aligned_top = stack_top_addr & ~@as(usize, 15);
        const stack_top = aligned_top - 8;

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

