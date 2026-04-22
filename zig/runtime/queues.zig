const std = @import("std");
const fc = @import("fiber-core.zig");

const Fiber = fc.Fiber;
const StackSize = fc.StackSize;

// Comptime atomic type selection: SimAtomic in Loom mode, real atomics otherwise.
// When the root module exports SimAtomic (vopr-loom.zig), all atomic operations
// in RunQueue become yield points for deterministic interleaving.
pub const Atomic = blk: {
    const root = @import("root");
    break :blk if (@hasDecl(root, "SimAtomic")) root.SimAtomic else std.atomic.Value;
};

pub const InboxType = enum { Spawn, Resume, RemoteCall };


// A generic node header that must be embedded in any struct sent to the Inbox.
pub const InboxNode = struct {
    next: ?*InboxNode = null,
    type: InboxType,
    canary: u64 = INBOX_CANARY,

    pub const INBOX_CANARY: u64 = 0xCAFE_BABE_DEAD_BEEF;

    pub fn validate(self: *const InboxNode, label: []const u8) void {
        if (self.canary != INBOX_CANARY) {
            std.debug.print("INBOX CANARY FAIL [{s}]: addr={*} canary=0x{x} type={d} next={?*}\n", .{
                label, self, self.canary, @intFromEnum(self.type), self.next,
            });
            @panic("InboxNode canary corrupted");
        }
    }
};

// Multi-Producer, Single-Consumer Atomic Stack
// Provides a scalable, thread-safe way to spawn new tasks / fibers
pub const AtomicInbox = struct {
    // The "Head" of the linked list.
    // Producers CAS this to push. Consumer SWAPs this to pop all.
    head: Atomic(?*InboxNode) = Atomic(?*InboxNode).init(null),

    /// Producer: Push a single node. Wait-Free.
    pub fn push(self: *AtomicInbox, node: *InboxNode) void {
        node.validate("push");
        var old_head = self.head.load(.monotonic);
        while (true) {
            node.next = old_head;
            // Try to swap Head with Node.
            // If Head is still OldHead, it works. If not, OldHead updates to current.
            old_head = self.head.cmpxchgWeak(
                old_head,
                node,
                .release,
                .monotonic
            ) orelse break;
        }
    }

    /// Consumer: Detach the entire list and return it. Wait-Free.
    pub fn popAll(self: *AtomicInbox) ?*InboxNode {
        // Atomically replace HEAD with NULL. We now own the entire chain.
        return self.head.swap(null, .acquire);
    }

    /// Helper: The list comes out LIFO (Reverse order).
    /// If you strictly need FIFO, call this on the result of popAll.
    pub fn reverse(list: ?*InboxNode) ?*InboxNode {
        var prev: ?*InboxNode = null;
        var curr = list;
        var depth: usize = 0;
        while (curr) |node| {
            node.validate("reverse");
            depth += 1;
            if (depth > 100_000) {
                std.debug.print("INBOX CYCLE: reverse depth > 100K, node={*}\n", .{node});
                @panic("inbox linked list cycle detected");
            }
            const next = node.next;
            node.next = prev;
            prev = node;
            curr = next;
        }
        return prev;
    }
};

