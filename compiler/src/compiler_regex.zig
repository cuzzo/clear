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

// Ruby's `JSON.generate` string escaping, byte for byte: quotes, backslash and
// the C0 controls are escaped, everything else -- UTF-8 included -- passes
// through literally. A fingerprint built any other way would not match one the
// Ruby compiler wrote.
pub fn compilerJsonQuote(value: []const u8) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.append(allocator, '"') catch @panic("json quote allocation failed");
    for (value) |byte| {
        switch (byte) {
            '"' => out.appendSlice(allocator, "\\\"") catch @panic("json quote allocation failed"),
            '\\' => out.appendSlice(allocator, "\\\\") catch @panic("json quote allocation failed"),
            0x08 => out.appendSlice(allocator, "\\b") catch @panic("json quote allocation failed"),
            0x0c => out.appendSlice(allocator, "\\f") catch @panic("json quote allocation failed"),
            '\n' => out.appendSlice(allocator, "\\n") catch @panic("json quote allocation failed"),
            '\r' => out.appendSlice(allocator, "\\r") catch @panic("json quote allocation failed"),
            '\t' => out.appendSlice(allocator, "\\t") catch @panic("json quote allocation failed"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                var buf: [6]u8 = undefined;
                const hex = "0123456789abcdef";
                buf[0] = '\\';
                buf[1] = 'u';
                buf[2] = '0';
                buf[3] = '0';
                buf[4] = hex[byte >> 4];
                buf[5] = hex[byte & 0x0f];
                out.appendSlice(allocator, &buf) catch @panic("json quote allocation failed");
            },
            else => out.append(allocator, byte) catch @panic("json quote allocation failed"),
        }
    }
    out.append(allocator, '"') catch @panic("json quote allocation failed");
    return out.items;
}

// Ruby's `Digest::SHA256.hexdigest`, byte for byte: lowercase hex of the
// digest. Fingerprints key the incremental build, so a self-hosted compiler
// that hashed differently would silently stop reusing Ruby-built artifacts.
pub fn compilerSha256Hex(value: []const u8) []const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    const out = allocator.alloc(u8, digest.len * 2) catch @panic("sha256 allocation failed");
    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        out[index * 2] = hex[byte >> 4];
        out[index * 2 + 1] = hex[byte & 0x0f];
    }
    return out;
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

