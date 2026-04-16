const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;

// Layered benchmark: isolate each source of CLEAR overhead vs raw Zig.
// Each layer adds one feature from the CLEAR runtime on top of the raw baseline.

const N_KEYS: usize = 1_000_000;
const N_SHARDS: usize = 128;
const N_WORKERS: usize = 32;

// ---- Zipf (same as bench_compare) ----
fn hFunc(x: f64, s: f64) f64 { return @exp(-s * @log(x)); }
fn hInt(x: f64, s: f64) f64 {
    const t = 1.0 - s;
    if (@abs(t) > 1e-8) return (std.math.pow(f64, x, t) - 1.0) / t;
    return @log(x);
}
fn hIntInv(x: f64, s: f64) f64 {
    const t = 1.0 - s;
    if (@abs(t) > 1e-8) return std.math.pow(f64, t * x + 1.0, 1.0 / t);
    return @exp(x);
}
fn zipfNext(state: *i64, n: i64, s: f64, hIntegral: f64, hFraction: f64) i64 {
    const hIntHalf = hInt(0.5, s);
    while (true) {
        state.* = state.* *% 6364136223846793005 +% 1442695040888963407;
        var uBits = state.*;
        if (uBits < 0) uBits = -uBits;
        var u: f64 = @as(f64, @floatFromInt(@mod(uBits, 1000000000))) / 1000000000.0;
        u = hIntegral + u * (hIntHalf - hIntegral);
        const x = hIntInv(u, s);
        var k: i64 = @intFromFloat(x + 0.5);
        if (k < 1) k = 1;
        if (k > n) k = n;
        const kf: f64 = @floatFromInt(k);
        if (kf - x <= hFraction) return k - 1;
        if (u >= hInt(kf + 0.5, s) - hFunc(kf, s)) return k - 1;
    }
    return 0;
}

var key_buf: [N_KEYS][]const u8 = undefined;

fn initKeys(alloc: std.mem.Allocator) !void {
    for (0..N_KEYS) |i| {
        key_buf[i] = try std.fmt.allocPrint(alloc, "key:{d}", .{i});
    }
}

fn nowMs() i64 {
    return @intCast(@divFloor(std.time.nanoTimestamp(), 1_000_000));
}

// Simulate CLEAR's frame allocator: a bump allocator backed by a fixed buffer.
const BumpAlloc = struct {
    buf: []u8,
    pos: usize = 0,

    fn alloc(self: *BumpAlloc, n: usize) []u8 {
        const result = self.buf[self.pos..][0..n];
        self.pos += n;
        return result;
    }

    fn reset(self: *BumpAlloc) void {
        self.pos = 0;
    }
};

// =========================================================================
// Layer 0: Raw baseline — pre-built keys, direct map access
// =========================================================================
fn layer0_raw(map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS)) i64 {
    const chunk = N_KEYS / N_WORKERS;
    const s: f64 = 1.0;
    const hIntegral = hInt(@as(f64, @floatFromInt(N_KEYS)) + 0.5, s);
    const hFraction = hFunc(1.5, s) - 1.0;

    const t0 = nowMs();
    var threads: [N_WORKERS]std.Thread = undefined;
    for (0..N_WORKERS) |wi| {
        const Ctx = struct {
            map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS),
            seed: i64, chunk_size: usize, hI: f64, hF: f64,
            fn run(ctx: @This()) void {
                var state: i64 = ctx.seed;
                var hits: usize = 0;
                for (0..ctx.chunk_size) |_| {
                    const k = zipfNext(&state, @intCast(N_KEYS), 1.0, ctx.hI, ctx.hF);
                    state = state *% 6364136223846793005 +% 1442695040888963407;
                    if (ctx.map.get(key_buf[@intCast(k)])) |_| hits += 1;
                }
                std.mem.doNotOptimizeAway(hits);
            }
        };
        threads[wi] = std.Thread.spawn(.{}, Ctx.run, .{Ctx{
            .map = map, .seed = @intCast(wi + 42), .chunk_size = chunk,
            .hI = hIntegral, .hF = hFraction,
        }}) catch unreachable;
    }
    for (0..N_WORKERS) |wi| threads[wi].join();
    return nowMs() - t0;
}