// Dynamic Chase-Lev Work-Stealing Deque (Chase & Lev, 2005)
//
// Growable circular buffer behind an atomic CircularArray pointer.
// Starts at 64 slots (512B), doubles when full. Only the owner calls
// push/pop/grow. Thieves call stealOne: pure atomic reads + one CAS.
//
// Pinned tasks are NOT stored here — the scheduler routes them to a
// separate owner-local list, eliminating the thief-pushes-to-victim
// race that caused data corruption.
pub const RunQueue = struct {
    pub const INITIAL_LOG_SIZE: u5 = 6; // 2^6 = 64 slots

    pub const CircularArray = struct {
        data: []Atomic(?*Task),
        mask: u32,
    };

    array: Atomic(?*CircularArray),
    allocator: std.mem.Allocator,
    old_arrays: std.ArrayListUnmanaged(*CircularArray) = .empty,

    top: Atomic(u32) = Atomic(u32).init(0),
    bottom: Atomic(u32) = Atomic(u32).init(0),

    pub fn init() RunQueue {
        return .{ .array = Atomic(?*CircularArray).init(null), .allocator = undefined };
    }

    pub fn initWithAllocator(alloc: std.mem.Allocator) !RunQueue {
        return initWithSize(alloc, INITIAL_LOG_SIZE);
    }

    pub fn initWithSize(alloc: std.mem.Allocator, log_size: u5) !RunQueue {
        const arr = try makeArray(alloc, log_size);
        return .{ .array = Atomic(?*CircularArray).init(arr), .allocator = alloc };
    }

    fn makeArray(alloc: std.mem.Allocator, log_size: u5) !*CircularArray {
        const size = @as(u32, 1) << log_size;
        const data = try alloc.alloc(Atomic(?*Task), size);
        for (data) |*slot| slot.* = Atomic(?*Task).init(null);
        const arr = try alloc.create(CircularArray);
        arr.* = .{ .data = data, .mask = size - 1 };
        return arr;
    }

    fn freeArray(self: *RunQueue, arr: *CircularArray) void {
        self.allocator.free(arr.data);
        self.allocator.destroy(arr);
    }

    pub fn deinit(self: *RunQueue) void {
        if (self.array.load(.monotonic)) |arr| self.freeArray(arr);
        for (self.old_arrays.items) |old| self.freeArray(old);
        self.old_arrays.deinit(self.allocator);
    }

    pub fn getBuffer(self: *RunQueue) []Atomic(?*Task) {
        const arr = self.array.load(.monotonic) orelse return &.{};
        return arr.data;
    }

    pub fn getMask(self: *RunQueue) u32 {
        const arr = self.array.load(.monotonic) orelse return 0;
        return arr.mask;
    }

    fn grow(self: *RunQueue, b: u32, t: u32) !void {
        const old_arr = self.array.load(.monotonic).?;
        const old_log: u5 = @intCast(@ctz(old_arr.mask + 1));
        const new_arr = try makeArray(self.allocator, old_log + 1);
        var i = t;
        while (i != b) : (i +%= 1) {
            new_arr.data[i & new_arr.mask].store(
                old_arr.data[i & old_arr.mask].load(.monotonic), .monotonic);
        }
        self.old_arrays.append(self.allocator, old_arr) catch {};
        self.array.store(new_arr, .release);
    }

    pub fn push(self: *RunQueue, alloc: std.mem.Allocator, task: *Task) !void {
        _ = alloc;
        const b = self.bottom.load(.monotonic);
        const t = self.top.load(.acquire);
        var arr = self.array.load(.monotonic).?;
        if (b -% t > arr.mask) {
            try self.grow(b, t);
            arr = self.array.load(.monotonic).?;
        }
        arr.data[b & arr.mask].store(task, .monotonic);
        self.bottom.store(b +% 1, .release);
    }

    pub fn pop(self: *RunQueue) ?*Task {
        const b = self.bottom.load(.monotonic);
        const t_check = self.top.load(.monotonic);
        if (b -% t_check == 0) return null;
        const new_b = b -% 1;
        self.bottom.store(new_b, .seq_cst);
        const t = self.top.load(.seq_cst);
        const arr = self.array.load(.monotonic).?;
        const task = arr.data[new_b & arr.mask].load(.monotonic);
        const size = new_b -% t;
        if (size > arr.mask) {
            self.bottom.store(b, .monotonic);
            return null;
        }
        if (t == new_b) {
            if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic) != null) {
                self.bottom.store(t +% 1, .monotonic);
                return null;
            }
            self.bottom.store(t +% 1, .monotonic);
            return task;
        }
        return task;
    }

    pub fn len(self: *RunQueue) usize {
        const b = self.bottom.load(.monotonic);
        const t = self.top.load(.monotonic);
        return b -% t;
    }

    // Steal from top — thief only. Pure atomic reads + one CAS.
    // No pinned check — pinned tasks are never in this queue.
    pub fn stealOne(self: *RunQueue) ?*Task {
        const t = self.top.load(.acquire);
        const b = self.bottom.load(.seq_cst);
        const arr = self.array.load(.acquire) orelse return null;
        const size = b -% t;
        if (size == 0 or size > arr.mask) return null;
        const task = arr.data[t & arr.mask].load(.acquire);
        if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic) != null) {
            return null;
        }
        return task;
    }

    pub fn tryStealFrom(self: *RunQueue, victim: *RunQueue, alloc: std.mem.Allocator) usize {
        const v_len = victim.len();
        if (v_len == 0) return 0;
        const target = (v_len + 1) / 2;
        var stolen_count: usize = 0;
        while (stolen_count < target) {
            const task = victim.stealOne() orelse break;
            self.push(alloc, task) catch break;
            stolen_count += 1;
        }
        return stolen_count;
    }
};

