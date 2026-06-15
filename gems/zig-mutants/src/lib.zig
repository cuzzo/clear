const std = @import("std");

const Ast = std.zig.Ast;
const Token = std.zig.Token;
const Allocator = std.mem.Allocator;

pub const MutationKind = enum {
    bool_literal_flip,
    comparison_flip,
    logical_flip,
    if_condition_negation,
    while_condition_negation,
    assertion_weakening,
    defer_removal,
    errdefer_removal,
    try_unwrap_unreachable,
    catch_fallback_unreachable,
    cleanup_call_removal,
    lock_call_removal,
    atomic_ordering_weakening,
    error_return_unreachable,
    bounds_guard_weakening,

    pub fn label(kind: MutationKind) []const u8 {
        return @tagName(kind);
    }
};

pub const Outcome = enum {
    killed,
    survived,
    timeout,
    unviable,
    skipped,

    pub fn label(outcome: Outcome) []const u8 {
        return @tagName(outcome);
    }
};

pub const Mutant = struct {
    id: []const u8,
    path: []const u8,
    method: []const u8,
    kind: MutationKind,
    line: usize,
    column: usize,
    start: usize,
    end: usize,
    original: []const u8,
    replacement: []const u8,

    pub fn deinit(self: Mutant, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.path);
        allocator.free(self.method);
        allocator.free(self.original);
        allocator.free(self.replacement);
    }
};

pub const TrialResult = struct {
    mutant_index: usize,
    outcome: Outcome,
    exit_code: i32 = 0,
    artifact_path: ?[]const u8 = null,

    pub fn deinit(self: TrialResult, allocator: Allocator) void {
        if (self.artifact_path) |path| allocator.free(path);
    }
};

pub const RunSummary = struct {
    total: usize,
    killed: usize,
    survived: usize,
    timeout: usize,
    unviable: usize,
    skipped: usize,

    pub fn killRate(self: RunSummary) f64 {
        const selected = self.killed + self.survived + self.timeout;
        if (selected == 0) return 100.0;
        return (@as(f64, @floatFromInt(self.killed)) / @as(f64, @floatFromInt(selected))) * 100.0;
    }
};

pub fn freeMutants(allocator: Allocator, mutants: []Mutant) void {
    for (mutants) |mutant| mutant.deinit(allocator);
    allocator.free(mutants);
}

pub fn freeTrialResults(allocator: Allocator, results: []TrialResult) void {
    for (results) |result| result.deinit(allocator);
    allocator.free(results);
}

pub fn discoverFile(allocator: Allocator, path: []const u8, source: [:0]const u8) ![]Mutant {
    var tree = try Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.ParseError;

    const function_spans = try collectFunctionSpans(allocator, &tree);
    defer allocator.free(function_spans);

    var collector = Collector{
        .allocator = allocator,
        .path = path,
        .source = source,
        .tree = &tree,
        .function_spans = function_spans,
        .mutants = std.array_list.Managed(Mutant).init(allocator),
    };
    errdefer collector.deinitMutants();

    var raw_node: u32 = 1;
    while (raw_node < tree.nodes.len) : (raw_node += 1) {
        const node: Ast.Node.Index = @enumFromInt(raw_node);
        try collector.visitNode(node);
    }

    return collector.mutants.toOwnedSlice();
}

pub fn applyMutant(allocator: Allocator, source: []const u8, mutant: Mutant) ![]u8 {
    if (mutant.start > mutant.end or mutant.end > source.len) return error.InvalidMutantSpan;
    var out = try std.array_list.Managed(u8).initCapacity(
        allocator,
        source.len - (mutant.end - mutant.start) + mutant.replacement.len,
    );
    errdefer out.deinit();
    try out.appendSlice(source[0..mutant.start]);
    try out.appendSlice(mutant.replacement);
    try out.appendSlice(source[mutant.end..]);
    return out.toOwnedSlice();
}

pub fn summarize(mutants: []const Mutant, results: []const TrialResult, path: []const u8) RunSummary {
    return summarizeByMethod(mutants, results, path, null);
}