// =========================================================================
// Layer 1: + string formatting per access (fmt.count + bufPrint + alloc)
// Same allocator (c_allocator), no other CLEAR overhead
// =========================================================================
fn layer1_fmt(map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS)) i64 {
    const chunk = N_KEYS / N_WORKERS;
    const s: f64 = 1.0;
    const hIntegral = hInt(@as(f64, @floatFromInt(N_KEYS)) + 0.5, s);
    const hFraction = hFunc(1.5, s) - 1.0;
    const alloc = std.heap.c_allocator;

    const t0 = nowMs();
    var threads: [N_WORKERS]std.Thread = undefined;
    for (0..N_WORKERS) |wi| {
        const Ctx = struct {
            map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS),
            alloc: std.mem.Allocator,
            seed: i64, chunk_size: usize, hI: f64, hF: f64,
            fn run(ctx: @This()) void {
                var state: i64 = ctx.seed;
                var hits: usize = 0;
                for (0..ctx.chunk_size) |_| {
                    const k = zipfNext(&state, @intCast(N_KEYS), 1.0, ctx.hI, ctx.hF);
                    state = state *% 6364136223846793005 +% 1442695040888963407;
                    // Build key string the way CLEAR does
                    const n = std.fmt.count("key:{d}", .{k});
                    const buf = ctx.alloc.alloc(u8, n) catch unreachable;
                    _ = std.fmt.bufPrint(buf, "key:{d}", .{k}) catch unreachable;
                    if (ctx.map.get(buf)) |_| hits += 1;
                    ctx.alloc.free(buf);
                }
                std.mem.doNotOptimizeAway(hits);
            }
        };
        threads[wi] = std.Thread.spawn(.{}, Ctx.run, .{Ctx{
            .map = map, .alloc = alloc, .seed = @intCast(wi + 42), .chunk_size = chunk,
            .hI = hIntegral, .hF = hFraction,
        }}) catch unreachable;
    }
    for (0..N_WORKERS) |wi| threads[wi].join();
    return nowMs() - t0;
}

// =========================================================================
// Layer 2: + bump allocator (no free, simulates frame allocator)
// =========================================================================
fn layer2_bump(map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS)) i64 {
    const chunk = N_KEYS / N_WORKERS;
    const s: f64 = 1.0;
    const hIntegral = hInt(@as(f64, @floatFromInt(N_KEYS)) + 0.5, s);
    const hFraction = hFunc(1.5, s) - 1.0;
    const alloc = std.heap.c_allocator;

    const t0 = nowMs();
    var threads: [N_WORKERS]std.Thread = undefined;
    var bump_ptrs: [N_WORKERS][]u8 = undefined;
    for (0..N_WORKERS) |i| bump_ptrs[i] = alloc.alloc(u8, 4096) catch unreachable;
    for (0..N_WORKERS) |wi| {
        const Ctx = struct {
            map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS),
            bump_buf: []u8,
            seed: i64, chunk_size: usize, hI: f64, hF: f64,
            fn run(ctx: @This()) void {
                var bump = BumpAlloc{ .buf = ctx.bump_buf };
                var state: i64 = ctx.seed;
                var hits: usize = 0;
                for (0..ctx.chunk_size) |_| {
                    const k = zipfNext(&state, @intCast(N_KEYS), 1.0, ctx.hI, ctx.hF);
                    state = state *% 6364136223846793005 +% 1442695040888963407;
                    const n = std.fmt.count("key:{d}", .{k});
                    const buf = bump.alloc(n);
                    _ = std.fmt.bufPrint(buf, "key:{d}", .{k}) catch unreachable;
                    if (ctx.map.get(buf)) |_| hits += 1;
                    bump.reset();
                }
                std.mem.doNotOptimizeAway(hits);
            }
        };
        threads[wi] = std.Thread.spawn(.{}, Ctx.run, .{Ctx{
            .map = map, .bump_buf = bump_ptrs[wi], .seed = @intCast(wi + 42),
            .chunk_size = chunk, .hI = hIntegral, .hF = hFraction,
        }}) catch unreachable;
    }
    for (0..N_WORKERS) |wi| threads[wi].join();
    for (0..N_WORKERS) |i| alloc.free(bump_ptrs[i]);
    return nowMs() - t0;
}

// =========================================================================
// Layer 3: + vtable dispatch (bump alloc behind std.mem.Allocator interface)
// This is what CLEAR's frameAlloc() does — same bump, but through the vtable.
// =========================================================================
const VtableBump = struct {
    buf: []u8,
    pos: usize = 0,

    fn vtableAlloc(ctx: *anyopaque, n: usize, _: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *VtableBump = @ptrCast(@alignCast(ctx));
        if (self.pos + n > self.buf.len) return null;
        const result = self.buf[self.pos..][0..n];
        self.pos += n;
        return result.ptr;
    }
    fn vtableFree(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}
    fn vtableResize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool { return false; }
    fn vtableRemap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 { return null; }

    const vtable = std.mem.Allocator.VTable{
        .alloc = @ptrCast(&vtableAlloc),
        .free = @ptrCast(&vtableFree),
        .resize = @ptrCast(&vtableResize),
        .remap = @ptrCast(&vtableRemap),
    };

    fn allocator(self: *VtableBump) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn reset(self: *VtableBump) void { self.pos = 0; }
};

