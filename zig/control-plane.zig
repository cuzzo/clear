// control-plane.zig — Runtime Control Plane
//
// Adaptive runtime policies that operate LIVE while the program runs.
// No logging-and-suggest — these take effect immediately.
//
// OnOverflow:  When a task's stack overflows (__morestack fires),
//              upsize all future tasks of the same class.
//
// OnUnderflow: When a task completes using far less stack than
//              allocated, downsize future tasks to save memory.
//              Conservative: requires many completions before acting.
//
// Architecture:
//   A fixed-size, lock-free hash table keyed by function pointer.
//   O(1) per spawn (lookup), O(1) per overflow/completion (CAS).
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

pub const UnderflowPolicy = enum {
    /// Auto-downsize future tasks of the same class (default).
    downsize,
    /// Log but don't change sizing.
    log,
    /// Do nothing.
    ignore,
};

pub const ControlPlane = struct {
    on_overflow: OverflowPolicy = .upsize,
    on_underflow: UnderflowPolicy = .downsize,

    /// Number of 1-tier underflows before downsizing by 1.
    /// (Task used < 50% of its tier's capacity.)
    underflow_1tier_threshold: u32 = 100_000,

    /// Number of 2-tier underflows before downsizing by 2.
    /// (Task used < 25% of its tier's capacity — e.g. Large but only needed Micro.)
    underflow_2tier_threshold: u32 = 10_000,
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

const NO_RECOMMENDATION: u8 = 0xFF;

const Entry = struct {
    /// Function pointer (0 = empty slot).
    fn_addr: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// Recommended StackSize ordinal, or NO_RECOMMENDATION (0xFF) if unset.
    recommended: std.atomic.Value(u8) = std.atomic.Value(u8).init(NO_RECOMMENDATION),
    /// Number of overflows seen.
    overflow_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Underflow counters: task used < 50% of tier (1-tier) or < 25% (2-tier).
    underflow_1tier: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    underflow_2tier: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// True when the recommendation was set by a downsize (not an upsize).
    downsized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

var registry: [REGISTRY_SIZE]Entry = [_]Entry{.{}} ** REGISTRY_SIZE;

const fm = @import("fiber-memory.zig");

/// Bump a StackSize up one tier.  XL stays at XL.
fn nextSize(size: StackSize) StackSize {
    return switch (size) {
        .Micro => .Standard,
        .Standard => .Large,
        .Large => .Xl,
        .Xl => .Xl,
    };
}

/// Drop a StackSize down one tier.  Micro stays at Micro.
fn prevSize(size: StackSize) StackSize {
    return switch (size) {
        .Micro => .Micro,
        .Standard => .Micro,
        .Large => .Standard,
        .Xl => .Large,
    };
}

/// Byte size for a StackSize tier.
fn tierBytes(size: StackSize) usize {
    return switch (size) {
        .Micro => fm.MICRO_STACK_SIZE,
        .Standard => fm.STANDARD_STACK_SIZE,
        .Large => fm.LARGE_STACK_SIZE,
        .Xl => fm.XL_STACK_SIZE,
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
            // Already tracked.  Bump recommendation upward.
            while (true) {
                const old = entry.recommended.load(.monotonic);
                if (old != NO_RECOMMENDATION and old >= new_ord) break;
                if (entry.recommended.cmpxchgWeak(
                    old,
                    new_ord,
                    .release,
                    .monotonic,
                )) |_| continue else break;
            }
            entry.downsized.store(false, .release); // Overflow overrides any downsize.
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
/// Returns the recommended size from the registry if one exists,
/// otherwise the requested size.  The registry is updated by both
/// overflow (upsize) and underflow (downsize) — it represents the
/// control plane's best estimate for this task class.
pub fn recommendSize(fn_addr: usize, requested: StackSize) StackSize {
    if (fn_addr == 0) return requested;

    const entry = findEntry(fn_addr) orelse return requested;
    const rec_ord = entry.recommended.load(.acquire);

    if (rec_ord == NO_RECOMMENDATION) return requested; // No recommendation yet.

    const rec: StackSize = @enumFromInt(rec_ord);

    // The recommendation is the control plane's best estimate.
    // Overflow pushes it up; underflow pushes it down.
    // Always honor it: if it's higher than requested, upsize;
    // if it's lower, downsize.  Both policies must be enabled.
    if (@intFromEnum(rec) > @intFromEnum(requested)) {
        return if (config.on_overflow == .upsize) rec else requested;
    }
    if (@intFromEnum(rec) < @intFromEnum(requested)) {
        // Only honor a lower recommendation if it came from a downsize
        // (not from an overflow at a smaller tier).
        return if (config.on_underflow == .downsize and entry.downsized.load(.acquire)) rec else requested;
    }

    return requested;
}

// ── OnUnderflow ──────────────────────────────────────────────────

/// Measure stack high-water mark by scanning the 0xCC fill pattern.
/// Returns bytes actually used (from the top of the stack downward).
/// Called on task completion before the stack is freed.
pub fn measureStackUsage(stack_mem: []u8) usize {
    // Fiber.init fills the stack with 0xCC.  Scan from the bottom
    // (low address) upward, counting untouched bytes.
    var untouched: usize = 0;
    for (stack_mem) |byte| {
        if (byte != 0xCC) break;
        untouched += 1;
    }
    return stack_mem.len - untouched;
}

/// Called by the scheduler when a task finishes.
/// Checks whether the task used significantly less stack than its
/// tier provides.  If so, increments underflow counters.  When a
/// counter crosses the threshold, the recommendation is downsized.
///
/// `fn_addr`: the task's function pointer.
/// `size_class`: the StackSize tier the task ran at.
/// `bytes_used`: from measureStackUsage().
pub fn recordCompletion(fn_addr: usize, size_class: StackSize, bytes_used: usize) void {
    if (config.on_underflow == .ignore) return;
    if (fn_addr == 0) return;
    if (size_class == .Micro) return; // Can't downsize below Micro.

    const tier_size = tierBytes(size_class);
    const half = tier_size / 2;
    const quarter = tier_size / 4;

    // Determine underflow severity.
    const is_2tier = bytes_used < quarter; // used < 25% → could go 2 tiers down
    const is_1tier = !is_2tier and bytes_used < half; // used < 50% → could go 1 tier down

    if (!is_1tier and !is_2tier) return; // No underflow.

    // Find or create an entry for this function.
    const entry = findOrCreateEntry(fn_addr) orelse return;

    if (is_2tier) {
        const count = entry.underflow_2tier.fetchAdd(1, .monotonic) + 1;
        if (count == config.underflow_2tier_threshold) {
            // Downsize by 2 tiers.
            const target = prevSize(prevSize(size_class));
            applyDownsize(entry, target, fn_addr);
        }
    } else {
        const count = entry.underflow_1tier.fetchAdd(1, .monotonic) + 1;
        if (count == config.underflow_1tier_threshold) {
            // Downsize by 1 tier.
            const target = prevSize(size_class);
            applyDownsize(entry, target, fn_addr);
        }
    }
}

fn applyDownsize(entry: *Entry, target: StackSize, fn_addr: usize) void {
    const target_ord = @intFromEnum(target);

    // Update recommendation to the downsized target.
    while (true) {
        const old = entry.recommended.load(.monotonic);
        // If recommendation is already at or below target (and is set), nothing to do.
        if (old != NO_RECOMMENDATION and old <= target_ord) break;
        if (entry.recommended.cmpxchgWeak(old, target_ord, .release, .monotonic)) |_|
            continue
        else {
            // Mark as downsized and reset counters.
            entry.downsized.store(true, .release);
            entry.underflow_1tier.store(0, .release);
            entry.underflow_2tier.store(0, .release);

            if (config.on_underflow == .log) {
                std.debug.print(
                    "[control-plane] underflow downsize fn 0x{x}: recommend {s}\n",
                    .{ fn_addr, @tagName(target) },
                );
            }
            break;
        }
    }
}

// ── Registry helpers ─────────────────────────────────────────────

fn findEntry(fn_addr: usize) ?*Entry {
    const start = hashFn(fn_addr);
    var i: usize = 0;
    while (i < REGISTRY_SIZE) : (i += 1) {
        const idx = (start + i) % REGISTRY_SIZE;
        const entry = &registry[idx];
        const existing = entry.fn_addr.load(.acquire);
        if (existing == fn_addr) return entry;
        if (existing == 0) return null;
    }
    return null;
}

fn findOrCreateEntry(fn_addr: usize) ?*Entry {
    const start = hashFn(fn_addr);
    var i: usize = 0;
    while (i < REGISTRY_SIZE) : (i += 1) {
        const idx = (start + i) % REGISTRY_SIZE;
        const entry = &registry[idx];
        const existing = entry.fn_addr.load(.acquire);
        if (existing == fn_addr) return entry;
        if (existing == 0) {
            if (entry.fn_addr.cmpxchgWeak(0, fn_addr, .release, .monotonic)) |_| {
                i -= 1; // Retry — someone else claimed it
                continue;
            }
            return entry;
        }
    }
    return null; // Registry full.
}

/// Reset the registry (for testing).
pub fn resetRegistry() void {
    for (&registry) |*entry| {
        entry.fn_addr.store(0, .release);
        entry.recommended.store(NO_RECOMMENDATION, .release);
        entry.overflow_count.store(0, .release);
        entry.underflow_1tier.store(0, .release);
        entry.underflow_2tier.store(0, .release);
        entry.downsized.store(false, .release);
    }
}

/// Get the overflow count for a given function (for testing / diagnostics).
pub fn getOverflowCount(fn_addr: usize) u32 {
    const entry = findEntry(fn_addr) orelse return 0;
    return entry.overflow_count.load(.monotonic);
}

/// Get underflow counts (for testing).
pub fn getUnderflowCounts(fn_addr: usize) struct { tier1: u32, tier2: u32 } {
    const entry = findEntry(fn_addr) orelse return .{ .tier1 = 0, .tier2 = 0 };
    return .{
        .tier1 = entry.underflow_1tier.load(.monotonic),
        .tier2 = entry.underflow_2tier.load(.monotonic),
    };
}
