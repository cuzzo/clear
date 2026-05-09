// spsc.zig — Single-Producer Single-Consumer ring buffer for scheduler messages.
//
// Replaces the MPSC Treiber stack (AtomicInbox) which had use-after-free bugs
// due to linked-list node reuse across threads.
//
// SPSC guarantees:
//   - No linked list → no node.next corruption
//   - Entries are COPIED into the ring → no use-after-free
//   - Fixed-size → no allocation during operation
//   - FIFO naturally → no reverse() needed
//   - One producer, one consumer → minimal atomic overhead

const std = @import("std");

pub const MessageTag = enum(u8) {
    Spawn,
    Resume,
    RemoteCall,
    /// FSM (stackless) task spawn. Unlike `Spawn`, the target scheduler
    /// does not allocate a fiber/stack — `fsm_task` points to a
    /// caller-owned, pre-initialized FsmTask that is appended to the
    /// scheduler's fsm_ready_queue as-is. See docs/agents/finite-state-machines.md.
    FsmSpawn,
    /// FSM (stackless) task resume — wake a previously-parked FSM back
    /// into the target scheduler's fsm_ready_queue. Unlike FsmSpawn,
    /// this does NOT increment active_tasks (the task was already
    /// counted when originally enqueued). Used by ParkingMutex unlock
    /// to wake an FSM waiter on a different scheduler.
    FsmResume,
    /// Return a stackful fiber stack to the scheduler that allocated it.
    /// Stack pools are scheduler-local because their slab magazines are not
    /// safe to mutate from arbitrary scheduler threads.
    RemoteStackFree,
    /// Return a generated FSM ctx slab slot to the scheduler that allocated
    /// it. Same locality rule as RemoteStackFree.
    RemoteFsmCtxFree,
};

/// A value-type message copied into the ring buffer.
/// 48 bytes — fits in one cache line with padding.
pub const Message = struct {
    tag: MessageTag,
    // Spawn fields
    trampoline_addr: usize = 0,
    user_fn: ?*const fn (*anyopaque, ?*anyopaque) anyerror!void = null,
    args: ?*anyopaque = null,
    config_stack_size: u8 = 0, // StackSize enum as u8
    config_pinned: bool = false,
    config_timeout_ms: u64 = 0,
    config_profile_site_id: u32 = 0,
    config_profile_dispatch: u8 = 0,
    // Resume fields
    task: ?*anyopaque = null, // *Task as opaque
    // RemoteCall fields
    rc_func: ?*const fn (*anyopaque) void = null,
    rc_ctx: ?*anyopaque = null,
    rc_wg: ?*anyopaque = null, // *WaitGroup as opaque
    // FsmSpawn fields — reuses `task` would conflate with Resume, so
    // a dedicated pointer field keeps decoding branch-free.
    fsm_task: ?*anyopaque = null, // *FsmTask as opaque
    // RemoteStackFree fields
    stack_ptr: usize = 0,
    stack_len: usize = 0,
    // RemoteFsmCtxFree fields
    fsm_ctx_ptr: usize = 0,
    fsm_ctx_class: u8 = 0,
};

/// SPSC ring buffer.  Fixed capacity, power-of-two size.
/// Producer calls push(), consumer calls pop().
/// Both are wait-free.
pub fn SpscRing(comptime ring_capacity: usize) type {
    comptime {
        // Must be power of two for mask trick
        if (ring_capacity == 0 or (ring_capacity & (ring_capacity - 1)) != 0)
            @compileError("SpscRing capacity must be a power of two");
    }

    return struct {
        const Self = @This();
        const mask = ring_capacity - 1;

        /// Compile-time capacity (number of slots). Tests reference this
        /// to size fill/drain loops generically — never hardcode the
        /// numeric value, since DefaultRing's capacity is tuned for RSS
        /// and changes break any test pinned to a specific value.
        pub const capacity: usize = ring_capacity;

        buffer: [ring_capacity]Message = undefined,
        /// Written by producer, read by consumer.
        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        /// Written by consumer, read by producer.
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        /// Producer: push a message. Returns false if full.
        pub fn push(self: *Self, msg: Message) bool {
            const h = self.head.load(.monotonic);
            const t = self.tail.load(.acquire);
            if (h -% t >= capacity) return false; // full
            self.buffer[h & mask] = msg;
            self.head.store(h +% 1, .release);
            return true;
        }

        /// Consumer: pop a message. Returns null if empty.
        pub fn pop(self: *Self) ?Message {
            const t = self.tail.load(.monotonic);
            const h = self.head.load(.acquire);
            if (t == h) return null; // empty
            // Access via pointer to avoid debug-mode copy of entire buffer array.
            const msg = (&self.buffer)[t & mask];
            self.tail.store(t +% 1, .release);
            return msg;
        }

        /// Consumer: peek at the next message without consuming it.
        pub fn peek(self: *Self) ?Message {
            const t = self.tail.load(.monotonic);
            const h = self.head.load(.acquire);
            if (t == h) return null;
            return (&self.buffer)[t & mask];
        }

        /// Consumer: number of pending messages.
        pub fn len(self: *Self) usize {
            const h = self.head.load(.acquire);
            const t = self.tail.load(.monotonic);
            return h -% t;
        }

        /// Consumer: is there anything to read?
        pub fn isEmpty(self: *Self) bool {
            return self.len() == 0;
        }
    };
}

// Default ring size: 256 entries. At ~112 bytes/Message ≈ 28 KB per ring.
//
// The previous 4096 (~458 KB/ring) caused massive RSS bloat at high
// thread counts: with N schedulers each lazily allocating up to N-1
// inbound rings, worst case was ~470 MB of just-the-rings before any
// user work. At 32 threads, benchmarks/concurrent/08_pubsub showed
// 480 MB RSS — 100x what Go (1.8 MB) and Rust (2.5 MB) use for the
// same workload. Unacceptable.
//
// 256 entries is plenty for typical wake/spawn cross-thread traffic;
// when the ring is full submitResume/submitSpawn/submitFsmResume
// already wait-and-work (drainChannels + coopYield), so smaller rings
// produce more cooperative yielding under heavy traffic, not message
// loss. This costs throughput when contended (especially under TSan
// where every atomic op is instrumented and the wait-and-work loop
// runs much more slowly), but RSS bound matters more than throughput
// for benchmark fairness.
//
// FUTURE WORK: replace the spin-loop wait-and-work with a parking
// mechanism similar to Go/Rust channels (register on a wake list,
// signal on dequeue). That fixes the throughput cost at small ring
// sizes without growing the ring.
pub const DefaultRing = SpscRing(256);
