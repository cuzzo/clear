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

    mod_tests.root_module.addImport("fiber-core", b.createModule(.{
        .root_source_file = b.path("fiber-core.zig"),
    }));

    mod_tests.addAssemblyFile(b.path("switch.S"));
    mod_tests.addAssemblyFile(b.path("onRoot.S"));
    mod_tests.linkLibC();

    const run_mod_tests = b.addRunArtifact(mod_tests);
    test_step.dependOn(&run_mod_tests.step);

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
    // Equivalent to: zig test ... -femit-llvm-bc=... -fno-emit-bin
    const emit_bc = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "test",
        "fiber-overflow-test.zig",
        "switch.S",
        "onRoot.S",
        "--library", "c",
        "-O", "ReleaseSafe", // Keep stack frame small
        b.fmt("-femit-llvm-bc={s}", .{raw_bc}),
        "-fno-emit-bin",
    });
    // We don't depend on cmake here, but it's part of the flow

    // STEP 3: Instrument Bitcode (Opt -> BC)
    // Equivalent to: opt -load-pass-plugin=... -passes="fiber-stack-check" ...
    const instrument_bc = b.addSystemCommand(&.{
        "opt",
        b.fmt("-load-pass-plugin={s}", .{pass_lib}),
        "-passes=fiber-stack-check",
        raw_bc,
        "-o", instr_bc,
    });
    instrument_bc.step.dependOn(&cmake_build.step); // Pass must exist
    instrument_bc.step.dependOn(&emit_bc.step);     // Raw BC must exist

    // STEP 4: Compile Executable (Zig -> Exe)
    // Equivalent to: zig build-exe fiber-test-instrumented.bc ...
    const build_exe = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build-exe",
        instr_bc,
        "switch.S",
        "onRoot.S",
        "--library", "c",
        "-O", "ReleaseSafe",
        "--name", runner_exe,
    });
    build_exe.step.dependOn(&instrument_bc.step);

    // STEP 5: Run It (and snoop for TEST FAILED SUCCESFULLY)
    // Equivalent to: ./fiber-test-runner
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
    // INDIVIDUAL TEST FILES
    // -------------------------------------------------------------------------
    // We add every test file found in your directory here.
    const test_files = [_][]const u8{
        "asm-test.zig",
        "fiber-test.zig",
        "fiber-control-tests.zig",
        "fiber-memory-test.zig",
        "frame-test.zig",
        "queues-test.zig",
        "safety-test.zig",
        "scheduler-test.zig",
        "slab-alloc-test.zig",
        "thread-test.zig",
        // "transpile-test.zig",
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

        // ensure ASM symbols exist
        unit_tests.root_module.addImport("fiber-core", b.createModule(.{
            .root_source_file = b.path("fiber-core.zig"),
        }));

        // CRITICAL: Link the context switching assembly to every test.
        // Even if a specific test doesn't use fibers, linking it doesn't hurt,
        // and it ensures 'thread-test' and 'fiber-test' work correctly.
        unit_tests.addAssemblyFile(b.path("switch.S"));
        unit_tests.addAssemblyFile(b.path("onRoot.S"));

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
        "arena-benchmark-test.zig",
        "benchmark-test.zig",
        "safety-benchmark-test.zig",
        "slab-alloc-benchmark-test.zig",
        "queues-benchmark-test.zig",
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

        bench_tests.root_module.addImport("fiber-core", b.createModule(.{
            .root_source_file = b.path("fiber-core.zig"),
        }));

        bench_tests.addAssemblyFile(b.path("switch.S"));
        bench_tests.addAssemblyFile(b.path("onRoot.S"));
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
    lib.addAssemblyFile(b.path("onRoot.S"));
    lib.linkLibC();
    b.installArtifact(lib);
}

