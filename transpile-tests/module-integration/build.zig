const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -----------------------------------------------------------------------
    // Absolute paths (needed for addSystemCommand args and --pkg flags)
    // -----------------------------------------------------------------------
    const build_root  = b.build_root.path orelse ".";
    const transpiler  = b.fmt("{s}/../../src/backends/transpiler.rb", .{build_root});
    const math_src    = b.fmt("{s}/packages/math/src/lib.cht", .{build_root});
    const geom_src    = b.fmt("{s}/packages/geometry/src/lib.cht", .{build_root});
    const main_src    = b.fmt("{s}/src/main.cht", .{build_root});

    // --pkg flags passed to the Ruby transpiler so it can type-check imports
    const math_pkg_arg = b.fmt("math={s}", .{math_src});
    const geom_pkg_arg = b.fmt("geometry={s}", .{geom_src});

    // -----------------------------------------------------------------------
    // cheat_runtime module (shared by all CLEAR modules)
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
    // math package: transpile lib.cht → Zig module
    // -----------------------------------------------------------------------
    const transpile_math = b.addSystemCommand(&.{ "ruby", transpiler, "--module", math_src });
    const math_zig = transpile_math.captureStdOut(.{});

    const math_mod = b.createModule(.{ .root_source_file = math_zig });
    math_mod.addImport("cheat_runtime", cheat_runtime_mod);

    // -----------------------------------------------------------------------
    // geometry package: transpile lib.cht → Zig module (depends on math)
    // -----------------------------------------------------------------------
    const transpile_geom = b.addSystemCommand(&.{
        "ruby", transpiler, "--module", geom_src,
        "--pkg", math_pkg_arg,
    });
    const geom_zig = transpile_geom.captureStdOut(.{});

    const geom_mod = b.createModule(.{ .root_source_file = geom_zig });
    geom_mod.addImport("cheat_runtime", cheat_runtime_mod);
    geom_mod.addImport("math", math_mod);

    // -----------------------------------------------------------------------
    // main: transpile src/main.cht → Zig module (with embedded test block)
    //
    // The transpiler emits a `test "cheat main" { ... }` block when it detects
    // FN main() in the source. This lets main_mod be used directly as
    // the test root without a separate test_runner file.
    // -----------------------------------------------------------------------
    const transpile_main = b.addSystemCommand(&.{
        "ruby", transpiler, "--module", main_src,
        "--pkg", math_pkg_arg,
        "--pkg", geom_pkg_arg,
    });
    const main_zig = transpile_main.captureStdOut(.{});

    const main_mod = b.createModule(.{
        .root_source_file = main_zig,
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("cheat_runtime", cheat_runtime_mod);
    main_mod.addImport("math", math_mod);
    main_mod.addImport("geometry", geom_mod);

    // -----------------------------------------------------------------------
    // Integration test: run the test block embedded in main_mod
    // -----------------------------------------------------------------------
    const test_step = b.step("test", "Run CLEAR package integration tests");

    // Assembly is required for the fiber runtime context switching
    main_mod.addAssemblyFile(b.path("../../zig/runtime/switch.S"));
    main_mod.addAssemblyFile(b.path("../../zig/runtime/onRoot.S"));
    main_mod.link_libc = true;

    const integration_test = b.addTest(.{ .root_module = main_mod });

    const run_test = b.addRunArtifact(integration_test);
    test_step.dependOn(&run_test.step);
}
