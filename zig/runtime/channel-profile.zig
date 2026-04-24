// channel-profile.zig — Channel saturation telemetry for `clear profile`.
//
// Collected only when `CLEAR_PROFILE == true` (comptime-gated at every
// call site in data-structures.zig). Normal `clear build` / `--optimized`
// / `--safe` builds compile this tracking out entirely — the conditional
// `Prof` field on Inner becomes `void`, the `register` / `record` calls
// live inside `if (rt.CLEAR_PROFILE) { ... }` branches that Zig erases.
//
// The registry is a fixed-size array of weak pointers to per-channel
// Prof structs. No allocation, no locking on the hot path — only the
// init-time `register` call walks the array. At process exit (or when
// `dumpToFile` is invoked), we emit a tab-separated table of all
// registered channels: pushes, pops, push_blocked, pop_blocked,
// max_depth, capacity.

const std = @import("std");
const compat = @import("../lib/compat.zig");

pub const MAX_CHANNELS: usize = 1024;

// NOTE: We store opaque pointers (*anyopaque) because the channel's
// `Prof` type is generic over the channel's element type. Each push
// only ever updates the fields relative to its own pointer, so the
// concrete layout is known at its own call site. The registry is
// iterated for output only; we snapshot the raw fields by offset,
// which is stable because every channel has the same Prof struct.

pub const ProfStats = extern struct {
    pushes: u64 = 0,
    pops: u64 = 0,
    push_blocked: u64 = 0,
    pop_blocked: u64 = 0,
    max_depth: u64 = 0,
    capacity: u64 = 0,
};

// Stats stored BY VALUE in the registry so they survive the channel's
// deinit — the channel holds only an index, and we read the saved
// stats directly at dump time. If we held `*ProfStats` instead the
// pointer would dangle once the owning Inner was freed, and the dump
// would read garbage.
var stats: [MAX_CHANNELS]ProfStats = [_]ProfStats{.{}} ** MAX_CHANNELS;
var count: usize = 0;
var mu: compat.Mutex = .{};

// Returns an id in [0, MAX_CHANNELS) that the channel uses to index
// into `stats`. When the registry is full, returns MAX_CHANNELS and
// the channel's updates become no-ops (bounds-check in `snapshot`).
pub fn register(initial_capacity: u64) usize {
    mu.lock();
    defer mu.unlock();
    if (count >= MAX_CHANNELS) return MAX_CHANNELS;
    const id = count;
    stats[id] = .{ .capacity = initial_capacity };
    count += 1;
    return id;
}

pub inline fn recordPush(id: usize, depth: u64, blocked: bool) void {
    if (id >= MAX_CHANNELS) return;
    stats[id].pushes += 1;
    if (depth > stats[id].max_depth) stats[id].max_depth = depth;
    if (blocked) stats[id].push_blocked += 1;
}

pub inline fn recordPop(id: usize) void {
    if (id >= MAX_CHANNELS) return;
    stats[id].pops += 1;
}

pub inline fn recordPopBlocked(id: usize) void {
    if (id >= MAX_CHANNELS) return;
    stats[id].pop_blocked += 1;
}

// Dump the registered stats to the path in $CLEAR_CHANNEL_PROFILE.
// Called from the runtime's atexit hook. When the env var isn't set,
// we skip silently so non-profile runs (where CLEAR_PROFILE was still
// true but the user didn't request a channel profile) have no I/O.
pub fn dumpToEnvFile() void {
    const path_ptr = std.c.getenv("CLEAR_CHANNEL_PROFILE") orelse return;
    const fd = compat.createFileTruncate(path_ptr) catch return;
    defer compat.closeFd(fd);

    var buf: [256]u8 = undefined;
    _ = compat.writeAllFd(fd, "# channel-profile v1\n") catch return;
    _ = compat.writeAllFd(fd, "# id\tpushes\tpops\tpush_blocked\tpop_blocked\tmax_depth\tcapacity\n") catch return;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const p = stats[i];
        const line = std.fmt.bufPrint(&buf, "{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
            i, p.pushes, p.pops, p.push_blocked, p.pop_blocked, p.max_depth, p.capacity,
        }) catch continue;
        _ = compat.writeAllFd(fd, line) catch return;
    }
}
