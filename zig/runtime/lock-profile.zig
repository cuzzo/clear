// lock-profile.zig — ParkingMutex wait + hold time telemetry.
//
// Zero overhead when CLEAR_PROFILE == false; every call site in
// parking-lot.zig is wrapped with `if (rt_profile.CLEAR_PROFILE)`.
//
// Default keying: lock pointer (one row per mutex). With `clear profile
// --sync-callstacks`, each (lock, caller-trace) pair becomes its own row,
// so the dump shows which call site contended for which lock. The flag
// is off by default because the FP walk costs ~100-500ns per record;
// uncontended mutex acquire is ~10-20ns, so the trace can dominate.
// `--sample=N` composes (record every Nth event, scale by N at record
// time). The CLI auto-defaults --sample to 100 when --sync-callstacks
// is set unless the user passes their own value.
//
// Counters are plain u64 (not atomic): under concurrent recordAcquire
// the counts can be slightly low under tearing. Acceptable for profile
// data — the same relaxed approach `alloc-profile.zig` uses for total
// allocs. The categorization bucketing still works because the
// lost-update rate is tiny vs. sample volume.

const std = @import("std");
const compat = @import("../lib/compat.zig");
const SpinLock = @import("profile-lock.zig").SpinLock;
const profile_trace = @import("profile-trace.zig");

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

    // Caller stack captured at first record into this slot. Empty
    // (caller_trace_count == 0) when --sync-callstacks is off, in
    // which case the slot's identity is just `addr`. Leaf-first.
    caller_trace: [profile_trace.MAX_FRAMES]usize = [_]usize{0} ** profile_trace.MAX_FRAMES,
    caller_trace_count: u8 = 0,
};

var stats: [MAX_LOCKS]LockStats = [_]LockStats{.{}} ** MAX_LOCKS;
var mu: SpinLock = .{};

// Counts findSlot() calls that hit the saturated table. Surfaced
// in the dump as a `# WARNING:` header so doctor can advise the
// user to bump --profile-max=N. See mvcc-profile.zig for rationale.
var dropped_samples: u64 = 0;

// Sample stride snapshot. Read once on first record call (under `mu`,
// no atomic needed) and reused thereafter. 0 = uninitialized sentinel.
var sample_n: u64 = 0;
var sample_counter: u64 = 0;

fn ensureSampleN() void {
    if (sample_n != 0) return;
    sample_n = profile_trace.sampleStride();
}

pub inline fn now() u64 {
    return compat.nanoTimestamp();
}

// Mix `addr` (lock pointer) with the optional caller trace into one
// hash. fnv-1a-style; same recipe as alloc-profile's hashTrace.
fn hashKey(addr: usize, trace: []const usize) usize {
    var h: usize = addr *% 0x9E3779B97F4A7C15;
    for (trace) |a| {
        h ^= a;
        h *%= 0x9E3779B97F4A7C15;
    }
    return h;
}

fn keyMatches(slot: *const LockStats, addr: usize, trace: []const usize) bool {
    if (slot.addr != addr) return false;
    if (slot.caller_trace_count != trace.len) return false;
    for (trace, 0..) |a, i| {
        if (slot.caller_trace[i] != a) return false;
    }
    return true;
}

fn findSlot(addr: usize, trace: []const usize) ?*LockStats {
    const hash = hashKey(addr, trace);
    var idx: usize = @intCast(hash & (MAX_LOCKS - 1));
    var probes: usize = 0;
    while (probes < MAX_LOCKS) : (probes += 1) {
        const slot = &stats[idx];
        if (slot.addr == 0 and slot.caller_trace_count == 0) {
            // Empty slot: claim it.
            slot.addr = addr;
            const n: u8 = @intCast(@min(trace.len, profile_trace.MAX_FRAMES));
            for (0..n) |i| slot.caller_trace[i] = trace[i];
            slot.caller_trace_count = n;
            return slot;
        }
        if (keyMatches(slot, addr, trace)) return slot;
        idx = (idx + 1) & (MAX_LOCKS - 1);
    }
    dropped_samples += 1;
    return null;
}

// Captures the caller trace if --sync-callstacks is on; otherwise
// returns an empty slice. The trace buffer is supplied by the caller
// so it lives on the recorder's stack frame.
fn captureCallerTrace(
    ret_addr: usize,
    buf: *[profile_trace.MAX_FRAMES]usize,
) []const usize {
    if (!profile_trace.syncCallstacksEnabled()) return &.{};
    const n = profile_trace.captureFromHere(ret_addr, buf);
    return buf[0..n];
}

// Sampling gate. `sample_counter` is incremented on every call so
// even sampled-out events count for the cadence; the next captured
// sample's values are scaled by `sample_n` so per-row totals match
// estimated reality. Returns true if this call should be recorded.
fn shouldSample() bool {
    sample_counter +%= 1;
    return sample_n <= 1 or (sample_counter % sample_n) == 0;
}

