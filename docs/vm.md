# CLEAR VM & Gradual Typing (Scheme Backend)

## Overview

CLEAR's primary target is high-performance Zig/Native code. However, for rapid prototyping, scripting, and environments where a full compilation step is undesirable, CLEAR supports a **VM Mode**. This mode lowers CLEAR source to S-expression Scheme and executes it on a specialized interpreter written in CLEAR itself (`examples/scheme/interpreter.cht`).

## Why This Matters

### The Debugger Problem

Debugging native CLEAR means `gdb` on generated Zig. You're debugging the compiler's output, not your program:
- Mangled names, optimized-away locals, arena internals in every stack frame
- Breakpoints on Zig lines, not CLEAR lines
- Values displayed as `tagged_union_128`, not CLEAR types

A VM backend gives you a debugger that operates at **CLEAR's semantic level**:
- Breakpoints on CLEAR lines
- Inspect values as CLEAR types (not Zig representations)
- Step through CLEAR control flow (not inlined arena bookkeeping)
- Watch ownership state, capability scopes, borrow lifetimes
- REPL at the breakpoint - evaluate expressions in the live environment

This is the primary value proposition. Ruby's `byebug` and Python's `pdb` have no native-compilation equivalent. The closest analog is Common Lisp's SLIME/SLY - a fully interactive, REPL-driven development environment for a language that can also compile to native. Rust, Go, and C++ have nothing like this.

### Rapid Iteration via REPL

The native backend compiles in ~2 seconds, which is fast for batch workflows. But for **interactive, exploratory development** - testing an expression, inspecting intermediate state, prototyping a data transformation - there's no native-backend equivalent to a REPL. A REPL changes the development model from "edit-compile-run-inspect" to "think-evaluate-see."

### Gradual Typing

VM mode allows type annotations to be omitted (defaulting to `Any`). This enables a development workflow:

1. Write CLEAR with capabilities but no type annotations - compiles to Scheme
2. Run on VM, iterate fast (REPL, semantic debugger)
3. Add type annotations incrementally - annotator catches mismatches
4. Switch to native backend - works, guaranteed

Step 4 **cannot fail for ownership reasons** because ownership is enforced by the annotator at compile time, regardless of backend. CLEAR's ownership/capability system (`GIVE`, `TAKES`, `@shared`, `@locked`, `WITH RESTRICT`) is checked in the semantic analysis pass, not the code generator. The VM backend simply uses GC for deallocation timing, but the language prevents observing the difference - use-after-scope, double-`GIVE`, and borrow violations are caught before either backend runs.

The "gradual" dimension is strictly **types**: `Any` -> `Int64`, `Any` -> `String`, etc. Capabilities are always required and checked.

### What About Arena vs. GC Semantics?

A reasonable concern: CLEAR uses arena-scoped memory natively, while Scheme uses GC. Does this create observable behavioral differences?

No. The annotator enforces the same lifetime rules in both modes. A value that would die at scope exit in the native backend is simply unreachable at that same point in the VM - the GC collects it lazily, but the language has already prevented any reference to it. Destructors and cleanup callbacks execute at the same logical points because CLEAR's `DEFER` semantics are scope-based, not finalizer-based.

The GC vs. arena gap is an implementation detail invisible to the programmer.

## Proposed Usage

```bash
# Run a CLEAR script directly on the VM
./clear run --vm myfile.cht

# Transpile to Scheme without running
./clear transpile --scheme myfile.cht > myfile.scm

# Interactive REPL
./clear repl

# REPL with a file's definitions loaded
./clear repl myfile.cht
```

## Current State: The Interpreter

`examples/scheme/interpreter.cht` is a Mal Level 4 implementation (~489 lines) written in CLEAR. It currently supports:

- Lexer/parser for S-expressions
- `def!`, `let*`, `fn*`, `do`, `if`
- Lambdas with closure capture (pool-based environments)
- Arithmetic, comparison, list ops, boolean logic
- 21 passing tests (arithmetic, recursion, closures, fibonacci)

### Compilation Blockers

