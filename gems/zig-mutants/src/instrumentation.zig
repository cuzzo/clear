const std = @import("std");
const MutationKind = @import("mutation_kind.zig").MutationKind;

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Bounds = struct { start: usize, end: usize };

pub const Site = struct {
    index: usize,
    kind: MutationKind,
    start: usize,
    end: usize,
    replacement: []const u8,
};

pub const TestPoint = struct {
    index: usize,
    name: []const u8,
    line: usize,
    body_offset: usize,

    pub fn deinit(self: TestPoint, allocator: Allocator) void {
        allocator.free(self.name);
    }
};

pub fn freeTestPoints(allocator: Allocator, tests: []TestPoint) void {
    for (tests) |point| point.deinit(allocator);
    allocator.free(tests);
}

pub fn discoverTests(
    allocator: Allocator,
    source: [:0]const u8,
    first_index: usize,
) ![]TestPoint {
    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.ParseError;

    var tests = std.array_list.Managed(TestPoint).init(allocator);
    errdefer {
        for (tests.items) |point| point.deinit(allocator);
        tests.deinit();
    }

    var raw_node: u32 = 1;
    while (raw_node < tree.nodes.len) : (raw_node += 1) {
        const node: Ast.Node.Index = @enumFromInt(raw_node);
        if (tree.nodeTag(node) != .test_decl) continue;
        const name_token, const body = tree.nodeData(node).opt_token_and_node;
        const name = if (name_token.unwrap()) |token|
            tree.tokenSlice(token)
        else
            "<anonymous>";
        const body_token = tree.firstToken(body);
        const open_offset = tree.tokenStart(body_token) + tree.tokenSlice(body_token).len;
        const location = lineColumn(source, tree.tokenStart(tree.nodeMainToken(node)));
        try tests.append(.{
            .index = first_index + tests.items.len,
            .name = try allocator.dupe(u8, trimTestName(name)),
            .line = location.line,
            .body_offset = open_offset,
        });
    }
    return tests.toOwnedSlice();
}

pub fn instrumentTests(
    allocator: Allocator,
    source: []const u8,
    tests: []const TestPoint,
    runtime_import: []const u8,
) ![]u8 {
    return instrumentTestsAs(allocator, source, tests, runtime_import, "__zig_mutants_runtime__");
}

pub fn instrumentTestsAs(
    allocator: Allocator,
    source: []const u8,
    tests: []const TestPoint,
    runtime_import: []const u8,
    runtime_name: []const u8,
) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    const declaration = try std.fmt.allocPrint(allocator, "const {s} = @import(", .{runtime_name});
    defer allocator.free(declaration);
    if (std.mem.indexOf(u8, source, declaration) == null) {
        try output.writer.print("const {s} = @import(\"{s}\");\n", .{ runtime_name, runtime_import });
    }

    var cursor: usize = 0;
    for (tests) |point| {
        if (point.body_offset < cursor or point.body_offset > source.len) return error.InvalidTestPoint;
        try output.writer.writeAll(source[cursor..point.body_offset]);
        try output.writer.print(
            "\n    if (!{s}.enter({d})) return error.SkipZigTest;\n    defer {s}.leave();",
            .{ runtime_name, point.index, runtime_name },
        );
        cursor = point.body_offset;
    }
    try output.writer.writeAll(source[cursor..]);
    return output.toOwnedSlice();
}

pub fn instrumentMutants(
    allocator: Allocator,
    source: []const u8,
    sites: []const Site,
    runtime_import: []const u8,
) ![]u8 {
    for (sites, 0..) |left, left_index| {
        if (!switchable(left.kind)) continue;
        for (sites[left_index + 1 ..]) |right| {
            if (!switchable(right.kind)) continue;
            if (partiallyOverlaps(left, right)) return error.PartiallyOverlappingMutants;
        }
    }

    var output = std.Io.Writer.Allocating.init(allocator);
    errdefer output.deinit();
    if (std.mem.indexOf(u8, source, "const __zig_mutants_runtime__ = @import(") == null) {
        try output.writer.print("const __zig_mutants_runtime__ = @import(\"{s}\");\n", .{runtime_import});
    }
    try writeRegion(&output.writer, source, 0, source.len, sites, null);
    return output.toOwnedSlice();
}

