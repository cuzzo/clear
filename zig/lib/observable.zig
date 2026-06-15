//! Lock-free atomic-scalar accumulators for `~T@observable` pipeline
//! aggregates.
//!
//! Each terminal (SUM, MAX, MIN, COUNT, ANY, ALL, ...) replaces its
//! local accumulator with one of these wrappers so that consumers
//! can read the running value cross-fiber via `WITH VIEW v AS s`
//! without taking a lock.
//!
//! Per-item update path uses the cheapest atomic op available
//! (fetchAdd / fetchOr / fetchAnd) where a primitive exists, and
//! falls back to a `cmpxchgWeak` CAS loop for the others (max,
//! min, float sum). Read path is always a single `.load(.acquire)`.
//!
//! The accumulator's underlying numeric / boolean type is captured
//! at compile time via `comptime T: type`. Per the design in
//! `docs/agents/observables.md`, the @observable capability covers
//! exactly the types where lock-free access is structurally cheap;
//! complex aggregates (REDUCE-collection, INDEX) route through
//! `WITH MATERIALIZED VIEW` instead.

const std = @import("std");
const atomic = @import("atomic.zig");
const AtomicValue = atomic.AtomicValue;

// Re-export the atomic primitives so callers reach them via
// `obs.AtomicInt64` etc. (matches the Go-style surface in CLEAR).
pub const AtomicInt = atomic.AtomicInt;
pub const AtomicFloat = atomic.AtomicFloat;
pub const AtomicInt64 = atomic.AtomicInt64;
pub const AtomicUint64 = atomic.AtomicUint64;
pub const AtomicInt32 = atomic.AtomicInt32;
pub const AtomicUint32 = atomic.AtomicUint32;
pub const AtomicFloat64 = atomic.AtomicFloat64;
pub const AtomicFloat32 = atomic.AtomicFloat32;
pub const AtomicBool = atomic.AtomicBool;

/// Pick the right primitive for a comptime numeric `T`.
fn AtomicFor(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .int, .comptime_int => AtomicInt(T),
        .float => AtomicFloat(T),
        else => @compileError("observable accumulator: T must be int or float"),
    };
}

// AtomicSum/Max/Min/Reduce/Avg each repeat the same trivial
// `started()` (load `seen` with .acquire). Zig 0.16 removed
// `usingnamespace`, so a true mixin is impossible; a free helper
// would trade one indirection for another without reducing per-type
// lines. The canonical rationale (release/acquire ordering of `seen`
// against the value field) lives at `AtomicSum.add` and is
// cross-referenced from each clone via "see AtomicSum.add for full
// ordering rationale." Inner.materialize was deleted under A6 —
// scalars don't need it; ObservableTerminal.materialize comptime-
// dispatches on @hasDecl to call inner.materialize for collection
// inners (StreamSet) or fall back to view() for scalars.

/// Lock-free running sum. Composes `AtomicInt(T)` / `AtomicFloat(T)`
/// + a writer-only `seen` flag for `started()` semantics.
pub fn AtomicSum(comptime T: type) type {
    return struct {
        inner: AtomicFor(T) = .{},
        seen: AtomicValue(u8) align(64) = .{ .raw = 0 },

        const Self = @This();

        pub inline fn add(self: *Self, item: T) void {
            // Order matters: update value first, then publish `seen`
            // with .release. A reader doing `started()` (acquire on
            // seen) followed by `view()` (acquire on value) then
            // synchronizes-with this release; the value update is
            // guaranteed visible. The reverse order would let a
            // weakly-ordered reader observe started=true with a stale
            // value (not visible on x86 TSO; real on ARM).
            //
            // P1 amortization: only release-store `seen` on the first
            // call. `view()` reads `inner` with .acquire, so the value
            // synchronizes through `inner` itself; `seen` only needs
            // to flip 0→1 once. After the first store, subsequent
            // adds do a relaxed load that stays in the writer's L1
            // (no cache-line bouncing with concurrent readers).
            _ = self.inner.fetchAdd(item);
            if (self.seen.load(.monotonic) == 0) {
                self.seen.store(1, .release);
            }
        }
        pub inline fn view(self: *const Self) T {
            return self.inner.load();
        }
        pub inline fn started(self: *const Self) bool {
            return self.seen.load(.acquire) != 0;
        }
    };
}

/// Lock-free running count of i64. Per-item: fetchAdd(1).
/// `started()` distinguishes "0 items in" from "stream not started
/// yet" by checking the counter directly (which is monotonic).
/// AtomicInt64's storage is already cache-line aligned by atomic.zig
/// so the wrapper doesn't add its own align(64).
pub const AtomicCount = struct {
    inner: AtomicInt64 = .{},

    const Self = @This();

    pub inline fn inc(self: *Self) void {
        _ = self.inner.fetchAdd(1);
    }
    pub inline fn add(self: *Self, n: i64) void {
        _ = self.inner.fetchAdd(n);
    }
    pub inline fn view(self: *const Self) i64 {
        return self.inner.load();
    }
    /// COUNT defaults to 0 unambiguously; `started()` reads the
    /// counter directly. Distinguishes "0 items in" from "stream
    /// not started yet" only when the counter is monotonic.
    pub inline fn started(self: *const Self) bool {
        return self.inner.load() != 0;
    }
};

/// Lock-free running max. CAS loop -- per-item path is bounded
/// by the number of higher items the writer races with (zero in
/// the single-writer / many-reader model).
///
/// Initial value: `min_init` from `init()` -- defaults to T's
/// minimum (so the first observed item always wins).
pub fn AtomicMax(comptime T: type) type {
    return struct {
        inner: AtomicFor(T),
        seen: AtomicValue(u8) align(64) = .{ .raw = 0 },

        const Self = @This();

        pub fn init() Self {
            return .{ .inner = AtomicFor(T).init(floor(T)) };
        }

        pub inline fn submit(self: *Self, item: T) void {
            // Update value first, then publish `seen` with .release so
            // a reader's `started() && view()` chain synchronizes-with
            // this update. See AtomicSum.add for full ordering rationale.
            // P1: amortize `seen` (see AtomicSum.add).
            self.inner.fetchMax(item);
            if (self.seen.load(.monotonic) == 0) {
                self.seen.store(1, .release);
            }
        }
        pub inline fn view(self: *const Self) T {
            return self.inner.load();
        }
        pub inline fn started(self: *const Self) bool {
            return self.seen.load(.acquire) != 0;
        }
    };
}

/// Lock-free running min. Mirror of AtomicMax.
pub fn AtomicMin(comptime T: type) type {
    return struct {
        inner: AtomicFor(T),
        seen: AtomicValue(u8) align(64) = .{ .raw = 0 },

        const Self = @This();

        pub fn init() Self {
            return .{ .inner = AtomicFor(T).init(ceiling(T)) };
        }

        pub inline fn submit(self: *Self, item: T) void {
            // Update value first, then publish `seen` with .release.
            // See AtomicSum.add for ordering rationale.
            // P1: amortize `seen` (see AtomicSum.add).
            self.inner.fetchMin(item);
            if (self.seen.load(.monotonic) == 0) {
                self.seen.store(1, .release);
            }
        }
        pub inline fn view(self: *const Self) T {
            return self.inner.load();
        }
        pub inline fn started(self: *const Self) bool {
            return self.seen.load(.acquire) != 0;
        }
    };
}

