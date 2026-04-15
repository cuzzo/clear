const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const compat = @import("../lib/compat.zig");

// -------------------------------------------------------------------------
// Concurrency Primitives (Locked<T>)
// -------------------------------------------------------------------------

pub fn Locked(comptime T: type) type {
    return struct {
        // The mutex protects the data below
        mutex: compat.Mutex = .{},
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
            // We loop until we successfully swap the pointer
            while (true) {
                // 1. Load the current state (Snapshot)
                const old_ptr = self.ptr.load(.monotonic);

                // 2. Allocation: Create a copy of the state
                //    This is easy to leak, beware.
                const new_ptr = try allocator.create(T);
                new_ptr.* = old_ptr.*;

                // 3. Modification: Apply the user function to the copy
                // We use @call to unpack the args tuple
                @call(.auto, func, .{new_ptr} ++ args);

                // 4. CAS: Attempt to swap the old pointer with the new one
                // .release ensures our writes to new_ptr are visible if we succeed
                // .monotonic is sufficient for the failure load
                const attempts = self.ptr.cmpxchgWeak(old_ptr, new_ptr, .release, .monotonic);

                if (attempts) |actual_old| {
                    // === FAILURE PATH ===
                    // Someone else updated the pointer before us.
                    // Our 'new_ptr' is now invalid/stale.

                    // We MUST destroy the allocation we just made.
                    allocator.destroy(new_ptr);

                    // Optional: update your local view of old_ptr here to retry faster,
                    // though loading it at the top of the loop is also fine.
                    _ = actual_old;
                    continue;
                }

                // === SUCCESS PATH ===
                // We successfully swapped the pointer. 'new_ptr' is now live.
                // 'old_ptr' is now effectively garbage.
                try trt.ebr.retire(allocator, old_ptr);
                return;
            }
        }
    };
}

// -------------------------------------------------------------------------
// Interior Mutability (RefCell<T>)
// -------------------------------------------------------------------------
// Allows mutation through a const binding. No mutex — single-thread only.
// In debug mode, tracks borrows and panics on overlapping mutable borrows.

pub fn RefCell(comptime T: type) type {
    return struct {
        data: T,
        borrow_state: i32 = 0, // 0=idle, >0=shared borrows, -1=mutable borrow

        const Self = @This();

        pub fn init(val: T) Self {
            return .{ .data = val };
        }

        pub fn get(self: *Self) *T {
            if (self.borrow_state < 0) @panic("RefCell: mutable borrow already active");
            return &self.data;
        }

        pub fn getMut(self: *Self) *T {
            if (self.borrow_state != 0) @panic("RefCell: borrow already active");
            self.borrow_state = -1;
            return &self.data;
        }

        pub fn releaseMut(self: *Self) void {
            self.borrow_state = 0;
        }

        pub fn getConst(self: *const Self) *const T {
            return &self.data;
        }
    };
}

// -------------------------------------------------------------------------
// Concurrency Primitives (RwLocked<T>)
// -------------------------------------------------------------------------

pub fn RwLocked(comptime T: type) type {
    return compat.RwLocked(T);
}
