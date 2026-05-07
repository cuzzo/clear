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
        errdefer alloc.free(data);
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
        // Compare via signed delta. `b -% t` is unsigned wrapping arithmetic;
        // when an interleaved pop has incremented `top` but not yet restored
        // `bottom`, b can be transiently less than t and the unsigned diff
        // wraps to ~MAX_U32, falsely tripping grow() and looping `MAX_U32`
        // copies. The signed compare correctly observes the transient
        // negative size as "no grow needed" — the queue still has room.
        const size_signed = @as(i64, b) - @as(i64, t);
        if (size_signed > @as(i64, arr.mask)) {
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
// Waiter kind is used by ParkingRwLock's FIFO waiter list so the wake path
// knows whether to grant a read or a write slot. ParkingMutex ignores it.
pub const WaiterKind = enum(u8) { Write, Read };

pub const WaiterNode = struct {
    task: *Task = undefined,
    fsm_task: ?*anyopaque = null, // *FsmTask, erased to avoid circular import
    sched_ptr: *anyopaque = undefined, // *Scheduler, erased to avoid circular import
    next: ?*WaiterNode = null,
    kind: WaiterKind = .Write,

    pub fn isFsm(self: *const WaiterNode) bool {
        return self.fsm_task != null;
    }
};

// Spinlock-protected intrusive FIFO queue of WaiterNodes.
// Placed inside ParkingMutex / ParkingRwLock. Not heap-allocated.
// push() appends to the tail; pop() removes from the head. FIFO prevents
// waiter starvation under high contention regardless of whether the lock
// is a mutex (LIFO would let new arrivals keep grabbing the lock ahead of
// already-parked fibers) or an rwlock (FIFO is the basis of fair ordering).
pub const WaiterList = struct {
    head: ?*WaiterNode = null,
    tail: ?*WaiterNode = null,
    spin: Atomic(u32) = Atomic(u32).init(0),

    pub fn spinAcquire(self: *WaiterList) void {
        while (self.spin.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn spinRelease(self: *WaiterList) void {
        self.spin.store(0, .release);
    }

    // Append to tail (FIFO).
    pub fn push(self: *WaiterList, node: *WaiterNode) void {
        node.next = null;
        if (self.tail) |t| {
            t.next = node;
            self.tail = node;
        } else {
            self.head = node;
            self.tail = node;
        }
    }

    // Remove from head.
    pub fn pop(self: *WaiterList) ?*WaiterNode {
        const h = self.head orelse return null;
        self.head = h.next;
        if (self.head == null) self.tail = null;
        h.next = null;
        return h;
    }

    // Peek at head without removing (used by rwlock wakeNext to decide
    // whether the next drain step is a reader or a writer).
    pub fn peek(self: *const WaiterList) ?*WaiterNode {
        return self.head;
    }

    pub fn remove(self: *WaiterList, target: *WaiterNode) bool {
        var prev: ?*WaiterNode = null;
        var curr = self.head;
        while (curr) |c| {
            if (c == target) {
                if (prev) |p| p.next = c.next else self.head = c.next;
                if (self.tail == c) self.tail = prev;
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
    profile_site_id: u32 = 0,          // profile-only BG/worker site id; 0 = unattributed
    profile_dispatch: u8 = 0,          // profile-only: fiber-profile.DispatchKind enum value
};

// ─────────────────────────────────────────────────────────────────────────────
// Task layout — fields are grouped logically so that within each cache line
// the contents are correlated, but we do NOT force align(64) on group
// boundaries. Forcing alignment causes Zig to reorder fields (the aligned
// field gets moved to the front), which in turn changes lock-state pointer
// observability under VOPR-style schedules and induces livelock in the
// loom harness. Slab-allocated Tasks naturally pack and the SlabAllocator
// chooses slab geometry; revisit hard cache-line padding only if profiling
// shows true false-sharing on these fields.
//
// Group 1: owner-only hot fields. ONLY the scheduler-thread currently
// running this Task touches these.
//
// Group 2: cross-thread-touched atomics. detectCycle (any scheduler),
// submitResume (any scheduler), and the timeout scanner read/write here.
//
// Group 3: cold/rare fields. Not on any hot path.
// ─────────────────────────────────────────────────────────────────────────────
pub const Task = struct {
    // ── Group 1: owner-only hot ─────────────────────────────────────────
    base: *Fiber,                      // 8
    user_fn: TaskFn,                   // 8
    runtime_ptr: ?*anyopaque = null,   // 8
    context: ?*anyopaque = null,       // 8
    config: TaskConfig = .{},          // 16  (timeout u64 + 3 bools padded)
    spawn_ns: u64 = 0,                 // 8   (profile-only)
    profile_site_id: u32 = 0,          // 4   (profile-only)
    wake_time: i64 = 0,                // 8   (0 = not sleeping)

    // ── Group 2: cross-thread-touched atomics ───────────────────────────
    status: Atomic(TaskStatus) = Atomic(TaskStatus).init(.Ready),
    /// 3-state slot guard for the cross-scheduler submitResume race
    /// against the .Finished destroy in run(). State machine:
    ///   IDLE       (0) -- task is running OR not in any queue
    ///   IN_QUEUE   (1) -- task is enqueued, waiting to be popped
    ///   DESTROYING (2) -- run()'s .Finished branch claimed the slot;
    ///                     no further submitResume push is permitted
    ///
    /// Transitions (all CAS):
    ///   submitResume:  IDLE       -> IN_QUEUE
    ///   run-loop pop:  IN_QUEUE   -> IDLE  (plain store; owner-only)
    ///   run-loop yield (.Ready):  push only if state == IDLE
    ///   run-loop destroy (.Finished):  IDLE -> DESTROYING
    ///
    /// If the destroy CAS fails because submitResume claimed
    /// IN_QUEUE first, the task is now in some queue. The destroyer
    /// skips destroy and returns to the run loop; the next pop will
    /// observe status=.Finished with state=IDLE again and retry the
    /// destroy CAS. No leak (task is either queued or currently
    /// being destroyed) and no UAF (submitResume can never claim
    /// after IDLE -> DESTROYING).
    ///
    /// This fix closes the cross-scheduler submitResume-after-Finished
    /// race that surfaced as the SplitStream pubsub-hammer SEGV at
    /// scheduler.zig run() destroy(task.base). VOPR + Loom regression
    /// tests document the bug shape; with this state machine, both
    /// suites enumerate zero failing schedules.
    in_inbox: Atomic(u8) = Atomic(u8).init(IN_INBOX_IDLE),
    /// Tag identifying the kind of lock the task is parked on. detectCycle
    /// dispatches on this to look up the lock's CURRENT exclusive owner.
    ///   0 = not parked
    ///   1 = ParkingMutex (exclusive)
    ///   2 = ParkingRwLock (write/exclusive)
    ///   3 = ParkingRwLock (shared/read) — chain terminator
    waiting_for_lock_kind: Atomic(u8) = Atomic(u8).init(0),
    /// Set true by Scheduler.scanLockWaiters when the parked-task's
    /// deadline elapsed and we removed it from the lock's waiter list.
    /// Read by the waker-side path in lockSlow after yield() returns
    /// to decide whether to return error.LockTimeout. Atomic because
    /// the writer (scanner) and reader (waking fiber) run on
    /// different threads.
    lock_timed_out: Atomic(bool) = Atomic(bool).init(false),
    /// Owner-only flag, but kept in this group rather than group 1 so the
    /// hot owner-only line stays at exactly 64 bytes. The scheduler reads
    /// this when entering the root-stack trampoline; cost is negligible.
    is_on_root_stack: bool = false,
    /// Owner-only fairness flag. Set by Scheduler.coopYield before
    /// yielding; consumed by run()'s .Ready handler to route the task
    /// to the FIFO yield_queue (cooperative-fairness path) instead of
    /// re-pushing onto the LIFO Chase-Lev ready_queue. Cleared by the
    /// run loop after consumption. Without this flag, two co-located
    /// cooperative fibers starve the older one (proven by the VOPR
    /// "ready queue starves the older of two co-located cooperative
    /// tasks" test).
    co_yielded: bool = false,
    /// Monotonic counter of every park/wake transition affecting the
    /// (waiting_for_lock, waiting_for_lock_kind) pair. detectCycle uses
    /// this to validate per-hop snapshots across an N-hop chain walk.
    seq: Atomic(u32) = Atomic(u32).init(0),
    /// Per-slot generation counter, bumped by Scheduler.drainChannels on
    /// every Task allocation from `task_slab.create()`. Used by
    /// detectCycle (Phase 3) to validate that a captured
    /// `(*Task, generation)` pair still refers to the same logical Task —
    /// guards against use-after-free when the slot is reallocated to a
    /// different Task while a chain walker holds a stale pointer.
    ///
    /// Atomic so cross-thread reads (chain walkers in other schedulers)
    /// observe a consistent value paired with the generation-bumping
    /// store. Loom-instrumented via the comptime Atomic alias so
    /// generation transitions become yield points under simulation.
    generation: Atomic(u32) = Atomic(u32).init(0),
    /// Set by ParkingMutex/ParkingRwLock on park; read by the scheduler's
    /// timeout scanner. Always null when not parked. Loom-instrumented.
    waiting_for_lock: Atomic(?*anyopaque) = Atomic(?*anyopaque).init(null),
    /// Set to the exclusive owner of the lock this task is blocked on.
    /// Cross-thread cycle-detection reads this field while unlock() /
    /// park() write it on a different core; Atomic prevents torn reads.
    waiting_for_lock_owner: Atomic(?*Task) = Atomic(?*Task).init(null),
    /// Wall-clock millisecond timestamp captured by registerLockWaiter
    /// when the task parks. Read by Scheduler.scanLockWaiters (called
    /// from `run()` on whatever scheduler currently holds the task in
    /// its lock_waiters list) plus the idle-path deadline computation
    /// at scheduler.zig:830. Atomic to avoid torn reads on cross-
    /// scheduler timeout-scan paths (the scan thread is not
    /// necessarily the thread that registered the task — a parked
    /// task that was previously stolen ends up registered on its
    /// current scheduler, which may differ from the original).
    lock_wait_start_ms: Atomic(i64) = Atomic(i64).init(0),

    // ── Group 3: cold/rare ──────────────────────────────────────────────
    inbox_link: InboxNode = .{ .type = .Resume },
    /// Back-pointer to lock's waiter list. Set by lockSlow before
    /// yield, cleared by either the wake-side (lockSlow after yield,
    /// or notifier-side wakeNext) or the timeout scanner. Atomic so
    /// the scanner's read can't tear with concurrent wake-side
    /// clears.
    waiting_for_lock_list: Atomic(?*WaiterList) = Atomic(?*WaiterList).init(null),
    /// Back-pointer to our WaiterNode in that list. Same writers and
    /// reader as `waiting_for_lock_list` — the two move together.
    lock_waiter_node: Atomic(?*WaiterNode) = Atomic(?*WaiterNode).init(null),
    /// Set by ParkingRwLock when parking as a write-lock waiter. On
    /// timeout, the scheduler decrements this counter (writers_waiting)
    /// so future readers are not permanently blocked by a phantom writer.
    lock_counter_ptr: ?*u32 = null,

};

pub const LOCK_KIND_NONE: u8 = 0;
pub const LOCK_KIND_MUTEX: u8 = 1;
pub const LOCK_KIND_RWLOCK_WRITE: u8 = 2;
pub const LOCK_KIND_RWLOCK_SHARED: u8 = 3;

/// Task.in_inbox states (see field doc above).
pub const IN_INBOX_IDLE: u8 = 0;
pub const IN_INBOX_IN_QUEUE: u8 = 1;
pub const IN_INBOX_DESTROYING: u8 = 2;