/// Lock-free running average. Two atomics (`sum` + `count`) so
/// the per-item path is two `fetchAdd`s. WITH VIEW returns the
/// quotient as a Float64. The two loads are NOT atomic with
/// respect to each other -- a reader can observe `count` from
/// after the latest item but `sum` from before, producing a
/// slight underestimate. AVG is itself a sampled estimator;
/// this race-window is acceptable.
///
/// `T` is the per-item type (i64 / f64). The output is always
/// f64 so integer streams can still produce a fractional average.
pub fn AtomicAvg(comptime T: type) type {
    return struct {
        sum: AtomicSum(T) = .{},
        count: AtomicCount = .{},

        const Self = @This();

        pub fn add(self: *Self, item: T) void {
            self.sum.add(item);
            self.count.inc();
        }

        pub fn view(self: *const Self) f64 {
            const c = self.count.view();
            if (c == 0) return 0;
            const s = self.sum.view();
            return switch (@typeInfo(T)) {
                .int => @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(c)),
                .float => @as(f64, @floatCast(s)) / @as(f64, @floatFromInt(c)),
                else => unreachable,
            };
        }

        /// AVG returns 0 pre-first-item (not NaN); `started()`
        /// distinguishes "no items yet" from "count is 0".
        pub fn started(self: *const Self) bool {
            return self.count.started();
        }
    };
}

/// Lock-free REDUCE(scalar). Holds a single accumulator value;
/// the user-supplied reducer fn (`fn(acc: T, item: T) T`) runs
/// inside a CAS loop on each item.
///
/// Codegen emits the reducer as a Zig fn whose body is the
/// CLEAR REDUCE body monomorphized for T. The wrapper just
/// provides the CAS-loop scaffold + the bit-level encode/decode
/// for floats.
///
/// Differs from AtomicSum/Max/etc. in that the reduction op is
/// user-defined rather than a builtin (`+`, `>`, `or`); they
/// could in principle be expressed as `AtomicReduce` instances
/// but are left distinct so the per-item path can use cheap
/// fetchAdd/fetchOr where available.
pub fn AtomicReduce(comptime T: type) type {
    return struct {
        inner: AtomicFor(T),
        seen: AtomicValue(u8) align(64) = .{ .raw = 0 },

        const Self = @This();

        pub fn init(initial: T) Self {
            return .{ .inner = AtomicFor(T).init(initial) };
        }

        /// Apply a reducer atomically. Used directly from Zig (and
        /// exercised by observable-test.zig). CLEAR codegen takes a
        /// different path because the user-supplied reducer body may
        /// reference stage-context (`_` and `acc`) which is awkward to
        /// lift into a module-level fn; codegen inlines the CAS loop at
        /// the publish site (lower_range_reduce_observable) and goes
        /// through the public `tryCommit` / `markSeen` helpers below
        /// so it doesn't reach into private fields. Both paths share
        /// the underlying `inner.cmpxchgWeak`.
        pub fn update(self: *Self, comptime reducer: fn (T, T) T, item: T) void {
            // CAS-loop the value first, then publish `seen` with .release
            // so a reader's `started() && view()` synchronizes-with the
            // committed update. See AtomicSum.add for rationale.
            var current = self.inner.load();
            while (true) {
                const next = reducer(current, item);
                if (self.tryCommit(current, next)) |actual| {
                    current = actual;
                } else break;
            }
            self.markSeen();
        }
        pub inline fn view(self: *const Self) T {
            return self.inner.load();
        }
        pub inline fn started(self: *const Self) bool {
            return self.seen.load(.acquire) != 0;
        }
        /// A4: public CAS hook for codegen's inline-reducer path. Returns
        /// null on success, or the new current value on contention --
        /// matches AtomicFor.cmpxchgWeak's protocol exactly so the
        /// inlined CAS loop in lower_range_reduce_observable can use
        /// it without peeking at the private `inner` field.
        pub inline fn tryCommit(self: *Self, expected: T, next: T) ?T {
            return self.inner.cmpxchgWeak(expected, next);
        }
        /// A4: public publication hook. Codegen's inline CAS loop calls
        /// this once after the loop converges so a reader's `started()`
        /// (acquire on seen) synchronizes-with the committed update.
        /// Centralizes the .release ordering rationale documented at
        /// AtomicSum.add; previously the codegen used .monotonic here,
        /// which was a latent ordering bug that this method fixes.
        /// P1: amortize `seen` (see AtomicSum.add).
        pub inline fn markSeen(self: *Self) void {
            if (self.seen.load(.monotonic) == 0) {
                self.seen.store(1, .release);
            }
        }
    };
}

/// Lock-free FIND -- "first item matching predicate, observable
/// while the stream runs". Once a match is recorded the value is
/// frozen; further submits are ignored. WITH VIEW returns ?T:
/// `null` until the first match, the matched value afterwards.
///
/// Two atomics: a `found` flag (u8) + the value slot. The flag
/// is the publication barrier -- writers CAS it from 0 to 1; the
/// winner stores the value with relaxed ordering and the flag's
/// release pairs with the reader's acquire load on the same flag.
///
/// `T` must be a primitive (int / float / bool) for the inline-encoding
/// variant. String inputs (`[]const u8` / `[]u8`) route to
/// `AtomicFindString` below — same external surface (init/submit/view/
/// started/materialize/deinit) but a heap-pointer-CAS implementation
/// because slice values don't fit in a single atomic word.
pub fn AtomicFind(comptime T: type) type {
    if (T == []const u8 or T == []u8) return AtomicFindString();
    const ti = @typeInfo(T);
    const Backing = switch (ti) {
        .int => T,
        .float => switch (@bitSizeOf(T)) {
            32 => u32,
            64 => u64,
            else => @compileError("AtomicFind: float bit size not supported (32 or 64 only)"),
        },
        .bool => u8,
        else => @compileError("AtomicFind: T must be int / float / bool / []const u8"),
    };
    return struct {
        // FIND's two-atomic publication pattern doesn't fit
        // AtomicInt cleanly (the `found` bit is the publication
        // barrier, not a value), so this stays as raw atomics. Both
        // fields are still cache-line aligned.
        found: AtomicValue(u8) align(64) = .{ .raw = 0 },
        value: AtomicValue(Backing) align(64) = .{ .raw = 0 },
        // Single-writer enforcement (always-on after M4). The current
        // submit() pattern (store value, then CAS the flag) is unsafe
        // under multi-writer: writer A stores A, writer B overwrites
        // with B, writer A wins the CAS — published value is B (the
        // loser's). The single-writer contract is enforced upstream
        // by CLEAR's type system (FIND is a fold terminal, single-
        // producer by construction); the assert catches misuse from
        // raw Zig in every build mode (steady-state cost is one
        // relaxed load per submit; see assertSingleWriter).
        writer_tid: AtomicValue(usize) = .{ .raw = 0 },

        const Self = @This();

        /// Submit a candidate. The first call wins; subsequent
        /// calls are no-ops. Single-writer contract.
        pub fn submit(self: *Self, item: T) void {
            assertSingleWriter(&self.writer_tid);
            if (self.found.load(.acquire) != 0) return;
            self.value.store(encode(item), .monotonic);
            _ = self.found.cmpxchgStrong(0, 1, .release, .monotonic);
        }

        pub fn view(self: *const Self) ?T {
            if (self.found.load(.acquire) == 0) return null;
            return decode(self.value.load(.monotonic));
        }

        /// FIND has its own optional return; `started()` is the
        /// uniform predicate (true once a match has been recorded).
        pub fn started(self: *const Self) bool {
            return self.found.load(.acquire) != 0;
        }

        inline fn encode(v: T) Backing {
            return switch (ti) {
                .int => v,
                .float => @bitCast(v),
                .bool => @intFromBool(v),
                else => unreachable,
            };
        }

        inline fn decode(b: Backing) T {
            return switch (ti) {
                .int => b,
                .float => @bitCast(b),
                .bool => b != 0,
                else => unreachable,
            };
        }
    };
}

