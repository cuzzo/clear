# Known-failing transpile reproducers

Each `.cht` file here is a minimal reproducer for a CLEAR compiler
bug listed in [`docs/agents/puck-clear-bugs.md`](../../docs/agents/puck-clear-bugs.md).
They are intentionally NOT picked up by `transpile-tests/gen.rb` (which
globs `transpile-tests/*.cht`, non-recursive) so they don't break the
standard CI run.

When a bug is fixed, move its reproducer up into
`transpile-tests/<NNN>_<descriptive_name>.cht` so the regression
becomes part of the gate.

## Inventory

All four reproducers below have been FIXED and promoted into
`transpile-tests/` proper (no `bug` prefix):

| Was | Bug | Now |
| --- | --- | --- |
| `bug1_or_fallback_in_if_condition_hoist.cht` | #1 | `transpile-tests/or_fallback_in_if_condition_hoist.cht` |
| `bug2_while_loop_with_local_split_no_rewind.cht` | #2 | `transpile-tests/while_loop_with_local_split_no_rewind.cht` |
| `bug3_or_fallback_doesnt_propagate_fallibility.cht` | #3 | `transpile-tests/or_fallback_doesnt_propagate_fallibility.cht` (alloc-conflation de-conflated; residuals #11/#12/#13 filed) |
| `bug9_list_in_struct_in_list.cht` | #9 | `transpile-tests/list_in_struct_in_list.cht` |
(FIXED + promoted, via the architectural /plan collapse-divergent-
path work -- each killed a bug by collapsing an Nth re-derivation
onto the one canonical source:
- `tailcall_reentrant_in_tight_loop.cht` → Step A: TIGHT gate
  re-keyed onto canonical `reentrance_kind`; now
  `transpile-tests/529_tailcall_reentrant_in_tight_loop.cht`.
- `bgcopy_list_param_reentrant_items.cht` → Step B: list deep-copy
  routed through the canonical `MIR::ItemsAccess(safe:true)`; now
  `transpile-tests/530_bgcopy_list_param_reentrant.cht`.
- `bug8_bare_string_list_copy_into_bg.cht` → Step C: COPY-depth
  decided by the canonical `implicitly_copyable?` predicate +
  per-element canonical `dupeValue`; now
  `transpile-tests/531_bgcopy_string_list_element_ownership.cht`
  (leak-checked in the gate).)

Reproduce with `./clear build <file>` or `./clear run <file>`.
