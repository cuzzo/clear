const std = @import("std");

// CLEAR_BUILD_ENTRY
//
// Self-host compiler build entry. The current CLEAR compiler pipeline still
// owns parsing, MIR lowering, runtime wiring, and cache layout, so this build
// file delegates to `../../clear` with project-specific native link settings.
// PCRE2 is used for compiler regex support because it is a portable C library
// and can be linked through Zig's libc/system-library path.
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const source = b.option([]const u8, "clear-source", "CLEAR source file") orelse "main.clear";
    const output = b.option([]const u8, "clear-output", "Output binary path") orelse "clear-self-host";
    const use_c_allocator = b.option(bool, "clear-use-c-allocator", "Use CLEAR's C allocator path") orelse false;
    const use_debug_allocator = b.option(bool, "clear-use-debug-allocator", "Use CLEAR's debug allocator path") orelse false;
    const ownership_mode = b.option([]const u8, "clear-ownership-mode", "CLEAR ownership mode: easy, default, strict") orelse "default";

    const build_root = b.build_root.path orelse ".";
    const clear_bin = b.fmt("{s}/../../clear", .{build_root});
    const native_dirs_env = b.fmt("CLEAR_EXTRA_NATIVE_DIRS={s}", .{build_root});
    const opt_arg = switch (optimize) {
        .Debug => "--debug",
        .ReleaseSafe => "--safe",
        .ReleaseFast, .ReleaseSmall => "--release",
    };

    const build_step = b.step("clear-build", "Build a CLEAR compiler source with native regex support");
    const build_cmd = b.addSystemCommand(&.{
        "env",
        "CLEAR_DISABLE_BUILD_ZIG=1",
        "CLEAR_EXTRA_LINK_LIBS=pcre2-8",
        native_dirs_env,
        clear_bin,
        "build",
        opt_arg,
        source,
        "-o",
        output,
    });
    if (use_c_allocator) build_cmd.addArg("--use-c-allocator");
    if (use_debug_allocator) build_cmd.addArg("--debug-allocator");
    if (std.mem.eql(u8, ownership_mode, "easy")) build_cmd.addArg("--gradual");
    if (std.mem.eql(u8, ownership_mode, "strict")) build_cmd.addArg("--strict");
    build_step.dependOn(&build_cmd.step);

    const run_step = b.step("clear-run", "Run a CLEAR compiler source with native regex support");
    const run_cmd = b.addSystemCommand(&.{
        "env",
        "CLEAR_DISABLE_BUILD_ZIG=1",
        "CLEAR_EXTRA_LINK_LIBS=pcre2-8",
        native_dirs_env,
        clear_bin,
        "run",
        opt_arg,
        source,
    });
    if (use_c_allocator) run_cmd.addArg("--use-c-allocator");
    if (std.mem.eql(u8, ownership_mode, "easy")) run_cmd.addArg("--gradual");
    if (std.mem.eql(u8, ownership_mode, "strict")) run_cmd.addArg("--strict");
    if (b.args) |args| {
        run_cmd.addArg("--");
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);
}