/// String-specialized FIND. Slice values (`[]const u8`) are 16 bytes
/// on 64-bit and don't fit in a single atomic word, so we hold a
/// heap-allocated `*Box` and CAS-publish the pointer. First submit
/// wins; subsequent submits free their incoming bytes (ownership
/// transfer pattern, mirroring StreamSet).
///
/// Lifecycle:
///   - `init(alloc)`: returns `Self`. No allocation.
///   - `submit(item)`: takes ownership of `item` (must have been
///     allocated via `self.alloc`). If the slot is already filled,
///     frees the incoming. If we win the CAS, the box keeps `item`.
///     OOM during box-create silently drops the match (FIND can miss).
///   - `view()`: returns `?[]const u8`. The returned slice is pinned
///     for the AtomicFindString's lifetime; do NOT keep across
///     destroy(). Use `materialize` for an owned copy.
///   - `materialize(alloc)`: deep-dupes the matched string into
///     caller's allocator.
///   - `deinit()`: frees the box and the matched string (if any).
fn AtomicFindString() type {
    return struct {
        const T = []const u8;
        const Box = struct { data: T };
        // Atomic head pointer. Null = no match yet; non-null = the box
        // we own holds the published string.
        slot: AtomicValue(?*Box) align(64) = .{ .raw = null },
        alloc: std.mem.Allocator,
        // Single-writer contract enforcement (always-on after M4).
        // See StreamSetCfg.writer_tid for rationale.
        writer_tid: AtomicValue(usize) = .{ .raw = 0 },

        const Self = @This();

        pub fn init(alloc: std.mem.Allocator) Self {
            return .{ .alloc = alloc };
        }

        pub fn deinit(self: *Self) void {
            if (self.slot.load(.acquire)) |b| {
                self.alloc.free(b.data);
                self.alloc.destroy(b);
            }
        }

        /// Take ownership of `item`. Producer must have allocated `item`
        /// from `self.alloc`. Frees the incoming on duplicate-submit /
        /// loser path / OOM. Single-writer contract.
        pub fn submit(self: *Self, item: T) void {
            assertSingleWriter(&self.writer_tid);
            if (self.slot.load(.acquire) != null) {
                self.alloc.free(item);
                return;
            }
            const box = self.alloc.create(Box) catch {
                // OOM allocating the box: drop the match silently and
                // free the incoming. FIND semantics tolerate misses
                // (the consumer just keeps seeing null); a hard error
                // here would change submit's signature for every
                // AtomicFind shape.
                self.alloc.free(item);
                return;
            };
            box.* = .{ .data = item };
            // Publish via CAS. Release order so a reader's acquire-load
            // on slot synchronizes-with this store and sees `box.data`.
            const prev = self.slot.cmpxchgStrong(null, box, .release, .monotonic);
            if (prev != null) {
                // Lost the race (single-writer contract violation;
                // assertSingleWriter would have panicked above unless
                // the violator is the same thread re-entering — which
                // is also wrong). Free our orphaned allocation.
                self.alloc.free(item);
                self.alloc.destroy(box);
            }
        }

        pub fn view(self: *const Self) ?T {
            const b = self.slot.load(.acquire) orelse return null;
            return b.data;
        }

        pub fn started(self: *const Self) bool {
            return self.slot.load(.acquire) != null;
        }

        /// Owned `[]const u8` snapshot for `WITH MATERIALIZED VIEW`.
        /// Caller frees with `alloc.free` when done.
        pub fn materialize(self: *const Self, alloc: std.mem.Allocator) !?T {
            const b = self.slot.load(.acquire) orelse return null;
            return try alloc.dupe(u8, b.data);
        }

        /// Element type of materialize's `!?T` return — declared so
        /// future ObservableTerminal.materializeNext-style paths can
        /// recover it without type-info reflection (parity with
        /// StreamSet).
        pub const MaterializedElem = T;
    };
}

/// Lock-free OR-fold over a stream of bools. WITH VIEW returns
/// "any true seen so far". Per-item: fetchOr.
pub const AtomicAny = struct {
    value: AtomicValue(u8) align(64) = .{ .raw = 0 },
    seen: AtomicValue(u8) align(64) = .{ .raw = 0 },

    const Self = @This();

    pub fn submit(self: *Self, item: bool) void {
        // Update value first, then publish `seen` with .release. See
        // AtomicSum.add for ordering rationale.
        //
        // P2: ANY is monotone: once `value` is 1, no further item can
        // change it. Single writer means a relaxed pre-load is race-
        // free; we skip the atomic RMW after the first true.
        // P1: amortize `seen` (see AtomicSum.add).
        if (item and self.value.load(.monotonic) == 0) {
            _ = self.value.fetchOr(1, .monotonic);
        }
        if (self.seen.load(.monotonic) == 0) {
            self.seen.store(1, .release);
        }
    }

    pub fn view(self: *const Self) bool {
        return self.value.load(.acquire) != 0;
    }

    /// ANY returns false pre-first-item; `started()` distinguishes
    /// "no items yet" from "every observed item was false".
    pub fn started(self: *const Self) bool {
        return self.seen.load(.acquire) != 0;
    }
};

/// Lock-free AND-fold over a stream of bools. WITH VIEW returns
/// "all seen so far were true". Per-item: fetchAnd.
///
/// Initial state: 1 (true). Stays true until the first false flips
/// it to 0. Once 0, it never goes back.
pub const AtomicAll = struct {
    value: AtomicValue(u8) align(64) = .{ .raw = 1 },
    seen: AtomicValue(u8) align(64) = .{ .raw = 0 },

    const Self = @This();

    pub fn submit(self: *Self, item: bool) void {
        // Update value first, then publish `seen` with .release. See
        // AtomicSum.add for ordering rationale.
        //
        // P2: ALL is monotone: once `value` is 0, no further item can
        // change it. Single writer means a relaxed pre-load is race-
        // free; we skip the atomic RMW after the first false.
        // P1: amortize `seen` (see AtomicSum.add).
        if (!item and self.value.load(.monotonic) != 0) {
            _ = self.value.fetchAnd(0, .monotonic);
        }
        if (self.seen.load(.monotonic) == 0) {
            self.seen.store(1, .release);
        }
    }

    pub fn view(self: *const Self) bool {
        return self.value.load(.acquire) != 0;
    }

    /// ALL returns true pre-first-item (vacuous truth);
    /// `started()` distinguishes vacuous from "every observed
    /// item was true".
    pub fn started(self: *const Self) bool {
        return self.seen.load(.acquire) != 0;
    }
};

// =============================================================
// Pipeline-terminal observable wrappers.
//
// `ObservableTerminal(Inner)` is the one shared wrapper. It bundles
// any of the lock-free accumulators above (AtomicSum, AtomicCount,
// AtomicMax, AtomicAvg, ...) with a producer-side `done` flag plus
// a codegen-supplied WaitGroup bridge.
//
// Read API:
//   - `view()`   point-in-time read. Non-blocking. Returns the
//                running aggregate pre-finish, the converged value
//                post-finish.
//   - `next()`   blocks on the WaitGroup until `finish()`, then
//                reads. The blocking variant of view().
//
// `started`/`isFinished` predicates expose the lifecycle state.
// Terminal-specific writers (`add`, `submit`, `inc`, `update`) live
// on `Inner`; codegen calls them directly via `acc.inner.X` so the
// wrapper stays per-terminal surface-free.
//
// Construction:
//   - `new(alloc)`            -- Inner default-constructs (`Inner{}`)
//                                or exposes 0-arg `init()` or
//                                `init(alloc) Self` (AtomicFindString).
//   - `newWith(alloc, inner)` -- for seeded inits where the codegen
//                                supplies the configured Inner
//                                (REDUCE, DISTINCT).
//
// Per-terminal aliases below (`ObservableSum`, `ObservableCount`,
// `ObservableMax`, ...) just pick the right Inner so callers can
// write `*ObservableSum(T)` etc. unchanged.
// =============================================================