// Ruby's `String#dump`, byte for byte. The emitter renders every Zig string
// literal through it, so the self-hosted compiler's output only matches the
// Ruby compiler's if the escaping matches exactly -- including Ruby's
// four-digit `\uXXXX` below U+10000 and braced `\u{...}` above it, its
// uppercase hex, and its `\#` only before `{`, `$` or `@`.
pub fn compilerStringDump(value: []const u8) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.append(allocator, '"') catch @panic("string dump allocation failed");
    var index: usize = 0;
    while (index < value.len) {
        const byte = value[index];
        switch (byte) {
            '"' => {
                out.appendSlice(allocator, "\\\"") catch @panic("string dump allocation failed");
                index += 1;
                continue;
            },
            '\\' => {
                out.appendSlice(allocator, "\\\\") catch @panic("string dump allocation failed");
                index += 1;
                continue;
            },
            '\n' => {
                out.appendSlice(allocator, "\\n") catch @panic("string dump allocation failed");
                index += 1;
                continue;
            },
            '\t' => {
                out.appendSlice(allocator, "\\t") catch @panic("string dump allocation failed");
                index += 1;
                continue;
            },
            '\r' => {
                out.appendSlice(allocator, "\\r") catch @panic("string dump allocation failed");
                index += 1;
                continue;
            },
            0x0C => {
                out.appendSlice(allocator, "\\f") catch @panic("string dump allocation failed");
                index += 1;
                continue;
            },
            0x0B => {
                out.appendSlice(allocator, "\\v") catch @panic("string dump allocation failed");
                index += 1;
                continue;
            },
            0x08 => {
                out.appendSlice(allocator, "\\b") catch @panic("string dump allocation failed");
                index += 1;
                continue;
            },
            0x07 => {
                out.appendSlice(allocator, "\\a") catch @panic("string dump allocation failed");
                index += 1;
                continue;
            },
            0x1B => {
                out.appendSlice(allocator, "\\e") catch @panic("string dump allocation failed");
                index += 1;
                continue;
            },
            '#' => {
                // Ruby escapes `#` only where it would start an interpolation.
                const next: u8 = if (index + 1 < value.len) value[index + 1] else 0;
                if (next == '{' or next == '$' or next == '@') {
                    out.appendSlice(allocator, "\\#") catch @panic("string dump allocation failed");
                } else {
                    out.append(allocator, '#') catch @panic("string dump allocation failed");
                }
                index += 1;
                continue;
            },
            else => {},
        }
        if (byte >= 0x20 and byte < 0x7F) {
            out.append(allocator, byte) catch @panic("string dump allocation failed");
            index += 1;
            continue;
        }
        if (byte < 0x80) {
            out.print(allocator, "\\x{X:0>2}", .{byte}) catch @panic("string dump allocation failed");
            index += 1;
            continue;
        }
        const length = std.unicode.utf8ByteSequenceLength(byte) catch {
            // Invalid UTF-8 stays a raw byte escape, as Ruby does for a
            // binary string.
            out.print(allocator, "\\x{X:0>2}", .{byte}) catch @panic("string dump allocation failed");
            index += 1;
            continue;
        };
        if (index + length > value.len) {
            out.print(allocator, "\\x{X:0>2}", .{byte}) catch @panic("string dump allocation failed");
            index += 1;
            continue;
        }
        const codepoint = std.unicode.utf8Decode(value[index .. index + length]) catch {
            out.print(allocator, "\\x{X:0>2}", .{byte}) catch @panic("string dump allocation failed");
            index += 1;
            continue;
        };
        if (codepoint > 0xFFFF) {
            out.print(allocator, "\\u{{{X}}}", .{codepoint}) catch @panic("string dump allocation failed");
        } else {
            out.print(allocator, "\\u{X:0>4}", .{codepoint}) catch @panic("string dump allocation failed");
        }
        index += length;
    }
    out.append(allocator, '"') catch @panic("string dump allocation failed");
    return out.toOwnedSlice(allocator) catch @panic("string dump allocation failed");
}

// `zig_byte_string_literal`: a Zig literal for a BYTE string, where every
// non-ASCII byte is escaped individually rather than decoded. Note the
// lowercase hex -- Ruby writes `%02x` here and `String#dump` writes uppercase,
// and the two must not be unified.
pub fn compilerByteStringLiteral(value: []const u8) []const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    out.append(allocator, '"') catch @panic("byte literal allocation failed");
    for (value) |byte| {
        switch (byte) {
            0x5C => out.appendSlice(allocator, "\\\\") catch @panic("byte literal allocation failed"),
            0x22 => out.appendSlice(allocator, "\\\"") catch @panic("byte literal allocation failed"),
            0x0A => out.appendSlice(allocator, "\\n") catch @panic("byte literal allocation failed"),
            0x0D => out.appendSlice(allocator, "\\r") catch @panic("byte literal allocation failed"),
            0x09 => out.appendSlice(allocator, "\\t") catch @panic("byte literal allocation failed"),
            0x00 => out.appendSlice(allocator, "\\x00") catch @panic("byte literal allocation failed"),
            0x01...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F, 0x80...0xFF => out.print(allocator, "\\x{x:0>2}", .{byte}) catch @panic("byte literal allocation failed"),
            else => out.append(allocator, byte) catch @panic("byte literal allocation failed"),
        }
    }
    out.append(allocator, '"') catch @panic("byte literal allocation failed");
    return out.toOwnedSlice(allocator) catch @panic("byte literal allocation failed");
}

