const std = @import("std");
const CheatLib = @import("runtime-header.zig").CheatLib;

const Value = union(enum) {
    Nil: void,
    Num: f64,
    Str: []const u8,
    List: []Value,
};

test "reassignment cleanup frees Value.List buffer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("LEAK: reassignment did not free old List buffer");
    }
    const alloc = gpa.allocator();

    // Simulate: result = Value{ List: [Num(1), Num(2), Num(3)] }
    var items1 = try alloc.alloc(Value, 3);
    items1[0] = Value{ .Num = 1.0 };
    items1[1] = Value{ .Num = 2.0 };
    items1[2] = Value{ .Num = 3.0 };
    var result = Value{ .List = items1 };

    // Simulate: cleanup(result) before reassignment
    CheatLib.cleanup(Value, alloc, &result);

    // Reassign
    result = Value{ .Num = 3.0 };

    // Final cleanup (from defer)
    CheatLib.cleanup(Value, alloc, &result);
}
