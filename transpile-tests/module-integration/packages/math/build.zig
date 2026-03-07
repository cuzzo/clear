const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_root = b.build_root.path orelse ".";
    const transpiler = b.fmt("{s}/../../../../src/transpiler.rb", .{build_root});
    const math_src   = b.fmt("{s}/src/lib.cht", .{build_root});

    // cheat_runtime: path relative from packages/math/ to the zig/ directory
    const cheat_runtime_mod = b.createModule(.{
        .root_source_file = b.path("../../../../zig/runtime-header.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Transpile lib.cht → Zig source and expose as the "math" module
    const transpile = b.addSystemCommand(&.{ "ruby", transpiler, "--module", math_src });
    const lib_zig   = transpile.captureStdOut();

    const math_mod = b.createModule(.{ .root_source_file = lib_zig });
    math_mod.addImport("cheat_runtime", cheat_runtime_mod);

    _ = b.addModule("math", .{
        .root_source_file = lib_zig,
        .target = target,
        .optimize = optimize,
    });
}