pub fn summarizeByMethod(
    mutants: []const Mutant,
    results: []const TrialResult,
    path: []const u8,
    method: ?[]const u8,
) RunSummary {
    var summary = RunSummary{
        .total = 0,
        .killed = 0,
        .survived = 0,
        .timeout = 0,
        .unviable = 0,
        .skipped = 0,
    };
    for (mutants) |mutant| {
        if (!std.mem.eql(u8, mutant.path, path)) continue;
        if (method) |name| {
            if (!std.mem.eql(u8, mutant.method, name)) continue;
        }
        summary.total += 1;
    }
    for (results) |result| {
        if (result.mutant_index >= mutants.len) continue;
        if (!std.mem.eql(u8, mutants[result.mutant_index].path, path)) continue;
        if (method) |name| {
            if (!std.mem.eql(u8, mutants[result.mutant_index].method, name)) continue;
        }
        switch (result.outcome) {
            .killed => summary.killed += 1,
            .survived => summary.survived += 1,
            .timeout => summary.timeout += 1,
            .unviable => summary.unviable += 1,
            .skipped => summary.skipped += 1,
        }
    }
    return summary;
}

pub fn writeFactsJson(
    allocator: Allocator,
    sources: []const []const u8,
    mutants: []const Mutant,
    results: []const TrialResult,
    hard_gate: bool,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll("{\n");
    try w.writeAll("  \"schema\": \"mutant-facts/v1\",\n");
    try w.writeAll("  \"source\": \"gems/zig-mutants\",\n");
    try w.writeAll("  \"language\": \"zig\",\n");
    try w.writeAll("  \"mutation_kind\": \"invariant\",\n");
    try w.writeAll("  \"subjects\": [\n");
    var subjects_written: usize = 0;
    for (sources) |source| {
        for (mutants, 0..) |mutant, index| {
            if (!std.mem.eql(u8, mutant.path, source)) continue;
            if (methodSeenBefore(mutants, source, mutant.method, index)) continue;

            const summary = summarizeByMethod(mutants, results, source, mutant.method);
            if (subjects_written != 0) try w.writeAll(",\n");
            subjects_written += 1;
            try w.writeAll("    { \"file\": ");
            try writeJsonString(w, source);
            try w.writeAll(", \"method\": ");
            try writeJsonString(w, mutant.method);
            try w.writeAll(", \"kill_rate\": ");
            try w.print("{d:.2}", .{summary.killRate()});
            try w.writeAll(", \"gate_status\": ");
            try writeJsonString(w, if (hard_gate) "hard" else "advisory");
            try w.writeAll(", \"mutation_kind\": \"invariant\"");
            try w.print(
                ", \"mutations\": {d}, \"killed\": {d}, \"alive\": {d}, \"timeouts\": {d}, \"unviable\": {d}, \"skipped\": {d} }}",
                .{
                    summary.total,
                    summary.killed,
                    summary.survived,
                    summary.timeout,
                    summary.unviable,
                    summary.skipped,
                },
            );
        }
    }
    try w.writeAll("\n  ],\n");
    try w.writeAll("  \"mutants\": [\n");
    var mutants_written: usize = 0;
    for (results) |result| {
        if (result.mutant_index >= mutants.len) continue;
        const mutant = mutants[result.mutant_index];
        if (mutants_written != 0) try w.writeAll(",\n");
        mutants_written += 1;
        try w.writeAll("    { \"id\": ");
        try writeJsonString(w, mutant.id);
        try w.writeAll(", \"file\": ");
        try writeJsonString(w, mutant.path);
        try w.writeAll(", \"method\": ");
        try writeJsonString(w, mutant.method);
        try w.writeAll(", \"kind\": ");
        try writeJsonString(w, mutant.kind.label());
        try w.writeAll(", \"outcome\": ");
        try writeJsonString(w, result.outcome.label());
        try w.print(", \"line\": {d}, \"column\": {d}, \"exit_code\": {d}", .{
            mutant.line,
            mutant.column,
            result.exit_code,
        });
        if (result.artifact_path) |artifact_path| {
            try w.writeAll(", \"artifact\": ");
            try writeJsonString(w, artifact_path);
        }
        try w.writeAll(" }");
    }
    try w.writeAll("\n  ]\n");
    try w.writeAll("}\n");

    return out.toOwnedSlice();
}

