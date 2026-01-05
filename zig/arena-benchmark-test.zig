const std = @import("std");
const CheatArena = @import("frame.zig").CheatArena;

// Link LibC for the malloc comparison
pub const std_options = struct {
    pub const log_level = .info;
};

const ITERATIONS = 100_000;
const LIST_SIZE = 50; // Items per list

test "Benchmark: CheatArena vs Malloc (ArrayList)" {
    const stdout = std.debug.print;

    // -------------------------------------------------------------------------
    // 1. BENCHMARK: CHEAT ARENA
    // -------------------------------------------------------------------------
    {
        // We use c_allocator as the backing for the arena so we measure
        // purely the overhead of the Arena logic vs raw Malloc logic.
        var arena = CheatArena.init(std.heap.c_allocator);
        defer arena.deinit();

        // Create the interface for the ArrayList to use
        const Wrapper = struct {
            fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, r: usize) ?[*]u8 {
                const self: *CheatArena = @ptrCast(@alignCast(ctx));
                const align_u8 = @as(u8, @intCast(alignment.toByteUnits()));
                return self.alloc(n, align_u8, r);
            }
            fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, r: usize) bool {
                _ = ctx; _ = buf; _ = alignment; _ = new_len; _ = r;
                return false; // Arena cannot resize in place
            }
            fn free(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize) void {}
            fn remap(ctx: *anyopaque, m: []u8, a: std.mem.Alignment, n: usize, r: usize) ?[*]u8 {
                _ = ctx; _ = m; _ = a; _ = n; _ = r;
                return null;
            }
        };
        const arena_allocator = std.mem.Allocator{
            .ptr = &arena,
            .vtable = &.{ .alloc = Wrapper.alloc, .resize = Wrapper.resize, .free = Wrapper.free, .remap = Wrapper.remap },
        };

        var timer = try std.time.Timer.start();

        var i: usize = 0;
        while (i < ITERATIONS) : (i += 1) {
            var list = std.ArrayListUnmanaged(u64){};

            // Mark the start of the "Scope"
            const mark = arena.getMark();

            // Simulate work: Grow a list
            var j: usize = 0;
            while (j < LIST_SIZE) : (j += 1) {
                try list.append(arena_allocator, @intCast(j));
            }

            // "Free" everything at end of scope
            arena.rewind(mark);
        }

        const arena_time = timer.read();
        stdout("\n[Arena ] {d} iterations of {d} items: {d}ms\n", .{ITERATIONS, LIST_SIZE, arena_time / 1_000_000});
    }

    // -------------------------------------------------------------------------
    // 2. BENCHMARK: MALLOC (System Allocator)
    // -------------------------------------------------------------------------
    {
        const malloc_allocator = std.heap.c_allocator;

        var timer = try std.time.Timer.start();

        var i: usize = 0;
        while (i < ITERATIONS) : (i += 1) {
            var list = std.ArrayListUnmanaged(u64){};

            // Simulate work: Grow a list
            var j: usize = 0;
            while (j < LIST_SIZE) : (j += 1) {
                try list.append(malloc_allocator, @intCast(j));
            }

            // Actually free memory
            list.deinit(malloc_allocator);
        }

        const malloc_time = timer.read();
        stdout("[Malloc] {d} iterations of {d} items: {d}ms\n", .{ITERATIONS, LIST_SIZE, malloc_time / 1_000_000});
    }

    // -------------------------------------------------------------------------
    // 3. BENCHMARK: ZIG GPA (General Purpose Allocator)
    // -------------------------------------------------------------------------
    {
        // This is often slower than C malloc but safer (detects leaks)
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const gpa_allocator = gpa.allocator();

        var timer = try std.time.Timer.start();

        var i: usize = 0;
        while (i < ITERATIONS) : (i += 1) {
            var list = std.ArrayListUnmanaged(u64){};

            var j: usize = 0;
            while (j < LIST_SIZE) : (j += 1) {
                try list.append(gpa_allocator, @intCast(j));
            }

            list.deinit(gpa_allocator);
        }

        const gpa_time = timer.read();
        stdout("[GPA   ] {d} iterations of {d} items: {d}ms\n", .{ITERATIONS, LIST_SIZE, gpa_time / 1_000_000});
    }
}

