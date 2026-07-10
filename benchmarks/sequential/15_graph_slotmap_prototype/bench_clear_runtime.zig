const std = @import("std");
const ClearRuntime = @import("clear_runtime");
const CheatLib = ClearRuntime.CheatLib;

pub const CLEAR_PROFILE = false;

const edge_count = 4;

const Timer = struct {
    start_ns: u64,

    fn start() @This() {
        return .{ .start_ns = now() };
    }

    fn read(self: *@This()) u64 {
        return now() - self.start_ns;
    }

    fn now() u64 {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    }
};

const CountingAllocator = struct {
    backing: std.mem.Allocator,
    bytes_in_use: usize = 0,
    peak_bytes: usize = 0,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
        };
    }

    fn account(self: *@This(), old_len: usize, new_len: usize) void {
        self.bytes_in_use = self.bytes_in_use + new_len - old_len;
        self.peak_bytes = @max(self.peak_bytes, self.bytes_in_use);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.account(0, len);
        return ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const ok = self.backing.rawResize(buf, alignment, new_len, ret_addr);
        if (ok) self.account(buf.len, new_len);
        return ok;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawRemap(buf, alignment, new_len, ret_addr) orelse return null;
        self.account(buf.len, new_len);
        return ptr;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(buf, alignment, ret_addr);
        self.bytes_in_use -= buf.len;
    }
};

fn readScale() f64 {
    const raw = std.c.getenv("BENCH_SCALE") orelse return 1.0;
    return std.fmt.parseFloat(f64, std.mem.span(raw)) catch 1.0;
}

fn readCapacity() u32 {
    if (std.c.getenv("BENCH_N")) |raw| {
        const parsed = std.fmt.parseInt(u32, std.mem.span(raw), 10) catch 0;
        if (parsed >= 4096 and parsed <= 1_048_576) return parsed;
    }
    return @intFromFloat(@max(4096.0, 1_000_000.0 * readScale()));
}

fn evenAtLeast(raw: u32, minimum: u32) u32 {
    const value = @max(raw, minimum);
    return value + (value & 1);
}

fn localTarget(i: u32, edge: u32, core_count: u32) u32 {
    return ((i % core_count) + edge + 1) % core_count;
}

fn randomTarget(i: u32, edge: u32, core_count: u32) u32 {
    return (i *% 1_664_525 +% (edge + 1) *% 1_013_904_223) % core_count;
}

fn printResult(impl: []const u8, elapsed_ns: u64, capacity: u32, live: u32, peak: usize, retained: usize, checksum: u64) void {
    std.debug.print("BENCH_RESULT: {d:.3} ms\n", .{@as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0});
    std.debug.print("BENCH_INFO: impl={s} nodes={} live={} peak_mib={d:.2} retained_mib={d:.2} bytes_per_capacity={d:.1} checksum={}\n", .{
        impl,
        capacity,
        live,
        @as(f64, @floatFromInt(peak)) / (1024.0 * 1024.0),
        @as(f64, @floatFromInt(retained)) / (1024.0 * 1024.0),
        @as(f64, @floatFromInt(peak)) / @as(f64, @floatFromInt(capacity)),
        checksum,
    });
}

const PoolNode = struct {
    value: u64,
    edges: [edge_count]u64,
};