fn methodSeenBefore(mutants: []const Mutant, path: []const u8, method: []const u8, before: usize) bool {
    for (mutants[0..before]) |mutant| {
        if (std.mem.eql(u8, mutant.path, path) and std.mem.eql(u8, mutant.method, method)) return true;
    }
    return false;
}

pub fn writeJsonString(w: *std.Io.Writer, value: []const u8) !void {
    try w.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11...12, 14...0x1f => try w.print("\\u{x:0>4}", .{byte}),
            else => try w.writeByte(byte),
        }
    }
    try w.writeByte('"');
}

const Collector = struct {
    allocator: Allocator,
    path: []const u8,
    source: [:0]const u8,
    tree: *const Ast,
    function_spans: []const FunctionSpan,
    mutants: std.array_list.Managed(Mutant),

    fn deinitMutants(self: *Collector) void {
        for (self.mutants.items) |mutant| mutant.deinit(self.allocator);
        self.mutants.deinit();
    }

    fn visitNode(self: *Collector, node: Ast.Node.Index) !void {
        const tag = self.tree.nodeTag(node);
        switch (tag) {
            .identifier => try self.maybeBoolLiteral(node),
            .equal_equal => try self.addTokenReplacement(node, .comparison_flip, "!="),
            .bang_equal => try self.addTokenReplacement(node, .comparison_flip, "=="),
            .less_than => try self.addTokenReplacement(node, .comparison_flip, "<="),
            .less_or_equal => try self.addTokenReplacement(node, .comparison_flip, "<"),
            .greater_than => try self.addTokenReplacement(node, .comparison_flip, ">="),
            .greater_or_equal => try self.addTokenReplacement(node, .comparison_flip, ">"),
            .bool_and => try self.addTokenReplacement(node, .logical_flip, "or"),
            .bool_or => try self.addTokenReplacement(node, .logical_flip, "and"),
            .if_simple, .@"if" => try self.addConditionNegation(node, .if_condition_negation),
            .while_simple, .while_cont, .@"while" => try self.addConditionNegation(node, .while_condition_negation),
            .call, .call_comma, .call_one, .call_one_comma => try self.visitCall(node),
            .@"defer" => try self.addNodeReplacement(node, .defer_removal, "{};"),
            .@"errdefer" => try self.addNodeReplacement(node, .errdefer_removal, "{};"),
            .@"try" => try self.addTryUnreachable(node),
            .@"catch" => try self.addCatchUnreachable(node),
            .enum_literal => try self.maybeAtomicOrderingWeakening(node),
            .@"return" => try self.maybeErrorReturnUnreachable(node),
            else => {},
        }
    }

    fn visitCall(self: *Collector, node: Ast.Node.Index) !void {
        try self.maybeAssertWeakening(node);
        try self.maybeStandaloneCallRemoval(node);
    }

    fn maybeBoolLiteral(self: *Collector, node: Ast.Node.Index) !void {
        const token = self.tree.nodeMainToken(node);
        const text = self.tree.tokenSlice(token);
        if (std.mem.eql(u8, text, "true")) {
            try self.addTokenReplacement(node, .bool_literal_flip, "false");
        } else if (std.mem.eql(u8, text, "false")) {
            try self.addTokenReplacement(node, .bool_literal_flip, "true");
        }
    }

    fn addTokenReplacement(self: *Collector, node: Ast.Node.Index, kind: MutationKind, replacement: []const u8) !void {
        const token = self.tree.nodeMainToken(node);
        const start = self.tree.tokenStart(token);
        const original = self.tree.tokenSlice(token);
        try self.addMutant(kind, start, start + original.len, replacement);
    }

    fn addNodeReplacement(self: *Collector, node: Ast.Node.Index, kind: MutationKind, replacement: []const u8) !void {
        const first = self.tree.firstToken(node);
        var last = self.tree.lastToken(node);
        if (last + 1 < self.tree.tokens.len and self.tree.tokenTag(last + 1) == .semicolon) {
            last += 1;
        }
        const start = self.tree.tokenStart(first);
        const end_token_start = self.tree.tokenStart(last);
        const end = end_token_start + self.tree.tokenSlice(last).len;
        try self.addMutant(kind, start, end, replacement);
    }

    fn addConditionNegation(self: *Collector, node: Ast.Node.Index, kind: MutationKind) !void {
        const cond = switch (self.tree.nodeTag(node)) {
            .if_simple => self.tree.ifSimple(node).ast.cond_expr,
            .@"if" => self.tree.ifFull(node).ast.cond_expr,
            .while_simple => self.tree.whileSimple(node).ast.cond_expr,
            .while_cont => self.tree.whileCont(node).ast.cond_expr,
            .@"while" => self.tree.whileFull(node).ast.cond_expr,
            else => unreachable,
        };
        if (self.tree.nodeTag(cond) == .bool_not) return;
        const span = self.tree.nodeToSpan(cond);
        const original = self.source[span.start..span.end];
        const replacement = try std.fmt.allocPrint(self.allocator, "!({s})", .{original});
        defer self.allocator.free(replacement);
        try self.addMutant(kind, span.start, span.end, replacement);
        if (kind == .if_condition_negation) {
            try self.maybeBoundsGuardWeakening(cond, span);
        }
    }

    fn maybeAssertWeakening(self: *Collector, node: Ast.Node.Index) !void {
        var buffer: [1]Ast.Node.Index = undefined;
        const call = self.tree.fullCall(&buffer, node) orelse return;
        if (!try self.callTargetIs(call.ast.fn_expr, "std.debug.assert")) return;
        if (call.ast.params.len == 0) return;

        const param = call.ast.params[0];
        const span = self.tree.nodeToSpan(param);
        const original = std.mem.trim(u8, self.source[span.start..span.end], " \t\r\n");
        if (std.mem.eql(u8, original, "true")) return;
        try self.addMutant(.assertion_weakening, span.start, span.end, "true");
    }

    fn maybeStandaloneCallRemoval(self: *Collector, node: Ast.Node.Index) !void {
        var buffer: [1]Ast.Node.Index = undefined;
        const call = self.tree.fullCall(&buffer, node) orelse return;
        var name = std.Io.Writer.Allocating.init(self.allocator);
        defer name.deinit();
        try self.writeCallee(&name.writer, call.ast.fn_expr);
        const callee = name.written();
        const kind: ?MutationKind = if (calleeEndsWithAny(callee, &.{ ".free", ".destroy", ".deinit", ".release" }))
            .cleanup_call_removal
        else if (calleeEndsWithAny(callee, &.{ ".lock", ".unlock" }))
            .lock_call_removal
        else
            null;
        const selected = kind orelse return;
        if (self.previousTokenIs(node, .keyword_try)) return;
        const span = self.statementSpan(node) orelse return;
        try self.addMutant(selected, span.start, span.end, "{};");
    }

    fn addTryUnreachable(self: *Collector, node: Ast.Node.Index) !void {
        const expr = self.tree.nodeData(node).node;
        const expr_span = self.tree.nodeToSpan(expr);
        const original = self.source[expr_span.start..expr_span.end];
        const replacement = try std.fmt.allocPrint(self.allocator, "({s} catch unreachable)", .{original});
        defer self.allocator.free(replacement);
        const span = self.tree.nodeToSpan(node);
        try self.addMutant(.try_unwrap_unreachable, span.start, span.end, replacement);
    }

    fn addCatchUnreachable(self: *Collector, node: Ast.Node.Index) !void {
        const catch_token = self.tree.nodeMainToken(node);
        const start = self.tree.tokenStart(catch_token);
        const span = self.tree.nodeToSpan(node);
        try self.addMutant(.catch_fallback_unreachable, start, span.end, "catch unreachable");
    }

    fn maybeAtomicOrderingWeakening(self: *Collector, node: Ast.Node.Index) !void {
        const span = self.tree.nodeToSpan(node);
        const original = self.source[span.start..span.end];
        if (!std.mem.eql(u8, original, ".acquire") and
            !std.mem.eql(u8, original, ".release") and
            !std.mem.eql(u8, original, ".acq_rel") and
            !std.mem.eql(u8, original, ".seq_cst"))
        {
            return;
        }
        try self.addMutant(.atomic_ordering_weakening, span.start, span.end, ".monotonic");
    }

    fn maybeErrorReturnUnreachable(self: *Collector, node: Ast.Node.Index) !void {
        const value = self.tree.nodeData(node).opt_node.unwrap() orelse return;
        if (self.tree.nodeTag(value) != .error_value) return;
        if (self.statementSpan(node)) |span| {
            try self.addMutant(.error_return_unreachable, span.start, span.end, "unreachable;");
            return;
        }
        const span = self.tree.nodeToSpan(node);
        try self.addMutant(.error_return_unreachable, span.start, span.end, "unreachable");
    }

    fn maybeBoundsGuardWeakening(self: *Collector, cond: Ast.Node.Index, span: Ast.Span) !void {
        const original = self.source[span.start..span.end];
        if (std.mem.eql(u8, std.mem.trim(u8, original, " \t\r\n"), "true")) return;
        if (!looksLikeBoundsGuard(original)) return;
        _ = cond;
        try self.addMutant(.bounds_guard_weakening, span.start, span.end, "true");
    }

    fn callTargetIs(self: *Collector, node: Ast.Node.Index, expected: []const u8) !bool {
        var name = std.Io.Writer.Allocating.init(self.allocator);
        defer name.deinit();
        try self.writeCallee(&name.writer, node);
        return std.mem.eql(u8, name.written(), expected);
    }

    fn writeCallee(self: *Collector, w: *std.Io.Writer, node: Ast.Node.Index) !void {
        switch (self.tree.nodeTag(node)) {
            .identifier => try w.writeAll(self.tree.tokenSlice(self.tree.nodeMainToken(node))),
            .field_access => {
                const lhs, const field_token = self.tree.nodeData(node).node_and_token;
                try self.writeCallee(w, lhs);
                try w.writeByte('.');
                try w.writeAll(self.tree.tokenSlice(field_token));
            },
            else => {},
        }
    }

    fn addMutant(self: *Collector, kind: MutationKind, start: usize, end: usize, replacement: []const u8) !void {
        if (start > end or end > self.source.len) return error.InvalidMutantSpan;
        const original = self.source[start..end];
        if (std.mem.eql(u8, original, replacement)) return;

        const loc = lineColumn(self.source, start);
        const method = self.methodForOffset(start);
        const owned_original = try self.allocator.dupe(u8, original);
        errdefer self.allocator.free(owned_original);
        const owned_replacement = try self.allocator.dupe(u8, replacement);
        errdefer self.allocator.free(owned_replacement);
        const owned_path = try self.allocator.dupe(u8, self.path);
        errdefer self.allocator.free(owned_path);
        const owned_method = try self.allocator.dupe(u8, method);
        errdefer self.allocator.free(owned_method);
        const id = try stableId(self.allocator, self.path, loc.line, loc.column, kind, original, replacement);
        errdefer self.allocator.free(id);

        try self.mutants.append(.{
            .id = id,
            .path = owned_path,
            .method = owned_method,
            .kind = kind,
            .line = loc.line,
            .column = loc.column,
            .start = start,
            .end = end,
            .original = owned_original,
            .replacement = owned_replacement,
        });
    }

    const StatementSpan = struct {
        start: usize,
        end: usize,
        has_semicolon: bool,
    };

    fn statementSpan(self: *const Collector, node: Ast.Node.Index) ?StatementSpan {
        const first = self.tree.firstToken(node);
        var last = self.tree.lastToken(node);
        var has_semicolon = false;
        if (last + 1 < self.tree.tokens.len and self.tree.tokenTag(last + 1) == .semicolon) {
            last += 1;
            has_semicolon = true;
        }
        if (!has_semicolon) return null;
        const start = self.tree.tokenStart(first);
        const end_token_start = self.tree.tokenStart(last);
        return .{
            .start = start,
            .end = end_token_start + self.tree.tokenSlice(last).len,
            .has_semicolon = has_semicolon,
        };
    }

    fn previousTokenIs(self: *const Collector, node: Ast.Node.Index, tag: Token.Tag) bool {
        const first = self.tree.firstToken(node);
        return first > 0 and self.tree.tokenTag(first - 1) == tag;
    }

    fn methodForOffset(self: *const Collector, offset: usize) []const u8 {
        var best: ?FunctionSpan = null;
        for (self.function_spans) |span| {
            if (offset < span.start or offset > span.end) continue;
            if (best == null or span.end - span.start < best.?.end - best.?.start) {
                best = span;
            }
        }
        return if (best) |span| span.name else "*";
    }
};

