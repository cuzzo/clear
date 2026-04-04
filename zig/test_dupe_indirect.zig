const std = @import("std");
const CheatLib = @import("runtime-header.zig").CheatLib;

const Inner = struct {
    x: i64,
    name: []const u8,
};

const Value = union(enum) {
    Nil: void,
    Num: f64,
    Boxed: *Inner,
};

test "dupeUnionValue deep-copies *T (single pointer) fields" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("LEAK in dupeUnionValue pointer test");
    }
    const alloc = gpa.allocator();

    // Create original: Value{ Boxed: *Inner{ x: 42, name: "hello" } }
    const inner = try alloc.create(Inner);
    inner.* = Inner{ .x = 42, .name = try alloc.dupe(u8, "hello") };
    const original = Value{ .Boxed = inner };

    // Deep copy
    var copy = try CheatLib.dupeUnionValue(Value, original, alloc);

    // Verify copy is independent
    try std.testing.expect(copy.Boxed.x == 42);
    try std.testing.expect(std.mem.eql(u8, copy.Boxed.name, "hello"));
    try std.testing.expect(copy.Boxed != original.Boxed); // different pointers

    // Free both independently - should not double-free
    CheatLib.cleanup(Value, alloc, &copy);
    var orig_mut = original;
    CheatLib.cleanup(Value, alloc, &orig_mut);
}