pub fn ObservableTerminal(comptime Inner: type) type {
    return struct {
        inner: Inner,
        // Producer-side "stream is exhausted" flag. Released by
        // `finish()`; acquired by `isFinished()`. Independent of the
        // Inner's `seen` counter (seen = "any item observed yet";
        // done = "no more items will arrive").
        //
        // M3: aligned to 64 bytes so it lives in a different cache line
        // than `inner`'s atomic fields (writer-only `seen` / value).
        // Without this alignment, the producer's writes to inner's
        // .release `seen.store(1, ...)` and a reader's spin on
        // `done.load(.acquire)` ping-pong the same cache line, doubling
        // wait()-side traffic on the hot publish path. The 64-byte
        // alignment also pushes the function-pointer table below into a
        // separate line so writes to `done` (rare, once) don't dirty
        // cold codegen-time fields.
        done: AtomicValue(u8) align(64) = .{ .raw = 0 },
        // Opaque "completion handle" -- the codegen heap-allocates a
        // `*WaitGroup` (from runtime/scheduler.zig) and stores its
        // pointer here at construction time. observable.zig calls
        // `done_done_fn(done_handle)` from `finish()` and the joiner
        // calls `done_wait_fn(done_handle)` from `next()`. Function
        // pointers keep this struct runtime-agnostic so the
        // standalone tests and bench_clear.zig don't need the
        // scheduler module.
        done_handle: ?*anyopaque = null,
        done_done_fn: ?*const fn (?*anyopaque) void = null,
        done_wait_fn: ?*const fn (?*anyopaque) void = null,
        done_destroy_fn: ?*const fn (?*anyopaque, std.mem.Allocator) void = null,

        const Self = @This();
        const safety_checks = std.debug.runtime_safety;
        // View result type lifted from Inner.view via type-info reflection
        // -- handles AtomicSum(T)→T, AtomicCount→i64, AtomicAvg→f64,
        // AtomicFind(T)→?T, AtomicAny/All→bool uniformly.
        const View = @typeInfo(@TypeOf(Inner.view)).@"fn".return_type.?;

        pub fn new(alloc: std.mem.Allocator) !*Self {
            return newWith(alloc, defaultInner(alloc));
        }

        pub fn newWith(alloc: std.mem.Allocator, inner: Inner) !*Self {
            const self = try alloc.create(Self);
            self.* = .{ .inner = inner };
            return self;
        }

        /// Codegen-only: wire the runtime's WaitGroup into the
        /// observable so producer/joiner can park instead of spin.
        /// Must be called after `new`/`newWith` and before any item
        /// publish or `next()`. Standalone tests skip this -- the
        /// joiner falls back to a `std.Thread.yield` spin.
        pub fn setCompletion(
            self: *Self,
            handle: *anyopaque,
            done_fn: *const fn (?*anyopaque) void,
            wait_fn: *const fn (?*anyopaque) void,
            destroy_fn: *const fn (?*anyopaque, std.mem.Allocator) void,
        ) void {
            // Single-init contract: codegen calls this exactly once
            // immediately after new()/newWith(), before the producer
            // fiber starts publishing. A second call would silently
            // overwrite the first handle (leaking the prior
            // WaitGroup) and tear-read the function pointers from
            // the producer's perspective. Catch misuse explicitly.
            std.debug.assert(self.done_handle == null);
            self.done_handle = handle;
            self.done_done_fn = done_fn;
            self.done_wait_fn = wait_fn;
            self.done_destroy_fn = destroy_fn;
        }

        pub fn destroy(self: *Self, alloc: std.mem.Allocator) void {
            // H2 contract: by the time destroy() runs, the producer fiber
            // must have called `finish()`. The codegen's :observable
            // cleanup template enforces this by emitting `wait()` before
            // destroy(). If the producer hard-panicked before defer
            // ctx.acc.finish() ran, wait() deadlocks (caller never
            // reaches us). If the producer returned cleanly with neither
            // defer nor errdefer firing finish(), we'd UAF the inner
            // mid-publish; assert instead so it shows up loudly in
            // Debug/ReleaseSafe rather than silently corrupting state in
            // a future view() from a stale snapshot. Producers should
            // pair `defer ctx.acc.finish()` with an `errdefer` on any
            // pre-loop allocation that can fail; the codegen's spawn
            // template does this today.
            // Gate on done_handle != null so the standalone tests
            // (which exercise lifecycle without a WG bridge) can
            // create+destroy without finishing. The codegen always
            // wires done_handle via setCompletion before the producer
            // fiber spawns, so the assertion fires for any real
            // pipeline-terminal observable that bypasses wait().
            if (safety_checks and self.done_handle != null) {
                std.debug.assert(self.isFinished());
            }
            // H4 contract: the binding's owning scope is the SOLE
            // destroyer. Sibling readers calling view() through a shared
            // pointer must release before that scope exits. Today
            // observables are heap-pointed locals captured by exactly
            // one BG producer fiber + the owner; no shared-binding
            // codegen path emits a *ObservableTerminal across fibers.
            // The :observable cleanup template's wait()-before-destroy
            // sequence guarantees the producer is gone before destroy()
            // runs, and the owner fiber is single-threaded for view()
            // calls within its scope. If a future codegen path leaks an
            // observable pointer to a sibling fiber (e.g. via @shared
            // wrapper), this comment is the place to add a refcount
            // gate; see commit history for an active_readers prototype.
            // Free the completion handle (if wired) via the
            // codegen-supplied destroy function.
            if (self.done_destroy_fn) |f| f(self.done_handle, alloc);
            // Inners with owned heap state (StreamSet's hashmap + buffers)
            // expose `deinit()`; scalar atomic Inners (AtomicSum / Count /
            // Max / ...) have only POD fields and skip this branch via
            // comptime `@hasDecl`. Lets the same `:observable` cleanup
            // recipe handle every terminal shape.
            if (comptime @hasDecl(Inner, "deinit")) self.inner.deinit();
            alloc.destroy(self);
        }

        /// Point-in-time read. Returns the inner accumulator's
        /// current value; works at any lifecycle stage. Pre-finish
        /// it's the running aggregate; post-finish it's the
        /// converged value (no longer changing). For "wait until
        /// done, then read," use `next()` instead.
        pub fn view(self: *const Self) View {
            return self.inner.view();
        }

        pub fn started(self: *const Self) bool {
            return self.inner.started();
        }

        /// Mark the producer side as exhausted. CONTRACT (H2): the
        /// producer fiber MUST call `finish()` on every exit path,
        /// including caught errors. The codegen emits this as a
        /// `defer ctx.acc.finish()` at the top of the producer body,
        /// which covers normal return + `return error.X` paths. A hard
        /// Zig panic (`@panic`, unreachable, integer overflow in
        /// ReleaseSafe, OOM in ReleaseFast where panic is enabled)
        /// bypasses defer and aborts the process before finish() runs;
        /// post-panic observable lifetime is undefined and `wait()`
        /// will deadlock waiting for a callback the panicked fiber
        /// never made. This is acceptable because panic is
        /// process-fatal anyway. Producer-side errors that should not
        /// kill the process must be `try`-caught and converted to
        /// finish-without-publish before they unwind past defer.
        pub fn finish(self: *Self) void {
            // Use a CAS 0→1 transition so the completion callback fires
            // exactly once. The producer's `defer ctx.acc.finish()` can
            // be called twice on some control-flow paths (an explicit
            // finish() in the body plus the defer); a duplicate
            // done_done_fn(handle) into a WaitGroup is a panic, so gate
            // the callback on the unique transition.
            if (self.done.cmpxchgStrong(0, 1, .release, .monotonic) == null) {
                if (self.done_done_fn) |f| f(self.done_handle);
            }
        }

        pub fn isFinished(self: *const Self) bool {
            return self.done.load(.acquire) != 0;
        }

        /// Block until `finish()` has been called. Like `next()` but
        /// doesn't acquire a value -- used by the cleanup path on
        /// scope exit so the binding's destroy() doesn't race the
        /// producer fiber. Critical for collection inners (StreamSet)
        /// where `next()` would acquire a snapshot the cleanup then
        /// discards, leaking its refcount.
        ///
        /// H2 deadlock note: `wait()` parks indefinitely if the
        /// producer fiber never calls `finish()`. See the contract on
        /// `finish()` for the cases where this is possible -- in
        /// short, hard panic in the producer is process-fatal anyway,
        /// and any other producer-side error path the codegen emits
        /// is wrapped to guarantee `finish()` runs.
        pub fn wait(self: *Self) void {
            if (self.done_wait_fn) |f| {
                f(self.done_handle);
            } else {
                while (!self.isFinished()) {
                    std.Thread.yield() catch std.atomic.spinLoopHint();
                }
            }
        }

        /// Block until `finish()` has been called, then return the
        /// final value. Used by CLEAR's `NEXT running` / `s> COLLECT`
        /// lowering for `~T@observable` bindings.
        ///
        /// When the codegen has wired a completion handle (via
        /// setCompletion), park on it -- the joiner's task status
        /// goes to Blocked and the consumer fiber takes CPU. (A
        /// spin-with-coopYield wouldn't work: owner-side LIFO
        /// RunQueue.pop would re-pop the joiner every time and
        /// starve the consumer.) Standalone tests without the
        /// completion handle fall back to a Thread.yield spin --
        /// adequate when only one fiber exists.
        ///
        /// Signature is `anyerror!View` to match
        /// `CheatLib.Promise.next()` so the same `try X.next()`
        /// lowering shape works for both backings.
        pub fn next(self: *Self) anyerror!View {
            self.wait();
            return self.inner.view();
        }

        /// Mid-fold owned snapshot. Used by CLEAR's
        /// `WITH MATERIALIZED VIEW running AS s { ... }` lowering;
        /// the alias `s` owns the snapshot until end-of-WITH and the
        /// receiving cleanup path frees it.
        ///
        /// A6: scalar Inners (AtomicSum/Count/Max/Min/Avg/Reduce/Find/
        /// Any/All) don't define their own `materialize` — the
        /// allocator is unused for value-typed terminals; the
        /// snapshot is just a copy of `view()`. Comptime-dispatch on
        /// `@hasDecl` so collection Inners (StreamSet) get a real
        /// dupe and scalars get a no-alloc copy without each Inner
        /// repeating a `_ = alloc; return self.view();` forwarder.
        pub fn materialize(
            self: *Self,
            alloc: std.mem.Allocator,
        ) if (@hasDecl(Inner, "materialize"))
            @typeInfo(@TypeOf(Inner.materialize)).@"fn".return_type.?
        else
            anyerror!View {
            if (comptime @hasDecl(Inner, "materialize")) {
                return self.inner.materialize(alloc);
            } else {
                return self.view();
            }
        }

        /// Wait + materialize: like `next()` but returns an owned
        /// snapshot via `inner.materialize(alloc)`. Used by NEXT on
        /// collection observables (DISTINCT) where `inner.view()`
        /// returns a refcounted handle the caller would have to
        /// release explicitly. Only valid when `Inner` exposes a
        /// `materialize` method.
        ///
        /// The raw `[]T` from `inner.materialize` is wrapped in a
        /// `std.ArrayListUnmanaged(T)` so the receiving CLEAR binding
        /// (typed `T[]`) flows through the existing list-cleanup path
        /// at scope exit.
        pub fn materializeNext(
            self: *Self,
            alloc: std.mem.Allocator,
        ) anyerror!std.ArrayListUnmanaged(Inner.MaterializedElem) {
            self.wait();
            const slice = try self.inner.materialize(alloc);
            return .{ .items = slice, .capacity = slice.len };
        }

        // Comptime constructor for the default Inner.
        //   - `Inner.init()` for 0-arg inits (AtomicMax/Min).
        //   - `Inner.init(alloc)` for inits that need an allocator
        //     (AtomicFindString — heap-CAS variant of AtomicFind for
        //     `[]const u8`). Falls through to default-aggregate
        //     (`Inner{}`) for inits-less accumulators (AtomicSum /
        //     Count / Avg / Any / All / scalar Find).
        fn defaultInner(alloc: std.mem.Allocator) Inner {
            if (comptime hasAllocInit(Inner)) return Inner.init(alloc);
            if (comptime hasZeroArgInit(Inner)) return Inner.init();
            return .{};
        }
    };
}

