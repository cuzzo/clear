const std = @import("std");
const zig_mutants = @import("zig_mutants");

const Allocator = std.mem.Allocator;
const DEFAULT_OUT_DIR = "/tmp/zig-mutants";
const DEFAULT_BUILD_CACHE_DIR = "/tmp/zig-mutants-build-cache";

const Options = struct {
    command: Command,
    root: []const u8 = ".",
    out_dir: []const u8 = DEFAULT_OUT_DIR,
    artifact_dir: ?[]const u8 = null,
    build_cache_dir: []const u8 = DEFAULT_BUILD_CACHE_DIR,
    manifest_path: ?[]const u8 = null,
    ratchet_path: ?[]const u8 = null,
    facts_path: ?[]const u8 = null,
    test_command: ?[]const u8 = null,
    since: ?[]const u8 = null,
    diff_file: ?[]const u8 = null,
    sources: std.array_list.Managed([]const u8),
    max_mutants: ?usize = null,
    shard_index: usize = 0,
    shard_count: usize = 1,
    timeout_seconds: u32 = 120,
    json: bool = false,
    hard_gate: bool = false,
    test_miser: bool = false,
    mutation_switching: bool = false,
    test_selection: bool = true,

    const Command = enum { list, run, help };

    fn deinit(self: *Options) void {
        self.sources.deinit();
    }
};

const Subject = struct {
    source: []const u8,
    test_command: []const u8,
    test_commands: [][]const u8,
    timeout_seconds: u32,

    fn deinit(self: Subject, allocator: Allocator) void {
        allocator.free(self.source);
        allocator.free(self.test_command);
        for (self.test_commands) |command| allocator.free(command);
        allocator.free(self.test_commands);
    }
};

const Manifest = struct {
    subjects: []ManifestSubject,
};

const ManifestSubject = struct {
    source: []const u8,
    test_command: ?[]const u8 = null,
    test_commands: ?[][]const u8 = null,
    timeout_seconds: ?u32 = null,
};

pub fn main(init: std.process.Init) !void {
    var opts = try parseOptions(init.gpa, init.minimal.args);
    defer opts.deinit();

    switch (opts.command) {
        .help => {
            usage();
            return;
        },
        .list => try listMutants(init.gpa, init.io, opts),
        .run => try runMutants(init.gpa, init.io, opts),
    }
}

fn parseOptions(allocator: Allocator, args: std.process.Args) !Options {
    var iter = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer iter.deinit();
    _ = iter.next();

    const command_text = iter.next() orelse "help";
    var opts = Options{
        .command = parseCommand(command_text),
        .sources = std.array_list.Managed([]const u8).init(allocator),
    };

    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--source")) {
            try opts.sources.append(iter.next() orelse return error.MissingOptionValue);
        } else if (std.mem.eql(u8, arg, "--root")) {
            opts.root = iter.next() orelse return error.MissingOptionValue;
        } else if (std.mem.eql(u8, arg, "--out")) {
            opts.out_dir = iter.next() orelse return error.MissingOptionValue;
        } else if (std.mem.eql(u8, arg, "--artifact-dir")) {
            opts.artifact_dir = iter.next() orelse return error.MissingOptionValue;
        } else if (std.mem.eql(u8, arg, "--build-cache")) {
            opts.build_cache_dir = iter.next() orelse return error.MissingOptionValue;
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            opts.manifest_path = iter.next() orelse return error.MissingOptionValue;
        } else if (std.mem.eql(u8, arg, "--facts")) {
            opts.facts_path = iter.next() orelse return error.MissingOptionValue;
        } else if (std.mem.eql(u8, arg, "--ratchet")) {
            opts.ratchet_path = iter.next() orelse return error.MissingOptionValue;
        } else if (std.mem.eql(u8, arg, "--test-command")) {
            opts.test_command = iter.next() orelse return error.MissingOptionValue;
        } else if (std.mem.eql(u8, arg, "--since")) {
            opts.since = iter.next() orelse return error.MissingOptionValue;
        } else if (std.mem.eql(u8, arg, "--diff-file")) {
            opts.diff_file = iter.next() orelse return error.MissingOptionValue;
        } else if (std.mem.eql(u8, arg, "--max-mutants")) {
            opts.max_mutants = try std.fmt.parseInt(usize, iter.next() orelse return error.MissingOptionValue, 10);
        } else if (std.mem.eql(u8, arg, "--shard")) {
            const shard = iter.next() orelse return error.MissingOptionValue;
            const parsed = try parseShard(shard);
            opts.shard_index = parsed.index;
            opts.shard_count = parsed.count;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            opts.timeout_seconds = try std.fmt.parseInt(u32, iter.next() orelse return error.MissingOptionValue, 10);
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, arg, "--hard-gate")) {
            opts.hard_gate = true;
        } else if (std.mem.eql(u8, arg, "--test-miser")) {
            opts.test_miser = true;
        } else if (std.mem.eql(u8, arg, "--mutation-switching")) {
            opts.mutation_switching = true;
        } else if (std.mem.eql(u8, arg, "--no-test-selection")) {
            opts.test_selection = false;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            opts.command = .help;
        } else {
            std.debug.print("unknown option: {s}\n", .{arg});
            return error.UnknownOption;
        }
    }

    if (opts.command != .help and opts.sources.items.len == 0 and opts.manifest_path == null) {
        std.debug.print("at least one --source or --manifest is required\n", .{});
        return error.MissingSource;
    }
    if (opts.shard_count == 0 or opts.shard_index >= opts.shard_count) {
        std.debug.print("--shard must be INDEX/COUNT with INDEX < COUNT\n", .{});
        return error.InvalidShard;
    }
    if (opts.command == .run and opts.test_command == null and opts.manifest_path == null) {
        std.debug.print("--test-command is required for run without --manifest\n", .{});
        return error.MissingTestCommand;
    }
    if (opts.since != null and opts.diff_file != null) {
        std.debug.print("--since and --diff-file are mutually exclusive\n", .{});
        return error.ConflictingDiffOptions;
    }
    return opts;
}

const Shard = struct {
    index: usize,
    count: usize,
};

fn parseShard(value: []const u8) !Shard {
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return error.InvalidShard;
    return .{
        .index = try std.fmt.parseInt(usize, value[0..slash], 10),
        .count = try std.fmt.parseInt(usize, value[slash + 1 ..], 10),
    };
}

fn parseCommand(command: []const u8) Options.Command {
    if (std.mem.eql(u8, command, "list")) return .list;
    if (std.mem.eql(u8, command, "run")) return .run;
    return .help;
}

fn usage() void {
    std.debug.print(
        \\Usage:
        \\  zig-mutants list (--source FILE | --manifest FILE) [--since REV | --diff-file PATCH] [--json]
        \\  zig-mutants run --root DIR (--source FILE | --manifest FILE) [--since REV | --diff-file PATCH] [--mutation-switching] [--no-test-selection] [--test-command CMD] [--facts FILE] [--test-miser] [--out DIR] [--artifact-dir DIR] [--build-cache DIR] [--shard INDEX/COUNT] [--ratchet FACTS]
        \\
        \\Examples:
        \\  zig build -Doptimize=ReleaseSafe run -- list --source ../../zig/lib/safety.zig
        \\  zig build run -- list --root ../.. --manifest subjects.json --json
        \\  zig build run -- run --root ../.. --source zig/lib/safety.zig --test-command "cd zig && zig build test" --facts /tmp/zig-mutants.json
        \\
    , .{});
}

