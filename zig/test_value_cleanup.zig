const std = @import("std");
const CheatLib = @import("runtime-header.zig").CheatLib;

const Value = union(enum) {
    Nil: void,
    Num: f64,
    Str: []const u8,
    List: []Value,
};

test "cleanup frees Value.Str heap string" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("LEAK: Str not freed");
    }
    const alloc = gpa.allocator();
    var v = Value{ .Str = try alloc.dupe(u8, "hello") };
    CheatLib.cleanup(Value, alloc, &v);
}

test "cleanup frees Value.List with Str elements" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("LEAK: List elements not freed");
    }
    const alloc = gpa.allocator();

    var items = try alloc.alloc(Value, 2);
    items[0] = Value{ .Str = try alloc.dupe(u8, "hello") };
    items[1] = Value{ .Str = try alloc.dupe(u8, "world") };
    var v = Value{ .List = items };
    CheatLib.cleanup(Value, alloc, &v);
}

test "cleanup frees nested Value.List (List of Lists)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("LEAK: nested List not freed");
    }
    const alloc = gpa.allocator();

    var inner = try alloc.alloc(Value, 1);
    inner[0] = Value{ .Str = try alloc.dupe(u8, "nested") };

    var outer = try alloc.alloc(Value, 1);
    outer[0] = Value{ .List = inner };

    var v = Value{ .List = outer };
    CheatLib.cleanup(Value, alloc, &v);
}

test "dupeUnionValue + cleanup = no leak" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("LEAK: dupeUnionValue copy not freed");
    }
    const alloc = gpa.allocator();

    var items = try alloc.alloc(Value, 1);
    items[0] = Value{ .Str = try alloc.dupe(u8, "original") };
    var original = Value{ .List = items };

    // Deep copy
    var copy = try CheatLib.dupeUnionValue(Value, original, alloc);

    // Free both
    CheatLib.cleanup(Value, alloc, &original);
    CheatLib.cleanup(Value, alloc, &copy);
}
