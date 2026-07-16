const std = @import("std");
const Runtime = @import("runtime.zig").Runtime;
const ThreadLocalEbr = @import("../lib/ebr.zig").ThreadLocalEbr;
const compat = @import("../lib/compat.zig");
const rt_profile = @import("runtime-header.zig");
const mvcc_profile = @import("mvcc-profile.zig");

// Comptime atomic type selection: SimAtomic in Loom mode, real
// std.atomic.Value otherwise. When the root module exports
// `SimAtomic` (i.e. the wrapper file is a Loom test driver), every
// load/store/cmpxchg in `Versioned(T)` becomes a deterministic yield
// point. Mirrors the pattern used by queues.zig + scheduler.zig.
pub const Atomic = blk: {
    const root = @import("root");
    break :blk if (@hasDecl(root, "SimAtomic")) root.SimAtomic else std.atomic.Value;
};

// Hard cap on update / updateMulti CAS retries before surfacing
// `error.UpdateRetriesExhausted` (bridges to CLEAR `MvccConflict`).
// Versioned.update re-runs the WHOLE transaction body on
// retry (vs. AtomicPtr.update which just re-applies a closure on a
// fresh allocation), so retry is more expensive here. 64 is the
// realistic "give-up budget" -- past that, the caller (or CLEAR's
// `ON MvccConflict RETRY(N) THEN ...` / SYNC POLICY) handles the
// failure rather than spinning. The single-cell `update` and the
// multi-cell `updateMulti` outer-retry loop share this budget
// intentionally: they're the same shape of "give up and surface."
//
// Test seam: a test wrapper at zig/ root may declare
// `pub const CLEAR_MVCC_MAX_UPDATE_RETRIES: usize = N;` to lower the
// cap so exhaustion fires deterministically under modest concurrency.
// Production code never declares this, so the default (64) folds to a
// constant. Mirrors the SimAtomic / CLEAR_PROFILE pattern.
pub const MAX_UPDATE_RETRIES: usize = if (@hasDecl(@import("root"), "CLEAR_MVCC_MAX_UPDATE_RETRIES"))
    @import("root").CLEAR_MVCC_MAX_UPDATE_RETRIES
else
    64;

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
// Multi-Version Concurrency Control: `Versioned(T)`
// -------------------------------------------------------------------------
//
// MVCC cell. Each `Versioned(T)` holds an atomic pointer to the current
// committed version of T. Readers acquire a Guard via `read()` (lock-
// free; just an atomic load + EBR pin). Writers swap a new version via
// `update()` (CAS-loop; produces a fresh `*T` and retires the old via
// EBR for deferred-free).
//
// Naming: `Versioned` (not `Versioned`) avoids collision with CLEAR's
// `@shared` capability (Arc-based ownership). CLEAR's `@versioned`
// sigil maps to this primitive in the runtime.
//
// Multi-object consistency: `updateMulti()` (below) needs to atomically
// commit N cells of potentially different T. The mechanism is a tagged-
// address "soft lock" stored in the cell's atomic word:
//
//   * Acquire phase: for each cell in address-sorted order, CAS the
//     current address to its tagged form (low bit set). The tagged
//     address IS the old address -- it still points to valid memory,
//     and readers only need to mask off the tag bit to recover the live
//     value. Sorted order prevents deadlock between two N-cell
//     transactions.
//
//   * Commit phase: with all N tags installed, the txn body runs against
//     stable snapshots. Plain `.release` stores publish the new ptrs,
//     implicitly releasing each tag.
//
// Single-cell `update()` checks the tag on every iteration and spins past
// it, so it never CASes over a tag. Single-cell `read()` masks the tag and
// returns the old (still-EBR-pinned) value -- readers never block on a
// multi-cell txn.
//
// Storage representation: the cell stores its pointer as `Atomic(usize)`
// (the integer form of `*T`). Storing the tagged form as a `*T` would
// trip Zig's `@ptrFromInt` alignment check in safe modes. The `usize`
// representation lets us tag freely and only convert back to `*T` after
// untagging.
//
// Alignment requirement: `T` must have `@alignOf(T) >= 2` so the low bit
// of `*T` is a free tag bit. Asserted at comptime in init().
const PTR_TAG_BIT: usize = 1;

