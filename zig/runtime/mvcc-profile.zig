// mvcc-profile.zig — `Versioned(T)` cell telemetry: reads, commits,
// retries, COW byte volume.
//
// Zero overhead when CLEAR_PROFILE == false. Per-cell stats are keyed
// by cell address (open-addressed hash like alloc-profile and
// lock-profile). Counters are plain u64; the same relaxed-tearing
// rationale as the sibling profile modules applies.
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
                                // this cell participated. AtomicPtr M3.16
                                // doctor signal: if commits > 0 AND
                                // multi_commits == 0, the cell only does
                                // single-cell whole-struct commits and is
                                // upgrade-eligible to @indirect:atomic.
    retries: u64 = 0,           // CAS failures inside update() (excludes the
                                // final success). Per-update retry counts add
                                // here: 0 for fast-path-success, N for
                                // contended commits.
    update_failures: u64 = 0,   // returned UpdateRetriesExhausted (gave up)
};

var stats: [MAX_CELLS]CellStats = [_]CellStats{.{}} ** MAX_CELLS;
var mu: SpinLock = .{};

// Counts findSlot() calls that hit the saturated table and had to
// drop the sample. Surfaced in the dump as a `# WARNING:` header
// so `clear doctor` can advise the user to bump --profile-max=N.
// Plain u64; same relaxed-tearing rationale as the per-cell counters.
var dropped_samples: u64 = 0;

fn findSlot(addr: usize, struct_size: u32) ?*CellStats {
    const hash = addr *% 0x9E3779B97F4A7C15;
    var idx: usize = @intCast(hash & (MAX_CELLS - 1));
    var probes: usize = 0;
    while (probes < MAX_CELLS) : (probes += 1) {
        if (stats[idx].addr == addr) return &stats[idx];
        if (stats[idx].addr == 0) {
            stats[idx].addr = addr;
            stats[idx].struct_size = struct_size;
            return &stats[idx];
        }
        idx = (idx + 1) & (MAX_CELLS - 1);
    }
    dropped_samples += 1;
    return null; // table saturated -- bump CLEAR_PROFILE_MAX_TABLE_ENTRIES
}

pub inline fn recordRead(addr: usize, struct_size: u32) void {
    mu.lock();
    defer mu.unlock();
    if (findSlot(addr, struct_size)) |s| {
        s.reads += 1;
    }
}

/// Records a single `update()` outcome. `retries` is the count of
/// CAS failures inside the update before the eventual success
/// (0 for fast-path commits). `committed` distinguishes a winning
/// commit from a bailed-out UpdateRetriesExhausted.
pub inline fn recordUpdate(addr: usize, struct_size: u32, retries: u64, committed: bool) void {
    mu.lock();
    defer mu.unlock();
    if (findSlot(addr, struct_size)) |s| {
        s.retries += retries;
        if (committed) {
            s.commits += 1;
        } else {
            s.update_failures += 1;
        }
    }
}

/// AtomicPtr M3.16: record a successful `updateMulti()` commit
/// touching this cell. The cell's `multi_commits` increments
/// per participating cell; the doctor uses
/// `multi_commits == 0 && commits > 0` as the gate for the
/// "upgrade @shared:versioned -> @indirect:atomic" suggestion
/// (multi-cell commits forbid the upgrade because AtomicPtr has
/// no multi-pointer CAS).
pub inline fn recordMultiCommit(addr: usize, struct_size: u32) void {
    mu.lock();
    defer mu.unlock();
    if (findSlot(addr, struct_size)) |s| {
        s.multi_commits += 1;
    }
}

pub fn dumpToEnvFile() void {
    const path_ptr = std.c.getenv("CLEAR_MVCC_PROFILE") orelse return;
    const fd = compat.createFileTruncate(path_ptr) catch return;
    defer compat.closeFd(fd);

    mu.lock();
    defer mu.unlock();

    var buf: [256]u8 = undefined;
    _ = compat.writeAllFd(fd, "# mvcc-profile v1\n") catch return;
    if (dropped_samples > 0) {
        const warn = std.fmt.bufPrint(&buf,
            "# WARNING: {d} samples dropped (cap={d}; rebuild with `clear profile --profile-max=N`)\n",
            .{ dropped_samples, MAX_CELLS }) catch return;
        _ = compat.writeAllFd(fd, warn) catch return;
    }
    _ = compat.writeAllFd(fd,
        "# addr\tstruct_size\treads\tcommits\tretries\tupdate_failures\tmulti_commits\n")
    catch return;

    for (&stats) |*s| {
        if (s.addr == 0) continue;
        if (s.reads == 0 and s.commits == 0 and s.update_failures == 0 and s.multi_commits == 0) continue;
        const line = std.fmt.bufPrint(&buf,
            "0x{x}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
            .{ s.addr, s.struct_size, s.reads, s.commits, s.retries, s.update_failures, s.multi_commits })
        catch continue;
        _ = compat.writeAllFd(fd, line) catch return;
    }
}