fn loadSubjects(allocator: Allocator, io: std.Io, opts: Options) ![]Subject {
    var subjects = std.array_list.Managed(Subject).init(allocator);
    errdefer {
        for (subjects.items) |subject| subject.deinit(allocator);
        subjects.deinit();
    }

    if (opts.manifest_path) |manifest_path| {
        {
            const loaded = try loadManifestSubjects(allocator, io, manifest_path, opts.test_command);
            errdefer freeSubjects(allocator, loaded);
            try subjects.appendSlice(loaded);
            allocator.free(loaded);
        }
    }

    for (opts.sources.items) |source| {
        const commands = try copyTestCommands(allocator, opts.test_command orelse "", null);
        errdefer freeTestCommands(allocator, commands);
        try subjects.append(.{
            .source = try allocator.dupe(u8, source),
            .test_command = try allocator.dupe(u8, opts.test_command orelse ""),
            .test_commands = commands,
            .timeout_seconds = opts.timeout_seconds,
        });
    }

    return subjects.toOwnedSlice();
}

fn loadManifestSubjects(
    allocator: Allocator,
    io: std.Io,
    manifest_path: []const u8,
    command_override: ?[]const u8,
) ![]Subject {
    const bytes = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        manifest_path,
        allocator,
        .limited(8 * 1024 * 1024),
        .of(u8),
        0,
    );
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(Manifest, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var subjects = std.array_list.Managed(Subject).init(allocator);
    errdefer {
        for (subjects.items) |subject| subject.deinit(allocator);
        subjects.deinit();
    }

    for (parsed.value.subjects) |subject| {
        const command = command_override orelse subject.test_command orelse "";
        const command_list = if (command_override != null)
            try copyTestCommands(allocator, command, null)
        else
            try copyTestCommands(allocator, command, subject.test_commands);
        errdefer freeTestCommands(allocator, command_list);
        const joined = try joinTestCommands(allocator, command_list, " && ");
        errdefer allocator.free(joined);
        try subjects.append(.{
            .source = try allocator.dupe(u8, subject.source),
            .test_command = joined,
            .test_commands = command_list,
            .timeout_seconds = subject.timeout_seconds orelse 120,
        });
    }
    return subjects.toOwnedSlice();
}

fn copyTestCommands(allocator: Allocator, legacy: []const u8, commands: ?[][]const u8) ![][]const u8 {
    var copied = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (copied.items) |command| allocator.free(command);
        copied.deinit();
    }
    if (commands) |items| {
        for (items) |command| try copied.append(try allocator.dupe(u8, command));
    } else {
        var parts = std.mem.splitSequence(u8, legacy, "&&");
        var setup: ?[]const u8 = null;
        while (parts.next()) |part| {
            const command = std.mem.trim(u8, part, " \t\r\n");
            if (command.len == 0) continue;
            if (copied.items.len == 0 and setup == null and std.mem.startsWith(u8, command, "cd ")) {
                setup = command;
                continue;
            }
            if (setup) |prefix| {
                try copied.append(try std.fmt.allocPrint(allocator, "{s} && {s}", .{ prefix, command }));
            } else {
                try copied.append(try allocator.dupe(u8, command));
            }
        }
        if (copied.items.len == 0 and setup != null) try copied.append(try allocator.dupe(u8, setup.?));
    }
    return copied.toOwnedSlice();
}

fn freeTestCommands(allocator: Allocator, commands: [][]const u8) void {
    for (commands) |command| allocator.free(command);
    allocator.free(commands);
}

fn joinTestCommands(allocator: Allocator, commands: []const []const u8, separator: []const u8) ![]u8 {
    return std.mem.join(allocator, separator, commands);
}

fn freeSubjects(allocator: Allocator, subjects: []Subject) void {
    for (subjects) |subject| subject.deinit(allocator);
    allocator.free(subjects);
}

fn subjectSources(allocator: Allocator, subjects: []const Subject) ![][]const u8 {
    const sources = try allocator.alloc([]const u8, subjects.len);
    for (subjects, 0..) |subject, index| sources[index] = subject.source;
    return sources;
}

fn listMutants(allocator: Allocator, io: std.Io, opts: Options) !void {
    const subjects = try loadSubjects(allocator, io, opts);
    defer freeSubjects(allocator, subjects);
    const sources = try subjectSources(allocator, subjects);
    defer allocator.free(sources);
    const mutants = try discoverAll(allocator, io, opts.root, sources);
    defer zig_mutants.freeMutants(allocator, mutants);
    var changed = try loadChangedLines(allocator, io, opts);
    defer if (changed) |lines| lines.deinit();

    if (opts.json) {
        const selected = try selectChangedMutants(allocator, mutants, if (changed) |*lines| lines else null);
        defer allocator.free(selected);
        try printMutantsJson(allocator, io, selected);
        return;
    }

    var selected_count: usize = 0;
    for (mutants) |mutant| {
        if (!selectedByChangedLines(mutant, if (changed) |*lines| lines else null)) continue;
        selected_count += 1;
        std.debug.print("{s}:{d}:{d}: {s} replace `{s}` with `{s}`\n", .{
            mutant.path,
            mutant.line,
            mutant.column,
            mutant.kind.label(),
            mutant.original,
            mutant.replacement,
        });
    }
    std.debug.print("{d} mutants selected ({d} discovered)\n", .{ selected_count, mutants.len });
}

