# Mal Interpreter - Status & Roadmap

This interpreter is the **confidence test** for CLEAR's v0.1-pre release
and the foundation for the **CLEAR VM backend** (see `docs/vm.md`).

## Current Status: Mal Level 4

**Compiles and runs.** All 21 tests pass. The P0 blockers listed in the
original TODO are resolved - the compiler supports string escapes, charAt,
substr, toNumber, MATCH AS, @indirect, @shared, and RAISE in WHILE.

```bash
./clear test examples/scheme/interpreter.cht
```

Implemented:
- Lexer/parser for S-expressions
- `def!`, `let*`, `fn*`, `do`, `if`
- Lambdas with closure capture (pool-based environments)
- Arithmetic (`+`, `-`, `*`, `/`)
- Comparison (`=`, `<`, `>`, `<=`, `>=`)
- List ops (`list`, `list?`, `empty?`, `count`)
- Boolean logic (`not`), truthiness
- Recursive functions (sumdown, fibonacci)
- `prn` (readable printing)

## Mal 4.5: VM Backend Target

The interpreter does not need to be a full Scheme. It only needs to handle
what the CLEAR transpiler emits - a closed, known set. No `quote`, no
macros, no continuations, no `call/cc`, no `eval`, no varargs, no atoms.

### Syntax Alignment

The transpiler will emit standard Scheme, not Mal syntax. Either rename
the existing forms or add parallel dispatch:

| Current (Mal) | Needed (Scheme) | Notes |
|---|---|---|
| `def!` | `define` | Top-level binding |
| `fn*` | `lambda` | Function creation |
| `let*` | `let` | Scoped bindings |
| `do` | `begin` | Sequential evaluation |
| (missing) | `set!` | Mutable binding reassignment |

### Data Model Extensions

CLEAR structs and unions lower to Scheme vectors and tagged pairs:

| Work | Notes |
|------|-------|
| `vector`, `vector-ref`, `vector-set!` | STRUCT fields become vector slots |
| `cons`, `car`, `cdr` + symbol tag checks | UNION variants become `(cons 'Tag payload)` |
| String ops (`string-append`, `substring`, `string-length`, `string-ref`) | Current string support is minimal |

### Runtime Semantics

| Work | Size | Notes |
|------|------|-------|
| TCO: trampoline loop in `eval` | Medium | Convert tail-position calls to loop iterations. Without this, any recursive CLEAR program stack-overflows. |
| `set!` for mutable bindings | Small | Walk scope chain, find binding, update in place. |
| Error values + propagation | Large | New error Value variant. Check after every sub-eval, unwind on `RAISE`, catch on `s>`. Biggest single item. |
| Growable env pool + cycle cleanup | Medium | Replace fixed 10,000-slot array. Handle Env->Lambda->Env reference cycles. |

### Tooling Hooks

| Work | Size | Notes |
|------|------|-------|
| Source-map metadata | Medium | Thread CLEAR line/col through parse + eval for debugger. |
| Native function registration API | Small | Replace string `if` chain with extensible dispatch table. |
| `BREAKPOINT` hook in eval loop | Small | Check breakpoint state at each eval step. |

### Not Needed

These are standard Scheme/Mal features that the transpiler will never emit:

- `call/cc` or continuations
- `quote` / `quasiquote` / macros / `macroexpand`
- `eval` at runtime
- Varargs / `& rest`
- Atoms (`atom`, `deref`, `swap!`)
- File I/O (`slurp`, `read-string`)
- Hygienic macro expansion

## Compiler Bugs (blocking clean implementation)

1. **@list param passing** - transpiler extracts `.items` from ArrayList when passing
   `MUTABLE x: Value[]@list` to a function, turning it into a slice. `.append()` fails.
   Workaround: inline all @list operations, never pass @list between functions.

2. **@list arena lifetime** - @list arrays allocated in a function's frame arena are freed
   when the function returns. Storing them in HashMap entries or returning them as
   Value.List causes use-after-free. PromotionPlan should promote these to the heap
   when they escape through assignment or return.
   Workaround: `compile!` stores bytecode entry-by-entry as Value.Number in the pool
   env (inline values, no pointers). Undo this when the promotion bug is fixed -
   compile! should return `Value.Pair{ List[ops], List[consts] }` directly.

3. **MATCH AS payload return** - returning a MATCH-extracted array from a helper function
   generates `items_moved = true` without declaring the tracking variable.

