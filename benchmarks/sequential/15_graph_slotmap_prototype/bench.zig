const std = @import("std");

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

const edge_count = 4;
const slot_bits = 20;
const chunk_shift = 12;
const chunk_capacity: u32 = 1 << chunk_shift;
const chunk_mask = chunk_capacity - 1;
const slot_mask: u32 = (1 << slot_bits) - 1;
const generation_mask: u32 = (1 << 12) - 1;
const dead_index = slot_mask;

// Capacity-specialized compact handle for the benchmark's <= 2^20 nodes.
// Generation exhaustion retires a slot instead of wrapping, preserving stale
// handle safety for 4,095 reuse cycles per logical slot.
const Handle = u32;

inline fn makeHandle(slot: u32, generation: u32) Handle {
    return (generation << slot_bits) | slot;
}

inline fn handleSlot(handle: Handle) u32 {
    return handle & slot_mask;
}

inline fn handleGeneration(handle: Handle) u32 {
    return handle >> slot_bits;
}

const Node = struct {
    value: u64,
    edges: [edge_count]Handle,
};

fn DenseGraph(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        capacity: u32,
        nodes: []T,
        dense_to_slot: []u32,
        // Low 20 bits are the dense payload index; high 12 bits are the
        // generation. The all-ones dense index is the dead sentinel.
        meta: []u32,
        free_slots: []u32,
        live_count: u32 = 0,
        free_top: u32,
        committed_payload_capacity: u32 = 0,

        fn init(allocator: std.mem.Allocator, capacity: u32) !Self {
            if (capacity >= dead_index) return error.CapacityTooLarge;
            if ((chunk_capacity * @sizeOf(T)) % std.heap.page_size_min != 0) {
                @compileError("payload chunk byte size must be page aligned");
            }
            const nodes = try allocator.alloc(T, capacity);
            errdefer allocator.free(nodes);
            const dense_to_slot = try allocator.alloc(u32, capacity);
            errdefer allocator.free(dense_to_slot);
            const meta = try allocator.alloc(u32, capacity);
            errdefer allocator.free(meta);
            const free_slots = try allocator.alloc(u32, capacity);
            errdefer allocator.free(free_slots);

            for (0..capacity) |raw_i| {
                const i: u32 = @intCast(raw_i);
                meta[raw_i] = dead_index;
                free_slots[raw_i] = capacity - 1 - i;
            }

            return .{
                .allocator = allocator,
                .capacity = capacity,
                .nodes = nodes,
                .dense_to_slot = dense_to_slot,
                .meta = meta,
                .free_slots = free_slots,
                .free_top = capacity,
            };
        }

        fn deinit(self: *Self) void {
            self.allocator.free(self.free_slots);
            self.allocator.free(self.meta);
            self.allocator.free(self.dense_to_slot);
            self.allocator.free(self.nodes);
        }

        inline fn markCommitted(self: *Self, dense_index: u32) void {
            if (dense_index < self.committed_payload_capacity) return;
            self.committed_payload_capacity = @min(
                self.capacity,
                ((dense_index >> chunk_shift) + 1) * chunk_capacity,
            );
        }

        inline fn nodePtr(self: *Self, dense_index: u32) *T {
            return &self.nodes[dense_index];
        }

        inline fn denseSlot(self: *Self, dense_index: u32) u32 {
            return self.dense_to_slot[dense_index];
        }

        inline fn setDenseSlot(self: *Self, dense_index: u32, slot: u32) void {
            self.dense_to_slot[dense_index] = slot;
        }

        fn decommitRange(comptime E: type, slice: []E, start: u32, end: u32) void {
            if (start >= end) return;
            const byte_ptr: [*]u8 = @ptrCast(slice.ptr + start);
            const aligned_ptr: [*]align(std.heap.page_size_min) u8 = @alignCast(byte_ptr);
            const byte_len = @as(usize, end - start) * @sizeOf(E);
            std.posix.madvise(aligned_ptr, byte_len, std.c.MADV.DONTNEED) catch
                @panic("payload decommit failed");
        }

        fn decommitEmptyTailChunk(self: *Self) void {
            if ((self.live_count & chunk_mask) != 0) return;
            const start = self.live_count;
            const end = @min(self.capacity, start + chunk_capacity);
            decommitRange(T, self.nodes, start, end);
            decommitRange(u32, self.dense_to_slot, start, end);
            self.committed_payload_capacity = start;
        }

        inline fn insert(self: *Self, value: T) Handle {
            if (self.free_top == 0) @panic("graph is full");
            self.free_top -= 1;
            const slot = self.free_slots[self.free_top];
            const dense_index = self.live_count;
            self.markCommitted(dense_index);
            self.nodePtr(dense_index).* = value;
            self.setDenseSlot(dense_index, slot);
            const generation = self.meta[slot] >> slot_bits;
            self.meta[slot] = (generation << slot_bits) | dense_index;
            self.live_count += 1;
            return makeHandle(slot, generation);
        }

        inline fn get(self: *Self, handle: Handle) ?*T {
            const slot = handleSlot(handle);
            if (slot >= self.meta.len) return null;
            const entry = self.meta[slot];
            const dense_index = entry & slot_mask;
            if (dense_index == dead_index or entry >> slot_bits != handleGeneration(handle)) return null;
            return self.nodePtr(dense_index);
        }

        inline fn remove(self: *Self, handle: Handle) bool {
            const slot = handleSlot(handle);
            if (slot >= self.meta.len) return false;
            const entry = self.meta[slot];
            const removed_dense = entry & slot_mask;
            const generation = entry >> slot_bits;
            if (removed_dense == dead_index or generation != handleGeneration(handle)) return false;

            const last_dense = self.live_count - 1;
            if (removed_dense != last_dense) {
                self.nodePtr(removed_dense).* = self.nodePtr(last_dense).*;
                const moved_slot = self.denseSlot(last_dense);
                self.setDenseSlot(removed_dense, moved_slot);
                self.meta[moved_slot] = (self.meta[moved_slot] & ~slot_mask) | removed_dense;
            }

            self.live_count -= 1;
            self.decommitEmptyTailChunk();
            if (generation < generation_mask) {
                self.meta[slot] = ((generation + 1) << slot_bits) | dead_index;
                self.free_slots[self.free_top] = slot;
                self.free_top += 1;
            } else {
                self.meta[slot] = (generation << slot_bits) | dead_index;
            }
            return true;
        }

        fn virtualBytes(self: *const Self) usize {
            return self.nodes.len * @sizeOf(T) +
                self.dense_to_slot.len * @sizeOf(u32) +
                self.meta.len * @sizeOf(u32) +
                self.free_slots.len * @sizeOf(u32) +
                0;
        }

        fn committedBytesEstimate(self: *const Self) usize {
            return self.meta.len * @sizeOf(u32) +
                self.free_slots.len * @sizeOf(u32) +
                @as(usize, self.committed_payload_capacity) * (@sizeOf(T) + @sizeOf(u32));
        }
    };
}

