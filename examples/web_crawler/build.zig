const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_root = b.build_root.path orelse ".";
    const transpiler = b.fmt("{s}/../../src/backends/transpiler.rb", .{build_root});
    const main_src = b.fmt("{s}/src/main.clear", .{build_root});

    // cheat_runtime module: root at zig/ so ../lib/ imports in runtime-header.zig work
    const cheat_runtime_mod = b.createModule(.{
        .root_source_file = b.path("../../zig/cheat_runtime.zig"),
        .target = target,
        .optimize = optimize,
    });

    // http: native Zig module wrapping std.net for HTTP
    const http_mod = b.createModule(.{
        .root_source_file = b.path("packages/http/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Transpile main.clear → Zig module
    const transpile_main = b.addSystemCommand(&.{ "ruby", transpiler, "--module", main_src });
    const main_zig = transpile_main.captureStdOut(.{ .basename = "main.zig" });

    const main_mod = b.createModule(.{
        .root_source_file = main_zig,
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("cheat_runtime", cheat_runtime_mod);
    main_mod.addImport("http", http_mod);

    // Integration test
    const test_step = b.step("test", "Run web crawler integration test");

    main_mod.addAssemblyFile(b.path("../../zig/runtime/switch.S"));
    main_mod.addAssemblyFile(b.path("../../zig/runtime/onRoot.S"));

    const integration_test = b.addTest(.{ .root_module = main_mod });
    main_mod.link_libc = true;

    const run_test = b.addRunArtifact(integration_test);
    test_step.dependOn(&run_test.step);
}