const FunctionSpan = struct {
    name: []const u8,
    start: usize,
    end: usize,
};

fn collectFunctionSpans(allocator: Allocator, tree: *const Ast) ![]FunctionSpan {
    var spans = std.array_list.Managed(FunctionSpan).init(allocator);
    errdefer spans.deinit();
    var raw_node: u32 = 1;
    while (raw_node < tree.nodes.len) : (raw_node += 1) {
        const node: Ast.Node.Index = @enumFromInt(raw_node);
        if (tree.nodeTag(node) != .fn_decl) continue;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, node) orelse continue;
        const name = if (proto.name_token) |token| tree.tokenSlice(token) else "*";
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        const start = tree.tokenStart(first);
        const end = tree.tokenStart(last) + tree.tokenSlice(last).len;
        try spans.append(.{
            .name = name,
            .start = start,
            .end = end,
        });
    }
    return spans.toOwnedSlice();
}

fn calleeEndsWithAny(callee: []const u8, suffixes: []const []const u8) bool {
    for (suffixes) |suffix| {
        if (std.mem.endsWith(u8, callee, suffix)) return true;
    }
    return false;
}

fn looksLikeBoundsGuard(source: []const u8) bool {
    const needles = [_][]const u8{
        ".len",
        "capacity",
        "count",
        "index",
        "idx",
        "bounds",
        "limit",
        "size",
    };
    for (needles) |needle| {
        if (std.mem.indexOf(u8, source, needle) != null) return true;
    }
    return false;
}