fn layer3_vtable(map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS)) i64 {
    const chunk = N_KEYS / N_WORKERS;
    const s: f64 = 1.0;
    const hIntegral = hInt(@as(f64, @floatFromInt(N_KEYS)) + 0.5, s);
    const hFraction = hFunc(1.5, s) - 1.0;
    const alloc = std.heap.c_allocator;

    const t0 = nowMs();
    var threads: [N_WORKERS]std.Thread = undefined;
    var bump_ptrs: [N_WORKERS][]u8 = undefined;
    for (0..N_WORKERS) |i| bump_ptrs[i] = alloc.alloc(u8, 4096) catch unreachable;
    for (0..N_WORKERS) |wi| {
        const Ctx = struct {
            map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS),
            bump_buf: []u8,
            seed: i64, chunk_size: usize, hI: f64, hF: f64,
            fn run(ctx: @This()) void {
                var vb = VtableBump{ .buf = ctx.bump_buf };
                const vtalloc = vb.allocator();
                var state: i64 = ctx.seed;
                var hits: usize = 0;
                for (0..ctx.chunk_size) |_| {
                    const k = zipfNext(&state, @intCast(N_KEYS), 1.0, ctx.hI, ctx.hF);
                    state = state *% 6364136223846793005 +% 1442695040888963407;
                    const n = std.fmt.count("key:{d}", .{k});
                    const buf = vtalloc.alloc(u8, n) catch unreachable;
                    _ = std.fmt.bufPrint(buf, "key:{d}", .{k}) catch unreachable;
                    if (ctx.map.get(buf)) |_| hits += 1;
                    vb.reset();
                }
                std.mem.doNotOptimizeAway(hits);
            }
        };
        threads[wi] = std.Thread.spawn(.{}, Ctx.run, .{Ctx{
            .map = map, .bump_buf = bump_ptrs[wi], .seed = @intCast(wi + 42),
            .chunk_size = chunk, .hI = hIntegral, .hF = hFraction,
        }}) catch unreachable;
    }
    for (0..N_WORKERS) |wi| threads[wi].join();
    for (0..N_WORKERS) |i| alloc.free(bump_ptrs[i]);
    return nowMs() - t0;
}

// =========================================================================
// Layer 4: + intToString + concat (CLEAR's OLD 2-alloc path)
// =========================================================================
fn layer4_old_interp(map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS)) i64 {
    const chunk = N_KEYS / N_WORKERS;
    const s: f64 = 1.0;
    const hIntegral = hInt(@as(f64, @floatFromInt(N_KEYS)) + 0.5, s);
    const hFraction = hFunc(1.5, s) - 1.0;
    const heap = std.heap.c_allocator;

    const t0 = nowMs();
    var threads: [N_WORKERS]std.Thread = undefined;
    var bump_ptrs: [N_WORKERS][]u8 = undefined;
    for (0..N_WORKERS) |i| bump_ptrs[i] = heap.alloc(u8, 4096) catch unreachable;
    for (0..N_WORKERS) |wi| {
        const Ctx = struct {
            map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS),
            bump_buf: []u8,
            seed: i64, chunk_size: usize, hI: f64, hF: f64,
            fn run(ctx: @This()) void {
                var vb = VtableBump{ .buf = ctx.bump_buf };
                const vtalloc = vb.allocator();
                var state: i64 = ctx.seed;
                var hits: usize = 0;
                for (0..ctx.chunk_size) |_| {
                    const k = zipfNext(&state, @intCast(N_KEYS), 1.0, ctx.hI, ctx.hF);
                    state = state *% 6364136223846793005 +% 1442695040888963407;
                    // Exactly what CLEAR used to emit: intToString + concat
                    const key = std.mem.concat(vtalloc, u8, &.{
                        "key:",
                        CheatLib.intToString(vtalloc, k) catch unreachable,
                        "",
                    }) catch unreachable;
                    if (ctx.map.get(key)) |_| hits += 1;
                    vb.reset();
                }
                std.mem.doNotOptimizeAway(hits);
            }
        };
        threads[wi] = std.Thread.spawn(.{}, Ctx.run, .{Ctx{
            .map = map, .bump_buf = bump_ptrs[wi], .seed = @intCast(wi + 42),
            .chunk_size = chunk, .hI = hIntegral, .hF = hFraction,
        }}) catch unreachable;
    }
    for (0..N_WORKERS) |wi| threads[wi].join();
    for (0..N_WORKERS) |i| heap.free(bump_ptrs[i]);
    return nowMs() - t0;
}

