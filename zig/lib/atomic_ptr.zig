//! AtomicPtr(T) — lock-free atomic-pointer cell for the M3 `@indirect:atomic`
//! capability. Publishes whole-T snapshots via atomic pointer swap; readers
//! get an EBR-pinned snapshot for the duration of a `WITH SNAPSHOT` block.
//!
//! Mental model: this is the runtime side of CLEAR's `@indirect:atomic`.
//! Roughly Rust `arc-swap::ArcSwap<T>` semantics with EBR (instead of
//! arc-swap's hazard-pointer-style fast path) for snapshot reclamation.
//!
//! Reader: pin EBR epoch, atomic-load the pointer, hand a `Guard` to the
//! caller. The Guard's `.get()` is valid until `.release()` drops the pin.
//! Concurrent producers cannot free the snapshot while any reader holds an
//! epoch ≤ the retire epoch.
//!
//! Writer (rcu-style): `update()` runs the user-supplied closure against a
//! freshly-allocated copy of the current snapshot, then CAS-publishes the
//! new pointer. On CAS failure (concurrent winner), retries the whole
//! load/copy/run/CAS — UNBOUNDED retry, matching Rust
//! `arc-swap::ArcSwap::rcu` (the design contract in
//! docs/agents/atomicptr.md §4.2). User body MUST be pure: no IO, no
//! yield, no heap effects beyond the clone, since it can be called
//! multiple times.
//!
//! `compareAndPublish` is the lower-level CAS primitive used by `update`'s
//! retry loop AND directly testable in unit tests; it does not retry,
//! just CAS-and-retire-on-success.
//!
//! Design contract — see docs/agents/atomicptr.md §4 / §5:
//!   - Single-cell only. Multi-pointer atomicity is not supported (M3.9
//!     rejects multi-cell `WITH SNAPSHOT MUTABLE` at parse/annotate);
//!     this primitive doesn't even expose a multi-CAS API.
//!   - No conflict-handler today: rcu retries until success. Once
//!     #330 bounds the loop at 256 attempts, the right handler at the
//!     CLEAR level will be `ON AtomicConflict`, defaulted by the
//!     baked-in SYNC POLICY.
//!   - Memory ordering: seq_cst surfaces (acq_rel / acquire on CAS,
//!     acquire on read load). v0.3 inherits seq_cst-only from M1
//!     atomics; relaxation surfaces are deferred.
//!
//! See `zig/runtime/atomic-ptr-loom-test.zig` for the pin-survives-retire
//! EBR-contract test (single-thread, deterministic) and
//! `zig/runtime/atomic-ptr-stress-test.zig` for the multi-thread
//! reader+writer hammer.

const std = @import("std");
const ebr_mod = @import("ebr.zig");

const ThreadLocalEbr = ebr_mod.ThreadLocalEbr;

// Comptime atomic type selection: SimAtomic in Loom mode, real
// std.atomic.Value otherwise. Mirrors versioned.zig's pattern.
pub const Atomic = blk: {
    const root = @import("root");
    break :blk if (@hasDecl(root, "SimAtomic")) root.SimAtomic else std.atomic.Value;
};

// True-Sync-Polymorphism (#330): hard cap on AtomicPtr.update CAS
// retries before surfacing `error.AtomicConflict` (bridges to CLEAR
// `AtomicConflict`). 256 is generous because atomic-pointer retry is
// cheap (one acquire-load + one closure call + one CAS); past 256
// fresh attempts all losing the publish race signals real contention
// the caller (or CLEAR's `ON AtomicConflict RETRY(N)` / SYNC POLICY)
// should handle.
//
// Test seam: a test wrapper at zig/ root may declare
// `pub const CLEAR_ATOMIC_PTR_MAX_UPDATE_RETRIES: usize = N;` to lower
// the cap so exhaustion fires deterministically under modest concurrency.
// Production code never declares this, so the default (256) folds to a
// constant. Mirrors the Versioned pattern.
pub const MAX_UPDATE_RETRIES: usize = if (@hasDecl(@import("root"), "CLEAR_ATOMIC_PTR_MAX_UPDATE_RETRIES"))
    @import("root").CLEAR_ATOMIC_PTR_MAX_UPDATE_RETRIES
else
    256;

