const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;

// -------------------------------------------------------------------------
// 2. User Types & Functions (Transpiled)
// -------------------------------------------------------------------------
fn fib(rt: *Runtime, n: i64) !i64 {
    _ = &rt;
    _ = &n;
    if ((n <= 1)) {
    return n;
    }
return (try fib(rt, (n - 1)) + try fib(rt, (n - 2)));
}


fn cheatMain(rt: *Runtime) !void {
    _ = &rt;
    const r: i64 = try fib(rt, @intFromFloat(35)); _ = &r;


CheatLib.assert((r == 9227465), "Fib(35) calculation error");
return ;
}


// -------------------------------------------------------------------------
// 3. Main Entry (Test Harness)
// -------------------------------------------------------------------------
// TODO: Make this depend on libc, use jemalloc
pub fn main() !void {
    // 1. Setup Allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 2. Setup Contexts (Required by your current runtime.zig)
    // We import EbrContext from ebr.zig (referenced in your runtime)
    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    // 3. Init Runtime (5 Arguments)
    // init(allocator, frame_size, global_ctx, global_alloc, backing_alloc)
    var rt = try Runtime.init(
        allocator,
        1024 * 1024,
        &global_ctx,
    );
    defer rt.deinit();
    rt.wireAllocator();

    // 4. Run Main
    // Call the function defined in CHEAT
    const result = try cheatMain(&rt);

    const RType = @TypeOf(result);
    if (@typeInfo(RType) == .pointer) {
        CheatLib.free(&rt, result); // manual free, or else we leak
    }
}

