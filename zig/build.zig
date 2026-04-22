const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Common paths
    const switch_s = b.path("runtime/switch.S");
    const onroot_s = b.path("runtime/onRoot.S");
    const fiber_core_path = b.path("runtime/fiber-core.zig");
    const runtime_path = b.path("runtime/runtime.zig");

    // Named modules for lib/ dependencies (leaf nodes, no cross-imports)
    const safety_mod = b.createModule(.{ .root_source_file = b.path("lib/safety.zig") });
    const ebr_mod = b.createModule(.{ .root_source_file = b.path("lib/ebr.zig") });
    const ownership_mod = b.createModule(.{ .root_source_file = b.path("lib/ownership.zig") });
    const compat_mod = b.createModule(.{ .root_source_file = b.path("lib/compat.zig") });
    ebr_mod.addImport("compat", compat_mod);

    // -------------------------------------------------------------------------
    // MODULES & EXECUTABLES
    // -------------------------------------------------------------------------
    _ = b.addModule("zig", .{
        .root_source_file = runtime_path,
        .target = target,
    });

    // -------------------------------------------------------------------------
    // TEST CONFIGURATION
    // -------------------------------------------------------------------------
    const test_step = b.step("test", "Run all tests");

    // -------------------------------------------------------------------------
    // CUSTOM LLVM PASS SETUP
    // -------------------------------------------------------------------------

    // Paths
    const pass_src_dir = "fiber-stack-check/pass";
    const pass_build_dir = "fiber-stack-check/pass/build";
    const lib_ext = if (target.result.os.tag == .macos) ".dylib" else ".so";
    const pass_lib = b.fmt("{s}/libFiberStackCheck{s}", .{ pass_build_dir, lib_ext });

    // Artifact Names
    const raw_bc = "fiber-test-raw.bc";
    const instr_bc = "fiber-test-instrumented.bc";
    const runner_exe = "fiber-test-runner";

    // STEP 1: Build the C++ Pass (CMake)
    const cmake_config = b.addSystemCommand(&.{ "cmake", "-B", pass_build_dir, "-S", pass_src_dir });
    const cmake_build = b.addSystemCommand(&.{ "cmake", "--build", pass_build_dir });
    cmake_build.step.dependOn(&cmake_config.step);

    // STEP 2: Emit Bitcode (Zig -> BC)
    const emit_bc = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "test",
        "runtime/fiber-overflow-test.zig",
        "runtime/switch.S",
        "runtime/onRoot.S",
        "--library", "c",
        "-O", "ReleaseSafe",
        b.fmt("-femit-llvm-bc={s}", .{raw_bc}),
        "-fno-emit-bin",
    });

    // STEP 3: Instrument Bitcode (Opt -> BC)
    const instrument_bc = b.addSystemCommand(&.{
        "opt",
        b.fmt("-load-pass-plugin={s}", .{pass_lib}),
        "-passes=fiber-stack-check",
        raw_bc,
        "-o", instr_bc,
    });
    instrument_bc.step.dependOn(&cmake_build.step);
    instrument_bc.step.dependOn(&emit_bc.step);

    // STEP 4: Compile Executable (Zig -> Exe)
    const build_exe = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build-exe",
        instr_bc,
        "runtime/switch.S",
        "runtime/onRoot.S",
        "--library", "c",
        "-O", "ReleaseSafe",
        "--name", runner_exe,
    });
    build_exe.step.dependOn(&instrument_bc.step);

    // STEP 5: Run It
    const run_cmd = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            \\./{s}; ret=$?;
            \\if [ $ret -eq 99 ] || [ $ret -eq 133 ]; then
            \\  echo "\n[SUCCESS] Test crashed as expected (Exit Code: $ret)";
            \\  exit 0;
            \\else
            \\  echo "\n[FAILURE] Process exited with $ret. Expected 99 or 133 (SIGTRAP).";
            \\  exit 1;
            \\fi
        , .{runner_exe}),
    });
    run_cmd.step.dependOn(&build_exe.step);

    // EXPOSE: zig build test-stack
    const test_stack_step = b.step("test-stack", "Run fiber stack check tests with LLVM pass");
    test_stack_step.dependOn(&run_cmd.step);

    // -------------------------------------------------------------------------
    // INDIVIDUAL TEST FILES (all in runtime/)
    // -------------------------------------------------------------------------
    const test_files = [_][]const u8{
        "arena-mode-test.zig",
        "asm-test.zig",
        "batch-window-test.zig",
        "control-plane-test.zig",
        "data-structures-test.zig",
        "fiber-control-tests.zig",
        "fiber-memory-test.zig",
        "fiber-test.zig",
        "frame-test.zig",
        "inbox-race-smoke-test.zig",
        "iouring-test.zig",
        "ownership-test.zig",
        "partitioned-map-test.zig",
        "runtime-isolation-test.zig",
        "runtime-direct-test.zig",
        "promote-list-test.zig",
        "queues-test.zig",
        "resource-test.zig",
        "runtime-header-test.zig",
        "scheduler-direct-test.zig",
        "semaphore-test.zig",
        "spsc-ring-test.zig",
        "spsc-test.zig",
        "spsc-scheduler-test.zig",
        "vopr-test.zig",
        "vopr-loom-test.zig",
        "yield-test.zig",
        "parking-lot-loom-test.zig",
        "parking-lot-test.zig",
    };

    for (test_files) |filename| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(filename),
                .target = target,
                .optimize = optimize,
            }),
        });
        unit_tests.root_module.addImport("fiber-core", b.createModule(.{ .root_source_file = fiber_core_path }));
        unit_tests.root_module.addImport("safety", safety_mod);
        unit_tests.root_module.addImport("ebr", ebr_mod);
        unit_tests.root_module.addImport("ownership", ownership_mod);
        unit_tests.root_module.addImport("compat", compat_mod);
        unit_tests.root_module.addAssemblyFile(switch_s);
        unit_tests.root_module.addAssemblyFile(onroot_s);
        unit_tests.root_module.link_libc = true;

        const run_unit_tests = std.Build.Step.Run.create(b, b.fmt("run test {s}", .{filename}));
        run_unit_tests.addArtifactArg(unit_tests);
        run_unit_tests.stdio = .inherit;
        run_unit_tests.setCwd(b.path("."));
        test_step.dependOn(&run_unit_tests.step);
    }

    // -------------------------------------------------------------------------
    // BENCHMARKS (zig build benchmark)
    // -------------------------------------------------------------------------
    const bench_step = b.step("benchmark", "Run performance benchmarks");

    const benchmark_files = [_][]const u8{
        "arena-benchmark-test.zig",
        "benchmark-test.zig",
        "safety-benchmark-test.zig",
        "slab-alloc-benchmark-test.zig",
        "queues-benchmark-test.zig",
        "scheduler-benchmark-test.zig",
        "experimental/freeze_bench.zig",
    };

    for (benchmark_files) |filename| {
        const bench_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(filename),
                .target = target,
                .optimize = optimize,
            }),
        });

        bench_tests.root_module.addImport("fiber-core", b.createModule(.{ .root_source_file = fiber_core_path }));
        bench_tests.root_module.addImport("safety", safety_mod);
        bench_tests.root_module.addImport("ebr", ebr_mod);
        bench_tests.root_module.addImport("ownership", ownership_mod);
        bench_tests.root_module.addImport("compat", compat_mod);
        bench_tests.root_module.addAssemblyFile(switch_s);
        bench_tests.root_module.addAssemblyFile(onroot_s);
        bench_tests.root_module.link_libc = true;

        const run_bench = std.Build.Step.Run.create(b, b.fmt("run benchmark {s}", .{filename}));
        run_bench.addArtifactArg(bench_tests);
        run_bench.stdio = .inherit;
        bench_step.dependOn(&run_bench.step);
    }

    // -------------------------------------------------------------------------
    // HAMMER / STRESS TESTS (zig build hammer)
    // -------------------------------------------------------------------------
    const hammer_step = b.step("hammer", "Run stress tests and race detectors");

    const hammer_test_files = [_][]const u8{
        "runtime/arena-fuzz-test.zig",
        "runtime/control-plane-hammer-test.zig",
    };

    for (hammer_test_files) |filename| {
        const hammer_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(filename),
                .target = target,
                .optimize = optimize,
            }),
        });
        hammer_tests.root_module.addImport("fiber-core", b.createModule(.{ .root_source_file = fiber_core_path }));
        hammer_tests.root_module.addImport("safety", safety_mod);
        hammer_tests.root_module.addImport("ebr", ebr_mod);
        hammer_tests.root_module.addImport("ownership", ownership_mod);
        hammer_tests.root_module.addImport("compat", compat_mod);
        hammer_tests.root_module.addAssemblyFile(switch_s);
        hammer_tests.root_module.addAssemblyFile(onroot_s);
        hammer_tests.root_module.link_libc = true;
        const run_hammer = b.addRunArtifact(hammer_tests);
        run_hammer.has_side_effects = true;
        hammer_step.dependOn(&run_hammer.step);
    }

    // Standalone exe tests (pub fn main -- bootstrap their own scheduler)
    const hammer_exe_files = [_][]const u8{
        "runtime/shared-nothing-test.zig",
        "runtime/routing-crash-test.zig",
        "runtime/scheduler-race-test.zig",
        "runtime/inbox-race-test.zig",
        "runtime/io-pressure-test.zig",
    };

    for (hammer_exe_files) |filename| {
        const hammer_exe = b.addExecutable(.{
            .name = std.fs.path.stem(filename),
            .root_module = b.createModule(.{
                .root_source_file = b.path(filename),
                .target = target,
                .optimize = optimize,
            }),
        });
        hammer_exe.root_module.addImport("fiber-core", b.createModule(.{ .root_source_file = fiber_core_path }));
        hammer_exe.root_module.addImport("safety", safety_mod);
        hammer_exe.root_module.addImport("ebr", ebr_mod);
        hammer_exe.root_module.addImport("ownership", ownership_mod);
        hammer_exe.root_module.addImport("compat", compat_mod);
        hammer_exe.root_module.addAssemblyFile(switch_s);
        hammer_exe.root_module.addAssemblyFile(onroot_s);
        hammer_exe.root_module.link_libc = true;
        const run_hammer_exe = b.addRunArtifact(hammer_exe);
        run_hammer_exe.has_side_effects = true;
        hammer_step.dependOn(&run_hammer_exe.step);
    }

    // -------------------------------------------------------------------------
    // VOPR -- Deterministic simulation testing
    // -------------------------------------------------------------------------
    const vopr_step = b.step("vopr", "Run VOPR deterministic simulation tests");
    const vopr_exe = b.addExecutable(.{
        .name = "vopr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/vopr.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    vopr_exe.root_module.link_libc = true;
    const run_vopr = b.addRunArtifact(vopr_exe);
    run_vopr.has_side_effects = true;
    vopr_step.dependOn(&run_vopr.step);

    // -------------------------------------------------------------------------
    // LOOM -- Deterministic atomic interleaving tests
    // -------------------------------------------------------------------------
    const loom_step = b.step("loom", "Run Loom deterministic interleaving tests");
    const loom_exe = b.addExecutable(.{
        .name = "loom",
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/vopr-loom.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    loom_exe.root_module.addImport("fiber-core", b.createModule(.{ .root_source_file = fiber_core_path }));
    loom_exe.root_module.addImport("safety", safety_mod);
    loom_exe.root_module.addImport("ebr", ebr_mod);
    loom_exe.root_module.addImport("ownership", ownership_mod);
    loom_exe.root_module.addImport("compat", compat_mod);
    loom_exe.root_module.addAssemblyFile(switch_s);
    loom_exe.root_module.addAssemblyFile(onroot_s);
    loom_exe.root_module.link_libc = true;
    const run_loom = b.addRunArtifact(loom_exe);
    run_loom.has_side_effects = true;
    loom_step.dependOn(&run_loom.step);

    // -------------------------------------------------------------------------
    // STATIC LIBRARY (cheat-runtime)
    // -------------------------------------------------------------------------
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "cheat-runtime",
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/runtime-header.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    lib.root_module.addImport("fiber-core", b.createModule(.{ .root_source_file = fiber_core_path }));
    lib.root_module.addImport("safety", safety_mod);
    lib.root_module.addImport("ebr", ebr_mod);
    lib.root_module.addImport("ownership", ownership_mod);
    lib.root_module.addImport("compat", compat_mod);
    lib.root_module.addAssemblyFile(switch_s);
    lib.root_module.addAssemblyFile(onroot_s);
    lib.root_module.link_libc = true;
    b.installArtifact(lib);
}