// =========================================================================
// Layer 5: stack-buffer formatting (0 allocations, theoretical minimum)
// =========================================================================
fn layer5_stack(map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS)) i64 {
    const chunk = N_KEYS / N_WORKERS;
    const s: f64 = 1.0;
    const hIntegral = hInt(@as(f64, @floatFromInt(N_KEYS)) + 0.5, s);
    const hFraction = hFunc(1.5, s) - 1.0;

    const t0 = nowMs();
    var threads: [N_WORKERS]std.Thread = undefined;
    for (0..N_WORKERS) |wi| {
        const Ctx = struct {
            map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS),
            seed: i64, chunk_size: usize, hI: f64, hF: f64,
            fn run(ctx: @This()) void {
                var state: i64 = ctx.seed;
                var hits: usize = 0;
                for (0..ctx.chunk_size) |_| {
                    const k = zipfNext(&state, @intCast(N_KEYS), 1.0, ctx.hI, ctx.hF);
                    state = state *% 6364136223846793005 +% 1442695040888963407;
                    // Stack buffer — zero allocations
                    var sb: [32]u8 = undefined;
                    const key = std.fmt.bufPrint(&sb, "key:{d}", .{k}) catch unreachable;
                    if (ctx.map.get(key)) |_| hits += 1;
                }
                std.mem.doNotOptimizeAway(hits);
            }
        };
        threads[wi] = std.Thread.spawn(.{}, Ctx.run, .{Ctx{
            .map = map, .seed = @intCast(wi + 42), .chunk_size = chunk,
            .hI = hIntegral, .hF = hFraction,
        }}) catch unreachable;
    }
    for (0..N_WORKERS) |wi| threads[wi].join();
    return nowMs() - t0;
}

// =========================================================================
// Runtime overhead layers — isolate each CLEAR fiber runtime cost
// All use stack-buf formatting (L5 baseline) + add one runtime feature.
// =========================================================================

// R1: + checkYield every iteration (counter + mask + branch)
fn runtime1_checkYield(map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS)) i64 {
    const chunk = N_KEYS / N_WORKERS;
    const s: f64 = 1.0;
    const hIntegral = hInt(@as(f64, @floatFromInt(N_KEYS)) + 0.5, s);
    const hFraction = hFunc(1.5, s) - 1.0;

    const t0 = nowMs();
    var threads: [N_WORKERS]std.Thread = undefined;
    for (0..N_WORKERS) |wi| {
        const Ctx = struct {
            map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS),
            seed: i64, chunk_size: usize, hI: f64, hF: f64,
            fn run(ctx: @This()) void {
                var state: i64 = ctx.seed;
                var hits: usize = 0;
                var yield_counter: u32 = 0;
                for (0..ctx.chunk_size) |_| {
                    const k = zipfNext(&state, @intCast(N_KEYS), 1.0, ctx.hI, ctx.hF);
                    state = state *% 6364136223846793005 +% 1442695040888963407;
                    var sb: [32]u8 = undefined;
                    const key = std.fmt.bufPrint(&sb, "key:{d}", .{k}) catch unreachable;
                    if (ctx.map.get(key)) |_| hits += 1;
                    // Simulate checkYield
                    yield_counter = (yield_counter +% 1) & 4095;
                    if (yield_counter == 0) {
                        std.mem.doNotOptimizeAway(yield_counter);
                    }
                }
                std.mem.doNotOptimizeAway(hits);
            }
        };
        threads[wi] = std.Thread.spawn(.{}, Ctx.run, .{Ctx{
            .map = map, .seed = @intCast(wi + 42), .chunk_size = chunk,
            .hI = hIntegral, .hF = hFraction,
        }}) catch unreachable;
    }
    for (0..N_WORKERS) |wi| threads[wi].join();
    return nowMs() - t0;
}

// R2: + loop mark save/restore (simulates arena getMark + rewind)
fn runtime2_loopMark(map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS)) i64 {
    const chunk = N_KEYS / N_WORKERS;
    const s: f64 = 1.0;
    const hIntegral = hInt(@as(f64, @floatFromInt(N_KEYS)) + 0.5, s);
    const hFraction = hFunc(1.5, s) - 1.0;

    const t0 = nowMs();
    var threads: [N_WORKERS]std.Thread = undefined;
    for (0..N_WORKERS) |wi| {
        const Ctx = struct {
            map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS),
            seed: i64, chunk_size: usize, hI: f64, hF: f64,
            fn run(ctx: @This()) void {
                var state: i64 = ctx.seed;
                var hits: usize = 0;
                // Simulate arena state that getMark/rewind touches
                var arena_cursor: usize = 0;
                var arena_block_index: usize = 0;
                var arena_large_count: usize = 0;
                var blocks_len: usize = 0;
                const static_block_len: usize = 4096; // non-zero = has static
                for (0..ctx.chunk_size) |_| {
                    // saveLoopMark: read 3 fields + conditional
                    const shift: usize = if (static_block_len > 0 and blocks_len > 0) 1 else 0;
                    const mark_bi = arena_block_index + shift;
                    const mark_cursor = arena_cursor;
                    const mark_large = arena_large_count;

                    const k = zipfNext(&state, @intCast(N_KEYS), 1.0, ctx.hI, ctx.hF);
                    state = state *% 6364136223846793005 +% 1442695040888963407;
                    var sb: [32]u8 = undefined;
                    const key = std.fmt.bufPrint(&sb, "key:{d}", .{k}) catch unreachable;
                    if (ctx.map.get(key)) |_| hits += 1;

                    // restoreLoopMark (rewind): conditional logic
                    const has_static = (static_block_len > 0);
                    if (has_static) {
                        if (mark_bi == 0) {
                            arena_block_index = 0;
                        } else {
                            arena_block_index = mark_bi - 1;
                        }
                    } else {
                        arena_block_index = mark_bi;
                    }
                    arena_cursor = mark_cursor;
                    // Check large objects (while loop that doesn't execute)
                    while (arena_large_count > mark_large) {
                        arena_large_count -= 1;
                    }
                    // Check blocks (while loop that doesn't execute)
                    while (blocks_len > arena_block_index + 1) {
                        blocks_len -= 1;
                    }
                }
                std.mem.doNotOptimizeAway(hits);
                std.mem.doNotOptimizeAway(arena_cursor);
            }
        };
        threads[wi] = std.Thread.spawn(.{}, Ctx.run, .{Ctx{
            .map = map, .seed = @intCast(wi + 42), .chunk_size = chunk,
            .hI = hIntegral, .hF = hFraction,
        }}) catch unreachable;
    }
    for (0..N_WORKERS) |wi| threads[wi].join();
    return nowMs() - t0;
}

