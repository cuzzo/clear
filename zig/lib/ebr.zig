const std = @import("std");

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
    global_epoch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // A registry so the memory reclaimer can find all active threads
    registry_lock: std.Thread.Mutex = .{},
    registry: std.ArrayListUnmanaged(*ThreadLocalEbr) = .{},

    // The Graveyard for dead threads' garbage
    orphans: std.ArrayListUnmanaged(RetiredPtr) = .{},

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

    pub fn dumpTrash(self: *EbrContext, allocator: std.mem.Allocator, trash: []RetiredPtr) !void {
        self.registry_lock.lock();
        defer self.registry_lock.unlock();
        try self.orphans.appendSlice(allocator, trash);
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
    limbo_list: std.ArrayListUnmanaged(RetiredPtr) = .{},

    // local_epoch: "The time I saw when I started reading"
    local_epoch: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // is_active: "I am currently holding a pointer inside a critical section"
    is_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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

    // Signal that we are starting a read
    pub fn enter(self: *ThreadLocalEbr) void {
        // 1. Mark active
        self.is_active.store(true, .seq_cst);

        // 2. Snap to global time
        // We must load global AFTER marking active to ensure we don't miss an epoch change.
        const global = self.context.global_epoch.load(.seq_cst);
        self.local_epoch.store(global, .seq_cst);
    }

    // Signal that we are done
    pub fn exit(self: *ThreadLocalEbr) void {
        self.is_active.store(false, .seq_cst);
    }
};


