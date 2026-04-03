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

7. **Early return in functions** - `IF cond THEN RETURN val; END RETURN other;` transpiles
   to `(if cond val nil) other` which always evaluates `other`. The Scheme tree-walker
   has no early-return mechanism. Needs either: continuation-based return, or the
   transpiler restructuring the body as nested if/else chains.
   Affects: 55_generic_union and any function with conditional early returns.

8. **Nested list arena lifetime** - Vectors/lists inside other lists (e.g., list of structs
   returned from list-index grouping) hit use-after-free when accessed after the creating
   function returns. Related to bug #2 but specifically for nested collections.
   Affects: 25_index field access, 29_unnest (double free).

## Future (Post-VM)

- Bytecode compilation (transpiler emits bytecode directly, dispatch loop replaces tree-walker)
- Slot-indexed environments (variable index instead of hash lookup)
- Native @regex (replace manual tokenizer)
- Weak pointers for Env->Lambda->Env cycles
- Automatic @indirect inference on recursive unions
