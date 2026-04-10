// vopr-atomic.zig -- SimAtomic: drop-in replacement for std.atomic.Value.
//
// Every load/store/CAS yields to the Loom coordinator via fiber.yield().
// This creates a yield point at each atomic operation, allowing the
// coordinator to interleave operations from different virtual threads.
//
// No real atomics -- everything is plain value storage.  The interleaving
// is what creates race conditions, not memory ordering.

const std = @import("std");
const fc = @import("fiber-core.zig");

/// Yield to the Loom coordinator.  Called at every atomic operation.
/// If not running on a fiber (e.g., during queue setup), this is a no-op.
/// We check __fiber_parent_ctx because __fiber can be stale after a fiber
/// completes -- only switchTo() sets parent_ctx, and yield() clears it.
fn yieldPoint() void {
    if (fc.__fiber_parent_ctx != null) {
        if (fc.__fiber) |fiber| {
            fiber.yield();
        }
    }
}

/// Drop-in replacement for std.atomic.Value(T).
/// Same API, plain value storage, yields at every operation.
pub fn SimAtomic(comptime T: type) type {
    return struct {
        value: T,

        const Self = @This();

        pub fn init(v: T) Self {
            return .{ .value = v };
        }

        pub fn load(self: *const Self, _: std.builtin.AtomicOrder) T {
            yieldPoint();
            return self.value;
        }

        pub fn store(self: *@This(), v: T, _: std.builtin.AtomicOrder) void {
            yieldPoint();
            self.value = v;
        }

        pub fn cmpxchgStrong(
            self: *@This(),
            expected: T,
            desired: T,
            _: std.builtin.AtomicOrder,
            _: std.builtin.AtomicOrder,
        ) ?T {
            yieldPoint();
            if (self.value == expected) {
                self.value = desired;
                return null; // success
            }
            return self.value; // failure: return current value
        }

        pub fn cmpxchgWeak(
            self: *@This(),
            expected: T,
            desired: T,
            success: std.builtin.AtomicOrder,
            failure: std.builtin.AtomicOrder,
        ) ?T {
            return self.cmpxchgStrong(expected, desired, success, failure);
        }

        pub fn swap(self: *@This(), new_val: T, _: std.builtin.AtomicOrder) T {
            yieldPoint();
            const old = self.value;
            self.value = new_val;
            return old;
        }

        pub fn fetchAdd(self: *@This(), val: T, _: std.builtin.AtomicOrder) T {
            yieldPoint();
            const old = self.value;
            self.value = old +% val;
            return old;
        }

        pub fn fetchSub(self: *@This(), val: T, _: std.builtin.AtomicOrder) T {
            yieldPoint();
            const old = self.value;
            self.value = old -% val;
            return old;
        }

        pub fn fetchOr(self: *@This(), val: T, _: std.builtin.AtomicOrder) T {
            yieldPoint();
            const old = self.value;
            self.value = old | val;
            return old;
        }
    };
}