4. **TEST THAT runtime pointer** - test framework passes `rt` by value instead of `&rt`
   when calling functions that need the runtime from TEST THAT blocks.

5. **Struct literal with @list fields** - `Chunk{ ops: List[], ... }` fails because the
   transpiler tries to access `.items` on the error union from `makeList`.

6. **@pool + @shared:locked composition** - `pool @shared:locked` generates incorrect Zig.
   The codegen wraps the raw array type `[N]T` instead of the Pool wrapper type
   `CheatLib.Pool(T)`. Should emit `Arc(Mutex(CheatLib.Pool(T)))`. Fix is in
   `src/transpiler.rb` capability composition logic. This blocks real concurrency
   in the interpreter - the pool can't be shared across BG fibers without it.
   Workaround: sequential fake concurrency (BG evals immediately).

7. **Early return in functions** - FIXED in Commit 27. Transpiler restructures
   IF...RETURN...END patterns into nested if/else chains.

8. **Nested list arena lifetime** - Vectors/lists inside other lists (e.g., list of structs
   returned from list-index grouping) hit use-after-free when accessed after the creating
   function returns. Related to bug #2 but specifically for nested collections.
   Affects: 25_index field access, 29_unnest (double free).

## Debugger Plan

### Phase 1: File-based IPC (stub, no compiler changes)

The interpreter uses readFile/writeFile to communicate with the Ruby wrapper:

1. Breakpoint check in eval loop: when entering a function in the breakpoint set,
   the interpreter writes env state to `_debug_env.txt` and function name to
   `_debug_break.txt`, then polls `_debug_cmd.txt` for commands.
2. Ruby wrapper polls `_debug_break.txt`. When a break is detected, enters debug
   REPL. User commands are written to `_debug_cmd.txt`.
3. Interpreter reads command, processes (inspect var, dump locals, eval expression),
   writes response to `_debug_resp.txt`. Loops until `:continue`.
4. On `:continue`, interpreter clears break file and resumes eval.

This gives: breakpoints, variable inspection, expression eval at break, call stack
display, continue. All without readLine.

### Phase 2: readLine-based (requires compiler change)

Add `readLine` to CLEAR stdlib (~10 lines of Zig):
```zig
pub fn readLine(alloc: Allocator) ![]const u8 {
    return std.io.getStdIn().reader().readUntilDelimiterAlloc(alloc, '\n', 4096);
}
```

Replace file polling with direct stdin reading. Same debug commands, no temp files,
lower latency. The interpreter's debug REPL reads from stdin directly.

### Phase 3: Persistent interpreter process

Compile the interpreter ONCE with a stdin-reading main loop. The Ruby wrapper pipes
S-expressions via stdin, reads results from stdout. Process stays alive across
interactions:
- Eliminates 2-second compile latency per REPL interaction
- Eliminates arena lifetime issues (single process = persistent memory)
- Debug pausing is natural (process blocks on readLine)
- Full CLEAR runtime access maintained throughout

## Blocked on Compiler

**Bug #2 (@list arena lifetime) is the single biggest blocker.** Fixing PromotionPlan
to promote @list data to the heap when it escapes through @indirect assignment
would unblock ALL of the following:

- **Typed structs**: typed-struct:i64/f64 infrastructure built, FFI functions ready,
  transpiler detects homogeneous types. Data dies on return. (Commit 43)
- **Nested collections**: list-index results, struct arrays, struct-of-struct.
  Inner arrays freed when outer function returns. (25_index, 29_unnest)
- **Mutation**: vector-set!, struct field mutation. MATCH AS bindings are immutable.
  7 transpile-tests blocked (04, 19, 40, 41, 42, 43, 48).
- **Bytecode compiler return**: compile! stores bytecode entry-by-entry in env
  as workaround. Should return Pair{List[ops], List[consts]} directly. (Commit 9)

## Compiler Changes Needed

- **PromotionPlan fix** - promote @list to heap when escaping through @indirect (bug #2)
- **readLine** - add to std_lib.rb + runtime-header.zig (Phase 2+3)
- **@pool + @shared:locked** - fix capability composition for real concurrency (bug #6)

## Future (Post-VM)

- Bytecode compilation (transpiler emits bytecode directly, dispatch loop replaces tree-walker)
- Slot-indexed environments (variable index instead of hash lookup)
- Native @regex (replace manual tokenizer)
- Weak pointers for Env->Lambda->Env cycles
- Automatic @indirect inference on recursive unions
