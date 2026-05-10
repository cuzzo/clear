const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Enable ThreadSanitizer for test/benchmark/hammer modules.
    // CI: `zig build test -Dsanitize-thread`. Local: same. The flag
    // routes through Module.sanitize_thread on every test module
    // created in the test_files loop.
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable ThreadSanitizer (TSan) on test/bench/hammer modules") orelse false;
    // Enable kcov coverage collection on test binaries. Each test runs
    // under `kcov zig-out/coverage/<n> <binary>`, then a final merge
    // step produces zig-out/coverage/merged/cobertura.xml for upload to
    // Codecov / Coveralls. CI: `zig build test -Dcoverage`.
    const coverage = b.option(bool, "coverage", "Wrap test binaries with kcov to collect coverage (writes Cobertura XML)") orelse false;
    // Like -Dcoverage but scoped to Loom-only tests (`*-loom-test.zig` and
    // the parking-lot-loom executable). Output goes to a separate
    // `zig-out/coverage-loom/` tree so the report reflects only what the
    // exhaustive interleaving harness exercises -- used to find atomic
    // operation sites that are NOT covered by Loom. Invoke as
    // `zig build coverage-loom -Dcoverage-loom`. VOPR tests are intentionally
    // excluded -- VOPR is a single-threaded simulator and would pollute the
    // "what does Loom cover" report with lines it happens to touch.
    const coverage_loom = b.option(bool, "coverage-loom", "Wrap Loom-only tests with kcov (writes Cobertura XML to zig-out/coverage-loom/)") orelse false;
    // Mirror of -Dcoverage-loom for VOPR-only tests (`*-vopr-test.zig`).
    // Output goes to a separate `zig-out/coverage-vopr/` tree so the
    // report reflects only what the deterministic simulator exercises --
    // used to find time / random / IO / retry sites that no VOPR test
    // reaches. Loom tests are intentionally excluded -- Loom is for
    // atomic-op interleaving, not VOPR's fault/clock/retry surface.
    // Invoke as `zig build coverage-vopr -Dcoverage-vopr`.
    const coverage_vopr = b.option(bool, "coverage-vopr", "Wrap VOPR-only tests with kcov (writes Cobertura XML to zig-out/coverage-vopr/)") orelse false;
    // Test sharding for CI parallelism. With `-Dshard-count=N -Dshard-index=I`
    // (0 <= I < N), only every Nth test added to `test_step` (selected by
    // round-robin index within the loop) is built and run. Codecov merges the
    // per-shard XMLs server-side via the `flags: zig` tag, so each shard can
    // upload its own cobertura.xml without a separate join job.
    const shard_index = b.option(u32, "shard-index", "Test shard index (0-based, default 0)") orelse 0;
    const shard_count = b.option(u32, "shard-count", "Total test shards for CI parallelism (default 1 = no sharding)") orelse 1;

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
    // All test files. Files marked `tsan_*` run under ThreadSanitizer too
    // via `zig build test-tsan`. TSan tests force the LLVM backend (stage2
    // doesn't link the TSan runtime regardless of opt level); see the
    // `tsan_tests` block below for details on the Debug optimize choice.
    const TestEntry = struct {
        path: []const u8,
        // True when the test exercises shared mutable state across threads/
        // schedulers and would benefit from data-race detection. Adding a
        // file here means it ALSO runs under `zig build test-tsan`.
        tsan: bool = false,
        // True for high-iteration concurrency/fuzz stress tests whose
        // value comes from running them under ThreadSanitizer (every
        // memory op instrumented amplifies what each iteration can
        // detect). Hammer/fuzz tests are EXCLUDED from the regular
        // `zig build test` step (slow, low marginal value
        // un-instrumented) and from the regular `zig build test-tsan`
        // step (so the per-shard wallclock stays bounded), and run
        // exclusively in `zig build test-hammer` (TSan-instrumented).
        // This keeps the CI unit test job fast while preserving stress
        // coverage on a dedicated job.
        hammer: bool = false,
        // True for `*-loom-test.zig` and `*-vopr-test.zig`: deterministic
        // interleaving / simulation tests that exhaustively explore
        // schedules in-process. They take minutes each and dominate
        // `zig build test` wallclock. TSan adds nothing — the exhaustive
        // enumeration is its own race detector. Routed exclusively to
        // `zig build test-loom-vopr` (sharded), excluded from `test`,
        // `test-tsan`, and `test-hammer`.
        loom_vopr: bool = false,
    };

    const test_files = [_]TestEntry{
        // Concurrency-sensitive — also run under TSan
        .{ .path = "atomic-test.zig", .tsan = true },
        .{ .path = "atomic-hammer-test.zig", .tsan = true, .hammer = true },
        .{ .path = "batch-window-test.zig", .tsan = true },
        .{ .path = "bounded-channel-test.zig", .tsan = true },
        .{ .path = "bounded-stream-test.zig", .tsan = true },
        .{ .path = "cleanup-test.zig", .tsan = true },
        .{ .path = "control-plane-hammer-test.zig", .tsan = true, .hammer = true },
        .{ .path = "control-plane-test.zig", .tsan = true },
        .{ .path = "data-structures-hammer-test.zig", .tsan = true, .hammer = true },
        .{ .path = "epoll-oneshot-test.zig", .tsan = true },
        .{ .path = "epoll-steal-test.zig", .tsan = true },
        .{ .path = "ffi-concurrency-test.zig", .tsan = true },
        .{ .path = "fiber-test.zig", .tsan = true },
        .{ .path = "fiber-profile-test.zig", .tsan = true },
        // FSM (stackless task) tests
        .{ .path = "fsm-benchmark-test.zig", .tsan = true },
        .{ .path = "fsm-concurrent-test.zig", .tsan = true },
        .{ .path = "fsm-cross-scheduler-test.zig", .tsan = true },
        .{ .path = "fsm-endtoend-fairness-test.zig", .tsan = true },
        .{ .path = "fsm-fairness-test.zig", .tsan = true },
        .{ .path = "fsm-hammer-test.zig", .tsan = true, .hammer = true },
        .{ .path = "fsm-lock-safety-test.zig", .tsan = true },
        .{ .path = "fsm-lock-test.zig", .tsan = true },
        // fsm-lock-vopr-test built as executable (see vopr_exes).
        .{ .path = "fsm-loom-test.zig", .loom_vopr = true },
        .{ .path = "fsm-race-test.zig", .tsan = true },
        .{ .path = "fsm-rwlock-test.zig", .tsan = true },
        .{ .path = "fsm-scheduler-test.zig", .tsan = true },
        .{ .path = "fsm-steal-test.zig", .tsan = true },
        .{ .path = "fsm-test.zig", .tsan = true },
        // fsm-vopr-test built as executable (see vopr_exes).
        .{ .path = "fsm-wg-test.zig", .tsan = true },
        .{ .path = "inf-stream-test.zig", .tsan = true },
        .{ .path = "infstream-hammer-test.zig", .tsan = true, .hammer = true },
        .{ .path = "io-pressure-test.zig", .tsan = true },
        .{ .path = "iouring-test.zig", .tsan = true },
        .{ .path = "net-steal-hammer-test.zig", .tsan = true, .hammer = true },
        .{ .path = "parking-lot-cycle-test.zig", .tsan = true },
        .{ .path = "parking-lot-hammer-test.zig", .tsan = true, .hammer = true },
        // parking-lot-loom-test is built as an executable above (search for
        // pl_loom_exe). Building via b.addTest puts the test_runner at
        // module root, hiding `pub const SimAtomic` from the comptime
        // Atomic alias and silently disabling Loom — see GAP-B.
        .{ .path = "parking-lot-test.zig", .tsan = true },
        .{ .path = "pool-test.zig", .tsan = true },
        .{ .path = "queues-test.zig", .tsan = true },
        .{ .path = "routing-crash-test.zig", .tsan = true },
        .{ .path = "runtime-direct-test.zig", .tsan = true },
        .{ .path = "runtime-isolation-test.zig", .tsan = true },
        .{ .path = "scheduler-test.zig", .tsan = true },
        .{ .path = "scheduler-direct-test.zig", .tsan = true },
        .{ .path = "scheduler-primitives-hammer-test.zig", .tsan = true, .hammer = true },
        .{ .path = "semaphore-test.zig", .tsan = true },
        .{ .path = "sharded-list-test.zig", .tsan = true },
        .{ .path = "sharded-pool-test.zig", .tsan = true },
        .{ .path = "shared-nothing-test.zig", .tsan = true },
        .{ .path = "shared-promise-test.zig", .tsan = true },
        .{ .path = "slab-alloc-test.zig", .tsan = true },
        .{ .path = "spsc-ring-test.zig", .tsan = true },
        .{ .path = "spsc-scheduler-test.zig", .tsan = true },
        .{ .path = "spsc-hammer-test.zig", .tsan = true, .hammer = true },
        .{ .path = "spsc-test.zig", .tsan = true },
        .{ .path = "steal-hammer-test.zig", .tsan = true, .hammer = true },
        .{ .path = "stream-hammer-test.zig", .tsan = true, .hammer = true },
        .{ .path = "stream-test.zig", .tsan = true },
        .{ .path = "observable-test.zig", .tsan = true },
        .{ .path = "tcp-fairness-test.zig", .tsan = true },
        .{ .path = "tcp-starvation-test.zig", .tsan = true },
        .{ .path = "vopr-loom-test.zig", .loom_vopr = true },
        // vopr-test built as executable (see vopr_exes).
        .{ .path = "yield-test.zig", .tsan = true },
        // MVCC: Versioned(T) tests + lock hammers
        .{ .path = "fsm-rwlock-hammer-test.zig", .tsan = true, .hammer = true },
        .{ .path = "parking-rwlock-fiber-hammer-test.zig", .tsan = true, .hammer = true },
        .{ .path = "versioned-test.zig", .tsan = true },
        .{ .path = "versioned-stress-test.zig", .tsan = true },
        .{ .path = "versioned-loom-test.zig", .loom_vopr = true },
        // versioned-vopr-test is built as an executable (see vopr_exes).
        .{ .path = "versioned-fiber-stress-test.zig", .tsan = true },
        // Atomics v0.2 / v0.3
        .{ .path = "atomic-ptr-loom-test.zig", .loom_vopr = true },
        // VOPR test entries (`*-vopr-test.zig`) are built as
        // executables below (search for `vopr_exes`). Building via
        // b.addTest puts the test_runner at module root, hiding
        // `pub const SimClock` / `pub const SimRandom` from the
        // comptime seam in lib/compat.zig and silently disabling
        // them (same GAP-B issue parking-lot-loom hit pre-2026-05).
        .{ .path = "atomic-ptr-stress-test.zig", .tsan = true },

        // Single-threaded / pure logic — debug build only
        .{ .path = "arena-fuzz-test.zig", .hammer = true },
        .{ .path = "arena-mode-test.zig" },
        .{ .path = "asm-test.zig" },
        .{ .path = "data-structures-test.zig" },
        .{ .path = "fiber-control-test.zig" },
        .{ .path = "fiber-memory-test.zig" },
        .{ .path = "frame-rewind-test.zig" },
        .{ .path = "frame-test.zig" },
        .{ .path = "ownership-test.zig" },
        .{ .path = "partitioned-map-test.zig", .tsan = true },
        .{ .path = "promote-list-test.zig" },
        .{ .path = "resource-test.zig" },
        .{ .path = "runtime-header-test.zig" },
        .{ .path = "sigaltstack-test.zig" },
        .{ .path = "soa-list-test.zig" },
        .{ .path = "soa-pool-test.zig" },
    };

    const test_tsan_step = b.step("test-tsan", "Run concurrency-sensitive tests under ThreadSanitizer");
    // Dedicated step for high-iteration concurrency stress tests
    // (`*-hammer-test.zig`). Built with TSan instrumentation: every
    // memory op instrumented turns each iteration into a real
    // race-detection probe. Excluded from `test` and `test-tsan`
    // because un-instrumented hammer runs are mostly wallclock cost
    // with low marginal value, and the dedicated step lets CI run
    // it on its own job (parallel with the unit-test job, doesn't
    // bottleneck the unit-test PR signal).
    const test_hammer_step = b.step("test-hammer", "Run hammer stress tests under ThreadSanitizer");
    // Dedicated step for deterministic interleaving / simulation tests
    // (`*-loom-test.zig`, `*-vopr-test.zig`). Built without TSan: the
    // exhaustive enumeration is its own race detector, and TSan adds
    // multiple-minutes-per-test overhead with no marginal value.
    // Excluded from `test`, `test-tsan`, and `test-hammer` so the
    // unit-test PR signal stays fast; sharded the same way as
    // `test-tsan`/`test-hammer` for CI parallelism.
    const test_loom_vopr_step = b.step("test-loom-vopr", "Run Loom and VOPR deterministic-interleaving tests");
    // Dedicated step for Loom-only kcov runs. Distinct from `test`/`test-loom-vopr`
    // because the report is meant to answer "what atomic sites does Loom miss?"
    // and mixing in unit/TSan/VOPR coverage would defeat that.
    const coverage_loom_step = b.step("coverage-loom", "Run Loom-only tests under kcov (requires -Dcoverage-loom)");
    // Dedicated step for VOPR-only kcov runs. Mirror of coverage-loom.
    const coverage_vopr_step = b.step("coverage-vopr", "Run VOPR-only tests under kcov (requires -Dcoverage-vopr)");

    // When -Dcoverage is set, accumulate per-test kcov runs so a final
    // merge step can produce one zig-out/coverage/merged/cobertura.xml
    // for Codecov upload. The merge step depends on every kcov run so
    // it fires only after all per-test coverage dirs are populated.
    const merge_cmd = if (coverage)
        b.addSystemCommand(&.{ "kcov", "--merge", "zig-out/coverage/merged" })
    else
        null;
    if (merge_cmd) |m| {
        m.stdio = .inherit;
        m.setCwd(b.path("."));
    }
    // Same shape as `merge_cmd`, but for the Loom-only coverage tree.
    const merge_cmd_loom = if (coverage_loom)
        b.addSystemCommand(&.{ "kcov", "--merge", "zig-out/coverage-loom/merged" })
    else
        null;
    if (merge_cmd_loom) |m| {
        m.stdio = .inherit;
        m.setCwd(b.path("."));
    }
    // Same shape as `merge_cmd_loom`, but for the VOPR-only coverage tree.
    const merge_cmd_vopr = if (coverage_vopr)
        b.addSystemCommand(&.{ "kcov", "--merge", "zig-out/coverage-vopr/merged" })
    else
        null;
    if (merge_cmd_vopr) |m| {
        m.stdio = .inherit;
        m.setCwd(b.path("."));
    }

    // Counts only the test_files entries that contribute to `test_step`
    // (i.e. survive the coverage skip-list when -Dcoverage is set). Used
    // for round-robin shard assignment so each shard gets a roughly equal
    // slice of the active set, regardless of which entries got filtered.
    var test_step_idx: usize = 0;

    // kcov path args -- must use absolute --include-path (not pattern)
    // to keep Zig's stdlib out of the report. The previous
    // --include-pattern=runtime/,lib/ also matched
    // /usr/local/zig/lib/std/... and .../compiler_rt/, polluting max
    // common path -> kcov stripped only the leading "/" -> cobertura
    // emitted absolute paths (home/runner/.../zig/runtime/foo.zig) that
    // Codecov could not map to repo files (only basename-only entries
    // like switch.S survived via Codecov's basename fuzzy match).
    //
    // --strip-path trims the repo root so paths come out repo-relative
    // (zig/runtime/foo.zig). build_root is `.../zig`; its parent is the
    // repo root.
    const runtime_dir_abs = b.path("runtime").getPath(b);
    const lib_dir_abs = b.path("lib").getPath(b);
    const repo_root = std.fs.path.dirname(b.build_root.path orelse ".") orelse ".";
    const kcov_include_arg = b.fmt("--include-path={s},{s}", .{ runtime_dir_abs, lib_dir_abs });
    const kcov_strip_arg = b.fmt("--strip-path={s}/", .{repo_root});

    // build_options module exposing `coverage` and `tsan` to test code.
    // Used by per-test SkipZigTest guards in source files for kcov- /
    // TSan-hostile tests (e.g. AB/BA cycle: the LockCycle error-recovery
    // path uses just enough fiber stack that TSan's per-call shadow-
    // memory probes push it over 16 KB, overflowing into the slab
    // header). ONLY attached to test root modules (via per-test
    // addImport below) -- never to runtime modules, because the runtime
    // is also compiled by the `clear` CLI, which uses ordinary file
    // imports and has no named-module registry.
    const test_build_options = b.addOptions();
    // Note: only the regular `coverage` flag (used by `zig build test -Dcoverage`)
    // scales iteration counts down. `-Dcoverage-loom` deliberately keeps
    // the full exhaustive-enumeration depth so kcov sees every race-
    // dependent branch in the loom suite (lower depth → fewer schedules
    // → atomic ops in branches taken only on specific interleavings get
    // missed, which manifests as a misleading drop in coverage).
    test_build_options.addOption(bool, "coverage", coverage);
    test_build_options.addOption(bool, "tsan", sanitize_thread);
    const build_options_mod = test_build_options.createModule();

    // Separate options module pinned for the test-tsan step. The TSan
    // test addTest() below sets `.sanitize_thread = true`
    // unconditionally for entries with `entry.tsan = true`, so the
    // build_options module those tests see must report `tsan = true`
    // regardless of the top-level `-Dsanitize-thread` flag — otherwise
    // SkipZigTest guards keyed on `build_options.tsan` silently fall
    // through and tests that should be skipped under TSan
    // instrumentation run anyway (and crash). CI invokes
    // `zig build test-tsan` without `-Dsanitize-thread`; before this
    // split the tsan-skip path was unreachable in CI.
    const tsan_build_options = b.addOptions();
    tsan_build_options.addOption(bool, "coverage", coverage);
    tsan_build_options.addOption(bool, "tsan", true);
    const tsan_build_options_mod = tsan_build_options.createModule();
    const fiber_core_mod = b.createModule(.{ .root_source_file = fiber_core_path });
    // Mirror counter for `test_tsan_step` -- only increments on entries
    // with `tsan = true`. The TSan path uses LLVM + Debug (stage2 silently
    // drops TSan instrumentation regardless of opt level), so per-shard
    // sizing here matters more than for the regular test_step path.
    var tsan_step_idx: usize = 0;
    // Mirror counter for `test_hammer_step`. Increments only on
    // `entry.hammer = true` entries; sharded the same way so each
    // hammer CI shard gets a roughly equal slice.
    var hammer_step_idx: usize = 0;
    // Mirror counter for `test_loom_vopr_step`. Increments only on
    // `entry.loom_vopr = true` entries; sharded so each loom-vopr CI
    // shard gets a roughly equal slice.
    var loom_vopr_step_idx: usize = 0;

    for (test_files, 0..) |entry, idx| {
        const filename = entry.path;
        // Coverage runs every test-file entry, including stress /
        // loom / vopr / hammer / fuzz entries. Those files scale their
        // own iteration counts down when build_options.coverage is
        // true, so kcov gets line coverage for the surface without
        // ptracing the full stress workload.
        const skip_for_coverage = false;

        // Determine whether this iteration's test_step contribution
        // belongs to the requested shard. With shard_count=1 (default),
        // `% 1` is always 0 so every test is included -- behavior is
        // identical to the unsharded path.
        //
        // TSan-tagged entries are excluded from `test_step` entirely —
        // they run only via `test_tsan_step` (TSan-instrumented,
        // dedicated CI shards). Hammer entries are similarly routed
        // only through `test_hammer_step`. This keeps the plain unit
        // lane from duplicating the expensive concurrency surface that
        // TSan already covers.
        // Loom/vopr entries are likewise excluded from `test_step` —
        // they run only via `test_loom_vopr_step` (sharded, no TSan).
        var include_in_test_step = !skip_for_coverage and (coverage or (!entry.tsan and !entry.hammer and !entry.loom_vopr));
        if (include_in_test_step) {
            const my_shard = (test_step_idx % shard_count) == shard_index;
            test_step_idx += 1;
            include_in_test_step = my_shard;
        }

        if (include_in_test_step) {
        // Standard build (Debug, stage2 backend; coverage forces LLVM
        // backend so kcov can read complete DWARF for project .zig
        // sources -- stage2 emits limited DWARF that only exposes .S
        // files and compiler_rt, leaving project files invisible to
        // kcov regardless of include filters).
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(filename),
                .target = target,
                .optimize = optimize,
                .sanitize_thread = sanitize_thread,
            }),
            .use_llvm = if (coverage) true else null,
        });
        unit_tests.root_module.addImport("fiber-core", fiber_core_mod);
        unit_tests.root_module.addImport("safety", safety_mod);
        unit_tests.root_module.addImport("ebr", ebr_mod);
        unit_tests.root_module.addImport("ownership", ownership_mod);
        unit_tests.root_module.addImport("compat", compat_mod);
        unit_tests.root_module.addImport("build_options", build_options_mod);
        unit_tests.root_module.addAssemblyFile(switch_s);
        unit_tests.root_module.addAssemblyFile(onroot_s);
        unit_tests.root_module.link_libc = true;

        if (coverage) {
            // Numeric subdir keeps paths flat (test_files contains paths
            // like "lib/atomic.zig" that would otherwise create deep
            // dirs). kcov instruments the test binary on the fly:
            //   `kcov [opts] OUTPUT_DIR EXECUTABLE [test args]`.
            //
            // jammy's apt ships kcov v38, which does not auto-create the
            // output directory and reports "Can't open directory" if it
            // doesn't exist. v40+ creates it on demand. Pre-create with
            // `mkdir -p` so we work on either version.
            const kcov_dir = b.fmt("zig-out/coverage/{d}", .{idx});
            const mkdir_cmd = b.addSystemCommand(&.{ "mkdir", "-p", kcov_dir });
            const run_kcov = b.addSystemCommand(&.{
                "kcov",
                "--clean",
                kcov_include_arg,
                kcov_strip_arg,
                kcov_dir,
            });
            run_kcov.addArtifactArg(unit_tests);
            run_kcov.stdio = .inherit;
            run_kcov.setCwd(b.path("."));
            run_kcov.step.dependOn(&mkdir_cmd.step);
            test_step.dependOn(&run_kcov.step);
            merge_cmd.?.addArg(kcov_dir);
            merge_cmd.?.step.dependOn(&run_kcov.step);
        } else {
            const run_unit_tests = std.Build.Step.Run.create(b, b.fmt("run test {s}", .{filename}));
            run_unit_tests.addArtifactArg(unit_tests);
            run_unit_tests.stdio = .inherit;
            run_unit_tests.setCwd(b.path("."));
            test_step.dependOn(&run_unit_tests.step);
        }
        }

        // TSan / hammer builds — only for concurrency-sensitive tests.
        // Forces LLVM backend (stage2 doesn't link the TSan runtime
        // regardless of opt level). Optimize is Debug: race detection
        // is identical at any opt level (TSan instruments at the IR
        // level, not the optimized machine code), and Debug compiles
        // ~4x faster than ReleaseSafe under LLVM.
        //
        // Routing rule:
        //   entry.hammer = true  → goes into `test_hammer_step` ONLY.
        //   entry.tsan   = true  → goes into `test_tsan_step` ONLY.
        // Hammer entries are not double-counted into test-tsan; the
        // dedicated step keeps each shard's wallclock bounded.
        if (entry.tsan or entry.hammer) {
            const target_step = if (entry.hammer) test_hammer_step else test_tsan_step;
            const idx_ref = if (entry.hammer) &hammer_step_idx else &tsan_step_idx;
            const in_shard = (idx_ref.* % shard_count) == shard_index;
            idx_ref.* += 1;
            if (in_shard) {
            const tsan_tests = b.addTest(.{
                .root_module = b.createModule(.{
                    .root_source_file = b.path(filename),
                    .target = target,
                    .optimize = .Debug,
                    .sanitize_thread = true,
                }),
                .use_llvm = true,
            });
            tsan_tests.root_module.addImport("fiber-core", fiber_core_mod);
            tsan_tests.root_module.addImport("safety", safety_mod);
            tsan_tests.root_module.addImport("ebr", ebr_mod);
            tsan_tests.root_module.addImport("ownership", ownership_mod);
            tsan_tests.root_module.addImport("compat", compat_mod);
            tsan_tests.root_module.addImport("build_options", tsan_build_options_mod);
            tsan_tests.root_module.addAssemblyFile(switch_s);
            tsan_tests.root_module.addAssemblyFile(onroot_s);
            tsan_tests.root_module.link_libc = true;

            const label = if (entry.hammer) "hammer" else "tsan";
            const run_tsan_tests = std.Build.Step.Run.create(b, b.fmt("run {s} {s}", .{ label, filename }));
            run_tsan_tests.addArtifactArg(tsan_tests);
            run_tsan_tests.stdio = .inherit;
            run_tsan_tests.setCwd(b.path("."));
            target_step.dependOn(&run_tsan_tests.step);
            }
        }

        // Loom / VOPR builds — deterministic interleaving / simulation.
        // No TSan: the exhaustive enumeration is its own race detector,
        // and TSan adds multiple-minutes-per-test overhead with zero
        // marginal value. Sharded the same way as TSan/hammer.
        if (entry.loom_vopr) {
            const in_shard = (loom_vopr_step_idx % shard_count) == shard_index;
            loom_vopr_step_idx += 1;
            // Loom-only filter for the coverage-loom report. VOPR test
            // entries (`*-vopr-test.zig`) are excluded -- VOPR is a
            // single-threaded simulator and shouldn't count as Loom coverage.
            const is_loom_only = std.mem.endsWith(u8, filename, "-loom-test.zig");
            const is_vopr_only = std.mem.endsWith(u8, filename, "-vopr-test.zig");
            if (in_shard) {
                const lv_tests = b.addTest(.{
                    .root_module = b.createModule(.{
                        .root_source_file = b.path(filename),
                        .target = target,
                        .optimize = optimize,
                    }),
                    // Force LLVM when collecting Loom or VOPR kcov for
                    // the same reason as the regular coverage path:
                    // stage2 emits limited DWARF and project .zig sources
                    // are otherwise invisible to kcov.
                    .use_llvm = if ((coverage_loom and is_loom_only) or (coverage_vopr and is_vopr_only)) true else null,
                });
                lv_tests.root_module.addImport("fiber-core", fiber_core_mod);
                lv_tests.root_module.addImport("safety", safety_mod);
                lv_tests.root_module.addImport("ebr", ebr_mod);
                lv_tests.root_module.addImport("ownership", ownership_mod);
                lv_tests.root_module.addImport("compat", compat_mod);
                lv_tests.root_module.addImport("build_options", build_options_mod);
                lv_tests.root_module.addAssemblyFile(switch_s);
                lv_tests.root_module.addAssemblyFile(onroot_s);
                lv_tests.root_module.link_libc = true;

                if (coverage_loom and is_loom_only) {
                    const kcov_dir = b.fmt("zig-out/coverage-loom/{d}", .{idx});
                    const mkdir_cmd = b.addSystemCommand(&.{ "mkdir", "-p", kcov_dir });
                    const run_kcov = b.addSystemCommand(&.{
                        "kcov",
                        "--clean",
                        kcov_include_arg,
                        kcov_strip_arg,
                        kcov_dir,
                    });
                    run_kcov.addArtifactArg(lv_tests);
                    run_kcov.stdio = .inherit;
                    run_kcov.setCwd(b.path("."));
                    run_kcov.step.dependOn(&mkdir_cmd.step);
                    coverage_loom_step.dependOn(&run_kcov.step);
                    merge_cmd_loom.?.addArg(kcov_dir);
                    merge_cmd_loom.?.step.dependOn(&run_kcov.step);
                } else if (coverage_vopr and is_vopr_only) {
                    const kcov_dir = b.fmt("zig-out/coverage-vopr/{d}", .{idx});
                    const mkdir_cmd = b.addSystemCommand(&.{ "mkdir", "-p", kcov_dir });
                    const run_kcov = b.addSystemCommand(&.{
                        "kcov",
                        "--clean",
                        kcov_include_arg,
                        kcov_strip_arg,
                        kcov_dir,
                    });
                    run_kcov.addArtifactArg(lv_tests);
                    run_kcov.stdio = .inherit;
                    run_kcov.setCwd(b.path("."));
                    run_kcov.step.dependOn(&mkdir_cmd.step);
                    coverage_vopr_step.dependOn(&run_kcov.step);
                    merge_cmd_vopr.?.addArg(kcov_dir);
                    merge_cmd_vopr.?.step.dependOn(&run_kcov.step);
                } else {
                    const run_lv_tests = std.Build.Step.Run.create(b, b.fmt("run loom-vopr {s}", .{filename}));
                    run_lv_tests.addArtifactArg(lv_tests);
                    run_lv_tests.stdio = .inherit;
                    run_lv_tests.setCwd(b.path("."));
                    test_loom_vopr_step.dependOn(&run_lv_tests.step);
                }
            }
        }
    }

    if (merge_cmd) |m| test_step.dependOn(&m.step);
    if (merge_cmd_loom) |m| coverage_loom_step.dependOn(&m.step);
    if (merge_cmd_vopr) |m| coverage_vopr_step.dependOn(&m.step);

    // -------------------------------------------------------------------------
    // BENCHMARKS (zig build benchmark)
    // -------------------------------------------------------------------------
    const bench_step = b.step("benchmark", "Run performance benchmarks");
    const bench_locks_step = b.step("bench-locks", "Run only the parking-lot benchmark");

    const benchmark_files = [_][]const u8{
        "arena-benchmark-test.zig",
        "benchmark-test.zig",
        "safety-benchmark-test.zig",
        "slab-alloc-benchmark-test.zig",
        "queues-benchmark-test.zig",
        "scheduler-benchmark-test.zig",
        "parking-lot-benchmark-test.zig",
        "versioned-benchmark-test.zig",
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

        bench_tests.root_module.addImport("fiber-core", fiber_core_mod);
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
        if (std.mem.eql(u8, filename, "parking-lot-benchmark-test.zig")) {
            bench_locks_step.dependOn(&run_bench.step);
        }
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
        hammer_tests.root_module.addImport("fiber-core", fiber_core_mod);
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
        hammer_exe.root_module.addImport("fiber-core", fiber_core_mod);
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
            // Wrapper at zig/ root re-exports runtime/vopr.zig's main.
            // Required so the module's path (zig/) covers both runtime/
            // and lib/ -- runtime files use relative ../lib/ imports
            // and would otherwise fail "import outside module path".
            // Mirrors the unit-test shim pattern (vopr-test.zig).
            .root_source_file = b.path("vopr.zig"),
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
    // Module root is `zig/` (not `runtime/`) so runtime/*.zig files can
    // `@import("../lib/foo.zig")` — Zig 0.16 rejects `../lib/` imports
    // when the module root is `runtime/`. The wrapper at zig/vopr-loom-runner.zig
    // re-exports SimAtomic / SimRing so the comptime Atomic alias in
    // queues.zig picks SimAtomic via @import("root").
    const loom_exe = b.addExecutable(.{
        .name = "loom",
        .root_module = b.createModule(.{
            .root_source_file = b.path("vopr-loom-runner.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    // Loom needs the fiber switch + onRoot assembly because it actually
    // runs scheduler/fiber code (unlike VOPR which simulates the queue
    // alone and never calls switchContext).
    loom_exe.root_module.addAssemblyFile(switch_s);
    loom_exe.root_module.addAssemblyFile(onroot_s);
    loom_exe.root_module.link_libc = true;
    const run_loom = b.addRunArtifact(loom_exe);
    run_loom.has_side_effects = true;
    loom_step.dependOn(&run_loom.step);

    // parking-lot-loom — built as an executable so `@import("root")` from
    // inside lib/parking-lot.zig and runtime/queues.zig resolves to the
    // entry file (parking-lot-loom-test.zig). The entry has
    // `pub const SimAtomic` — the comptime Atomic alias picks SimAtomic
    // and the suite loom-tests instead of running on real atomics. See
    // GAP-B in docs/agents/parking-lot-loom-coverage.md.
    //
    // Module root is `zig/` (not `runtime/`) because runtime/ files like
    // fiber-core.zig do `@import("../lib/safety.zig")` and Zig 0.16
    // rejects `../lib/` imports when the module root is `runtime/`. See
    // commit 9544787a.
    const pl_loom_exe = b.addExecutable(.{
        .name = "parking-lot-loom",
        .root_module = b.createModule(.{
            .root_source_file = b.path("parking-lot-loom-test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        // Same reason as the unit-test path: stage2 emits limited DWARF
        // and kcov sees only the embedded .S files. Force LLVM under
        // -Dcoverage-loom so project .zig sources land in the report.
        .use_llvm = if (coverage_loom) true else null,
    });
    pl_loom_exe.root_module.addImport("build_options", build_options_mod);
    pl_loom_exe.root_module.addAssemblyFile(switch_s);
    pl_loom_exe.root_module.addAssemblyFile(onroot_s);
    pl_loom_exe.root_module.link_libc = true;
    const run_pl_loom = b.addRunArtifact(pl_loom_exe);
    run_pl_loom.has_side_effects = true;
    run_pl_loom.stdio = .inherit;
    if (coverage and shard_index == 0) {
        const pl_loom_kcov_dir = "zig-out/coverage/parking-lot-loom";
        const mkdir_cmd = b.addSystemCommand(&.{ "mkdir", "-p", pl_loom_kcov_dir });
        const run_pl_loom_kcov = b.addSystemCommand(&.{
            "kcov",
            "--clean",
            kcov_include_arg,
            kcov_strip_arg,
            pl_loom_kcov_dir,
        });
        run_pl_loom_kcov.addArtifactArg(pl_loom_exe);
        run_pl_loom_kcov.stdio = .inherit;
        run_pl_loom_kcov.setCwd(b.path("."));
        run_pl_loom_kcov.step.dependOn(&mkdir_cmd.step);
        test_step.dependOn(&run_pl_loom_kcov.step);
        merge_cmd.?.addArg(pl_loom_kcov_dir);
        merge_cmd.?.step.dependOn(&run_pl_loom_kcov.step);
    } else if (!coverage and shard_index == 0) {
        test_loom_vopr_step.dependOn(&run_pl_loom.step);
    }
    // Loom-only coverage: route parking-lot-loom into the dedicated tree.
    // Independent of the `coverage`/`!coverage` branches above so this can
    // be combined or run on its own without mixing with the unit-test report.
    if (coverage_loom and shard_index == 0) {
        const pl_loom_kcov_dir = "zig-out/coverage-loom/parking-lot-loom";
        const mkdir_cmd = b.addSystemCommand(&.{ "mkdir", "-p", pl_loom_kcov_dir });
        const run_pl_loom_kcov = b.addSystemCommand(&.{
            "kcov",
            "--clean",
            kcov_include_arg,
            kcov_strip_arg,
            pl_loom_kcov_dir,
        });
        run_pl_loom_kcov.addArtifactArg(pl_loom_exe);
        run_pl_loom_kcov.stdio = .inherit;
        run_pl_loom_kcov.setCwd(b.path("."));
        run_pl_loom_kcov.step.dependOn(&mkdir_cmd.step);
        coverage_loom_step.dependOn(&run_pl_loom_kcov.step);
        merge_cmd_loom.?.addArg(pl_loom_kcov_dir);
        merge_cmd_loom.?.step.dependOn(&run_pl_loom_kcov.step);
    }
    loom_step.dependOn(&run_pl_loom.step);

    // VOPR executables. Built as `b.addExecutable` (NOT `b.addTest`)
    // so `@import("root")` from inside lib/compat.zig resolves to the
    // entry file (`pub const SimClock = ...`). Without this, the
    // comptime SimClock / SimRandom seam in compat.zig silently falls
    // through to OS clock_gettime / getrandom -- same GAP-B issue
    // parking-lot-loom hit pre-2026-05.
    const VoprExe = struct {
        name: []const u8,
        entry: []const u8, // path under zig/, e.g. "scheduler-timeout-vopr-test.zig"
    };
    const vopr_exes = [_]VoprExe{
        .{ .name = "scheduler-timeout-vopr", .entry = "scheduler-timeout-vopr-test.zig" },
        .{ .name = "atomic-ptr-vopr", .entry = "atomic-ptr-vopr-test.zig" },
        .{ .name = "versioned-vopr", .entry = "versioned-vopr-test.zig" },
        .{ .name = "fsm-lock-vopr", .entry = "fsm-lock-vopr-test.zig" },
        .{ .name = "fsm-vopr", .entry = "fsm-vopr-test.zig" },
        .{ .name = "vopr-runqueue", .entry = "vopr-test.zig" },
        .{ .name = "data-structures-vopr", .entry = "data-structures-vopr-test.zig" },
    };
    for (vopr_exes) |ve| {
        const exe = b.addExecutable(.{
            .name = ve.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(ve.entry),
                .target = target,
                .optimize = optimize,
            }),
            .use_llvm = if (coverage_vopr) true else null,
        });
        exe.root_module.addImport("build_options", build_options_mod);
        exe.root_module.addAssemblyFile(switch_s);
        exe.root_module.addAssemblyFile(onroot_s);
        exe.root_module.link_libc = true;
        const run_exe = b.addRunArtifact(exe);
        run_exe.has_side_effects = true;
        run_exe.stdio = .inherit;
        if (!coverage_vopr and shard_index == 0) {
            test_loom_vopr_step.dependOn(&run_exe.step);
        }
        if (coverage_vopr and shard_index == 0) {
            const kcov_dir = b.fmt("zig-out/coverage-vopr/{s}", .{ve.name});
            const mkdir_cmd = b.addSystemCommand(&.{ "mkdir", "-p", kcov_dir });
            const run_kcov = b.addSystemCommand(&.{
                "kcov",
                "--clean",
                kcov_include_arg,
                kcov_strip_arg,
                kcov_dir,
            });
            run_kcov.addArtifactArg(exe);
            run_kcov.stdio = .inherit;
            run_kcov.setCwd(b.path("."));
            run_kcov.step.dependOn(&mkdir_cmd.step);
            coverage_vopr_step.dependOn(&run_kcov.step);
            merge_cmd_vopr.?.addArg(kcov_dir);
            merge_cmd_vopr.?.step.dependOn(&run_kcov.step);
        }
    }

    const versioned_loom_exe = b.addExecutable(.{
        .name = "versioned-loom-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("versioned-loom-test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    versioned_loom_exe.root_module.addAssemblyFile(switch_s);
    versioned_loom_exe.root_module.addAssemblyFile(onroot_s);
    versioned_loom_exe.root_module.link_libc = true;
    const run_versioned_loom = b.addRunArtifact(versioned_loom_exe);
    run_versioned_loom.has_side_effects = true;
    run_versioned_loom.stdio = .inherit;
    if (shard_index == 0) {
        test_loom_vopr_step.dependOn(&run_versioned_loom.step);
    }
    loom_step.dependOn(&run_versioned_loom.step);

    // versioned-multi-loom -- multi-fiber Loom harness for updateMulti
    // contention. Built as an executable so `@import("root")` resolves
    // to versioned-multi-loom-test.zig, exposing both `pub const SimAtomic`
    // and `pub const CLEAR_MVCC_MAX_INNER_RETRIES_MULTI = 4`. Drives two
    // fibers updating overlapping cell-sets through deterministic
    // schedules to reach the contention-rollback branch at versioned.zig:565.
    const vm_loom_exe = b.addExecutable(.{
        .name = "versioned-multi-loom",
        .root_module = b.createModule(.{
            .root_source_file = b.path("versioned-multi-loom-test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = if (coverage_loom) true else null,
    });
    vm_loom_exe.root_module.addAssemblyFile(switch_s);
    vm_loom_exe.root_module.addAssemblyFile(onroot_s);
    vm_loom_exe.root_module.link_libc = true;
    const run_vm_loom = b.addRunArtifact(vm_loom_exe);
    run_vm_loom.has_side_effects = true;
    run_vm_loom.stdio = .inherit;
    if (shard_index == 0) {
        test_loom_vopr_step.dependOn(&run_vm_loom.step);
    }
    loom_step.dependOn(&run_vm_loom.step);
    if (coverage_loom and shard_index == 0) {
        const vm_loom_kcov_dir = "zig-out/coverage-loom/versioned-multi-loom";
        const mkdir_cmd = b.addSystemCommand(&.{ "mkdir", "-p", vm_loom_kcov_dir });
        const run_vm_loom_kcov = b.addSystemCommand(&.{
            "kcov",
            "--clean",
            kcov_include_arg,
            kcov_strip_arg,
            vm_loom_kcov_dir,
        });
        run_vm_loom_kcov.addArtifactArg(vm_loom_exe);
        run_vm_loom_kcov.stdio = .inherit;
        run_vm_loom_kcov.setCwd(b.path("."));
        run_vm_loom_kcov.step.dependOn(&mkdir_cmd.step);
        coverage_loom_step.dependOn(&run_vm_loom_kcov.step);
        merge_cmd_loom.?.addArg(vm_loom_kcov_dir);
        merge_cmd_loom.?.step.dependOn(&run_vm_loom_kcov.step);
    }

    // ownership-loom -- multi-fiber Loom harness for Arc<T> / Weak<T>
    // refcount races. Same shape as versioned-multi-loom: standalone
    // exe so `pub const SimAtomic` at root flips lib/ownership.zig's
    // comptime alias. Three scenarios per run cover clone/deinit,
    // weak-upgrade vs strong-drop, and concurrent downgrade.
    const ow_loom_exe = b.addExecutable(.{
        .name = "ownership-loom",
        .root_module = b.createModule(.{
            .root_source_file = b.path("ownership-loom-test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = if (coverage_loom) true else null,
    });
    ow_loom_exe.root_module.addAssemblyFile(switch_s);
    ow_loom_exe.root_module.addAssemblyFile(onroot_s);
    ow_loom_exe.root_module.link_libc = true;
    const run_ow_loom = b.addRunArtifact(ow_loom_exe);
    run_ow_loom.has_side_effects = true;
    run_ow_loom.stdio = .inherit;
    if (shard_index == 0) {
        test_loom_vopr_step.dependOn(&run_ow_loom.step);
    }
    loom_step.dependOn(&run_ow_loom.step);
    if (coverage_loom and shard_index == 0) {
        const ow_loom_kcov_dir = "zig-out/coverage-loom/ownership-loom";
        const mkdir_cmd = b.addSystemCommand(&.{ "mkdir", "-p", ow_loom_kcov_dir });
        const run_ow_loom_kcov = b.addSystemCommand(&.{
            "kcov",
            "--clean",
            kcov_include_arg,
            kcov_strip_arg,
            ow_loom_kcov_dir,
        });
        run_ow_loom_kcov.addArtifactArg(ow_loom_exe);
        run_ow_loom_kcov.stdio = .inherit;
        run_ow_loom_kcov.setCwd(b.path("."));
        run_ow_loom_kcov.step.dependOn(&mkdir_cmd.step);
        coverage_loom_step.dependOn(&run_ow_loom_kcov.step);
        merge_cmd_loom.?.addArg(ow_loom_kcov_dir);
        merge_cmd_loom.?.step.dependOn(&run_ow_loom_kcov.step);
    }

    // -------------------------------------------------------------------------
    // VERSIONED-EXHAUST -- Deterministic MVCC retry-exhaustion check
    // -------------------------------------------------------------------------
    // Builds zig/versioned-exhaust.zig as a standalone exe whose root
    // declares `pub const CLEAR_MVCC_MAX_UPDATE_RETRIES = 50`. The
    // runtime's `@hasDecl(@import("root"), ...)` reads this and lowers
    // the inner CAS retry cap from 10K to 50, so 8 contending writers
    // deterministically hit `error.UpdateRetriesExhausted` -- closing
    // the test gap that the stochastic stress test in
    // versioned-stress-test.zig left open. Folded into the `hammer`
    // step alongside the other concurrent stress tests.
    const versioned_exhaust_step = b.step("versioned-exhaust", "Run deterministic MVCC retry-exhaustion check");
    const versioned_exhaust_exe = b.addExecutable(.{
        .name = "versioned-exhaust",
        .root_module = b.createModule(.{
            .root_source_file = b.path("versioned-exhaust.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    versioned_exhaust_exe.root_module.addAssemblyFile(switch_s);
    versioned_exhaust_exe.root_module.addAssemblyFile(onroot_s);
    versioned_exhaust_exe.root_module.link_libc = true;
    const run_versioned_exhaust = b.addRunArtifact(versioned_exhaust_exe);
    run_versioned_exhaust.has_side_effects = true;
    versioned_exhaust_step.dependOn(&run_versioned_exhaust.step);
    hammer_step.dependOn(&run_versioned_exhaust.step);

    // -------------------------------------------------------------------------
    // STATIC LIBRARY (cheat-runtime)
    // -------------------------------------------------------------------------
    // The library's root is the wrapper at zig/cheat_runtime.zig (which
    // re-exports runtime/runtime-header.zig). Rooting at zig/ -- not
    // runtime/ -- means the module's path covers both runtime/ and lib/,
    // so runtime files' relative `../lib/...` imports resolve. Mirrors
    // the vopr/loom pattern (see comments at vopr_step / loom_step
    // above). Without the wrapper, every relative import to lib/ fails
    // with "import of file outside module path".
    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "cheat-runtime",
        .root_module = b.createModule(.{
            .root_source_file = b.path("cheat_runtime.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    lib.root_module.addImport("fiber-core", fiber_core_mod);
    lib.root_module.addImport("safety", safety_mod);
    lib.root_module.addImport("ebr", ebr_mod);
    lib.root_module.addImport("ownership", ownership_mod);
    lib.root_module.addImport("compat", compat_mod);
    lib.root_module.addAssemblyFile(switch_s);
    lib.root_module.addAssemblyFile(onroot_s);
    lib.root_module.link_libc = true;
    b.installArtifact(lib);
}