inline fn addrIsTagged(addr: usize) bool {
    return (addr & PTR_TAG_BIT) != 0;
}

inline fn addrUntag(addr: usize) usize {
    return addr & ~PTR_TAG_BIT;
}

inline fn addrTag(addr: usize) usize {
    return addr | PTR_TAG_BIT;
}

pub fn Versioned(comptime T: type) type {
    return struct {
        // The atomic word holds the integer form of `*T`.
        // Stored as `usize` (not `*T`) so that the multi-cell-txn tag
        // bit (see updateMulti) can be set without tripping
        // `@ptrFromInt`'s safe-mode alignment check.
        ptr: Atomic(usize),

        // Re-export of T so generic code (`updateMulti`) can recover the
        // inner type from a `*Versioned(T)` value via
        // `@TypeOf(cell.*).Inner`.
        pub const Inner = T;

        const Self = @This();

        fn destroyOwnedVersion(allocator: std.mem.Allocator, ptr: *T) void {
            // Versioned(T) owns the committed T. Destroying the version must
            // recursively drop T's owned fields before releasing its node.
            rt_profile.CheatLib.cleanup(T, allocator, ptr);
            allocator.destroy(ptr);
        }

        // 1. Init: Allocate the first version on the heap
        pub fn init(allocator: std.mem.Allocator, val: T) !Self {
            comptime std.debug.assert(@alignOf(T) >= 2); // low bit reserved for txn tag
            const node = try allocator.create(T);
            node.* = val;
            return Self{ .ptr = Atomic(usize).init(@intFromPtr(node)) };
        }

        // C2: Retire-via-EBR teardown. The previous variant called
        // `allocator.destroy(current_ptr)` synchronously -- a UAF
        // hazard if any reader still held a Guard against this
        // Versioned. Retiring instead defers the free until every
        // currently-active EBR epoch has drained, matching the same
        // contract `update()` uses for the OLD pointer it swaps out.
        // The Versioned struct itself is value-typed and can be dropped
        // by the caller immediately after this call returns.
        pub fn deinit(self: *Self, trt: *Runtime, allocator: std.mem.Allocator) !void {
            const current_ptr: *T = @ptrFromInt(addrUntag(self.ptr.load(.acquire)));
            try trt.currentEbr().retireWithDeinit(allocator, current_ptr, destroyOwnedVersion);
        }

        // B1 fix (2026-04-30): cleanup variant for `Arc(Versioned(T))`.
        // The Arc reaches strong_count=0 on the path into arcDeinitInner
        // (runtime-header.zig), which has access to an allocator but NOT
        // a `*Runtime` -- so the EBR-retire path above isn't reachable
        // from there. This sync teardown is safe because:
        //   - The CLEAR annotator marks every WITH alias (Guard's `.get()`
        //     result) as non_escaping, so a Guard cannot outlive the WITH
        //     scope that obtained it.
        //   - Every reader holds a strong Arc ref while it has a Guard
        //     (ownership is `Arc`, not the inner cell), so Arc strong=0
        //     happens-after the last Guard is released.
        //   - OLDER versions (pre-current ptrs swapped out by previous
        //     update() calls) are already on the EBR retire queue from
        //     those updates and stay alive until their epochs drain.
        //   - Only the FINAL committed version is freed here, sync.
        pub fn deinitSync(self: *Self, allocator: std.mem.Allocator) void {
            const current_ptr: *T = @ptrFromInt(addrUntag(self.ptr.load(.acquire)));
            destroyOwnedVersion(allocator, current_ptr);
        }

        // 2. Read: Just load the pointer.
        // This is Wait-Free, Lock-Free, and insanely fast.
        //
        // C1: the load uses `.acquire` so that the reader
        // synchronizes-with the writer's `.release` cmpxchg in
        // `update()`. This guarantees the writes the writer applied
        // to `*new_ptr` are visible to the reader when it reads
        // through the returned Guard.
        pub fn read(self: *Self, trt: *Runtime) Guard {
            // A. Signal start
            const ebr = trt.currentEbr();
            ebr.enter();

            // B. Load pointer (Safe because we are in the epoch).
            //    Acquire-paired with the cmpxchg .release in update().
            //    A multi-cell txn may have tagged the low bit; mask it off
            //    to recover the live (still-EBR-pinned) old pointer. The
            //    reader never blocks on a multi-cell txn.
            const val: *T = @ptrFromInt(addrUntag(self.ptr.load(.acquire)));

            if (rt_profile.CLEAR_PROFILE) {
                mvcc_profile.recordRead(@intFromPtr(self), @sizeOf(T));
            }
            return Guard{ .ptr = val, .ebr = ebr };
        }

        // H3: closure-based read API that auto-releases via defer.
        // This is the recommended API for use sites that don't need
        // to hold the Guard across a function boundary -- it's
        // impossible to forget the release. The result of `func` is
        // returned to the caller.
        pub fn withRead(
            self: *Self,
            trt: *Runtime,
            comptime func: anytype,
            args: anytype,
        ) @typeInfo(@TypeOf(func)).@"fn".return_type.? {
            var g = self.read(trt);
            defer g.release();
            return @call(.auto, func, .{g.get()} ++ args);
        }

        // The Read Guard
        pub const Guard = struct {
            ptr: *T,
            ebr: *ThreadLocalEbr,

            pub fn get(self: *Guard) *T {
                return self.ptr;
            }

            pub fn release(self: *Guard) void {
                // C. Signal done
                self.ebr.exit();
            }
        };

        /// Returned when `update()` exhausts its CAS retry budget under
        /// extreme contention. The previous version is unchanged on the
        /// caller's behalf -- caller may retry the whole `update`
        /// (typically with backoff at a higher layer) or treat as
        /// "operation failed."
        // A managed payload may provide an allocator-aware `dupe` operation
        // with its own declared failures. Do not narrow that error contract to
        // OutOfMemory: update must faithfully propagate every failure from
        // constructing the unpublished candidate, plus retry exhaustion.
        pub const UpdateError = anyerror;

        // 3. Write: Copy-On-Write with CAS.
        //
        // H1: each attempt owns a fully independent candidate version.
        // Owned fields must be deep-copied so retiring the old version
        // cannot invalidate the newly published version.
        //
        // H2 (bounded retry): retries are capped at `MAX_UPDATE_RETRIES`
        // (module-level; see top of file) with a spin-pause backoff
        // that grows up to 256 hints per iteration. Past the cap,
        // returns `error.UpdateRetriesExhausted` (bridges to CLEAR
        // `MvccConflict`) so the caller can choose what to do (retry
        // at a higher layer via CLEAR's `ON MvccConflict RETRY(N) THEN
        // ...`, fall back to a lock, surface to the user, etc).
        pub fn update(self: *Self, trt: *Runtime, allocator: std.mem.Allocator, comptime func: anytype, args: anytype) UpdateError!void {
            // EBR critical section spans the entire retry loop. Without
            // this pin, the candidate copy below would
            // race against a concurrent updater retiring the same
            // old_ptr and a third updater's `dumpTrash` freeing it
            // (TSan-flagged on versioned-fiber-stress-test). The pin
            // forces reclaim's global_epoch to stop at this thread's
            // local until update() returns, so any old_ptr we observe
            // via `self.ptr.load` is alive throughout the memcpy + CAS.
            const ebr = trt.currentEbr();
            ebr.enter();
            defer ebr.exit();

            var retries: usize = 0;
            // VOPR-START-RETRY: MVCC update CAS-loser retry, bounded by MAX_UPDATE_RETRIES
            while (retries < MAX_UPDATE_RETRIES) : (retries += 1) {
                // 1. Load the current state (Snapshot). `.acquire`
                // synchronizes with the prior writer's CAS .release
                // so our copy below sees the published bytes.
                var old_addr = self.ptr.load(.acquire);

                // 1a. Multi-cell-txn tag check. If an `updateMulti` has
                // tagged this cell, spin until it commits (untags by
                // storing a fresh addr). Tagged-pointer txns are short
                // (one alloc + a user txn body), so spinning is cheap
                // vs the alternative of falling through and CAS-failing
                // every iteration.
                while (addrIsTagged(old_addr)) {
                    std.atomic.spinLoopHint();
                    old_addr = self.ptr.load(.acquire);
                }
                const old_ptr: *T = @ptrFromInt(old_addr);

                // 2. Deep-copy + re-mutate an independent candidate.
                const new_ptr = try allocator.create(T);
                var initialized = false;
                var published = false;
                errdefer if (initialized and !published) destroyOwnedVersion(allocator, new_ptr) else allocator.destroy(new_ptr);
                new_ptr.* = try rt_profile.CheatLib.dupeValue(T, old_ptr.*, allocator);
                initialized = true;
                @call(.auto, func, .{new_ptr} ++ args);

                // 3. CAS: .release on success publishes our writes to
                // *new_ptr; .acquire on failure synchronizes the
                // failure-side load of `actual_old` with the winning
                // writer's prior .release.
                if (self.ptr.cmpxchgWeak(old_addr, @intFromPtr(new_ptr), .release, .acquire)) |_| {
                    destroyOwnedVersion(allocator, new_ptr);
                    initialized = false;
                    // === FAILURE PATH === — back off briefly and retry.
                    // The hint count grows linearly with retries up to
                    // 256 (2^8). Past that we keep retrying at 256
                    // hints per iter -- enough to let the winner make
                    // progress without burning excess cycles.
                    const hints: usize = @as(usize, 1) << @as(u6, @intCast(@min(retries, 8)));
                    var i: usize = 0;
                    while (i < hints) : (i += 1) std.atomic.spinLoopHint();
                    continue;
                }

                // === SUCCESS PATH === — disarm the defer cleanup,
                // retire the old pointer for EBR-deferred free.
                published = true;
                try ebr.retireWithDeinit(allocator, old_ptr, destroyOwnedVersion);
                if (rt_profile.CLEAR_PROFILE) {
                    mvcc_profile.recordUpdate(@intFromPtr(self), @sizeOf(T), retries, true);
                }
                return;
            }

            // VOPR-END-RETRY
            if (rt_profile.CLEAR_PROFILE) {
                mvcc_profile.recordUpdate(@intFromPtr(self), @sizeOf(T), MAX_UPDATE_RETRIES, false);
            }
            return error.UpdateRetriesExhausted;
        }

        pub fn updateFlow(self: *Self, trt: *Runtime, allocator: std.mem.Allocator, comptime func: anytype, args: anytype) UpdateError!void {
            trt.ebr.enter();
            defer trt.ebr.exit();

            var retries: usize = 0;
            // VOPR-START-RETRY: MVCC updateFlow CAS-loser retry
            while (retries < MAX_UPDATE_RETRIES) : (retries += 1) {
                var old_addr = self.ptr.load(.acquire);
                while (addrIsTagged(old_addr)) {
                    std.atomic.spinLoopHint();
                    old_addr = self.ptr.load(.acquire);
                }
                const old_ptr: *T = @ptrFromInt(old_addr);

                const new_ptr = try allocator.create(T);
                var initialized = false;
                var published = false;
                errdefer if (initialized and !published) destroyOwnedVersion(allocator, new_ptr) else allocator.destroy(new_ptr);
                new_ptr.* = try rt_profile.CheatLib.dupeValue(T, old_ptr.*, allocator);
                initialized = true;
                @call(.auto, func, .{new_ptr} ++ args);

                const flow_ptr = args[0];
                switch (flow_ptr.kind) {
                    .skip_no_commit, .ret_no_commit, .raise_no_commit => {
                        destroyOwnedVersion(allocator, new_ptr);
                        initialized = false;
                        return;
                    },
                    .cont_commit, .ret_commit => {},
                }

                if (self.ptr.cmpxchgWeak(old_addr, @intFromPtr(new_ptr), .release, .acquire)) |_| {
                    destroyOwnedVersion(allocator, new_ptr);
                    initialized = false;
                    const hints: usize = @as(usize, 1) << @as(u6, @intCast(@min(retries, 8)));
                    var i: usize = 0;
                    while (i < hints) : (i += 1) std.atomic.spinLoopHint();
                    continue;
                }

                published = true;
                try trt.ebr.retireWithDeinit(allocator, old_ptr, destroyOwnedVersion);
                if (rt_profile.CLEAR_PROFILE) {
                    mvcc_profile.recordUpdate(@intFromPtr(self), @sizeOf(T), retries, true);
                }
                return;
            }
            // VOPR-END-RETRY

            if (rt_profile.CLEAR_PROFILE) {
                mvcc_profile.recordUpdate(@intFromPtr(self), @sizeOf(T), MAX_UPDATE_RETRIES, false);
            }
            return error.UpdateRetriesExhausted;
        }
    };
}