fn emptyNode(value: u64) Node {
    return .{ .value = value, .edges = .{0} ** edge_count };
}

fn readScale() f64 {
    const raw = std.c.getenv("BENCH_SCALE") orelse return 1.0;
    return std.fmt.parseFloat(f64, std.mem.span(raw)) catch 1.0;
}

fn readCapacity() u32 {
    if (std.c.getenv("BENCH_N")) |raw| {
        const parsed = std.fmt.parseInt(u32, std.mem.span(raw), 10) catch 0;
        if (parsed >= 4096 and parsed < dead_index) return parsed;
    }
    return @min(dead_index - 1, @as(u32, @intFromFloat(@max(4096.0, 1_000_000.0 * readScale()))));
}

fn evenAtLeast(raw: u32, minimum: u32) u32 {
    const value = @max(raw, minimum);
    return value + (value & 1);
}

fn residentBytes(allocator: std.mem.Allocator, comptime E: type, slice: []E) !usize {
    const byte_len = slice.len * @sizeOf(E);
    const page_count = (byte_len + std.heap.page_size_min - 1) / std.heap.page_size_min;
    const residency = try allocator.alloc(u8, page_count);
    defer allocator.free(residency);
    const byte_ptr: [*]u8 = @ptrCast(slice.ptr);
    const aligned_ptr: [*]align(std.heap.page_size_min) u8 = @alignCast(byte_ptr);
    try std.posix.mincore(aligned_ptr, byte_len, residency.ptr);
    var resident_pages: usize = 0;
    for (residency) |entry| resident_pages += entry & 1;
    return resident_pages * std.heap.page_size_min;
}

