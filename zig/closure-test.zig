// A CLEAR `FN(...)` value is a function pointer plus the environment its
// `USE(...)` captures live in. These tests pin the shape the Zig backend emits:
// a closure that writes through a captured pointer, one that captures nothing,
// and both travelling through the SAME parameter type.
const std = @import("std");
const header = @import("runtime/runtime-header.zig");
const CheatLib = header.CheatLib;
const Runtime = header.Runtime;

const AddFn = fn (*Runtime, ?*anyopaque, i64) anyerror!void;
const AddClosure = CheatLib.Closure(AddFn);

fn callEach(rt: *Runtime, items: []const i64, f: AddClosure) !void {
    for (items) |it| try f.call(rt, f.ctx, it);
}

test "closure writes through a captured pointer" {
    var sum: i64 = 0;
    const Ctx = struct { sum: *i64 };
    var ctx = Ctx{ .sum = &sum };
    const closure = AddClosure.bind(@ptrCast(&ctx), &struct {
            fn call(_: *Runtime, raw: ?*anyopaque, v: i64) anyerror!void {
                const c: *Ctx = @ptrCast(@alignCast(raw.?));
                c.sum.* += v;
            }
        }.call);

    const items = [_]i64{ 1, 2, 3 };
    try callEach(undefined, &items, closure);
    try std.testing.expectEqual(@as(i64, 6), sum);
}

var bare_calls: i64 = 0;

fn countCall(_: *Runtime, _: ?*anyopaque, v: i64) anyerror!void {
    bare_calls += v;
}

test "a function that captures nothing travels as the same type" {
    bare_calls = 0;
    const closure = AddClosure.bind(null, &countCall);

    const items = [_]i64{ 4, 5 };
    try callEach(undefined, &items, closure);
    try std.testing.expectEqual(@as(i64, 9), bare_calls);
    // A lambda that captures nothing carries no environment at all.
    try std.testing.expect(closure.ctx == null);
}

test "two closures over different environments stay independent" {
    var a: i64 = 0;
    var b: i64 = 0;
    const Ctx = struct { target: *i64 };
    var ctx_a = Ctx{ .target = &a };
    var ctx_b = Ctx{ .target = &b };
    const call = struct {
        fn call(_: *Runtime, raw: ?*anyopaque, v: i64) anyerror!void {
            const c: *Ctx = @ptrCast(@alignCast(raw.?));
            c.target.* += v;
        }
    }.call;

    const ca = AddClosure.bind(@ptrCast(&ctx_a), &call);
    const cb = AddClosure.bind(@ptrCast(&ctx_b), &call);

    const items = [_]i64{ 7 };
    try callEach(undefined, &items, ca);
    try callEach(undefined, &items, cb);
    try callEach(undefined, &items, cb);

    try std.testing.expectEqual(@as(i64, 7), a);
    try std.testing.expectEqual(@as(i64, 14), b);
}
