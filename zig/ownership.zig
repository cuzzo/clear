const std = @import("std");

// -------------------------------------------------------------------------
// Reference Counted Pointer (Rc<T>) - Single-Threaded
// -------------------------------------------------------------------------
// A non-atomic reference counted smart pointer. Use when:
// - All access is from a single thread
// - You need shared ownership without the overhead of atomics
// - Performance is critical and thread-safety is not required

pub fn Rc(comptime T: type) type {
    return struct {
        /// Internal control block stored alongside the data
        const Inner = struct {
            data: T,
            ref_count: usize,
        };

        inner: *Inner,
        allocator: std.mem.Allocator,

        const Self = @This();

        /// Create a new Rc with the given value
        pub fn init(allocator: std.mem.Allocator, val: T) !Self {
            const inner = try allocator.create(Inner);
            inner.* = .{
                .data = val,
                .ref_count = 1,
            };
            return Self{
                .inner = inner,
                .allocator = allocator,
            };
        }

        /// Clone the Rc, incrementing the reference count
        /// Returns a new handle to the same underlying data
        pub fn clone(self: Self) Self {
            self.inner.ref_count += 1;
            return Self{
                .inner = self.inner,
                .allocator = self.allocator,
            };
        }

        /// Get a pointer to the inner data (mutable)
        pub fn get(self: Self) *T {
            return &self.inner.data;
        }

        /// Get a const pointer to the inner data
        pub fn getConst(self: Self) *const T {
            return &self.inner.data;
        }

        /// Get the current reference count (for debugging)
        pub fn refCount(self: Self) usize {
            return self.inner.ref_count;
        }

        /// Release this handle. If this was the last reference,
        /// the underlying data is freed.
        /// If T has a deinit method, it will be called before freeing.
        pub fn deinit(self: *Self) void {
            self.inner.ref_count -= 1;
            if (self.inner.ref_count == 0) {
                // Only deinit when necessary
                switch (@typeInfo(T)) {
                    .@"struct", .@"union", .@"enum" => {
                        // Call T.deinit if it exists (handles types like ArrayList that manage their own memory)
                        if (comptime @hasDecl(T, "deinit")) {
                            const deinit_fn = @typeInfo(@TypeOf(T.deinit)).@"fn";
                            if (deinit_fn.params.len == 2) {
                                // deinit(self, allocator) pattern (e.g., ArrayListUnmanaged)
                                self.inner.data.deinit(self.allocator);
                            } else {
                                // deinit(self) pattern (e.g., ArrayList)
                                self.inner.data.deinit();
                            }
                        }
                    },
                    else => {},
                }
                self.allocator.destroy(self.inner);
            }
            // Invalidate to catch use-after-deinit
            self.inner = undefined;
        }
    };
}

// -------------------------------------------------------------------------
// Atomic Reference Counted Pointer (Arc<T>) - Thread-Safe
// -------------------------------------------------------------------------
// An atomic reference counted smart pointer. Use when:
// - Data needs to be shared across multiple threads
// - You need shared ownership with thread-safety
// - The overhead of atomic operations is acceptable
//
// The control block uses a split reference count design:
// - strong_count: Number of Arc handles (controls data lifetime)
// - weak_count: Number of Weak handles + 1 (if strong_count > 0)
//
// This ensures Weak pointers can safely check if the data is still alive
// even after all strong references are dropped.