pub noinline fn recordAcquire(addr: usize, wait_ns: u64, contended: bool) void {
    var trace_buf: [profile_trace.MAX_FRAMES]usize = undefined;
    const trace = captureCallerTrace(@returnAddress(), &trace_buf);

    mu.lock();
    defer mu.unlock();

    ensureSampleN();
    if (!shouldSample()) return;

    if (findSlot(addr, trace)) |s| {
        s.acquires += sample_n;
        s.total_wait_ns += wait_ns * sample_n;
        if (wait_ns > s.max_wait_ns) s.max_wait_ns = wait_ns;
        if (contended) s.contended_acquires += sample_n;
    }
}

/// Read-side acquire on a ParkingRwLock. Same shape as recordAcquire
/// but stored in the read counters so doctor can compute read/write
/// split (read-heavy → recommend @shared:versioned).
pub noinline fn recordReadAcquire(addr: usize, wait_ns: u64, contended: bool) void {
    var trace_buf: [profile_trace.MAX_FRAMES]usize = undefined;
    const trace = captureCallerTrace(@returnAddress(), &trace_buf);

    mu.lock();
    defer mu.unlock();

    ensureSampleN();
    if (!shouldSample()) return;

    if (findSlot(addr, trace)) |s| {
        s.read_acquires += sample_n;
        s.read_total_wait_ns += wait_ns * sample_n;
        if (wait_ns > s.read_max_wait_ns) s.read_max_wait_ns = wait_ns;
        if (contended) s.read_contended_acquires += sample_n;
    }
}

pub noinline fn recordRelease(addr: usize, hold_ns: u64) void {
    var trace_buf: [profile_trace.MAX_FRAMES]usize = undefined;
    const trace = captureCallerTrace(@returnAddress(), &trace_buf);

    mu.lock();
    defer mu.unlock();

    ensureSampleN();
    if (!shouldSample()) return;

    if (findSlot(addr, trace)) |s| {
        s.total_hold_ns += hold_ns * sample_n;
        if (hold_ns > s.max_hold_ns) s.max_hold_ns = hold_ns;
    }
}

pub fn dumpToEnvFile() void {
    const path_ptr = std.c.getenv("CLEAR_LOCK_PROFILE") orelse return;
    const fd = compat.createFileTruncate(path_ptr) catch return;
    defer compat.closeFd(fd);

    mu.lock();
    defer mu.unlock();

    var buf: [4096]u8 = undefined;
    _ = compat.writeAllFd(fd, "# lock-profile v3\n") catch return;
    if (sample_n > 1) {
        const sw = std.fmt.bufPrint(&buf, "# sample_n: {d}\n", .{sample_n}) catch return;
        _ = compat.writeAllFd(fd, sw) catch return;
    }
    if (dropped_samples > 0) {
        const warn = std.fmt.bufPrint(&buf,
            "# WARNING: {d} samples dropped (cap={d}; rebuild with `clear profile --profile-max=N`)\n",
            .{ dropped_samples, MAX_LOCKS }) catch return;
        _ = compat.writeAllFd(fd, warn) catch return;
    }
    _ = compat.writeAllFd(fd,
        "# addr\tacquires\tcontended\ttotal_wait_ns\tmax_wait_ns\ttotal_hold_ns\tmax_hold_ns" ++
        "\tread_acquires\tread_contended\tread_total_wait_ns\tread_max_wait_ns\tcaller_trace\n")
    catch return;

    for (&stats) |*s| {
        if (s.addr == 0 and s.caller_trace_count == 0) continue;
        if (s.acquires == 0 and s.read_acquires == 0) continue;

        // Existing 11 columns first.
        const head = std.fmt.bufPrint(&buf,
            "0x{x}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t",
            .{
                s.addr, s.acquires, s.contended_acquires,
                s.total_wait_ns, s.max_wait_ns,
                s.total_hold_ns, s.max_hold_ns,
                s.read_acquires, s.read_contended_acquires,
                s.read_total_wait_ns, s.read_max_wait_ns,
            })
        catch continue;
        _ = compat.writeAllFd(fd, head) catch return;

        // Caller trace (12th column). `-` when empty so column count
        // is constant; comma-separated leaf-first when populated.
        if (s.caller_trace_count == 0) {
            _ = compat.writeAllFd(fd, "-\n") catch return;
        } else {
            var pos: usize = 0;
            var i: u8 = 0;
            while (i < s.caller_trace_count) : (i += 1) {
                const sep = if (i == 0) "" else ",";
                const slc = std.fmt.bufPrint(buf[pos..], "{s}0x{x}", .{ sep, s.caller_trace[i] }) catch break;
                pos += slc.len;
            }
            const tail = std.fmt.bufPrint(buf[pos..], "\n", .{}) catch continue;
            pos += tail.len;
            _ = compat.writeAllFd(fd, buf[0..pos]) catch return;
        }
    }
}