fn runMutantsSwitching(allocator: Allocator, io: std.Io, opts: Options) anyerror!void {
    const subjects = try loadSubjects(allocator, io, opts);
    defer freeSubjects(allocator, subjects);
    const sources = try subjectSources(allocator, subjects);
    defer allocator.free(sources);
    const mutants = try discoverAll(allocator, io, opts.root, sources);
    defer zig_mutants.freeMutants(allocator, mutants);
    var changed = try loadChangedLines(allocator, io, opts);
    defer if (changed) |lines| lines.deinit();

    const work_dir = try effectiveWorkDir(allocator, opts);
    defer if (!std.mem.eql(u8, work_dir, opts.out_dir)) allocator.free(work_dir);
    const artifact_dir = try effectiveArtifactDir(allocator, opts, work_dir);
    defer if (opts.artifact_dir == null) allocator.free(artifact_dir);
    try copyWorkspace(allocator, io, opts.root, work_dir);

    for (subjects) |subject| {
        if (!subjectSelected(subject, mutants, opts, if (changed) |*lines| lines else null)) continue;
        for (subject.test_commands) |command| {
            const baseline = try runShell(allocator, io, work_dir, command, subject.timeout_seconds);
            defer baseline.deinit(allocator);
            if (!baseline.success()) {
                std.debug.print("baseline failed for {s}; refusing to test mutants\n{s}{s}\n", .{
                    subject.source,
                    baseline.stdout,
                    baseline.stderr,
                });
                return error.BaselineFailed;
            }
        }
    }

    const runtime_source = try zig_mutants.instrumentation.runtimeSource(allocator, mutants.len);
    defer allocator.free(runtime_source);

    var test_records = std.array_list.Managed(zig_mutants.TestRecord).init(allocator);
    defer {
        for (test_records.items) |record| record.deinit(allocator);
        test_records.deinit();
    }

    for (subjects) |subject| {
        const source_path = try std.fs.path.join(allocator, &.{ work_dir, subject.source });
        defer allocator.free(source_path);
        const original = try std.Io.Dir.cwd().readFileAllocOptions(
            io,
            source_path,
            allocator,
            .limited(32 * 1024 * 1024),
            .of(u8),
            0,
        );
        defer allocator.free(original);

        var sites = std.array_list.Managed(zig_mutants.instrumentation.Site).init(allocator);
        defer sites.deinit();
        for (mutants, 0..) |mutant, index| {
            if (!std.mem.eql(u8, mutant.path, subject.source)) continue;
            if (!selectedForRun(mutant, index, opts, if (changed) |*lines| lines else null)) continue;
            try sites.append(.{
                .index = index,
                .kind = mutant.kind,
                .start = mutant.start,
                .end = mutant.end,
                .replacement = mutant.replacement,
            });
        }
        if (sites.items.len == 0) continue;

        const source_dir = std.fs.path.dirname(source_path) orelse work_dir;
        const runtime_path = try std.fs.path.join(allocator, &.{ source_dir, ".zig-mutants-runtime.zig" });
        defer allocator.free(runtime_path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = runtime_path, .data = runtime_source });
        const runtime_import = ".zig-mutants-runtime.zig";
        const switched = zig_mutants.instrumentation.instrumentMutants(
            allocator,
            original,
            sites.items,
            runtime_import,
        ) catch |err| {
            std.debug.print("mutation switching unavailable for {s} ({s}); using legacy execution\n", .{
                subject.source,
                @errorName(err),
            });
            var fallback = opts;
            fallback.mutation_switching = false;
            return runMutants(allocator, io, fallback);
        };
        defer allocator.free(switched);
        const switched_z = try allocator.dupeZ(u8, switched);
        defer allocator.free(switched_z);
        const tests = try zig_mutants.instrumentation.discoverTests(
            allocator,
            switched_z,
            test_records.items.len,
        );
        defer zig_mutants.instrumentation.freeTestPoints(allocator, tests);
        const instrumented = try zig_mutants.instrumentation.instrumentTests(
            allocator,
            switched,
            tests,
            runtime_import,
        );
        defer allocator.free(instrumented);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = instrumented });

        for (tests) |point| {
            const id = try std.fmt.allocPrint(allocator, "zig:{s}:{s}", .{ subject.source, point.name });
            errdefer allocator.free(id);
            try test_records.append(.{
                .id = id,
                .name = try allocator.dupe(u8, point.name),
                .file = try allocator.dupe(u8, subject.source),
                .line = point.line,
            });
        }
    }

    for (subjects, 0..) |subject, subject_index| {
        if (!subjectSelected(subject, mutants, opts, if (changed) |*lines| lines else null)) continue;
        try instrumentExternalSubjectTests(
            allocator,
            io,
            work_dir,
            subject,
            subject_index,
            &test_records,
        );
    }

    const coverage = try allocator.alloc(std.array_list.Managed(usize), mutants.len);
    defer {
        for (coverage) |*set| set.deinit();
        allocator.free(coverage);
    }
    for (coverage) |*set| set.* = std.array_list.Managed(usize).init(allocator);

    var switching_baseline_ok = true;
    for (subjects) |subject| {
        if (!subjectSelected(subject, mutants, opts, if (changed) |*lines| lines else null)) continue;
        for (subject.test_commands) |command| {
            const quoted_cache = try shellQuote(allocator, opts.build_cache_dir);
            defer allocator.free(quoted_cache);
            const coverage_command = try std.fmt.allocPrint(
                allocator,
                "export ZIG_GLOBAL_CACHE_DIR={s}; unset ZIG_MUTANTS_ACTIVE ZIG_MUTANTS_TESTS; {s}",
                .{ quoted_cache, command },
            );
            defer allocator.free(coverage_command);
            const baseline = try runShell(allocator, io, work_dir, coverage_command, subject.timeout_seconds);
            defer baseline.deinit(allocator);
            if (!baseline.success()) {
                switching_baseline_ok = false;
                std.debug.print("instrumented baseline failed for {s}; using legacy execution\n{s}{s}\n", .{
                    subject.source,
                    baseline.stdout,
                    baseline.stderr,
                });
                break;
            }
            try appendCoverageMarkers(baseline.stdout, coverage);
            try appendCoverageMarkers(baseline.stderr, coverage);
        }
        if (!switching_baseline_ok) break;
    }
    if (!switching_baseline_ok) {
        var fallback = opts;
        fallback.mutation_switching = false;
        return runMutants(allocator, io, fallback);
    }

    var results = std.array_list.Managed(zig_mutants.TrialResult).init(allocator);
    defer {
        for (results.items) |result| result.deinit(allocator);
        results.deinit();
    }
    var legacy_work_dir: ?[]u8 = null;
    defer {
        if (legacy_work_dir) |path| allocator.free(path);
    }
    for (mutants, 0..) |mutant, index| {
        if (!selectedForRun(mutant, index, opts, if (changed) |*lines| lines else null)) continue;
        if (coverage[index].items.len != 0 and !std.mem.eql(u8, mutant.method, "*")) continue;
        legacy_work_dir = try std.fmt.allocPrint(allocator, "{s}-static-fallback", .{work_dir});
        try copyWorkspace(allocator, io, opts.root, legacy_work_dir.?);
        break;
    }
    for (mutants, 0..) |mutant, index| {
        if (!selectedForRun(mutant, index, opts, if (changed) |*lines| lines else null)) {
            try results.append(.{ .mutant_index = index, .outcome = .skipped });
            continue;
        }
        const subject = subjectForMutant(subjects, mutant) orelse return error.MissingSubject;
        if (coverage[index].items.len == 0 or std.mem.eql(u8, mutant.method, "*")) {
            const result = try executeLegacyTrial(
                allocator,
                io,
                opts,
                legacy_work_dir orelse return error.MissingLegacyWorkspace,
                artifact_dir,
                mutant,
                index,
                subject,
                test_records.items,
            );
            try results.append(result);
            std.debug.print("{s} {s}:{d}:{d} {s} (static/empty coverage fallback)\n", .{
                result.outcome.label(),
                mutant.path,
                mutant.line,
                mutant.column,
                mutant.kind.label(),
            });
            continue;
        }
        const test_filter = if (opts.test_selection)
            try coverageTestFilter(allocator, coverage[index].items)
        else
            null;
        defer if (test_filter) |filter| allocator.free(filter);
        const command = try switchingCommand(
            allocator,
            index,
            test_filter,
            opts.build_cache_dir,
            if (opts.test_miser) subject.test_commands else &.{subject.test_command},
        );
        defer allocator.free(command);
        const trial = try runShell(allocator, io, work_dir, command, subject.timeout_seconds);
        defer trial.deinit(allocator);
        const outcome: zig_mutants.Outcome = if (trial.timed_out)
            .timeout
        else if (trial.success())
            .survived
        else
            .killed;
        const artifact_path = if (outcome == .survived or outcome == .timeout) blk: {
            const original_path = try std.fs.path.join(allocator, &.{ opts.root, mutant.path });
            defer allocator.free(original_path);
            const original = try std.Io.Dir.cwd().readFileAllocOptions(
                io,
                original_path,
                allocator,
                .limited(32 * 1024 * 1024),
                .of(u8),
                0,
            );
            defer allocator.free(original);
            const mutated = try zig_mutants.applyMutant(allocator, original, mutant);
            defer allocator.free(mutated);
            break :blk try writeSurvivorArtifact(
                allocator,
                io,
                artifact_dir,
                work_dir,
                mutant,
                subject.test_command,
                trial,
                original,
                mutated,
            );
        } else null;
        const covered_by = try coveredTestIds(allocator, coverage[index].items, test_records.items);
        const killed_by = if (opts.test_miser and outcome == .killed)
            try failedTestIdsForRecords(allocator, trial.stdout, trial.stderr, test_records.items)
        else
            &.{};
        try results.append(.{
            .mutant_index = index,
            .outcome = outcome,
            .exit_code = trial.exitCode(),
            .artifact_path = artifact_path,
            .covered_by = covered_by,
            .killed_by = killed_by,
        });
        std.debug.print("{s} {s}:{d}:{d} {s} ({d} covering tests)\n", .{
            outcome.label(),
            mutant.path,
            mutant.line,
            mutant.column,
            mutant.kind.label(),
            coveringTestCount(coverage[index].items),
        });
    }

    if (opts.facts_path) |facts_path| {
        const facts = try zig_mutants.writeFactsJsonWithAttribution(
            allocator,
            sources,
            mutants,
            results.items,
            opts.hard_gate,
            .{
                .tests = test_records.items,
                .complete = opts.max_mutants == null and opts.shard_count == 1 and changed == null,
            },
        );
        defer allocator.free(facts);
        if (std.fs.path.dirname(facts_path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = facts_path, .data = facts });
    }
    if (opts.ratchet_path) |ratchet_path| try enforceRatchet(allocator, io, ratchet_path, mutants, results.items);
    for (sources) |source| {
        const summary = zig_mutants.summarize(mutants, results.items, source);
        std.debug.print("{s}: {d:.2}% killed ({d} killed, {d} survived, {d} timeout, {d} unviable, {d} skipped)\n", .{
            source,
            summary.killRate(),
            summary.killed,
            summary.survived,
            summary.timeout,
            summary.unviable,
            summary.skipped,
        });
    }
}

