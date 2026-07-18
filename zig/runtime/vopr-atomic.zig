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
pub var sim_cmpxchg_synthetic_fault_count: usize = 0;

/// VOPR fault-injection mode for cmpxchg ops. When `inject_cas_fault`
/// is true, every cmpxchg whose value DID match is randomly converted
/// to a synthetic failure with probability `inject_cas_fault_rate`/10000,
/// driven by a SimRandom-seeded PRNG so the loss pattern is replayable
/// by VOPR seed.
///
/// Off by default (rate=0). Loom tests don't touch these knobs, so
/// their behavior is unchanged. VOPR scenarios that want to drive
/// retry-loop bodies set:
///   sim_atomic.inject_cas_fault = true;
///   sim_atomic.inject_cas_fault_rate = N;  // 0-10000
///
/// The fault state is process-global; VOPR scenarios reset it at the
/// end (or via a deferred reset helper).
pub var inject_cas_fault: bool = false;
pub var inject_cas_fault_rate: u32 = 0;
pub var inject_cas_fault_count_remaining: u32 = 0;

/// Swap fault injection. Off by default. When `inject_swap_busy_fault`
/// is true, every `swap(new_val, ...)` returns `new_val` (without
/// updating the underlying value) with probability
/// `inject_swap_busy_rate`/10000. The caller's "did I get the
/// expected old value?" check sees the fault as "lock was busy" —
/// useful for driving spin-acquire retry bodies single-threaded.
///
/// The rate MUST be strictly less than 10000 — at 100% the spinlock
/// would spin forever (no roll ever succeeds). Tests that want
/// guaranteed faulting should use rates around 5000 (50%).
pub var inject_swap_busy_fault: bool = false;
pub var inject_swap_busy_rate: u32 = 0;

pub var sim_swap_synthetic_fault_count: usize = 0;

/// Load tag injection for the MVCC tag-spin retry path. When
/// `inject_load_tagged_count_remaining > 0`, the next N integer loads
/// return `value | 1` (low-bit-tagged) before the counter decrements
/// to 0 and loads return raw. Used by VOPR scenarios that need to
/// drive Versioned.update's `while (addrIsTagged(old_addr))` body
/// single-threaded -- the cell's ptr is pre-set to a tagged value,
/// the first load returns tagged (entering the spin body), the
/// second-or-later load returns untagged (exiting the spin).
pub var inject_load_tagged_count_remaining: u32 = 0;
pub var inject_load_tagged_skip_remaining: u32 = 0;
pub var sim_load_synthetic_tag_count: usize = 0;

pub var fault_prng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0);

pub fn seedFault(seed: u64) void {
    fault_prng = std.Random.DefaultPrng.init(seed);
}

pub fn resetFault() void {
    inject_cas_fault = false;
    inject_cas_fault_rate = 0;
    inject_cas_fault_count_remaining = 0;
    sim_cmpxchg_synthetic_fault_count = 0;
    inject_swap_busy_fault = false;
    inject_swap_busy_rate = 0;
    sim_swap_synthetic_fault_count = 0;
    inject_load_tagged_count_remaining = 0;
    inject_load_tagged_skip_remaining = 0;
    sim_load_synthetic_tag_count = 0;
}

inline fn shouldInjectFault() bool {
    if (inject_cas_fault_count_remaining > 0) {
        inject_cas_fault_count_remaining -= 1;
        return true;
    }
    if (!inject_cas_fault) return false;
    if (inject_cas_fault_rate == 0) return false;
    const roll = fault_prng.random().intRangeLessThan(u32, 0, 10_000);
    return roll < inject_cas_fault_rate;
}

inline fn shouldInjectSwapBusy() bool {
    if (!inject_swap_busy_fault) return false;
    if (inject_swap_busy_rate == 0) return false;
    const roll = fault_prng.random().intRangeLessThan(u32, 0, 10_000);
    return roll < inject_swap_busy_rate;
}

/// M8 coverage tracking. Every SimAtomic method records its caller's
/// return address — one unique IP per source line that calls a SimAtomic
/// method. After the loom suite finishes, the unique-IP count is a
/// structural lower bound on how many distinct atomic-op call sites in
/// parking-lot.zig were exercised. The runner asserts this count meets
/// a threshold derived from the per-site audit in
/// docs/agents/parking-lot-loom-coverage.md, so a regression that quietly
/// drops a code path stops being silent.
const MAX_UNIQUE_SITES: usize = 512;
pub var sim_unique_sites: [MAX_UNIQUE_SITES]usize = [_]usize{0} ** MAX_UNIQUE_SITES;
pub var sim_unique_site_count: usize = 0;