// Comptime predicate: does `T` have a `pub fn init()` taking 0 params?
fn hasZeroArgInit(comptime T: type) bool {
    if (!@hasDecl(T, "init")) return false;
    const InitT = @TypeOf(T.init);
    const info = @typeInfo(InitT);
    if (info != .@"fn") return false;
    return info.@"fn".params.len == 0;
}

// Comptime predicate: does `T` have `pub fn init(alloc: std.mem.Allocator) Self`?
// Used by ObservableTerminal.defaultInner so AtomicFindString (the
// heap-CAS variant for `[]const u8`) can be default-constructed
// through `ObservableTerminal.new(alloc)` without codegen needing a
// special-case `newWith` path. The `Inner.init` signature must be
// exactly `(alloc) Self` — not `(alloc) !Self` — so submit's no-fail
// signature stays uniform across all AtomicFind variants.
fn hasAllocInit(comptime T: type) bool {
    if (!@hasDecl(T, "init")) return false;
    const InitT = @TypeOf(T.init);
    const info = @typeInfo(InitT);
    if (info != .@"fn") return false;
    if (info.@"fn".params.len != 1) return false;
    const P0 = info.@"fn".params[0].type orelse return false;
    return P0 == std.mem.Allocator;
}

// --- Per-terminal aliases ---
// Each alias picks the right Inner; codegen continues to write
// `*ObservableSum(T)` / `*ObservableCount()` / etc. and gets a
// fully-shaped wrapper for free.

pub fn ObservableSum(comptime T: type) type {
    return ObservableTerminal(AtomicSum(T));
}

pub fn ObservableCount() type {
    return ObservableTerminal(AtomicCount);
}

pub fn ObservableMax(comptime T: type) type {
    return ObservableTerminal(AtomicMax(T));
}

pub fn ObservableMin(comptime T: type) type {
    return ObservableTerminal(AtomicMin(T));
}

pub fn ObservableAvg(comptime T: type) type {
    return ObservableTerminal(AtomicAvg(T));
}

pub fn ObservableAny() type {
    return ObservableTerminal(AtomicAny);
}

pub fn ObservableAll() type {
    return ObservableTerminal(AtomicAll);
}

pub fn ObservableFind(comptime T: type) type {
    return ObservableTerminal(AtomicFind(T));
}

// REDUCE-scalar uses `newWith(alloc, AtomicReduce(T).init(seed))` --
// no default-init alias because the seed is part of the user form.
pub fn ObservableReduce(comptime T: type) type {
    return ObservableTerminal(AtomicReduce(T));
}

// DISTINCT into ~T[]@set:observable. The Inner is the dynamic
// `StreamSet(T)` -- a single-writer / many-reader append-only set
// with grow-on-fill geometric doubling. StreamSet.init takes an
// allocator (1 arg), so codegen constructs via:
//   ObservableStreamSet(T).newWith(alloc, try StreamSet(T).init(alloc))
//   catch unreachable
// (Not the default `new(alloc)` -- the Inner doesn't default-construct.)
pub fn ObservableStreamSet(comptime T: type) type {
    return ObservableTerminal(StreamSet(T));
}

// DISTINCT into ~T[N]@set:observable (bounded stream source). The Inner
// is `StreamSetBounded(T, N)` — fixed-capacity, no grow path, no
// refcounted snapshots (the [N]T buffer never relocates so view()
// returns a stable slice directly into it). Codegen constructs via:
//   ObservableStreamSetBounded(T, N).newWith(alloc, try StreamSetBounded(T, N).init(alloc))
//   catch unreachable
pub fn ObservableStreamSetBounded(comptime T: type, comptime N: usize) type {
    return ObservableTerminal(StreamSetBounded(T, N));
}

// --- StreamSet (DISTINCT terminal backing) ---

