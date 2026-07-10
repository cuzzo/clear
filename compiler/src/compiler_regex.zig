const std = @import("std");

const c = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});

const allocator = std.heap.c_allocator;
const max_captures = 16;
const pcre2_unset = std.math.maxInt(usize);

pub const CompilerRegex = struct {
    pattern: []const u8,
};

const ScannerState = struct {
    pos: usize = 0,
    matched: []const u8 = "",
    captures: [max_captures]?[]const u8 = [_]?[]const u8{null} ** max_captures,
};

pub const CompilerRegexScanner = struct {
    source: []const u8,
    state: *ScannerState,
};

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

pub fn compilerRegexScanner(source: []const u8) CompilerRegexScanner {
    const state = allocator.create(ScannerState) catch @panic("failed to allocate regex scanner state");
    state.* = .{};
    return .{ .source = source, .state = state };
}

pub fn compilerRegexEos(scanner: CompilerRegexScanner) bool {
    return scanner.state.pos >= scanner.source.len;
}

pub fn compilerRegexMatched(scanner: CompilerRegexScanner) []const u8 {
    return scanner.state.matched;
}

pub fn compilerRegexCapture(scanner: CompilerRegexScanner, index: i64) []const u8 {
    if (index < 0) return "";
    const idx: usize = @intCast(index);
    if (idx >= max_captures) return "";
    return scanner.state.captures[idx] orelse "";
}

pub fn compilerRegexPeek(scanner: CompilerRegexScanner, count: i64) []const u8 {
    if (count <= 0) return "";
    const start = @min(scanner.state.pos, scanner.source.len);
    const wanted: usize = @intCast(count);
    const end = @min(scanner.source.len, start + wanted);
    return scanner.source[start..end];
}

pub fn compilerRegexGetch(scanner: CompilerRegexScanner) ?[]const u8 {
    if (compilerRegexEos(scanner)) return null;
    const start = scanner.state.pos;
    const width = utf8Width(scanner.source[start]) orelse 1;
    const end = @min(scanner.source.len, start + width);
    scanner.state.pos = end;
    scanner.state.matched = scanner.source[start..end];
    clearCaptures(scanner.state);
    return scanner.state.matched;
}

pub fn compilerRegexScan(scanner: CompilerRegexScanner, regex: CompilerRegex) bool {
    const base = scanner.state.pos;
    const subject = scanner.source[base..];
    var result = matchRegex(regex.pattern, subject, true) orelse {
        scanner.state.matched = "";
        clearCaptures(scanner.state);
        return false;
    };
    defer result.deinit();

    const start = base + result.ranges[0].start;
    const end = base + result.ranges[0].end;
    scanner.state.pos = end;
    scanner.state.matched = scanner.source[start..end];
    clearCaptures(scanner.state);

    const capture_count = @min(result.count, max_captures);
    for (0..capture_count) |idx| {
        const range = result.ranges[idx];
        if (range.matched) {
            scanner.state.captures[idx] = scanner.source[(base + range.start)..(base + range.end)];
        }
    }
    return true;
}

pub fn compilerRegexMatch(subject: []const u8, regex: CompilerRegex) bool {
    var result = matchRegex(regex.pattern, subject, false) orelse return false;
    result.deinit();
    return true;
}

pub fn compilerRegexMatchData(subject: []const u8, regex: CompilerRegex) ?CompilerRegexScanner {
    var result = matchRegex(regex.pattern, subject, false) orelse return null;
    defer result.deinit();

    const whole = result.ranges[0];
    if (!whole.matched) return null;

    const state = allocator.create(ScannerState) catch @panic("failed to allocate regex match state");
    state.* = .{};
    state.pos = whole.end;
    state.matched = subject[whole.start..whole.end];

    const capture_count = @min(result.count, max_captures);
    for (0..capture_count) |idx| {
        const range = result.ranges[idx];
        if (range.matched) {
            state.captures[idx] = subject[range.start..range.end];
        }
    }

    return .{ .source = subject, .state = state };
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

pub fn compilerParseIntBase(text: []const u8, base: i64) i64 {
    if (base < 2 or base > 36) return 0;
    return std.fmt.parseInt(i64, text, @intCast(base)) catch 0;
}

pub fn compilerCodepointToString(codepoint: i64) []const u8 {
    if (codepoint < 0) return "";
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(codepoint), &buf) catch return "";
    const out = allocator.alloc(u8, len) catch @panic("codepoint allocation failed");
    @memcpy(out, buf[0..len]);
    return out;
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

fn matchRegex(pattern: []const u8, subject: []const u8, anchored: bool) ?MatchResult {
    var error_number: c_int = 0;
    var error_offset: usize = 0;
    const code = c.pcre2_compile_8(
        pattern.ptr,
        pattern.len,
        0,
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
        var result = matchRegex(regex.pattern, subject[offset..], false) orelse {
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
    try std.testing.expect(compilerRegexScan(scanner, compilerRegexCompile("[a-z]+")));
    try std.testing.expectEqualStrings("abc", compilerRegexMatched(scanner));
    try std.testing.expect(compilerRegexScan(scanner, compilerRegexCompile("(\\d+)")));
    try std.testing.expectEqualStrings("123", compilerRegexCapture(scanner, 1));
    try std.testing.expect(compilerRegexEos(scanner));
}
