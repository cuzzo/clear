# Decomplex Report

> Decision-level duplication and neglected-condition analysis.
> Every entry is a ranked **candidate** (Engler's discipline),
> never a verdict -- *POSSIBLE* findings, triaged by a human.
> Sections are ordered by SIGNAL TIER (1 = lowest false
> positive), not by volume. Items within a section are
> frequency-ranked. Triage tier 1, top-of-list, first.

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Decision Pressure (256)](#decision-pressure-256)
- [Missing Abstractions (217)](#missing-abstractions-217)
- [Reification Misses (129)](#reification-misses-129)
- [Semantic Predicate Aliases (3)](#semantic-predicate-aliases-3)
- [Exact Predicate Aliases (7)](#exact-predicate-aliases-7)
- [Type-3 Clones (missed rename) (14)](#type3-clones-missed-rename-14)
- [Neglected Updates (6090)](#neglected-updates-6090)
- [Derived-State Staleness (222)](#derivedstate-staleness-222)
- [Neglected Conditions (47)](#neglected-conditions-47)
- [Neglected Path Conditions (2203)](#neglected-path-conditions-2203)
- [Broken Protocols (1730)](#broken-protocols-1730)
- [Run Summary](#run-summary)

## Project Prioritization
_Ordered by signal tier (1 = highest signal / lowest FP), then by volume._

- **[tier 1]** [Decision Pressure (256)](#decision-pressure-256): loose contract -> N defensive type/nil decisions; fix the contract once, the cluster dies (intra-proc; cross-proc = nil-kill)
- **[tier 1]** [Missing Abstractions (217)](#missing-abstractions-217): guard tuple recomputed across >=2 decision units
- **[tier 1]** [Reification Misses (129)](#reification-misses-129): an existing predicate reinvented inline -- invariant #16
- **[tier 1]** [Exact Predicate Aliases (7)](#exact-predicate-aliases-7): identical one-line predicate body under >=2 names
- **[tier 1]** [Semantic Predicate Aliases (3)](#semantic-predicate-aliases-3): one decision, multiple names (receiver/polarity folded)
- **[tier 2]** [Neglected Updates (6090)](#neglected-updates-6090): co-written state, one write missing -- *POSSIBLE* redundant-state desync
- **[tier 2]** [Derived-State Staleness (222)](#derivedstate-staleness-222): b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug
- **[tier 2]** [Neglected Conditions (47)](#neglected-conditions-47): dispatch/conjunction minus one element -- *POSSIBLE* bug
- **[tier 2]** [Type-3 Clones (missed rename) (14)](#type3-clones-missed-rename-14): pasted block, one identifier inconsistently renamed -- *POSSIBLE* bug
- **[tier 3]** [Neglected Path Conditions (2203)](#neglected-path-conditions-2203): nested-if/&& guard set minus one atom -- *POSSIBLE* bug (noisy)
- **[tier 3]** [Broken Protocols (1730)](#broken-protocols-1730): co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)

## Decision Pressure (256)
_loose contract -> N defensive type/nil decisions; fix the contract once, the cluster dies (intra-proc; cross-proc = nil-kill)_

- `.type_info` drives **274** defensive type/nil decisions across 94 method(s)
  - `src/annotator-helpers/function_analysis.rb:243` (resolve_call) ; `src/annotator-helpers/function_analysis.rb:247` (resolve_call) ; `src/annotator-helpers/function_analysis.rb:248` (resolve_call) ; `src/annotator-helpers/function_analysis.rb:248` (resolve_call)
- `.value` drives **110** defensive type/nil decisions across 54 method(s)
  - `src/annotator-helpers/auto_inference.rb:760` (walk_binops) ; `src/annotator-helpers/capabilities.rb:1055` (_unified_capture_walk) ; `src/annotator-helpers/capabilities.rb:1059` (_unified_capture_walk) ; `src/annotator-helpers/capabilities.rb:1067` (_unified_capture_walk)
- `.symbol` drives **63** defensive type/nil decisions across 44 method(s)
  - `src/annotator-helpers/capabilities.rb:93` (cap_var_sync) ; `src/annotator-helpers/capabilities.rb:118` (cap_var_layout) ; `src/annotator-helpers/capabilities.rb:142` (validate_capability) ; `src/annotator-helpers/capabilities.rb:164` (validate_capability)
- `.target` drives **60** defensive type/nil decisions across 35 method(s)
  - `src/annotator-helpers/auto_inference.rb:655` (record_index_assign) ; `src/annotator-helpers/capabilities.rb:746` (cap_var_name) ; `src/annotator-helpers/function_analysis.rb:909` (verify_return) ; `src/annotator-helpers/generic_analysis.rb:645` (find_container_source)
- `.name` drives **55** defensive type/nil decisions across 37 method(s)
  - `src/annotator-helpers/auto_inference.rb:653` (record_index_assign) ; `src/annotator-helpers/capabilities.rb:1040` (_unified_capture_walk) ; `src/annotator-helpers/capabilities.rb:1292` (_bg_walk) ; `src/annotator-helpers/generic_analysis.rb:630` (register_container_borrow!)
- `.right` drives **53** defensive type/nil decisions across 17 method(s)
  - `src/annotator-helpers/pipe_analysis.rb:24` (visit_Smooth) ; `src/annotator-helpers/pipe_analysis.rb:26` (visit_Smooth) ; `src/annotator-helpers/pipe_analysis.rb:263` (analyze_select_family_op) ; `src/annotator-helpers/pipe_analysis.rb:263` (analyze_select_family_op)
- `.current_fn_ctx` drives **35** defensive type/nil decisions across 23 method(s)
  - `src/annotator-helpers/capabilities.rb:1148` (_unified_capture_walk) ; `src/annotator-helpers/capabilities.rb:1185` (_unified_capture_walk) ; `src/annotator-helpers/capabilities.rb:1329` (record_capability_binding) ; `src/annotator-helpers/capabilities.rb:1337` (record_capability_binding)
- `.full_type` drives **33** defensive type/nil decisions across 20 method(s)
  - `src/annotator-helpers/capabilities.rb:95` (cap_var_sync) ; `src/annotator-helpers/capabilities.rb:104` (cap_var_storage) ; `src/annotator-helpers/capabilities.rb:120` (cap_var_layout) ; `src/annotator-helpers/capabilities.rb:186` (validate_capability)
- `[:type]` drives **29** defensive type/nil decisions across 20 method(s)
  - `src/annotator-helpers/function_analysis.rb:326` (verify_function_signature!) ; `src/annotator-helpers/function_analysis.rb:553` (atomic_cell_to_atomic_param?) ; `src/annotator-helpers/function_analysis.rb:693` (verify_lifetime_source!) ; `src/annotator-helpers/function_analysis.rb:726` (declare_and_verify_params)
- `.left` drives **29** defensive type/nil decisions across 18 method(s)
  - `src/annotator-helpers/pipe_analysis.rb:63` (stamp_observable_terminal!) ; `src/annotator-helpers/pipe_analysis.rb:240` (analyze_collect_op) ; `src/annotator-helpers/pipe_analysis.rb:588` (analyze_limit_op) ; `src/annotator-helpers/pipe_analysis.rb:1335` (analyze_shard_op)
- `.type` drives **28** defensive type/nil decisions across 21 method(s)
  - `src/annotator-helpers/auto_inference.rb:210` (record_local) ; `src/annotator-helpers/auto_inference.rb:504` (stamp_map_pairs!) ; `src/annotator-helpers/auto_inference.rb:505` (stamp_map_pairs!) ; `src/annotator-helpers/auto_inference.rb:572` (walk_for_shape_decls)
- `.return_type` drives **27** defensive type/nil decisions across 15 method(s)
  - `src/annotator-helpers/capabilities.rb:566` (visit_post_clauses!) ; `src/annotator-helpers/function_analysis.rb:170` (resolve_call) ; `src/annotator-helpers/reentrance.rb:162` (validate_not_logical_return!) ; `src/annotator-helpers/reentrance.rb:164` (validate_not_logical_return!)
- `.last` drives **25** defensive type/nil decisions across 6 method(s)
  - `src/annotator.rb:5619` (expr_result_type) ; `src/annotator.rb:5621` (expr_result_type) ; `src/annotator.rb:5628` (expr_result_type) ; `src/annotator.rb:5628` (expr_result_type)
- `.token` drives **22** defensive type/nil decisions across 19 method(s)
  - `src/annotator-helpers/capabilities.rb:1341` (record_capability_binding) ; `src/annotator-helpers/capabilities.rb:1342` (record_capability_binding) ; `src/mir/concurrency_checks.rb:73` (check_hold_across_yield!) ; `src/mir/concurrency_checks.rb:171` (check_reentrant!)
- `.capture_analysis` drives **22** defensive type/nil decisions across 17 method(s)
  - `src/mir/control_flow.rb:675` (transfer_stmt) ; `src/mir/control_flow.rb:755` (collect_ownership_transfers) ; `src/mir/control_flow.rb:841` (_walk_bg_captures_in_expr) ; `src/mir/control_flow.rb:870` (collect_bg_body_gives)
- `[name]` drives **21** defensive type/nil decisions across 20 method(s)
  - `src/annotator-helpers/effects.rb:985` (max_tier_for_calls) ; `src/annotator-helpers/fixable_helpers.rb:310` (emit_use_of_moved_error!) ; `src/annotator-helpers/fixable_helpers.rb:997` (emit_with_materialized_needs_tense!) ; `src/annotator-helpers/fixable_helpers.rb:1200` (build_decl_cap_insert_fix)
- `.tail` drives **21** defensive type/nil decisions across 6 method(s)
  - `src/mir/fsm_transform/emit.rb:341` (build_recursive) ; `src/mir/fsm_transform/emit.rb:375` (build_recursive) ; `src/mir/fsm_transform/emit.rb:376` (build_recursive) ; `src/mir/fsm_transform/emit.rb:444` (build_recursive)
- `.element_type` drives **19** defensive type/nil decisions across 15 method(s)
  - `src/annotator-helpers/generic_analysis.rb:182` (validate_type_annotation!) ; `src/annotator-helpers/method_analysis.rb:42` (narrow_collection_type!) ; `src/annotator-helpers/method_analysis.rb:121` (resolve_typed_method) ; `src/annotator.rb:4305` (infer_element_type)
- `@union_schemas` drives **18** defensive type/nil decisions across 13 method(s)
  - `src/mir/mir_lowering.rb:262` (owned_value_temp_needs_cleanup?) ; `src/mir/mir_lowering.rb:263` (owned_value_temp_needs_cleanup?) ; `src/mir/mir_lowering.rb:291` (copy_container_borrow_if_needed) ; `src/mir/mir_lowering.rb:1297` (lower_function_def)
- `[:var_node]` drives **18** defensive type/nil decisions across 12 method(s)
  - `src/annotator-helpers/capabilities.rb:668` (acquire_capability!) ; `src/annotator-helpers/capabilities.rb:679` (acquire_capability!) ; `src/annotator-helpers/capabilities.rb:709` (acquire_capability!) ; `src/annotator-helpers/capabilities.rb:714` (acquire_capability!)
- `.payload_type` drives **17** defensive type/nil decisions across 5 method(s)
  - `src/annotator-helpers/function_analysis.rb:192` (resolve_call) ; `src/annotator-helpers/function_analysis.rb:195` (resolve_call) ; `src/annotator-helpers/function_analysis.rb:199` (resolve_call) ; `src/annotator-helpers/function_analysis.rb:200` (resolve_call)
- `.reg` drives **15** defensive type/nil decisions across 11 method(s)
  - `src/annotator-helpers/fixable_helpers.rb:1000` (emit_with_materialized_needs_tense!) ; `src/annotator-helpers/fixable_helpers.rb:1201` (build_decl_cap_insert_fix) ; `src/annotator-helpers/fixable_helpers.rb:1229` (build_decl_cap_replace_fix) ; `src/annotator-helpers/function_analysis.rb:970` (return_is_borrow?)
- `.arms` drives **14** defensive type/nil decisions across 8 method(s)
  - `src/annotator-helpers/capabilities.rb:1221` (_unified_capture_walk) ; `src/annotator-helpers/effects.rb:1178` (scan_for_raises) ; `src/annotator.rb:4523` (visit_WithBlock) ; `src/annotator.rb:4682` (visit_WithBlock)
- `@og` drives **14** defensive type/nil decisions across 6 method(s)
  - `src/annotator.rb:1199` (analyze_control_flow_branches) ; `src/annotator.rb:1206` (analyze_control_flow_branches) ; `src/annotator.rb:1212` (analyze_control_flow_branches) ; `src/annotator.rb:1223` (analyze_control_flow_branches)
- `.sync` drives **13** defensive type/nil decisions across 12 method(s)
  - `src/annotator-helpers/function_analysis.rb:204` (resolve_call) ; `src/annotator-helpers/generic_analysis.rb:453` (generic_type_has_capabilities?) ; `src/annotator-helpers/pipe_analysis.rb:1147` (collect_sharded_names) ; `src/annotator-helpers/pipe_analysis.rb:1170` (pre_scan_node_for_sharded)
- ...(+231 more)

## Missing Abstractions (217)
_guard tuple recomputed across >=2 decision units_

- **[conjunction]** support=14 scatter=14 rank=196
  - tuple: `schema.is_a?(Hash) | schema[:kind] == :union`
  - `src/annotator-helpers/function_analysis.rb:257` (resolve_call) ; `src/annotator-helpers/union.rb:148` (validate_union_schema!) ; `src/annotator.rb:1427` (visit_MatchStatement) ; `src/annotator.rb:3039` (track_union_alias) ; `src/annotator.rb:3551` (visit_StructLit) ; `src/annotator.rb:4292` (visit_CopyNode)
- **[conjunction]** support=10 scatter=10 rank=100
  - tuple: `!ti.is_a?(Type) | ti`
  - `src/annotator.rb:6537` (share_consumes_source?) ; `src/mir/control_flow.rb:1564` (promote_value_to_heap!) ; `src/mir/control_flow.rb:1973` (_collect_share_moves) ; `src/mir/mir_lowering.rb:273` (container_borrow_expr?) ; `src/mir/mir_lowering.rb:851` (build_drop_entry!) ; `src/mir/mir_pass.rb:804` (stamp_reassign_cleanup!)
- **[case_dispatch]** support=7 scatter=7 rank=49
  - tuple: `AST::GetField | AST::GetIndex | AST::Identifier`
  - `src/annotator-helpers/capabilities.rb:743` (cap_var_name) ; `src/annotator.rb:1291` (ifbind_source_root) ; `src/ast/parser.rb:3921` (deep_clone_node) ; `src/backends/pipeline_host.rb:4503` (target_rooted_at_placeholder?) ; `src/mir/control_flow.rb:1771` (cap_source_name) ; `src/mir/escape_analysis.rb:648` (e2_root_ident)
- **[conjunction]** support=7 scatter=7 rank=49
  - tuple: `!schema[:kind] | schema.is_a?(Hash)`
  - `src/annotator-helpers/function_analysis.rb:728` (declare_and_verify_params) ; `src/ast/type.rb:1462` (implicitly_copyable?) ; `src/ast/type.rb:1489` (needs_promotion?) ; `src/ast/type.rb:1510` (needs_cleanup?) ; `src/ast/type.rb:1550` (needs_explicit_cleanup?) ; `src/ast/type.rb:1571` (elem_has_heap_internals?)
- **[case_dispatch]** support=7 scatter=7 rank=49
  - tuple: `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
  - `src/tools/formatter.rb:477` (match_block_start?) ; `src/tools/formatter.rb:603` (build_match_arm) ; `src/tools/formatter.rb:703` (emit_match_body) ; `src/tools/formatter.rb:1070` (find_fn_arrow) ; `src/tools/formatter.rb:1654` (find_concurrent_stage_end) ; `src/tools/formatter.rb:2039` (count_statements_in_block)
- **[case_dispatch]** support=7 scatter=7 rank=49
  - tuple: `'(' | ')' | '[' | ']' | '{' | '}'`
  - `src/tools/formatter.rb:503` (find_match_block_end) ; `src/tools/formatter.rb:1135` (branch_end_for_inline_expansion) ; `src/tools/formatter.rb:1179` (matching_end) ; `src/tools/formatter.rb:1553` (consume_on_segment) ; `src/tools/formatter.rb:1701` (expand_method_chains) ; `src/tools/formatter.rb:1994` (body_has_top_level_block?)
- **[conjunction]** support=7 scatter=6 rank=42
  - tuple: `var_data.is_a?(Hash) | var_data[:kind] == :inline_struct`
  - `src/annotator-helpers/union.rb:162` (validate_union_schema!) ; `src/annotator.rb:1151` (visit_UnionDef) ; `src/mir/mir_lowering.rb:981` (lower_union_def) ; `src/mir/mir_lowering.rb:1044` (lower_union_def) ; `src/mir/mir_lowering.rb:4519` (visible_type_defs) ; `src/mir/mir_lowering.rb:4972` (unit_variant_access)
- **[case_dispatch]** support=7 scatter=6 rank=42
  - tuple: `AST::FuncCall | AST::MethodCall`
  - `src/mir/control_flow.rb:1422` (escapes_to_outer?) ; `src/mir/control_flow.rb:1474` (promote_outer_mutations!) ; `src/mir/control_flow.rb:1704` (key_allocates_frame?) ; `src/mir/escape_analysis.rb:127` (return_expr_is_heap?) ; `src/mir/escape_analysis.rb:139` (return_expr_is_heap?) ; `src/mir/escape_analysis.rb:232` (per_fn_scan!)
- **[conjunction]** support=6 scatter=6 rank=36
  - tuple: `entry | entry[:needs_cleanup]`
  - `src/mir/mir_lowering.rb:1381` (lower_function_def) ; `src/mir/mir_pass.rb:180` (transform_function!) ; `src/mir/mir_pass.rb:234` (walk_for_bg_captures) ; `src/mir/mir_pass.rb:431` (insert_bg_give_suppress!) ; `src/mir/mir_pass.rb:853` (stamp_while_bind_cleanup!) ; `src/mir/mir_pass.rb:867` (stamp_if_bind_cleanup!)
- **[conjunction]** support=6 scatter=6 rank=36
  - tuple: `bdepth.zero? | t.type == :KEYWORD`
  - `src/tools/formatter.rb:507` (find_match_block_end) ; `src/tools/formatter.rb:570` (scan_match_arms) ; `src/tools/formatter.rb:609` (build_match_arm) ; `src/tools/formatter.rb:714` (emit_match_body) ; `src/tools/formatter.rb:1139` (branch_end_for_inline_expansion) ; `src/tools/formatter.rb:1183` (matching_end)
- **[conjunction]** support=6 scatter=6 rank=36
  - tuple: `out.last | out.last.type == :NL`
  - `src/tools/formatter.rb:649` (emit_match_arm) ; `src/tools/formatter.rb:698` (emit_match_body) ; `src/tools/formatter.rb:1289` (expand_if_while_for) ; `src/tools/formatter.rb:1462` (emit_with_block) ; `src/tools/formatter.rb:1940` (emit_wrapped_args) ; `src/tools/formatter.rb:2396` (insert_nl)
- **[case_dispatch]** support=10 scatter=3 rank=30
  - tuple: `AST::GetField | AST::MethodCall`
  - `src/annotator.rb:1453` (visit_MatchStatement) ; `src/annotator.rb:1562` (visit_MatchStatement) ; `src/annotator.rb:1583` (visit_MatchStatement) ; `src/annotator.rb:1633` (visit_MatchStatement) ; `src/annotator.rb:1648` (visit_MatchStatement) ; `src/annotator.rb:1724` (visit_MatchStatement)
- **[case_dispatch]** support=5 scatter=5 rank=25
  - tuple: `:multiowned | :shared`
  - `src/annotator-helpers/capabilities.rb:105` (cap_var_storage) ; `src/mir/bg_capture_classifier.rb:142` (resolve_capture_type) ; `src/mir/mir_lowering.rb:2520` (with_cap_sync_storage) ; `src/mir/mir_lowering.rb:5840` (lower_cap_wrap) ; `src/mir/mir_lowering.rb:5976` (compose_capability_wrap)
- **[conjunction]** support=5 scatter=5 rank=25
  - tuple: `node.is_a?(AST::BinaryOp) | node.op == :SMOOTH`
  - `src/annotator.rb:1067` (collect_pipe_input_types) ; `src/backends/pipeline_host.rb:2142` (unwrap_range_chain) ; `src/backends/pipeline_host.rb:2170` (unwrap_binding_unnest_chain) ; `src/backends/pipeline_rewriter.rb:40` (rewrite!) ; `src/backends/pipeline_rewriter.rb:266` (binding_source?)
- **[case_dispatch]** support=5 scatter=5 rank=25
  - tuple: `AST::ForEach | AST::ForRange | AST::IfStatement | AST::WhileBindLoop | AST::WhileLoop | AST::WithBlock`
  - `src/mir/fsm_transform/recursive_splitter.rb:275` (stmt_introduces_split?) ; `src/mir/fsm_transform/recursive_splitter.rb:298` (contains_suspend_anywhere?) ; `src/mir/fsm_transform/recursive_splitter.rb:405` (emit_pivot) ; `src/mir/fsm_transform.rb:215` (body_needs_conservative?) ; `src/mir/fsm_transform.rb:238` (contains_suspend_anywhere?)
- **[case_dispatch]** support=5 scatter=5 rank=25
  - tuple: `'END' | 'FN' | 'FOR' | 'IF' | 'START' | 'TEST' | 'WHEN' | 'WHILE'`
  - `src/tools/formatter.rb:508` (find_match_block_end) ; `src/tools/formatter.rb:571` (scan_match_arms) ; `src/tools/formatter.rb:610` (build_match_arm) ; `src/tools/formatter.rb:715` (emit_match_body) ; `src/tools/formatter.rb:1184` (matching_end)
- **[case_dispatch]** support=5 scatter=5 rank=25
  - tuple: `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
  - `src/tools/formatter.rb:556` (scan_match_arms) ; `src/tools/formatter.rb:911` (emit_fn_signature_wrapped) ; `src/tools/formatter.rb:1019` (emit_fn_params_only_wrapped) ; `src/tools/formatter.rb:1630` (count_depth0_commas) ; `src/tools/formatter.rb:1923` (emit_wrapped_args)
- **[case_dispatch]** support=5 scatter=4 rank=20
  - tuple: `AST::Assignment | AST::BindExpr | AST::VarDecl`
  - `src/mir/escape_analysis.rb:668` (tag_transitive_provenance!) ; `src/mir/fsm_transform/liveness.rb:197` (collect_defs) ; `src/mir/mir_pass.rb:700` (collect_consumed_names) ; `src/mir/mir_pass.rb:730` (collect_consumed_names) ; `src/tools/migration_suggester_helpers.rb:88` (walk_recursive)
- **[case_dispatch]** support=4 scatter=4 rank=16
  - tuple: `:always_mutable | :atomic | :local | :locked | :versioned | :write_locked`
  - `src/annotator-helpers/generic_analysis.rb:474` (generic_binding_source) ; `src/annotator-helpers/generic_analysis.rb:493` (shared_call_capability_display) ; `src/annotator.rb:2279` (type_display) ; `src/ast/parser.rb:2937` (type_annotation_source)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `%w[true TRUE].include?(node.right.options["parallel"].name) | node.right.options["parallel"].is_a?(AST::Identifier)`
  - `src/annotator-helpers/pipe_analysis.rb:1605` (analyze_concurrent_bounded_select_family_op) ; `src/annotator-helpers/pipe_analysis.rb:1638` (analyze_concurrent_bounded_each_op) ; `src/annotator-helpers/pipe_analysis.rb:1668` (analyze_concurrent_stream_select_family_op) ; `src/annotator-helpers/pipe_analysis.rb:1704` (analyze_concurrent_stream_each_op)
- **[case_dispatch]** support=4 scatter=4 rank=16
  - tuple: `AST::BindExpr | AST::VarDecl`
  - `src/mir/control_flow.rb:1358` (collect_local_names) ; `src/mir/control_flow.rb:1397` (local_frame_decls) ; `src/mir/control_flow.rb:1463` (promote_outer_mutations!) ; `src/mir/escape_analysis.rb:876` (e3_find_decl)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `Type.new(expr_type).zig_type == "void" | expr_type.respond_to?(:to_s)`
  - `src/mir/fsm_lowering.rb:124` (lower_step_stmts) ; `src/mir/fsm_lowering.rb:203` (wrap_step_as_stmt) ; `src/mir/mir_lowering.rb:3735` (lower_do_block) ; `src/mir/mir_lowering.rb:3911` (lower_bg_block)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `!ti.string? | ti.array?`
  - `src/mir/mir_lowering.rb:275` (container_borrow_expr?) ; `src/mir/mir_lowering.rb:7421` (direct_indexable_collection_type?) ; `src/mir/mir_lowering.rb:7462` (lower_direct_length) ; `src/mir/promotion_plan.rb:516` (takes_param_base_entry)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `out.last | out.last.type == :NL | out.length > body_start`
  - `src/tools/formatter.rb:839` (emit_fn_block) ; `src/tools/formatter.rb:1338` (expand_if_while_for) ; `src/tools/formatter.rb:2117` (emit_bg_do_wrapped) ; `src/tools/formatter.rb:2382` (emit_record_type)
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `j < toks.length | toks[j].type == :NL`
  - `src/tools/formatter.rb:851` (skip_nls) ; `src/tools/formatter.rb:2232` (detect_recover_stages) ; `src/tools/formatter.rb:2374` (emit_record_type) ; `src/tools/formatter.rb:2417` (emit_stmt_terminator)
- ...(+192 more)

## Reification Misses (129)
_an existing predicate reinvented inline -- invariant #16_

- predicate `atomic?` reinvented inline at `src/annotator-helpers/capabilities.rb:1091` (_unified_capture_walk) (`info.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator-helpers/capabilities.rb:1133` (_unified_capture_walk) (`info.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator-helpers/fixable_helpers.rb:1303` (build_atomic_escape_migration_fix) (`source_sym.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator-helpers/function_analysis.rb:553` (atomic_cell_to_atomic_param?) (`ptype.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator-helpers/function_analysis.rb:573` (explicit_primitive_atomic_param?) (`type.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator-helpers/generic_analysis.rb:89` (validate_type_annotation!) (`type_obj.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator-helpers/lock_helper.rb:400` (verify_handler_reachability!) (`sym.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:3131` (visit_Assignment) (`sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:3407` (visit_GetField) (`sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:4115` (visit_CapabilityWrap) (`node.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:4120` (visit_CapabilityWrap) (`node.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:4131` (visit_CapabilityWrap) (`node.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:4137` (visit_CapabilityWrap) (`node.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:4152` (visit_CapabilityWrap) (`node.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:4824` (validate_lock_error_clause!) (`sym.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:4898` (reject_bare_atomic_ptr_mutation!) (`sym.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:4975` (cap_admits_atomic?) (`sym.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:6149` (bg_capture_independent?) (`info.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/ast/parser.rb:2902` (parse_type_annotation) (`sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/ast/scope.rb:176` (resolve_full_type) (`entry.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/ast/type.rb:2142` (compute_zig_type) (`@sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/ast/type.rb:2144` (compute_zig_type) (`@sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/ast/type.rb:2154` (compute_zig_type) (`@sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/mir/control_flow.rb:895` (copy_type?) (`ti.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/mir/control_flow.rb:2022` (copy_type?) (`ti.sync == :atomic`)
- ...(+104 more)

## Semantic Predicate Aliases (3)
_one decision, multiple names (receiver/polarity folded)_

- `needs_capture_site_annotation? = mir? = stmt? = expr? = has_own_frame?` == `true`
  - `src/mir/capture_strategy.rb:79` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:95` (needs_capture_site_annotation?) ; `src/mir/mir.rb:27` (mir?) ; `src/mir/mir.rb:39` (stmt?) ; `src/mir/mir.rb:47` (expr?) ; `src/mir/mir.rb:75` (has_own_frame?) ; `src/mir/mir.rb:349` (expr?) ; `src/mir/mir.rb:402` (expr?) ; `src/mir/mir.rb:416` (expr?) ; `src/mir/mir.rb:532` (expr?) ; `src/mir/mir.rb:543` (expr?) ; `src/mir/mir.rb:558` (expr?) ; `src/mir/mir.rb:594` (expr?) ; `src/mir/mir.rb:1244` (stmt?) ; `src/mir/mir.rb:1276` (stmt?) ; `src/mir/mir.rb:1298` (stmt?) ; `src/mir/mir.rb:1325` (stmt?) ; `src/mir/mir.rb:1334` (stmt?) ; `src/mir/mir.rb:1348` (stmt?) ; `src/mir/mir.rb:1360` (stmt?) ; `src/mir/mir.rb:1368` (stmt?) ; `src/mir/mir.rb:1377` (stmt?) ; `src/mir/mir.rb:1385` (stmt?) ; `src/mir/mir.rb:1393` (stmt?) ; `src/mir/mir.rb:1665` (expr?) ; `src/mir/mir.rb:1745` (expr?) ; `src/mir/mir.rb:1789` (expr?)
- `wildcard? = needs_capture_site_annotation? = stmt? = expr?` == `false`
  - `src/ast/ast.rb:723` (wildcard?) ; `src/ast/ast.rb:818` (wildcard?) ; `src/ast/ast.rb:833` (wildcard?) ; `src/mir/capture_strategy.rb:51` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:64` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:108` (needs_capture_site_annotation?) ; `src/mir/mir.rb:29` (stmt?) ; `src/mir/mir.rb:31` (expr?)
- `auto? = auto_type?` == `t.is_a?(Type) && t.auto?`
  - `src/annotator-helpers/auto_inference.rb:98` (auto?) ; `src/annotator-helpers/auto_inference.rb:787` (auto?) ; `src/backends/importer.rb:159` (auto_type?)

## Exact Predicate Aliases (7)
_identical one-line predicate body under >=2 names_

- `needs_cleanup = needs_capture_site_annotation? = mir? = stmt? = expr? = has_own_frame?` == `true`
  - `src/ast/ast.rb:1396` (needs_cleanup) ; `src/mir/capture_strategy.rb:79` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:95` (needs_capture_site_annotation?) ; `src/mir/mir.rb:27` (mir?) ; `src/mir/mir.rb:39` (stmt?) ; `src/mir/mir.rb:47` (expr?) ; `src/mir/mir.rb:75` (has_own_frame?) ; `src/mir/mir.rb:349` (expr?) ; `src/mir/mir.rb:402` (expr?) ; `src/mir/mir.rb:416` (expr?) ; `src/mir/mir.rb:532` (expr?) ; `src/mir/mir.rb:543` (expr?) ; `src/mir/mir.rb:558` (expr?) ; `src/mir/mir.rb:594` (expr?) ; `src/mir/mir.rb:1244` (stmt?) ; `src/mir/mir.rb:1276` (stmt?) ; `src/mir/mir.rb:1298` (stmt?) ; `src/mir/mir.rb:1325` (stmt?) ; `src/mir/mir.rb:1334` (stmt?) ; `src/mir/mir.rb:1348` (stmt?) ; `src/mir/mir.rb:1360` (stmt?) ; `src/mir/mir.rb:1368` (stmt?) ; `src/mir/mir.rb:1377` (stmt?) ; `src/mir/mir.rb:1385` (stmt?) ; `src/mir/mir.rb:1393` (stmt?) ; `src/mir/mir.rb:1665` (expr?) ; `src/mir/mir.rb:1745` (expr?) ; `src/mir/mir.rb:1789` (expr?)
- `visit_PassStmt = visit_OrRaise = visit_OrBreak = visit_OrPass = visit_OrPrune` == `node.full_type = :Void`
  - `src/annotator.rb:1413` (visit_PassStmt) ; `src/annotator.rb:4069` (visit_OrRaise) ; `src/annotator.rb:4074` (visit_OrBreak) ; `src/annotator.rb:4079` (visit_OrPass) ; `src/annotator.rb:4086` (visit_OrPrune)
- `wildcard? = needs_capture_site_annotation? = stmt? = expr?` == `false`
  - `src/ast/ast.rb:723` (wildcard?) ; `src/ast/ast.rb:818` (wildcard?) ; `src/ast/ast.rb:833` (wildcard?) ; `src/mir/capture_strategy.rb:51` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:64` (needs_capture_site_annotation?) ; `src/mir/capture_strategy.rb:108` (needs_capture_site_annotation?) ; `src/mir/mir.rb:29` (stmt?) ; `src/mir/mir.rb:31` (expr?)
- `emit_rc_retain = emit_rc_downgrade = emit_weak_upgrade` == `"CheatLib.#{node.func}(#{node.zig_base}, #{emit(node.source)})"`
  - `src/mir/mir_emitter.rb:1260` (emit_rc_retain) ; `src/mir/mir_emitter.rb:1265` (emit_rc_downgrade) ; `src/mir/mir_emitter.rb:1270` (emit_weak_upgrade)
- `auto? = auto_type?` == `t.is_a?(Type) && t.auto?`
  - `src/annotator-helpers/auto_inference.rb:98` (auto?) ; `src/annotator-helpers/auto_inference.rb:787` (auto?) ; `src/backends/importer.rb:159` (auto_type?)
- `child_bodies = marker_plan` == `[]`
  - `src/ast/ast.rb:195` (child_bodies) ; `src/mir/capture_strategy.rb:49` (marker_plan) ; `src/mir/capture_strategy.rb:62` (marker_plan) ; `src/mir/capture_strategy.rb:106` (marker_plan)
- `full_type = type_info` == `@type_object`
  - `src/ast/ast.rb:316` (full_type) ; `src/ast/ast.rb:495` (type_info)

## Type-3 Clones (missed rename) (14)
_pasted block, one identifier inconsistently renamed -- *POSSIBLE* bug_

- *POSSIBLE* `src/tools/formatter.rb:705` (emit_match_body) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:801` (emit_fn_block) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:813` (emit_fn_block) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:913` (emit_fn_signature_wrapped) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1021` (emit_fn_params_only_wrapped) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1273` (expand_if_while_for) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1275` (expand_if_while_for) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1277` (expand_if_while_for) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:1925` (emit_wrapped_args) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2093` (emit_bg_do_wrapped) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2364` (emit_record_type) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2368` (emit_record_type) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/tools/formatter.rb:2370` (emit_record_type) clone of `src/tools/formatter.rb:704` (emit_match_body): ref var `+` spelled ["-", "+"] here
- *POSSIBLE* `src/annotator.rb:4052` (visit_OrRescue) clone of `src/annotator.rb:4038` (visit_OrRescue): ref var `payload_type` spelled ["wrapped", "wrapped_type"] here

## Neglected Updates (6090)
_co-written state, one write missing -- *POSSIBLE* redundant-state desync_

- *POSSIBLE* (support=52) `src/annotator-helpers/function_analysis.rb:140` (resolve_call) writes `.full_type` but NOT `.storage` (recv `args[i]`)
- *POSSIBLE* (support=52) `src/annotator-helpers/function_analysis.rb:740` (declare_and_verify_params) writes `.full_type` but NOT `.storage` (recv `param[:default]`)
- *POSSIBLE* (support=52) `src/annotator-helpers/generic_analysis.rb:544` (propagate_declared_type_to_value!) writes `.full_type` but NOT `.storage` (recv `node.value`)
- *POSSIBLE* (support=52) `src/annotator-helpers/method_analysis.rb:52` (narrow_collection_type!) writes `.full_type` but NOT `.storage` (recv `list_arg`)
- *POSSIBLE* (support=52) `src/annotator-helpers/method_analysis.rb:89` (resolve_typed_method) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/pipe_analysis.rb:31` (visit_Smooth) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/pipe_analysis.rb:87` (lift_to_observable_if_terminal!) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/pipe_analysis.rb:726` (analyze_pipe_to_func_call) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/pipe_analysis.rb:747` (analyze_pipe_to_identifier) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/pipe_analysis.rb:788` (analyze_pipe_to_named_function) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/pipe_analysis.rb:1257` (auto_detect_sharded_access) writes `.full_type` but NOT `.storage` (recv `map_ident`)
- *POSSIBLE* (support=52) `src/annotator-helpers/test_annotation.rb:37` (visit_TestBlock) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/test_annotation.rb:63` (visit_WhenBlock) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/test_annotation.rb:106` (visit_TestThat) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/test_annotation.rb:113` (visit_AssertRaises) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/test_annotation.rb:120` (visit_BenchmarkStmt) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/test_annotation.rb:127` (visit_SmashStmt) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/test_annotation.rb:134` (visit_ProfileStmt) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/test_annotation.rb:151` (visit_StubDecl) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator-helpers/union.rb:112` (resolve_variant_access) writes `.full_type` but NOT `.storage` (recv `node.target`)
- *POSSIBLE* (support=52) `src/annotator.rb:479` (visit_Program) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator.rb:498` (visit_RequireNode) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator.rb:573` (visit_ExternFnDecl) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator.rb:594` (visit_ExternStructDecl) writes `.full_type` but NOT `.storage` (recv `node`)
- *POSSIBLE* (support=52) `src/annotator.rb:644` (visit_LambdaLit) writes `.full_type` but NOT `.storage` (recv `node`)
- ...(+6065 more)

## Derived-State Staleness (222)
_b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug_

- *POSSIBLE* `src/mir/mir_lowering.rb:5996` (lower_var_decl): `is_mutable` derived from `ft` (line 5996); `ft` reassigned line 6175, `is_mutable` not recomputed
- *POSSIBLE* `src/mir/mir_lowering.rb:5997` (lower_var_decl): `is_mutable` derived from `ft` (line 5997); `ft` reassigned line 6175, `is_mutable` not recomputed
- *POSSIBLE* `src/mir/mir_lowering.rb:5998` (lower_var_decl): `is_mutable` derived from `ft` (line 5998); `ft` reassigned line 6175, `is_mutable` not recomputed
- *POSSIBLE* `src/mir/mir_lowering.rb:5999` (lower_var_decl): `is_mutable` derived from `ft` (line 5999); `ft` reassigned line 6175, `is_mutable` not recomputed
- *POSSIBLE* `src/mir/mir_lowering.rb:6010` (lower_var_decl): `copy_decl_needs_drop` derived from `ft` (line 6010); `ft` reassigned line 6175, `copy_decl_needs_drop` not recomputed
- *POSSIBLE* `src/mir/mir_lowering.rb:6015` (lower_var_decl): `has_mutable_cleanup` derived from `ft` (line 6015); `ft` reassigned line 6175, `has_mutable_cleanup` not recomputed
- *POSSIBLE* `src/mir/mir_lowering.rb:6031` (lower_var_decl): `needs_annotation` derived from `ft` (line 6031); `ft` reassigned line 6175, `needs_annotation` not recomputed
- *POSSIBLE* `src/mir/mir_lowering.rb:6051` (lower_var_decl): `has_caps` derived from `ft` (line 6051); `ft` reassigned line 6175, `has_caps` not recomputed
- *POSSIBLE* `src/mir/mir_lowering.rb:6052` (lower_var_decl): `bare_ft` derived from `ft` (line 6052); `ft` reassigned line 6175, `bare_ft` not recomputed
- *POSSIBLE* `src/mir/mir_lowering.rb:6055` (lower_var_decl): `init` derived from `ft` (line 6055); `ft` reassigned line 6175, `init` not recomputed
- *POSSIBLE* `src/mir/mir_lowering.rb:6056` (lower_var_decl): `cap` derived from `ft` (line 6056); `ft` reassigned line 6175, `cap` not recomputed
- *POSSIBLE* `src/mir/mir_lowering.rb:6090` (lower_var_decl): `inner` derived from `ft` (line 6090); `ft` reassigned line 6175, `inner` not recomputed
- *POSSIBLE* `src/ast/ast.rb:399` (finalize_storage!): `value_sync` derived from `vt` (line 399); `vt` reassigned line 476, `value_sync` not recomputed
- *POSSIBLE* `src/mir/mir_lowering.rb:6098` (lower_var_decl): `inner` derived from `ft` (line 6098); `ft` reassigned line 6175, `inner` not recomputed
- *POSSIBLE* `src/mir/mir_lowering.rb:7184` (lower_return): `stmts` derived from `value` (line 7184); `value` reassigned line 7252, `stmts` not recomputed
- *POSSIBLE* `src/tools/doctor.rb:158` (section_heap): `addrs` derived from `sites` (line 158); `sites` reassigned line 218, `addrs` not recomputed
- *POSSIBLE* `src/ast/type.rb:2128` (compute_zig_type): `inner_zig` derived from `base_zig` (line 2128); `base_zig` reassigned line 2186, `inner_zig` not recomputed
- *POSSIBLE* `src/annotator.rb:2105` (visit_ReturnNode): `expected_void_compatible` derived from `expected` (line 2105); `expected` reassigned line 2159, `expected_void_compatible` not recomputed
- *POSSIBLE* `src/mir/mir_lowering.rb:6055` (lower_var_decl): `init` derived from `is_move` (line 6055); `is_move` reassigned line 6102, `init` not recomputed
- *POSSIBLE* `src/annotator-helpers/capabilities.rb:204` (validate_capability): `atomic_ptr_ok` derived from `syn` (line 204); `syn` reassigned line 249, `atomic_ptr_ok` not recomputed
- *POSSIBLE* `src/tools/formatter.rb:2747` (needs_space?): `a_is_struct_open` derived from `a_idx` (line 2747); `a_idx` reassigned line 2791, `a_is_struct_open` not recomputed
- *POSSIBLE* `src/mir/mir_lowering.rb:4890` (lower_binary_op): `left_is_comptime` derived from `left_ti` (line 4890); `left_ti` reassigned line 4928, `left_is_comptime` not recomputed
- *POSSIBLE* `src/mir/mir_lowering.rb:4891` (lower_binary_op): `right_is_comptime` derived from `right_ti` (line 4891); `right_ti` reassigned line 4929, `right_is_comptime` not recomputed
- *POSSIBLE* `src/mir/mir_lowering.rb:4892` (lower_binary_op): `both_int` derived from `right_ti` (line 4892); `right_ti` reassigned line 4929, `both_int` not recomputed
- *POSSIBLE* `src/mir/mir_lowering.rb:2325` (lower_list_lit): `promise_zig` derived from `elem_zig` (line 2325); `elem_zig` reassigned line 2361, `promise_zig` not recomputed
- ...(+197 more)

## Neglected Conditions (47)
_dispatch/conjunction minus one element -- *POSSIBLE* bug_

- *POSSIBLE* (support=7) `src/mir/control_flow.rb:1540` (promote_outer_field_assigns!) -- MISSING `AST::Identifier` from `AST::GetField | AST::GetIndex | AST::Identifier`
- *POSSIBLE* (support=7) `src/mir/mir_lowering.rb:2570` (build_field_path_zig) -- MISSING `AST::GetIndex` from `AST::GetField | AST::GetIndex | AST::Identifier`
- *POSSIBLE* (support=7) `src/tools/formatter.rb:503` (find_match_block_end) -- MISSING `';'` from `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=7) `src/tools/formatter.rb:1135` (branch_end_for_inline_expansion) -- MISSING `';'` from `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=7) `src/tools/formatter.rb:1179` (matching_end) -- MISSING `';'` from `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=7) `src/tools/formatter.rb:1493` (find_with_open_brace) -- MISSING `'}'` from `'(' | ')' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=7) `src/tools/formatter.rb:1553` (consume_on_segment) -- MISSING `';'` from `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=7) `src/tools/formatter.rb:1701` (expand_method_chains) -- MISSING `';'` from `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=7) `src/tools/formatter.rb:1994` (body_has_top_level_block?) -- MISSING `';'` from `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=7) `src/tools/formatter.rb:2137` (bg_body_has_strategy_arrow?) -- MISSING `';'` from `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=5) `src/mir/control_flow.rb:1358` (collect_local_names) -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=5) `src/mir/control_flow.rb:1397` (local_frame_decls) -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=5) `src/mir/control_flow.rb:1463` (promote_outer_mutations!) -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=5) `src/mir/escape_analysis.rb:876` (e3_find_decl) -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=5) `src/tools/atomic_migration_suggester.rb:129` (stmt_eligible?) -- MISSING `AST::VarDecl` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=5) `src/tools/atomic_ptr_migration_suggester.rb:122` (stmt_eligible?) -- MISSING `AST::VarDecl` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- *POSSIBLE* (support=5) `src/tools/formatter.rb:503` (find_match_block_end) -- MISSING `','` from `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=5) `src/tools/formatter.rb:1135` (branch_end_for_inline_expansion) -- MISSING `','` from `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=5) `src/tools/formatter.rb:1179` (matching_end) -- MISSING `','` from `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=5) `src/tools/formatter.rb:1208` (one_liner_end) -- MISSING `'START'` from `'END' | 'FN' | 'FOR' | 'IF' | 'START' | 'TEST' | 'WHEN' | 'WHILE'`
- *POSSIBLE* (support=5) `src/tools/formatter.rb:1280` (expand_if_while_for) -- MISSING `'START'` from `'END' | 'FN' | 'FOR' | 'IF' | 'START' | 'TEST' | 'WHEN' | 'WHILE'`
- *POSSIBLE* (support=5) `src/tools/formatter.rb:1553` (consume_on_segment) -- MISSING `','` from `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=5) `src/tools/formatter.rb:1701` (expand_method_chains) -- MISSING `','` from `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=5) `src/tools/formatter.rb:1994` (body_has_top_level_block?) -- MISSING `','` from `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
- *POSSIBLE* (support=5) `src/tools/formatter.rb:2137` (bg_body_has_strategy_arrow?) -- MISSING `','` from `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
- ...(+22 more)

## Neglected Path Conditions (2203)
_nested-if/&& guard set minus one atom -- *POSSIBLE* bug (noisy)_

- *POSSIBLE* (support=39) `src/mir/mir_lowering.rb:6972` (lower_for_range) -- MISSING `node.mark_per_iter` from `!node.tight | @current_fn_has_rt | node.mark_per_iter`
- *POSSIBLE* (support=39) `src/mir/mir_lowering.rb:6972` (lower_for_range) -- MISSING `node.mark_per_iter` from `!node.tight | @current_fn_has_rt | node.mark_per_iter`
- *POSSIBLE* (support=39) `src/mir/mir_lowering.rb:6972` (lower_for_range) -- MISSING `node.mark_per_iter` from `!node.tight | @current_fn_has_rt | node.mark_per_iter`
- *POSSIBLE* (support=29) `src/annotator-helpers/function_analysis.rb:183` (resolve_call) -- MISSING `inner.is_a?(Type)` from `!func_type == :Intrinsic | !type_params&.any? | func_type.is_a?(FunctionSignature) | inner.is_a?(Type) | node.full_type.error_union? | node.full_type.is_a?(Type) | node.full_type.respond_to?(:error_union?)`
- *POSSIBLE* (support=29) `src/annotator-helpers/function_analysis.rb:184` (resolve_call) -- MISSING `inner.is_a?(Type)` from `!func_type == :Intrinsic | !type_params&.any? | func_type.is_a?(FunctionSignature) | inner.is_a?(Type) | node.full_type.error_union? | node.full_type.is_a?(Type) | node.full_type.respond_to?(:error_union?)`
- *POSSIBLE* (support=29) `src/annotator-helpers/function_analysis.rb:184` (resolve_call) -- MISSING `inner.is_a?(Type)` from `!func_type == :Intrinsic | !type_params&.any? | func_type.is_a?(FunctionSignature) | inner.is_a?(Type) | node.full_type.error_union? | node.full_type.is_a?(Type) | node.full_type.respond_to?(:error_union?)`
- *POSSIBLE* (support=29) `src/annotator-helpers/function_analysis.rb:185` (resolve_call) -- MISSING `inner.is_a?(Type)` from `!func_type == :Intrinsic | !type_params&.any? | func_type.is_a?(FunctionSignature) | inner.is_a?(Type) | node.full_type.error_union? | node.full_type.is_a?(Type) | node.full_type.respond_to?(:error_union?)`
- *POSSIBLE* (support=29) `src/annotator-helpers/function_analysis.rb:185` (resolve_call) -- MISSING `inner.is_a?(Type)` from `!func_type == :Intrinsic | !type_params&.any? | func_type.is_a?(FunctionSignature) | inner.is_a?(Type) | node.full_type.error_union? | node.full_type.is_a?(Type) | node.full_type.respond_to?(:error_union?)`
- *POSSIBLE* (support=29) `src/annotator-helpers/function_analysis.rb:192` (resolve_call) -- MISSING `inner.is_a?(Type)` from `!func_type == :Intrinsic | !type_params&.any? | func_type.is_a?(FunctionSignature) | inner.is_a?(Type) | node.full_type.error_union? | node.full_type.is_a?(Type) | node.full_type.respond_to?(:error_union?)`
- *POSSIBLE* (support=29) `src/annotator-helpers/function_analysis.rb:214` (resolve_call) -- MISSING `inner.is_a?(Type)` from `!func_type == :Intrinsic | !type_params&.any? | func_type.is_a?(FunctionSignature) | inner.is_a?(Type) | node.full_type.error_union? | node.full_type.is_a?(Type) | node.full_type.respond_to?(:error_union?)`
- *POSSIBLE* (support=28) `src/annotator-helpers/capabilities.rb:1083` (_unified_capture_walk) -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=28) `src/annotator-helpers/capabilities.rb:1090` (_unified_capture_walk) -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=28) `src/annotator-helpers/capabilities.rb:1090` (_unified_capture_walk) -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=28) `src/annotator-helpers/capabilities.rb:1118` (_unified_capture_walk) -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=28) `src/annotator-helpers/capabilities.rb:1122` (_unified_capture_walk) -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=28) `src/annotator-helpers/capabilities.rb:1122` (_unified_capture_walk) -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=28) `src/annotator-helpers/capabilities.rb:1123` (_unified_capture_walk) -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=28) `src/annotator-helpers/capabilities.rb:1123` (_unified_capture_walk) -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=28) `src/annotator-helpers/capabilities.rb:1124` (_unified_capture_walk) -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=28) `src/annotator-helpers/capabilities.rb:1130` (_unified_capture_walk) -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=28) `src/annotator-helpers/capabilities.rb:1130` (_unified_capture_walk) -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=28) `src/annotator-helpers/capabilities.rb:1130` (_unified_capture_walk) -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=28) `src/annotator-helpers/capabilities.rb:1130` (_unified_capture_walk) -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=28) `src/annotator-helpers/capabilities.rb:1133` (_unified_capture_walk) -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- *POSSIBLE* (support=28) `src/annotator-helpers/capabilities.rb:1133` (_unified_capture_walk) -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- ...(+2178 more)

## Broken Protocols (1730)
_co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)_

- *POSSIBLE* conf=0.99 support=78 `src/annotator-helpers/function_context.rb:15` ((top-level)) does `sig` without `returns`
- *POSSIBLE* conf=0.99 support=78 `src/annotator.rb:2225` (visit_ReturnNode) does `returns` without `extend`
- *POSSIBLE* conf=0.99 support=78 `src/annotator.rb:2225` (visit_ReturnNode) does `returns` without `sig`
- *POSSIBLE* conf=0.99 support=78 `src/mir/mir.rb:26` ((top-level)) does `sig` without `params`
- *POSSIBLE* conf=0.99 support=78 `src/mir/mir.rb:26` ((top-level)) does `sig` without `untyped`
- *POSSIBLE* conf=0.98 support=47 `src/ast/ast.rb:206` (column) does `column` without `line`
- *POSSIBLE* conf=0.98 support=43 `src/ast/parser.rb:1762` (parse_binary_op) does `parse_expression` without `consume`
- *POSSIBLE* conf=0.97 support=77 `src/annotator.rb:2225` (visit_ReturnNode) does `returns` without `params`
- *POSSIBLE* conf=0.97 support=77 `src/annotator.rb:2225` (visit_ReturnNode) does `returns` without `untyped`
- *POSSIBLE* conf=0.97 support=77 `src/mir/mir.rb:26` ((top-level)) does `returns` without `params`
- *POSSIBLE* conf=0.97 support=77 `src/mir/mir.rb:26` ((top-level)) does `returns` without `untyped`
- *POSSIBLE* conf=0.97 support=31 `src/annotator-helpers/function_context.rb:15` ((top-level)) does `void` without `returns`
- *POSSIBLE* conf=0.97 support=31 `src/mir/effect_set.rb:42` ((top-level)) does `void` without `nilable`
- *POSSIBLE* conf=0.97 support=30 `src/annotator.rb:5645` (promote_to_expr_if!) does `else_branch` without `then_branch`
- *POSSIBLE* conf=0.97 support=30 `src/mir/mir_pass.rb:874` (stamp_if_bind_cleanup!) does `then_branch` without `else_branch`
- *POSSIBLE* conf=0.97 support=29 `src/ast/scope.rb:86` (initialize_copy) does `capabilities` without `[]`
- *POSSIBLE* conf=0.96 support=43 `src/backends/pipeline_host.rb:3030` (default_obs_alloc_zig) does `transpile_type` without `new`
- *POSSIBLE* conf=0.96 support=43 `src/mir/mir_lowering.rb:7415` (bare_zig_type) does `transpile_type` without `new`
- *POSSIBLE* conf=0.96 support=25 `src/mir/escape_analysis.rb:437` (e2_walk_calls) does `walk_body` without `is_a?`
- *POSSIBLE* conf=0.95 support=79 `src/mir/thunk_transform.rb:21` ((top-level)) does `extend` without `sig`
- *POSSIBLE* conf=0.95 support=79 `src/opcodes.rb:6` ((top-level)) does `extend` without `sig`
- *POSSIBLE* conf=0.95 support=79 `src/tools/atomic_migration_suggester.rb:43` ((top-level)) does `extend` without `sig`
- *POSSIBLE* conf=0.95 support=79 `src/tools/atomic_ptr_migration_suggester.rb:39` ((top-level)) does `extend` without `sig`
- *POSSIBLE* conf=0.95 support=35 `src/ast/parser.rb:525` (match_literal!) does `match!` without `consume`
- *POSSIBLE* conf=0.95 support=35 `src/ast/parser.rb:3527` (parse_error_selectors) does `match!` without `consume`
- ...(+1705 more)

## Run Summary
- Files analyzed: 93
- Detectors: 11 (all shipped, self-tested)
- Total candidates: 10918
- Method: stdlib AST only, intra-procedural, zero deps, no CFG / no points-to (see docs/agents/design.md)