/// Bounded append-only set with stable storage. Used as the
/// backing for `~T[N]@set:observable` (DISTINCT terminal on a
/// bounded stream). Maintains two structures:
///
///   - `contents`: fixed-capacity buffer of T (never relocates,
///                 since N is known at init -- the slice
///                 returned by `view()` points into here)
///   - `lookup`:   AutoHashMap for O(1) membership testing
///                 (rehash is fine; readers don't touch it)
///   - `count`:    atomic published-element count -- the
///                 publication barrier between writer and reader
///
/// **Single-writer** (the pipeline) + many-reader. `submit()`
/// is NOT safe for concurrent writers (the HashMap put isn't
/// atomic). `view()` is lock-free; the returned slice is
/// stable for the caller's WITH VIEW scope.
///
/// `T` must be hash + eq compatible with std's AutoHashMap
/// (primitives, enums, packed structs). `[]const u8` / `[]u8`
/// (string keys) are detected at comptime and routed through
/// StringHashMap automatically. Other slice / heap-pointing key
/// types are not yet supported and will compile-error.
pub fn StreamSetBounded(comptime T: type, comptime N: usize) type {
    const is_string_key = T == []const u8 or T == []u8;
    const Lookup = if (is_string_key)
        std.StringHashMapUnmanaged(void)
    else
        std.AutoHashMapUnmanaged(T, void);

    return struct {
        contents: [N]T = undefined,
        count: AtomicValue(usize) = .{ .raw = 0 },
        lookup: Lookup = .{},
        alloc: std.mem.Allocator,

        const Self = @This();
        pub const capacity: usize = N;

        pub fn init(alloc: std.mem.Allocator) !Self {
            var self: Self = .{ .alloc = alloc };
            try self.lookup.ensureTotalCapacity(alloc, @intCast(N));
            return self;
        }

        pub fn deinit(self: *Self) void {
            // String-keyed sets take ownership of submitted strings;
            // free retained uniques here. Primitive keys skip via comptime.
            if (comptime is_string_key) {
                const c = self.count.load(.monotonic);
                for (self.contents[0..c]) |s| self.alloc.free(s);
            }
            self.lookup.deinit(self.alloc);
        }

        /// Insert if novel. Returns true on insert, false on
        /// duplicate or full. Single-writer: caller must not
        /// race other submits.
        ///
        /// String-keyed sets take ownership of `item`: duplicates
        /// (and overflow) are freed immediately; uniques retained
        /// until deinit. Producer allocator must match `self.alloc`.
        pub fn submit(self: *Self, item: T) bool {
            if (self.lookup.contains(item)) {
                if (comptime is_string_key) self.alloc.free(item);
                return false;
            }
            const c = self.count.load(.monotonic);
            if (c >= N) {
                if (comptime is_string_key) self.alloc.free(item);
                return false;
            }
            self.contents[c] = item;
            self.lookup.putAssumeCapacity(item, {});
            // Release-store on count is the publication barrier.
            // A reader's acquire-load on count pairs here.
            self.count.store(c + 1, .release);
            return true;
        }

        /// Stable read-only snapshot. Length reflects items
        /// published as of the load.
        pub fn view(self: *const Self) []const T {
            const c = self.count.load(.acquire);
            return self.contents[0..c];
        }

        pub fn len(self: *const Self) usize {
            return self.count.load(.acquire);
        }

        pub fn started(self: *const Self) bool {
            return self.count.load(.acquire) != 0;
        }

        /// Owned `[]T` snapshot for `WITH MATERIALIZED VIEW`. Caller
        /// frees with `alloc.free` (and per-element free for string keys).
        /// Deep-dupes string entries since this StreamSetBounded owns the
        /// underlying bytes; a shallow dupe would dangle after deinit.
        pub fn materialize(self: *const Self, alloc: std.mem.Allocator) ![]T {
            const c = self.count.load(.acquire);
            const src = self.contents[0..c];
            if (comptime is_string_key) {
                const out = try alloc.alloc(T, c);
                errdefer alloc.free(out);
                var n: usize = 0;
                errdefer for (out[0..n]) |s| alloc.free(s);
                while (n < c) : (n += 1) out[n] = try alloc.dupe(u8, src[n]);
                return out;
            }
            return alloc.dupe(T, src);
        }

        /// Element type of materialize's `![]T` return -- declared
        /// explicitly so `ObservableTerminal.materializeNext` doesn't
        /// have to recover it via type-info reflection.
        pub const MaterializedElem = T;
    };
}

/// Dynamic-capacity append-only set with stable, contiguous
/// storage. Used as the backing for `~T[]@set@observable`
/// (DISTINCT on an unbounded stream).
///
/// Implementation: single contiguous `[]T` buffer with
/// **grow-on-fill** (geometric doubling). When the buffer fills,
/// the writer allocates a new buffer at 2x capacity, copies
/// existing items, and atomically swaps the head pointer.
/// Readers hold refcounted snapshots that pin the buffer they're
/// looking at -- old buffers stay alive until the last reader's
/// `WITH VIEW` scope exits, then are freed.
///
/// `view()` returns a real `[]const T` slice, matching the doc's
/// `?String[]@set` binding type for the dynamic case. Per-emit
/// cost is amortized O(1) (geometric doubling); per-emit cost
/// during a grow is O(N) but happens log(N) times.
///
/// Single-writer (the stream emitter) + many-reader. A brief
/// mutex around the head-pointer load+refcount-increment race
/// prevents the classic ABA between "load head" and "bump
/// refcount" -- without it, a writer's swap-and-release could
/// free the old buffer between the reader's load and inc. Future
/// optimization: epoch-based reclamation via lib/ebr.zig (deferred
/// to v0.3 along with the persistent-data-structure work).
///
/// `T` must be hash + eq compatible with std's AutoHashMap
/// (primitives, enums, packed structs). `[]const u8` / `[]u8`
/// (string keys) are detected at comptime and routed through
/// StringHashMap automatically.
pub fn StreamSet(comptime T: type) type {
    return StreamSetCfg(T, .{});
}

pub const StreamSetConfig = struct {
    initial_capacity: usize = 8,
};

