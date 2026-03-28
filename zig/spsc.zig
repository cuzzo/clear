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
    // Resume fields
    task: ?*anyopaque = null, // *Task as opaque
    // RemoteCall fields
    rc_func: ?*const fn (*anyopaque) void = null,
    rc_ctx: ?*anyopaque = null,
    rc_wg: ?*anyopaque = null, // *WaitGroup as opaque
};

/// SPSC ring buffer.  Fixed capacity, power-of-two size.
/// Producer calls push(), consumer calls pop().
/// Both are wait-free.
pub fn SpscRing(comptime capacity: usize) type {
    comptime {
        // Must be power of two for mask trick
        if (capacity == 0 or (capacity & (capacity - 1)) != 0)
            @compileError("SpscRing capacity must be a power of two");
    }

    return struct {
        const Self = @This();
        const mask = capacity - 1;

        buffer: [capacity]Message = undefined,
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
            const msg = self.buffer[t & mask];
            self.tail.store(t +% 1, .release);
            return msg;
        }

        /// Consumer: peek at the next message without consuming it.
        pub fn peek(self: *Self) ?Message {
            const t = self.tail.load(.monotonic);
            const h = self.head.load(.acquire);
            if (t == h) return null;
            return self.buffer[t & mask];
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

// Default ring size: 4096 entries.  At ~72 bytes each = ~288KB per ring.
// With 64 schedulers, each has 63 incoming rings = ~18MB total.
// Oversized to minimize backpressure events in normal workloads.
pub const DefaultRing = SpscRing(4096);