// R3: + context pointer indirection (access everything through a heap-allocated struct ptr)
fn runtime3_ctxPtr(map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS)) i64 {
    const chunk = N_KEYS / N_WORKERS;
    const s: f64 = 1.0;
    const hIntegral = hInt(@as(f64, @floatFromInt(N_KEYS)) + 0.5, s);
    const hFraction = hFunc(1.5, s) - 1.0;
    const alloc = std.heap.c_allocator;

    const t0 = nowMs();
    var threads: [N_WORKERS]std.Thread = undefined;

    const BgCtx = struct {
        map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS),
        seed: i64, chunk_size: usize, hI: f64, hF: f64,
        n: i64, zipfSkew: f64,
    };

    var ctxs: [N_WORKERS]*BgCtx = undefined;
    for (0..N_WORKERS) |wi| {
        ctxs[wi] = alloc.create(BgCtx) catch unreachable;
        ctxs[wi].* = .{
            .map = map, .seed = @intCast(wi + 42), .chunk_size = chunk,
            .hI = hIntegral, .hF = hFraction, .n = @intCast(N_KEYS), .zipfSkew = s,
        };
        const WorkerFn = struct {
            fn run(ctx: *BgCtx) void {
                var state: i64 = ctx.seed;
                var hits: usize = 0;
                for (0..ctx.chunk_size) |_| {
                    const k = zipfNext(&state, ctx.n, ctx.zipfSkew, ctx.hI, ctx.hF);
                    state = state *% 6364136223846793005 +% 1442695040888963407;
                    var sb: [32]u8 = undefined;
                    const key = std.fmt.bufPrint(&sb, "key:{d}", .{k}) catch unreachable;
                    if (ctx.map.get(key)) |_| hits += 1;
                }
                std.mem.doNotOptimizeAway(hits);
            }
        };
        threads[wi] = std.Thread.spawn(.{}, WorkerFn.run, .{ctxs[wi]}) catch unreachable;
    }
    for (0..N_WORKERS) |wi| {
        threads[wi].join();
        alloc.destroy(ctxs[wi]);
    }
    return nowMs() - t0;
}