/// Tiny spinlock for the very-brief head-swap critical section
/// in StreamSet. Since the section is just a pointer load plus
/// a refcount fetchAdd (or pointer swap + refcount fetchSub), a
/// real Mutex is overkill and Zig 0.16's std doesn't expose
/// `std.Thread.Mutex` anymore. ParkingMutex is fiber-aware and
/// requires a Task context, which we don't have here.
const SpinLock = struct {
    flag: AtomicValue(bool) = .{ .raw = false },

    fn lock(self: *SpinLock) void {
        while (self.flag.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinLock) void {
        self.flag.store(false, .release);
    }
};

/// Refcounted buffer. The head atomic holds one reference; each
/// reader's snapshot holds another. `release()` decrements; the
/// buffer is freed when the count hits zero.
fn StreamSetBuffer(comptime T: type) type {
    return struct {
        data: []T,
        // Items currently in `data` (always <= data.len). Set by
        // the writer with .release; read by viewers with .acquire.
        count: AtomicValue(usize) = .{ .raw = 0 },
        refcount: AtomicValue(u32) = .{ .raw = 1 }, // head holds 1

        const Self = @This();

        pub fn create(alloc: std.mem.Allocator, capacity: usize) !*Self {
            const buf = try alloc.create(Self);
            buf.* = .{ .data = try alloc.alloc(T, capacity) };
            return buf;
        }

        pub fn release(self: *Self, alloc: std.mem.Allocator) void {
            const prev = self.refcount.fetchSub(1, .acq_rel);
            if (prev == 1) {
                alloc.free(self.data);
                alloc.destroy(self);
            }
        }
    };
}

pub fn StreamSetCfg(comptime T: type, comptime cfg: StreamSetConfig) type {
    // String-shaped keys (`[]const u8`) need StringHashMap; std.hash.autoHash
    // refuses slices since hashing-by-pointer-vs-contents is ambiguous.
    // Detect at comptime so the same StreamSet API works for both
    // primitives and strings. Future non-primitive keys (slices of
    // other element types, structs containing slices) will compile-error
    // here and need their own hash strategy.
    const is_string_key = T == []const u8 or T == []u8;
    const Lookup = if (is_string_key)
        std.StringHashMapUnmanaged(void)
    else
        std.AutoHashMapUnmanaged(T, void);

    return struct {
        head: ?*Buffer = null, // current write buffer; protected by mtx for swaps
        mtx: SpinLock = .{}, // brief lock around head load+inc / swap+dec
        lookup: Lookup = .{},
        alloc: std.mem.Allocator,
        // Single-writer contract enforcement (always-on after M4).
        // The first submit() arms the writer thread id; subsequent
        // submits from the same thread are a single relaxed load on
        // the steady-state hot path. A different-thread submit panics
        // (silent corruption otherwise — see assertSingleWriter).
        writer_tid: AtomicValue(usize) = .{ .raw = 0 },

        const Self = @This();
        const Buffer = StreamSetBuffer(T);
        pub const SnapshotT = StreamSetSnapshot(T);

        pub fn init(alloc: std.mem.Allocator) !Self {
            return .{
                .head = try Buffer.create(alloc, cfg.initial_capacity),
                .alloc = alloc,
            };
        }

        pub fn deinit(self: *Self) void {
            // For string-keyed sets, the producer transfers ownership of
            // each unique string to the StreamSet via submit(); free the
            // retained items here before tearing down the lookup + buffer.
            // Primitive-keyed sets skip this branch at comptime (no per-key
            // allocation to reclaim).
            if (comptime is_string_key) {
                if (self.head) |buf| {
                    const c = buf.count.load(.monotonic);
                    for (buf.data[0..c]) |s| self.alloc.free(s);
                }
            }
            self.lookup.deinit(self.alloc);
            if (self.head) |buf| buf.release(self.alloc);
        }

        /// Insert if novel. Single-writer: caller must not race
        /// other submits. May allocate when the current buffer
        /// fills (geometric doubling).
        ///
        /// String-keyed sets take ownership of `item` on submit:
        /// duplicates are freed immediately; uniques are retained
        /// until deinit (freed there). Producer allocator must match
        /// `self.alloc` (typically `rt.heapAlloc()` on both sides).
        pub fn submit(self: *Self, item: T) !bool {
            assertSingleWriter(&self.writer_tid);
            if (self.lookup.contains(item)) {
                if (comptime is_string_key) self.alloc.free(item);
                return false;
            }
            // No mutex needed for the lookup put or item write -- only
            // the head swap is contended (against readers).
            const cur = self.head.?;
            const cur_count = cur.count.load(.monotonic);
            const buf = if (cur_count >= cur.data.len) blk: {
                // Grow: alloc new buffer, copy items, swap head.
                const new_cap = cur.data.len * 2;
                const new_buf = try Buffer.create(self.alloc, new_cap);
                @memcpy(new_buf.data[0..cur_count], cur.data[0..cur_count]);
                new_buf.count.store(cur_count, .monotonic);
                // Mutex window covers reader's load(head)+fetchAdd
                // pair; serializing here prevents ABA.
                self.mtx.lock();
                self.head = new_buf;
                self.mtx.unlock();
                cur.release(self.alloc); // drop head's reference
                break :blk new_buf;
            } else cur;
            try self.lookup.put(self.alloc, item, {});
            buf.data[cur_count] = item;
            // Release-store on count is the publication barrier
            // for the slot write; reader's acquire-load on count
            // pairs.
            buf.count.store(cur_count + 1, .release);
            return true;
        }

        /// Stable read-only snapshot. Returns a slice into the
        /// buffer that's pinned for the snapshot's lifetime;
        /// caller MUST call snapshot.release() when done.
        pub fn view(self: *Self) SnapshotT {
            self.mtx.lock();
            const buf = self.head.?;
            _ = buf.refcount.fetchAdd(1, .monotonic);
            self.mtx.unlock();
            const len_now = buf.count.load(.acquire);
            return .{ .buffer = buf, .length = len_now, .alloc = self.alloc };
        }

        pub fn len(self: *Self) usize {
            // Refcount the buffer before unlocking so a concurrent
            // grow + release can't free `buf` between the unlock and
            // the count read. Mirrors the `view()` pattern. Without
            // this, a writer that grows + releases the old buffer can
            // race the count.load() into UAF.
            self.mtx.lock();
            const buf = self.head.?;
            _ = buf.refcount.fetchAdd(1, .monotonic);
            self.mtx.unlock();
            const result = buf.count.load(.acquire);
            buf.release(self.alloc);
            return result;
        }

        pub fn started(self: *Self) bool {
            return self.len() != 0;
        }

        /// Owned `[]T` snapshot for `WITH MATERIALIZED VIEW`. Caller
        /// frees with `alloc.free` (and per-element free for string
        /// keys -- see below). Acquires a snapshot, dupes, then
        /// releases the snapshot before returning.
        ///
        /// For string-keyed sets, the StreamSet owns the underlying
        /// string bytes and frees them at deinit. A shallow `alloc.dupe`
        /// would copy slice headers (pointers) only -- the caller would
        /// hold dangling pointers after destroy. So for string keys we
        /// deep-dupe each entry; the caller must free each element +
        /// the outer slice (or use the standard list cleanup which does
        /// both via `CheatLib.cleanup(ArrayListUnmanaged([]const u8))`).
        pub fn materialize(self: *Self, alloc: std.mem.Allocator) ![]T {
            var snap = self.view();
            defer snap.release();
            const src = snap.slice();
            if (comptime is_string_key) {
                const out = try alloc.alloc(T, src.len);
                errdefer alloc.free(out);
                var n: usize = 0;
                errdefer for (out[0..n]) |s| alloc.free(s);
                while (n < src.len) : (n += 1) out[n] = try alloc.dupe(u8, src[n]);
                return out;
            }
            return alloc.dupe(T, src);
        }

        /// Element type of materialize's `![]T` return -- declared
        /// explicitly so `ObservableTerminal.materializeNext` doesn't
        /// have to recover it via type-info reflection.
        pub const MaterializedElem = T;
    };
}

pub fn StreamSetSnapshot(comptime T: type) type {
    return struct {
        buffer: *StreamSetBuffer(T),
        length: usize,
        alloc: std.mem.Allocator,

        const Self = @This();

        pub fn slice(self: *const Self) []const T {
            return self.buffer.data[0..self.length];
        }

        pub fn release(self: *Self) void {
            self.buffer.release(self.alloc);
        }
    };
}

// --- Observable<T>: general single-writer snapshot cell ---

/// Generic single-writer / many-reader snapshot cell. The
/// runtime backing for IMMUTABLE Stream Observables (per
/// `docs/agents/observables.md`).
///
/// Each `set(new_val)` allocates a fresh `Snapshot(T)` holding
/// `new_val`, atomically swaps the head pointer, and decrements
/// the old head's refcount. Each `view()` returns a snapshot
/// handle whose `value()` is a `*const T` pinned for the
/// handle's lifetime; the snapshot stays alive (refcounted)
/// until the handle is `release()`d.
///
/// The reader's load(head)+inc(refcount) race against the
/// writer's swap(head)+dec(old_refcount) is serialized by a
/// brief spinlock -- same pattern as `StreamSet`. Without it,
/// the writer could free the old buffer between the reader's
/// load and inc (classic ABA / dangling-pointer issue). Future
/// optimization: epoch-based reclamation via lib/ebr.zig.
///
/// Single-writer is a CONTRACT, not enforced at runtime: multiple
/// concurrent `set()` calls would race on the head swap. CLEAR's
/// type system enforces it (the stream's internal emit code is
/// the sole writer).
///
/// Heap-allocated T (lists, strings, structs with owning fields)
/// require a `cleanup_fn` at init -- the runtime invokes it when
/// the last snapshot of a given T dies, so the underlying T is
/// deinited correctly. For Plain-Old-Data T (primitives, value-
/// type structs) `cleanup_fn` is `null`.
pub fn Observable(comptime T: type) type {
    return struct {
        head: ?*Snap = null,
        mtx: SpinLock = .{},
        alloc: std.mem.Allocator,
        cleanup_fn: ?*const fn (*T, std.mem.Allocator) void = null,
        // Tracks the original initial value so `started()` can
        // distinguish the seeded snapshot from any user `set()`.
        // The pre-set state is `seen == 0`; any `set()` flips it.
        seen: AtomicValue(u8) = .{ .raw = 0 },
        // Single-writer contract enforcement (always-on after M4).
        // See StreamSetCfg.writer_tid for rationale.
        writer_tid: AtomicValue(usize) = .{ .raw = 0 },

        const Self = @This();
        pub const Snap = ObservableSnap(T);
        pub const Handle = ObservableHandle(T);

        /// Initialize with an initial value. The Observable takes
        /// ownership of `initial` -- if T owns heap state, the
        /// caller must NOT free it after this call.
        pub fn init(alloc: std.mem.Allocator, initial: T) !Self {
            const snap = try alloc.create(Snap);
            snap.* = .{ .value = initial };
            return .{
                .head = snap,
                .alloc = alloc,
            };
        }

        /// Initialize with a custom cleanup hook for T's deinit.
        /// The hook fires when each snapshot's refcount hits zero.
        pub fn initWithCleanup(
            alloc: std.mem.Allocator,
            initial: T,
            cleanup_fn: *const fn (*T, std.mem.Allocator) void,
        ) !Self {
            const snap = try alloc.create(Snap);
            snap.* = .{ .value = initial };
            return .{
                .head = snap,
                .alloc = alloc,
                .cleanup_fn = cleanup_fn,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.head) |snap| self.releaseSnap(snap);
        }

        /// Publish a new snapshot. Single-writer contract: caller
        /// must not race other `set()` calls.
        pub fn set(self: *Self, new_val: T) !void {
            assertSingleWriter(&self.writer_tid);
            const snap = try self.alloc.create(Snap);
            snap.* = .{ .value = new_val };

            self.mtx.lock();
            const old = self.head;
            self.head = snap;
            self.mtx.unlock();

            // P1: amortize `seen` (see AtomicSum.add). The mtx
            // unlock above already provides release ordering for
            // readers acquiring `head`; `seen` is a one-way 0→1
            // flag for `started()` and only needs to flip once.
            if (self.seen.load(.monotonic) == 0) {
                self.seen.store(1, .monotonic);
            }
            if (old) |o| self.releaseSnap(o);
        }

        /// Has any user `set()` been called? The seeded initial value
        /// is *not* counted — `started()` reflects the design-doc
        /// "NIL until first item observed" semantic.
        pub fn started(self: *const Self) bool {
            return self.seen.load(.acquire) != 0;
        }

        /// Owned snapshot for `WITH MATERIALIZED VIEW`. POD T:
        /// returns the value by copy. Heap-owned T (with a
        /// `cleanup_fn`) requires the caller to provide a deep-copy
        /// hook -- otherwise the materialized owned copy and the
        /// pinned snapshot would alias and either's release would
        /// UAF the other. Returns `error.MaterializeRequiresPOD` so
        /// the contract is enforced in ALL build modes (the previous
        /// `std.debug.assert` was removed in ReleaseFast, leaving
        /// non-POD callers silently aliasing the snapshot).
        /// v0.3: a `materializeWithCopy` variant takes the copy
        /// hook explicitly.
        pub fn materialize(self: *Self, _alloc: std.mem.Allocator) !T {
            _ = _alloc;
            if (self.cleanup_fn != null) return error.MaterializeRequiresPOD;
            var h = self.view();
            defer h.release();
            return h.value().*;
        }

        /// Get a stable snapshot handle. The caller MUST call
        /// handle.release() when done. The snapshot's T value is
        /// pinned for the handle's lifetime.
        pub fn view(self: *Self) Handle {
            self.mtx.lock();
            const snap = self.head.?;
            _ = snap.refcount.fetchAdd(1, .monotonic);
            self.mtx.unlock();
            return .{
                .snap = snap,
                .alloc = self.alloc,
                .cleanup_fn = self.cleanup_fn,
            };
        }

        fn releaseSnap(self: *Self, snap: *Snap) void {
            const prev = snap.refcount.fetchSub(1, .acq_rel);
            if (prev == 1) {
                if (self.cleanup_fn) |f| f(&snap.value, self.alloc);
                self.alloc.destroy(snap);
            }
        }
    };
}

pub fn ObservableSnap(comptime T: type) type {
    return struct {
        value: T,
        refcount: AtomicValue(u32) = .{ .raw = 1 },
    };
}

/// Handle to an Observable snapshot. `value()` returns a
/// `*const T` valid until `release()`. The handle owns one
/// refcount on the snapshot.
pub fn ObservableHandle(comptime T: type) type {
    return struct {
        snap: *ObservableSnap(T),
        alloc: std.mem.Allocator,
        cleanup_fn: ?*const fn (*T, std.mem.Allocator) void,

        const Self = @This();

        pub fn value(self: *const Self) *const T {
            return &self.snap.value;
        }

        pub fn release(self: *Self) void {
            const prev = self.snap.refcount.fetchSub(1, .acq_rel);
            if (prev == 1) {
                if (self.cleanup_fn) |f| f(&self.snap.value, self.alloc);
                self.alloc.destroy(self.snap);
            }
        }
    };
}

// --- Internal helpers ---

fn floor(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .int => std.math.minInt(T),
        .float => -std.math.inf(T),
        else => @compileError("AtomicMax/Min: T must be int or float"),
    };
}