// -------------------------------------------------------------------------
// Multi-cell transactional update (Versioned cells, possibly heterogeneous T).
// -------------------------------------------------------------------------
//
// Atomically commits N cells via tagged-pointer "soft locks":
//
//   1. Sort cells by `@intFromPtr(cell)` so two transactions that touch
//      the same cell-set (in any textual order) acquire in the same
//      runtime order. No deadlock between two N-cell transactions.
//   2. For each cell in sorted order, CAS-install the tagged form of
//      its current ptr (low bit set). If another multi-cell txn already
//      tagged the cell, spin and retry. If a single-cell `update` raced
//      us on the CAS, retry that cell.
//   3. With all N tags installed, no other writer can race us:
//        * Single-cell `update` spins past the tag (see its inner loop).
//        * Single-cell `read` masks the tag and returns the old value
//          (still EBR-pinned), so readers never block.
//        * Other multi-cell `updateMulti` txns spin in step 2.
//   4. Pin EBR, copy each old snapshot into a fresh node, run the user
//      `txn_fn` with the tuple of mutable views, then plain-store each
//      new node into its cell with `.release` ordering. The store
//      simultaneously publishes the new value AND clears the tag.
//   5. Retire old snapshots via EBR.
//
// On user `txn_fn` error: roll back by storing the old (untagged)
// pointers, deallocate the new nodes, propagate the error.
//
// Errors:
//   * `error.UpdateRetriesExhausted` -> CLEAR `MvccConflict`. Fires if
//     we fail to acquire all N tags within `MAX_UPDATE_RETRIES` outer
//     attempts (genuine pathological contention).
//   * Allocator errors propagate.