// R4: + ALL runtime overheads combined (checkYield + loopMark + ctxPtr)
fn runtime4_all(map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS)) i64 {
    const chunk = N_KEYS / N_WORKERS;
    const s: f64 = 1.0;
    const hIntegral = hInt(@as(f64, @floatFromInt(N_KEYS)) + 0.5, s);
    const hFraction = hFunc(1.5, s) - 1.0;
    const alloc = std.heap.c_allocator;

    const t0 = nowMs();
    var threads: [N_WORKERS]std.Thread = undefined;

    const BgCtx = struct {
        map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS),
        seed: i64, chunk_size: usize, hI: f64, hF: f64,
        n: i64, zipfSkew: f64,
    };

    var ctxs: [N_WORKERS]*BgCtx = undefined;
    for (0..N_WORKERS) |wi| {
        ctxs[wi] = alloc.create(BgCtx) catch unreachable;
        ctxs[wi].* = .{
            .map = map, .seed = @intCast(wi + 42), .chunk_size = chunk,
            .hI = hIntegral, .hF = hFraction, .n = @intCast(N_KEYS), .zipfSkew = s,
        };
        const WorkerFn = struct {
            fn run(ctx: *BgCtx) void {
                var state: i64 = ctx.seed;
                var hits: usize = 0;
                var yield_counter: u32 = 0;
                var arena_cursor: usize = 0;
                var arena_block_index: usize = 0;
                var arena_large_count: usize = 0;
                var blocks_len: usize = 0;
                const static_block_len: usize = 4096;
                for (0..ctx.chunk_size) |_| {
                    // saveLoopMark
                    const shift: usize = if (static_block_len > 0 and blocks_len > 0) 1 else 0;
                    const mark_bi = arena_block_index + shift;
                    const mark_cursor = arena_cursor;
                    const mark_large = arena_large_count;

                    const k = zipfNext(&state, ctx.n, ctx.zipfSkew, ctx.hI, ctx.hF);
                    state = state *% 6364136223846793005 +% 1442695040888963407;
                    var sb: [32]u8 = undefined;
                    const key = std.fmt.bufPrint(&sb, "key:{d}", .{k}) catch unreachable;
                    if (ctx.map.get(key)) |_| hits += 1;

                    // checkYield
                    yield_counter = (yield_counter +% 1) & 4095;
                    if (yield_counter == 0) std.mem.doNotOptimizeAway(yield_counter);

                    // restoreLoopMark
                    const has_static = (static_block_len > 0);
                    if (has_static) {
                        if (mark_bi == 0) { arena_block_index = 0; } else { arena_block_index = mark_bi - 1; }
                    } else { arena_block_index = mark_bi; }
                    arena_cursor = mark_cursor;
                    while (arena_large_count > mark_large) arena_large_count -= 1;
                    while (blocks_len > arena_block_index + 1) blocks_len -= 1;
                }
                std.mem.doNotOptimizeAway(hits);
                std.mem.doNotOptimizeAway(arena_cursor);
            }
        };
        threads[wi] = std.Thread.spawn(.{}, WorkerFn.run, .{ctxs[wi]}) catch unreachable;
    }
    for (0..N_WORKERS) |wi| {
        threads[wi].join();
        alloc.destroy(ctxs[wi]);
    }
    return nowMs() - t0;
}

// R5: + REAL CheatArena (use actual Runtime saveLoopMark/restoreLoopMark)
fn runtime5_realArena(map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS)) i64 {
    const chunk = N_KEYS / N_WORKERS;
    const s: f64 = 1.0;
    const hIntegral = hInt(@as(f64, @floatFromInt(N_KEYS)) + 0.5, s);
    const hFraction = hFunc(1.5, s) - 1.0;
    const CheatArena = @import("frame.zig").CheatArena;

    const t0 = nowMs();
    var threads: [N_WORKERS]std.Thread = undefined;
    for (0..N_WORKERS) |wi| {
        const Ctx = struct {
            map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS),
            seed: i64, chunk_size: usize, hI: f64, hF: f64,
            fn run(ctx: @This()) void {
                // Create a real CheatArena like the CLEAR runtime does
                const arena_buf = std.heap.c_allocator.alloc(u8, 64 * 1024) catch unreachable;
                defer std.heap.c_allocator.free(arena_buf);
                var arena = CheatArena.init(std.heap.c_allocator, arena_buf);
                defer arena.deinit();

                var state: i64 = ctx.seed;
                var hits: usize = 0;
                var yield_counter: u32 = 0;
                for (0..ctx.chunk_size) |_| {
                    // Real saveLoopMark
                    const mark = arena.getMark();

                    const k = zipfNext(&state, @intCast(N_KEYS), 1.0, ctx.hI, ctx.hF);
                    state = state *% 6364136223846793005 +% 1442695040888963407;
                    var sb: [32]u8 = undefined;
                    const key = std.fmt.bufPrint(&sb, "key:{d}", .{k}) catch unreachable;
                    if (ctx.map.get(key)) |_| hits += 1;

                    // checkYield
                    yield_counter = (yield_counter +% 1) & 4095;
                    if (yield_counter == 0) std.mem.doNotOptimizeAway(yield_counter);

                    // Real restoreLoopMark
                    arena.rewind(mark);
                }
                std.mem.doNotOptimizeAway(hits);
            }
        };
        threads[wi] = std.Thread.spawn(.{}, Ctx.run, .{Ctx{
            .map = map, .seed = @intCast(wi + 42), .chunk_size = chunk,
            .hI = hIntegral, .hF = hFraction,
        }}) catch unreachable;
    }
    for (0..N_WORKERS) |wi| threads[wi].join();
    return nowMs() - t0;
}

