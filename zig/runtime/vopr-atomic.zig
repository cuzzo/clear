// vopr-atomic.zig -- SimAtomic: drop-in replacement for std.atomic.Value.
//
// Every load/store/CAS yields to the Loom coordinator via fiber.yield().
// This creates a yield point at each atomic operation, allowing the
// coordinator to interleave operations from different virtual threads.
//
// No real atomics -- everything is plain value storage.  The interleaving
// is what creates race conditions, not memory ordering.
//
// API surface mirrors std.atomic.Value(T):
//   - field `raw: T`   (matches std.atomic.Value's `raw`)
//   - init/load/store/cmpxchg{Strong,Weak}/swap/fetchAdd/fetchSub/fetchOr/fetchAnd
// This means production code using `*Atomic(T)` (the comptime alias) and
// helpers like `&ptr.raw` work in both modes — no `if (loom_active)`
// branches in production source.

const std = @import("std");
const fc = @import("fiber-core.zig");

/// Diagnostic counter (M2 GAP-B probe). Incremented every time any
/// SimAtomic method body executes — proves at runtime that SimAtomic is
/// the active substitution for `Atomic` in parking-lot.zig (vs the
/// comptime alias silently resolving to `std.atomic.Value`, which would
/// reduce the entire loom suite to a single-threaded run with real
/// atomics). Read by tests after a run; > 0 means loom is actually
/// firing; 0 means GAP-B (b) — nothing has been loom-tested.
pub var sim_atomic_op_count: usize = 0;
pub var sim_cmpxchg_fail_count: usize = 0;
pub var sim_cmpxchg_succeed_count: usize = 0;

/// Yield to the Loom coordinator.  Called at every atomic operation.
/// If not running on a fiber (e.g., during queue setup), this is a no-op.
/// We check __fiber_parent_ctx because __fiber can be stale after a fiber
/// completes -- only switchTo() sets parent_ctx, and yield() clears it.
fn yieldPoint() void {
    sim_atomic_op_count += 1;
    if (fc.__fiber_parent_ctx != null) {
        if (fc.__fiber) |fiber| {
            fiber.yield();
        }
    }
}

/// Drop-in replacement for std.atomic.Value(T).
/// Same API including the `raw: T` field, plain value storage, yields at
/// every operation. The `raw` field name (rather than `value`) matches
/// std.atomic.Value so callers like Futex helpers that take `*ptr.raw`
/// type-check identically against either type.
pub fn SimAtomic(comptime T: type) type {
    return struct {
        raw: T,

        const Self = @This();

        pub fn init(v: T) Self {
            return .{ .raw = v };
        }

        pub fn load(self: *const Self, _: std.builtin.AtomicOrder) T {
            yieldPoint();
            return self.raw;
        }

        pub fn store(self: *@This(), v: T, _: std.builtin.AtomicOrder) void {
            yieldPoint();
            self.raw = v;
        }

        pub fn cmpxchgStrong(
            self: *@This(),
            expected: T,
            desired: T,
            _: std.builtin.AtomicOrder,
            _: std.builtin.AtomicOrder,
        ) ?T {
            yieldPoint();
            if (self.raw == expected) {
                self.raw = desired;
                sim_cmpxchg_succeed_count += 1;
                return null; // success
            }
            sim_cmpxchg_fail_count += 1;
            return self.raw; // failure: return current value
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
            const old = self.raw;
            self.raw = new_val;
            return old;
        }

        pub fn fetchAdd(self: *@This(), val: T, _: std.builtin.AtomicOrder) T {
            yieldPoint();
            const old = self.raw;
            self.raw = old +% val;
            return old;
        }

        pub fn fetchSub(self: *@This(), val: T, _: std.builtin.AtomicOrder) T {
            yieldPoint();
            const old = self.raw;
            self.raw = old -% val;
            return old;
        }

        pub fn fetchOr(self: *@This(), val: T, _: std.builtin.AtomicOrder) T {
            yieldPoint();
            const old = self.raw;
            self.raw = old | val;
            return old;
        }

        pub fn fetchAnd(self: *@This(), val: T, _: std.builtin.AtomicOrder) T {
            yieldPoint();
            const old = self.raw;
            self.raw = old & val;
            return old;
        }
    };
}
