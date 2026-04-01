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

// TODO: Rename to Deque
pub const RunQueue = struct {
    // Fixed size ring buffer for MVP
    buffer: [65536]Atomic(?*Task) = undefined,
    mask: u32 = 65535,

    top: Atomic(u32) = Atomic(u32).init(0),
    bottom: Atomic(u32) = Atomic(u32).init(0),

    pub fn init() RunQueue {
        var q = RunQueue{};
        for (&q.buffer) |*slot| slot.* = Atomic(?*Task).init(null);
        return q;
    }

    // push (bottom) - lock free
    pub fn push(self: *RunQueue, alloc: std.mem.Allocator, task: *Task) !void {
        _ = alloc; // Don't need allocator for fixed buffer

        // Chase-Lev Push Bottom
        const b = self.bottom.load(.monotonic);
        const t = self.top.load(.acquire);

        if (b -% t > self.mask) return error.QueueFull; // MVP limitation

        self.buffer[b & self.mask].store(task, .monotonic);
        self.bottom.store(b +% 1, .release);
    }


    // Chase-Lev Pop Bottom (owner-side dequeue)
    // Ref: "Dynamic Circular Work-Stealing Deque" (Chase & Lev, 2005)
    //
    // The owner decrements bottom, then checks top. A seq_cst fence between
    // the bottom store and top load is REQUIRED to prevent the owner and a
    // thief from reading the same element. Without it, the CPU can reorder
    // the bottom store past the top load, causing a double-read.
    pub fn pop(self: *RunQueue) ?*Task {
        const b = self.bottom.load(.monotonic);
        const t_check = self.top.load(.monotonic);
        if (b -% t_check == 0) return null;

        const new_b = b -% 1;
        // seq_cst store: ensures the bottom decrement is visible to thieves
        // BEFORE we read top. This is the critical synchronization point
        // in the Chase-Lev algorithm. Without seq_cst here, the CPU can
        // reorder this store past the top load, causing double-reads.
        self.bottom.store(new_b, .seq_cst);

        const t = self.top.load(.seq_cst);
        const task = self.buffer[new_b & self.mask].load(.monotonic);

        const size = new_b -% t;
        if (size > self.mask) {
            // Queue is empty (new_b wrapped past t)
            self.bottom.store(b, .monotonic);
            return null;
        }

        if (t == new_b) {
            // Last element — race with thief. CAS to claim it.
            if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic) != null) {
                // Lost race — thief got it.
                self.bottom.store(t +% 1, .monotonic);
                return null;
            }
            self.bottom.store(t +% 1, .monotonic);
            return task;
        }
        return task;
    }

    // Safe length check
    pub fn len(self: *RunQueue) usize {
        const b = self.bottom.load(.monotonic);
        const t = self.top.load(.monotonic); // TODO: May need to be .seq_cast
        return b -% t;
    }

    // Used internally by tryStealFrom.
    // Skips pinned tasks — they must stay on their owning scheduler's thread.
    pub fn stealOne(self: *RunQueue) ?*Task {
        const t = self.top.load(.acquire);
        const b = self.bottom.load(.seq_cst);

        const size = b -% t;
        if (size == 0 or size > self.mask) return null;

        // Read the task pointer.
        const task = self.buffer[t & self.mask].load(.acquire);

        // CAS to claim the slot BEFORE dereferencing the task pointer.
        // Without this ordering, the owner can pop() and free() the task
        // between our read and dereference, causing use-after-free.
        if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic) != null) {
            return null;  // Lost race with another thief or owner
        }

        // Now we own the slot. Safe to dereference.
        // If pinned, push it back — the task must stay on its owning scheduler.
        if (task) |t_ptr| {
            if (t_ptr.config.pinned) {
                self.push(std.heap.c_allocator, t_ptr) catch {};
                return null;
            }
        }
        return task;
    }

    // For stealing (Take half, lock free)
    pub fn tryStealFrom(self: *RunQueue, victim: *RunQueue, alloc: std.mem.Allocator) usize {
        const v_len = victim.len();
        if (v_len == 0) return 0;

        const target = (v_len + 1) / 2;
        var stolen_count: usize = 0;

        while (stolen_count < target) {
            const task = victim.stealOne() orelse break;
            self.push(alloc, task) catch break; // queue full — stop stealing
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

pub const TaskConfig = struct {
    timeout_ms: u64 = 0,
    stack_size: StackSize = .Standard,  // Default to Standard
    pinned: bool = false,              // true = cannot be stolen by other schedulers
};

pub const Task = struct {
    base: *Fiber,
    user_fn: TaskFn,
    inbox_link: InboxNode = .{ .type = .Resume },
    runtime_ptr: ?*anyopaque = null,
    context: ?*anyopaque = null,
    status: std.atomic.Value(TaskStatus) = std.atomic.Value(TaskStatus).init(.Ready),
    config: TaskConfig = .{},
    is_on_root_stack: bool = false,
    /// Debug guard: set to true when inbox_link is pushed to an inbox,
    /// cleared when drainInbox processes it. Detects double-push.
    in_inbox: Atomic(bool) = Atomic(bool).init(false),
    wake_time: i64 = 0, // Timestamp to wake up (0 = not sleeping - deal with it)
    /// Tracks which scheduler's epoll this task's fd is registered with.
    /// When a fiber is stolen, the old scheduler's epoll still has the fd.
    /// On the next registerFd, we unregister from the old scheduler first.
    epoll_fd: i32 = -1,
    epoll_io_fd: i32 = -1,
};

