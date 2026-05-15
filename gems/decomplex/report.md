# Decomplex Report

> Decision-level duplication and neglected-condition analysis.
> Every count is a ranked **candidate** list (Engler's discipline),
> not a verdict. Triage top-of-list first.

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Missing Abstractions (217)](#missing-abstractions-217)
- [Neglected Conditions (47)](#neglected-conditions-47)
- [Neglected Updates (6090)](#neglected-updates-6090)
- [Semantic Predicate Aliases (3)](#semantic-predicate-aliases-3)
- [Reification Misses (129)](#reification-misses-129)
- [Neglected Path Conditions (2203)](#neglected-path-conditions-2203)
- [Broken Protocols (1730)](#broken-protocols-1730)
- [Derived-State Staleness (222)](#derivedstate-staleness-222)
- [Type-3 Clones (missed rename) (14)](#type3-clones-missed-rename-14)
- [Exact Predicate Aliases (7)](#exact-predicate-aliases-7)
- [Run Summary](#run-summary)

## Project Prioritization
- [Neglected Updates (6090)](#neglected-updates-6090): co-written state, one write missing -- redundant-state desync
- [Neglected Path Conditions (2203)](#neglected-path-conditions-2203): nested-if/&& guard set minus one atom
- [Broken Protocols (1730)](#broken-protocols-1730): co-called pair, one site does A without B
- [Derived-State Staleness (222)](#derivedstate-staleness-222): b = f(a); a later reassigned, b not recomputed
- [Missing Abstractions (217)](#missing-abstractions-217): guard tuple recomputed across >=2 decision units
- [Reification Misses (129)](#reification-misses-129): an existing predicate reinvented inline -- invariant #16
- [Neglected Conditions (47)](#neglected-conditions-47): dispatch/conjunction minus one element -- likely bug
- [Type-3 Clones (missed rename) (14)](#type3-clones-missed-rename-14): pasted block, one identifier inconsistently renamed
- [Exact Predicate Aliases (7)](#exact-predicate-aliases-7): identical one-line predicate body under >=2 names
- [Semantic Predicate Aliases (3)](#semantic-predicate-aliases-3): one decision, multiple names (receiver/polarity folded)

## Missing Abstractions (217)
_guard tuple recomputed across >=2 decision units_

- **[conjunction]** support=14 scatter=14 rank=196
  - tuple: `schema.is_a?(Hash) | schema[:kind] == :union`
  - src/annotator-helpers/function_analysis.rb:resolve_call:257 ; src/annotator-helpers/union.rb:validate_union_schema!:148 ; src/annotator.rb:visit_MatchStatement:1427 ; src/annotator.rb:track_union_alias:3039 ; src/annotator.rb:visit_StructLit:3551 ; src/annotator.rb:visit_CopyNode:4292
- **[conjunction]** support=10 scatter=10 rank=100
  - tuple: `!ti.is_a?(Type) | ti`
  - src/annotator.rb:share_consumes_source?:6537 ; src/mir/control_flow.rb:promote_value_to_heap!:1564 ; src/mir/control_flow.rb:_collect_share_moves:1973 ; src/mir/mir_lowering.rb:container_borrow_expr?:273 ; src/mir/mir_lowering.rb:build_drop_entry!:851 ; src/mir/mir_pass.rb:stamp_reassign_cleanup!:804
- **[case_dispatch]** support=7 scatter=7 rank=49
  - tuple: `AST::GetField | AST::GetIndex | AST::Identifier`
  - src/annotator-helpers/capabilities.rb:cap_var_name:743 ; src/annotator.rb:ifbind_source_root:1291 ; src/ast/parser.rb:deep_clone_node:3921 ; src/backends/pipeline_host.rb:target_rooted_at_placeholder?:4503 ; src/mir/control_flow.rb:cap_source_name:1771 ; src/mir/escape_analysis.rb:e2_root_ident:648
- **[conjunction]** support=7 scatter=7 rank=49
  - tuple: `!schema[:kind] | schema.is_a?(Hash)`
  - src/annotator-helpers/function_analysis.rb:declare_and_verify_params:728 ; src/ast/type.rb:implicitly_copyable?:1462 ; src/ast/type.rb:needs_promotion?:1489 ; src/ast/type.rb:needs_cleanup?:1510 ; src/ast/type.rb:needs_explicit_cleanup?:1550 ; src/ast/type.rb:elem_has_heap_internals?:1571
- **[case_dispatch]** support=7 scatter=7 rank=49
  - tuple: `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
  - src/tools/formatter.rb:match_block_start?:477 ; src/tools/formatter.rb:build_match_arm:603 ; src/tools/formatter.rb:emit_match_body:703 ; src/tools/formatter.rb:find_fn_arrow:1070 ; src/tools/formatter.rb:find_concurrent_stage_end:1654 ; src/tools/formatter.rb:count_statements_in_block:2039
- **[case_dispatch]** support=7 scatter=7 rank=49
  - tuple: `'(' | ')' | '[' | ']' | '{' | '}'`
  - src/tools/formatter.rb:find_match_block_end:503 ; src/tools/formatter.rb:branch_end_for_inline_expansion:1135 ; src/tools/formatter.rb:matching_end:1179 ; src/tools/formatter.rb:consume_on_segment:1553 ; src/tools/formatter.rb:expand_method_chains:1701 ; src/tools/formatter.rb:body_has_top_level_block?:1994
- **[conjunction]** support=7 scatter=6 rank=42
  - tuple: `var_data.is_a?(Hash) | var_data[:kind] == :inline_struct`
  - src/annotator-helpers/union.rb:validate_union_schema!:162 ; src/annotator.rb:visit_UnionDef:1151 ; src/mir/mir_lowering.rb:lower_union_def:981 ; src/mir/mir_lowering.rb:lower_union_def:1044 ; src/mir/mir_lowering.rb:visible_type_defs:4519 ; src/mir/mir_lowering.rb:unit_variant_access:4972
- **[case_dispatch]** support=7 scatter=6 rank=42
  - tuple: `AST::FuncCall | AST::MethodCall`
  - src/mir/control_flow.rb:escapes_to_outer?:1422 ; src/mir/control_flow.rb:promote_outer_mutations!:1474 ; src/mir/control_flow.rb:key_allocates_frame?:1704 ; src/mir/escape_analysis.rb:return_expr_is_heap?:127 ; src/mir/escape_analysis.rb:return_expr_is_heap?:139 ; src/mir/escape_analysis.rb:per_fn_scan!:232
- **[conjunction]** support=6 scatter=6 rank=36
  - tuple: `entry | entry[:needs_cleanup]`
  - src/mir/mir_lowering.rb:lower_function_def:1381 ; src/mir/mir_pass.rb:transform_function!:180 ; src/mir/mir_pass.rb:walk_for_bg_captures:234 ; src/mir/mir_pass.rb:insert_bg_give_suppress!:431 ; src/mir/mir_pass.rb:stamp_while_bind_cleanup!:853 ; src/mir/mir_pass.rb:stamp_if_bind_cleanup!:867
- **[conjunction]** support=6 scatter=6 rank=36
  - tuple: `bdepth.zero? | t.type == :KEYWORD`
  - src/tools/formatter.rb:find_match_block_end:507 ; src/tools/formatter.rb:scan_match_arms:570 ; src/tools/formatter.rb:build_match_arm:609 ; src/tools/formatter.rb:emit_match_body:714 ; src/tools/formatter.rb:branch_end_for_inline_expansion:1139 ; src/tools/formatter.rb:matching_end:1183
- **[conjunction]** support=6 scatter=6 rank=36
  - tuple: `out.last | out.last.type == :NL`
  - src/tools/formatter.rb:emit_match_arm:649 ; src/tools/formatter.rb:emit_match_body:698 ; src/tools/formatter.rb:expand_if_while_for:1289 ; src/tools/formatter.rb:emit_with_block:1462 ; src/tools/formatter.rb:emit_wrapped_args:1940 ; src/tools/formatter.rb:insert_nl:2396
- **[case_dispatch]** support=10 scatter=3 rank=30
  - tuple: `AST::GetField | AST::MethodCall`
  - src/annotator.rb:visit_MatchStatement:1453 ; src/annotator.rb:visit_MatchStatement:1562 ; src/annotator.rb:visit_MatchStatement:1583 ; src/annotator.rb:visit_MatchStatement:1633 ; src/annotator.rb:visit_MatchStatement:1648 ; src/annotator.rb:visit_MatchStatement:1724
- **[case_dispatch]** support=5 scatter=5 rank=25
  - tuple: `:multiowned | :shared`
  - src/annotator-helpers/capabilities.rb:cap_var_storage:105 ; src/mir/bg_capture_classifier.rb:resolve_capture_type:142 ; src/mir/mir_lowering.rb:with_cap_sync_storage:2520 ; src/mir/mir_lowering.rb:lower_cap_wrap:5840 ; src/mir/mir_lowering.rb:compose_capability_wrap:5976
- **[conjunction]** support=5 scatter=5 rank=25
  - tuple: `node.is_a?(AST::BinaryOp) | node.op == :SMOOTH`
  - src/annotator.rb:collect_pipe_input_types:1067 ; src/backends/pipeline_host.rb:unwrap_range_chain:2142 ; src/backends/pipeline_host.rb:unwrap_binding_unnest_chain:2170 ; src/backends/pipeline_rewriter.rb:rewrite!:40 ; src/backends/pipeline_rewriter.rb:binding_source?:266
- **[case_dispatch]** support=5 scatter=5 rank=25
  - tuple: `AST::ForEach | AST::ForRange | AST::IfStatement | AST::WhileBindLoop | AST::WhileLoop | AST::WithBlock`
  - src/mir/fsm_transform/recursive_splitter.rb:stmt_introduces_split?:275 ; src/mir/fsm_transform/recursive_splitter.rb:contains_suspend_anywhere?:298 ; src/mir/fsm_transform/recursive_splitter.rb:emit_pivot:405 ; src/mir/fsm_transform.rb:body_needs_conservative?:215 ; src/mir/fsm_transform.rb:contains_suspend_anywhere?:238
- **[case_dispatch]** support=5 scatter=5 rank=25
  - tuple: `'END' | 'FN' | 'FOR' | 'IF' | 'START' | 'TEST' | 'WHEN' | 'WHILE'`
  - src/tools/formatter.rb:find_match_block_end:508 ; src/tools/formatter.rb:scan_match_arms:571 ; src/tools/formatter.rb:build_match_arm:610 ; src/tools/formatter.rb:emit_match_body:715 ; src/tools/formatter.rb:matching_end:1184
- **[case_dispatch]** support=5 scatter=5 rank=25
  - tuple: `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
  - src/tools/formatter.rb:scan_match_arms:556 ; src/tools/formatter.rb:emit_fn_signature_wrapped:911 ; src/tools/formatter.rb:emit_fn_params_only_wrapped:1019 ; src/tools/formatter.rb:count_depth0_commas:1630 ; src/tools/formatter.rb:emit_wrapped_args:1923
- **[case_dispatch]** support=5 scatter=4 rank=20
  - tuple: `AST::Assignment | AST::BindExpr | AST::VarDecl`
  - src/mir/escape_analysis.rb:tag_transitive_provenance!:668 ; src/mir/fsm_transform/liveness.rb:collect_defs:197 ; src/mir/mir_pass.rb:collect_consumed_names:700 ; src/mir/mir_pass.rb:collect_consumed_names:730 ; src/tools/migration_suggester_helpers.rb:walk_recursive:88
- **[case_dispatch]** support=4 scatter=4 rank=16
  - tuple: `:always_mutable | :atomic | :local | :locked | :versioned | :write_locked`
  - src/annotator-helpers/generic_analysis.rb:generic_binding_source:474 ; src/annotator-helpers/generic_analysis.rb:shared_call_capability_display:493 ; src/annotator.rb:type_display:2279 ; src/ast/parser.rb:type_annotation_source:2937
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `%w[true TRUE].include?(node.right.options["parallel"].name) | node.right.options["parallel"].is_a?(AST::Identifier)`
  - src/annotator-helpers/pipe_analysis.rb:analyze_concurrent_bounded_select_family_op:1605 ; src/annotator-helpers/pipe_analysis.rb:analyze_concurrent_bounded_each_op:1638 ; src/annotator-helpers/pipe_analysis.rb:analyze_concurrent_stream_select_family_op:1668 ; src/annotator-helpers/pipe_analysis.rb:analyze_concurrent_stream_each_op:1704
- **[case_dispatch]** support=4 scatter=4 rank=16
  - tuple: `AST::BindExpr | AST::VarDecl`
  - src/mir/control_flow.rb:collect_local_names:1358 ; src/mir/control_flow.rb:local_frame_decls:1397 ; src/mir/control_flow.rb:promote_outer_mutations!:1463 ; src/mir/escape_analysis.rb:e3_find_decl:876
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `Type.new(expr_type).zig_type == "void" | expr_type.respond_to?(:to_s)`
  - src/mir/fsm_lowering.rb:lower_step_stmts:124 ; src/mir/fsm_lowering.rb:wrap_step_as_stmt:203 ; src/mir/mir_lowering.rb:lower_do_block:3735 ; src/mir/mir_lowering.rb:lower_bg_block:3911
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `!ti.string? | ti.array?`
  - src/mir/mir_lowering.rb:container_borrow_expr?:275 ; src/mir/mir_lowering.rb:direct_indexable_collection_type?:7421 ; src/mir/mir_lowering.rb:lower_direct_length:7462 ; src/mir/promotion_plan.rb:takes_param_base_entry:516
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `out.last | out.last.type == :NL | out.length > body_start`
  - src/tools/formatter.rb:emit_fn_block:839 ; src/tools/formatter.rb:expand_if_while_for:1338 ; src/tools/formatter.rb:emit_bg_do_wrapped:2117 ; src/tools/formatter.rb:emit_record_type:2382
- **[conjunction]** support=4 scatter=4 rank=16
  - tuple: `j < toks.length | toks[j].type == :NL`
  - src/tools/formatter.rb:skip_nls:851 ; src/tools/formatter.rb:detect_recover_stages:2232 ; src/tools/formatter.rb:emit_record_type:2374 ; src/tools/formatter.rb:emit_stmt_terminator:2417
- ...(+192 more)

## Neglected Conditions (47)
_dispatch/conjunction minus one element -- likely bug_

- support=7 at `src/mir/control_flow.rb:promote_outer_field_assigns!:1540` -- MISSING `AST::Identifier` from `AST::GetField | AST::GetIndex | AST::Identifier`
- support=7 at `src/mir/mir_lowering.rb:build_field_path_zig:2570` -- MISSING `AST::GetIndex` from `AST::GetField | AST::GetIndex | AST::Identifier`
- support=7 at `src/tools/formatter.rb:find_match_block_end:503` -- MISSING `';'` from `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
- support=7 at `src/tools/formatter.rb:branch_end_for_inline_expansion:1135` -- MISSING `';'` from `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
- support=7 at `src/tools/formatter.rb:matching_end:1179` -- MISSING `';'` from `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
- support=7 at `src/tools/formatter.rb:find_with_open_brace:1493` -- MISSING `'}'` from `'(' | ')' | '[' | ']' | '{' | '}'`
- support=7 at `src/tools/formatter.rb:consume_on_segment:1553` -- MISSING `';'` from `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
- support=7 at `src/tools/formatter.rb:expand_method_chains:1701` -- MISSING `';'` from `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
- support=7 at `src/tools/formatter.rb:body_has_top_level_block?:1994` -- MISSING `';'` from `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
- support=7 at `src/tools/formatter.rb:bg_body_has_strategy_arrow?:2137` -- MISSING `';'` from `'(' | ')' | ';' | '[' | ']' | '{' | '}'`
- support=5 at `src/mir/control_flow.rb:collect_local_names:1358` -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- support=5 at `src/mir/control_flow.rb:local_frame_decls:1397` -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- support=5 at `src/mir/control_flow.rb:promote_outer_mutations!:1463` -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- support=5 at `src/mir/escape_analysis.rb:e3_find_decl:876` -- MISSING `AST::Assignment` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- support=5 at `src/tools/atomic_migration_suggester.rb:stmt_eligible?:129` -- MISSING `AST::VarDecl` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- support=5 at `src/tools/atomic_ptr_migration_suggester.rb:stmt_eligible?:122` -- MISSING `AST::VarDecl` from `AST::Assignment | AST::BindExpr | AST::VarDecl`
- support=5 at `src/tools/formatter.rb:find_match_block_end:503` -- MISSING `','` from `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
- support=5 at `src/tools/formatter.rb:branch_end_for_inline_expansion:1135` -- MISSING `','` from `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
- support=5 at `src/tools/formatter.rb:matching_end:1179` -- MISSING `','` from `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
- support=5 at `src/tools/formatter.rb:one_liner_end:1208` -- MISSING `'START'` from `'END' | 'FN' | 'FOR' | 'IF' | 'START' | 'TEST' | 'WHEN' | 'WHILE'`
- support=5 at `src/tools/formatter.rb:expand_if_while_for:1280` -- MISSING `'START'` from `'END' | 'FN' | 'FOR' | 'IF' | 'START' | 'TEST' | 'WHEN' | 'WHILE'`
- support=5 at `src/tools/formatter.rb:consume_on_segment:1553` -- MISSING `','` from `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
- support=5 at `src/tools/formatter.rb:expand_method_chains:1701` -- MISSING `','` from `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
- support=5 at `src/tools/formatter.rb:body_has_top_level_block?:1994` -- MISSING `','` from `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
- support=5 at `src/tools/formatter.rb:bg_body_has_strategy_arrow?:2137` -- MISSING `','` from `'(' | ')' | ',' | '[' | ']' | '{' | '}'`
- ...(+22 more)

## Neglected Updates (6090)
_co-written state, one write missing -- redundant-state desync_

- support=52 `src/annotator-helpers/function_analysis.rb:resolve_call:140` writes `.full_type` but NOT `.storage` (recv `args[i]`)
- support=52 `src/annotator-helpers/function_analysis.rb:declare_and_verify_params:740` writes `.full_type` but NOT `.storage` (recv `param[:default]`)
- support=52 `src/annotator-helpers/generic_analysis.rb:propagate_declared_type_to_value!:544` writes `.full_type` but NOT `.storage` (recv `node.value`)
- support=52 `src/annotator-helpers/method_analysis.rb:narrow_collection_type!:52` writes `.full_type` but NOT `.storage` (recv `list_arg`)
- support=52 `src/annotator-helpers/method_analysis.rb:resolve_typed_method:89` writes `.full_type` but NOT `.storage` (recv `node`)
- support=52 `src/annotator-helpers/pipe_analysis.rb:visit_Smooth:31` writes `.full_type` but NOT `.storage` (recv `node`)
- support=52 `src/annotator-helpers/pipe_analysis.rb:lift_to_observable_if_terminal!:87` writes `.full_type` but NOT `.storage` (recv `node`)
- support=52 `src/annotator-helpers/pipe_analysis.rb:analyze_pipe_to_func_call:726` writes `.full_type` but NOT `.storage` (recv `node`)
- support=52 `src/annotator-helpers/pipe_analysis.rb:analyze_pipe_to_identifier:747` writes `.full_type` but NOT `.storage` (recv `node`)
- support=52 `src/annotator-helpers/pipe_analysis.rb:analyze_pipe_to_named_function:788` writes `.full_type` but NOT `.storage` (recv `node`)
- support=52 `src/annotator-helpers/pipe_analysis.rb:auto_detect_sharded_access:1257` writes `.full_type` but NOT `.storage` (recv `map_ident`)
- support=52 `src/annotator-helpers/test_annotation.rb:visit_TestBlock:37` writes `.full_type` but NOT `.storage` (recv `node`)
- support=52 `src/annotator-helpers/test_annotation.rb:visit_WhenBlock:63` writes `.full_type` but NOT `.storage` (recv `node`)
- support=52 `src/annotator-helpers/test_annotation.rb:visit_TestThat:106` writes `.full_type` but NOT `.storage` (recv `node`)
- support=52 `src/annotator-helpers/test_annotation.rb:visit_AssertRaises:113` writes `.full_type` but NOT `.storage` (recv `node`)
- support=52 `src/annotator-helpers/test_annotation.rb:visit_BenchmarkStmt:120` writes `.full_type` but NOT `.storage` (recv `node`)
- support=52 `src/annotator-helpers/test_annotation.rb:visit_SmashStmt:127` writes `.full_type` but NOT `.storage` (recv `node`)
- support=52 `src/annotator-helpers/test_annotation.rb:visit_ProfileStmt:134` writes `.full_type` but NOT `.storage` (recv `node`)
- support=52 `src/annotator-helpers/test_annotation.rb:visit_StubDecl:151` writes `.full_type` but NOT `.storage` (recv `node`)
- support=52 `src/annotator-helpers/union.rb:resolve_variant_access:112` writes `.full_type` but NOT `.storage` (recv `node.target`)
- support=52 `src/annotator.rb:visit_Program:479` writes `.full_type` but NOT `.storage` (recv `node`)
- support=52 `src/annotator.rb:visit_RequireNode:498` writes `.full_type` but NOT `.storage` (recv `node`)
- support=52 `src/annotator.rb:visit_ExternFnDecl:573` writes `.full_type` but NOT `.storage` (recv `node`)
- support=52 `src/annotator.rb:visit_ExternStructDecl:594` writes `.full_type` but NOT `.storage` (recv `node`)
- support=52 `src/annotator.rb:visit_LambdaLit:644` writes `.full_type` but NOT `.storage` (recv `node`)
- ...(+6065 more)

## Semantic Predicate Aliases (3)
_one decision, multiple names (receiver/polarity folded)_

- `needs_capture_site_annotation? = mir? = stmt? = expr? = has_own_frame?` == `true`
  - src/mir/capture_strategy.rb:needs_capture_site_annotation?:79 ; src/mir/capture_strategy.rb:needs_capture_site_annotation?:95 ; src/mir/mir.rb:mir?:27 ; src/mir/mir.rb:stmt?:39 ; src/mir/mir.rb:expr?:47 ; src/mir/mir.rb:has_own_frame?:75 ; src/mir/mir.rb:expr?:349 ; src/mir/mir.rb:expr?:402 ; src/mir/mir.rb:expr?:416 ; src/mir/mir.rb:expr?:532 ; src/mir/mir.rb:expr?:543 ; src/mir/mir.rb:expr?:558 ; src/mir/mir.rb:expr?:594 ; src/mir/mir.rb:stmt?:1244 ; src/mir/mir.rb:stmt?:1276 ; src/mir/mir.rb:stmt?:1298 ; src/mir/mir.rb:stmt?:1325 ; src/mir/mir.rb:stmt?:1334 ; src/mir/mir.rb:stmt?:1348 ; src/mir/mir.rb:stmt?:1360 ; src/mir/mir.rb:stmt?:1368 ; src/mir/mir.rb:stmt?:1377 ; src/mir/mir.rb:stmt?:1385 ; src/mir/mir.rb:stmt?:1393 ; src/mir/mir.rb:expr?:1665 ; src/mir/mir.rb:expr?:1745 ; src/mir/mir.rb:expr?:1789
- `wildcard? = needs_capture_site_annotation? = stmt? = expr?` == `false`
  - src/ast/ast.rb:wildcard?:723 ; src/ast/ast.rb:wildcard?:818 ; src/ast/ast.rb:wildcard?:833 ; src/mir/capture_strategy.rb:needs_capture_site_annotation?:51 ; src/mir/capture_strategy.rb:needs_capture_site_annotation?:64 ; src/mir/capture_strategy.rb:needs_capture_site_annotation?:108 ; src/mir/mir.rb:stmt?:29 ; src/mir/mir.rb:expr?:31
- `auto? = auto_type?` == `t.is_a?(Type) && t.auto?`
  - src/annotator-helpers/auto_inference.rb:auto?:98 ; src/annotator-helpers/auto_inference.rb:auto?:787 ; src/backends/importer.rb:auto_type?:159

## Reification Misses (129)
_an existing predicate reinvented inline -- invariant #16_

- predicate `atomic?` reinvented inline at `src/annotator-helpers/capabilities.rb:_unified_capture_walk:1091` (`info.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator-helpers/capabilities.rb:_unified_capture_walk:1133` (`info.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator-helpers/fixable_helpers.rb:build_atomic_escape_migration_fix:1303` (`source_sym.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator-helpers/function_analysis.rb:atomic_cell_to_atomic_param?:553` (`ptype.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator-helpers/function_analysis.rb:explicit_primitive_atomic_param?:573` (`type.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator-helpers/generic_analysis.rb:validate_type_annotation!:89` (`type_obj.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator-helpers/lock_helper.rb:verify_handler_reachability!:400` (`sym.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:visit_Assignment:3131` (`sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:visit_GetField:3407` (`sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:visit_CapabilityWrap:4115` (`node.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:visit_CapabilityWrap:4120` (`node.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:visit_CapabilityWrap:4131` (`node.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:visit_CapabilityWrap:4137` (`node.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:visit_CapabilityWrap:4152` (`node.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:validate_lock_error_clause!:4824` (`sym.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:reject_bare_atomic_ptr_mutation!:4898` (`sym.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:cap_admits_atomic?:4975` (`sym.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/annotator.rb:bg_capture_independent?:6149` (`info.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/ast/parser.rb:parse_type_annotation:2902` (`sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/ast/scope.rb:resolve_full_type:176` (`entry.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/ast/type.rb:compute_zig_type:2142` (`@sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/ast/type.rb:compute_zig_type:2144` (`@sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/ast/type.rb:compute_zig_type:2154` (`@sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/mir/control_flow.rb:copy_type?:895` (`ti.sync == :atomic`)
- predicate `atomic?` reinvented inline at `src/mir/control_flow.rb:copy_type?:2022` (`ti.sync == :atomic`)
- ...(+104 more)

## Neglected Path Conditions (2203)
_nested-if/&& guard set minus one atom_

- support=39 at `src/mir/mir_lowering.rb:lower_for_range:6972` -- MISSING `node.mark_per_iter` from `!node.tight | @current_fn_has_rt | node.mark_per_iter`
- support=39 at `src/mir/mir_lowering.rb:lower_for_range:6972` -- MISSING `node.mark_per_iter` from `!node.tight | @current_fn_has_rt | node.mark_per_iter`
- support=39 at `src/mir/mir_lowering.rb:lower_for_range:6972` -- MISSING `node.mark_per_iter` from `!node.tight | @current_fn_has_rt | node.mark_per_iter`
- support=29 at `src/annotator-helpers/function_analysis.rb:resolve_call:183` -- MISSING `inner.is_a?(Type)` from `!func_type == :Intrinsic | !type_params&.any? | func_type.is_a?(FunctionSignature) | inner.is_a?(Type) | node.full_type.error_union? | node.full_type.is_a?(Type) | node.full_type.respond_to?(:error_union?)`
- support=29 at `src/annotator-helpers/function_analysis.rb:resolve_call:184` -- MISSING `inner.is_a?(Type)` from `!func_type == :Intrinsic | !type_params&.any? | func_type.is_a?(FunctionSignature) | inner.is_a?(Type) | node.full_type.error_union? | node.full_type.is_a?(Type) | node.full_type.respond_to?(:error_union?)`
- support=29 at `src/annotator-helpers/function_analysis.rb:resolve_call:184` -- MISSING `inner.is_a?(Type)` from `!func_type == :Intrinsic | !type_params&.any? | func_type.is_a?(FunctionSignature) | inner.is_a?(Type) | node.full_type.error_union? | node.full_type.is_a?(Type) | node.full_type.respond_to?(:error_union?)`
- support=29 at `src/annotator-helpers/function_analysis.rb:resolve_call:185` -- MISSING `inner.is_a?(Type)` from `!func_type == :Intrinsic | !type_params&.any? | func_type.is_a?(FunctionSignature) | inner.is_a?(Type) | node.full_type.error_union? | node.full_type.is_a?(Type) | node.full_type.respond_to?(:error_union?)`
- support=29 at `src/annotator-helpers/function_analysis.rb:resolve_call:185` -- MISSING `inner.is_a?(Type)` from `!func_type == :Intrinsic | !type_params&.any? | func_type.is_a?(FunctionSignature) | inner.is_a?(Type) | node.full_type.error_union? | node.full_type.is_a?(Type) | node.full_type.respond_to?(:error_union?)`
- support=29 at `src/annotator-helpers/function_analysis.rb:resolve_call:192` -- MISSING `inner.is_a?(Type)` from `!func_type == :Intrinsic | !type_params&.any? | func_type.is_a?(FunctionSignature) | inner.is_a?(Type) | node.full_type.error_union? | node.full_type.is_a?(Type) | node.full_type.respond_to?(:error_union?)`
- support=29 at `src/annotator-helpers/function_analysis.rb:resolve_call:214` -- MISSING `inner.is_a?(Type)` from `!func_type == :Intrinsic | !type_params&.any? | func_type.is_a?(FunctionSignature) | inner.is_a?(Type) | node.full_type.error_union? | node.full_type.is_a?(Type) | node.full_type.respond_to?(:error_union?)`
- support=28 at `src/annotator-helpers/capabilities.rb:_unified_capture_walk:1083` -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- support=28 at `src/annotator-helpers/capabilities.rb:_unified_capture_walk:1090` -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- support=28 at `src/annotator-helpers/capabilities.rb:_unified_capture_walk:1090` -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- support=28 at `src/annotator-helpers/capabilities.rb:_unified_capture_walk:1118` -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- support=28 at `src/annotator-helpers/capabilities.rb:_unified_capture_walk:1122` -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- support=28 at `src/annotator-helpers/capabilities.rb:_unified_capture_walk:1122` -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- support=28 at `src/annotator-helpers/capabilities.rb:_unified_capture_walk:1123` -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- support=28 at `src/annotator-helpers/capabilities.rb:_unified_capture_walk:1123` -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- support=28 at `src/annotator-helpers/capabilities.rb:_unified_capture_walk:1124` -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- support=28 at `src/annotator-helpers/capabilities.rb:_unified_capture_walk:1130` -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- support=28 at `src/annotator-helpers/capabilities.rb:_unified_capture_walk:1130` -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- support=28 at `src/annotator-helpers/capabilities.rb:_unified_capture_walk:1130` -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- support=28 at `src/annotator-helpers/capabilities.rb:_unified_capture_walk:1130` -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- support=28 at `src/annotator-helpers/capabilities.rb:_unified_capture_walk:1133` -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- support=28 at `src/annotator-helpers/capabilities.rb:_unified_capture_walk:1133` -- MISSING `!result.captures.key?(name)` from `!result.captures.key?(name) | info | node.is_a?(AST::Identifier)`
- ...(+2178 more)

## Broken Protocols (1730)
_co-called pair, one site does A without B_

- conf=0.99 support=78 `src/annotator-helpers/function_context.rb:(top-level):15` does `sig` without `returns`
- conf=0.99 support=78 `src/annotator.rb:visit_ReturnNode:2225` does `returns` without `extend`
- conf=0.99 support=78 `src/annotator.rb:visit_ReturnNode:2225` does `returns` without `sig`
- conf=0.99 support=78 `src/mir/mir.rb:(top-level):26` does `sig` without `params`
- conf=0.99 support=78 `src/mir/mir.rb:(top-level):26` does `sig` without `untyped`
- conf=0.98 support=47 `src/ast/ast.rb:column:206` does `column` without `line`
- conf=0.98 support=43 `src/ast/parser.rb:parse_binary_op:1762` does `parse_expression` without `consume`
- conf=0.97 support=77 `src/annotator.rb:visit_ReturnNode:2225` does `returns` without `params`
- conf=0.97 support=77 `src/annotator.rb:visit_ReturnNode:2225` does `returns` without `untyped`
- conf=0.97 support=77 `src/mir/mir.rb:(top-level):26` does `returns` without `params`
- conf=0.97 support=77 `src/mir/mir.rb:(top-level):26` does `returns` without `untyped`
- conf=0.97 support=31 `src/annotator-helpers/function_context.rb:(top-level):15` does `void` without `returns`
- conf=0.97 support=31 `src/mir/effect_set.rb:(top-level):42` does `void` without `nilable`
- conf=0.97 support=30 `src/annotator.rb:promote_to_expr_if!:5645` does `else_branch` without `then_branch`
- conf=0.97 support=30 `src/mir/mir_pass.rb:stamp_if_bind_cleanup!:874` does `then_branch` without `else_branch`
- conf=0.97 support=29 `src/ast/scope.rb:initialize_copy:86` does `capabilities` without `[]`
- conf=0.96 support=43 `src/backends/pipeline_host.rb:default_obs_alloc_zig:3030` does `transpile_type` without `new`
- conf=0.96 support=43 `src/mir/mir_lowering.rb:bare_zig_type:7415` does `transpile_type` without `new`
- conf=0.96 support=25 `src/mir/escape_analysis.rb:e2_walk_calls:437` does `walk_body` without `is_a?`
- conf=0.95 support=79 `src/mir/thunk_transform.rb:(top-level):21` does `extend` without `sig`
- conf=0.95 support=79 `src/opcodes.rb:(top-level):6` does `extend` without `sig`
- conf=0.95 support=79 `src/tools/atomic_migration_suggester.rb:(top-level):43` does `extend` without `sig`
- conf=0.95 support=79 `src/tools/atomic_ptr_migration_suggester.rb:(top-level):39` does `extend` without `sig`
- conf=0.95 support=35 `src/ast/parser.rb:match_literal!:525` does `match!` without `consume`
- conf=0.95 support=35 `src/ast/parser.rb:parse_error_selectors:3527` does `match!` without `consume`
- ...(+1705 more)

## Derived-State Staleness (222)
_b = f(a); a later reassigned, b not recomputed_

- `src/mir/mir_lowering.rb:lower_var_decl:5996`: `is_mutable` derived from `ft` (line 5996); `ft` reassigned line 6175, `is_mutable` not recomputed
- `src/mir/mir_lowering.rb:lower_var_decl:5997`: `is_mutable` derived from `ft` (line 5997); `ft` reassigned line 6175, `is_mutable` not recomputed
- `src/mir/mir_lowering.rb:lower_var_decl:5998`: `is_mutable` derived from `ft` (line 5998); `ft` reassigned line 6175, `is_mutable` not recomputed
- `src/mir/mir_lowering.rb:lower_var_decl:5999`: `is_mutable` derived from `ft` (line 5999); `ft` reassigned line 6175, `is_mutable` not recomputed
- `src/mir/mir_lowering.rb:lower_var_decl:6010`: `copy_decl_needs_drop` derived from `ft` (line 6010); `ft` reassigned line 6175, `copy_decl_needs_drop` not recomputed
- `src/mir/mir_lowering.rb:lower_var_decl:6015`: `has_mutable_cleanup` derived from `ft` (line 6015); `ft` reassigned line 6175, `has_mutable_cleanup` not recomputed
- `src/mir/mir_lowering.rb:lower_var_decl:6031`: `needs_annotation` derived from `ft` (line 6031); `ft` reassigned line 6175, `needs_annotation` not recomputed
- `src/mir/mir_lowering.rb:lower_var_decl:6051`: `has_caps` derived from `ft` (line 6051); `ft` reassigned line 6175, `has_caps` not recomputed
- `src/mir/mir_lowering.rb:lower_var_decl:6052`: `bare_ft` derived from `ft` (line 6052); `ft` reassigned line 6175, `bare_ft` not recomputed
- `src/mir/mir_lowering.rb:lower_var_decl:6055`: `init` derived from `ft` (line 6055); `ft` reassigned line 6175, `init` not recomputed
- `src/mir/mir_lowering.rb:lower_var_decl:6056`: `cap` derived from `ft` (line 6056); `ft` reassigned line 6175, `cap` not recomputed
- `src/mir/mir_lowering.rb:lower_var_decl:6090`: `inner` derived from `ft` (line 6090); `ft` reassigned line 6175, `inner` not recomputed
- `src/ast/ast.rb:finalize_storage!:399`: `value_sync` derived from `vt` (line 399); `vt` reassigned line 476, `value_sync` not recomputed
- `src/mir/mir_lowering.rb:lower_var_decl:6098`: `inner` derived from `ft` (line 6098); `ft` reassigned line 6175, `inner` not recomputed
- `src/mir/mir_lowering.rb:lower_return:7184`: `stmts` derived from `value` (line 7184); `value` reassigned line 7252, `stmts` not recomputed
- `src/tools/doctor.rb:section_heap:158`: `addrs` derived from `sites` (line 158); `sites` reassigned line 218, `addrs` not recomputed
- `src/ast/type.rb:compute_zig_type:2128`: `inner_zig` derived from `base_zig` (line 2128); `base_zig` reassigned line 2186, `inner_zig` not recomputed
- `src/annotator.rb:visit_ReturnNode:2105`: `expected_void_compatible` derived from `expected` (line 2105); `expected` reassigned line 2159, `expected_void_compatible` not recomputed
- `src/mir/mir_lowering.rb:lower_var_decl:6055`: `init` derived from `is_move` (line 6055); `is_move` reassigned line 6102, `init` not recomputed
- `src/annotator-helpers/capabilities.rb:validate_capability:204`: `atomic_ptr_ok` derived from `syn` (line 204); `syn` reassigned line 249, `atomic_ptr_ok` not recomputed
- `src/tools/formatter.rb:needs_space?:2747`: `a_is_struct_open` derived from `a_idx` (line 2747); `a_idx` reassigned line 2791, `a_is_struct_open` not recomputed
- `src/mir/mir_lowering.rb:lower_binary_op:4890`: `left_is_comptime` derived from `left_ti` (line 4890); `left_ti` reassigned line 4928, `left_is_comptime` not recomputed
- `src/mir/mir_lowering.rb:lower_binary_op:4891`: `right_is_comptime` derived from `right_ti` (line 4891); `right_ti` reassigned line 4929, `right_is_comptime` not recomputed
- `src/mir/mir_lowering.rb:lower_binary_op:4892`: `both_int` derived from `right_ti` (line 4892); `right_ti` reassigned line 4929, `both_int` not recomputed
- `src/mir/mir_lowering.rb:lower_list_lit:2325`: `promise_zig` derived from `elem_zig` (line 2325); `elem_zig` reassigned line 2361, `promise_zig` not recomputed
- ...(+197 more)

## Type-3 Clones (missed rename) (14)
_pasted block, one identifier inconsistently renamed_

- `src/tools/formatter.rb:emit_match_body:705` clone of `src/tools/formatter.rb:emit_match_body:704`: ref var `+` spelled ["-", "+"] here
- `src/tools/formatter.rb:emit_fn_block:801` clone of `src/tools/formatter.rb:emit_match_body:704`: ref var `+` spelled ["-", "+"] here
- `src/tools/formatter.rb:emit_fn_block:813` clone of `src/tools/formatter.rb:emit_match_body:704`: ref var `+` spelled ["-", "+"] here
- `src/tools/formatter.rb:emit_fn_signature_wrapped:913` clone of `src/tools/formatter.rb:emit_match_body:704`: ref var `+` spelled ["-", "+"] here
- `src/tools/formatter.rb:emit_fn_params_only_wrapped:1021` clone of `src/tools/formatter.rb:emit_match_body:704`: ref var `+` spelled ["-", "+"] here
- `src/tools/formatter.rb:expand_if_while_for:1273` clone of `src/tools/formatter.rb:emit_match_body:704`: ref var `+` spelled ["-", "+"] here
- `src/tools/formatter.rb:expand_if_while_for:1275` clone of `src/tools/formatter.rb:emit_match_body:704`: ref var `+` spelled ["-", "+"] here
- `src/tools/formatter.rb:expand_if_while_for:1277` clone of `src/tools/formatter.rb:emit_match_body:704`: ref var `+` spelled ["-", "+"] here
- `src/tools/formatter.rb:emit_wrapped_args:1925` clone of `src/tools/formatter.rb:emit_match_body:704`: ref var `+` spelled ["-", "+"] here
- `src/tools/formatter.rb:emit_bg_do_wrapped:2093` clone of `src/tools/formatter.rb:emit_match_body:704`: ref var `+` spelled ["-", "+"] here
- `src/tools/formatter.rb:emit_record_type:2364` clone of `src/tools/formatter.rb:emit_match_body:704`: ref var `+` spelled ["-", "+"] here
- `src/tools/formatter.rb:emit_record_type:2368` clone of `src/tools/formatter.rb:emit_match_body:704`: ref var `+` spelled ["-", "+"] here
- `src/tools/formatter.rb:emit_record_type:2370` clone of `src/tools/formatter.rb:emit_match_body:704`: ref var `+` spelled ["-", "+"] here
- `src/annotator.rb:visit_OrRescue:4052` clone of `src/annotator.rb:visit_OrRescue:4038`: ref var `payload_type` spelled ["wrapped", "wrapped_type"] here

## Exact Predicate Aliases (7)
_identical one-line predicate body under >=2 names_

- `needs_cleanup = needs_capture_site_annotation? = mir? = stmt? = expr? = has_own_frame?` == `true`
  - src/ast/ast.rb:needs_cleanup:1396 ; src/mir/capture_strategy.rb:needs_capture_site_annotation?:79 ; src/mir/capture_strategy.rb:needs_capture_site_annotation?:95 ; src/mir/mir.rb:mir?:27 ; src/mir/mir.rb:stmt?:39 ; src/mir/mir.rb:expr?:47 ; src/mir/mir.rb:has_own_frame?:75 ; src/mir/mir.rb:expr?:349 ; src/mir/mir.rb:expr?:402 ; src/mir/mir.rb:expr?:416 ; src/mir/mir.rb:expr?:532 ; src/mir/mir.rb:expr?:543 ; src/mir/mir.rb:expr?:558 ; src/mir/mir.rb:expr?:594 ; src/mir/mir.rb:stmt?:1244 ; src/mir/mir.rb:stmt?:1276 ; src/mir/mir.rb:stmt?:1298 ; src/mir/mir.rb:stmt?:1325 ; src/mir/mir.rb:stmt?:1334 ; src/mir/mir.rb:stmt?:1348 ; src/mir/mir.rb:stmt?:1360 ; src/mir/mir.rb:stmt?:1368 ; src/mir/mir.rb:stmt?:1377 ; src/mir/mir.rb:stmt?:1385 ; src/mir/mir.rb:stmt?:1393 ; src/mir/mir.rb:expr?:1665 ; src/mir/mir.rb:expr?:1745 ; src/mir/mir.rb:expr?:1789
- `visit_PassStmt = visit_OrRaise = visit_OrBreak = visit_OrPass = visit_OrPrune` == `node.full_type = :Void`
  - src/annotator.rb:visit_PassStmt:1413 ; src/annotator.rb:visit_OrRaise:4069 ; src/annotator.rb:visit_OrBreak:4074 ; src/annotator.rb:visit_OrPass:4079 ; src/annotator.rb:visit_OrPrune:4086
- `wildcard? = needs_capture_site_annotation? = stmt? = expr?` == `false`
  - src/ast/ast.rb:wildcard?:723 ; src/ast/ast.rb:wildcard?:818 ; src/ast/ast.rb:wildcard?:833 ; src/mir/capture_strategy.rb:needs_capture_site_annotation?:51 ; src/mir/capture_strategy.rb:needs_capture_site_annotation?:64 ; src/mir/capture_strategy.rb:needs_capture_site_annotation?:108 ; src/mir/mir.rb:stmt?:29 ; src/mir/mir.rb:expr?:31
- `emit_rc_retain = emit_rc_downgrade = emit_weak_upgrade` == `"CheatLib.#{node.func}(#{node.zig_base}, #{emit(node.source)})"`
  - src/mir/mir_emitter.rb:emit_rc_retain:1260 ; src/mir/mir_emitter.rb:emit_rc_downgrade:1265 ; src/mir/mir_emitter.rb:emit_weak_upgrade:1270
- `auto? = auto_type?` == `t.is_a?(Type) && t.auto?`
  - src/annotator-helpers/auto_inference.rb:auto?:98 ; src/annotator-helpers/auto_inference.rb:auto?:787 ; src/backends/importer.rb:auto_type?:159
- `child_bodies = marker_plan` == `[]`
  - src/ast/ast.rb:child_bodies:195 ; src/mir/capture_strategy.rb:marker_plan:49 ; src/mir/capture_strategy.rb:marker_plan:62 ; src/mir/capture_strategy.rb:marker_plan:106
- `full_type = type_info` == `@type_object`
  - src/ast/ast.rb:full_type:316 ; src/ast/ast.rb:type_info:495

## Run Summary
- Files analyzed: 93
- Detectors: 10 (all shipped, self-tested)
- Total candidates: 10662
- Method: stdlib AST only, intra-procedural, zero deps, no CFG / no points-to (see docs/agents/design.md)
