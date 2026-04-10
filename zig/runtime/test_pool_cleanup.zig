const std = @import("std");
const CheatLib = @import("runtime-header.zig").CheatLib;

const Value = union(enum) {
    Nil: void,
    Str: []const u8,
    List: []Value,
};

const Env = struct {
    vars: CheatLib.StringMap(Value),
};

test "Pool deinit cleans up HashMap values with strings" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("LEAK detected in pool cleanup test");
    }
    const alloc = gpa.allocator();

    var pool = try CheatLib.Pool(Env).initCapacity(alloc, 10);
    defer pool.deinit(alloc);

    // Insert an Env with a string value in its HashMap
    const id = try pool.insert(alloc, Env{ .vars = CheatLib.StringMap(Value){ .alloc = alloc } });
    var env = pool.get(id).?;
    try env.vars.put(alloc, alloc, "key", Value{ .Str = try alloc.dupe(u8, "hello") });
}

test "Pool deinit cleans up HashMap values with list slices" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("LEAK detected in pool list cleanup test");
    }
    const alloc = gpa.allocator();

    var pool = try CheatLib.Pool(Env).initCapacity(alloc, 10);
    defer pool.deinit(alloc);

    // Insert an Env with a Value.List containing a heap-duped string
    const id = try pool.insert(alloc, Env{ .vars = CheatLib.StringMap(Value){ .alloc = alloc } });
    var env = pool.get(id).?;

    // Build a Value.List with one element: Value{ .Str = "world" }
    var items = try alloc.alloc(Value, 1);
    items[0] = Value{ .Str = try alloc.dupe(u8, "world") };
    try env.vars.put(alloc, alloc, "mylist", Value{ .List = items });
}
