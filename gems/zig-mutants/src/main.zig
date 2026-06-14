const std = @import("std");
const zig_mutants = @import("zig_mutants");

const Allocator = std.mem.Allocator;

const Options = struct {
    command: Command,
    root: []const u8 = ".",
    out_dir: []const u8 = "/tmp/zig-mutants",
    facts_path: ?[]const u8 = null,
    test_command: ?[]const u8 = null,
    sources: std.array_list.Managed([]const u8),
    max_mutants: ?usize = null,
    timeout_seconds: u32 = 120,
    json: bool = false,
    hard_gate: bool = false,

    const Command = enum { list, run, help };

    fn deinit(self: *Options) void {
        self.sources.deinit();
    }
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
        } else if (std.mem.eql(u8, arg, "--facts")) {
            opts.facts_path = iter.next() orelse return error.MissingOptionValue;
        } else if (std.mem.eql(u8, arg, "--test-command")) {
            opts.test_command = iter.next() orelse return error.MissingOptionValue;
        } else if (std.mem.eql(u8, arg, "--max-mutants")) {
            opts.max_mutants = try std.fmt.parseInt(usize, iter.next() orelse return error.MissingOptionValue, 10);
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

    if (opts.command != .help and opts.sources.items.len == 0) {
        std.debug.print("at least one --source is required\n", .{});
        return error.MissingSource;
    }
    if (opts.command == .run and opts.test_command == null) {
        std.debug.print("--test-command is required for run\n", .{});
        return error.MissingTestCommand;
    }
    return opts;
}

fn parseCommand(command: []const u8) Options.Command {
    if (std.mem.eql(u8, command, "list")) return .list;
    if (std.mem.eql(u8, command, "run")) return .run;
    return .help;
}

fn usage() void {
    std.debug.print(
        \\Usage:
        \\  zig-mutants list --source FILE [--source FILE] [--json]
        \\  zig-mutants run --root DIR --source FILE [--source FILE] --test-command CMD [--facts FILE] [--out DIR] [--max-mutants N]
        \\
        \\Examples:
        \\  zig build -Doptimize=ReleaseSafe run -- list --source ../../zig/lib/safety.zig
        \\  zig build run -- run --root ../.. --source zig/lib/safety.zig --test-command "cd zig && zig build test" --facts /tmp/zig-mutants.json
        \\
    , .{});
}

fn listMutants(allocator: Allocator, io: std.Io, opts: Options) !void {
    const mutants = try discoverAll(allocator, io, opts.root, opts.sources.items);
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
    const mutants = try discoverAll(allocator, io, opts.root, opts.sources.items);
    defer zig_mutants.freeMutants(allocator, mutants);

    try copyWorkspace(allocator, io, opts.root, opts.out_dir);

    const baseline = try runShell(allocator, io, opts.out_dir, opts.test_command.?, opts.timeout_seconds);
    defer baseline.deinit(allocator);
    if (!baseline.success()) {
        std.debug.print("baseline failed; refusing to test mutants\n{s}{s}\n", .{ baseline.stdout, baseline.stderr });
        return error.BaselineFailed;
    }

    var results = std.array_list.Managed(zig_mutants.TrialResult).init(allocator);
    defer results.deinit();

    for (mutants, 0..) |mutant, index| {
        if (opts.max_mutants) |limit| {
            if (index >= limit) {
                try results.append(.{ .mutant_index = index, .outcome = .skipped });
                continue;
            }
        }

        const source_path = try std.fs.path.join(allocator, &.{ opts.out_dir, mutant.path });
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

        const mutated = try zig_mutants.applyMutant(allocator, original, mutant);
        defer allocator.free(mutated);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = mutated });

        const parse_check = try runShell(allocator, io, opts.out_dir, "zig fmt --ast-check .", opts.timeout_seconds);
        defer parse_check.deinit(allocator);
        if (!parse_check.success()) {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = source_path, .data = original });
            try results.append(.{ .mutant_index = index, .outcome = .unviable, .exit_code = parse_check.exitCode() });
            continue;
        }

        const trial = try runShell(allocator, io, opts.out_dir, opts.test_command.?, opts.timeout_seconds);
        defer trial.deinit(allocator);
        const outcome: zig_mutants.Outcome = if (trial.timed_out)
            .timeout
        else if (trial.success())
            .survived
        else
            .killed;
        try results.append(.{ .mutant_index = index, .outcome = outcome, .exit_code = trial.exitCode() });

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
        const facts = try zig_mutants.writeFactsJson(allocator, opts.sources.items, mutants, results.items, opts.hard_gate);
        defer allocator.free(facts);
        const dir_name = std.fs.path.dirname(facts_path);
        if (dir_name) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = facts_path, .data = facts });
    }

    for (opts.sources.items) |source| {
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
    const argv = [_][]const u8{ "bash", "-lc", command };
    const run_result = std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
        .timeout = .{ .duration = timeoutDuration(timeout_seconds) },
    }) catch |err| switch (err) {
        error.Timeout => return .{
            .term = .{ .unknown = 124 },
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try allocator.dupe(u8, "timeout"),
            .timed_out = true,
        },
        else => |e| return e,
    };
    return .{
        .term = run_result.term,
        .stdout = run_result.stdout,
        .stderr = run_result.stderr,
        .timed_out = false,
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
