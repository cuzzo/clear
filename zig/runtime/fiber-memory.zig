const std = @import("std");

const fc = @import("fiber-core.zig");

const SlabAllocator = @import("slab-alloc.zig").SlabAllocator;
const StackSize = fc.StackSize;
const Fiber = fc.Fiber;

// Debug seam for hunting fiber-stack leaks. Flip to `true` here when a
// TSan / hammer test reports a leaked region with `(empty stack trace)`
// (DebugAllocator's DWARF unwind returns no frames when the alloc
// happens through a fiber-stack switchTo without CFI). With this on,
// every Scheduler.allocStack records the calling task's user_fn and
// the spawn-handler return address; StackPool.deinit dumps any
// remaining live entries. Resolve the printed addresses with
// `addr2line -e .zig-cache/o/<hash>/test 0x...`.
//
// Comptime-elided when false (default): every record/forget call
// becomes a no-op the optimizer drops. Zero production overhead.
pub const debug_stack_origins: bool = false;

pub const StackOrigin = struct {
    user_fn: usize,
    return_addr: usize,
    size_class: StackSize,
    owner_index: u32,
};

// LOOM-EXCLUDE-BEGIN: compile-time-disabled debug diagnostics
var origins_map: std.AutoHashMap(usize, StackOrigin) = undefined;
var origins_lock: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var origins_initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn lockOrigins() void {
    while (origins_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}
fn unlockOrigins() void {
    origins_lock.store(0, .release);
}
fn ensureOriginsInit() void {
    if (!debug_stack_origins) return;
    if (origins_initialized.load(.acquire)) return;
    lockOrigins();
    defer unlockOrigins();
    if (origins_initialized.load(.monotonic)) return;
    origins_map = std.AutoHashMap(usize, StackOrigin).init(std.heap.c_allocator);
    origins_initialized.store(true, .release);
}
// LOOM-EXCLUDE-END

pub fn recordStackOrigin(ptr: usize, origin: StackOrigin) void {
    if (!debug_stack_origins) return;
    ensureOriginsInit();
    lockOrigins();
    defer unlockOrigins();
    origins_map.put(ptr, origin) catch return;
}

pub fn forgetStackOrigin(ptr: usize) void {
    if (!debug_stack_origins) return;
    ensureOriginsInit();
    lockOrigins();
    defer unlockOrigins();
    _ = origins_map.remove(ptr);
}

pub fn dumpStackOrigins(label: []const u8) void {
    if (!debug_stack_origins) return;
    ensureOriginsInit();
    lockOrigins();
    defer unlockOrigins();
    if (origins_map.count() == 0) return;
    std.debug.print("[STACK-ORIGIN {s}] {d} live\n", .{ label, origins_map.count() });
    var it = origins_map.iterator();
    while (it.next()) |e| {
        std.debug.print(
            "  ptr=0x{x} size={s} owner={d} user_fn=0x{x} alloc_site=0x{x}\n",
            .{ e.key_ptr.*, @tagName(e.value_ptr.size_class), e.value_ptr.owner_index, e.value_ptr.user_fn, e.value_ptr.return_addr },
        );
    }
}

// ---------------------------------------------------------------------------
// Stack size tier constants (total bytes per fiber allocation).
// These are also used by the Scheduler to route the L1 stack cache.
// ---------------------------------------------------------------------------
pub const MICRO_STACK_SIZE:    usize =   4 * 1024;   //   4 KB
pub const STANDARD_STACK_SIZE: usize =  16 * 1024;   //  16 KB  (default)
pub const LARGE_STACK_SIZE:    usize =  64 * 1024;   //  64 KB
pub const XL_STACK_SIZE:       usize = 256 * 1024;   // 256 KB
pub const HUGE_STACK_SIZE:     usize =   4 * 1024 * 1024; // 4 MB service stack

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
        if (debug_stack_origins) dumpStackOrigins("StackPool.deinit");
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

    pub fn alloc(self: *StackPool, size: StackSize) ![]u8 {
        return switch (size) {
            .Micro    => blk: { const p = try self.micro_slab.create();    break :blk p[0..]; },
            .Standard => blk: { const p = try self.standard_slab.create(); break :blk p[0..]; },
            .Large    => blk: { const p = try self.large_slab.create();    break :blk p[0..]; },
            .Xl       => blk: { const p = try self.xl_slab.create();       break :blk p[0..]; },
            .Huge     => try self.allocator.alloc(u8, HUGE_STACK_SIZE),
        };
    }

    pub fn free(self: *StackPool, stack: []u8) void {
        switch (stack.len) {
            MICRO_STACK_SIZE    => { const p: *MicroArray    = @ptrCast(stack.ptr); self.micro_slab.destroy(p); },
            STANDARD_STACK_SIZE => { const p: *StandardArray = @ptrCast(stack.ptr); self.standard_slab.destroy(p); },
            LARGE_STACK_SIZE    => { const p: *LargeArray    = @ptrCast(stack.ptr); self.large_slab.destroy(p); },
            XL_STACK_SIZE       => { const p: *XlArray       = @ptrCast(stack.ptr); self.xl_slab.destroy(p); },
            HUGE_STACK_SIZE     => self.allocator.free(stack),
            else => unreachable,
        }
    }
};

// Kept for the scheduler import that references it; will be removed later.
pub const VirtualArena = void;