fn executeLegacyTrial(
    allocator: Allocator,
    io: std.Io,
    opts: Options,
    work_dir: []const u8,
    artifact_dir: []const u8,
    mutant: zig_mutants.Mutant,
    mutant_index: usize,
    subject: Subject,
    test_records: []const zig_mutants.TestRecord,
) !zig_mutants.TrialResult {
    const source_path = try std.fs.path.join(allocator, &.{ work_dir, mutant.path });
    defer allocator.free(source_path);
    const original = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        source_path,
        allocator,
        .limited(32 * 1024 * 1024),
        .of(u8),
        0,
    );
    defer allocator.free(original);
    const mutated = zig_mutants.applyMutant(allocator, original, mutant) catch |err| switch (err) {
        error.InvalidMutantSpan => return .{
            .mutant_index = mutant_index,
            .outcome = .unviable,
        },
        else => |other| return other,
    };
    defer allocator.free(mutated);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = mutated });
    defer std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = original }) catch {};

    const quoted_path = try shellQuote(allocator, mutant.path);
    defer allocator.free(quoted_path);
    const parse_command = try std.fmt.allocPrint(allocator, "zig fmt --ast-check {s}", .{quoted_path});
    defer allocator.free(parse_command);
    const parse_check = try runShell(allocator, io, work_dir, parse_command, subject.timeout_seconds);
    defer parse_check.deinit(allocator);
    if (!parse_check.success()) return .{
        .mutant_index = mutant_index,
        .outcome = .unviable,
        .exit_code = parse_check.exitCode(),
    };

    const command = if (opts.test_miser)
        try runToCompleteCommand(allocator, mutant_index, subject.test_commands)
    else
        try std.fmt.allocPrint(
            allocator,
            "export ZIG_GLOBAL_CACHE_DIR=.zig-mutants-static-cache/{d}; {s}",
            .{ mutant_index, subject.test_command },
        );
    defer allocator.free(command);
    const trial = try runShell(allocator, io, work_dir, command, subject.timeout_seconds);
    defer trial.deinit(allocator);
    const outcome: zig_mutants.Outcome = if (trial.timed_out)
        .timeout
    else if (trial.success())
        .survived
    else
        .killed;
    const artifact_path = if (outcome == .survived or outcome == .timeout)
        try writeSurvivorArtifact(
            allocator,
            io,
            artifact_dir,
            work_dir,
            mutant,
            subject.test_command,
            trial,
            original,
            mutated,
        )
    else
        null;
    const killed_by = if (opts.test_miser and outcome == .killed)
        try failedTestIdsForRecords(allocator, trial.stdout, trial.stderr, test_records)
    else
        &.{};
    return .{
        .mutant_index = mutant_index,
        .outcome = outcome,
        .exit_code = trial.exitCode(),
        .artifact_path = artifact_path,
        .killed_by = killed_by,
    };
}

fn instrumentExternalSubjectTests(
    allocator: Allocator,
    io: std.Io,
    work_dir: []const u8,
    subject: Subject,
    subject_index: usize,
    records: *std.array_list.Managed(zig_mutants.TestRecord),
) !void {
    const subject_dir = std.fs.path.dirname(subject.source) orelse ".";
    const runtime_path = try std.fs.path.join(allocator, &.{ subject_dir, ".zig-mutants-runtime.zig" });
    defer allocator.free(runtime_path);
    const runtime_name = try std.fmt.allocPrint(allocator, "__zig_mutants_runtime_{d}__", .{subject_index});
    defer allocator.free(runtime_name);

    for (subject.test_commands) |command| {
        const filter = testFileFilter(command) orelse continue;
        const basename = std.fs.path.basename(filter);
        const argv = [_][]const u8{ "find", ".", "-type", "f", "-name", basename, "-print" };
        const found = try std.process.run(allocator, io, .{
            .argv = &argv,
            .cwd = .{ .path = work_dir },
            .stdout_limit = .limited(4 * 1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
            .timeout = .{ .duration = timeoutDuration(30) },
        });
        defer allocator.free(found.stdout);
        defer allocator.free(found.stderr);
        if (!termSucceeded(found.term)) continue;

        var paths = std.mem.splitScalar(u8, found.stdout, '\n');
        while (paths.next()) |raw_path| {
            const trimmed = std.mem.trim(u8, raw_path, " \t\r");
            if (trimmed.len == 0) continue;
            const relative_path = if (std.mem.startsWith(u8, trimmed, "./")) trimmed[2..] else trimmed;
            if (std.mem.eql(u8, relative_path, subject.source)) continue;
            const full_path = try std.fs.path.join(allocator, &.{ work_dir, relative_path });
            defer allocator.free(full_path);
            const source = try std.Io.Dir.cwd().readFileAllocOptions(
                io,
                full_path,
                allocator,
                .limited(32 * 1024 * 1024),
                .of(u8),
                0,
            );
            defer allocator.free(source);
            const runtime_declaration = try std.fmt.allocPrint(allocator, "const {s} = @import(", .{runtime_name});
            defer allocator.free(runtime_declaration);
            if (std.mem.indexOf(u8, source, runtime_declaration) != null) continue;
            const tests = try zig_mutants.instrumentation.discoverTests(allocator, source, records.items.len);
            defer zig_mutants.instrumentation.freeTestPoints(allocator, tests);
            if (tests.len == 0) continue;

            for (tests) |*point| {
                var existing_index: ?usize = null;
                for (records.items, 0..) |record, index| {
                    if (std.mem.eql(u8, record.file, relative_path) and std.mem.eql(u8, record.name, point.name)) {
                        existing_index = index;
                        break;
                    }
                }
                if (existing_index) |index| {
                    point.index = index;
                    continue;
                }
                point.index = records.items.len;
                const id = try std.fmt.allocPrint(allocator, "zig:{s}:{s}", .{ relative_path, point.name });
                errdefer allocator.free(id);
                try records.append(.{
                    .id = id,
                    .name = try allocator.dupe(u8, point.name),
                    .file = try allocator.dupe(u8, relative_path),
                    .line = point.line,
                });
            }

            const test_dir = std.fs.path.dirname(relative_path) orelse ".";
            const runtime_import = try std.fs.path.relativePosix(allocator, ".", test_dir, runtime_path);
            defer allocator.free(runtime_import);
            const instrumented = try zig_mutants.instrumentation.instrumentTestsAs(
                allocator,
                source,
                tests,
                runtime_import,
                runtime_name,
            );
            defer allocator.free(instrumented);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = full_path, .data = instrumented });
        }
    }
}

fn testFileFilter(command: []const u8) ?[]const u8 {
    var words = std.mem.tokenizeAny(u8, command, " \t\r\n\"'");
    while (words.next()) |word| {
        const prefix = "-Dtest-file=";
        if (std.mem.startsWith(u8, word, prefix) and word.len > prefix.len) return word[prefix.len..];
    }
    return null;
}

fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn runMutants(allocator: Allocator, io: std.Io, opts: Options) anyerror!void {
    if (opts.mutation_switching) return runMutantsSwitching(allocator, io, opts);
    const subjects = try loadSubjects(allocator, io, opts);
    defer freeSubjects(allocator, subjects);
    const sources = try subjectSources(allocator, subjects);
    defer allocator.free(sources);

    const mutants = try discoverAll(allocator, io, opts.root, sources);
    defer zig_mutants.freeMutants(allocator, mutants);
    var changed = try loadChangedLines(allocator, io, opts);
    defer if (changed) |lines| lines.deinit();

    const work_dir = try effectiveWorkDir(allocator, opts);
    defer if (!std.mem.eql(u8, work_dir, opts.out_dir)) allocator.free(work_dir);
    const artifact_dir = try effectiveArtifactDir(allocator, opts, work_dir);
    defer if (opts.artifact_dir == null) allocator.free(artifact_dir);

    try copyWorkspace(allocator, io, opts.root, work_dir);

    var test_records = std.array_list.Managed(zig_mutants.TestRecord).init(allocator);
    defer {
        for (test_records.items) |record| record.deinit(allocator);
        test_records.deinit();
    }

    for (subjects) |subject| {
        if (!subjectSelected(subject, mutants, opts, if (changed) |*lines| lines else null)) continue;
        if (subject.test_commands.len == 0) return error.MissingTestCommand;
        for (subject.test_commands) |command| {
            const baseline = try runShell(allocator, io, work_dir, command, subject.timeout_seconds);
            defer baseline.deinit(allocator);
            if (!baseline.success()) {
                std.debug.print("baseline failed for {s}; refusing to test mutants\n{s}{s}\n", .{
                    subject.source,
                    baseline.stdout,
                    baseline.stderr,
                });
                return error.BaselineFailed;
            }
            if (opts.test_miser) {
                try appendBaselineTests(allocator, io, opts.root, command, baseline.stdout, &test_records);
                try appendBaselineTests(allocator, io, opts.root, command, baseline.stderr, &test_records);
            }
        }
    }

    var results = std.array_list.Managed(zig_mutants.TrialResult).init(allocator);
    defer {
        for (results.items) |result| result.deinit(allocator);
        results.deinit();
    }

    for (mutants, 0..) |mutant, index| {
        if (!selectedByChangedLines(mutant, if (changed) |*lines| lines else null) or
            !selectedByShard(index, opts.shard_index, opts.shard_count) or
            beyondMaxMutants(index, opts.max_mutants))
        {
            try results.append(.{ .mutant_index = index, .outcome = .skipped });
            continue;
        }
        const subject = subjectForMutant(subjects, mutant) orelse return error.MissingSubject;

        const source_path = try std.fs.path.join(allocator, &.{ work_dir, mutant.path });
        defer allocator.free(source_path);
        const original = try std.Io.Dir.cwd().readFileAllocOptions(
            io,
            source_path,
            allocator,
            .limited(32 * 1024 * 1024),
            .of(u8),
            0,
        );
        defer allocator.free(original);

        const mutated = zig_mutants.applyMutant(allocator, original, mutant) catch |err| switch (err) {
            error.InvalidMutantSpan => {
                try results.append(.{ .mutant_index = index, .outcome = .unviable, .exit_code = 0 });
                std.debug.print("unviable {s}:{d}:{d} {s} invalid span\n", .{
                    mutant.path,
                    mutant.line,
                    mutant.column,
                    mutant.kind.label(),
                });
                continue;
            },
            else => |e| return e,
        };
        defer allocator.free(mutated);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = mutated });

        const quoted_mutant_path = try shellQuote(allocator, mutant.path);
        defer allocator.free(quoted_mutant_path);
        const parse_command = try std.fmt.allocPrint(allocator, "zig fmt --ast-check {s}", .{quoted_mutant_path});
        defer allocator.free(parse_command);
        const parse_check = try runShell(allocator, io, work_dir, parse_command, subject.timeout_seconds);
        defer parse_check.deinit(allocator);
        if (!parse_check.success()) {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = original });
            try results.append(.{ .mutant_index = index, .outcome = .unviable, .exit_code = parse_check.exitCode() });
            continue;
        }

        const test_command = if (opts.test_miser)
            try runToCompleteCommand(allocator, index, subject.test_commands)
        else
            try std.fmt.allocPrint(
                allocator,
                "export ZIG_GLOBAL_CACHE_DIR=.zig-mutants-cache/{d}; {s}",
                .{ index, subject.test_command },
            );
        defer allocator.free(test_command);
        const trial = try runShell(allocator, io, work_dir, test_command, subject.timeout_seconds);
        defer trial.deinit(allocator);
        const outcome: zig_mutants.Outcome = if (trial.timed_out)
            .timeout
        else if (trial.success())
            .survived
        else
            .killed;
        const artifact_path = if (outcome == .survived or outcome == .timeout)
            try writeSurvivorArtifact(
                allocator,
                io,
                artifact_dir,
                work_dir,
                mutant,
                subject.test_command,
                trial,
                original,
                mutated,
            )
        else
            null;
        const killed_by = if (opts.test_miser and outcome == .killed)
            try failedTestIds(allocator, trial.stdout, trial.stderr)
        else
            &.{};
        try results.append(.{
            .mutant_index = index,
            .outcome = outcome,
            .exit_code = trial.exitCode(),
            .artifact_path = artifact_path,
            .killed_by = killed_by,
        });

        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = original });
        std.debug.print("{s} {s}:{d}:{d} {s}\n", .{
            outcome.label(),
            mutant.path,
            mutant.line,
            mutant.column,
            mutant.kind.label(),
        });
    }

    if (opts.facts_path) |facts_path| {
        const attribution: ?zig_mutants.TestAttribution = if (opts.test_miser)
            .{
                .tests = test_records.items,
                .complete = opts.max_mutants == null and opts.shard_count == 1 and changed == null,
            }
        else
            null;
        const facts = try zig_mutants.writeFactsJsonWithAttribution(
            allocator,
            sources,
            mutants,
            results.items,
            opts.hard_gate,
            attribution,
        );
        defer allocator.free(facts);
        const dir_name = std.fs.path.dirname(facts_path);
        if (dir_name) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = facts_path, .data = facts });
    }

    if (opts.ratchet_path) |ratchet_path| {
        try enforceRatchet(allocator, io, ratchet_path, mutants, results.items);
    }

    for (sources) |source| {
        const summary = zig_mutants.summarize(mutants, results.items, source);
        std.debug.print("{s}: {d:.2}% killed ({d} killed, {d} survived, {d} timeout, {d} unviable, {d} skipped)\n", .{
            source,
            summary.killRate(),
            summary.killed,
            summary.survived,
            summary.timeout,
            summary.unviable,
            summary.skipped,
        });
    }
}

fn runToCompleteCommand(allocator: Allocator, mutant_index: usize, commands: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.print("export ZIG_GLOBAL_CACHE_DIR=.zig-mutants-cache/{d}; status=0; ", .{mutant_index});
    for (commands) |command| {
        try writer.print("{{ {s}; }} || status=$?; ", .{command});
    }
    try writer.writeAll("exit $status");
    return out.toOwnedSlice();
}

const ParsedTestLine = struct {
    name: []const u8,
    failed: bool,
};

fn parsedTestName(line: []const u8) ?[]const u8 {
    const dots = std.mem.indexOf(u8, line, "...") orelse return null;
    const prefix = std.mem.trim(u8, line[0..dots], " \t\r");
    const first_space = std.mem.indexOfScalar(u8, prefix, ' ') orelse return null;
    const progress = prefix[0..first_space];
    if (std.mem.indexOfScalar(u8, progress, '/') == null) return null;
    const name = std.mem.trim(u8, prefix[first_space + 1 ..], " \t\r");
    if (name.len == 0) return null;
    return name;
}

fn parsedTestLine(line: []const u8) ?ParsedTestLine {
    const dots = std.mem.indexOf(u8, line, "...") orelse return null;
    const name = parsedTestName(line) orelse return null;
    const status = std.mem.trim(u8, line[dots + 3 ..], " \t\r");
    if (std.mem.startsWith(u8, status, "OK") or std.mem.startsWith(u8, status, "SKIP")) {
        return .{ .name = name, .failed = false };
    }
    if (std.mem.startsWith(u8, status, "FAIL")) {
        return .{ .name = name, .failed = true };
    }
    return null;
}

