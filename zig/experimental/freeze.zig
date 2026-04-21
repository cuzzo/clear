//! freeze.zig -- Compact a struct tree into a single contiguous heap allocation.
//!
//! freeze(T, alloc, ptr) walks every pointer / slice field of T recursively
//! and packs the whole object tree into one flat buffer.  Interior pointers are
//! rewritten to point into the new buffer.  The caller frees the buffer via
//! Frozen(T).deinit().
//!
//! v0.2 supported field types
//!   - Primitives (i64, u8, bool, f64, …)          just copied
//!   - []const u8 / []u8  (strings)                bytes inlined, ptr patched
//!   - []T where T is a supported struct            array inlined, ptrs patched
//!   - ?*T where T is a supported struct            child inlined if non-null
//!   - *T                                           child inlined
//!   - Nested structs (no pointer fields of their own need no special handling)
//!   - Cycles / shared nodes                        handled via placement map;
//!                                                  back-edge pointers patched
//!                                                  to the already-copied node
//!
//! NOT supported (silently skipped / left as stale pointers):
//!   - HashMap, Set, Pool  (non-relocatable internal structure)
//!   - Function pointers
//!
//! Cycle handling:
//!   For types where isRecursive(T) is true, freeze() builds a placement map
//!   (old_ptr -> buf_offset) during the measure pass.  The copy pass uses this
//!   map to patch back-edge pointers to their already-written buffer locations.
//!   Cycles are preserved faithfully: a self-loop in the frozen buffer points
//!   back to the frozen copy of the same node.

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
        /// Direct pointer to root for efficient field access from CLEAR.
        _root: *const T,

        pub fn deinit(self: Self, alloc: Allocator) void {
            alloc.free(self._buf);
        }
    };
}

/// Preserved for backward compatibility.  Cycles no longer produce an error;
/// this is now an alias for Allocator.Error.
pub const FreezeError = std.mem.Allocator.Error;

