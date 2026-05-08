// alloc-profile.zig -- Allocation site tracker for `clear profile`.
//
// Records allocation stack traces via std.debug.captureStackTrace, hashed
// across the full trace so distinct call paths to the same helper resolve
// as separate sites. Zero overhead when profiling is not built in
// (comptime branch elimination at the call sites). Fixed-size open-
// addressed hash table -- no allocations inside the profiler.
//
// Sampling: `CLEAR_PROFILE_SAMPLE=N` (set by `clear profile --sample=N`)
// records every Nth call. Default N=1 (no sampling). Sampled values are
// scaled by N at record time so pprof / doctor see estimated totals.

const std = @import("std");
const compat = @import("../lib/compat.zig");
const SpinLock = @import("profile-lock.zig").SpinLock;

// Profile-table size; shared default with lock-profile / mvcc-profile.
// `clear profile --profile-max=N` injects the override into the
// transpiled root via `CLEAR_PROFILE_MAX_TABLE_ENTRIES`. See
// mvcc-profile.zig for the full comment block.
pub const MAX_SITES: usize = if (@hasDecl(@import("root"), "CLEAR_PROFILE_MAX_TABLE_ENTRIES"))
    @import("root").CLEAR_PROFILE_MAX_TABLE_ENTRIES
else
    1024;

// Maximum frames captured per stack. 16 matches the default depth
// `perf record -g` walks on x86. 128 bytes per Site, vs the 8 we used
// to cost. With MAX_SITES=1024 the table grows from ~40 KB to ~172 KB
// — comfortably small relative to the Large (60 KB) profile-build
// fiber stacks. The trace buffer at the call site is `[16]usize` ==
// 128 B on the recorder's stack; the FP walk reads but doesn't push
// new frames.
pub const MAX_FRAMES: u8 = 16;

const Site = struct {
    // The captured stack, leaf-first. addrs[0] is closest to the alloc
    // site. addr_count == 0 means the slot is empty (a real captured
    // trace always has at least the leaf frame).
    addrs: [MAX_FRAMES]usize = [_]usize{0} ** MAX_FRAMES,
    addr_count: u8 = 0,
    alloc_count: u64 = 0,
    alloc_bytes: u64 = 0,
    free_count: u64 = 0,
    free_bytes: u64 = 0,
};

var sites: [MAX_SITES]Site = [_]Site{.{}} ** MAX_SITES;
var total_allocs: u64 = 0;
var total_bytes: u64 = 0;
var mu: SpinLock = .{};

// Counts findSlot() calls that hit the saturated table. Surfaced
// in the dump as a `# WARNING:` header so doctor can advise the
// user to bump --profile-max=N. See mvcc-profile.zig for rationale.
var dropped_samples: u64 = 0;

// Sample stride. Read once from CLEAR_PROFILE_SAMPLE on the first
// recordAlloc call (always under `mu`, so no atomics needed). 0 is
// the uninitialized sentinel; 1 means no sampling.
var sample_n: u64 = 0;
var sample_counter: u64 = 0;

fn ensureSampleN() void {
    if (sample_n != 0) return;
    if (std.c.getenv("CLEAR_PROFILE_SAMPLE")) |env| {
        const slc = std.mem.span(env);
        const n = std.fmt.parseInt(u64, slc, 10) catch 1;
        sample_n = if (n == 0) 1 else n;
    } else {
        sample_n = 1;
    }
}

// Hash a captured stack trace. fnv-1a-style mixing of the addresses
// keeps the cost ~constant in the trace length and gives reasonable
// dispersion for our open-addressed table.
fn hashTrace(addrs: []const usize) usize {
    var h: usize = 0xcbf29ce484222325;
    for (addrs) |a| {
        h ^= a;
        h *%= 0x9E3779B97F4A7C15;
    }
    return h;
}

fn tracesEqual(slot: *const Site, addrs: []const usize) bool {
    if (slot.addr_count != addrs.len) return false;
    for (addrs, 0..) |a, i| {
        if (slot.addrs[i] != a) return false;
    }
    return true;
}

fn findSlot(addrs: []const usize) ?*Site {
    if (addrs.len == 0) return null;
    const hash = hashTrace(addrs);
    var idx = hash & (MAX_SITES - 1);
    var probes: usize = 0;
    while (probes < MAX_SITES) : (probes += 1) {
        const slot = &sites[idx];
        if (slot.addr_count == 0) {
            // Empty: claim it. Copy up to MAX_FRAMES; a real captured
            // trace has been clamped already, but guard anyway.
            const n: u8 = @intCast(@min(addrs.len, MAX_FRAMES));
            for (0..n) |i| slot.addrs[i] = addrs[i];
            slot.addr_count = n;
            return slot;
        }
        if (tracesEqual(slot, addrs)) return slot;
        idx = (idx + 1) & (MAX_SITES - 1);
    }
    dropped_samples += 1;
    return null;
}

