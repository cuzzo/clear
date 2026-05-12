# Puck

Puck is a deliberately small Oberon-shaped language experiment implemented in
CLEAR.

The core language is limited to seven primitive operations:

1. Variable declaration and assignment
2. Procedure calls
3. `IF`
4. `LOOP`
5. `EXIT`
6. User-defined AST macros
7. Lexical scope exit with refcount cleanup

Everything else, including `RECORD`, `PROCEDURE`, `WHILE`, and later `FOR`, is
intended to live in `core.puck` as macro-expanded surface syntax over that
small core. `SYSCALL(id, ...)` is reserved as a later eighth primitive and is
not part of this slice.

Hard constraints for this experiment:

- Grammar must stay LL(1).
- Statements end with `;`.
- Comments are line comments only: `# ...`.
- Strings use double quotes only. There are no multi-line strings and no
  single-quote strings.
- Quote escaping is `\"`.
- Source text is ASCII only.
- Heap values are explicit `REF` values, e.g. `VAR heapPoint: REF Point;`.
- No escape analysis. `REF` values are refcounted and released at scope exit.

Current files:

- `puck.cht`: self-contained tokenizer, primitive VM, and `.puck` runner.
- `core.puck`: macro-level surface forms for realistic Oberon syntax.
- `samples/primitive.puck`: primitive-core runnable smoke file.
- `samples/point.puck`: record/procedure example.
- `samples/while_macro.puck`: macro rewrite example.

Run the primitive `.puck` smoke file with:

```bash
./clear run examples/puck/puck.cht
```

Current VM execution supports the primitive core: assignment, procedure calls
for `Print`, `IF`, `LOOP`, and `EXIT`, plus simple integer/string expressions.
Macro expansion from `core.puck` is loaded and counted, but expansion of surface
forms such as `WHILE`, `FOR`, and `CASE` is the next implementation step.
