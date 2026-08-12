const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});

const allocator = std.heap.c_allocator;
const max_captures = 16;
const pcre2_unset = std.math.maxInt(usize);
var test_live_scanners = std.atomic.Value(usize).init(0);

// Public (Ruby-faithful) name for the compiled-regex value used by pkg:regex.
pub const Regexp = CompilerRegex;

pub const CompilerRegex = struct {
    pattern: []const u8,
};

const ScannerState = struct {
    source: []const u8,
    closed: bool = false,
    pos: usize = 0,
    matched: []const u8 = "",
    captures: [max_captures]?[]const u8 = [_]?[]const u8{null} ** max_captures,
};

// Public (Ruby-faithful) name for a match result used by pkg:regex.
pub const RegexpMatch = CompilerRegexScanner;

pub const CompilerRegexScanner = struct {
    /// Opaque to CLEAR's generic ownership cleanup. Scanner storage is owned by
    /// this module and must be released with compilerRegexScannerClose.
    handle: *anyopaque,

    pub fn deinit(self: CompilerRegexScanner) void {
        trackScannerClose();
        const state = scannerState(self);
        if (state.closed) @panic("compiler_regex: scanner closed twice");
        state.closed = true;
        allocator.free(state.source);
        state.source = "";
        allocator.destroy(state);
    }
};

fn scannerState(scanner: CompilerRegexScanner) *ScannerState {
    return @ptrCast(@alignCast(scanner.handle));
}

pub fn compilerRegexCompile(pattern: []const u8) CompilerRegex {
    return .{ .pattern = pattern };
}

pub fn compilerRegexPattern(regex: CompilerRegex) []const u8 {
    return regex.pattern;
}

pub fn compilerFormatTemplate(template: []const u8) []const u8 {
    return template;
}

pub fn compilerInspectValue() []const u8 {
    return "<value>";
}

pub fn compilerRepeatString(value: []const u8, count: i64) []const u8 {
    if (count <= 0 or value.len == 0) return "";
    const repeat_count: usize = @intCast(count);
    const len = std.math.mul(usize, value.len, repeat_count) catch @panic("string repeat overflow");
    const out = allocator.alloc(u8, len) catch @panic("string repeat allocation failed");
    for (0..repeat_count) |index| {
        const start = index * value.len;
        @memcpy(out[start .. start + value.len], value);
    }
    return out;
}

pub fn compilerZigTranslateC(
    zig: []const u8,
    source_dir: []const u8,
    header_path: []const u8,
) ![]const u8 {
    const include_arg = try std.fmt.allocPrint(allocator, "-I{s}", .{source_dir});
    defer allocator.free(include_arg);

    const argv = [_][]const u8{ zig, "translate-c", include_arg, header_path };
    const result = try std.process.run(
        allocator,
        std.Io.Threaded.global_single_threaded.io(),
        .{
            .argv = &argv,
            .stdout_limit = .limited(64 * 1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        },
    );
    defer allocator.free(result.stderr);

    const succeeded = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!succeeded) {
        allocator.free(result.stdout);
        return error.ZigTranslateCFailed;
    }
    return result.stdout;
}

pub fn compilerZigExecutable() []const u8 {
    return "zig";
}

pub fn compilerRegexScanner(source: []const u8) CompilerRegexScanner {
    const state = allocator.create(ScannerState) catch @panic("failed to allocate regex scanner state");
    // The scanner OWNS its source: callers manage their argument's
    // lifetime independently (the borrowed slice may die with the caller's
    // frame while the scanner lives on inside a Lexer).
    const owned = allocator.dupe(u8, source) catch @panic("failed to copy regex scanner source");
    state.* = .{ .source = owned };
    trackScannerCreate();
    return .{ .handle = state };
}

inline fn trackScannerCreate() void {
    if (comptime builtin.is_test) _ = test_live_scanners.fetchAdd(1, .monotonic);
}

inline fn trackScannerClose() void {
    if (comptime builtin.is_test) {
        const previous = test_live_scanners.fetchSub(1, .monotonic);
        std.debug.assert(previous > 0);
    }
}

fn testScannerLiveCount() usize {
    if (comptime builtin.is_test) return test_live_scanners.load(.monotonic);
    unreachable;
}

pub fn compilerRegexScannerClose(scanner: CompilerRegexScanner) void {
    scanner.deinit();
}

pub fn compilerRegexEos(scanner: CompilerRegexScanner) bool {
    const state = scannerState(scanner);
    return state.pos >= state.source.len;
}

pub fn compilerRegexPosition(scanner: CompilerRegexScanner) i64 {
    return @intCast(scannerState(scanner).pos);
}

pub fn compilerRegexMatched(scanner: CompilerRegexScanner) []const u8 {
    return scannerState(scanner).matched;
}