pub fn runtimeSource(allocator: Allocator, mutant_count: usize) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\const builtin = @import("builtin");
        \\
        \\const mutant_count = {d};
        \\var current_test = std.atomic.Value(usize).init(0);
        \\var concurrent_tests = std.atomic.Value(u8).init(0);
        \\var seen = [_]std.atomic.Value(usize){{std.atomic.Value(usize).init(0)}} ** mutant_count;
        \\
        \\pub fn enter(test_index: usize) bool {{
        \\    if (!selectedTest(test_index)) return false;
        \\    const next = test_index + 1;
        \\    const previous = current_test.swap(next, .acq_rel);
        \\    if (previous != 0 and previous != next and concurrent_tests.swap(1, .acq_rel) == 0) {{
        \\        for (0..mutant_count) |mutant_index| {{
        \\            std.debug.print("__ZIG_MUTANTS_COVERAGE__:0:{{d}}\n", .{{mutant_index}});
        \\        }}
        \\    }}
        \\    return true;
        \\}}
        \\
        \\pub fn leave() void {{
        \\    current_test.store(0, .release);
        \\}}
        \\
        \\pub fn active(mutant_index: usize) bool {{
        \\    if (@inComptime()) return false;
        \\    const test_index = current_test.load(.acquire);
        \\    if (mutant_index < mutant_count and seen[mutant_index].swap(test_index + 1, .acq_rel) != test_index + 1) {{
        \\        std.debug.print("__ZIG_MUTANTS_COVERAGE__:{{d}}:{{d}}\n", .{{ test_index, mutant_index }});
        \\    }}
        \\    return (envInt("ZIG_MUTANTS_ACTIVE") orelse return false) == mutant_index;
        \\}}
        \\
        \\fn selectedTest(test_index: usize) bool {{
        \\    const filter = envValue("ZIG_MUTANTS_TESTS") orelse return true;
        \\    defer freeEnv(filter);
        \\    var values = std.mem.splitScalar(u8, filter.value, ',');
        \\    while (values.next()) |value| {{
        \\        const parsed = std.fmt.parseInt(usize, value, 10) catch continue;
        \\        if (parsed == test_index) return true;
        \\    }}
        \\    return false;
        \\}}
        \\
        \\fn envInt(comptime name: []const u8) ?usize {{
        \\    const value = envValue(name) orelse return null;
        \\    defer freeEnv(value);
        \\    return std.fmt.parseInt(usize, value.value, 10) catch null;
        \\}}
        \\
        \\const EnvValue = struct {{ value: []const u8, owned: ?[]u8 }};
        \\
        \\fn envValue(comptime name: []const u8) ?EnvValue {{
        \\    if (builtin.os.tag == .windows) {{
        \\        const owned = std.testing.environ.getAlloc(std.heap.page_allocator, name) catch return null;
        \\        return .{{ .value = owned, .owned = owned }};
        \\    }}
        \\    const value = std.testing.environ.getPosix(name) orelse return null;
        \\    return .{{ .value = value, .owned = null }};
        \\}}
        \\
        \\fn freeEnv(value: EnvValue) void {{
        \\    if (value.owned) |owned| std.heap.page_allocator.free(owned);
        \\}}
        \\
    , .{mutant_count});
}

pub fn switchable(kind: MutationKind) bool {
    return switch (kind) {
        .bool_literal_flip,
        .comparison_flip,
        .logical_flip,
        .if_condition_negation,
        .while_condition_negation,
        .assertion_weakening,
        .try_unwrap_unreachable,
        .catch_fallback_unreachable,
        .defer_removal,
        .errdefer_removal,
        .atomic_ordering_weakening,
        .bounds_guard_weakening,
        .cleanup_call_removal,
        .lock_call_removal,
        .error_return_unreachable,
        => true,
    };
}

fn writeRegion(
    writer: *std.Io.Writer,
    source: []const u8,
    start: usize,
    end: usize,
    sites: []const Site,
    excluded: ?Bounds,
) anyerror!void {
    var cursor = start;
    while (true) {
        const next = nextTopLevelSite(sites, start, end, cursor, excluded) orelse break;
        const site = sites[next];
        try writer.writeAll(source[cursor..site.start]);
        try writeGroup(writer, source, sites, next);
        cursor = site.end;
    }
    try writer.writeAll(source[cursor..end]);
}

fn nextTopLevelSite(
    sites: []const Site,
    region_start: usize,
    region_end: usize,
    cursor: usize,
    excluded: ?Bounds,
) ?usize {
    var selected: ?usize = null;
    for (sites, 0..) |site, index| {
        if (!switchable(site.kind)) continue;
        if (site.start < cursor or site.end > region_end or site.start < region_start) continue;
        if (excluded) |bounds| {
            if (site.start == bounds.start and site.end == bounds.end) continue;
        }
        var contained = false;
        for (sites) |other_site| {
            const other = other_site;
            if (!switchable(other.kind)) continue;
            if (excluded) |bounds| {
                if (other.start == bounds.start and other.end == bounds.end) continue;
            }
            if (strictlyContains(other, site) and
                other.start >= region_start and other.end <= region_end)
            {
                contained = true;
                break;
            }
        }
        if (contained) continue;
        if (selected == null or site.start < sites[selected.?].start) selected = index;
    }
    return selected;
}