/// `updateMulti` returns `anyerror!void` because the user-supplied txn
/// body can return any error type. The set we ourselves produce is
/// `Allocator.Error || error{UpdateRetriesExhausted}` -- the latter is
/// what bridges to CLEAR's `MvccConflict`. Documented for tests; not
/// enforced as a narrower error union.
pub const MultiUpdateError = anyerror;

// Bounded inner CAS-loop budget per cell; past this we treat the cell
// as "stuck" and trigger an outer retry to re-walk acquisition from
// the start. Distinct from MAX_UPDATE_RETRIES: this is the per-cell
// tag-installation spin budget, not the txn-level give-up cap.
//
// Test seam: a test wrapper at zig/ root may declare
// `pub const CLEAR_MVCC_MAX_INNER_RETRIES_MULTI: usize = N;` to lower
// the cap so the contention-rollback path (release tags + outer-retry)
// fires deterministically under modest concurrency. Mirrors the
// MAX_UPDATE_RETRIES seam pattern at line 35.
const MAX_INNER_RETRIES_MULTI: usize = if (@hasDecl(@import("root"), "CLEAR_MVCC_MAX_INNER_RETRIES_MULTI"))
    @import("root").CLEAR_MVCC_MAX_INNER_RETRIES_MULTI
else
    1024;

