# pydantic-settings — Python

**Revision:** `5c702e535b08` · **Scope:** `pydantic_settings` · **Result:**
credible CLI/configuration complexity; no probable correctness or performance
defect established.

## Analyzer evidence

| Tool | Evidence |
| --- | --- |
| Nil-Kill static | 22 files, 213 methods, 199 fields; 300 Type Next candidates, the largest Python review queue in this pass. |
| Espalier | 168/208 time bounds unknown (80.8%). `CliSettingsSource` dominates: 38 state members and 42 methods. |
| Decomplex | 43 convergences, led by `_load_env_vars`, CLI construction, `_add_parser_args`, and `_add_parser_submodels`. |

## Independent source audit

- The CLI source builds an argument parser from model fields, resolves aliases,
  nested models, defaults, and serialized forms. `_add_parser_args` and
  `_add_parser_submodels` are actual fan-out surfaces; their cost scales with
  model/schema shape.
- `_load_env_vars` translates parsed arguments into environment-style settings
  and copies/normalizes input when necessary. It is a real precedence and
  transformation boundary, not merely a detector artifact.
- The source object intentionally owns parser state such as `_parser_map`; its
  high owner score reflects a concentrated adapter, not evidence of stale
  state. Other source providers and model validation are external constraints.

## Assessment and follow-up

- The rankings make good review starting points. Static type leads are useful
  because the project is already annotated, but must exclude generic/model
  metaprogramming before they become action items.
- The unknown rate is too high to use Big-O as a performance verdict. It misses
  a potentially useful symbolic model: field count × nesting depth × input
  argument count.
- No candidate defect was found. The most valuable future test is a deeply
  nested model with repeated aliases, to distinguish intentional one-pass
  traversal from repeated parser construction.

## Second-pass time/space audit

- **Partial evidence:** all 168 unknown time/space results have components.
  `_settings_init_sources` and local model/config reads are under-specified;
  source-provider invocation in `_settings_build_values` is appropriately
  opaque. The three-source sample is two under-specified, one appropriate.
- **Actual dominant work:** parser construction and value resolution depend on
  settings fields, nesting, aliases, and number of configured sources. Space
  grows with parser/model-derived maps and parsed argument/environment values.
- **Coverage verdict:** Espalier should emit a field × source/nesting symbolic
  component while preserving external provider work as unknown. It currently
  identifies the right owner but not the time/space shape.