// R6: Exact CLEAR generated code pattern, running on native threads (not fibers)
fn runtime6_exactClear(map_arc: *CheatLib.Arc(CheatLib.MutexShardedStringMap([]const u8, N_SHARDS))) i64 {
    const chunk = N_KEYS / N_WORKERS;
    const s: f64 = 1.0;
    const hIntegral = hInt(@as(f64, @floatFromInt(N_KEYS)) + 0.5, s);
    const hFraction = hFunc(1.5, s) - 1.0;
    const heap = std.heap.c_allocator;
    const CheatArena = @import("frame.zig").CheatArena;

    const t0 = nowMs();
    var threads: [N_WORKERS]std.Thread = undefined;

    const BgCtx = struct {
        map: *CheatLib.Arc(CheatLib.MutexShardedStringMap([]const u8, N_SHARDS)),
        seed: i64, cnt: i64, n: i64, zipfSkew: f64, hIntegral: f64, hFraction: f64,
    };

    var ctxs: [N_WORKERS]*BgCtx = undefined;
    for (0..N_WORKERS) |wi| {
        ctxs[wi] = heap.create(BgCtx) catch unreachable;
        ctxs[wi].* = .{
            .map = map_arc, .seed = @intCast(wi + 42), .cnt = @intCast(chunk),
            .n = @intCast(N_KEYS), .zipfSkew = s, .hIntegral = hIntegral, .hFraction = hFraction,
        };
        const WorkerFn = struct {
            fn run(ctx_ptr: *BgCtx) void {
                // Replicate exact CLEAR pattern: CheatArena + frameAlloc vtable + error handling
                const arena_buf = std.heap.c_allocator.alloc(u8, 64 * 1024) catch unreachable;
                defer std.heap.c_allocator.free(arena_buf);
                var arena = CheatArena.init(std.heap.c_allocator, arena_buf);
                defer arena.deinit();
                // Wire allocator through vtable, same as Runtime.wireAllocator
                const ArenaVTable = struct {
                    fn vtAlloc(arena_ptr: *anyopaque, n: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
                        const a: *CheatArena = @ptrCast(@alignCast(arena_ptr));
                        return a.alloc(n, @intCast(ptr_align.toByteUnits()), ret_addr);
                    }
                    fn vtFree(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}
                    fn vtResize(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool { return false; }
                    fn vtRemap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 { return null; }
                    const table = std.mem.Allocator.VTable{
                        .alloc = @ptrCast(&vtAlloc),
                        .free = @ptrCast(&vtFree),
                        .resize = @ptrCast(&vtResize),
                        .remap = @ptrCast(&vtRemap),
                    };
                };
                const frame_alloc = std.mem.Allocator{
                    .ptr = &arena,
                    .vtable = &ArenaVTable.table,
                };

                const ctx = ctx_ptr;
                var hits: i64 = 0;
                var state: i64 = ctx.seed;
                var yield_counter: u32 = 0;

                var __for: i64 = 0;
                while (__for < ctx.cnt) : (__for += 1) {
                    // saveLoopMark
                    const __loop_mark = arena.getMark();

                    const k: i64 = zipfNext(&state, ctx.n, ctx.zipfSkew, ctx.hIntegral, ctx.hFraction);
                    state = state *% 6364136223846793005 +% 1442695040888963407;

                    // Exact CLEAR interp pattern: count + vtable alloc + bufPrint
                    const __n = std.fmt.count("key:{d}", .{k});
                    const __buf = frame_alloc.alloc(u8, __n) catch unreachable;
                    _ = std.fmt.bufPrint(__buf, "key:{d}", .{k}) catch unreachable;

                    // Arc deref + map get (exact CLEAR path)
                    const got: []const u8 = (ctx.map.ctrl.data.*.get(__buf)) orelse "";

                    if (got.len > 0) {
                        hits = hits + 1;
                    }

                    // checkYield
                    yield_counter = (yield_counter +% 1) & 4095;
                    if (yield_counter == 0) std.mem.doNotOptimizeAway(yield_counter);

                    // restoreLoopMark
                    arena.rewind(__loop_mark);
                }
                std.mem.doNotOptimizeAway(hits);
            }
        };
        threads[wi] = std.Thread.spawn(.{}, WorkerFn.run, .{ctxs[wi]}) catch unreachable;
    }
    for (0..N_WORKERS) |wi| {
        threads[wi].join();
        heap.destroy(ctxs[wi]);
    }
    return nowMs() - t0;
}

// R7: Native thread but on mmap'd stack-sized memory for locals
// Tests whether the 64KB mmap'd stack region causes cache/TLB issues
fn runtime7_mmapStack(map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS)) i64 {
    const chunk = N_KEYS / N_WORKERS;
    const s: f64 = 1.0;
    const hIntegral = hInt(@as(f64, @floatFromInt(N_KEYS)) + 0.5, s);
    const hFraction = hFunc(1.5, s) - 1.0;

    const t0 = nowMs();
    var threads: [N_WORKERS]std.Thread = undefined;
    for (0..N_WORKERS) |wi| {
        const Ctx = struct {
            map: *CheatLib.MutexShardedStringMap([]const u8, N_SHARDS),
            seed: i64, chunk_size: usize, hI: f64, hF: f64,
            fn run(ctx: @This()) void {
                // Allocate hot locals on mmap'd memory (like fiber stacks)
                const page = std.posix.mmap(
                    null,
                    4096,
                    std.posix.PROT.READ | std.posix.PROT.WRITE,
                    .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                    -1,
                    0,
                ) catch unreachable;
                defer std.posix.munmap(page);

                // Put state/hits on mmap'd page to simulate fiber stack access pattern
                const state_ptr: *i64 = @ptrCast(@alignCast(page.ptr));
                const hits_ptr: *usize = @ptrCast(@alignCast(page.ptr + 8));
                state_ptr.* = ctx.seed;
                hits_ptr.* = 0;

                for (0..ctx.chunk_size) |_| {
                    const k = zipfNext(state_ptr, @intCast(N_KEYS), 1.0, ctx.hI, ctx.hF);
                    state_ptr.* = state_ptr.* *% 6364136223846793005 +% 1442695040888963407;
                    if (ctx.map.get(key_buf[@intCast(k)])) |_| hits_ptr.* += 1;
                }
                std.mem.doNotOptimizeAway(hits_ptr.*);
            }
        };
        threads[wi] = std.Thread.spawn(.{}, Ctx.run, .{Ctx{
            .map = map, .seed = @intCast(wi + 42), .chunk_size = chunk,
            .hI = hIntegral, .hF = hFraction,
        }}) catch unreachable;
    }
    for (0..N_WORKERS) |wi| threads[wi].join();
    return nowMs() - t0;
}

