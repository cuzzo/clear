// fsm.zig — Stackless finite-state-machine tasks for the CLEAR scheduler.
//
// An FsmTask is an alternative execution form for fiber bodies whose control
// flow does not require a stack: it runs inline on the worker thread's stack
// and returns a YieldReason value instead of performing an assembly context
// switch. This is cheaper than a stackful Task on both memory (~80 bytes of
// task metadata + caller-sized state struct vs a minimum 2 KB fiber stack)
// and CPU (no switch.S round-trip).
//
// The scheduler integrates FsmTasks alongside stackful Tasks via a separate
// ready queue (fsm_ready_queue); they can await io_uring completions through
// FsmIoWaiter, which encodes a marker in the CQE user_data so the scheduler's
// existing drain path routes the wake to the FSM queue.
//
// FsmTasks are slab-allocated by the Scheduler (`fsm_task_slab`); the
// user-owned ctx struct holds a `*FsmTask` and the FsmTask's `ctx` field
// points back. The slab gives detectCycleFsm a Pin protocol that mirrors
// the stackful Task slab — chain walkers can deref a *FsmTask safely
// across schedulers without UAF. This file provides the FsmTask shape;
// allocation lives in `Scheduler.allocFsmTask` (runtime/scheduler.zig).
//
// Out-of-scope for this module (handled by the caller / scheduler):
//   - state struct layout (user-defined)
//   - parking-lot lock waits (FSM tasks fall back to stackful today)
//   - FSM <-> stackful await interop (handled by promise wake path)

const std = @import("std");

// Comptime atomic type selection: SimAtomic in Loom mode, real atomics
// otherwise. Mirrors queues.zig: loom harness exports SimAtomic so FsmTask
// field accesses become yield points for deterministic interleaving.
const Atomic = blk: {
    const root = @import("root");
    break :blk if (@hasDecl(root, "SimAtomic")) root.SimAtomic else std.atomic.Value;
};

// -----------------------------------------------------------------------------
// Status
// -----------------------------------------------------------------------------

pub const FsmStatus = enum(u8) {
    /// Task is in the ready queue or currently running.
    Ready = 0,
    /// Task has produced YieldReason.Done and is ready to be freed.
    Finished = 1,
    /// Task returned YieldReason.WaitForIO and is parked on an FsmIoWaiter.
    /// Re-enqueued to Ready by processCqes when the CQE arrives.
    Blocked = 2,
};

// -----------------------------------------------------------------------------
// YieldReason — what the resume function reports back to the scheduler
// -----------------------------------------------------------------------------
//
// Returned by value from every FSM resume call. The scheduler dispatches on
// the tag and either frees the task, re-queues it, or stashes it blocked.
//
// Intentionally simple for the MVP: adding new wait reasons (timer, lock)
// only requires extending this union and the scheduler's dispatch arm.

pub const YieldReason = union(enum) {
    /// Task body has completed. Scheduler frees the task (caller still owns
    /// the state struct; tasks do not self-free their state).
    Done: void,
    /// Task has more work and wants to be re-scheduled. Typically used to
    /// break up long compute into cooperative chunks.
    Yielded: void,
    /// Task has submitted an io_uring SQE whose user_data is
    /// `waiter.encode()`. Scheduler stashes the task; CQE wake re-enqueues.
    WaitForIO: *FsmIoWaiter,
    /// Task has registered on a ParkingMutex/ParkingRwLock waiter queue
    /// via tryLockOrRegister. Scheduler stashes the task; the lock's
    /// unlock path wakes it via submitFsmResume. The waiter node lives
    /// in the user state struct alongside the FsmTask.
    WaitForLock: void,
};

// -----------------------------------------------------------------------------
// Resume function signature
// -----------------------------------------------------------------------------
//
// Every FSM task has a single resume function. On each invocation it dispatches
// on the state index stored in the task (or in the user state struct), runs up
// to the next suspension point, and returns a YieldReason.
//
// The convention is that the resume fn never calls the scheduler directly; it
// communicates only via its return value. This keeps FSM dispatch a single
// inline function call — no yield/switch, no allocation, no hidden state.

