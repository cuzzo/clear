const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
pub const Runtime = @import("runtime.zig").Runtime;
const fc = @import("fiber-core.zig");
const fp = @import("scheduler.zig");

pub const EbrContext = @import("ebr.zig").EbrContext;
const Task = @import("queues.zig").Task;
const Fiber = fc.Fiber;

// Concurrency primitives re-exported for DO block fork-join support.
pub const WaitGroup = fp.WaitGroup;
pub const Semaphore = fp.Semaphore;
pub const TaskFn = @import("queues.zig").TaskFn;

// Scheduler + fiber-memory re-exported for test harness scheduler setup.
pub const scheduler = fp;
pub const fiber_memory = @import("fiber-memory.zig");


// Helper Functions
// Cached cwd file descriptor — resolved once, used by readFile/writeFile
// so they can use openat() (a single syscall) instead of std.fs.cwd()
// which needs deep stack frames.
var __cwd_fd: ?std.posix.fd_t = null;
fn getCwdFd() std.posix.fd_t {
    if (__cwd_fd) |fd| return fd;
    __cwd_fd = std.fs.cwd().fd;
    return __cwd_fd.?;
}

// Open a file relative to cwd using direct openat syscall.
// Null-terminates the path inline — zero heap alloc, minimal stack.
noinline fn openPathFd(path: []const u8, flags: std.posix.O, mode: std.posix.mode_t) !std.posix.fd_t {
    if (path.len > 255) return error.NameTooLong;
    var buf: [256]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.posix.openatZ(getCwdFd(), buf[0..path.len :0], flags, mode);
}

