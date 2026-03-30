const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_root = b.build_root.path orelse ".";
    const transpiler = b.fmt("{s}/../../src/transpiler.rb", .{build_root});
    const main_src = b.fmt("{s}/src/main.cht", .{build_root});

    // cheat_runtime module (needed by --module output)
    const cheat_runtime_mod = b.createModule(.{
        .root_source_file = b.path("../../zig/runtime-header.zig"),
        .target = target,
        .optimize = optimize,
    });

    // http: native Zig module wrapping std.net for HTTP
    const http_mod = b.createModule(.{
        .root_source_file = b.path("packages/http/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Transpile main.cht → Zig module
    const transpile_main = b.addSystemCommand(&.{ "ruby", transpiler, "--module", main_src });
    const main_zig = transpile_main.captureStdOut();

    const main_mod = b.createModule(.{
        .root_source_file = main_zig,
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("cheat_runtime", cheat_runtime_mod);
    main_mod.addImport("http", http_mod);

    // Integration test
    const test_step = b.step("test", "Run web crawler integration test");

    const integration_test = b.addTest(.{ .root_module = main_mod });
    integration_test.addAssemblyFile(b.path("../../zig/switch.S"));
    integration_test.addAssemblyFile(b.path("../../zig/onRoot.S"));
    integration_test.linkLibC();

    const run_test = b.addRunArtifact(integration_test);
    test_step.dependOn(&run_test.step);
}
