const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;

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
    NativeFn: []const u8,
};

const Env = struct {
    vars: CheatLib.StringMap(Value),
};

fn evalList(rt: *Runtime, items: []Value, envId: u64, _: *CheatLib.Pool(Env)) anyerror!Value {
    const frame_mark = rt.saveFrameMark();
    defer rt.restoreFrameMark(frame_mark);

    // Simulate: formName = items[0].Symbol
    const form = items[0].Symbol;

    if (std.mem.eql(u8, form, "fn*")) {
        // items[1] = List of params, items[2] = List (body)
        const pnames = items[1].List;
        // COPY pnames (deep)
        const p_buf = try rt.heapAlloc().alloc(Value, pnames.len);
        for (p_buf, 0..) |*dst, i| {
            dst.* = try CheatLib.dupeUnionValue(Value, pnames[i], rt.heapAlloc());
        }
        // COPY items[2] as @indirect body
        const body_ptr = try rt.heapAlloc().create(Value);
        body_ptr.* = try CheatLib.dupeUnionValue(Value, items[2], rt.heapAlloc());

        return Value{ .Lambda = Value_Lambda{
            .params = p_buf,
            .body = body_ptr,
            .envId = envId,
        } };
    }
    return Value{ .Nil = {} };
}

fn eval(rt: *Runtime, ast: Value, envId: u64, pool: *CheatLib.Pool(Env)) anyerror!Value {
    const frame_mark = rt.saveFrameMark();
    defer rt.restoreFrameMark(frame_mark);

    if (std.meta.activeTag(ast) == .List) {
        return evalList(rt, ast.List, envId, pool);
    }
    return ast;
}

test "Lambda body survives frame rewind + HashMap storage" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("LEAK");
    }
    const allocator = gpa.allocator();
    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var rt = try Runtime.init(allocator, 128 * 1024 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    var pool = try CheatLib.Pool(Env).initCapacity(rt.heapAlloc(), 100);
    defer pool.deinit(rt.heapAlloc());

    const rootId = try pool.insert(rt.heapAlloc(), Env{ .vars = CheatLib.StringMap(Value){ .alloc = rt.heapAlloc() } });

    // Build AST for (fn* (x) (+ x a))
    var fn_items = try rt.frameAlloc().alloc(Value, 3);
    fn_items[0] = Value{ .Symbol = "fn*" };

    var param_list = try rt.frameAlloc().alloc(Value, 1);
    param_list[0] = Value{ .Symbol = "x" };
    fn_items[1] = Value{ .List = param_list };

    var body_list = try rt.frameAlloc().alloc(Value, 3);
    body_list[0] = Value{ .Symbol = "+" };
    body_list[1] = Value{ .Symbol = "x" };
    body_list[2] = Value{ .Symbol = "a" };
    fn_items[2] = Value{ .List = body_list };

    // eval (fn* (x) (+ x a)) -> returns Lambda
    const lambda_val = try eval(&rt, Value{ .List = fn_items }, rootId, &pool);

    // Store in env (like def!)
    try pool.get(rootId).?.vars.put(rt.heapAlloc(), rt.frameAlloc(), "f", lambda_val);

    // Retrieve with COPY (like envGet)
    const stored = pool.get(rootId).?.vars.get("f").?;
    var copy = try CheatLib.dupeUnionValue(Value, stored, rt.heapAlloc());
    defer CheatLib.cleanup(Value, rt.heapAlloc(), &copy);

    // Verify
    try std.testing.expect(std.meta.activeTag(copy) == .Lambda);
    try std.testing.expect(copy.Lambda.params.len == 1);
    try std.testing.expect(std.meta.activeTag(copy.Lambda.body.*) == .List);
    const body = copy.Lambda.body.*.List;
    try std.testing.expect(body.len == 3);
    try std.testing.expect(std.mem.eql(u8, body[0].Symbol, "+"));
}
