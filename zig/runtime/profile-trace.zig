// profile-trace.zig -- Shared stack-trace + sampling helpers for the
// alloc / lock / mvcc profile recorders.
//
// Each recorder has its own state (table, lock, sample counter), but
// the trace-capture call shape is identical. We centralize:
//   * MAX_FRAMES (one number to tune)
//   * captureFromHere() — wraps std.debug.captureCurrentStackTrace
//   * syncCallstacksEnabled() — reads CLEAR_PROFILE_SYNC_CALLSTACKS
//     once on first call. Used by lock + mvcc to gate stack capture
//     behind `clear profile --sync-callstacks` (off by default; the
//     flag costs ~100-500ns per record and scales the wait-cheap
//     fast paths poorly).
//   * sampleStride() — reads CLEAR_PROFILE_SAMPLE; alloc-profile keeps
//     its own copy because it computed sample_n before this module
//     was extracted.

const std = @import("std");

pub const MAX_FRAMES: u8 = 16;

// Capture a stack trace starting at `first_addr` (typically the
// caller's `@returnAddress()`). Returns the number of frames written
// into `addrs`. The buffer lives on the caller's stack -- 128 B at
// MAX_FRAMES=16 -- and the FP walk reads but does not push frames,
// so the cost is one `[16]usize` slot on the calling stack plus the
// walk itself.
pub fn captureFromHere(first_addr: usize, addrs: *[MAX_FRAMES]usize) u8 {
    const trace = std.debug.captureCurrentStackTrace(
        .{ .first_address = first_addr },
        addrs,
    );
    return @intCast(@min(trace.return_addresses.len, MAX_FRAMES));
}

var sync_callstacks_state: enum { uninit, off, on } = .uninit;

pub fn syncCallstacksEnabled() bool {
    if (sync_callstacks_state != .uninit) return sync_callstacks_state == .on;
    if (std.c.getenv("CLEAR_PROFILE_SYNC_CALLSTACKS")) |env| {
        const slc = std.mem.span(env);
        if (slc.len > 0 and slc[0] != '0') {
            sync_callstacks_state = .on;
            return true;
        }
    }
    sync_callstacks_state = .off;
    return false;
}

var sample_n: u64 = 0;

// Read CLEAR_PROFILE_SAMPLE once and cache. Returns >=1; 0 in the env
// is treated as 1 (no sampling).
pub fn sampleStride() u64 {
    if (sample_n != 0) return sample_n;
    if (std.c.getenv("CLEAR_PROFILE_SAMPLE")) |env| {
        const slc = std.mem.span(env);
        const n = std.fmt.parseInt(u64, slc, 10) catch 1;
        sample_n = if (n == 0) 1 else n;
    } else {
        sample_n = 1;
    }
    return sample_n;
}