The interpreter **does not currently compile**. It depends on CLEAR compiler features that don't exist yet:

| Feature | Why it's needed |
|---------|----------------|
| String escape sequences (`\"`, `\n`) | Tokenizer whitespace/quote handling |
| String indexing (`str[i]`) | Manual tokenizer character iteration |
| `MATCH` payload extraction (`Value.X AS payload`) | Core of the evaluator |
| `@indirect` on union fields | Break `Value -> Lambda -> Value` recursion |
| `RAISE` inside `WHILE` | Error propagation in parser loops |

See `examples/scheme/TODO.md` for the full list (P0 through P2).

### Gap: What the Interpreter Still Needs

The interpreter does **not** need to be a full Scheme. It's a **CLEAR VM with S-expression syntax** - it only needs to handle what the transpiler emits, which is a closed, known set.

Features NOT needed (the transpiler won't emit them):
- `call/cc` or continuations
- `quote` / `quasiquote` / macros
- `eval` at runtime
- Hygienic macro expansion
- Varargs / `& rest`
- Atoms (`atom`, `deref`, `swap!`)
- File I/O (`slurp`, `read-string`)

Features actually needed beyond current Mal 4:

| Feature | Why |
|---|---|
| TCO (trampoline in eval loop) | Any recursive CLEAR code will stack-overflow without it |
| `set!` | CLEAR `MUTABLE` bindings need reassignment |
| Error values + propagation | CLEAR `RAISE` / `s>` need a runtime error path |
| Growable env pool + cycle cleanup | 10,000-slot fixed pool won't survive real programs |
| Source-map metadata | Debugger needs CLEAR line -> S-expr mapping |
| Native function extensibility | FFI, concurrency, stdlib all register as native fns |

This is roughly **Mal 4.5** - not Mal 7+. The interpreter work is smaller than initially estimated.

## Effort Breakdown

### Phase 0: Compiler Prerequisites (~10-15 commits)

Implement the CLEAR language features that unblock `interpreter.cht` compilation. These are compiler tasks (lexer/parser/annotator/transpiler), not interpreter tasks.

- String escape sequences
- String indexing and slicing
- `MATCH` payload extraction
- `@indirect` on recursive union fields
- `RAISE` propagation through `WHILE`
- Optional type fallback (`OR` pattern)

### Phase 1: Interpreter Maturation - Mal 4 -> 4.5 (~8-12 commits)

The interpreter only needs to handle what the transpiler emits. No `quote`, no macros, no continuations, no file I/O, no atoms.

| Work | Size | Notes |
|------|------|-------|
| TCO: trampoline loop in `eval` | Medium | Convert tail-position calls to loop iterations |
| `set!` for mutable bindings | Small | Env mutation - walk scope chain, update in place |
| Error values + propagation | Medium | Tagged error type, unwind on `RAISE`, catch on `s>` |
| Growable env pool + cycle cleanup | Medium | Replace fixed 10,000-slot array, handle Env->Lambda->Env |
| Source-map metadata in emitted S-exprs | Small | Line/col annotations for debugger |
| Native function registration API | Small | Extensible dispatch table (replaces string matching) |

**This phase produces a working interpreter that can run transpiler output.** Independently useful as a CLEAR showcase.

### Phase 2: REPL & Debugger (~10-15 commits)

This is the **primary deliverable** and should be prioritized above the transpiler.

- stdin REPL loop with incremental environment
- Source-map support: CLEAR line -> S-expression mapping
- Breakpoint API: `BREAKPOINT` keyword or `--break fn_name`
- Value inspector at breakpoints (print CLEAR types, not Scheme internals)
- Expression evaluation at breakpoints (REPL inside the debugger)
- Step-in, step-over, step-out through CLEAR control flow
- Watch expressions for ownership state and capability scopes

### Phase 3: Scheme Transpiler (~25-35 commits)

A new `src/scheme_transpiler.rb` that lowers CLEAR AST to S-expressions.

- **Commit 1-2**: CLI flags (`--vm`, `--scheme`), scaffold transpiler with visitor base extracted from `transpiler.rb`
- **Commit 3-4**: `loose_mode` in annotator - unannotated params default to `Type::ANY`, type checking remains active for annotated code
- **Commit 5-8**: Core emission - functions, bindings, control flow, loops, closures
- **Commit 9-10**: Data structure mapping - `STRUCT` -> vectors with field indices, `UNION` -> tagged pairs
- **Commit 11-13**: Typed vs. untyped dispatch - annotator metadata drives whether to emit specialized primitives or generic `clear-add` with runtime type checks
- **Commit 14-16**: `EXTERN` FFI marshalling - typed path (direct unbox), untyped path (runtime type check + unbox)
- **Commit 17-19**: Concurrency lowering - `BG` -> spawn, `DO` -> wait-group (requires threading model decision in interpreter)
- **Commit 20-22**: Standard library bridge (`runtime/scheme_bridge.scm`)
- **Commit 23-25**: Native handles - C pointers to Zig `runtime.zig` objects for mutexes, arcs, etc.

### Phase 4: Integration & Testing (~10-15 commits)

- Wire up `./clear run --vm` execution loop
- Stack scaling for VM mode (interpreter C stack overhead)
- Compliance test generator: run 130+ existing `.cht` transpile tests in both strict and loose modes
- Verify `ASSERT` statements pass identically on VM and native backends
- Performance baseline: establish "fast enough" threshold for interactive use

### Total: ~55-85 commits

| Phase | Commits | Focus |
|-------|---------|-------|
| 0: Compiler prereqs | 10-15 | Unblock interpreter compilation |
| 1: Mal 4 -> 4.5 | 8-12 | Minimal viable interpreter |
| 2: REPL & debugger | 10-15 | **Primary deliverable** |
| 3: Scheme transpiler | 20-28 | CLEAR-to-Scheme lowering |
| 4: Integration & testing | 7-12 | End-to-end validation |

Split roughly **25/75** between interpreter maturation (Phases 0-1) and transpiler/tooling (Phases 2-4).

## Features Only Possible With a VM

These capabilities **cannot be replicated** by the native backend, regardless of tooling investment:

| Feature | Why it requires a VM |
|---------|---------------------|
| Semantic debugger (byebug-equivalent) | Native debugging operates on Zig IR, not CLEAR semantics. Source maps can't recover optimized-away locals, inlined functions, or arena bookkeeping. |
| REPL with live environment | AOT compilation can't incrementally add definitions to a running program. |
| Hot code reload | Replacing a function in a running program requires an interpreter or JIT. |
| Expression evaluation at breakpoints | Requires an evaluator running alongside the program - which is the VM. |
| Type-optional prototyping | The native backend requires concrete types for code generation. `Any` as a runtime type needs dynamic dispatch, which is what the VM provides. |
| Embedded scripting | Hosting CLEAR as an extension language inside another application requires an embeddable interpreter, not a compiler toolchain. |

## Concurrency: Open Question

The plan maps `BG` -> `(clear-spawn ...)` and `DO` -> `(clear-wait-group ...)`, but the execution model needs a decision:

| Option | Tradeoff |
|--------|----------|
| OS threads | Simple. Breaks fiber stack semantics. Heavyweight for many-spawn patterns. |
| Green threads / continuations | Correct. Requires interpreter support for continuation capture. |
| Coroutines in C | Complex. Interpreter-dependent. |

Recommendation: start with OS threads for correctness, optimize to green threads later if spawn-heavy workloads demand it. The annotator enforces `@shared`/`@locked` regardless, so the threading model is an implementation detail.

## Viability Assessment

**Viable and worth the effort**, provided the project leads with the REPL and debugger, not iteration speed.

The native backend's 2-second compile time is adequate for batch workflows. The VM backend's value is in capabilities that native compilation fundamentally cannot provide: semantic debugging, live evaluation, hot reload, and type-optional exploration. These are qualitative improvements to the development experience, not incremental speedups.

The gradual typing story is sound because CLEAR's ownership system is enforced at the language level (annotator), not the backend level (code generator). Code that runs on the VM will compile natively once type annotations are added - ownership was always checked.
