const std = @import("std");
const CheatLib = @import("runtime-header.zig").CheatLib;

const Value_Lambda = struct {
    params: []Value,
    body: *Value,
    envId: u64,

    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        if (comptime CheatLib.needsCleanup(Value)) {
            for (self.params) |*e| CheatLib.cleanup(Value, alloc, e);
        }
        if (self.params.len > 0) alloc.free(self.params);
        CheatLib.cleanup(Value, alloc, self.body);
        alloc.destroy(self.body);
    }
};

const Value = union(enum) {
    Nil: void,
    Number: f64,
    Symbol: []const u8,
    List: []Value,
    Lambda: Value_Lambda,
};

test "Lambda body survives HashMap storage and retrieval" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("LEAK");
    }
    const alloc = gpa.allocator();

    // Build a Lambda: params=[Symbol("x")], body=List[Symbol("+"), Symbol("x")]
    var params = try alloc.alloc(Value, 1);
    params[0] = Value{ .Symbol = try alloc.dupe(u8, "x") };

    var body_items = try alloc.alloc(Value, 2);
    body_items[0] = Value{ .Symbol = try alloc.dupe(u8, "+") };
    body_items[1] = Value{ .Symbol = try alloc.dupe(u8, "x") };

    const body_ptr = try alloc.create(Value);
    body_ptr.* = Value{ .List = body_items };

    const lambda = Value{ .Lambda = Value_Lambda{
        .params = params,
        .body = body_ptr,
        .envId = 0,
    } };

    // Store in HashMap (like pool[envId]?.vars["f"] = lambda)
    var map = CheatLib.StringMap(Value){ .alloc = alloc };
    defer map.deinit(alloc, alloc);

    try map.put(alloc, alloc, "f", lambda);

    // Retrieve with dupeUnionValue (like envGet COPY)
    const stored = map.get("f").?;
    var copy = try CheatLib.dupeUnionValue(Value, stored, alloc);
    defer CheatLib.cleanup(Value, alloc, &copy);

    // Verify body survived
    try std.testing.expect(std.meta.activeTag(copy) == .Lambda);
    const lam = copy.Lambda;
    try std.testing.expect(lam.params.len == 1);
    try std.testing.expect(std.meta.activeTag(lam.body.*) == .List);
    const body_list = lam.body.*.List;
    try std.testing.expect(body_list.len == 2);
    try std.testing.expect(std.mem.eql(u8, body_list[0].Symbol, "+"));
    try std.testing.expect(std.mem.eql(u8, body_list[1].Symbol, "x"));
}