pub fn Arc(comptime T: type) type {
    return struct {
        /// Internal control block stored alongside the data.
        /// The control block outlives the data when weak references exist.
        pub const Inner = struct {
            data: T,
            strong_count: std.atomic.Value(usize),
            /// Weak count starts at 1 representing the "implicit" weak reference
            /// held collectively by all strong references. When strong_count drops
            /// to 0, this implicit weak reference is released.
            weak_count: std.atomic.Value(usize),
        };

        inner: *Inner,
        allocator: std.mem.Allocator,

        const Self = @This();

        /// Create a new Arc with the given value
        pub fn init(allocator: std.mem.Allocator, val: T) !Self {
            const inner = try allocator.create(Inner);
            inner.* = .{
                .data = val,
                .strong_count = std.atomic.Value(usize).init(1),
                .weak_count = std.atomic.Value(usize).init(1), // Implicit weak from strong refs
            };
            return Self{
                .inner = inner,
                .allocator = allocator,
            };
        }

        /// Clone the Arc, atomically incrementing the strong reference count
        /// Returns a new handle to the same underlying data
        /// Safe to call from any thread
        pub fn clone(self: Self) Self {
            // Use .monotonic for the increment since we don't need
            // to synchronize with any other memory operations here.
            // The acquire/release happens at clone/drop boundaries.
            _ = self.inner.strong_count.fetchAdd(1, .monotonic);
            return Self{
                .inner = self.inner,
                .allocator = self.allocator,
            };
        }

        /// Create a weak reference from this Arc
        /// The weak reference does not prevent deallocation
        pub fn downgrade(self: Self) Weak(T) {
            // Increment weak count for the new Weak reference
            _ = self.inner.weak_count.fetchAdd(1, .monotonic);
            return Weak(T){
                .inner = self.inner,
                .allocator = self.allocator,
            };
        }

        /// Get a pointer to the inner data (mutable)
        /// WARNING: Caller must ensure proper synchronization when mutating
        /// shared data. Consider using Arc(Locked(T)) or Arc(RwLocked(T))
        /// for safe mutable access.
        pub fn get(self: Self) *T {
            return &self.inner.data;
        }

        /// Get a const pointer to the inner data
        pub fn getConst(self: Self) *const T {
            return &self.inner.data;
        }

        /// Get the current strong reference count (for debugging)
        /// Note: This value may be stale immediately after reading
        pub fn refCount(self: Self) usize {
            return self.inner.strong_count.load(.monotonic);
        }

        /// Get the current weak reference count (for debugging)
        /// Note: This value may be stale immediately after reading
        pub fn weakCount(self: Self) usize {
            return self.inner.weak_count.load(.monotonic);
        }

        /// Release this handle. If this was the last strong reference,
        /// the data becomes inaccessible (but control block may persist
        /// if weak references exist).
        /// If T has a deinit method, it will be called when the last strong
        /// reference is dropped.
        /// Safe to call from any thread.
        pub fn deinit(self: *Self) void {
            // Use .acq_rel to ensure all writes to the data happen-before
            // the potential deallocation, and we synchronize with previous releases.
            const prev_strong = self.inner.strong_count.fetchSub(1, .acq_rel);

            if (prev_strong == 1) {
                // We were the last strong reference.
                // The data is now considered "dead" - Weak.upgrade() will fail.

                // Call T.deinit if it exists (handles types like ArrayList that manage their own memory)
                switch (@typeInfo(T)) {
                    .@"struct", .@"union", .@"enum" => {
                        if (comptime @hasDecl(T, "deinit")) {
                            const deinit_fn = @typeInfo(@TypeOf(T.deinit)).@"fn";
                            if (deinit_fn.params.len == 2) {
                                // deinit(self, allocator) pattern (e.g., ArrayListUnmanaged)
                                self.inner.data.deinit(self.allocator);
                            } else {
                                // deinit(self) pattern (e.g., ArrayList)
                                self.inner.data.deinit();
                            }
                        }
                    },
                    else => {},
                }

                // Now release the implicit weak reference held by strong refs
                const prev_weak = self.inner.weak_count.fetchSub(1, .acq_rel);

                if (prev_weak == 1) {
                    // No weak references exist either - free the control block
                    self.allocator.destroy(self.inner);
                }
                // else: Weak references still exist, control block stays alive
            }

            // Invalidate to catch use-after-deinit
            self.inner = undefined;
        }
    };
}

// -------------------------------------------------------------------------
// Weak Reference (Weak<T>) - For Arc Only
// -------------------------------------------------------------------------
// A weak reference that doesn't prevent deallocation of the data,
// but does keep the control block alive so it can safely check
// whether the data is still accessible.
//
// Create weak references using Arc.downgrade() or Weak.fromArc().

pub fn Weak(comptime T: type) type {
    return struct {
        const ArcType = Arc(T);
        const Inner = ArcType.Inner;

        inner: *Inner,
        allocator: std.mem.Allocator,

        const Self = @This();

        /// Create a weak reference from an Arc.
        /// This increments the weak count.
        pub fn fromArc(arc: ArcType) Self {
            _ = arc.inner.weak_count.fetchAdd(1, .monotonic);
            return Self{
                .inner = arc.inner,
                .allocator = arc.allocator,
            };
        }

        /// Clone this weak reference, incrementing the weak count
        pub fn clone(self: Self) Self {
            _ = self.inner.weak_count.fetchAdd(1, .monotonic);
            return Self{
                .inner = self.inner,
                .allocator = self.allocator,
            };
        }

        /// Attempt to upgrade to a strong reference (Arc).
        /// Returns null if all strong references have been dropped.
        /// Safe to call even after the data has been deallocated.
        pub fn upgrade(self: Self) ?ArcType {
            // Try to increment the strong count, but only if it's > 0
            while (true) {
                const current = self.inner.strong_count.load(.monotonic);
                if (current == 0) {
                    return null; // All strong refs dropped, data is dead
                }

                // Try to atomically increment the strong count
                if (self.inner.strong_count.cmpxchgWeak(
                    current,
                    current + 1,
                    .acquire,
                    .monotonic,
                )) |_| {
                    // CAS failed, retry
                    continue;
                } else {
                    // Success - we now have a strong reference
                    return ArcType{
                        .inner = self.inner,
                        .allocator = self.allocator,
                    };
                }
            }
        }

        /// Check if the referenced data is still alive (has strong references).
        /// Note: The result may be stale immediately after reading in a
        /// concurrent context.
        pub fn isAlive(self: Self) bool {
            return self.inner.strong_count.load(.monotonic) > 0;
        }

        /// Get the current strong reference count (for debugging)
        pub fn strongCount(self: Self) usize {
            return self.inner.strong_count.load(.monotonic);
        }

        /// Get the current weak reference count (for debugging)
        pub fn weakCount(self: Self) usize {
            return self.inner.weak_count.load(.monotonic);
        }

        /// Release this weak reference.
        /// If this was the last reference (weak or strong), the control
        /// block is freed.
        pub fn deinit(self: *Self) void {
            const prev_weak = self.inner.weak_count.fetchSub(1, .acq_rel);

            if (prev_weak == 1) {
                // We were the last weak reference.
                // Since weak_count was 1 and we're decrementing it to 0,
                // and strong refs hold an implicit weak ref, strong_count
                // must already be 0. Safe to free the control block.
                self.allocator.destroy(self.inner);
            }

            // Invalidate to catch use-after-deinit
            self.inner = undefined;
        }
    };
}