/// Build a comptime tuple type `.{*T_0, *T_1, ...}` from the cells
/// tuple type `.{*Versioned(T_0), *Versioned(T_1), ...}`. This is the type
/// of the `views` argument passed to the user's `txn_fn` -- one
/// mutable typed pointer per cell.
fn ViewsTupleType(comptime Cells: type) type {
    const cells_info = @typeInfo(Cells).@"struct";
    var types: [cells_info.fields.len]type = undefined;
    inline for (cells_info.fields, 0..) |f, i| {
        const VersionedType = @typeInfo(f.type).pointer.child;
        types[i] = *VersionedType.Inner;
    }
    return std.meta.Tuple(&types);
}

pub fn updateMulti(
    cells: anytype,
    trt: *Runtime,
    allocator: std.mem.Allocator,
    comptime txn_fn: anytype,
    args: anytype,
) MultiUpdateError!void {
    const Cells = @TypeOf(cells);
    const cells_info = @typeInfo(Cells).@"struct";
    const N = cells_info.fields.len;

    if (N == 0) return;

    // 1. Allocate fresh nodes for each cell (hoisted out of the retry
    //    loop -- a single CAS race shouldn't cause N reallocations).
    var new_nodes: ViewsTupleType(Cells) = undefined;
    var initialized: [N]bool = [_]bool{false} ** N;
    inline for (0..N) |i| {
        const T = @TypeOf(cells[i].*).Inner;
        new_nodes[i] = try allocator.create(T);
    }
    var success = false;
    defer if (!success) {
        inline for (0..N) |i| {
            const T = @TypeOf(cells[i].*).Inner;
            if (initialized[i]) {
                rt_profile.CheatLib.cleanup(T, allocator, new_nodes[i]);
            }
            allocator.destroy(new_nodes[i]);
        }
    };

    // 2. Sort cell indices by `@intFromPtr(cell)`. Two transactions
    //    touching the same cell-set always commit in the same address
    //    order -- no deadlock between concurrent multi-cell txns.
    var sorted: [N]usize = undefined;
    var addrs: [N]usize = undefined;
    inline for (0..N) |i| {
        sorted[i] = i;
        addrs[i] = @intFromPtr(cells[i]);
    }
    // Insertion sort -- N is small (typically 2..4).
    {
        var i: usize = 1;
        while (i < N) : (i += 1) {
            var j: usize = i;
            while (j > 0 and addrs[sorted[j - 1]] > addrs[sorted[j]]) : (j -= 1) {
                const tmp = sorted[j - 1];
                sorted[j - 1] = sorted[j];
                sorted[j] = tmp;
            }
        }
    }

    // 3. Snapshot capture array (per-cell address of the un-tagged old
    //    pointer recorded when the tag is installed). Stored as
    //    `usize`; cast back to `*T` per-index as needed.
    var snap_addrs: [N]usize = undefined;

    // 4. Outer retry loop: re-walks tag acquisition if we hit
    //    pathological contention from another multi-cell txn.
    var outer_retries: usize = 0;
    // VOPR-START-RETRY: updateMulti outer retry on inner contention rollback
    outer: while (outer_retries < MAX_UPDATE_RETRIES) : (outer_retries += 1) {
        var acquired: usize = 0;
        var contended = false;

        // 4a. Acquire tags in sorted order.
        sorted_loop: for (sorted) |slot| {
            inline for (0..N) |k| {
                if (slot == k) {
                    const cell = cells[k];
                    var inner_retries: usize = 0;
                    // VOPR-START-RETRY: updateMulti per-cell tag-install spin
                    inner: while (inner_retries < MAX_INNER_RETRIES_MULTI) : (inner_retries += 1) {
                        const curr_addr = cell.ptr.load(.acquire);
                        if (addrIsTagged(curr_addr)) {
                            // Another multi-cell txn owns this cell. Spin.
                            std.atomic.spinLoopHint();
                            continue :inner;
                        }
                        if (cell.ptr.cmpxchgWeak(curr_addr, addrTag(curr_addr), .acq_rel, .acquire)) |_| {
                            // CAS lost -- some single-cell `update` raced
                            // us. Re-load and try again.
                            continue :inner;
                        }
                        snap_addrs[k] = curr_addr;
                        acquired += 1;
                        break :inner;
                    } else {
                        // Inner retries exhausted. Some other txn is
                        // monopolizing this cell. Roll back partial
                        // acquisition and re-walk from the start.
                        contended = true;
                    }
                    // VOPR-END-RETRY
                }
            }
            if (contended) break :sorted_loop;
        }

        if (contended) {
            // 4b. Release acquired tags by storing the un-tagged old
            //     addr back. Walk the prefix in original sorted order;
            //     order doesn't matter for releases (we own the tag).
            for (sorted[0..acquired]) |slot| {
                inline for (0..N) |k| {
                    if (slot == k) {
                        cells[k].ptr.store(snap_addrs[k], .release);
                    }
                }
            }
            continue :outer;
        }

        // 5. Pin EBR. The user's txn body reads from the captured
        //    snapshots (which are still valid because EBR retirement
        //    only fires after every active epoch drains).
        const ebr = trt.currentEbr();
        ebr.enter();
        defer ebr.exit();

        // 6. Copy each captured snapshot into the new_node so the user
        //    starts from the latest committed state for that cell.
        inline for (0..N) |i| {
            const T = @TypeOf(cells[i].*).Inner;
            const old_node: *T = @ptrFromInt(snap_addrs[i]);
            new_nodes[i].* = try rt_profile.CheatLib.dupeValue(T, old_node.*, allocator);
            initialized[i] = true;
        }

        // 7. Run user transaction. On error, roll back the tags and
        //    propagate. (Allocator hand-off via the outer `defer` does
        //    the new_node cleanup.)
        @call(.auto, txn_fn, .{new_nodes} ++ args) catch |err| {
            inline for (0..N) |i| {
                cells[i].ptr.store(snap_addrs[i], .release);
            }
            return err;
        };

        // 8. Publish new pointers (untagged) with `.release` ordering.
        //    The store atomically clears each tag and makes our writes
        //    visible to readers.
        inline for (0..N) |i| {
            cells[i].ptr.store(@intFromPtr(new_nodes[i]), .release);
        }

        // 9. Retire snapshots via EBR -- safe to free once all readers
        //    that captured the snapshot have drained.
        success = true;
        inline for (0..N) |i| {
            const T = @TypeOf(cells[i].*).Inner;
            const old_node: *T = @ptrFromInt(snap_addrs[i]);
            const destroy = struct {
                fn call(a: std.mem.Allocator, ptr: *T) void {
                    rt_profile.CheatLib.cleanup(T, a, ptr);
                    a.destroy(ptr);
                }
            }.call;
            try ebr.retireWithDeinit(allocator, old_node, destroy);
            // Record per-cell that THIS commit was multi-cell. The doctor
            // uses this to reject @shared:versioned -> @boxed:atomic
            // suggestions because AtomicPtr has no multi-pointer CAS.
            if (rt_profile.CLEAR_PROFILE) {
                mvcc_profile.recordMultiCommit(@intFromPtr(cells[i]), @sizeOf(T));
            }
        }
        return;
    }
    // VOPR-END-RETRY

    return error.UpdateRetriesExhausted;
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