pub fn compilerRegexCapture(scanner: CompilerRegexScanner, index: i64) []const u8 {
    if (index < 0) return "";
    const idx: usize = @intCast(index);
    if (idx >= max_captures) return "";
    return scannerState(scanner).captures[idx] orelse "";
}

pub fn compilerRegexPeek(scanner: CompilerRegexScanner, count: i64) []const u8 {
    if (count <= 0) return "";
    const state = scannerState(scanner);
    const start = @min(state.pos, state.source.len);
    const wanted: usize = @intCast(count);
    const end = @min(state.source.len, start + wanted);
    return state.source[start..end];
}

pub fn compilerRegexGetch(scanner: CompilerRegexScanner) ?[]const u8 {
    if (compilerRegexEos(scanner)) return null;
    const state = scannerState(scanner);
    const start = state.pos;
    const width = utf8Width(state.source[start]) orelse 1;
    const end = @min(state.source.len, start + width);
    state.pos = end;
    state.matched = state.source[start..end];
    clearCaptures(state);
    return state.matched;
}

pub fn compilerRegexScan(scanner: CompilerRegexScanner, regex: CompilerRegex) bool {
    const state = scannerState(scanner);
    const base = state.pos;
    const subject = state.source[base..];
    var result = matchRegex(regex, subject, true) orelse {
        state.matched = "";
        clearCaptures(state);
        return false;
    };
    defer result.deinit();

    const start = base + result.ranges[0].start;
    const end = base + result.ranges[0].end;
    state.pos = end;
    state.matched = state.source[start..end];
    clearCaptures(state);

    const capture_count = @min(result.count, max_captures);
    for (0..capture_count) |idx| {
        const range = result.ranges[idx];
        if (range.matched) {
            state.captures[idx] = state.source[(base + range.start)..(base + range.end)];
        }
    }
    return true;
}

pub fn compilerRegexScanValue(scanner: CompilerRegexScanner, regex: CompilerRegex) ?[]const u8 {
    if (!compilerRegexScan(scanner, regex)) return null;
    return compilerRegexMatched(scanner);
}

pub fn compilerParseUInt(digits: []const u8, base: i64) error{ Overflow, InvalidCharacter }!u64 {
    // Lexer integer literals are never negative; their full domain is u64.
    return std.fmt.parseUnsigned(u64, digits, @intCast(base));
}

pub fn compilerCountOccurrences(text: []const u8, needle: []const u8) i64 {
    if (needle.len == 0) return 0;
    var count: i64 = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, text, offset, needle)) |index| {
        count += 1;
        offset = index + needle.len;
    }
    return count;
}

pub fn compilerLastIndex(text: []const u8, needle: []const u8) i64 {
    const index = std.mem.lastIndexOf(u8, text, needle) orelse return -1;
    return @intCast(index);
}

pub fn compilerRegexMatch(subject: []const u8, regex: CompilerRegex) bool {
    var result = matchRegex(regex, subject, false) orelse return false;
    result.deinit();
    return true;
}

pub fn compilerRegexMatchData(subject: []const u8, regex: CompilerRegex) ?CompilerRegexScanner {
    var result = matchRegex(regex, subject, false) orelse return null;
    defer result.deinit();

    const whole = result.ranges[0];
    if (!whole.matched) return null;

    const state = allocator.create(ScannerState) catch @panic("failed to allocate regex match state");
    // Own the subject like compilerRegexScanner does, so the matched slice and
    // captures stay valid until close and deinit's free is of our own memory
    // (the caller's borrowed subject may die before the scanner is closed).
    const owned = allocator.dupe(u8, subject) catch @panic("failed to copy regex match source");
    state.* = .{ .source = owned };
    state.pos = whole.end;
    state.matched = owned[whole.start..whole.end];
    trackScannerCreate();

    const capture_count = @min(result.count, max_captures);
    for (0..capture_count) |idx| {
        const range = result.ranges[idx];
        if (range.matched) {
            state.captures[idx] = owned[range.start..range.end];
        }
    }

    return .{ .handle = state };
}

// Ruby `str[/regex/]`: the whole first match, or null when there is no match.
pub fn compilerRegexFirstMatch(subject: []const u8, regex: CompilerRegex) ?[]const u8 {
    var result = matchRegex(regex, subject, false) orelse return null;
    defer result.deinit();

    const whole = result.ranges[0];
    if (!whole.matched) return null;
    return subject[whole.start..whole.end];
}