// Ruby's `String#chomp(separator)`, including its two special cases, which a
// plain "strip the suffix" reading gets wrong: an EMPTY separator strips every
// trailing newline rather than nothing, and a "\n" separator also takes the
// "\r" of a trailing "\r\n". Found by differential corpus, not by reading.
pub fn compilerStringChomp(value: []const u8, separator: []const u8) []const u8 {
    if (separator.len == 0) {
        var end = value.len;
        while (end > 0 and value[end - 1] == '\n') {
            end -= 1;
            if (end > 0 and value[end - 1] == '\r') end -= 1;
        }
        return value[0..end];
    }
    if (separator.len > value.len) return value;
    if (!std.mem.endsWith(u8, value, separator)) return value;
    var end = value.len - separator.len;
    if (std.mem.eql(u8, separator, "\n") and end > 0 and value[end - 1] == '\r') end -= 1;
    return value[0..end];
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

// Ruby `str.index(/re/, start)`: the byte offset of the first match at or
// after `start`, or -1 when there is none. The offset goes to PCRE2 rather
// than slicing the subject, so `\b` and lookbehind still see what precedes it.
pub fn compilerRegexIndexFrom(subject: []const u8, regex: CompilerRegex, start: i64) i64 {
    if (start < 0) return -1;
    const from: usize = @intCast(start);
    if (from > subject.len) return -1;
    var result = matchRegexFrom(regex, subject, from, false) orelse return -1;
    defer result.deinit();
    const whole = result.ranges[0];
    if (!whole.matched) return -1;
    return @intCast(whole.start);
}

fn matchRegex(regex: CompilerRegex, subject: []const u8, anchored: bool) ?MatchResult {
    return matchRegexFrom(regex, subject, 0, anchored);
}

fn matchRegexFrom(regex: CompilerRegex, subject: []const u8, offset: usize, anchored: bool) ?MatchResult {
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
    const rc = c.pcre2_match_8(code, subject.ptr, subject.len, offset, options, match_data, null);
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

test "compiler string dump matches Ruby String#dump" {
    try std.testing.expectEqualStrings("\"\"", compilerStringDump(""));
    try std.testing.expectEqualStrings("\"plain\"", compilerStringDump("plain"));
    // Ruby: "a\"b\\c\nd\te\r\x00f\x01g\e"
    try std.testing.expectEqualStrings(
        "\"a\\\"b\\\\c\\nd\\te\\r\\x00f\\x01g\\e\"",
        compilerStringDump("a\"b\\c\nd\te\r\x00f\x01g\x1B"),
    );
    try std.testing.expectEqualStrings("\"\\a\\b\\v\\f\"", compilerStringDump("\x07\x08\x0B\x0C"));
    // DEL is a hex escape, not a literal.
    try std.testing.expectEqualStrings("\"\\x7F\"", compilerStringDump("\x7F"));
}

test "compiler string dump escapes only interpolating hashes" {
    // Ruby: "\#{x} \#$y \#@z # ok"
    try std.testing.expectEqualStrings(
        "\"\\#{x} \\#$y \\#@z # ok\"",
        compilerStringDump("#{x} #$y #@z # ok"),
    );
    // A trailing `#` has nothing to interpolate.
    try std.testing.expectEqualStrings("\"#\"", compilerStringDump("#"));
}

test "compiler string dump uses Ruby's two unicode spellings" {
    // Ruby pads below U+10000 to four digits and braces above it.
    try std.testing.expectEqualStrings("\"caf\\u00E9\"", compilerStringDump("caf\u{E9}"));
    try std.testing.expectEqualStrings("\"\\x7F\\u0080\\u00A0\"", compilerStringDump("\x7F\u{80}\u{A0}"));
    try std.testing.expectEqualStrings("\"\\u{1F600}\"", compilerStringDump("\u{1F600}"));
}

test "compiler string dump leaves invalid utf8 as raw byte escapes" {
    try std.testing.expectEqualStrings("\"\\xFF\"", compilerStringDump("\xFF"));
    // A truncated sequence must not read past the end.
    try std.testing.expectEqualStrings("\"\\xC3\"", compilerStringDump("\xC3"));
}

test "compiler byte string literal escapes every non-ascii byte" {
    try std.testing.expectEqualStrings("\"\"", compilerByteStringLiteral(""));
    try std.testing.expectEqualStrings("\"plain\"", compilerByteStringLiteral("plain"));
    try std.testing.expectEqualStrings(
        "\"\\\\ \\\" \\n \\r \\t \\x00\"",
        compilerByteStringLiteral("\\ \" \n \r \t \x00"),
    );
    // Lowercase hex here, unlike String#dump's uppercase.
    try std.testing.expectEqualStrings("\"\\x01\\x1f\\x7f\\x80\\xff\"", compilerByteStringLiteral("\x01\x1F\x7F\x80\xFF"));
    // A UTF-8 sequence stays byte-escaped rather than decoded.
    try std.testing.expectEqualStrings("\"caf\\xc3\\xa9\"", compilerByteStringLiteral("caf\xC3\xA9"));
}

test "compiler string chomp matches Ruby String#chomp(separator)" {
    try std.testing.expectEqualStrings("a", compilerStringChomp("a;", ";"));
    try std.testing.expectEqualStrings("a", compilerStringChomp("a", ";"));
    // Ruby removes exactly one trailing occurrence, not all of them.
    try std.testing.expectEqualStrings("a;", compilerStringChomp("a;;", ";"));
    try std.testing.expectEqualStrings("", compilerStringChomp("", ";"));
    try std.testing.expectEqualStrings("", compilerStringChomp(";", ";"));
    // An empty separator strips every trailing newline, not nothing.
    try std.testing.expectEqualStrings("abc", compilerStringChomp("abc", ""));
    try std.testing.expectEqualStrings("x", compilerStringChomp("x\n\n", ""));
    try std.testing.expectEqualStrings("x", compilerStringChomp("x\r\n", ""));
    // A "\n" separator also takes the "\r" of a trailing "\r\n".
    try std.testing.expectEqualStrings("x", compilerStringChomp("x\r\n", "\n"));
    // A separator longer than the value cannot match.
    try std.testing.expectEqualStrings("a", compilerStringChomp("a", ";;;"));
    try std.testing.expectEqualStrings("foo", compilerStringChomp("foobar", "bar"));
}

test "compiler sha256 hex matches the published vectors" {
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        compilerSha256Hex(""),
    );
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        compilerSha256Hex("abc"),
    );
    try std.testing.expectEqualStrings(
        "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae",
        compilerSha256Hex("foo"),
    );
}

