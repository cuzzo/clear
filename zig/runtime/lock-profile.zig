// lock-profile.zig — ParkingMutex wait + hold time telemetry.
//
// Zero overhead when CLEAR_PROFILE == false; every call site in
// parking-lot.zig is wrapped with `if (rt_profile.CLEAR_PROFILE)`.
//
// Per-lock stats are keyed by mutex address (open-addressed hash like
// alloc-profile). Each lock gets its own entry in the hash; profile
// data is stored by value in the table so stats survive the mutex's
// lifetime — the registered entry is never revoked.
//
// Counters are plain u64 (not atomic): under concurrent recordAcquire
// the counts can be slightly low under tearing. Acceptable for profile
// data — the same relaxed approach `alloc-profile.zig` uses for total
// allocs. The categorization bucketing still works because the
// lost-update rate is tiny vs. sample volume.

const std = @import("std");
const compat = @import("../lib/compat.zig");

pub const MAX_LOCKS: usize = 1024;

pub const LockStats = struct {
    addr: usize = 0,          // mutex pointer; 0 = empty slot
    acquires: u64 = 0,        // successful lock() completions
    total_wait_ns: u64 = 0,   // sum of wait durations across acquires
    max_wait_ns: u64 = 0,
    total_hold_ns: u64 = 0,   // sum of (unlock - acquire) durations
    max_hold_ns: u64 = 0,
    contended_acquires: u64 = 0,  // acquires that took the slow path
};

var stats: [MAX_LOCKS]LockStats = [_]LockStats{.{}} ** MAX_LOCKS;

pub inline fn now() u64 {
    return compat.nanoTimestamp();
}

fn findSlot(addr: usize) ?*LockStats {
    // Fibonacci-style multiplicative hash — same recipe as alloc-profile.
    const hash = addr *% 0x9E3779B97F4A7C15;
    var idx: usize = @intCast(hash & (MAX_LOCKS - 1));
    var probes: usize = 0;
    while (probes < MAX_LOCKS) : (probes += 1) {
        if (stats[idx].addr == addr) return &stats[idx];
        if (stats[idx].addr == 0) {
            stats[idx].addr = addr;
            return &stats[idx];
        }
        idx = (idx + 1) & (MAX_LOCKS - 1);
    }
    return null; // table saturated — silently drop the sample
}

pub inline fn recordAcquire(addr: usize, wait_ns: u64, contended: bool) void {
    if (findSlot(addr)) |s| {
        s.acquires += 1;
        s.total_wait_ns += wait_ns;
        if (wait_ns > s.max_wait_ns) s.max_wait_ns = wait_ns;
        if (contended) s.contended_acquires += 1;
    }
}

pub inline fn recordRelease(addr: usize, hold_ns: u64) void {
    if (findSlot(addr)) |s| {
        s.total_hold_ns += hold_ns;
        if (hold_ns > s.max_hold_ns) s.max_hold_ns = hold_ns;
    }
}

pub fn dumpToEnvFile() void {
    const path_ptr = std.c.getenv("CLEAR_LOCK_PROFILE") orelse return;
    const fd = compat.createFileTruncate(path_ptr) catch return;
    defer compat.closeFd(fd);

    var buf: [256]u8 = undefined;
    _ = compat.writeAllFd(fd, "# lock-profile v1\n") catch return;
    _ = compat.writeAllFd(fd,
        "# addr\tacquires\tcontended\ttotal_wait_ns\tmax_wait_ns\ttotal_hold_ns\tmax_hold_ns\n")
    catch return;

    for (&stats) |*s| {
        if (s.addr == 0 or s.acquires == 0) continue;
        const line = std.fmt.bufPrint(&buf,
            "0x{x}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
            .{
                s.addr, s.acquires, s.contended_acquires,
                s.total_wait_ns, s.max_wait_ns,
                s.total_hold_ns, s.max_hold_ns,
            })
        catch continue;
        _ = compat.writeAllFd(fd, line) catch return;
    }
}
