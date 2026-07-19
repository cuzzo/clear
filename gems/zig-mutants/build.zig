const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const coverage = b.option(bool, "coverage", "Run zig-mutants unit tests under kcov") orelse false;

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zig-mutants",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("zig_mutants", lib_mod);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zig-mutants");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = lib_mod,
        .use_llvm = if (coverage) true else null,
    });
    const run_unit_tests = if (coverage) b.addSystemCommand(&.{
        "kcov",
        "--clean",
        "--include-path=src",
        "--path-strip-level=0",
        "--exclude-pattern=zig-cache,.zig-cache,zig-out",
        "zig-out/coverage/kcov",
    }) else b.addRunArtifact(unit_tests);
    if (coverage) {
        const mkdir_coverage = b.addSystemCommand(&.{ "mkdir", "-p", "zig-out/coverage/kcov" });
        run_unit_tests.addArtifactArg(unit_tests);
        run_unit_tests.stdio = .inherit;
        run_unit_tests.step.dependOn(&mkdir_coverage.step);
    }
    const test_step = b.step("test", "Run zig-mutants unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const coverage_step = b.step("coverage", "Run zig-mutants unit tests under kcov");
    coverage_step.dependOn(&run_unit_tests.step);
}
