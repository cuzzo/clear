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

| File | Bug | Failure shape |
| --- | --- | --- |
| `bug1_or_fallback_in_if_condition_hoist.cht` | #1 | Zig emits `if (...__tmp_N...)` before declaring `__tmp_N`. |
| `bug2_while_loop_with_local_split_no_rewind.cht` | #2 | `[FRAME_NO_REWIND]` from MIR ownership check at build time. |
| `bug3_or_fallback_doesnt_propagate_fallibility.cht` | #3 | "Function 'X' can fail (raises directly via RAISE)" even though it never RAISEs. |
| `bug9_list_in_struct_in_list.cht` | #9 | Runtime: `items[1].data[0]` returns the wrong value (storage shared across iterations). |
| `bug8_bare_string_list_copy_into_bg.cht` | vm-bugs.md "Bug #8" | **Leak-detection only**: builds/runs clean under C alloc; `./clear test <file>` reports `Second free:` (element-string double-free). |

(FIXED + promoted, via the architectural /plan collapse-divergent-
path work:
- `tailcall_reentrant_in_tight_loop.cht` → Step A: TIGHT gate
  re-keyed onto canonical `reentrance_kind`; now
  `transpile-tests/529_tailcall_reentrant_in_tight_loop.cht`.
- `bgcopy_list_param_reentrant_items.cht` → Step B: list deep-copy
  routed through the canonical `MIR::ItemsAccess(safe:true)`; now
  `transpile-tests/530_bgcopy_list_param_reentrant.cht`.)

Reproduce with `./clear build <file>` or `./clear run <file>`, EXCEPT
`bug8_*` which is leak-detection-only: `./clear test <file>` (it
builds clean under the C allocator).
