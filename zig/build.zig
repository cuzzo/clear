const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -------------------------------------------------------------------------
    // MODULES & EXECUTABLES
    // -------------------------------------------------------------------------
    const mod = b.addModule("zig", .{
        .root_source_file = b.path("runtime.zig"),
        .target = target,
    });

    // -------------------------------------------------------------------------
    // TEST CONFIGURATION
    // -------------------------------------------------------------------------
    const test_step = b.step("test", "Run all tests");

    // 1. Run tests inside the main module (runtime.zig)
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    mod_tests.addAssemblyFile(b.path("switch.S")); // Link ASM for runtime internal tests
    mod_tests.linkLibC();
    const run_mod_tests = b.addRunArtifact(mod_tests);
    test_step.dependOn(&run_mod_tests.step);

    // -------------------------------------------------------------------------
    // INDIVIDUAL TEST FILES
    // -------------------------------------------------------------------------
    // We add every test file found in your directory here.
    const test_files = [_][]const u8{
        "fiber-test.zig",
        // "fiber-memory-test.zig",
        "frame-test.zig",
        "queues-test.zig",
        "sbr-test.zig",
        "sbr-unit-test.zig",
        "scheduler-test.zig",
        "slab-alloc-test.zig",
        "thread-test.zig",
        "transpile-test.zig",
    };

    for (test_files) |filename| {
        // Create a dedicated test executable for this file
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(filename),
                .target = target,
                .optimize = optimize,
            }),
        });

        // CRITICAL: Link the context switching assembly to every test.
        // Even if a specific test doesn't use fibers, linking it doesn't hurt,
        // and it ensures 'thread-test' and 'fiber-test' work correctly.
        unit_tests.addAssemblyFile(b.path("switch.S"));
        unit_tests.linkLibC();

        // Create the run step and attach it to the top-level 'test' command
        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }

    // -------------------------------------------------------------------------
    // BENCHMARKS (zig build benchmark)
    // -------------------------------------------------------------------------
    const bench_step = b.step("benchmark", "Run performance benchmarks");

    const benchmark_files = [_][]const u8{
        "benchmark-test.zig",
        "arena-benchmark-test.zig",
        "queues-benchmark-test.zig",
        "sbr-benchmark-test.zig",
        "slab-alloc-benchmark-test.zig",
    };

    for (benchmark_files) |filename| {
        // We usually want benchmarks to run in ReleaseFast mode
        // to see real performance, but Debug is fine for development.
        // You can use `zig build benchmark -Doptimize=ReleaseFast` to override.
        const bench_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(filename),
                .target = target,
                .optimize = optimize,
            }),
        });

        bench_tests.addAssemblyFile(b.path("switch.S"));
        bench_tests.linkLibC();

        // Optional: Benchmarks often output to stdout, which `zig build` hides by default.
        // We can force it to show up.
        const run_bench = b.addRunArtifact(bench_tests);
        run_bench.has_side_effects = true;

        bench_step.dependOn(&run_bench.step);
    }

    // -------------------------------------------------------------------------
    // STATIC LIBRARY (cheat-runtime)
    // -------------------------------------------------------------------------
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "cheat-runtime",
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime-header.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    lib.addAssemblyFile(b.path("switch.S"));
    lib.linkLibC();
    b.installArtifact(lib);
}

