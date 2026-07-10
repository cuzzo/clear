# CLEAR Build System Design

This document describes the work needed to move `clear build`, `clear run`,
and package/native linking from the current ad hoc `zig build-exe` wrapper to a
generated `build.zig` flow.

The motivating case is simple: a CLEAR package should be able to depend on a
native Zig wrapper and a C library, such as PCRE2 for regex, and `clear run`
should build and execute it without users hand-writing linker flags, copying
modules into cache directories, or setting allocator preload variables.

## Current State

Today `./clear` owns the full build flow in Ruby:

- transpiles the entry `.clear` file through `compiler/ruby/backends/transpiler.rb`;
- scans source text for `REQUIRE "pkg:name"` and passes `--pkg` flags;
- scans source text for `EXTERN ... FROM "module"` and copies matching sibling
  or `packages/<module>/src/lib.zig` files into a per-source cache directory;
- rewrites some imports from named modules to file imports, for example
  `@import("cheat_runtime")` to `@import("runtime/runtime-header.zig")`;
- runs `zig build-exe` or `zig test` directly from the cache directory;
- always links libc through `-lc`;
- in `clear run`, detects jemalloc/tcmalloc and uses `LD_PRELOAD` for the
  executed binary when available.

This works for small examples, but it does not scale to native packages:

- there is no generated Zig package graph;
- standalone builds do not consistently use named Zig modules;
- native modules cannot declare system libraries, include paths, C source
  files, frameworks, defines, or pkg-config dependencies;
- package native setup is implicit and source-scanned instead of represented as
  a build plan;
- `clear run` cannot express run-time environment needs except the current
  allocator preload heuristic;
- build cache signatures do not include native package metadata or system
  library decisions;
- a package-provided `build.zig` exists in integration tests, but the normal
  CLI path does not use that model.

## Implemented Self-Host Bridge

As of 2026-07-08, the self-host compiler has a narrow bridge before the full
generated build-plan work lands:

- `clear build` and `clear run` look for a parent `build.zig` containing the
  `CLEAR_BUILD_ENTRY` marker and delegate to its `clear-build` / `clear-run`
  steps.
- `compiler/src/build.zig` is that marker build file for the self-host
  compiler tree.
- The self-host build delegates back to `../../clear` with
  `CLEAR_DISABLE_BUILD_ZIG=1` to avoid recursion.
- The direct `clear` build path accepts `CLEAR_EXTRA_LINK_LIBS`, which lets the
  self-host build add `-lpcre2-8`.
- The direct `clear` build and test paths accept `CLEAR_EXTRA_NATIVE_DIRS`, so
  project build files can point native module discovery at project-owned Zig
  modules even when generated CLEAR files inline their `EXTERN` declarations.
- `gems/ruby-to-clear/config/compiler_regex_helpers.json` injects inline
  compiler-only regex/scanner `EXTERN` declarations for generated compiler
  files.
- `compiler/src/compiler_regex.clear` also declares the same FFI surface for
  hand-written CLEAR code that wants a local module file.
- `compiler/src/compiler_regex.zig` implements that surface with PCRE2.

This is intentionally not a stdlib regex package. The compiler currently owns
the regex bridge because the immediate goal is translating and running the
self-host lexer, not exposing a general regex API to user programs.

## Target

`clear build app.clear` should generate a build directory like:

```text
zig/.clear-cache/<build-key>/
  build.zig
  build.zig.zon
  generated/
    root.zig
    pkg_path.zig
    pkg_regex.zig
  .zig-cache/
  zig-out/
```

Then the CLI should invoke Zig's build runner:

```text
zig build -Doptimize=Debug clear:exe
```

`clear run app.clear -- args...` should use the same build graph and then run
the resulting artifact, either through a generated `run` step or by executing
the built binary after the Zig build step completes.

The generated `build.zig` is the single place that wires:

- transpiled CLEAR modules;
- first-party runtime modules;
- first-party stdlib packages;
- project packages;
- native Zig modules;
- C libraries and C source files;
- allocator choices;
- profiling, coverage, sanitizer, and stack options.

## Build Plan

Add an explicit build planning layer before any Zig code is generated.

Suggested Ruby model:

```text
ClearBuild::Plan
  entry_source
  mode                  # exe, run, test, module
  optimize
  target
  output_name
  cache_key
  clear_modules         # entry + local REQUIRE + package REQUIRE graph
  native_modules        # EXTERN FROM modules and package-declared native modules
  runtime_modules
  link_libs
  c_sources
  include_dirs
  defines
  build_options
  run_environment
```

The plan should be computed once and then used for:

- cache signatures;
- transpile commands;
- generated `build.zig`;
- `clear run` environment;
- diagnostics when a native module cannot be resolved.

The existing `ClearBuildSupport.collect_clear_dependencies` and package lookup
logic can seed this. The missing piece is a structured dependency graph instead
of regex scans local to `clear`.

## Native Package Metadata

Use declarative package metadata for normal packages. A package `build.zig`
escape hatch can come later, but a manifest is easier to cache, audit, and
compose.

Recommended package layout:

```text
packages/regex/
  clear.package.toml
  src/lib.clear
  native/regex.zig
  native/pcre2_shim.c
```

Example manifest:

```toml
[package]
name = "regex"
entry = "src/lib.clear"

[[native.module]]
name = "clear_regex"
root = "native/regex.zig"
link_libc = true
pkg_config = ["libpcre2-8"]
link_system_libs = ["pcre2-8"]
c_sources = ["native/pcre2_shim.c"]
include_dirs = ["native/include"]
defines = { PCRE2_CODE_UNIT_WIDTH = "8" }
```

The CLEAR wrapper can then hide native details:

```clear
EXTERN STRUCT RegexCode {} CLOSE "deinit" FROM "clear_regex";
EXTERN FN compile(pattern: String) RETURNS !RegexCode
  EFFECTS :alloc:heap FROM "clear_regex";
EXTERN FN matches(code: RegexCode, subject: String) RETURNS Bool
  FROM "clear_regex";
```

User code imports only the CLEAR package:

```clear
REQUIRE "pkg:regex";
```

The build planner sees the package manifest, wires `clear_regex`, links PCRE2,
and exposes the native module to transpiled CLEAR code as
`@import("clear_regex")`.

## Generated build.zig Shape

The generated file should use named modules everywhere. Standalone builds
should stop rewriting imports to local files.

