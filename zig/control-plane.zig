// control-plane.zig — Runtime Control Plane (v0.1)
//
// Adaptive runtime policies that operate LIVE while the program runs.
// No logging-and-suggest — these take effect immediately.
//
// v0.1: OnOverflow — auto-upsize future tasks when a stack overflows.
//
// Architecture:
//   The overflow registry is a fixed-size, lock-free hash table keyed
//   by function pointer.  When __morestack fires (via __zig_alloc_segment),
//   the current task's function is recorded with a bumped stack size.
//   On subsequent spawns, the scheduler checks the registry and upsizes
//   if a recommendation exists.
//
//   This is O(1) per spawn (hash lookup) and O(1) per overflow (CAS insert).
//   No allocator needed — the registry is a static array.

const std = @import("std");
const fc = @import("fiber-core.zig");
const StackSize = fc.StackSize;

// ── Policy Configuration ─────────────────────────────────────────

pub const OverflowPolicy = enum {
    /// Auto-upsize future tasks of the same class (default).
    upsize,
    /// Log the overflow but don't change sizing.
    log,
    /// Do nothing.
    ignore,
};

pub const ControlPlane = struct {
    on_overflow: OverflowPolicy = .upsize,
};

/// Global control plane instance.  Defaults are sane for production.
pub var config: ControlPlane = .{};

// ── Overflow Registry ────────────────────────────────────────────
// Lock-free open-addressed hash table.  Keyed by user_fn pointer
// (the TaskFn that the scheduler uses to identify task classes).
//
// Capacity: 256 entries.  In practice, programs have far fewer
// distinct task classes (BG blocks).  Linear probing with wrap.

const REGISTRY_SIZE = 256;

const Entry = struct {
    /// Function pointer (0 = empty slot).
    fn_addr: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Recommended StackSize ordinal.  Atomically updated upward.
    recommended: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    /// Number of overflows seen (for diagnostics / future OnUnderflow).
    overflow_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

var registry: [REGISTRY_SIZE]Entry = [_]Entry{.{}} ** REGISTRY_SIZE;

/// Bump a StackSize up one tier.  XL stays at XL.
fn nextSize(size: StackSize) StackSize {
    return switch (size) {
        .Micro => .Standard,
        .Standard => .Large,
        .Large => .Xl,
        .Xl => .Xl,
    };
}

/// Hash a function pointer to a registry index.
fn hashFn(addr: usize) usize {
    // FNV-1a-style mix to spread pointers across the table.
    var h: u64 = 0xcbf29ce484222325;
    h ^= addr;
    h *%= 0x100000001b3;
    return @as(usize, @truncate(h)) % REGISTRY_SIZE;
}

// ── Public API ───────────────────────────────────────────────────

/// Called from __zig_alloc_segment when a stack overflow occurs.
/// Records the overflow and bumps the recommendation for this task class.
///
/// `fn_addr` is the current task's user function pointer (from the
/// __current_task_fn threadlocal set by the scheduler).
/// `current_size` is the task's current StackSize.
pub fn recordOverflow(fn_addr: usize, current_size: StackSize) void {
    if (config.on_overflow == .ignore) return;
    if (fn_addr == 0) return; // No task context (e.g. test harness)

    const new_size = nextSize(current_size);
    const new_ord = @intFromEnum(new_size);

    // Find or claim a slot via linear probing.
    const start = hashFn(fn_addr);
    var i: usize = 0;
    while (i < REGISTRY_SIZE) : (i += 1) {
        const idx = (start + i) % REGISTRY_SIZE;
        const entry = &registry[idx];

        const existing = entry.fn_addr.load(.acquire);

        if (existing == fn_addr) {
            // Already tracked.  Bump recommendation upward (never downward).
            while (true) {
                const old = entry.recommended.load(.monotonic);
                if (old >= new_ord) break; // already at this level or higher
                if (entry.recommended.cmpxchgWeak(
                    old,
                    new_ord,
                    .release,
                    .monotonic,
                )) |_| continue else break;
            }
            _ = entry.overflow_count.fetchAdd(1, .monotonic);

            if (config.on_overflow == .log) {
                std.debug.print(
                    "[control-plane] overflow #{d} for fn 0x{x}: recommend {s}\n",
                    .{
                        entry.overflow_count.load(.monotonic),
                        fn_addr,
                        @tagName(new_size),
                    },
                );
            }
            return;
        }

        if (existing == 0) {
            // Empty slot — try to claim it.
            if (entry.fn_addr.cmpxchgWeak(0, fn_addr, .release, .monotonic)) |_| {
                // Lost the race.  Re-check this slot (might now match).
                i -= 1;
                continue;
            }
            // Claimed.  Set initial recommendation.
            entry.recommended.store(new_ord, .release);
            _ = entry.overflow_count.fetchAdd(1, .monotonic);

            if (config.on_overflow == .log) {
                std.debug.print(
                    "[control-plane] NEW overflow for fn 0x{x}: recommend {s}\n",
                    .{ fn_addr, @tagName(new_size) },
                );
            }
            return;
        }

        // Slot belongs to a different fn — continue probing.
    }
    // Registry full — silently drop.  256 distinct task classes is a lot.
}

/// Called by the scheduler before allocating a stack for a new task.
/// Returns the requested size or a larger one if an overflow was recorded.
pub fn recommendSize(fn_addr: usize, requested: StackSize) StackSize {
    if (config.on_overflow != .upsize) return requested;
    if (fn_addr == 0) return requested;

    const start = hashFn(fn_addr);
    var i: usize = 0;
    while (i < REGISTRY_SIZE) : (i += 1) {
        const idx = (start + i) % REGISTRY_SIZE;
        const entry = &registry[idx];
        const existing = entry.fn_addr.load(.acquire);

        if (existing == fn_addr) {
            const rec: StackSize = @enumFromInt(entry.recommended.load(.acquire));
            // Return the larger of requested and recommended.
            return if (@intFromEnum(rec) > @intFromEnum(requested)) rec else requested;
        }

        if (existing == 0) return requested; // Not in registry.
    }
    return requested; // Registry full, not found.
}

/// Reset the registry (for testing).
pub fn resetRegistry() void {
    for (&registry) |*entry| {
        entry.fn_addr.store(0, .release);
        entry.recommended.store(0, .release);
        entry.overflow_count.store(0, .release);
    }
}

/// Get the overflow count for a given function (for testing / diagnostics).
pub fn getOverflowCount(fn_addr: usize) u32 {
    const start = hashFn(fn_addr);
    var i: usize = 0;
    while (i < REGISTRY_SIZE) : (i += 1) {
        const idx = (start + i) % REGISTRY_SIZE;
        const entry = &registry[idx];
        const existing = entry.fn_addr.load(.acquire);
        if (existing == fn_addr) return entry.overflow_count.load(.monotonic);
        if (existing == 0) return 0;
    }
    return 0;
}
