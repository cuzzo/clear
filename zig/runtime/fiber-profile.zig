// fiber-profile.zig — Fiber lifetime + per-scheduler workstealing balance.
//
// Collected only when `CLEAR_PROFILE == true` (comptime-gated at every
// call site). Normal builds compile this tracking out entirely.
//
// Two telemetry surfaces:
//   - Fiber lifetime: every spawned fiber's (exit_ns - spawn_ns). We
//     keep totals + a "short-lived" bucket for sub-millisecond fibers,
//     which surfaces the classic "micro-fiber overhead" pattern where
//     fiber setup cost dominates the work performed.
//   - Workstealing balance: per-scheduler fibers-run counter. A highly
//     lopsided distribution indicates a single scheduler is doing all
//     the work while others idle — usually a symptom of BG spawn
//     policy choosing the wrong target.

const std = @import("std");
const compat = @import("../lib/compat.zig");
const SpinLock = @import("profile-lock.zig").SpinLock;

// CLEAR defaults to 4 scheduler threads; scale if more are used. Fixed
// upper bound avoids per-scheduler allocations in the profile module.
pub const MAX_SCHEDULERS: usize = 32;
pub const MAX_SITES: usize = 256;

// Buckets (in nanoseconds) used to classify lifetimes.
pub const SHORT_NS: u64 = 1_000_000;     // 1 ms
pub const VSHORT_NS: u64 = 10_000;       // 10 us

// Global lifetime stats. Pub for inspection from runtime/fiber-profile-test.zig.
pub var total_fibers: u64 = 0;
pub var short_fibers: u64 = 0;    // < 1ms
pub var vshort_fibers: u64 = 0;   // < 10us
pub var total_lifetime_ns: u64 = 0;
pub var max_lifetime_ns: u64 = 0;
var mu: SpinLock = .{};

// Per-scheduler fibers-run counter. Index = Scheduler.index. Pub for tests.
pub var sched_runs: [MAX_SCHEDULERS]u64 = [_]u64{0} ** MAX_SCHEDULERS;
var sched_active: usize = 0;

pub const DispatchKind = enum(u8) {
    unknown = 0,
    local = 1,
    parallel = 2,
    pinned = 3,
};

pub const TaskForm = enum(u8) {
    unknown = 0,
    stack = 1,
    fsm = 2,
};

pub const Site = struct {
    id: u32 = 0,
    dispatch: DispatchKind = .unknown,
    form: TaskForm = .unknown,
    spawns: u64 = 0,
    runs: u64 = 0,
    exits: u64 = 0,
    total_lifetime_ns: u64 = 0,
    max_lifetime_ns: u64 = 0,
    sched_runs: [MAX_SCHEDULERS]u64 = [_]u64{0} ** MAX_SCHEDULERS,
};

pub var sites: [MAX_SITES]Site = [_]Site{.{}} ** MAX_SITES;
pub var site_dropped: u64 = 0;

pub fn resetForTest() void {
    mu.lock();
    defer mu.unlock();
    total_fibers = 0;
    short_fibers = 0;
    vshort_fibers = 0;
    total_lifetime_ns = 0;
    max_lifetime_ns = 0;
    sched_runs = [_]u64{0} ** MAX_SCHEDULERS;
    sched_active = 0;
    sites = [_]Site{.{}} ** MAX_SITES;
    site_dropped = 0;
}

pub fn findSiteLocked(site_id: u32) ?*Site {
    if (site_id == 0) return null;
    var idx: usize = @as(usize, site_id) % MAX_SITES;
    var probes: usize = 0;
    while (probes < MAX_SITES) : (probes += 1) {
        if (sites[idx].id == site_id) return &sites[idx];
        if (sites[idx].id == 0) {
            sites[idx].id = site_id;
            return &sites[idx];
        }
        idx = (idx + 1) % MAX_SITES;
    }
    site_dropped += 1;
    return null;
}

pub inline fn nowNs() u64 {
    return compat.nanoTimestamp();
}

pub inline fn recordSchedulerRun(sched_idx: usize) void {
    mu.lock();
    defer mu.unlock();
    if (sched_idx >= MAX_SCHEDULERS) return;
    sched_runs[sched_idx] += 1;
    if (sched_idx + 1 > sched_active) sched_active = sched_idx + 1;
}

