// mvcc-profile.zig — `Versioned(T)` cell telemetry: reads, commits,
// retries, COW byte volume.
//
// Zero overhead when CLEAR_PROFILE == false. Default keying: cell pointer
// (one row per Versioned cell). With `clear profile --sync-callstacks`,
// each (cell, caller-trace) pair becomes its own row, so the dump shows
// which call site reads/commits which cell. The flag is off by default
// because the FP walk costs ~100-500ns per record; an MVCC commit fast
// path is ~20-50ns, so the trace can dominate. `--sample=N` composes
// (record every Nth event, scale by N at record time).
//
// Why MVCC needs its own profile (not lock-profile): MVCC has no
// lock. The interesting numbers are different:
//   - read count (and how it compares to commits) tells us if MVCC's
//     lock-free read path is actually paying off
//   - commit count + struct size = COW byte volume; if writers are
//     copying GBs per second, the binding belongs in `@indirect` so
//     the CAS payload is a pointer-swap instead of a struct-copy
//   - retry count tells us how often writers race; high retries
//     mean MVCC isn't a fit (writer-heavy)
//
// Used by `clear doctor` (Tranche C) to recommend `@indirect` for COW
// thrash and `@shared:writeLocked` / `@shared:locked` for write-heavy
// MVCC misuse.

const std = @import("std");
const compat = @import("../lib/compat.zig");
const SpinLock = @import("profile-lock.zig").SpinLock;
const profile_trace = @import("profile-trace.zig");

// Profile-table size, shared across alloc-profile / lock-profile /
// mvcc-profile via a single root-level override knob. Default 1024
// is plenty for typical CLEAR programs (10s-100s of distinct cells/
// sites/locks). The `clear profile --profile-max=N` flag injects
// `pub const CLEAR_PROFILE_MAX_TABLE_ENTRIES = N;` into the
// transpiled root for users with larger working sets.
//
// Must be a power of two: the open-addressed hash uses `& (N-1)`
// for slot indexing. The build-side wiring in clear validates this.
pub const MAX_CELLS: usize = if (@hasDecl(@import("root"), "CLEAR_PROFILE_MAX_TABLE_ENTRIES"))
    @import("root").CLEAR_PROFILE_MAX_TABLE_ENTRIES
else
    1024;

pub const CellStats = struct {
    addr: usize = 0,            // Versioned(T) cell pointer; 0 = empty slot
    struct_size: u32 = 0,       // @sizeOf(T) -- captured on first record so
                                // doctor can compute total COW bytes without
                                // needing the comptime T at consumption time.
    reads: u64 = 0,             // successful read() calls
    commits: u64 = 0,           // successful update() commits (single-cell)
    multi_commits: u64 = 0,     // successful updateMulti() commits where
                                // this cell participated. If commits > 0 AND
                                // multi_commits == 0, the cell only does single-cell
                                // whole-struct commits and is upgrade-eligible.
    retries: u64 = 0,           // CAS failures inside update() (excludes the
                                // final success). Per-update retry counts add
                                // here: 0 for fast-path-success, N for
                                // contended commits.
    update_failures: u64 = 0,   // returned UpdateRetriesExhausted (gave up)

    // Caller stack captured at first record into this slot. Empty
    // (caller_trace_count == 0) when --sync-callstacks is off, in
    // which case the slot's identity is just `addr`. Leaf-first.
    caller_trace: [profile_trace.MAX_FRAMES]usize = [_]usize{0} ** profile_trace.MAX_FRAMES,
    caller_trace_count: u8 = 0,
};

var stats: [MAX_CELLS]CellStats = [_]CellStats{.{}} ** MAX_CELLS;
var mu: SpinLock = .{};

// Counts findSlot() calls that hit the saturated table and had to
// drop the sample. Surfaced in the dump as a `# WARNING:` header
// so `clear doctor` can advise the user to bump --profile-max=N.
// Plain u64; same relaxed-tearing rationale as the per-cell counters.
var dropped_samples: u64 = 0;

// Sample stride snapshot. Read once on first record call (under `mu`,
// no atomic needed) and reused thereafter. 0 = uninitialized sentinel.
var sample_n: u64 = 0;
var sample_counter: u64 = 0;

fn ensureSampleN() void {
    if (sample_n != 0) return;
    sample_n = profile_trace.sampleStride();
}

fn hashKey(addr: usize, trace: []const usize) usize {
    var h: usize = addr *% 0x9E3779B97F4A7C15;
    for (trace) |a| {
        h ^= a;
        h *%= 0x9E3779B97F4A7C15;
    }
    return h;
}

fn keyMatches(slot: *const CellStats, addr: usize, trace: []const usize) bool {
    if (slot.addr != addr) return false;
    if (slot.caller_trace_count != trace.len) return false;
    for (trace, 0..) |a, i| {
        if (slot.caller_trace[i] != a) return false;
    }
    return true;
}

