const std = @import("std");
const fc = @import("fiber-core.zig");

const Fiber = fc.Fiber;
const StackSize = fc.StackSize;

pub const InboxType = enum { Spawn, Resume };


// A generic node header that must be embedded in any struct sent to the Inbox.
pub const InboxNode = struct {
    next: ?*InboxNode = null,
    type: InboxType,
};

// Multi-Producer, Single-Consumer Atomic Stack
// Provides a scalable, thread-safe way to spawn new tasks / fibers
pub const AtomicInbox = struct {
    // The "Head" of the linked list.
    // Producers CAS this to push. Consumer SWAPs this to pop all.
    head: std.atomic.Value(?*InboxNode) = std.atomic.Value(?*InboxNode).init(null),

    /// Producer: Push a single node. Wait-Free.
    pub fn push(self: *AtomicInbox, node: *InboxNode) void {
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
        while (curr) |node| {
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
    buffer: [65536]std.atomic.Value(?*Task) = undefined,
    mask: u32 = 65535,

    top: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    bottom: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn init() RunQueue {
        var q = RunQueue{};
        for (&q.buffer) |*slot| slot.* = std.atomic.Value(?*Task).init(null);
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


    // Chase-Lev Pop Bottom - lock free
    pub fn pop(self: *RunQueue) ?*Task {
        const b = self.bottom.load(.monotonic);

        const t_check = self.top.load(.monotonic);
        if (b -% t_check == 0) return null;

        const new_b = b -% 1;
        self.bottom.store(new_b, .seq_cst);

        const t = self.top.load(.monotonic);
        const task = self.buffer[new_b & self.mask].load(.monotonic);

        const size = new_b -% t;
        if (size > self.mask) {
            // Queue is empty (new_b is effectively less than t)
            self.bottom.store(b, .monotonic);
            return null;
        }

        if (t == new_b) {
            // Race with thief
            if (self.top.cmpxchgWeak(t, t +% 1, .seq_cst, .monotonic) != null) {
                self.bottom.store(b, .monotonic); // Lost race
                return null;
            }
            self.bottom.store(b, .monotonic);
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

    // Used internally by tryStealFrom
    fn stealOne(self: *RunQueue) ?*Task {
        const t = self.top.load(.acquire);
        const b = self.bottom.load(.seq_cst);

        const size = b -% t;
        if (size == 0 or size > self.mask) return null;

        const task = self.buffer[t & self.mask].load(.monotonic);
        if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic) != null) {
            return null;  // Lost race
        }
        return task;
    }

    // For stealing (Take half, lock free)
    pub fn tryStealFrom(self: *RunQueue, victim: *RunQueue, alloc: std.mem.Allocator, fallback_inbox: *AtomicInbox) usize {
        const v_len = victim.len();
        if (v_len == 0) return 0;

        const target = (v_len + 1) / 2;
        var stolen_count: usize = 0;

        while (stolen_count < target) {
            const task = victim.stealOne() orelse break;

            self.push(alloc, task) catch {
                // FIX: Queue is full, but we already stole the task!
                // We cannot drop it. We must offload it to the inbox.
                task.inbox_link.type = .Resume;
                fallback_inbox.push(&task.inbox_link);

                // We successfully took responsibility for the task, even if we put it in inbox.
                stolen_count += 1;
                continue;
            };
            stolen_count += 1;
        }

        return stolen_count;
    }
};

// Tasks

pub const TaskFn = *const fn (rt: *anyopaque, ctx: ?*anyopaque) anyerror!void;

pub const TaskStatus = enum {
    Ready,    // Run me again
    Finished, // Recycle me
    Blocked,  // Don't run me, I'm waiting on something
};

pub const TaskConfig = struct {
    timeout_ms: u64 = 0,
    stack_size: StackSize = .Standard,  // Default to Standard
};

pub const Task = struct {
    base: *Fiber,
    user_fn: TaskFn,
    inbox_link: InboxNode = .{ .type = .Resume },
    runtime_ptr: ?*anyopaque = null,
    context: ?*anyopaque = null,
    status: TaskStatus = .Ready,
    config: TaskConfig = .{},
    is_on_root_stack: bool = false,
    wake_time: i64 = 0, // Timestamp to wake up (0 = not sleeping - deal with it)
};