fn ceiling(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .int => std.math.maxInt(T),
        .float => std.math.inf(T),
        else => @compileError("AtomicMax/Min: T must be int or float"),
    };
}

/// Single-writer contract enforcement (always-on after M4). The
/// first caller's thread id arms `tid` via CAS; subsequent calls
/// from the same thread are a single relaxed load (fast path,
/// per-emit cost ~constant). A call from a different thread is a
/// contract violation and panics — silent corruption otherwise.
///
/// Why a panic and not a return-error: the contract is enforced
/// upstream by CLEAR's type system (only the stream's internal
/// emit code holds the `@observable` writer end). The runtime
/// check is a backstop for raw-Zig misuse and mis-wired codegen,
/// not a recoverable failure mode.
fn assertSingleWriter(tid: *AtomicValue(usize)) void {
    // M4: removed the build-mode gate. The previous implementation
    // skipped this check in ReleaseFast, so a misuse (two writer
    // fibers on the same observable) would silently corrupt data with
    // no signal. The contract is enforced by CLEAR's type system
    // upstream (single producer fiber per observable), so the steady
    // state is "tid already armed to me, fast path returns" -- one
    // relaxed load per write, no CAS, no panic. The arming CAS fires
    // once at first write per binding lifetime.
    const me: usize = std.Thread.getCurrentId();
    const cur = tid.load(.monotonic);
    if (cur == me) return; // fast path: this thread is already the writer
    // Resolve who already armed: if cur==0 we race to arm and read back
    // the actual winner; if cur != 0 the offender is `cur` directly.
    // A10: single fall-through panic instead of two near-identical blocks.
    const offender = if (cur == 0)
        (tid.cmpxchgStrong(0, me, .acquire, .acquire) orelse return)
    else
        cur;
    if (offender == me) return; // we won the arming CAS in the cur==0 branch
    std.debug.panic(
        "@observable single-writer contract violated: thread {d} writing while thread {d} already wrote",
        .{ me, offender },
    );
}