const SourceLocation = struct {
    line: usize,
    column: usize,
};

fn lineColumn(source: []const u8, byte_offset: usize) SourceLocation {
    var line: usize = 1;
    var column: usize = 1;
    var i: usize = 0;
    while (i < byte_offset and i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

fn stableId(
    allocator: Allocator,
    path: []const u8,
    line: usize,
    column: usize,
    kind: MutationKind,
    original: []const u8,
    replacement: []const u8,
) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(path);
    hasher.update(&.{0});
    const line_text = try std.fmt.allocPrint(allocator, "{d}:{d}:{s}:{s}:{s}", .{
        line,
        column,
        kind.label(),
        original,
        replacement,
    });
    defer allocator.free(line_text);
    hasher.update(line_text);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    const hex = std.fmt.bytesToHex(digest[0..8], .lower);
    return std.fmt.allocPrint(allocator, "zig:{s}:{d}:{d}:{s}:{s}", .{
        path,
        line,
        column,
        kind.label(),
        hex,
    });
}

test "discovers Zig mutants from std AST nodes without touching comments or strings" {
    const allocator = std.testing.allocator;
    const source =
        \\const std = @import("std");
        \\pub fn sample(x: i32, y: i32) bool {
        \\    // true == false and x < y
        \\    const ignored = "false and x >= y";
        \\    defer cleanup();
        \\    std.debug.assert(x < y);
        \\    if (x == y or true) return false;
        \\    while (x <= y and y > 0) break;
        \\    return x != y;
        \\}
        \\fn cleanup() void {}
        \\
    ;
    const zsource = try allocator.dupeZ(u8, source);
    defer allocator.free(zsource);

    const mutants = try discoverFile(allocator, "sample.zig", zsource);
    defer freeMutants(allocator, mutants);

    try std.testing.expect(mutants.len >= 12);
    for (mutants) |mutant| {
        try std.testing.expect(!std.mem.eql(u8, mutant.original, "true == false"));
        try std.testing.expect(!std.mem.eql(u8, mutant.original, "false and x >= y"));
    }
    try std.testing.expect(hasKind(mutants, .bool_literal_flip));
    try std.testing.expect(hasKind(mutants, .comparison_flip));
    try std.testing.expect(hasKind(mutants, .logical_flip));
    try std.testing.expect(hasKind(mutants, .if_condition_negation));
    try std.testing.expect(hasKind(mutants, .while_condition_negation));
    try std.testing.expect(hasKind(mutants, .assertion_weakening));
    try std.testing.expect(hasKind(mutants, .defer_removal));
    try std.testing.expect(hasMethodForKind(mutants, .bool_literal_flip, "sample"));
}

test "discovers runtime safety mutants with function attribution" {
    const allocator = std.testing.allocator;
    const source =
        \\const std = @import("std");
        \\pub fn runtimePath(alloc: std.mem.Allocator, items: []u8, index: usize) !void {
        \\    if (index < items.len) {
        \\        std.debug.assert(items.len > 0);
        \\    }
        \\    const box = try alloc.create(u8);
        \\    errdefer alloc.destroy(box);
        \\    alloc.free(items);
        \\    var m = std.Thread.Mutex{};
        \\    m.lock();
        \\    m.unlock();
        \\    std.atomic.spinLoopHint();
        \\    flag.store(1, .release);
        \\    return error.Bad;
        \\}
        \\fn fallback() u8 {
        \\    return maybe() catch 1;
        \\}
        \\extern var flag: std.atomic.Value(u8);
        \\extern fn maybe() anyerror!u8;
        \\
    ;
    const zsource = try allocator.dupeZ(u8, source);
    defer allocator.free(zsource);

    const mutants = try discoverFile(allocator, "runtime.zig", zsource);
    defer freeMutants(allocator, mutants);

    try std.testing.expect(hasKind(mutants, .try_unwrap_unreachable));
    try std.testing.expect(hasKind(mutants, .catch_fallback_unreachable));
    try std.testing.expect(hasKind(mutants, .cleanup_call_removal));
    try std.testing.expect(hasKind(mutants, .lock_call_removal));
    try std.testing.expect(hasKind(mutants, .atomic_ordering_weakening));
    try std.testing.expect(hasKind(mutants, .error_return_unreachable));
    try std.testing.expect(hasKind(mutants, .bounds_guard_weakening));
    try std.testing.expect(hasMethodForKind(mutants, .try_unwrap_unreachable, "runtimePath"));
    try std.testing.expect(hasMethodForKind(mutants, .catch_fallback_unreachable, "fallback"));
}

test "applies a mutant by source span" {
    const allocator = std.testing.allocator;
    const source = "pub fn f() bool { return true; }\n";
    const zsource = try allocator.dupeZ(u8, source);
    defer allocator.free(zsource);

    const mutants = try discoverFile(allocator, "sample.zig", zsource);
    defer freeMutants(allocator, mutants);

    const first = mutants[0];
    const mutated = try applyMutant(allocator, source, first);
    defer allocator.free(mutated);

    try std.testing.expect(std.mem.indexOf(u8, mutated, first.replacement) != null);
    try std.testing.expect(!std.mem.eql(u8, mutated, source));
}

test "writes boobytrap-compatible mutant facts JSON" {
    const allocator = std.testing.allocator;
    const source = "pub fn f() bool { return true; }\n";
    const zsource = try allocator.dupeZ(u8, source);
    defer allocator.free(zsource);

    const mutants = try discoverFile(allocator, "sample.zig", zsource);
    defer freeMutants(allocator, mutants);
    const results = [_]TrialResult{
        .{ .mutant_index = 0, .outcome = .killed, .exit_code = 1 },
    };
    const sources = [_][]const u8{"sample.zig"};

    const json = try writeFactsJson(allocator, &sources, mutants, &results, false);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"schema\": \"mutant-facts/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"language\": \"zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"mutation_kind\": \"invariant\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"method\": \"f\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kill_rate\": 100.00") != null);
}

fn hasKind(mutants: []const Mutant, kind: MutationKind) bool {
    for (mutants) |mutant| {
        if (mutant.kind == kind) return true;
    }
    return false;
}

fn hasMethodForKind(mutants: []const Mutant, kind: MutationKind, method: []const u8) bool {
    for (mutants) |mutant| {
        if (mutant.kind == kind and std.mem.eql(u8, mutant.method, method)) return true;
    }
    return false;
}
