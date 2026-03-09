const std = @import("std");
const builtin = @import("builtin");
pub const Runtime = @import("runtime.zig").Runtime;
const fc = @import("fiber-core.zig");
const fp = @import("scheduler.zig");

pub const EbrContext = @import("ebr.zig").EbrContext;
const Task = fc.Task;
const Fiber = fc.Fiber;

// Concurrency primitives re-exported for DO block fork-join support.
pub const WaitGroup = fp.WaitGroup;
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

    // HashMap / Associative Map

    // Usage: var map = try rt.makeMap(i64, rt.heapAlloc());
    pub fn makeHashMap(comptime V: type) !std.StringHashMapUnmanaged(V) {
        // Start empty. Unmanaged maps don't alloc until you put().
        return std.StringHashMapUnmanaged(V){};
    }

    // Usage: try rt.mapPut(i64, rt.heapAlloc(), &map, "key", 100);
    pub fn mapPut(comptime V: type, allocator: std.mem.Allocator, map: *std.StringHashMapUnmanaged(V), key: []const u8, value: V) !void {
        // Check if key already exists - if so, just update the value
        if (map.getPtr(key)) |val_ptr| {
            val_ptr.* = value;
            return;
        }
        // Key doesn't exist - duplicate it to the Heap because the Map keeps a pointer to it.
        // If we don't, and 'key' is a frame string that dies, the map breaks.
        const key_copy = try allocator.dupe(u8, key);
        try map.put(allocator, key_copy, value);
    }

    // Usage: rt.mapGet(i64, map, "key")
    // Smart return: if V is ArrayListUnmanaged(T), returns []T instead of the list struct
    pub fn mapGet(comptime V: type, map: std.StringHashMapUnmanaged(V), key: []const u8) MapGetReturnType(V) {
        const is_array_list = comptime isArrayListUnmanaged(V);

        if (map.get(key)) |val| {
            if (comptime is_array_list) {
                return val.items; // Return slice for ArrayListUnmanaged
            } else {
                return val;
            }
        }

        // Default values based on type
        if (comptime is_array_list) return &[_]ArrayListElement(V){};
        if (V == i64 or V == f64) return 0;
        if (V == []const u8) return "";
        return undefined;
    }

    // Helper: Check if type is ArrayListUnmanaged
    fn isArrayListUnmanaged(comptime T: type) bool {
        if (@typeInfo(T) != .@"struct") return false;
        return @hasField(T, "items") and @hasField(T, "capacity") and !@hasField(T, "allocator");
    }

    // Helper: Get element type from ArrayListUnmanaged
    fn ArrayListElement(comptime T: type) type {
        const items_field = @typeInfo(T).@"struct".fields[0]; // items is first field
        const slice_info = @typeInfo(items_field.type).pointer;
        return slice_info.child;
    }

    // Helper: Compute return type for mapGet
    fn MapGetReturnType(comptime V: type) type {
        if (comptime isArrayListUnmanaged(V)) {
            return []ArrayListElement(V);
        }
        return V;
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
    pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
        // 1. Open File
        // Note: We use the absolute path or CWD.
        var dir = std.fs.cwd();
        var file = try dir.openFile(path, .{});
        defer file.close();

        // 2. Stat size to allocate exact buffer
        const stat = try file.stat();

        // 3. Alloc buffer in Heap Arena (Survivor)
        const buffer = try allocator.alloc(u8, stat.size);

        // 4. Read
        _ = try file.readAll(buffer);
        return buffer;
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

    // Read up to 4096 bytes from a connected client socket into a heap-allocated String.
    // Yields the fiber (via epoll) until data is available.
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

    /// Submits a task to the least-loaded scheduler from the global registry.
    /// Used by @pinned DO branches to pin execution to the best available thread.
    /// Errors if no scheduler is registered (i.e. running outside a scheduler context).
    pub fn spawnBest(trampoline_addr: usize, user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
        const sched = fp.global_registry.getLeastLoaded() orelse return error.NoSchedulerAvailable;
        try sched.submitSpawn(trampoline_addr, user_fn, args, config);
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
                    .slice => {
                        rt.heapAlloc().free(item);
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

            slots: std.ArrayListUnmanaged(Slot) = .{},

            pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
                self.slots.deinit(allocator);
            }

            /// Insert a value, returning a stable u64 handle.
            /// The handle encodes: [(generation: u32) << 32 | (index: u32)].
            /// Reuses dead slots when available; otherwise grows the array.
            pub fn insert(self: *Self, allocator: std.mem.Allocator, value: T) !u64 {
                // Linear scan for a dead slot to reuse
                for (self.slots.items, 0..) |*slot, i| {
                    if (!slot.alive) {
                        const gen = slot.generation;
                        slot.* = .{ .generation = gen, .alive = true, .value = value };
                        return (@as(u64, gen) << 32) | @as(u64, @intCast(i));
                    }
                }
                // No free slot: grow
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

/// Module-level spawnBest: submits a task to the least-loaded scheduler
/// from the global registry. Used by @pinned DO branches.
/// Errors if no scheduler is registered (outside a scheduler context).
pub fn spawnBest(trampoline_addr: usize, user_fn: TaskFn, args: ?*anyopaque, config: fp.TaskConfig) !void {
    const sched = fp.global_registry.getLeastLoaded() orelse return error.NoSchedulerAvailable;
    try sched.submitSpawn(trampoline_addr, user_fn, args, config);
}


