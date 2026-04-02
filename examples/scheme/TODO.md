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

## Future (Post-VM)

- Bytecode compilation (transpiler emits bytecode directly, dispatch loop replaces tree-walker)
- Slot-indexed environments (variable index instead of hash lookup)
- Native @regex (replace manual tokenizer)
- Weak pointers for Env->Lambda->Env cycles
- Automatic @indirect inference on recursive unions
