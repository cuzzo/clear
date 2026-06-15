const std = @import("std");
const zig_mutants = @import("zig_mutants");

const Allocator = std.mem.Allocator;
const DEFAULT_OUT_DIR = "/tmp/zig-mutants";

const Options = struct {
    command: Command,
    root: []const u8 = ".",
    out_dir: []const u8 = DEFAULT_OUT_DIR,
    artifact_dir: ?[]const u8 = null,
    manifest_path: ?[]const u8 = null,
    ratchet_path: ?[]const u8 = null,
    facts_path: ?[]const u8 = null,
    test_command: ?[]const u8 = null,
    sources: std.array_list.Managed([]const u8),
    max_mutants: ?usize = null,
    shard_index: usize = 0,
    shard_count: usize = 1,
    timeout_seconds: u32 = 120,
    json: bool = false,
    hard_gate: bool = false,

    const Command = enum { list, run, help };

    fn deinit(self: *Options) void {
        self.sources.deinit();
    }
};

const Subject = struct {
    source: []const u8,
    test_command: []const u8,
    timeout_seconds: u32,

    fn deinit(self: Subject, allocator: Allocator) void {
        allocator.free(self.source);
        allocator.free(self.test_command);
    }
};

const Manifest = struct {
    subjects: []ManifestSubject,
};

const ManifestSubject = struct {
    source: []const u8,
    test_command: []const u8,
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
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            opts.manifest_path = iter.next() orelse return error.MissingOptionValue;
        } else if (std.mem.eql(u8, arg, "--facts")) {
            opts.facts_path = iter.next() orelse return error.MissingOptionValue;
        } else if (std.mem.eql(u8, arg, "--ratchet")) {
            opts.ratchet_path = iter.next() orelse return error.MissingOptionValue;
        } else if (std.mem.eql(u8, arg, "--test-command")) {
            opts.test_command = iter.next() orelse return error.MissingOptionValue;
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
        \\  zig-mutants list (--source FILE | --manifest FILE) [--json]
        \\  zig-mutants run --root DIR (--source FILE | --manifest FILE) [--test-command CMD] [--facts FILE] [--out DIR] [--artifact-dir DIR] [--shard INDEX/COUNT] [--ratchet FACTS]
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
        try subjects.append(.{
            .source = try allocator.dupe(u8, source),
            .test_command = try allocator.dupe(u8, opts.test_command orelse ""),
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
        const command = command_override orelse subject.test_command;
        try subjects.append(.{
            .source = try allocator.dupe(u8, subject.source),
            .test_command = try allocator.dupe(u8, command),
            .timeout_seconds = subject.timeout_seconds orelse 120,
        });
    }
    return subjects.toOwnedSlice();
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

    if (opts.json) {
        try printMutantsJson(allocator, io, mutants);
        return;
    }

    for (mutants) |mutant| {
        std.debug.print("{s}:{d}:{d}: {s} replace `{s}` with `{s}`\n", .{
            mutant.path,
            mutant.line,
            mutant.column,
            mutant.kind.label(),
            mutant.original,
            mutant.replacement,
        });
    }
    std.debug.print("{d} mutants discovered\n", .{mutants.len});
}

fn runMutants(allocator: Allocator, io: std.Io, opts: Options) !void {
    const subjects = try loadSubjects(allocator, io, opts);
    defer freeSubjects(allocator, subjects);
    const sources = try subjectSources(allocator, subjects);
    defer allocator.free(sources);

    const mutants = try discoverAll(allocator, io, opts.root, sources);
    defer zig_mutants.freeMutants(allocator, mutants);

    const work_dir = try effectiveWorkDir(allocator, opts);
    defer if (!std.mem.eql(u8, work_dir, opts.out_dir)) allocator.free(work_dir);
    const artifact_dir = try effectiveArtifactDir(allocator, opts, work_dir);
    defer if (opts.artifact_dir == null) allocator.free(artifact_dir);

    try copyWorkspace(allocator, io, opts.root, work_dir);

    for (subjects) |subject| {
        if (subject.test_command.len == 0) return error.MissingTestCommand;
        const baseline = try runShell(allocator, io, work_dir, subject.test_command, subject.timeout_seconds);
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

    var results = std.array_list.Managed(zig_mutants.TrialResult).init(allocator);
    defer {
        for (results.items) |result| result.deinit(allocator);
        results.deinit();
    }

    for (mutants, 0..) |mutant, index| {
        if (!selectedByShard(index, opts.shard_index, opts.shard_count) or beyondMaxMutants(index, opts.max_mutants)) {
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

        const trial = try runShell(allocator, io, work_dir, subject.test_command, subject.timeout_seconds);
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
        try results.append(.{
            .mutant_index = index,
            .outcome = outcome,
            .exit_code = trial.exitCode(),
            .artifact_path = artifact_path,
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
        const facts = try zig_mutants.writeFactsJson(allocator, sources, mutants, results.items, opts.hard_gate);
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
        if (allowed.contains(mutant.id)) continue;
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
        \\  --exclude=.zig-cache \
        \\  --exclude=zig-cache \
        \\  --exclude=zig/.clear-cache \
        \\  --exclude=zig/zig-out \
        \\  -C "$0" -cf - . | tar -C "$1" -xf -
    ;
    const argv = [_][]const u8{ "bash", "-lc", script, root, out_dir };
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
