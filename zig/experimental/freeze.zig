//! freeze.zig -- Compact a struct tree into a single contiguous heap allocation.
//!
//! freeze(T, alloc, ptr) walks every pointer / slice field of T recursively
//! and packs the whole object tree into one flat buffer.  Interior pointers are
//! rewritten to point into the new buffer.  The caller frees the buffer via
//! Frozen(T).deinit().
//!
//! v0.1 supported field types
//!   - Primitives (i64, u8, bool, f64, …)          just copied
//!   - []const u8 / []u8  (strings)                bytes inlined, ptr patched
//!   - []T where T is a supported struct            array inlined, ptrs patched
//!   - ?*T where T is a supported struct            child inlined if non-null
//!   - *T                                           child inlined
//!   - Nested structs (no pointer fields of their own need no special handling)
//!
//! NOT supported (and will be silently skipped / left as stale pointers):
//!   - HashMap, Set, Pool  (non-relocatable internal structure)
//!   - Cycles / shared nodes in non-recursive types (no visited-set overhead)
//!   - Function pointers
//!
//! Cycle detection:
//!   freeze() returns FreezeError!Frozen(T) for types where isRecursive(T) is true,
//!   and Allocator.Error!Frozen(T) for non-recursive types.  For recursive types a
//!   DFS in-progress set is maintained; error.Cycle is returned if a cycle is found.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ─────────────────────────────────────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────────────────────────────────────

/// Owns the single contiguous buffer that holds the frozen value and all its
/// transitively-pointed-to data.
pub fn Frozen(comptime T: type) type {
    return struct {
        const Self = @This();
        _buf: []align(@alignOf(T)) u8,

        /// Pointer to the root value.  Valid for the lifetime of Self.
        pub fn root(self: *const Self) *const T {
            return @ptrCast(self._buf.ptr);
        }

        pub fn deinit(self: Self, alloc: Allocator) void {
            alloc.free(self._buf);
        }
    };
}

/// Error set for recursive-type freeze calls (adds error.Cycle to OOM).
pub const FreezeError = std.mem.Allocator.Error || error{Cycle};

/// Returns true if T's type graph contains any pointer that refers back to T.
/// When true, freeze() uses a DFS in-progress set and returns FreezeError!Frozen(T).
pub fn isRecursive(comptime T: type) bool {
    return typeRefersTo(T, T);
}

fn typeRefersTo(comptime Root: type, comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct" => |si| {
            inline for (si.fields) |f| {
                if (fieldRefersTo(Root, f.type)) return true;
            }
            return false;
        },
        .@"union" => |ui| {
            inline for (ui.fields) |f| {
                if (fieldRefersTo(Root, f.type)) return true;
            }
            return false;
        },
        else => return false,
    }
}

fn fieldRefersTo(comptime Root: type, comptime FT: type) bool {
    switch (@typeInfo(FT)) {
        .pointer => |pi| return pi.child == Root or fieldRefersTo(Root, pi.child),
        .optional => |oi| return fieldRefersTo(Root, oi.child),
        .@"struct" => {
            if (FT == Root) return false; // guard: don't re-enter Root's own fields
            return typeRefersTo(Root, FT);
        },
        .@"union" => {
            if (FT == Root) return false;
            return typeRefersTo(Root, FT);
        },
        else => return false,
    }
}

/// Freeze `val` into a single heap allocation.
/// - Non-recursive T: returns Allocator.Error!Frozen(T)  (no cycle detection overhead)
/// - Recursive T:     returns FreezeError!Frozen(T)       (DFS in-progress set; error.Cycle on cycle)
pub fn freeze(comptime T: type, alloc: Allocator, val: *const T)
    if (isRecursive(T)) FreezeError!Frozen(T) else std.mem.Allocator.Error!Frozen(T)
{
    if (comptime isRecursive(T)) {
        var in_progress = std.AutoHashMap(usize, void).init(alloc);
        defer in_progress.deinit();

        var size: usize = 0;
        try measureNodeCyclic(T, val, &size, &in_progress);

        const buf = try alloc.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(@alignOf(T)), size);
        errdefer alloc.free(buf);

        var cursor: usize = 0;
        copyNode(T, val, buf, &cursor);
        std.debug.assert(cursor == size);
        return Frozen(T){ ._buf = buf };
    } else {
        var size: usize = 0;
        measureNode(T, val, &size);

        const buf = try alloc.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(@alignOf(T)), size);
        errdefer alloc.free(buf);

        var cursor: usize = 0;
        copyNode(T, val, buf, &cursor);
        std.debug.assert(cursor == size);
        return Frozen(T){ ._buf = buf };
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Measurement pass  (advances cursor without writing)
// ─────────────────────────────────────────────────────────────────────────────