// Comptime helper: accept either `*ThreadLocalEbr` (used directly by
// unit tests) OR `*Runtime` (the WITH SNAPSHOT lowering passes the
// CLEAR-side `rt` variable, which has an `.ebr` field). Both forms
// resolve to a `*ThreadLocalEbr` for the .enter() / .exit() / .retire()
// calls inside this file. Same idea Versioned.read uses (it takes
// `*Runtime` directly), but AtomicPtr lives in lib/ and can't import
// Runtime, so we duck-type with @hasField.
inline fn extractEbr(arg: anytype) *ThreadLocalEbr {
    const T = @TypeOf(arg);
    return if (comptime @hasField(@typeInfo(T).pointer.child, "ebr"))
        arg.ebr
    else
        arg;
}

pub fn AtomicPtr(comptime T: type) type {
    return struct {
        // The atomic word holds the published `*T`. `?*T` so cleanup
        // can null the cell on teardown without a sentinel value.
        ptr: Atomic(?*T),

        // Re-export of T so generic code can recover the inner type
        // from a `*AtomicPtr(T)` value via `@TypeOf(cell.*).Inner`.
        pub const Inner = T;

        const Self = @This();

        /// Allocate a heap-pinned cell with an initial published value.
        /// The cell owns the published `*T`; `deinit` / `deinitSync`
        /// frees the current published `T`.
        pub fn init(allocator: std.mem.Allocator, val: T) !Self {
            const node = try allocator.create(T);
            node.* = val;
            return Self{ .ptr = Atomic(?*T).init(node) };
        }

        /// Retire-via-EBR teardown. The currently-published `*T` is
        /// retired so any in-flight reader epoch can drain before the
        /// pointer's actual `destroy`. Mirrors `Versioned.deinit`.
        ///
        /// `ebr_or_rt` accepts either `*ThreadLocalEbr` directly (unit
        /// tests) or `*Runtime` (CLEAR-side WITH SNAPSHOT lowering
        /// passes `rt`, which has an `.ebr` field).
        pub fn deinit(self: *Self, ebr_or_rt: anytype, allocator: std.mem.Allocator) !void {
            const ebr = extractEbr(ebr_or_rt);
            const current = self.ptr.swap(null, .acq_rel) orelse return;
            try ebr.retire(allocator, current);
        }

        /// Synchronous teardown — direct `destroy` of the published
        /// `*T`. Safe ONLY when the caller can prove no reader is
        /// concurrently holding a Guard against this cell.
        ///
        /// Mirrors `Versioned.deinitSync`. The CLEAR annotator marks
        /// every WITH-alias as non_escaping, so a Guard cannot outlive
        /// its WITH scope; by the time the Arc-managed cell hits
        /// refcount 0, every reader has released its Guard.
        pub fn deinitSync(self: *Self, allocator: std.mem.Allocator) void {
            const current = self.ptr.swap(null, .acq_rel) orelse return;
            allocator.destroy(current);
        }

        /// Read: return a Guard whose `.get()` yields the currently-
        /// published `*T`. Lock-free, wait-free. The EBR pin (entered
        /// here, exited by `Guard.release`) keeps the snapshot alive
        /// even if a concurrent producer publishes a new value before
        /// the caller releases.
        ///
        /// Memory ordering: `.acquire` on the load synchronizes-with
        /// the producer's `.release` cmpxchg in `compareAndPublish`,
        /// so the user sees all writes the producer applied to `*T`
        /// before publish.
        pub fn read(self: *Self, ebr_or_rt: anytype) Guard {
            const ebr = extractEbr(ebr_or_rt);
            ebr.enter();
            const val = self.ptr.load(.acquire) orelse unreachable;
            return Guard{ .ptr = val, .ebr = ebr };
        }

        /// Closure-form read that auto-releases via defer. Recommended
        /// when the caller doesn't need to hand the Guard across a
        /// function boundary — impossible to forget the release.
        /// Mirrors `Versioned.withRead`.
        pub fn withRead(
            self: *Self,
            ebr_or_rt: anytype,
            comptime func: anytype,
            args: anytype,
        ) @typeInfo(@TypeOf(func)).@"fn".return_type.? {
            var g = self.read(ebr_or_rt);
            defer g.release();
            return @call(.auto, func, .{g.get()} ++ args);
        }

        /// The Read Guard. Holds an EBR pin from `read()` until
        /// `release()`. Treat the `*T` as immutable for the duration
        /// of the Guard — the producer may publish a new value at
        /// any time, but EBR keeps THIS snapshot alive.
        pub const Guard = struct {
            ptr: *T,
            ebr: *ThreadLocalEbr,

            pub fn get(self: *Guard) *T {
                return self.ptr;
            }

            pub fn release(self: *Guard) void {
                self.ebr.exit();
            }
        };

        /// Update via rcu-style unbounded retry: load → copy → run
        /// `func` against the copy → CAS-publish → retry on CAS
        /// failure. The user `func` MUST be pure — it can be called
        /// any number of times under contention. On success, retires
        /// the prior `*T` via EBR.
        ///
        /// Memory ordering matches `Versioned.update`:
        ///   - `.acquire` on the load synchronizes the user's copy
        ///     with the prior writer's `.release` cmpxchg.
        ///   - `.release` on the cmpxchg success-path publishes the
        ///     user's writes to `*new_ptr`.
        ///   - `.acquire` on the cmpxchg failure-path synchronizes
        ///     the failure-side load of `actual_old` with the
        ///     winning writer's prior `.release`.
        ///
        /// BOUNDED RETRY (True-Sync-Polymorphism #330): the loop is
        /// capped at `MAX_UPDATE_RETRIES` (256 by default; tests can
        /// override via `pub const CLEAR_ATOMIC_PTR_MAX_UPDATE_RETRIES`
        /// at root). Past the cap, returns `error.AtomicConflict` so
        /// the caller (or CLEAR's per-WITH `ON AtomicConflict ...` /
        /// program SYNC POLICY) can surface a real contention failure
        /// instead of spinning indefinitely.
        ///
        /// The cap is generous (256) because atomic-pointer retry is
        /// cheap -- one acquire-load + one closure call + one CAS --
        /// versus Versioned commit retry which re-runs a whole
        /// transaction body. Hitting the cap means contention so
        /// extreme that 256 fresh attempts all lost the publish race.
        pub fn update(
            self: *Self,
            ebr_or_rt: anytype,
            allocator: std.mem.Allocator,
            comptime func: anytype,
            args: anytype,
        ) !void {
            const ebr = extractEbr(ebr_or_rt);
            const new_ptr = try allocator.create(T);
            var success = false;
            defer if (!success) allocator.destroy(new_ptr);

            var retries: usize = 0;
            while (retries < MAX_UPDATE_RETRIES) : (retries += 1) {
                const old_ptr = self.ptr.load(.acquire) orelse unreachable;

                // Re-copy + re-mutate into the SAME `new_ptr`. The
                // user-supplied `func` must be idempotent on identical
                // input; this is true for any pure mutator.
                new_ptr.* = old_ptr.*;
                @call(.auto, func, .{new_ptr} ++ args);

                if (self.ptr.cmpxchgWeak(old_ptr, new_ptr, .release, .acquire)) |_| {
                    // Failure: another writer published first. Spin
                    // briefly and retry.
                    std.atomic.spinLoopHint();
                    continue;
                }

                // Success: retire the old pointer for EBR-deferred free.
                success = true;
                try ebr.retire(allocator, old_ptr);
                return;
            }
            return error.AtomicConflict;
        }

        /// Lower-level CAS primitive. Tries to publish `new` if the
        /// currently-published pointer equals `expected`. On success,
        /// retires `expected` via EBR; ownership of `new` transfers
        /// to the cell. On failure, returns false; the caller still
        /// owns `new` (must free it themselves) and `expected` is
        /// unchanged.
        ///
        /// Used by `update` internally and exposed for unit tests of
        /// the CAS-and-retire contract. CLEAR users do NOT see this —
        /// the WITH SNAPSHOT MUTABLE block is the only mutation
        /// surface (see docs/agents/atomicptr.md §4.2).
        pub fn compareAndPublish(
            self: *Self,
            ebr_or_rt: anytype,
            allocator: std.mem.Allocator,
            expected: *T,
            new: *T,
        ) !bool {
            if (self.ptr.cmpxchgStrong(expected, new, .release, .acquire)) |_| {
                return false;
            }
            const ebr = extractEbr(ebr_or_rt);
            try ebr.retire(allocator, expected);
            return true;
        }
    };
}