fn appendBaselineTests(
    allocator: Allocator,
    io: std.Io,
    root: []const u8,
    test_command: []const u8,
    output: []const u8,
    records: *std.array_list.Managed(zig_mutants.TestRecord),
) !void {
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const parsed = parsedTestLine(line) orelse continue;
        var duplicate = false;
        for (records.items) |record| {
            if (std.mem.eql(u8, record.name, parsed.name)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        const test_file = testFileFromCommand(test_command) orelse return error.MissingTestFile;
        const id = try std.fmt.allocPrint(allocator, "zig:{s}", .{parsed.name});
        errdefer allocator.free(id);
        try records.append(.{
            .id = id,
            .name = try allocator.dupe(u8, parsed.name),
            .file = try allocator.dupe(u8, test_file),
            .line = try testSourceLine(allocator, io, root, test_file, parsed.name),
        });
    }
}

fn testFileFromCommand(command: []const u8) ?[]const u8 {
    var words = std.mem.tokenizeAny(u8, command, " \t\r\n\"'");
    var saw_test = false;
    while (words.next()) |word| {
        if (saw_test and std.mem.endsWith(u8, word, ".zig")) return word;
        if (std.mem.eql(u8, word, "test")) saw_test = true;
    }
    return null;
}

fn testSourceLine(
    allocator: Allocator,
    io: std.Io,
    root: []const u8,
    source: []const u8,
    test_name: []const u8,
) !usize {
    const marker = ".test.";
    const marker_index = std.mem.lastIndexOf(u8, test_name, marker) orelse return 1;
    const leaf = test_name[marker_index + marker.len ..];
    const needle = try std.fmt.allocPrint(allocator, "test \"{s}\"", .{leaf});
    defer allocator.free(needle);
    const path = try std.fs.path.join(allocator, &.{ root, source });
    defer allocator.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        allocator,
        .limited(32 * 1024 * 1024),
        .of(u8),
        0,
    );
    defer allocator.free(bytes);
    var line_number: usize = 1;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| : (line_number += 1) {
        if (std.mem.indexOf(u8, line, needle) != null) return line_number;
    }
    return 1;
}

fn failedTestIds(allocator: Allocator, stdout: []const u8, stderr: []const u8) ![]const []const u8 {
    var ids = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit();
    }
    for ([_][]const u8{ stdout, stderr }) |output| {
        var pending: ?[]const u8 = null;
        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            if (parsedTestName(line)) |name| {
                pending = name;
                if (parsedTestLine(line)) |parsed| {
                    if (parsed.failed) try appendFailedTestId(allocator, &ids, parsed.name);
                    pending = null;
                }
                continue;
            }
            const status = std.mem.trim(u8, line, " \t\r");
            if (pending) |name| {
                if (std.mem.startsWith(u8, status, "FAIL")) {
                    try appendFailedTestId(allocator, &ids, name);
                    pending = null;
                }
            }
        }
    }
    if (ids.items.len == 0) {
        ids.deinit();
        return &.{};
    }
    return ids.toOwnedSlice();
}

fn failedTestIdsForRecords(
    allocator: Allocator,
    stdout: []const u8,
    stderr: []const u8,
    records: []const zig_mutants.TestRecord,
) ![]const []const u8 {
    var ids = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit();
    }
    for ([_][]const u8{ stdout, stderr }) |output| {
        var lines = std.mem.splitScalar(u8, output, '\n');
        while (lines.next()) |line| {
            const name = zigFailureName(line) orelse continue;
            for (records) |record| {
                if (!std.mem.eql(u8, record.name, name)) continue;
                try appendExactTestId(allocator, &ids, record.id);
                break;
            }
        }
    }
    if (ids.items.len == 0) {
        ids.deinit();
        return failedTestIds(allocator, stdout, stderr);
    }
    return ids.toOwnedSlice();
}

fn zigFailureName(line: []const u8) ?[]const u8 {
    const prefix = "error: '";
    const start = std.mem.indexOf(u8, line, prefix) orelse return null;
    const value_start = start + prefix.len;
    const suffix = std.mem.indexOf(u8, line[value_start..], "' failed:") orelse return null;
    const qualified = line[value_start .. value_start + suffix];
    const test_marker = std.mem.indexOf(u8, qualified, ".test.") orelse return qualified;
    return qualified[test_marker + ".test.".len ..];
}

fn appendExactTestId(
    allocator: Allocator,
    ids: *std.array_list.Managed([]const u8),
    id: []const u8,
) !void {
    for (ids.items) |existing| if (std.mem.eql(u8, existing, id)) return;
    try ids.append(try allocator.dupe(u8, id));
}

fn appendFailedTestId(
    allocator: Allocator,
    ids: *std.array_list.Managed([]const u8),
    name: []const u8,
) !void {
    const id = try std.fmt.allocPrint(allocator, "zig:{s}", .{name});
    errdefer allocator.free(id);
    for (ids.items) |existing| {
        if (std.mem.eql(u8, existing, id)) {
            allocator.free(id);
            return;
        }
    }
    try ids.append(id);
}

fn discoverAll(allocator: Allocator, io: std.Io, root: []const u8, sources: []const []const u8) ![]zig_mutants.Mutant {
    var all = std.array_list.Managed(zig_mutants.Mutant).init(allocator);
    errdefer {
        for (all.items) |mutant| mutant.deinit(allocator);
        all.deinit();
    }

    for (sources) |source| {
        const source_path = try std.fs.path.join(allocator, &.{ root, source });
        defer allocator.free(source_path);
        const bytes = try std.Io.Dir.cwd().readFileAllocOptions(
            io,
            source_path,
            allocator,
            .limited(32 * 1024 * 1024),
            .of(u8),
            0,
        );
        defer allocator.free(bytes);
        const mutants = try zig_mutants.discoverFile(allocator, source, bytes);
        defer allocator.free(mutants);
        try all.appendSlice(mutants);
    }
    return all.toOwnedSlice();
}

fn loadChangedLines(
    allocator: Allocator,
    io: std.Io,
    opts: Options,
) !?zig_mutants.selection.ChangedLines {
    var owned_diff: ?[]u8 = null;
    defer {
        if (owned_diff) |bytes| allocator.free(bytes);
    }

    const diff = if (opts.diff_file) |path| blk: {
        owned_diff = try std.Io.Dir.cwd().readFileAllocOptions(
            io,
            path,
            allocator,
            .limited(64 * 1024 * 1024),
            .of(u8),
            null,
        );
        break :blk owned_diff.?;
    } else if (opts.since) |revision| blk: {
        const argv = [_][]const u8{ "git", "diff", "--unified=0", revision, "--" };
        const result = try std.process.run(allocator, io, .{
            .argv = &argv,
            .cwd = .{ .path = opts.root },
            .stdout_limit = .limited(64 * 1024 * 1024),
            .stderr_limit = .limited(4 * 1024 * 1024),
            .timeout = .{ .duration = timeoutDuration(120) },
        });
        defer allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code != 0) {
                defer allocator.free(result.stdout);
                std.debug.print("git diff failed for revision {s}\n{s}\n", .{ revision, result.stderr });
                return error.GitDiffFailed;
            },
            else => {
                defer allocator.free(result.stdout);
                std.debug.print("git diff did not exit normally for revision {s}\n{s}\n", .{ revision, result.stderr });
                return error.GitDiffFailed;
            },
        }
        owned_diff = result.stdout;
        break :blk owned_diff.?;
    } else return null;

    return try zig_mutants.selection.parseUnifiedDiff(allocator, diff);
}

fn selectedByChangedLines(
    mutant: zig_mutants.Mutant,
    changed: ?*const zig_mutants.selection.ChangedLines,
) bool {
    const lines = changed orelse return true;
    return lines.contains(mutant.path, mutant.line);
}

