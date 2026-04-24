const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------------------------------------------------
    // Absolute paths
    // -----------------------------------------------------------------------
    const build_root = b.build_root.path orelse ".";
    const transpiler = b.fmt("{s}/../../src/backends/transpiler.rb", .{build_root});
    const main_src   = b.fmt("{s}/src/main.cht", .{build_root});

    // -----------------------------------------------------------------------
    // cheat_runtime module
    // -----------------------------------------------------------------------
    const cheat_runtime_mod = b.createModule(.{
        .root_source_file = b.path("../../zig/runtime/runtime-header.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Named modules for cross-directory lib/ imports
    const safety_mod = b.createModule(.{ .root_source_file = b.path("../../zig/lib/safety.zig") });
    const ebr_mod = b.createModule(.{ .root_source_file = b.path("../../zig/lib/ebr.zig") });
    const ownership_mod = b.createModule(.{ .root_source_file = b.path("../../zig/lib/ownership.zig") });
    cheat_runtime_mod.addImport("safety", safety_mod);
    cheat_runtime_mod.addImport("ebr", ebr_mod);
    cheat_runtime_mod.addImport("ownership", ownership_mod);

    // -----------------------------------------------------------------------
    // native_math: pure Zig module (no CLEAR transpilation needed)
    // -----------------------------------------------------------------------
    const native_math_mod = b.createModule(.{
        .root_source_file = b.path("packages/native_math/src/lib.zig"),
    });

    // -----------------------------------------------------------------------
    // Transpile main.cht → Zig module
    // EXTERN FN declarations in main.cht emit @import("native_math").
    // The build system wires the actual module via addImport below.
    // -----------------------------------------------------------------------
    const transpile_main = b.addSystemCommand(&.{ "ruby", transpiler, "--module", main_src });
    const main_zig = transpile_main.captureStdOut(.{});

    const main_mod = b.createModule(.{
        .root_source_file = main_zig,
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("cheat_runtime", cheat_runtime_mod);
    main_mod.addImport("native_math", native_math_mod);

    // -----------------------------------------------------------------------
    // Integration test: run the embedded `test "cheat main"` block
    // -----------------------------------------------------------------------
    const test_step = b.step("test", "Run CLEAR FFI integration tests");

    main_mod.addAssemblyFile(b.path("../../zig/runtime/switch.S"));
    main_mod.addAssemblyFile(b.path("../../zig/runtime/onRoot.S"));
    main_mod.link_libc = true;

    const integration_test = b.addTest(.{ .root_module = main_mod });

    const run_test = b.addRunArtifact(integration_test);
    test_step.dependOn(&run_test.step);
}
