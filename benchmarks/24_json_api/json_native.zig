// json_native.zig — Minimal native helpers for CLEAR FFI.
// JSON parsing is handled directly by std.json via EXTERN FN in server.cht.

const std = @import("std");

/// The JSON record type. Exported so CLEAR can import it as a concrete type.
pub const JsonRecord = struct { id: i64, data: []const i64 };

/// Create a directory (no-op if it already exists).
pub fn ensureDir(path: []const u8) void {
    std.fs.cwd().makePath(path) catch {};
}