fn writeGroup(writer: *std.Io.Writer, source: []const u8, sites: []const Site, first: usize) anyerror!void {
    const bounds = sites[first];
    const statement = statementMutation(bounds.kind);
    var count: usize = 0;
    for (sites) |site| {
        if (!switchable(site.kind)) continue;
        if (site.start != bounds.start or site.end != bounds.end) continue;
        if (statementMutation(site.kind) != statement) return error.MixedMutationContext;
        count += 1;
        if (statement) {
            const replacement = if (std.mem.eql(u8, std.mem.trim(u8, site.replacement, " \t\r\n"), "{};"))
                "{}"
            else
                site.replacement;
            try writer.print("if (__zig_mutants_runtime__.active({d})) {{ {s} }} else ", .{
                site.index,
                replacement,
            });
        } else {
            try writer.print("(if (__zig_mutants_runtime__.active({d})) ({s}) else ", .{
                site.index,
                site.replacement,
            });
        }
    }

    if (statement) try writer.writeAll("{ ");
    try writeRegion(writer, source, bounds.start, bounds.end, sites, .{
        .start = bounds.start,
        .end = bounds.end,
    });
    if (statement) try writer.writeAll(" }");
    if (!statement) {
        for (0..count) |_| try writer.writeByte(')');
    }
}

fn statementMutation(kind: MutationKind) bool {
    return switch (kind) {
        .cleanup_call_removal, .lock_call_removal, .error_return_unreachable => true,
        else => false,
    };
}

fn strictlyContains(outer: Site, inner: Site) bool {
    return outer.start <= inner.start and outer.end >= inner.end and
        (outer.start != inner.start or outer.end != inner.end);
}

fn partiallyOverlaps(left: Site, right: Site) bool {
    if (left.end <= right.start or right.end <= left.start) return false;
    if (strictlyContains(left, right) or strictlyContains(right, left)) return false;
    return left.start != right.start or left.end != right.end;
}

fn trimTestName(name: []const u8) []const u8 {
    if (name.len >= 2 and name[0] == '"' and name[name.len - 1] == '"') return name[1 .. name.len - 1];
    return name;
}

fn lineColumn(source: []const u8, byte_offset: usize) struct { line: usize, column: usize } {
    var line: usize = 1;
    var column: usize = 1;
    for (source[0..@min(byte_offset, source.len)]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

test "discovers and instruments Zig test blocks" {
    const allocator = std.testing.allocator;
    const source: [:0]const u8 = "test \"works\" { try std.testing.expect(true); }\n";
    const tests = try discoverTests(allocator, source, 3);
    defer freeTestPoints(allocator, tests);
    try std.testing.expectEqual(@as(usize, 1), tests.len);
    try std.testing.expectEqualStrings("works", tests[0].name);
    const instrumented = try instrumentTests(allocator, source, tests, ".zig-mutants/runtime.zig");
    defer allocator.free(instrumented);
    try std.testing.expect(std.mem.indexOf(u8, instrumented, "enter(3)") != null);
}

test "runtime switching nests overlapping expression mutants" {
    const allocator = std.testing.allocator;
    const source = "pub fn f(a: u8, b: u8) bool { return a < b; }\n";
    const sites = [_]Site{.{
        .index = 4,
        .kind = .comparison_flip,
        .start = 39,
        .end = 44,
        .replacement = "a <= b",
    }};
    const instrumented = try instrumentMutants(allocator, source, &sites, ".zig-mutants/runtime.zig");
    defer allocator.free(instrumented);
    try std.testing.expect(std.mem.indexOf(u8, instrumented, "active(") != null);
    try std.testing.expect(std.mem.indexOf(u8, instrumented, "a <= b") != null);
}

test "runtime switching emits valid blocks for statement removal" {
    const allocator = std.testing.allocator;
    const source: [:0]const u8 = "pub fn f() void { cleanup(); }\n";
    const start = std.mem.indexOf(u8, source, "cleanup") orelse unreachable;
    const end = start + "cleanup();".len;
    const sites = [_]Site{.{
        .index = 0,
        .kind = .cleanup_call_removal,
        .start = start,
        .end = end,
        .replacement = "{};",
    }};
    const instrumented = try instrumentMutants(allocator, source, &sites, ".zig-mutants/runtime.zig");
    defer allocator.free(instrumented);
    try std.testing.expect(std.mem.indexOf(u8, instrumented, "{ {} }") != null);

    const terminated = try allocator.dupeZ(u8, instrumented);
    defer allocator.free(terminated);
    var ast = try std.zig.Ast.parse(allocator, terminated, .zig);
    defer ast.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
}
