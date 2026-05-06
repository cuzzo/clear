const std = @import("std");
const compat = @import("compat.zig");

// Comptime atomic type selection: SimAtomic in Loom mode, real
// std.atomic.Value otherwise. When the root module exports
// `SimAtomic`, every load/store/cmpxchg becomes a deterministic
// yield point. Mirrors the pattern used by queues.zig +
// scheduler.zig + shared-memory.zig.
pub const Atomic = blk: {
    const root = @import("root");
    break :blk if (@hasDecl(root, "SimAtomic")) root.SimAtomic else std.atomic.Value;
};

// EBR
pub const RetiredPtr = struct {
    ptr: *anyopaque,
    // We need a function pointer to know how to free this specific type later
    deinit_fn: *const fn (allocator: std.mem.Allocator, ptr: *anyopaque) void,

    // We must store the epoch so we know WHEN it was deleted
    epoch: u32,

    // Helper to wrap the type-erasure
    pub fn create(comptime T: type, ptr: *T, epoch: u32) RetiredPtr {
        return .{
            .ptr = ptr,
            .epoch = epoch,
            .deinit_fn = struct {
                fn call(allocator: std.mem.Allocator, p: *anyopaque) void {
                    const typed: *T = @ptrCast(@alignCast(p));
                    allocator.destroy(typed);
                }
            }.call,
        };
    }
};