// Tasks

pub const TaskFn = *const fn (rt: *anyopaque, ctx: ?*anyopaque) anyerror!void;

pub const TaskStatus = enum(u8) {
    Ready = 0,    // Run me again
    Finished = 1, // Recycle me
    Blocked = 2,  // Don't run me, I'm waiting on something
};

// Lock timeout: 30 seconds. Panics instead of hanging forever.
pub const LOCK_TIMEOUT_MS: i64 = 30_000;

// Intrusive waiter node placed on the parking fiber's stack (no heap alloc).
// Used by ParkingMutex and ParkingRwLock to track blocked fibers.
pub const WaiterNode = struct {
    task: *Task = undefined,
    sched_ptr: *anyopaque = undefined, // *Scheduler, erased to avoid circular import
    next: ?*WaiterNode = null,
};

// Spinlock-protected intrusive linked list of WaiterNodes.
// Placed inside ParkingMutex / ParkingRwLock. Not heap-allocated.
pub const WaiterList = struct {
    head: ?*WaiterNode = null,
    spin: Atomic(u32) = Atomic(u32).init(0),

    pub fn spinAcquire(self: *WaiterList) void {
        while (self.spin.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn spinRelease(self: *WaiterList) void {
        self.spin.store(0, .release);
    }

    pub fn push(self: *WaiterList, node: *WaiterNode) void {
        node.next = self.head;
        self.head = node;
    }

    pub fn pop(self: *WaiterList) ?*WaiterNode {
        const h = self.head orelse return null;
        self.head = h.next;
        h.next = null;
        return h;
    }

    pub fn remove(self: *WaiterList, target: *WaiterNode) bool {
        var prev: ?*WaiterNode = null;
        var curr = self.head;
        while (curr) |c| {
            if (c == target) {
                if (prev) |p| p.next = c.next else self.head = c.next;
                c.next = null;
                return true;
            }
            prev = c;
            curr = c.next;
        }
        return false;
    }

    pub fn isEmpty(self: *const WaiterList) bool {
        return self.head == null;
    }
};

pub const TaskConfig = struct {
    timeout_ms: u64 = 0,
    stack_size: StackSize = .Standard,  // Default to Standard
    pinned: bool = false,              // true = cannot be stolen by other schedulers
    use_arena: bool = false,           // true = expose scheduler local_arena via __pinned_local_alloc (@arena BG blocks only)
};

pub const Task = struct {
    base: *Fiber,
    user_fn: TaskFn,
    inbox_link: InboxNode = .{ .type = .Resume },
    runtime_ptr: ?*anyopaque = null,
    context: ?*anyopaque = null,
    status: Atomic(TaskStatus) = Atomic(TaskStatus).init(.Ready),
    config: TaskConfig = .{},
    is_on_root_stack: bool = false,
    /// Debug guard: set to true when inbox_link is pushed to an inbox,
    /// cleared when drainInbox processes it. Detects double-push.
    in_inbox: Atomic(bool) = Atomic(bool).init(false),
    wake_time: i64 = 0, // Timestamp to wake up (0 = not sleeping - deal with it)

    // Parking-lot lock fields. Set by ParkingMutex/ParkingRwLock on park.
    // Read by the scheduler's timeout scanner. Always null when not parked.
    // Using std.atomic.Value (not SimAtomic) so scheduler can safely read
    // from its loop without these becoming Loom yield points.
    waiting_for_lock: std.atomic.Value(?*anyopaque) = std.atomic.Value(?*anyopaque).init(null),
    waiting_for_lock_list: ?*WaiterList = null, // back-ptr to lock's waiter list
    lock_waiter_node: ?*WaiterNode = null,      // back-ptr to our WaiterNode in that list
    lock_wait_start_ms: i64 = 0,
    lock_timed_out: bool = false,
    // Set to the exclusive owner of the lock this task is blocked on.
    // Used by cycle detection: follow the chain task -> owner -> owner -> ...
    // Null when not blocked or blocked on a read lock (no single owner).
    waiting_for_lock_owner: ?*Task = null,
};
