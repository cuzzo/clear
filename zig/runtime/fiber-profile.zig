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

// Buckets (in nanoseconds) used to classify lifetimes.
pub const SHORT_NS: u64 = 1_000_000;     // 1 ms
pub const VSHORT_NS: u64 = 10_000;       // 10 us

// Global lifetime stats.
var total_fibers: u64 = 0;
var short_fibers: u64 = 0;    // < 1ms
var vshort_fibers: u64 = 0;   // < 10us
var total_lifetime_ns: u64 = 0;
var max_lifetime_ns: u64 = 0;
var mu: SpinLock = .{};

// Per-scheduler fibers-run counter. Index = Scheduler.index.
var sched_runs: [MAX_SCHEDULERS]u64 = [_]u64{0} ** MAX_SCHEDULERS;
var sched_active: usize = 0;

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

pub inline fn recordFiberExit(spawn_ns: u64, now: u64) void {
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
}

pub fn dumpToEnvFile() void {
    const path_ptr = std.c.getenv("CLEAR_FIBER_PROFILE") orelse return;
    const fd = compat.createFileTruncate(path_ptr) catch return;
    defer compat.closeFd(fd);

    mu.lock();
    defer mu.unlock();

    var buf: [256]u8 = undefined;

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
}
