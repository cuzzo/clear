# Stage 3: per-component byte compatibility

Does the CLEAR compiler produce the same outputs as the Ruby one, given the same
inputs? Measured per component, bottom-up, so each failure belongs to exactly
one component and reproduces on small inputs.

## Method

1. A shared corpus module (`*_cases.rb`) so both sides are driven by identical
   inputs.
2. A Ruby oracle that runs the real implementation and prints one canonical line
   per observation.
3. A CLEAR harness that prints the same lines, built against the real component
   through the importer.
4. `diff`. Byte compatibility is the diff returning nothing.

## Status

| Component | Observations | Result |
|---|---|---|
| `ast/parser` (scc_parser_7) | 8 corpus cases | byte-identical (`tools/parser_compat.rb`) |
| `semantic/effect_set` | 504 | byte-identical |

## Gotchas found the hard way

- CLEAR's `print` writes to **stderr** and appends its own newline, so the
  harness output needs `grep -v '^$'` before comparison.
- `Bool` has no `toString`; render with `IF b THEN "true" ELSE "false" END`
  (type.clear:4223 does the same).
- A constructor returning `!T@multiowned` cannot have its result passed to a
  plain-`T` parameter -- that type-checks and then miscompiles. Build the struct
  directly, or unwrap with `WITH`.
- Passing 2c does NOT mean a component is sound: Zig only compiles what is
  reachable from the probe's empty `main`, so most functions are never
  instantiated. Stage 3 is what exercises them.