inline fn localTarget(i: u32, edge: u32, core: u32) u32 {
    return ((i % core) + edge + 1) % core;
}

inline fn randomTarget(i: u32, edge: u32, core: u32) u32 {
    return (i *% 1_664_525 +% (edge + 1) *% 1_013_904_223) % core;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const capacity = readCapacity();
    const core_count: u32 = capacity * 3 / 4;
    const churn_count = capacity - core_count;
    const read_rounds = evenAtLeast(9_000_000 / core_count, 12);
    const write_rounds = evenAtLeast(1_000_000 / capacity, 4);
    const churn_rounds = evenAtLeast(1_000_000 / churn_count, 4);
    const sparse_rounds = @max(100_000_000 / capacity, 100);

    var graph = try DenseGraph(Node).init(allocator, capacity);
    defer graph.deinit();
    const churn_handles = try allocator.alloc(Handle, churn_count);
    defer allocator.free(churn_handles);

    var timer = Timer.start();

    for (0..capacity) |raw_i| {
        const i: u32 = @intCast(raw_i);
        const handle = graph.insert(emptyNode(i));
        if (i >= core_count) churn_handles[i - core_count] = handle;
    }

    for (0..capacity) |raw_i| {
        const i: u32 = @intCast(raw_i);
        const node = graph.get(makeHandle(i, 0)).?;
        inline for (0..edge_count) |edge_i| {
            node.edges[edge_i] = makeHandle(localTarget(i, @intCast(edge_i), core_count), 0);
        }
    }

    const build_ns = timer.read();
    const peak_committed_bytes = graph.committedBytesEstimate();
    const virtual_bytes = graph.virtualBytes();
    const peak_payload_resident_bytes = try residentBytes(allocator, Node, graph.nodes) +
        try residentBytes(allocator, u32, graph.dense_to_slot);
    var phase = Timer.start();
    var checksum: u64 = 0;
    for (0..read_rounds) |_| {
        for (0..core_count) |raw_i| {
            // Graph iteration is over the dense payload sequence. Only edge
            // traversal pays logical-slot resolution.
            const node = graph.nodePtr(@intCast(raw_i));
            inline for (0..edge_count) |edge_i| {
                checksum +%= graph.get(node.edges[edge_i]).?.value;
            }
        }
    }

    const local_read_ns = phase.read();
    phase = Timer.start();
    for (0..write_rounds) |round| {
        const use_random = (round & 1) != 0 or round + 1 == write_rounds;
        for (0..capacity) |raw_i| {
            const i: u32 = @intCast(raw_i);
            const node = graph.nodePtr(i);
            inline for (0..edge_count) |edge_i| {
                const target = if (use_random)
                    randomTarget(i, @intCast(edge_i), core_count)
                else
                    localTarget(i, @intCast(edge_i), core_count);
                node.edges[edge_i] = makeHandle(target, 0);
            }
        }
    }
    const edge_write_ns = phase.read();

    phase = Timer.start();
    var random_checksum: u64 = 0;
    for (0..read_rounds) |_| {
        for (0..core_count) |raw_i| {
            const node = graph.nodePtr(@intCast(raw_i));
            inline for (0..edge_count) |edge_i| {
                random_checksum +%= graph.get(node.edges[edge_i]).?.value;
            }
        }
    }
    const random_read_ns = phase.read();

    phase = Timer.start();
    for (0..churn_rounds) |round| {
        for (churn_handles, 0..) |handle, raw_i| {
            if (!graph.remove(handle)) @panic("live churn handle rejected");
            var replacement = emptyNode(@as(u64, @intCast(round)) + raw_i);
            inline for (0..edge_count) |edge_i| {
                replacement.edges[edge_i] = makeHandle(randomTarget(@intCast(raw_i), @intCast(edge_i), core_count), 0);
            }
            churn_handles[raw_i] = graph.insert(replacement);
        }
    }

    const churn_ns = phase.read();
    phase = Timer.start();
    const keep = @max(1, capacity / 100);
    var i: u32 = keep;
    while (i < core_count) : (i += 1) {
        if (!graph.remove(makeHandle(i, 0))) @panic("core collapse removal rejected");
    }
    for (churn_handles) |handle| {
        if (!graph.remove(handle)) @panic("tail collapse removal rejected");
    }

    const collapse_ns = phase.read();
    if (graph.get(makeHandle(0, 0)) == null) @panic("live handle rejected after compaction");
    if (keep < core_count and graph.get(makeHandle(keep, 0)) != null) @panic("stale handle survived removal");
    var sparse_timer = Timer.start();
    var sparse_checksum: u64 = 0;
    for (0..sparse_rounds) |_| {
        for (graph.nodes[0..graph.live_count]) |node| sparse_checksum +%= node.value;
    }
    const sparse_ns = sparse_timer.read();
    const elapsed_ns = build_ns + local_read_ns + edge_write_ns + random_read_ns + churn_ns + collapse_ns;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;
    const retained_committed_bytes = graph.committedBytesEstimate();
    const retained_payload_resident_bytes = try residentBytes(allocator, Node, graph.nodes) +
        try residentBytes(allocator, u32, graph.dense_to_slot);
    const retained_mib = @as(f64, @floatFromInt(retained_committed_bytes)) / (1024.0 * 1024.0);

    std.debug.print("BENCH_RESULT: {d:.3} ms\n", .{elapsed_ms});
    std.debug.print("BENCH_INFO: impl=zig-safe-paged-slotmap nodes={} live={} peak_committed_mib={d:.2} retained_committed_mib={d:.2} peak_payload_resident_mib={d:.2} retained_payload_resident_mib={d:.2} virtual_reserved_mib={d:.2} bytes_per_capacity={d:.1} local_checksum={} random_checksum={}\n", .{
        capacity,
        graph.live_count,
        @as(f64, @floatFromInt(peak_committed_bytes)) / (1024.0 * 1024.0),
        retained_mib,
        @as(f64, @floatFromInt(peak_payload_resident_bytes)) / (1024.0 * 1024.0),
        @as(f64, @floatFromInt(retained_payload_resident_bytes)) / (1024.0 * 1024.0),
        @as(f64, @floatFromInt(virtual_bytes)) / (1024.0 * 1024.0),
        @as(f64, @floatFromInt(peak_committed_bytes)) / @as(f64, @floatFromInt(capacity)),
        checksum,
        random_checksum,
    });
    std.debug.print("BENCH_PHASES: impl=zig-safe-paged-slotmap build_ms={d:.3} local_read_ms={d:.3} edge_write_ms={d:.3} random_read_ms={d:.3} churn_ms={d:.3} collapse_ms={d:.3} sparse_scan_ms={d:.3} sparse_checksum={}\n", .{
        @as(f64, @floatFromInt(build_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(local_read_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(edge_write_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(random_read_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(churn_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(collapse_ns)) / 1_000_000.0,
        @as(f64, @floatFromInt(sparse_ns)) / 1_000_000.0,
        sparse_checksum,
    });
}