// (R8 removed — scheduler integration too complex for standalone benchmark)

pub fn main() !void {
    const alloc = std.heap.c_allocator;
    try initKeys(alloc);

    var map = CheatLib.MutexShardedStringMap([]const u8, N_SHARDS){ .alloc = alloc };
    defer map.deinit(alloc, alloc);
    for (0..N_KEYS) |i| {
        try map.put(alloc, alloc, key_buf[i], key_buf[i]);
    }

    std.debug.print("\n=== Layered Overhead Analysis (zipf GET, {d} workers, {d} shards) ===\n\n", .{ N_WORKERS, N_SHARDS });

    // Run each layer 3 times, take best
    // Also run the full CLEAR benchmark for comparison
    std.debug.print("  CLEAR (from runner):                ~161ms (reference)\n\n", .{});

    const labels = [_][]const u8{
        "L0: raw (pre-built keys)         ",
        "L1: + fmt.count+bufPrint+c_alloc ",
        "L2: + bump alloc (no free)       ",
        "L3: + vtable dispatch            ",
        "L4: + intToString+concat (old)   ",
        "L5: stack-buf fmt (0 allocs)     ",
        "R1: L5 + checkYield             ",
        "R2: L5 + loopMark save/restore  ",
        "R3: L5 + ctx pointer indirection",
        "R4: L5 + ALL simulated overhead ",
        "R5: L5 + REAL CheatArena        ",
    };
    const funcs = [_]*const fn (*CheatLib.MutexShardedStringMap([]const u8, N_SHARDS)) i64{
        &layer0_raw, &layer1_fmt, &layer2_bump, &layer3_vtable, &layer4_old_interp, &layer5_stack,
        &runtime1_checkYield, &runtime2_loopMark, &runtime3_ctxPtr, &runtime4_all, &runtime5_realArena,
    };

    for (labels, funcs) |label, func| {
        var best: i64 = std.math.maxInt(i64);
        for (0..3) |_| {
            const ms = func(&map);
            if (ms < best) best = ms;
        }
        std.debug.print("  {s}  {d:>4}ms\n", .{ label, best });
    }

    // R6: exact CLEAR code on native threads (needs Arc-wrapped map)
    {
        const CheatArena = @import("frame.zig").CheatArena;
        _ = CheatArena;
        var arc_map = CheatLib.arcCreate(
            CheatLib.MutexShardedStringMap([]const u8, N_SHARDS),
            alloc,
            CheatLib.MutexShardedStringMap([]const u8, N_SHARDS){ .alloc = alloc },
        ) catch unreachable;
        for (0..N_KEYS) |i| {
            arc_map.ctrl.data.*.put(alloc, alloc, key_buf[i], key_buf[i]) catch unreachable;
        }
        var best: i64 = std.math.maxInt(i64);
        for (0..3) |_| {
            const ms = runtime6_exactClear(&arc_map);
            if (ms < best) best = ms;
        }
        std.debug.print("  R6: EXACT CLEAR code, native thr   {d:>4}ms\n", .{best});

        // R7: mmap'd stack memory
        best = std.math.maxInt(i64);
        for (0..3) |_| {
            const ms = runtime7_mmapStack(&map);
            if (ms < best) best = ms;
        }
        std.debug.print("  R7: native thr + mmap'd locals     {d:>4}ms\n", .{best});

        CheatLib.arcRelease(CheatLib.MutexShardedStringMap([]const u8, N_SHARDS), alloc, arc_map);
    }

    std.debug.print("\n", .{});
}