fn selectedForRun(
    mutant: zig_mutants.Mutant,
    index: usize,
    opts: Options,
    changed: ?*const zig_mutants.selection.ChangedLines,
) bool {
    return selectedByChangedLines(mutant, changed) and
        selectedByShard(index, opts.shard_index, opts.shard_count) and
        !beyondMaxMutants(index, opts.max_mutants);
}

fn subjectSelected(
    subject: Subject,
    mutants: []const zig_mutants.Mutant,
    opts: Options,
    changed: ?*const zig_mutants.selection.ChangedLines,
) bool {
    for (mutants, 0..) |mutant, index| {
        if (!std.mem.eql(u8, mutant.path, subject.source)) continue;
        if (selectedForRun(mutant, index, opts, changed)) return true;
    }
    return false;
}

fn appendCoverageMarkers(output: []const u8, coverage: []std.array_list.Managed(usize)) !void {
    const prefix = "__ZIG_MUTANTS_COVERAGE__:";
    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        const marker = std.mem.indexOf(u8, raw_line, prefix) orelse continue;
        const payload = raw_line[marker + prefix.len ..];
        const colon = std.mem.indexOfScalar(u8, payload, ':') orelse continue;
        const test_slot = std.fmt.parseInt(usize, payload[0..colon], 10) catch continue;
        const mutant_index = std.fmt.parseInt(
            usize,
            std.mem.trim(u8, payload[colon + 1 ..], " \t\r"),
            10,
        ) catch continue;
        if (mutant_index >= coverage.len) continue;
        var duplicate = false;
        for (coverage[mutant_index].items) |existing| {
            if (existing == test_slot) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) try coverage[mutant_index].append(test_slot);
    }
}

fn coverageTestFilter(allocator: Allocator, test_slots: []const usize) !?[]u8 {
    if (test_slots.len == 0) return null;
    for (test_slots) |slot| if (slot == 0) return null;
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    for (test_slots, 0..) |slot, index| {
        if (index != 0) try out.writer.writeByte(',');
        try out.writer.print("{d}", .{slot - 1});
    }
    return try out.toOwnedSlice();
}

fn coveringTestCount(test_slots: []const usize) usize {
    var count: usize = 0;
    for (test_slots) |slot| if (slot != 0) {
        count += 1;
    };
    return count;
}

fn switchingCommand(
    allocator: Allocator,
    mutant_index: usize,
    test_filter: ?[]const u8,
    build_cache_dir: []const u8,
    commands: []const []const u8,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    const quoted_cache = try shellQuote(allocator, build_cache_dir);
    defer allocator.free(quoted_cache);
    try out.writer.print(
        "export ZIG_GLOBAL_CACHE_DIR={s} ZIG_MUTANTS_ACTIVE={d}; ",
        .{ quoted_cache, mutant_index },
    );
    if (test_filter) |filter| {
        try out.writer.print("export ZIG_MUTANTS_TESTS={s}; ", .{filter});
    } else {
        try out.writer.writeAll("unset ZIG_MUTANTS_TESTS; ");
    }
    try out.writer.writeAll("status=0; ");
    for (commands) |command| try out.writer.print("{{ {s}; }} || status=$?; ", .{command});
    try out.writer.writeAll("exit $status");
    return out.toOwnedSlice();
}

fn coveredTestIds(
    allocator: Allocator,
    test_slots: []const usize,
    records: []const zig_mutants.TestRecord,
) ![]const []const u8 {
    var ids = std.array_list.Managed([]const u8).init(allocator);
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit();
    }
    for (test_slots) |slot| {
        if (slot == 0 or slot - 1 >= records.len) continue;
        try ids.append(try allocator.dupe(u8, records[slot - 1].id));
    }
    if (ids.items.len == 0) {
        ids.deinit();
        return &.{};
    }
    return ids.toOwnedSlice();
}

fn selectChangedMutants(
    allocator: Allocator,
    mutants: []const zig_mutants.Mutant,
    changed: ?*const zig_mutants.selection.ChangedLines,
) ![]zig_mutants.Mutant {
    var selected = std.array_list.Managed(zig_mutants.Mutant).init(allocator);
    defer selected.deinit();
    for (mutants) |mutant| {
        if (selectedByChangedLines(mutant, changed)) try selected.append(mutant);
    }
    return allocator.dupe(zig_mutants.Mutant, selected.items);
}

fn effectiveWorkDir(allocator: Allocator, opts: Options) ![]const u8 {
    if (opts.shard_count > 1 and std.mem.eql(u8, opts.out_dir, DEFAULT_OUT_DIR)) {
        return std.fmt.allocPrint(allocator, "{s}-shard-{d}-of-{d}", .{
            DEFAULT_OUT_DIR,
            opts.shard_index,
            opts.shard_count,
        });
    }
    return opts.out_dir;
}

fn effectiveArtifactDir(allocator: Allocator, opts: Options, work_dir: []const u8) ![]const u8 {
    if (opts.artifact_dir) |artifact_dir| return artifact_dir;
    return std.fs.path.join(allocator, &.{ work_dir, "mutant-artifacts" });
}

fn selectedByShard(index: usize, shard_index: usize, shard_count: usize) bool {
    return index % shard_count == shard_index;
}

fn beyondMaxMutants(index: usize, max_mutants: ?usize) bool {
    if (max_mutants) |limit| return index >= limit;
    return false;
}

fn subjectForMutant(subjects: []const Subject, mutant: zig_mutants.Mutant) ?Subject {
    for (subjects) |subject| {
        if (std.mem.eql(u8, subject.source, mutant.path)) return subject;
    }
    return null;
}

fn writeSurvivorArtifact(
    allocator: Allocator,
    io: std.Io,
    artifact_root: []const u8,
    work_dir: []const u8,
    mutant: zig_mutants.Mutant,
    test_command: []const u8,
    trial: CommandResult,
    original: []const u8,
    mutated: []const u8,
) ![]const u8 {
    const safe_id = try safeMutantId(allocator, mutant.id);
    defer allocator.free(safe_id);
    const dir = try std.fs.path.join(allocator, &.{ artifact_root, safe_id });
    errdefer allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);

    try writeArtifactFile(allocator, io, dir, "original.zig", original);
    try writeArtifactFile(allocator, io, dir, "mutated.zig", mutated);
    try writeArtifactFile(allocator, io, dir, "stdout.txt", trial.stdout);
    try writeArtifactFile(allocator, io, dir, "stderr.txt", trial.stderr);

    const patch = try std.fmt.allocPrint(
        allocator,
        "--- {s}\n+++ {s}\n@@ line {d}, column {d} @@\n-{s}\n+{s}\n",
        .{ mutant.path, mutant.path, mutant.line, mutant.column, mutant.original, mutant.replacement },
    );
    defer allocator.free(patch);
    try writeArtifactFile(allocator, io, dir, "mutant.patch", patch);

    const metadata = try artifactMetadataJson(allocator, mutant, test_command, trial);
    defer allocator.free(metadata);
    try writeArtifactFile(allocator, io, dir, "metadata.json", metadata);

    const source_path = try std.fs.path.join(allocator, &.{ work_dir, mutant.path });
    defer allocator.free(source_path);
    const quoted_source = try shellQuote(allocator, source_path);
    defer allocator.free(quoted_source);
    const quoted_work_dir = try shellQuote(allocator, work_dir);
    defer allocator.free(quoted_work_dir);
    const repro = try std.fmt.allocPrint(
        allocator,
        "#!/usr/bin/env bash\nset -euo pipefail\ncp \"$(dirname \"$0\")/mutated.zig\" {s}\ncd {s}\n{s}\n",
        .{ quoted_source, quoted_work_dir, test_command },
    );
    defer allocator.free(repro);
    try writeArtifactFile(allocator, io, dir, "repro.sh", repro);

    return dir;
}

