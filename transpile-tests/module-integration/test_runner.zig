const std = @import("std");
const cheat_runtime = @import("cheat_runtime");
const Runtime = cheat_runtime.Runtime;
const EbrContext = cheat_runtime.EbrContext;
const main_module = @import("program");

test "module integration" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    var rt = try Runtime.init(allocator, 1024 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    try main_module.clearMain(&rt);
}