test "compiler json quote matches Ruby JSON.generate string escaping" {
    try std.testing.expectEqualStrings("\"\"", compilerJsonQuote(""));
    try std.testing.expectEqualStrings("\"plain\"", compilerJsonQuote("plain"));
    try std.testing.expectEqualStrings("\"a\\\"b\"", compilerJsonQuote("a\"b"));
    try std.testing.expectEqualStrings("\"a\\\\b\"", compilerJsonQuote("a\\b"));
    try std.testing.expectEqualStrings("\"a\\nb\"", compilerJsonQuote("a\nb"));
    try std.testing.expectEqualStrings("\"a\\u0001b\"", compilerJsonQuote("a\x01b"));
    try std.testing.expectEqualStrings("\"caf\u{00e9}\"", compilerJsonQuote("caf\u{00e9}"));
}

test "compiler regex index from honours the start offset and word boundaries" {
    const re = compilerRegexCompile("\\bSTREAM\\b");
    try std.testing.expectEqual(@as(i64, 4), compilerRegexIndexFrom("BG  STREAM {", re, 0));
    // Ruby scans forward from `start`; the earlier match is skipped.
    try std.testing.expectEqual(@as(i64, 17), compilerRegexIndexFrom("BG  STREAM {} BG STREAM {", re, 11));
    // A start inside a word must not create a boundary that is not there.
    try std.testing.expectEqual(@as(i64, -1), compilerRegexIndexFrom("BG XSTREAMX {", re, 0));
    try std.testing.expectEqual(@as(i64, -1), compilerRegexIndexFrom("BG STREAM {", re, 99));
    try std.testing.expectEqual(@as(i64, -1), compilerRegexIndexFrom("BG STREAM {", re, -1));
}