// Capture a stack trace starting one frame above the caller (so the
// recorder itself does not appear in the trace). The buffer lives on
// the caller's stack -- 128 B at MAX_FRAMES=16. Returns the actual
// number of frames written into `addrs`.
fn captureFromHere(first_addr: usize, addrs: *[MAX_FRAMES]usize) u8 {
    const trace = std.debug.captureCurrentStackTrace(
        .{ .first_address = first_addr },
        addrs,
    );
    return @intCast(@min(trace.return_addresses.len, MAX_FRAMES));
}

pub fn totalAllocs() u64 {
    return total_allocs;
}

pub fn totalBytes() u64 {
    return total_bytes;
}

pub fn recordAlloc(ret_addr: usize, size: usize) void {
    var trace_buf: [MAX_FRAMES]usize = undefined;
    const n = captureFromHere(ret_addr, &trace_buf);

    mu.lock();
    defer mu.unlock();

    ensureSampleN();
    total_allocs += 1;
    total_bytes += size;

    // Drop all but every sample_n-th sample. Counter is incremented
    // unconditionally so even sampled-out allocs contribute to
    // total_allocs / total_bytes (the header reflects the full run).
    sample_counter +%= 1;
    if (sample_n > 1 and (sample_counter % sample_n) != 0) return;

    if (n == 0) return; // FP walk failed -- keep totals, drop site

    if (findSlot(trace_buf[0..n])) |site| {
        // Scale by sample_n so per-site totals approximate the real
        // distribution at the cost of one multiply per recorded sample.
        site.alloc_count += sample_n;
        site.alloc_bytes += size * sample_n;
    }
}

pub fn recordFree(ret_addr: usize, size: usize) void {
    var trace_buf: [MAX_FRAMES]usize = undefined;
    const n = captureFromHere(ret_addr, &trace_buf);

    mu.lock();
    defer mu.unlock();

    ensureSampleN();
    sample_counter +%= 1;
    if (sample_n > 1 and (sample_counter % sample_n) != 0) return;

    if (n == 0) return;

    if (findSlot(trace_buf[0..n])) |site| {
        site.free_count += sample_n;
        site.free_bytes += size * sample_n;
    }
}

pub fn dump() void {
    const path_ptr = std.c.getenv("CLEAR_ALLOC_PROFILE") orelse return;

    const fd = compat.createFileTruncate(path_ptr) catch return;
    defer compat.closeFd(fd);

    mu.lock();
    defer mu.unlock();

    var buf: [4096]u8 = undefined;

    compat.writeAllFd(fd, "# alloc-profile v2 (multi-frame, comma-separated leaf-first)\n") catch return;
    const hdr = std.fmt.bufPrint(&buf, "# total_allocs: {d}\n", .{total_allocs}) catch return;
    compat.writeAllFd(fd, hdr) catch return;
    if (sample_n > 1) {
        const sw = std.fmt.bufPrint(&buf, "# sample_n: {d}\n", .{sample_n}) catch return;
        compat.writeAllFd(fd, sw) catch return;
    }
    if (dropped_samples > 0) {
        const warn = std.fmt.bufPrint(&buf,
            "# WARNING: {d} samples dropped (cap={d}; rebuild with `clear profile --profile-max=N`)\n",
            .{ dropped_samples, MAX_SITES }) catch return;
        compat.writeAllFd(fd, warn) catch return;
    }
    compat.writeAllFd(fd, "# addrs alloc_count alloc_bytes free_count free_bytes live_bytes\n") catch return;

    for (&sites) |*site| {
        if (site.addr_count == 0 or site.alloc_count == 0) continue;
        const live = if (site.alloc_bytes >= site.free_bytes)
            site.alloc_bytes - site.free_bytes
        else
            0;

        // Build the comma-separated addrs field into the line buffer
        // by appending with `bufPrint` and walking a write cursor.
        // With 16 frames at "0x" + 16 hex + ",", worst case is
        // 19*16 = 304 chars. 4 KB buffer covers that plus the
        // count/bytes tail with margin.
        var pos: usize = 0;
        var i: u8 = 0;
        while (i < site.addr_count) : (i += 1) {
            const sep = if (i == 0) "" else ",";
            const slc = std.fmt.bufPrint(buf[pos..], "{s}0x{x}", .{ sep, site.addrs[i] }) catch break;
            pos += slc.len;
        }
        const tail = std.fmt.bufPrint(buf[pos..], " {d} {d} {d} {d} {d}\n", .{
            site.alloc_count,
            site.alloc_bytes,
            site.free_count,
            site.free_bytes,
            live,
        }) catch continue;
        pos += tail.len;
        compat.writeAllFd(fd, buf[0..pos]) catch return;
    }
}