fn runPool(capacity: u32) !void {
    var counter = CountingAllocator{ .backing = std.heap.c_allocator };
    const allocator = counter.allocator();
    const Pool = CheatLib.Pool(PoolNode);
    var pool = try Pool.initCapacity(allocator, capacity);
    defer pool.deinit(allocator);

    const core_count = capacity * 3 / 4;
    const churn_count = capacity - core_count;
    const read_rounds = evenAtLeast(9_000_000 / core_count, 12);
    const write_rounds = evenAtLeast(1_000_000 / capacity, 4);
    const churn_rounds = evenAtLeast(1_000_000 / churn_count, 4);
    const sparse_rounds = @max(100_000_000 / capacity, 100);
    const churn_handles = try std.heap.page_allocator.alloc(u64, churn_count);
    defer std.heap.page_allocator.free(churn_handles);

    var timer = Timer.start();
    for (0..capacity) |raw_i| {
        const i: u32 = @intCast(raw_i);
        const handle = try pool.insert(allocator, .{ .value = i, .edges = .{0} ** edge_count });
        if (i >= core_count) churn_handles[i - core_count] = handle;
    }

    for (0..capacity) |raw_i| {
        const i: u32 = @intCast(raw_i);
        const node = pool.get(i).?;
        inline for (0..edge_count) |raw_edge| {
            node.edges[raw_edge] = localTarget(i, @intCast(raw_edge), core_count);
        }
    }

    const build_ns = timer.read();
    var phase = Timer.start();
    var checksum: u64 = 0;
    for (0..read_rounds) |_| {
        for (0..core_count) |raw_i| {
            const node = pool.get(@intCast(raw_i)).?;
            inline for (0..edge_count) |edge| checksum +%= pool.get(node.edges[edge]).?.value;
        }
    }

    const local_read_ns = phase.read();
    phase = Timer.start();
    for (0..write_rounds) |round| {
        const use_random = (round & 1) != 0 or round + 1 == write_rounds;
        for (0..capacity) |raw_i| {
            const i: u32 = @intCast(raw_i);
            const node = pool.get(i).?;
            inline for (0..edge_count) |edge| {
                node.edges[edge] = if (use_random)
                    randomTarget(i, @intCast(edge), core_count)
                else
                    localTarget(i, @intCast(edge), core_count);
            }
        }
    }
    const edge_write_ns = phase.read();

    phase = Timer.start();
    var random_checksum: u64 = 0;
    for (0..read_rounds) |_| {
        for (0..core_count) |raw_i| {
            const node = pool.get(@intCast(raw_i)).?;
            inline for (0..edge_count) |edge| random_checksum +%= pool.get(node.edges[edge]).?.value;
        }
    }
    const random_read_ns = phase.read();

    phase = Timer.start();
    for (0..churn_rounds) |round| {
        for (churn_handles, 0..) |handle, i| {
            pool.remove(handle);
            var replacement = PoolNode{ .value = i + round, .edges = .{0} ** edge_count };
            inline for (0..edge_count) |edge| {
                replacement.edges[edge] = randomTarget(@intCast(i), @intCast(edge), core_count);
            }
            churn_handles[i] = try pool.insert(allocator, replacement);
        }
    }

    const churn_ns = phase.read();
    phase = Timer.start();
    const keep = @max(1, capacity / 100);
    var i = keep;
    while (i < core_count) : (i += 1) pool.remove(i);
    for (churn_handles) |handle| pool.remove(handle);

    const collapse_ns = phase.read();
    var sparse_timer = Timer.start();
    var sparse_checksum: u64 = 0;
    for (0..sparse_rounds) |_| {
        for (pool.slots) |slot| if (slot.alive) {
            sparse_checksum +%= slot.value.value;
        };
    }
    const sparse_ns = sparse_timer.read();
    const elapsed_ns = build_ns + local_read_ns + edge_write_ns + random_read_ns + churn_ns + collapse_ns;

    printResult("clear-manual-pool", elapsed_ns, capacity, pool.live_count, counter.peak_bytes, counter.bytes_in_use, checksum +% random_checksum);
    std.debug.print("BENCH_PHASES: impl=clear-manual-pool build_ms={d:.3} local_read_ms={d:.3} edge_write_ms={d:.3} random_read_ms={d:.3} churn_ms={d:.3} collapse_ms={d:.3} sparse_scan_ms={d:.3} local_checksum={} random_checksum={} sparse_checksum={}\n", .{
        @as(f64, @floatFromInt(build_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(local_read_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(edge_write_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(random_read_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(churn_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(collapse_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(sparse_ns)) / 1_000_000.0,
        checksum,
        random_checksum,
        sparse_checksum,
    });
}

const LinkNode = struct {
    value: u64,
    edges: [edge_count]CheatLib.WeakRc(LinkNode),
};
const RcNode = CheatLib.Rc(LinkNode);

fn runLinks(capacity: u32) !void {
    var counter = CountingAllocator{ .backing = std.heap.c_allocator };
    const allocator = counter.allocator();
    const roots = try allocator.alloc(?RcNode, capacity);
    defer allocator.free(roots);
    @memset(roots, null);

    const core_count = capacity * 3 / 4;
    const churn_count = capacity - core_count;
    const read_rounds = evenAtLeast(9_000_000 / core_count, 12);
    const write_rounds = evenAtLeast(1_000_000 / capacity, 4);
    const churn_rounds = evenAtLeast(1_000_000 / churn_count, 4);
    const sparse_rounds = @max(100_000_000 / capacity, 100);

    var timer = Timer.start();
    for (0..capacity) |i| {
        roots[i] = try CheatLib.rcCreate(LinkNode, allocator, .{ .value = i, .edges = undefined });
    }

    for (0..capacity) |raw_i| {
        const i: u32 = @intCast(raw_i);
        const node = roots[i].?.ctrl.data;
        inline for (0..edge_count) |raw_edge| {
            node.edges[raw_edge] = CheatLib.rcDowngrade(LinkNode, roots[localTarget(i, @intCast(raw_edge), core_count)].?);
        }
    }

    const build_ns = timer.read();
    var phase = Timer.start();
    var checksum: u64 = 0;
    for (0..read_rounds) |_| {
        for (0..core_count) |raw_i| {
            const node = roots[raw_i].?.ctrl.data;
            inline for (0..edge_count) |edge| {
                const strong = CheatLib.weakRcUpgrade(LinkNode, node.edges[edge]).?;
                checksum +%= strong.ctrl.data.value;
                CheatLib.rcRelease(LinkNode, allocator, strong);
            }
        }
    }

    const local_read_ns = phase.read();
    phase = Timer.start();
    for (0..write_rounds) |round| {
        const use_random = (round & 1) != 0 or round + 1 == write_rounds;
        for (0..capacity) |raw_i| {
            const i: u32 = @intCast(raw_i);
            const node = roots[i].?.ctrl.data;
            inline for (0..edge_count) |edge| {
                CheatLib.weakRcRelease(LinkNode, allocator, node.edges[edge]);
                const target_index = if (use_random)
                    randomTarget(i, @intCast(edge), core_count)
                else
                    localTarget(i, @intCast(edge), core_count);
                node.edges[edge] = CheatLib.rcDowngrade(LinkNode, roots[target_index].?);
            }
        }
    }
    const edge_write_ns = phase.read();

    phase = Timer.start();
    var random_checksum: u64 = 0;
    for (0..read_rounds) |_| {
        for (0..core_count) |raw_i| {
            const node = roots[raw_i].?.ctrl.data;
            inline for (0..edge_count) |edge| {
                const strong = CheatLib.weakRcUpgrade(LinkNode, node.edges[edge]).?;
                random_checksum +%= strong.ctrl.data.value;
                CheatLib.rcRelease(LinkNode, allocator, strong);
            }
        }
    }
    const random_read_ns = phase.read();

    phase = Timer.start();
    for (0..churn_rounds) |round| {
        for (0..churn_count) |tail_i| {
            const i = core_count + tail_i;
            CheatLib.rcRelease(LinkNode, allocator, roots[i].?);
            const replacement = try CheatLib.rcCreate(LinkNode, allocator, .{ .value = tail_i + round, .edges = undefined });
            inline for (0..edge_count) |edge| {
                replacement.ctrl.data.edges[edge] = CheatLib.rcDowngrade(LinkNode, roots[randomTarget(@intCast(tail_i), @intCast(edge), core_count)].?);
            }
            roots[i] = replacement;
        }
    }

    const churn_ns = phase.read();
    phase = Timer.start();
    const keep = @max(1, capacity / 100);
    for (keep..capacity) |i| {
        CheatLib.rcRelease(LinkNode, allocator, roots[i].?);
        roots[i] = null;
    }

    const collapse_ns = phase.read();
    var sparse_timer = Timer.start();
    var sparse_checksum: u64 = 0;
    for (0..sparse_rounds) |_| {
        for (roots) |maybe| {
            if (maybe) |root| sparse_checksum +%= root.ctrl.data.value;
        }
    }
    const sparse_ns = sparse_timer.read();
    const elapsed = build_ns + local_read_ns + edge_write_ns + random_read_ns + churn_ns + collapse_ns;
    printResult("clear-link-resolve-runtime", elapsed, capacity, keep, counter.peak_bytes, counter.bytes_in_use, checksum +% random_checksum);
    std.debug.print("BENCH_LAYOUT: impl=clear-link-resolve-runtime root_slot_bytes={} control_block_bytes={} node_bytes={} weak_edge_bytes={}\n", .{
        @sizeOf(?RcNode),
        @sizeOf(CheatLib.RcControlBlock(LinkNode)),
        @sizeOf(LinkNode),
        @sizeOf(CheatLib.WeakRc(LinkNode)),
    });
    std.debug.print("BENCH_PHASES: impl=clear-link-resolve-runtime build_ms={d:.3} local_read_ms={d:.3} edge_write_ms={d:.3} random_read_ms={d:.3} churn_ms={d:.3} collapse_ms={d:.3} sparse_scan_ms={d:.3} local_checksum={} random_checksum={} sparse_checksum={}\n", .{
        @as(f64, @floatFromInt(build_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(local_read_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(edge_write_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(random_read_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(churn_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(collapse_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(sparse_ns)) / 1_000_000.0,
        checksum,
        random_checksum,
        sparse_checksum,
    });

    for (roots) |maybe| if (maybe) |root| CheatLib.rcRelease(LinkNode, allocator, root);
}

pub fn main() !void {
    const capacity = readCapacity();
    const only = if (std.c.getenv("BENCH_ONLY")) |raw| std.mem.span(raw) else "";
    if (!std.mem.eql(u8, only, "link")) try runPool(capacity);
    if (!std.mem.eql(u8, only, "pool")) try runLinks(capacity);
}