fn artifactMetadataJson(
    allocator: Allocator,
    mutant: zig_mutants.Mutant,
    test_command: []const u8,
    trial: CommandResult,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\n  \"id\": ");
    try zig_mutants.writeJsonString(w, mutant.id);
    try w.writeAll(",\n  \"file\": ");
    try zig_mutants.writeJsonString(w, mutant.path);
    try w.writeAll(",\n  \"method\": ");
    try zig_mutants.writeJsonString(w, mutant.method);
    try w.writeAll(",\n  \"kind\": ");
    try zig_mutants.writeJsonString(w, mutant.kind.label());
    try w.writeAll(",\n  \"test_command\": ");
    try zig_mutants.writeJsonString(w, test_command);
    try w.print(",\n  \"line\": {d},\n  \"column\": {d},\n  \"exit_code\": {d}\n}}\n", .{
        mutant.line,
        mutant.column,
        trial.exitCode(),
    });
    return out.toOwnedSlice();
}

fn writeArtifactFile(
    allocator: Allocator,
    io: std.Io,
    dir: []const u8,
    name: []const u8,
    data: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn safeMutantId(allocator: Allocator, id: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, id.len);
    for (id, 0..) |byte, i| {
        out[i] = if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_') byte else '_';
    }
    return out;
}

fn shellQuote(allocator: Allocator, value: []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.append('\'');
    for (value) |byte| {
        if (byte == '\'') {
            try out.appendSlice("'\\''");
        } else {
            try out.append(byte);
        }
    }
    try out.append('\'');
    return out.toOwnedSlice();
}

fn enforceRatchet(
    allocator: Allocator,
    io: std.Io,
    baseline_path: []const u8,
    mutants: []const zig_mutants.Mutant,
    results: []const zig_mutants.TrialResult,
) !void {
    var allowed = try loadAllowedAliveMutants(allocator, io, baseline_path);
    defer freeStringSet(allocator, &allowed);

    var new_alive: usize = 0;
    for (results) |result| {
        if (result.mutant_index >= mutants.len) continue;
        if (result.outcome != .survived and result.outcome != .timeout) continue;
        const mutant = mutants[result.mutant_index];
        if (allowed.contains(mutant.id) or allowed.contains(mutant.legacy_id)) continue;
        new_alive += 1;
        std.debug.print("new alive Zig mutant: {s}\n", .{mutant.id});
    }
    if (new_alive > 0) return error.RatchetFailed;
}

fn loadAllowedAliveMutants(allocator: Allocator, io: std.Io, baseline_path: []const u8) !std.StringHashMap(void) {
    var allowed = std.StringHashMap(void).init(allocator);
    errdefer freeStringSet(allocator, &allowed);
    const bytes = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        baseline_path,
        allocator,
        .limited(32 * 1024 * 1024),
        .of(u8),
        0,
    );
    defer allocator.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const mutants_value = switch (parsed.value) {
        .object => |object| object.get("mutants") orelse return allowed,
        else => return allowed,
    };
    switch (mutants_value) {
        .array => |array| {
            for (array.items) |entry| {
                const object = switch (entry) {
                    .object => |object| object,
                    else => continue,
                };
                const id_value = object.get("id") orelse continue;
                const outcome_value = object.get("outcome") orelse continue;
                const id = switch (id_value) {
                    .string => |id| id,
                    else => continue,
                };
                const outcome = switch (outcome_value) {
                    .string => |outcome| outcome,
                    else => continue,
                };
                if (!std.mem.eql(u8, outcome, "survived") and
                    !std.mem.eql(u8, outcome, "timeout"))
                {
                    continue;
                }
                try allowed.put(try allocator.dupe(u8, id), {});
            }
        },
        else => return allowed,
    }
    return allowed;
}

fn freeStringSet(allocator: Allocator, set: *std.StringHashMap(void)) void {
    var iter = set.iterator();
    while (iter.next()) |entry| allocator.free(entry.key_ptr.*);
    set.deinit();
}

const CommandResult = struct {
    term: std.process.Child.Term,
    stdout: []u8,
    stderr: []u8,
    timed_out: bool,

    fn deinit(self: CommandResult, allocator: Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }

    fn success(self: CommandResult) bool {
        return switch (self.term) {
            .exited => |code| code == 0,
            else => false,
        };
    }

    fn exitCode(self: CommandResult) i32 {
        return switch (self.term) {
            .exited => |code| code,
            .signal => |sig| @intCast(@intFromEnum(sig)),
            .stopped => |sig| @intCast(@intFromEnum(sig)),
            .unknown => |code| @intCast(code),
        };
    }
};

fn runShell(allocator: Allocator, io: std.Io, cwd: []const u8, command: []const u8, timeout_seconds: u32) !CommandResult {
    const timeout_text = try std.fmt.allocPrint(allocator, "{d}s", .{timeout_seconds});
    defer allocator.free(timeout_text);
    const argv = [_][]const u8{
        "timeout",
        "--kill-after",
        "5s",
        timeout_text,
        "bash",
        "-lc",
        command,
    };
    const run_result = std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
        .timeout = .{ .duration = timeoutDuration(timeout_seconds + 10) },
    }) catch |err| switch (err) {
        error.Timeout => return .{
            .term = .{ .unknown = 124 },
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try allocator.dupe(u8, "timeout"),
            .timed_out = true,
        },
        error.StreamTooLong => return .{
            .term = .{ .exited = 1 },
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try allocator.dupe(u8, "output limit exceeded"),
            .timed_out = false,
        },
        else => |e| return e,
    };
    const timed_out = switch (run_result.term) {
        .exited => |code| code == 124 or code == 137,
        .signal => true,
        .stopped => true,
        .unknown => |code| code == 124 or code == 137,
    };
    return .{
        .term = run_result.term,
        .stdout = run_result.stdout,
        .stderr = run_result.stderr,
        .timed_out = timed_out,
    };
}

fn copyWorkspace(allocator: Allocator, io: std.Io, root: []const u8, out_dir: []const u8) !void {
    const script =
        \\rm -rf "$1" &&
        \\mkdir -p "$1" &&
        \\tar \
        \\  --exclude=.git \
        \\  --exclude=.claude \
        \\  --exclude="*/.zig-cache" \
        \\  --exclude="*/zig-cache" \
        \\  --exclude="*/.clear-cache" \
        \\  --exclude="*/zig-out" \
        \\  --exclude="*/target" \
        \\  --exclude="*/node_modules" \
        \\  --exclude="*/tmp" \
        \\  -C "$0" -cf - . | tar -C "$1" -xf -
    ;
    const argv = [_][]const u8{ "bash", "-c", script, root, out_dir };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .timeout = .{ .duration = timeoutDuration(120) },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    std.debug.print("workspace copy failed\n{s}{s}\n", .{ result.stdout, result.stderr });
    return error.CopyFailed;
}

fn timeoutDuration(seconds: u32) std.Io.Clock.Duration {
    return .{
        .raw = .{ .nanoseconds = @as(i96, seconds) * std.time.ns_per_s },
        .clock = .awake,
    };
}

fn printMutantsJson(allocator: Allocator, io: std.Io, mutants: []const zig_mutants.Mutant) !void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("{\"mutants\":[");
    for (mutants, 0..) |mutant, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try zig_mutants.writeJsonString(w, mutant.id);
        try w.writeAll(",\"file\":");
        try zig_mutants.writeJsonString(w, mutant.path);
        try w.writeAll(",\"method\":");
        try zig_mutants.writeJsonString(w, mutant.method);
        try w.writeAll(",\"kind\":");
        try zig_mutants.writeJsonString(w, mutant.kind.label());
        try w.print(",\"line\":{d},\"column\":{d},\"original\":", .{ mutant.line, mutant.column });
        try zig_mutants.writeJsonString(w, mutant.original);
        try w.writeAll(",\"replacement\":");
        try zig_mutants.writeJsonString(w, mutant.replacement);
        try w.writeByte('}');
    }
    try w.writeAll("]}\n");
    const json = try out.toOwnedSlice();
    defer allocator.free(json);
    try std.Io.File.stdout().writeStreamingAll(io, json);
}
