const std = @import("std");
const builtin = @import("builtin");
const safety = @import("safety.zig");

// Fibers

// The registers we need to save.
// This layout matches the assembly exactly.

pub const Context = if (builtin.cpu.arch == .x86_64) extern struct {
    sp: u64,
    rbx: u64 = 0,
    rbp: u64 = 0,
    r12: u64 = 0,
    r13: u64 = 0,
    r14: u64 = 0,
    r15: u64 = 0,
} else if (builtin.cpu.arch == .aarch64) extern struct {
    sp: u64,
    x19: u64 = 0,
    x20: u64 = 0,
    x21: u64 = 0,
    x22: u64 = 0,
    x23: u64 = 0,
    x24: u64 = 0,
    x25: u64 = 0,
    x26: u64 = 0,
    x27: u64 = 0,
    x28: u64 = 0,
    fp: u64 = 0, // x29 is frame pointer
    lr: u64 = 0, // x30 is link register
} else @compileError("Unsupported Architecture");

// 1. Declare the external symbol
// Zig will look for this in the .s file we just created.
extern fn switch_context_asm(from: *Context, to: *Context) callconv(.c) void;

// 2. Public Wrapper
pub fn switchContext(from: *Context, to: *Context) void {
    switch_context_asm(from, to);
}

// 3. switch to Root Stack
extern fn call_on_stack_asm(stack_ptr: usize, func: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) void;

pub fn callOnStack(stack_ptr: usize, func: *const fn (?*anyopaque) callconv(.c) void, arg: ?*anyopaque) void {
    const aligned_sp = stack_ptr & ~@as(usize, 0xF);
    call_on_stack_asm(aligned_sp, func, arg);
}

pub export threadlocal var __fiber_stack_limit: ?*u8 = null;
pub export threadlocal var __fiber_parent_ctx: ?*Context = null;
pub export threadlocal var __fiber: ?*Fiber = null;

// ── Control plane: current task identity ─────────────────────────
// Set by the scheduler before switching to a task, read by
// __zig_alloc_segment on overflow to identify the task class.
pub threadlocal var __current_task_fn: usize = 0;
pub threadlocal var __current_task_size: StackSize = .Standard;


pub const StackSegment = struct {
    memory: []u8,
    previous_sp: usize,    // Where we came from
    previous_limit: usize, // The limit of the previous stack
    previous_segment: ?*StackSegment,
};

threadlocal var segment_pool: [20][]u8 = undefined;
threadlocal var segment_index: usize = 0;
pub threadlocal var __test_last_allocation: []u8 = &.{};

// CACHE: Pointer to the thread-local pool.
// We resolve this ONCE during setup, so we don't need complex TLS logic
// inside the tiny stack allocator.
pub threadlocal var pool_addr_cache: ?* [20][]u8 = null;

// Helper for tests to setup the pool
pub fn test_setup_segment_pool(allocator: std.mem.Allocator) !void {
    pool_addr_cache = &segment_pool;

    segment_index = 0;
    for (&segment_pool) |*slot| {
        // Allocate real heap memory
        slot.* = try allocator.alloc(u8, 32 * 1024);
        @memset(slot.*, 0xAA); // Pre-fill to be safe
    }
}

pub fn test_teardown_segment_pool(allocator: std.mem.Allocator) void {
    for (segment_pool) |slot| {
        if (slot.len > 0) allocator.free(slot);
    }
}

fn alloc_segment_impl() usize {
    // Disable Safety to avoid panic overhead in the Red Zone
    @setRuntimeSafety(false);

    const pool_ptr = pool_addr_cache orelse {
        @trap(); // Setup was not called!
    };

    const idx = segment_index;
    if (idx >= pool_ptr.len) {
        @trap();
    }

    // Increment Thread-Local Index
    segment_index += 1;

    // Get the slice from the pool correctly.
    // We want the address OF the slot.
    const new_mem = pool_ptr[idx];

    if (@intFromPtr(new_mem.ptr) < 0x1000) {
        @trap(); // We got garbage (like 0xCC) again. Trap immediately.
    }

    __test_last_allocation = new_mem;

    // 5. Minimal Setup (Zero stack usage)
    //    We fill with 0xCC to help debugging, but we do NOT call Fiber.init or print.
    @memset(new_mem, 0xCC);

    // 6. Calculate Top (High Address)
    const stack_top = @intFromPtr(new_mem.ptr) + new_mem.len;

    // 7. Align 16-byte
    const aligned_top = (stack_top & ~@as(usize, 15));

    return aligned_top;
}