pub const ResumeFn = *const fn (*FsmTask) YieldReason;

pub const FsmCtxAllocClass = enum(u8) {
    none,
    slab64,
    slab128,
    slab256,
    heap,
};

// -----------------------------------------------------------------------------
// FsmTask
// -----------------------------------------------------------------------------
//
// Type-erased handle to a state machine. Recovery from `*FsmTask` to the
// owning ctx struct is via `@ptrCast(@alignCast(t.ctx.?))` — Zig resolves the
// offset at comptime, so the ctx struct can place `task` at any field
// position. The codegen and runtime tests place it at offset 0 by
// convention (predictable layout for debuggers, the offset-0 subtraction
// is elided), but recovery is correct at any offset.
//
// Size: ~40 bytes on 64-bit. Compare to Task (~160 B) + Fiber + stack (2 KB).

/// Error surfaced by a parking-lot lock op on an FSM. Stored on
/// `FsmTask.lock_error` and observed by the resume fn on next dispatch.
/// Mirrors `parking-lot.LockError`.
pub const FsmLockError = enum(u8) {
    None = 0,
    Deadlock = 1,
    LockCycle = 2,
    LockTimeout = 3,
};

pub const FsmTask = struct {
    /// Invoked by the scheduler to make progress on this task.
    resume_fn: ResumeFn,
    /// Current status.
    status: FsmStatus = .Ready,
    /// Profile-only: spawn timestamp in ns.
    spawn_ns: u64 = 0,
    /// Profile-only: generated BG/worker site id; 0 = unattributed.
    profile_site_id: u32 = 0,
    /// Profile-only: fiber-profile.DispatchKind enum value.
    profile_dispatch: u8 = 0,
    /// Forward pointer to the user-owned ctx struct that holds resume
    /// state. FsmTask is slab-allocated separately from the ctx (mirrors
    /// stackful Task: slab pin protects detectCycleFsm chain walks from
    /// UAF), so resume_fn recovers ctx via
    /// `@ptrCast(@alignCast(t.ctx.?))` rather than the legacy
    /// `@fieldParentPtr("task", t)`. Set at spawn, cleared at Done.
    ctx: ?*anyopaque = null,
    /// Monotonic counter of every park/wake transition. detectCycleFsm
    /// uses this to validate per-hop snapshots across a chain walk
    /// (mirrors stackful Task.seq).
    seq: Atomic(u32) = Atomic(u32).init(0),
    /// Per-slot generation. Bumped by Scheduler.allocFsmTask on every
    /// allocation from fsm_task_slab. detectCycleFsm captures this
    /// after pinning the slab and re-reads on validation; mismatch =
    /// slot reused mid-walk = torn snapshot. Mirrors stackful
    /// Task.generation.
    generation: Atomic(u32) = Atomic(u32).init(0),
    /// Scheduler that allocated this task's slab slot. FSM tasks may be
    /// load-balanced to another scheduler, but completion must return the
    /// slot to the allocating scheduler's slab.
    owner_scheduler: ?*anyopaque = null,
    /// Non-null when blocked on IO.
    waiter: ?*FsmIoWaiter = null,
    /// Non-null when blocked on a parking-lot lock. Opaque `*WaiterNode`.
    /// Atomic so wake-side writes (under queue_spin) establish a
    /// TSan-visible happens-before with reader-side scans
    /// (scanFsmLockWaiters, detectCycleFsm). Mirrors the stackful
    /// `lock_waiter_node` protocol.
    lock_waiter: Atomic(?*anyopaque) = Atomic(?*anyopaque).init(null),
    /// Non-null when blocked on a parking-lot lock — points at the
    /// lock's WaiterList so scanFsmLockWaiters can remove the waiter
    /// node on timeout. Mirrors stackful Task.waiting_for_lock_list.
    waiting_for_lock_list: Atomic(?*anyopaque) = Atomic(?*anyopaque).init(null),
    /// Surfaced by parking-lot / scheduler when a lock op fails. The
    /// resume fn reads and clears on next dispatch.
    lock_error: FsmLockError = .None,
    /// Points to the lock this task is parked on (opaque). Cleared on wake.
    /// Atomic for the same reason as `lock_waiter` — read by
    /// scanFsmLockWaiters / detectCycleFsm without holding queue_spin.
    waiting_for_lock: Atomic(?*anyopaque) = Atomic(?*anyopaque).init(null),
    /// FSM holder of the lock we're parked on (if FSM-held). Used by
    /// detectCycleFsm to walk mixed and pure-FSM cycles.
    waiting_for_fsm_owner: Atomic(?*FsmTask) = Atomic(?*FsmTask).init(null),
    /// Monotonic ms timestamp of when this FSM parked. Read by the
    /// scheduler's lock timeout scanner.
    lock_wait_start_ms: Atomic(i64) = Atomic(i64).init(0),
    /// Monotonic ms timestamp at which this FSM should be woken
    /// from a sleep. Set by Scheduler.fsmSleepTask before the resume
    /// fn yields WaitForLock; the scan loop in run() compares
    /// against this and re-enqueues the FSM when reached.
    fsm_wake_time: i64 = 0,
    /// Optional callback invoked by the scheduler after the task
    /// reaches .Finished. Frees the user-owned ctx struct (which
    /// contains this FsmTask -- so the callback frees itself).
    ///
    /// Required for FSM-emitted bodies: the resume fn used to call
    /// `alloc.destroy(ctx)` on the Done path then return, but
    /// dispatchOnce reads `task.status` AFTER the resume fn returns,
    /// which is a use-after-free once ctx is gone. Moving the
    /// destroy here closes the window: dispatchOnce writes status
    /// while ctx is still live, then the scheduler invokes
    /// destroy_fn separately after the dispatch returns.
    ///
    /// The FSM emit synthesizes a per-ctx-type fn:
    ///   fn destroyTask(t: *FsmTask) void {
    ///       const c: *@This() = @ptrCast(@alignCast(t.ctx.?));
    ///       CheatHeader.freeFsmCtx(@This(), t, c);
    ///   }
    /// and stores its pointer here at spawn time.
    destroy_fn: ?*const fn (*FsmTask) void = null,

    /// Allocation class for the generated FSM ctx pointed to by `ctx`.
    /// Set by CheatHeader.allocFsmCtx; consumed by freeFsmCtx. `none`
    /// covers hand-written runtime tests that do not use generated ctx
    /// allocation.
    ctx_alloc_class: FsmCtxAllocClass = .none,

    /// Per-task Runtime shell. Heap-allocated at spawn time and freed by
    /// the scheduler on .Done. The codegen binds the FSM ctx's `rt` field
    /// to this pointer BEFORE spawning; MVCC uses Runtime.currentEbr() to
    /// resolve the active scheduler thread's EBR slot at dispatch time.
    /// Lazy-imports runtime.zig in the field type so the
    /// runtime.zig -> scheduler.zig -> fsm.zig -> runtime.zig cycle
    /// resolves: only the pointer-to-Runtime is needed here, not the
    /// full Runtime layout, which Zig handles for cyclic pointer-only
    /// types.
    task_runtime: ?*@import("runtime.zig").Runtime = null,

    pub fn init(resume_fn: ResumeFn) FsmTask {
        return .{ .resume_fn = resume_fn };
    }
};