/// Returns true if T's type graph contains any pointer that refers back to T.
/// When true, freeze() uses a placement map and handles cycles.
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
            if (FT == Root) return false;
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
/// For recursive types, cycles are preserved: back-edge pointers in the frozen
/// buffer point to the already-copied node at its buffer offset.
pub fn freeze(comptime T: type, alloc: Allocator, val: *const T) Allocator.Error!Frozen(T) {
    if (comptime isRecursive(T)) {
        var pm = PlacementMap.init(alloc);
        defer pm.deinit();

        var size: usize = 0;
        try measureNodePM(T, val, &size, &pm);

        const buf = try alloc.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(@alignOf(T)), size);
        errdefer alloc.free(buf);

        var ws = WrittenSet.init(alloc);
        defer ws.deinit();

        var cursor: usize = 0;
        try copyNodePM(T, val, buf, &cursor, &pm, &ws);
        std.debug.assert(cursor == size);
        return Frozen(T){ ._buf = buf, ._root = @ptrCast(buf.ptr) };
    } else {
        var size: usize = 0;
        measureNode(T, val, &size);

        const buf = try alloc.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(@alignOf(T)), size);
        errdefer alloc.free(buf);

        var cursor: usize = 0;
        copyNode(T, val, buf, &cursor);
        std.debug.assert(cursor == size);
        return Frozen(T){ ._buf = buf, ._root = @ptrCast(buf.ptr) };
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Measurement pass  (non-recursive fast path — no HashMap overhead)
// ─────────────────────────────────────────────────────────────────────────────

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
                    cursor.* += val.*.len;
                } else {
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

        .@"struct" => measurePointees(FT, val, cursor),
        .@"union" => measurePointees(FT, val, cursor),
        else => {},
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Placement-map measurement pass  (iterative DFS — O(1) stack depth per node)
//
// Self-referential pointer fields (*T / ?*T where T == RootT) are pushed onto
// an explicit work list instead of recursed into, so linked-list-length chains
// don't overflow the call stack.  Non-self-referential pointer fields still
// recurse, but their depth is bounded by the OTHER type's structure, not the
// graph size.
// ─────────────────────────────────────────────────────────────────────────────

const PlacementMap = std.AutoHashMap(usize, usize); // old addr -> buf offset

fn measureNodePM(comptime T: type, root: *const T, cursor: *usize, pm: *PlacementMap) Allocator.Error!void {
    var work = std.ArrayList(*const T).empty;
    defer work.deinit(pm.allocator);
    try work.append(pm.allocator, root);
    while (work.pop()) |val| {
        const addr = @intFromPtr(val);
        if (pm.contains(addr)) continue;
        cursor.* = alignUp(cursor.*, @alignOf(T));
        try pm.put(addr, cursor.*);
        cursor.* += @sizeOf(T);
        try measureFieldsIter(T, T, val, cursor, pm, &work);
    }
}

fn measureFieldsIter(
    comptime RootT: type,
    comptime StructT: type,
    val: *const StructT,
    cursor: *usize,
    pm: *PlacementMap,
    work: *std.ArrayList(*const RootT),
) Allocator.Error!void {
    switch (@typeInfo(StructT)) {
        .@"struct" => |si| {
            inline for (si.fields) |f| {
                try measureFieldIter(RootT, f.type, &@field(val.*, f.name), cursor, pm, work);
            }
        },
        .@"union" => |ui| {
            if (ui.tag_type != null) {
                const tag = std.meta.activeTag(val.*);
                inline for (ui.fields) |f| {
                    if (tag == @field(std.meta.Tag(StructT), f.name)) {
                        try measureFieldIter(RootT, f.type, &@field(val.*, f.name), cursor, pm, work);
                    }
                }
            }
        },
        else => {},
    }
}

fn measureFieldIter(
    comptime RootT: type,
    comptime FT: type,
    val: *const FT,
    cursor: *usize,
    pm: *PlacementMap,
    work: *std.ArrayList(*const RootT),
) Allocator.Error!void {
    switch (@typeInfo(FT)) {
        .pointer => |pi| switch (pi.size) {
            .slice => {
                if (pi.child == u8) {
                    cursor.* += val.*.len;
                } else {
                    cursor.* = alignUp(cursor.*, @alignOf(pi.child));
                    cursor.* += val.*.len * @sizeOf(pi.child);
                    for (val.*) |*elem| {
                        try measureFieldIter(RootT, pi.child, elem, cursor, pm, work);
                    }
                }
            },
            .one => {
                if (comptime pi.child == RootT) {
                    try work.append(pm.allocator, val.*); // iterative: push to work list
                } else {
                    try measureNodePM(pi.child, val.*, cursor, pm); // bounded depth
                }
            },
            else => {},
        },
        .optional => |oi| {
            switch (@typeInfo(oi.child)) {
                .pointer => |pi| switch (pi.size) {
                    .one => {
                        if (val.* != null) {
                            if (comptime pi.child == RootT) {
                                try work.append(pm.allocator, val.*.?);
                            } else {
                                try measureNodePM(pi.child, val.*.?, cursor, pm);
                            }
                        }
                    },
                    else => {},
                },
                else => {},
            }
        },
        .@"struct" => try measureFieldsIter(RootT, FT, val, cursor, pm, work),
        .@"union"  => try measureFieldsIter(RootT, FT, val, cursor, pm, work),
        else => {},
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Copy pass  (non-recursive fast path — no HashMap overhead)
// ─────────────────────────────────────────────────────────────────────────────

fn copyNode(comptime T: type, val: *const T, buf: []u8, cursor: *usize) void {
    cursor.* = alignUp(cursor.*, @alignOf(T));
    const my_off = cursor.*;
    cursor.* += @sizeOf(T);

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
                    const off = cursor.*;
                    @memcpy(buf[off..][0..len], src_val.*);
                    cursor.* += len;
                    dest_field.* = buf[off..][0..len];
                } else {
                    cursor.* = alignUp(cursor.*, @alignOf(pi.child));
                    const off = cursor.*;
                    const bytes = len * @sizeOf(pi.child);
                    @memcpy(buf[off..][0..bytes], @as([*]const u8, @ptrCast(src_val.*.ptr))[0..bytes]);
                    cursor.* += bytes;
                    const new_arr: [*]pi.child = @ptrCast(@alignCast(buf[off..].ptr));
                    dest_field.* = new_arr[0..len];
                    for (0..len) |i| {
                        patchField(pi.child, &src_val.*[i], &new_arr[i], buf, cursor);
                    }
                }
            },

            .one => {
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

        .@"struct" => patchPointees(FT, src_val, dest_field, buf, cursor),
        .@"union" => patchPointees(FT, src_val, dest_field, buf, cursor),
        else => {},
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Placement-map copy pass  (iterative DFS — same traversal order as measure pass)
//
// Pointer fields are patched immediately using the placement map (all offsets are
// known from the measure pass).  Self-referential children are pushed onto a work
// list instead of recursed into, keeping call-stack depth O(1) per node.
// ─────────────────────────────────────────────────────────────────────────────

const WrittenSet = std.AutoHashMap(usize, void);

fn copyNodePM(
    comptime T: type,
    root: *const T,
    buf: []u8,
    cursor: *usize,
    pm: *const PlacementMap,
    ws: *WrittenSet,
) Allocator.Error!void {
    var work = std.ArrayList(*const T).empty;
    defer work.deinit(ws.allocator);
    try work.append(ws.allocator, root);
    while (work.pop()) |val| {
        const addr = @intFromPtr(val);
        if (ws.contains(addr)) continue;
        try ws.put(addr, {});
        cursor.* = alignUp(cursor.*, @alignOf(T));
        const my_off = cursor.*;
        cursor.* += @sizeOf(T);
        @memcpy(buf[my_off..][0..@sizeOf(T)], @as([*]const u8, @ptrCast(val))[0..@sizeOf(T)]);
        const dest: *T = @ptrCast(@alignCast(buf[my_off..].ptr));
        try patchFieldsIter(T, T, val, dest, buf, cursor, pm, ws, &work);
    }
}

fn patchFieldsIter(
    comptime RootT: type,
    comptime StructT: type,
    src: *const StructT,
    dest: *StructT,
    buf: []u8,
    cursor: *usize,
    pm: *const PlacementMap,
    ws: *WrittenSet,
    work: *std.ArrayList(*const RootT),
) Allocator.Error!void {
    switch (@typeInfo(StructT)) {
        .@"struct" => |si| {
            inline for (si.fields) |f| {
                try patchFieldIter(RootT, f.type, &@field(src.*, f.name), &@field(dest.*, f.name), buf, cursor, pm, ws, work);
            }
        },
        .@"union" => |ui| {
            if (ui.tag_type != null) {
                const tag = std.meta.activeTag(src.*);
                inline for (ui.fields) |f| {
                    if (tag == @field(std.meta.Tag(StructT), f.name)) {
                        try patchFieldIter(RootT, f.type, &@field(src.*, f.name), &@field(dest.*, f.name), buf, cursor, pm, ws, work);
                    }
                }
            }
        },
        else => {},
    }
}

fn patchFieldIter(
    comptime RootT: type,
    comptime FT: type,
    src_val: *const FT,
    dest_field: *FT,
    buf: []u8,
    cursor: *usize,
    pm: *const PlacementMap,
    ws: *WrittenSet,
    work: *std.ArrayList(*const RootT),
) Allocator.Error!void {
    switch (@typeInfo(FT)) {
        .pointer => |pi| switch (pi.size) {
            .slice => {
                const len = src_val.*.len;
                if (len == 0) return;
                if (pi.child == u8) {
                    const off = cursor.*;
                    @memcpy(buf[off..][0..len], src_val.*);
                    cursor.* += len;
                    dest_field.* = buf[off..][0..len];
                } else {
                    cursor.* = alignUp(cursor.*, @alignOf(pi.child));
                    const off = cursor.*;
                    const bytes = len * @sizeOf(pi.child);
                    @memcpy(buf[off..][0..bytes], @as([*]const u8, @ptrCast(src_val.*.ptr))[0..bytes]);
                    cursor.* += bytes;
                    const new_arr: [*]pi.child = @ptrCast(@alignCast(buf[off..].ptr));
                    dest_field.* = new_arr[0..len];
                    for (0..len) |i| {
                        try patchFieldIter(RootT, pi.child, &src_val.*[i], &new_arr[i], buf, cursor, pm, ws, work);
                    }
                }
            },
            .one => {
                // Patch immediately — pm has every node's final offset.
                const child_addr = @intFromPtr(src_val.*);
                const child_off = pm.get(child_addr).?;
                dest_field.* = @ptrCast(@alignCast(buf[child_off..].ptr));
                if (comptime pi.child == RootT) {
                    if (!ws.contains(child_addr)) try work.append(ws.allocator, src_val.*);
                } else {
                    if (!ws.contains(child_addr)) try copyNodePM(pi.child, src_val.*, buf, cursor, pm, ws);
                }
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
                            const child_addr = @intFromPtr(src_val.*.?);
                            const child_off = pm.get(child_addr).?;
                            dest_field.* = @ptrCast(@alignCast(buf[child_off..].ptr));
                            if (comptime pi.child == RootT) {
                                if (!ws.contains(child_addr)) try work.append(ws.allocator, src_val.*.?);
                            } else {
                                if (!ws.contains(child_addr)) try copyNodePM(pi.child, src_val.*.?, buf, cursor, pm, ws);
                            }
                        }
                    },
                    else => {},
                },
                else => {},
            }
        },
        .@"struct" => try patchFieldsIter(RootT, FT, src_val, dest_field, buf, cursor, pm, ws, work),
        .@"union"  => try patchFieldsIter(RootT, FT, src_val, dest_field, buf, cursor, pm, ws, work),
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

    const r = frozen._root;
    try std.testing.expectEqualStrings("hello", r.name);
    try std.testing.expectEqual(@as(i64, 42), r.value);

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

    const left = try alloc.create(Node);
    left.* = .{ .key = try alloc.dupe(u8, "a"), .value = 1, .left = null, .right = null };
    const right = try alloc.create(Node);
    right.* = .{ .key = try alloc.dupe(u8, "c"), .value = 3, .left = null, .right = null };
    const root_node = try alloc.create(Node);
    root_node.* = .{ .key = try alloc.dupe(u8, "b"), .value = 2, .left = left, .right = right };

    const frozen = try freeze(Node, alloc, root_node);
    defer frozen.deinit(alloc);

    alloc.free(left.key); alloc.destroy(left);
    alloc.free(right.key); alloc.destroy(right);
    alloc.free(root_node.key); alloc.destroy(root_node);

    const r = frozen._root;
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

    alloc.free(title);
    alloc.free(tag0);
    alloc.free(tag1);
    alloc.free(tags);

    defer frozen.deinit(alloc);

    const r = frozen._root;
    const base = @intFromPtr(frozen._buf.ptr);
    const end  = base + frozen._buf.len;

    try std.testing.expectEqualStrings("Frozen Docs", r.title);
    try std.testing.expect(@intFromPtr(r.title.ptr) >= base and @intFromPtr(r.title.ptr) < end);

    try std.testing.expectEqual(@as(usize, 2), r.tags.len);
    try std.testing.expectEqualStrings("zig",     r.tags[0]);
    try std.testing.expectEqualStrings("systems", r.tags[1]);
    try std.testing.expect(@intFromPtr(r.tags[0].ptr) >= base and @intFromPtr(r.tags[0].ptr) < end);
    try std.testing.expect(@intFromPtr(r.tags[1].ptr) >= base and @intFromPtr(r.tags[1].ptr) < end);
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
    alloc.free(label);
    defer frozen.deinit(alloc);

    const r = frozen._root;
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

    alloc.free(c0.name); alloc.destroy(c0);
    alloc.free(c1.name); alloc.destroy(c1);
    alloc.free(ptrs);

    defer frozen.deinit(alloc);

    const r = frozen._root;
    const base = @intFromPtr(frozen._buf.ptr);
    const end  = base + frozen._buf.len;

    try std.testing.expectEqual(@as(usize, 2), r.children.len);
    try std.testing.expectEqualStrings("first",  r.children[0].name);
    try std.testing.expectEqualStrings("second", r.children[1].name);
    try std.testing.expectEqual(@as(i64, 1), r.children[0].val);
    try std.testing.expectEqual(@as(i64, 2), r.children[1].val);
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

    {
        const v = Val{ .num = 42 };
        const frozen = try freeze(Val, alloc, &v);
        defer frozen.deinit(alloc);
        try std.testing.expectEqual(Val{ .num = 42 }, frozen._root.*);
    }

    {
        const s = try alloc.dupe(u8, "hello union");
        const v = Val{ .str = s };
        const frozen = try freeze(Val, alloc, &v);
        alloc.free(s);
        defer frozen.deinit(alloc);

        const r = frozen._root;
        const base = @intFromPtr(frozen._buf.ptr);
        const end  = base + frozen._buf.len;
        try std.testing.expectEqualStrings("hello union", r.str);
        try std.testing.expect(@intFromPtr(r.str.ptr) >= base and @intFromPtr(r.str.ptr) < end);
    }
}

test "freeze: tagged union — recursive tree (Value-like)" {
    const Expr = union(enum) {
        nil,
        int: i64,
        str: []const u8,
        list: []@This(),
    };

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const elems = try alloc.dupe(Expr, &[_]Expr{
        .{ .str = try alloc.dupe(u8, "+") },
        .{ .str = try alloc.dupe(u8, "hello") },
        .{ .int = 42 },
    });
    const root_expr = Expr{ .list = elems };

    const frozen = try freeze(Expr, alloc, &root_expr);

    alloc.free(elems[0].str);
    alloc.free(elems[1].str);
    alloc.free(elems);

    defer frozen.deinit(alloc);

    const r = frozen._root;
    const base = @intFromPtr(frozen._buf.ptr);
    const end  = base + frozen._buf.len;

    try std.testing.expect(r.* == .list);
    try std.testing.expectEqual(@as(usize, 3), r.list.len);

    try std.testing.expect(@intFromPtr(r.list.ptr) >= base and @intFromPtr(r.list.ptr) < end);

    try std.testing.expect(r.list[0] == .str);
    try std.testing.expectEqualStrings("+", r.list[0].str);
    try std.testing.expect(@intFromPtr(r.list[0].str.ptr) >= base and @intFromPtr(r.list[0].str.ptr) < end);

    try std.testing.expect(r.list[1] == .str);
    try std.testing.expectEqualStrings("hello", r.list[1].str);

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

    const r = frozen._root;
    const base = @intFromPtr(frozen._buf.ptr);
    const end  = base + frozen._buf.len;

    try std.testing.expect(r.* == .list);
    try std.testing.expectEqual(@as(usize, 2), r.list.len);

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

    const r = frozen._root;
    const base = @intFromPtr(frozen._buf.ptr);
    const end  = base + frozen._buf.len;

    try std.testing.expectEqual(@as(i64, 7), r.id);
    try std.testing.expect(r.val == .str);
    try std.testing.expectEqualStrings("embedded", r.val.str);
    try std.testing.expect(@intFromPtr(r.val.str.ptr) >= base and @intFromPtr(r.val.str.ptr) < end);
}

// ─────────────────────────────────────────────────────────────────────────────
// isRecursive and cycle tests
// ─────────────────────────────────────────────────────────────────────────────

test "isRecursive: correctly classifies types" {
    const Flat       = struct { x: i64, y: f64 };
    const WithStr    = struct { name: []const u8, val: i64 };
    const LinkedList = struct { val: i64, next: ?*@This() };
    const Tree       = struct { val: i64, left: ?*@This(), right: ?*@This() };
    const Expr       = union(enum) { nil, int: i64, list: []@This() };

    try std.testing.expect(!isRecursive(Flat));
    try std.testing.expect(!isRecursive(WithStr));
    try std.testing.expect(isRecursive(LinkedList));
    try std.testing.expect(isRecursive(Tree));
    try std.testing.expect(isRecursive(Expr));
}

test "freeze: cyclic linked list freezes correctly" {
    const Node = struct { val: i64, next: ?*@This() };
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const a = try alloc.create(Node);
    const b = try alloc.create(Node);
    a.* = .{ .val = 1, .next = b };
    b.* = .{ .val = 2, .next = a }; // cycle: b -> a

    const frozen = try freeze(Node, alloc, a);
    alloc.destroy(a);
    alloc.destroy(b);
    defer frozen.deinit(alloc);

    const r = frozen._root;
    const base = @intFromPtr(frozen._buf.ptr);
    const end  = base + frozen._buf.len;

    try std.testing.expectEqual(@as(i64, 1), r.val);
    try std.testing.expect(r.next != null);
    try std.testing.expectEqual(@as(i64, 2), r.next.?.val);
    try std.testing.expect(r.next.?.next != null);
    // Back-edge: b.next points to the frozen copy of a (the root)
    try std.testing.expectEqual(r, r.next.?.next.?);
    try std.testing.expect(@intFromPtr(r)        >= base and @intFromPtr(r)        < end);
    try std.testing.expect(@intFromPtr(r.next.?) >= base and @intFromPtr(r.next.?) < end);
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

    const r = frozen._root;
    const base = @intFromPtr(frozen._buf.ptr);
    const end  = base + frozen._buf.len;

    try std.testing.expectEqual(@as(i64, 1), r.val);
    try std.testing.expectEqual(@as(i64, 2), r.next.?.val);
    try std.testing.expectEqual(@as(i64, 3), r.next.?.next.?.val);
    try std.testing.expect(r.next.?.next.?.next == null);
    try std.testing.expect(@intFromPtr(r.next.?)       >= base and @intFromPtr(r.next.?)       < end);
    try std.testing.expect(@intFromPtr(r.next.?.next.?) >= base and @intFromPtr(r.next.?.next.?) < end);
}

test "freeze: self-loop freezes correctly" {
    const Node = struct { val: i64, next: ?*@This() };
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const a = try alloc.create(Node);
    a.* = .{ .val = 42, .next = a }; // self-loop

    const frozen = try freeze(Node, alloc, a);
    alloc.destroy(a);
    defer frozen.deinit(alloc);

    const r = frozen._root;
    try std.testing.expectEqual(@as(i64, 42), r.val);
    try std.testing.expect(r.next != null);
    // Self-loop: next points to self
    try std.testing.expectEqual(r, r.next.?);
}

test "freeze: cycle in union pointer variant freezes correctly" {
    const Expr = union(enum) {
        nil,
        int: i64,
        ptr: *@This(),
        list: []@This(),
    };
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const a = try alloc.create(Expr);
    a.* = .{ .ptr = a }; // self-referential

    const frozen = try freeze(Expr, alloc, a);
    alloc.destroy(a);
    defer frozen.deinit(alloc);

    const r = frozen._root;
    try std.testing.expect(r.* == .ptr);
    // Self-loop: ptr points to root
    try std.testing.expectEqual(r, r.ptr);
}

test "freeze: deep cycle (100 nodes) freezes correctly" {
    const Node = struct { val: i64, next: ?*@This() };
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const N = 100;
    const nodes = try alloc.alloc(Node, N);
    for (0..N) |i| nodes[i] = .{ .val = @intCast(i), .next = if (i + 1 < N) &nodes[i + 1] else null };
    nodes[N - 1].next = &nodes[0]; // cycle at depth 100

    const frozen = try freeze(Node, alloc, &nodes[0]);
    alloc.free(nodes); // free originals; frozen buffer is self-contained
    defer frozen.deinit(alloc);

    const r = frozen._root;
    // Walk exactly N steps; should arrive back at root
    var cur: ?*const Node = r;
    for (0..N) |_| cur = cur.?.next;
    try std.testing.expectEqual(r, cur.?);
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

    var cur: ?*const Node = frozen._root;
    var count: usize = 0;
    while (cur) |n| : (cur = n.next) count += 1;
    try std.testing.expectEqual(@as(usize, N), count);
}
