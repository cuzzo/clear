# CLEAR VM & Gradual Typing (Historical Scheme Backend)

Historical note: this document describes the older Mal/S-expression VM design.
That interpreter has been restored under `examples/mal`. The active MiniVM work
lives under `examples/minivm` and uses bytecode/register-machine paths.

## Overview

CLEAR's primary target is high-performance Zig/Native code. However, for rapid prototyping, scripting, and environments where a full compilation step is undesirable, CLEAR explored a **VM Mode**. This historical mode lowered CLEAR source to S-expression Scheme and executed it on a specialized interpreter written in CLEAR itself (`examples/mal/interpreter.clear`).

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
./clear run --vm myfile.clear

# Transpile to Scheme without running
./clear transpile --scheme myfile.clear > myfile.scm

# Interactive REPL
./clear repl

# REPL with a file's definitions loaded
./clear repl myfile.clear
```

## Current State: The Interpreter

`examples/mal/interpreter.clear` is a Mal Level 4 implementation written in CLEAR. It supports:

- Lexer/parser for S-expressions
- `def!`, `let*`, `fn*`, `do`, `if`
- Lambdas with closure capture (pool-based environments)
- Arithmetic, comparison, list ops, boolean logic
- 21 passing tests (arithmetic, recursion, closures, fibonacci)

### Compilation Status

The `TODO.md` lists 8 compilation blockers - **all are already implemented**:

| Feature | Status | Evidence |
|---------|--------|---------|
| String escape sequences (`\"`, `\n`) | Done | `lexer.rb:172-210` |
| String indexing (`charAt`) | Done | `std_lib.rb:67-72`, `transpile-tests/55_string_ops.clear` |
| `substr()` | Done | `std_lib.rb:29-36`, `transpile-tests/55_string_ops.clear` |
| `toNumber()` with `OR` fallback | Done | `std_lib.rb:88-93`, `transpile-tests/55_string_ops.clear` |
| `MATCH ... AS` payload extraction | Done | `parser.rb:1298`, `transpiler.rb:1266`, `match_spec.rb:601-648` |
| `@indirect` on union fields | Done | `parser.rb:1786`, `transpile-tests/97_stack_heap_interop.clear` |
| `@shared` construction | Done | `transpile-tests/35_shared.clear`, `capabilities_spec.rb` |
| `RAISE` inside `WHILE` | Done | Error handling fully implemented |

The additional features the interpreter uses (`EFFECTS REENTRANT`, `@pool`, `Id<T>`, `HashMap<Value>` with `OR` fallback, `@list`, UNION with struct-like variants) are also all implemented and tested. **The interpreter should compile today.** The TODO.md is stale.

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

## Architecture: Instruction IR with Swappable Backends

The transpiler should **not** emit S-expressions directly. Instead, it emits an intermediate **instruction list**, and separate renderers produce either S-expressions or bytecode from it. This means the transpiler never changes when we switch execution strategy - only the renderer and interpreter loop swap.

### Why Not Emit S-Expressions Directly?

If the transpiler emits S-expression strings, switching to bytecode later means either:
- Rewriting the transpiler to emit bytecode instead (throwing away working code), or
- Parsing the S-expressions back into a structure to compile to bytecode (wasting work the transpiler already did)

Both are bad. The transpiler already knows every variable's scope index, every function's arity, every tail position. That information should be preserved in a structured form, not serialized into text and re-parsed.

### The Instruction IR

The transpiler emits a flat list of typed instructions:

```ruby
Instruction = Struct.new(:op, :args, :source_loc)

# CLEAR source:  IF x > 1 THEN x + 2 ELSE 0 END
# Instruction output:
[
  Inst(:LOAD_SLOT,      [3],    loc(12, 4)),   # x
  Inst(:LOAD_CONST,     [1],    loc(12, 8)),   # 1
  Inst(:GT,             [],     loc(12, 6)),
  Inst(:JUMP_IF_FALSE,  [:L1],  loc(12, 1)),
  Inst(:LOAD_SLOT,      [3],    loc(12, 14)),  # x
  Inst(:LOAD_CONST,     [2],    loc(12, 18)),  # 2
  Inst(:ADD,            [],     loc(12, 16)),
  Inst(:JUMP,           [:L2],  loc(12, 1)),
  Inst(:LABEL,          [:L1],  nil),
  Inst(:LOAD_CONST,     [0],    loc(12, 22)),  # 0
  Inst(:LABEL,          [:L2],  nil),
]
```

Source locations are preserved at every instruction for the debugger.

### Two Renderers, Same Input

```
                                 +---> SexpRenderer ----> "(if (> x 1) (+ x 2) 0)"
                                 |                         tree-walker interprets this
CLEAR AST --> SchemeTranspiler --+
              (emits Inst[])     |
                                 +---> BytecodeRenderer -> [0x05, 0x03, 0x06, 0x01, ...]
                                                           dispatch loop executes this
```

**SexpRenderer** reconstructs nested S-expressions from the flat instruction stream. `JUMP_IF_FALSE` + `LABEL` pairs become `(if ...)`. `CALL` becomes `(fn arg1 arg2)`. This is the day-1 execution path and the permanent debug/inspect output (`--scheme` flag).

**BytecodeRenderer** resolves labels to byte offsets and packs instructions into a `u8[]` array. This replaces the S-expression path when performance matters. ~200 lines of code, added later.

### The Interpreter Has the Same Split

The interpreter's runtime - `Value` union, environment pool, native function table, debugger hooks - is shared between both execution modes. Only the eval loop changes:

| Component | Shared? | Changes for bytecode? |
|---|---|---|
| `Value` union (tagged, inline) | Yes | No |
| Environment pool (arena-allocated) | Yes | No |
| Native function table | Yes | No |
| Debugger / breakpoint hooks | Yes | No |
| Source-map lookup | Yes | No |
| S-expression parser + tree-walk eval | Day 1 | Replaced by dispatch loop |
| Bytecode dispatch loop | Day 2 | New code (~150 lines) |

### File Layout

| File | Role | Changes for bytecode? |
|---|---|---|
| `src/scheme_transpiler.rb` | CLEAR AST -> `Instruction[]` | No |
| `src/sexp_renderer.rb` | `Instruction[]` -> S-expression string | No (becomes `--scheme` debug output) |
| `src/bytecode_renderer.rb` | `Instruction[]` -> `u8[]` | New file (~200 lines) |
| `interpreter.clear` (runtime) | Value, Env, native fns, debugger | No |
| `interpreter.clear` (eval) | Tree-walks S-expressions | Replaced by dispatch loop |

The cut line is between the transpiler and the renderer. Everything above stays. Everything below swaps.

### Performance Trajectory

| Stage | Execution path | Speed vs CPython (no JIT) |
|---|---|---|
| Day 1: S-expressions | Tree-walk eval | ~3-10x slower |
| Day 2: Bytecode + hashmap envs | Dispatch loop | ~1x (parity) |
| Day 3: Bytecode + slot-indexed envs | Dispatch loop + array access | ~2-5x faster |

The slot-indexed environment optimization is free - the transpiler already resolves variable scopes. It emits `LOAD_SLOT 3` instead of `LOAD_NAME "x"`, and environments become `Value[]` arrays instead of `HashMap<Value>`. This eliminates hash lookups on every variable reference, which is the single largest overhead in any interpreter.

### ~30 Opcodes (Complete Set)

The transpiler controls what gets emitted. The full opcode set for CLEAR's subset:

| Category | Opcodes |
|---|---|
| Stack | `LOAD_CONST`, `LOAD_SLOT`, `STORE_SLOT`, `POP`, `DUP` |
| Arithmetic | `ADD`, `SUB`, `MUL`, `DIV`, `MOD`, `NEG` |
| Comparison | `EQ`, `LT`, `GT`, `LTE`, `GTE` |
| Logic | `NOT`, `AND`, `OR` |
| Control | `JUMP`, `JUMP_IF_FALSE`, `CALL`, `TAIL_CALL`, `RETURN` |
| Data | `MAKE_VEC`, `VEC_GET`, `VEC_SET`, `MAKE_LIST`, `LIST_GET`, `CONS`, `CAR`, `CDR` |
| Strings | `STR_CONCAT`, `STR_LEN`, `SUBSTR` |
| Environment | `MAKE_ENV`, `CLOSE_OVER` |
| VM | `BREAKPOINT`, `HALT`, `NATIVE_CALL` |

No `CALL_CC`. No `EVAL`. No `MACRO_EXPAND`. The opcode set is closed because the transpiler is the only producer.

## Effort Breakdown

### Phase 0: Compiler Prerequisites

**None.** All required compiler features are already implemented. The interpreter should compile and run its 21 tests today. Verify with:

```bash
./clear test examples/mal/interpreter.clear
```

### Phase 1: Interpreter Maturation (~15-25 commits)

The interpreter only needs to handle what the transpiler emits. No `quote`, no macros, no continuations, no `call/cc`. But "Mal 4.5" understates the delta - the current interpreter speaks Mal syntax and handles a handful of forms. Running transpiler output requires standard Scheme syntax, new data types, error semantics, and debugger hooks.

**Syntax alignment** (transpiler emits standard Scheme, not Mal):

| Work | Size | Notes |
|------|------|-------|
| `define` / `lambda` / `let` / `begin` / `set!` | Medium | Replace or alias `def!` / `fn*` / `let*` / `do`. Touches every branch of `evalList!`. |

**Data model extensions** (CLEAR types lowered to Scheme):

| Work | Size | Notes |
|------|------|-------|
| Vectors (`vector`, `vector-ref`, `vector-set!`) | Medium | STRUCT lowering. New Value variant, index bookkeeping. |
| Tagged pairs (`cons`, `car`, `cdr` + symbol tags) | Medium | UNION lowering. Tag check at each MATCH site. |
| String operations (`string-append`, `substring`, `string-length`, `string-ref`) | Medium | Current string support is near-zero. |

**Runtime semantics:**

| Work | Size | Notes |
|------|------|-------|
| TCO: trampoline loop in `eval` | Medium | Well-known pattern but restructures the entire eval loop. |
| Error values + propagation | Large | New error Value variant, check-after-every-eval, unwind on `RAISE`, catch on `s>`. Biggest single item. |
| Growable env pool + cycle cleanup | Medium | Replace fixed 10,000-slot array, handle Env->Lambda->Env cycles. |

**Tooling hooks:**

| Work | Size | Notes |
|------|------|-------|
| Source-map metadata in emitted S-exprs | Medium | Thread source locations through parse + eval. |
| Native function registration API | Small | Extensible dispatch table (replaces string `if` chain). |
| `BREAKPOINT` hook in eval loop | Small | Check breakpoint state at each eval step. |

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
- Compliance test generator: run 130+ existing `.clear` transpile tests in both strict and loose modes
- Verify `ASSERT` statements pass identically on VM and native backends
- Performance baseline: establish "fast enough" threshold for interactive use

### Total: ~55-80 commits

| Phase | Commits | Focus |
|-------|---------|-------|
| 0: Compiler prereqs | 0 | Already done |
| 1: Interpreter maturation | 15-25 | Syntax, data types, errors, TCO, debugger hooks |
| 2: REPL & debugger | 10-15 | **Primary deliverable** |
| 3: Scheme transpiler | 20-28 | CLEAR AST -> Instruction IR -> S-expressions |
| 4: Integration & testing | 7-12 | End-to-end validation |

Split roughly **30/70** between interpreter maturation (Phase 1) and transpiler/tooling (Phases 2-4).

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
