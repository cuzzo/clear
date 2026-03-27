const std = @import("std");
const builtin = @import("builtin");
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


// Helper Functions
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


    // Mostly for green fibers
    // Read from a non-blocking socket
    // Only works on Linux
    pub fn read(fd: i32, buffer: []u8) !usize {
        const sched = fp.active_scheduler;
        const task = sched.getCurrent();

        while (true) {
            // 1. Try to read using the high-level wrapper
            // This returns an error union (!usize), not a raw number.
            const n = std.posix.read(fd, buffer) catch |err| {
                if (err == error.WouldBlock) {
                    // 2. EAGAIN! No data yet.

                    // Register with Epoll
                    // We catch 'FileDescriptorAlreadyPresent' just in case we loop rapidly
                    try sched.registerFd(fd, task);

                    // Yield (Block)
                    task.status = .Blocked;
                    task.base.yield();

                    // When we wake up, loop back and try read() again!
                    continue;
                }
                // Propagate legitimate errors (e.g. ConnectionReset, etc)
                return err;
            };

            // Success! 'n' is definitely the valid byte count.
            return n;
        }
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
    pub fn getAt(container: anytype, index: anytype) @TypeOf(if (@hasField(@TypeOf(container), "items")) container.items[0] else container[0]) {
        const i: usize = @intCast(index); // Auto-cast i64 -> usize

        if (@hasField(@TypeOf(container), "items")) {
            return container.items[i];
        } else {
            return container[i];
        }
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
        return try std.mem.concat(allocator, u8, &.{ s1, s2 });
    }

    // Polymorphic Length (Strings or Lists)
    pub fn len(container: anytype) i64 {
        // If it has .items (ArrayList), use that. Otherwise assume it's a Slice.
        if (@hasField(@TypeOf(container), "items")) {
            return @intCast(container.items.len);
        } else {
            return @intCast(container.len);
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

            pub fn put(self: *Self, key_alloc: std.mem.Allocator, bucket_alloc: std.mem.Allocator, key: []const u8, value: V) !void {
                if (self.inner.getPtr(key)) |val_ptr| {
                    val_ptr.* = value;
                    return;
                }
                const key_copy = try key_alloc.dupe(u8, key);
                try self.inner.put(bucket_alloc, key_copy, value);
            }

            pub fn get(self: *Self, key: []const u8) ?V {
                return self.inner.get(key);
            }

            pub fn contains(self: *Self, key: []const u8) bool {
                return self.inner.contains(key);
            }

            pub fn remove(self: *Self, key_alloc: std.mem.Allocator, key: []const u8) void {
                if (self.inner.fetchRemove(key)) |kv| {
                    key_alloc.free(kv.key);
                }
            }

            pub fn count(self: *Self) i64 {
                return @intCast(self.inner.count());
            }

            pub fn deinit(self: *Self, key_alloc: std.mem.Allocator, bucket_alloc: std.mem.Allocator) void {
                var it = self.inner.iterator();
                while (it.next()) |entry| key_alloc.free(entry.key_ptr.*);
                self.inner.deinit(bucket_alloc);
            }

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
        try map.put(alloc, key, value);
    }

    pub fn numericMapGet(comptime K: type, comptime V: type, map: NumericMapType(K, V), key: K) ?V {
        return map.get(key);
    }

    pub fn numericMapDelete(comptime K: type, comptime V: type, alloc: std.mem.Allocator, map: *NumericMapType(K, V), key: K) void {
        _ = map.remove(key);
        _ = alloc;
    }

    pub fn numericMapContains(comptime K: type, comptime V: type, map: NumericMapType(K, V), key: K) bool {
        return map.contains(key);
    }

    pub fn numericMapCount(comptime K: type, comptime V: type, map: NumericMapType(K, V)) i64 {
        return @intCast(map.count());
    }

    pub fn numericMapDeinit(comptime K: type, comptime V: type, alloc: std.mem.Allocator, map: *NumericMapType(K, V)) void {
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
        _ = try file.readAll(buffer);
        return buffer;
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
    // When a scheduler is active (BG fibers), the actual read(2) syscall is
    // submitted via io_uring (IORING_OP_READ).  The fiber parks itself as
    // .Blocked and yields; the kernel completes the read asynchronously and
    // the scheduler's CQE drain wakes the fiber.  Other fibers run in the
    // meantime, giving genuine concurrency on a single OS thread.
    //
    // Fallback: Outside a scheduler context (unit tests), a plain blocking
    // readAll is used — no io_uring, no yield.
    pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        // 1. Open + stat are fast (no data transfer, just metadata).
        var dir = std.fs.cwd();
        var file = try dir.openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const buffer = try allocator.alloc(u8, stat.size);

        // 2. Async path: submit read via io_uring, yield, resume when done.
        if (fp.scheduler_running) {
            const sched = fp.active_scheduler;
            const task = sched.getCurrent();

            // IoWaiter lives on the fiber's stack — safe because the fiber is
            // .Blocked until the CQE arrives and the scheduler writes .result.
            var waiter = fp.Scheduler.IoWaiter{ .task = task };
            try sched.submitRead(&waiter, file.handle, buffer);
            task.base.yield(); // park until CQE

            if (waiter.result < 0) {
                allocator.free(buffer);
                return error.IoUringReadFailed;
            }
            return buffer[0..@intCast(waiter.result)];
        }

        // 3. Blocking fallback for test / non-scheduler contexts.
        _ = try file.readAll(buffer);
        return buffer;
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
    pub fn writeFile(path: []const u8, content: []const u8) !void {
        var dir = std.fs.cwd();
        // Create or Overwrite
        var file = try dir.createFile(path, .{});
        defer file.close();

        try file.writeAll(content);
    }

    // String Lib

    // Used to make HEAP strings
    pub fn makeString(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{s}", .{text});
    }

    pub fn substr(allocator: std.mem.Allocator, str: []const u8, start: i64, length: i64) ![]const u8 {
        // Basic safety checks (Zig panics on slice OOB, but clean errors are better)
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
    pub fn intToString(allocator: std.mem.Allocator, value: i64) ![]const u8 {
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
        // Support both ArrayListUnmanaged and raw Slices
        const items = if (@hasField(@TypeOf(list), "items")) list.items else list;
        return std.mem.join(allocator, delimiter, items);
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

    // Accept one incoming connection on `server_fd`.
    // If no connection is ready yet (EAGAIN/WouldBlock), registers with epoll
    // and yields the current fiber until a connection arrives.
    // Returns the client fd (set non-blocking via fcntl). Caller owns it.
    pub fn socketAccept(server_fd: i32) !i32 {
        const sched = fp.active_scheduler;
        const task  = sched.getCurrent();

        while (true) {
            var client_addr: std.posix.sockaddr = undefined;
            var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);

            // Use the high-level posix wrapper — it maps kernel errors to Zig errors
            // (same pattern as std.posix.read used in CheatLib.read above).
            const client_fd = std.posix.accept(
                server_fd, &client_addr, &addr_len,
                std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC,
            ) catch |err| {
                if (err == error.WouldBlock) {
                    // No client yet — register for read-readiness and yield.
                    try sched.registerFd(server_fd, task);
                    task.status = .Blocked;
                    task.base.yield();
                    continue;
                }
                return err;
            };

            return client_fd;
        }
    }

    // Write `data` to a non-blocking socket fd.
    // Loops until all bytes are sent, yielding the fiber on EAGAIN.
    // Returns the total bytes sent (== data.len on success).
    pub fn socketWrite(fd: i32, data: []const u8) !usize {
        const sched = fp.active_scheduler;
        const task  = sched.getCurrent();

        var sent: usize = 0;
        while (sent < data.len) {
            const n = std.posix.write(fd, data[sent..]) catch |err| {
                if (err == error.WouldBlock) {
                    // Socket send buffer is full — wait for write-readiness.
                    try sched.registerWriteFd(fd, task);
                    task.status = .Blocked;
                    task.base.yield();
                    continue;
                }
                return err;
            };
            sent += n;
        }
        return sent;
    }

    // Close a TCP socket fd, removing it from epoll first so no stale events fire.
    pub fn socketClose(fd: i32) void {
        fp.active_scheduler.unregisterFd(fd);
        std.posix.close(fd);
    }

    // Read up to 4096 bytes from a connected client socket.
    // Yields the fiber (via epoll) until data is available.
    //
    // Reads into a stack-local buffer then dupes into the frame arena
    // (the allocator passed by the transpiler is rt.frameAlloc()).
    // The returned slice lives until the enclosing loop iteration's
    // restoreLoopMark rewinds the arena — zero GPA calls in the hot path.
    //
    // Usage: data = tcpRead(client)
    pub fn socketRead(allocator: std.mem.Allocator, fd: i32) ![]const u8 {
        var buf: [4096]u8 = undefined;
        const n = try CheatLib.read(fd, &buf);
        return allocator.dupe(u8, buf[0..n]);
    }

    // Write all bytes from `data` to a connected client socket, discarding the byte count.
    // Yields the fiber if the send buffer is temporarily full (epoll-backed).
    // Usage: tcpWrite(client, "hello")
    pub fn socketWriteVoid(fd: i32, data: []const u8) !void {
        _ = try CheatLib.socketWrite(fd, data);
    }

    // Connect to a TCP server at `host:port` (dotted-decimal IPv4 only).
    // Non-blocking: if the kernel returns EINPROGRESS the fiber yields until
    // epoll signals write-readiness, then the connection result is verified.
    // Returns the client fd; caller owns it (close via socketClose / RAII).
    pub fn socketConnect(host: []const u8, port: u16) !i32 {
        const sched = fp.active_scheduler;
        const task  = sched.getCurrent();

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

        std.posix.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) catch |err| {
            // Non-blocking connect returns WouldBlock (EINPROGRESS) immediately.
            if (err != error.WouldBlock) return err;
            // Wait for epoll OUT event — kernel signals it when the 3-way handshake completes.
            try sched.registerWriteFd(fd, task);
            task.status = .Blocked;
            task.base.yield();
            // Check SO_ERROR to distinguish success from async errors (e.g. ECONNREFUSED).
            try std.posix.getsockoptError(fd);
        };

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

    /// Rc(T): a reference-counted wrapper around a heap-allocated T.
    /// The data pointer and ref-count are both allocated via the provided allocator.
    pub fn Rc(comptime T: type) type {
        return struct {
            const Self = @This();
            data: *T,
            ref_count: *usize,
        };
    }

    /// Create a new Rc from an already-heap-allocated *T.
    /// The Rc takes ownership of data_ptr; ref_count starts at 1.
    pub fn rcCreate(comptime T: type, alloc: std.mem.Allocator, data: T) !Rc(T) {
        const ref_count = try alloc.create(usize);
        ref_count.* = 1;
        const data_ptr = try alloc.create(T);
        data_ptr.* = data;
        return Rc(T){ .data = data_ptr, .ref_count = ref_count };
    }

    /// Increment the reference count and return a copy of the handle.
    /// Both the original and the returned handle must eventually be released.
    pub fn rcRetain(comptime T: type, rc: Rc(T)) Rc(T) {
        rc.ref_count.* += 1;
        return rc;
    }

    /// Decrement the reference count.  When it reaches 0 the data and
    /// ref-count allocation are freed.
    pub fn rcRelease(comptime T: type, alloc: std.mem.Allocator, rc: Rc(T)) void {
        rc.ref_count.* -= 1;
        if (rc.ref_count.* == 0) {
            alloc.destroy(rc.data);
            alloc.destroy(rc.ref_count);
        }
    }

    // -------------------------------------------------------------------------
    // Atomic Reference Counting (shared / Arc)
    // -------------------------------------------------------------------------

    /// Arc(T): an atomically reference-counted wrapper around a heap-allocated T.
    /// Thread-safe: the ref-count is an atomic usize.
    pub fn Arc(comptime T: type) type {
        return struct {
            const Self = @This();
            data: *T,
            ref_count: *std.atomic.Value(usize),
        };
    }

    /// Create a new Arc from an already-heap-allocated *T.
    /// The Arc takes ownership of data_ptr; ref_count starts at 1.
    pub fn arcCreate(comptime T: type, alloc: std.mem.Allocator, data: T) !Arc(T) {
        const ref_count = try alloc.create(std.atomic.Value(usize));
        ref_count.* = std.atomic.Value(usize).init(1);
        const data_ptr = try alloc.create(T);
        data_ptr.* = data;
        return Arc(T){ .data = data_ptr, .ref_count = ref_count };
    }

    /// Increment the reference count atomically and return a copy of the handle.
    /// Both the original and the returned handle must eventually be released.
    pub fn arcRetain(comptime T: type, arc: Arc(T)) Arc(T) {
        _ = arc.ref_count.fetchAdd(1, .acquire);
        return arc;
    }

    /// Decrement the reference count atomically. When it reaches 0 the data
    /// and ref-count allocation are freed.
    pub fn arcRelease(comptime T: type, alloc: std.mem.Allocator, arc: Arc(T)) void {
        const prev = arc.ref_count.fetchSub(1, .release);
        if (prev == 1) {
            // Acquire the release-sequence so all writes before prior arcRelease()
            // calls are visible before we free the data.
            _ = arc.ref_count.load(.acquire);
            alloc.destroy(arc.data);
            alloc.destroy(arc.ref_count);
        }
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
    pub fn RwLocked(comptime T: type) type {
        return struct {
            lock: std.Thread.RwLock = .{},
            data: T,

            const Self = @This();

            pub fn init(val: T) Self {
                return .{ .data = val };
            }

            pub fn read(self: *Self) ReadGuard {
                self.lock.lockShared();
                return ReadGuard{ .parent = self };
            }

            pub fn write(self: *Self) WriteGuard {
                self.lock.lock();
                return WriteGuard{ .parent = self };
            }

            pub const ReadGuard = struct {
                parent: *Self,

                pub fn get(self: *ReadGuard) *const T {
                    return &self.parent.data;
                }

                pub fn release(self: *ReadGuard) void {
                    self.parent.lock.unlockShared();
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
                    self.parent.lock.unlock();
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
            pub const Inner = struct {
                result: T = undefined,
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
                    .result = undefined,
                    .wg = WaitGroup.init(sched),
                };
                inner.wg.add(1);
                return Self{ .inner = inner, .alloc = alloc };
            }

            /// Block the current fiber until the BG fiber has written its result
            /// (via `inner.result = val` before calling `inner.wg.done()`), then
            /// return that result and free the heap-allocated Inner.
            ///
            /// Safe ordering: the BG fiber's store to `inner.result` happens-before
            /// the seq_cst `wg.done()`, which happens-before this function returns.
            pub fn next(self: Self) T {
                self.inner.wg.wait();
                const val = self.inner.result;
                self.alloc.destroy(self.inner);
                return val;
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
                result: T = undefined,
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
                    .result = undefined,
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
            pub fn next(self: *Self) T {
                if (self.resolved) |val| return val;
                self.inner.wg.wait();
                const val = self.inner.result;
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
            /// Advances the internal head pointer so subsequent calls yield
            /// successive items. Panics if the stream has already been fully
            /// consumed (all N items retrieved).
            pub fn next(self: *Self) T {
                if (self.head >= N) @panic("BoundedStream exhausted: all items consumed");
                const val = self.items[self.head].next();
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

            /// Consume the next buffered value.
            /// Blocks on the first call until the generator fiber has finished.
            /// Returns null when all yielded values have been consumed.
            pub fn next(self: *Self) ?T {
                self.inner.wg.wait();
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
    // InfStream(T): A lazy rendezvous generator stream. Corresponds to ~T[INF] in CLEAR.
    //
    // Generator and consumer rendezvous on each value via a single-slot channel:
    //   - Generator calls push(val): writes val, blocks until consumer reads it.
    //   - Consumer calls next(): blocks until generator pushes, reads val, wakes generator.
    //
    // Both sides run as green fibers in the same scheduler. Blocking = fiber yield.
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

            pub const Inner = struct {
                slot: T = undefined,
                // 0 = empty (no value available), 1 = value ready (generator is waiting)
                state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
                // Spinlock protecting consumer_task and producer_task
                lock: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
                consumer_task: ?*Task = null,
                producer_task: ?*Task = null,
                sched: *fp.Scheduler,
                // Set by deinit() to signal the generator fiber to stop.
                closed: bool = false,
            };

            inner: *Inner,
            alloc: std.mem.Allocator,

            /// Allocate an Inner on the heap and return the InfStream handle.
            pub fn spawnNew(alloc: std.mem.Allocator, sched: *fp.Scheduler) !Self {
                const inner = try alloc.create(Inner);
                inner.* = .{ .sched = sched };
                return Self{ .inner = inner, .alloc = alloc };
            }

            /// Generator fiber calls this to yield a value.
            /// Writes val into the slot, wakes the consumer, then blocks until val is consumed.
            /// Returns error.StreamClosed if deinit() was called while the generator was blocked.
            pub fn push(self: *Self, val: T) error{StreamClosed}!void {
                const inner = self.inner;

                // Write value and mark slot as ready (state = 1)
                while (inner.lock.swap(1, .acquire) == 1) std.Thread.yield() catch {};
                if (inner.closed) { inner.lock.store(0, .release); return error.StreamClosed; }
                inner.slot = val;
                inner.state.store(1, .release);
                if (inner.consumer_task) |consumer| {
                    inner.consumer_task = null;
                    inner.lock.store(0, .release);
                    inner.sched.schedule(consumer);
                } else {
                    inner.lock.store(0, .release);
                }

                // Block until consumer reads the value (state returns to 0)
                while (true) {
                    while (inner.lock.swap(1, .acquire) == 1) std.Thread.yield() catch {};
                    if (inner.closed) { inner.lock.store(0, .release); return error.StreamClosed; }
                    if (inner.state.load(.acquire) == 0) {
                        inner.lock.store(0, .release);
                        return; // Value was consumed — proceed to next YIELD
                    }
                    const task = inner.sched.getCurrent();
                    task.status = .Blocked;
                    inner.producer_task = task;
                    inner.lock.store(0, .release);
                    task.base.yield();
                }
            }

            /// Consumer calls this to receive the next yielded value.
            /// Blocks until the generator calls push().
            pub fn next(self: *Self) T {
                const inner = self.inner;

                while (true) {
                    while (inner.lock.swap(1, .acquire) == 1) std.Thread.yield() catch {};
                    if (inner.state.load(.acquire) == 1) {
                        const val = inner.slot;
                        inner.state.store(0, .release);
                        if (inner.producer_task) |producer| {
                            inner.producer_task = null;
                            inner.lock.store(0, .release);
                            inner.sched.schedule(producer);
                        } else {
                            inner.lock.store(0, .release);
                        }
                        return val;
                    }
                    const task = inner.sched.getCurrent();
                    task.status = .Blocked;
                    inner.consumer_task = task;
                    inner.lock.store(0, .release);
                    task.base.yield();
                }
            }

            /// No-op — infinite streams have no natural close point.
            pub fn close(_: *Self) void {}

            /// Signal the generator fiber to stop.
            /// Sets the closed flag and wakes the generator if it is blocked in push().
            /// The generator will see closed=true, return error.StreamClosed, and free Inner
            /// itself before exiting — so this function must NOT free Inner to avoid UAF.
            pub fn deinit(self: *Self) void {
                const inner = self.inner;
                // Acquire lock, mark closed, and wake any blocked producer.
                while (inner.lock.swap(1, .acquire) == 1) std.Thread.yield() catch {};
                inner.closed = true;
                if (inner.producer_task) |producer| {
                    inner.producer_task = null;
                    inner.lock.store(0, .release);
                    inner.sched.schedule(producer);
                } else {
                    inner.lock.store(0, .release);
                }
                // Inner will be freed by the generator fiber when it exits via error.StreamClosed.
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
    // Handles are u64 values encoding [generation: upper 32 bits][index: lower 32 bits].
    // Generation counters prevent use-after-remove (ABA safety).
    //
    // Usage (mirrors CLEAR `MUTABLE p: User[]@pool = []`):
    //   var p = CheatLib.Pool(User){};
    //   defer p.deinit(allocator);
    //   const id: u64 = try p.insert(allocator, User{ .name = "Alice" });
    //   const ptr: ?*User = p.get(id);    // null if stale
    //   p.remove(id);                     // increments generation
    pub fn Pool(comptime T: type) type {
        return struct {
            const Self = @This();

            const Slot = struct {
                generation: u32 = 0,
                alive: bool = false,
                value: T = undefined,
            };

            slots:      std.ArrayListUnmanaged(Slot) = .{},
            /// Number of dead (removed) slots available for reuse.
            /// When zero we can skip the linear scan entirely and just append,
            /// giving O(1) amortised insert for workloads with no removes.
            free_count: u32 = 0,

            pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
                self.slots.deinit(allocator);
            }

            /// Insert a value, returning a stable u64 handle.
            /// The handle encodes: [(generation: u32) << 32 | (index: u32)].
            /// Reuses dead slots when available (O(N) scan); otherwise O(1) append.
            /// For insert-only workloads free_count stays 0, so the scan is skipped.
            pub fn insert(self: *Self, allocator: std.mem.Allocator, value: T) !u64 {
                // Only scan for a dead slot if we know at least one exists.
                if (self.free_count > 0) {
                    for (self.slots.items, 0..) |*slot, i| {
                        if (!slot.alive) {
                            self.free_count -= 1;
                            const gen = slot.generation;
                            slot.* = .{ .generation = gen, .alive = true, .value = value };
                            return (@as(u64, gen) << 32) | @as(u64, @intCast(i));
                        }
                    }
                }
                // No free slot (or free_count was 0): grow
                const idx = @as(u32, @intCast(self.slots.items.len));
                try self.slots.append(allocator, .{ .generation = 0, .alive = true, .value = value });
                return @as(u64, idx); // generation=0, index=idx
            }

            /// Look up a handle. Returns null if stale or out of range.
            pub fn get(self: *Self, id: u64) ?*T {
                const idx = @as(u32, @truncate(id));
                const gen = @as(u32, @truncate(id >> 32));
                if (idx >= self.slots.items.len) return null;
                const slot = &self.slots.items[idx];
                if (!slot.alive or slot.generation != gen) return null;
                return &slot.value;
            }

            /// Remove a slot. Increments the generation counter (ABA protection).
            /// No-op if the handle is stale or out of range.
            pub fn remove(self: *Self, id: u64) void {
                const idx = @as(u32, @truncate(id));
                const gen = @as(u32, @truncate(id >> 32));
                if (idx >= self.slots.items.len) return;
                const slot = &self.slots.items[idx];
                if (!slot.alive or slot.generation != gen) return;
                slot.alive = false;
                slot.generation +%= 1; // wrapping increment for ABA safety
                self.free_count += 1;
            }

            /// Returns the number of live (non-removed) slots.
            pub fn count(self: *const Self) usize {
                var n: usize = 0;
                for (self.slots.items) |slot| {
                    if (slot.alive) n += 1;
                }
                return n;
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

            pub fn length(self: *const Self) usize {
                return self.data.len;
            }

            pub fn count(self: *const Self) usize {
                return self.data.len;
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
            generations: std.ArrayListUnmanaged(u32) = .{},
            alive: std.ArrayListUnmanaged(bool) = .{},
            free_count: u32 = 0,

            pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
                self.data.deinit(allocator);
                self.generations.deinit(allocator);
                self.alive.deinit(allocator);
            }

            pub fn insert(self: *Self, allocator: std.mem.Allocator, value: T) !u64 {
                // Reuse a dead slot if available.
                if (self.free_count > 0) {
                    for (self.alive.items, 0..) |is_alive, i| {
                        if (!is_alive) {
                            self.free_count -= 1;
                            const gen = self.generations.items[i];
                            self.alive.items[i] = true;
                            // Write each field into the MultiArrayList.
                            self.data.set(i, value);
                            return (@as(u64, gen) << 32) | @as(u64, @intCast(i));
                        }
                    }
                }
                // Grow: append to all parallel arrays.
                const idx = @as(u32, @intCast(self.data.len));
                try self.data.append(allocator, value);
                try self.generations.append(allocator, 0);
                try self.alive.append(allocator, true);
                return @as(u64, idx);
            }

            /// Look up a handle.  Returns the struct by value (reassembled
            /// from SOA arrays), or null if the handle is stale.
            pub fn get(self: *const Self, id: u64) ?T {
                const idx = @as(u32, @truncate(id));
                const gen = @as(u32, @truncate(id >> 32));
                if (idx >= self.data.len) return null;
                if (!self.alive.items[idx] or self.generations.items[idx] != gen) return null;
                return self.data.get(idx);
            }

            /// Get a mutable pointer to a specific field for a given handle.
            /// Used by EACH pipeline for in-place mutation of individual fields.
            pub fn getFieldPtr(self: *Self, comptime field: std.meta.FieldEnum(T), id: u64) ?*std.meta.fieldInfo(T, field).type {
                const idx = @as(u32, @truncate(id));
                const gen = @as(u32, @truncate(id >> 32));
                if (idx >= self.data.len) return null;
                if (!self.alive.items[idx] or self.generations.items[idx] != gen) return null;
                const slice = self.data.items(field);
                return &slice[idx];
            }

            pub fn remove(self: *Self, id: u64) void {
                const idx = @as(u32, @truncate(id));
                const gen = @as(u32, @truncate(id >> 32));
                if (idx >= self.data.len) return;
                if (!self.alive.items[idx] or self.generations.items[idx] != gen) return;
                self.alive.items[idx] = false;
                self.generations.items[idx] +%= 1;
                self.free_count += 1;
            }

            pub fn count(self: *const Self) usize {
                var n: usize = 0;
                for (self.alive.items) |a| {
                    if (a) n += 1;
                }
                return n;
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
            pub fn count(self: *const Self) usize {
                var n: usize = 0;
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

            fn shardIndex(key: []const u8) usize {
                return @as(usize, std.hash.Fnv1a_64.hash(key)) % N;
            }

            fn ensureOwnership(self: *Self) void {
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

            inline fn isLocal(self: *Self, s: usize) bool {
                return (self.owners[s] == fp.active_scheduler);
            }

            // Remote-call context structs — live on the calling fiber's stack.
            // The remote function must NOT call wg.done(); drainInbox does it.

            // Remote operation context structs.  Each has a `done` atomic flag
            // that the target sets after completing the operation.  The caller
            // spins on this flag — no WaitGroup, no cross-thread scheduler access.
            const PutCtx = struct {
                map: *Self, shard: usize,
                key: []const u8, value: V,
                err: bool = false,
                done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
                fn run(raw: *anyopaque) void {
                    const c: *@This() = @ptrCast(@alignCast(raw));
                    c.map.shards[c.shard].map.put(remote_alloc, c.key, c.value) catch {
                        remote_alloc.free(c.key); c.err = true;
                    };
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
            const ContainsCtx = struct {
                map: *Self, shard: usize, key: []const u8, result: bool = false,
                done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
                fn run(raw: *anyopaque) void {
                    const c: *@This() = @ptrCast(@alignCast(raw));
                    c.result = c.map.shards[c.shard].map.contains(c.key);
                    c.done.store(true, .release);
                }
            };
            const RemoveCtx = struct {
                map: *Self, shard: usize, key: []const u8,
                done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
                fn run(raw: *anyopaque) void {
                    const c: *@This() = @ptrCast(@alignCast(raw));
                    if (c.map.shards[c.shard].map.fetchRemove(c.key)) |kv|
                        remote_alloc.free(kv.key);
                    c.done.store(true, .release);
                }
            };

            // Heap-allocated bundle for cross-scheduler RPC.
            // Must be heap-allocated because the calling fiber's stack may be
            // modified between inbox.push() and drainInbox processing.
            const RemoteBundle = struct {
                rc: fp.RemoteCall,
                wg: WaitGroup,
                ctx: PutCtx,
            };
            const GetBundle = struct {
                rc: fp.RemoteCall,
                wg: WaitGroup,
                ctx: GetCtx,
            };
            const ContainsBundle = struct {
                rc: fp.RemoteCall,
                wg: WaitGroup,
                ctx: ContainsCtx,
            };
            const RemoveBundle = struct {
                rc: fp.RemoteCall,
                wg: WaitGroup,
                ctx: RemoveCtx,
            };

            pub fn put(self: *Self, _: std.mem.Allocator, _: std.mem.Allocator, key: []const u8, value: V) !void {
                self.ensureOwnership();
                const s = shardIndex(key);
                if (self.isLocal(s)) {
                    const owned_key = try remote_alloc.dupe(u8, key);
                    try self.shards[s].map.put(remote_alloc, owned_key, value);
                } else {
                    // COLD PATH: send via SPSC channel. Caller spins on done flag.
                    // No WaitGroup, no cross-thread scheduler access.
                    const safe_key = try remote_alloc.dupe(u8, key);
                    var ctx = PutCtx{ .map = self, .shard = s, .key = safe_key, .value = value };
                    const msg = fp.SpscMessage{
                        .tag = .RemoteCall,
                        .rc_func = @ptrCast(&PutCtx.run),
                        .rc_ctx = @ptrCast(&ctx),
                    };
                    const target = self.owners[s].?;
                    const sender_idx = fp.active_scheduler.index;
                    while (!target.channels[sender_idx].push(msg)) {
                        std.Thread.yield() catch {};
                    }
                    target.event_fd.notify();
                    // Spin until target completes the operation
                    while (!ctx.done.load(.acquire)) {
                        std.Thread.yield() catch {};
                    }
                    if (ctx.err) return error.OutOfMemory;
                }
            }

            pub fn get(self: *Self, key: []const u8) ?V {
                self.ensureOwnership();
                const s = shardIndex(key);
                if (self.isLocal(s)) {
                    return self.shards[s].map.get(key);
                } else {
                    const safe_key = remote_alloc.dupe(u8, key) catch return null;
                    defer remote_alloc.free(safe_key);
                    var ctx = GetCtx{ .map = self, .shard = s, .key = safe_key };
                    const msg = fp.SpscMessage{
                        .tag = .RemoteCall,
                        .rc_func = @ptrCast(&GetCtx.run),
                        .rc_ctx = @ptrCast(&ctx),
                    };
                    const target = self.owners[s].?;
                    const sender_idx = fp.active_scheduler.index;
                    while (!target.channels[sender_idx].push(msg))
                        std.Thread.yield() catch {};
                    target.event_fd.notify();
                    while (!ctx.done.load(.acquire))
                        std.Thread.yield() catch {};
                    return ctx.result;
                }
            }

            pub fn contains(self: *Self, key: []const u8) bool {
                self.ensureOwnership();
                const s = shardIndex(key);
                if (self.isLocal(s)) {
                    return self.shards[s].map.contains(key);
                } else {
                    const safe_key = remote_alloc.dupe(u8, key) catch return false;
                    defer remote_alloc.free(safe_key);
                    var ctx = ContainsCtx{ .map = self, .shard = s, .key = safe_key };
                    const msg = fp.SpscMessage{
                        .tag = .RemoteCall,
                        .rc_func = @ptrCast(&ContainsCtx.run),
                        .rc_ctx = @ptrCast(&ctx),
                    };
                    const target = self.owners[s].?;
                    const sender_idx = fp.active_scheduler.index;
                    while (!target.channels[sender_idx].push(msg))
                        std.Thread.yield() catch {};
                    target.event_fd.notify();
                    while (!ctx.done.load(.acquire))
                        std.Thread.yield() catch {};
                    return ctx.result;
                }
            }

            pub fn remove(self: *Self, _: std.mem.Allocator, key: []const u8) void {
                self.ensureOwnership();
                const s = shardIndex(key);
                if (self.isLocal(s)) {
                    if (self.shards[s].map.fetchRemove(key)) |kv| remote_alloc.free(kv.key);
                } else {
                    const safe_key = remote_alloc.dupe(u8, key) catch return;
                    defer remote_alloc.free(safe_key);
                    var ctx = RemoveCtx{ .map = self, .shard = s, .key = safe_key };
                    const msg = fp.SpscMessage{
                        .tag = .RemoteCall,
                        .rc_func = @ptrCast(&RemoveCtx.run),
                        .rc_ctx = @ptrCast(&ctx),
                    };
                    const target = self.owners[s].?;
                    const sender_idx = fp.active_scheduler.index;
                    while (!target.channels[sender_idx].push(msg))
                        std.Thread.yield() catch {};
                    target.event_fd.notify();
                    while (!ctx.done.load(.acquire))
                        std.Thread.yield() catch {};
                }
            }

            pub fn count(self: *Self) i64 {
                var nc: i64 = 0;
                for (&self.shards) |*shard| nc += @intCast(shard.map.count());
                return nc;
            }

            pub fn deinit(self: *Self, _: std.mem.Allocator, _: std.mem.Allocator) void {
                // Always use remote_alloc (c_allocator) — consistent with put/remove.
                for (&self.shards) |*shard| {
                    var it = shard.map.iterator();
                    while (it.next()) |entry| remote_alloc.free(entry.key_ptr.*);
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

            fn shardIndex(key: []const u8) usize {
                return @as(usize, std.hash.Fnv1a_64.hash(key)) % N;
            }

            pub fn put(self: *Self, key_alloc: std.mem.Allocator, bucket_alloc: std.mem.Allocator, key: []const u8, value: V) !void {
                const s = shardIndex(key);
                self.shards[s].lock.lock();
                defer self.shards[s].lock.unlock();
                _ = self.shards[s].ops.fetchAdd(1, .monotonic);
                const owned_key = try key_alloc.dupe(u8, key);
                try self.shards[s].map.put(bucket_alloc, owned_key, value);
            }

            pub fn get(self: *Self, key: []const u8) ?V {
                const s = shardIndex(key);
                self.shards[s].lock.lockShared();
                defer self.shards[s].lock.unlockShared();
                _ = self.shards[s].ops.fetchAdd(1, .monotonic);
                return self.shards[s].map.get(key);
            }

            pub fn contains(self: *Self, key: []const u8) bool {
                const s = shardIndex(key);
                self.shards[s].lock.lockShared();
                defer self.shards[s].lock.unlockShared();
                return self.shards[s].map.contains(key);
            }

            pub fn remove(self: *Self, key_alloc: std.mem.Allocator, key: []const u8) void {
                const s = shardIndex(key);
                self.shards[s].lock.lock();
                defer self.shards[s].lock.unlock();
                if (self.shards[s].map.fetchRemove(key)) |kv| {
                    key_alloc.free(kv.key);
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

            pub fn deinit(self: *Self, key_alloc: std.mem.Allocator, bucket_alloc: std.mem.Allocator) void {
                for (&self.shards) |*shard| {
                    var it = shard.map.iterator();
                    while (it.next()) |entry| key_alloc.free(entry.key_ptr.*);
                    shard.map.deinit(bucket_alloc);
                }
            }

            pub fn getOpCounts(self: *const Self) [N]u64 {
                var counts: [N]u64 = undefined;
                for (0..N) |i| counts[i] = self.shards[i].ops.load(.monotonic);
                return counts;
            }
        };
    }

    // StripedStringMap — alias for ShardedStringMap (backward compat).
    // Lock elision removed; @sharded(N) always uses RwLock.
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
                ops: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
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
                _ = shard.ops.fetchAdd(1, .monotonic);
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
                try self.shards[s].map.put(alloc, key, value);
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
                _ = alloc;
                _ = self.shards[s].map.fetchRemove(key);
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

            pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
                for (&self.shards) |*shard| shard.map.deinit(alloc);
            }

            pub fn getOpCounts(self: *const Self) [N]u64 {
                var counts: [N]u64 = undefined;
                for (0..N) |i| counts[i] = self.shards[i].ops.load(.monotonic);
                return counts;
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


