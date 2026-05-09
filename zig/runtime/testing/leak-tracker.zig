// leak-tracker.zig — wrap any allocator with per-allocation @returnAddress
// capture so leak reports name the alloc site even when DebugAllocator's
// DWARF unwind returns zero frames (typical for fiber-stack allocs:
// switchTo lacks CFI → captureCurrentStackTrace yields the "(empty stack
// trace)" we see in stream-test-zig leak reports).
//
// Usage:
//
//     var tracker = LeakTracker.init(std.testing.allocator);
//     defer tracker.dumpLeaks("test name") catch {};
//     defer tracker.deinit();
//     const allocator = tracker.allocator();
//     // ... pass `allocator` everywhere instead of std.testing.allocator
//
// Output on leak:
//
//     [LEAK-TRACKER test name] 1 live alloc(s) at dump:
//       ptr=0x7f... len=64 align=8 ret_addr=0x55...90fc
//
// Resolve ret_addr with addr2line:
//
//     addr2line -e zig-cache/o/<hash>/test 0x55...90fc

const std = @import("std");

pub const LeakTracker = struct {
    inner: std.mem.Allocator,
    map: std.AutoHashMap(usize, AllocSite),
    map_lock: std.atomic.Value(u32),

    pub const AllocSite = struct {
        len: usize,
        alignment: u8,
        ret_addr: usize,
    };

    pub fn init(backing: std.mem.Allocator) LeakTracker {
        return .{
            .inner = backing,
            .map = std.AutoHashMap(usize, AllocSite).init(std.heap.c_allocator),
            .map_lock = std.atomic.Value(u32).init(0),
        };
    }

    pub fn deinit(self: *LeakTracker) void {
        self.map.deinit();
    }

    fn lock(self: *LeakTracker) void {
        while (self.map_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *LeakTracker) void {
        self.map_lock.store(0, .release);
    }

    pub fn allocator(self: *LeakTracker) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = trackedAlloc,
                .resize = trackedResize,
                .remap = trackedRemap,
                .free = trackedFree,
            },
        };
    }

    fn trackedAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *LeakTracker = @ptrCast(@alignCast(ctx));
        const ptr = self.inner.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.lock();
        defer self.unlock();
        self.map.put(@intFromPtr(ptr), .{
            .len = len,
            .alignment = @intFromEnum(alignment),
            .ret_addr = ret_addr,
        }) catch {};
        return ptr;
    }

    fn trackedResize(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *LeakTracker = @ptrCast(@alignCast(ctx));
        const ok = self.inner.rawResize(mem, alignment, new_len, ret_addr);
        if (ok) {
            self.lock();
            defer self.unlock();
            if (self.map.getPtr(@intFromPtr(mem.ptr))) |site| {
                site.len = new_len;
            }
        }
        return ok;
    }

    fn trackedRemap(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *LeakTracker = @ptrCast(@alignCast(ctx));
        const new_ptr = self.inner.rawRemap(mem, alignment, new_len, ret_addr) orelse return null;
        self.lock();
        defer self.unlock();
        const old_addr = @intFromPtr(mem.ptr);
        if (self.map.fetchRemove(old_addr)) |kv| {
            self.map.put(@intFromPtr(new_ptr), .{
                .len = new_len,
                .alignment = kv.value.alignment,
                .ret_addr = kv.value.ret_addr,
            }) catch {};
        }
        return new_ptr;
    }

    fn trackedFree(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *LeakTracker = @ptrCast(@alignCast(ctx));
        self.lock();
        _ = self.map.remove(@intFromPtr(mem.ptr));
        self.unlock();
        self.inner.rawFree(mem, alignment, ret_addr);
    }

    /// Print live allocations to stderr. Call before backing-allocator
    /// deinit so we have a complete view. Always returns; caller should
    /// `try` so missing allocator panics propagate.
    pub fn dumpLeaks(self: *LeakTracker, label: []const u8) !void {
        self.lock();
        defer self.unlock();
        if (self.map.count() == 0) return;
        std.debug.print("\n[LEAK-TRACKER {s}] {d} live alloc(s) at dump:\n", .{ label, self.map.count() });
        var it = self.map.iterator();
        while (it.next()) |e| {
            std.debug.print("  ptr=0x{x} len={d} align={d} ret_addr=0x{x}\n", .{
                e.key_ptr.*,
                e.value_ptr.len,
                e.value_ptr.alignment,
                e.value_ptr.ret_addr,
            });
        }
    }
};