fn findSlot(addr: usize, struct_size: u32, trace: []const usize) ?*CellStats {
    const hash = hashKey(addr, trace);
    var idx: usize = @intCast(hash & (MAX_CELLS - 1));
    var probes: usize = 0;
    while (probes < MAX_CELLS) : (probes += 1) {
        const slot = &stats[idx];
        if (slot.addr == 0 and slot.caller_trace_count == 0) {
            slot.addr = addr;
            slot.struct_size = struct_size;
            const n: u8 = @intCast(@min(trace.len, profile_trace.MAX_FRAMES));
            for (0..n) |i| slot.caller_trace[i] = trace[i];
            slot.caller_trace_count = n;
            return slot;
        }
        if (keyMatches(slot, addr, trace)) return slot;
        idx = (idx + 1) & (MAX_CELLS - 1);
    }
    dropped_samples += 1;
    return null;
}

fn captureCallerTrace(
    ret_addr: usize,
    buf: *[profile_trace.MAX_FRAMES]usize,
) []const usize {
    if (!profile_trace.syncCallstacksEnabled()) return &.{};
    const n = profile_trace.captureFromHere(ret_addr, buf);
    return buf[0..n];
}

fn shouldSample() bool {
    sample_counter +%= 1;
    return sample_n <= 1 or (sample_counter % sample_n) == 0;
}

pub noinline fn recordRead(addr: usize, struct_size: u32) void {
    var trace_buf: [profile_trace.MAX_FRAMES]usize = undefined;
    const trace = captureCallerTrace(@returnAddress(), &trace_buf);

    mu.lock();
    defer mu.unlock();
    ensureSampleN();
    if (!shouldSample()) return;

    if (findSlot(addr, struct_size, trace)) |s| {
        s.reads += sample_n;
    }
}

/// Records a single `update()` outcome. `retries` is the count of
/// CAS failures inside the update before the eventual success
/// (0 for fast-path commits). `committed` distinguishes a winning
/// commit from a bailed-out UpdateRetriesExhausted.
pub noinline fn recordUpdate(addr: usize, struct_size: u32, retries: u64, committed: bool) void {
    var trace_buf: [profile_trace.MAX_FRAMES]usize = undefined;
    const trace = captureCallerTrace(@returnAddress(), &trace_buf);

    mu.lock();
    defer mu.unlock();
    ensureSampleN();
    if (!shouldSample()) return;

    if (findSlot(addr, struct_size, trace)) |s| {
        s.retries += retries * sample_n;
        if (committed) {
            s.commits += sample_n;
        } else {
            s.update_failures += sample_n;
        }
    }
}

/// Record a successful `updateMulti()` commit touching this cell.
/// The cell's `multi_commits` increments per participating cell; the doctor uses
/// `multi_commits == 0 && commits > 0` as the gate for the
/// "upgrade @shared:versioned -> @indirect:atomic" suggestion
/// (multi-cell commits forbid the upgrade because AtomicPtr has
/// no multi-pointer CAS).
pub noinline fn recordMultiCommit(addr: usize, struct_size: u32) void {
    var trace_buf: [profile_trace.MAX_FRAMES]usize = undefined;
    const trace = captureCallerTrace(@returnAddress(), &trace_buf);

    mu.lock();
    defer mu.unlock();
    ensureSampleN();
    if (!shouldSample()) return;

    if (findSlot(addr, struct_size, trace)) |s| {
        s.multi_commits += sample_n;
    }
}

pub fn dumpToEnvFile() void {
    const path_ptr = std.c.getenv("CLEAR_MVCC_PROFILE") orelse return;
    const fd = compat.createFileTruncate(path_ptr) catch return;
    defer compat.closeFd(fd);

    mu.lock();
    defer mu.unlock();

    var buf: [4096]u8 = undefined;
    _ = compat.writeAllFd(fd, "# mvcc-profile v2\n") catch return;
    if (sample_n > 1) {
        const sw = std.fmt.bufPrint(&buf, "# sample_n: {d}\n", .{sample_n}) catch return;
        _ = compat.writeAllFd(fd, sw) catch return;
    }
    if (dropped_samples > 0) {
        const warn = std.fmt.bufPrint(&buf,
            "# WARNING: {d} samples dropped (cap={d}; rebuild with `clear profile --profile-max=N`)\n",
            .{ dropped_samples, MAX_CELLS }) catch return;
        _ = compat.writeAllFd(fd, warn) catch return;
    }
    _ = compat.writeAllFd(fd,
        "# addr\tstruct_size\treads\tcommits\tretries\tupdate_failures\tmulti_commits\tcaller_trace\n")
    catch return;

    for (&stats) |*s| {
        if (s.addr == 0 and s.caller_trace_count == 0) continue;
        if (s.reads == 0 and s.commits == 0 and s.update_failures == 0 and s.multi_commits == 0) continue;

        const head = std.fmt.bufPrint(&buf,
            "0x{x}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t",
            .{ s.addr, s.struct_size, s.reads, s.commits, s.retries, s.update_failures, s.multi_commits })
        catch continue;
        _ = compat.writeAllFd(fd, head) catch return;

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
