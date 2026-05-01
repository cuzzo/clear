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

// Profile-table size; shared default with alloc-profile / mvcc-profile.
// `clear profile --profile-max=N` injects the override into the
// transpiled root via `CLEAR_PROFILE_MAX_TABLE_ENTRIES`. See
// mvcc-profile.zig for the full comment block.
pub const MAX_LOCKS: usize = if (@hasDecl(@import("root"), "CLEAR_PROFILE_MAX_TABLE_ENTRIES"))
    @import("root").CLEAR_PROFILE_MAX_TABLE_ENTRIES
else
    1024;

pub const LockStats = struct {
    addr: usize = 0,          // mutex pointer; 0 = empty slot
    acquires: u64 = 0,        // successful WRITE-mode lock() / write-lock() / mutex-lock() completions
    total_wait_ns: u64 = 0,   // sum of wait durations across write-mode acquires
    max_wait_ns: u64 = 0,
    total_hold_ns: u64 = 0,   // sum of (unlock - acquire) write-mode durations
    max_hold_ns: u64 = 0,
    contended_acquires: u64 = 0,  // write acquires that took the slow path

    // Read-side counters (RwLock only). lockShared / tryReadLockForFsm
    // path. Used by `clear doctor` to compute the read-vs-write split
    // that decides whether to recommend `@shared:versioned` (MVCC).
    // Read holds are not tracked: with N concurrent readers a single
    // hold timer is meaningless. For MVCC fit, the read FREQUENCY +
    // wait pressure are what matter.
    read_acquires: u64 = 0,
    read_total_wait_ns: u64 = 0,
    read_max_wait_ns: u64 = 0,
    read_contended_acquires: u64 = 0,
};

var stats: [MAX_LOCKS]LockStats = [_]LockStats{.{}} ** MAX_LOCKS;

// Counts findSlot() calls that hit the saturated table. Surfaced
// in the dump as a `# WARNING:` header so doctor can advise the
// user to bump --profile-max=N. See mvcc-profile.zig for rationale.
var dropped_samples: u64 = 0;

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
    dropped_samples += 1;
    return null; // table saturated — bump CLEAR_PROFILE_MAX_TABLE_ENTRIES
}

pub inline fn recordAcquire(addr: usize, wait_ns: u64, contended: bool) void {
    if (findSlot(addr)) |s| {
        s.acquires += 1;
        s.total_wait_ns += wait_ns;
        if (wait_ns > s.max_wait_ns) s.max_wait_ns = wait_ns;
        if (contended) s.contended_acquires += 1;
    }
}

/// Read-side acquire on a ParkingRwLock. Same shape as recordAcquire
/// but stored in the read counters so doctor can compute read/write
/// split (read-heavy → recommend @shared:versioned).
pub inline fn recordReadAcquire(addr: usize, wait_ns: u64, contended: bool) void {
    if (findSlot(addr)) |s| {
        s.read_acquires += 1;
        s.read_total_wait_ns += wait_ns;
        if (wait_ns > s.read_max_wait_ns) s.read_max_wait_ns = wait_ns;
        if (contended) s.read_contended_acquires += 1;
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

    var buf: [512]u8 = undefined;
    _ = compat.writeAllFd(fd, "# lock-profile v2\n") catch return;
    if (dropped_samples > 0) {
        const warn = std.fmt.bufPrint(&buf,
            "# WARNING: {d} samples dropped (cap={d}; rebuild with `clear profile --profile-max=N`)\n",
            .{ dropped_samples, MAX_LOCKS }) catch return;
        _ = compat.writeAllFd(fd, warn) catch return;
    }
    _ = compat.writeAllFd(fd,
        "# addr\tacquires\tcontended\ttotal_wait_ns\tmax_wait_ns\ttotal_hold_ns\tmax_hold_ns" ++
        "\tread_acquires\tread_contended\tread_total_wait_ns\tread_max_wait_ns\n")
    catch return;

    for (&stats) |*s| {
        if (s.addr == 0) continue;
        if (s.acquires == 0 and s.read_acquires == 0) continue;
        const line = std.fmt.bufPrint(&buf,
            "0x{x}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
            .{
                s.addr, s.acquires, s.contended_acquires,
                s.total_wait_ns, s.max_wait_ns,
                s.total_hold_ns, s.max_hold_ns,
                s.read_acquires, s.read_contended_acquires,
                s.read_total_wait_ns, s.read_max_wait_ns,
            })
        catch continue;
        _ = compat.writeAllFd(fd, line) catch return;
    }
}
