# Boobytrap Method Coverage Tracker

Generated from `coverage/.resultset.json` on May 31, 2026, scoped to
`src/annotator` and `src/mir`.

Goal: address every Boobytrap "Mostly Uncovered Methods" entry with the
smallest useful coverage path. Fuzz was checked first as a whole-category
option; these entries are mostly internal post-annotation MIR/cleanup helpers
that require precise compiler state, so targeted unit characterization is the
default unless a source-level fixture naturally covers the path.

Completion snapshot:

- Boobytrap mostly-uncovered methods: `31 -> 0`.
- Scoped covered lines (`src/annotator` + `src/mir`): `25174 -> 25455` (`+281`).
- Scoped covered branches (`src/annotator` + `src/mir`): `11569 -> 11700` (`+131`).
- The post-collate branch denominator changed because the focused SimpleCov
  run reintroduced branch definitions for files the prior collated result did
  not count the same way; the stable signal for this burndown is covered
  branch count and Boobytrap's method-gap section.
- Bug found/fixed: `SemanticAnnotator#visit_BlockExpr` returned a storage
  symbol despite its `T.nilable(Scope)` contract. It now returns `nil`.

| # | status | path | method | baseline covered | plan |
|---|--------|------|--------|------------------|------|
| 1 | addressed | `src/mir/cleanup_classifier.rb:967` | `struct_lit_borrows_cleanup_fields?` | `1/12` | `spec/boobytrap_method_coverage_spec.rb` |
| 2 | addressed | `src/mir/hoist.rb:464` | `hoist_lazy_alloc_result` | `1/14` | `spec/boobytrap_method_coverage_spec.rb` |
| 3 | addressed | `src/annotator/helpers/fixable_helpers.rb:1224` | `build_decl_cap_replace_fix` | `1/12` | `spec/boobytrap_method_coverage_spec.rb` |
| 4 | addressed | `src/mir/mir_lowering.rb:640` | `scoped_owning_branch_value` | `1/16` | `spec/boobytrap_method_coverage_spec.rb` |
| 5 | addressed | `src/mir/cleanup_classifier.rb:800` | `container_alloc_from` | `1/8` | `spec/boobytrap_method_coverage_spec.rb` |
| 6 | addressed | `src/mir/cleanup_classifier.rb:889` | `classify_owned_string` | `2/12` | `spec/boobytrap_method_coverage_spec.rb` |
| 7 | addressed | `src/mir/mir_lowering.rb:1815` | `collect_moved_arg_roots` | `1/6` | `spec/boobytrap_method_coverage_spec.rb` |
| 8 | addressed | `src/mir/mir_checker.rb:2285` | `expr_has_frame_alloc?` | `1/8` | `spec/boobytrap_method_coverage_spec.rb` |
| 9 | addressed | `src/mir/mir_pass.rb:785` | `collect_return_escapes` | `1/9` | `spec/boobytrap_method_coverage_spec.rb` |
| 10 | addressed | `src/annotator/annotator.rb:6359` | `contains_self_call?` | `1/5` | `spec/boobytrap_method_coverage_spec.rb` |
| 11 | addressed | `src/mir/lowering/functions.rb:1458` | `call_owned_return_from_args?` | `1/10` | `spec/boobytrap_method_coverage_spec.rb` |
| 12 | addressed | `src/mir/mir_emitter.rb:253` | `emit_raw_bc_as_zig` | `1/6` | `spec/boobytrap_method_coverage_spec.rb` |
| 13 | addressed | `src/annotator/annotator.rb:6540` | `find_unbounded_callee` | `1/9` | `spec/boobytrap_method_coverage_spec.rb` |
| 14 | addressed | `src/mir/lowering/capabilities.rb:150` | `build_field_path_zig` | `1/7` | `spec/boobytrap_method_coverage_spec.rb` |
| 15 | addressed | `src/annotator/helpers/pipe_analysis.rb:1174` | `pre_scan_node_for_sharded` | `1/7` | `spec/boobytrap_method_coverage_spec.rb` |
| 16 | addressed | `src/mir/lowering/functions.rb:1507` | `lower_safe_nav_method_call` | `1/12` | `spec/boobytrap_method_coverage_spec.rb` |
| 17 | addressed | `src/annotator/annotator.rb:5997` | `lifetime_violation_for_store` | `1/8` | `spec/boobytrap_method_coverage_spec.rb` |
| 18 | addressed | `src/mir/lowering/expressions.rb:1162` | `copy_type_capabilities` | `1/6` | `spec/boobytrap_method_coverage_spec.rb` |
| 19 | addressed | `src/mir/mir_lowering.rb:1898` | `consumed_binding_root` | `1/6` | `spec/boobytrap_method_coverage_spec.rb` |
| 20 | addressed | `src/mir/mir_lowering.rb:1775` | `collect_explicit_move_roots` | `1/7` | `spec/boobytrap_method_coverage_spec.rb` |
| 21 | addressed | `src/annotator/annotator.rb:4424` | `visit_Copy` | `1/5` | `spec/boobytrap_method_coverage_spec.rb` |
| 22 | addressed | `src/mir/mir_lowering.rb:1851` | `walk_ast_for_moved_args` | `1/5` | `spec/boobytrap_method_coverage_spec.rb` |
| 23 | addressed | `src/mir/hoist.rb:452` | `descend` | `1/5` | `spec/boobytrap_method_coverage_spec.rb` |
| 24 | addressed | `src/annotator/annotator.rb:1293` | `visit_BlockExpr` | `1/6` | `spec/boobytrap_method_coverage_spec.rb` |
| 25 | addressed | `src/mir/lowering/functions.rb:1781` | `lower_extern_direct_method` | `1/6` | `spec/boobytrap_method_coverage_spec.rb` |
| 26 | addressed | `src/mir/mir_emitter.rb:1387` | `emit_discard_owned` | `1/8` | `spec/boobytrap_method_coverage_spec.rb` |
| 27 | addressed | `src/mir/control_flow.rb:569` | `stmt_moves_name?` | `1/5` | `spec/boobytrap_method_coverage_spec.rb` |
| 28 | addressed | `src/annotator/annotator.rb:3169` | `visit_assignment_variable` | `1/5` | `spec/boobytrap_method_coverage_spec.rb` |
| 29 | addressed | `src/annotator/helpers/fixable_helpers.rb:935` | `emit_with_read_needs_write_lock!` | `1/6` | `spec/boobytrap_method_coverage_spec.rb` |
| 30 | addressed | `src/mir/fsm_transform/recursive_splitter.rb:393` | `emit_suspend` | `1/7` | `spec/boobytrap_method_coverage_spec.rb` |
| 31 | addressed | `src/annotator/helpers/pipe_analysis.rb:1283` | `walk_for_sharded_getindex` | `1/5` | `spec/boobytrap_method_coverage_spec.rb` |