Sketch:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const opts = b.addOptions();
    opts.addOption(bool, "coverage", false);
    opts.addOption(bool, "clear_profile", false);
    opts.addOption(bool, "use_c_allocator", true);
    const build_options = opts.createModule();

    const runtime = b.createModule(.{
        .root_source_file = b.path("/abs/repo/zig/runtime/runtime-header.zig"),
        .target = target,
        .optimize = optimize,
    });

    const regex_native = b.createModule(.{
        .root_source_file = b.path("/abs/project/packages/regex/native/regex.zig"),
        .target = target,
        .optimize = optimize,
    });

    const regex_pkg = b.createModule(.{
        .root_source_file = b.path("generated/pkg_regex.zig"),
        .target = target,
        .optimize = optimize,
    });
    regex_pkg.addImport("cheat_runtime", runtime);
    regex_pkg.addImport("clear_regex", regex_native);

    const root = b.createModule(.{
        .root_source_file = b.path("generated/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    root.addImport("cheat_runtime", runtime);
    root.addImport("regex", regex_pkg);
    root.addImport("clear_regex", regex_native);
    root.addImport("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = root,
    });
    exe.root_module.addAssemblyFile(b.path("/abs/repo/zig/runtime/switch.S"));
    exe.root_module.addAssemblyFile(b.path("/abs/repo/zig/runtime/onRoot.S"));
    exe.linkLibC();
    exe.linkSystemLibrary("pcre2-8");

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Run CLEAR program").dependOn(&run.step);
}
```

The exact API should follow the Zig version vendored or selected by the repo,
but the architecture should remain: one generated graph, named modules, and
native link metadata owned by the build plan.

## Transpilation in the Build Graph

There are two viable approaches.

Approach A: `clear` transpiles all CLEAR sources before writing `build.zig`.

- Simpler first implementation.
- Current cache code mostly survives.
- Zig build sees generated `.zig` files as normal inputs.
- Rebuild invalidation stays in `clear`, not Zig.

Approach B: generated `build.zig` uses `b.addSystemCommand` to transpile each
`.clear` source.

- Zig build graph owns more invalidation.
- This matches the existing integration fixtures.
- It needs careful command selection so stage0 uses Ruby but stage1 can use a
  self-hosted compiler binary.

Recommended sequence:

1. Implement Approach A to replace ad hoc linking without destabilizing
   transpilation.
2. Add enough metadata to make Approach B possible.
3. Switch packages to build-graph transpilation once the self-hosted compiler
   binary can act as the transpiler command.

## clear run

`clear run` should become:

1. build a `ClearBuild::Plan` with mode `run`;
2. generate or reuse the build directory;
3. invoke `zig build run -- <program args>` or invoke `zig build clear:exe`
   followed by the installed artifact;
4. apply declared run environment.

Run environment should be explicit:

```toml
[run]
env = { CLEAR_THREADS = "0" }

[allocator]
mode = "jemalloc" # gpa, c, jemalloc, mimalloc, debug
```

For allocators:

- `gpa`: no libc allocator override; useful for debug/leak checks.
- `c`: emit `USE_C_ALLOCATOR = true`; link libc.
- `jemalloc`: emit `USE_C_ALLOCATOR = true`, link or preload jemalloc.
- `mimalloc`: same shape as jemalloc.
- `debug`: emit `USE_DEBUG_ALLOCATOR = true`.

On Linux, `jemalloc` can be implemented first as a run-time preload because the
runtime already uses `std.heap.c_allocator` when `USE_C_ALLOCATOR` is true. A
later build-linked mode can add `linkSystemLibrary("jemalloc")` when the user
requests a fully linked allocator.

## CLI Surface

Keep the common path small:

```text
clear build app.clear
clear run app.clear -- args...
clear test app.clear
```

Add focused options:

```text
--allocator=gpa|c|jemalloc|mimalloc|debug
--native-manifest PATH
--no-native-auto
--emit-build-zig
--keep-build-dir
--target <zig target>
```

Avoid asking users to pass `-l`, `-I`, `-D`, or `pkg-config` flags directly in
the normal path. Those belong in package metadata.

## Self-Host Requirements

For the self-hosted compiler, this build system needs to support:

- `stdlib/path`: lexical path helpers already started locally;
- `stdlib/fs`: `File` and `Dir` replacement surface for compiler/module
  importer/build support code;
- compiler-local regex/scanner FFI through `compiler/src/compiler_regex.*`;
- `stdlib/json`: enough JSON parse/generate for build metadata, diagnostics,
  and tool output;
- `stdlib/process`: argument parsing, environment reads/writes, subprocess
  execution, and captured output;
- first-party native packages for runtime support where CLEAR code needs Zig
  or C backing implementations.

The compiler-local PCRE2 bridge is a bootstrap exception. Longer-term native
link wiring should still move into build metadata so compiler-specific and
user-package native dependencies use the same build planning machinery.

## Migration Plan

1. Add `ClearBuild::Plan` and make the existing `clear build` path print or
   test the plan without changing behavior.
2. Add package manifest parsing for `clear.package.toml`.
3. Move current source scans for `REQUIRE` and `EXTERN FROM` into the planner.
4. Generate `build.zig` and generated module files in the cache dir.
5. Build existing simple programs through `zig build` instead of
   `zig build-exe`.
6. Port current FFI integration fixtures to the generated build path.
7. Add native package metadata for a small pure Zig package.
8. Add native package metadata for a C-backed package, preferably
   `stdlib/regex` with PCRE2 or a small vendored C regex shim.
9. Switch `clear run` to the same generated build graph.
10. Add allocator modes and remove the implicit jemalloc/tcmalloc heuristic
    from the common path, keeping it only as a fallback.
11. Add cache signatures for package manifests, native module files, C sources,
    link libs, include dirs, target, optimize mode, allocator mode, and build
    options.
12. Make `clear test` use the same planner so test mode, coverage mode, and
    package/native wiring cannot diverge.

## Done Criteria

- `clear build` and `clear run` use the same build plan.
- A program with `REQUIRE "pkg:regex"` can build and run without user linker
  flags.
- A package can declare a native Zig module and a C system library in metadata.
- Standalone builds no longer rewrite named module imports to file imports.
- The existing FFI and module integration tests pass through the generated
  build path.
- Build cache invalidates on native package manifest, C source, Zig source, and
  CLEAR dependency changes.
- The self-host compiler can import first-party stdlib/native packages without
  special-case CLI wiring.