pub const EbrContext = struct {
    // The Global Clock (0, 1, 2...)
    global_epoch: Atomic(u32) = Atomic(u32).init(0),

    // A registry so the memory reclaimer can find all active threads
    registry_lock: compat.Mutex = .{},
    registry: std.ArrayListUnmanaged(*ThreadLocalEbr) = .empty,

    // The Graveyard for dead threads' garbage
    orphans: std.ArrayListUnmanaged(RetiredPtr) = .empty,

    pub fn deinit(self: *EbrContext, allocator: std.mem.Allocator) void {
        self.registry.deinit(allocator);
        for (self.orphans.items) |item| {
            item.deinit_fn(allocator, item.ptr);
        }
        self.orphans.deinit(allocator);
    }

    // Register a new thread (We will call this when threads start)
    pub fn register(self: *EbrContext, allocator: std.mem.Allocator, local: *ThreadLocalEbr) !void {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();
        try self.registry.append(allocator, local);
    }

    pub fn unregister(self: *EbrContext, local: *ThreadLocalEbr) void {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();

        // Find the pointer and remove it
        for (self.registry.items, 0..) |item, i| {
            if (item == local) {
                // swapRemove is O(1) - it moves the last item to this spot
                _ = self.registry.swapRemove(i);
                return;
            }
        }
    }

    /// Move a dying thread's pending limbo into the global orphans
    /// list. M2: pre-filter items already past the safe threshold and
    /// free them immediately, so a steady churn of short-lived
    /// threads under heavy reclaim pressure can't grow `orphans`
    /// unboundedly. Items still inside the grace window go to
    /// `orphans` for `reclaim()` to pick up later.
    pub fn dumpTrash(self: *EbrContext, allocator: std.mem.Allocator, trash: []RetiredPtr) !void {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();

        const global_epoch = self.global_epoch.load(.seq_cst);
        const safe_threshold = if (global_epoch > 1) global_epoch - 1 else 0;

        for (trash) |item| {
            if (item.epoch < safe_threshold) {
                // Already past the grace window -- free directly.
                item.deinit_fn(allocator, item.ptr);
            } else {
                try self.orphans.append(allocator, item);
            }
        }
    }

    // You can call this periodically (e.g., every 1000 updates, or on a timer).
    pub fn reclaim(self: *EbrContext, allocator: std.mem.Allocator) void {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();

        // 1. Advance Global Epoch
        const current_global = self.global_epoch.load(.seq_cst);
        var can_advance = true;

        for (self.registry.items) |thread_local| {
            if (thread_local.is_active.load(.seq_cst)) {
                const t_epoch = thread_local.local_epoch.load(.seq_cst);
                if (t_epoch != current_global) {
                    can_advance = false;
                    break;
                }
            }
        }

        if (can_advance) {
            self.global_epoch.store(current_global + 1, .seq_cst);

            // 2. CLEAN ORPHANS ONLY
            // [MOVED] We stopped iterating active threads here. That was the bug.
            const safe_threshold = if (current_global > 1) current_global - 1 else 0;

            var i: usize = 0;
            while (i < self.orphans.items.len) {
                const item = self.orphans.items[i];
                if (item.epoch < safe_threshold) {
                    item.deinit_fn(allocator, item.ptr);
                    _ = self.orphans.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }
    }
};

pub const ThreadLocalEbr = struct {
    // Things I have deleted but not freed
    limbo_list: std.ArrayListUnmanaged(RetiredPtr) = .empty,

    // local_epoch: "The time I saw when I started reading"
    local_epoch: Atomic(u32) = Atomic(u32).init(0),

    // is_active: "I am currently holding a pointer inside a critical section"
    is_active: Atomic(bool) = Atomic(bool).init(false),

    // Nested EBR guards on the same participant. The first enter publishes
    // the epoch; only the final exit clears is_active.
    pin_depth: Atomic(u32) = Atomic(u32).init(0),

    // link to the global world
    context: *EbrContext,

    pub fn deinit(self: *ThreadLocalEbr, allocator: std.mem.Allocator) void {
        if (self.limbo_list.items.len > 0) {
            // Try to move to global orphans
            self.context.dumpTrash(allocator, self.limbo_list.items) catch {
                // Fallback: If OOM, we must force free to avoid leaks.
                for (self.limbo_list.items) |node| {
                    node.deinit_fn(allocator, node.ptr);
                }
            };
        }
        self.limbo_list.deinit(allocator);
    }

    pub fn retire(self: *ThreadLocalEbr, allocator: std.mem.Allocator, ptr: anytype) !void {
        const T = @TypeOf(ptr.*);
        const current_time = self.local_epoch.load(.monotonic);
        const node = RetiredPtr.create(T, ptr, current_time);
        try self.limbo_list.append(allocator, node);
    }

    pub fn reclaimLocal(self: *ThreadLocalEbr, allocator: std.mem.Allocator) void {
        // Read the global epoch to know what is safe
        const global_epoch = self.context.global_epoch.load(.seq_cst);
        const safe_threshold = if (global_epoch > 1) global_epoch - 1 else 0;

        var i: usize = 0;
        while (i < self.limbo_list.items.len) {
            const item = self.limbo_list.items[i];

            if (item.epoch < safe_threshold) {
                // SAFE TO FREE
                item.deinit_fn(allocator, item.ptr);
                // Safe to modify: We are the only thread touching this list
                _ = self.limbo_list.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    // Signal that we are starting a read.
    //
    // Memory-ordering rationale (3 seq_cst -> 1 seq_cst + 2 relaxed):
    //
    // The protocol requires reclaim to observe (is_active=true,
    // local_epoch=G) atomically when iterating the registry, so it can
    // either bail (mismatch) or advance safely. We get that with a
    // release-store on is_active: any thread that does an acquire-load
    // of is_active and sees `true` is guaranteed to see all prior
    // writes by this thread, including the local_epoch store -- even
    // if local_epoch was stored .relaxed/.monotonic. The seq_cst on
    // is_active.store doubles as the StoreLoad fence the reader needs
    // before its first data load (cell pointer), so reclaim cannot
    // observe is_active=false after this returns. The local_epoch
    // store can therefore be .monotonic; the global_epoch load can
    // be .acquire (only the .seq_cst total order through is_active
    // matters for safety, not the global_epoch.load itself -- the
    // worst case is a stale read pinning at a too-low epoch, which
    // makes reclaim conservative, never unsafe).
    //
    // This drops one full mfence per enter() on x86 (was 2 xchg/mfence,
    // now 1) and is the dominant cost in tight read loops like the
    // bench-17 200K-read fiber.
    pub fn enter(self: *ThreadLocalEbr) void {
        const prev_depth = self.pin_depth.fetchAdd(1, .acq_rel);
        if (prev_depth != 0) return;

        const global = self.context.global_epoch.load(.acquire);
        self.local_epoch.store(global, .monotonic);
        // The .seq_cst here is doing two jobs:
        //   (1) StoreLoad fence so subsequent data loads cannot be
        //       reordered before the pin publish.
        //   (2) release-store so the .monotonic local_epoch above
        //       is visible to any thread that acquire-loads is_active
        //       and sees true.
        self.is_active.store(true, .seq_cst);
    }

    // Signal that we are done.
    //
    // .release (not .seq_cst) is sufficient: we need LoadStore
    // ordering so prior data loads cannot be reordered after the
    // exit publish. Release-store provides that. We do NOT need
    // StoreLoad (no further loads in this thread depend on reclaim
    // observing is_active=false promptly).
    pub fn exit(self: *ThreadLocalEbr) void {
        const prev_depth = self.pin_depth.fetchSub(1, .acq_rel);
        std.debug.assert(prev_depth > 0);
        if (prev_depth != 1) return;

        self.is_active.store(false, .release);
    }
};
