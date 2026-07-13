const std = @import("std");
const clear_runtime = @import("clear_runtime");

const CheatLib = clear_runtime.CheatLib;
const Node = struct {
    next: CheatLib.NodeRef(@This()) = .{},
    id: i64,
};
const Map = CheatLib.PagedSlotMap(Node);
const Ref = CheatLib.NodeRef(Node);

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const n: u32 = 1_000_000;
    const read_rounds: u32 = 8;
    const write_rounds: u32 = 4;

    var map = try Map.initCapacity(allocator, Map.max_capacity);
    defer map.deinit();
    const nodes = try allocator.alloc(Ref, n);
    defer allocator.free(nodes);

    const build_start = nowMs();
    for (0..n) |raw_i| {
        nodes[raw_i] = Ref.fromHandle(try map.insert(.{ .id = @intCast(raw_i) }));
    }
    for (0..n) |raw_i| {
        const i: u32 = @intCast(raw_i);
        const target: u32 = @intCast((@as(u64, i) * 1_664_525 + 1_013_904_223) % n);
        map.get(nodes[raw_i].handle().?).?.next = nodes[target];
    }
    const build_ms = nowMs() - build_start;

    var checksum: i64 = 0;
    const read_start = nowMs();
    for (0..read_rounds) |_| {
        for (0..n) |raw_i| {
            const edge = map.get(nodes[raw_i].handle().?).?.next;
            const value = if (edge.handle()) |handle|
                if (map.get(handle)) |target| target.id else 0
            else
                0;
            checksum = std.math.add(i64, checksum, value) catch unreachable;
        }
    }
    const read_ms = nowMs() - read_start;

    const write_start = nowMs();
    for (0..write_rounds) |raw_round| {
        const round: u32 = @intCast(raw_round);
        for (0..n) |raw_i| {
            const i: u32 = @intCast(raw_i);
            const target: u32 = @intCast((@as(u64, i) * 22_695_477 +
                @as(u64, round) * 1_103_515_245 + 12_345) % n);
            map.get(nodes[raw_i].handle().?).?.next = nodes[target];
        }
    }
    const write_ms = nowMs() - write_start;
    std.mem.doNotOptimizeAway(checksum);

    std.debug.print("NODE_BENCH: impl=manual-zig-slotmap nodes={} build_ms={} read_ms={} write_ms={} total_ms={} checksum={}\n", .{
        n, build_ms, read_ms, write_ms, read_ms + write_ms, checksum,
    });
}
