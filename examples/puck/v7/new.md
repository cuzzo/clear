# Puck V7

V7 branches from V6 and adds compile-time macro expansion.

- `MACRO name(args) DO body END; ... END;` — definitions
- `name(args) DO ... END` — call sites (the `DO ... END` is the body slot's value)
- `body;` in a template — splice point for the caller's block. Parses as the new bare zero-arg `CallStatement(name, [])` shape.
- `ELSIF` and `ELSE` (and the `:If` AST node gains `else_body`)
- comparison operators: `<`, `<=`, `>`, `>=`, `#` (Oberon's not-equal)
- `parse_statements` now accepts an array of stop types so `IF` can stop at any of `:ELSIF`/`:ELSE`/`:END`
- `macro_expander.rb` — one walker that substitutes args, splices bodies, and recursively expands nested macros

The compiler picks up two small things: an else-branch in `If` (two patch sites instead of one — same pattern as V4's `LOOP`/`EXIT`) and a `COMPARE_OPS` map from source operator to Ruby method symbol.

The VM gains no new opcodes. Its one-line change is in `compare`: V5/V6's `if op == :==` guard is dropped, since the compiler now always picks a Ruby method symbol the VM can just `send`. Macros are eliminated before compilation; the bytecode the VM sees is the same shape as V6.
