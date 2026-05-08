# respond_to? Inventory (TODO #9 Phase 0)

`tools/respond_to_inventory.rb` walks `src/ast/ast.rb` to map AST classes
to their attrs (Struct members + `include Locatable` + `attr_accessor` +
custom `def name` getters), then walks `src/**/*.rb` for every
`respond_to?(:X)` site and writes:

- `tmp/respond_to_inventory/attrs_by_class.csv` — `class, attr`
- `tmp/respond_to_inventory/sites.csv` — `file, line, attr, receiver, method, caller_kind, classes_with_attr`
- `tmp/respond_to_inventory/summary.md` — top-30 attrs + caller-kind histogram

`caller_kind` is a heuristic on the enclosing method's params:

- **generic_walker** — first param has a generic name (`node`, `stmt`,
  `expr`, `body`, `value`, `n`, `v`, `item`, etc.) AND that's the
  receiver of the `respond_to?`. Treat as legitimate duck-typing on
  heterogeneous tree input.
- **typed_or_unclear** — receiver doesn't match a generic-named param.
  The caller likely has a typed param. `respond_to?` here is usually
  dead defensive code.
- **unknown** — no enclosing method (top-level scripts, etc.).

## Headline numbers (current)

- 655 total `respond_to?` sites
- 384 generic_walker (58.6%) — legitimate, candidates for declarative
  metadata fix (Phase 1b)
- 249 typed_or_unclear (38.0%) — candidates for pure-deletion sweep
- 22 unknown — small tail

## Locatable is universal

117 of 117 inventoried AST classes include `AST::Locatable`. Locatable
provides 33 attrs (`token`, `symbol`, `full_type`, `type_info`,
`storage`, `matched_stdlib_def`, `was_moved`, `zig_pattern`, `line`,
`column`, `coerced_type`, etc.). For every AST node receiver,
`respond_to?(:LOCATABLE_ATTR)` is unconditionally `true`.

This collapses the dominant attr categories in the top-30:

- `:symbol` (50), `:full_type` (44), `:token` (26), `:type_info` (20),
  `:storage` (20), `:line` (9), `:matched_stdlib_def` (9),
  `:coerced_type` (6), `:was_moved` (5), `:zig_pattern` (5),
  `:mutates_receiver` (4)

Total: ~198 sites where the `respond_to?` is testing a Locatable attr.
Of these, ~150 are in `typed_or_unclear` callers — candidates for
straight deletion (use safe-nav `&.` instead).

## Phased plan

| Phase | Scope | Sites | Action |
|---|---|---:|---|
| 1a | Locatable attrs in typed callers | ~150 | Delete `respond_to?(:X)` guard; keep `&.` for nilable values. |
| 1b | Generic-walker sites probing AST shape | ~190 | Introduce `AST::HasBodies` / `HasChildExprs` declarative traits. Walkers iterate via `node.child_bodies` instead of hand-coded case chains. |
| 2 | Multi-class shared-trait attrs (`:name` 22cls, `:value` 17cls, `:target` 5cls) | ~80 | Per-trait module + `include` in the relevant classes. `respond_to?(:value)` becomes `is_a?(AST::HasValue)`. |
| 3 | Single-class attrs (`:layout`, `:sync`, `:requires`, `:ownership`) | ~40 | Tighten the caller's signature so the param is the one class that has the attr. |
| 4 | External duck-typing on String / Hash / Type / FFI return values (`:strip`, `:each_pair`, `:error_union?`, `:empty?`) | ~75 | Document with one-line comment per site. Keep the check. |

## Risk hotspots

- Phase 1a relies on `caller_kind` being correct. The classifier marks
  `typed_or_unclear` whenever the param name is non-generic, but some
  methods take typed args with generic names (`def visit(node)`) and
  some take generic args with typed names. Per-site eyeball still
  required.
- Phase 1b introduces base modules; risk is over-narrowing the walkers
  and missing a node type that participates structurally without the
  trait include. Tests catch this.
- Phase 3 signature-tightening will surface real type mismatches —
  expect to find a few callers that have been quietly passing the
  wrong shape. That's a feature: those bugs are revealed.

## Re-run

```
bundle exec ruby tools/respond_to_inventory.rb
```

Idempotent. Reads only; writes only to `tmp/respond_to_inventory/`.