// -----------------------------------------------------------------------------
// FsmIoWaiter
// -----------------------------------------------------------------------------
//
// Parallel to scheduler.IoWaiter, but for FSM tasks. The CQE user_data encoding
// uses bit 0 as the "is waiter" marker and bit 1 as the "is FSM" marker, so
// the scheduler's processCqes can tell apart:
//   ud & 0b01 == 0 : direct *Task pointer (poll readiness wake)
//   ud & 0b11 == 1 : stackful IoWaiter
//   ud & 0b11 == 3 : FsmIoWaiter (this type)
//
// Result is filled by the scheduler on CQE drain, then the task is enqueued
// back onto fsm_ready_queue.

// (FsmRunQueue uses the file-level `Atomic` alias declared at the top.)

pub const FsmIoWaiter = struct {
    task: *FsmTask,
    result: i32 = undefined,

    pub fn init(task: *FsmTask) FsmIoWaiter {
        return .{ .task = task };
    }

    pub fn encode(self: *FsmIoWaiter) u64 {
        // Pointers to extern / regular struct data are at least 4-byte
        // aligned on all supported architectures, so the low two bits are
        // available for tagging.
        return @intFromPtr(self) | 0b11;
    }

    pub fn decode(ud: u64) *FsmIoWaiter {
        return @ptrFromInt(ud & ~@as(u64, 0b11));
    }

    pub fn isFsmMarker(ud: u64) bool {
        return (ud & 0b11) == 0b11;
    }
};

