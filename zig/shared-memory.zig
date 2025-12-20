const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;

// -------------------------------------------------------------------------
// Concurrency Primitives (Locked<T>)
// -------------------------------------------------------------------------

pub fn Locked(comptime T: type) type {
    return struct {
        // The mutex protects the data below
        mutex: std.Thread.Mutex = .{},
        data: T,

        const Self = @This();

        // 1. Init: Create the object (unlocked)
        pub fn init(val: T) Self {
            return .{ .data = val };
        }

        // 2. Acquire: Blocks until lock is obtained.
        // Returns a "Guard" that gives access to data.
        pub fn acquire(self: *Self) Guard {
            self.mutex.lock();
            return Guard{ .parent = self };
        }

        // The Guard Pattern:
        // Holds the pointer to the parent.
        // Releases the lock automatically when usage is done (if you defer release).
        pub const Guard = struct {
            parent: *Self,

            // Get mutable pointer to the inner data
            pub fn get(self: *Guard) *T {
                return &self.parent.data;
            }

            // Get const pointer (read-only)
            pub fn getConst(self: *Guard) *const T {
                return &self.parent.data;
            }

            // Release the lock
            pub fn release(self: *Guard) void {
                self.parent.mutex.unlock();
            }
        };
    };
}

// -------------------------------------------------------------------------
// Concurrency Primitives (Shared<T>)
// -------------------------------------------------------------------------

pub fn Shared(comptime T: type) type {
    return struct {
        // The Atomic Pointer to the current version.
        // We use *T because we are swapping the entire object.
        ptr: std.atomic.Value(*T),

        const Self = @This();

        // 1. Init: Allocate the first version on the heap
        pub fn init(allocator: std.mem.Allocator, val: T) !Self {
            const node = try allocator.create(T);
            node.* = val;
            return Self{ .ptr = std.atomic.Value(*T).init(node) };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            // Load the current pointer and destroy it
            const current_ptr = self.ptr.load(.seq_cst);
            allocator.destroy(current_ptr);
        }

        // 2. Read: Just load the pointer.
        // This is Wait-Free, Lock-Free, and insanely fast.
        pub fn read(self: *Self, trt: *Runtime) Guard {
            // A. Signal start
            trt.ebr.enter();

            // B. Load pointer (Safe because we are in the epoch)
            const val = self.ptr.load(.monotonic);

            return Guard{ .ptr = val, .rt = trt };
        }

        // The Read Guard
        pub const Guard = struct {
            ptr: *T,
            rt: *Runtime,

            pub fn get(self: *Guard) *T {
                return self.ptr;
            }

            pub fn release(self: *Guard) void {
                // C. Signal done
                self.rt.ebr.exit();
            }
        };

        // 3. Write: Copy-On-Write with CAS (Compare And Swap)
        // This is the "Transaction" logic.
        // func: A lambda/function that takes (*NewData) and modifies it.
        pub fn update(self: *Self, trt: *Runtime, allocator: std.mem.Allocator, comptime func: anytype, args: anytype) !void {

            // OPTIMISTIC LOOP
            while (true) {
                // A. Snapshot the world
                const old_ptr = self.ptr.load(.monotonic);

                // B. Create the Future (Allocation)
                const new_ptr = try allocator.create(T);

                // C. Copy History (Clone old data to new)
                new_ptr.* = old_ptr.*;

                // D. Apply Changes (Run the user's logic on the PRIVATE new copy)
                //    We use @call to pass arguments to the update function
                @call(.auto, func, .{new_ptr} ++ args);

                // E. The Commit (Compare and Swap)
                // "If ptr is still old_ptr, replace it with new_ptr."
                // ordering: .release to ensure writes to new_ptr are visible before the swap
                const result = self.ptr.cmpxchgWeak(old_ptr, new_ptr, .release, .monotonic);

                if (result == null) {
                    // Schedule this ptr for deletion
                    try trt.ebr.retire(allocator, old_ptr);
                    return;
                } else {
                    allocator.destroy(new_ptr);
                }
            }
        }
    };
}

// -------------------------------------------------------------------------
// Concurrency Primitives (RwLocked<T>)
// -------------------------------------------------------------------------

pub fn RwLocked(comptime T: type) type {
    return struct {
        lock: std.Thread.RwLock = .{},
        data: T,

        const Self = @This();

        pub fn init(val: T) Self {
            return .{ .data = val };
        }

        // 1. Read Access
        // Allows multiple concurrent readers. Blocks if a Writer is active.
        pub fn read(self: *Self) ReadGuard {
            self.lock.lockShared();
            return ReadGuard{ .parent = self };
        }

        // 2. Write Access
        // Exclusive access. Blocks until all Readers AND Writers are gone.
        pub fn write(self: *Self) WriteGuard {
            self.lock.lock();
            return WriteGuard{ .parent = self };
        }

        pub const ReadGuard = struct {
            parent: *Self,

            // CRITICAL: We only return a CONST pointer here.
            // This prevents the user from accidentally modifying data inside a read lock.
            pub fn get(self: *ReadGuard) *const T {
                return &self.parent.data;
            }

            pub fn release(self: *ReadGuard) void {
                self.parent.lock.unlockShared();
            }
        };

        pub const WriteGuard = struct {
            parent: *Self,

            // Mutable pointer allowed here.
            pub fn get(self: *WriteGuard) *T {
                return &self.parent.data;
            }

            // You can also get const if you want
            pub fn getConst(self: *WriteGuard) *const T {
                return &self.parent.data;
            }

            pub fn release(self: *WriteGuard) void {
                self.parent.lock.unlock();
            }
        };
    };
}

