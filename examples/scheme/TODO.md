# Mal Level 4 Interpreter — Implementation Gaps

This interpreter is the **confidence test** for CLEAR's v0.1-pre release.
If it compiles and runs, the language isn't brittle.

## Current Status

**First blocker**: The lexer doesn't support string escape sequences (`\"`, `\n`, `\t`).
The interpreter.cht file uses these extensively in the tokenizer.

Attempting to compile (`ruby src/transpiler.rb examples/scheme/interpreter.cht`):
```
Unexpected char: \ on line 48:26
```

## P0 — Blocks Compilation

These are CLEAR compiler features that must be implemented before interpreter.cht
can even parse and transpile. Ordered by dependency:

1. **String escape sequences** — lexer must handle `\"`, `\n`, `\t`, `\\` in string
   literals. Without this, the tokenizer's whitespace/quote handling can't be expressed.

2. **String indexing** — `str[i]` must return a character. Used throughout the manual
   tokenizer (`c = str[i]`). May return String (single char) or Byte.

3. **String.substring(start, end)** — or equivalent slice syntax. Used in readAtom
   to strip quotes from string literals, and in eval to slice argument lists.

4. **toNumber(string)** — `toNumber(token) OR -999.999` in readAtom. Needs to return
   `?Float64` (optional). The `OR` fallback pattern must work with optionals.

5. **MATCH payload extraction** — `Value.Number(n) -> n` must bind `n` to the payload.
   This is the core of the evaluator. Every `MATCH v START Value.X(payload) -> ...`
   pattern depends on this.

6. **@indirect on union fields** — `Body: Value @indirect` in the Lambda variant must
   emit a heap-allocated pointer to break the `Value -> Lambda -> Value` recursion.

7. **@shared struct construction** — `Env{...} @shared` must wrap in Arc. Used for
   environment creation in eval (let*, fn*).

8. **Error propagation through WHILE** — `RAISE` inside a WHILE loop body must
   propagate the error to the function's return type (`!Value`).

## P1 — Blocks Test Suite

The step4_tests.mal file needs these to pass:

9. **Math operators** — `-`, `*`, `/` on native functions. Only `+` is currently
   implemented in the interpreter.

10. **Comparison operators** — `=`, `<`, `>`, `<=`, `>=` as native functions. Needed
    for `if` conditionals and recursive algorithms (fibonacci, etc.).

11. **`OR BREAK`** — `readForm!(r) OR BREAK` in the REPL loop. Error-to-break
    coercion for loop control flow.

12. **Optional field access** — `inner.Outer.?` to unwrap optional Env. Used in
    envGet for scope chain traversal.

## P2 — Demo Polish

13. **stdin REPL** — read a line from stdin for interactive use.
14. **More native functions** — `pr-str`, `prn`, `str`, `println` for Mal compliance.
15. **Varargs** — `& rest` syntax in fn* for variadic functions.

## v0.2+ (Punt)

These are legitimate improvements but not needed for v0.1-pre confidence:

- Native @regex (replace manual tokenizer)
- Sealed interfaces / protocols (replace UNION Value)
- Weak pointers for Env→Lambda→Env cycles
- TCO (@tco attribute for infinite recursion)
- Automatic @indirect inference on recursive unions