// -----------------------------------------------------------------------------
// FsmRunQueue — work-stealing Chase-Lev deque for FsmTasks
// -----------------------------------------------------------------------------
//
// Identical algorithm to queues.zig:RunQueue but specialized for *FsmTask.
// Owner does push/pop from the bottom; thieves do stealOne from the top via
// CAS. tryStealFrom grabs ~half of the victim's queue.
//
// Separate type (rather than generalizing RunQueue) so the stackful hot path
// is untouched; the algorithms are the same, but correctness for FSM stealing
// is validated independently through fsm-steal-test.zig and the race/VOPR
// tests.
//
// The Chase-Lev algorithm itself has extensive Loom coverage via RunQueue
// (queues-test.zig + vopr-loom.zig); since FsmRunQueue mirrors it verbatim
// with only the element type changed, the memory-ordering correctness
// carries over.

pub const FsmRunQueue = struct {
    pub const INITIAL_LOG_SIZE: u5 = 6; // 2^6 = 64 slots

    pub const CircularArray = struct {
        data: []Atomic(?*FsmTask),
        mask: u32,
    };

    array: Atomic(?*CircularArray),
    allocator: std.mem.Allocator,
    old_arrays: std.ArrayListUnmanaged(*CircularArray) = .empty,

    top: Atomic(u32) = Atomic(u32).init(0),
    bottom: Atomic(u32) = Atomic(u32).init(0),

    pub fn initWithAllocator(alloc: std.mem.Allocator) !FsmRunQueue {
        const arr = try makeArray(alloc, INITIAL_LOG_SIZE);
        return .{ .array = Atomic(?*CircularArray).init(arr), .allocator = alloc };
    }

    fn makeArray(alloc: std.mem.Allocator, log_size: u5) !*CircularArray {
        const size = @as(u32, 1) << log_size;
        const data = try alloc.alloc(Atomic(?*FsmTask), size);
        errdefer alloc.free(data);
        for (data) |*slot| slot.* = Atomic(?*FsmTask).init(null);
        const arr = try alloc.create(CircularArray);
        arr.* = .{ .data = data, .mask = size - 1 };
        return arr;
    }

    fn freeArray(self: *FsmRunQueue, arr: *CircularArray) void {
        self.allocator.free(arr.data);
        self.allocator.destroy(arr);
    }

    pub fn deinit(self: *FsmRunQueue) void {
        if (self.array.load(.monotonic)) |arr| self.freeArray(arr);
        for (self.old_arrays.items) |old| self.freeArray(old);
        self.old_arrays.deinit(self.allocator);
    }

    fn grow(self: *FsmRunQueue, b: u32, t: u32) !void {
        const old_arr = self.array.load(.monotonic).?;
        const old_log: u5 = @intCast(@ctz(old_arr.mask + 1));
        const new_arr = try makeArray(self.allocator, old_log + 1);
        var i = t;
        while (i != b) : (i +%= 1) {
            new_arr.data[i & new_arr.mask].store(
                old_arr.data[i & old_arr.mask].load(.monotonic),
                .monotonic,
            );
        }
        errdefer self.freeArray(new_arr);
        try self.old_arrays.append(self.allocator, old_arr);
        self.array.store(new_arr, .release);
    }

    /// Owner only. Append at bottom. Extend array if full.
    pub fn push(self: *FsmRunQueue, alloc: std.mem.Allocator, task: *FsmTask) !void {
        _ = alloc;
        const b = self.bottom.load(.monotonic);
        const t = self.top.load(.acquire);
        var arr = self.array.load(.monotonic).?;
        if (b -% t > arr.mask) {
            try self.grow(b, t);
            arr = self.array.load(.monotonic).?;
        }
        arr.data[b & arr.mask].store(task, .monotonic);
        self.bottom.store(b +% 1, .release);
    }

    /// Owner only. Remove from bottom. Returns null when empty.
    pub fn pop(self: *FsmRunQueue) ?*FsmTask {
        const b = self.bottom.load(.monotonic);
        const t_check = self.top.load(.monotonic);
        if (b -% t_check == 0) return null;
        const new_b = b -% 1;
        self.bottom.store(new_b, .seq_cst);
        const t = self.top.load(.seq_cst);
        const arr = self.array.load(.monotonic).?;
        const task = arr.data[new_b & arr.mask].load(.monotonic);
        const size = new_b -% t;
        if (size > arr.mask) {
            self.bottom.store(b, .monotonic);
            return null;
        }
        if (t == new_b) {
            if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic) != null) {
                self.bottom.store(t +% 1, .monotonic);
                return null;
            }
            self.bottom.store(t +% 1, .monotonic);
            return task;
        }
        return task;
    }

    /// Approximate length. Safe to call from any thread.
    pub fn len(self: *const FsmRunQueue) usize {
        const b = self.bottom.load(.monotonic);
        const t = self.top.load(.monotonic);
        return b -% t;
    }

    /// Thief only. Remove from top with a CAS. Returns null if empty or
    /// a concurrent stealer/popper won the race.
    pub fn stealOne(self: *FsmRunQueue) ?*FsmTask {
        const t = self.top.load(.acquire);
        const b = self.bottom.load(.seq_cst);
        const arr = self.array.load(.acquire) orelse return null;
        const size = b -% t;
        if (size == 0 or size > arr.mask) return null;
        const task = arr.data[t & arr.mask].load(.acquire);
        if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic) != null) {
            return null;
        }
        return task;
    }

    /// Thief helper: take ~half of victim's queue into self's queue.
    /// Returns number of tasks stolen.
    pub fn tryStealFrom(self: *FsmRunQueue, victim: *FsmRunQueue, alloc: std.mem.Allocator) usize {
        const v_len = victim.len();
        if (v_len == 0) return 0;
        const target = (v_len + 1) / 2;
        var stolen_count: usize = 0;
        while (stolen_count < target) {
            const task = victim.stealOne() orelse break;
            self.push(alloc, task) catch break;
            stolen_count += 1;
        }
        return stolen_count;
    }
};

// -----------------------------------------------------------------------------
// Dispatch helper (used by the scheduler; exposed for tests)
// -----------------------------------------------------------------------------
//
// Runs the task's resume fn once and applies the returned YieldReason to the
// task's status. The caller is responsible for enqueue / free based on the
// resulting status. Returns the YieldReason so the scheduler can stash the
// waiter pointer when the task blocks.
pub fn dispatchOnce(task: *FsmTask) YieldReason {
    // Clear any previous waiter; a WaitForIO / WaitForLock will set fresh.
    task.waiter = null;
    task.lock_waiter.store(null, .release);
    const reason = task.resume_fn(task);
    switch (reason) {
        .Done => task.status = .Finished,
        .Yielded => task.status = .Ready,
        .WaitForIO => |w| {
            task.status = .Blocked;
            task.waiter = w;
        },
        .WaitForLock => {
            // The resume fn has already set task.lock_waiter via
            // tryLockOrRegister before returning this variant.
            task.status = .Blocked;
        },
    }
    return reason;
}
