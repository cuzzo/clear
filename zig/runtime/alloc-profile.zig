// alloc-profile.zig -- Allocation site tracker for `clear profile`.
//
// Records allocation counts and bytes per call site using @returnAddress().
// Zero overhead when CLEAR_PROFILE is not set (comptime branch elimination).
// Fixed-size open-addressed hash table -- no allocations inside the profiler.

const std = @import("std");
const compat = @import("../lib/compat.zig");

const MAX_SITES = 1024;

const Site = struct {
    addr: usize = 0,
    alloc_count: u64 = 0,
    alloc_bytes: u64 = 0,
    free_count: u64 = 0,
    free_bytes: u64 = 0,
};

var sites: [MAX_SITES]Site = [_]Site{.{}} ** MAX_SITES;
var total_allocs: u64 = 0;

fn findSlot(addr: usize) ?*Site {
    const hash = addr *% 0x9E3779B97F4A7C15; // fibonacci hash
    var idx = hash & (MAX_SITES - 1);
    var probes: usize = 0;
    while (probes < MAX_SITES) : (probes += 1) {
        if (sites[idx].addr == addr) return &sites[idx];
        if (sites[idx].addr == 0) {
            sites[idx].addr = addr;
            return &sites[idx];
        }
        idx = (idx + 1) & (MAX_SITES - 1);
    }
    return null; // table full
}

var total_bytes: u64 = 0;

pub fn totalAllocs() u64 {
    return total_allocs;
}

pub fn totalBytes() u64 {
    return total_bytes;
}

pub fn recordAlloc(ret_addr: usize, size: usize) void {
    if (findSlot(ret_addr)) |site| {
        site.alloc_count += 1;
        site.alloc_bytes += size;
    }
    total_allocs += 1;
    total_bytes += size;
}

pub fn recordFree(ret_addr: usize, size: usize) void {
    if (findSlot(ret_addr)) |site| {
        site.free_count += 1;
        site.free_bytes += size;
    }
}

pub fn dump() void {
    // Read output path from env var
    const path_ptr = std.c.getenv("CLEAR_ALLOC_PROFILE") orelse return;

    const fd = compat.createFileTruncate(path_ptr) catch return;
    defer compat.closeFd(fd);

    var buf: [256]u8 = undefined;

    compat.writeAllFd(fd, "# alloc-profile v1\n") catch return;
    const hdr = std.fmt.bufPrint(&buf, "# total_allocs: {d}\n", .{total_allocs}) catch return;
    compat.writeAllFd(fd, hdr) catch return;
    compat.writeAllFd(fd, "# addr alloc_count alloc_bytes free_count free_bytes live_bytes\n") catch return;

    for (&sites) |*site| {
        if (site.addr != 0 and site.alloc_count > 0) {
            const live = if (site.alloc_bytes >= site.free_bytes)
                site.alloc_bytes - site.free_bytes
            else
                0;
            const line = std.fmt.bufPrint(&buf, "0x{x} {d} {d} {d} {d} {d}\n", .{
                site.addr,
                site.alloc_count,
                site.alloc_bytes,
                site.free_count,
                site.free_bytes,
                live,
            }) catch continue;
            compat.writeAllFd(fd, line) catch return;
        }
    }
}
