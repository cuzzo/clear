pub const CLEAR_FRAME_DEBUG = false;

const std = @import("std");

pub const partitioned_map_counters = struct {
    pub var get_created = std.atomic.Value(usize).init(0);
    pub var get_destroyed = std.atomic.Value(usize).init(0);
    pub var get_inflight = std.atomic.Value(usize).init(0);
    pub var remove_created = std.atomic.Value(usize).init(0);
    pub var remove_destroyed = std.atomic.Value(usize).init(0);
    pub var remove_inflight = std.atomic.Value(usize).init(0);
    pub var per_shard_get_inflight = [_]std.atomic.Value(usize){std.atomic.Value(usize).init(0)} ** 8;
    pub var per_shard_remove_inflight = [_]std.atomic.Value(usize){std.atomic.Value(usize).init(0)} ** 8;
};

pub const PartitionedMapEvent = struct {
    kind: u8,
    stage: u8,
    shard: u8,
    _pad: u8 = 0,
    op_id: u64,
    ctx_ptr: usize,
    key_ptr: usize,
};

pub const partitioned_map_event_log = struct {
    pub var enabled = std.atomic.Value(bool).init(false);
    pub var next_op_id = std.atomic.Value(u64).init(1);
    pub var count = std.atomic.Value(usize).init(0);
    pub var dropped = std.atomic.Value(usize).init(0);
    pub var events = [_]PartitionedMapEvent{.{
        .kind = 0,
        .stage = 0,
        .shard = 0,
        .op_id = 0,
        .ctx_ptr = 0,
        .key_ptr = 0,
    }} ** 32768;
};

pub var partitioned_map_delay_ctx_destroy = false;
pub var partitioned_map_delay_get_ctx_destroy = false;
pub var partitioned_map_delay_remove_ctx_destroy = false;
pub var partitioned_map_delay_key_free = false;
pub var partitioned_map_delay_completion_destroy = false;
pub var partitioned_map_watchdog_timeout_ms: usize = 0;

pub fn partitionedMapTestNextOpId(_: u8, _: usize) u64 {
    return partitioned_map_event_log.next_op_id.fetchAdd(1, .seq_cst);
}

pub fn partitionedMapTestNoteEvent(kind: u8, stage: u8, shard: usize, op_id: u64, ctx_ptr: usize, key_ptr: usize) void {
    if (!partitioned_map_event_log.enabled.load(.seq_cst)) return;
    const slot = partitioned_map_event_log.count.fetchAdd(1, .seq_cst);
    if (slot >= partitioned_map_event_log.events.len) {
        _ = partitioned_map_event_log.dropped.fetchAdd(1, .seq_cst);
        return;
    }
    partitioned_map_event_log.events[slot] = .{
        .kind = kind,
        .stage = stage,
        .shard = @intCast(shard),
        .op_id = op_id,
        .ctx_ptr = ctx_ptr,
        .key_ptr = key_ptr,
    };
}

pub fn partitionedMapTestCtxCreated(kind: u8, shard: usize) void {
    switch (kind) {
        1 => {
            _ = partitioned_map_counters.get_created.fetchAdd(1, .seq_cst);
            _ = partitioned_map_counters.get_inflight.fetchAdd(1, .seq_cst);
            if (shard < partitioned_map_counters.per_shard_get_inflight.len)
                _ = partitioned_map_counters.per_shard_get_inflight[shard].fetchAdd(1, .seq_cst);
        },
        2 => {
            _ = partitioned_map_counters.remove_created.fetchAdd(1, .seq_cst);
            _ = partitioned_map_counters.remove_inflight.fetchAdd(1, .seq_cst);
            if (shard < partitioned_map_counters.per_shard_remove_inflight.len)
                _ = partitioned_map_counters.per_shard_remove_inflight[shard].fetchAdd(1, .seq_cst);
        },
        else => {},
    }
}

pub fn partitionedMapTestCtxDestroyed(kind: u8, shard: usize) void {
    switch (kind) {
        1 => {
            _ = partitioned_map_counters.get_destroyed.fetchAdd(1, .seq_cst);
            _ = partitioned_map_counters.get_inflight.fetchSub(1, .seq_cst);
            if (shard < partitioned_map_counters.per_shard_get_inflight.len)
                _ = partitioned_map_counters.per_shard_get_inflight[shard].fetchSub(1, .seq_cst);
        },
        2 => {
            _ = partitioned_map_counters.remove_destroyed.fetchAdd(1, .seq_cst);
            _ = partitioned_map_counters.remove_inflight.fetchSub(1, .seq_cst);
            if (shard < partitioned_map_counters.per_shard_remove_inflight.len)
                _ = partitioned_map_counters.per_shard_remove_inflight[shard].fetchSub(1, .seq_cst);
        },
        else => {},
    }
}

test {
    _ = @import("lib/partitioned-map-test.zig");
}