/// Account for the bytes needed to hold one value of type T plus all its
/// transitively-pointed-to data.
fn measureNode(comptime T: type, val: *const T, cursor: *usize) void {
    cursor.* = alignUp(cursor.*, @alignOf(T));
    cursor.* += @sizeOf(T);
    measurePointees(T, val, cursor);
}

fn measurePointees(comptime T: type, val: *const T, cursor: *usize) void {
    switch (@typeInfo(T)) {
        .@"struct" => |si| {
            inline for (si.fields) |f| {
                measureField(f.type, &@field(val.*, f.name), cursor);
            }
        },
        .@"union" => |ui| {
            if (ui.tag_type != null) {
                const tag = std.meta.activeTag(val.*);
                inline for (ui.fields) |f| {
                    if (tag == @field(std.meta.Tag(T), f.name)) {
                        measureField(f.type, &@field(val.*, f.name), cursor);
                    }
                }
            }
        },
        else => {},
    }
}

fn measureField(comptime FT: type, val: *const FT, cursor: *usize) void {
    switch (@typeInfo(FT)) {

        .pointer => |pi| switch (pi.size) {
            .slice => {
                if (pi.child == u8) {
                    // []u8 / []const u8  — inline bytes, no alignment needed (u8)
                    cursor.* += val.*.len;
                } else {
                    // []Child  — inline the array then recurse into each element.
                    // Use measureField (not measurePointees) so that pointer-typed
                    // children like []*T and [][]const u8 are also followed.
                    cursor.* = alignUp(cursor.*, @alignOf(pi.child));
                    cursor.* += val.*.len * @sizeOf(pi.child);
                    for (val.*) |*elem| {
                        measureField(pi.child, elem, cursor);
                    }
                }
            },
            .one => measureNode(pi.child, val.*, cursor),
            else => {},
        },

        .optional => |oi| {
            switch (@typeInfo(oi.child)) {
                .pointer => |pi| switch (pi.size) {
                    .one => {
                        if (val.* != null) measureNode(pi.child, val.*.?, cursor);
                    },
                    else => {},
                },
                else => {},
            }
        },

        // Inline nested struct/union: flat bytes covered by parent's @sizeOf,
        // but pointer fields within the active variant still need measuring.
        .@"struct" => measurePointees(FT, val, cursor),
        .@"union" => measurePointees(FT, val, cursor),
        else => {},
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Cyclic measurement pass  (same as above but with DFS in-progress cycle check)
// ─────────────────────────────────────────────────────────────────────────────

const InProgress = std.AutoHashMap(usize, void);

fn measureNodeCyclic(comptime T: type, val: *const T, cursor: *usize, ip: *InProgress) FreezeError!void {
    const addr = @intFromPtr(val);
    if (ip.contains(addr)) return error.Cycle;
    try ip.put(addr, {});
    defer _ = ip.remove(addr);
    cursor.* = alignUp(cursor.*, @alignOf(T));
    cursor.* += @sizeOf(T);
    try measurePointeesCyclic(T, val, cursor, ip);
}

fn measurePointeesCyclic(comptime T: type, val: *const T, cursor: *usize, ip: *InProgress) FreezeError!void {
    switch (@typeInfo(T)) {
        .@"struct" => |si| {
            inline for (si.fields) |f| {
                try measureFieldCyclic(f.type, &@field(val.*, f.name), cursor, ip);
            }
        },
        .@"union" => |ui| {
            if (ui.tag_type != null) {
                const tag = std.meta.activeTag(val.*);
                inline for (ui.fields) |f| {
                    if (tag == @field(std.meta.Tag(T), f.name)) {
                        try measureFieldCyclic(f.type, &@field(val.*, f.name), cursor, ip);
                    }
                }
            }
        },
        else => {},
    }
}

fn measureFieldCyclic(comptime FT: type, val: *const FT, cursor: *usize, ip: *InProgress) FreezeError!void {
    switch (@typeInfo(FT)) {
        .pointer => |pi| switch (pi.size) {
            .slice => {
                if (pi.child == u8) {
                    cursor.* += val.*.len;
                } else {
                    cursor.* = alignUp(cursor.*, @alignOf(pi.child));
                    cursor.* += val.*.len * @sizeOf(pi.child);
                    for (val.*) |*elem| {
                        try measureFieldCyclic(pi.child, elem, cursor, ip);
                    }
                }
            },
            .one => try measureNodeCyclic(pi.child, val.*, cursor, ip),
            else => {},
        },
        .optional => |oi| {
            switch (@typeInfo(oi.child)) {
                .pointer => |pi| switch (pi.size) {
                    .one => {
                        if (val.* != null) try measureNodeCyclic(pi.child, val.*.?, cursor, ip);
                    },
                    else => {},
                },
                else => {},
            }
        },
        .@"struct" => try measurePointeesCyclic(FT, val, cursor, ip),
        .@"union"  => try measurePointeesCyclic(FT, val, cursor, ip),
        else => {},
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Copy pass  (writes bytes and patches pointers)
// ─────────────────────────────────────────────────────────────────────────────

/// Write one value of type T at cursor, then recurse into its pointees.
/// Pointer fields in the written copy are patched to point into buf.
fn copyNode(comptime T: type, val: *const T, buf: []u8, cursor: *usize) void {
    cursor.* = alignUp(cursor.*, @alignOf(T));
    const my_off = cursor.*;
    cursor.* += @sizeOf(T);

    // Flat copy (includes stale pointer bytes — patched below)
    @memcpy(buf[my_off..][0..@sizeOf(T)], @as([*]const u8, @ptrCast(val))[0..@sizeOf(T)]);

    const dest: *T = @ptrCast(@alignCast(buf[my_off..].ptr));
    patchPointees(T, val, dest, buf, cursor);
}

fn patchPointees(comptime T: type, src: *const T, dest: *T, buf: []u8, cursor: *usize) void {
    switch (@typeInfo(T)) {
        .@"struct" => |si| {
            inline for (si.fields) |f| {
                patchField(
                    f.type,
                    &@field(src.*, f.name),
                    &@field(dest.*, f.name),
                    buf,
                    cursor,
                );
            }
        },
        .@"union" => |ui| {
            if (ui.tag_type != null) {
                const tag = std.meta.activeTag(src.*);
                inline for (ui.fields) |f| {
                    if (tag == @field(std.meta.Tag(T), f.name)) {
                        patchField(
                            f.type,
                            &@field(src.*, f.name),
                            &@field(dest.*, f.name),
                            buf,
                            cursor,
                        );
                    }
                }
            }
        },
        else => {},
    }
}

fn patchField(
    comptime FT: type,
    src_val: *const FT,
    dest_field: *FT,
    buf: []u8,
    cursor: *usize,
) void {
    switch (@typeInfo(FT)) {

        .pointer => |pi| switch (pi.size) {
            .slice => {
                const len = src_val.*.len;
                if (len == 0) return;

                if (pi.child == u8) {
                    // String: copy bytes, patch .ptr
                    const off = cursor.*;
                    @memcpy(buf[off..][0..len], src_val.*);
                    cursor.* += len;
                    dest_field.* = buf[off..][0..len];
                } else {
                    // Slice of structs: copy flat array, patch each element
                    cursor.* = alignUp(cursor.*, @alignOf(pi.child));
                    const off = cursor.*;
                    const bytes = len * @sizeOf(pi.child);
                    @memcpy(buf[off..][0..bytes], @as([*]const u8, @ptrCast(src_val.*.ptr))[0..bytes]);
                    cursor.* += bytes;
                    const new_arr: [*]pi.child = @ptrCast(@alignCast(buf[off..].ptr));
                    dest_field.* = new_arr[0..len];
                    for (0..len) |i| {
                        // patchField (not patchPointees) handles pointer-typed children
                        // like []*T and [][]const u8, not just inline struct elements.
                        patchField(pi.child, &src_val.*[i], &new_arr[i], buf, cursor);
                    }
                }
            },

            .one => {
                // The child offset is wherever copy will land after alignment.
                const child_off = alignUp(cursor.*, @alignOf(pi.child));
                copyNode(pi.child, src_val.*, buf, cursor);
                dest_field.* = @ptrCast(@alignCast(buf[child_off..].ptr));
            },

            else => {},
        },

        .optional => |oi| {
            switch (@typeInfo(oi.child)) {
                .pointer => |pi| switch (pi.size) {
                    .one => {
                        if (src_val.* == null) {
                            dest_field.* = null;
                        } else {
                            const child_off = alignUp(cursor.*, @alignOf(pi.child));
                            copyNode(pi.child, src_val.*.?, buf, cursor);
                            dest_field.* = @ptrCast(@alignCast(buf[child_off..].ptr));
                        }
                    },
                    else => {},
                },
                else => {},
            }
        },

        // Inline nested struct/union: flat bytes already copied by parent's memcpy,
        // but pointer fields in the active variant still need relocating.
        .@"struct" => patchPointees(FT, src_val, dest_field, buf, cursor),
        .@"union" => patchPointees(FT, src_val, dest_field, buf, cursor),
        else => {},
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Utility
// ─────────────────────────────────────────────────────────────────────────────

fn alignUp(n: usize, alignment: usize) usize {
    std.debug.assert(alignment > 0 and std.math.isPowerOfTwo(alignment));
    return (n + alignment - 1) & ~(alignment - 1);
}

// ─────────────────────────────────────────────────────────────────────────────
// Correctness tests
// ─────────────────────────────────────────────────────────────────────────────

test "freeze: flat struct with string field" {
    const Item = struct { name: []const u8, value: i64 };
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const name = try alloc.dupe(u8, "hello");
    defer alloc.free(name);
    const item = Item{ .name = name, .value = 42 };

    const frozen = try freeze(Item, alloc, &item);
    defer frozen.deinit(alloc);

    const r = frozen.root();
    try std.testing.expectEqualStrings("hello", r.name);
    try std.testing.expectEqual(@as(i64, 42), r.value);

    // Pointer must live inside the buffer
    try std.testing.expect(@intFromPtr(r.name.ptr) >= @intFromPtr(frozen._buf.ptr));
    try std.testing.expect(@intFromPtr(r.name.ptr) < @intFromPtr(frozen._buf.ptr) + frozen._buf.len);
}

test "freeze: binary tree with string keys" {
    const Node = struct {
        key: []const u8,
        value: i64,
        left: ?*@This(),
        right: ?*@This(),
    };

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Build: root("b", 2) -> left("a", 1), right("c", 3)
    const left = try alloc.create(Node);
    left.* = .{ .key = try alloc.dupe(u8, "a"), .value = 1, .left = null, .right = null };
    const right = try alloc.create(Node);
    right.* = .{ .key = try alloc.dupe(u8, "c"), .value = 3, .left = null, .right = null };
    const root_node = try alloc.create(Node);
    root_node.* = .{ .key = try alloc.dupe(u8, "b"), .value = 2, .left = left, .right = right };

    const frozen = try freeze(Node, alloc, root_node);
    defer frozen.deinit(alloc);

    // Free original tree
    alloc.free(left.key); alloc.destroy(left);
    alloc.free(right.key); alloc.destroy(right);
    alloc.free(root_node.key); alloc.destroy(root_node);

    const r = frozen.root();
    try std.testing.expectEqualStrings("b", r.key);
    try std.testing.expectEqual(@as(i64, 2), r.value);
    try std.testing.expect(r.left != null);
    try std.testing.expect(r.right != null);
    try std.testing.expectEqualStrings("a", r.left.?.key);
    try std.testing.expectEqualStrings("c", r.right.?.key);
    try std.testing.expectEqual(@as(i64, 1), r.left.?.value);
    try std.testing.expectEqual(@as(i64, 3), r.right.?.value);
    try std.testing.expect(r.left.?.left == null);
    try std.testing.expect(r.right.?.right == null);

    // All pointers must live inside the buffer
    const base = @intFromPtr(frozen._buf.ptr);
    const end = base + frozen._buf.len;
    try std.testing.expect(@intFromPtr(r.key.ptr) >= base and @intFromPtr(r.key.ptr) < end);
    try std.testing.expect(@intFromPtr(r.left.?) >= base and @intFromPtr(r.left.?) < end);
    try std.testing.expect(@intFromPtr(r.right.?) >= base and @intFromPtr(r.right.?) < end);
}

test "freeze: [][]const u8 — inner strings relocated into buffer" {
    const Doc = struct { title: []const u8, tags: [][]const u8 };
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const tag0 = try alloc.dupe(u8, "zig");
    const tag1 = try alloc.dupe(u8, "systems");
    const tags = try alloc.dupe([]const u8, &.{ tag0, tag1 });
    const title = try alloc.dupe(u8, "Frozen Docs");

    const doc = Doc{ .title = title, .tags = tags };
    const frozen = try freeze(Doc, alloc, &doc);

    // Free originals before touching frozen — proves there are no stale pointers.
    alloc.free(title);
    alloc.free(tag0);
    alloc.free(tag1);
    alloc.free(tags);

    defer frozen.deinit(alloc);

    const r = frozen.root();
    const base = @intFromPtr(frozen._buf.ptr);
    const end  = base + frozen._buf.len;

    try std.testing.expectEqualStrings("Frozen Docs", r.title);
    try std.testing.expect(@intFromPtr(r.title.ptr) >= base and @intFromPtr(r.title.ptr) < end);

    try std.testing.expectEqual(@as(usize, 2), r.tags.len);
    try std.testing.expectEqualStrings("zig",     r.tags[0]);
    try std.testing.expectEqualStrings("systems", r.tags[1]);
    // Each inner string must also live inside the buffer.
    try std.testing.expect(@intFromPtr(r.tags[0].ptr) >= base and @intFromPtr(r.tags[0].ptr) < end);
    try std.testing.expect(@intFromPtr(r.tags[1].ptr) >= base and @intFromPtr(r.tags[1].ptr) < end);
    // The tags slice header itself must live inside the buffer.
    try std.testing.expect(@intFromPtr(r.tags.ptr) >= base and @intFromPtr(r.tags.ptr) < end);
}

test "freeze: nested inline struct with string field" {
    const Meta = struct { label: []const u8, weight: i64 };
    const Item = struct { meta: Meta, value: i64 };
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const label = try alloc.dupe(u8, "alpha");
    const item = Item{ .meta = .{ .label = label, .weight = 7 }, .value = 99 };
    const frozen = try freeze(Item, alloc, &item);
    alloc.free(label);  // free before reading frozen to prove no stale ptr
    defer frozen.deinit(alloc);

    const r = frozen.root();
    const base = @intFromPtr(frozen._buf.ptr);
    const end  = base + frozen._buf.len;

    try std.testing.expectEqualStrings("alpha", r.meta.label);
    try std.testing.expectEqual(@as(i64, 7),  r.meta.weight);
    try std.testing.expectEqual(@as(i64, 99), r.value);
    try std.testing.expect(@intFromPtr(r.meta.label.ptr) >= base and @intFromPtr(r.meta.label.ptr) < end);
}

test "freeze: []*T — slice of pointers to structs" {
    const Child = struct { name: []const u8, val: i64 };
    const Parent = struct { children: []*Child };
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const c0 = try alloc.create(Child); c0.* = .{ .name = try alloc.dupe(u8, "first"),  .val = 1 };
    const c1 = try alloc.create(Child); c1.* = .{ .name = try alloc.dupe(u8, "second"), .val = 2 };
    const ptrs = try alloc.dupe(*Child, &.{ c0, c1 });
    const parent = Parent{ .children = ptrs };

    const frozen = try freeze(Parent, alloc, &parent);

    // Free originals before reading frozen.
    alloc.free(c0.name); alloc.destroy(c0);
    alloc.free(c1.name); alloc.destroy(c1);
    alloc.free(ptrs);

    defer frozen.deinit(alloc);

    const r = frozen.root();
    const base = @intFromPtr(frozen._buf.ptr);
    const end  = base + frozen._buf.len;

    try std.testing.expectEqual(@as(usize, 2), r.children.len);
    try std.testing.expectEqualStrings("first",  r.children[0].name);
    try std.testing.expectEqualStrings("second", r.children[1].name);
    try std.testing.expectEqual(@as(i64, 1), r.children[0].val);
    try std.testing.expectEqual(@as(i64, 2), r.children[1].val);
    // All pointers must live inside the buffer.
    try std.testing.expect(@intFromPtr(r.children.ptr)    >= base and @intFromPtr(r.children.ptr)    < end);
    try std.testing.expect(@intFromPtr(r.children[0])     >= base and @intFromPtr(r.children[0])     < end);
    try std.testing.expect(@intFromPtr(r.children[1])     >= base and @intFromPtr(r.children[1])     < end);
    try std.testing.expect(@intFromPtr(r.children[0].name.ptr) >= base and @intFromPtr(r.children[0].name.ptr) < end);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tagged union tests
// ─────────────────────────────────────────────────────────────────────────────

test "freeze: tagged union — string and integer variants" {
    const Val = union(enum) {
        num: i64,
        str: []const u8,
        flag: bool,
    };

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Numeric variant: no pointer, just copied.
    {
        const v = Val{ .num = 42 };
        const frozen = try freeze(Val, alloc, &v);
        defer frozen.deinit(alloc);
        try std.testing.expectEqual(Val{ .num = 42 }, frozen.root().*);
    }

    // String variant: string bytes must be inlined into the buffer.
    {
        const s = try alloc.dupe(u8, "hello union");
        const v = Val{ .str = s };
        const frozen = try freeze(Val, alloc, &v);
        alloc.free(s); // free before reading to prove no stale ptr
        defer frozen.deinit(alloc);

        const r = frozen.root();
        const base = @intFromPtr(frozen._buf.ptr);
        const end  = base + frozen._buf.len;
        try std.testing.expectEqualStrings("hello union", r.str);
        try std.testing.expect(@intFromPtr(r.str.ptr) >= base and @intFromPtr(r.str.ptr) < end);
    }
}

test "freeze: tagged union — recursive tree (Value-like)" {
    // Mirrors the minivm's Value union structure: a tagged union whose List
    // variant holds a slice of itself, and Str holds a heap string.
    const Expr = union(enum) {
        nil,
        int: i64,
        str: []const u8,
        list: []@This(),  // recursive: slice of self
    };

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Build: (+ "hello" 42)  represented as List[ Str("+"), Str("hello"), Int(42) ]
    const elems = try alloc.dupe(Expr, &[_]Expr{
        .{ .str = try alloc.dupe(u8, "+") },
        .{ .str = try alloc.dupe(u8, "hello") },
        .{ .int = 42 },
    });
    const root_expr = Expr{ .list = elems };

    const frozen = try freeze(Expr, alloc, &root_expr);

    // Free originals before reading to prove all pointers are intra-buffer.
    alloc.free(elems[0].str);
    alloc.free(elems[1].str);
    alloc.free(elems);

    defer frozen.deinit(alloc);

    const r = frozen.root();
    const base = @intFromPtr(frozen._buf.ptr);
    const end  = base + frozen._buf.len;

    // Root is a list of 3 elements.
    try std.testing.expect(r.* == .list);
    try std.testing.expectEqual(@as(usize, 3), r.list.len);

    // list slice lives in buffer.
    try std.testing.expect(@intFromPtr(r.list.ptr) >= base and @intFromPtr(r.list.ptr) < end);

    // First element: Str("+")
    try std.testing.expect(r.list[0] == .str);
    try std.testing.expectEqualStrings("+", r.list[0].str);
    try std.testing.expect(@intFromPtr(r.list[0].str.ptr) >= base and @intFromPtr(r.list[0].str.ptr) < end);

    // Second element: Str("hello")
    try std.testing.expect(r.list[1] == .str);
    try std.testing.expectEqualStrings("hello", r.list[1].str);

    // Third element: Int(42)
    try std.testing.expect(r.list[2] == .int);
    try std.testing.expectEqual(@as(i64, 42), r.list[2].int);
}

test "freeze: tagged union — nested list of lists" {
    const Expr = union(enum) {
        nil,
        int: i64,
        str: []const u8,
        list: []@This(),
    };

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Build: ((1 2) (3 4)) — a list containing two sub-lists.
    const inner0 = try alloc.dupe(Expr, &[_]Expr{ .{ .int = 1 }, .{ .int = 2 } });
    const inner1 = try alloc.dupe(Expr, &[_]Expr{ .{ .int = 3 }, .{ .int = 4 } });
    const outer  = try alloc.dupe(Expr, &[_]Expr{
        .{ .list = inner0 },
        .{ .list = inner1 },
    });
    const root_expr = Expr{ .list = outer };

    const frozen = try freeze(Expr, alloc, &root_expr);

    alloc.free(inner0);
    alloc.free(inner1);
    alloc.free(outer);

    defer frozen.deinit(alloc);

    const r = frozen.root();
    const base = @intFromPtr(frozen._buf.ptr);
    const end  = base + frozen._buf.len;

    try std.testing.expect(r.* == .list);
    try std.testing.expectEqual(@as(usize, 2), r.list.len);

    // Both sub-lists live in buffer.
    try std.testing.expect(r.list[0] == .list);
    try std.testing.expect(r.list[1] == .list);
    try std.testing.expect(@intFromPtr(r.list[0].list.ptr) >= base and @intFromPtr(r.list[0].list.ptr) < end);
    try std.testing.expect(@intFromPtr(r.list[1].list.ptr) >= base and @intFromPtr(r.list[1].list.ptr) < end);

    try std.testing.expectEqual(@as(i64, 1), r.list[0].list[0].int);
    try std.testing.expectEqual(@as(i64, 2), r.list[0].list[1].int);
    try std.testing.expectEqual(@as(i64, 3), r.list[1].list[0].int);
    try std.testing.expectEqual(@as(i64, 4), r.list[1].list[1].int);
}

test "freeze: union embedded in struct" {
    const Val = union(enum) { num: i64, str: []const u8 };
    const Row = struct { id: i64, val: Val };

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const s = try alloc.dupe(u8, "embedded");
    const row = Row{ .id = 7, .val = .{ .str = s } };
    const frozen = try freeze(Row, alloc, &row);
    alloc.free(s);
    defer frozen.deinit(alloc);

    const r = frozen.root();
    const base = @intFromPtr(frozen._buf.ptr);
    const end  = base + frozen._buf.len;

    try std.testing.expectEqual(@as(i64, 7), r.id);
    try std.testing.expect(r.val == .str);
    try std.testing.expectEqualStrings("embedded", r.val.str);
    try std.testing.expect(@intFromPtr(r.val.str.ptr) >= base and @intFromPtr(r.val.str.ptr) < end);
}

// ─────────────────────────────────────────────────────────────────────────────
// isRecursive and cycle detection tests
// ─────────────────────────────────────────────────────────────────────────────

test "isRecursive: correctly classifies types" {
    const Flat       = struct { x: i64, y: f64 };
    const WithStr    = struct { name: []const u8, val: i64 };
    const LinkedList = struct { val: i64, next: ?*@This() };
    const Tree       = struct { val: i64, left: ?*@This(), right: ?*@This() };
    const Expr       = union(enum) { nil, int: i64, list: []@This() };

    try std.testing.expect(!isRecursive(Flat));
    try std.testing.expect(!isRecursive(WithStr));   // []const u8 child is u8, not self
    try std.testing.expect(isRecursive(LinkedList));
    try std.testing.expect(isRecursive(Tree));
    try std.testing.expect(isRecursive(Expr));
}

test "freeze: cyclic linked list returns error.Cycle" {
    const Node = struct { val: i64, next: ?*@This() };
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const a = try alloc.create(Node);
    const b = try alloc.create(Node);
    defer { alloc.destroy(a); alloc.destroy(b); }
    a.* = .{ .val = 1, .next = b };
    b.* = .{ .val = 2, .next = a }; // cycle: b -> a

    try std.testing.expectError(error.Cycle, freeze(Node, alloc, a));
}

test "freeze: acyclic linked list (recursive type) succeeds" {
    const Node = struct { val: i64, next: ?*@This() };
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const c = try alloc.create(Node); c.* = .{ .val = 3, .next = null };
    const b = try alloc.create(Node); b.* = .{ .val = 2, .next = c };
    const a = try alloc.create(Node); a.* = .{ .val = 1, .next = b };

    const frozen = try freeze(Node, alloc, a);
    alloc.destroy(c); alloc.destroy(b); alloc.destroy(a);
    defer frozen.deinit(alloc);

    const r = frozen.root();
    const base = @intFromPtr(frozen._buf.ptr);
    const end  = base + frozen._buf.len;

    try std.testing.expectEqual(@as(i64, 1), r.val);
    try std.testing.expectEqual(@as(i64, 2), r.next.?.val);
    try std.testing.expectEqual(@as(i64, 3), r.next.?.next.?.val);
    try std.testing.expect(r.next.?.next.?.next == null);
    try std.testing.expect(@intFromPtr(r.next.?)       >= base and @intFromPtr(r.next.?)       < end);
    try std.testing.expect(@intFromPtr(r.next.?.next.?) >= base and @intFromPtr(r.next.?.next.?) < end);
}

test "freeze: self-loop (single node pointing to itself) returns error.Cycle" {
    const Node = struct { val: i64, next: ?*@This() };
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const a = try alloc.create(Node);
    defer alloc.destroy(a);
    a.* = .{ .val = 42, .next = a }; // self-loop

    try std.testing.expectError(error.Cycle, freeze(Node, alloc, a));
}

test "freeze: cycle in union pointer variant returns error.Cycle" {
    const Expr = union(enum) {
        nil,
        int: i64,
        ptr: *@This(),    // explicit pointer variant — can form cycles
        list: []@This(),  // value elements — cannot form cycles
    };
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const a = try alloc.create(Expr);
    defer alloc.destroy(a);
    a.* = .{ .ptr = a }; // self-referential

    try std.testing.expectError(error.Cycle, freeze(Expr, alloc, a));
}

test "freeze: deep cycle (cycle 100 nodes in) returns error.Cycle" {
    const Node = struct { val: i64, next: ?*@This() };
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Build chain of 100 nodes, then make the last point back to the first.
    const N = 100;
    const nodes = try alloc.alloc(Node, N);
    defer alloc.free(nodes);
    for (0..N) |i| nodes[i] = .{ .val = @intCast(i), .next = if (i + 1 < N) &nodes[i + 1] else null };
    nodes[N - 1].next = &nodes[0]; // cycle at depth 100

    try std.testing.expectError(error.Cycle, freeze(Node, alloc, &nodes[0]));
}

test "freeze: acyclic chain of 100 (recursive type) succeeds" {
    const Node = struct { val: i64, next: ?*@This() };
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const N = 100;
    const nodes = try alloc.alloc(Node, N);
    defer alloc.free(nodes);
    for (0..N) |i| nodes[i] = .{ .val = @intCast(i), .next = if (i + 1 < N) &nodes[i + 1] else null };

    const frozen = try freeze(Node, alloc, &nodes[0]);
    defer frozen.deinit(alloc);

    var cur: ?*const Node = frozen.root();
    var count: usize = 0;
    while (cur) |n| : (cur = n.next) count += 1;
    try std.testing.expectEqual(@as(usize, N), count);
}
