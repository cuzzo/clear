// resource-test.zig
// Unit tests for the linear File resource primitives (Phase 1):
//   CheatLib.fileOpen  — opens a file, returns std.fs.File caller must close
//   CheatLib.fileReadAll — reads entire file into a heap buffer
//
// These tests exercise the Zig runtime directly, independent of the CLEAR compiler.
const std = @import("std");
const CheatLib = @import("runtime-header.zig").CheatLib;
const Runtime = @import("runtime.zig").Runtime;
const EbrContext = @import("ebr.zig").EbrContext;

// comptime linker shims (matches pattern used in other test files)
comptime {
    _ = @import("scheduler.zig");
}

// ---------------------------------------------------------------------------
// fileOpen — basic open / close
// ---------------------------------------------------------------------------

test "fileOpen: opens a readable file and caller closes it" {
    var f = try CheatLib.fileOpen("testdata/fruits.csv");
    defer f.close();
    // If we reach here without error, the file was opened successfully.
    // Read one byte to confirm the fd is valid.
    var buf: [1]u8 = undefined;
    const n = try f.read(&buf);
    try std.testing.expect(n == 1);
}

test "fileOpen: returns error for non-existent path" {
    const result = CheatLib.fileOpen("testdata/does_not_exist_xyzzy.csv");
    try std.testing.expectError(error.FileNotFound, result);
}

// ---------------------------------------------------------------------------
// fileReadAll — reads entire file into allocator-owned slice
// ---------------------------------------------------------------------------

test "fileReadAll: returns non-empty slice for fruits.csv" {
    const allocator = std.testing.allocator;
    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var rt = try Runtime.init(allocator, 512 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    var f = try CheatLib.fileOpen("testdata/fruits.csv");
    defer f.close();

    const contents = try CheatLib.fileReadAll(rt.heapAlloc(), f);
    defer allocator.free(contents);

    try std.testing.expect(contents.len > 0);
}

test "fileReadAll: contents match direct readFile output" {
    const allocator = std.testing.allocator;
    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);
    var rt = try Runtime.init(allocator, 512 * 1024, &global_ctx);
    defer rt.deinit();
    rt.wireAllocator();

    // Read via resource API
    var f = try CheatLib.fileOpen("testdata/fruits.csv");
    defer f.close();
    const via_resource = try CheatLib.fileReadAll(rt.heapAlloc(), f);
    defer allocator.free(via_resource);

    // Read via high-level readFile (existing API)
    const via_readfile = try CheatLib.readFile(rt.heapAlloc(), "testdata/fruits.csv");
    defer allocator.free(via_readfile);

    try std.testing.expectEqualSlices(u8, via_readfile, via_resource);
}

// ---------------------------------------------------------------------------
// RAII pattern: defer f.close() (mirrors what the CLEAR compiler emits)
// ---------------------------------------------------------------------------

test "RAII pattern: defer f.close() matches compiler-emitted code" {
    // This test mirrors exactly what `f = File::open("path")` produces in Zig:
    //   const f = try CheatLib.fileOpen("testdata/fruits.csv");
    //   _ = &f;
    //   defer f.close();
    const f = try CheatLib.fileOpen("testdata/fruits.csv");
    _ = &f;
    defer f.close();

    // Read a small chunk to exercise the fd
    var buf: [16]u8 = undefined;
    const n = try f.read(&buf);
    try std.testing.expect(n > 0);
}