// Ruby `str[/regex/, n]`: capture group n of the first match (0 = whole match),
// or null when there is no match or the group did not participate.
pub fn compilerRegexMatchGroup(subject: []const u8, regex: CompilerRegex, index: i64) ?[]const u8 {
    var result = matchRegex(regex, subject, false) orelse return null;
    defer result.deinit();

    if (index < 0 or index >= @as(i64, @intCast(result.count))) return null;
    const range = result.ranges[@intCast(index)];
    if (!range.matched) return null;
    return subject[range.start..range.end];
}

pub fn compilerRegexReplaceFirst(subject: []const u8, regex: CompilerRegex, replacement: []const u8) []const u8 {
    return replaceRegex(subject, regex, replacement, false);
}

pub fn compilerRegexReplaceAll(subject: []const u8, regex: CompilerRegex, replacement: []const u8) []const u8 {
    return replaceRegex(subject, regex, replacement, true);
}

pub fn compilerRegexEscape(value: []const u8) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (value) |ch| {
        if (isRegexMeta(ch)) out.append(allocator, '\\') catch @panic("regex escape allocation failed");
        out.append(allocator, ch) catch @panic("regex escape allocation failed");
    }
    return out.toOwnedSlice(allocator) catch @panic("regex escape allocation failed");
}

pub fn compilerCodepointToString(codepoint: u64) []const u8 {
    if (codepoint > 0x10FFFF) return "";
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(codepoint), &buf) catch return "";
    const out = allocator.alloc(u8, len) catch @panic("codepoint allocation failed");
    @memcpy(out, buf[0..len]);
    return out;
}

pub fn compilerFloatBits(value: f64) u64 {
    return @bitCast(value);
}

pub fn compilerParseIntBase(text: []const u8, base: i64) i64 {
    const radix: u8 = if (hasMatchingRadixPrefix(text, base)) 0 else @intCast(base);
    return std.fmt.parseInt(i64, text, radix) catch @panic("invalid signed integer literal");
}

pub fn compilerParseUIntBase(text: []const u8, base: i64) u64 {
    const radix: u8 = if (hasMatchingRadixPrefix(text, base)) 0 else @intCast(base);
    return std.fmt.parseInt(u64, text, radix) catch @panic("invalid unsigned integer literal");
}

pub fn compilerUIntToFloat(value: u64) f64 {
    return @floatFromInt(value);
}

fn hasMatchingRadixPrefix(text: []const u8, base: i64) bool {
    if (text.len < 2 or text[0] != '0') return false;
    return switch (text[1]) {
        'x', 'X' => base == 16,
        'o', 'O' => base == 8,
        'b', 'B' => base == 2,
        else => false,
    };
}

const Range = struct {
    start: usize = 0,
    end: usize = 0,
    matched: bool = false,
};

const MatchResult = struct {
    data: *c.pcre2_match_data_8,
    ranges: []Range,
    count: usize,

    fn deinit(self: *MatchResult) void {
        c.pcre2_match_data_free_8(self.data);
        allocator.free(self.ranges);
    }
};

fn matchRegex(regex: CompilerRegex, subject: []const u8, anchored: bool) ?MatchResult {
    var error_number: c_int = 0;
    var error_offset: usize = 0;
    const code = c.pcre2_compile_8(
        regex.pattern.ptr,
        regex.pattern.len,
        c.PCRE2_MULTILINE,
        &error_number,
        &error_offset,
        null,
    ) orelse return null;
    defer c.pcre2_code_free_8(code);

    const match_data = c.pcre2_match_data_create_from_pattern_8(code, null) orelse return null;
    errdefer c.pcre2_match_data_free_8(match_data);

    const options: u32 = if (anchored) c.PCRE2_ANCHORED else 0;
    const rc = c.pcre2_match_8(code, subject.ptr, subject.len, 0, options, match_data, null);
    if (rc < 0) {
        c.pcre2_match_data_free_8(match_data);
        return null;
    }

    const count: usize = @intCast(rc);
    const ovector = c.pcre2_get_ovector_pointer_8(match_data);
    const ranges = allocator.alloc(Range, count) catch @panic("regex match allocation failed");
    for (0..count) |idx| {
        const start = ovector[idx * 2];
        const end = ovector[(idx * 2) + 1];
        ranges[idx] = if (start == pcre2_unset or end == pcre2_unset)
            .{}
        else
            .{ .start = start, .end = end, .matched = true };
    }

    return .{ .data = match_data, .ranges = ranges, .count = count };
}

