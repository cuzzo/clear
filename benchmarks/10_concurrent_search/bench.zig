// Concurrent File Search — CLEAR Runtime Benchmark
//
// Uses CLEAR's scheduler/runtime API directly (hand-written Zig).
// Identical infrastructure to transpiled CLEAR programs:
//   - CheatLib.Promise(i64) for per-fiber result passing
//   - WaitGroup for fiber synchronization
//   - CLEAR Runtime arena (frameAlloc/heapAlloc)
//   - CLEAR Scheduler (single-threaded cooperative M:1)
//
// Algorithm:
//   1. Generate 128 test files of ~10 KB each (deterministic, not timed)
//   2. Spawn one fiber per file — each reads the file, counts "the"
//   3. Main fiber NEXT-s all promises (waits for each in order)
//   4. Sort by count descending, print top-10
//
// Build (handled by benchmarks/runner.rb):
//   zig build-exe bench.zig switch.S onRoot.S --name bench_clear -O ReleaseFast -lc

const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib     = CheatHeader.CheatLib;
const Runtime      = CheatHeader.Runtime;
const EbrContext   = CheatHeader.EbrContext;
const fp           = @import("scheduler.zig");
const fm           = @import("fiber-memory.zig");
const qs           = @import("queues.zig");

const N_FILES  : usize = 128;
const FILE_SIZE: usize = 10 * 1024;  // 10 KB per file
const NEEDLE          = "the";
const DATA_DIR        = "benchmarks/10_concurrent_search/data";

// ---------------------------------------------------------------------------
// Count non-overlapping occurrences of needle in haystack (same as
// CheatLib.countOccurrences, inlined here so bench.zig is self-contained)
// ---------------------------------------------------------------------------
fn countOccurrences(haystack: []const u8, needle: []const u8) i64 {
    if (needle.len == 0) return 0;
    var count: i64 = 0;
    var pos: usize = 0;
    while (pos + needle.len <= haystack.len) {
        if (std.mem.startsWith(u8, haystack[pos..], needle)) {
            count += 1;
            pos += needle.len;
        } else {
            pos += 1;
        }
    }
    return count;
}

// ---------------------------------------------------------------------------
// Generate test data (outside timing loop, idempotent)
// ---------------------------------------------------------------------------
// Word table: common English words + needle ("the") to ensure hits
const WORDS = [_][]const u8{
    "a", "an", "and", "are", "as", "at", "be", "been", "but", "by",
    "do", "for", "from", "had", "has", "have", "he", "her", "him", "his",
    "in", "is", "it", "its", "may", "me", "my", "no", "not", "of",
    "on", "or", "our", "out", "she", "so", "than", "that", "the", "their",
    "them", "then", "there", "they", "this", "to", "up", "was", "we", "were",
    "when", "which", "who", "will", "with", "would", "you", "your", "time", "way",
};

fn generateTestData(allocator: std.mem.Allocator) !void {
    // Create data dir if needed
    std.fs.cwd().makeDir(DATA_DIR) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Skip generation if all files already exist
    var dir = try std.fs.cwd().openDir(DATA_DIR, .{ .iterate = true });
    var existing: usize = 0;
    var it = dir.iterate();
    while (try it.next()) |_| existing += 1;
    dir.close();
    if (existing >= N_FILES) return;

    const buf = try allocator.alloc(u8, FILE_SIZE);
    defer allocator.free(buf);

    var i: usize = 0;
    while (i < N_FILES) : (i += 1) {
        // Each file gets a different needle density:
        //   file 0 has very few "the"s, file 127 has many.
        // We achieve this by biasing the RNG: higher i → more "the" picks.
        var rng = std.Random.DefaultPrng.init(
            @as(u64, i) *% 6364136223846793005 +% 1442695040888963407
        );
        const rand = rng.random();

        var pos: usize = 0;
        while (pos + 6 < FILE_SIZE) {
            // Pick a word. With probability proportional to i/N_FILES, use "the".
            const word = blk: {
                const r = rand.intRangeAtMost(u32, 0, N_FILES - 1);
                if (r < i) {
                    break :blk @as([]const u8, "the");
                } else {
                    const idx = rand.intRangeAtMost(usize, 0, WORDS.len - 2); // skip "the" at WORDS[38]
                    break :blk WORDS[idx];
                }
            };
            @memcpy(buf[pos..][0..word.len], word);
            pos += word.len;
            if (pos < FILE_SIZE) {
                buf[pos] = ' ';
                pos += 1;
            }
        }
        while (pos < FILE_SIZE) : (pos += 1) buf[pos] = '\n';

        var fname: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&fname, DATA_DIR ++ "/file{d:0>3}.txt", .{i});
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(buf);
    }
}