pub inline fn recordSiteSpawn(site_id: u32, dispatch: DispatchKind, form: TaskForm) void {
    if (site_id == 0) return;
    mu.lock();
    defer mu.unlock();
    if (findSiteLocked(site_id)) |site| {
        site.spawns += 1;
        if (site.dispatch == .unknown) site.dispatch = dispatch;
        if (site.form == .unknown) site.form = form;
    }
}

pub inline fn recordSiteRun(site_id: u32, sched_idx: usize) void {
    if (site_id == 0) return;
    mu.lock();
    defer mu.unlock();
    if (findSiteLocked(site_id)) |site| {
        site.runs += 1;
        if (sched_idx < MAX_SCHEDULERS) site.sched_runs[sched_idx] += 1;
    }
}

pub inline fn recordFiberExit(site_id: u32, spawn_ns: u64, now: u64) void {
    if (spawn_ns == 0) return;           // never recorded a spawn
    if (now <= spawn_ns) return;          // clock went backwards
    const dur: u64 = now - spawn_ns;
    mu.lock();
    defer mu.unlock();
    total_fibers += 1;
    total_lifetime_ns += dur;
    if (dur > max_lifetime_ns) max_lifetime_ns = dur;
    if (dur < SHORT_NS)  short_fibers  += 1;
    if (dur < VSHORT_NS) vshort_fibers += 1;
    if (findSiteLocked(site_id)) |site| {
        site.exits += 1;
        site.total_lifetime_ns += dur;
        if (dur > site.max_lifetime_ns) site.max_lifetime_ns = dur;
    }
}

pub fn dumpToEnvFile() void {
    const path_ptr = std.c.getenv("CLEAR_FIBER_PROFILE") orelse return;
    const fd = compat.createFileTruncate(path_ptr) catch return;
    defer compat.closeFd(fd);

    mu.lock();
    defer mu.unlock();

    var buf: [1024]u8 = undefined;

    _ = compat.writeAllFd(fd, "# fiber-profile v1\n") catch return;

    const hdr = std.fmt.bufPrint(&buf,
        "total_fibers: {d}\nshort_fibers_under_1ms: {d}\nvshort_fibers_under_10us: {d}\ntotal_lifetime_ns: {d}\nmax_lifetime_ns: {d}\n",
        .{ total_fibers, short_fibers, vshort_fibers, total_lifetime_ns, max_lifetime_ns },
    ) catch return;
    _ = compat.writeAllFd(fd, hdr) catch return;

    _ = compat.writeAllFd(fd, "# per-scheduler fibers-run\n# sched\tfibers\n") catch return;
    var i: usize = 0;
    while (i < sched_active) : (i += 1) {
        const line = std.fmt.bufPrint(&buf, "{d}\t{d}\n", .{ i, sched_runs[i] }) catch continue;
        _ = compat.writeAllFd(fd, line) catch return;
    }

    _ = compat.writeAllFd(fd, "# per-site fibers\n# site\tspawns\truns\texits\ttotal_lifetime_ns\tmax_lifetime_ns\tdispatch\tform\tschedulers\n") catch return;
    if (site_dropped > 0) {
        const warn = std.fmt.bufPrint(&buf,
            "# WARNING: {d} fiber-site samples dropped (cap={d}; rebuild runtime with larger MAX_SITES)\n",
            .{ site_dropped, MAX_SITES },
        ) catch return;
        _ = compat.writeAllFd(fd, warn) catch return;
    }
    for (&sites) |*site| {
        if (site.id == 0) continue;
        var sched_buf: [512]u8 = undefined;
        var sched_len: usize = 0;
        var first = true;
        var si: usize = 0;
        while (si < sched_active) : (si += 1) {
            const runs = site.sched_runs[si];
            if (runs == 0) continue;
            if (!first and sched_len < sched_buf.len) {
                sched_buf[sched_len] = ',';
                sched_len += 1;
            }
            first = false;
            const part = std.fmt.bufPrint(sched_buf[sched_len..], "{d}:{d}", .{ si, runs }) catch break;
            sched_len += part.len;
        }
        const scheds = sched_buf[0..sched_len];
        const line = std.fmt.bufPrint(&buf, "{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{s}\t{s}\t{s}\n", .{
            site.id,
            site.spawns,
            site.runs,
            site.exits,
            site.total_lifetime_ns,
            site.max_lifetime_ns,
            @tagName(site.dispatch),
            @tagName(site.form),
            scheds,
        }) catch continue;
        _ = compat.writeAllFd(fd, line) catch return;
    }
}