fn replaceRegex(subject: []const u8, regex: CompilerRegex, replacement: []const u8, all: bool) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var offset: usize = 0;

    while (offset <= subject.len) {
        var result = matchRegex(regex, subject[offset..], false) orelse {
            out.appendSlice(allocator, subject[offset..]) catch @panic("regex replace allocation failed");
            break;
        };
        defer result.deinit();

        const range = result.ranges[0];
        if (!range.matched) {
            out.appendSlice(allocator, subject[offset..]) catch @panic("regex replace allocation failed");
            break;
        }

        out.appendSlice(allocator, subject[offset .. offset + range.start]) catch @panic("regex replace allocation failed");
        out.appendSlice(allocator, replacement) catch @panic("regex replace allocation failed");
        offset += range.end;

        if (!all) {
            out.appendSlice(allocator, subject[offset..]) catch @panic("regex replace allocation failed");
            break;
        }

        if (range.start == range.end) {
            if (offset >= subject.len) break;
            out.append(allocator, subject[offset]) catch @panic("regex replace allocation failed");
            offset += 1;
        }
    }

    return out.toOwnedSlice(allocator) catch @panic("regex replace allocation failed");
}

fn clearCaptures(state: *ScannerState) void {
    state.captures = [_]?[]const u8{null} ** max_captures;
}

fn isRegexMeta(ch: u8) bool {
    return switch (ch) {
        '\\', '.', '+', '*', '?', '[', '^', ']', '$', '(', ')', '{', '}', '=', '!', '<', '>', '|', ':', '-' => true,
        else => false,
    };
}

fn utf8Width(first: u8) ?usize {
    if (first < 0x80) return 1;
    if ((first & 0b1110_0000) == 0b1100_0000) return 2;
    if ((first & 0b1111_0000) == 0b1110_0000) return 3;
    if ((first & 0b1111_1000) == 0b1111_0000) return 4;
    return null;
}

test "compiler regex scanner" {
    const scanner = compilerRegexScanner("abc123");
    defer compilerRegexScannerClose(scanner);
    try std.testing.expect(compilerRegexScan(scanner, compilerRegexCompile("[a-z]+")));
    try std.testing.expectEqualStrings("abc", compilerRegexMatched(scanner));
    try std.testing.expect(compilerRegexScan(scanner, compilerRegexCompile("(\\d+)")));
    try std.testing.expectEqualStrings("123", compilerRegexCapture(scanner, 1));
    try std.testing.expect(compilerRegexEos(scanner));
}

test "compiler regex scanner repeated create and close balances exactly" {
    try std.testing.expectEqual(@as(usize, 0), testScannerLiveCount());
    for (0..10_000) |_| {
        const scanner = compilerRegexScanner("borrowed source");
        try std.testing.expectEqualStrings("b", compilerRegexGetch(scanner).?);
        compilerRegexScannerClose(scanner);
    }
    try std.testing.expectEqual(@as(usize, 0), testScannerLiveCount());
}

test "compiler regex match-data scanners retain borrowed captures until close" {
    try std.testing.expectEqual(@as(usize, 0), testScannerLiveCount());
    for (0..100) |_| {
        const scanner = compilerRegexMatchData("name=clear", compilerRegexCompile("name=(\\w+)")) orelse unreachable;
        try std.testing.expectEqualStrings("name=clear", compilerRegexMatched(scanner));
        try std.testing.expectEqualStrings("clear", compilerRegexCapture(scanner, 1));
        compilerRegexScannerClose(scanner);
    }
    try std.testing.expectEqual(@as(usize, 0), testScannerLiveCount());
}

fn scannerLifetimeWorker() void {
    for (0..1_000) |_| {
        const scanner = compilerRegexScanner("thread-local scanner");
        _ = compilerRegexGetch(scanner);
        compilerRegexScannerClose(scanner);
    }
}

test "compiler regex independent scanner lifetimes are thread safe" {
    var threads: [32]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, scannerLifetimeWorker, .{});
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(usize, 0), testScannerLiveCount());
}

test "compiler regex first match returns the whole match or null" {
    try std.testing.expectEqualStrings("~!?", compilerRegexFirstMatch("~!?User", compilerRegexCompile("\\A[~!?]+")).?);
    try std.testing.expect(compilerRegexFirstMatch("User", compilerRegexCompile("\\A[~!?]+")) == null);
    try std.testing.expectEqualStrings("  ", compilerRegexFirstMatch("  body", compilerRegexCompile("\\A\\s*")).?);
}

test "compiler regex match group returns the requested capture or null" {
    const re = compilerRegexCompile("\\A\\[(\\d*|INF)\\]\\z");
    try std.testing.expectEqualStrings("[10]", compilerRegexMatchGroup("[10]", re, 0).?);
    try std.testing.expectEqualStrings("10", compilerRegexMatchGroup("[10]", re, 1).?);
    try std.testing.expectEqualStrings("INF", compilerRegexMatchGroup("[INF]", re, 1).?);
    try std.testing.expect(compilerRegexMatchGroup("nope", re, 1) == null);
    try std.testing.expect(compilerRegexMatchGroup("[10]", re, 5) == null);
}