// ---------------------------------------------------------------------------
// Per-fiber context: holds path index + promise inner cell
// ---------------------------------------------------------------------------
const SearchCtx = struct {
    file_idx:  usize,
    allocator: std.mem.Allocator,
    inner:     *CheatLib.Promise(i64).Inner,

    // TaskFn signature: fn(*anyopaque rt, ?*anyopaque ctx) anyerror!void
    fn run(_: *anyopaque, raw_ctx: ?*anyopaque) anyerror!void {
        const ctx: *SearchCtx = @ptrCast(@alignCast(raw_ctx.?));

        var fname: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&fname, DATA_DIR ++ "/file{d:0>3}.txt", .{ctx.file_idx});

        const content = std.fs.cwd().readFileAlloc(ctx.allocator, path, 1024 * 1024) catch {
            ctx.inner.result = 0;
            ctx.inner.wg.done();
            return;
        };
        defer ctx.allocator.free(content);

        ctx.inner.result = countOccurrences(content, NEEDLE);
        ctx.inner.wg.done();
    }
};

// ---------------------------------------------------------------------------
// Result: (file index, count) for sorting
// ---------------------------------------------------------------------------
const Result = struct {
    file_idx: usize,
    count:    i64,

    fn descending(_: void, a: Result, b: Result) bool {
        return a.count > b.count;
    }
};

// ---------------------------------------------------------------------------
// cheatMain: runs inside the scheduler as the root fiber
// ---------------------------------------------------------------------------
fn cheatMain(rt: *Runtime) !void {
    const alloc = rt.heapAlloc();
    const sched = rt.getSched();

    // Allocate N context structs + N promise handles on the heap
    const ctxs     = try alloc.alloc(SearchCtx,             N_FILES);
    defer alloc.free(ctxs);
    const promises = try alloc.alloc(CheatLib.Promise(i64), N_FILES);
    defer alloc.free(promises);

    // Spawn one fiber per file
    var i: usize = 0;
    while (i < N_FILES) : (i += 1) {
        promises[i] = try CheatLib.Promise(i64).spawn(alloc, sched);
        ctxs[i] = SearchCtx{
            .file_idx  = i,
            .allocator = alloc,
            .inner     = promises[i].inner,
        };
        try sched.submitSpawn(
            @intFromPtr(&Runtime.entryWrapper),
            @as(qs.TaskFn, @ptrCast(&SearchCtx.run)),
            @ptrCast(&ctxs[i]),
            .{},
        );
    }

    // Collect results — NEXT blocks until each fiber writes its result
    const results = try alloc.alloc(Result, N_FILES);
    defer alloc.free(results);

    i = 0;
    while (i < N_FILES) : (i += 1) {
        results[i] = .{ .file_idx = i, .count = promises[i].next() };
    }

    // Sort by count descending
    std.mem.sort(Result, results, {}, Result.descending);

    // Print top-10
    std.debug.print("Top 10 files by '{s}' count:\n", .{NEEDLE});
    const top = @min(10, results.len);
    i = 0;
    while (i < top) : (i += 1) {
        std.debug.print("  file{d:0>3}.txt  {d}\n",
            .{ results[i].file_idx, results[i].count });
    }
}

// ---------------------------------------------------------------------------
// main: boilerplate identical to transpiled CLEAR programs
// ---------------------------------------------------------------------------
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Generate test data (not timed)
    try generateTestData(allocator);

    // 2. Standard CLEAR runtime setup
    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    var rt = try Runtime.init(allocator, 4 * 1024 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();

    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(allocator);
    }
    fp.active_scheduler = &sched;

    // 3. Submit cheatMain as a Large-stack fiber (it allocates 2×N pointers)
    const MainRunner = struct {
        outer_rt: *Runtime,
        fn run(_: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw_args.?));
            try cheatMain(self.outer_rt);
        }
    };
    var main_runner = MainRunner{ .outer_rt = &rt };

    // 4. Time only the search phase
    const t0 = std.time.nanoTimestamp();

    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(qs.TaskFn, @ptrCast(&MainRunner.run)),
        &main_runner,
        .{ .stack_size = .Large },
    );
    sched.run();

    const t1 = std.time.nanoTimestamp();
    const elapsed_s = @as(f64, @floatFromInt(t1 - t0)) / 1e9;
    std.debug.print("Time: {d:.4} s\n", .{elapsed_s});
}