inline fn recordSite(ip: usize) void {
    // Linear search; the site set is bounded (<200 in practice for the
    // parking-lot critical path) and this is cheaper than a hashmap.
    var i: usize = 0;
    while (i < sim_unique_site_count) : (i += 1) {
        if (sim_unique_sites[i] == ip) return;
    }
    if (sim_unique_site_count < MAX_UNIQUE_SITES) {
        sim_unique_sites[sim_unique_site_count] = ip;
        sim_unique_site_count += 1;
    }
}

/// Set by VOPR fiber-harness scenarios that drive REAL production code
/// inside a fiber. The Loom-style "yield on every atomic op" behavior
/// is a Loom-coordinator contract, not a production-fiber contract --
/// inside a production fiber's call into e.g. `sched.sleepTask`, the
/// atomic ops on `task.status` / `sleeping_queue` are part of the
/// production transition, NOT yield points the harness wants to walk
/// through. Setting this disables the yield while still recording the
/// op (so M8 coverage / fault injection still work).
pub var disable_fiber_yield_point: bool = false;

/// Yield to the Loom coordinator.  Called at every atomic operation.
/// If not running on a fiber (e.g., during queue setup), this is a no-op.
/// We check __fiber_parent_ctx because __fiber can be stale after a fiber
/// completes -- only switchTo() sets parent_ctx, and yield() clears it.
fn yieldPoint() void {
    sim_atomic_op_count += 1;
    if (disable_fiber_yield_point) return;
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
            recordSite(@returnAddress());
            yieldPoint();
            // Tagged-load fault: first N integer loads return value|1
            // so MVCC's addrIsTagged spin body executes.
            if (comptime @typeInfo(T) == .int) {
                if (inject_load_tagged_skip_remaining > 0) {
                    inject_load_tagged_skip_remaining -= 1;
                    return self.raw;
                }
                if (inject_load_tagged_count_remaining > 0) {
                    inject_load_tagged_count_remaining -= 1;
                    sim_load_synthetic_tag_count += 1;
                    return self.raw | 1;
                }
            }
            return self.raw;
        }

        pub fn store(self: *@This(), v: T, _: std.builtin.AtomicOrder) void {
            recordSite(@returnAddress());
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
            recordSite(@returnAddress());
            yieldPoint();
            if (self.raw == expected) {
                if (shouldInjectFault()) {
                    // Synthetic CAS-loser: pretend we lost the race.
                    // Caller observes the current (matching) value as
                    // the "new winner" and is forced into its retry
                    // path. Used by VOPR to drive retry-loop bodies
                    // single-threaded.
                    sim_cmpxchg_synthetic_fault_count += 1;
                    sim_cmpxchg_fail_count += 1;
                    return self.raw;
                }
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
            recordSite(@returnAddress());
            yieldPoint();
            if (shouldInjectSwapBusy()) {
                // Synthetic "lock is busy". Return new_val without
                // writing -- caller's `swap == new_val` busy check sees
                // the fault and enters its retry body. The underlying
                // value stays unchanged so subsequent rolls can succeed.
                sim_swap_synthetic_fault_count += 1;
                return new_val;
            }
            const old = self.raw;
            self.raw = new_val;
            return old;
        }

        pub fn fetchAdd(self: *@This(), val: T, _: std.builtin.AtomicOrder) T {
            recordSite(@returnAddress());
            yieldPoint();
            const old = self.raw;
            self.raw = old +% val;
            return old;
        }

        pub fn fetchSub(self: *@This(), val: T, _: std.builtin.AtomicOrder) T {
            recordSite(@returnAddress());
            yieldPoint();
            const old = self.raw;
            self.raw = old -% val;
            return old;
        }

        pub fn fetchOr(self: *@This(), val: T, _: std.builtin.AtomicOrder) T {
            recordSite(@returnAddress());
            yieldPoint();
            const old = self.raw;
            self.raw = old | val;
            return old;
        }

        pub fn fetchAnd(self: *@This(), val: T, _: std.builtin.AtomicOrder) T {
            recordSite(@returnAddress());
            yieldPoint();
            const old = self.raw;
            self.raw = old & val;
            return old;
        }
    };
}