pub export fn __zig_alloc_segment(old_sp: usize) callconv(.c) usize {
    _ = old_sp; // Currently unused, but keeps ABI honest
    @setRuntimeSafety(false);

    // Notify the control plane that this task class overflowed.
    const cp = @import("control-plane.zig");
    cp.recordOverflow(__current_task_fn, __current_task_size);

    return alloc_segment_impl();
}

pub export fn __zig_free_segment(current_sp_ptr: usize) callconv(.c) void {
    _ = current_sp_ptr;
    segment_index -= 1;
}

// CHEAT uses VMA Pooling with mprotect and madvise.
// 2MB is not the per-fiber stack memory usage. It's the limit.
// 4KB is the minimum (p95) size.
pub const StackSize = enum {
    /// Micro: 4 KB total (4 KB stack; arena allocated lazily on first use up to 4 KB)
    Micro,
    /// Standard: 16 KB total (12 KB stack + 4 KB arena) — default for all spawns
    Standard,
    /// Large: 64 KB total (60 KB stack + 4 KB arena)
    Large,
    /// Xl: 256 KB total (252 KB stack + 4 KB arena)
    Xl,
    /// Huge: 2 MB total — for tests where __morestack is not available
    Huge,
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
    stack_limit: usize,
    stack_guard_head: ?*safety.GuardNode = null,

    pub fn init(memory: []u8, entry_fn: usize, size: StackSize) Fiber {
        //std.debug.print("\n=== Fiber.init ===\n", .{});
        //std.debug.print("Memory: 0x{x} - 0x{x} ({} bytes)\n", .{
        //    @intFromPtr(memory.ptr),
        //    @intFromPtr(memory.ptr) + memory.len,
        //    memory.len,
        //});
        //std.debug.print("Entry function: 0x{x}\n", .{entry_fn});

        // Fill stack with pattern to debug
        @memset(memory, 0xCC);

        const stack = Stack{ .memory = memory };
        const stack_top_addr = @intFromPtr(memory.ptr) + memory.len;
        const aligned_top = stack_top_addr & ~@as(usize, 15);

        //std.debug.print("Stack top addr: 0x{x}\n", .{stack_top_addr});
        //std.debug.print("Aligned top: 0x{x}\n", .{aligned_top});

        const return_addr_location = aligned_top - 128;  // Back off past Red Zone
        //std.debug.print("Return addr location: 0x{x}\n", .{return_addr_location});

        const ptr = @as(*usize, @ptrFromInt(return_addr_location));
        ptr.* = entry_fn;

        //std.debug.print("Stored value: 0x{x}\n", .{ptr.*});
        //std.debug.print("Verify read back: 0x{x}\n", .{ptr.*});

        const initial_sp = return_addr_location;
        //std.debug.print("Initial SP: 0x{x}\n", .{initial_sp});

        const stack_bottom_addr = @intFromPtr(memory.ptr);
        const safety_margin = 512;
        const limit = stack_bottom_addr + safety_margin;

        //std.debug.print("Stack limit: 0x{x}\n", .{limit});
        //std.debug.print("=================\n\n", .{});

        return Fiber{
            .stack = stack,
            // Point SP to the address we just wrote.
            // When 'ret' runs, it pops the value AT this pointer.
            .ctx = Context{ .sp = initial_sp },
            .stack_limit = limit,
            .parent_ctx = undefined,
            .size_class = size,
            .stack_guard_head = null,
        };
    }

    // Switch FROM parent TO this fiber
    pub fn switchTo(self: *Fiber, parent: *Context) void {
        self.parent_ctx = parent;
        __fiber_stack_limit = @ptrFromInt(self.stack_limit);
        __fiber_parent_ctx = parent;
        __fiber = self;
        safety.stack_guard_head = self.stack_guard_head;
        switchContext(parent, &self.ctx);
    }

    // Switch FROM this fiber BACK to parent
    // Before yielding, scheduler must check task.is_on_root_stack
    pub fn yield(self: *Fiber) void {
        __fiber_stack_limit = undefined;
        __fiber = undefined;
        safety.stack_guard_head = null;
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

