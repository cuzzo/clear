const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_root = b.build_root.path orelse ".";
    const transpiler = b.fmt("{s}/../../../../compiler/ruby/backends/transpiler.rb", .{build_root});
    const geom_src   = b.fmt("{s}/src/lib.clear", .{build_root});
    const math_src   = b.fmt("{s}/../math/src/lib.clear", .{build_root});
    const math_pkg_arg = b.fmt("math={s}", .{math_src});

    // cheat_runtime: path relative from packages/geometry/ to zig/
    const cheat_runtime_mod = b.createModule(.{
        .root_source_file = b.path("../../../../zig/runtime-header.zig"),
        .target = target,
        .optimize = optimize,
    });

    // math module (from sibling package)
    const math_dep = b.dependency("math", .{ .target = target, .optimize = optimize });
    const math_mod = math_dep.module("math");

    // Transpile lib.clear → Zig source and expose as the "geometry" module
    const transpile = b.addSystemCommand(&.{
        "ruby", transpiler, "--module", geom_src,
        "--pkg", math_pkg_arg,
    });
    const lib_zig = transpile.captureStdOut();

    const geom_inner = b.createModule(.{ .root_source_file = lib_zig });
    geom_inner.addImport("cheat_runtime", cheat_runtime_mod);
    geom_inner.addImport("math", math_mod);

    _ = b.addModule("geometry", .{
        .root_source_file = lib_zig,
        .target = target,
        .optimize = optimize,
    });
}