pub const CheatLib = struct {
    // -----------------------------------------------------------------------
    // Range: a contiguous numeric range [start, end) (end is always exclusive)
    // Created via (start..<end) or (start..<=end) in CLEAR source.
    pub const Range = struct {
        start: f64,
        end: f64,  // exclusive end

        pub fn len(self: Range) f64 {
            return self.end - self.start;
        }

        pub fn contains(self: Range, val: f64) bool {
            return val >= self.start and val < self.end;
        }
    };


    // Read from a socket via io_uring IORING_OP_RECV.
    // Submits a single recv and yields; CQE result is the byte count.
    pub noinline fn read(fd: i32, buffer: []u8) !usize {
        const sched = fp.active_scheduler;
        const task = sched.getCurrent();
        var waiter = fp.Scheduler.IoWaiter{ .task = task };
        try sched.submitRecv(&waiter, fd, buffer);
        task.base.yield();
        if (waiter.result < 0) return fp.Scheduler.ioError(waiter.result);
        return @intCast(waiter.result);
    }

    // List / Dynamic Array

    pub fn makeList(comptime T: type, allocator: std.mem.Allocator, items: []const T) !std.ArrayListUnmanaged(T) {
        var list = try std.ArrayListUnmanaged(T).initCapacity(allocator, items.len);
        list.appendSliceAssumeCapacity(items);
        return list;
    }

    // Promote a @list's arena-backed buffer to heap before returning from a frame-using
    // function.  The frame arena rewinds on function exit; without promotion the caller
    // would hold a dangling pointer.  After promotion the caller must deinit with
    // rt.heapAlloc() — the annotator sets heap_list=true on the receiving variable so
    // emit_cleanup emits the correct allocator.
    //
    // Empty lists are a no-op (items.len == 0 means no backing allocation).
    pub fn promoteList(comptime T: type, rt: *Runtime, list: *std.ArrayListUnmanaged(T)) !void {
        if (list.items.len == 0) return;
        const heap_buf = try rt.heapAlloc().alloc(T, list.items.len);
        @memcpy(heap_buf, list.items);
        list.items = heap_buf;
        list.capacity = heap_buf.len;
    }

    // Works for ArrayListUnmanaged (has .items) AND Standard Slices (direct access)
    // Also handles casting the index to usize automatically.
    // Unwraps optional containers (e.g. from hashmap.get()) before indexing.
    pub fn getAt(container: anytype, index: anytype) ElementType(@TypeOf(container)) {
        const i: usize = @intCast(index);
        const c = if (@typeInfo(@TypeOf(container)) == .optional) container.? else container;

        if (@hasField(@TypeOf(c), "items")) {
            return c.items[i];
        } else {
            return c[i];
        }
    }

    fn ElementType(comptime C: type) type {
        const Inner = if (@typeInfo(C) == .optional) @typeInfo(C).optional.child else C;
        if (@hasField(Inner, "items")) {
            // ArrayList: .items is []T, element type is T
            for (@typeInfo(Inner).@"struct".fields) |f| {
                if (std.mem.eql(u8, f.name, "items"))
                    return std.meta.Elem(f.type);
            }
            unreachable;
        } else {
            return std.meta.Elem(Inner);
        }
    }

    // Byte-level character access: returns a single-byte slice ([]const u8).
    // Used by CLEAR's String@raw buf[i] indexing.
    pub noinline fn charAt(str: []const u8, index: anytype) []const u8 {
        const idx = @as(i64, @intCast(index));
        if (idx < 0) return "";
        const i: usize = @intCast(idx);
        if (i >= str.len) return "";
        return str[i .. i + 1];
    }

    // UTF-8 codepoint count. Returns the number of Unicode codepoints in the string.
    // Falls back to byte count on invalid UTF-8.
    pub fn codepointCount(str: []const u8) i64 {
        return @intCast(std.unicode.utf8CountCodepoints(str) catch str.len);
    }

    // UTF-8 codepoint access: returns the i-th codepoint as a multi-byte slice.
    // O(n) per call — iterates from the start. Returns "" on out-of-bounds or invalid UTF-8.
    pub fn charAtCodepoint(alloc: std.mem.Allocator, str: []const u8, index: anytype) ![]const u8 {
        Runtime.profileAlloc(1);
        const target: usize = @intCast(index);
        const view = std.unicode.Utf8View.initUnchecked(str);
        var it = view.iterator();
        var i: usize = 0;
        while (it.nextCodepointSlice()) |cp_slice| {
            if (i == target) {
                const result = try alloc.dupe(u8, cp_slice);
                return result;
            }
            i += 1;
        }
        return "";
    }

    // Works for Lists and Slices because it modifies the memory the slice points to.
    pub fn setAt(container: anytype, index: anytype, value: anytype) void {
        const i: usize = @intCast(index);

        if (@hasField(@TypeOf(container), "items")) {
            // ArrayListUnmanaged
            container.items[i] = value;
        } else {
            // Standard Slice
            container[i] = value;
        }
    }

    pub fn concat(allocator: std.mem.Allocator, s1: []const u8, s2: []const u8) ![]const u8 {
        Runtime.profileAlloc(s1.len + s2.len);
        return try std.mem.concat(allocator, u8, &.{ s1, s2 });
    }

    // Polymorphic Length (Strings or Lists)
    // Unwraps optional containers (e.g. from hashmap.get()) before measuring.
    pub fn len(container: anytype) i64 {
        const c = if (@typeInfo(@TypeOf(container)) == .optional) container.? else container;
        // If it has .items (ArrayList), use that. Otherwise assume it's a Slice.
        if (@hasField(@TypeOf(c), "items")) {
            return @intCast(c.items.len);
        } else {
            return @intCast(c.len);
        }
    }

    // =========================================================================
    // String-keyed HashMap (StringHashMapUnmanaged)
    //
    // Option 1 — Arena bucket array:
    //   mapPut takes two allocators:
    //     key_alloc    — heap allocator for key string copies (keys must
    //                    outlive the frame; GPA ensures this).
    //   Both key copies and bucket array use frameAlloc (bump, ~2 ns/alloc).
    //   mapPromote() is called before RETURN to clone both to heapAlloc for
    //   maps that escape their function.  Non-escaping maps pay zero GPA cost.
    //   mapDeinit() is only called for promoted (heap-backed) maps.
    // =========================================================================

    pub fn makeHashMap(comptime V: type) std.StringHashMapUnmanaged(V) {
        return std.StringHashMapUnmanaged(V){};
    }

    // Both key copies and bucket array go to frameAlloc (bump, ~2 ns per alloc).
    // Keys are re-copied to heapAlloc by mapPromote() when the map escapes its frame.
    pub fn mapPut(comptime V: type, key_alloc: std.mem.Allocator, bucket_alloc: std.mem.Allocator, map: *std.StringHashMapUnmanaged(V), key: []const u8, value: V) !void {
        if (map.getPtr(key)) |val_ptr| {
            cleanup(V, bucket_alloc, val_ptr);
            val_ptr.* = value;
            return;
        }
        const key_copy = try key_alloc.dupe(u8, key);
        try map.put(bucket_alloc, key_copy, value);
    }

    // -----------------------------------------------------------------------
    // StringMap(V) — thin wrapper around StringHashMapUnmanaged(V) that
    // provides the same .put()/.get()/.remove()/.contains() API as
    // PartitionedStringMap and ShardedStringMap.  This allows functions to
    // accept any map variant via `anytype` — changing HashMap to
    // HashMap@sharded(N) at the declaration site is a one-line change that
    // doesn't ripple through function signatures.
    // -----------------------------------------------------------------------
    pub fn StringMap(comptime V: type) type {
        return struct {
            const Self = @This();
            inner: std.StringHashMapUnmanaged(V) = .{},
            alloc: std.mem.Allocator = std.heap.page_allocator, // overwritten at init

            /// All operations use self.alloc — set at construction by transpiler.
            /// The key_alloc/bucket_alloc params are kept for backward compat but ignored.
            /// For tagged union values with []const u8 fields, the string data is
            /// heap-duped so it survives loop-mark arena rewinds.
            /// TAKES ownership of value. Strings are duped (may be rodata/frame).
            /// TAKES ownership of value. No implicit copies. Caller must
            /// ensure all data (including strings) is heap-owned.
            pub fn put(self: *Self, key_alloc: std.mem.Allocator, bucket_alloc: std.mem.Allocator, key: []const u8, value: V) !void {
                _ = key_alloc;
                _ = bucket_alloc;
                const stored_value = value;
                if (self.inner.getPtr(key)) |val_ptr| {
                    CheatLib.cleanup(V, self.alloc, val_ptr);
                    val_ptr.* = stored_value;
                    return;
                }
                const key_copy = try self.alloc.dupe(u8, key);
                try self.inner.put(self.alloc, key_copy, stored_value);
            }


            pub fn get(self: anytype, key: []const u8) ?V {
                return self.inner.get(key);
            }

            pub fn contains(self: anytype, key: []const u8) bool {
                return self.inner.contains(key);
            }

            pub fn remove(self: *Self, key_alloc: std.mem.Allocator, key: []const u8) void {
                _ = key_alloc;
                if (self.inner.fetchRemove(key)) |kv| {
                    self.alloc.free(kv.key);
                    var val = kv.value;
                    CheatLib.cleanup(V, self.alloc, &val);
                }
            }

            pub fn count(self: *Self) i64 {
                return @intCast(self.inner.count());
            }

            pub fn deinit(self: *Self, key_alloc: std.mem.Allocator, bucket_alloc: std.mem.Allocator) void {
                _ = key_alloc;
                _ = bucket_alloc;
                var it = self.inner.iterator();
                while (it.next()) |entry| {
                    self.alloc.free(entry.key_ptr.*);
                    CheatLib.cleanup(V, self.alloc, entry.value_ptr);
                }
                self.inner.deinit(self.alloc);
            }

            /// Free heap-allocated payloads inside tagged union values.

            // Delegate to inner for code that still uses raw HashMap API
            pub fn getPtr(self: *Self, key: []const u8) ?*V {
                return self.inner.getPtr(key);
            }

            pub fn iterator(self: *Self) @TypeOf(self.inner).Iterator {
                return self.inner.iterator();
            }

            pub fn keyIterator(self: *Self) @TypeOf(self.inner).KeyIterator {
                return self.inner.keyIterator();
            }
        };
    }

    /// Promotes a frame-allocated string map to heap before it escapes a function.
    /// Clones the bucket array to heap (via map.clone) and re-dupes each key string
    /// to heap so both survive the caller's frame rewind.  Called by the transpiler
    /// immediately before `return m` for any String HashMap identifier.
    pub fn mapPromote(comptime V: type, heap: std.mem.Allocator, map: *std.StringHashMapUnmanaged(V)) !void {
        // Clone bucket array to heap; key pointers still reference frame arena at this point.
        var promoted = try map.clone(heap);
        // Re-copy each key string to heap, fixing the frame-arena pointers in-place.
        var it = promoted.keyIterator();
        while (it.next()) |k| k.* = try heap.dupe(u8, k.*);
        // Replace original (frame-backed) map with the fully heap-backed clone.
        map.* = promoted;
    }

    // Free all heap-duplicated key strings, then deinit the bucket array.
    // Used only for promoted maps (heap_map=true); frame-scoped maps use m.deinit(frameAlloc).
    pub fn mapDeinit(comptime V: type, key_alloc: std.mem.Allocator, bucket_alloc: std.mem.Allocator, map: *std.StringHashMapUnmanaged(V)) void {
        var it = map.keyIterator();
        while (it.next()) |k| key_alloc.free(k.*);
        map.deinit(bucket_alloc);
    }

    // Smart return: if V is ArrayListUnmanaged(T), returns []T instead of the list struct.
    pub fn mapGet(comptime V: type, map: std.StringHashMapUnmanaged(V), key: []const u8) ?V {
        return map.get(key);
    }

    // Delete a key. Frees the heap-duplicated key string via key_alloc.
    pub fn mapDelete(comptime V: type, key_alloc: std.mem.Allocator, map: *std.StringHashMapUnmanaged(V), key: []const u8) void {
        if (map.fetchRemove(key)) |entry| key_alloc.free(entry.key);
    }

    pub fn mapContains(comptime V: type, map: std.StringHashMapUnmanaged(V), key: []const u8) bool {
        return map.contains(key);
    }

    pub fn mapCount(comptime V: type, map: std.StringHashMapUnmanaged(V)) i64 {
        return @intCast(map.count());
    }

    pub fn mapKeys(comptime V: type, allocator: std.mem.Allocator, map: std.StringHashMapUnmanaged(V)) ![][]const u8 {
        const result = try allocator.alloc([]const u8, map.count());
        var it = map.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) result[i] = k.*;
        return result;
    }

    pub fn mapValues(comptime V: type, allocator: std.mem.Allocator, map: std.StringHashMapUnmanaged(V)) ![]V {
        const result = try allocator.alloc(V, map.count());
        var it = map.valueIterator();
        var i: usize = 0;
        while (it.next()) |v| : (i += 1) result[i] = v.*;
        return result;
    }

    // Helper: Check if type is ArrayListUnmanaged
    fn isArrayListUnmanaged(comptime T: type) bool {
        if (@typeInfo(T) != .@"struct") return false;
        return @hasField(T, "items") and @hasField(T, "capacity") and !@hasField(T, "allocator");
    }

    // Helper: Get element type from ArrayListUnmanaged
    fn ArrayListElement(comptime T: type) type {
        const items_field = @typeInfo(T).@"struct".fields[0];
        const slice_info = @typeInfo(items_field.type).pointer;
        return slice_info.child;
    }

    // (MapGetReturnType removed — mapGet now returns ?V directly)

    // =========================================================================
    // Numeric-keyed HashMap (Option 3)
    //
    // For integer keys (i64, u64, …): std.AutoHashMapUnmanaged(K, V).
    // For float keys (f64, f32):      std.HashMapUnmanaged with a custom
    //   context that bit-casts the float to u64 before hashing — avoids
    //   NaN/+0/-0 equality issues and satisfies Zig's hashability rules.
    //
    //   MUTABLE m: HashMap<Number, Number> = {};  →  NumericMapType(f64,f64)
    //   MUTABLE m: HashMap<Int64, Number>  = {};  →  NumericMapType(i64,f64)
    //
    // All numericMap* functions accept *NumericMapType(K,V) so callers never
    // need to know the distinction.
    // =========================================================================

    /// Returns the concrete Zig map type for a numeric-keyed CLEAR HashMap.
    /// Integer keys → AutoHashMapUnmanaged (Zig default).
    /// Float keys   → HashMapUnmanaged with a bit-cast context (NaN-safe).
    pub fn NumericMapType(comptime K: type, comptime V: type) type {
        if (@typeInfo(K) == .float) {
            // Bit-cast context: hash via murmur-finalised u64 bit-pattern.
            const Ctx = struct {
                pub fn hash(_: @This(), k: K) u64 {
                    var bits: u64 = @bitCast(@as(f64, k));
                    bits ^= bits >> 33;
                    bits *%= 0xff51afd7ed558ccd;
                    bits ^= bits >> 33;
                    bits *%= 0xc4ceb9fe1a85ec53;
                    bits ^= bits >> 33;
                    return bits;
                }
                pub fn eql(_: @This(), a: K, b: K) bool {
                    return @as(u64, @bitCast(@as(f64, a))) ==
                           @as(u64, @bitCast(@as(f64, b)));
                }
            };
            return std.HashMapUnmanaged(K, V, Ctx, 80);
        }
        return std.AutoHashMapUnmanaged(K, V);
    }

    pub fn numericMapPut(comptime K: type, comptime V: type, alloc: std.mem.Allocator, map: *NumericMapType(K, V), key: K, value: V) !void {
        const gop = try map.getOrPut(alloc, key);
        if (gop.found_existing) {
            if (comptime needsCleanup(V)) cleanup(V, alloc, gop.value_ptr);
        }
        gop.value_ptr.* = value;
    }

    pub fn numericMapGet(comptime K: type, comptime V: type, map: NumericMapType(K, V), key: K) ?V {
        return map.get(key);
    }

    pub fn numericMapDelete(comptime K: type, comptime V: type, alloc: std.mem.Allocator, map: *NumericMapType(K, V), key: K) void {
        if (map.fetchRemove(key)) |kv| {
            if (comptime needsCleanup(V)) {
                var val = kv.value;
                cleanup(V, alloc, &val);
            }
        }
    }

    pub fn numericMapContains(comptime K: type, comptime V: type, map: NumericMapType(K, V), key: K) bool {
        return map.contains(key);
    }

    pub fn numericMapCount(comptime K: type, comptime V: type, map: NumericMapType(K, V)) i64 {
        return @intCast(map.count());
    }

    pub fn numericMapDeinit(comptime K: type, comptime V: type, alloc: std.mem.Allocator, map: *NumericMapType(K, V)) void {
        if (comptime needsCleanup(V)) {
            var it = map.valueIterator();
            while (it.next()) |val_ptr| cleanup(V, alloc, val_ptr);
        }
        map.deinit(alloc);
    }

    pub fn numericMapKeys(comptime K: type, comptime V: type, allocator: std.mem.Allocator, map: NumericMapType(K, V)) ![]K {
        const result = try allocator.alloc(K, map.count());
        var it = map.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) result[i] = k.*;
        return result;
    }

    pub fn numericMapValues(comptime K: type, comptime V: type, allocator: std.mem.Allocator, map: NumericMapType(K, V)) ![]V {
        const result = try allocator.alloc(V, map.count());
        var it = map.valueIterator();
        var i: usize = 0;
        while (it.next()) |v| : (i += 1) result[i] = v.*;
        return result;
    }

    // FILE

    // Open a file as a linear resource. Caller is responsible for calling .close().
    // Designed for use with CLEAR's resource system: `f = File::open("path")`.
    // The compiler auto-injects `defer f.close()` at the declaration site.
    pub fn fileOpen(path: []const u8) !std.fs.File {
        return std.fs.cwd().openFile(path, .{ .mode = .read_only });
    }

    // Read all bytes from an open file resource into a heap-allocated buffer.
    // Intended for use as `f.readAll()` on a File resource.
    pub fn fileReadAll(allocator: std.mem.Allocator, file: std.fs.File) ![]const u8 {
        const stat = try file.stat();
        const buffer = try allocator.alloc(u8, stat.size);
        var total: usize = 0;
        while (total < buffer.len) {
            const n = try std.posix.read(file.handle, buffer[total..]);
            if (n == 0) break;
            total += n;
        }
        return buffer[0..total];
    }

    // Create (or truncate) a file for writing. Caller owns the returned File resource.
    // The compiler auto-injects `defer f.close()` at the declaration site.
    pub fn fileCreate(path: []const u8) !std.fs.File {
        return std.fs.cwd().createFile(path, .{ .truncate = true });
    }

    // Write `data` to an open writable File resource.
    // Usage: fileWrite(f, "hello world")
    pub fn fileWrite(file: std.fs.File, data: []const u8) !void {
        return file.writeAll(data);
    }

    // Read File (Allocates on HEAP)
    //
    // When a scheduler is active (BG fibers), the bulk read is submitted
    // via io_uring (IORING_OP_READ). The fiber parks as .Blocked and yields;
    // the kernel completes the read asynchronously and the scheduler's CQE
    // drain wakes the fiber. Other fibers run in the meantime.
    //
    // open/fstat remain synchronous -- fast VFS metadata lookups that don't
    // benefit from async submission.
    //
    // Fallback: Outside a scheduler context (unit tests), a plain blocking
    // readAll is used -- no io_uring, no yield.
    pub noinline fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        const fd = try openPathFd(path, .{ .ACCMODE = .RDONLY }, 0);
        defer std.posix.close(fd);
        const stat = try std.posix.fstat(fd);
        const size: usize = @intCast(stat.size);
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        if (fp.scheduler_running) {
            // Async path: submit IORING_OP_READ, yield, resume on CQE.
            const sched = fp.active_scheduler;
            const task = sched.getCurrent();
            var total: usize = 0;
            while (total < buffer.len) {
                var waiter = fp.Scheduler.IoWaiter{ .task = task };
                try sched.submitRead(&waiter, fd, buffer[total..]);
                task.base.yield();
                if (waiter.result < 0) return fp.Scheduler.ioError(waiter.result);
                if (waiter.result == 0) break; // EOF
                total += @intCast(waiter.result);
            }
            return buffer[0..total];
        } else {
            // Blocking fallback (no scheduler -- unit tests, CLI tools).
            var total: usize = 0;
            while (total < buffer.len) {
                const n = std.posix.read(fd, buffer[total..]) catch break;
                if (n == 0) break;
                total += n;
            }
            return buffer[0..total];
        }
    }

    // List all files in a directory. Returns an ArrayListUnmanaged of heap-allocated
    // filename slices (not full paths). Caller owns the list and each string.
    // Usage: files = listDir(allocator, "/some/dir")
    pub fn listDir(allocator: std.mem.Allocator, path: []const u8) !std.ArrayListUnmanaged([]const u8) {
        var list = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (list.items) |s| allocator.free(s);
            list.deinit(allocator);
        }
        var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind == .file) {
                const name = try allocator.dupe(u8, entry.name);
                try list.append(allocator, name);
            }
        }
        return list;
    }

    // List ALL entries (files AND directories) in a directory.
    // Returns entries prefixed with "f:" for files or "d:" for directories.
    // Usage: entries = listAll(allocator, "/some/dir")
    pub fn listAll(allocator: std.mem.Allocator, path: []const u8) !std.ArrayListUnmanaged([]const u8) {
        var list = std.ArrayListUnmanaged([]const u8){};
        errdefer {
            for (list.items) |s| allocator.free(s);
            list.deinit(allocator);
        }
        var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            const prefix: []const u8 = switch (entry.kind) {
                .file => "f:",
                .directory => "d:",
                else => continue,
            };
            const full = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, entry.name });
            try list.append(allocator, full);
        }
        return list;
    }

    // Get file size in bytes. Returns -1 on error.
    // Usage: size = fileSize("/some/file.txt")
    pub fn fileSize(path: []const u8) i64 {
        const file = std.fs.cwd().openFile(path, .{}) catch return -1;
        defer file.close();
        const stat = file.stat() catch return -1;
        return @intCast(stat.size);
    }

    // Count non-overlapping occurrences of needle in haystack.
    // Returns 0 if needle is empty or not found.
    // Usage: n = countOccurrences("hello world", "o")  → 2
    //
    // Uses std.mem.count, which delegates to std.mem.indexOf in a tight loop.
    // The Zig backend autovectorizes the inner byte scan on amd64 (SSE2/AVX2),
    // matching the throughput of Go's bytes.Count.  The old scalar startsWith
    // loop processed one byte per iteration; this version scans a full vector
    // register (16–32 bytes) per iteration when the CPU supports it.
    pub fn countOccurrences(haystack: []const u8, needle: []const u8) i64 {
        if (needle.len == 0) return 0;
        return @intCast(std.mem.count(u8, haystack, needle));
    }

    // Write File
    //
    // Async path mirrors readFile: open is synchronous, bulk write uses
    // io_uring IORING_OP_WRITE. Handles short writes by resubmitting
    // the remainder.
    pub noinline fn writeFile(path: []const u8, content: []const u8) !void {
        const fd = try openPathFd(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        defer std.posix.close(fd);

        if (fp.scheduler_running) {
            const sched = fp.active_scheduler;
            const task = sched.getCurrent();
            var written: usize = 0;
            while (written < content.len) {
                var waiter = fp.Scheduler.IoWaiter{ .task = task };
                try sched.submitWrite(&waiter, fd, content[written..]);
                task.base.yield();
                if (waiter.result < 0) return fp.Scheduler.ioError(waiter.result);
                if (waiter.result == 0) return error.WriteError; // zero bytes written
                written += @intCast(waiter.result);
            }
        } else {
            var written: usize = 0;
            while (written < content.len) {
                written += std.posix.write(fd, content[written..]) catch return error.WriteError;
            }
        }
    }

    // Read Line from stdin
    const ReadLineCtx = struct {
        allocator: std.mem.Allocator,
        result: []const u8 = &.{},
        err: ?anyerror = null,
        fn run(ptr: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            var buf: [4096]u8 = undefined;
            var pos: usize = 0;
            while (pos < buf.len) {
                const n = std.posix.read(std.posix.STDIN_FILENO, buf[pos..][0..1]) catch |e| {
                    self.err = e;
                    return;
                };
                if (n == 0) break; // EOF
                if (buf[pos] == '\n') break;
                pos += 1;
            }
            if (pos > 0 and buf[pos - 1] == '\r') {
                pos -= 1;
            }
            self.result = self.allocator.dupe(u8, buf[0..pos]) catch |e| {
                self.err = e;
                return;
            };
        }
    };

    pub noinline fn readLine(allocator: std.mem.Allocator) ![]const u8 {
        var ctx = ReadLineCtx{ .allocator = allocator };
        if (fp.scheduler_running) {
            const rt: *Runtime = @ptrCast(@alignCast(fp.active_scheduler.getCurrent().runtime_ptr.?));
            rt.onRootStack(@as(*const fn (?*anyopaque) callconv(.c) void, &ReadLineCtx.run), @ptrCast(&ctx));
        } else {
            ReadLineCtx.run(@ptrCast(&ctx));
        }
        if (ctx.err) |e| return e;
        return ctx.result;
    }

    // Line editing with history (POSIX termios)
    const LINE_MAX = 4096;
    const HISTORY_MAX = 256;

    var rl_history: [HISTORY_MAX][LINE_MAX]u8 = undefined;
    var rl_history_lens: [HISTORY_MAX]usize = [_]usize{0} ** HISTORY_MAX;
    var rl_history_count: usize = 0;
    var rl_history_initialized: bool = false;

    fn rlHistoryAdd(buf: []const u8) void {
        if (buf.len == 0) return;
        // Don't add duplicates of the last entry
        if (rl_history_count > 0) {
            const last_idx = rl_history_count - 1;
            const last = rl_history[last_idx][0..rl_history_lens[last_idx]];
            if (std.mem.eql(u8, last, buf)) return;
        }
        if (rl_history_count < HISTORY_MAX) {
            @memcpy(rl_history[rl_history_count][0..buf.len], buf);
            rl_history_lens[rl_history_count] = buf.len;
            rl_history_count += 1;
        } else {
            // Shift history up, drop oldest
            for (0..HISTORY_MAX - 1) |i| {
                @memcpy(rl_history[i][0..rl_history_lens[i + 1]], rl_history[i + 1][0..rl_history_lens[i + 1]]);
                rl_history_lens[i] = rl_history_lens[i + 1];
            }
            @memcpy(rl_history[HISTORY_MAX - 1][0..buf.len], buf);
            rl_history_lens[HISTORY_MAX - 1] = buf.len;
        }
    }

    const ReadLineEditCtx = struct {
        allocator: std.mem.Allocator,
        prompt: []const u8,
        result: []const u8 = &.{},
        err: ?anyerror = null,

        fn run(ptr: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.result = rlEdit(self.allocator, self.prompt) catch |e| {
                self.err = e;
                return;
            };
        }
    };

    fn rlEdit(allocator: std.mem.Allocator, prompt: []const u8) ![]const u8 {
        const stdin_fd = std.posix.STDIN_FILENO;
        const stderr_fd = std.posix.STDERR_FILENO;

        // Check if stdin is a tty; if not, fall back to basic readLine
        if (!std.posix.isatty(stdin_fd)) {
            return readLine(allocator);
        }

        // Save original terminal state
        const orig = try std.posix.tcgetattr(stdin_fd);

        // Enter raw mode
        var raw = orig;
        // Input: no break/CR-to-NL/parity/strip/flow-control
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        // Output: keep default
        // Local: no echo, no canonical, no signals, no extended
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        // Read returns after 1 byte
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);
        errdefer std.posix.tcsetattr(stdin_fd, .FLUSH, orig) catch {};

        defer std.posix.tcsetattr(stdin_fd, .FLUSH, orig) catch {};

        // Write prompt
        _ = std.posix.write(stderr_fd, prompt) catch {};

        var buf: [LINE_MAX]u8 = undefined;
        var line_len: usize = 0;
        var pos: usize = 0; // cursor position within buf
        var hist_idx: usize = rl_history_count; // browsing index (count = "current line")
        var saved_line: [LINE_MAX]u8 = undefined;
        var saved_len: usize = 0;

        while (true) {
            var c: [1]u8 = undefined;
            const n = std.posix.read(stdin_fd, &c) catch break;
            if (n == 0) {
                // EOF
                if (line_len == 0) return error.EndOfStream;
                break;
            }

            switch (c[0]) {
                '\r', '\n' => {
                    // Submit line
                    _ = std.posix.write(stderr_fd, "\r\n") catch {};
                    break;
                },
                3 => {
                    // Ctrl-C: discard line, print ^C
                    _ = std.posix.write(stderr_fd, "^C\r\n") catch {};
                    line_len = 0;
                    pos = 0;
                    break;
                },
                4 => {
                    // Ctrl-D: EOF if empty, delete-char otherwise
                    if (line_len == 0) {
                        _ = std.posix.write(stderr_fd, "\r\n") catch {};
                        return error.EndOfStream;
                    }
                    if (pos < line_len) {
                        std.mem.copyForwards(u8, buf[pos..line_len - 1], buf[pos + 1 .. line_len]);
                        line_len -= 1;
                        rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                    }
                },
                1 => {
                    // Ctrl-A: home
                    pos = 0;
                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                },
                5 => {
                    // Ctrl-E: end
                    pos = line_len;
                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                },
                11 => {
                    // Ctrl-K: kill to end of line
                    line_len = pos;
                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                },
                21 => {
                    // Ctrl-U: kill to start of line
                    std.mem.copyForwards(u8, buf[0 .. line_len - pos], buf[pos..line_len]);
                    line_len -= pos;
                    pos = 0;
                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                },
                12 => {
                    // Ctrl-L: clear screen and redraw
                    _ = std.posix.write(stderr_fd, "\x1b[H\x1b[2J") catch {};
                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                },
                127, 8 => {
                    // Backspace (127 or BS 8)
                    if (pos > 0) {
                        std.mem.copyForwards(u8, buf[pos - 1 .. line_len - 1], buf[pos..line_len]);
                        pos -= 1;
                        line_len -= 1;
                        rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                    }
                },
                27 => {
                    // Escape sequence
                    var seq: [2]u8 = undefined;
                    const n1 = std.posix.read(stdin_fd, seq[0..1]) catch break;
                    if (n1 == 0) break;
                    if (seq[0] == '[') {
                        const n2 = std.posix.read(stdin_fd, seq[1..2]) catch break;
                        if (n2 == 0) break;
                        switch (seq[1]) {
                            'A' => {
                                // Up arrow: history previous
                                if (rl_history_count > 0 and hist_idx > 0) {
                                    if (hist_idx == rl_history_count) {
                                        // Save current line
                                        @memcpy(saved_line[0..line_len], buf[0..line_len]);
                                        saved_len = line_len;
                                    }
                                    hist_idx -= 1;
                                    const hlen = rl_history_lens[hist_idx];
                                    @memcpy(buf[0..hlen], rl_history[hist_idx][0..hlen]);
                                    line_len = hlen;
                                    pos = line_len;
                                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                                }
                            },
                            'B' => {
                                // Down arrow: history next
                                if (hist_idx < rl_history_count) {
                                    hist_idx += 1;
                                    if (hist_idx == rl_history_count) {
                                        // Restore saved line
                                        @memcpy(buf[0..saved_len], saved_line[0..saved_len]);
                                        line_len = saved_len;
                                    } else {
                                        const hlen = rl_history_lens[hist_idx];
                                        @memcpy(buf[0..hlen], rl_history[hist_idx][0..hlen]);
                                        line_len = hlen;
                                    }
                                    pos = line_len;
                                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                                }
                            },
                            'C' => {
                                // Right arrow
                                if (pos < line_len) {
                                    pos += 1;
                                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                                }
                            },
                            'D' => {
                                // Left arrow
                                if (pos > 0) {
                                    pos -= 1;
                                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                                }
                            },
                            'H' => {
                                // Home
                                pos = 0;
                                rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                            },
                            'F' => {
                                // End
                                pos = line_len;
                                rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                            },
                            '3' => {
                                // Delete key: ESC [ 3 ~
                                var tilde: [1]u8 = undefined;
                                _ = std.posix.read(stdin_fd, &tilde) catch break;
                                if (tilde[0] == '~' and pos < line_len) {
                                    std.mem.copyForwards(u8, buf[pos..line_len - 1], buf[pos + 1 .. line_len]);
                                    line_len -= 1;
                                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                                }
                            },
                            '1' => {
                                // Home: ESC [ 1 ~
                                var tilde: [1]u8 = undefined;
                                _ = std.posix.read(stdin_fd, &tilde) catch break;
                                if (tilde[0] == '~') {
                                    pos = 0;
                                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                                }
                            },
                            '4' => {
                                // End: ESC [ 4 ~
                                var tilde: [1]u8 = undefined;
                                _ = std.posix.read(stdin_fd, &tilde) catch break;
                                if (tilde[0] == '~') {
                                    pos = line_len;
                                    rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                                }
                            },
                            else => {},
                        }
                    } else if (seq[0] == 'O') {
                        // ESC O H (Home), ESC O F (End) - alternate sequences
                        switch (seq[1]) {
                            'H' => {
                                pos = 0;
                                rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                            },
                            'F' => {
                                pos = line_len;
                                rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                            },
                            else => {},
                        }
                    }
                },
                else => {
                    // Printable character
                    if (c[0] >= 32 and line_len < LINE_MAX - 1) {
                        if (pos < line_len) {
                            // Shift right to make room
                            std.mem.copyBackwards(u8, buf[pos + 1 .. line_len + 1], buf[pos..line_len]);
                        }
                        buf[pos] = c[0];
                        pos += 1;
                        line_len += 1;
                        rlRefresh(stderr_fd, prompt, buf[0..line_len], pos);
                    }
                },
            }
        }

        // Add to history
        if (line_len > 0) {
            rlHistoryAdd(buf[0..line_len]);
        }

        return try allocator.dupe(u8, buf[0..line_len]);
    }

    fn rlRefresh(fd: std.posix.fd_t, prompt: []const u8, line: []const u8, cursor: usize) void {
        // \r to start of line, write prompt + buffer, clear to end, reposition cursor
        var out: [LINE_MAX + 256]u8 = undefined;
        var off: usize = 0;

        // Carriage return
        out[off] = '\r';
        off += 1;

        // Prompt
        const plen = @min(prompt.len, out.len - off - 64);
        @memcpy(out[off .. off + plen], prompt[0..plen]);
        off += plen;

        // Line content
        const llen = @min(line.len, out.len - off - 64);
        @memcpy(out[off .. off + llen], line[0..llen]);
        off += llen;

        // Clear to end of line: ESC [ K
        out[off] = '\x1b';
        off += 1;
        out[off] = '[';
        off += 1;
        out[off] = 'K';
        off += 1;

        // Move cursor to correct position: \r then ESC [ <n> C
        out[off] = '\r';
        off += 1;

        const cursor_pos = prompt.len + cursor;
        if (cursor_pos > 0) {
            // ESC [ <n> C - move cursor forward n columns
            out[off] = '\x1b';
            off += 1;
            out[off] = '[';
            off += 1;
            // Format the number
            var num_buf: [16]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{cursor_pos}) catch return;
            @memcpy(out[off .. off + num_str.len], num_str);
            off += num_str.len;
            out[off] = 'C';
            off += 1;
        }

        _ = std.posix.write(fd, out[0..off]) catch {};
    }

    pub noinline fn readLinePrompt(allocator: std.mem.Allocator, prompt: []const u8) ![]const u8 {
        var ctx = ReadLineEditCtx{ .allocator = allocator, .prompt = prompt };
        if (fp.scheduler_running) {
            const rt: *Runtime = @ptrCast(@alignCast(fp.active_scheduler.getCurrent().runtime_ptr.?));
            rt.onRootStack(@as(*const fn (?*anyopaque) callconv(.c) void, &ReadLineEditCtx.run), @ptrCast(&ctx));
        } else {
            ReadLineEditCtx.run(@ptrCast(&ctx));
        }
        if (ctx.err) |e| return e;
        return ctx.result;
    }

    // String Lib

    // Used to make HEAP strings
    pub fn makeString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
        Runtime.profileAlloc(text.len);
        return try std.fmt.allocPrint(allocator, "{s}", .{text});
    }

    pub fn substr(allocator: std.mem.Allocator, str: []const u8, start: i64, length: i64) ![]const u8 {
        Runtime.profileAlloc(@intCast(length));
        const u_start: usize = @intCast(start);
        const u_len: usize = @intCast(length);

        if (u_start + u_len > str.len) return error.OutOfBounds;

        // Slicing in Zig is O(1) pointer math!
        const slice = str[u_start .. u_start + u_len];

        // We must COPY it to the new allocator (usually Heap) so it survives
        return allocator.dupe(u8, slice);
    }

    // String Equality (Content check)
    pub fn strEql(s1: []const u8, s2: []const u8) bool {
        return std.mem.eql(u8, s1, s2);
    }

    // Lexicographic string comparison. Returns -1, 0, or 1.
    pub fn strcmp(a: []const u8, b: []const u8) i64 {
        const order = std.mem.order(u8, a, b);
        return switch (order) {
            .lt => @as(i64, -1),
            .eq => @as(i64, 0),
            .gt => @as(i64, 1),
        };
    }

    // Generic Equality (works for primitives and slices)
    pub fn eql(a: anytype, b: @TypeOf(a)) bool {
        const T = @TypeOf(a);
        const info = @typeInfo(T);

        // For slices (like strings), use mem.eql
        if (info == .pointer and info.pointer.size == .slice) {
            return std.mem.eql(info.pointer.child, a, b);
        }

        // For primitives (int, float, bool), use ==
        return a == b;
    }

    // indexOf: returns ?i64 position of needle in haystack, or null if not found.
    pub fn indexOf(haystack: []const u8, needle: []const u8) ?i64 {
        if (std.mem.indexOf(u8, haystack, needle)) |pos| {
            return @intCast(pos);
        }
        return null;
    }

    // toString: Int64 -> String (heap-allocated decimal representation)
    /// Parse a string to i64. Returns error on invalid input.
    pub fn toInt(s: []const u8) !i64 {
        return std.fmt.parseInt(i64, s, 10);
    }

    // -----------------------------------------------------------------
    // Clock & Timing
    // -----------------------------------------------------------------

    // Integer arithmetic: checked in debug/safe (panics on overflow),
    // wrapping in release (matches Rust semantics). This ensures hash
    // functions, RNGs, and checksums work correctly in production while
    // catching accidental overflow bugs during development.
    fn IntResult(comptime A: type, comptime B: type) type {
        // When mixing comptime_int with a fixed-width int, use the fixed-width type.
        if (A == comptime_int) return B;
        return A;
    }

    pub inline fn intAdd(a: anytype, b: anytype) IntResult(@TypeOf(a), @TypeOf(b)) {
        const R = IntResult(@TypeOf(a), @TypeOf(b));
        const av: R = a;
        const bv: R = b;
        if (@import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe) {
            return av + bv;
        } else {
            return av +% bv;
        }
    }
    pub inline fn intSub(a: anytype, b: anytype) IntResult(@TypeOf(a), @TypeOf(b)) {
        const R = IntResult(@TypeOf(a), @TypeOf(b));
        const av: R = a;
        const bv: R = b;
        if (@import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe) {
            return av - bv;
        } else {
            return av -% bv;
        }
    }
    pub inline fn intMul(a: anytype, b: anytype) IntResult(@TypeOf(a), @TypeOf(b)) {
        const R = IntResult(@TypeOf(a), @TypeOf(b));
        const av: R = a;
        const bv: R = b;
        if (@import("builtin").mode == .Debug or @import("builtin").mode == .ReleaseSafe) {
            return av * bv;
        } else {
            return av *% bv;
        }
    }

    // Explicit wrapping arithmetic (%+, %-, %*) — wraps in ALL build modes.
    // Use for hash functions, RNGs, checksums, and other intentional-overflow code.
    pub inline fn wrapAdd(a: anytype, b: anytype) IntResult(@TypeOf(a), @TypeOf(b)) {
        const R = IntResult(@TypeOf(a), @TypeOf(b));
        return @as(R, a) +% @as(R, b);
    }
    pub inline fn wrapSub(a: anytype, b: anytype) IntResult(@TypeOf(a), @TypeOf(b)) {
        const R = IntResult(@TypeOf(a), @TypeOf(b));
        return @as(R, a) -% @as(R, b);
    }
    pub inline fn wrapMul(a: anytype, b: anytype) IntResult(@TypeOf(a), @TypeOf(b)) {
        const R = IntResult(@TypeOf(a), @TypeOf(b));
        return @as(R, a) *% @as(R, b);
    }

    // Explicit checked arithmetic (!+, !-, !*) — panics in ALL build modes.
    // Use for financial math, safety-critical code, and overflow detection.
    pub inline fn checkAdd(a: anytype, b: anytype) IntResult(@TypeOf(a), @TypeOf(b)) {
        const R = IntResult(@TypeOf(a), @TypeOf(b));
        const result = @addWithOverflow(@as(R, a), @as(R, b));
        if (result[1] != 0) @panic("integer overflow in checked addition (!+)");
        return result[0];
    }
    pub inline fn checkSub(a: anytype, b: anytype) IntResult(@TypeOf(a), @TypeOf(b)) {
        const R = IntResult(@TypeOf(a), @TypeOf(b));
        const result = @subWithOverflow(@as(R, a), @as(R, b));
        if (result[1] != 0) @panic("integer overflow in checked subtraction (!-)");
        return result[0];
    }
    pub inline fn checkMul(a: anytype, b: anytype) IntResult(@TypeOf(a), @TypeOf(b)) {
        const R = IntResult(@TypeOf(a), @TypeOf(b));
        const result = @mulWithOverflow(@as(R, a), @as(R, b));
        if (result[1] != 0) @panic("integer overflow in checked multiplication (!*)");
        return result[0];
    }

    /// Wall clock milliseconds since Unix epoch.
    pub fn timestampMs() i64 {
        return std.time.milliTimestamp();
    }

    /// Returns the total number of scheduler threads.
    /// Matches the CLEAR_THREADS environment variable.
    pub fn threadCount() i64 {
        return @as(i64, @intCast(fp.global_registry.count()));
    }

    // sleep is called directly on rt: rt.sleep(ms) — see Runtime.sleep in runtime.zig

    /// Peak resident set size (VmHWM) in KB, from /proc/self/status.
    /// Returns the high-water mark of physical memory used by this process.
    /// Cross-language comparable — works identically in C, Go, Zig, etc.
    pub fn peakMemoryKb() i64 {
        const file = std.fs.openFileAbsolute("/proc/self/status", .{}) catch return -1;
        defer file.close();
        var buf: [4096]u8 = undefined;
        const n = file.readAll(&buf) catch return -1;
        const content = buf[0..n];
        // Find "VmHWM:" line and parse the KB value
        if (std.mem.indexOf(u8, content, "VmHWM:")) |pos| {
            var i = pos + 6; // skip "VmHWM:"
            while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {}
            var val: i64 = 0;
            while (i < content.len and content[i] >= '0' and content[i] <= '9') : (i += 1) {
                val = val * 10 + @as(i64, content[i] - '0');
            }
            return val;
        }
        return -1;
    }

    /// Current resident set size (VmRSS) in KB, from /proc/self/status.
    pub fn currentMemoryKb() i64 {
        const file = std.fs.openFileAbsolute("/proc/self/status", .{}) catch return -1;
        defer file.close();
        var buf: [4096]u8 = undefined;
        const n = file.readAll(&buf) catch return -1;
        const content = buf[0..n];
        if (std.mem.indexOf(u8, content, "VmRSS:")) |pos| {
            var i = pos + 6; // skip "VmRSS:"
            while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {}
            var val: i64 = 0;
            while (i < content.len and content[i] >= '0' and content[i] <= '9') : (i += 1) {
                val = val * 10 + @as(i64, content[i] - '0');
            }
            return val;
        }
        return -1;
    }

    // -----------------------------------------------------------------
    // Random
    // -----------------------------------------------------------------

    /// Random float in [0.0, 1.0). Uses OS CSPRNG.
    pub fn random() f64 {
        var bytes: [8]u8 = undefined;
        std.crypto.random.bytes(&bytes);
        // Use top 52 bits as mantissa of a double in [1.0, 2.0), then subtract 1.0
        const bits = std.mem.readInt(u64, &bytes, .little);
        const mantissa = (bits >> 12) | (0x3FF << 52); // exponent = 1023 = 1.0
        return @as(f64, @bitCast(mantissa)) - 1.0;
    }

    /// Random integer in [0, max). Uses OS CSPRNG.
    pub fn randomInt(max: i64) i64 {
        if (max <= 0) return 0;
        const umax: u64 = @intCast(max);
        var bytes: [8]u8 = undefined;
        std.crypto.random.bytes(&bytes);
        const val = std.mem.readInt(u64, &bytes, .little);
        return @intCast(val % umax);
    }

    /// Format an integer into a caller-provided buffer. Returns the slice written.
    /// Zero-allocation — use for transient string interpolation (map keys, comparisons).
    pub fn fmtInt(buf: []u8, value: i64) []const u8 {
        var tmp: [21]u8 = undefined;
        var slen: usize = 0;
        var v: u64 = if (value < 0) @intCast(-value) else @intCast(value);
        if (v == 0) {
            tmp[0] = '0';
            slen = 1;
        } else {
            while (v > 0) : (slen += 1) {
                tmp[slen] = @intCast('0' + (v % 10));
                v /= 10;
            }
            if (value < 0) {
                tmp[slen] = '-';
                slen += 1;
            }
            var lo: usize = 0;
            var hi: usize = slen - 1;
            while (lo < hi) {
                const t = tmp[lo];
                tmp[lo] = tmp[hi];
                tmp[hi] = t;
                lo += 1;
                hi -= 1;
            }
        }
        @memcpy(buf[0..slen], tmp[0..slen]);
        return buf[0..slen];
    }

    /// Concatenate slices into a caller-provided buffer. Returns the slice written.
    /// Zero-allocation — use for transient string building (map keys, comparisons).
    pub fn bufConcat(buf: []u8, parts: anytype) []const u8 {
        var pos: usize = 0;
        inline for (parts) |part| {
            @memcpy(buf[pos..][0..part.len], part);
            pos += part.len;
        }
        return buf[0..pos];
    }

    pub fn intToString(allocator: std.mem.Allocator, value: i64) ![]const u8 {
        Runtime.profileAlloc(21);
        // Max i64 is 19 digits + sign + null = 21 bytes; allocate 21
        var buf: [21]u8 = undefined;
        var slen: usize = 0;
        var v: u64 = if (value < 0) @intCast(-value) else @intCast(value);
        if (v == 0) {
            buf[0] = '0';
            slen = 1;
        } else {
            while (v > 0) : (slen += 1) {
                buf[slen] = @intCast('0' + (v % 10));
                v /= 10;
            }
            if (value < 0) {
                buf[slen] = '-';
                slen += 1;
            }
            // Reverse in-place
            var lo: usize = 0;
            var hi: usize = slen - 1;
            while (lo < hi) {
                const tmp = buf[lo];
                buf[lo] = buf[hi];
                buf[hi] = tmp;
                lo += 1;
                hi -= 1;
            }
        }
        const result = try allocator.alloc(u8, slen);
        @memcpy(result, buf[0..slen]);
        return result;
    }

    // Split: String -> List
    pub fn split(allocator: std.mem.Allocator, str: []const u8, delimiter: []const u8) !std.ArrayListUnmanaged([]const u8) {
        var list = std.ArrayListUnmanaged([]const u8){};

        // splitSequence handles string delimiters (e.g. ", ")
        var iter = std.mem.splitSequence(u8, str, delimiter);

        while (iter.next()) |part| {
            // Important: Make a copy of the part in the new allocator (Heap)
            // so the list doesn't point to frame memory that might die.
            const part_copy = try allocator.dupe(u8, part);
            try list.append(allocator, part_copy);
        }
        return list;
    }

    // Join: List -> String (technically an array function)
    pub fn join(allocator: std.mem.Allocator, list: anytype, delimiter: []const u8) ![]const u8 {
        Runtime.profileAlloc(0); // size unknown until join completes
        const items = if (@hasField(@TypeOf(list), "items")) list.items else list;
        return std.mem.join(allocator, delimiter, items);
    }

    // replace(str, old, new) -> String with all occurrences replaced
    pub fn stringReplace(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8, replacement: []const u8) ![]const u8 {
        Runtime.profileAlloc(0);
        var result = std.ArrayListUnmanaged(u8){};
        var i: usize = 0;
        while (i < haystack.len) {
            if (i + needle.len <= haystack.len and std.mem.eql(u8, haystack[i..][0..needle.len], needle)) {
                try result.appendSlice(allocator, replacement);
                i += needle.len;
            } else {
                try result.append(allocator, haystack[i]);
                i += 1;
            }
        }
        return result.items;
    }

    // lowercase(str) -> new string with all ASCII bytes lowered
    pub fn stringLowercase(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
        Runtime.profileAlloc(str.len);
        const buf = try allocator.alloc(u8, str.len);
        for (str, 0..) |c, idx| {
            buf[idx] = std.ascii.toLower(c);
        }
        return buf;
    }

    // uppercase(str) -> new string with all ASCII bytes uppercased
    pub fn stringUppercase(allocator: std.mem.Allocator, str: []const u8) ![]const u8 {
        Runtime.profileAlloc(str.len);
        const buf = try allocator.alloc(u8, str.len);
        for (str, 0..) |c, idx| {
            buf[idx] = std.ascii.toUpper(c);
        }
        return buf;
    }

    // shell

    pub fn shell(allocator: std.mem.Allocator, cmd: []const u8) ![]const u8 {
        // 1. Prepare Command (Wrap in sh -c to support pipes/globbing)
        //    Note: For Windows support, you'd check builtin.os.tag and use "cmd", "/C"
        const argv = if (builtin.os.tag == .windows)
            &[_][]const u8{ "cmd", "/C", cmd }
        else
            &[_][]const u8{ "/bin/sh", "-c", cmd };

        // 2. Initialize Process
        var child = std.process.Child.init(argv, allocator);
        child.stdout_behavior = .Pipe; // Capture StdOut
        child.stderr_behavior = .Inherit; // Print StdErr to console (helpful for debugging)

        // 3. Run
        try child.spawn();

        // 4. Read Output
        //    readToEndAlloc will allocate exactly enough memory for the output.
        //    We set a safety limit (e.g., 10MB) to prevent crashing on massive output.
        const stdout = try child.stdout.?.readToEndAlloc(allocator, 10 * 1024 * 1024);

        // 5. Cleanup
        _ = try child.wait(); // Wait for finish

        return stdout;
    }

    // -------------------------------------------------------------------------
    // TCP SOCKETS — fiber-aware, epoll-backed, Linux only
    // -------------------------------------------------------------------------

    // Create a non-blocking TCP server socket, bind it to `port`, and begin
    // listening. Returns the raw server fd; caller owns it (must socketClose).
    pub fn socketListen(port: u16) !i32 {
        const fd = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
            0,
        );
        errdefer std.posix.close(fd);

        // SO_REUSEADDR so we can restart quickly without TIME_WAIT stalls.
        try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

        const addr = std.posix.sockaddr.in{
            .family = std.posix.AF.INET,
            .port   = std.mem.nativeToBig(u16, port),
            .addr   = 0, // INADDR_ANY
            .zero   = [_]u8{0} ** 8,
        };
        try std.posix.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        try std.posix.listen(fd, 128);
        return fd;
    }

    // Accept one incoming connection on `server_fd` via io_uring.
    // Submits IORING_OP_ACCEPT and yields; the CQE result is the client fd
    // (already non-blocking via SOCK_NONBLOCK flag in the SQE).
    // Returns the client fd; caller owns it (close via socketClose / RAII).
    pub noinline fn socketAccept(server_fd: i32) !i32 {
        const sched = fp.active_scheduler;
        const task = sched.getCurrent();
        var waiter = fp.Scheduler.IoWaiter{ .task = task };
        try sched.submitAccept(&waiter, server_fd);
        task.base.yield();
        if (waiter.result < 0) return fp.Scheduler.ioError(waiter.result);
        return waiter.result;
    }

    // -----------------------------------------------------------------------
    // Socket I/O: completion-based via io_uring.
    //
    // Each operation submits a single SQE and yields the fiber. The CQE
    // result contains the byte count (or negative errno). No EAGAIN retry
    // loops -- the kernel handles the wait internally.
    // -----------------------------------------------------------------------

    // Write `data` to a socket via io_uring IORING_OP_SEND.
    // Loops on short sends (resubmits remainder), yielding between each.
    // Returns the total bytes sent (== data.len on success).
    pub noinline fn socketWrite(fd: i32, data: []const u8) !usize {
        const sched = fp.active_scheduler;
        const task = sched.getCurrent();
        var sent: usize = 0;
        while (sent < data.len) {
            var waiter = fp.Scheduler.IoWaiter{ .task = task };
            try sched.submitSend(&waiter, fd, data[sent..]);
            task.base.yield();
            if (waiter.result < 0) return fp.Scheduler.ioError(waiter.result);
            if (waiter.result == 0) return sent;
            sent += @intCast(waiter.result);
        }
        return sent;
    }

    // Close a TCP socket fd. With io_uring completion-based I/O, there are
    // no pending polls to cancel -- the fd is simply closed.
    pub noinline fn socketClose(fd: i32) void {
        std.posix.close(fd);
    }

    // Read up to 4096 bytes from a connected client socket via io_uring.
    // Submits IORING_OP_RECV and yields until data is available.
    //
    // Reads into a frame-arena buffer (the allocator passed by the transpiler
    // is rt.frameAlloc()). The returned slice lives until the enclosing loop
    // iteration's restoreLoopMark rewinds the arena.
    //
    // Yields after successful read for I/O fairness among concurrent client fibers.
    pub noinline fn socketRead(allocator: std.mem.Allocator, fd: i32) ![]const u8 {
        // Allocate read buffer on the frame arena (not the fiber stack)
        // to avoid consuming 4 KB of the fiber's limited 16 KB stack space.
        const buf = try allocator.alloc(u8, 4096);
        const n = try CheatLib.read(fd, buf);
        const result = buf[0..n];
        // Cooperative yield: if other fibers are Ready, give them a turn.
        // This prevents a single client with pipelined data from monopolizing
        // the scheduler across multiple read-process-write cycles.
        if (fp.scheduler_running) {
            fp.active_scheduler.coopYield();
        }
        return result;
    }

    // Write all bytes from `data` to a connected client socket, discarding the byte count.
    // Yields the fiber via io_uring IORING_OP_SEND.
    // Usage: tcpWrite(client, "hello")
    pub noinline fn socketWriteVoid(fd: i32, data: []const u8) !void {
        _ = try CheatLib.socketWrite(fd, data);
    }

    // Connect to a TCP server at `host:port` (dotted-decimal IPv4 only).
    // Submits IORING_OP_CONNECT and yields; the CQE result is 0 on success
    // or negative errno on error. No getsockoptError post-check needed.
    // Returns the client fd; caller owns it (close via socketClose / RAII).
    pub noinline fn socketConnect(host: []const u8, port: u16) !i32 {
        const fd = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
            0,
        );
        errdefer std.posix.close(fd);

        const s_addr = try parseIpv4Addr(host);
        const addr = std.posix.sockaddr.in{
            .family = std.posix.AF.INET,
            .port   = std.mem.nativeToBig(u16, port),
            .addr   = s_addr,
            .zero   = [_]u8{0} ** 8,
        };

        const sched = fp.active_scheduler;
        const task = sched.getCurrent();
        var waiter = fp.Scheduler.IoWaiter{ .task = task };
        try sched.submitConnect(&waiter, fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        task.base.yield();
        if (waiter.result < 0) return fp.Scheduler.ioError(waiter.result);

        return fd;
    }

    // Parse a dotted-decimal IPv4 address ("127.0.0.1") into a network-byte-order u32.
    fn parseIpv4Addr(host: []const u8) !u32 {
        var parts: [4]u8 = .{0} ** 4;
        var part_idx: usize = 0;
        var cur: u32 = 0;
        var has_digit: bool = false;

        for (host) |c| {
            switch (c) {
                '0'...'9' => {
                    cur = cur * 10 + (c - '0');
                    if (cur > 255) return error.InvalidHost;
                    has_digit = true;
                },
                '.' => {
                    if (!has_digit or part_idx >= 3) return error.InvalidHost;
                    parts[part_idx] = @intCast(cur);
                    part_idx += 1;
                    cur = 0;
                    has_digit = false;
                },
                else => return error.InvalidHost,
            }
        }
        if (!has_digit or part_idx != 3) return error.InvalidHost;
        parts[3] = @intCast(cur);

        // Assemble as host-byte-order then flip to network byte order.
        const host_order: u32 = (@as(u32, parts[0]) << 24) | (@as(u32, parts[1]) << 16) |
                                 (@as(u32, parts[2]) << 8)  |  @as(u32, parts[3]);
        return std.mem.nativeToBig(u32, host_order);
    }

    // Threading
    // THE INTERNAL WRAPPER
    // This runs INSIDE the new thread. It handles the boilerplate.
    fn threadWrapper(allocator: std.mem.Allocator, frame_size: usize, global_ctx: *EbrContext, comptime func: anytype, args: anytype) !void {
        // 1. BOILERPLATE: Setup Runtime
        var rt = try Runtime.init(allocator, frame_size, global_ctx);
        defer rt.deinit();

        rt.wireAllocator();

        // IMPORTANT: Register this thread with the global context now that `rt` is stable on the frame.
        try global_ctx.register(allocator, &rt.ebr);

        // This runs FIRST (before deinit): Remove from global registry
        // so the GC doesn't try to look at our dead frame.
        defer global_ctx.unregister(&rt.ebr);

        // 2. MAGIC: Call the user function
        // We assume your worker functions always take 'rt' as the first argument.
        // We use '++' to concatenate the Runtime pointer with the user's arguments.
        const type_info = @typeInfo(@TypeOf(func));
        if (type_info == .@"fn" or type_info == .Fn) {
            try @call(.auto, func, .{&rt} ++ args);
        }
    }

    /// Distribute a fiber to the least-loaded scheduler (default for BG/DO blocks).
    /// Fully lock-free: pickTwo is 1 fetchAdd + 2 atomic loads (O(1), wait-free).
    /// Fallback: if registry is empty (test contexts), uses active_scheduler.
    pub fn spawnBest(trampoline_addr: usize, user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
        const pair = fp.global_registry.pickTwo();
        const a = pair.a orelse {
            // Registry empty (unit-test context) — fall back to threadlocal scheduler.
            if (fp.scheduler_running) {
                try fp.active_scheduler.submitSpawn(trampoline_addr, user_fn, args, config);
                return;
            }
            return error.NoSchedulerAvailable;
        };
        const b = pair.b orelse {
            // Single scheduler — direct submit, zero overhead.
            try a.submitSpawn(trampoline_addr, user_fn, args, config);
            return;
        };
        // Power-of-Two Choices: compare load, pick lighter.
        const la = a.active_tasks.load(.monotonic);
        const lb = b.active_tasks.load(.monotonic);
        const target = if (la <= lb) a else b;
        try target.submitSpawn(trampoline_addr, user_fn, args, config);
    }

    // TODO: When does this get cleaned up?
    pub fn spawnThread(sys_allocator: std.mem.Allocator, frame_size: usize, global_ctx: *EbrContext, comptime func: anytype, args: anytype) !std.Thread {
        // We don't call 'func' directly. We call the wrapper.
        // We pass the config + the function + the args TO the wrapper.
        return std.Thread.spawn(.{}, threadWrapper, .{ sys_allocator, frame_size, global_ctx, func, args });
    }

    // Helper to wrap arbitrary arguments into a Context Pointer
    pub fn wrapArgs(allocator: std.mem.Allocator, args: anytype) !*anyopaque {
        const ArgsType = @TypeOf(args);
        const ptr = try allocator.create(ArgsType);
        ptr.* = args;
        return ptr;
    }

    // Polymorphic free: TODO: do this in the transpiler
    pub fn free(rt: *Runtime, item: anytype) void {
        const T = @TypeOf(item);

        switch (@typeInfo(T)) {
            // Case 1: Structs (check for deinit, e.g. ArrayListUnmanaged)
            .@"struct" => {
                // Special case: StringHashMapUnmanaged - free duplicated keys first
                if (@hasDecl(T, "iterator") and @hasField(T, "metadata")) {
                    var mut_item = item;
                    var it = mut_item.iterator();
                    while (it.next()) |entry| {
                        rt.heapAlloc().free(entry.key_ptr.*);
                    }
                    mut_item.deinit(rt.heapAlloc());
                } else if (@hasDecl(T, "deinit")) {
                    var mut_item = item;
                    mut_item.deinit(rt.heapAlloc());
                }
            },
            // Case 2: Pointers
            .pointer => |ptr_info| {
                switch (ptr_info.size) {
                    // Case 2a: Slices ([]const u8)
                    // Frame-allocated slices (e.g. from socketRead) live inside
                    // the frame arena's static_block and are freed in bulk by
                    // restoreLoopMark / restoreFrameMark — individual free is
                    // a no-op for them.  Heap-allocated slices (string concat
                    // results, etc.) live outside the static_block and must be
                    // freed via the GPA.
                    .slice => {
                        const frame_mem = rt.overflow_arena.static_block;
                        const p = @intFromPtr(item.ptr);
                        const frame_base = @intFromPtr(frame_mem.ptr);
                        if (p >= frame_base and p < frame_base + frame_mem.len) {
                            // Frame-allocated — freed by arena rewind, not here.
                        } else {
                            rt.heapAlloc().free(item);
                        }
                    },
                    // Case 2b: Single Items (*User)
                    .one => {
                        rt.heapAlloc().destroy(item);
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    // -------------------------------------------------------------------------
    // Reference Counting (multiowned / Rc)
    // -------------------------------------------------------------------------

    // -------------------------------------------------------------------------
    // Reference Counting with Control Block (supports weak references)
    // -------------------------------------------------------------------------
    // Both Rc and Arc use a control block that holds strong + weak counts
    // alongside the data pointer. This enables WeakRc/WeakArc to check if
    // the value is still alive without holding a strong reference.

    pub fn RcControlBlock(comptime T: type) type {
        return struct {
            strong: usize,
            weak: usize,
            data: *T,
            alloc: std.mem.Allocator,
        };
    }

    /// Rc(T): a reference-counted wrapper around a heap-allocated T.
    /// Uses a control block shared with WeakRc for weak reference support.
    pub fn Rc(comptime T: type) type {
        return struct {
            const Self = @This();
            ctrl: *RcControlBlock(T),
            // Convenience: access data through .data for compatibility
            pub fn getData(self: Self) *T { return self.ctrl.data; }
        };
    }

    pub fn rcCreate(comptime T: type, alloc: std.mem.Allocator, data: T) !Rc(T) {
        const ctrl = try alloc.create(RcControlBlock(T));
        const data_ptr = try alloc.create(T);
        data_ptr.* = data;
        ctrl.* = .{ .strong = 1, .weak = 0, .data = data_ptr, .alloc = alloc };
        return Rc(T){ .ctrl = ctrl };
    }

    pub fn rcRetain(comptime T: type, rc: Rc(T)) Rc(T) {
        rc.ctrl.strong += 1;
        return rc;
    }

    pub fn rcRelease(comptime T: type, alloc: std.mem.Allocator, rc: Rc(T)) void {
        _ = alloc; // alloc stored in control block
        rc.ctrl.strong -= 1;
        if (rc.ctrl.strong == 0) {
            rc.ctrl.alloc.destroy(rc.ctrl.data);
            if (rc.ctrl.weak == 0) {
                rc.ctrl.alloc.destroy(rc.ctrl);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Atomic Reference Counting with Control Block (shared / Arc)
    // -------------------------------------------------------------------------

    pub fn ArcControlBlock(comptime T: type) type {
        return struct {
            strong: std.atomic.Value(usize),
            weak: std.atomic.Value(usize),
            data: *T,
            alloc: std.mem.Allocator,
        };
    }

    /// Arc(T): an atomically reference-counted wrapper around a heap-allocated T.
    /// Uses a control block shared with WeakArc for weak reference support.
    pub fn Arc(comptime T: type) type {
        return struct {
            const Self = @This();
            ctrl: *ArcControlBlock(T),
            pub fn getData(self: Self) *T { return self.ctrl.data; }
        };
    }

    pub fn arcCreate(comptime T: type, alloc: std.mem.Allocator, data: T) !Arc(T) {
        const ctrl = try alloc.create(ArcControlBlock(T));
        const data_ptr = try alloc.create(T);
        data_ptr.* = data;
        ctrl.* = .{
            .strong = std.atomic.Value(usize).init(1),
            .weak = std.atomic.Value(usize).init(0),
            .data = data_ptr,
            .alloc = alloc,
        };
        return Arc(T){ .ctrl = ctrl };
    }

    pub fn arcRetain(comptime T: type, arc: Arc(T)) Arc(T) {
        _ = arc.ctrl.strong.fetchAdd(1, .acquire);
        return arc;
    }

    pub fn arcRelease(comptime T: type, alloc: std.mem.Allocator, arc: Arc(T)) void {
        _ = alloc;
        const prev = arc.ctrl.strong.fetchSub(1, .release);
        if (prev == 1) {
            _ = arc.ctrl.strong.load(.acquire);
            // Deinit inner data before freeing the pointer.
            // RwLocked/Locked wrap types that may own heap memory (StringMap keys, etc.).
            arcDeinitInner(T, arc.ctrl.alloc, arc.ctrl.data);
            arc.ctrl.alloc.destroy(arc.ctrl.data);
            if (arc.ctrl.weak.load(.acquire) == 0) {
                arc.ctrl.alloc.destroy(arc.ctrl);
            }
        }
    }

    /// Recursively deinit inner data for Arc-wrapped types.
    /// Handles RwLocked(StringMap), Locked(StringMap), and plain StringMap.
    fn arcDeinitInner(comptime T: type, a: std.mem.Allocator, ptr: *T) void {
        // RwLocked(U) or Locked(U): deinit the inner .data field
        if (@hasField(T, "data") and @hasField(T, "lock")) {
            const DataT = @TypeOf(ptr.data);
            if (@hasDecl(DataT, "deinit")) {
                // StringMap.deinit takes (key_alloc, bucket_alloc) but uses self.alloc internally
                const deinit_fn = @typeInfo(@TypeOf(DataT.deinit)).@"fn";
                if (deinit_fn.params.len == 3) {
                    ptr.data.deinit(a, a);
                } else if (deinit_fn.params.len == 2) {
                    ptr.data.deinit(a);
                } else {
                    ptr.data.deinit();
                }
            }
        } else if (@hasDecl(T, "deinit")) {
            const deinit_fn = @typeInfo(@TypeOf(T.deinit)).@"fn";
            if (deinit_fn.params.len == 3) {
                ptr.deinit(a, a);
            } else if (deinit_fn.params.len == 2) {
                ptr.deinit(a);
            } else {
                ptr.deinit();
            }
        }
    }

    // -------------------------------------------------------------------------
    // Weak References (link / WeakRc / WeakArc)
    // -------------------------------------------------------------------------

    pub fn WeakRc(comptime T: type) type {
        return struct {
            const Self = @This();
            ctrl: *RcControlBlock(T),
        };
    }

    pub fn rcDowngrade(comptime T: type, rc: Rc(T)) WeakRc(T) {
        rc.ctrl.weak += 1;
        return WeakRc(T){ .ctrl = rc.ctrl };
    }

    pub fn weakRcUpgrade(comptime T: type, weak: WeakRc(T)) ?Rc(T) {
        if (weak.ctrl.strong == 0) return null;
        weak.ctrl.strong += 1;
        return Rc(T){ .ctrl = weak.ctrl };
    }

    pub fn weakRcRelease(comptime T: type, weak: WeakRc(T)) void {
        weak.ctrl.weak -= 1;
        if (weak.ctrl.weak == 0 and weak.ctrl.strong == 0) {
            weak.ctrl.alloc.destroy(weak.ctrl);
        }
    }

    pub fn WeakArc(comptime T: type) type {
        return struct {
            const Self = @This();
            ctrl: *ArcControlBlock(T),
        };
    }

    pub fn arcDowngrade(comptime T: type, arc: Arc(T)) WeakArc(T) {
        _ = arc.ctrl.weak.fetchAdd(1, .acquire);
        return WeakArc(T){ .ctrl = arc.ctrl };
    }

    pub fn weakArcUpgrade(comptime T: type, weak: WeakArc(T)) ?Arc(T) {
        // CAS loop: atomically increment strong if > 0
        while (true) {
            const strong = weak.ctrl.strong.load(.acquire);
            if (strong == 0) return null;
            if (weak.ctrl.strong.cmpxchgWeak(strong, strong + 1, .acquire, .monotonic)) |_| {
                continue; // CAS failed, retry
            } else {
                return Arc(T){ .ctrl = weak.ctrl };
            }
        }
    }

    pub fn weakArcRelease(comptime T: type, weak: WeakArc(T)) void {
        const prev = weak.ctrl.weak.fetchSub(1, .release);
        if (prev == 1) {
            if (weak.ctrl.strong.load(.acquire) == 0) {
                weak.ctrl.alloc.destroy(weak.ctrl);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Comptime Structural Helpers
    // -------------------------------------------------------------------------

    /// Extracts the inner type T from Rc(T), Arc(T), WeakRc(T), or WeakArc(T).
    /// Returns null if the type is not a recognized ref-counted wrapper.
    fn refInnerType(comptime FT: type) ?type {
        const info = @typeInfo(FT);
        if (info != .@"struct") return null;
        const fields = info.@"struct".fields;
        if (fields.len < 1) return null;
        if (!std.mem.eql(u8, fields[0].name, "ctrl")) return null;
        const ctrl_ptr_info = @typeInfo(fields[0].type);
        if (ctrl_ptr_info != .pointer) return null;
        const ctrl_info = @typeInfo(ctrl_ptr_info.pointer.child);
        if (ctrl_info != .@"struct") return null;
        inline for (ctrl_info.@"struct".fields) |cf| {
            if (comptime std.mem.eql(u8, cf.name, "data")) {
                const data_info = @typeInfo(cf.type);
                if (data_info == .pointer) return data_info.pointer.child;
            }
        }
        return null;
    }

    /// Returns true if FT is an Arc(T) or WeakArc(T) — the control block
    /// uses atomic ref counts (strong field is not a plain integer).
    fn isAtomicRef(comptime FT: type) bool {
        const info = @typeInfo(FT);
        if (info != .@"struct") return false;
        const fields = info.@"struct".fields;
        if (fields.len < 1) return false;
        if (!comptime std.mem.eql(u8, fields[0].name, "ctrl")) return false;
        const ctrl_ptr_info = @typeInfo(fields[0].type);
        if (ctrl_ptr_info != .pointer) return false;
        const ctrl_info = @typeInfo(ctrl_ptr_info.pointer.child);
        if (ctrl_info != .@"struct") return false;
        inline for (ctrl_info.@"struct".fields) |cf| {
            if (comptime std.mem.eql(u8, cf.name, "strong")) {
                return @typeInfo(cf.type) != .int;
            }
        }
        return false;
    }

    /// Returns true if FT is a WeakRc(T) or WeakArc(T).
    /// Weak types have no `getData` decl (only strong Rc/Arc do).
    fn isWeakRef(comptime FT: type) bool {
        if (refInnerType(FT) == null) return false;
        return !@hasDecl(FT, "getData");
    }

    /// Release a single ref-counted value. Dispatches to the correct release
    /// function based on the comptime type (Rc/Arc/WeakRc/WeakArc).
    pub fn releaseOne(comptime FT: type, alloc: std.mem.Allocator, value: FT) void {
        const T = comptime refInnerType(FT) orelse return;
        const is_weak = comptime isWeakRef(FT);
        const is_atomic = comptime isAtomicRef(FT);
        if (is_weak) {
            if (is_atomic) {
                weakArcRelease(T, .{ .ctrl = @ptrCast(value.ctrl) });
            } else {
                weakRcRelease(T, .{ .ctrl = @ptrCast(value.ctrl) });
            }
        } else {
            if (is_atomic) {
                arcRelease(T, alloc, .{ .ctrl = @ptrCast(value.ctrl) });
            } else {
                rcRelease(T, alloc, .{ .ctrl = @ptrCast(value.ctrl) });
            }
        }
    }

    /// Walk all fields of struct T and release any that are ref-counted
    /// (Rc, Arc, WeakRc, WeakArc). Zero-cost: fields without ref-counted
    /// types emit no code thanks to comptime dead-code elimination.
    pub fn releaseFields(comptime T: type, alloc: std.mem.Allocator, value: T) void {
        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (comptime refInnerType(field.type) != null) {
                releaseOne(field.type, alloc, @field(value, field.name));
            }
        }
    }

    // -------------------------------------------------------------------------
    // Unified comptime cleanup — replaces per-type Ruby emit_cleanup logic.
    // The transpiler emits `defer CheatLib.cleanup(T, alloc, &x);` for every
    // variable that needs cleanup. Zig comptime eliminates no-op branches,
    // so primitives and copy types emit zero code.
    // -------------------------------------------------------------------------

    /// Returns true if T is a StringMap(V) wrapper (has inner + alloc + put).
    fn isStringMap(comptime T: type) bool {
        const info = @typeInfo(T);
        if (info != .@"struct") return false;
        return @hasField(T, "inner") and @hasField(T, "alloc") and @hasDecl(T, "put");
    }

    /// Returns true if T is a numeric map (AutoHashMapUnmanaged or similar).
    /// Detected by: struct with metadata field and deinit, but not a StringMap.
    fn isNumericMap(comptime T: type) bool {
        const info = @typeInfo(T);
        if (info != .@"struct") return false;
        if (isStringMap(T)) return false;
        return @hasField(T, "metadata") and @hasDecl(T, "deinit");
    }

    /// Returns true if T is a Pool(U) — has slots, free_stack, free_top, capacity.
    fn isPool(comptime T: type) bool {
        const info = @typeInfo(T);
        if (info != .@"struct") return false;
        return @hasField(T, "slots") and @hasField(T, "free_stack") and
               @hasField(T, "free_top") and @hasField(T, "capacity");
    }

    /// Returns true if T is a Set(U) — has inner field and is not a StringMap.
    fn isSetType(comptime T: type) bool {
        const info = @typeInfo(T);
        if (info != .@"struct") return false;
        if (!@hasField(T, "inner")) return false;
        if (isStringMap(T)) return false;
        // Set has insert/remove/contains but no alloc field
        return @hasDecl(T, "insert") and !@hasField(T, "alloc");
    }

    /// Returns true if T is a Locked(U) — has mutex + data fields.
    fn isLocked(comptime T: type) bool {
        const info = @typeInfo(T);
        if (info != .@"struct") return false;
        return @hasField(T, "mutex") and @hasField(T, "data") and !@hasField(T, "lock");
    }

    /// Returns true if T is a RwLocked(U) — has lock (RwLock) + data fields.
    fn isRwLocked(comptime T: type) bool {
        const info = @typeInfo(T);
        if (info != .@"struct") return false;
        return @hasField(T, "lock") and @hasField(T, "data") and !@hasField(T, "mutex");
    }

    /// Unified comptime cleanup for any CLEAR type.
    /// Dispatches to the correct cleanup function based on structural type analysis.
    /// For types that need no cleanup (primitives, enums, plain structs without RC fields),
    /// comptime eliminates the entire function body — zero runtime cost.
    pub fn cleanup(comptime T: type, alloc: std.mem.Allocator, cptr: *const T) void {
        const ptr = @constCast(cptr);

        // 0. Strings: free with the provided allocator. Frame-arena free is
        // a no-op, so frame strings are safe. Heap strings are freed.
        if (T == []const u8 or T == []u8) {
            if (ptr.len > 0) alloc.free(ptr.*);
            return;
        }

        // 1. Ref-counted types: Rc(U), Arc(U), WeakRc(U), WeakArc(U)
        if (comptime refInnerType(T) != null) {
            releaseOne(T, alloc, ptr.*);
            return;
        }

        // 2. ArrayList (list collections)
        if (comptime isArrayList(T)) {
            const ElemT = comptime arrayListElemType(T).?;
            // Recursively cleanup elements (RC release, string free, nested unions, etc.)
            if (comptime needsCleanup(ElemT)) {
                for (ptr.items) |*item| {
                    cleanup(ElemT, alloc, item);
                }
            }
            ptr.deinit(alloc);
            return;
        }

        // 2b. Slices: recursively cleanup elements then free the buffer.
        // The compiler guarantees cleanup is only called on owned slices
        // (COPY results, TAKES params) via _moved guards.
        if (comptime blk: {
            const ti = @typeInfo(T);
            break :blk ti == .pointer and ti.pointer.size == .slice and T != []const u8 and T != []u8;
        }) {
            const ElemT = @typeInfo(T).pointer.child;
            if (comptime needsCleanup(ElemT)) {
                for (ptr.*) |*elem| {
                    cleanup(ElemT, alloc, elem);
                }
            }
            if (ptr.len > 0) alloc.free(ptr.*);
            return;
        }

        // 3. StringMap(V) — string-keyed hashmap wrapper
        if (comptime isStringMap(T)) {
            ptr.deinit(alloc, alloc);
            return;
        }

        // 4. Numeric map (AutoHashMapUnmanaged or custom hash)
        if (comptime isNumericMap(T)) {
            const VT = @TypeOf(ptr.values());
            const ElemT = std.meta.Elem(VT);
            if (comptime needsCleanup(ElemT)) {
                var vit = ptr.valueIterator();
                while (vit.next()) |val_ptr| cleanup(ElemT, alloc, val_ptr);
            }
            ptr.deinit(alloc);
            return;
        }

        // 5. Pool(U)
        if (comptime isPool(T)) {
            ptr.deinit(alloc);
            return;
        }

        // 6. Set(U)
        if (comptime isSetType(T)) {
            // Release ref-counted elements
            const InnerMap = @TypeOf(ptr.inner);
            const inner_info = @typeInfo(InnerMap);
            if (inner_info == .@"struct") {
                // Iterate keys to release RC elements or free duped strings
                var it = ptr.inner.keyIterator();
                while (it.next()) |key_ptr| {
                    const KeyT = @TypeOf(key_ptr.*);
                    if (comptime refInnerType(KeyT) != null) {
                        releaseOne(KeyT, alloc, key_ptr.*);
                    } else if (KeyT == []const u8) {
                        alloc.free(key_ptr.*);
                    }
                }
            }
            ptr.inner.deinit(alloc);
            return;
        }

        // 7. Locked(U) / RwLocked(U)
        if (comptime isLocked(T)) {
            alloc.destroy(@as(*align(@alignOf(T)) T, @alignCast(ptr)));
            return;
        }
        if (comptime isRwLocked(T)) {
            alloc.destroy(@as(*align(@alignOf(T)) T, @alignCast(ptr)));
            return;
        }

        // 8. Structs with a deinit method (ShardedList, ShardedMap, etc.)
        //    Detect deinit arity: 1 alloc (ShardedList) vs 2 allocs (ShardedMap).
        if (@typeInfo(T) == .@"struct" and @hasDecl(T, "deinit") and
            !isStringMap(T) and !isPool(T) and !isNumericMap(T))
        {
            const deinit_info = @typeInfo(@TypeOf(T.deinit));
            const param_count = deinit_info.@"fn".params.len;
            if (param_count == 3) {
                // deinit(self, key_alloc, bucket_alloc)
                ptr.deinit(alloc, alloc);
            } else if (param_count == 2) {
                // deinit(self, alloc)
                ptr.deinit(alloc);
            } else {
                // deinit(self) - no allocator needed
                ptr.deinit();
            }
            return;
        }

        // 9. Structs: recursively clean up all owned fields
        const info = @typeInfo(T);
        if (info == .@"struct") {
            inline for (info.@"struct".fields) |field| {
                const FT = field.type;
                const f_info = @typeInfo(FT);
                // Skip opaque types and function pointers (Zig stdlib internals)
                if (f_info == .@"opaque" or f_info == .@"fn") continue;
                if (comptime refInnerType(FT) != null) {
                    releaseOne(FT, alloc, @field(ptr, field.name));
                } else if (f_info == .pointer and f_info.pointer.size == .slice) {
                    const payload = @field(ptr, field.name);
                    if (FT == []const u8 or FT == []u8) {
                        if (payload.len > 0) alloc.free(payload);
                    } else {
                        if (comptime needsCleanup(f_info.pointer.child)) {
                            for (payload) |*elem| {
                                cleanup(f_info.pointer.child, alloc, elem);
                            }
                        }
                        if (payload.len > 0) alloc.free(payload);
                    }
                } else if (f_info == .pointer and f_info.pointer.size == .one and @typeInfo(f_info.pointer.child) != .@"opaque" and @typeInfo(f_info.pointer.child) != .@"fn") {
                    // Single pointer (*T): cleanup the pointee then free the pointer.
                    // This handles @indirect fields in inline struct union variants.
                    const pointee = @field(ptr, field.name);
                    const ChildT = f_info.pointer.child;
                    if (comptime needsCleanup(ChildT)) {
                        cleanup(ChildT, alloc, pointee);
                    }
                    alloc.destroy(pointee);
                } else if (comptime needsCleanup(FT)) {
                    cleanup(FT, alloc, &@field(ptr, field.name));
                }
            }
            return;
        }

        // 9. Tagged unions: check active variant and clean up its payload.
        if (info == .@"union" and info.@"union".tag_type != null) {
            inline for (info.@"union".fields) |field| {
                if (std.meta.activeTag(ptr.*) == @field(std.meta.Tag(T), field.name)) {
                    const FT = field.type;
                    const f_info = @typeInfo(FT);
                    // Slice variant ([]T): recursively cleanup elements then free buffer.
                    if (f_info == .pointer and f_info.pointer.size == .slice) {
                        if (FT == []const u8 or FT == []u8) {
                            const str = @field(ptr, field.name);
                            if (str.len > 0) alloc.free(str);
                        } else {
                            const payload = @field(ptr, field.name);
                            if (comptime needsCleanup(f_info.pointer.child)) {
                                for (payload) |*elem| {
                                    cleanup(f_info.pointer.child, alloc, elem);
                                }
                            }
                            if (payload.len > 0) alloc.free(payload);
                        }
                    } else if (f_info == .pointer and f_info.pointer.size == .one and
                        @typeInfo(f_info.pointer.child) != .@"opaque" and @typeInfo(f_info.pointer.child) != .@"fn")
                    {
                        // Single pointer (*T): cleanup pointee then free pointer.
                        const pointee = @field(ptr, field.name);
                        const ChildT = f_info.pointer.child;
                        if (comptime needsCleanup(ChildT)) {
                            cleanup(ChildT, alloc, pointee);
                        }
                        alloc.destroy(pointee);
                    } else if (comptime needsCleanup(FT)) {
                        cleanup(FT, alloc, &@field(ptr, field.name));
                    }
                    return;
                }
            }
            return;
        }

        // Primitives, enums, untagged unions: no-op (comptime-eliminated)
    }

    /// Returns true if a type needs cleanup (has heap-allocated data).
    pub fn needsCleanup(comptime FT: type) bool {
        @setEvalBranchQuota(100000);
        if (FT == []const u8 or FT == []u8) return true;
        if (refInnerType(FT) != null) return true;
        if (isArrayList(FT)) return true;
        if (isStringMap(FT)) return true;
        if (isNumericMap(FT)) return true;
        if (isPool(FT)) return true;
        const ft_info = @typeInfo(FT);
        // Pointers and non-string slices trivially need cleanup (heap data).
        // Check BEFORE recursing to avoid exponential blowup on recursive types.
        if (ft_info == .pointer and ft_info.pointer.size == .one) return true;
        if (ft_info == .pointer and ft_info.pointer.size == .slice) return true;
        // Types with deinit manage their own lifecycle — don't recurse into fields.
        if (ft_info == .@"struct" and @hasDecl(FT, "deinit")) return true;
        if (ft_info == .@"struct") {
            inline for (ft_info.@"struct".fields) |field| {
                if (comptime needsCleanup(field.type)) return true;
            }
        }
        if (ft_info == .@"union" and ft_info.@"union".tag_type != null) {
            inline for (ft_info.@"union".fields) |field| {
                if (comptime needsCleanup(field.type)) return true;
            }
        }
        return false;
    }

    /// Promote all escapable fields of a struct from frame arena to heap.
    /// DEPRECATED: use promote() for new code. Kept for backward compat.
    /// Deep-copy a union value's heap-owning payload (strings, slices, struct fields).
    pub fn dupeUnionValue(comptime T: type, value: T, alloc: std.mem.Allocator) std.mem.Allocator.Error!T {
        const info = @typeInfo(T);
        if (info != .@"union" or info.@"union".tag_type == null) return value;
        var result = value;
        inline for (info.@"union".fields) |field| {
            if (std.meta.activeTag(value) == @field(std.meta.Tag(T), field.name)) {
                const FT = field.type;
                const ft_info = @typeInfo(FT);
                if (FT == []const u8) {
                    const src = @field(value, field.name);
                    @field(result, field.name) = if (src.len > 0) try alloc.dupe(u8, src) else src;
                    return result;
                } else if (ft_info == .pointer and ft_info.pointer.size == .slice and FT != []u8) {
                    const src = @field(value, field.name);
                    if (src.len > 0) {
                        const ElemT = ft_info.pointer.child;
                        const buf = try alloc.alloc(ElemT, src.len);
                        for (src, 0..) |elem, i| {
                            buf[i] = try dupeUnionValue(ElemT, elem, alloc);
                        }
                        @field(result, field.name) = buf;
                    }
                    return result;
                } else if (ft_info == .pointer and ft_info.pointer.size == .one and
                    @typeInfo(ft_info.pointer.child) != .@"opaque" and @typeInfo(ft_info.pointer.child) != .@"fn")
                {
                    // Single pointer (*T): allocate new pointee and deep-copy.
                    // Handles @indirect fields in union variants.
                    const src_ptr = @field(value, field.name);
                    const ChildT = ft_info.pointer.child;
                    const new_ptr = try alloc.create(ChildT);
                    // Use dupeStructSlices for struct pointees (deep-copies string/slice fields).
                    // Use dupeUnionValue for union pointees.
                    if (@typeInfo(ChildT) == .@"struct")
                        new_ptr.* = try dupeStructSlices(ChildT, src_ptr.*, alloc)
                    else
                        new_ptr.* = try dupeUnionValue(ChildT, src_ptr.*, alloc);
                    @field(result, field.name) = new_ptr;
                    return result;
                } else if (ft_info == .@"struct" and
                    !isArrayList(FT) and !isStringMap(FT) and !isNumericMap(FT) and !isPool(FT) and
                    !(@hasField(FT, "inner") and @hasField(FT, "alloc") and @hasDecl(FT, "put")))
                {
                    @field(result, field.name) = try dupeStructSlices(FT, @field(value, field.name), alloc);
                    return result;
                }
                return value;
            }
        }
        return value;
    }

    /// Deep-copy slice and pointer fields inside a struct.
    fn dupeStructSlices(comptime T: type, value: T, alloc: std.mem.Allocator) std.mem.Allocator.Error!T {
        const info = @typeInfo(T);
        if (info != .@"struct") return value;
        var result = value;
        inline for (info.@"struct".fields) |field| {
            const FT = field.type;
            const ft_info = @typeInfo(FT);
            if (ft_info == .pointer and ft_info.pointer.size == .slice) {
                const src = @field(value, field.name);
                if (src.len > 0) {
                    const ElemT = ft_info.pointer.child;
                    if (FT == []const u8 or FT == []u8) {
                        @field(result, field.name) = try alloc.dupe(u8, src);
                    } else {
                        const buf = try alloc.alloc(ElemT, src.len);
                        for (src, 0..) |elem, i| {
                            buf[i] = try dupeUnionValue(ElemT, elem, alloc);
                        }
                        @field(result, field.name) = buf;
                    }
                }
            } else if (ft_info == .pointer and ft_info.pointer.size == .one) {
                const child_ptr = @field(value, field.name);
                const ChildT = ft_info.pointer.child;
                const new_ptr = try alloc.create(ChildT);
                new_ptr.* = try dupeUnionValue(ChildT, child_ptr.*, alloc);
                @field(result, field.name) = new_ptr;
            } else if (ft_info == .@"union" and ft_info.@"union".tag_type != null) {
                @field(result, field.name) = try dupeUnionValue(FT, @field(value, field.name), alloc);
            }
        }
        return result;
    }

    pub fn promoteFields(comptime T: type, rt: *Runtime, value: *T) !void {
        try promote(T, rt, value);
    }

    /// Deep promote: unconditionally dupe ALL strings (including heap).
    /// Used for HPT independence -- the source is about to be freed,
    /// so the returned copy must own its own data regardless of allocator.
    pub fn promoteDeep(comptime T: type, rt: *Runtime, value: *T) std.mem.Allocator.Error!void {
        const info = @typeInfo(T);

        if (T == []const u8 or T == []u8) {
            if (value.len == 0) return;
            value.* = try rt.heapAlloc().dupe(u8, value.*);
            return;
        }

        if (comptime isArrayList(T)) {
            const ElemT = comptime arrayListElemType(T).?;
            try promoteList(ElemT, rt, value);
            if (comptime needsPromotion(ElemT)) {
                for (value.items) |*elem| {
                    try promoteDeep(ElemT, rt, elem);
                }
            }
            return;
        }

        if (comptime isStringMap(T)) {
            value.alloc = rt.heapAlloc();
            return;
        }

        if (info == .@"union" and info.@"union".tag_type != null) {
            inline for (info.@"union".fields) |field| {
                if (comptime needsPromotion(field.type)) {
                    if (std.meta.activeTag(value.*) == @field(std.meta.Tag(T), field.name)) {
                        const FT = field.type;
                        const ft_info = @typeInfo(FT);
                        if (ft_info == .pointer and ft_info.pointer.size == .one and
                            @typeInfo(ft_info.pointer.child) != .@"opaque" and @typeInfo(ft_info.pointer.child) != .@"fn")
                        {
                            const ChildT = ft_info.pointer.child;
                            if (comptime needsPromotion(ChildT)) {
                                try promoteDeep(ChildT, rt, @field(value, field.name));
                            }
                        } else {
                            try promoteDeep(FT, rt, &@field(value, field.name));
                        }
                        return;
                    }
                }
            }
            return;
        }

        if (info == .@"struct") {
            inline for (info.@"struct".fields) |field| {
                const FT = field.type;
                const ft_info = @typeInfo(FT);
                if (ft_info == .pointer and ft_info.pointer.size == .one and
                    @typeInfo(ft_info.pointer.child) != .@"opaque" and @typeInfo(ft_info.pointer.child) != .@"fn")
                {
                    const ChildT = ft_info.pointer.child;
                    if (comptime needsPromotion(ChildT)) {
                        try promoteDeep(ChildT, rt, @field(value, field.name));
                    }
                } else if (comptime needsPromotion(FT)) {
                    try promoteDeep(FT, rt, &@field(value, field.name));
                }
            }
            return;
        }
    }

    /// Generic comptime promotion: walks any type and dupes all frame-arena
    /// data to heap. Handles strings, ArrayLists, StringMaps, structs, and
    /// tagged unions recursively. No-op for primitives (comptime eliminated).
    pub fn promote(comptime T: type, rt: *Runtime, value: *T) std.mem.Allocator.Error!void {
        const info = @typeInfo(T);

        // 1. Strings: dupe only frame-arena strings to heap.
        // Heap strings (from COPY, toString, etc.) are already escaped —
        // duping them again leaks the original.
        if (T == []const u8 or T == []u8) {
            if (value.len == 0) return;
            const frame_mem = rt.overflow_arena.static_block;
            const p = @intFromPtr(value.*.ptr);
            const frame_base = @intFromPtr(frame_mem.ptr);
            if (p >= frame_base and p < frame_base + frame_mem.len) {
                value.* = try rt.heapAlloc().dupe(u8, value.*);
            }
            return;
        }

        // 2. ArrayList: promote backing buffer + recurse into elements
        if (comptime isArrayList(T)) {
            const ElemT = comptime arrayListElemType(T).?;
            try promoteList(ElemT, rt, value);
            // Recursively promote elements if they contain escapable data
            if (comptime needsPromotion(ElemT)) {
                for (value.items) |*elem| {
                    try promote(ElemT, rt, elem);
                }
            }
            return;
        }

        // 3. StringMap: alloc is already heapAlloc (set at construction).
        // Ensure alloc field is heap. Keys and values are managed by StringMap.
        if (comptime isStringMap(T)) {
            value.alloc = rt.heapAlloc();
            return;
        }

        // 4. Tagged unions: promote the active variant's payload
        if (info == .@"union" and info.@"union".tag_type != null) {
            inline for (info.@"union".fields) |field| {
                if (comptime needsPromotion(field.type)) {
                    if (std.meta.activeTag(value.*) == @field(std.meta.Tag(T), field.name)) {
                        const FT = field.type;
                        const ft_info = @typeInfo(FT);
                        if (ft_info == .pointer and ft_info.pointer.size == .one and
                            @typeInfo(ft_info.pointer.child) != .@"opaque" and @typeInfo(ft_info.pointer.child) != .@"fn")
                        {
                            const ChildT = ft_info.pointer.child;
                            if (comptime needsPromotion(ChildT)) {
                                try promote(ChildT, rt, @field(value, field.name));
                            }
                        } else {
                            try promote(FT, rt, &@field(value, field.name));
                        }
                        return;
                    }
                }
            }
            return;
        }

        // 5. Structs: walk fields recursively
        if (info == .@"struct") {
            inline for (info.@"struct".fields) |field| {
                const FT = field.type;
                const ft_info = @typeInfo(FT);
                if (ft_info == .pointer and ft_info.pointer.size == .one and
                    @typeInfo(ft_info.pointer.child) != .@"opaque" and @typeInfo(ft_info.pointer.child) != .@"fn")
                {
                    // Single pointer (*T) from @indirect: promote the pointee.
                    const ChildT = ft_info.pointer.child;
                    if (comptime needsPromotion(ChildT)) {
                        try promote(ChildT, rt, @field(value, field.name));
                    }
                } else if (comptime needsPromotion(FT)) {
                    try promote(FT, rt, &@field(value, field.name));
                }
            }
            return;
        }

        // Primitives, enums, etc.: no-op (comptime-eliminated)
    }

    /// Returns true if a type has data that needs promotion (frame -> heap).
    fn needsPromotion(comptime FT: type) bool {
        if (FT == []const u8 or FT == []u8) return true;
        if (isArrayList(FT)) return true;
        if (isStringMap(FT)) return true;
        const ft_info = @typeInfo(FT);
        // Single pointer (*T) from @indirect: return true without recursing
        // to avoid infinite comptime recursion on self-referential types.
        if (ft_info == .pointer and ft_info.pointer.size == .one) return true;
        if (ft_info == .@"struct") {
            inline for (ft_info.@"struct".fields) |field| {
                if (comptime needsPromotion(field.type)) return true;
            }
        }
        if (ft_info == .@"union" and ft_info.@"union".tag_type != null) {
            inline for (ft_info.@"union".fields) |field| {
                if (comptime needsPromotion(field.type)) return true;
            }
        }
        return false;
    }

    fn isArrayList(comptime T: type) bool {
        return arrayListElemType(T) != null;
    }

    fn arrayListElemType(comptime T: type) ?type {
        const info = @typeInfo(T);
        if (info != .@"struct") return null;
        const fields = info.@"struct".fields;
        // ArrayListUnmanaged has `items` (slice) and `capacity` (usize)
        var has_items = false;
        var has_capacity = false;
        var elem_type: ?type = null;
        inline for (fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "items")) {
                has_items = true;
                const slice_info = @typeInfo(f.type);
                if (slice_info == .pointer and slice_info.pointer.size == .slice) {
                    elem_type = slice_info.pointer.child;
                }
            }
            if (comptime std.mem.eql(u8, f.name, "capacity")) has_capacity = true;
        }
        if (has_items and has_capacity) return elem_type;
        return null;
    }

    /// Deinit a list whose elements may be ref-counted. Releases each element
    /// before freeing the backing buffer. If elements are not ref-counted,
    /// comptime eliminates the release loop entirely.
    pub fn deinitList(comptime ElemT: type, alloc: std.mem.Allocator, heapAlloc: std.mem.Allocator, list: *std.ArrayListUnmanaged(ElemT)) void {
        if (comptime refInnerType(ElemT) != null) {
            for (list.items) |item| {
                releaseOne(ElemT, heapAlloc, item);
            }
        }
        list.deinit(alloc);
    }

    /// Deinit a set whose elements may be ref-counted. Releases each element
    /// before freeing the backing hashmap. For string sets, frees duped keys.
    /// If elements are not ref-counted, comptime eliminates the release loop.
    pub fn deinitSet(comptime ElemT: type, alloc: std.mem.Allocator, set: *Set(ElemT)) void {
        const is_string = ElemT == []const u8;
        if (comptime refInnerType(ElemT) != null) {
            var it = set.inner.keyIterator();
            while (it.next()) |key_ptr| {
                releaseOne(ElemT, alloc, key_ptr.*);
            }
        }
        if (is_string) {
            var it = set.inner.keyIterator();
            while (it.next()) |key_ptr| alloc.free(key_ptr.*);
        }
        set.inner.deinit(alloc);
    }

    // -------------------------------------------------------------------------
    // Mutex-Protected (locked / Locked)
    // -------------------------------------------------------------------------

    /// Locked(T): a mutex-protected heap-allocated value.
    /// Must remain at a stable address — never copy or move after first use.
    /// Acquire exclusive access via acquire(); release via guard.release().
    pub fn Locked(comptime T: type) type {
        return struct {
            mutex: std.Thread.Mutex = .{},
            data: T,

            const Self = @This();

            pub fn init(val: T) Self {
                return .{ .data = val };
            }

            pub fn acquire(self: *Self) Guard {
                self.mutex.lock();
                return Guard{ .parent = self };
            }

            pub const Guard = struct {
                parent: *Self,

                pub fn get(self: *Guard) *T {
                    return &self.parent.data;
                }

                pub fn getConst(self: *Guard) *const T {
                    return &self.parent.data;
                }

                pub fn release(self: *Guard) void {
                    self.parent.mutex.unlock();
                }
            };
        };
    }

    // -------------------------------------------------------------------------
    // Interior Mutability (RefCell)
    // -------------------------------------------------------------------------

    /// RefCell(T): interior mutability without a mutex. Single-thread only.
    /// Allows mutation through const bindings. Panics on overlapping mutable borrows.
    pub fn RefCell(comptime T: type) type {
        return struct {
            data: T,

            const Self = @This();

            pub fn init(val: T) Self {
                return .{ .data = val };
            }

            pub fn get(self: *Self) *T {
                return &self.data;
            }

            pub fn getConst(self: *const Self) *const T {
                return &self.data;
            }
        };
    }

    pub fn refCellCreate(comptime T: type, alloc: std.mem.Allocator, data: T) !*RefCell(T) {
        const ptr = try alloc.create(RefCell(T));
        ptr.* = RefCell(T).init(data);
        return ptr;
    }

    pub fn refCellDestroy(comptime T: type, alloc: std.mem.Allocator, rc: *RefCell(T)) void {
        alloc.destroy(rc);
    }

    /// Heap-allocate a new Locked(T) wrapping a value of type T.
    /// Caller owns the returned pointer; free with lockedDestroy.
    /// Allocate a bare T on the heap and return a mutable pointer.
    /// Used by @local capability — no Mutex/RwLock wrapper, just *T.
    pub fn localCreate(comptime T: type, alloc: std.mem.Allocator, data: T) !*T {
        const ptr = try alloc.create(T);
        ptr.* = data;
        return ptr;
    }

    pub fn lockedCreate(comptime T: type, alloc: std.mem.Allocator, data: T) !*Locked(T) {
        const ptr = try alloc.create(Locked(T));
        ptr.* = Locked(T).init(data);
        return ptr;
    }

    /// Free a heap-allocated Locked(T). Caller must ensure no active guards.
    pub fn lockedDestroy(comptime T: type, alloc: std.mem.Allocator, locked: *Locked(T)) void {
        alloc.destroy(locked);
    }

    // -------------------------------------------------------------------------
    // RwLock-Protected (writeLocked / RwLocked)
    // -------------------------------------------------------------------------

    /// RwLocked(T): a readers-writer-lock heap-allocated value.
    /// Multiple concurrent readers allowed; writers are exclusive.
    /// Acquire read access via read(); write access via write().
    ///
    /// Uses writer-preferring pthread_rwlock to prevent writer starvation.
    /// glibc's default pthread_rwlock is reader-preferring: new readers can
    /// acquire while a writer waits, causing indefinite starvation under load.
    /// PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP blocks new readers once
    /// a writer is waiting, matching Go's sync.RWMutex and Rust's futex_rwlock.
    pub fn RwLocked(comptime T: type) type {
        return struct {
            lock: std.c.pthread_rwlock_t = .{},
            data: T,

            const Self = @This();

            /// PTHREAD_RWLOCK_PREFER_WRITER_NONRECURSIVE_NP (glibc extension).
            /// Prevents writer starvation by blocking new readers when a writer waits.
            const PREFER_WRITER_NONRECURSIVE_NP: c_int = 2;

            const pthread_rwlockattr_t = extern struct {
                data: [8]u8 align(@alignOf(c_long)) = [_]u8{0} ** 8,
            };

            extern "c" fn pthread_rwlock_init(rwl: *std.c.pthread_rwlock_t, attr: ?*const pthread_rwlockattr_t) callconv(.c) std.c.E;
            extern "c" fn pthread_rwlockattr_init(attr: *pthread_rwlockattr_t) callconv(.c) std.c.E;
            extern "c" fn pthread_rwlockattr_destroy(attr: *pthread_rwlockattr_t) callconv(.c) std.c.E;
            extern "c" fn pthread_rwlockattr_setkind_np(attr: *pthread_rwlockattr_t, kind: c_int) callconv(.c) std.c.E;

            pub fn init(val: T) Self {
                var self = Self{ .data = val };
                var attr: pthread_rwlockattr_t = .{};
                var rc = pthread_rwlockattr_init(&attr);
                std.debug.assert(rc == .SUCCESS);
                rc = pthread_rwlockattr_setkind_np(&attr, PREFER_WRITER_NONRECURSIVE_NP);
                std.debug.assert(rc == .SUCCESS);
                rc = pthread_rwlock_init(&self.lock, &attr);
                std.debug.assert(rc == .SUCCESS);
                rc = pthread_rwlockattr_destroy(&attr);
                std.debug.assert(rc == .SUCCESS);
                return self;
            }

            pub fn read(self: *Self) ReadGuard {
                const rc = std.c.pthread_rwlock_rdlock(&self.lock);
                std.debug.assert(rc == .SUCCESS);
                return ReadGuard{ .parent = self };
            }

            pub fn write(self: *Self) WriteGuard {
                const rc = std.c.pthread_rwlock_wrlock(&self.lock);
                std.debug.assert(rc == .SUCCESS);
                return WriteGuard{ .parent = self };
            }

            pub const ReadGuard = struct {
                parent: *Self,

                pub fn get(self: *ReadGuard) *const T {
                    return &self.parent.data;
                }

                pub fn release(self: *ReadGuard) void {
                    const rc = std.c.pthread_rwlock_unlock(&self.parent.lock);
                    std.debug.assert(rc == .SUCCESS);
                }
            };

            pub const WriteGuard = struct {
                parent: *Self,

                pub fn get(self: *WriteGuard) *T {
                    return &self.parent.data;
                }

                pub fn getConst(self: *WriteGuard) *const T {
                    return &self.parent.data;
                }

                pub fn release(self: *WriteGuard) void {
                    const rc = std.c.pthread_rwlock_unlock(&self.parent.lock);
                    std.debug.assert(rc == .SUCCESS);
                }
            };
        };
    }

    /// Heap-allocate a new RwLocked(T) wrapping a value of type T.
    /// Caller owns the returned pointer; free with rwLockedDestroy.
    pub fn rwLockedCreate(comptime T: type, alloc: std.mem.Allocator, data: T) !*RwLocked(T) {
        const ptr = try alloc.create(RwLocked(T));
        ptr.* = RwLocked(T).init(data);
        return ptr;
    }

    /// Free a heap-allocated RwLocked(T). Caller must ensure no active guards.
    pub fn rwLockedDestroy(comptime T: type, alloc: std.mem.Allocator, locked: *RwLocked(T)) void {
        alloc.destroy(locked);
    }

    // -----------------------------------------------------------------------
    // Promise(T): A linear handle to the result of a BG (background) fiber.
    // Corresponds to ~T in CLEAR source. Must be consumed with NEXT exactly once.
    //
    // Lifecycle:
    //   Spawn site:  var p = try CheatLib.Promise(f64).spawn(rt.heapAlloc(), rt.getSched());
    //   In BG run(): ctx.inner.result = val;
    //                defer ctx.inner.wg.done();   // signals waiter
    //   NEXT site:   const val = p.next();        // blocks, then frees Inner
    //
    // The Inner is heap-allocated so it outlives both fiber stacks — the BG
    // fiber's stack is gone by the time NEXT is called, and the caller's stack
    // may have advanced past the spawn site.
    pub fn Promise(comptime T: type) type {
        return struct {
            const Self = @This();

            /// Heap-resident result cell shared between producer (BG fiber) and
            /// consumer (NEXT caller). Allocated at spawn, freed by next().
            /// Stores `anyerror!T` so fiber errors propagate to the caller.
            pub const Inner = struct {
                result: anyerror!T = error.BgNotReady,
                wg: WaitGroup,
            };

            inner: *Inner,
            alloc: std.mem.Allocator,

            /// Allocate an Inner on the heap and return the Promise handle.
            /// Pass `promise.inner` into the BG context struct so the fiber can
            /// write the result and signal completion.
            /// `sched` must be the calling fiber's scheduler (`rt.getSched()`).
            pub fn spawn(alloc: std.mem.Allocator, sched: *fp.Scheduler) !Self {
                const inner = try alloc.create(Inner);
                inner.* = .{
                    .result = error.BgNotReady,
                    .wg = WaitGroup.init(sched),
                };
                inner.wg.add(1);
                return Self{ .inner = inner, .alloc = alloc };
            }

            /// Block the current fiber until the BG fiber has written its result,
            /// then return the result (or propagate the error) and free Inner.
            ///
            /// If the BG fiber errored, the error is stored in `inner.result`
            /// and re-raised here. The caller handles it with OR or OR RAISE.
            pub fn next(self: Self) anyerror!T {
                self.inner.wg.wait();
                const val = self.inner.result;
                self.alloc.destroy(self.inner);
                return val;
            }

            /// No-op: next() owns the Inner lifecycle. After next() frees Inner,
            /// the pointer is dangling. Cleanup must not recurse into fields.
            pub fn deinit(self: *Self, alloc_: std.mem.Allocator) void {
                _ = self;
                _ = alloc_;
            }
        };
    }

    // -----------------------------------------------------------------------
    // SharedPromise(T): A memoized, non-linear promise that can be consumed by
    // multiple concurrent holders.  Corresponds to ~T@shared in CLEAR source.
    //
    // Unlike Promise(T), next() is idempotent per handle:
    //   - First call blocks until the BG fiber writes its result, then caches it.
    //   - Subsequent calls on the same handle return the cached value instantly.
    //   - The heap-allocated Inner is freed when the last outstanding handle
    //     calls next() (ref_count reaches 0).
    //
    // Use retain() to clone a handle before passing it to another fiber.
    // retain() increments the ref_count; the new handle must also call next().
    //
    // Lifecycle:
    //   Spawn:      var sp = try CheatLib.SharedPromise(f64).spawn(alloc, sched);
    //   Clone:      var sp2 = sp.retain();       // ref_count: 1 -> 2
    //   In BG:      ctx.inner.result = val;
    //               defer ctx.inner.wg.done();
    //   Consume:    const v1 = sp.next();         // blocks, caches, ref_count: 2->1
    //               const v2 = sp2.next();        // blocks, caches, ref_count: 1->0 -> free
    //               const v3 = sp.next();         // instant: returns cached value
    pub fn SharedPromise(comptime T: type) type {
        return struct {
            const Self = @This();

            /// Heap-resident result cell.  Outlives all handles: freed only when
            /// ref_count reaches 0 (i.e. all handles have called next() once).
            pub const Inner = struct {
                result: anyerror!T = error.BgNotReady,
                wg: WaitGroup,
                ref_count: std.atomic.Value(usize),
            };

            inner: *Inner,
            alloc: std.mem.Allocator,
            /// Cached result after the first next() call on this handle.
            /// null = not yet resolved by this handle.
            resolved: ?T = null,

            pub fn spawn(alloc: std.mem.Allocator, sched: *fp.Scheduler) !Self {
                const inner = try alloc.create(Inner);
                inner.* = .{
                    .result = error.BgNotReady,
                    .wg = WaitGroup.init(sched),
                    .ref_count = std.atomic.Value(usize).init(1),
                };
                inner.wg.add(1);
                return Self{ .inner = inner, .alloc = alloc, .resolved = null };
            }

            /// Block until the BG fiber delivers its result, then return it.
            /// Idempotent: once resolved, subsequent calls return the cached value
            /// without touching the Inner (which may already have been freed).
            /// Decrements the ref_count on the first call; frees Inner at zero.
            pub fn next(self: *Self) anyerror!T {
                if (self.resolved) |val| return val;
                self.inner.wg.wait();
                const val = try self.inner.result;
                self.resolved = val;
                const prev = self.inner.ref_count.fetchSub(1, .release);
                if (prev == 1) {
                    _ = self.inner.ref_count.load(.acquire);
                    self.alloc.destroy(self.inner);
                }
                return val;
            }

            /// Clone this handle, incrementing the shared ref_count.
            /// The returned handle must also eventually call next() to release its
            /// reference.  Call retain() before passing a handle to another fiber.
            pub fn retain(self: Self) Self {
                _ = self.inner.ref_count.fetchAdd(1, .acquire);
                return Self{ .inner = self.inner, .alloc = self.alloc, .resolved = null };
            }
        };
    }

    // -----------------------------------------------------------------------
    // BoundedStream(T, N): A fixed-size ordered stream of N concurrent BG fibers.
    // Corresponds to ~T[N] in CLEAR source.
    //
    // Each slot is a Promise(T) spawned at stream creation. NEXT consumes them
    // in FIFO order — the Nth NEXT call blocks on the Nth promise then frees it.
    // Calling next() more than N times panics at runtime.
    //
    // Lifecycle:
    //   Creation:   var s = CheatLib.BoundedStream(f64, 3){ .items = .{ p0, p1, p2 } };
    //   Consume:    const val = s.next();   // O(1), head advances
    //   Exhausted:  s.next()                // panics
    pub fn BoundedStream(comptime T: type, comptime N: usize) type {
        return struct {
            const Self = @This();

            items: [N]Promise(T),
            head: usize = 0,

            /// Block on the next unconsumed BG fiber and return its result.
            /// Propagates errors from the underlying Promise.
            pub fn next(self: *Self) anyerror!T {
                if (self.head >= N) @panic("BoundedStream exhausted: all items consumed");
                const val = try self.items[self.head].next();
                self.head += 1;
                return val;
            }
        };
    }

    // -----------------------------------------------------------------------
    // Stream(T): An open/closeable generator stream. Corresponds to ~T[?] in CLEAR.
    //
    // A BG STREAM { YIELD x; } block spawns a generator fiber that calls push() for
    // each YIELD and close() when the body completes. The consumer calls next() to
    // retrieve values one by one; next() returns null when the stream is exhausted.
    //
    // First next() call blocks via WaitGroup until the generator fiber has finished
    // (buffered all values). Subsequent next() calls return immediately from the buffer.
    //
    // Lifecycle:
    //   Spawn:   var s = try CheatLib.Stream(f64).spawnNew(alloc, sched);
    //   In gen:  var local = CheatLib.Stream(f64){ .inner = ctx.stream_inner, .alloc = ctx.alloc };
    //            defer local.close();
    //            try local.push(1.0); try local.push(2.0);
    //   Consume: const v1 = s.next(); // ?f64 — blocks until generator done, then pops
    //            const v2 = s.next(); // ?f64 — pops next item
    //            const v3 = s.next(); // null — exhausted
    //   Cleanup: defer s.deinit();    // frees Inner + buffer
    pub fn Stream(comptime T: type) type {
        return struct {
            const Self = @This();

            pub const Inner = struct {
                items: std.ArrayListUnmanaged(T) = .{},
                wg: WaitGroup = undefined,
                err: ?anyerror = null, // terminal error from generator fiber
            };

            inner: *Inner,
            alloc: std.mem.Allocator,
            head: usize = 0,

            /// Allocate an Inner on the heap, initialize the WaitGroup, and return the Stream handle.
            pub fn spawnNew(alloc: std.mem.Allocator, sched: *fp.Scheduler) !Self {
                const inner = try alloc.create(Inner);
                inner.* = .{ .items = .{}, .wg = WaitGroup.init(sched) };
                inner.wg.add(1);
                return Self{ .inner = inner, .alloc = alloc, .head = 0 };
            }

            /// Called by the generator fiber to buffer a yielded value.
            pub fn push(self: *Self, val: T) !void {
                try self.inner.items.append(self.alloc, val);
            }

            /// Called by the generator fiber (via defer) when its body finishes.
            /// Signals the consumer that all values have been buffered.
            pub fn close(self: *Self) void {
                self.inner.wg.done();
            }

            /// Record a terminal error from the generator fiber.
            /// Called when the generator's run() catches an error before close().
            pub fn setError(self: *Self, err: anyerror) void {
                self.inner.err = err;
            }

            /// Consume the next buffered value.
            /// Blocks on the first call until the generator fiber has finished.
            /// Returns error if the generator fiber failed, null if exhausted.
            pub fn next(self: *Self) anyerror!?T {
                self.inner.wg.wait();
                if (self.inner.err) |err| return err;
                if (self.head >= self.inner.items.items.len) return null;
                const val = self.inner.items.items[self.head];
                self.head += 1;
                return val;
            }

            /// Free the buffer and Inner allocation. Call once when done consuming.
            pub fn deinit(self: *Self) void {
                self.inner.items.deinit(self.alloc);
                self.alloc.destroy(self.inner);
            }
        };
    }

    // -----------------------------------------------------------------------
    // InfStream(T): A buffered generator stream. Corresponds to ~T[INF] in CLEAR.
    //
    // Lock-free SPSC ring buffer between producer and consumer fibers.
    // Producer fills the buffer without blocking; blocks only when full.
    // Consumer reads without blocking; blocks only when empty.
    // Context switches happen only at buffer-full/buffer-empty boundaries,
    // reducing overhead by ~BUF_SIZE compared to single-slot rendezvous.
    //
    // Both sides run as green fibers on the same scheduler. Blocking = fiber yield.
    // The generator is expected to loop forever (BG STREAM { WHILE TRUE DO YIELD; END }).
    //
    // Lifecycle:
    //   Spawn:   var s = try CheatLib.InfStream(f64).spawnNew(alloc, sched);
    //   In gen:  var local = CheatLib.InfStream(f64){ .inner = ctx.stream_inner, .alloc = ctx.alloc };
    //            while (true) { try local.push(val); }
    //   Consume: const v = s.next();  // T — blocks until generator pushes
    //   Cleanup: defer s.deinit();    // frees Inner
    pub fn InfStream(comptime T: type) type {
        return struct {
            const Self = @This();
            const BUF_SIZE: u32 = 64; // must be power of 2
            const MASK: u32 = BUF_SIZE - 1;

            pub const Inner = struct {
                buf: [BUF_SIZE]T = undefined,
                // Producer writes head, consumer reads head.
                head: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
                // Consumer writes tail, producer reads tail.
                tail: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
                // Spinlock protecting task pointers (only used for block/wake)
                lock: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
                consumer_task: ?*Task = null,
                producer_task: ?*Task = null,
                sched: *fp.Scheduler,
                closed: bool = false,
                err: ?anyerror = null,
            };

            inner: *Inner,
            alloc: std.mem.Allocator,

            pub fn spawnNew(alloc: std.mem.Allocator, sched: *fp.Scheduler) !Self {
                const inner = try alloc.create(Inner);
                inner.* = .{ .sched = sched };
                return Self{ .inner = inner, .alloc = alloc };
            }

            /// Generator pushes a value. Lock-free fast path when buffer has space.
            /// Blocks (yields fiber) only when buffer is full.
            pub fn push(self: *Self, val: T) error{StreamClosed}!void {
                const inner = self.inner;

                while (true) {
                    if (inner.closed) return error.StreamClosed;

                    const h = inner.head.load(.monotonic);
                    const t = inner.tail.load(.acquire);

                    if (h -% t < BUF_SIZE) {
                        // Buffer has space — write without locking.
                        inner.buf[h & MASK] = val;
                        inner.head.store(h +% 1, .release);

                        // Wake consumer if it was blocked (buffer was empty).
                        if (h == t) {
                            // Buffer was empty, consumer might be waiting.
                            while (inner.lock.swap(1, .acquire) == 1) std.Thread.yield() catch {};
                            if (inner.consumer_task) |consumer| {
                                inner.consumer_task = null;
                                inner.lock.store(0, .release);
                                inner.sched.schedule(consumer);
                            } else {
                                inner.lock.store(0, .release);
                            }
                        }
                        return;
                    }

                    // Buffer full — block until consumer drains at least one slot.
                    while (inner.lock.swap(1, .acquire) == 1) std.Thread.yield() catch {};
                    if (inner.closed) { inner.lock.store(0, .release); return error.StreamClosed; }
                    // Re-check after acquiring lock (consumer may have drained).
                    const t2 = inner.tail.load(.acquire);
                    if (h -% t2 < BUF_SIZE) {
                        inner.lock.store(0, .release);
                        continue; // Retry — space available now.
                    }
                    const task = inner.sched.getCurrent();
                    task.status.store(.Blocked, .release);
                    inner.producer_task = task;
                    inner.lock.store(0, .release);
                    task.base.yield();
                }
            }

            /// Consumer reads the next value. Lock-free fast path when buffer has data.
            /// Blocks (yields fiber) only when buffer is empty.
            pub fn next(self: *Self) anyerror!T {
                const inner = self.inner;

                while (true) {
                    const t = inner.tail.load(.monotonic);
                    const h = inner.head.load(.acquire);

                    if (h != t) {
                        // Buffer has data — read without locking.
                        const val = inner.buf[t & MASK];
                        inner.tail.store(t +% 1, .release);

                        // Wake producer if it was blocked (buffer was full).
                        if (h -% t == BUF_SIZE) {
                            // Buffer was full, producer might be waiting.
                            while (inner.lock.swap(1, .acquire) == 1) std.Thread.yield() catch {};
                            if (inner.producer_task) |producer| {
                                inner.producer_task = null;
                                inner.lock.store(0, .release);
                                inner.sched.schedule(producer);
                            } else {
                                inner.lock.store(0, .release);
                            }
                        }
                        return val;
                    }

                    // Buffer empty — check for close/error, then block.
                    if (inner.closed) {
                        if (inner.err) |err| return err;
                    }

                    while (inner.lock.swap(1, .acquire) == 1) std.Thread.yield() catch {};
                    if (inner.closed) {
                        inner.lock.store(0, .release);
                        if (inner.err) |err| return err;
                    }
                    // Re-check after acquiring lock (producer may have pushed).
                    const h2 = inner.head.load(.acquire);
                    if (h2 != t) {
                        inner.lock.store(0, .release);
                        continue; // Retry — data available now.
                    }
                    const task = inner.sched.getCurrent();
                    task.status.store(.Blocked, .release);
                    inner.consumer_task = task;
                    inner.lock.store(0, .release);
                    task.base.yield();
                }
            }

            /// Signal EOF to the consumer: no more values will be pushed.
            /// Wakes the consumer if it was blocked waiting for data.
            pub fn close(self: *Self) void {
                const inner = self.inner;
                while (inner.lock.swap(1, .acquire) == 1) std.Thread.yield() catch {};
                inner.closed = true;
                if (inner.consumer_task) |consumer| {
                    inner.consumer_task = null;
                    inner.lock.store(0, .release);
                    inner.sched.schedule(consumer);
                } else {
                    inner.lock.store(0, .release);
                }
            }

            /// Consumer reads next value, returning null on EOF (closed + empty).
            /// Lock-free fast path when buffer has data.
            /// Blocks (yields fiber) when buffer is empty and stream is open.
            pub fn nextOrNull(self: *Self) anyerror!?T {
                const inner = self.inner;

                while (true) {
                    const t = inner.tail.load(.monotonic);
                    const h = inner.head.load(.acquire);

                    if (h != t) {
                        // Buffer has data — read without locking.
                        const val = inner.buf[t & MASK];
                        inner.tail.store(t +% 1, .release);

                        // Wake producer if it was blocked (buffer was full).
                        if (h -% t == BUF_SIZE) {
                            while (inner.lock.swap(1, .acquire) == 1) std.Thread.yield() catch {};
                            if (inner.producer_task) |producer| {
                                inner.producer_task = null;
                                inner.lock.store(0, .release);
                                inner.sched.schedule(producer);
                            } else {
                                inner.lock.store(0, .release);
                            }
                        }
                        return val;
                    }

                    // Buffer empty — check for close, then block.
                    if (inner.closed) {
                        if (inner.err) |err| return err;
                        return null; // EOF
                    }

                    while (inner.lock.swap(1, .acquire) == 1) std.Thread.yield() catch {};
                    // Re-check under lock (producer may have pushed or closed).
                    const h2 = inner.head.load(.acquire);
                    if (h2 != t) {
                        inner.lock.store(0, .release);
                        continue; // Data available now.
                    }
                    if (inner.closed) {
                        inner.lock.store(0, .release);
                        if (inner.err) |err| return err;
                        return null; // EOF
                    }
                    const task = inner.sched.getCurrent();
                    task.status.store(.Blocked, .release);
                    inner.consumer_task = task;
                    inner.lock.store(0, .release);
                    task.base.yield();
                }
            }

            /// Signal the generator fiber to stop.
            /// Sets closed flag and wakes the producer if blocked.
            /// The producer will see closed=true, return error.StreamClosed, and free Inner.
            pub fn deinit(self: *Self) void {
                const inner = self.inner;
                while (inner.lock.swap(1, .acquire) == 1) std.Thread.yield() catch {};
                inner.closed = true;
                if (inner.producer_task) |producer| {
                    inner.producer_task = null;
                    inner.lock.store(0, .release);
                    inner.sched.schedule(producer);
                } else {
                    inner.lock.store(0, .release);
                }
            }
        };
    }

    pub fn assert(condition: bool, msg: []const u8) void {
        if (!condition) {
            std.debug.print("ASSERTION FAILED: {s}\n", .{msg});
            std.process.exit(1);
        }
    }

    // -----------------------------------------------------------------------
    // Pool(T): A generational pool for ABA-safe handle-based access.
    //
    // Fixed-capacity pool with generational handles and O(1) insert/remove.
    //
    // Handles are u64 values encoding [generation: upper 32 bits][index: lower 32 bits].
    // Generation counters prevent use-after-remove (ABA safety).
    //
    // All slots are pre-allocated upfront — zero allocator calls during operation.
    // A free stack provides O(1) insert (pop) and O(1) remove (push).
    //
    // Usage (mirrors CLEAR `MUTABLE p: Entity[1000]@pool = []`):
    //   var p = try CheatLib.Pool(Entity).initCapacity(allocator, 1000);
    //   defer p.deinit(allocator);
    //   const id: u64 = p.insert(Entity{ .name = "Alice" });  // O(1), panics if full
    //   const ptr: ?*Entity = p.get(id);   // null if stale
    //   p.remove(id);                      // O(1), increments generation
    pub fn Pool(comptime T: type) type {
        return struct {
            const Self = @This();

            const Slot = struct {
                generation: u32 = 0,
                alive: bool = false,
                value: T = undefined,
            };

            slots: []Slot = &.{},
            /// Stack of free slot indices. Top is at free_stack[free_top - 1].
            free_stack: []u32 = &.{},
            free_top: u32 = 0,
            capacity: u32 = 0,
            live_count: u32 = 0,

            /// Pre-allocate all slots and build the free stack.
            pub fn initCapacity(allocator: std.mem.Allocator, cap: u32) !Self {
                const slots = try allocator.alloc(Slot, cap);
                // Zero the entire buffer so alive=false for all slots.
                // @memset with Slot{} leaves value=undefined which may not
                // zero the alive field (Zig fills undefined with 0xAA in debug).
                @memset(std.mem.sliceAsBytes(slots), 0);
                const free_stack = try allocator.alloc(u32, cap);
                // Fill free stack so index 0 is popped first (LIFO: push N-1..0)
                for (0..cap) |i| {
                    free_stack[i] = @intCast(cap - 1 - i);
                }
                return Self{
                    .slots = slots,
                    .free_stack = free_stack,
                    .free_top = cap,
                    .capacity = cap,
                };
            }

            pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
                // Only scan slots that could have been used. Slots are allocated
                // from the free stack in LIFO order (0, 1, 2, ...) so the highest
                // possible used index is capacity - free_top.
                const max_used = self.capacity - self.free_top;
                for (self.slots[0..max_used]) |*slot| {
                    if (slot.alive) {
                        deinitFields(&slot.value, allocator);
                    }
                }
                allocator.free(self.slots);
                allocator.free(self.free_stack);
            }

            /// Cleanup all fields of a struct value using CheatLib.cleanup.
            fn deinitFields(value: *T, alloc: std.mem.Allocator) void {
                CheatLib.cleanup(T, alloc, value);
            }

            /// Insert a value, returning a stable u64 handle. O(1).
            /// Panics if the pool is full.
            pub fn insert(self: *Self, _: std.mem.Allocator, value: T) !u64 {
                if (self.free_top == 0) @panic("Pool is full");
                self.free_top -= 1;
                const idx = self.free_stack[self.free_top];
                const slot = &self.slots[idx];
                const gen = slot.generation;
                slot.* = .{ .generation = gen, .alive = true, .value = value };
                self.live_count += 1;
                return (@as(u64, gen) << 32) | @as(u64, idx);
            }

            /// Look up a handle. Returns null if stale or out of range.
            pub fn get(self: *Self, id: u64) ?*T {
                const idx = @as(u32, @truncate(id));
                const gen = @as(u32, @truncate(id >> 32));
                if (idx >= self.capacity) return null;
                const slot = &self.slots[idx];
                if (!slot.alive or slot.generation != gen) return null;
                return &slot.value;
            }

            /// Remove a slot. O(1). Increments generation (ABA protection).
            /// No-op if the handle is stale or out of range.
            pub fn remove(self: *Self, id: u64) void {
                const idx = @as(u32, @truncate(id));
                const gen = @as(u32, @truncate(id >> 32));
                if (idx >= self.capacity) return;
                const slot = &self.slots[idx];
                if (!slot.alive or slot.generation != gen) return;
                slot.alive = false;
                slot.generation +%= 1;
                self.free_stack[self.free_top] = idx;
                self.free_top += 1;
                self.live_count -= 1;
            }

            /// Returns the number of live (non-removed) slots.
            pub fn count(self: *const Self) i64 {
                return @intCast(self.live_count);
            }
        };
    }

    // -----------------------------------------------------------------
    // SoaList(T): Dynamic list with Structure-of-Arrays layout.
    //
    // Same API as ArrayListUnmanaged(T) but stores fields in separate
    // contiguous arrays via std.MultiArrayList.  Pipeline iteration
    // over a single field reads a cache-optimal contiguous slice.
    //
    // Usage (CLEAR: `MUTABLE items: Entity[]@list:soa = []`):
    //   var list = CheatLib.SoaList(Entity){};
    //   defer list.deinit(allocator);
    //   try list.append(allocator, Entity{ .x=1, .y=2, ... });
    //   const val: Entity = list.get(0);
    // -----------------------------------------------------------------
    pub fn SoaList(comptime T: type) type {
        return struct {
            const Self = @This();
            const MAL = std.MultiArrayList(T);

            data: MAL = .{},

            pub fn initCapacity(allocator: std.mem.Allocator, cap: usize) !Self {
                var data: MAL = .{};
                try data.setCapacity(allocator, cap);
                return Self{ .data = data };
            }

            pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
                self.data.deinit(allocator);
            }

            pub fn append(self: *Self, allocator: std.mem.Allocator, value: T) !void {
                try self.data.append(allocator, value);
            }

            pub fn get(self: *const Self, index: usize) T {
                return self.data.get(index);
            }

            pub fn set(self: *Self, index: usize, value: T) void {
                self.data.set(index, value);
            }

            pub fn length(self: *const Self) i64 {
                return @intCast(self.data.len);
            }

            pub fn count(self: *const Self) i64 {
                return @intCast(self.data.len);
            }
        };
    }

    // -----------------------------------------------------------------
    // SoaPool(T): Generational pool with Structure-of-Arrays layout.
    //
    // Same handle semantics as Pool(T), but stores fields in separate
    // arrays via std.MultiArrayList.  Iteration over a single field
    // (e.g. all .x values) reads a contiguous cache-line-friendly
    // array instead of striding over the entire struct width.
    //
    // Usage (CLEAR: `MUTABLE p: Entity[]@pool:soa = []`):
    //   var p = CheatLib.SoaPool(Entity){};
    //   defer p.deinit(allocator);
    //   const id = try p.insert(allocator, Entity{ .x=1, .y=2, ... });
    //   const val: Entity = p.get(id).?;   // returns by value (reassembled)
    //   p.remove(id);
    // -----------------------------------------------------------------
    pub fn SoaPool(comptime T: type) type {
        return struct {
            const Self = @This();
            const MAL = std.MultiArrayList(T);
            const fields = std.meta.fields(T);

            data: MAL = .{},
            generations: []u32 = &.{},
            alive: []bool = &.{},
            free_stack: []u32 = &.{},
            free_top: u32 = 0,
            capacity: u32 = 0,
            live_count: u32 = 0,

            pub fn initCapacity(allocator: std.mem.Allocator, cap: u32) !Self {
                var data: MAL = .{};
                try data.setCapacity(allocator, cap);
                // Set len to capacity so .set(idx) works for any slot.
                // Data is uninitialized but alive[] guards all reads.
                data.len = cap;
                const generations = try allocator.alloc(u32, cap);
                @memset(generations, 0);
                const alive = try allocator.alloc(bool, cap);
                @memset(alive, false);
                const free_stack = try allocator.alloc(u32, cap);
                for (0..cap) |i| free_stack[i] = @intCast(cap - 1 - i);
                return Self{
                    .data = data,
                    .generations = generations,
                    .alive = alive,
                    .free_stack = free_stack,
                    .free_top = cap,
                    .capacity = cap,
                };
            }

            pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
                self.data.deinit(allocator);
                allocator.free(self.generations);
                allocator.free(self.alive);
                allocator.free(self.free_stack);
            }

            pub fn insert(self: *Self, _: std.mem.Allocator, value: T) !u64 {
                if (self.free_top == 0) @panic("SoaPool is full");
                self.free_top -= 1;
                const idx = self.free_stack[self.free_top];
                const gen = self.generations[idx];
                self.alive[idx] = true;
                self.data.set(idx, value);
                self.live_count += 1;
                return (@as(u64, gen) << 32) | @as(u64, @intCast(idx));
            }

            pub fn get(self: *const Self, id: u64) ?T {
                const idx = @as(u32, @truncate(id));
                const gen = @as(u32, @truncate(id >> 32));
                if (idx >= self.capacity) return null;
                if (!self.alive[idx] or self.generations[idx] != gen) return null;
                return self.data.get(idx);
            }

            pub fn getFieldPtr(self: *Self, comptime field: std.meta.FieldEnum(T), id: u64) ?*std.meta.fieldInfo(T, field).type {
                const idx = @as(u32, @truncate(id));
                const gen = @as(u32, @truncate(id >> 32));
                if (idx >= self.capacity) return null;
                if (!self.alive[idx] or self.generations[idx] != gen) return null;
                const slice = self.data.items(field);
                return &slice[idx];
            }

            pub fn remove(self: *Self, id: u64) void {
                const idx = @as(u32, @truncate(id));
                const gen = @as(u32, @truncate(id >> 32));
                if (idx >= self.capacity) return;
                if (!self.alive[idx] or self.generations[idx] != gen) return;
                self.alive[idx] = false;
                self.generations[idx] +%= 1;
                self.free_stack[self.free_top] = idx;
                self.free_top += 1;
                self.live_count -= 1;
            }

            pub fn count(self: *const Self) i64 {
                return @intCast(self.live_count);
            }
        };
    }

    /// ShardedPool(T, N) — N independent Pool(T) shards behind a single insert/get/remove/count interface.
    /// Handles encode the shard index in the upper 8 bits:
    ///   [(shard_idx: u8) << 56 | (pool_handle: u56)]
    /// This allows up to 256 shards and keeps the same u64 handle type as Pool(T).
    pub fn ShardedPool(comptime T: type, comptime N: usize) type {
        comptime std.debug.assert(N >= 2); // sharding requires at least 2 shards
        return struct {
            const Self = @This();
            const SHARD_SHIFT: u6 = 56;
            const HANDLE_MASK: u64 = (1 << 56) - 1;

            shards: [N]Pool(T) = [_]Pool(T){.{}} ** N,
            round_robin: usize = 0,

            pub fn initCapacity(allocator: std.mem.Allocator, total_cap: u32) !Self {
                const per_shard: u32 = @intCast(total_cap / N);
                var self = Self{ .shards = undefined };
                for (&self.shards) |*s| {
                    s.* = try Pool(T).initCapacity(allocator, per_shard);
                }
                return self;
            }

            pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
                for (&self.shards) |*s| s.deinit(allocator);
            }

            /// Insert into the next shard (round-robin). Returns a handle encoding shard index.
            pub fn insert(self: *Self, allocator: std.mem.Allocator, value: T) !u64 {
                const shard_idx = self.round_robin % N;
                self.round_robin +%= 1;
                const local_handle = try self.shards[shard_idx].insert(allocator, value);
                return (@as(u64, shard_idx) << SHARD_SHIFT) | (local_handle & HANDLE_MASK);
            }

            /// Look up a handle. Returns null if stale, out of range, or wrong shard.
            pub fn get(self: *Self, id: u64) ?*T {
                const shard_idx = @as(usize, @intCast(id >> SHARD_SHIFT));
                if (shard_idx >= N) return null;
                const local_handle = id & HANDLE_MASK;
                return self.shards[shard_idx].get(local_handle);
            }

            /// Remove by handle. No-op if stale or out of range.
            pub fn remove(self: *Self, id: u64) void {
                const shard_idx = @as(usize, @intCast(id >> SHARD_SHIFT));
                if (shard_idx >= N) return;
                const local_handle = id & HANDLE_MASK;
                self.shards[shard_idx].remove(local_handle);
            }

            /// Returns the total number of live slots across all shards.
            pub fn count(self: *const Self) i64 {
                var n: i64 = 0;
                for (&self.shards) |*s| n += s.count();
                return n;
            }
        };
    }

    /// ShardedList(T, N) — N independent ArrayListUnmanaged(T) shards.
    /// Provides the same append/len interface as a single list but distributed across N shards.
    pub fn ShardedList(comptime T: type, comptime N: usize) type {
        comptime std.debug.assert(N >= 2);
        return struct {
            const Self = @This();

            shards: [N]std.ArrayListUnmanaged(T) = [_]std.ArrayListUnmanaged(T){.{}} ** N,
            round_robin: usize = 0,

            pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
                for (&self.shards) |*s| s.deinit(allocator);
            }

            /// Append to the next shard (round-robin).
            pub fn append(self: *Self, allocator: std.mem.Allocator, value: T) !void {
                const shard_idx = self.round_robin % N;
                self.round_robin +%= 1;
                try self.shards[shard_idx].append(allocator, value);
            }

            /// Returns the total number of items across all shards.
            pub fn len(self: *const Self) usize {
                var n: usize = 0;
                for (&self.shards) |*s| n += s.items.len;
                return n;
            }
        };
    }

    // -----------------------------------------------------------------------
    // Set(T) — hash set of unique values.
    // Backed by StringHashMapUnmanaged(void) for strings,
    // AutoHashMapUnmanaged(T, void) for other types.
    // -----------------------------------------------------------------------
    pub fn Set(comptime T: type) type {
        const is_string = T == []const u8;
        const Map = if (is_string) std.StringHashMapUnmanaged(void) else std.AutoHashMapUnmanaged(T, void);
        return struct {
            const Self = @This();
            inner: Map = .{},

            pub fn insert(self: *Self, alloc: std.mem.Allocator, value: T) !void {
                if (is_string) {
                    if (!self.inner.contains(value)) {
                        const owned = try alloc.dupe(u8, value);
                        errdefer alloc.free(owned);
                        try self.inner.put(alloc, owned, {});
                    }
                } else {
                    try self.inner.put(alloc, value, {});
                }
            }

            pub fn contains(self: *Self, value: T) bool {
                return self.inner.contains(value);
            }

            pub fn remove(self: *Self, alloc: std.mem.Allocator, value: T) void {
                if (is_string) {
                    if (self.inner.fetchRemove(value)) |kv| alloc.free(kv.key);
                } else {
                    _ = self.inner.fetchRemove(value);
                }
            }

            pub fn count(self: *Self) i64 {
                return @intCast(self.inner.count());
            }

            pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
                if (is_string) {
                    var it = self.inner.keyIterator();
                    while (it.next()) |key_ptr| alloc.free(key_ptr.*);
                }
                self.inner.deinit(alloc);
            }
        };
    }

    // -----------------------------------------------------------------------
    // PartitionedStringMap(V, N) — true shared-nothing string hash map.
    //
    // N independent shards with cache-line padding.  Each shard is owned
    // by scheduler (shard_index % num_schedulers).
    //
    // HOT PATH (shard owned by current scheduler):
    //   Direct access — zero locks, zero atomics.  Cooperative scheduling
    //   ensures only one fiber runs at a time per scheduler.
    //
    // COLD PATH (shard owned by another scheduler):
    //   Transparently routed via the scheduler inbox.  The calling fiber
    //   parks (WaitGroup), the owning scheduler executes the operation
    //   inline in drainInbox, then signals completion.  The caller's
    //   WaitGroup and context live on the fiber stack — safe because
    //   drainInbox captures all fields into OS-thread locals before
    //   calling func(), and calls wg.done() after func() returns.
    //
    // Emitted for @sharded(N) without :locked/:writeLocked.
    pub fn PartitionedStringMap(comptime V: type, comptime N: usize) type {
        comptime std.debug.assert(N >= 2);
        return struct {
            const Self = @This();
            const Map = std.StringHashMapUnmanaged(V);
            // Thread-safe allocator for cold-path key/bucket allocations.
            const remote_alloc = std.heap.c_allocator;

            const Shard = struct {
                map: Map = .{},
                _pad: [56]u8 = undefined, // cache-line padding
            };

            shards: [N]Shard = [_]Shard{.{}} ** N,
            owners: [N]?*fp.Scheduler = [_]?*fp.Scheduler{null} ** N,
            ownership_init: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

            pub fn shardIndex(key: []const u8) usize {
                return @as(usize, std.hash_map.hashString(key)) % N;
            }

            pub fn shardIndexWithHash(key: []const u8) struct { shard: usize, hash: u64 } {
                const h = std.hash_map.hashString(key);
                return .{ .shard = @as(usize, h) % N, .hash = h };
            }

            /// Initialize shard-to-scheduler ownership mapping.
            /// CO-LOCATION GUARANTEE: All PartitionedStringMap(V, N) instances with the
            /// same N get the same owners[] mapping (deterministic: owners[i] = scheds[i % sc]).
            /// This means two @sharded(8) maps accessed with the same key will always route
            /// to the same scheduler — zero cross-shard overhead for co-located access.
            pub fn ensureOwnership(self: *Self) void {
                if (self.ownership_init.load(.acquire) == 2) return;
                if (self.ownership_init.cmpxchgStrong(0, 1, .acquire, .monotonic)) |_| {
                    while (self.ownership_init.load(.acquire) != 2)
                        std.Thread.yield() catch {};
                    return;
                }
                var scheds: [64]?*fp.Scheduler = [_]?*fp.Scheduler{null} ** 64;
                var sc: u32 = 0;
                const n = fp.global_registry.len.load(.acquire);
                for (fp.global_registry.slots[0..n]) |*slot| {
                    if (slot.load(.acquire)) |s| { scheds[sc] = s; sc += 1; }
                }
                if (sc == 0) { scheds[0] = fp.active_scheduler; sc = 1; }
                for (0..N) |i| self.owners[i] = scheds[i % sc];
                self.ownership_init.store(2, .release);
            }

            // Operation context structs — stack-allocated on calling fiber.
            // The `done` atomic flag is set by the target scheduler after
            // completing the operation. The caller drains channels + yields
            // while waiting, preventing deadlock.
            const is_slice_value = @typeInfo(V) == .pointer and @typeInfo(V).pointer.size == .slice;

            const PutCtx = struct {
                map: *Self, shard: usize,
                key: []const u8, value: V,
                err: bool = false,
                done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
                fn run(raw: *anyopaque) void {
                    const c: *@This() = @ptrCast(@alignCast(raw));
                    // For slice values (e.g. []const u8), dupe the value too --
                    // the original may point to the caller's stack.
                    const safe_val = if (comptime is_slice_value)
                        remote_alloc.dupe(@typeInfo(V).pointer.child, c.value) catch {
                            remote_alloc.free(c.key); c.err = true;
                            c.done.store(true, .release);
                            return;
                        }
                    else
                        c.value;
                    const gop = c.map.shards[c.shard].map.getOrPut(remote_alloc, c.key) catch {
                        remote_alloc.free(c.key);
                        if (comptime is_slice_value) remote_alloc.free(safe_val);
                        c.err = true;
                        c.done.store(true, .release);
                        return;
                    };
                    if (gop.found_existing) {
                        // Cleanup old value before overwriting.
                        if (comptime needsCleanup(V)) cleanup(V, remote_alloc, gop.value_ptr);
                        remote_alloc.free(gop.key_ptr.*);
                        gop.key_ptr.* = c.key;
                    } else {
                        gop.key_ptr.* = c.key;
                    }
                    gop.value_ptr.* = safe_val;
                    c.done.store(true, .release);
                }
            };
            const GetCtx = struct {
                map: *Self, shard: usize, key: []const u8, result: ?V = null,
                done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
                fn run(raw: *anyopaque) void {
                    const c: *@This() = @ptrCast(@alignCast(raw));
                    c.result = c.map.shards[c.shard].map.get(c.key);
                    c.done.store(true, .release);
                }
            };
            const RemoveCtx = struct {
                map: *Self, shard: usize, key: []const u8,
                done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
                fn run(raw: *anyopaque) void {
                    const c: *@This() = @ptrCast(@alignCast(raw));
                    if (c.map.shards[c.shard].map.fetchRemove(c.key)) |kv| {
                        remote_alloc.free(kv.key);
                        var val = kv.value;
                        CheatLib.cleanup(V, remote_alloc, &val);
                    }
                    c.done.store(true, .release);
                }
            };

            // Send a RemoteCall via SPSC and wait for completion.
            // Drains our own channels + yields fiber while waiting.
            fn sendAndWait(target: *fp.Scheduler, func_ptr: *const fn (*anyopaque) void, ctx_ptr: *anyopaque, done_flag: *std.atomic.Value(bool)) void {
                if (target == fp.active_scheduler) {
                    // LOCAL: target is our own scheduler — call directly, no SPSC.
                    // This avoids context-switch overhead for self-sends and keeps
                    // the stack shallow (no drainChannels in the call chain).
                    func_ptr(ctx_ptr);
                    return;
                }
                // REMOTE: send via SPSC channel, spin on done flag.
                // No fiber yield — spin is ~10ns per iteration, vastly cheaper
                // than a context switch (~1μs). The remote scheduler processes
                // the message in its own drainChannels loop independently.
                const sender_idx = fp.active_scheduler.index;
                std.debug.assert(sender_idx < target.channels.len);
                // Lazily allocate channel ring on first use
                if (target.channels[sender_idx] == null) {
                    target.channels[sender_idx] = target.allocator.create(
                        @import("spsc.zig").DefaultRing
                    ) catch @panic("SPSC channel alloc failed");
                    target.channels[sender_idx].?.* = .{};
                }
                const ring = target.channels[sender_idx].?;
                const msg = fp.SpscMessage{
                    .tag = .RemoteCall,
                    .rc_func = @ptrCast(func_ptr),
                    .rc_ctx = ctx_ptr,
                };
                while (!ring.push(msg)) {
                    std.atomic.spinLoopHint();
                }
                _ = target.dirty_mask.fetchOr(@as(u64, 1) << @intCast(sender_idx), .seq_cst);
                target.event_fd.notify();
                // Spin-then-yield for remote completion.  Spin first with
                // PAUSE (spinLoopHint) which is critical for cross-core
                // visibility.  Fall back to yield so the scheduler can drain
                // channels — without yield, two fibers on different schedulers
                // can deadlock when each spin-waits for the other's shard.
                //
                // Pin the task during yield to prevent work-stealing.  A stolen
                // task would land on the shard owner's scheduler, where it takes
                // the LOCAL path on next access — racing with the still-pending
                // RemoteCall being processed by drainChannels on the same thread.
                const task = fp.active_scheduler.getCurrent();
                const was_pinned = task.config.pinned;
                task.config.pinned = true;
                var _sw_spins: u32 = 0;
                while (!done_flag.load(.acquire)) {
                    std.atomic.spinLoopHint();
                    _sw_spins += 1;
                    if (_sw_spins >= 8192) {
                        _sw_spins = 0;
                        task.status.store(.Ready, .release);
                        task.base.yield();
                    }
                }
                task.config.pinned = was_pinned;
            }

            // ONE path for every operation. No hot/cold split.
            // Always routes through the owning scheduler via SPSC.

            pub fn put(self: *Self, _: std.mem.Allocator, caller_alloc: std.mem.Allocator, key: []const u8, value: V) !void {
                self.ensureOwnership();
                const s = shardIndex(key);
                const safe_key = try remote_alloc.dupe(u8, key);
                var ctx = PutCtx{ .map = self, .shard = s, .key = safe_key, .value = value };
                sendAndWait(self.owners[s].?, @ptrCast(&PutCtx.run), @ptrCast(&ctx), &ctx.done);
                if (ctx.err) return error.OutOfMemory;
                // PutCtx.run dupes slice values with remote_alloc for thread safety.
                // Free the caller's copy since ownership has been transferred.
                if (comptime is_slice_value) caller_alloc.free(value);
            }

            pub fn get(self: *Self, key: []const u8) ?V {
                self.ensureOwnership();
                const s = shardIndex(key);
                const safe_key = remote_alloc.dupe(u8, key) catch return null;
                var ctx = GetCtx{ .map = self, .shard = s, .key = safe_key };
                sendAndWait(self.owners[s].?, @ptrCast(&GetCtx.run), @ptrCast(&ctx), &ctx.done);
                remote_alloc.free(safe_key);
                return ctx.result;
            }

            pub fn contains(self: *Self, key: []const u8) bool {
                self.ensureOwnership();
                const s = shardIndex(key);
                const safe_key = remote_alloc.dupe(u8, key) catch return false;
                var ctx = GetCtx{ .map = self, .shard = s, .key = safe_key };
                sendAndWait(self.owners[s].?, @ptrCast(&GetCtx.run), @ptrCast(&ctx), &ctx.done);
                remote_alloc.free(safe_key);
                return ctx.result != null;
            }

            pub fn remove(self: *Self, _: std.mem.Allocator, key: []const u8) void {
                self.ensureOwnership();
                const s = shardIndex(key);
                const safe_key = remote_alloc.dupe(u8, key) catch return;
                var ctx = RemoveCtx{ .map = self, .shard = s, .key = safe_key };
                sendAndWait(self.owners[s].?, @ptrCast(&RemoveCtx.run), @ptrCast(&ctx), &ctx.done);
                remote_alloc.free(safe_key);
            }

            // ── Direct shard access (no hash, no routing) ──
            // Used by the SHARD pipeline: the fiber is already pinned to the
            // owning scheduler, and the shard index is known from routing.
            // Zero overhead: no shardIndex(), no sendAndWait(), no key dupe.

            pub fn putDirect(self: *Self, shard: usize, alloc: std.mem.Allocator, key: []const u8, value: V) !void {
                const gop = try self.shards[shard].map.getOrPut(alloc, key);
                if (gop.found_existing) {
                    CheatLib.cleanup(V, alloc, gop.value_ptr);
                } else {
                    gop.key_ptr.* = try alloc.dupe(u8, key);
                }
                gop.value_ptr.* = if (comptime is_slice_value)
                    try alloc.dupe(@typeInfo(V).pointer.child, value)
                else
                    value;
            }

            /// Insert using a pre-computed hash. The hash MUST have been computed
            /// by shardIndexWithHash (Wyhash) — the same function StringHashMap uses.
            /// Skips rehashing the key, saving ~50% of hash work in SHARD pipelines.
            pub fn putPrehashed(self: *Self, shard: usize, precomputed_hash: u64, alloc: std.mem.Allocator, key: []const u8, value: V) !void {
                const owned_key = try alloc.dupe(u8, key);
                const safe_val = if (comptime is_slice_value)
                    try alloc.dupe(@typeInfo(V).pointer.child, value)
                else
                    value;
                const PrehashedCtx = struct {
                    h: u64,
                    pub fn hash(self_ctx: @This(), _: []const u8) u64 { return self_ctx.h; }
                    pub fn eql(_: @This(), a: []const u8, b: []const u8) bool { return std.mem.eql(u8, a, b); }
                };
                const gop = self.shards[shard].map.getOrPutAdapted(alloc, owned_key, PrehashedCtx{ .h = precomputed_hash }) catch |e| {
                    alloc.free(owned_key);
                    if (comptime is_slice_value) alloc.free(safe_val);
                    return e;
                };
                if (gop.found_existing) {
                    alloc.free(owned_key);
                    if (comptime is_slice_value) {
                        const old = gop.value_ptr.*;
                        alloc.free(old);
                    }
                } else {
                    gop.key_ptr.* = owned_key;
                }
                gop.value_ptr.* = safe_val;
            }

            pub fn getDirect(self: *Self, shard: usize, key: []const u8) ?V {
                return self.shards[shard].map.get(key);
            }

            pub fn containsDirect(self: *Self, shard: usize, key: []const u8) bool {
                return self.shards[shard].map.contains(key);
            }

            pub fn removeDirect(self: *Self, shard: usize, alloc: std.mem.Allocator, key: []const u8) void {
                if (self.shards[shard].map.fetchRemove(key)) |kv| {
                    alloc.free(kv.key);
                    if (is_slice_value) alloc.free(kv.value);
                }
            }

            pub fn count(self: *Self) i64 {
                var nc: i64 = 0;
                for (&self.shards) |*shard| nc += @intCast(shard.map.count());
                return nc;
            }

            pub fn keys(self: *Self, alloc: std.mem.Allocator) !std.ArrayListUnmanaged([]const u8) {
                var list = std.ArrayListUnmanaged([]const u8){};
                for (&self.shards) |*shard| {
                    var it = shard.map.keyIterator();
                    while (it.next()) |k| try list.append(alloc, k.*);
                }
                return list;
            }

            pub fn values(self: *Self, alloc: std.mem.Allocator) !std.ArrayListUnmanaged(V) {
                var list = std.ArrayListUnmanaged(V){};
                for (&self.shards) |*shard| {
                    var it = shard.map.valueIterator();
                    while (it.next()) |v| try list.append(alloc, v.*);
                }
                return list;
            }

            pub fn deinit(self: *Self, _: std.mem.Allocator, _: std.mem.Allocator) void {
                for (&self.shards) |*shard| {
                    var it = shard.map.iterator();
                    while (it.next()) |entry| {
                        remote_alloc.free(entry.key_ptr.*);
                        CheatLib.cleanup(V, remote_alloc, entry.value_ptr);
                    }
                    shard.map.deinit(remote_alloc);
                }
            }

            pub fn getOpCounts(self: *const Self) [N]u64 {
                _ = self;
                return [_]u64{0} ** N;
            }
        };
    }

    // ShardedStringMap(V, N) — RwLock-sharded string hash map.
    // N independent shards, each protected by a RwLock. Readers are concurrent
    // within a shard; writers are exclusive per-shard. Thread-safe for @parallel.
    // Emitted for @sharded(N):locked and @sharded(N):writeLocked.
    pub fn ShardedStringMap(comptime V: type, comptime N: usize) type {
        comptime std.debug.assert(N >= 2);
        return struct {
            const Self = @This();
            const Map = std.StringHashMapUnmanaged(V);

            const Shard = struct {
                map: Map = .{},
                lock: std.Thread.RwLock = .{},
                ops: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
            };

            shards: [N]Shard = [_]Shard{.{}} ** N,
            alloc: std.mem.Allocator = std.heap.page_allocator,

            fn shardIndex(key: []const u8) usize {
                return @as(usize, std.hash.Fnv1a_64.hash(key)) % N;
            }

            pub fn put(self: *Self, key_alloc: std.mem.Allocator, bucket_alloc: std.mem.Allocator, key: []const u8, value: V) !void {
                _ = key_alloc;
                _ = bucket_alloc;
                const s = shardIndex(key);
                self.shards[s].lock.lock();
                defer self.shards[s].lock.unlock();
                if (self.shards[s].map.getPtr(key)) |val_ptr| {
                    CheatLib.cleanup(V, self.alloc, val_ptr);
                    val_ptr.* = value;
                    return;
                }
                const owned_key = try self.alloc.dupe(u8, key);
                try self.shards[s].map.put(self.alloc, owned_key, value);
            }

            pub fn get(self: *Self, key: []const u8) ?V {
                const s = shardIndex(key);
                self.shards[s].lock.lockShared();
                defer self.shards[s].lock.unlockShared();
                return self.shards[s].map.get(key);
            }

            pub fn contains(self: *Self, key: []const u8) bool {
                const s = shardIndex(key);
                self.shards[s].lock.lockShared();
                defer self.shards[s].lock.unlockShared();
                return self.shards[s].map.contains(key);
            }

            pub fn remove(self: *Self, key_alloc: std.mem.Allocator, key: []const u8) void {
                _ = key_alloc;
                const s = shardIndex(key);
                self.shards[s].lock.lock();
                defer self.shards[s].lock.unlock();
                if (self.shards[s].map.fetchRemove(key)) |kv| {
                    self.alloc.free(kv.key);
                    var val = kv.value;
                    CheatLib.cleanup(V, self.alloc, &val);
                }
            }

            pub fn count(self: *Self) i64 {
                var n: i64 = 0;
                for (&self.shards) |*shard| {
                    shard.lock.lockShared();
                    defer shard.lock.unlockShared();
                    n += @intCast(shard.map.count());
                }
                return n;
            }

            pub fn keys(self: *Self, alloc: std.mem.Allocator) !std.ArrayListUnmanaged([]const u8) {
                var list = std.ArrayListUnmanaged([]const u8){};
                for (&self.shards) |*shard| {
                    shard.lock.lockShared();
                    defer shard.lock.unlockShared();
                    var it = shard.map.keyIterator();
                    while (it.next()) |k| try list.append(alloc, k.*);
                }
                return list;
            }

            pub fn values(self: *Self, alloc: std.mem.Allocator) !std.ArrayListUnmanaged(V) {
                var list = std.ArrayListUnmanaged(V){};
                for (&self.shards) |*shard| {
                    shard.lock.lockShared();
                    defer shard.lock.unlockShared();
                    var it = shard.map.valueIterator();
                    while (it.next()) |v| try list.append(alloc, v.*);
                }
                return list;
            }

            pub fn deinit(self: *Self, key_alloc: std.mem.Allocator, bucket_alloc: std.mem.Allocator) void {
                _ = key_alloc;
                _ = bucket_alloc;
                for (&self.shards) |*shard| {
                    var it = shard.map.iterator();
                    while (it.next()) |entry| {
                        self.alloc.free(entry.key_ptr.*);
                        CheatLib.cleanup(V, self.alloc, entry.value_ptr);
                    }
                    shard.map.deinit(self.alloc);
                }
            }

            pub fn getOpCounts(self: *const Self) [N]u64 {
                var counts: [N]u64 = undefined;
                for (self.shards, 0..) |shard, i| {
                    counts[i] = shard.ops.load(.monotonic);
                }
                return counts;
            }
        };
    }

    // MutexShardedStringMap: report contention stats to stderr on deinit.
    // This is temporary instrumentation for performance debugging.

    // MutexShardedStringMap(V, N) — Mutex-sharded string hash map.
    // Like ShardedStringMap but uses Mutex (exclusive) instead of RwLock.
    // Simpler locking, lower per-op overhead, but readers block each other.
    // Emitted for @sharded(N):locked.
    pub fn MutexShardedStringMap(comptime V: type, comptime N: usize) type {
        comptime std.debug.assert(N >= 2);
        return struct {
            const Self = @This();
            const Map = std.StringHashMapUnmanaged(V);

            const Shard = struct {
                map: Map = .{},
                lock: std.Thread.Mutex = .{},
                contention_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
                lock_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
            };

            shards: [N]Shard = [_]Shard{.{}} ** N,
            alloc: std.mem.Allocator = std.heap.page_allocator,

            fn shardIndex(key: []const u8) usize {
                return @as(usize, std.hash.Fnv1a_64.hash(key)) % N;
            }

            inline fn instrumentedLock(shard: *Shard) void {
                _ = shard.lock_count.fetchAdd(1, .monotonic);
                if (!shard.lock.tryLock()) {
                    _ = shard.contention_count.fetchAdd(1, .monotonic);
                    shard.lock.lock();
                }
            }

            pub fn getContentionStats(self: *Self) struct { total_locks: u64, total_contentions: u64, hot_shard_locks: u64, hot_shard_contentions: u64, hot_shard_idx: usize } {
                var total_locks: u64 = 0;
                var total_contentions: u64 = 0;
                var hot_shard_locks: u64 = 0;
                var hot_shard_contentions: u64 = 0;
                var hot_shard_idx: usize = 0;
                for (&self.shards, 0..) |*shard, i| {
                    const lc = shard.lock_count.load(.monotonic);
                    const cc = shard.contention_count.load(.monotonic);
                    total_locks += lc;
                    total_contentions += cc;
                    if (lc > hot_shard_locks) {
                        hot_shard_locks = lc;
                        hot_shard_contentions = cc;
                        hot_shard_idx = i;
                    }
                }
                return .{ .total_locks = total_locks, .total_contentions = total_contentions, .hot_shard_locks = hot_shard_locks, .hot_shard_contentions = hot_shard_contentions, .hot_shard_idx = hot_shard_idx };
            }

            pub fn printShardDistribution(self: *Self) void {
                // Print top 5 shards by lock count
                var top_idx: [5]usize = .{0} ** 5;
                var top_cnt: [5]u64 = .{0} ** 5;
                for (&self.shards, 0..) |*shard, i| {
                    const lc = shard.lock_count.load(.monotonic);
                    for (0..5) |j| {
                        if (lc > top_cnt[j]) {
                            // Shift down
                            var k: usize = 4;
                            while (k > j) : (k -= 1) {
                                top_idx[k] = top_idx[k - 1];
                                top_cnt[k] = top_cnt[k - 1];
                            }
                            top_idx[j] = i;
                            top_cnt[j] = lc;
                            break;
                        }
                    }
                }
                std.debug.print("[top shards] ", .{});
                for (0..5) |j| {
                    if (top_cnt[j] > 0) std.debug.print("[{d}]={d} ", .{ top_idx[j], top_cnt[j] });
                }
                std.debug.print("\n", .{});
            }

            pub fn put(self: *Self, key_alloc: std.mem.Allocator, bucket_alloc: std.mem.Allocator, key: []const u8, value: V) !void {
                _ = key_alloc;
                _ = bucket_alloc;
                const s = shardIndex(key);
                instrumentedLock(&self.shards[s]);
                defer self.shards[s].lock.unlock();
                // Update in-place if key exists (avoids key re-dupe and leak).
                if (self.shards[s].map.getPtr(key)) |val_ptr| {
                    CheatLib.cleanup(V, self.alloc, val_ptr);
                    val_ptr.* = value;
                    return;
                }
                const owned_key = try self.alloc.dupe(u8, key);
                try self.shards[s].map.put(self.alloc, owned_key, value);
            }

            pub fn get(self: *Self, key: []const u8) ?V {
                const s = shardIndex(key);
                instrumentedLock(&self.shards[s]);
                defer self.shards[s].lock.unlock();
                return self.shards[s].map.get(key);
            }

            pub fn contains(self: *Self, key: []const u8) bool {
                const s = shardIndex(key);
                self.shards[s].lock.lock();
                defer self.shards[s].lock.unlock();
                return self.shards[s].map.contains(key);
            }

            pub fn remove(self: *Self, key_alloc: std.mem.Allocator, key: []const u8) void {
                _ = key_alloc;
                const s = shardIndex(key);
                self.shards[s].lock.lock();
                defer self.shards[s].lock.unlock();
                if (self.shards[s].map.fetchRemove(key)) |kv| {
                    self.alloc.free(kv.key);
                    var val = kv.value;
                    CheatLib.cleanup(V, self.alloc, &val);
                }
            }

            pub fn count(self: *Self) i64 {
                var n: i64 = 0;
                for (&self.shards) |*shard| {
                    shard.lock.lock();
                    defer shard.lock.unlock();
                    n += @intCast(shard.map.count());
                }
                return n;
            }

            pub fn keys(self: *Self, alloc: std.mem.Allocator) !std.ArrayListUnmanaged([]const u8) {
                var list = std.ArrayListUnmanaged([]const u8){};
                for (&self.shards) |*shard| {
                    shard.lock.lock();
                    defer shard.lock.unlock();
                    var it = shard.map.keyIterator();
                    while (it.next()) |k| try list.append(alloc, k.*);
                }
                return list;
            }

            pub fn values(self: *Self, alloc: std.mem.Allocator) !std.ArrayListUnmanaged(V) {
                var list = std.ArrayListUnmanaged(V){};
                for (&self.shards) |*shard| {
                    shard.lock.lock();
                    defer shard.lock.unlock();
                    var it = shard.map.valueIterator();
                    while (it.next()) |v| try list.append(alloc, v.*);
                }
                return list;
            }

            pub fn deinit(self: *Self, key_alloc: std.mem.Allocator, bucket_alloc: std.mem.Allocator) void {
                _ = key_alloc;
                _ = bucket_alloc;
                // Report contention stats
                const stats = self.getContentionStats();
                if (stats.total_locks > 0) {
                    const pct = if (stats.total_locks > 0) (stats.total_contentions * 100) / stats.total_locks else 0;
                    const hot_pct = if (stats.hot_shard_locks > 0) (stats.hot_shard_contentions * 100) / stats.hot_shard_locks else 0;
                    std.debug.print("[contention] locks={d} contentions={d} ({d}%) hot_shard[{d}]: locks={d} contentions={d} ({d}%)\n", .{
                        stats.total_locks, stats.total_contentions, pct,
                        stats.hot_shard_idx,
                        stats.hot_shard_locks, stats.hot_shard_contentions, hot_pct,
                    });
                    self.printShardDistribution();
                }
                for (&self.shards) |*shard| {
                    var it = shard.map.iterator();
                    while (it.next()) |entry| {
                        self.alloc.free(entry.key_ptr.*);
                        CheatLib.cleanup(V, self.alloc, entry.value_ptr);
                    }
                    shard.map.deinit(self.alloc);
                }
            }
        };
    }

    // StripedStringMap — alias for ShardedStringMap (backward compat / RwLock).
    pub fn StripedStringMap(comptime V: type, comptime N: usize) type {
        return ShardedStringMap(V, N);
    }

    // -----------------------------------------------------------------------
    // ShardedNumericMap(K, V, N) — Unified sharded numeric hash map.
    // Same lock-elision design as ShardedStringMap.
    // -----------------------------------------------------------------------
    pub fn ShardedNumericMap(comptime K: type, comptime V: type, comptime N: usize) type {
        comptime std.debug.assert(N >= 2);
        return struct {
            const Self = @This();
            const Map = NumericMapType(K, V);

            const Shard = struct {
                map: Map = .{},
                lock: std.Thread.Mutex = .{},
            };

            shards: [N]Shard = [_]Shard{.{}} ** N,
            locks_elided: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

            fn shardIndex(key: K) usize {
                const bits: u64 = if (@typeInfo(K) == .float)
                    @bitCast(@as(f64, key))
                else
                    @as(u64, @intCast(key));
                return @as(usize, @truncate(bits)) % N;
            }

            inline fn acquire(shard: *Shard, elided: bool) void {
                if (!elided) shard.lock.lock();
            }

            inline fn release(shard: *Shard, elided: bool) void {
                if (!elided) shard.lock.unlock();
            }

            pub fn put(self: *Self, alloc: std.mem.Allocator, key: K, value: V) !void {
                const s = shardIndex(key);
                const elided = self.locks_elided.load(.monotonic);
                acquire(&self.shards[s], elided);
                defer release(&self.shards[s], elided);
                const gop = try self.shards[s].map.getOrPut(alloc, key);
                if (gop.found_existing) {
                    if (comptime needsCleanup(V)) cleanup(V, alloc, gop.value_ptr);
                }
                gop.value_ptr.* = value;
            }

            pub fn get(self: *Self, key: K) ?V {
                const s = shardIndex(key);
                const elided = self.locks_elided.load(.monotonic);
                acquire(&self.shards[s], elided);
                defer release(&self.shards[s], elided);
                return self.shards[s].map.get(key);
            }

            pub fn contains(self: *Self, key: K) bool {
                const s = shardIndex(key);
                const elided = self.locks_elided.load(.monotonic);
                acquire(&self.shards[s], elided);
                defer release(&self.shards[s], elided);
                return self.shards[s].map.contains(key);
            }

            pub fn remove(self: *Self, alloc: std.mem.Allocator, key: K) void {
                const s = shardIndex(key);
                const elided = self.locks_elided.load(.monotonic);
                acquire(&self.shards[s], elided);
                defer release(&self.shards[s], elided);
                if (self.shards[s].map.fetchRemove(key)) |kv| {
                    if (comptime needsCleanup(V)) {
                        var val = kv.value;
                        cleanup(V, alloc, &val);
                    }
                }
            }

            pub fn count(self: *Self) i64 {
                var n: i64 = 0;
                const elided = self.locks_elided.load(.monotonic);
                for (&self.shards) |*shard| {
                    acquire(shard, elided);
                    defer release(shard, elided);
                    n += @intCast(shard.map.count());
                }
                return n;
            }

            pub fn deinit(self: *Self, key_alloc: std.mem.Allocator, bucket_alloc: std.mem.Allocator) void {
                for (&self.shards) |*shard| {
                    if (comptime needsCleanup(V)) {
                        var vit = shard.map.valueIterator();
                        while (vit.next()) |val_ptr| cleanup(V, bucket_alloc, val_ptr);
                    }
                    // Free duped key strings before releasing bucket array.
                    var it = shard.map.keyIterator();
                    while (it.next()) |k| key_alloc.free(k.*);
                    shard.map.deinit(bucket_alloc);
                }
            }

            pub fn getOpCounts(self: *const Self) [N]u64 {
                _ = self;
                return [_]u64{0} ** N;
            }

            pub fn enableLocks(self: *Self) void {
                self.locks_elided.store(false, .release);
            }
        };
    }

    // StripedNumericMap wraps ShardedNumericMap with locks NOT elided.
    pub fn StripedNumericMap(comptime K: type, comptime V: type, comptime N: usize) type {
        const Base = ShardedNumericMap(K, V, N);
        return struct {
            const Self = @This();
            inner: Base = .{ .locks_elided = std.atomic.Value(bool).init(false) },

            pub fn put(self: *Self, a: std.mem.Allocator, k: K, v: V) !void { return self.inner.put(a, k, v); }
            pub fn get(self: *Self, k: K) ?V { return self.inner.get(k); }
            pub fn contains(self: *Self, k: K) bool { return self.inner.contains(k); }
            pub fn remove(self: *Self, a: std.mem.Allocator, k: K) void { self.inner.remove(a, k); }
            pub fn count(self: *Self) i64 { return self.inner.count(); }
            pub fn deinit(self: *Self, a: std.mem.Allocator) void { self.inner.deinit(a); }
            pub fn getOpCounts(self: *const Self) [N]u64 { return self.inner.getOpCounts(); }
            pub fn enableLocks(self: *Self) void { self.inner.enableLocks(); }
        };
    }

    pub fn ffi(rt: *Runtime, comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
        const F = @TypeOf(f);
        const type_info = @typeInfo(F);
        const ReturnType = type_info.@"fn".return_type.?;

        // Create a Function POINTER type based on the function's signature.
        // This is the key: we need the pointer type, not the function type.
        const PtrType = *const F;

        const Frame = struct {
            args: @TypeOf(args),
            ret: ReturnType,
            func_ptr: PtrType,
        };

        var frame = Frame{
            .args = args,
            .ret = undefined,
            .func_ptr = &f, // Take the address of the function constant
        };

        rt.onRootStack(struct {
            fn wrapper(ptr: ?*anyopaque) callconv(.c) void {
                const wrapped: *Frame = @ptrCast(@alignCast(ptr));
                // We call through the pointer stored in the frame.
                // Since func_ptr is a PtrType (*const fn...), this is a valid runtime call.
                wrapped.ret = @call(.auto, wrapped.func_ptr, wrapped.args);
            }
        }.wrapper, &frame);

        return frame.ret;
    }

    // =====================================================================
    // Benchmark / Profile / Smash Infrastructure
    // =====================================================================

    pub const BenchmarkResult = struct {
        iterations: u64,
        total_ns: u64,
        min_ns: u64,
        max_ns: u64,
        avg_ns: u64,
        p50_ns: u64,
        p99_ns: u64,
        alloc_count: u64,
        alloc_bytes: u64,
        arena_high_water: usize,
    };

    /// Run a function N times, measuring wall-clock time, allocations, and arena usage.
    pub fn benchmark(
        comptime func: anytype,
        rt: *Runtime,
        args: anytype,
        iterations: u64,
    ) BenchmarkResult {
        const alloc_profile = @import("alloc-profile.zig");
        const timer = std.time.Timer;

        const max_samples = @min(iterations, 10_000);
        var samples: [10_000]u64 = undefined;
        var sample_count: u64 = 0;

        const alloc_before = alloc_profile.totalAllocs();
        const bytes_before = alloc_profile.totalBytes();

        var total_ns: u64 = 0;
        var min_ns: u64 = std.math.maxInt(u64);
        var max_ns: u64 = 0;
        var arena_hw: usize = 0;

        var i: u64 = 0;
        while (i < iterations) : (i += 1) {
            const mark = rt.saveFrameMark();
            var t = timer.start() catch continue;

            const ResultType = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
            if (@typeInfo(ResultType) == .error_union) {
                _ = @call(.auto, func, .{rt} ++ args) catch {};
            } else {
                _ = @call(.auto, func, .{rt} ++ args);
            }
            const elapsed = t.read();

            const cursor = rt.overflow_arena.cursor;
            if (cursor > arena_hw) arena_hw = cursor;
            rt.restoreFrameMark(mark);

            total_ns += elapsed;
            if (elapsed < min_ns) min_ns = elapsed;
            if (elapsed > max_ns) max_ns = elapsed;
            if (sample_count < max_samples) {
                samples[sample_count] = elapsed;
                sample_count += 1;
            }
        }

        const alloc_after = alloc_profile.totalAllocs();
        const bytes_after = alloc_profile.totalBytes();

        if (sample_count > 0) {
            std.mem.sort(u64, samples[0..sample_count], {}, std.sort.asc(u64));
        }
        const p50_idx = if (sample_count > 0) sample_count / 2 else 0;
        const p99_idx = if (sample_count > 0) (sample_count * 99) / 100 else 0;

        return BenchmarkResult{
            .iterations = iterations,
            .total_ns = total_ns,
            .min_ns = if (min_ns == std.math.maxInt(u64)) 0 else min_ns,
            .max_ns = max_ns,
            .avg_ns = if (iterations > 0) total_ns / iterations else 0,
            .p50_ns = if (sample_count > 0) samples[p50_idx] else 0,
            .p99_ns = if (sample_count > 0) samples[p99_idx] else 0,
            .alloc_count = alloc_after - alloc_before,
            .alloc_bytes = bytes_after - bytes_before,
            .arena_high_water = arena_hw,
        };
    }

    /// Print a BenchmarkResult to stderr.
    pub fn printBenchmarkResult(name: []const u8, r: BenchmarkResult) void {
        std.debug.print("\nBENCHMARK {s} x{d}:\n", .{ name, r.iterations });
        std.debug.print("  Time:    {d:.1}ms avg ({d:.1}ms min, {d:.1}ms max)\n", .{
            @as(f64, @floatFromInt(r.avg_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(r.min_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(r.max_ns)) / 1_000_000.0,
        });
        std.debug.print("  Latency: {d:.1}ms p50, {d:.1}ms p99\n", .{
            @as(f64, @floatFromInt(r.p50_ns)) / 1_000_000.0,
            @as(f64, @floatFromInt(r.p99_ns)) / 1_000_000.0,
        });
        if (r.alloc_count > 0) {
            const per_call = if (r.iterations > 0) r.alloc_count / r.iterations else 0;
            std.debug.print("  Allocs:  {d} total ({d} per call, {d} KB)\n", .{
                r.alloc_count, per_call, r.alloc_bytes / 1024,
            });
        }
        if (r.arena_high_water > 0) {
            std.debug.print("  Arena:   {d} KB high-water\n", .{r.arena_high_water / 1024});
        }
    }

    /// Generate keys that all route to the same shard in a sharded map.
    pub fn generateSkewKeys(
        comptime N: usize,
        target_shard: usize,
        count: usize,
        allocator: std.mem.Allocator,
    ) ![][]const u8 {
        var keys = try allocator.alloc([]const u8, count);
        var found: usize = 0;
        var candidate: u64 = 0;

        while (found < count) : (candidate += 1) {
            var buf: [20]u8 = undefined;
            const key_str = std.fmt.bufPrint(&buf, "sk{d}", .{candidate}) catch continue;
            const h = std.hash_map.hashString(key_str);
            if (@as(usize, h) % N == target_shard) {
                const duped = try allocator.dupe(u8, key_str);
                keys[found] = duped;
                found += 1;
            }
        }
        return keys;
    }

    /// Free keys generated by generateSkewKeys.
    pub fn freeSkewKeys(keys: [][]const u8, allocator: std.mem.Allocator) void {
        for (keys) |k| allocator.free(k);
        allocator.free(keys);
    }
};

/// Module-level spawnPinned: distribute a pinned fiber round-robin across
/// schedulers.  Each call picks the next scheduler in sequence.  The fiber
/// is pinned to that scheduler (config.pinned = true).  This gives each
/// scheduler its own set of fibers — the shared-nothing model.
pub fn spawnPinned(trampoline_addr: usize, user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
    const n = fp.global_registry.len.load(.acquire);
    if (n == 0) {
        if (fp.scheduler_running) {
            try fp.active_scheduler.submitSpawn(trampoline_addr, user_fn, args, config);
            return;
        }
        return error.NoSchedulerAvailable;
    }
    const idx = fp.global_registry.next.fetchAdd(1, .monotonic) % n;
    const sched = fp.global_registry.slots[idx].load(.acquire) orelse {
        try fp.active_scheduler.submitSpawn(trampoline_addr, user_fn, args, config);
        return;
    };
    try sched.submitSpawn(trampoline_addr, user_fn, args, config);
}

/// Module-level spawnBest: distribute a fiber to the least-loaded scheduler.
/// Default dispatch for BG/DO blocks; @pinned blocks bypass this.
/// Fully lock-free via pickTwo (1 fetchAdd + 2 atomic loads).
pub fn spawnBest(trampoline_addr: usize, user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
    const pair = fp.global_registry.pickTwo();
    const a = pair.a orelse {
        if (fp.scheduler_running) {
            try fp.active_scheduler.submitSpawn(trampoline_addr, user_fn, args, config);
            return;
        }
        return error.NoSchedulerAvailable;
    };
    const b = pair.b orelse {
        try a.submitSpawn(trampoline_addr, user_fn, args, config);
        return;
    };
    const la = a.active_tasks.load(.monotonic);
    const lb = b.active_tasks.load(.monotonic);
    const target = if (la <= lb) a else b;
    try target.submitSpawn(trampoline_addr, user_fn, args, config);
}

/// Spawn a BG block on a dedicated OS thread (not a green fiber).
/// Designed for heavy-compute tasks that are non-cooperative (no yields).
/// The OS handles preemption. The result is delivered via the existing
/// Promise/WaitGroup mechanism — the thread calls wg.done() when finished,
/// which wakes the calling fiber on its scheduler.
///
/// Unlike fiber-based BG, the user function receives a freshly allocated
/// Runtime with its own frame arena. No scheduler is involved — the thread
/// runs independently until completion.
pub fn spawnOsThread(user_fn: TaskFn, args: ?*anyopaque) !void {
    _ = std.Thread.spawn(.{}, struct {
        fn run(fn_ptr: TaskFn, fn_args: ?*anyopaque) void {
            // Allocate a standalone Runtime for this thread.
            // Use c_allocator (no GPA — OS threads are outside the scheduler).
            const allocator = std.heap.c_allocator;
            const frame_size = 64 * 1024; // 64 KB frame arena
            const frame_mem = allocator.alloc(u8, frame_size) catch return;
            defer allocator.free(frame_mem);

            var global_ctx = EbrContext{};
            var rt = Runtime.initFromSlice(frame_mem, &global_ctx, allocator, 0) catch return;
            defer rt.deinit();
            rt.wireAllocator();

            const rt_ptr = @as(*anyopaque, @ptrCast(&rt));
            if (fn_ptr(rt_ptr, fn_args)) |_| {} else |_| {}
        }
    }.run, .{ user_fn, args }) catch return error.ThreadSpawnFailed;
}


