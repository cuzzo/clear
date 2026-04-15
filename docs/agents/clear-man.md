# clear(1) - CLEAR Language Compiler

## SYNOPSIS

```
clear build <file.cht> [-o output] [--release|--safe]
clear run <file.cht> [-- args...]
clear test <file.cht>
clear help
```

## DESCRIPTION

`clear` is the command-line interface for the CLEAR programming language.
It transpiles CLEAR source (`.cht` files) to Zig, compiles to a native
binary, and optionally executes or tests the result.

## COMMANDS

### build

Transpile and compile a CLEAR program to a native binary.

```
clear build server.cht              # produces ./server
clear build server.cht -o bin/srv   # custom output path
clear build server.cht --safe       # with bounds/overflow checks
```

The binary is placed in the same directory as the source file by default.
Use `-o` to specify a different path.

**FFI auto-detection**: Any `.zig` files in the same directory as the
source are automatically linked as FFI modules. For example, if
`native_math.zig` exists alongside `main.cht`, it becomes available via
`EXTERN FN ... FROM "native_math"`.

### run

Build and execute a CLEAR program in one step. The binary is kept after
execution.

```
clear run hello.cht
clear run server.cht -- --port 8080
```

Arguments after `--` are passed to the program.

On first run, hints are printed to stderr:
- If `CLEAR_THREADS` is not set, a hint about the fiber runtime
- If jemalloc is not installed, a hint about allocator performance

### test

Build and run a CLEAR file as a test. Uses the module test harness which
wraps `main()` in a Zig test block with leak detection (GPA allocator).

```
clear test my_module.cht
```

ASSERT statements in the code become test assertions. Memory leaks are
detected and reported.

## BUILD FLAGS

| Flag | Description |
|------|-------------|
| `-o PATH` | Output binary path |
| `--release` | Optimize for speed (default, `-O ReleaseFast`) |
| `--safe` | Include safety checks (`-O ReleaseSafe`) |

## ENVIRONMENT

| Variable | Description |
|----------|-------------|
| `CLEAR_THREADS` | Number of scheduler threads. `0` = auto-detect (all cores), `1` = single thread (default). |
| `LD_PRELOAD` | Set to jemalloc/tcmalloc path for better allocator performance. |

## EXAMPLES

```bash
# Build and run a simple program
clear run examples/hello.cht

# Build an optimized server binary
clear build benchmarks/24_json_api/server.cht -o server

# Run with multi-threaded scheduler and jemalloc
CLEAR_THREADS=0 LD_PRELOAD=/lib/x86_64-linux-gnu/libjemalloc.so.2 ./server

# Test a module with leak detection
clear test transpile-tests/58_bg.cht

# Build with safety checks for debugging
clear build my_app.cht --safe
```

## FILES

| Path | Description |
|------|-------------|
| `src/transpiler.rb` | CLEAR-to-Zig transpiler |
| `zig/runtime-header.zig` | Runtime library |
| `zig/switch.S` | Fiber context switch (x86-64) |
| `zig/onRoot.S` | g0 trampoline (x86-64) |

## SEE ALSO

- `docs/ffi.md` - Foreign Function Interface guide
- `docs/concurrency.md` - Fiber and pipeline concurrency
- `docs/collections.md` - Collection types (@list, @pool, @set)
- `benchmarks/README.md` - Benchmark suite
