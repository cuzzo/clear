const std = @import("std");
const compat = @import("compat");
const fp = @import("../runtime/scheduler.zig");
const Task = @import("../runtime/queues.zig").Task;

pub fn bind(comptime deps: type) type {
    return struct {
        const WaitGroup = fp.WaitGroup;

        fn cleanup(comptime T: type, alloc: std.mem.Allocator, cptr: *const T) void {
            deps.cleanup(T, alloc, cptr);
        }

        fn needsCleanup(comptime T: type) bool {
            return deps.needsCleanup(T);
        }

        fn refInnerType(comptime T: type) ?type {
            return deps.refInnerType(T);
        }

        fn releaseOne(comptime T: type, alloc: std.mem.Allocator, value: T) void {
            deps.releaseOne(T, alloc, value);
        }

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
                    cleanup(V, self.alloc, val_ptr);
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
                    cleanup(V, self.alloc, &val);
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
                    cleanup(V, self.alloc, entry.value_ptr);
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
    /// align(64): each Locked(T) occupies at least one full cache line, preventing
    /// false sharing when multiple Locked values are heap-allocated adjacently.
    pub fn Locked(comptime T: type) type {
        return struct {
            mutex: compat.Mutex align(64) = .{},
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
        return compat.RwLocked(T);
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
                items: std.ArrayListUnmanaged(T) = .empty,
                wg: WaitGroup = undefined,
                err: ?anyerror = null, // terminal error from generator fiber
            };

            inner: *Inner,
            alloc: std.mem.Allocator,
            head: usize = 0,

            /// Allocate an Inner on the heap, initialize the WaitGroup, and return the Stream handle.
            pub fn spawnNew(alloc: std.mem.Allocator, sched: *fp.Scheduler) !Self {
                const inner = try alloc.create(Inner);
                inner.* = .{ .items = .empty, .wg = WaitGroup.init(sched) };
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
            /// Takes ownership of val: if the stream is closed, frees val before returning
            /// StreamClosed so callers that pre-allocate (e.g. string dupe) don't leak.
            pub fn push(self: *Self, val: T) error{StreamClosed}!void {
                const inner = self.inner;

                while (true) {
                    if (inner.closed) {
                        cleanup(T, self.alloc, &val);
                        return error.StreamClosed;
                    }

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
                    if (inner.closed) {
                        inner.lock.store(0, .release);
                        cleanup(T, self.alloc, &val);
                        return error.StreamClosed;
                    }
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
            /// For string streams (T = []const u8), drains and frees unconsumed buffered items
            /// before signaling the producer, preventing leaks on early consumer exit.
            pub fn deinit(self: *Self) void {
                const inner = self.inner;
                while (inner.lock.swap(1, .acquire) == 1) std.Thread.yield() catch {};
                inner.closed = true;

                // Drain and free unconsumed items. Read head under the lock so we capture
                // exactly the items committed before closed=true; producer cannot add more.
                if (comptime (T == []const u8 or T == []u8)) {
                    const h = inner.head.load(.acquire);
                    const t = inner.tail.load(.acquire);
                    var i: u32 = t;
                    while (i != h) : (i +%= 1) {
                        const item = inner.buf[i & MASK];
                        if (item.len > 0) self.alloc.free(item);
                    }
                    // Mark buffer as empty so destroy(stream_inner) in the generator fiber
                    // cannot double-free (the generator exits cleanly without touching buf).
                    inner.tail.store(h, .release);
                }

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

            /// Cleanup all fields of a struct value using cleanup.
            fn deinitFields(value: *T, alloc: std.mem.Allocator) void {
                cleanup(T, alloc, value);
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

            shards: [N]std.ArrayListUnmanaged(T) = [_]std.ArrayListUnmanaged(T){.empty} ** N,
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
            const root = @import("root");

            const Shard = struct {
                map: Map = .{},
                _pad: [56]u8 = undefined, // cache-line padding
            };

            shards: [N]Shard = [_]Shard{.{}} ** N,
            owners: [N]?*fp.Scheduler = [_]?*fp.Scheduler{null} ** N,
            ownership_init: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

            inline fn noteCtxCreated(kind: u8, shard: usize) void {
                if (@hasDecl(root, "partitionedMapTestCtxCreated")) root.partitionedMapTestCtxCreated(kind, shard);
            }

            inline fn noteCtxDestroyed(kind: u8, shard: usize) void {
                if (@hasDecl(root, "partitionedMapTestCtxDestroyed")) root.partitionedMapTestCtxDestroyed(kind, shard);
            }

            inline fn nextOpId(kind: u8, shard: usize) u64 {
                if (@hasDecl(root, "partitionedMapTestNextOpId")) return root.partitionedMapTestNextOpId(kind, shard);
                return 0;
            }

            inline fn noteEvent(kind: u8, stage: u8, shard: usize, op_id: u64, ctx_ptr: usize, key_ptr: usize) void {
                if (@hasDecl(root, "partitionedMapTestNoteEvent"))
                    root.partitionedMapTestNoteEvent(kind, stage, shard, op_id, ctx_ptr, key_ptr);
            }

            inline fn delayCtxDestroy() bool {
                return deps.partitionedMapDelayCtxDestroy();
            }

            inline fn delayGetCtxDestroy() bool {
                return @hasDecl(root, "partitioned_map_delay_get_ctx_destroy") and root.partitioned_map_delay_get_ctx_destroy;
            }

            inline fn delayRemoveCtxDestroy() bool {
                return @hasDecl(root, "partitioned_map_delay_remove_ctx_destroy") and root.partitioned_map_delay_remove_ctx_destroy;
            }

            inline fn delayKeyFree() bool {
                return @hasDecl(root, "partitioned_map_delay_key_free") and root.partitioned_map_delay_key_free;
            }

            inline fn delayCompletionDestroy() bool {
                return @hasDecl(root, "partitioned_map_delay_completion_destroy") and root.partitioned_map_delay_completion_destroy;
            }

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
                map: *Self, shard: usize, key: []const u8, op_id: u64, result: ?V = null,
                done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
                fn run(raw: *anyopaque) void {
                    const c: *@This() = @ptrCast(@alignCast(raw));
                    noteEvent(1, 2, c.shard, c.op_id, @intFromPtr(c), @intFromPtr(c.key.ptr));
                    c.result = c.map.shards[c.shard].map.get(c.key);
                    noteEvent(1, 3, c.shard, c.op_id, @intFromPtr(c), @intFromPtr(c.key.ptr));
                    c.done.store(true, .release);
                }
            };
            const RemoveCtx = struct {
                map: *Self, shard: usize, key: []const u8, op_id: u64,
                done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
                fn run(raw: *anyopaque) void {
                    const c: *@This() = @ptrCast(@alignCast(raw));
                    noteEvent(2, 2, c.shard, c.op_id, @intFromPtr(c), @intFromPtr(c.key.ptr));
                    if (c.map.shards[c.shard].map.fetchRemove(c.key)) |kv| {
                        remote_alloc.free(kv.key);
                        var val = kv.value;
                        cleanup(V, remote_alloc, &val);
                    }
                    noteEvent(2, 3, c.shard, c.op_id, @intFromPtr(c), @intFromPtr(c.key.ptr));
                    c.done.store(true, .release);
                }
            };

            // Send a RemoteCall via SPSC and wait for completion.
            // Drains our own channels + yields fiber while waiting.
            fn sendAndWait(
                target: *fp.Scheduler,
                func_ptr: *const fn (*anyopaque) void,
                ctx_ptr: *anyopaque,
                done_flag: *std.atomic.Value(bool),
                kind: u8,
                shard: usize,
                op_id: u64,
                key_ptr: usize,
            ) void {
                if (target == fp.active_scheduler) {
                    // LOCAL: target is our own scheduler — call directly, no SPSC.
                    // This avoids context-switch overhead for self-sends and keeps
                    // the stack shallow (no drainChannels in the call chain).
                    func_ptr(ctx_ptr);
                    return;
                }
                // REMOTE: send via SPSC channel and block on a WaitGroup. This
                // gives the scheduler an explicit wake/resume edge instead of
                // relying on yield-polling around a stack-local done flag.
                const sender_idx = fp.active_scheduler.index;
                std.debug.assert(sender_idx < target.channels.len);
                const ring = target.ensureChannel(sender_idx) catch @panic("SPSC channel alloc failed");
                const completion = remote_alloc.create(fp.RemoteCompletion) catch @panic("RemoteCall completion alloc failed");
                completion.* = .{
                    .wg = fp.WaitGroup.init(fp.active_scheduler),
                    .finished = std.atomic.Value(bool).init(false),
                };
                completion.wg.add(1);
                const msg = fp.SpscMessage{
                    .tag = .RemoteCall,
                    .rc_func = @ptrCast(func_ptr),
                    .rc_ctx = ctx_ptr,
                    .rc_wg = @ptrCast(completion),
                };
                while (!ring.push(msg)) {
                    std.atomic.spinLoopHint();
                }
                _ = target.dirty_mask.fetchOr(@as(u64, 1) << @intCast(sender_idx), .seq_cst);
                target.event_fd.notify();
                completion.wg.wait();
                while (!completion.finished.load(.acquire)) std.atomic.spinLoopHint();
                std.debug.assert(done_flag.load(.acquire));
                if (delayCompletionDestroy()) fp.active_scheduler.coopYield();
                noteEvent(kind, 7, shard, op_id, 0, key_ptr);
                remote_alloc.destroy(completion);
            }

            // ONE path for every operation. No hot/cold split.
            // Always routes through the owning scheduler via SPSC.

            pub fn put(self: *Self, _: std.mem.Allocator, caller_alloc: std.mem.Allocator, key: []const u8, value: V) !void {
                self.ensureOwnership();
                const s = shardIndex(key);
                const safe_key = try remote_alloc.dupe(u8, key);
                const ctx = try remote_alloc.create(PutCtx);
                noteCtxCreated(0, s);
                ctx.* = .{ .map = self, .shard = s, .key = safe_key, .value = value };
                sendAndWait(self.owners[s].?, @ptrCast(&PutCtx.run), @ptrCast(ctx), &ctx.done, 0, s, 0, @intFromPtr(safe_key.ptr));
                const had_err = ctx.err;
                remote_alloc.destroy(ctx);
                noteCtxDestroyed(0, s);
                if (had_err) return error.OutOfMemory;
                // PutCtx.run dupes slice values with remote_alloc for thread safety.
                // Free the caller's copy since ownership has been transferred.
                if (comptime is_slice_value) caller_alloc.free(value);
            }

            pub fn get(self: *Self, key: []const u8) ?V {
                self.ensureOwnership();
                const s = shardIndex(key);
                const safe_key = remote_alloc.dupe(u8, key) catch return null;
                const ctx = remote_alloc.create(GetCtx) catch {
                    remote_alloc.free(safe_key);
                    return null;
                };
                const op_id = nextOpId(1, s);
                noteCtxCreated(1, s);
                ctx.* = .{ .map = self, .shard = s, .key = safe_key, .op_id = op_id };
                noteEvent(1, 0, s, op_id, @intFromPtr(ctx), @intFromPtr(safe_key.ptr));
                noteEvent(1, 1, s, op_id, @intFromPtr(ctx), @intFromPtr(safe_key.ptr));
                sendAndWait(self.owners[s].?, @ptrCast(&GetCtx.run), @ptrCast(ctx), &ctx.done, 1, s, op_id, @intFromPtr(safe_key.ptr));
                noteEvent(1, 4, s, op_id, @intFromPtr(ctx), @intFromPtr(safe_key.ptr));
                const result = ctx.result;
                if (!delayCtxDestroy()) {
                    if (delayGetCtxDestroy()) fp.active_scheduler.coopYield();
                    noteEvent(1, 5, s, op_id, @intFromPtr(ctx), @intFromPtr(safe_key.ptr));
                    remote_alloc.destroy(ctx);
                    noteCtxDestroyed(1, s);
                    if (delayKeyFree()) fp.active_scheduler.coopYield();
                    noteEvent(1, 6, s, op_id, 0, @intFromPtr(safe_key.ptr));
                    remote_alloc.free(safe_key);
                }
                return result;
            }

            pub fn contains(self: *Self, key: []const u8) bool {
                self.ensureOwnership();
                const s = shardIndex(key);
                const safe_key = remote_alloc.dupe(u8, key) catch return false;
                const ctx = remote_alloc.create(GetCtx) catch {
                    remote_alloc.free(safe_key);
                    return false;
                };
                const op_id = nextOpId(1, s);
                noteCtxCreated(1, s);
                ctx.* = .{ .map = self, .shard = s, .key = safe_key, .op_id = op_id };
                noteEvent(1, 0, s, op_id, @intFromPtr(ctx), @intFromPtr(safe_key.ptr));
                noteEvent(1, 1, s, op_id, @intFromPtr(ctx), @intFromPtr(safe_key.ptr));
                sendAndWait(self.owners[s].?, @ptrCast(&GetCtx.run), @ptrCast(ctx), &ctx.done, 1, s, op_id, @intFromPtr(safe_key.ptr));
                noteEvent(1, 4, s, op_id, @intFromPtr(ctx), @intFromPtr(safe_key.ptr));
                const found = ctx.result != null;
                if (!delayCtxDestroy()) {
                    if (delayGetCtxDestroy()) fp.active_scheduler.coopYield();
                    noteEvent(1, 5, s, op_id, @intFromPtr(ctx), @intFromPtr(safe_key.ptr));
                    remote_alloc.destroy(ctx);
                    noteCtxDestroyed(1, s);
                    if (delayKeyFree()) fp.active_scheduler.coopYield();
                    noteEvent(1, 6, s, op_id, 0, @intFromPtr(safe_key.ptr));
                    remote_alloc.free(safe_key);
                }
                return found;
            }

            pub fn remove(self: *Self, _: std.mem.Allocator, key: []const u8) void {
                self.ensureOwnership();
                const s = shardIndex(key);
                const safe_key = remote_alloc.dupe(u8, key) catch return;
                const ctx = remote_alloc.create(RemoveCtx) catch {
                    remote_alloc.free(safe_key);
                    return;
                };
                const op_id = nextOpId(2, s);
                noteCtxCreated(2, s);
                ctx.* = .{ .map = self, .shard = s, .key = safe_key, .op_id = op_id };
                noteEvent(2, 0, s, op_id, @intFromPtr(ctx), @intFromPtr(safe_key.ptr));
                noteEvent(2, 1, s, op_id, @intFromPtr(ctx), @intFromPtr(safe_key.ptr));
                sendAndWait(self.owners[s].?, @ptrCast(&RemoveCtx.run), @ptrCast(ctx), &ctx.done, 2, s, op_id, @intFromPtr(safe_key.ptr));
                noteEvent(2, 4, s, op_id, @intFromPtr(ctx), @intFromPtr(safe_key.ptr));
                if (!delayCtxDestroy()) {
                    if (delayRemoveCtxDestroy()) fp.active_scheduler.coopYield();
                    noteEvent(2, 5, s, op_id, @intFromPtr(ctx), @intFromPtr(safe_key.ptr));
                    remote_alloc.destroy(ctx);
                    noteCtxDestroyed(2, s);
                    if (delayKeyFree()) fp.active_scheduler.coopYield();
                    noteEvent(2, 6, s, op_id, 0, @intFromPtr(safe_key.ptr));
                    remote_alloc.free(safe_key);
                }
            }

            // ── Direct shard access (no hash, no routing) ──
            // Used by the SHARD pipeline: the fiber is already pinned to the
            // owning scheduler, and the shard index is known from routing.
            // Zero overhead: no shardIndex(), no sendAndWait(), no key dupe.

            pub fn putDirect(self: *Self, shard: usize, _: std.mem.Allocator, key: []const u8, value: V) !void {
                const gop = try self.shards[shard].map.getOrPut(remote_alloc, key);
                if (gop.found_existing) {
                    cleanup(V, remote_alloc, gop.value_ptr);
                } else {
                    gop.key_ptr.* = try remote_alloc.dupe(u8, key);
                }
                gop.value_ptr.* = if (comptime is_slice_value)
                    try remote_alloc.dupe(@typeInfo(V).pointer.child, value)
                else
                    value;
            }

            /// Insert using a pre-computed hash. The hash MUST have been computed
            /// by shardIndexWithHash (Wyhash) — the same function StringHashMap uses.
            /// Skips rehashing the key, saving ~50% of hash work in SHARD pipelines.
            pub fn putPrehashed(self: *Self, shard: usize, precomputed_hash: u64, _: std.mem.Allocator, key: []const u8, value: V) !void {
                const owned_key = try remote_alloc.dupe(u8, key);
                const safe_val = if (comptime is_slice_value)
                    try remote_alloc.dupe(@typeInfo(V).pointer.child, value)
                else
                    value;
                const PrehashedCtx = struct {
                    h: u64,
                    pub fn hash(self_ctx: @This(), _: []const u8) u64 { return self_ctx.h; }
                    pub fn eql(_: @This(), a: []const u8, b: []const u8) bool { return std.mem.eql(u8, a, b); }
                };
                const gop = self.shards[shard].map.getOrPutAdapted(remote_alloc, owned_key, PrehashedCtx{ .h = precomputed_hash }) catch |e| {
                    remote_alloc.free(owned_key);
                    if (comptime is_slice_value) remote_alloc.free(safe_val);
                    return e;
                };
                if (gop.found_existing) {
                    remote_alloc.free(owned_key);
                    if (comptime is_slice_value) {
                        const old = gop.value_ptr.*;
                        remote_alloc.free(old);
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

            pub fn removeDirect(self: *Self, shard: usize, _: std.mem.Allocator, key: []const u8) void {
                if (self.shards[shard].map.fetchRemove(key)) |kv| {
                    remote_alloc.free(kv.key);
                    if (is_slice_value) remote_alloc.free(kv.value);
                }
            }

            pub fn count(self: *Self) i64 {
                var nc: i64 = 0;
                for (&self.shards) |*shard| nc += @intCast(shard.map.count());
                return nc;
            }

            pub fn keys(self: *Self, alloc: std.mem.Allocator) !std.ArrayListUnmanaged([]const u8) {
                var list: std.ArrayListUnmanaged([]const u8) = .empty;
                for (&self.shards) |*shard| {
                    var it = shard.map.keyIterator();
                    while (it.next()) |k| try list.append(alloc, k.*);
                }
                return list;
            }

            pub fn values(self: *Self, alloc: std.mem.Allocator) !std.ArrayListUnmanaged(V) {
                var list: std.ArrayListUnmanaged(V) = .empty;
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
                        cleanup(V, remote_alloc, entry.value_ptr);
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
                lock: compat.RwLock = .{},
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
                    cleanup(V, self.alloc, val_ptr);
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
                    cleanup(V, self.alloc, &val);
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
                var list: std.ArrayListUnmanaged([]const u8) = .empty;
                for (&self.shards) |*shard| {
                    shard.lock.lockShared();
                    defer shard.lock.unlockShared();
                    var it = shard.map.keyIterator();
                    while (it.next()) |k| try list.append(alloc, k.*);
                }
                return list;
            }

            pub fn values(self: *Self, alloc: std.mem.Allocator) !std.ArrayListUnmanaged(V) {
                var list: std.ArrayListUnmanaged(V) = .empty;
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
                        cleanup(V, self.alloc, entry.value_ptr);
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
                lock: compat.Mutex = .{},
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
                    cleanup(V, self.alloc, val_ptr);
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
                    cleanup(V, self.alloc, &val);
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
                var list: std.ArrayListUnmanaged([]const u8) = .empty;
                for (&self.shards) |*shard| {
                    shard.lock.lock();
                    defer shard.lock.unlock();
                    var it = shard.map.keyIterator();
                    while (it.next()) |k| try list.append(alloc, k.*);
                }
                return list;
            }

            pub fn values(self: *Self, alloc: std.mem.Allocator) !std.ArrayListUnmanaged(V) {
                var list: std.ArrayListUnmanaged(V) = .empty;
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
                        cleanup(V, self.alloc, entry.value_ptr);
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
                lock: compat.Mutex = .{},
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
    };
}
