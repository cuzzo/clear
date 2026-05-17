# Nil Kill Report

- Target dirs: src
- Methods indexed: 2328
- Runtime-observed methods: 1162
- Missing sigs: 111
- Existing sigs: 2217
- Existing/candidate `T.let` sites: 686
- Sorbet errors captured: 0

## Project Prioritization
- [Nil Source Fixes (158)](#nil-source-fixes-158): 148 action item(s), 158 `T.nilable` slot(s); top source affects 6 slot(s), 726 source calls
- [Union / `T.any` Candidates (504)](#union-tany-candidates-504): 472 action item(s), 504 union slot(s); top source affects 3 slot(s), 936745 source calls
- [Hash Record Struct Candidates (Shapes + Pressure)](#hash-record-struct-candidates-shapes-pressure): 238 struct candidate(s), 513 pressure record(s); top candidate BodyRecord has pressure 119; 63 pressure record(s) without a literal shape cluster

## Hygiene Overview

### Type Soundness

| Slot category | Total | Strong | Weak | Untyped | Nilable |
|---|---|---|---|---|---|
| Param inputs | 2852 | 1957 (68.6%) | 22 (0.8%) | 873 (30.6%) | 184 (6.5%) |
| Returns | 1620 | 1331 (82.2%) | 16 (1.0%) | 273 (16.9%) | 360 (22.2%) |
| Struct/class fields & ivars | 1483 | 560 (37.8%) | 19 (1.3%) | 904 (61.0%) | 93 (6.3%) |
| Arrays/Sets/Hashmaps | 1195 | 346 (29.0%) | 849 (71.0%) | 0 (0.0%) | 324 (27.1%) |

Total = Strong + Weak + Untyped. Nilable is a cross-cut sub-count (a `T.nilable(String)` slot is Strong and Nilable, not a fourth bucket). Collection-typed slots (`T::Array[...]` etc.) are counted only in the Arrays/Sets/Hashmaps row, so the four categories are mutually exclusive. The Param/Returns/Struct Untyped columns equal the per-row denominators in the Untyped Cause Breakdown below.

### Untyped Cause Breakdown

| Slot category | Refused/Pending | PropagationGap | WeakEvidence | Heterogeneous | NoEvidence |
|---|---|---|---|---|---|
| Param inputs (873 untyped) | 260 (29.8%) | 114 (13.1%) | 184 (21.1%) | 211 (24.2%) | 104 (11.9%) |
| Returns (273 untyped) | 113 (41.4%) | 10 (3.7%) | 80 (29.3%) | 66 (24.2%) | 4 (1.5%) |
| Struct/class fields & ivars (904 untyped) | 604 (66.8%) | 52 (5.8%) | 6 (0.7%) | 37 (4.1%) | 205 (22.7%) |
| Arrays/Sets/Hashmaps (669 untyped) | 143 (21.4%) | 28 (4.2%) | 90 (13.5%) | 249 (37.2%) | 159 (23.8%) |

- **Refused/Pending**: type IS determinable from local evidence (single observed runtime type, void/unused, boolean pair) -- untyped only because the fix is unapplied or conservatively refused
- **PropagationGap**: type is determinable elsewhere but needs cross-method/whole-program flow (forwarded return, ivar-from-param capture, callee untyped-but-resolvable, coherent collection needing the typed-collection rewrite)
- **WeakEvidence**: a type is known but only weakly (T::Array[`T.untyped`], a union wider than policy) -- the weak-collection / union-policy axis
- **Heterogeneous**: slot legitimately holds many unrelated types/shapes (AST/MIR node grab-bags, dynamic dispatch) -- `T.untyped` is the correct type
- **NoEvidence**: never observed at runtime AND no static expression/callsite to infer from -- needs a test or a hand-written sig

Actionable by more nil-kill work: PropagationGap (and the policy half of WeakEvidence). Inherent (correct `T.untyped` or needs human/tests): Heterogeneous + NoEvidence. Refused/Pending is resolvable today but unapplied or conservatively declined.

### Union Decomplexity
- Each entry is a canonical origin contract (an accessor like `.type_info`, a hash key like `[:type]`, an ivar, a call) and the TOTAL `is_a?(Type)` guards that collapse if that one contract is given a concrete type. Guards are aggregated across every method that reads the contract. Producer types come from runtime evidence for that contract; `unattributed` = no runtime trace yet for it.
- 59 guards collapse | `.type_info` (accessor) across 38 method(s) -> via @type_info assignments (runtime) {NilClass, Type}: tighten that contract
  - methods: `FunctionAnalysis#resolve_call`, `EscapeAnalysis#tag_transitive_provenance!`, `FunctionAnalysis#verify_function_signature!`, `CleanupClassifier#classify_struct_cleanup_fields`, `CleanupClassifier#walk_if_bind_bindings`, `CleanupClassifier#walk_match_as_bindings`, +32 more
  - guards at: src/annotator-helpers/function_analysis.rb:243, src/annotator-helpers/function_analysis.rb:247, src/annotator-helpers/function_analysis.rb:249, src/mir/escape_analysis.rb:673, src/mir/escape_analysis.rb:676
- 38 guards collapse | `.full_type` (accessor) across 29 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `GenericAnalysis#propagate_collection_metadata!`, `CapabilityHelper#declare_capability_scope!`, `CapabilityHelper#validate_capability`, `FunctionAnalysis#verify_function_signature!`, `MIRLowering#lower_binary_op`, `SemanticAnnotator#promote_pipe_to_observable_dest!`, +23 more
  - guards at: src/annotator-helpers/generic_analysis.rb:580, src/annotator-helpers/generic_analysis.rb:590, src/annotator-helpers/generic_analysis.rb:597, src/annotator-helpers/capabilities.rb:771, src/annotator-helpers/capabilities.rb:789
- 28 guards collapse | `.type` (accessor) across 23 method(s) -> via @type assignments (runtime) {Type, Symbol, NilClass, T.nilable(Type), FunctionSignature, String}: tighten that contract
  - methods: `CapabilityHelper#_unified_capture_walk`, `SemanticAnnotator#finalize_decl_node!`, `SemanticAnnotator#promote_pipe_to_observable_dest!`, `CapabilityHelper#_bg_walk`, `EscapeAnalysis#e2_stamp_symbol_via_return_ident!`, `EscapeAnalysis#per_fn_scan!`, +17 more
  - guards at: src/annotator-helpers/capabilities.rb:1130, src/annotator-helpers/capabilities.rb:1141, src/annotator.rb:2712, src/annotator.rb:2763, src/annotator.rb:2639
- 22 guards collapse | `.return_type` (accessor) across 17 method(s) -> via @return_type assignments (runtime) {T.nilable(Type), Type, Symbol, Hash, Proc}: tighten that contract
  - methods: `ReentranceBridge#emit_mutual_thunk_unsupported!`, `ReentranceBridge#validate_not_logical_return!`, `SemanticAnnotator#visit_FunctionDef`, `CapabilityHelper#visit_post_clauses!`, `EffectTracker#enforce_fallible_returns!`, `EscapeAnalysis#e2_carry_return_vars`, +11 more
  - guards at: src/annotator-helpers/reentrance.rb:441, src/annotator-helpers/reentrance.rb:479, src/annotator-helpers/reentrance.rb:162, src/annotator-helpers/reentrance.rb:164, src/annotator.rb:674
- 11 guards collapse | `:type` (hash-key) across 9 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `MIRLowering#lower_lambda`, `EscapeAnalysis#param_accepts_caller_sync?`, `EscapeAnalysis#param_sync_was_declared?`, `EscapeAnalysis#per_fn_scan!`, `FunctionAnalysis#atomic_cell_to_atomic_param?`, `FunctionAnalysis#verify_function_signature!`, +3 more
  - guards at: src/mir/mir_lowering.rb:2264, src/mir/mir_lowering.rb:2265, src/mir/escape_analysis.rb:814, src/mir/escape_analysis.rb:808, src/mir/escape_analysis.rb:365
- 9 guards collapse | `param `final_type` (AST::Locatable#finalize_storage!)` (param) across 1 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `AST::Locatable#finalize_storage!`
  - guards at: src/ast/ast.rb:404, src/ast/ast.rb:407, src/ast/ast.rb:412
- 5 guards collapse | `` (hash-key) across 4 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `CleanupClassifier#walk_match_as_bindings`, `MIRLowering#lower_union_variant_lit`, `SemanticAnnotator#annotate_struct_pattern!`, `SemanticAnnotator#visit_MatchStatement`
  - guards at: src/mir/promotion_plan.rb:564, src/mir/mir_lowering.rb:5490, src/annotator.rb:1401, src/annotator.rb:1465, src/annotator.rb:1664
- 3 guards collapse | `local `ti` (EscapeAnalysis#per_fn_scan!)` (local) across 1 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `EscapeAnalysis#per_fn_scan!`
  - guards at: src/mir/escape_analysis.rb:238, src/mir/escape_analysis.rb:327, src/mir/escape_analysis.rb:374
- 3 guards collapse | `:resolved_type` (hash-key) across 2 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `MIRLowering#lower_with_block`, `MIRLowering#lower_polymorphic_universal`
  - guards at: src/mir/mir_lowering.rb:2761, src/mir/mir_lowering.rb:2823, src/mir/mir_lowering.rb:3193
- 3 guards collapse | `.wrapped_type` (accessor) across 3 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `CleanupClassifier#walk_if_bind_bindings`, `CleanupClassifier#walk_while_bind_bindings`, `SemanticAnnotator#visit_IfBind`
  - guards at: src/mir/promotion_plan.rb:626, src/mir/promotion_plan.rb:601, src/annotator.rb:1325
- 2 guards collapse | `param `ti` (MIRLowering#build_drop_entry!)` (param) across 1 method(s) -> always `Type`: collapse, all 2 die
  - methods: `MIRLowering#build_drop_entry!`
  - guards at: src/mir/mir_lowering.rb:851, src/mir/mir_lowering.rb:852
- 2 guards collapse | `param `other_type` (Type#accepts_fn_type?)` (param) across 1 method(s) -> always `Type`: collapse, all 2 die
  - methods: `Type#accepts_fn_type?`
  - guards at: src/ast/type.rb:1745, src/ast/type.rb:1746
- 2 guards collapse | `param `expected_type` (SemanticAnnotator#ensure_owned_value!)` (param) across 1 method(s) -> 50.0% `T.nilable(Type)` + 1 outlier producer(s)
  - methods: `SemanticAnnotator#ensure_owned_value!`
  - guards at: src/annotator.rb:4232, src/annotator.rb:4236
  - outlier producer `Type` at src/annotator.rb:3606 `expected_type`
- 2 guards collapse | `local `ti` (BorrowChecker#_collect_share_moves)` (local) across 1 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `BorrowChecker#_collect_share_moves`
  - guards at: src/mir/control_flow.rb:1973, src/mir/control_flow.rb:1974
- 2 guards collapse | `local `source_type` (CapabilityHelper#declare_capability_scope!)` (local) across 1 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `CapabilityHelper#declare_capability_scope!`
  - guards at: src/annotator-helpers/capabilities.rb:830, src/annotator-helpers/capabilities.rb:859
- 2 guards collapse | `local `field_ti` (CleanupClassifier#stamp_field_pre_cleanups!)` (local) across 1 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `CleanupClassifier#stamp_field_pre_cleanups!`
  - guards at: src/mir/promotion_plan.rb:323, src/mir/promotion_plan.rb:324
- 2 guards collapse | `local `decl_ti` (EscapeAnalysis#e2_loop_carry_names!)` (local) across 1 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `EscapeAnalysis#e2_loop_carry_names!`
  - guards at: src/mir/escape_analysis.rb:544, src/mir/escape_analysis.rb:545
- 2 guards collapse | `local `outer_ti` (EscapeAnalysis#e2_loop_carry_names!)` (local) across 1 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `EscapeAnalysis#e2_loop_carry_names!`
  - guards at: src/mir/escape_analysis.rb:558, src/mir/escape_analysis.rb:559
- 2 guards collapse | `local `ti` (EscapeAnalysis#e3_mark_carry_expr!)` (local) across 1 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `EscapeAnalysis#e3_mark_carry_expr!`
  - guards at: src/mir/escape_analysis.rb:906, src/mir/escape_analysis.rb:912
- 2 guards collapse | `local `ct` (FsmTransform#collect_body_locals)` (local) across 1 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `FsmTransform#collect_body_locals`
  - guards at: src/mir/fsm_transform.rb:186, src/mir/fsm_transform.rb:188
- 2 guards collapse | `local `ct` (FsmTransform::RecursiveSplitter#emit_for_each_fragment)` (local) across 1 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `FsmTransform::RecursiveSplitter#emit_for_each_fragment`
  - guards at: src/mir/fsm_transform/recursive_splitter.rb:532, src/mir/fsm_transform/recursive_splitter.rb:545
- 2 guards collapse | `local `ti` (LoopFrameAnalysis#promote_value_to_heap!)` (local) across 1 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `LoopFrameAnalysis#promote_value_to_heap!`
  - guards at: src/mir/control_flow.rb:1564, src/mir/control_flow.rb:1565
- 2 guards collapse | `param `ti` (MIRLowering#bare_zig_type)` (param) across 1 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `MIRLowering#bare_zig_type`
  - guards at: src/mir/mir_lowering.rb:7415, src/mir/mir_lowering.rb:7590
- 2 guards collapse | `local `ti` (MIRLowering#container_borrow_expr?)` (local) across 1 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `MIRLowering#container_borrow_expr?`
  - guards at: src/mir/mir_lowering.rb:273, src/mir/mir_lowering.rb:274
- 2 guards collapse | `param `type` (MIRLowering#generic_type_arg_zig)` (param) across 1 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `MIRLowering#generic_type_arg_zig`
  - guards at: src/mir/mir_lowering.rb:5915, src/mir/mir_lowering.rb:5918
- 2 guards collapse | `local `field_ti` (MIRLowering#lower_assignment)` (local) across 1 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `MIRLowering#lower_assignment`
  - guards at: src/mir/mir_lowering.rb:6349, src/mir/mir_lowering.rb:6350
- 2 guards collapse | `local `root_ti` (MIRLowering#lower_assignment)` (local) across 1 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `MIRLowering#lower_assignment`
  - guards at: src/mir/mir_lowering.rb:6360, src/mir/mir_lowering.rb:6361
- 2 guards collapse | `.resolved_type` (accessor) across 1 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `MIRLowering#lower_match`
  - guards at: src/mir/mir_lowering.rb:7008, src/mir/mir_lowering.rb:7012
- 2 guards collapse | `local `p` (SemanticAnnotator#visit_MatchStatement)` (local) across 1 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `SemanticAnnotator#visit_MatchStatement`
  - guards at: src/annotator.rb:1573, src/annotator.rb:1638
- 2 guards collapse | `.element_type` (accessor) across 2 method(s) -> producers unattributed (no runtime trace for this contract yet)
  - methods: `MIRLowering#build_drop_entry!`, `MIRLowering#lower_for_each`
  - guards at: src/mir/mir_lowering.rb:876, src/mir/mir_lowering.rb:6934

### Node-Union Alias Candidates
- Heterogeneous param slots whose every observed class is in ONE namespace. Each namespace below collapses to a single `T.type_alias` (e.g. `AstNode = T.type_alias { T.any(AST::...) }`); applying it types every listed param at once. `classes` = distinct node types observed at that slot (small = a precise sub-union; large = the full node grab-bag).
- 161 of 207 Heterogeneous params (78%) collapse to 3 alias(es).
- `AstNode` (AST::*): 134 param slot(s)
  - src/backends/string_concat_rewriter.rb:27 `StringConcatRewriter#rewrite_in_node!` param `node` (82 node types)
  - src/backends/string_concat_rewriter.rb:45 `StringConcatRewriter#rewrite_children!` param `node` (82 node types)
  - src/backends/string_concat_rewriter.rb:78 `StringConcatRewriter#string_concat?` param `node` (82 node types)
  - src/ast/ast.rb:162 `AST#_expr_each_concurrent_capture` param `node` (81 node types)
  - src/mir/escape_analysis.rb:441 `EscapeAnalysis#e2_walk_calls_in_expr` param `node` (79 node types)
  - src/annotator.rb:345 `SemanticAnnotator#visit` param `node` (68 node types)
  - src/mir/control_flow.rb:234 `FunctionCFG#stmt_can_fail?` param `node` (65 node types)
  - src/backends/pipeline_rewriter.rb:34 `PipelineRewriter#rewrite!` param `node` (59 node types)
  - src/backends/pipeline_rewriter.rb:57 `PipelineRewriter#rewrite_children!` param `node` (59 node types)
  - src/mir/control_flow.rb:1140 `UseAfterMoveChecker#check_reads_in_expr` param `node` (55 node types)
  - src/mir/control_flow.rb:1984 `BorrowChecker#walk_for_was_moved` param `node` (53 node types)
  - src/mir/control_flow.rb:900 `OwnershipDataflow#walk_expr` param `node` (52 node types)
  - src/mir/control_flow.rb:945 `OwnershipDataflow#walk_expr_skip_copy` param `node` (52 node types)
  - src/mir/mir_pass.rb:744 `MIRPass#walk_consumed` param `node` (40 node types)
  - src/ast/ast.rb:67 `AST#_bg_visit_recursive` param `node` (33 node types)
  - src/ast/ast.rb:124 `AST#_expr_each_bg_block_shallow` param `expr` (32 node types)
  - src/ast/ast.rb:85 `AST#_expr_each_bg_block_recursive` param `expr` (32 node types)
  - src/annotator.rb:3031 `SemanticAnnotator#track_union_alias` param `value_node` (31 node types)
  - src/ast/ast.rb:107 `AST#each_bg_block_in_stmt` param `stmt` (29 node types)
  - src/mir/mir_pass.rb:335 `MIRPass#recurse_branches!` param `stmt` (29 node types)
  - src/mir/mir_pass.rb:399 `MIRPass#insert_suppress_cleanup!` param `stmt` (29 node types)
  - src/mir/mir_pass.rb:422 `MIRPass#insert_bg_give_suppress!` param `stmt` (29 node types)
  - src/mir/mir_pass.rb:446 `MIRPass#insert_bg_resource_suppress!` param `stmt` (29 node types)
  - src/mir/mir_pass.rb:589 `MIRPass#insert_bg_escape_promote!` param `stmt` (29 node types)
  - src/mir/mir_pass.rb:630 `MIRPass#insert_or_fallback_dupe!` param `stmt` (29 node types)
  - src/mir/mir_pass.rb:641 `MIRPass#find_or_rescue_in_value` param `stmt` (29 node types)
  - src/mir/mir_pass.rb:796 `MIRPass#stamp_reassign_cleanup!` param `stmt` (29 node types)
  - src/mir/mir_pass.rb:813 `MIRPass#stamp_match_as_cleanup!` param `stmt` (29 node types)
  - src/mir/mir_pass.rb:850 `MIRPass#stamp_while_bind_cleanup!` param `stmt` (29 node types)
  - src/mir/mir_pass.rb:862 `MIRPass#stamp_if_bind_cleanup!` param `stmt` (29 node types)
  - src/mir/mir_pass.rb:881 `MIRPass#insert_container_promote!` param `stmt` (29 node types)
  - src/mir/mir_pass.rb:696 `MIRPass#collect_consumed_names` param `stmt` (28 node types)
  - src/mir/control_flow.rb:1887 `BorrowChecker#check_binding_moves` param `expr` (27 node types)
  - src/mir/control_flow.rb:1914 `BorrowChecker#collect_moved_names` param `node` (27 node types)
  - src/mir/control_flow.rb:1921 `BorrowChecker#_collect_moves` param `node` (27 node types)
  - src/mir/control_flow.rb:698 `OwnershipDataflow#collect_binding_moves` param `node` (27 node types)
  - src/mir/control_flow.rb:707 `OwnershipDataflow#collect_ownership_transfers` param `node` (27 node types)
  - src/mir/control_flow.rb:1050 `UseAfterMoveChecker#check_stmt_reads` param `stmt` (25 node types)
  - src/mir/control_flow.rb:1287 `LoopFrameAnalysis#walk_stmt!` param `stmt` (25 node types)
  - src/mir/control_flow.rb:1791 `BorrowChecker#check_stmt` param `stmt` (25 node types)
  - src/mir/control_flow.rb:604 `OwnershipDataflow#transfer_stmt` param `stmt` (25 node types)
  - src/mir/mir_lowering.rb:219 `MIRLowering#hoist_alloc` param `ast_node` (24 node types)
  - src/mir/mir_lowering.rb:7276 `MIRLowering#call_union_return_needs_hoist?` param `ast_node` (22 node types)
  - src/mir/escape_analysis.rb:126 `EscapeAnalysis#return_expr_is_heap?` param `val` (21 node types)
  - src/annotator-helpers/function_analysis.rb:961 `FunctionAnalysis#return_is_borrow?` param `node` (20 node types)
  - src/annotator-helpers/function_analysis.rb:532 `FunctionAnalysis#atomic_cell_to_bare_value_param?` param `arg_node` (19 node types)
  - src/annotator-helpers/function_analysis.rb:547 `FunctionAnalysis#atomic_cell_to_atomic_param?` param `arg_node` (19 node types)
  - src/annotator-helpers/function_analysis.rb:591 `FunctionAnalysis#verify_param_lifetime!` param `arg_node` (19 node types)
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` param `node` (19 node types)
  - src/ast/parser.rb:1910 `Parser#parse_suffixes` param `lhs` (18 node types)
  - src/mir/control_flow.rb:801 `OwnershipDataflow#collect_share_transfers_in` param `node` (17 node types)
  - src/mir/control_flow.rb:1959 `BorrowChecker#_collect_was_moved` param `node` (16 node types)
  - src/mir/control_flow.rb:772 `OwnershipDataflow#collect_explicit_in` param `node` (16 node types)
  - src/mir/control_flow.rb:837 `OwnershipDataflow#_walk_bg_captures_in_expr` param `expr` (16 node types)
  - src/annotator-helpers/generic_analysis.rb:698 `GenericAnalysis#bg_exit_frame_string?` param `expr` (14 node types)
  - src/ast/ast.rb:40 `AST#wrapped_children` param `expr` (14 node types)
  - src/ast/parser.rb:1743 `Parser#parse_binary_op` param `lhs` (14 node types)
  - src/backends/pipeline_host.rb:375 `PipelineHost#copy_type_info` param `src` (14 node types)
  - src/backends/pipeline_host.rb:375 `PipelineHost#copy_type_info` param `dst` (14 node types)
  - src/mir/escape_analysis.rb:393 `EscapeAnalysis#e2_promote_frame_concats!` param `node` (13 node types)
  - src/mir/fsm_transform/recursive_splitter.rb:380 `FsmTransform::RecursiveSplitter#stmt_unsupported_suspend?` param `stmt` (13 node types)
  - src/mir/mir_lowering.rb:7289 `MIRLowering#universal_poly_arg_needs_addr?` param `arg_node` (13 node types)
  - src/backends/pipeline_rewriter.rb:407 `PipelineRewriter#build_init` param `terminal` (11 node types)
  - src/backends/pipeline_rewriter.rb:503 `PipelineRewriter#build_recursive_body` param `terminal` (11 node types)
  - src/backends/pipeline_rewriter.rb:601 `PipelineRewriter#build_terminal_action` param `terminal` (11 node types)
  - src/mir/mir_lowering.rb:238 `MIRLowering#hoist_owned_value_temp` param `ast_node` (11 node types)
  - src/mir/mir_lowering.rb:254 `MIRLowering#owned_value_temp_needs_cleanup?` param `ast_node` (11 node types)
  - src/mir/mir_lowering.rb:286 `MIRLowering#copy_container_borrow_if_needed` param `ast_node` (11 node types)
  - src/annotator.rb:5990 `SemanticAnnotator#lifetime_sources_for_value` param `val_node` (10 node types)
  - src/backends/pipeline_rewriter.rb:792 `PipelineRewriter#replace_placeholder` param `node` (10 node types)
  - src/mir/control_flow.rb:1442 `LoopFrameAnalysis#expr_references_var?` param `expr` (10 node types)
  - src/mir/escape_analysis.rb:885 `EscapeAnalysis#e3_top_level_exprs` param `stmt` (10 node types)
  - src/mir/mir_lowering.rb:4956 `MIRLowering#unit_variant_access` param `node` (10 node types)
  - src/annotator.rb:5724 `SemanticAnnotator#finalize_scope` param `node` (9 node types)
  - src/backends/pipeline_rewriter.rb:718 `PipelineRewriter#build_final_result` param `terminal` (9 node types)
  - src/mir/mir_lowering.rb:667 `MIRLowering#alloc_for_node` param `node` (9 node types)
  - src/mir/mir_lowering.rb:7596 `MIRLowering#should_dupe_borrowed_union?` param `val_node` (9 node types)
  - src/backends/pipeline_host.rb:170 `PipelineHost#visit_mir` param `node` (8 node types)
  - src/backends/pipeline_host.rb:2316 `PipelineHost#lower_binding_fold` param `fold` (8 node types)
  - src/backends/pipeline_host.rb:2845 `PipelineHost#lower_range_fold_observable_default` param `fold_op` (8 node types)
  - src/backends/pipeline_host.rb:758 `PipelineHost#build_soa_scalar_fold_block` param `fold_node` (8 node types)
  - src/backends/string_concat_rewriter.rb:86 `StringConcatRewriter#collect_parts` param `node` (8 node types)
  - src/mir/control_flow.rb:1561 `LoopFrameAnalysis#promote_value_to_heap!` param `node` (8 node types)
  - src/mir/mir_lowering.rb:5694 `MIRLowering#type_info_for` param `ast_node` (8 node types)
  - src/mir/mir_pass.rb:548 `MIRPass#bg_exit_needs_string_dupe?` param `expr` (8 node types)
  - src/ast/parser.rb:2022 `Parser#extract_paren_bindings` param `node` (7 node types)
  - src/ast/source_error.rb:81 `ErrorHelper#note!` param `node_or_token` (7 node types)
  - src/backends/pipeline_rewriter.rb:264 `PipelineRewriter#binding_source?` param `node` (7 node types)
  - src/backends/pipeline_rewriter.rb:756 `PipelineRewriter#needs_transpiler_pipeline?` param `source` (7 node types)
  - src/mir/control_flow.rb:786 `OwnershipDataflow#collect_explicit_moves` param `node` (7 node types)
  - src/mir/mir_lowering.rb:299 `MIRLowering#hoist_cleanup_entry` param `ast_node` (7 node types)
  - src/annotator.rb:1290 `SemanticAnnotator#ifbind_source_root` param `expr` (6 node types)
  - src/backends/pipeline_host.rb:111 `PipelineHost#visit` param `node` (6 node types)
  - src/mir/fsm_transform.rb:257 `FsmTransform#suspend_value?` param `value` (6 node types)
  - src/mir/mir_lowering.rb:756 `MIRLowering#extract_root_var_name` param `node` (6 node types)
  - src/tools/migration_suggester_helpers.rb:106 `MigrationSuggesterHelpers#classify_uses!` param `node` (6 node types)
  - src/backends/pipeline_host.rb:196 `PipelineHost#ast_node_uses_placeholder?` param `node` (5 node types)
  - src/mir/fsm_transform/recursive_splitter.rb:400 `FsmTransform::RecursiveSplitter#emit_pivot` param `stmt` (5 node types)
  - src/mir/thunk_transform/recursive_splitter.rb:257 `ThunkTransform::RecursiveSplitter#direct_self_call` param `node` (5 node types)
  - src/annotator.rb:6519 `SemanticAnnotator#og_declare` param `node` (4 node types)
  - src/ast/parser.rb:3920 `Parser#deep_clone_node` param `node` (4 node types)
  - src/ast/scope.rb:24 `Scope#declare` param `reg` (4 node types)
  - src/backends/pipeline_rewriter.rb:307 `PipelineRewriter#fuse_pipeline` param `source` (4 node types)
  - src/mir/control_flow.rb:1314 `LoopFrameAnalysis#process_loop!` param `loop_node` (4 node types)
  - src/mir/control_flow.rb:595 `OwnershipDataflow#make_owner_entry` param `node` (4 node types)
  - src/mir/promotion_plan.rb:645 `CleanupClassifier#classify_binding` param `node` (4 node types)
  - src/mir/promotion_plan.rb:693 `CleanupClassifier#classify_resource` param `node` (4 node types)
  - src/mir/promotion_plan.rb:756 `CleanupClassifier#classify_array_struct_strings` param `node` (4 node types)
  - src/mir/promotion_plan.rb:817 `CleanupClassifier#classify_heap_provenance` param `node` (4 node types)
  - src/mir/promotion_plan.rb:853 `CleanupClassifier#classify_heap_struct_plain` param `node` (4 node types)
  - src/mir/thunk_transform/emit.rb:133 `ThunkTransform::Emit#render_expr` param `ast_expr` (4 node types)
  - src/mir/thunk_transform/recursive_splitter.rb:214 `ThunkTransform::RecursiveSplitter#match_base_case` param `stmt` (4 node types)
  - src/annotator-helpers/generic_analysis.rb:32 `GenericAnalysis#validate_type_param_list!` param `node` (3 node types)
  - src/annotator.rb:5460 `SemanticAnnotator#handle_assign_move` param `node` (3 node types)
  - src/annotator.rb:5530 `SemanticAnnotator#handle_assign_borrow` param `node` (3 node types)
  - src/annotator.rb:5603 `SemanticAnnotator#verify_unrestricted!` param `node` (3 node types)
  - src/annotator.rb:5643 `SemanticAnnotator#promote_to_expr_if!` param `parent_node` (3 node types)
  - src/annotator.rb:5821 `SemanticAnnotator#mark_chain_needs_mut_ref!` param `node` (3 node types)
  - src/mir/mir_lowering.rb:716 `MIRLowering#resolve_alloc_sym` param `node` (3 node types)
  - src/annotator-helpers/capabilities.rb:362 `CapabilityHelper#record_predicate_call_site!` param `node` (2 node types)
  - src/annotator-helpers/effects.rb:1000 `EffectTracker#validate_tight_body!` param `loop_node` (2 node types)
  - src/annotator-helpers/function_analysis.rb:11 `FunctionAnalysis#analyze_routine` param `node` (2 node types)
  - src/annotator-helpers/function_analysis.rb:89 `FunctionAnalysis#resolve_call` param `node` (2 node types)
  - src/annotator-helpers/test_annotation.rb:72 `TestAnnotation#visit_test_lets` param `node` (2 node types)
  - src/annotator-helpers/test_annotation.rb:93 `TestAnnotation#visit_test_hook_bodies` param `node` (2 node types)
  - src/annotator.rb:2063 `SemanticAnnotator#resolve_error_registration!` param `node` (2 node types)
  - src/annotator.rb:2690 `SemanticAnnotator#finalize_decl_node!` param `node` (2 node types)
  - src/annotator.rb:3278 `SemanticAnnotator#validate_assignment_type` param `node` (2 node types)
  - src/annotator.rb:5682 `SemanticAnnotator#promote_to_expr_match!` param `parent_node` (2 node types)
  - src/annotator.rb:6032 `SemanticAnnotator#stamp_bg_handle_lifetime!` param `decl_node` (2 node types)
  - src/mir/mir_lowering.rb:1902 `MIRLowering#lower_intrinsic` param `node` (2 node types)
  - src/mir/mir_lowering.rb:4658 `MIRLowering#fiber_string_promotes` param `node` (2 node types)
  - src/mir/mir_lowering.rb:716 `MIRLowering#resolve_alloc_sym` param `target_node` (2 node types)
  - src/mir/mir_lowering.rb:7264 `MIRLowering#call_heap_provenance?` param `node` (2 node types)
- `MirNode` (MIR::*): 23 param slot(s)
  - src/mir/mir_checker.rb:340 `MIRChecker#walk_mir_node` param `node` (51 node types)
  - src/mir/mir_checker.rb:810 `MIRChecker#check_stmt_for_unhoisted` param `node` (48 node types)
  - src/mir/mir_lowering.rb:7477 `MIRLowering#emit_expr` param `node` (38 node types)
  - src/mir/mir_lowering.rb:180 `MIRLowering#mir_allocates?` param `node` (35 node types)
  - src/mir/mir_lowering.rb:6204 `MIRLowering#owned_return_transfer_binding?` param `init` (31 node types)
  - src/mir/mir_lowering.rb:782 `MIRLowering#mir_cast` param `mir_node` (28 node types)
  - src/mir/mir_lowering.rb:7276 `MIRLowering#call_union_return_needs_hoist?` param `expr` (25 node types)
  - src/mir/mir_checker.rb:749 `MIRChecker#expr_has_frame_alloc?` param `expr` (19 node types)
  - src/mir/mir_lowering.rb:238 `MIRLowering#hoist_owned_value_temp` param `expr` (19 node types)
  - src/mir/mir_lowering.rb:286 `MIRLowering#copy_container_borrow_if_needed` param `expr` (16 node types)
  - src/mir/mir_checker.rb:383 `MIRChecker#scan_expr_for_hpt_leak!` param `node` (14 node types)
  - src/mir/mir_lowering.rb:299 `MIRLowering#hoist_cleanup_entry` param `mir` (12 node types)
  - src/mir/mir_lowering.rb:7496 `MIRLowering#strip_try` param `mir_node` (10 node types)
  - src/mir/fsm_lowering.rb:194 `FsmLowering#wrap_step_as_stmt` param `mir` (8 node types)
  - src/mir/mir_emitter.rb:368 `MIREmitter#emit_flow_stmt` param `stmt` (8 node types)
  - src/mir/mir_lowering.rb:7489 `MIRLowering#try_catch_with_provenance` param `catch_body` (6 node types)
  - src/mir/mir_lowering.rb:7434 `MIRLowering#direct_index_get` param `index` (4 node types)
  - src/mir/mir_lowering.rb:7489 `MIRLowering#try_catch_with_provenance` param `fallback` (4 node types)
  - src/backends/pipeline_host.rb:551 `PipelineHost#mat_append` param `value_expr` (2 node types)
  - src/mir/mir_emitter.rb:216 `MIREmitter#sharded_map_template` param `node` (2 node types)
  - src/mir/mir_emitter.rb:223 `MIREmitter#sharded_map_substitute_common` param `node` (2 node types)
  - src/mir/mir_emitter.rb:889 `MIREmitter#emit_batch_window_emit` param `node` (2 node types)
  - src/mir/mir_lowering.rb:155 `MIRLowering#with_pending` param `node` (2 node types)
- `FsmOpsNode` (FsmOps::*): 4 param slot(s)
  - src/mir/fsm_ops.rb:281 `FsmOps::Emitter#emit_expr` param `expr` (11 node types)
  - src/mir/fsm_ops.rb:442 `FsmOps::Lowerer#lower_expr` param `expr` (10 node types)
  - src/mir/fsm_ops.rb:394 `FsmOps::Lowerer#lower_stmt` param `op` (8 node types)
  - src/mir/fsm_ops.rb:241 `FsmOps::Emitter#emit_stmt` param `op` (7 node types)

### Untyped Evidence Gaps
- The residual NoEvidence, by category x WHY, then listed with locations. Each is a triage candidate (dead code / missing test / should-be-void / untraceable arg), not a classifier defect.

|  | unseen | arg untraced | only nil | discarded return | collection no elements | struct unobserved | Total |
|---|---|---|---|---|---|---|---|
| Params | 40 | 52 | 12 | 0 | 0 | 0 | 104 |
| Returns | 4 | 0 | 0 | 0 | 0 | 0 | 4 |
| Struct/ivar | 0 | 0 | 0 | 0 | 0 | 23 | 23 |
| Collections | 0 | 0 | 0 | 0 | 159 | 0 | 159 |
| **Total** | 44 | 52 | 12 | 0 | 159 | 23 | 290 |
- `unseen`: Not reached by the collect workload (a superset of every suite) and no runtime record -- genuinely dead/unreachable, or a real missing test. Investigate or delete.
- `arg untraced`: Block / kwarg / splat arg -- the tracer types only positional named args (these are ~always Proc; low value)
- `only nil`: Only ever nil at runtime -- likely unused / optional-dead; verify it is reachable with a real value
- `discarded return`: Return value never consumed -- likely should be `sig { ... .void }`
- `collection no elements`: Collection never observed holding an element -- only-empty, or built/consumed off any instrumented path
- `struct unobserved`: Struct/class field never observed assigned during collect -- the tracer signal for fields is struct_field_runtime/ivar_runtime, not line coverage, so the method-oriented coverage split does not apply. Either the class is never constructed by the workload, or the field is always left at its default.
- 44 unseen
  - src/annotator-helpers/capabilities.rb:1364 `CapabilityAudit#audit_mark_bg_captures` param `body_exprs`
  - src/annotator-helpers/capabilities.rb:1364 `CapabilityAudit#audit_mark_bg_captures` param `is_parallel`
  - src/annotator-helpers/fixable_helpers.rb:1224 `FixableHelper#build_decl_cap_replace_fix` param `name`
  - src/annotator-helpers/fixable_helpers.rb:528 `FixableHelper#emit_overflow_suffix_fix!` param `node`
  - src/annotator-helpers/fixable_helpers.rb:528 `FixableHelper#emit_overflow_suffix_fix!` param `tok`
  - src/annotator-helpers/fixable_helpers.rb:528 `FixableHelper#emit_overflow_suffix_fix!` return
  - src/annotator-helpers/fixable_helpers.rb:806 `FixableHelper#emit_cap_field_needs_with!` param `name`
  - src/annotator-helpers/fixable_helpers.rb:935 `FixableHelper#emit_with_read_needs_write_lock!` param `var_node`
  - src/annotator-helpers/fixable_helpers.rb:935 `FixableHelper#emit_with_read_needs_write_lock!` return
  - src/annotator-helpers/pipe_analysis.rb:1162 `PipeAnalysis#pre_scan_node_for_sharded` param `node`
  - src/annotator-helpers/pipe_analysis.rb:1222 `PipeAnalysis#auto_detect_sharded_access` param `conc`
  - src/annotator-helpers/pipe_analysis.rb:1222 `PipeAnalysis#auto_detect_sharded_access` param `smooth_node`
  - src/annotator-helpers/pipe_analysis.rb:1272 `PipeAnalysis#walk_for_sharded_access` param `nodes`
  - src/annotator-helpers/pipe_analysis.rb:1306 `PipeAnalysis#walk_for_sharded_getindex` param `results`
  - src/annotator-helpers/test_annotation.rb:110 `TestAnnotation#visit_AssertRaises` param `node`
  - src/annotator.rb:3912 `SemanticAnnotator#visit_Placeholder` param `node`
  - src/annotator.rb:4368 `SemanticAnnotator#visit_Give` param `node`
  - src/annotator.rb:5969 `SemanticAnnotator#lifetime_violation_for_store` param `dest_depth`
  - src/annotator.rb:5969 `SemanticAnnotator#lifetime_violation_for_store` param `val_node`
  - src/annotator.rb:6287 `SemanticAnnotator#contains_self_call?` param `fn_name`
  - src/ast/ast.rb:263 `AST::Locatable#collection_return=` param `val`
  - src/ast/schemas.rb:43 `Schemas::ResourceSchema#initialize` param `as_type`
  - src/ast/schemas.rb:43 `Schemas::ResourceSchema#initialize` param `close_zig`
  - src/ast/schemas.rb:43 `Schemas::ResourceSchema#initialize` param `extern_module`
  - src/ast/schemas.rb:43 `Schemas::ResourceSchema#initialize` param `fields`
  - src/ast/schemas.rb:43 `Schemas::ResourceSchema#initialize` param `static_methods`
  - src/ast/schemas.rb:43 `Schemas::ResourceSchema#initialize` param `type_params`
  - src/backends/pipeline_host.rb:2622 `PipelineHost#bc_for_iter_range` param `range_lit`
  - src/backends/pipeline_host.rb:3476 `PipelineHost#extract_concurrent_error_policy_for_bc` param `expr`
  - src/backends/pipeline_host.rb:3787 `PipelineHost#lower_bc_concurrent_select_prune` param `inner_expr`
  - src/backends/pipeline_host.rb:3814 `PipelineHost#lower_bc_concurrent_where_prune` param `inner_expr`
  - src/backends/pipeline_rewriter.rb:765 `PipelineRewriter#patch_chain_source!` param `new_source`
  - src/backends/pipeline_rewriter.rb:765 `PipelineRewriter#patch_chain_source!` return
  - src/backends/transpiler.rb:48 `ZigTranspiler#collect_bg_blocks` param `node`
  - src/backends/transpiler.rb:48 `ZigTranspiler#collect_bg_blocks` return
  - src/mir/control_flow.rb:1493 `LoopFrameAnalysis#rhs_references_any?` param `names`
  - src/mir/fsm_transform/recursive_splitter.rb:425 `FsmTransform::RecursiveSplitter#emit_suspend` param `builder`
  - src/mir/fsm_transform/recursive_splitter.rb:425 `FsmTransform::RecursiveSplitter#emit_suspend` param `susp_tail`
  - src/mir/fsm_transform/segments.rb:237 `FsmTransform::Segments#stmt_unsupported?` param `stmt`
  - src/mir/fsm_transform/segments.rb:264 `FsmTransform::Segments#contains_suspend_anywhere?` param `stmts`
  - src/mir/fsm_transform/segments.rb:331 `FsmTransform::Segments#suspending_call?` param `expr`
  - src/mir/mir_emitter.rb:1486 `MIREmitter#emit_has_field` param `node`
  - src/mir/mir_emitter.rb:243 `MIREmitter#emit_raw_bc_as_zig` param `node`
  - src/mir/mir_lowering.rb:1682 `MIRLowering#infer_catch_value_allocator` param `expr`
- 52 arg untraced
  - src/annotator-helpers/auto_inference.rb:568 `ShapeEvidenceCollector#walk_for_shape_decls` param `block`
  - src/annotator-helpers/auto_inference.rb:728 `OperatorEvidenceCollector#walk_for_local_decls` param `block`
  - src/annotator-helpers/capabilities.rb:57 `Capabilities#validate!` param `error_handler`
  - src/annotator-helpers/fixable_helpers.rb:1251 `FixableHelper#emit_with_cap_mismatch!` param `kw`
  - src/annotator-helpers/fixable_helpers.rb:740 `FixableHelper#emit_match_partial_fix!` param `kwargs`
  - src/annotator-helpers/pipe_analysis.rb:103 `PipeAnalysis#mark_observable_terminal!` param `type_kwargs`
  - src/annotator-helpers/pipe_analysis.rb:1801 `PipeAnalysis#with_soa_tracking` param `blk`
  - src/annotator-helpers/pipe_analysis.rb:84 `PipeAnalysis#lift_to_observable_if_terminal!` param `type_kwargs`
  - src/annotator.rb:1079 `SemanticAnnotator#walk_ast` param `block`
  - src/ast/ast.rb:107 `AST#each_bg_block_in_stmt` param `block`
  - src/ast/ast.rb:124 `AST#_expr_each_bg_block_shallow` param `block`
  - src/ast/ast.rb:147 `AST#each_capture_analysis` param `block`
  - src/ast/ast.rb:162 `AST#_expr_each_concurrent_capture` param `block`
  - src/ast/ast.rb:18 `AST#walk_body` param `visitor`
  - src/ast/ast.rb:376 `AST::Locatable#finalize_storage!` param `schema_lookup`
  - src/ast/ast.rb:60 `AST#each_bg_block` param `block`
  - src/ast/ast.rb:67 `AST#_bg_visit_recursive` param `block`
  - src/ast/ast.rb:85 `AST#_expr_each_bg_block_recursive` param `block`
  - src/ast/diagnostic_registry.rb:2538 `DiagnosticRegistry#format` param `kwargs`
  - src/ast/parser.rb:26 `Parser#stmt` param `block`
  - src/ast/parser.rb:42 `Parser#primary` param `block`
  - src/ast/parser.rb:57 `Parser#suffix` param `block`
  - src/ast/scope.rb:324 `ScopeHelper#with_new_scope` param `blk`
  - src/ast/source_error.rb:31 `ErrorHelper#error!` param `kwargs`
  - src/ast/type.rb:1334 `Type#slot_size` param `lookup_block`
  - src/ast/type.rb:1381 `Type#copyable?` param `lookup_block`
  - src/ast/type.rb:1413 `Type#bg_capture_is_value_copy?` param `lookup_block`
  - src/ast/type.rb:1440 `Type#implicitly_copyable?` param `lookup_block`
  - src/backends/pipeline_host.rb:76 `PipelineHost#with_optional_named_binding` param `blk`
  - src/backends/pipeline_host.rb:84 `PipelineHost#with_named_binding` param `blk`
  - src/backends/pipeline_host.rb:98 `PipelineHost#with_fiber_capture_map` param `blk`
  - src/lsp/document_store.rb:82 `LSP::DocumentStore#each` param `block`
  - src/mir/concurrency_checks.rb:185 `ConcurrencyChecks#walk_with_blocks` param `blk`
  - src/mir/concurrency_checks.rb:199 `ConcurrencyChecks#walk_scope_no_nested_with` param `blk`
  - src/mir/concurrency_checks.rb:222 `ConcurrencyChecks#walk_scope_for_nested_with` param `blk`
  - src/mir/control_flow.rb:1629 `LoopFrameAnalysis#scan_direct` param `block`
  - src/mir/control_flow.rb:1657 `LoopFrameAnalysis#walk_all_nodes` param `block`
  - src/mir/control_flow.rb:1984 `BorrowChecker#walk_for_was_moved` param `block`
  - src/mir/control_flow.rb:900 `OwnershipDataflow#walk_expr` param `block`
  - src/mir/control_flow.rb:945 `OwnershipDataflow#walk_expr_skip_copy` param `block`
  - src/mir/escape_analysis.rb:436 `EscapeAnalysis#e2_walk_calls` param `blk`
  - src/mir/escape_analysis.rb:441 `EscapeAnalysis#e2_walk_calls_in_expr` param `blk`
  - src/mir/escape_analysis.rb:792 `EscapeAnalysis#unify_caller_attr` param `project`
  - src/mir/fsm_transform/liveness.rb:240 `FsmTransform::Liveness#walk_idents` param `block`
  - src/mir/fsm_transform/recursive_splitter.rb:78 `FsmTransform::RecursiveSplitter::Builder#with_alias_overrides` param `blk`
  - src/mir/mir_checker.rb:334 `MIRChecker#walk_mir` param `block`
  - src/mir/mir_checker.rb:340 `MIRChecker#walk_mir_node` param `block`
  - src/mir/mir_checker.rb:931 `MIRChecker#each_sub_expr` param `blk`
  - src/mir/mir_lowering.rb:7552 `MIRLowering#with_fiber_capture_map` param `blk`
  - src/mir/promotion_plan.rb:687 `CleanupClassifier#entry` param `extra`
  - ... +2 more
- 12 only nil
  - src/annotator.rb:6530 `SemanticAnnotator#og_set_moved` param `consumer_param_type`
  - src/backends/pipeline_generator.rb:28 `PipelineGenerator#with_pipeline_context` param `shard_hash`
  - src/backends/pipeline_generator.rb:28 `PipelineGenerator#with_pipeline_context` param `shard_idx`
  - src/backends/pipeline_generator.rb:28 `PipelineGenerator#with_pipeline_context` param `shard_key`
  - src/backends/pipeline_generator.rb:28 `PipelineGenerator#with_pipeline_context` param `shard_map`
  - src/backends/pipeline_generator.rb:28 `PipelineGenerator#with_pipeline_context` param `soa`
  - src/backends/pipeline_host.rb:104 `PipelineHost#task_config_zig` param `computed_tier`
  - src/mir/control_flow.rb:1039 `UseAfterMoveChecker#check` param `can_fail_fns`
  - src/mir/mir_checker.rb:79 `MIRChecker#initialize` param `fn_name`
  - src/tools/migration_suggester_helpers.rb:170 `MigrationSuggesterHelpers#rhs_uses_alias_only_for_field_get?` param `field_name`
  - src/tools/stack_verifier.rb:334 `StackVerifier#deepest_path_cost` param `fn_nodes`
  - src/tools/stack_verifier.rb:384 `StackVerifier#compute_main_optimal_tier` param `fn_nodes`
- 159 collection no elements
  - src/annotator-helpers/auto_inference.rb:50 `T.let` ``
  - src/annotator-helpers/auto_inference.rb:58 `T.let` ``
  - src/annotator-helpers/auto_inference.rb:691 `T.let` ``
  - src/annotator-helpers/capabilities.rb:130 `T.let` ``
  - src/annotator-helpers/capabilities.rb:27 `T.let` ``
  - src/annotator-helpers/capabilities.rb:34 `Capabilities#errors_for` return
  - src/annotator-helpers/function_context.rb:27 `T.let` ``
  - src/annotator-helpers/function_signature.rb:66 `FunctionSignature#initialize` param `owner_type_params`
  - src/annotator-helpers/generic_analysis.rb:291 `T.let` ``
  - src/annotator-helpers/lock_helper.rb:381 `LockHelper#verify_handler_reachability!` param `types_with_self`
  - src/annotator-helpers/lock_helper.rb:44 `T.let` ``
  - src/annotator-helpers/lock_helper.rb:45 `T.let` ``
  - src/annotator-helpers/lock_helper.rb:46 `T.let` ``
  - src/annotator-helpers/lock_helper.rb:49 `T.let` ``
  - src/annotator-helpers/lock_helper.rb:53 `T.let` ``
  - src/annotator-helpers/lock_helper.rb:54 `T.let` ``
  - src/annotator-helpers/pipe_analysis.rb:1139 `PipeAnalysis#collect_sharded_names` param `names`
  - src/annotator-helpers/pipe_analysis.rb:1228 `T.let` ``
  - src/annotator-helpers/pipe_analysis.rb:133 `T.let` ``
  - src/annotator.rb:103 `T.let` ``
  - src/annotator.rb:104 `T.let` ``
  - src/annotator.rb:105 `T.let` ``
  - src/annotator.rb:107 `T.let` ``
  - src/annotator.rb:1099 `T.let` ``
  - src/annotator.rb:111 `T.let` ``
  - src/annotator.rb:112 `T.let` ``
  - src/annotator.rb:113 `T.let` ``
  - src/annotator.rb:114 `T.let` ``
  - src/annotator.rb:125 `T.let` ``
  - src/annotator.rb:126 `T.let` ``
  - src/annotator.rb:128 `T.let` ``
  - src/annotator.rb:132 `T.let` ``
  - src/annotator.rb:134 `T.let` ``
  - src/annotator.rb:135 `T.let` ``
  - src/annotator.rb:2304 `SemanticAnnotator#collect_implicit_type_params` param `explicit`
  - src/annotator.rb:276 `SemanticAnnotator#flush_deferred_with_validations!` return
  - src/annotator.rb:4175 `SemanticAnnotator#visit_MoveNode` return
  - src/annotator.rb:6311 `T.let` ``
  - src/annotator.rb:6528 `SemanticAnnotator#og_move` return
  - src/annotator.rb:6530 `SemanticAnnotator#og_set_moved` return
  - src/annotator.rb:96 `T.let` ``
  - src/annotator.rb:97 `T.let` ``
  - src/ast/ast.rb:1308 `T.let` ``
  - src/ast/ast.rb:1321 `T.let` ``
  - src/ast/ast.rb:1340 `T.let` ``
  - src/ast/ast.rb:553 `AST::FunctionDef.captures`
  - src/ast/ast.rb:664 `AST::StructDef.type_params`
  - src/ast/ast.rb:703 `AST#lazy_fields` return
  - src/ast/ast.rb:822 `AST::MethodCall.args`
  - src/ast/diagnostic_registry.rb:2538 `DiagnosticRegistry#format` param `args`
  - ... +109 more
- 23 struct unobserved
  - `OwnershipGraph::Node` (src/mir/ownership_graph.rb:21): 4 field(s) -- move_action, move_col, move_consumer_param_type, move_line
  - `MIR::RawBc` (src/mir/mir.rb:1741): 3 field(s) -- args, stdlib_def, template
  - `AST::Cast` (src/ast/ast.rb:856): 2 field(s) -- target, value
  - `AST::MatchStatement` (src/ast/ast.rb:1174): 2 field(s) -- exhaustive, takes
  - `MIR::FsmTailCondSkip` (src/mir/mir.rb:804): 2 field(s) -- cond_zig, skip_step
  - `MIR::HasField` (src/mir/mir.rb:1628): 2 field(s) -- expr, field
  - `MIR::InlineZig` (src/mir/mir.rb:1702): 2 field(s) -- allocs, target_var
  - `MIR::TryOrPanic` (src/mir/mir.rb:270): 2 field(s) -- expr, panic_msg
  - `AST::Copy` (src/ast/ast.rb:971): 1 field(s) -- value
  - `AST::Require` (src/ast/ast.rb:872): 1 field(s) -- path
  - `MIR::TryCatch` (src/mir/mir.rb:1513): 1 field(s) -- heap_provenance
  - `MIR::UnionVariantGet` (src/mir/mir.rb:1550): 1 field(s) -- object

### Signature Slot Evidence
- primary reason: the single strongest current explanation for why this weak/untyped signature slot has not been safely strengthened
- evidence count: runtime observations plus static callsite/origin records feeding the slot
- candidate action: an existing nil-kill action that could rewrite this slot, if one exists

#### Param Slot Evidence
- blocked: unknown callsite expression: 306 slot(s); weak 0, untyped 306; evidence 2956
  - src/annotator.rb:250 `SemanticAnnotator#program_has_auto?` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; src/annotator.rb:151 node; src/annotator.rb:258 c; src/annotator.rb:260 v; protocol hint strong d ...; evidence 119
  - src/backends/string_concat_rewriter.rb:45 `StringConcatRewriter#rewrite_children!` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; src/backends/pipeline_rewriter.rb:44 node; src/backends/string_concat_rew ...; evidence 84
  - src/backends/string_concat_rewriter.rb:78 `StringConcatRewriter#string_concat?` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; src/backends/string_concat_rewriter.rb:31 node; src/backends/string_concat_r ...; evidence 84
  - src/backends/pipeline_rewriter.rb:57 `PipelineRewriter#rewrite_children!` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; src/backends/pipeline_rewriter.rb:44 node; src/backends/string_concat_rewriter.rb: ...; evidence 61
  - src/mir/mir_checker.rb:908 `MIRChecker#allocating_expr?` expr; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; src/mir/mir_checker.rb:890 expr; src/mir/mir_checker.rb:898 expr; protocol hint strong direct proto ...; evidence 40
  - src/annotator.rb:6088 `SemanticAnnotator#collect_bg_sources_walk` v; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; src/annotator.rb:6083 v; src/annotator.rb:6090 x; src/annotator.rb:6091 x; protocol hint weak ...; evidence 36
  - src/ast/ast.rb:107 `AST#each_bg_block_in_stmt` stmt; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; src/mir/mir_pass.rb:229 stmt; src/mir/mir_pass.rb:295 stmt; src/mir/mir_pass.rb:428 stmt; protocol hint stron ...; evidence 35
  - src/ast/ast.rb:67 `AST#_bg_visit_recursive` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; src/ast/ast.rb:63 n; protocol hint strong direct protocol #args, #child_bodies, #object, #value; evidence 34
- candidate: runtime-only param observation: 260 slot(s); weak 0, untyped 260; evidence 962
  - src/mir/fsm_transform/recursive_splitter.rb:153 `FsmTransform::RecursiveSplitter#split` body; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; src/annotator-helpers/function_analysis.rb:614 "."; src/annotator-helpe ...; evidence 46
  - src/mir/thunk_transform/recursive_splitter.rb:88 `ThunkTransform::RecursiveSplitter#split` body; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; src/annotator-helpers/function_analysis.rb:614 "."; src/annotator-he ...; evidence 46
  - src/backends/pipeline_generator.rb:28 `PipelineGenerator#with_pipeline_context` placeholder; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; src/backends/pipeline_host.rb:180 placeholder; src/backends/pipeline_hos ...; evidence 40
  - src/mir/fsm_transform.rb:236 `FsmTransform#contains_suspend_anywhere?` stmts; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; src/mir/fsm_transform.rb:220 s.do_branch; src/mir/fsm_transform.rb:223 s.body; src/mir/ ...; evidence 34
  - src/mir/fsm_transform/recursive_splitter.rb:294 `FsmTransform::RecursiveSplitter#contains_suspend_anywhere?` stmts; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; src/mir/fsm_transform.rb:220 s.do_branch; src/mir ...; evidence 34
  - src/ast/source_error.rb:121 `ErrorHelper#fixable!` raise_in_collector; `T.untyped`; boolean pair; T::Boolean candidate; untyped literal/static expression; src/annotator-helpers/capabilities.rb:300 false; src/annotator-helpers/fixable_helpers.rb ...; evidence 25
  - src/mir/fsm_wrapper_emitter.rb:571 `FsmWrapperEmitter#empty?` s; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; src/mir/fsm_wrapper_emitter.rb:96 s.captures_decl_zig; src/mir/fsm_wrapper_emitter.rb:119 step.rt_su ...; evidence 19
  - src/mir/fsm_wrapper_emitter.rb:580 `FsmWrapperEmitter#indent_block` text; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; src/mir/fsm_wrapper_emitter.rb:115 l; src/mir/fsm_wrapper_emitter.rb:198 render_dispatch(s. ...; evidence 18
- blocked: forwarded return argument: 187 slot(s); weak 0, untyped 187; evidence 5595
  - src/ast/source_error.rb:31 `ErrorHelper#error!` node_or_token; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; src/annotator-helpers/capabilities.rb:133 var_node; src/annotator-helpers/capabilities.rb:267 node; s ...; evidence 471
  - src/ast/ast.rb:308 `AST::Locatable#full_type=` val; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; src/annotator-helpers/function_analysis.rb:140 :Type; src/annotator-helpers/function_analysis.rb:163 substituted ...; evidence 288
  - src/mir/mir_lowering.rb:376 `MIRLowering#lower` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; src/backends/pipeline_host.rb:163 substituted; src/backends/pipeline_host.rb:172 substituted; src/backends/pip ...; evidence 246
  - src/mir/mir_emitter.rb:43 `MIREmitter#emit` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; src/backends/importer.rb:213 item; src/backends/importer.rb:214 item; src/backends/pipeline_host.rb:164 mir_node;  ...; evidence 228
  - src/annotator.rb:345 `SemanticAnnotator#visit` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; src/annotator-helpers/capabilities.rb:458 gcap[:guard_expr]; src/annotator-helpers/capabilities.rb:522 expr; sr ...; evidence 205
  - src/backends/pipeline_host.rb:111 `PipelineHost#visit` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; src/annotator-helpers/capabilities.rb:458 gcap[:guard_expr]; src/annotator-helpers/capabilities.rb:522  ...; evidence 143
  - src/mir/escape_analysis.rb:441 `EscapeAnalysis#e2_walk_calls_in_expr` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; src/mir/escape_analysis.rb:437 stmt; src/mir/escape_analysis.rb:446 a; src/mir/escape_an ...; evidence 98
  - src/mir/mir_lowering.rb:7477 `MIRLowering#emit_expr` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; src/mir/fsm_lowering.rb:339 lower(clause[:message]); src/mir/fsm_ops.rb:244 op.value; src/mir/fsm_ops.rb: ...; evidence 98
- weak declared type: array element evidence needed: 172 slot(s); weak 172, untyped 0; evidence 950
  - src/mir/fsm_transform/recursive_splitter.rb:125 `FsmTransform::RecursiveSplitter::Builder#push` stmts; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; src/annotator-helpers/lock_helper.rb:298  ...; evidence 43
  - src/mir/fsm_ops.rb:179 `FsmOps::DSL#call` args; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; src/annotator-helpers/capabilities.rb:60 errs.first; src/annotator-helpers/method_analysis.rb:84 ...; evidence 35
  - src/mir/mir_lowering.rb:511 `MIRLowering#lower_body` stmts; T.nilable(T::Array[`T.untyped`]); weak declared type: array element evidence needed; untyped forwarded return; src/backends/pipeline_host.rb:182 substituted; src/mir/mir_lowering.rb:55 ...; evidence 34
  - src/ast/ast.rb:18 `AST#walk_body` body; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; src/annotator-helpers/with_match_check.rb:57 fn.body; src/annotator-helpers/with_match_check.rb:248 fn.b ...; evidence 33
  - src/ast/parser.rb:42 `Parser#primary` pattern; T.nilable(T::Array[`T.untyped`]); weak declared type: array element evidence needed; untyped struct/array/collection value; src/ast/parser.rb:202 ['CAST', '(', :expression, 'AS', :type_annotation,  ...; evidence 31
  - src/mir/mir_lowering.rb:7397 `MIRLowering#emit_builtin` args; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped struct/array/collection value; src/mir/mir_lowering.rb:997 [MIR::Ident.new(de[:zig_type]), alloc_ref ...; evidence 29
  - src/annotator-helpers/fixable_helpers.rb:139 `FixableHelper#emit_typo_suggestion!` candidates; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; src/annotator-helpers/capabilities.rb:329 [own_al ...; evidence 26
  - src/annotator.rb:1095 `SemanticAnnotator#visit_stmts` stmts; T.nilable(T::Array[`T.untyped`]); weak declared type: array element evidence needed; untyped forwarded return; src/annotator-helpers/function_analysis.rb:30 body; src/annotator-helper ...; evidence 22
- weak declared type: hash key/value evidence needed: 146 slot(s); weak 146, untyped 0; evidence 400
  - src/annotator-helpers/auto_inference.rb:589 `ShapeEvidenceCollector#walk` name_map; T::Hash[String, T::Hash[`T.untyped`, `T.untyped`]]; weak declared type: hash key/value evidence needed; untyped struct/array/collection value; src/annotator-helpe ...; evidence 11
  - src/annotator-helpers/generic_analysis.rb:356 `GenericAnalysis#apply_type_subst` subst; T::Hash[Symbol, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped struct/array/collection value; src/annotator-helpers/generic_analy ...; evidence 11
  - src/ast/schemas.rb:125 `Schemas#as_union_schema` schema; T.nilable(T::Hash[`T.untyped`, `T.untyped`]); weak declared type: hash key/value evidence needed; untyped unknown expression; src/mir/control_flow.rb:626 schema; src/mir/promotion_plan.rb:9 ...; evidence 11
  - src/mir/control_flow.rb:584 `OwnershipDataflow#mark_moved!` state; T::Hash[String, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped struct/array/collection value; src/mir/control_flow.rb:608 state; src/mir/control_flow. ...; evidence 11
  - src/mir/mir_pass.rb:226 `MIRPass#walk_for_bg_captures` bindings; T::Hash[String, T::Hash[Symbol, `T.untyped`]]; weak declared type: hash key/value evidence needed; untyped struct/array/collection value; src/mir/mir_pass.rb:222 bindings; src/mir ...; evidence 11
  - src/mir/promotion_plan.rb:416 `CleanupClassifier#walk_expression_bg_bodies` bindings; T::Hash[String, T::Hash[Symbol, `T.untyped`]]; weak declared type: hash key/value evidence needed; untyped struct/array/collection value; src/mir/promotion_pl ...; evidence 9
  - src/annotator-helpers/auto_inference.rb:751 `OperatorEvidenceCollector#walk_binops` name_to_slot; T::Hash[String, T::Array[`T.untyped`]]; weak declared type: hash key/value evidence needed; untyped struct/array/collection value; src/annotator-h ...; evidence 8
  - src/annotator-helpers/lock_helper.rb:164 `LockHelper#lock_identity_of` cap; T::Hash[Symbol, `T.untyped`]; weak declared type: hash key/value evidence needed; untyped struct/array/collection value; src/annotator-helpers/lock_helper.rb:77 cap; sr ...; evidence 7
- blocked: no static callsite evidence: 90 slot(s); weak 0, untyped 90; evidence 54
  - src/ast/symbol_entry.rb:151 `SymbolEntry#initialize` reg; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none observed; analysis gaps: captured in @reg ...; evidence 7
  - src/ast/type.rb:199 `Type#initialize` raw_input; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none observed; analysis gaps: aliases seen other at src ...; evidence 5
  - src/annotator-helpers/function_signature.rb:66 `FunctionSignature#initialize` return_type; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none observed ...; evidence 4
  - src/ast/symbol_entry.rb:151 `SymbolEntry#initialize` type; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none observed; analysis gaps: captured in @ty ...; evidence 4
  - src/annotator-helpers/function_signature.rb:66 `FunctionSignature#initialize` return_lifetime; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none obse ...; evidence 3
  - src/ast/fixable_error.rb:99 `FixableFinding#initialize` token; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none observed; analysis gaps: captured in ...; evidence 3
  - src/ast/source_error.rb:157 `SourceError#initialize` token; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none observed; analysis gaps: captured in @t ...; evidence 3
  - src/ast/symbol_entry.rb:151 `SymbolEntry#initialize` mutable; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; no static callsite origin; protocol hint direct protocol: none observed; analysis gaps: captured in  ...; evidence 3
- weak declared type: union: 18 slot(s); weak 18, untyped 0; evidence 42
  - src/tools/lint_fix_rewriter.rb:253 `LintFixRewriter#to_type` t; T.any(Symbol, Type); weak declared type: union; untyped forwarded return; src/annotator-helpers/union.rb:74 rp[:type]; src/annotator-helpers/union.rb:75 sig.params[i][:type]; src ...; evidence 8
  - src/annotator-helpers/effects.rb:1008 `EffectTracker#validate_tight_node!` loop_node; T.any(AST::WhileLoop, AST::ForRange); weak declared type: union; untyped unknown expression; src/annotator-helpers/effects.rb:1004 loop_node; src/annotator- ...; evidence 6
  - src/mir/mir_lowering.rb:5957 `MIRLowering#compose_capability_wrap` inner_mir; T.any(MIR::ContainerInit, MIR::StructInit); weak declared type: union; untyped unknown expression; src/mir/mir_lowering.rb:2428 inner; src/mir/mir_lowering.rb:6058  ...; evidence 6
  - src/annotator.rb:4800 `SemanticAnnotator#retryable_with_fallible_body_error!` sources; T.nilable(T.any(T::Array[`T.untyped`], T::Array[`T.untyped`])); weak declared type: union; untyped unknown expression; src/annotator.rb:4568 fallible_sources;  ...; evidence 3
  - src/mir/mir_pass.rb:388 `MIRPass#bg_inner_bindings` bg_node; T.any(AST::BgBlock, AST::BgStreamBlock); weak declared type: union; untyped unknown expression; src/mir/mir_pass.rb:361 stmt; src/mir/mir_pass.rb:371 val; src/mir/mir_pass.rb:376 a; evidence 3
  - src/annotator-helpers/fixable_helpers.rb:197 `FixableHelper#variant_anchor_from_unionlit` node; T.any(AST::StructLit, AST::UnionVariantLit); weak declared type: union; untyped unknown expression; src/annotator-helpers/union.rb:153 node; src/a ...; evidence 2
  - src/annotator-helpers/fixable_helpers.rb:358 `FixableHelper#emit_use_of_moved_in_loop_error!` node; T.any(AST::WhileBindLoop, AST::WhileLoop); weak declared type: union; untyped unknown expression; src/annotator.rb:1912 node; src/annotator.rb ...; evidence 2
  - src/mir/mir_lowering.rb:4085 `MIRLowering#enforce_bg_capture_strategies!` node; T.any(AST::BgBlock, AST::BgStreamBlock); weak declared type: union; untyped unknown expression; src/mir/mir_lowering.rb:3814 node; src/mir/mir_lowering.rb:4171 no ...; evidence 2
- blocked: runtime union policy: 15 slot(s); weak 0, untyped 15; evidence 7503
  - src/mir/ownership_graph.rb:293 OwnershipGraph#[] path; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped instance variable; src/annotator-helpers/auto_inference.rb:45 String; src/annotator-helpers/auto_inference.rb:50 `T.untyped`; s ...; evidence 5217
  - src/ast/type.rb:355 Type#== other; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped instance variable; src/annotator-helpers/auto_inference.rb:440 b; src/annotator-helpers/auto_inference.rb:444 b_sym; src/annotator-helpers/auto_i ...; evidence 1691
  - src/ast/source_error.rb:31 `ErrorHelper#error!` code_or_message; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; src/annotator-helpers/capabilities.rb:133 :WITH_CAP_BAD_TARGET; src/annotator-helpers/capa ...; evidence 408
  - src/ast/scope.rb:24 `Scope#declare` reg; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; src/annotator-helpers/capabilities.rb:575 nil; src/annotator-helpers/capabilities.rb:775 nil; src/annotator-helper ...; evidence 67
  - src/annotator-helpers/effects.rb:1008 `EffectTracker#validate_tight_node!` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; src/annotator-helpers/effects.rb:1004 s; src/annotator-helpers/effects.rb: ...; evidence 40
  - src/annotator.rb:6519 `SemanticAnnotator#og_declare` node; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; src/annotator-helpers/capabilities.rb:777 nil; src/annotator-helpers/capabilities.rb:795 nil; sr ...; evidence 22
  - src/backends/pipeline_rewriter.rb:307 `PipelineRewriter#fuse_pipeline` terminal; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; src/backends/pipeline_rewriter.rb:184 terminal; src/backends/pipeline_rewr ...; evidence 14
  - src/backends/pipeline_host.rb:3924 `PipelineHost#build_bounded_concurrent_callback` return_type; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; src/backends/pipeline_host.rb:4034 result_t; src/backends/ ...; evidence 13
- blocked: collection/hash argument evidence: 12 slot(s); weak 0, untyped 12; evidence 127
  - src/mir/control_flow.rb:1657 `LoopFrameAnalysis#walk_all_nodes` nodes; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; src/mir/control_flow.rb:1668 child; src/mir/control_flow.rb:1671 node; src/mir/c ...; evidence 79
  - src/annotator-helpers/pipe_analysis.rb:1801 `PipeAnalysis#with_soa_tracking` item_type; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; src/annotator-helpers/pipe_analysis.rb:282 item_type; src/annot ...; evidence 12
  - src/mir/fsm_ops.rb:575 `FsmOps#walk` block; `T.untyped`; slot not observed: source index did not model this param shape; untyped struct/array/collection value; src/annotator-helpers/auto_inference.rb:550 name_map; src/annotator-helpers/auto_inf ...; evidence 10
  - src/mir/thunk_transform/recursive_splitter.rb:194 `ThunkTransform::RecursiveSplitter#contains_any_call?` names_set; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; src/mir/thunk_transform/recursive_s ...; evidence 6
  - src/annotator-helpers/fixable_helpers.rb:59 `FixableHelper#closest_name` candidates; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; src/annotator-helpers/fixable_helpers.rb:103 candidates; src/annot ...; evidence 5
  - src/backends/transpiler.rb:48 `ZigTranspiler#collect_bg_blocks` result; `T.untyped`; slot not observed: method was not hit; untyped struct/array/collection value; src/backends/transpiler.rb:51 result; src/backends/transpiler.rb:54 result; src/b ...; evidence 4
  - src/annotator-helpers/pipe_analysis.rb:1306 `PipeAnalysis#walk_for_sharded_getindex` nodes; `T.untyped`; slot not observed: method was not hit; untyped struct/array/collection value; src/annotator-helpers/pipe_analysis.rb:1290 [node.value]; src ...; evidence 3
  - src/annotator-helpers/pipe_analysis.rb:1778 `PipeAnalysis#check_soa_opportunity!` item_type; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; src/annotator-helpers/pipe_analysis.rb:1805 item_type; pro ...; evidence 3
- weak declared type: collection element evidence needed: 10 slot(s); weak 10, untyped 0; evidence 24
  - src/annotator-helpers/pipe_analysis.rb:1139 `PipeAnalysis#collect_sharded_names` names; T::Set[`T.untyped`]; weak declared type: collection element evidence needed; untyped struct/array/collection value; src/annotator-helpers/pipe_analysis.rb:1 ...; evidence 4
  - src/annotator-helpers/fixable_helpers.rb:1427 `FixableHelper#build_auto_op_evidence_block` ops; T::Set[`T.untyped`]; weak declared type: collection element evidence needed; untyped unknown expression; src/annotator-helpers/fixable_helpers.rb:15 ...; evidence 3
  - src/annotator-helpers/with_match_check.rb:348 `WithMatchCheck#expand_snapshotted` family_set; T::Set[`T.untyped`]; weak declared type: collection element evidence needed; untyped forwarded return; src/annotator-helpers/with_match_check.rb:337 s ...; evidence 3
  - src/annotator-helpers/lock_helper.rb:381 `LockHelper#verify_handler_reachability!` types_with_self; T::Set[`T.untyped`]; weak declared type: collection element evidence needed; untyped unknown expression; src/annotator-helpers/lock_helper.rb:37 ...; evidence 2
  - src/annotator-helpers/test_annotation.rb:160 `TestAnnotation#validate_strict_io!` stubbed_fns; T::Set[`T.untyped`]; weak declared type: collection element evidence needed; untyped struct/array/collection value; src/annotator-helpers/test_annota ...; evidence 2
  - src/annotator.rb:1064 `SemanticAnnotator#collect_pipe_input_types` types; T::Set[`T.untyped`]; weak declared type: collection element evidence needed; untyped unknown expression; src/annotator.rb:794 snap_types; candidate action narrow_generic_ ...; evidence 2
  - src/annotator.rb:6411 `SemanticAnnotator#find_mutual_max_depth_callee` call_names; T::Set[`T.untyped`]; weak declared type: collection element evidence needed; untyped struct/array/collection value; src/annotator.rb:6361 call_names; candidate a ...; evidence 2
  - src/mir/control_flow.rb:1967 `BorrowChecker#_collect_share_moves` names; T::Set[`T.untyped`]; weak declared type: collection element evidence needed; untyped struct/array/collection value; src/mir/control_flow.rb:1945 names; candidate action na ...; evidence 2
- weak declared type: nested `T.untyped`: 6 slot(s); weak 6, untyped 0; evidence 0
  - src/annotator.rb:65 `SemanticAnnotator#with_conditional_context` blk; `T.proc`.returns(`T.untyped`); weak declared type: nested `T.untyped`; untyped unknown expression; no static callsite origin; evidence 0
  - src/ast/parser.rb:3905 `Parser#parse_comma_seq` blk; `T.proc`.returns(`T.untyped`); weak declared type: nested `T.untyped`; untyped unknown expression; no static callsite origin; evidence 0
  - src/backends/pipeline_generator.rb:28 `PipelineGenerator#with_pipeline_context` blk; `T.proc`.returns(`T.untyped`); weak declared type: nested `T.untyped`; untyped unknown expression; no static callsite origin; evidence 0
  - src/backends/pipeline_host.rb:458 `PipelineHost#lower_pipeline_block` blk; `T.proc`.params(items_ident: String, label: String).returns(T::Array[`T.untyped`]); weak declared type: nested `T.untyped`; untyped unknown expression; no static callsite or ...; evidence 0
  - src/mir/mir_lowering.rb:112 `MIRLowering#lower_scoped` blk; `T.proc`.returns(`T.untyped`); weak declared type: nested `T.untyped`; untyped unknown expression; no static callsite origin; evidence 0
  - src/mir/mir_lowering.rb:140 `MIRLowering#lower_head` blk; `T.proc`.returns(`T.untyped`); weak declared type: nested `T.untyped`; untyped unknown expression; no static callsite origin; evidence 0
- candidate: static callsite backflow: 1 slot(s); weak 0, untyped 1; evidence 4
  - src/backends/pipeline_rewriter.rb:765 `PipelineRewriter#patch_chain_source!` node; `T.untyped`; slot not observed: method was not hit; untyped unknown expression; src/backends/pipeline_rewriter.rb:131 node; src/backends/pipeline_rewriter.rb:150 ...; evidence 4
- nil only observed: 1 slot(s); weak 0, untyped 1; evidence 4
  - src/backends/pipeline_generator.rb:28 `PipelineGenerator#with_pipeline_context` acc; `T.untyped`; nil only observed; untyped literal/static expression; src/backends/pipeline_host.rb:1322 "acc"; src/backends/pipeline_host.rb:2944 curr_var; src/b ...; evidence 4
- slot not observed: method was not hit: 1 slot(s); weak 0, untyped 1; evidence 1
  - src/annotator-helpers/fixable_helpers.rb:1224 `FixableHelper#build_decl_cap_replace_fix` old_sigil; `T.untyped`; slot not observed: method was not hit; untyped literal/static expression; src/annotator-helpers/fixable_helpers.rb:939 '@locked'; evidence 1

#### Return Slot Evidence
- weak declared type: array element evidence needed: 219 slot(s); weak 219, untyped 0; evidence 716
  - src/annotator-helpers/capabilities.rb:126 `CapabilityHelper#validate_capability` return; T.nilable(T::Array[T::Hash[`T.untyped`, `T.untyped`]]); weak declared type: array element evidence needed; untyped forwarded return; call_untyped @deferred_w ...; evidence 24
  - src/backends/pipeline_rewriter.rb:601 `PipelineRewriter#build_terminal_action` return; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped forwarded return; static [assign]; static [if_stmt]; static [AST::Assignmen ...; evidence 14
  - src/mir/fsm_transform/segments.rb:162 `FsmTransform::Segments#split_while_loop_next` return; T.nilable(T::Array[`T.untyped`]); weak declared type: array element evidence needed; untyped struct/array/collection value; nil nil; nil nil; nil nil; evidence 12
  - src/backends/pipeline_host.rb:2316 `PipelineHost#lower_binding_fold` return; T.nilable(T::Array[`T.untyped`]); weak declared type: array element evidence needed; untyped struct/array/collection value; static [init, bc_wrap_stages(stages, placeh ...; evidence 10
  - src/annotator-helpers/auto_inference.rb:188 `AutoConstraintCollector#record_local` return; T.nilable(T::Array[`T.untyped`]); weak declared type: array element evidence needed; untyped literal/static expression; nil return; nil return; nil retur ...; evidence 9
  - src/annotator-helpers/auto_inference.rb:228 `AutoConstraintCollector#record_reassignment_sources` return; T.nilable(T::Array[`T.untyped`]); weak declared type: array element evidence needed; untyped forwarded return; nil return; nil return; nil ...; evidence 9
  - src/annotator-helpers/auto_inference.rb:615 `ShapeEvidenceCollector#record_method_call` return; T.nilable(T::Array[`T.untyped`]); weak declared type: array element evidence needed; untyped forwarded return; nil return; nil return; call_untyped  ...; evidence 9
  - src/ast/type.rb:932 `Type#resolve_resource_close` return; T::Array[`T.untyped`]; weak declared type: array element evidence needed; untyped struct/array/collection value; static [false, nil]; static [true, "{0}.deinit(rt.heapAlloc())"]; static  ...; evidence 9
- weak declared type: hash key/value evidence needed: 107 slot(s); weak 107, untyped 0; evidence 393
  - src/mir/mir_lowering.rb:299 `MIRLowering#hoist_cleanup_entry` return; T.nilable(T::Hash[`T.untyped`, `T.untyped`]); weak declared type: hash key/value evidence needed; untyped struct/array/collection value; static { kind: :heap_string, alloc: :he ...; evidence 18
  - src/mir/promotion_plan.rb:732 `CleanupClassifier#classify_collection` return; T.nilable(T::Hash[`T.untyped`, `T.untyped`]); weak declared type: hash key/value evidence needed; untyped struct/array/collection value; nil nil; typed_call entry(:fixe ...; evidence 11
  - src/mir/promotion_plan.rb:817 `CleanupClassifier#classify_heap_provenance` return; T.nilable(T::Hash[`T.untyped`, `T.untyped`]); weak declared type: hash key/value evidence needed; untyped struct/array/collection value; nil nil; nil nil; nil nil; evidence 10
  - src/mir/promotion_plan.rb:496 `CleanupClassifier#takes_param_base_entry` return; T.nilable(T::Hash[`T.untyped`, `T.untyped`]); weak declared type: hash key/value evidence needed; untyped struct/array/collection value; typed_call entry(:resource,  ...; evidence 9
  - src/mir/thunk_transform/recursive_splitter.rb:214 `ThunkTransform::RecursiveSplitter#match_base_case` return; T.nilable(T::Hash[`T.untyped`, `T.untyped`]); weak declared type: hash key/value evidence needed; untyped struct/array/collection value; ...; evidence 9
  - src/backends/pipeline_host.rb:2169 `PipelineHost#unwrap_binding_unnest_chain` return; T.nilable(T::Hash[`T.untyped`, `T.untyped`]); weak declared type: hash key/value evidence needed; untyped struct/array/collection value; nil nil; nil nil; nil n ...; evidence 8
  - src/mir/fsm_lowering.rb:325 `FsmLowering#emit_fsm_lock_error_arm_split` return; T.nilable(T::Hash[`T.untyped`, `T.untyped`]); weak declared type: hash key/value evidence needed; untyped struct/array/collection value; nil nil; nil nil; static { bo ...; evidence 8
  - src/mir/promotion_plan.rb:853 `CleanupClassifier#classify_heap_struct_plain` return; T.nilable(T::Hash[`T.untyped`, `T.untyped`]); weak declared type: hash key/value evidence needed; untyped struct/array/collection value; nil nil; nil nil; nil ni ...; evidence 8
- blocked: forwarded return chain: 101 slot(s); weak 0, untyped 101; evidence 1454
  - src/backends/string_concat_rewriter.rb:45 `StringConcatRewriter#rewrite_children!` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; typed_call node.body.map!.with_index { |s, _| rewrite_in_node!(s) }; unkn ...; evidence 82
  - src/mir/mir_lowering.rb:376 `MIRLowering#lower` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; unknown cast_node; call_untyped case node # --- Top-level --- when AST::Program then lower_program(node) # - ...; evidence 79
  - src/annotator-helpers/effects.rb:671 `EffectTracker#scan_suspend_points` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; call_untyped node.each { |n| scan_suspend_points(n, fn_node, points) }; call_untype ...; evidence 72
  - src/ast/parser.rb:1879 `Parser#parse_unary` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; static AST::UnaryOp.new(op_token, AST::OP_TO_OP_CODE[v], right); static AST::CallSiteOverride.new(sigil_tok, `T.m` ...; evidence 63
  - src/ast/parser.rb:2451 `Parser#parse_primary` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; call_untyped instance_exec(&rule); call_untyped parse_unary(); call_untyped parse_suffixes(lit); evidence 63
  - src/backends/pipeline_rewriter.rb:34 `PipelineRewriter#rewrite!` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; unknown node; call_untyped rewrite_pipeline(node); unknown node; evidence 62
  - src/backends/pipeline_rewriter.rb:57 `PipelineRewriter#rewrite_children!` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; typed_call node.statements.map! { |s| rewrite!(s) }; call_untyped node.body.map! { ...; evidence 60
  - src/ast/parser.rb:684 `Parser#parse_statement` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped forwarded return; unknown result; call_untyped instance_exec(&rule); unknown expr; evidence 42
- candidate: runtime-only return observation: 70 slot(s); weak 0, untyped 70; evidence 212
  - src/ast/type.rb:793 `Type#fsm_foreach_descriptor` return; `T.untyped`; single observed type; narrow candidate; untyped struct/array/collection value; static { kind: :pool_indexed, var_zig_type: element_type&.zig_type || "anyopaque" }; static {  ...; evidence 8
  - src/mir/fsm_transform/emit.rb:296 `FsmTransform::Emit#build_recursive` return; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; nil nil; nil nil; nil nil; candidate action fix_sig_return (review); evidence 7
  - src/mir/fsm_transform/recursive_splitter.rb:202 `FsmTransform::RecursiveSplitter#emit_stmts` return; `T.untyped`; single observed type; narrow candidate; untyped literal/static expression; static after_idx; typed_call builder.push(stmts, Segmen ...; evidence 6
  - src/ast/source_error.rb:121 `ErrorHelper#fixable!` return; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; nil return; call_untyped $stderr.puts "#{tag} #{message}#{loc}"; typed_call raise err_class.new(token, mes ...; evidence 5
  - src/ast/type.rb:1634 `Type#from_node` return; `T.untyped`; single observed type; narrow candidate; untyped literal/static expression; nil nil; nil nil; unknown t; candidate action fix_sig_return (review); evidence 5
  - src/mir/escape_analysis.rb:873 `EscapeAnalysis#e3_find_decl` return; `T.untyped`; single observed type; narrow candidate; untyped literal/static expression; nil nil; unknown node; unknown node; candidate action fix_sig_return (review); evidence 5
  - src/mir/fsm_transform.rb:60 `FsmTransform#transform` return; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; nil nil; nil nil; call_untyped Emit.build_recursive( ctx.merge(extra_ctx_fields: ext_ctx, recursive_prom ...; evidence 5
  - src/annotator.rb:3101 `SemanticAnnotator#chain_root_name` return; `T.untyped`; single observed type; narrow candidate; untyped forwarded return; call_untyped curr.name; nil nil; candidate action fix_sig_return (review); evidence 4
- blocked: runtime union policy: 39 slot(s); weak 0, untyped 39; evidence 301
  - src/ast/parser.rb:2972 `Parser#parse_concurrent_inner_op` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; static AST::SelectOp.new(previous, expr); static AST::WhereOp.new(previous, expr); typed_ ...; evidence 17
  - src/mir/mir_lowering.rb:4677 `MIRLowering#lower_literal` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; static MIR::Lit.new("\"#{escaped}\""); static MIR::Lit.new(node.value.to_i.to_s); static M ...; evidence 16
  - src/mir/fsm_ops.rb:394 `FsmOps::Lowerer#lower_stmt` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; static MIR::Set.new(state_ref(op.field), lower_expr(op.value), false); static MIR::Let.new(op.n ...; evidence 15
  - src/mir/fsm_transform/recursive_splitter.rb:820 `FsmTransform::RecursiveSplitter#remap_tail` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; static tail; static Segments::Goto.new(mapping.fetch(t ...; evidence 14
  - src/mir/mir_lowering.rb:4720 `MIRLowering#lower_identifier` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; static MIR::FnRef.new(zig_safe_name(node.name)); static MIR::Ident.new(rc_map[node.name ...; evidence 14
  - src/mir/mir_lowering.rb:5225 `MIRLowering#lower_get_field` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; static MIR::StructInit.new(node.target.name, [{ name: node.field.to_s, value: `MIR::Lit.n` ...; evidence 13
  - src/mir/mir_lowering.rb:6371 `MIRLowering#lower_indexed_assignment` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; static MIR::Set.new(MIR::IndexGet.new(target, idx), val); static MIR::Set.new(M ...; evidence 13
  - src/mir/capture_strategy.rb:143 `CaptureStrategy#classify` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; static MoveInto.new(zig_t, name, name); static FreshHeapCopy.new(zig_t, name, alloc_sym) ...; evidence 12
- blocked: unknown return expression: 27 slot(s); weak 0, untyped 27; evidence 414
  - src/backends/string_concat_rewriter.rb:27 `StringConcatRewriter#rewrite_in_node!` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; unknown node; unknown concat; unknown node; evidence 86
  - src/ast/parser.rb:1707 `Parser#parse_expression` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; unknown lhs; evidence 61
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; unknown node; unknown new_id; unknown new_id; evidence 40
  - src/mir/mir_lowering.rb:219 `MIRLowering#hoist_alloc` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; unknown expr; static MIR::Ident.new(name); evidence 27
  - src/ast/parser.rb:1910 `Parser#parse_suffixes` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped unknown expression; unknown lhs; evidence 20
  - src/mir/mir_lowering.rb:238 `MIRLowering#hoist_owned_value_temp` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; unknown expr; static MIR::Ident.new(name); evidence 20
  - src/mir/mir_lowering.rb:5126 `MIRLowering#lower_or_rescue` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; unknown left; static MIR::TryExpr.new(strip_try(left)); unknown left; evidence 19
  - src/mir/fsm_transform/emit.rb:209 `FsmTransform::Emit#build_dispatch_tail` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped literal/static expression; unknown tail; static MIR::FsmTailDone.new(nil); static MIR::FsmTailJump. ...; evidence 16
- candidate: void return: 21 slot(s); weak 0, untyped 21; evidence 129
  - src/annotator-helpers/pipe_analysis.rb:171 `PipeAnalysis#analyze_higher_order_op` return; `T.untyped`; void candidate; return value appears unused; untyped literal/static expression; typed_call analyze_select_family_op(node); typed_call analyze ...; evidence 29
  - src/mir/control_flow.rb:604 `OwnershipDataflow#transfer_stmt` return; `T.untyped`; void candidate; return value appears unused; untyped struct/array/collection value; assignment state[stmt.name.to_s] = make_owner_entry(stmt); assignment state[s ...; evidence 16
  - src/annotator.rb:3347 `SemanticAnnotator#visit_GetField` return; `T.untyped`; void candidate; return value appears unused; untyped forwarded return; nil return; nil return; typed_call_inferred error!(node, :ENUM_FIELD_ACCESS, enum: type); candi ...; evidence 10
  - src/annotator.rb:3876 `SemanticAnnotator#visit_BinaryOp` return; `T.untyped`; void candidate; return value appears unused; untyped forwarded return; call_untyped visit_Smooth(node); typed_call visit_BindVar(node); typed_call visit_OrRescue(node ...; evidence 10
  - src/annotator.rb:3278 `SemanticAnnotator#validate_assignment_type` return; `T.untyped`; void candidate; return value appears unused; untyped forwarded return; nil return; nil return; nil return; candidate action fix_sig_return (review); evidence 9
  - src/ast/scope.rb:207 `Scope#mark_read` return; `T.untyped`; void candidate; return value appears unused; untyped forwarded return; nil return; nil entry.reg&.tap { |r| r.var_used = true if r.respond_to?(:var_used=) }; call_untyped entry.reg&.ta ...; evidence 8
  - src/annotator.rb:3484 `SemanticAnnotator#visit_UnaryOp` return; `T.untyped`; void candidate; return value appears unused; untyped struct/array/collection value; assignment node.full_type = :Bool; assignment node.full_type = node.right.full_type ...; evidence 5
  - src/annotator.rb:361 `SemanticAnnotator#visit_Program` return; `T.untyped`; void candidate; return value appears unused; untyped struct/array/collection value; assignment node.full_type = node.statements.last.full_type; assignment node.full_typ ...; evidence 4
- weak declared type: union: 19 slot(s); weak 19, untyped 0; evidence 95
  - src/mir/mir_checker.rb:340 `MIRChecker#walk_mir_node` return; T.nilable(T::Array[T::Hash[Symbol, T.any(String, Symbol)]]); weak declared type: union; untyped struct/array/collection value; nil return; typed_call walk_mir(node.body, &block); t ...; evidence 27
  - src/backends/pipeline_host.rb:1882 `PipelineHost#lower_each` return; T.nilable(T.any(MIR::ForStmt, MIR::ScopeBlock)); weak declared type: union; untyped literal/static expression; typed_call lower_sharded_each(site, each_op); static MIR::Scop ...; evidence 10
  - src/mir/mir_lowering.rb:3235 `MIRLowering#guard_fail_flow_body` return; T.nilable(T.any(T::Array[`T.untyped`], T::Array[`T.untyped`])); weak declared type: union; untyped struct/array/collection value; static []; static []; static [MIR::ReturnStm ...; evidence 8
  - src/mir/mir_pass.rb:940 `MIRPass#insert_promotion!` return; T.nilable(T.any(T::Hash[`T.untyped`, `T.untyped`], Symbol, T::Hash[`T.untyped`, `T.untyped`])); weak declared type: union; untyped struct/array/collection value; nil return; assignment ret_n ...; evidence 7
  - src/mir/promotion_plan.rb:38 `PromotionClassifier#classify` return; T::Hash[Symbol, T.any(T::Array[T::Hash[Symbol, String]], T::Set[Integer])]; weak declared type: union; untyped struct/array/collection value; static {}; static {}; static {}; evidence 7
  - src/annotator.rb:3734 `SemanticAnnotator#visit_ListLit` return; T.nilable(T.any(Symbol, Type)); weak declared type: union; untyped literal/static expression; nil return; nil return; nil return; evidence 5
  - src/mir/control_flow.rb:542 `OwnershipDataflow#join_entry` return; T.any(OwnershipDataflow::OwnerEntry, Symbol); weak declared type: union; untyped literal/static expression; static T.must(b); static a; static OwnerEntry.new(state: joined_sta ...; evidence 5
  - src/mir/mir_lowering.rb:4113 `MIRLowering#lower_bg_stream_block` return; T.any(MIR::BgBlock, MIR::BlockExpr, MIR::InlineBc, MIR::StreamSpawn); weak declared type: union; untyped literal/static expression; static MIR::StreamSpawn.new(captures_ ...; evidence 4
- blocked: collection/field return evidence: 11 slot(s); weak 0, untyped 11; evidence 63
  - src/mir/control_flow.rb:1791 `BorrowChecker#check_stmt` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; typed_call handle_with_block(stmt); typed_call check_binding_moves(stmt.value, stmt.tok ...; evidence 16
  - src/annotator-helpers/generic_analysis.rb:325 `GenericAnalysis#extract_type_bindings!` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; unknown subst[p_res] = actual_binding; typed_call param_ ...; evidence 7
  - src/mir/mir_lowering.rb:968 `MIRLowering#lower_union_def` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; typed_call helper_structs + [generic_fn]; unknown generic_fn; typed_call helper_struc ...; evidence 7
  - src/mir/test_lowering.rb:435 `TestLowering#lower_stub_decl` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; static MIR::Let.new(stub_var, val, false, nil, nil); static MIR::Let.new(cap_name,  ...; evidence 7
  - src/annotator-helpers/pipe_analysis.rb:116 `PipeAnalysis#finite_stream_element_type` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; typed_call range_element_type(node); static node.type_info ...; evidence 5
  - src/mir/mir_lowering.rb:1127 `MIRLowering#lower_function_def` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; static [build_post_inner_fn(node, params_mir, return_type_str, prologue, body_mir ...; evidence 5
  - src/mir/mir_lowering.rb:4399 `MIRLowering#lower_require` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; static [raw, *helper_fns]; static MIR::Import.new(node.namespace || node.path, "#{node ...; evidence 5
  - src/mir/mir_lowering.rb:5993 `MIRLowering#lower_var_decl` return; `T.untyped`; runtime union; kept `T.untyped` by policy; untyped struct/array/collection value; static [MIR::AllocMark.new(safe_name, mir_alloc, node.type_info), let_node, MIR::Clea ...; evidence 5
- weak declared type: collection element evidence needed: 9 slot(s); weak 9, untyped 0; evidence 24
  - src/annotator-helpers/with_match_check.rb:387 `WithMatchCheck#warn_polymorphic_unhandled_errors!` return; T.nilable(T::Set[`T.untyped`]); weak declared type: collection element evidence needed; untyped struct/array/collection value; nil return; ...; evidence 4
  - src/mir/ownership_graph.rb:113 `OwnershipGraph#mark_moved` return; T.nilable(T::Set[`T.untyped`]); weak declared type: collection element evidence needed; untyped literal/static expression; nil return; typed_call invalidate(path, source); evidence 4
  - src/annotator-helpers/with_match_check.rb:348 `WithMatchCheck#expand_snapshotted` return; T::Set[`T.untyped`]; weak declared type: collection element evidence needed; untyped struct/array/collection value; static family_set; static out; candida ...; evidence 3
  - src/mir/concurrency_checks.rb:230 `ConcurrencyChecks#collect_held_params` return; T::Set[`T.untyped`]; weak declared type: collection element evidence needed; untyped struct/array/collection value; static `Set.new`; static out; candidate action n ...; evidence 3
  - src/annotator.rb:356 `SemanticAnnotator#outer_scope_vars` return; T::Set[`T.untyped`]; weak declared type: collection element evidence needed; untyped struct/array/collection value; typed_call @scope_stack.flat_map { |s| s.locals.keys }.to_set; ...; evidence 2
  - src/annotator.rb:4175 `SemanticAnnotator#visit_MoveNode` return; T.nilable(T::Set[`T.untyped`]); weak declared type: collection element evidence needed; untyped literal/static expression; typed_call og_set_moved(node.value.name, at_token: node. ...; evidence 2
  - src/annotator.rb:6528 `SemanticAnnotator#og_move` return; T::Set[`T.untyped`]; weak declared type: collection element evidence needed; untyped unknown expression; typed_call_inferred @og.transfer(from, to, at_token: at_token, action: action); evidence 2
  - src/annotator.rb:6530 `SemanticAnnotator#og_set_moved` return; T.nilable(T::Set[`T.untyped`]); weak declared type: collection element evidence needed; untyped forwarded return; call_untyped @og.mark_moved(name, at_token: at_token, action: actio ...; evidence 2
- nil only observed: 2 slot(s); weak 0, untyped 2; evidence 6
  - src/ast/schemas.rb:136 `Schemas#as_resource_schema` return; `T.untyped`; nil only observed; untyped literal/static expression; static schema; nil nil; static ResourceSchema.new( close_zig: schema[:close_zig], static_methods: schema[:static_meth ...; evidence 4
  - src/ast/fixable_error.rb:140 `FixCollector#disable!` return; `T.untyped`; nil only observed; untyped literal/static expression; nil nil; candidate action fix_sig_return (review); evidence 2
- blocked: instance variable return: 1 slot(s); weak 0, untyped 1; evidence 1
  - src/ast/type.rb:604 `Type#location` return; `T.untyped`; slot not observed: method was not hit; untyped instance variable; ivar_read @provenance; evidence 1
- slot not observed: method hit but return was not captured: 1 slot(s); weak 0, untyped 1; evidence 1
  - src/ast/source_error.rb:31 `ErrorHelper#error!` return; `T.untyped`; slot not observed: method hit but return was not captured; untyped literal/static expression; typed_call raise err_class.new(token, message, T.cast(T.unsafe(self).instance_var ...; evidence 1

### Return Hygiene
- control shape: whether the method return is branchless or depends on branching control flow
- return syntax: whether the method uses implicit return, explicit `return`, or a mix
- return value usage: whether static callsites use this method's return value, forward it, or ignore it
- return source kind: the kind of expression that produces the return value
- fixability: the report's estimate of whether the return is already addressed, directly fixable, cascading, or needs more evidence
- row percent: share of all return slots; strength percents: share within that row
- Return slots indexed: 2217
- Return slot strength: strong 1590 (71.7%); weak 354 (16.0%); untyped 273 (12.3%); nilable 579 (26.1%)

#### Control Shape

- branching: total 1117 (50.4%) of all returns; strong 706 (63.2%); weak 217 (19.4%); untyped 194 (17.4%); nilable 431 (38.6%) within row
- branchless: total 1100 (49.6%) of all returns; strong 884 (80.4%); weak 137 (12.5%); untyped 79 (7.2%); nilable 148 (13.5%) within row

#### Return Syntax

- implicit: total 1447 (65.3%) of all returns; strong 1086 (75.1%); weak 211 (14.6%); untyped 150 (10.4%); nilable 249 (17.2%) within row
- mixed: total 765 (34.5%) of all returns; strong 502 (65.6%); weak 143 (18.7%); untyped 120 (15.7%); nilable 329 (43.0%) within row
- explicit: total 5 (0.2%) of all returns; strong 2 (40.0%); weak 0 (0.0%); untyped 3 (60.0%); nilable 1 (20.0%) within row

#### Return Value Usage

- used as value: total 1585 (71.5%) of all returns; strong 1127 (71.1%); weak 225 (14.2%); untyped 233 (14.7%); nilable 382 (24.1%) within row
- ambiguous method name: total 220 (9.9%) of all returns; strong 164 (74.5%); weak 39 (17.7%); untyped 17 (7.7%); nilable 25 (11.4%) within row
- unused statement-only: total 183 (8.3%) of all returns; strong 85 (46.4%); weak 82 (44.8%); untyped 16 (8.7%); nilable 121 (66.1%) within row
- declared void: total 119 (5.4%) of all returns; strong 119 (100.0%); weak 0 (0.0%); untyped 0 (0.0%); nilable 0 (0.0%) within row
- no static callsites found: total 104 (4.7%) of all returns; strong 89 (85.6%); weak 8 (7.7%); untyped 7 (6.7%); nilable 49 (47.1%) within row
- declared noreturn: total 3 (0.1%) of all returns; strong 3 (100.0%); weak 0 (0.0%); untyped 0 (0.0%); nilable 0 (0.0%) within row
- unused via return-forwarding: total 3 (0.1%) of all returns; strong 3 (100.0%); weak 0 (0.0%); untyped 0 (0.0%); nilable 2 (66.7%) within row

#### Return Source Kind

- collection lookup: total 801 (36.1%) of all returns; strong 430 (53.7%); weak 282 (35.2%); untyped 89 (11.1%); nilable 240 (30.0%) within row
- literal/static: total 509 (23.0%) of all returns; strong 483 (94.9%); weak 9 (1.8%); untyped 17 (3.3%); nilable 74 (14.5%) within row
- implicit/direct forwarded return: total 255 (11.5%) of all returns; strong 158 (62.0%); weak 23 (9.0%); untyped 74 (29.0%); nilable 64 (25.1%) within row
- Ruby stdlib call: total 159 (7.2%) of all returns; strong 156 (98.1%); weak 0 (0.0%); untyped 3 (1.9%); nilable 20 (12.6%) within row
- mixed/direct forwarded return: total 150 (6.8%) of all returns; strong 78 (52.0%); weak 23 (15.3%); untyped 49 (32.7%); nilable 60 (40.0%) within row
- mixed sources: total 127 (5.7%) of all returns; strong 99 (78.0%); weak 3 (2.4%); untyped 25 (19.7%); nilable 46 (36.2%) within row
- unknown source: total 126 (5.7%) of all returns; strong 102 (81.0%); weak 13 (10.3%); untyped 11 (8.7%); nilable 21 (16.7%) within row
- mutation/setter assignment: total 81 (3.7%) of all returns; strong 80 (98.8%); weak 0 (0.0%); untyped 1 (1.2%); nilable 54 (66.7%) within row
- struct/class field or instance variable: total 6 (0.3%) of all returns; strong 4 (66.7%); weak 1 (16.7%); untyped 1 (16.7%); nilable 0 (0.0%) within row
- explicit/direct forwarded return: total 3 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 3 (100.0%); nilable 0 (0.0%) within row

#### Fixability

- addressed: strong: total 1468 (66.2%) of all returns; strong 1468 (100.0%); weak 0 (0.0%); untyped 0 (0.0%); nilable 412 (28.1%) within row
- addressed: weak: total 354 (16.0%) of all returns; strong 0 (0.0%); weak 354 (100.0%); untyped 0 (0.0%); nilable 167 (47.2%) within row
- addressed: void: total 119 (5.4%) of all returns; strong 119 (100.0%); weak 0 (0.0%); untyped 0 (0.0%); nilable 0 (0.0%) within row
- cascade: forwarded return: total 41 (1.8%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 41 (100.0%); nilable 0 (0.0%) within row
- review action: void from runtime_void: total 21 (0.9%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 21 (100.0%); nilable 0 (0.0%) within row
- needs collection/field evidence: total 20 (0.9%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 20 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(Array, Hash)) from review: total 12 (0.5%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 12 (100.0%); nilable 0 (0.0%) within row
- review action: T::Boolean from review: total 10 (0.5%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 10 (100.0%); nilable 0 (0.0%) within row
- manual review: total 9 (0.4%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 9 (100.0%); nilable 0 (0.0%) within row
- review action: String from review: total 9 (0.4%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 9 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T::Boolean) from review: total 9 (0.4%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 9 (100.0%); nilable 0 (0.0%) within row
- review action: Type from review: total 9 (0.4%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 9 (100.0%); nilable 0 (0.0%) within row
- review action: Integer from review: total 6 (0.3%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 6 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(Symbol, Type) from review: total 6 (0.3%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 6 (100.0%); nilable 0 (0.0%) within row
- review action: Array from review: total 5 (0.2%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 5 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(String) from review: total 5 (0.2%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 5 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(Array, Hash, Set)) from review: total 5 (0.2%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 5 (100.0%); nilable 0 (0.0%) within row
- addressed: noreturn: total 3 (0.1%) of all returns; strong 3 (100.0%); weak 0 (0.0%); untyped 0 (0.0%); nilable 0 (0.0%) within row
- review action: T.nilable(Array) from review: total 3 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 3 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(Hash) from review: total 3 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 3 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(Array, Set)) from review: total 3 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 3 (100.0%); nilable 0 (0.0%) within row
- missing action: no singular static/RBI candidate: total 2 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: Hash from review: total 2 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::IfBind, AST::IfStatement) from review: total 2 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(Array, MIR::Let) from review: total 2 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(FalseClass, Lexer::Token) from review: total 2 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::BlockExpr, MIR::IfStmt) from review: total 2 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::BlockExpr, MIR::InlineZig, MIR::ScopeBlock) from review: total 2 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(Symbol) from review: total 2 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(Hash, Schemas::StructSchema)) from review: total 2 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(String, Symbol)) from review: total 2 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: T::Array[T::Hash[Symbol, `T.untyped`]] from review: total 2 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- review action: T::Hash[String, LSP::DocumentStore::Document] from static_return_origin: total 2 (0.1%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 2 (100.0%); nilable 0 (0.0%) within row
- auto-fixable: String: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: AST::VarDecl from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: Lexer::Token from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: SymbolEntry from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::BatchWindowOp, AST::WindowOp) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::BgBlock, AST::BgStreamBlock) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::BinaryOp, AST::GetField, AST::Identifier) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::BinaryOp, AST::RangeLit) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::BlockExpr, AST::ForEach) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::CapabilityWrap, AST::Literal, AST::MethodCall) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::CopyNode, AST::Identifier, AST::StructLit) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::ExternFnDecl, AST::ExternStructDecl) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::ForEach, AST::ForRange) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::ForEach, AST::ForRange, AST::WhileLoop) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(AST::WhileBindLoop, AST::WhileLoop) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(Array, Hash) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(Array, MIR::FnDef) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(Array, MIR::FnDef, MIR::UnionTypeDef) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(Array, String) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(FalseClass, Lexer::Token, TrueClass) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(IO, StringIO) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(Lexer::Token, Symbol, TrueClass) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::BinOp, MIR::FieldGet, MIR::Ident) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::BlockExpr, MIR::HeapCreate, MIR::StructInit) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::BlockExpr, MIR::IfChain, MIR::SwitchStmt) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::BlockExpr, MIR::ScopeBlock) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::BlockExpr, MIR::StructInit) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::Call, MIR::Cast, MIR::InlineZig) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::Call, MIR::InlineZig) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::Call, MIR::Lit) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::CapWrap, MIR::RcRetain, MIR::SharePromote) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::Cast, MIR::Ident) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::Cast, MIR::Lit) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::FnDef, MIR::StructDef) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::ForStmt, MIR::InlineZig) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::ForStmt, MIR::ScopeBlock, MIR::WhileStmt) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::Import, MIR::Noop) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::Import, MIR::RawZig) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::InlineBc, MIR::InlineZig) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::InlineZig, MIR::Lit) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::InlineZig, MIR::MethodCall) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::PolymorphicMutate, MIR::PolymorphicMutateFlow) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::ReturnStmt, MIR::ScopeBlock) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::ScopeBlock, MIR::Set) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.any(MIR::SnapshotMultiTxn, MIR::SnapshotTransaction) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(FunctionContext) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(MIR::SuspendDescriptor) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(SymbolEntry) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(AST::Assignment, AST::BindExpr)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(Array, OwnershipDataflow::OwnerEntry)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(Array, Symbol, Type)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(FsmTransform::Segments::IoSuspend, FsmTransform::Segments::NextSuspend)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(FunctionSignature, Symbol)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(IO, StringIO, Thread)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(Integer, Symbol, Type)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(LSP::Analyzer::Result, String)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(LSP::Analyzer::SyntheticFinding, StubFinding)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(MIR::BlockExpr, MIR::Call, MIR::Ident)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(MIR::BlockExpr, String)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(Module, Symbol, Type)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T.any(Symbol, Type)) from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T.nilable(T::Hash[String, LSP::DocumentStore::Document]) from static_return_origin: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: `T.noreturn` from noreturn_body: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: `T.noreturn` from static_return_origin: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T::Array[Integer] from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T::Array[T::Array[`T.untyped`]] from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T::Array[Type] from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T::Hash[String, OwnershipDataflow::OwnerEntry] from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T::Hash[Symbol, `T.untyped`] from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T::Hash[Symbol, T::Array[`T.untyped`]] from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T::Hash[Symbol, T::Hash[Symbol, `T.untyped`]] from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T::Hash[Symbol, T::Hash[Symbol, T::Hash[Symbol, Integer]]] from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- review action: T::Set[String] from review: total 1 (0.0%) of all returns; strong 0 (0.0%); weak 0 (0.0%); untyped 1 (100.0%); nilable 0 (0.0%) within row
- Easily addressable/addressed returns: 1944 (99.9%)

#### Top Return Hygiene Actions

- src/tools/pprof.rb:181 `Pprof::Profile#encode`: auto-fixable: String; used as value; literal/static
- src/annotator-helpers/auto_inference.rb:568 `ShapeEvidenceCollector#walk_for_shape_decls`: cascade: forwarded return; used as value; mixed/direct forwarded return
- src/annotator-helpers/auto_inference.rb:589 `ShapeEvidenceCollector#walk`: cascade: forwarded return; ambiguous method name; mixed/direct forwarded return
- src/annotator-helpers/auto_inference.rb:728 `OperatorEvidenceCollector#walk_for_local_decls`: cascade: forwarded return; used as value; mixed/direct forwarded return
- src/annotator-helpers/auto_inference.rb:751 `OperatorEvidenceCollector#walk_binops`: cascade: forwarded return; used as value; mixed/direct forwarded return
- src/annotator-helpers/effects.rb:671 `EffectTracker#scan_suspend_points`: cascade: forwarded return; used as value; implicit/direct forwarded return
- src/annotator-helpers/effects.rb:1008 `EffectTracker#validate_tight_node!`: cascade: forwarded return; used as value; mixed/direct forwarded return
- src/annotator-helpers/pipe_analysis.rb:171 `PipeAnalysis#analyze_higher_order_op`: cascade: forwarded return; unused statement-only; implicit/direct forwarded return
- src/annotator.rb:345 `SemanticAnnotator#visit`: cascade: forwarded return; ambiguous method name; mixed/direct forwarded return
- src/ast/parser.rb:500 `Parser#run_action`: cascade: forwarded return; used as value; explicit/direct forwarded return
- src/ast/parser.rb:684 `Parser#parse_statement`: cascade: forwarded return; used as value; mixed/direct forwarded return
- src/ast/parser.rb:908 `Parser#parse_visibility_decl`: cascade: forwarded return; used as value; implicit/direct forwarded return
- src/ast/parser.rb:1786 `Parser#parse_or_rescue`: cascade: forwarded return; used as value; implicit/direct forwarded return
- src/ast/parser.rb:1925 `Parser#parse_var_id`: cascade: forwarded return; used as value; explicit/direct forwarded return
- src/ast/parser.rb:2451 `Parser#parse_primary`: cascade: forwarded return; used as value; mixed/direct forwarded return
- src/ast/parser.rb:2499 `Parser#parse_lit`: cascade: forwarded return; used as value; explicit/direct forwarded return
- src/ast/parser.rb:2573 `Parser#parse_sigil_construct`: cascade: forwarded return; used as value; mixed/direct forwarded return
- src/ast/parser.rb:2972 `Parser#parse_concurrent_inner_op`: cascade: forwarded return; used as value; implicit/direct forwarded return
- src/ast/parser.rb:3920 `Parser#deep_clone_node`: cascade: forwarded return; used as value; implicit/direct forwarded return
- src/ast/scope.rb:184 `Scope#resolve_type`: cascade: forwarded return; used as value; implicit/direct forwarded return


## Review Actions (2124)

### Nil Source Fixes (158)
- src/backends/pipeline_generator.rb:28: affects 6 of 158 nil source fixes; source calls 726
  - src/backends/pipeline_generator.rb:28 acc; top source src/backends/pipeline_generator.rb:28; source calls 121
  - src/backends/pipeline_generator.rb:28 shard_hash; top source src/backends/pipeline_generator.rb:28; source calls 121
  - src/backends/pipeline_generator.rb:28 shard_idx; top source src/backends/pipeline_generator.rb:28; source calls 121
  - src/backends/pipeline_generator.rb:28 shard_key; top source src/backends/pipeline_generator.rb:28; source calls 121
  - src/backends/pipeline_generator.rb:28 shard_map; top source src/backends/pipeline_generator.rb:28; source calls 121
  - src/backends/pipeline_generator.rb:28 soa; top source src/backends/pipeline_generator.rb:28; source calls 121
- src/tools/doctor.rb:1213: affects 3 of 158 nil source fixes; source calls 65
  - src/tools/doctor.rb:1213 llc_miss_rate; top source src/tools/doctor.rb:1213; source calls 24
  - src/tools/doctor.rb:1213 resolved; top source src/tools/doctor.rb:1213; source calls 24
  - src/tools/doctor.rb:1213 sites; candidate Array; auto-default []; top source src/tools/doctor.rb:1213; source calls 17
- src/annotator-helpers/function_signature.rb:66: affects 2 of 158 nil source fixes; source calls 49904
  - src/annotator-helpers/function_signature.rb:66 owner_type_params; candidate Array; auto-default []; top source src/annotator-helpers/function_signature.rb:66; source calls 31522
  - src/annotator-helpers/function_signature.rb:66 return_lifetime; candidate T.any(Array, String); top source src/annotator-helpers/function_signature.rb:66; source calls 18382
- src/mir/mir_pass.rb:23: affects 2 of 158 nil source fixes; source calls 1897
  - src/mir/mir_pass.rb:23 promo; candidate Hash; auto-default {}; top source src/mir/mir_pass.rb:23; source calls 1869
  - src/mir/mir_pass.rb:23 bindings; candidate Hash; auto-default {}; top source src/mir/mir_pass.rb:23; source calls 28
- src/lsp/hover.rb:91: affects 2 of 158 nil source fixes; source calls 11
  - src/lsp/hover.rb:91 entry; candidate Hash; auto-default {}; top source src/lsp/hover.rb:91; source calls 6
  - src/lsp/hover.rb:91 example; candidate Hash; auto-default {}; top source src/lsp/hover.rb:91; source calls 5
- src/ast/symbol_entry.rb:151: affects 1 of 158 nil source fix; source calls 470595
  - src/ast/symbol_entry.rb:151 reg; top source src/ast/symbol_entry.rb:151; source calls 470595
- src/ast/scope.rb:24: affects 1 of 158 nil source fix; source calls 470577
  - src/ast/scope.rb:24 reg; top source src/ast/scope.rb:24; source calls 470577
- src/annotator.rb:250: affects 1 of 158 nil source fix; source calls 68841
  - src/annotator.rb:250 node; top source src/annotator.rb:250; source calls 68841
- src/tools/lint_fix_rewriter.rb:211: affects 1 of 158 nil source fix; source calls 33492
  - src/tools/lint_fix_rewriter.rb:211 n; top source src/tools/lint_fix_rewriter.rb:211; source calls 33492
- src/ast/parser.rb:42: affects 1 of 158 nil source fix; source calls 32769
  - src/ast/parser.rb:42 pattern; candidate Array; auto-default []; top source src/ast/parser.rb:42; source calls 32769
- src/ast/parser.rb:26: affects 1 of 158 nil source fix; source calls 30783
  - src/ast/parser.rb:26 pattern; candidate Array; auto-default []; top source src/ast/parser.rb:26; source calls 30783
- src/tools/predicate_rewriter.rb:118: affects 1 of 158 nil source fix; source calls 23669
  - src/tools/predicate_rewriter.rb:118 n; top source src/tools/predicate_rewriter.rb:118; source calls 23669
- src/ast/ast.rb:273: affects 1 of 158 nil source fix; source calls 23540
  - src/ast/ast.rb:273 val; candidate String; auto-default ""; top source src/ast/ast.rb:273; source calls 23540
- src/tools/method_rewriter.rb:138: affects 1 of 158 nil source fix; source calls 23463
  - src/tools/method_rewriter.rb:138 node; top source src/tools/method_rewriter.rb:138; source calls 23463
- src/tools/predicate_rewriter.rb:103: affects 1 of 158 nil source fix; source calls 23355
  - src/tools/predicate_rewriter.rb:103 node; top source src/tools/predicate_rewriter.rb:103; source calls 23355
- src/tools/lint_fix_rewriter.rb:197: affects 1 of 158 nil source fix; source calls 16745
  - src/tools/lint_fix_rewriter.rb:197 node; top source src/tools/lint_fix_rewriter.rb:197; source calls 16745
- src/tools/lint_fix_rewriter.rb:68: affects 1 of 158 nil source fix; source calls 16745
  - src/tools/lint_fix_rewriter.rb:68 node; top source src/tools/lint_fix_rewriter.rb:68; source calls 16745
- src/tools/lint_fix_rewriter.rb:89: affects 1 of 158 nil source fix; source calls 16745
  - src/tools/lint_fix_rewriter.rb:89 node; top source src/tools/lint_fix_rewriter.rb:89; source calls 16745
- src/annotator-helpers/effects.rb:671: affects 1 of 158 nil source fix; source calls 15143
  - src/annotator-helpers/effects.rb:671 node; top source src/annotator-helpers/effects.rb:671; source calls 15143
- src/tools/method_rewriter.rb:65: affects 1 of 158 nil source fix; source calls 14143
  - src/tools/method_rewriter.rb:65 node; top source src/tools/method_rewriter.rb:65; source calls 14143
- ... 128 more source group(s)

### Union / `T.any` Candidates (504)
- src/ast/symbol_entry.rb:151: affects 3 of 504 union candidates; source calls 936745
  - src/ast/symbol_entry.rb:151 mutable; observed FalseClass, Lexer::Token, TrueClass; src/ast/symbol_entry.rb:151; source calls 481297
  - src/ast/symbol_entry.rb:151 type; observed FunctionSignature, String, Symbol, Type; src/ast/symbol_entry.rb:151; source calls 455440
  - src/ast/symbol_entry.rb:151 reg; observed AST::BindExpr, AST::LetBinding, AST::StubDecl, AST::VarDecl, String, Symbol; src/ast/symbol_entry.rb:151; source calls 8
- src/mir/thunk_transform/emit.rb:266: affects 3 of 504 union candidates; source calls 29
  - src/mir/thunk_transform/emit.rb:266 lowering; observed FakeThunkLowering, MIRLowering; src/mir/thunk_transform/emit.rb:266; source calls 21
  - src/mir/thunk_transform/emit.rb:266 _mtp; observed OpenStruct, ThunkTransform::RecursiveSplitter::MutualThunkPlan; src/mir/thunk_transform/emit.rb:266; source calls 4
  - src/mir/thunk_transform/emit.rb:266 cf; observed AST::FunctionDef, OpenStruct; src/mir/thunk_transform/emit.rb:266; source calls 4
- src/mir/mir_lowering.rb:7489: affects 3 of 504 union candidates; source calls 0
  - src/mir/mir_lowering.rb:7489 catch_body; observed MIR::BlockExpr, MIR::Ident, MIR::Lit, MIR::ScopeBlock, MIR::StructInit, MIR::UnaryOp; no source callsite
  - src/mir/mir_lowering.rb:7489 fallback; observed MIR::BlockExpr, MIR::Lit, MIR::StructInit, MIR::UnaryOp; no source callsite
  - src/mir/mir_lowering.rb:7489 left; observed MIR::Call, MIR::Ident, MIR::InlineZig; no source callsite
- src/ast/scope.rb:24: affects 2 of 504 union candidates; source calls 936688
  - src/ast/scope.rb:24 is_mutable; observed FalseClass, Lexer::Token, TrueClass; src/ast/scope.rb:24; source calls 481279
  - src/ast/scope.rb:24 type; observed FunctionSignature, String, Symbol, Type; src/ast/scope.rb:24; source calls 455409
- src/tools/lint_fix_rewriter.rb:68: affects 2 of 504 union candidates; source calls 674686
  - src/tools/lint_fix_rewriter.rb:68 in_bg; observed FalseClass, TrueClass; src/tools/lint_fix_rewriter.rb:68; source calls 520350
  - src/tools/lint_fix_rewriter.rb:68 node; observed AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp, AST::BatchWindowOp, AST::BenchmarkStmt, AST::BgBlock, ...; src/tools/lint_fix_rewriter.rb:68; source calls 154336
- src/ast/type.rb:2297: affects 2 of 504 union candidates; source calls 60855
  - src/ast/type.rb:2297 source_type; observed Symbol, Type; src/ast/type.rb:2297; source calls 31337
  - src/ast/type.rb:2297 target_type; observed Symbol, Type; src/ast/type.rb:2297; source calls 29518
- src/annotator-helpers/function_signature.rb:66: affects 2 of 504 union candidates; source calls 36101
  - src/annotator-helpers/function_signature.rb:66 return_type; observed Hash, Proc, Symbol, Type; src/annotator-helpers/function_signature.rb:66; source calls 22920
  - src/annotator-helpers/function_signature.rb:66 return_lifetime; observed Array, String; src/annotator-helpers/function_signature.rb:66; source calls 13181
- src/annotator-helpers/function_analysis.rb:11: affects 2 of 504 union candidates; source calls 18647
  - src/annotator-helpers/function_analysis.rb:11 body; observed AST::BinaryOp, AST::Identifier, AST::Literal, Array; src/annotator-helpers/function_analysis.rb:11; source calls 9360
  - src/annotator-helpers/function_analysis.rb:11 declared_return; observed Symbol, Type; src/annotator-helpers/function_analysis.rb:11; source calls 9287
- src/mir/thunk_transform/recursive_splitter.rb:194: affects 2 of 504 union candidates; source calls 1955
  - src/mir/thunk_transform/recursive_splitter.rb:194 names_set; observed Array, Set; src/mir/thunk_transform/recursive_splitter.rb:194; source calls 1455
  - src/mir/thunk_transform/recursive_splitter.rb:194 node; observed AST::BinaryOp, AST::FuncCall, AST::Identifier, AST::Literal, Array, FalseClass, Integer, Lexer::Token, ...; src/mir/thunk_transform/recursive_splitter.rb:194; source calls 500
- src/ast/source_error.rb:31: affects 2 of 504 union candidates; source calls 965
  - src/ast/source_error.rb:31 code_or_message; observed String, Symbol; src/ast/source_error.rb:31; source calls 960
  - src/ast/source_error.rb:31 node_or_token; observed AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp, AST::BgBlock, AST::BgStreamBlock, AST::BinaryOp, ...; src/ast/source_error.rb:31; source calls 5
- src/annotator-helpers/fixable_helpers.rb:59: affects 2 of 504 union candidates; source calls 231
  - src/annotator-helpers/fixable_helpers.rb:59 input; observed String, Symbol; src/annotator-helpers/fixable_helpers.rb:59; source calls 117
  - src/annotator-helpers/fixable_helpers.rb:59 candidates; observed Array, Set; src/annotator-helpers/fixable_helpers.rb:59; source calls 114
- src/annotator-helpers/generic_analysis.rb:426: affects 2 of 504 union candidates; source calls 36
  - src/annotator-helpers/generic_analysis.rb:426 left; observed Symbol, Type; src/annotator-helpers/generic_analysis.rb:426; source calls 18
  - src/annotator-helpers/generic_analysis.rb:426 right; observed Symbol, Type; src/annotator-helpers/generic_analysis.rb:426; source calls 18
- src/mir/thunk_transform/emit.rb:147: affects 2 of 504 union candidates; source calls 24
  - src/mir/thunk_transform/emit.rb:147 _lowering; observed FakeThunkLowering, MIRLowering; src/mir/thunk_transform/emit.rb:147; source calls 19
  - src/mir/thunk_transform/emit.rb:147 fn_node; observed AST::FunctionDef, OpenStruct; src/mir/thunk_transform/emit.rb:147; source calls 5
- src/annotator-helpers/auto_inference.rb:439: affects 2 of 504 union candidates; source calls 19
  - src/annotator-helpers/auto_inference.rb:439 a; observed Symbol, Type; src/annotator-helpers/auto_inference.rb:439; source calls 11
  - src/annotator-helpers/auto_inference.rb:439 b; observed Symbol, Type; src/annotator-helpers/auto_inference.rb:439; source calls 8
- src/mir/thunk_transform/emit.rb:79: affects 2 of 504 union candidates; source calls 15
  - src/mir/thunk_transform/emit.rb:79 lowering; observed FakeThunkLowering, MIRLowering; src/mir/thunk_transform/emit.rb:79; source calls 10
  - src/mir/thunk_transform/emit.rb:79 fn_node; observed AST::FunctionDef, OpenStruct; src/mir/thunk_transform/emit.rb:79; source calls 5
- src/mir/thunk_transform/emit.rb:223: affects 2 of 504 union candidates; source calls 11
  - src/mir/thunk_transform/emit.rb:223 lowering; observed FakeThunkLowering, MIRLowering; src/mir/thunk_transform/emit.rb:223; source calls 9
  - src/mir/thunk_transform/emit.rb:223 fn_node; observed AST::FunctionDef, OpenStruct; src/mir/thunk_transform/emit.rb:223; source calls 2
- src/backends/pipeline_host.rb:3050: affects 2 of 504 union candidates; source calls 0
  - src/backends/pipeline_host.rb:3050 fold_op; observed AST::AllOp, AST::AnyOp, AST::AverageOp, AST::CountOp, AST::FindOp, AST::MaxOp, AST::MinOp, AST::SumOp; no source callsite
  - src/backends/pipeline_host.rb:3050 range_lit; observed AST::Identifier, AST::RangeLit; no source callsite
- src/backends/pipeline_host.rb:375: affects 2 of 504 union candidates; source calls 0
  - src/backends/pipeline_host.rb:375 dst; observed AST::Assert, AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::FuncCall, AST::GetField, AST::GetIndex, AST::HashLit, ...; no source callsite
  - src/backends/pipeline_host.rb:375 src; observed AST::Assert, AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::FuncCall, AST::GetField, AST::GetIndex, AST::HashLit, ...; no source callsite
- src/backends/pipeline_host.rb:4396: affects 2 of 504 union candidates; source calls 0
  - src/backends/pipeline_host.rb:4396 inner; observed AST::AverageOp, AST::MaxOp, AST::MinOp, AST::SumOp; no source callsite
  - src/backends/pipeline_host.rb:4396 lhs; observed AST::Identifier, AST::MethodCall, AST::RangeLit; no source callsite
- src/backends/pipeline_host.rb:691: affects 2 of 504 union candidates; source calls 0
  - src/backends/pipeline_host.rb:691 expr_node; observed AST::BinaryOp, AST::GetField, AST::Identifier; no source callsite
  - src/backends/pipeline_host.rb:691 list_node; observed AST::BinaryOp, AST::Identifier; no source callsite
- ... 452 more source group(s)

### Missing Sigs Needing Manual Review (94)
- src/backends/pipeline_host.rb:1574 add_sig: [downgraded from high by sorbet pre-validate] add missing sig
- src/mir/mir_lowering.rb:7414 add_sig: add missing sig
- src/tools/atomic_escape_suggester.rb:25 add_sig: add missing sig
- src/tools/atomic_escape_suggester.rb:53 add_sig: add missing sig
- src/tools/atomic_migration_suggester.rb:53 add_sig: add missing sig
- src/tools/atomic_migration_suggester.rb:60 add_sig: add missing sig
- src/tools/atomic_migration_suggester.rb:103 add_sig: add missing sig
- src/tools/atomic_migration_suggester.rb:122 add_sig: add missing sig
- src/tools/atomic_migration_suggester.rb:128 add_sig: add missing sig
- src/tools/atomic_migration_suggester.rb:162 add_sig: add missing sig
- src/tools/atomic_ptr_migration_suggester.rb:41 add_sig: add missing sig
- src/tools/atomic_ptr_migration_suggester.rb:47 add_sig: add missing sig
- src/tools/atomic_ptr_migration_suggester.rb:84 add_sig: add missing sig
- src/tools/atomic_ptr_migration_suggester.rb:115 add_sig: add missing sig
- src/tools/atomic_ptr_migration_suggester.rb:121 add_sig: add missing sig
- src/tools/completions.rb:31 add_sig: add missing sig
- src/tools/completions.rb:44 add_sig: add missing sig
- src/tools/completions.rb:92 add_sig: add missing sig
- src/tools/completions.rb:127 add_sig: add missing sig
- src/tools/doctor.rb:73 add_sig: add missing sig
- ... 74 more

### Other Review Actions (1368)
- src/backends/pipeline_rewriter.rb:765 fix_sig_param: static callsites prove param node is AST::BinaryOp; 4 static callsite(s) agree
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `OwnershipDataflow::OwnerEntry#allocator` as Symbol (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `OwnershipDataflow::OwnerEntry#needs_cleanup` as T::Boolean (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `OwnershipDataflow::OwnerEntry#state` as Symbol (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `AST::FuncCall#name` as String (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `OwnershipGraph::Node#kind` as Symbol (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `OwnershipGraph::Node#line` as Integer (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `OwnershipGraph::Node#path` as String (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `OwnershipGraph::Node#scope_depth` as Integer (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `OwnershipGraph::Node#state` as Symbol (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `AST::MethodCall#name` as String (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `BinaryOpResult#type` as Type (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `OwnershipDataflow::DataflowStep#consumed` as Set (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `OwnershipDataflow::DataflowStep#state` as Hash (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `AST::StructLit#fields` as T.any(Hash, T::Hash[`T.untyped`, `T.untyped`]) (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `MIR::Call#args` as T.any(Array, T::Array[`T.untyped`]) (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `MIR::Call#callee` as String (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `FsmOps::CallExpr#args` as T.any(Array, T::Array[`T.untyped`]) (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `FsmOps::AssignField#value` as T.any(FsmOps::AllocExpr, FsmOps::CallExpr) (struct field RBI)
- sorbet/rbi/ast-struct-fields.rbi:1 add_struct_field_sig: type `MIR::Param#name` as String (struct field RBI)
- ... 1348 more
## High-Confidence Actions (49)
- src/backends/transpiler.rb:65 narrow_generic_param: narrow generic param pkg_paths from T::Hash[`T.untyped`, `T.untyped`] to T::Hash[String, String]
  - method: `ZigTranspiler#transpile`
  - current: sig { params(cheat_code: String, source_dir: String, pkg_paths: T::Hash[`T.untyped`, `T.untyped`], use_c_allocator: T::Boolean, use_debug_allocator: T::Boolean, test_mode: T::Boolean, strict_test: T::Boolean, exact_tiers: T.nilable(T::Hash[`T.untyped`, `T.untyped`]), main_tier: T.nilable(Symbol), default_stack: T.nilable(String)).returns(T.nilable(String)) }
  - evidence: observed T::Hash[String, String]
- src/backends/transpiler.rb:75 narrow_generic_param: narrow generic param pkg_paths from T::Hash[`T.untyped`, `T.untyped`] to T::Hash[String, String]
  - method: `ZigTranspiler#transpile_mir`
  - current: sig { params(cheat_code: String, source_dir: String, pkg_paths: T::Hash[`T.untyped`, `T.untyped`], use_c_allocator: T::Boolean, use_debug_allocator: T::Boolean, test_mode: T::Boolean, strict_test: T::Boolean, exact_tiers: T.nilable(T::Hash[`T.untyped`, `T.untyped`]), main_tier: T.nilable(Symbol), default_stack: T.nilable(String)).returns(T.nilable(String)) }
  - evidence: observed T::Hash[String, String]
- src/backends/importer.rb:31 narrow_generic_param: narrow generic param pkg_paths from T::Hash[`T.untyped`, `T.untyped`] to T::Hash[String, String]
  - method: `ModuleImporter#initialize`
  - current: sig { params(base_dir: String, pkg_paths: T::Hash[`T.untyped`, `T.untyped`], use_mir: T::Boolean, stdlib_root: String).void }
  - evidence: observed T::Hash[String, String]
- src/annotator-helpers/with_match_check.rb:387 narrow_generic_return: narrow generic return from T.nilable(T::Set[`T.untyped`]) to T.nilable(T::Set[String])
  - method: `WithMatchCheck#warn_polymorphic_unhandled_errors!`
  - current: sig { params(node: AST::WithBlock, bound_params: T::Set[String], requires_map: T::Hash[String, T::Set[Symbol]], policy_handlers: T::Array[T::Hash[Symbol, `T.untyped`]], warn_handler: Proc).returns(T.nilable(T::Set[`T.untyped`])) }
  - evidence: observed T.nilable(T::Set[String])
- src/mir/concurrency_checks.rb:136 narrow_generic_return: narrow generic return from T::Set[`T.untyped`] to T::Set[String]
  - method: `ConcurrencyChecks#lock_holding_names`
  - current: sig { params(with_block: `T.untyped`).returns(T::Set[`T.untyped`]) }
  - evidence: observed T::Set[String]
- src/mir/concurrency_checks.rb:230 narrow_generic_return: narrow generic return from T::Set[`T.untyped`] to T::Set[String]
  - method: `ConcurrencyChecks#collect_held_params`
  - current: sig { params(with_block: `T.untyped`, fn: `T.untyped`).returns(T::Set[`T.untyped`]) }
  - evidence: observed T::Set[String]
- src/tools/atomic_migration_suggester.rb:174 add_sig: add missing sig
  - method: `AtomicMigrationSuggester#field_get_of?`
  - proposed: sig { params(node: T.any(AST::GetField, AST::Literal), alias_name: String, field_name: String).returns(T::Boolean) }
- src/annotator.rb:356 narrow_generic_return: narrow generic return from T::Set[`T.untyped`] to T::Set[String]
  - method: `SemanticAnnotator#outer_scope_vars`
  - current: sig { returns(T::Set[`T.untyped`]) }
  - evidence: observed T::Set[String]
- src/tools/lint_fix_rewriter.rb:165 add_sig: add missing sig
  - method: `LintFixRewriter#mutable_unused_finding?`
  - proposed: sig { params(finding: FixableFinding).returns(T::Boolean) }
- src/tools/lint_fix_rewriter.rb:184 add_sig: add missing sig
  - method: `LintFixRewriter#edit_from_span`
  - proposed: sig { params(span: Span, replacement: String).returns(Hash) }
- src/ast/parser.rb:4084 narrow_generic_return: narrow generic return from T::Array[`T.untyped`] to T::Array[String]
  - method: `Parser#parse_when_tags`
  - current: sig { returns(T::Array[`T.untyped`]) }
  - evidence: observed T::Array[String]
- src/annotator.rb:1064 narrow_generic_param: narrow generic param types from T::Set[`T.untyped`] to T::Set[String]
  - method: `SemanticAnnotator#collect_pipe_input_types`
  - current: sig { params(body: T::Array[`T.untyped`], types: T::Set[`T.untyped`]).returns(T::Array[`T.untyped`]) }
  - evidence: observed T::Set[String]
- src/tools/pprof_converter.rb:401 add_sig: add missing sig
  - method: `PprofConverter#parse_addr`
  - proposed: sig { params(s: String).returns(Integer) }
- src/tools/pprof.rb:181 fix_sig_return: existing sig return is `T.untyped`; static return origins suggest String
  - method: `Pprof::Profile#encode`
  - current: sig { params(location_ids: Array, values: Array, labels: Hash).returns(`T.untyped`) }
  - proposed: change return to String
  - evidence: static candidate String
- src/tools/pprof.rb:42 add_sig: add missing sig
  - method: `Pprof::Wire#field_varint`
  - proposed: sig { params(field: Integer, n: Integer).returns(String) }
- src/tools/doctor.rb:654 add_sig: add missing sig
  - method: `Doctor#section_locks`
  - proposed: sig { params(profile_dir: String).returns(NilClass) }
- src/tools/doctor.rb:903 add_sig: add missing sig
  - method: `Doctor#section_mvcc`
  - proposed: sig { params(profile_dir: String).returns(NilClass) }
- src/tools/doctor.rb:1095 add_sig: add missing sig
  - method: `Doctor#section_atomic_escape`
  - proposed: sig { params(profile_dir: String).returns(NilClass) }
- src/tools/doctor.rb:1139 add_sig: add missing sig
  - method: `Doctor#section_syscalls`
  - proposed: sig { params(profile_dir: String).returns(NilClass) }
- src/tools/doctor.rb:1155 add_sig: add missing sig
  - method: `Doctor#section_hardware`
  - proposed: sig { params(profile_dir: String).returns(NilClass) }
- src/tools/doctor.rb:1651 add_sig: add missing sig
  - method: `Doctor#bytes_pretty`
  - proposed: sig { params(n: Integer).returns(String) }
- src/tools/predicate_rewriter.rb:412 add_sig: add missing sig
  - method: `PredicateRewriter#expression_terminator_op?`
  - proposed: sig { params(source: String, j: Integer).returns(T::Boolean) }
- src/tools/predicate_rewriter.rb:303 add_sig: add missing sig
  - method: `PredicateRewriter#literal_source_length`
  - proposed: sig { params(node: AST::Literal, source: String, lit_off: Integer).returns(Integer) }
- src/tools/predicate_rewriter.rb:283 add_sig: add missing sig
  - method: `PredicateRewriter#expand_paren_wrap`
  - proposed: sig { params(source: String, lhs_start: Integer, lhs_end: Integer).returns(Array) }
- src/tools/predicate_rewriter.rb:426 add_sig: add missing sig
  - method: `PredicateRewriter#receiver_source_for_method_call`
  - proposed: sig { params(call: AST::MethodCall, source: String).returns(String) }
- src/tools/predicate_rewriter.rb:445 add_sig: add missing sig
  - method: `PredicateRewriter#paren_if_needed`
  - proposed: sig { params(text: String).returns(String) }
- src/tools/predicate_rewriter.rb:475 add_sig: add missing sig
  - method: `PredicateRewriter#apply_edits`
  - proposed: sig { params(source: String, edits: Array).returns(String) }
- src/annotator-helpers/auto_inference.rb:355 narrow_tlet: narrow existing `T.let` to Proc
  - proposed: change `T.let` type to Proc
  - evidence: observed Proc
- src/annotator-helpers/effects.rb:117 narrow_tlet: narrow existing `T.let` to T.nilable(Integer)
  - proposed: change `T.let` type to T.nilable(Integer)
  - evidence: observed T.nilable(Integer)
- src/annotator-helpers/fixable_helpers.rb:430 narrow_tlet: narrow existing `T.let` to T.nilable(String)
  - proposed: change `T.let` type to T.nilable(String)
  - evidence: observed T.nilable(String)
- src/annotator.rb:3102 narrow_tlet: narrow existing `T.let` to T.any(AST::GetField, AST::GetIndex, AST::Identifier)
  - proposed: change `T.let` type to T.any(AST::GetField, AST::GetIndex, AST::Identifier)
  - evidence: observed T.any(AST::GetField, AST::GetIndex, AST::Identifier)
- src/annotator.rb:3697 narrow_tlet: narrow existing `T.let` to T.nilable(AST::CopyNode)
  - proposed: change `T.let` type to T.nilable(AST::CopyNode)
  - evidence: observed T.nilable(AST::CopyNode)
- src/annotator.rb:5422 narrow_tlet: narrow existing `T.let` to T.any(AST::CopyNode, AST::Identifier, AST::StructLit)
  - proposed: change `T.let` type to T.any(AST::CopyNode, AST::Identifier, AST::StructLit)
  - evidence: observed T.any(AST::CopyNode, AST::Identifier, AST::StructLit)
- src/ast/ast.rb:216 narrow_tlet: narrow existing `T.let` to T.nilable(T.any(String, Symbol))
  - method: `AST::Locatable#zig_pattern`
  - current: sig { returns(`T.untyped`) }
  - proposed: change `T.let` type to T.nilable(T.any(String, Symbol))
  - evidence: observed T.nilable(T.any(String, Symbol))
- src/ast/ast.rb:218 narrow_tlet: narrow existing `T.let` to T.nilable(T.any(String, Symbol))
  - method: `AST::Locatable#zig_pattern=`
  - current: sig { params(val: `T.untyped`).returns(`T.untyped`) }
  - proposed: change `T.let` type to T.nilable(T.any(String, Symbol))
  - evidence: observed T.nilable(T.any(String, Symbol))
- src/ast/ast.rb:231 narrow_tlet: narrow existing `T.let` to T.nilable(T::Boolean)
  - method: `AST::Locatable#mutates_receiver`
  - current: sig { returns(`T.untyped`) }
  - proposed: change `T.let` type to T.nilable(T::Boolean)
  - evidence: observed T.nilable(T::Boolean)
- src/ast/ast.rb:236 narrow_tlet: narrow existing `T.let` to T.nilable(T::Boolean)
  - method: `AST::Locatable#was_moved`
  - current: sig { returns(`T.untyped`) }
  - proposed: change `T.let` type to T.nilable(T::Boolean)
  - evidence: observed T.nilable(T::Boolean)
- src/ast/ast.rb:241 narrow_tlet: narrow existing `T.let` to T.nilable(T::Boolean)
  - method: `AST::Locatable#container_borrow`
  - current: sig { returns(`T.untyped`) }
  - proposed: change `T.let` type to T.nilable(T::Boolean)
  - evidence: observed T.nilable(T::Boolean)
- src/ast/ast.rb:246 narrow_tlet: narrow existing `T.let` to T.nilable(T::Boolean)
  - method: `AST::Locatable#needs_mut_ref`
  - current: sig { returns(`T.untyped`) }
  - proposed: change `T.let` type to T.nilable(T::Boolean)
  - evidence: observed T.nilable(T::Boolean)
- src/ast/ast.rb:256 narrow_tlet: narrow existing `T.let` to T.nilable(T::Boolean)
  - method: `AST::Locatable#needs_heap_create`
  - current: sig { returns(`T.untyped`) }
  - proposed: change `T.let` type to T.nilable(T::Boolean)
  - evidence: observed T.nilable(T::Boolean)
- src/ast/ast.rb:271 narrow_tlet: narrow existing `T.let` to T.nilable(String)
  - method: `AST::Locatable#resource_close_zig`
  - current: sig { returns(`T.untyped`) }
  - proposed: change `T.let` type to T.nilable(String)
  - evidence: observed T.nilable(String)
- src/ast/ast.rb:273 narrow_tlet: narrow existing `T.let` to T.nilable(String)
  - method: `AST::Locatable#resource_close_zig=`
  - current: sig { params(val: `T.untyped`).returns(`T.untyped`) }
  - proposed: change `T.let` type to T.nilable(String)
  - evidence: observed T.nilable(String)
- src/ast/ast.rb:276 narrow_tlet: narrow existing `T.let` to T.nilable(T::Boolean)
  - method: `AST::Locatable#can_fail`
  - current: sig { returns(`T.untyped`) }
  - proposed: change `T.let` type to T.nilable(T::Boolean)
  - evidence: observed T.nilable(T::Boolean)
- src/ast/ast.rb:291 narrow_tlet: narrow existing `T.let` to T.nilable(T::Boolean)
  - method: `AST::Locatable#var_used`
  - current: sig { returns(`T.untyped`) }
  - proposed: change `T.let` type to T.nilable(T::Boolean)
  - evidence: observed T.nilable(T::Boolean)
- src/ast/ast.rb:293 narrow_tlet: narrow existing `T.let` to T.nilable(T::Boolean)
  - method: `AST::Locatable#var_used=`
  - current: sig { params(val: `T.untyped`).returns(`T.untyped`) }
  - proposed: change `T.let` type to T.nilable(T::Boolean)
  - evidence: observed T.nilable(T::Boolean)
- src/ast/ast.rb:296 narrow_tlet: narrow existing `T.let` to T.nilable(T::Boolean)
  - method: `AST::Locatable#var_mutated`
  - current: sig { returns(`T.untyped`) }
  - proposed: change `T.let` type to T.nilable(T::Boolean)
  - evidence: observed T.nilable(T::Boolean)
- src/ast/ast.rb:301 narrow_tlet: narrow existing `T.let` to T.nilable(SymbolEntry)
  - method: `AST::Locatable#symbol`
  - current: sig { returns(`T.untyped`) }
  - proposed: change `T.let` type to T.nilable(SymbolEntry)
  - evidence: observed T.nilable(SymbolEntry)
- src/backends/pipeline_host.rb:2175 narrow_tlet: narrow existing `T.let` to T.any(AST::BinaryOp, AST::Identifier)
  - proposed: change `T.let` type to T.any(AST::BinaryOp, AST::Identifier)
  - evidence: observed T.any(AST::BinaryOp, AST::Identifier)
- src/lsp/document_store.rb:27 narrow_tlet: narrow existing `T.let` to T.nilable(T.any(LSP::Analyzer::Result, String))
  - method: `LSP::DocumentStore#cached_findings`
  - current: sig { returns(`T.untyped`) }
  - proposed: change `T.let` type to T.nilable(T.any(LSP::Analyzer::Result, String))
  - evidence: observed T.nilable(T.any(LSP::Analyzer::Result, String))

## Gap Actions (0)
- none

## Untyped Slots
- bucket: runtime-observation state for the current `T.untyped` slot, such as unobserved, nil-only, single-type, or runtime union
- source category: static origin category explaining where the untyped value appears to come from
- unknown expression cause: parser/indexer reason the report could not classify the expression more precisely

### Param `T.untyped` Buckets
- runtime union; kept `T.untyped` by policy: 476
  - 3 slots: src/annotator-helpers/function_analysis.rb:11 `FunctionAnalysis#analyze_routine` node; 9415 call(s); observed AST::FunctionDef, AST::LambdaLit; direct protocol: none observed; analysis gaps: forwarded to declare_and_verify_params slo ...
  - 3 slots: src/ast/scope.rb:24 `Scope#declare` reg; 490381 call(s); observed AST::BindExpr, AST::LetBinding, AST::StubDecl, AST::VarDecl, NilClass; direct protocol: none observed
  - 3 slots: src/ast/symbol_entry.rb:151 `SymbolEntry#initialize` reg; 490412 call(s); observed AST::BindExpr, AST::LetBinding, AST::StubDecl, AST::VarDecl, NilClass, String, Symbol; direct protocol: none observed; analysis gaps: captured in @reg ...
  - 3 slots: src/mir/mir_lowering.rb:7489 `MIRLowering#try_catch_with_provenance` left; 151 call(s); observed MIR::Call, MIR::Ident, MIR::InlineZig; direct protocol: none observed; analysis gaps: forwarded to mir_allocates? slot 0 at src/mir/mir_ ...
  - 3 slots: src/mir/thunk_transform/emit.rb:266 `ThunkTransform::Emit#build_mutual_arm` cf; 25 call(s); observed AST::FunctionDef, OpenStruct; strong direct protocol #mutual_thunk_plan, #name; analysis gaps: forwarded to find_cycle_member slot 0 ...
  - 2 slots: src/annotator-helpers/auto_inference.rb:228 `AutoConstraintCollector#record_reassignment_sources` entry; 8 call(s); observed Array, Hash; weak direct protocol #[]; analysis gaps: forwarded to [] slot 0 at src/annotator-helpers/auto_i ...
  - 2 slots: src/annotator-helpers/auto_inference.rb:439 `AutoUnifier#types_equal?` a; 13 call(s); observed Symbol, Type; medium direct protocol #==, #resolved
  - 2 slots: src/annotator-helpers/capabilities.rb:1325 `CapabilityAudit#record_capability_binding` node; 19769 call(s); observed AST::BindExpr, AST::VarDecl; medium direct protocol #token; other potential options, not exhaustive: AST::AllOp, AST ...
- single observed type; narrow candidate: 257
  - 7 slots: src/mir/fsm_transform/recursive_splitter.rb:568 `FsmTransform::RecursiveSplitter#emit_for_each_iterator` for_stmt; 2 call(s); observed AST::ForEach
  - 6 slots: src/mir/fsm_transform/recursive_splitter.rb:616 `FsmTransform::RecursiveSplitter#emit_for_each_indexed` for_stmt; 1 call(s); observed AST::ForEach
  - 5 slots: src/mir/fsm_transform/emit.rb:697 `FsmTransform::Emit#expand_lock_segment` spec; 215 call(s); observed Hash
  - 5 slots: src/mir/fsm_transform/recursive_splitter.rb:649 `FsmTransform::RecursiveSplitter#emit_for_each_pool` for_stmt; 1 call(s); observed AST::ForEach
  - 4 slots: src/lsp/code_actions.rb:60 `LSP::CodeActions#build_action` fix; 11 call(s); observed Fix
  - 4 slots: src/mir/concurrency_checks.rb:32 `ConcurrencyChecks#check_all!` fn_nodes; 4702 call(s); observed Hash
  - 4 slots: src/mir/fsm_transform/emit.rb:296 `FsmTransform::Emit#build_recursive` ctx; 727 call(s); observed Hash
  - 4 slots: src/mir/fsm_transform/emit.rb:649 `FsmTransform::Emit#check_fsm_cleanup_invariant!` seg_codes; 734 call(s); observed Array
- slot not observed: method was not hit: 83
  - 6 slots: src/ast/schemas.rb:43 `Schemas::ResourceSchema#initialize` close_zig; 0 call(s); observed no observed runtime type
  - 2 slots: src/annotator-helpers/capabilities.rb:1364 `CapabilityAudit#audit_mark_bg_captures` body_exprs; 0 call(s); observed no observed runtime type
  - 2 slots: src/annotator-helpers/fixable_helpers.rb:1224 `FixableHelper#build_decl_cap_replace_fix` name; 0 call(s); observed no observed runtime type
  - 2 slots: src/annotator-helpers/fixable_helpers.rb:528 `FixableHelper#emit_overflow_suffix_fix!` node; 0 call(s); observed no observed runtime type
  - 2 slots: src/annotator-helpers/fixable_helpers.rb:935 `FixableHelper#emit_with_read_needs_write_lock!` name; 0 call(s); observed no observed runtime type
  - 2 slots: src/annotator-helpers/pipe_analysis.rb:1120 `PipeAnalysis#emit_multi_map_warning` conc; 0 call(s); observed no observed runtime type
  - 2 slots: src/annotator-helpers/pipe_analysis.rb:1189 `PipeAnalysis#analyze_auto_shard_each_op` smooth_node; 0 call(s); observed no observed runtime type
  - 2 slots: src/annotator-helpers/pipe_analysis.rb:1222 `PipeAnalysis#auto_detect_sharded_access` smooth_node; 0 call(s); observed no observed runtime type
- slot not observed: source index did not model this param shape: 39
  - 1 slot: src/annotator-helpers/auto_inference.rb:568 `ShapeEvidenceCollector#walk_for_shape_decls` block; 1570 call(s); observed no observed runtime type
  - 1 slot: src/annotator-helpers/auto_inference.rb:728 `OperatorEvidenceCollector#walk_for_local_decls` block; 1409 call(s); observed no observed runtime type
  - 1 slot: src/annotator-helpers/capabilities.rb:57 `Capabilities#validate!` error_handler; 19769 call(s); observed no observed runtime type
  - 1 slot: src/annotator-helpers/fixable_helpers.rb:1251 `FixableHelper#emit_with_cap_mismatch!` kw; 9 call(s); observed no observed runtime type
  - 1 slot: src/annotator-helpers/fixable_helpers.rb:740 `FixableHelper#emit_match_partial_fix!` kwargs; 12 call(s); observed no observed runtime type
  - 1 slot: src/annotator-helpers/pipe_analysis.rb:1801 `PipeAnalysis#with_soa_tracking` blk; 124 call(s); observed no observed runtime type
  - 1 slot: src/annotator.rb:1079 `SemanticAnnotator#walk_ast` block; 2364 call(s); observed no observed runtime type
  - 1 slot: src/ast/ast.rb:107 `AST#each_bg_block_in_stmt` block; 107323 call(s); observed no observed runtime type
- nil only observed: 15
  - 6 slots: src/backends/pipeline_generator.rb:28 `PipelineGenerator#with_pipeline_context` acc; 121 call(s); observed NilClass
  - 1 slot: src/annotator.rb:6530 `SemanticAnnotator#og_set_moved` consumer_param_type; 258 call(s); observed NilClass
  - 1 slot: src/backends/pipeline_host.rb:104 `PipelineHost#task_config_zig` computed_tier; 198 call(s); observed NilClass
  - 1 slot: src/mir/control_flow.rb:1039 `UseAfterMoveChecker#check` can_fail_fns; 12 call(s); observed NilClass
  - 1 slot: src/mir/mir_checker.rb:253 `MIRChecker#check_fsm_structure!` source; 6 call(s); observed NilClass
  - 1 slot: src/mir/mir_checker.rb:79 `MIRChecker#initialize` fn_name; 1484 call(s); observed NilClass
  - 1 slot: src/mir/mir_lowering.rb:673 `MIRLowering#alloc_expr` _rt_name; 30 call(s); observed NilClass
  - 1 slot: src/tools/migration_suggester_helpers.rb:170 `MigrationSuggesterHelpers#rhs_uses_alias_only_for_field_get?` field_name; 9 call(s); observed NilClass
- boolean pair; T::Boolean candidate: 3
  - 1 slot: src/ast/ast.rb:293 `AST::Locatable#var_used=` val; 39715 call(s); observed FalseClass, NilClass, TrueClass
  - 1 slot: src/ast/diagnostic_examples.rb:154 `DiagnosticExamples#extract_first_heredoc_in_it` expecting_raise; 4264 call(s); observed FalseClass, TrueClass
  - 1 slot: src/ast/source_error.rb:121 `ErrorHelper#fixable!` raise_in_collector; 1245 call(s); observed FalseClass, TrueClass

### Return `T.untyped` Buckets
- runtime union; kept `T.untyped` by policy: 150
  - 1 slot: src/annotator-helpers/auto_inference.rb:108 `AutoConstraintCollector#walk` return; 5726 call(s); observed Array, Hash, NilClass
  - 1 slot: src/annotator-helpers/auto_inference.rb:429 `AutoUnifier#widen_byte_array_to_string` return; 41 call(s); observed Symbol, Type
  - 1 slot: src/annotator-helpers/auto_inference.rb:568 `ShapeEvidenceCollector#walk_for_shape_decls` return; 1570 call(s); observed AST::Assert, AST::Assignment, AST::BinaryOp, AST::FuncCall, AST::GetIndex, AST::HashLit, AST::Identifier, AST::Li ...
  - 1 slot: src/annotator-helpers/auto_inference.rb:589 `ShapeEvidenceCollector#walk` return; 776 call(s); observed AST::BindExpr, AST::HashLit, AST::Identifier, AST::ListLit, AST::Literal, AST::ReturnNode, AST::VarDecl, Array, ...
  - 1 slot: src/annotator-helpers/auto_inference.rb:728 `OperatorEvidenceCollector#walk_for_local_decls` return; 1409 call(s); observed AST::Assert, AST::Assignment, AST::BinaryOp, AST::FuncCall, AST::GetIndex, AST::HashLit, AST::Identifier, AST: ...
  - 1 slot: src/annotator-helpers/auto_inference.rb:751 `OperatorEvidenceCollector#walk_binops` return; 1307 call(s); observed AST::Assert, AST::Assignment, AST::BindExpr, AST::FuncCall, AST::GetIndex, AST::HashLit, AST::Identifier, AST::ListLit, ...
  - 1 slot: src/annotator-helpers/capabilities.rb:640 `CapabilityHelper#acquire_capability!` return; 2105 call(s); observed Array, Hash
  - 1 slot: src/annotator-helpers/effects.rb:1008 `EffectTracker#validate_tight_node!` return; 15032 call(s); observed AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::CapabilityWrap, AST::EachOp, AST::ForRange, AST::GetField, AST::GetIndex, . ...
- single observed type; narrow candidate: 68
  - 1 slot: src/annotator.rb:3101 `SemanticAnnotator#chain_root_name` return; 2212 call(s); observed NilClass, String
  - 1 slot: src/annotator.rb:56 `SemanticAnnotator#current_fn_ctx` return; 405908 call(s); observed FunctionContext, NilClass
  - 1 slot: src/annotator.rb:6005 `SemanticAnnotator#dest_scope_depth_for_target` return; 2 call(s); observed Integer
  - 1 slot: src/annotator.rb:6201 `SemanticAnnotator#root_variable_name` return; 473 call(s); observed String
  - 1 slot: src/annotator.rb:6411 `SemanticAnnotator#find_mutual_max_depth_callee` return; 1 call(s); observed String
  - 1 slot: src/annotator.rb:972 `SemanticAnnotator#synthesize_clause_from_policy` return; 63 call(s); observed Hash
  - 1 slot: src/ast/ast.rb:221 `AST::Locatable#matched_stdlib_def` return; 29381 call(s); observed Hash, NilClass
  - 1 slot: src/ast/ast.rb:231 `AST::Locatable#mutates_receiver` return; 9941 call(s); observed NilClass, TrueClass
- void candidate; return value appears unused: 21
  - 1 slot: src/annotator-helpers/pipe_analysis.rb:171 `PipeAnalysis#analyze_higher_order_op` return; 2550 call(s); observed Integer, NilClass, Symbol, SymbolEntry, Type
  - 1 slot: src/annotator.rb:3278 `SemanticAnnotator#validate_assignment_type` return; 6383 call(s); observed Module, NilClass, Symbol, Type
  - 1 slot: src/annotator.rb:3347 `SemanticAnnotator#visit_GetField` return; 10813 call(s); observed NilClass, Symbol, Type
  - 1 slot: src/annotator.rb:3484 `SemanticAnnotator#visit_UnaryOp` return; 749 call(s); observed Symbol, Type
  - 1 slot: src/annotator.rb:361 `SemanticAnnotator#visit_Program` return; 5753 call(s); observed Symbol, Type
  - 1 slot: src/annotator.rb:3837 `SemanticAnnotator#visit_Literal` return; 50736 call(s); observed Symbol, Type
  - 1 slot: src/annotator.rb:3876 `SemanticAnnotator#visit_BinaryOp` return; 28239 call(s); observed Integer, NilClass, Symbol, Type
  - 1 slot: src/annotator.rb:65 `SemanticAnnotator#with_conditional_context` return; 0 call(s); observed Array, NilClass
- nil only observed: 14
  - 1 slot: src/annotator-helpers/fixable_helpers.rb:1033 `FixableHelper#emit_with_restrict_immutable_error!` return; 10 call(s); observed NilClass
  - 1 slot: src/annotator-helpers/fixable_helpers.rb:1458 `FixableHelper#emit_auto_resolved_finding!` return; 18 call(s); observed NilClass
  - 1 slot: src/annotator-helpers/fixable_helpers.rb:1482 `FixableHelper#emit_auto_shape_resolved_finding!` return; 7 call(s); observed NilClass
  - 1 slot: src/annotator-helpers/fixable_helpers.rb:1524 `FixableHelper#emit_auto_ambiguity_finding!` return; 4 call(s); observed NilClass
  - 1 slot: src/annotator-helpers/fixable_helpers.rb:1555 `FixableHelper#emit_auto_unresolved_finding!` return; 9 call(s); observed NilClass
  - 1 slot: src/annotator-helpers/fixable_helpers.rb:740 `FixableHelper#emit_match_partial_fix!` return; 12 call(s); observed NilClass
  - 1 slot: src/annotator-helpers/fixable_helpers.rb:767 `FixableHelper#emit_return_borrowed_no_copy_error!` return; 9 call(s); observed NilClass
  - 1 slot: src/annotator-helpers/reentrance.rb:403 `ReentranceBridge#emit_mutual_thunk_unsupported!` return; 9 call(s); observed NilClass
- slot not observed: method was not hit: 10
  - 1 slot: src/annotator-helpers/fixable_helpers.rb:528 `FixableHelper#emit_overflow_suffix_fix!` return; 0 call(s); observed no observed runtime type
  - 1 slot: src/annotator-helpers/fixable_helpers.rb:935 `FixableHelper#emit_with_read_needs_write_lock!` return; 0 call(s); observed no observed runtime type
  - 1 slot: src/annotator-helpers/pipe_analysis.rb:1272 `PipeAnalysis#walk_for_sharded_access` return; 0 call(s); observed no observed runtime type
  - 1 slot: src/annotator-helpers/pipe_analysis.rb:1306 `PipeAnalysis#walk_for_sharded_getindex` return; 0 call(s); observed no observed runtime type
  - 1 slot: src/ast/type.rb:604 `Type#location` return; 0 call(s); observed no observed runtime type
  - 1 slot: src/backends/pipeline_host.rb:84 `PipelineHost#with_named_binding` return; 0 call(s); observed MIR::BlockExpr, NilClass, String
  - 1 slot: src/backends/pipeline_rewriter.rb:765 `PipelineRewriter#patch_chain_source!` return; 0 call(s); observed no observed runtime type
  - 1 slot: src/backends/transpiler.rb:48 `ZigTranspiler#collect_bg_blocks` return; 0 call(s); observed no observed runtime type
- slot not observed: method hit but return was not captured: 8
  - 1 slot: src/annotator-helpers/fixable_helpers.rb:1251 `FixableHelper#emit_with_cap_mismatch!` return; 9 call(s); observed no observed runtime type
  - 1 slot: src/annotator-helpers/fixable_helpers.rb:848 `FixableHelper#emit_with_guard_all_bindings_need_as!` return; 2 call(s); observed no observed runtime type
  - 1 slot: src/annotator-helpers/fixable_helpers.rb:883 `FixableHelper#emit_with_guard_mutable_mutated!` return; 8 call(s); observed no observed runtime type
  - 1 slot: src/annotator-helpers/fixable_helpers.rb:993 `FixableHelper#emit_with_materialized_needs_tense!` return; 3 call(s); observed no observed runtime type
  - 1 slot: src/ast/parser.rb:587 `Parser#emit_consume_error_with_fix` return; 45 call(s); observed no observed runtime type
  - 1 slot: src/ast/parser.rb:606 `Parser#emit_syntax_insert_end_of_line!` return; 12 call(s); observed no observed runtime type
  - 1 slot: src/ast/parser.rb:629 `Parser#emit_syntax_insert_before_token!` return; 4 call(s); observed no observed runtime type
  - 1 slot: src/ast/source_error.rb:31 `ErrorHelper#error!` return; 962 call(s); observed no observed runtime type
- boolean pair; T::Boolean candidate: 2
  - 1 slot: src/ast/ast.rb:291 `AST::Locatable#var_used` return; 17653 call(s); observed FalseClass, NilClass, TrueClass
  - 1 slot: src/ast/ast.rb:293 `AST::Locatable#var_used=` return; 39715 call(s); observed FalseClass, NilClass, TrueClass

### Param `T.untyped` Source Categories
- untyped unknown expression: 566
  - src/annotator-helpers/auto_inference.rb:135 `AutoConstraintCollector#record_constraint` node; src/annotator-helpers/auto_inference.rb:118 node
  - src/annotator-helpers/auto_inference.rb:188 `AutoConstraintCollector#record_local` decl_node; src/annotator-helpers/auto_inference.rb:142 node
  - src/annotator-helpers/auto_inference.rb:228 `AutoConstraintCollector#record_reassignment_sources` entry; src/annotator-helpers/auto_inference.rb:216 entry
  - src/annotator-helpers/auto_inference.rb:278 `AutoConstraintCollector#register_list_shape_slot` decl_node; src/annotator-helpers/auto_inference.rb:194 decl_node
  - src/annotator-helpers/auto_inference.rb:289 `AutoConstraintCollector#register_map_shape_slots` decl_node; src/annotator-helpers/auto_inference.rb:197 decl_node
  - src/annotator-helpers/auto_inference.rb:439 `AutoUnifier#types_equal?` a; src/annotator-helpers/auto_inference.rb:422 existing
  - src/annotator-helpers/auto_inference.rb:439 `AutoUnifier#types_equal?` b; src/annotator-helpers/auto_inference.rb:422 t
  - src/annotator-helpers/auto_inference.rb:458 `AutoUnifier#stamp_slot!` type; src/annotator-helpers/auto_inference.rb:375 type
- untyped forwarded return: 241
  - src/annotator-helpers/auto_inference.rb:108 `AutoConstraintCollector#walk` node; src/annotator-helpers/auto_inference.rb:67 program_node; src/annotator-helpers/auto_inference.rb:114 c; src/annotator-helpers/auto_inference.rb:116 v
  - src/annotator-helpers/auto_inference.rb:228 `AutoConstraintCollector#record_reassignment_sources` rhs; src/annotator-helpers/auto_inference.rb:216 decl_node.value
  - src/annotator-helpers/auto_inference.rb:267 `AutoConstraintCollector#empty_list_lit?` node; src/annotator-helpers/auto_inference.rb:193 decl_node.value
  - src/annotator-helpers/auto_inference.rb:273 `AutoConstraintCollector#empty_hash_lit?` node; src/annotator-helpers/auto_inference.rb:196 decl_node.value
  - src/annotator-helpers/auto_inference.rb:568 `ShapeEvidenceCollector#walk_for_shape_decls` node; src/annotator-helpers/auto_inference.rb:557 fn.body; src/annotator-helpers/auto_inference.rb:573 node.value; src/annotator-helpers/auto_inference. ...
  - src/annotator-helpers/auto_inference.rb:589 `ShapeEvidenceCollector#walk` node; src/annotator-helpers/auto_inference.rb:67 program_node; src/annotator-helpers/auto_inference.rb:114 c; src/annotator-helpers/auto_inference.rb:116 v
  - src/annotator-helpers/auto_inference.rb:728 `OperatorEvidenceCollector#walk_for_local_decls` node; src/annotator-helpers/auto_inference.rb:719 fn.body; src/annotator-helpers/auto_inference.rb:733 node.value; src/annotator-helpers/auto_inferen ...
  - src/annotator-helpers/auto_inference.rb:751 `OperatorEvidenceCollector#walk_binops` node; src/annotator-helpers/auto_inference.rb:705 fn.body; src/annotator-helpers/auto_inference.rb:756 node.left; src/annotator-helpers/auto_inference.rb:757  ...
- untyped struct/array/collection value: 34
  - src/annotator-helpers/fixable_helpers.rb:59 `FixableHelper#closest_name` candidates; src/annotator-helpers/fixable_helpers.rb:103 candidates; src/annotator-helpers/fixable_helpers.rb:142 candidates; src/annotator-helpers/fixable_helpers.rb:21 ...
  - src/annotator-helpers/fixable_helpers.rb:848 `FixableHelper#emit_with_guard_all_bindings_need_as!` missing_caps; src/annotator-helpers/capabilities.rb:445 missing_alias
  - src/annotator-helpers/fixable_helpers.rb:883 `FixableHelper#emit_with_guard_mutable_mutated!` names; src/annotator-helpers/capabilities.rb:621 mutated
  - src/annotator-helpers/pipe_analysis.rb:1272 `PipeAnalysis#walk_for_sharded_access` results; src/annotator-helpers/pipe_analysis.rb:1229 sharded_accesses; src/annotator-helpers/pipe_analysis.rb:1298 results
  - src/annotator-helpers/pipe_analysis.rb:1306 `PipeAnalysis#walk_for_sharded_getindex` nodes; src/annotator-helpers/pipe_analysis.rb:1290 [node.value]; src/annotator-helpers/pipe_analysis.rb:1320 val; src/annotator-helpers/pipe_analysis.rb:1322 ...
  - src/annotator-helpers/pipe_analysis.rb:1778 `PipeAnalysis#check_soa_opportunity!` item_type; src/annotator-helpers/pipe_analysis.rb:1805 item_type
  - src/annotator-helpers/pipe_analysis.rb:1801 `PipeAnalysis#with_soa_tracking` item_type; src/annotator-helpers/pipe_analysis.rb:282 item_type; src/annotator-helpers/pipe_analysis.rb:820 item_type; src/annotator-helpers/pipe_analysis.rb:999 ite ...
  - src/ast/diagnostic_examples.rb:81 `DiagnosticExamples#scan_file` out; src/ast/diagnostic_examples.rb:73 out
- untyped literal/static expression: 25
  - src/annotator-helpers/capabilities.rb:907 `CapabilityHelper#capability_alias_type` type; src/annotator-helpers/capabilities.rb:818 cap[:resolved_type] || cap[:old_scope]&.resolve_type(var_name) || :Any; src/annotator-helpers/capabilities.rb:8 ...
  - src/annotator-helpers/effects.rb:1008 `EffectTracker#validate_tight_node!` node; src/annotator-helpers/effects.rb:1004 s; src/annotator-helpers/effects.rb:1015 n; src/annotator-helpers/effects.rb:1026 a
  - src/annotator-helpers/fixable_helpers.rb:1224 `FixableHelper#build_decl_cap_replace_fix` old_sigil; src/annotator-helpers/fixable_helpers.rb:939 '@locked'
  - src/annotator-helpers/function_analysis.rb:11 `FunctionAnalysis#analyze_routine` declared_return; src/annotator.rb:640 :Any; src/annotator.rb:696 declared_return
  - src/annotator.rb:6519 `SemanticAnnotator#og_declare` node; src/annotator-helpers/capabilities.rb:777 nil; src/annotator-helpers/capabilities.rb:795 nil; src/annotator-helpers/capabilities.rb:823 nil
  - src/ast/ast.rb:228 `AST::Locatable#stdlib_allocates=` val; src/annotator-helpers/method_analysis.rb:117 true; src/annotator.rb:2372 true; src/annotator.rb:2575 true
  - src/ast/ast.rb:233 `AST::Locatable#mutates_receiver=` val; src/annotator-helpers/method_analysis.rb:118 true; src/annotator.rb:2373 true; src/annotator.rb:2576 true
  - src/ast/ast.rb:238 `AST::Locatable#was_moved=` val; src/annotator-helpers/function_analysis.rb:406 true; src/annotator-helpers/function_analysis.rb:407 true; src/annotator-helpers/function_analysis.rb:412 true
- untyped instance variable: 7
  - src/ast/ast.rb:278 `AST::Locatable#can_fail=` val; src/annotator-helpers/effects.rb:455 (can_fail[name] == true); src/annotator-helpers/effects.rb:591 true; src/annotator-helpers/function_signature.rb:56 fn.can_fail
  - src/ast/type.rb:355 Type#== other; src/annotator-helpers/auto_inference.rb:440 b; src/annotator-helpers/auto_inference.rb:444 b_sym; src/annotator-helpers/auto_inference.rb:495 :map_key
  - src/lsp/rpc.rb:32 `LSP::RPC#read_message` io; src/lsp/server.rb:54 @stdin
  - src/lsp/rpc.rb:53 `LSP::RPC#write_message` io; src/lsp/server.rb:129 @stdout
  - src/mir/concurrency_checks.rb:32 `ConcurrencyChecks#check_all!` fn_nodes; src/annotator.rb:186 @fn_nodes
  - src/mir/effect_inference.rb:21 `EffectInference#analyze!` fn_nodes; src/annotator.rb:164 @fn_nodes; src/mir/mir_pass.rb:85 @fn_nodes; src/mir/mir_pass.rb:95 @fn_nodes
  - src/mir/ownership_graph.rb:293 OwnershipGraph#[] path; src/annotator-helpers/auto_inference.rb:45 String; src/annotator-helpers/auto_inference.rb:50 `T.untyped`; src/annotator-helpers/auto_inference.rb:58 `T.untyped`

### Return `T.untyped` Source Categories
- untyped forwarded return: 159
  - src/annotator-helpers/auto_inference.rb:108 `AutoConstraintCollector#walk`
  - src/annotator-helpers/auto_inference.rb:568 `ShapeEvidenceCollector#walk_for_shape_decls`
  - src/annotator-helpers/auto_inference.rb:589 `ShapeEvidenceCollector#walk`
  - src/annotator-helpers/auto_inference.rb:728 `OperatorEvidenceCollector#walk_for_local_decls`
  - src/annotator-helpers/auto_inference.rb:751 `OperatorEvidenceCollector#walk_binops`
  - src/annotator-helpers/capabilities.rb:640 `CapabilityHelper#acquire_capability!`
  - src/annotator-helpers/effects.rb:671 `EffectTracker#scan_suspend_points`
  - src/annotator-helpers/effects.rb:1008 `EffectTracker#validate_tight_node!`
- untyped literal/static expression: 81
  - src/annotator-helpers/auto_inference.rb:429 `AutoUnifier#widen_byte_array_to_string`
  - src/annotator-helpers/pipe_analysis.rb:171 `PipeAnalysis#analyze_higher_order_op`
  - src/annotator.rb:6411 `SemanticAnnotator#find_mutual_max_depth_callee`
  - src/ast/ast.rb:329 `AST::Locatable#coerced_type`
  - src/ast/diagnostic_examples.rb:130 `DiagnosticExamples#find_block_end`
  - src/ast/fixable_error.rb:140 `FixCollector#disable!`
  - src/ast/parser.rb:675 `Parser#match!`
  - src/ast/parser.rb:702 `Parser#try_parse_bind_or_assign`
- untyped struct/array/collection value: 20
  - src/annotator-helpers/generic_analysis.rb:325 `GenericAnalysis#extract_type_bindings!`
  - src/annotator-helpers/pipe_analysis.rb:116 `PipeAnalysis#finite_stream_element_type`
  - src/annotator-helpers/pipe_analysis.rb:1272 `PipeAnalysis#walk_for_sharded_access`
  - src/annotator-helpers/pipe_analysis.rb:1306 `PipeAnalysis#walk_for_sharded_getindex`
  - src/annotator.rb:361 `SemanticAnnotator#visit_Program`
  - src/annotator.rb:3484 `SemanticAnnotator#visit_UnaryOp`
  - src/ast/parser.rb:3905 `Parser#parse_comma_seq`
  - src/ast/type.rb:793 `Type#fsm_foreach_descriptor`
- untyped unknown expression: 12
  - src/annotator.rb:3837 `SemanticAnnotator#visit_Literal`
  - src/annotator.rb:5421 `SemanticAnnotator#get_root_object`
  - src/ast/diagnostic_examples.rb:58 `DiagnosticExamples#all`
  - src/ast/parser.rb:1707 `Parser#parse_expression`
  - src/ast/parser.rb:1910 `Parser#parse_suffixes`
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders`
  - src/backends/pipeline_rewriter.rb:765 `PipelineRewriter#patch_chain_source!`
  - src/backends/string_concat_rewriter.rb:27 `StringConcatRewriter#rewrite_in_node!`
- untyped instance variable: 1
  - src/ast/type.rb:604 `Type#location`

### Param Unknown Expression Causes
- unknown expression with multiple unknown types: 8
  - src/annotator-helpers/function_analysis.rb:740 full_type=(0) param[:type].to_sym rescue param[:type]
  - src/annotator-helpers/lock_helper.rb:423 error!(0) sel[:token] || node
  - src/annotator-helpers/lock_helper.rb:455 error!(0) anchor || @current_fn_node || @program_node
  - src/annotator.rb:2773 check_prefixed_int_range!(1) node.value.coerced_type || final_type
  - src/annotator.rb:2856 og_declare(2) node.type_info || final_type
  - src/annotator.rb:3747 full_type=(0) :"~#{inner_types.first}[#{node.items.size}]"
  - src/annotator.rb:5143 full_type=(0) :"~?#{elem_syms.first}[]"
  - src/mir/fsm_transform/suspend_resolvers.rb:35 resolve_next(susp_idx) susp_idx || (seg.index + 1)
- unknown local variable item_type: 8
  - src/annotator-helpers/pipe_analysis.rb:303 full_type=(0) :"HashMap<#{item_type}[]>"
  - src/annotator-helpers/pipe_analysis.rb:307 full_type=(0) :"#{item_type}[]"
  - src/annotator-helpers/pipe_analysis.rb:362 declare(2) :"#{item_type}[]"
  - src/annotator-helpers/pipe_analysis.rb:440 declare(2) :"#{item_type}[]"
  - src/annotator-helpers/pipe_analysis.rb:611 full_type=(0) :"#{item_type}[]"
  - src/annotator-helpers/pipe_analysis.rb:911 full_type=(0) :"?#{item_type}"
  - src/annotator-helpers/pipe_analysis.rb:1623 full_type=(0) case node.right.op when AST::SelectOp :"#{node.right.op.expression.full_type}[]" when AST::WhereOp :"#{item_type}[]" end
  - src/annotator-helpers/pipe_analysis.rb:1686 full_type=(0) case node.right.op when AST::SelectOp then :"#{node.right.op.expression.full_type}[]" when AST::WhereOp then :"#{item_type}[]" end
- unknown operation unresolved constant SymbolEntry: 8
  - src/annotator.rb:2872 [](0) SymbolEntry
  - src/annotator.rb:5989 [](0) SymbolEntry
  - src/annotator.rb:5991 [](0) SymbolEntry
  - src/annotator.rb:6031 [](0) SymbolEntry
  - src/annotator.rb:6075 [](0) SymbolEntry
  - src/annotator.rb:6087 [](0) SymbolEntry
  - src/annotator.rb:6097 [](0) SymbolEntry
  - src/annotator.rb:6115 [](0) SymbolEntry
- unknown operation SelfNode: 6
  - src/annotator-helpers/reentrance.rb:126 split(2) self
  - src/annotator-helpers/reentrance.rb:376 split_mutual(3) self
  - src/annotator.rb:735 split(2) self
  - src/mir/mir_lowering.rb:1396 build_trampoline(1) self
  - src/mir/mir_lowering.rb:1398 build_mutual_trampoline(1) self
  - src/mir/mir_lowering.rb:4015 transform(2) self
- unknown operation RegularExpressionNode: 4
  - src/annotator-helpers/fixable_helpers.rb:815 [](0) /\A\s*/
  - src/ast/diagnostic_examples.rb:187 [](0) /\A( *)/
  - src/lsp/diagnostics.rb:162 split(0) /(%\{[^}]+\})/
  - src/tools/doctor.rb:452 split(0) /\t/
- unknown local variable elem_sym: 3
  - src/annotator.rb:5372 full_type=(0) :"?#{elem_sym}"
  - src/annotator.rb:5385 full_type=(0) :"?#{elem_sym}"
  - src/annotator.rb:5390 full_type=(0) :"?#{elem_sym}"
- unknown operation unresolved constant T::Boolean: 2
  - src/annotator-helpers/effects.rb:1054 [](0) T::Boolean
  - src/annotator-helpers/effects.rb:1140 [](0) T::Boolean
- unknown local variable expr_type: 2
  - src/annotator-helpers/pipe_analysis.rb:368 full_type=(0) :"#{expr_type}[]"
  - src/annotator-helpers/pipe_analysis.rb:445 full_type=(0) :"#{expr_type}[]"
- unknown operation unresolved constant HEAP_STRING_TYPE: 2
  - src/ast/type.rb:170 ==(0) HEAP_STRING_TYPE
  - src/ast/type.rb:170 ==(0) HEAP_STRING_TYPE
- unknown operation unresolved constant UNINIT: 2
  - src/mir/control_flow.rb:565 ==(0) UNINIT
  - src/mir/control_flow.rb:566 ==(0) UNINIT
- unknown operation unresolved constant FsmTransform::Segments::Segment: 2
  - src/mir/fsm_transform/recursive_splitter.rb:132 [](0) FsmTransform::Segments::Segment
  - src/mir/fsm_transform/recursive_splitter.rb:152 [](0) FsmTransform::Segments::Segment
- unknown instance variable @fn_nodes: 2
  - src/mir/mir_pass.rb:85 analyze!(0) @fn_nodes
  - src/mir/mir_pass.rb:95 analyze!(0) @fn_nodes
- unknown operation unresolved constant SUSPENDS: 1
  - src/annotator-helpers/effects.rb:138 ==(0) SUSPENDS
- unknown operation unresolved constant SUSPENDS_LOOP: 1
  - src/annotator-helpers/effects.rb:336 ==(0) SUSPENDS_LOOP
- unknown operation unresolved constant SUSPENDS_CONDITIONAL: 1
  - src/annotator-helpers/effects.rb:337 ==(0) SUSPENDS_CONDITIONAL
- unknown instance variable @can_fail: 1
  - src/annotator-helpers/function_signature.rb:105 can_fail=(0) @can_fail
- unknown operation unresolved constant Type: 1
  - src/annotator-helpers/generic_analysis.rb:70 [](0) Type
- unknown local variable join_type_name: 1
  - src/annotator-helpers/pipe_analysis.rb:503 full_type=(0) :"#{join_type_name}[]"
- unknown local variable nested_element_type: 1
  - src/annotator-helpers/pipe_analysis.rb:645 full_type=(0) :"#{nested_element_type}[]"
- unknown operation unresolved constant Edit: 1
  - src/annotator-helpers/reentrance.rb:512 [](0) Edit
- unknown operation unresolved constant Type::STRING_TYPE: 1
  - src/annotator.rb:300 declare(2) Type::STRING_TYPE
- unknown operation unresolved constant OwnershipGraph::Edge: 1
  - src/annotator.rb:3030 [](0) OwnershipGraph::Edge
- unknown local variable element: 1
  - src/annotator.rb:3467 full_type=(0) :"#{element}[]"
- unknown local variable first_val_type: 1
  - src/annotator.rb:3526 full_type=(0) :"HashMap<#{first_val_type}>"
- unknown local variable base_type: 1
  - src/annotator.rb:3790 full_type=(0) :"#{base_type}[#{node.items.size}]"
- unknown forwarded return error!: 1
  - src/annotator.rb:3838 full_type=(0) case node.type when :NUMBER then :Float64 when :INT64 then :Int64 when :STRING # provenance auto-inferred from location: :rodata in Type constructor if node.storage == :stack Type.new(:"Byte[#{node.value. ...
- unknown operation OrNode: 1
  - src/annotator.rb:5189 full_type=(0) node.expr.full_type || :Void
- unknown local variable last_type: 1
  - src/annotator.rb:5224 full_type=(0) :"~#{last_type}"
- unknown operation unresolved constant AST::Identifier: 1
  - src/annotator.rb:6055 [](0) AST::Identifier
- unknown operation unresolved constant Lexer::Token: 1
  - src/ast/parser.rb:61 [](0) Lexer::Token
- unknown operation unresolved constant Fix: 1
  - src/ast/source_error.rb:120 [](0) Fix
- unknown operation unresolved constant FixableFinding: 1
  - src/ast/syntax_typo_scanner.rb:123 [](0) FixableFinding
- unknown instance variable @observable_terminal: 1
  - src/ast/type.rb:1198 [](0) @observable_terminal
- unknown global variable $0: 1
  - src/backends/transpiler.rb:279 ==(0) $0
- unknown instance variable @stdin: 1
  - src/lsp/server.rb:54 read_message(0) @stdin
- unknown instance variable @stdout: 1
  - src/lsp/server.rb:129 write_message(0) @stdout
- unknown forwarded return lookup_type_schema: 1
  - src/mir/alloc.rb:50 resolve_resource_close(0) ->(name) { lookup_type_schema(name) }
- unknown local variable name: 1
  - src/mir/fsm_transform/liveness.rb:108 [](0) :"#{name}__type"
- unknown operation unresolved constant MIR::Let: 1
  - src/mir/mir_checker.rb:187 [](0) MIR::Let

### Return Unknown Expression Causes
- unknown local variable node: 13
  - src/ast/parser.rb:2499 `Parser#parse_lit` node
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` node
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` node
  - src/backends/pipeline_rewriter.rb:34 `PipelineRewriter#rewrite!` node
  - src/backends/pipeline_rewriter.rb:34 `PipelineRewriter#rewrite!` node
  - src/backends/pipeline_rewriter.rb:774 `PipelineRewriter#replace_named_placeholder` node
  - src/backends/pipeline_rewriter.rb:792 `PipelineRewriter#replace_placeholder` node
  - src/backends/string_concat_rewriter.rb:27 `StringConcatRewriter#rewrite_in_node!` node
- unknown local variable expr: 8
  - src/ast/ast.rb:124 `AST#_expr_each_bg_block_shallow` yield expr
  - src/ast/parser.rb:684 `Parser#parse_statement` expr
  - src/ast/parser.rb:3836 `Parser#parse_bg_body_stmt` expr
  - src/mir/mir_lowering.rb:219 `MIRLowering#hoist_alloc` expr
  - src/mir/mir_lowering.rb:238 `MIRLowering#hoist_owned_value_temp` expr
  - src/mir/mir_lowering.rb:286 `MIRLowering#copy_container_borrow_if_needed` expr
  - src/mir/mir_lowering.rb:286 `MIRLowering#copy_container_borrow_if_needed` expr
  - src/mir/mir_lowering.rb:286 `MIRLowering#copy_container_borrow_if_needed` expr
- unknown local variable result: 8
  - src/ast/parser.rb:684 `Parser#parse_statement` result
  - src/ast/parser.rb:3836 `Parser#parse_bg_body_stmt` result
  - src/mir/fsm_transform/emit.rb:831 `FsmTransform::Emit#build_segment_descriptor` result
  - src/mir/mir_lowering.rb:112 `MIRLowering#lower_scoped` result
  - src/mir/mir_lowering.rb:5398 `MIRLowering#lower_struct_lit` result
  - src/mir/mir_lowering.rb:6225 `MIRLowering#lower_bind_expr` result
  - src/mir/mir_lowering.rb:6989 `MIRLowering#lower_match` result
  - src/mir/mir_lowering.rb:7552 `MIRLowering#with_fiber_capture_map` result
- unknown forwarded return rewrite!: 6
  - src/backends/pipeline_rewriter.rb:57 `PipelineRewriter#rewrite_children!` node.value = rewrite!(node.value)
  - src/backends/pipeline_rewriter.rb:57 `PipelineRewriter#rewrite_children!` node.value = rewrite!(node.value)
  - src/backends/pipeline_rewriter.rb:57 `PipelineRewriter#rewrite_children!` node.value = rewrite!(node.value)
  - src/backends/pipeline_rewriter.rb:57 `PipelineRewriter#rewrite_children!` node.right = rewrite!(node.right)
  - src/backends/pipeline_rewriter.rb:57 `PipelineRewriter#rewrite_children!` node.right = rewrite!(node.right)
  - src/backends/pipeline_rewriter.rb:57 `PipelineRewriter#rewrite_children!` node.result = rewrite!(node.result)
- unknown local variable left: 6
  - src/mir/mir_lowering.rb:5126 `MIRLowering#lower_or_rescue` left
  - src/mir/mir_lowering.rb:5126 `MIRLowering#lower_or_rescue` left
  - src/mir/mir_lowering.rb:5126 `MIRLowering#lower_or_rescue` left
  - src/mir/mir_lowering.rb:5126 `MIRLowering#lower_or_rescue` left
  - src/mir/mir_lowering.rb:5126 `MIRLowering#lower_or_rescue` left
  - src/mir/mir_lowering.rb:5126 `MIRLowering#lower_or_rescue` left
- unknown operation InstanceVariableOrWriteNode: 5
  - src/ast/diagnostic_examples.rb:58 `DiagnosticExamples#all` @all ||= load!
  - src/ast/type.rb:995 `Type#value_type` @value_type_obj ||= T.let(Type.new(@value_type_raw || :Any), T.nilable(Type))
  - src/ast/type.rb:1030 `Type#wrapped_type` @wrapped_type_obj ||= T.let(Type.new(@wrapped_type_raw || :Any), T.nilable(Type))
  - src/ast/type.rb:1042 `Type#payload_type` @payload_type_obj ||= T.let(Type.new(@payload_type_raw || :Any), T.nilable(Type))
  - src/ast/type.rb:1215 `Type#tense_type` @tense_type_obj ||= T.let(Type.new(@tense_type_raw || :Void), T.nilable(Type))
- unknown local variable new_id: 5
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` new_id
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` new_id
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` new_id
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` new_id
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` new_id
- unknown forwarded return rewrite_in_node!: 4
  - src/backends/string_concat_rewriter.rb:45 `StringConcatRewriter#rewrite_children!` node.value = rewrite_in_node!(node.value)
  - src/backends/string_concat_rewriter.rb:45 `StringConcatRewriter#rewrite_children!` node.value = rewrite_in_node!(node.value)
  - src/backends/string_concat_rewriter.rb:45 `StringConcatRewriter#rewrite_children!` node.value = rewrite_in_node!(node.value)
  - src/backends/string_concat_rewriter.rb:45 `StringConcatRewriter#rewrite_children!` node.right = rewrite_in_node!(node.right)
- unknown expression with multiple unknown types: 2
  - src/ast/ast.rb:162 `AST#_expr_each_concurrent_capture` yield node.capture_analysis
  - src/ast/type.rb:1014 `Type#generic_args` @generic_args_obj ||= @generic_args_raw.map { |a| Type.new(a) }
- unknown local variable lhs: 2
  - src/ast/parser.rb:1707 `Parser#parse_expression` lhs
  - src/ast/parser.rb:1910 `Parser#parse_suffixes` lhs
- unknown local variable lit: 2
  - src/ast/parser.rb:2499 `Parser#parse_lit` lit
  - src/ast/parser.rb:2499 `Parser#parse_lit` lit
- unknown local variable t: 2
  - src/ast/type.rb:1634 `Type#from_node` t
  - src/mir/mir_lowering.rb:7589 `MIRLowering#bare_zig_type` t
- unknown local variable new_node: 2
  - src/backends/pipeline_rewriter.rb:774 `PipelineRewriter#replace_named_placeholder` new_node
  - src/backends/pipeline_rewriter.rb:792 `PipelineRewriter#replace_placeholder` new_node
- unknown local variable mir: 2
  - src/mir/fsm_lowering.rb:194 `FsmLowering#wrap_step_as_stmt` mir
  - src/mir/mir_lowering.rb:2088 `MIRLowering#lower_extern_arg` mir
- unknown local variable intercept: 2
  - src/mir/mir_lowering.rb:1697 `MIRLowering#lower_func_call` intercept
  - src/mir/mir_lowering.rb:1814 `MIRLowering#lower_method_call` intercept
- unknown local variable iz: 2
  - src/mir/mir_lowering.rb:2303 `MIRLowering#lower_list_lit` iz
  - src/mir/mir_lowering.rb:4273 `MIRLowering#lower_next_expr` iz
- unknown local variable cmp_node: 2
  - src/mir/mir_lowering.rb:4792 `MIRLowering#lower_binary_op` cmp_node
  - src/mir/mir_lowering.rb:4792 `MIRLowering#lower_binary_op` cmp_node
- unknown local variable out: 2
  - src/mir/thunk_transform/emit.rb:186 `ThunkTransform::Emit#qualify_params` out
  - src/mir/thunk_transform/emit.rb:308 `ThunkTransform::Emit#qualify_with_f` out
- unknown local variable actual_binding: 1
  - src/annotator-helpers/generic_analysis.rb:325 `GenericAnalysis#extract_type_bindings!` subst[p_res] = actual_binding
- unknown local variable target_type: 1
  - src/annotator.rb:3278 `SemanticAnnotator#validate_assignment_type` node.value.coerced_type = target_type
- unknown local variable field_type: 1
  - src/annotator.rb:3347 `SemanticAnnotator#visit_GetField` node.full_type = field_type
- unknown forwarded return error!: 1
  - src/annotator.rb:3837 `SemanticAnnotator#visit_Literal` node.full_type = case node.type when :NUMBER then :Float64 when :INT64 then :Int64 when :STRING # provenance auto-inferred from location: :rodata in Type constructor if node.storage == : ...
- unknown local variable curr: 1
  - src/annotator.rb:5421 `SemanticAnnotator#get_root_object` curr
- unknown local variable name: 1
  - src/annotator.rb:6411 `SemanticAnnotator#find_mutual_max_depth_callee` name
- unknown local variable stmt: 1
  - src/ast/ast.rb:107 `AST#each_bg_block_in_stmt` yield stmt
- unknown local variable k: 1
  - src/ast/diagnostic_examples.rb:130 `DiagnosticExamples#find_block_end` k
- unknown local variable bind: 1
  - src/ast/parser.rb:702 `Parser#try_parse_bind_or_assign` bind
- unknown local variable asgn: 1
  - src/ast/parser.rb:702 `Parser#try_parse_bind_or_assign` asgn
- unknown local variable schema: 1
  - src/ast/scope.rb:300 `ScopeHelper#lookup_type_schema` schema
- unknown forwarded return capacity: 1
  - src/ast/type.rb:1316 `Type#stream_capacity` optional_stream_shape_type&.capacity || tense_type.capacity
- unknown operation RescueModifierNode: 1
  - src/ast/type.rb:1634 `Type#from_node` Type.new(t) rescue nil
- unknown local variable new_call: 1
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` new_call
- unknown local variable new_mc: 1
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` new_mc
- unknown local variable new_bin: 1
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` new_bin
- unknown local variable new_gi: 1
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` new_gi
- unknown local variable new_gf: 1
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` new_gf
- unknown local variable new_ia: 1
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` new_ia
- unknown local variable new_bind: 1
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` new_bind
- unknown local variable new_assign: 1
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` new_assign
- unknown local variable new_uo: 1
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` new_uo
- unknown local variable new_with: 1
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` new_with
- unknown local variable new_sl: 1
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` new_sl
- unknown local variable new_hl: 1
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` new_hl
- unknown local variable new_assert: 1
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` new_assert
- unknown local variable new_if: 1
  - src/backends/pipeline_host.rb:219 `PipelineHost#substitute_placeholders` new_if
- unknown local variable expr_mir: 1
  - src/backends/pipeline_host.rb:2436 `PipelineHost#numeric_fold_expr_typed` expr_mir
- unknown local variable call: 1
  - src/backends/pipeline_rewriter.rb:105 `PipelineRewriter#rewrite_pipeline` call
- unknown local variable op: 1
  - src/backends/pipeline_rewriter.rb:105 `PipelineRewriter#rewrite_pipeline` op
- unknown local variable wrapper: 1
  - src/backends/pipeline_rewriter.rb:307 `PipelineRewriter#fuse_pipeline` wrapper
- unknown local variable new_source: 1
  - src/backends/pipeline_rewriter.rb:765 `PipelineRewriter#patch_chain_source!` cursor.left = new_source
- unknown local variable concat: 1
  - src/backends/string_concat_rewriter.rb:27 `StringConcatRewriter#rewrite_in_node!` concat
- unknown local variable diags: 1
  - src/lsp/diagnostics.rb:58 `LSP::Diagnostics#from_result` diags
- unknown local variable strict: 1
  - src/lsp/hover.rb:63 `LSP::Hover#find_overlapping` strict
- unknown local variable tail: 1
  - src/mir/fsm_transform/emit.rb:209 `FsmTransform::Emit#build_dispatch_tail` tail
- unknown local variable pivot_entry: 1
  - src/mir/fsm_transform/recursive_splitter.rb:202 `FsmTransform::RecursiveSplitter#emit_stmts` pivot_entry
- unknown local variable cast_node: 1
  - src/mir/mir_lowering.rb:376 `MIRLowering#lower` cast_node
- unknown local variable generic_fn: 1
  - src/mir/mir_lowering.rb:968 `MIRLowering#lower_union_def` generic_fn
- unknown local variable union_node: 1
  - src/mir/mir_lowering.rb:968 `MIRLowering#lower_union_def` union_node
- unknown local variable items: 1
  - src/mir/mir_lowering.rb:1095 `MIRLowering#lower_extern_struct` items
- unknown local variable len_expr: 1
  - src/mir/mir_lowering.rb:1902 `MIRLowering#lower_intrinsic` len_expr
- unknown local variable inner: 1
  - src/mir/mir_lowering.rb:2385 `MIRLowering#lower_hash_lit` inner
- unknown local variable wrapped: 1
  - src/mir/mir_lowering.rb:2385 `MIRLowering#lower_hash_lit` wrapped
- unknown local variable raw: 1
  - src/mir/mir_lowering.rb:4399 `MIRLowering#lower_require` raw
- unknown local variable mir_node: 1
  - src/mir/mir_lowering.rb:7496 `MIRLowering#strip_try` mir_node

## Nilability Pressure By Root Callsite
- pressure: how many review actions are attributed to the same source location
- root callsite: the caller/source location where nil entered one or more typed slots
- src/backends/pipeline_generator.rb:28 priority 9.46; affects `T.nilable` in 6 signature slot(s), 726 observed call(s)
  - src/backends/pipeline_generator.rb:28 acc
  - src/backends/pipeline_generator.rb:28 soa
  - src/backends/pipeline_generator.rb:28 shard_map
  - src/backends/pipeline_generator.rb:28 shard_idx
  - src/backends/pipeline_generator.rb:28 shard_key
- src/ast/symbol_entry.rb:151 priority 6.67; affects `T.nilable` in 1 signature slot(s), 470595 observed call(s)
  - src/ast/symbol_entry.rb:151 reg
- src/ast/scope.rb:24 priority 6.67; affects `T.nilable` in 1 signature slot(s), 470577 observed call(s)
  - src/ast/scope.rb:24 reg
- src/mir/mir_pass.rb:23 priority 6.05; affects `T.nilable` in 2 signature slot(s), 1897 observed call(s)
  - src/mir/mir_pass.rb:23 bindings (candidate Hash; default {})
  - src/mir/mir_pass.rb:23 promo (candidate Hash; default {})
- src/annotator.rb:250 priority 5.84; affects `T.nilable` in 1 signature slot(s), 68841 observed call(s)
  - src/annotator.rb:250 node
- src/tools/lint_fix_rewriter.rb:211 priority 5.52; affects `T.nilable` in 1 signature slot(s), 33492 observed call(s)
  - src/tools/lint_fix_rewriter.rb:211 n
- src/tools/predicate_rewriter.rb:118 priority 5.37; affects `T.nilable` in 1 signature slot(s), 23669 observed call(s)
  - src/tools/predicate_rewriter.rb:118 n
- src/ast/ast.rb:273 priority 5.37; affects `T.nilable` in 1 signature slot(s), 23540 observed call(s)
  - src/ast/ast.rb:273 val (candidate String; default "")
- src/tools/method_rewriter.rb:138 priority 5.37; affects `T.nilable` in 1 signature slot(s), 23463 observed call(s)
  - src/tools/method_rewriter.rb:138 node
- src/tools/predicate_rewriter.rb:103 priority 5.37; affects `T.nilable` in 1 signature slot(s), 23355 observed call(s)
  - src/tools/predicate_rewriter.rb:103 node
- src/annotator-helpers/function_signature.rb:66 priority 5.26; affects `T.nilable` in 1 signature slot(s), 18382 observed call(s)
  - src/annotator-helpers/function_signature.rb:66 return_lifetime (candidate T.any(Array, String))
- src/tools/lint_fix_rewriter.rb:68 priority 5.22; affects `T.nilable` in 1 signature slot(s), 16745 observed call(s)
  - src/tools/lint_fix_rewriter.rb:68 node
- src/tools/lint_fix_rewriter.rb:89 priority 5.22; affects `T.nilable` in 1 signature slot(s), 16745 observed call(s)
  - src/tools/lint_fix_rewriter.rb:89 node
- src/tools/lint_fix_rewriter.rb:197 priority 5.22; affects `T.nilable` in 1 signature slot(s), 16745 observed call(s)
  - src/tools/lint_fix_rewriter.rb:197 node
- src/annotator-helpers/effects.rb:671 priority 5.18; affects `T.nilable` in 1 signature slot(s), 15143 observed call(s)
  - src/annotator-helpers/effects.rb:671 node
- src/tools/method_rewriter.rb:65 priority 5.15; affects `T.nilable` in 1 signature slot(s), 14143 observed call(s)
  - src/tools/method_rewriter.rb:65 node
- src/ast/type.rb:1610 priority 5.10; affects `T.nilable` in 1 signature slot(s), 12536 observed call(s)
  - src/ast/type.rb:1610 vt (candidate T.any(Hash, Type))
- src/annotator.rb:6555 priority 5.01; affects `T.nilable` in 1 signature slot(s), 10133 observed call(s)
  - src/annotator.rb:6555 consumer_param_type (candidate T.any(Symbol, Type))
- src/ast/ast.rb:346 priority 4.99; affects `T.nilable` in 1 signature slot(s), 9822 observed call(s)
  - src/ast/ast.rb:346 declared_type (candidate T.any(Symbol, Type))
- src/annotator.rb:6519 priority 4.97; affects `T.nilable` in 1 signature slot(s), 9433 observed call(s)
  - src/annotator.rb:6519 node
- src/mir/mir_pass.rb:652 priority 4.91; affects `T.nilable` in 1 signature slot(s), 8152 observed call(s)
  - src/mir/mir_pass.rb:652 expr
- src/ast/schemas.rb:108 priority 4.89; affects `T.nilable` in 1 signature slot(s), 7847 observed call(s)
  - src/ast/schemas.rb:108 schema (candidate T.any(Hash, Schemas::StructSchema))
- src/tools/doctor.rb:1213 priority 4.88; affects `T.nilable` in 3 signature slot(s), 65 observed call(s)
  - src/tools/doctor.rb:1213 sites (candidate Array; default [])
  - src/tools/doctor.rb:1213 resolved
  - src/tools/doctor.rb:1213 llc_miss_rate
- src/ast/ast.rb:85 priority 4.84; affects `T.nilable` in 1 signature slot(s), 6904 observed call(s)
  - src/ast/ast.rb:85 expr
- src/ast/ast.rb:124 priority 4.80; affects `T.nilable` in 1 signature slot(s), 6372 observed call(s)
  - src/ast/ast.rb:124 expr
- src/annotator.rb:6088 priority 4.79; affects `T.nilable` in 1 signature slot(s), 6159 observed call(s)
  - src/annotator.rb:6088 v
- src/mir/test_lowering.rb:364 priority 4.64; affects `T.nilable` in 1 signature slot(s), 4374 observed call(s)
  - src/mir/test_lowering.rb:364 receiver
- src/annotator.rb:6256 priority 4.63; affects `T.nilable` in 1 signature slot(s), 4246 observed call(s)
  - src/annotator.rb:6256 node
- src/annotator.rb:6272 priority 4.61; affects `T.nilable` in 1 signature slot(s), 4098 observed call(s)
  - src/annotator.rb:6272 node
- src/ast/ast.rb:162 priority 4.57; affects `T.nilable` in 1 signature slot(s), 3714 observed call(s)
  - src/ast/ast.rb:162 node
- src/mir/escape_analysis.rb:441 priority 4.51; affects `T.nilable` in 1 signature slot(s), 3200 observed call(s)
  - src/mir/escape_analysis.rb:441 node
- src/mir/mir_lowering.rb:716 priority 4.41; affects `T.nilable` in 1 signature slot(s), 2559 observed call(s)
  - src/mir/mir_lowering.rb:716 target_node (candidate T.any(AST::GetField, AST::Identifier))
- src/ast/ast.rb:293 priority 4.37; affects `T.nilable` in 1 signature slot(s), 2339 observed call(s)
  - src/ast/ast.rb:293 val (candidate T::Boolean)
- src/mir/fsm_wrapper_emitter.rb:239 priority 4.35; affects `T.nilable` in 1 signature slot(s), 2253 observed call(s)
  - src/mir/fsm_wrapper_emitter.rb:239 cleanups (candidate Array; default [])
- src/mir/fsm_wrapper_emitter.rb:571 priority 4.35; affects `T.nilable` in 1 signature slot(s), 2240 observed call(s)
  - src/mir/fsm_wrapper_emitter.rb:571 s (candidate String; default "")
- src/mir/ownership_graph.rb:323 priority 4.35; affects `T.nilable` in 1 signature slot(s), 2231 observed call(s)
  - src/mir/ownership_graph.rb:323 consumer_param_type (candidate T.any(Symbol, Type))
- src/mir/ownership_graph.rb:113 priority 4.33; affects `T.nilable` in 1 signature slot(s), 2141 observed call(s)
  - src/mir/ownership_graph.rb:113 consumer_param_type (candidate T.any(Symbol, Type))
- src/mir/mir_checker.rb:79 priority 4.17; affects `T.nilable` in 1 signature slot(s), 1484 observed call(s)
  - src/mir/mir_checker.rb:79 fn_name
- src/mir/control_flow.rb:698 priority 4.14; affects `T.nilable` in 1 signature slot(s), 1369 observed call(s)
  - src/mir/control_flow.rb:698 node
- src/mir/control_flow.rb:1887 priority 3.99; affects `T.nilable` in 1 signature slot(s), 979 observed call(s)
  - src/mir/control_flow.rb:1887 expr
- src/mir/control_flow.rb:1140 priority 3.98; affects `T.nilable` in 1 signature slot(s), 964 observed call(s)
  - src/mir/control_flow.rb:1140 node
- src/ast/type.rb:199 priority 3.98; affects `T.nilable` in 1 signature slot(s), 960 observed call(s)
  - src/ast/type.rb:199 raw_input
- src/backends/transpiler.rb:160 priority 3.92; affects `T.nilable` in 1 signature slot(s), 837 observed call(s)
  - src/backends/transpiler.rb:160 override (candidate Symbol)
- src/ast/ast.rb:308 priority 3.91; affects `T.nilable` in 1 signature slot(s), 815 observed call(s)
  - src/ast/ast.rb:308 val (candidate T.any(FunctionSignature, Symbol, Type))
- src/mir/mir_checker.rb:874 priority 3.84; affects `T.nilable` in 1 signature slot(s), 689 observed call(s)
  - src/mir/mir_checker.rb:874 expr
- src/mir/fsm_transform/liveness.rb:240 priority 3.76; affects `T.nilable` in 1 signature slot(s), 569 observed call(s)
  - src/mir/fsm_transform/liveness.rb:240 node
- src/mir/mir_pass.rb:38 priority 3.71; affects `T.nilable` in 1 signature slot(s), 513 observed call(s)
  - src/mir/mir_pass.rb:38 promo (candidate Hash; default {})
- src/annotator-helpers/auto_inference.rb:108 priority 3.69; affects `T.nilable` in 1 signature slot(s), 486 observed call(s)
  - src/annotator-helpers/auto_inference.rb:108 node
- src/tools/predicate_rewriter.rb:62 priority 3.50; affects `T.nilable` in 1 signature slot(s), 314 observed call(s)
  - src/tools/predicate_rewriter.rb:62 node
- src/annotator.rb:6530 priority 3.41; affects `T.nilable` in 1 signature slot(s), 258 observed call(s)
  - src/annotator.rb:6530 consumer_param_type

## Union Pressure Downgraded To `T.untyped`
- downgrade: a slot observed with multiple runtime types was kept as `T.untyped` instead of emitted as `T.any(...)`
- why it happens: `T.any(...)` is risky when the runtime sample may not include every type that can reach the slot
Changing these to T.any(...) can be dangerous unless you are certain the runtime sample includes every type that can reach the slot. Static analysis can separately look for other types that could be passed without breaking the function.
- src/ast/symbol_entry.rb:151 priority 12.11; affects `T.any` in 3 signature slot(s), 980350 observed call(s)
  - src/ast/symbol_entry.rb:151 reg (observed AST::BindExpr, AST::LetBinding, AST::StubDecl, AST::VarDecl, String, ...)
  - src/ast/symbol_entry.rb:151 type (observed FunctionSignature, String, Symbol, Type)
  - src/ast/symbol_entry.rb:151 mutable (observed FalseClass, Lexer::Token, TrueClass)
- src/ast/scope.rb:24 priority 9.89; affects `T.any` in 2 signature slot(s), 980275 observed call(s)
  - src/ast/scope.rb:24 type (observed FunctionSignature, String, Symbol, Type)
  - src/ast/scope.rb:24 is_mutable (observed FalseClass, Lexer::Token, TrueClass)
- src/ast/type.rb:2297 priority 8.34; affects `T.any` in 2 signature slot(s), 79310 observed call(s)
  - src/ast/type.rb:2297 source_type (observed Symbol, Type)
  - src/ast/type.rb:2297 target_type (observed Symbol, Type)
- src/annotator-helpers/function_signature.rb:66 priority 7.99; affects `T.any` in 2 signature slot(s), 44816 observed call(s)
  - src/annotator-helpers/function_signature.rb:66 return_type (observed Hash, Proc, Symbol, Type)
  - src/annotator-helpers/function_signature.rb:66 return_lifetime (observed Array, String)
- src/annotator-helpers/function_analysis.rb:11 priority 7.46; affects `T.any` in 2 signature slot(s), 18775 observed call(s)
  - src/annotator-helpers/function_analysis.rb:11 body (observed AST::BinaryOp, AST::Identifier, AST::Literal, Array)
  - src/annotator-helpers/function_analysis.rb:11 declared_return (observed Symbol, Type)
- src/annotator.rb:250 priority 7.20; affects `T.any` in 1 signature slot(s), 1580368 observed call(s)
  - src/annotator.rb:250 node (observed AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp, ...)
- src/ast/lexer.rb:299 priority 7.14; affects `T.any` in 1 signature slot(s), 1374997 observed call(s)
  - src/ast/lexer.rb:299 val (observed Float, Integer, String)
- src/ast/type.rb:199 priority 6.78; affects `T.any` in 1 signature slot(s), 602843 observed call(s)
  - src/ast/type.rb:199 raw_input (observed FunctionSignature, String, Symbol, Type)
- src/annotator-helpers/effects.rb:671 priority 6.65; affects `T.any` in 1 signature slot(s), 443835 observed call(s)
  - src/annotator-helpers/effects.rb:671 node (observed AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp, ...)
- src/ast/ast.rb:308 priority 6.44; affects `T.any` in 1 signature slot(s), 274951 observed call(s)
  - src/ast/ast.rb:308 val (observed FunctionSignature, Symbol, Type)
- src/ast/type.rb:355 priority 6.30; affects `T.any` in 1 signature slot(s), 198783 observed call(s)
  - src/ast/type.rb:355 other (observed Symbol, Type)
- src/mir/control_flow.rb:1657 priority 6.26; affects `T.any` in 1 signature slot(s), 183436 observed call(s)
  - src/mir/control_flow.rb:1657 nodes (observed AST::AllOp, AST::AnyOp, AST::AverageOp, AST::BatchWindowOp, AST::BgBlock, ...)
- src/mir/thunk_transform/recursive_splitter.rb:194 priority 6.23; affects `T.any` in 2 signature slot(s), 2527 observed call(s)
  - src/mir/thunk_transform/recursive_splitter.rb:194 node (observed AST::BinaryOp, AST::FuncCall, AST::Identifier, AST::Literal, Array, ...)
  - src/mir/thunk_transform/recursive_splitter.rb:194 names_set (observed Array, Set)
- src/annotator.rb:6256 priority 5.96; affects `T.any` in 1 signature slot(s), 90338 observed call(s)
  - src/annotator.rb:6256 node (observed AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::CallSiteOverride, AST::ConcurrentOp, ...)
- src/annotator.rb:6272 priority 5.92; affects `T.any` in 1 signature slot(s), 82706 observed call(s)
  - src/annotator.rb:6272 node (observed AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::CallSiteOverride, AST::CopyNode, ...)
- src/ast/type.rb:2292 priority 5.90; affects `T.any` in 1 signature slot(s), 79462 observed call(s)
  - src/ast/type.rb:2292 input (observed Symbol, Type)
- src/annotator.rb:6088 priority 5.82; affects `T.any` in 1 signature slot(s), 66242 observed call(s)
  - src/annotator.rb:6088 v (observed AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BreakNode, ...)
- src/ast/source_error.rb:31 priority 5.64; affects `T.any` in 2 signature slot(s), 967 observed call(s)
  - src/ast/source_error.rb:31 node_or_token (observed AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp, ...)
  - src/ast/source_error.rb:31 code_or_message (observed String, Symbol)
- src/ast/ast.rb:60 priority 5.59; affects `T.any` in 1 signature slot(s), 38889 observed call(s)
  - src/ast/ast.rb:60 body (observed AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, ...)
- src/ast/ast.rb:293 priority 5.57; affects `T.any` in 1 signature slot(s), 37376 observed call(s)
  - src/ast/ast.rb:293 val (observed FalseClass, TrueClass)
- src/ast/type.rb:2305 priority 5.53; affects `T.any` in 1 signature slot(s), 33969 observed call(s)
  - src/ast/type.rb:2305 effective_type (observed FunctionSignature, Symbol, Type)
- src/backends/zig_type_mapper.rb:38 priority 5.49; affects `T.any` in 1 signature slot(s), 31200 observed call(s)
  - src/backends/zig_type_mapper.rb:38 type (observed FunctionSignature, String, Symbol, Type)
- src/annotator.rb:6519 priority 5.47; affects `T.any` in 1 signature slot(s), 29237 observed call(s)
  - src/annotator.rb:6519 type_info (observed Symbol, Type)
- src/annotator.rb:6616 priority 5.47; affects `T.any` in 1 signature slot(s), 29237 observed call(s)
  - src/annotator.rb:6616 type_info (observed Symbol, Type)
- src/ast/scope.rb:122 priority 5.43; affects `T.any` in 1 signature slot(s), 26984 observed call(s)
  - src/ast/scope.rb:122 schema (observed Hash, Schemas::StructSchema)
- src/annotator.rb:5830 priority 5.38; affects `T.any` in 1 signature slot(s), 24148 observed call(s)
  - src/annotator.rb:5830 node (observed AST::BgBlock, AST::BinaryOp, AST::CapabilityWrap, AST::CopyNode, AST::FuncCall, ...)
- src/annotator-helpers/generic_analysis.rb:71 priority 5.38; affects `T.any` in 1 signature slot(s), 24050 observed call(s)
  - src/annotator-helpers/generic_analysis.rb:71 type_obj (observed Symbol, Type)
- src/annotator-helpers/generic_analysis.rb:538 priority 5.30; affects `T.any` in 1 signature slot(s), 19769 observed call(s)
  - src/annotator-helpers/generic_analysis.rb:538 final_type (observed Symbol, Type)
- src/mir/alloc.rb:29 priority 5.30; affects `T.any` in 1 signature slot(s), 19769 observed call(s)
  - src/mir/alloc.rb:29 final_type (observed Symbol, Type)
- src/ast/ast.rb:376 priority 5.30; affects `T.any` in 1 signature slot(s), 19769 observed call(s)
  - src/ast/ast.rb:376 final_type (observed Symbol, Type)
- src/annotator-helpers/generic_analysis.rb:568 priority 5.30; affects `T.any` in 1 signature slot(s), 19769 observed call(s)
  - src/annotator-helpers/generic_analysis.rb:568 final_type (observed Symbol, Type)
- src/mir/alloc.rb:45 priority 5.30; affects `T.any` in 1 signature slot(s), 19769 observed call(s)
  - src/mir/alloc.rb:45 final_type (observed Symbol, Type)
- src/annotator-helpers/capabilities.rb:1325 priority 5.30; affects `T.any` in 1 signature slot(s), 19769 observed call(s)
  - src/annotator-helpers/capabilities.rb:1325 final_type (observed Symbol, Type)
- src/ast/ast.rb:321 priority 5.26; affects `T.any` in 1 signature slot(s), 18262 observed call(s)
  - src/ast/ast.rb:321 val (observed Symbol, Type)
- src/annotator.rb:2304 priority 5.25; affects `T.any` in 1 signature slot(s), 17722 observed call(s)
  - src/annotator.rb:2304 type (observed Symbol, Type)
- src/mir/ownership_graph.rb:293 priority 5.16; affects `T.any` in 1 signature slot(s), 14475 observed call(s)
  - src/mir/ownership_graph.rb:293 path (observed AST::GetField, AST::GetIndex, String)
- src/ast/type.rb:1610 priority 5.10; affects `T.any` in 1 signature slot(s), 12562 observed call(s)
  - src/ast/type.rb:1610 vt (observed Hash, Type)
- src/ast/ast.rb:346 priority 5.07; affects `T.any` in 1 signature slot(s), 11790 observed call(s)
  - src/ast/ast.rb:346 declared_type (observed Symbol, Type)
- src/ast/ast.rb:218 priority 5.05; affects `T.any` in 1 signature slot(s), 11102 observed call(s)
  - src/ast/ast.rb:218 val (observed String, Symbol)
- src/annotator-helpers/effects.rb:1008 priority 5.04; affects `T.any` in 1 signature slot(s), 10882 observed call(s)
  - src/annotator-helpers/effects.rb:1008 node (observed AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::CapabilityWrap, AST::EachOp, ...)
- src/annotator.rb:4218 priority 5.02; affects `T.any` in 1 signature slot(s), 10378 observed call(s)
  - src/annotator.rb:4218 expected_type (observed Symbol, Type)
- src/annotator-helpers/function_context.rb:16 priority 4.97; affects `T.any` in 1 signature slot(s), 9387 observed call(s)
  - src/annotator-helpers/function_context.rb:16 return_type (observed Symbol, Type)
- src/annotator-helpers/function_analysis.rb:887 priority 4.93; affects `T.any` in 1 signature slot(s), 8606 observed call(s)
  - src/annotator-helpers/function_analysis.rb:887 return_type (observed Symbol, Type)
- src/mir/fsm_transform/liveness.rb:240 priority 4.93; affects `T.any` in 1 signature slot(s), 8605 observed call(s)
  - src/mir/fsm_transform/liveness.rb:240 node (observed AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, ...)
- src/mir/effect_set.rb:43 priority 4.92; affects `T.any` in 1 signature slot(s), 8320 observed call(s)
  - src/mir/effect_set.rb:43 effects (observed Array, Set)
- src/ast/schemas.rb:108 priority 4.89; affects `T.any` in 1 signature slot(s), 7817 observed call(s)
  - src/ast/schemas.rb:108 schema (observed Hash, Schemas::StructSchema)
- src/annotator.rb:3278 priority 4.81; affects `T.any` in 1 signature slot(s), 6383 observed call(s)
  - src/annotator.rb:3278 target_type (observed Symbol, Type)
- src/annotator-helpers/fixable_helpers.rb:59 priority 4.78; affects `T.any` in 2 signature slot(s), 238 observed call(s)
  - src/annotator-helpers/fixable_helpers.rb:59 input (observed String, Symbol)
  - src/annotator-helpers/fixable_helpers.rb:59 candidates (observed Array, Set)
- src/mir/mir_lowering.rb:782 priority 4.74; affects `T.any` in 1 signature slot(s), 5547 observed call(s)
  - src/mir/mir_lowering.rb:782 to_type (observed FunctionSignature, Symbol)
- src/mir/mir_lowering.rb:698 priority 4.74; affects `T.any` in 1 signature slot(s), 5535 observed call(s)
  - src/mir/mir_lowering.rb:698 spec (observed Hash, Symbol)

## `T.any` Downgrades By Signature
- signature downgrade: an individual param or return slot where union evidence exists but the report kept the current `T.untyped` signature
- src/mir/fsm_ops.rb:141 value: observed FsmOps::AllocExpr, FsmOps::CallExpr; kept as `T.untyped`
- src/mir/fsm_ops.rb:177 expr: observed FsmOps::ArgRef, FsmOps::CallExpr; kept as `T.untyped`
- src/ast/type.rb:199 raw_input: observed FunctionSignature, String, Symbol, Type; kept as `T.untyped`
- src/ast/lexer.rb:299 val: observed Float, Integer, String; kept as `T.untyped`
- src/ast/parser.rb:1910 lhs: observed AST::BinaryOp, AST::CapabilityWrap, AST::CloneNode, AST::CopyNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::HashLit, AST::Identifier, AST::ListLit, AST::Literal, AST::MethodCall, AST::NextExpr, AST::RangeLit, AST::StaticCall, AST::StructLit, AST::UnaryOp, AST::UnionVariantLit; kept as `T.untyped`
- src/ast/scope.rb:24 reg: observed AST::BindExpr, AST::LetBinding, AST::StubDecl, AST::VarDecl; kept as `T.untyped`
- src/ast/scope.rb:24 type: observed FunctionSignature, String, Symbol, Type; kept as `T.untyped`
- src/ast/scope.rb:24 is_mutable: observed FalseClass, Lexer::Token, TrueClass; kept as `T.untyped`
- src/ast/symbol_entry.rb:151 reg: observed AST::BindExpr, AST::LetBinding, AST::StubDecl, AST::VarDecl, String, Symbol; kept as `T.untyped`
- src/ast/symbol_entry.rb:151 type: observed FunctionSignature, String, Symbol, Type; kept as `T.untyped`
- src/ast/symbol_entry.rb:151 mutable: observed FalseClass, Lexer::Token, TrueClass; kept as `T.untyped`
- src/ast/scope.rb:122 schema: observed Hash, Schemas::StructSchema; kept as `T.untyped`
- src/annotator.rb:345 node: observed AST::Assert, AST::Assignment, AST::BenchmarkStmt, AST::BgBlock, AST::BgStreamBlock, AST::BinaryOp, AST::BindExpr, AST::BlockExpr, AST::BreakNode, AST::CallSiteOverride, AST::CapabilityWrap, AST::Cast, AST::CloneNode, AST::ContinueNode, AST::CopyNode, AST::DoBlock, AST::EnumDef, AST::ExternStructDecl, AST::ForEach, AST::ForRange, AST::FreezeNode, AST::FuncCall, AST::FunctionDef, AST::GetField, AST::GetIndex, AST::HashLit, AST::Identifier, AST::IfBind, AST::IfStatement, AST::LambdaLit, AST::LinkNode, AST::ListLit, AST::Literal, AST::MatchStatement, AST::MethodCall, AST::MoveNode, AST::NextExpr, AST::OptionalUnwrap, AST::OrBreak, AST::OrExit, AST::OrPass, AST::OrPrune, AST::OrRaise, AST::PassStmt, AST::ProfileStmt, AST::Program, AST::Raise, AST::RangeLit, AST::ResolveNode, AST::ReturnNode, AST::ShareNode, AST::Slice, AST::SmashStmt, AST::StaticCall, AST::StructDef, AST::StructLit, AST::StubDecl, AST::SyncPolicyDecl, AST::TestBlock, AST::ThenChain, AST::UnaryOp, AST::UnionDef, AST::UnionVariantLit, AST::VarDecl, AST::WhileBindLoop, AST::WhileLoop, AST::WithBlock, AST::YieldExpr; kept as `T.untyped`
- src/ast/ast.rb:308 val: observed FunctionSignature, Symbol, Type; kept as `T.untyped`
- src/annotator-helpers/function_signature.rb:66 return_type: observed Hash, Proc, Symbol, Type; kept as `T.untyped`
- src/annotator-helpers/function_signature.rb:66 return_lifetime: observed Array, String; kept as `T.untyped`
- src/annotator.rb:2304 type: observed Symbol, Type; kept as `T.untyped`
- src/annotator-helpers/function_context.rb:16 return_type: observed Symbol, Type; kept as `T.untyped`
- src/annotator-helpers/function_analysis.rb:11 node: observed AST::FunctionDef, AST::LambdaLit; kept as `T.untyped`
- src/annotator-helpers/function_analysis.rb:11 body: observed AST::BinaryOp, AST::Identifier, AST::Literal, Array; kept as `T.untyped`
- src/annotator-helpers/function_analysis.rb:11 declared_return: observed Symbol, Type; kept as `T.untyped`
- src/annotator-helpers/function_analysis.rb:814 node: observed AST::FunctionDef, AST::LambdaLit; kept as `T.untyped`
- src/annotator-helpers/function_analysis.rb:719 node: observed AST::FunctionDef, AST::LambdaLit; kept as `T.untyped`
- src/annotator-helpers/function_analysis.rb:854 node: observed AST::FunctionDef, AST::LambdaLit; kept as `T.untyped`
- src/annotator.rb:2690 node: observed AST::BindExpr, AST::VarDecl; kept as `T.untyped`
- src/annotator.rb:5603 node: observed AST::Assignment, AST::BindExpr, AST::VarDecl; kept as `T.untyped`
- src/annotator.rb:5830 node: observed AST::BgBlock, AST::BinaryOp, AST::CapabilityWrap, AST::CopyNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::Identifier, AST::LambdaLit, AST::LinkNode, AST::Literal, AST::MethodCall, AST::MoveNode, AST::NextExpr, AST::RangeLit, AST::ShareNode, AST::StructLit, AST::UnaryOp, AST::UnionVariantLit, String; kept as `T.untyped`
- src/annotator.rb:5460 node: observed AST::Assignment, AST::BindExpr, AST::VarDecl; kept as `T.untyped`
- src/annotator.rb:5530 node: observed AST::Assignment, AST::BindExpr, AST::VarDecl; kept as `T.untyped`
- src/annotator-helpers/generic_analysis.rb:523 node: observed AST::BindExpr, AST::VarDecl; kept as `T.untyped`
- src/annotator.rb:2636 node: observed AST::BindExpr, AST::VarDecl; kept as `T.untyped`
- src/ast/ast.rb:346 declared_type: observed Symbol, Type; kept as `T.untyped`
- src/ast/type.rb:2305 node: observed AST::BgBlock, AST::BgStreamBlock, AST::BinaryOp, AST::BlockExpr, AST::CapabilityWrap, AST::Cast, AST::CloneNode, AST::CopyNode, AST::FreezeNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::HashLit, AST::Identifier, AST::IfStatement, AST::LambdaLit, AST::LinkNode, AST::ListLit, AST::Literal, AST::MatchStatement, AST::MethodCall, AST::MoveNode, AST::NextExpr, AST::RangeLit, AST::ResolveNode, AST::ShareNode, AST::Slice, AST::StaticCall, AST::StructLit, AST::UnaryOp, AST::UnionVariantLit; kept as `T.untyped`
- src/ast/type.rb:2305 effective_type: observed FunctionSignature, Symbol, Type; kept as `T.untyped`
- src/annotator-helpers/generic_analysis.rb:538 node: observed AST::BindExpr, AST::VarDecl; kept as `T.untyped`
- src/annotator-helpers/generic_analysis.rb:538 final_type: observed Symbol, Type; kept as `T.untyped`
- src/mir/alloc.rb:29 node: observed AST::BindExpr, AST::VarDecl; kept as `T.untyped`
- src/mir/alloc.rb:29 final_type: observed Symbol, Type; kept as `T.untyped`
- src/ast/ast.rb:376 final_type: observed Symbol, Type; kept as `T.untyped`
- src/mir/alloc.rb:16 node: observed AST::BindExpr, AST::VarDecl; kept as `T.untyped`
- src/annotator-helpers/generic_analysis.rb:568 node: observed AST::BindExpr, AST::VarDecl; kept as `T.untyped`
- src/annotator-helpers/generic_analysis.rb:568 final_type: observed Symbol, Type; kept as `T.untyped`
- src/annotator-helpers/generic_analysis.rb:615 node: observed AST::BindExpr, AST::VarDecl; kept as `T.untyped`
- src/annotator-helpers/generic_analysis.rb:682 expr: observed AST::Assignment, AST::BgBlock, AST::BgStreamBlock, AST::BinaryOp, AST::BindExpr, AST::BlockExpr, AST::CapabilityWrap, AST::Cast, AST::CloneNode, AST::CopyNode, AST::ForRange, AST::FreezeNode, AST::FuncCall, AST::GetField, AST::GetIndex, AST::HashLit, AST::Identifier, AST::IfStatement, AST::LambdaLit, AST::LinkNode, AST::ListLit, AST::Literal, AST::MatchStatement, AST::MethodCall, AST::MoveNode, AST::NextExpr, AST::RangeLit, AST::ResolveNode, AST::ShareNode, AST::Slice, AST::StaticCall, AST::StructLit, AST::ThenChain, AST::UnaryOp, AST::UnionVariantLit, AST::WhileLoop, AST::WithBlock; kept as `T.untyped`
- src/annotator.rb:6486 node: observed AST::BindExpr, AST::VarDecl; kept as `T.untyped`
- src/mir/alloc.rb:45 node: observed AST::BindExpr, AST::VarDecl; kept as `T.untyped`
- src/mir/alloc.rb:45 final_type: observed Symbol, Type; kept as `T.untyped`
- src/annotator-helpers/capabilities.rb:57 node: observed AST::BindExpr, AST::VarDecl; kept as `T.untyped`
- src/annotator.rb:6519 node: observed AST::BindExpr, AST::LetBinding, AST::StubDecl, AST::VarDecl; kept as `T.untyped`
- src/annotator.rb:6519 type_info: observed Symbol, Type; kept as `T.untyped`

## Return Origin Pressure
- origin: the expression or forwarded callee that currently determines a method's return type
- pressure: how many untyped returns could be improved by fixing the same origin
- cascading return fix: a return annotation that can unlock other forwarded-return annotations after it becomes typed
- blocked: 217
- weak: 42
- strong: 14

Top root return blockers:
- untyped callee let; affects 30 return(s); 30 source occurrence(s)
  - src/ast/ast.rb:216 `AST::Locatable#zig_pattern`
  - src/ast/ast.rb:218 `AST::Locatable#zig_pattern=`
  - src/ast/ast.rb:221 `AST::Locatable#matched_stdlib_def`
  - src/ast/ast.rb:223 `AST::Locatable#matched_stdlib_def=`
- untyped callee each; affects 21 return(s); 32 source occurrence(s); suggestion review as receiver-returning iterator; callers probably want explicit return value
  - src/annotator-helpers/auto_inference.rb:108 `AutoConstraintCollector#walk`
  - src/annotator-helpers/auto_inference.rb:568 `ShapeEvidenceCollector#walk_for_shape_decls`
  - src/annotator-helpers/auto_inference.rb:589 `ShapeEvidenceCollector#walk`
  - src/annotator-helpers/auto_inference.rb:589 `ShapeEvidenceCollector#walk`
- untyped callee fixable!; affects 16 return(s); 16 source occurrence(s)
  - src/annotator-helpers/fixable_helpers.rb:528 `FixableHelper#emit_overflow_suffix_fix!`
  - src/annotator-helpers/fixable_helpers.rb:740 `FixableHelper#emit_match_partial_fix!`
  - src/annotator-helpers/fixable_helpers.rb:767 `FixableHelper#emit_return_borrowed_no_copy_error!`
  - src/annotator-helpers/fixable_helpers.rb:848 `FixableHelper#emit_with_guard_all_bindings_need_as!`
- untyped callee each_value; affects 13 return(s); 13 source occurrence(s); suggestion review as receiver-returning iterator; callers probably want explicit return value
  - src/annotator-helpers/auto_inference.rb:108 `AutoConstraintCollector#walk`
  - src/annotator-helpers/auto_inference.rb:568 `ShapeEvidenceCollector#walk_for_shape_decls`
  - src/annotator-helpers/auto_inference.rb:589 `ShapeEvidenceCollector#walk`
  - src/annotator-helpers/auto_inference.rb:728 `OperatorEvidenceCollector#walk_for_local_decls`
- untyped callee each_pair; affects 10 return(s); 12 source occurrence(s); suggestion review as receiver-returning iterator; callers probably want explicit return value
  - src/annotator-helpers/auto_inference.rb:568 `ShapeEvidenceCollector#walk_for_shape_decls`
  - src/annotator-helpers/auto_inference.rb:589 `ShapeEvidenceCollector#walk`
  - src/annotator-helpers/auto_inference.rb:728 `OperatorEvidenceCollector#walk_for_local_decls`
  - src/annotator-helpers/auto_inference.rb:751 `OperatorEvidenceCollector#walk_binops`
- untyped callee []; affects 9 return(s); 10 source occurrence(s); suggestion review as nilable lookup or replace with fetch/typed accessor
  - src/annotator.rb:5554 `SemanticAnnotator#resolve_borrow_source`
  - src/annotator.rb:5554 `SemanticAnnotator#resolve_borrow_source`
  - src/ast/parser.rb:114 `Parser#peek_at`
  - src/ast/scope.rb:130 `Scope#resolve_type_definition`
- untyped callee call; affects 6 return(s); 7 source occurrence(s)
  - src/annotator.rb:65 `SemanticAnnotator#with_conditional_context`
  - src/annotator.rb:65 `SemanticAnnotator#with_conditional_context`
  - src/backends/pipeline_generator.rb:28 `PipelineGenerator#with_pipeline_context`
  - src/backends/pipeline_host.rb:76 `PipelineHost#with_optional_named_binding`
- untyped callee parse_suffixes; affects 5 return(s); 5 source occurrence(s)
  - src/ast/parser.rb:466 `Parser#parse_literal`
  - src/ast/parser.rb:1925 `Parser#parse_var_id`
  - src/ast/parser.rb:2451 `Parser#parse_primary`
  - src/ast/parser.rb:2499 `Parser#parse_lit`
- untyped callee send; affects 3 return(s); 3 source occurrence(s)
  - src/annotator.rb:345 `SemanticAnnotator#visit`
  - src/ast/parser.rb:500 `Parser#run_action`
  - src/mir/thunk_transform/emit.rb:133 `ThunkTransform::Emit#render_expr`
- untyped callee name; affects 3 return(s); 3 source occurrence(s)
  - src/annotator.rb:3101 `SemanticAnnotator#chain_root_name`
  - src/annotator.rb:6201 `SemanticAnnotator#root_variable_name`
  - src/mir/concurrency_checks.rb:242 `ConcurrencyChecks#cap_var_name`
- untyped callee instance_exec; affects 3 return(s); 3 source occurrence(s)
  - src/ast/parser.rb:684 `Parser#parse_statement`
  - src/ast/parser.rb:2451 `Parser#parse_primary`
  - src/ast/parser.rb:3836 `Parser#parse_bg_body_stmt`
- untyped callee lower; affects 3 return(s); 3 source occurrence(s)
  - src/backends/pipeline_host.rb:170 `PipelineHost#visit_mir`
  - src/mir/mir_lowering.rb:164 `MIRLowering#descend`
  - src/mir/mir_lowering.rb:4792 `MIRLowering#lower_binary_op`
- untyped callee first; affects 3 return(s); 3 source occurrence(s)
  - src/lsp/hover.rb:63 `LSP::Hover#find_overlapping`
  - src/mir/fsm_transform/recursive_splitter.rb:734 `FsmTransform::RecursiveSplitter#emit_with_fragment`
  - src/mir/mir_lowering.rb:1095 `MIRLowering#lower_extern_struct`
- untyped callee each_bg_block_in_stmt; affects 3 return(s); 3 source occurrence(s); suggestion void candidate: return is only forwarded into other returns, never used as a value
  - src/mir/mir_pass.rb:422 `MIRPass#insert_bg_give_suppress!`
  - src/mir/mir_pass.rb:446 `MIRPass#insert_bg_resource_suppress!`
  - src/mir/mir_pass.rb:589 `MIRPass#insert_bg_escape_promote!`
- untyped callee check_reads_in_expr; affects 2 return(s); 15 source occurrence(s)
  - src/mir/control_flow.rb:1050 `UseAfterMoveChecker#check_stmt_reads`
  - src/mir/control_flow.rb:1050 `UseAfterMoveChecker#check_stmt_reads`
  - src/mir/control_flow.rb:1050 `UseAfterMoveChecker#check_stmt_reads`
  - src/mir/control_flow.rb:1050 `UseAfterMoveChecker#check_stmt_reads`
- untyped callee map!; affects 2 return(s); 12 source occurrence(s)
  - src/backends/pipeline_rewriter.rb:57 `PipelineRewriter#rewrite_children!`
  - src/backends/pipeline_rewriter.rb:57 `PipelineRewriter#rewrite_children!`
  - src/backends/pipeline_rewriter.rb:57 `PipelineRewriter#rewrite_children!`
  - src/backends/pipeline_rewriter.rb:57 `PipelineRewriter#rewrite_children!`
- untyped callee walk_expr; affects 2 return(s); 12 source occurrence(s)
  - src/mir/control_flow.rb:801 `OwnershipDataflow#collect_share_transfers_in`
  - src/mir/control_flow.rb:900 `OwnershipDataflow#walk_expr`
  - src/mir/control_flow.rb:900 `OwnershipDataflow#walk_expr`
  - src/mir/control_flow.rb:900 `OwnershipDataflow#walk_expr`
- untyped callee walk_for_was_moved; affects 2 return(s); 8 source occurrence(s)
  - src/mir/control_flow.rb:1959 `BorrowChecker#_collect_was_moved`
  - src/mir/control_flow.rb:1984 `BorrowChecker#walk_for_was_moved`
  - src/mir/control_flow.rb:1984 `BorrowChecker#walk_for_was_moved`
  - src/mir/control_flow.rb:1984 `BorrowChecker#walk_for_was_moved`
- untyped callee parse_primary; affects 2 return(s); 3 source occurrence(s)
  - src/ast/parser.rb:1786 `Parser#parse_or_rescue`
  - src/ast/parser.rb:1786 `Parser#parse_or_rescue`
  - src/ast/parser.rb:1879 `Parser#parse_unary`
- untyped callee emit_typo_suggestion!; affects 2 return(s); 2 source occurrence(s)
  - src/annotator.rb:3347 `SemanticAnnotator#visit_GetField`
  - src/ast/parser.rb:3097 `Parser#apply_capability!`
- untyped callee loop; affects 2 return(s); 2 source occurrence(s)
  - src/ast/lexer.rb:170 `Lexer#read_interpolated_string`
  - src/lsp/server.rb:51 `LSP::Server#run`
- untyped callee tap; affects 2 return(s); 2 source occurrence(s)
  - src/ast/scope.rb:207 `Scope#mark_read`
  - src/mir/mir_lowering.rb:376 `MIRLowering#lower`
- untyped callee rewrite_pipeline; affects 2 return(s); 2 source occurrence(s); suggestion void candidate: return is only forwarded into other returns, never used as a value
  - src/backends/pipeline_rewriter.rb:34 `PipelineRewriter#rewrite!`
  - src/backends/pipeline_rewriter.rb:105 `PipelineRewriter#rewrite_pipeline`
- untyped callee lower_intrinsic; affects 2 return(s); 2 source occurrence(s)
  - src/mir/mir_lowering.rb:1697 `MIRLowering#lower_func_call`
  - src/mir/mir_lowering.rb:1814 `MIRLowering#lower_method_call`
- untyped callee expr; affects 2 return(s); 2 source occurrence(s)
  - src/mir/mir_lowering.rb:2088 `MIRLowering#lower_extern_arg`
  - src/mir/mir_lowering.rb:7496 `MIRLowering#strip_try`
- untyped callee walk_expr_skip_copy; affects 1 return(s); 10 source occurrence(s)
  - src/mir/control_flow.rb:945 `OwnershipDataflow#walk_expr_skip_copy`
  - src/mir/control_flow.rb:945 `OwnershipDataflow#walk_expr_skip_copy`
  - src/mir/control_flow.rb:945 `OwnershipDataflow#walk_expr_skip_copy`
  - src/mir/control_flow.rb:945 `OwnershipDataflow#walk_expr_skip_copy`
- untyped callee e2_walk_calls_in_expr; affects 1 return(s); 10 source occurrence(s)
  - src/mir/escape_analysis.rb:441 `EscapeAnalysis#e2_walk_calls_in_expr`
  - src/mir/escape_analysis.rb:441 `EscapeAnalysis#e2_walk_calls_in_expr`
  - src/mir/escape_analysis.rb:441 `EscapeAnalysis#e2_walk_calls_in_expr`
  - src/mir/escape_analysis.rb:441 `EscapeAnalysis#e2_walk_calls_in_expr`
- untyped callee with_optional_named_binding; affects 1 return(s); 6 source occurrence(s); suggestion void candidate: return is only forwarded into other returns, never used as a value
  - src/backends/pipeline_host.rb:3306 `PipelineHost#lower_concurrent`
  - src/backends/pipeline_host.rb:3306 `PipelineHost#lower_concurrent`
  - src/backends/pipeline_host.rb:3306 `PipelineHost#lower_concurrent`
  - src/backends/pipeline_host.rb:3306 `PipelineHost#lower_concurrent`
- nil return at src/mir/fsm_transform/liveness.rb:240; affects 1 return(s); 6 source occurrence(s)
  - src/mir/fsm_transform/liveness.rb:240 `FsmTransform::Liveness#walk_idents`
  - src/mir/fsm_transform/liveness.rb:240 `FsmTransform::Liveness#walk_idents`
  - src/mir/fsm_transform/liveness.rb:240 `FsmTransform::Liveness#walk_idents`
  - src/mir/fsm_transform/liveness.rb:240 `FsmTransform::Liveness#walk_idents`
- nil return at src/annotator.rb:3278; affects 1 return(s); 3 source occurrence(s)
  - src/annotator.rb:3278 `SemanticAnnotator#validate_assignment_type`
  - src/annotator.rb:3278 `SemanticAnnotator#validate_assignment_type`
  - src/annotator.rb:3278 `SemanticAnnotator#validate_assignment_type`

Top cascading return fixes:
- unknown expression at src/annotator.rb:3838; may unlock 1 return(s) (1 direct, 0 cascading), 0 possible param flow(s)
  - src/annotator.rb:3837 `SemanticAnnotator#visit_Literal`
- nil return at src/ast/fixable_error.rb:141; may unlock 1 return(s) (1 direct, 0 cascading), 0 possible param flow(s)
  - src/ast/fixable_error.rb:140 `FixCollector#disable!`
- nil return at src/ast/schemas.rb:138; may unlock 1 return(s) (1 direct, 0 cascading), 0 possible param flow(s)
  - src/ast/schemas.rb:136 `Schemas#as_resource_schema`
- nil return at src/ast/type.rb:815; may unlock 1 return(s) (1 direct, 0 cascading), 0 possible param flow(s)
  - src/ast/type.rb:793 `Type#fsm_foreach_descriptor`
- nil return at src/ast/type.rb:1283; may unlock 1 return(s) (1 direct, 0 cascading), 0 possible param flow(s)
  - src/ast/type.rb:1282 `Type#open_stream_element_type`
- nil return at src/ast/type.rb:1299; may unlock 1 return(s) (1 direct, 0 cascading), 0 possible param flow(s)
  - src/ast/type.rb:1298 `Type#inf_stream_element_type`
- nil return at src/ast/type.rb:1306; may unlock 1 return(s) (1 direct, 0 cascading), 0 possible param flow(s)
  - src/ast/type.rb:1305 `Type#stream_element_type`
- unknown expression at src/backends/pipeline_rewriter.rb:770; may unlock 1 return(s) (1 direct, 0 cascading), 0 possible param flow(s)
  - src/backends/pipeline_rewriter.rb:765 `PipelineRewriter#patch_chain_source!`
- nil return at src/mir/control_flow.rb:1808; may unlock 1 return(s) (1 direct, 0 cascading), 0 possible param flow(s)
  - src/mir/control_flow.rb:1791 `BorrowChecker#check_stmt`
- nil return at src/mir/mir_lowering.rb:5695; may unlock 1 return(s) (1 direct, 0 cascading), 0 possible param flow(s)
  - src/mir/mir_lowering.rb:5694 `MIRLowering#type_info_for`
- nil return at src/mir/test_lowering.rb:368; may unlock 1 return(s) (1 direct, 0 cascading), 0 possible param flow(s)
  - src/mir/test_lowering.rb:364 `TestLowering#stub_intercept_for`

Forwarded return blocker pressure:
- let: unresolved forwarded callee; affects 30 return(s), 0 possible param flow(s)
  - src/ast/ast.rb:216 `AST::Locatable#zig_pattern`
  - src/ast/ast.rb:218 `AST::Locatable#zig_pattern=`
  - src/ast/ast.rb:221 `AST::Locatable#matched_stdlib_def`
  - src/ast/ast.rb:223 `AST::Locatable#matched_stdlib_def=`
- each: typed signature T::Hash[String, LSP::DocumentStore::Document]; affects 21 return(s), 0 possible param flow(s)
  - src/annotator-helpers/auto_inference.rb:108 `AutoConstraintCollector#walk`
  - src/annotator-helpers/auto_inference.rb:568 `ShapeEvidenceCollector#walk_for_shape_decls`
  - src/annotator-helpers/auto_inference.rb:589 `ShapeEvidenceCollector#walk`
  - src/annotator-helpers/auto_inference.rb:589 `ShapeEvidenceCollector#walk`
- fixable!: callee return still untyped; affects 16 return(s), 0 possible param flow(s)
  - src/annotator-helpers/fixable_helpers.rb:528 `FixableHelper#emit_overflow_suffix_fix!`
  - src/annotator-helpers/fixable_helpers.rb:740 `FixableHelper#emit_match_partial_fix!`
  - src/annotator-helpers/fixable_helpers.rb:767 `FixableHelper#emit_return_borrowed_no_copy_error!`
  - src/annotator-helpers/fixable_helpers.rb:848 `FixableHelper#emit_with_guard_all_bindings_need_as!`
- each_value: unresolved forwarded callee; affects 13 return(s), 0 possible param flow(s)
  - src/annotator-helpers/auto_inference.rb:108 `AutoConstraintCollector#walk`
  - src/annotator-helpers/auto_inference.rb:568 `ShapeEvidenceCollector#walk_for_shape_decls`
  - src/annotator-helpers/auto_inference.rb:589 `ShapeEvidenceCollector#walk`
  - src/annotator-helpers/auto_inference.rb:728 `OperatorEvidenceCollector#walk_for_local_decls`
- each_pair: unresolved forwarded callee; affects 10 return(s), 0 possible param flow(s)
  - src/annotator-helpers/auto_inference.rb:568 `ShapeEvidenceCollector#walk_for_shape_decls`
  - src/annotator-helpers/auto_inference.rb:589 `ShapeEvidenceCollector#walk`
  - src/annotator-helpers/auto_inference.rb:728 `OperatorEvidenceCollector#walk_for_local_decls`
  - src/annotator-helpers/auto_inference.rb:751 `OperatorEvidenceCollector#walk_binops`
- []: typed signature T.nilable(OwnershipGraph::Node); affects 9 return(s), 2134 possible param flow(s)
  - src/annotator.rb:5554 `SemanticAnnotator#resolve_borrow_source`
  - src/annotator.rb:5554 `SemanticAnnotator#resolve_borrow_source`
  - src/ast/parser.rb:114 `Parser#peek_at`
  - src/ast/scope.rb:130 `Scope#resolve_type_definition`
- call: typed signature FsmOps::CallExpr; affects 6 return(s), 15 possible param flow(s)
  - src/annotator.rb:65 `SemanticAnnotator#with_conditional_context`
  - src/annotator.rb:65 `SemanticAnnotator#with_conditional_context`
  - src/backends/pipeline_generator.rb:28 `PipelineGenerator#with_pipeline_context`
  - src/backends/pipeline_host.rb:76 `PipelineHost#with_optional_named_binding`
- parse_suffixes: callee return still untyped; affects 5 return(s), 0 possible param flow(s)
  - src/ast/parser.rb:466 `Parser#parse_literal`
  - src/ast/parser.rb:1925 `Parser#parse_var_id`
  - src/ast/parser.rb:2451 `Parser#parse_primary`
  - src/ast/parser.rb:2499 `Parser#parse_lit`
- name: ambiguous method name; affects 3 return(s), 349 possible param flow(s)
  - src/annotator.rb:3101 `SemanticAnnotator#chain_root_name`
  - src/annotator.rb:6201 `SemanticAnnotator#root_variable_name`
  - src/mir/concurrency_checks.rb:242 `ConcurrencyChecks#cap_var_name`
- lower: callee return still untyped; affects 3 return(s), 49 possible param flow(s)
  - src/backends/pipeline_host.rb:170 `PipelineHost#visit_mir`
  - src/mir/mir_lowering.rb:164 `MIRLowering#descend`
  - src/mir/mir_lowering.rb:4792 `MIRLowering#lower_binary_op`
- first: unresolved forwarded callee; affects 3 return(s), 13 possible param flow(s)
  - src/lsp/hover.rb:63 `LSP::Hover#find_overlapping`
  - src/mir/fsm_transform/recursive_splitter.rb:734 `FsmTransform::RecursiveSplitter#emit_with_fragment`
  - src/mir/mir_lowering.rb:1095 `MIRLowering#lower_extern_struct`
- send: unresolved forwarded callee; affects 3 return(s), 1 possible param flow(s)
  - src/annotator.rb:345 `SemanticAnnotator#visit`
  - src/ast/parser.rb:500 `Parser#run_action`
  - src/mir/thunk_transform/emit.rb:133 `ThunkTransform::Emit#render_expr`
- each_bg_block_in_stmt: callee return still untyped; affects 3 return(s), 0 possible param flow(s)
  - src/mir/mir_pass.rb:422 `MIRPass#insert_bg_give_suppress!`
  - src/mir/mir_pass.rb:446 `MIRPass#insert_bg_resource_suppress!`
  - src/mir/mir_pass.rb:589 `MIRPass#insert_bg_escape_promote!`
- instance_exec: unresolved forwarded callee; affects 3 return(s), 0 possible param flow(s)
  - src/ast/parser.rb:684 `Parser#parse_statement`
  - src/ast/parser.rb:2451 `Parser#parse_primary`
  - src/ast/parser.rb:3836 `Parser#parse_bg_body_stmt`
- expr: unresolved forwarded callee; affects 2 return(s), 45 possible param flow(s)
  - src/mir/mir_lowering.rb:2088 `MIRLowering#lower_extern_arg`
  - src/mir/mir_lowering.rb:7496 `MIRLowering#strip_try`
- tap: unresolved forwarded callee; affects 2 return(s), 1 possible param flow(s)
  - src/ast/scope.rb:207 `Scope#mark_read`
  - src/mir/mir_lowering.rb:376 `MIRLowering#lower`
- check_reads_in_expr: callee return still untyped; affects 2 return(s), 0 possible param flow(s)
  - src/mir/control_flow.rb:1050 `UseAfterMoveChecker#check_stmt_reads`
  - src/mir/control_flow.rb:1050 `UseAfterMoveChecker#check_stmt_reads`
  - src/mir/control_flow.rb:1050 `UseAfterMoveChecker#check_stmt_reads`
  - src/mir/control_flow.rb:1050 `UseAfterMoveChecker#check_stmt_reads`
- emit_typo_suggestion!: typed signature NilClass; affects 2 return(s), 0 possible param flow(s)
  - src/annotator.rb:3347 `SemanticAnnotator#visit_GetField`
  - src/ast/parser.rb:3097 `Parser#apply_capability!`
- loop: unresolved forwarded callee; affects 2 return(s), 0 possible param flow(s)
  - src/ast/lexer.rb:170 `Lexer#read_interpolated_string`
  - src/lsp/server.rb:51 `LSP::Server#run`
- lower_intrinsic: callee return still untyped; affects 2 return(s), 0 possible param flow(s)
  - src/mir/mir_lowering.rb:1697 `MIRLowering#lower_func_call`
  - src/mir/mir_lowering.rb:1814 `MIRLowering#lower_method_call`

High-impact root return actions:
- untyped callee each: review as receiver-returning iterator; callers probably want explicit return value; may unblock 21 return(s)
- untyped callee each_value: review as receiver-returning iterator; callers probably want explicit return value; may unblock 13 return(s)
- untyped callee each_pair: review as receiver-returning iterator; callers probably want explicit return value; may unblock 10 return(s)
- untyped callee []: review as nilable lookup or replace with fetch/typed accessor; may unblock 9 return(s)
- untyped callee each_bg_block_in_stmt: void candidate: return is only forwarded into other returns, never used as a value; may unblock 3 return(s)
- untyped callee rewrite_pipeline: void candidate: return is only forwarded into other returns, never used as a value; may unblock 2 return(s)
- untyped callee with_optional_named_binding: void candidate: return is only forwarded into other returns, never used as a value; may unblock 1 return(s)
- untyped callee with_pending: void candidate: return is only forwarded into other returns, never used as a value; may unblock 1 return(s)
- untyped callee each at src/annotator-helpers/auto_inference.rb:114: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)
- untyped callee each_value at src/annotator-helpers/auto_inference.rb:116: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)
- untyped callee each at src/annotator-helpers/auto_inference.rb:577: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)
- untyped callee each_value at src/annotator-helpers/auto_inference.rb:579: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)
- untyped callee each_pair at src/annotator-helpers/auto_inference.rb:582: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)
- untyped callee each at src/annotator-helpers/auto_inference.rb:595: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)
- untyped callee each at src/annotator-helpers/auto_inference.rb:602: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)
- untyped callee each_value at src/annotator-helpers/auto_inference.rb:604: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)
- untyped callee each_pair at src/annotator-helpers/auto_inference.rb:607: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)
- untyped callee each at src/annotator-helpers/auto_inference.rb:737: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)
- untyped callee each_value at src/annotator-helpers/auto_inference.rb:739: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)
- untyped callee each_pair at src/annotator-helpers/auto_inference.rb:742: review as receiver-returning iterator; callers probably want explicit return value; may unblock 1 return(s)

Blocked return examples:
- src/annotator-helpers/auto_inference.rb:429 `AutoUnifier#widen_byte_array_to_string`: no blocker recorded
- src/annotator-helpers/auto_inference.rb:568 `ShapeEvidenceCollector#walk_for_shape_decls`: untyped callee walk_for_shape_decls at src/annotator-helpers/auto_inference.rb:573
- src/annotator-helpers/auto_inference.rb:589 `ShapeEvidenceCollector#walk`: untyped callee each at src/annotator-helpers/auto_inference.rb:595
- src/annotator-helpers/auto_inference.rb:728 `OperatorEvidenceCollector#walk_for_local_decls`: untyped callee walk_for_local_decls at src/annotator-helpers/auto_inference.rb:733
- src/annotator-helpers/auto_inference.rb:751 `OperatorEvidenceCollector#walk_binops`: untyped callee walk_binops at src/annotator-helpers/auto_inference.rb:757
- src/annotator-helpers/effects.rb:671 `EffectTracker#scan_suspend_points`: untyped callee each at src/annotator-helpers/effects.rb:677
- src/annotator-helpers/effects.rb:1008 `EffectTracker#validate_tight_node!`: untyped callee each at src/annotator-helpers/effects.rb:1015
- src/annotator-helpers/fixable_helpers.rb:528 `FixableHelper#emit_overflow_suffix_fix!`: untyped callee fixable! at src/annotator-helpers/fixable_helpers.rb:538
- src/annotator-helpers/fixable_helpers.rb:1458 `FixableHelper#emit_auto_resolved_finding!`: untyped callee fixable! at src/annotator-helpers/fixable_helpers.rb:1466
- src/annotator-helpers/fixable_helpers.rb:1482 `FixableHelper#emit_auto_shape_resolved_finding!`: untyped callee fixable! at src/annotator-helpers/fixable_helpers.rb:1489
- src/annotator-helpers/fixable_helpers.rb:1524 `FixableHelper#emit_auto_ambiguity_finding!`: untyped callee fixable! at src/annotator-helpers/fixable_helpers.rb:1543
- src/annotator-helpers/fixable_helpers.rb:1555 `FixableHelper#emit_auto_unresolved_finding!`: untyped callee fixable! at src/annotator-helpers/fixable_helpers.rb:1576

## Input Param Origin Backflow
- origin: the caller-side expression passed into a parameter slot
- backflow: tracing weak or untyped parameter pressure backward from the callee slot to the caller expression that supplied it
- return-to-param flow: a method return value that is later passed into another method's parameter
- Origins indexed: 49185
- static: 21509
- local: 11199
- untyped_return: 7523
- unknown: 4857
- typed_return: 4097

Return-to-param flows:
- untyped: 2526 flow(s); src/annotator-helpers/auto_inference.rb:45 -> [](1); src/annotator-helpers/auto_inference.rb:50 -> [](0); src/annotator-helpers/auto_inference.rb:50 -> [](1); src/annotator-helpers/auto_inference.rb:58 -> [](0)
- []: 2194 flow(s); src/annotator-helpers/auto_inference.rb:45 -> params(fn_nodes); src/annotator-helpers/auto_inference.rb:50 -> let(1); src/annotator-helpers/auto_inference.rb:58 -> nilable(0); src/annotator-helpers/auto_inference.rb:64 -> returns(0)
- new: 1330 flow(s); src/annotator-helpers/auto_inference.rb:81 -> []=(1); src/annotator-helpers/auto_inference.rb:88 -> []=(1); src/annotator-helpers/auto_inference.rb:376 -> []=(1); src/annotator-helpers/auto_inference.rb:383 -> []=(1)
- nilable: 894 flow(s); src/annotator-helpers/auto_inference.rb:58 -> let(1); src/annotator-helpers/auto_inference.rb:97 -> params(t); src/annotator-helpers/auto_inference.rb:107 -> params(current_fn); src/annotator-helpers/auto_inference.rb:134 -> returns(0)
- name: 351 flow(s); src/annotator-helpers/auto_inference.rb:150 -> [](0); src/annotator-helpers/auto_inference.rb:209 -> []=(0); src/annotator-helpers/auto_inference.rb:214 -> [](0); src/annotator-helpers/auto_inference.rb:285 -> []=(0)
- value: 250 flow(s); src/annotator-helpers/auto_inference.rb:169 -> <<(0); src/annotator-helpers/auto_inference.rb:193 -> empty_list_lit?(0); src/annotator-helpers/auto_inference.rb:196 -> empty_hash_lit?(0); src/annotator-helpers/auto_inference.rb:207 -> <<(0)
- body: 201 flow(s); src/annotator-helpers/auto_inference.rb:550 -> walk(0); src/annotator-helpers/auto_inference.rb:557 -> walk_for_shape_decls(0); src/annotator-helpers/auto_inference.rb:705 -> walk_binops(0); src/annotator-helpers/auto_inference.rb:719 -> walk_for_local_decls(0)
- to_s: 171 flow(s); src/annotator-helpers/capabilities.rb:560 -> [](0); src/annotator-helpers/capabilities.rb:1242 -> [](0); src/annotator-helpers/capabilities.rb:1292 -> [](0); src/annotator-helpers/capabilities.rb:1295 -> [](0)
- length: 152 flow(s); src/annotator-helpers/capabilities.rb:293 -> new(length); src/annotator-helpers/fixable_helpers.rb:36 -> new(length); src/annotator-helpers/fixable_helpers.rb:110 -> new(length); src/annotator-helpers/fixable_helpers.rb:149 -> new(length)
- must: 144 flow(s); src/annotator-helpers/auto_inference.rb:140 -> record_return(1); src/annotator-helpers/effects.rb:1119 -> fixable!(message); src/annotator-helpers/fixable_helpers.rb:619 -> fixable!(message); src/annotator-helpers/fixable_helpers.rb:636 -> fixable!(message)
- left: 115 flow(s); src/annotator-helpers/auto_inference.rb:756 -> walk_binops(0); src/annotator-helpers/generic_analysis.rb:668 -> find_container_source(0); src/annotator-helpers/generic_analysis.rb:689 -> has_heap_promoted_call?(0); src/annotator-helpers/pipe_analysis.rb:20 -> visit(0)
- resolved: 113 flow(s); src/annotator-helpers/capabilities.rb:196 -> emit_with_materialized_needs_tense!(2); src/annotator-helpers/function_analysis.rb:456 -> error!(expected); src/annotator-helpers/function_analysis.rb:456 -> error!(actual); src/annotator-helpers/function_analysis.rb:478 -> ==(0)
- token: 111 flow(s); src/annotator-helpers/capabilities.rb:329 -> emit_typo_suggestion!(0); src/annotator-helpers/capabilities.rb:338 -> emit_typo_suggestion!(0); src/annotator-helpers/capabilities.rb:348 -> emit_typo_suggestion!(0); src/annotator-helpers/capabilities.rb:724 -> new(0)
- expression: 88 flow(s); src/annotator-helpers/pipe_analysis.rb:283 -> visit(0); src/annotator-helpers/pipe_analysis.rb:335 -> visit(0); src/annotator-helpers/pipe_analysis.rb:363 -> visit(0); src/annotator-helpers/pipe_analysis.rb:441 -> visit(0)
- full_type: 87 flow(s); src/annotator-helpers/capabilities.rb:105 -> must(0); src/annotator-helpers/capabilities.rb:120 -> must(0); src/annotator-helpers/capabilities.rb:644 -> []=(1); src/annotator-helpers/function_analysis.rb:183 -> error_union_type=(0)
- freeze: 77 flow(s); src/annotator-helpers/capabilities.rb:19 -> let(0); src/annotator-helpers/capabilities.rb:27 -> let(0); src/annotator-helpers/effects.rb:66 -> let(0); src/annotator-helpers/effects.rb:68 -> let(0)
- +: 75 flow(s); src/annotator-helpers/fixable_helpers.rb:62 -> let(0); src/annotator-helpers/fixable_helpers.rb:83 -> [](0); src/annotator-helpers/fixable_helpers.rb:190 -> anchor_at(1); src/annotator-helpers/fixable_helpers.rb:566 -> [](0)
- right: 71 flow(s); src/annotator-helpers/auto_inference.rb:757 -> walk_binops(0); src/annotator-helpers/pipe_analysis.rb:22 -> higher_order_list_op?(0); src/annotator-helpers/pipe_analysis.rb:287 -> error!(0); src/annotator-helpers/pipe_analysis.rb:339 -> error!(0)
- to_sym: 61 flow(s); src/annotator-helpers/function_analysis.rb:139 -> <<(0); src/annotator-helpers/function_analysis.rb:910 -> lookup_type_schema(0); src/annotator-helpers/generic_analysis.rb:658 -> lookup_type_schema(0); src/annotator-helpers/method_analysis.rb:88 -> send(1)
- target: 60 flow(s); src/annotator-helpers/capabilities.rb:724 -> new(1); src/annotator-helpers/generic_analysis.rb:648 -> root_variable_name(0); src/annotator-helpers/generic_analysis.rb:664 -> root_variable_name(0); src/annotator-helpers/generic_analysis.rb:672 -> find_container_source(0)

## Foreign Scalar Inputs Into Object-Typed Params
This ranks caller origins where `String`/`Symbol` values flow into params that also receive object instances. It skips `src/tools` origins unless `NIL_KILL_FOREIGN_INCLUDE_TOOLS=1`.
- src/annotator.rb:250 `def program_has_auto?(node)`; 774565 foreign scalar call(s), affects 1 slot(s)
  - src/annotator.rb:250 `SemanticAnnotator#program_has_auto?` node: String, Symbol into AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp (774565); trace src/annotator.rb:250
- src/ast/type.rb:199 `def initialize(raw_input, ownership: nil, sync: nil, layout: nil, location: nil, collection: nil, shard_count: nil, stripe_count: nil, observable: nil, observab`; 480142 foreign scalar call(s), affects 1 slot(s)
  - src/ast/type.rb:199 `Type#initialize` raw_input: String, Symbol into FunctionSignature, Type (480142); trace src/ast/type.rb:199
- src/ast/symbol_entry.rb:151 `def initialize(reg:, type:, mutable:, storage:, sync: nil, layout: nil, rebindable: false,`; 455558 foreign scalar call(s), affects 2 slot(s)
  - src/ast/symbol_entry.rb:151 `SymbolEntry#initialize` type: String, Symbol into FunctionSignature, Type (455545); trace src/ast/symbol_entry.rb:151
  - src/ast/symbol_entry.rb:151 `SymbolEntry#initialize` reg: String, Symbol into AST::BindExpr, AST::LetBinding, AST::StubDecl, AST::VarDecl (13); trace src/ast/symbol_entry.rb:151
- src/ast/scope.rb:24 `def declare(name, reg, type, is_mutable = true, is_rebindable = false, size = nil, storage = :stack, capabilities = Set.new, _borrowed_paths = [], sync: nil, la`; 455514 foreign scalar call(s), affects 1 slot(s)
  - src/ast/scope.rb:24 `Scope#declare` type: String, Symbol into FunctionSignature, Type (455514); trace src/ast/scope.rb:24
- src/annotator-helpers/effects.rb:671 `def scan_suspend_points(node, fn_node, points)`; 224608 foreign scalar call(s), affects 1 slot(s)
  - src/annotator-helpers/effects.rb:671 `EffectTracker#scan_suspend_points` node: String, Symbol into AST::AllOp, AST::AnyOp, AST::Assert, AST::Assignment, AST::AverageOp (224608); trace src/annotator-helpers/effects.rb:671
- src/ast/type.rb:355 `def ==(other)`; 130397 foreign scalar call(s), affects 1 slot(s)
  - src/ast/type.rb:355 Type#== other: Symbol into Type (130397); trace src/ast/type.rb:355
- src/mir/control_flow.rb:1657 `def self.walk_all_nodes(nodes, visited = Set.new, &block)`; 125432 foreign scalar call(s), affects 1 slot(s)
  - src/mir/control_flow.rb:1657 `LoopFrameAnalysis#walk_all_nodes` nodes: String, Symbol into AST::AllOp, AST::AnyOp, AST::AverageOp, AST::BatchWindowOp, AST::BgBlock (125432); trace src/mir/control_flow.rb:1657
- src/ast/ast.rb:308 `def full_type=(val)`; 118920 foreign scalar call(s), affects 1 slot(s)
  - src/ast/ast.rb:308 `AST::Locatable#full_type=` val: Symbol into FunctionSignature, Type (118920); trace src/ast/ast.rb:308
- src/ast/type.rb:2297 `def is_safe_autocast?(source_type, target_type)`; 60855 foreign scalar call(s), affects 2 slot(s)
  - src/ast/type.rb:2297 `TypeHelper#is_safe_autocast?` source_type: Symbol into Type (31337); trace src/ast/type.rb:2297
  - src/ast/type.rb:2297 `TypeHelper#is_safe_autocast?` target_type: Symbol into Type (29518); trace src/ast/type.rb:2297
- src/ast/type.rb:2292 `def to_type(input)`; 60855 foreign scalar call(s), affects 1 slot(s)
  - src/ast/type.rb:2292 `TypeHelper#to_type` input: Symbol into Type (60855); trace src/ast/type.rb:2292
- src/annotator.rb:6256 `def collect_self_calls(node, fn_name, out = [])`; 49450 foreign scalar call(s), affects 1 slot(s)
  - src/annotator.rb:6256 `SemanticAnnotator#collect_self_calls` node: String, Symbol into AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::CallSiteOverride, AST::ConcurrentOp (49450); trace src/annotator.rb:6256
- src/annotator.rb:6272 `def collect_returns(node, out = [])`; 45581 foreign scalar call(s), affects 1 slot(s)
  - src/annotator.rb:6272 `SemanticAnnotator#collect_returns` node: String, Symbol into AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::CallSiteOverride, AST::CopyNode (45581); trace src/annotator.rb:6272
- src/annotator.rb:6088 `def collect_bg_sources_walk(v)`; 35076 foreign scalar call(s), affects 1 slot(s)
  - src/annotator.rb:6088 `SemanticAnnotator#collect_bg_sources_walk` v: String, Symbol into AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BreakNode (35076); trace src/annotator.rb:6088
- src/annotator.rb:5830 `def get_path_to_root(node)`; 24148 foreign scalar call(s), affects 1 slot(s)
  - src/annotator.rb:5830 `SemanticAnnotator#get_path_to_root` node: String into AST::BgBlock, AST::BinaryOp, AST::CapabilityWrap, AST::CopyNode, AST::FuncCall (24148); trace src/annotator.rb:5830
- src/ast/type.rb:2305 `def check_prefixed_int_range!(node, effective_type)`; 19914 foreign scalar call(s), affects 1 slot(s)
  - src/ast/type.rb:2305 `TypeHelper#check_prefixed_int_range!` effective_type: Symbol into FunctionSignature, Type (19914); trace src/ast/type.rb:2305
- src/mir/ownership_graph.rb:293 `def [](path)`; 14475 foreign scalar call(s), affects 1 slot(s)
  - src/mir/ownership_graph.rb:293 OwnershipGraph#[] path: String into AST::GetField, AST::GetIndex (14475); trace src/mir/ownership_graph.rb:293
- src/annotator-helpers/generic_analysis.rb:538 `def propagate_declared_type_to_value!(node, final_type)`; 12386 foreign scalar call(s), affects 1 slot(s)
  - src/annotator-helpers/generic_analysis.rb:538 `GenericAnalysis#propagate_declared_type_to_value!` final_type: Symbol into Type (12386); trace src/annotator-helpers/generic_analysis.rb:538
- src/mir/alloc.rb:29 `def finalize_decl_storage!(node, final_type)`; 12386 foreign scalar call(s), affects 1 slot(s)
  - src/mir/alloc.rb:29 `AllocHelper#finalize_decl_storage!` final_type: Symbol into Type (12386); trace src/mir/alloc.rb:29
- src/ast/ast.rb:376 `def finalize_storage!(final_type, &schema_lookup)`; 12386 foreign scalar call(s), affects 1 slot(s)
  - src/ast/ast.rb:376 `AST::Locatable#finalize_storage!` final_type: Symbol into Type (12386); trace src/ast/ast.rb:376
- src/annotator-helpers/generic_analysis.rb:568 `def propagate_collection_metadata!(node, final_type)`; 12386 foreign scalar call(s), affects 1 slot(s)
  - src/annotator-helpers/generic_analysis.rb:568 `GenericAnalysis#propagate_collection_metadata!` final_type: Symbol into Type (12386); trace src/annotator-helpers/generic_analysis.rb:568
- src/mir/alloc.rb:45 `def resolve_resource_close(node, final_type)`; 12386 foreign scalar call(s), affects 1 slot(s)
  - src/mir/alloc.rb:45 `AllocHelper#resolve_resource_close` final_type: Symbol into Type (12386); trace src/mir/alloc.rb:45
- src/annotator-helpers/capabilities.rb:1325 `def record_capability_binding(var_name, node, final_type, storage)`; 12386 foreign scalar call(s), affects 1 slot(s)
  - src/annotator-helpers/capabilities.rb:1325 `CapabilityAudit#record_capability_binding` final_type: Symbol into Type (12386); trace src/annotator-helpers/capabilities.rb:1325
- src/annotator-helpers/function_signature.rb:66 `def initialize(params:, return_type:, return_lifetime: nil, visibility: nil,`; 8635 foreign scalar call(s), affects 2 slot(s)
  - src/annotator-helpers/function_signature.rb:66 `FunctionSignature#initialize` return_type: Symbol into Hash, Proc, Type (8599); trace src/annotator-helpers/function_signature.rb:66
  - src/annotator-helpers/function_signature.rb:66 `FunctionSignature#initialize` return_lifetime: String into Array (36); trace src/annotator-helpers/function_signature.rb:66
- src/annotator-helpers/effects.rb:1008 `def validate_tight_node!(node, loop_node)`; 5679 foreign scalar call(s), affects 1 slot(s)
  - src/annotator-helpers/effects.rb:1008 `EffectTracker#validate_tight_node!` node: String, Symbol into AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::CapabilityWrap, AST::EachOp (5679); trace src/annotator-helpers/effects.rb:1008
- src/mir/mir_lowering.rb:782 `def mir_cast(mir_node, from_type, to_type)`; 5541 foreign scalar call(s), affects 1 slot(s)
  - src/mir/mir_lowering.rb:782 `MIRLowering#mir_cast` to_type: Symbol into FunctionSignature (5541); trace src/mir/mir_lowering.rb:782
- src/mir/fsm_transform/liveness.rb:240 `def walk_idents(node, &block)`; 5524 foreign scalar call(s), affects 1 slot(s)
  - src/mir/fsm_transform/liveness.rb:240 `FsmTransform::Liveness#walk_idents` node: String, Symbol into AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr (5524); trace src/mir/fsm_transform/liveness.rb:240
- src/ast/ast.rb:321 `def coerced_type=(val)`; 5504 foreign scalar call(s), affects 1 slot(s)
  - src/ast/ast.rb:321 `AST::Locatable#coerced_type=` val: Symbol into Type (5504); trace src/ast/ast.rb:321
- src/backends/zig_type_mapper.rb:38 `def transpile_type(type, is_param: false, is_field: false)`; 5188 foreign scalar call(s), affects 1 slot(s)
  - src/backends/zig_type_mapper.rb:38 `ZigTypeMapper#transpile_type` type: String, Symbol into FunctionSignature, Type (5188); trace src/backends/zig_type_mapper.rb:38
- src/annotator.rb:3278 `def validate_assignment_type(node, target_type, value_type)`; 4616 foreign scalar call(s), affects 1 slot(s)
  - src/annotator.rb:3278 `SemanticAnnotator#validate_assignment_type` target_type: Symbol into Type (4616); trace src/annotator.rb:3278
- src/ast/ast.rb:346 `def coerce!(declared_type)`; 4403 foreign scalar call(s), affects 1 slot(s)
  - src/ast/ast.rb:346 `AST::Locatable#coerce!` declared_type: Symbol into Type (4403); trace src/ast/ast.rb:346
- src/mir/mir_lowering.rb:698 `def coerce_stdlib_arg(arg_zig, spec)`; 4158 foreign scalar call(s), affects 1 slot(s)
  - src/mir/mir_lowering.rb:698 `MIRLowering#coerce_stdlib_arg` spec: Symbol into Hash (4158); trace src/mir/mir_lowering.rb:698
- src/annotator-helpers/generic_analysis.rb:71 `def validate_type_annotation!(node, type_obj, is_param: false)`; 2584 foreign scalar call(s), affects 1 slot(s)
  - src/annotator-helpers/generic_analysis.rb:71 `GenericAnalysis#validate_type_annotation!` type_obj: Symbol into Type (2584); trace src/annotator-helpers/generic_analysis.rb:71
- src/annotator.rb:6555 `def move_if_not_copyable!(node, action: :move, consumer_param_type: nil)`; 1989 foreign scalar call(s), affects 1 slot(s)
  - src/annotator.rb:6555 `SemanticAnnotator#move_if_not_copyable!` consumer_param_type: Symbol into Type (1989); trace src/annotator.rb:6555
- src/mir/mir_emitter.rb:43 `def emit(node)`; 1850 foreign scalar call(s), affects 1 slot(s)
  - src/mir/mir_emitter.rb:43 `MIREmitter#emit` node: String into MIR::AddressOf, MIR::AllocMark, MIR::AllocSlice, MIR::AllocatorRef, MIR::ArrayInit (1850); trace src/mir/mir_emitter.rb:43
- src/annotator-helpers/auto_inference.rb:108 `def walk(node, current_fn:)`; 1764 foreign scalar call(s), affects 1 slot(s)
  - src/annotator-helpers/auto_inference.rb:108 `AutoConstraintCollector#walk` node: String, Symbol into AST::Assert, AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::FuncCall (1764); trace src/annotator-helpers/auto_inference.rb:108
- src/annotator.rb:6519 `def og_declare(name, node, type_info)`; 1637 foreign scalar call(s), affects 1 slot(s)
  - src/annotator.rb:6519 `SemanticAnnotator#og_declare` type_info: Symbol into Type (1637); trace src/annotator.rb:6519
- src/annotator.rb:6616 `def classify_og_kind(type_info, sync: nil)`; 1637 foreign scalar call(s), affects 1 slot(s)
  - src/annotator.rb:6616 `SemanticAnnotator#classify_og_kind` type_info: Symbol into Type (1637); trace src/annotator.rb:6616
- src/annotator-helpers/pipe_analysis.rb:1778 `def check_soa_opportunity!(node, item_type)`; 1343 foreign scalar call(s), affects 1 slot(s)
  - src/annotator-helpers/pipe_analysis.rb:1778 `PipeAnalysis#check_soa_opportunity!` item_type: Symbol into Type (1343); trace src/annotator-helpers/pipe_analysis.rb:1778
- src/mir/thunk_transform/recursive_splitter.rb:266 `def contains_self_call?(node, fn_name)`; 954 foreign scalar call(s), affects 1 slot(s)
  - src/mir/thunk_transform/recursive_splitter.rb:266 `ThunkTransform::RecursiveSplitter#contains_self_call?` node: String, Symbol into AST::BinaryOp, AST::FuncCall, AST::GetField, AST::Identifier, AST::Literal (954); trace src/mir/thunk_transform/recursive_splitter.rb:266
- src/mir/mir_emitter.rb:974 `def alloc_expr(alloc)`; 850 foreign scalar call(s), affects 1 slot(s)
  - src/mir/mir_emitter.rb:974 `MIREmitter#alloc_expr` alloc: Symbol into MIR::AllocatorRef, MIR::Ident (850); trace src/mir/mir_emitter.rb:974
- src/annotator-helpers/auto_inference.rb:568 `def walk_for_shape_decls(node, &block)`; 564 foreign scalar call(s), affects 1 slot(s)
  - src/annotator-helpers/auto_inference.rb:568 `ShapeEvidenceCollector#walk_for_shape_decls` node: String, Symbol into AST::Assert, AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::FuncCall (564); trace src/annotator-helpers/auto_inference.rb:568
- src/mir/thunk_transform/recursive_splitter.rb:194 `def contains_any_call?(node, names_set)`; 546 foreign scalar call(s), affects 1 slot(s)
  - src/mir/thunk_transform/recursive_splitter.rb:194 `ThunkTransform::RecursiveSplitter#contains_any_call?` node: String, Symbol into AST::BinaryOp, AST::FuncCall, AST::Identifier, AST::Literal, Array (546); trace src/mir/thunk_transform/recursive_splitter.rb:194
- src/annotator-helpers/auto_inference.rb:728 `def walk_for_local_decls(node, &block)`; 512 foreign scalar call(s), affects 1 slot(s)
  - src/annotator-helpers/auto_inference.rb:728 `OperatorEvidenceCollector#walk_for_local_decls` node: String, Symbol into AST::Assert, AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::FuncCall (512); trace src/annotator-helpers/auto_inference.rb:728
- src/annotator-helpers/auto_inference.rb:751 `def walk_binops(node, name_to_slot, fn)`; 462 foreign scalar call(s), affects 1 slot(s)
  - src/annotator-helpers/auto_inference.rb:751 `OperatorEvidenceCollector#walk_binops` node: String, Symbol into AST::Assert, AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::FuncCall (462); trace src/annotator-helpers/auto_inference.rb:751
- src/mir/fsm_transform/liveness.rb:198 `def collect_defs(stmt, into)`; 458 foreign scalar call(s), affects 1 slot(s)
  - src/mir/fsm_transform/liveness.rb:198 `FsmTransform::Liveness#collect_defs` stmt: String into AST::Assert, AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::ForRange (458); trace src/mir/fsm_transform/liveness.rb:198
- src/mir/fsm_transform/liveness.rb:230 `def collect_uses(stmt, into)`; 458 foreign scalar call(s), affects 1 slot(s)
  - src/mir/fsm_transform/liveness.rb:230 `FsmTransform::Liveness#collect_uses` stmt: String into AST::Assert, AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::ForRange (458); trace src/mir/fsm_transform/liveness.rb:230
- src/annotator.rb:6601 `def og_set_live(name)  = (@og[name]&.state = :live)`; 353 foreign scalar call(s), affects 1 slot(s)
  - src/annotator.rb:6601 `SemanticAnnotator#og_set_live` name: String into AST::GetField, AST::GetIndex (353); trace src/annotator.rb:6601
- src/mir/test_lowering.rb:317 `def collect_identifier_refs(node, name_set, out)`; 285 foreign scalar call(s), affects 1 slot(s)
  - src/mir/test_lowering.rb:317 `TestLowering#collect_identifier_refs` node: String, Symbol into AST::Assert, AST::BinaryOp, AST::Identifier, AST::Literal, Lexer::Token (285); trace src/mir/test_lowering.rb:317
- src/annotator-helpers/auto_inference.rb:589 `def walk(node, name_map)`; 277 foreign scalar call(s), affects 1 slot(s)
  - src/annotator-helpers/auto_inference.rb:589 `ShapeEvidenceCollector#walk` node: String, Symbol into AST::Assignment, AST::BindExpr, AST::HashLit, AST::Identifier, AST::ListLit (277); trace src/annotator-helpers/auto_inference.rb:589
- src/mir/mir_lowering.rb:3217 `def ast_contains_return?(node)`; 191 foreign scalar call(s), affects 1 slot(s)
  - src/mir/mir_lowering.rb:3217 `MIRLowering#ast_contains_return?` node: String, Symbol into AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::GetField, AST::Identifier (191); trace src/mir/mir_lowering.rb:3217

## Type Normalizer Sites
- Sites matching `is_a?(Type)` plus `Type.new(...)`: 350
- src/annotator.rb: 68
  - line 262 `SemanticAnnotator#program_has_auto?`: node.type.is_a?(Type)
  - line 263 `SemanticAnnotator#program_has_auto?`: node.return_type.is_a?(Type)
  - line 265 `SemanticAnnotator#program_has_auto?`: p[:type].is_a?(Type)
  - line 466 `SemanticAnnotator#visit_Program`: sig.is_a?(Type)
  - line 607 `SemanticAnnotator#pre_register_function`: p[:type].is_a?(Type)
  - ... 63 more
- src/mir/mir_lowering.rb: 58
  - line 273 `MIRLowering#container_borrow_expr?`: ti.is_a?(Type)
  - line 274 `MIRLowering#container_borrow_expr?`: ti.is_a?(Type)
  - line 787 `MIRLowering#mir_cast`: from_type.is_a?(Type)
  - line 788 `MIRLowering#mir_cast`: to_type.is_a?(Type)
  - line 851 `MIRLowering#build_drop_entry!`: ti.is_a?(Type)
  - ... 53 more
- src/annotator-helpers/generic_analysis.rb: 31
  - line 73 `GenericAnalysis#validate_type_annotation!`: type_obj.is_a?(Type)
  - line 193 `GenericAnalysis#validate_type_annotation!`: inner.is_a?(Type)
  - line 271 `GenericAnalysis#infer_generic_type_args!`: param[:type].is_a?(Type)
  - line 272 `GenericAnalysis#infer_generic_type_args!`: arg.type_info.is_a?(Type)
  - line 295 `GenericAnalysis#enforce_shared_family_call_sync!`: param[:type].is_a?(Type)
  - ... 26 more
- src/mir/escape_analysis.rb: 30
  - line 152 `EscapeAnalysis#return_expr_is_heap?`: ti.is_a?(Type)
  - line 153 `EscapeAnalysis#return_expr_is_heap?`: ti.is_a?(Type)
  - line 170 `EscapeAnalysis#per_fn_scan!`: ret_t.is_a?(Type)
  - line 214 `EscapeAnalysis#per_fn_scan!`: sym_ti.is_a?(Type)
  - line 238 `EscapeAnalysis#per_fn_scan!`: ti.is_a?(Type)
  - ... 25 more
- src/ast/type.rb: 25
  - line 102 `Type#coerce_error`: source_type.is_a?(Type)
  - line 103 `Type#coerce_error`: target_type.is_a?(Type)
  - line 161 `Type#resolve_add_op`: t_left.is_a?(Type)
  - line 162 `Type#resolve_add_op`: t_right.is_a?(Type)
  - line 187 `Type#safe_autocast?`: from_type.is_a?(Type)
  - ... 20 more
- src/annotator-helpers/function_analysis.rb: 24
  - line 170 `FunctionAnalysis#resolve_call`: rt.is_a?(Type)
  - line 181 `FunctionAnalysis#resolve_call`: node.full_type.is_a?(Type)
  - line 192 `FunctionAnalysis#resolve_call`: inner.is_a?(Type)
  - line 219 `FunctionAnalysis#resolve_call`: func_type.is_a?(Type)
  - line 243 `FunctionAnalysis#resolve_call`: node.type_info.is_a?(Type)
  - ... 19 more
- src/mir/promotion_plan.rb: 24
  - line 43 `PromotionClassifier#classify`: ret_type_sym.is_a?(Type)
  - line 180 `PromotionClassifier#fn_has_escapable_return?`: ti.is_a?(Type)
  - line 181 `PromotionClassifier#fn_has_escapable_return?`: ti.is_a?(Type)
  - line 202 `PromotionClassifier#struct_has_promotable_fields?`: ft.is_a?(Type)
  - line 224 `PromotionClassifier#compute_struct_promote`: fdef.is_a?(Type)
  - ... 19 more
- src/annotator-helpers/capabilities.rb: 17
  - line 35 `Capabilities#errors_for`: type.is_a?(Type)
  - line 95 `CapabilityHelper#cap_var_sync`: var_node.full_type.is_a?(Type)
  - line 104 `CapabilityHelper#cap_var_storage`: var_node.full_type.is_a?(Type)
  - line 120 `CapabilityHelper#cap_var_layout`: var_node.full_type.is_a?(Type)
  - line 186 `CapabilityHelper#validate_capability`: var_type.is_a?(Type)
  - ... 12 more
- src/ast/ast.rb: 11
  - line 309 `AST::Locatable#full_type=`: val.is_a?(Type)
  - line 325 `AST::Locatable#coerced_type=`: val.is_a?(Type)
  - line 404 `AST::Locatable#finalize_storage!`: final_type.is_a?(Type)
  - line 407 `AST::Locatable#finalize_storage!`: final_type.is_a?(Type)
  - line 412 `AST::Locatable#finalize_storage!`: final_type.is_a?(Type)
  - ... 6 more
- src/mir/control_flow.rb: 11
  - line 512 `OwnershipDataflow#init_entry_state`: p[:type].is_a?(Type)
  - line 624 `OwnershipDataflow#transfer_stmt`: val_ti_raw.is_a?(Type)
  - line 1502 `LoopFrameAnalysis#rhs_references_any?`: ti.is_a?(Type)
  - line 1551 `LoopFrameAnalysis#promote_outer_field_assigns!`: val_ti.is_a?(Type)
  - line 1564 `LoopFrameAnalysis#promote_value_to_heap!`: ti.is_a?(Type)
  - ... 6 more
- src/mir/mir_pass.rb: 9
  - line 127 `MIRPass#transform!`: sig.is_a?(Type)
  - line 536 `MIRPass#annotate_bg_exit_promote!`: ft.is_a?(Type)
  - line 570 `MIRPass#walk_stream_yields`: ft.is_a?(Type)
  - line 670 `MIRPass#or_rescue_needs_fallback_dupe?`: ti.is_a?(Type)
  - line 682 `MIRPass#or_rescue_needs_fallback_dupe_left?`: ti.is_a?(Type)
  - ... 4 more
- src/annotator-helpers/pipe_analysis.rb: 8
  - line 738 `PipeAnalysis#analyze_pipe_to_identifier`: sig.is_a?(Type)
  - line 785 `PipeAnalysis#analyze_pipe_to_named_function`: result_type.is_a?(Type)
  - line 1124 `PipeAnalysis#emit_multi_map_warning`: sc.is_a?(Type)
  - line 1146 `PipeAnalysis#collect_sharded_names`: t.is_a?(Type)
  - line 1169 `PipeAnalysis#pre_scan_node_for_sharded`: t.is_a?(Type)
  - ... 3 more
- src/annotator-helpers/auto_inference.rb: 4
  - line 99 `AutoConstraintCollector#auto?`: t.is_a?(Type)
  - line 459 `AutoUnifier#stamp_slot!`: type.is_a?(Type)
  - line 572 `ShapeEvidenceCollector#walk_for_shape_decls`: node.type.is_a?(Type)
  - line 788 `OperatorEvidenceCollector#auto?`: t.is_a?(Type)
- src/annotator-helpers/effects.rb: 4
  - line 362 `EffectTracker#compute_needs_rt!`: fn_node.full_type.is_a?(Type)
  - line 364 `EffectTracker#compute_needs_rt!`: ret_type.is_a?(Type)
  - line 509 `EffectTracker#enforce_fallible_returns!`: ret.is_a?(Type)
  - line 587 `EffectTracker#mark_fn_value_references!`: arg_ft.is_a?(Type)
- src/annotator-helpers/reentrance.rb: 4
  - line 162 `ReentranceBridge#validate_not_logical_return!`: rt.is_a?(Type)
  - line 164 `ReentranceBridge#validate_not_logical_return!`: rt.is_a?(Type)
  - line 441 `ReentranceBridge#emit_mutual_thunk_unsupported!`: rt.is_a?(Type)
  - line 479 `ReentranceBridge#emit_mutual_thunk_unsupported!`: rt.is_a?(Type)
- src/mir/fsm_transform.rb: 3
  - line 181 `FsmTransform#collect_body_locals`: ct_obj.is_a?(Type)
  - line 186 `FsmTransform#collect_body_locals`: ct.is_a?(Type)
  - line 188 `FsmTransform#collect_body_locals`: ct.is_a?(Type)
- src/mir/fsm_transform/recursive_splitter.rb: 3
  - line 529 `FsmTransform::RecursiveSplitter#emit_for_each_fragment`: coll_type.is_a?(Type)
  - line 532 `FsmTransform::RecursiveSplitter#emit_for_each_fragment`: ct.is_a?(Type)
  - line 545 `FsmTransform::RecursiveSplitter#emit_for_each_fragment`: ct.is_a?(Type)
- src/annotator-helpers/fixable_helpers.rb: 2
  - line 300 `FixableHelper#emit_use_of_moved_error!`: pt.is_a?(Type)
  - line 1484 `FixableHelper#emit_auto_shape_resolved_finding!`: decl.type.is_a?(Type)
- src/ast/parser.rb: 2
  - line 2444 `Parser#reject_auto_in_aggregate_field!`: type.is_a?(Type)
  - line 2923 `Parser#type_annotation_source`: type.is_a?(Type)
- src/tools/atomic_migration_suggester.rb: 2
  - line 72 `AtomicMigrationSuggester#candidate_decl_info`: ti.is_a?(Type)
  - line 83 `AtomicMigrationSuggester#candidate_decl_info`: field_type.is_a?(Type)

## Struct Shape Report
- Struct declarations: 322
- Runtime-observed struct field slots: 566
- Static constructor field observations: 6741

### Struct Field Slot Breakdown
- missing field type with candidate: 4
  - `FmtVerifier::Result.path` -> String (runtime 13)
  - `Formatter::Emitter::FnSig.toks` -> T::Array[Formatter::FormatLexer::Token] (runtime 2028)
  - `Formatter::Emitter::FnSig.start` -> Integer (runtime 2028)
  - `Formatter::Emitter::FnSig.arrow_idx` -> Integer (runtime 2028)
- missing field type with no candidate: 4
  - `FmtVerifier::Result.error`
  - `FmtVerifier::Result.diff_excerpt`
  - `Formatter::Emitter::FnSig.po`
  - `Formatter::Emitter::FnSig.pc`
- untyped with runtime candidate: 317
  - `AutoConstraintCollector::Slot.kind` current `T.untyped` -> Symbol (runtime 73)
  - `AutoConstraintCollector::Slot.sources` current `T.untyped` -> T::Array[Symbol] (runtime 73)
  - `AutoUnifier::Result.resolved` current `T.untyped` -> Hash (runtime 32)
  - `AutoUnifier::Result.ambiguous` current `T.untyped` -> Hash (runtime 32)
  - `AutoUnifier::Result.unresolved` current `T.untyped` -> Hash (runtime 32)
  - `AutoUnifier::Resolution.slot` current `T.untyped` -> AutoConstraintCollector::Slot (runtime 24)
  - `AutoUnifier::Resolution.type` current `T.untyped` -> T.any(Symbol, Type) (runtime 24)
  - `AutoUnifier::Resolution.sources` current `T.untyped` -> T::Array[T.any(AST::Identifier, AST::Literal, Symbol)] (runtime 24)
  - ... 309 more
- untyped with static candidate: 4
  - `AST::BinaryOp.op` current `T.untyped` -> T.any(String, Symbol) (static)
  - `AST::Assert.message` current `T.untyped` -> String (static)
  - `MIR::DeferStmt.body` current `T.untyped` -> T.any(MIR::Call, MIR::MethodCall, MIR::ScopeBlock) (static)
  - `MIR::RawZig.code` current `T.untyped` -> String (static)
- untyped with no candidate: 332
  - `AutoConstraintCollector::Slot.fn_name` current `T.untyped`
  - `AutoConstraintCollector::Slot.index` current `T.untyped`
  - `AutoConstraintCollector::Slot.decl_node` current `T.untyped`
  - `AutoConstraintCollector::Slot.shape` current `T.untyped`
  - `AutoConstraintCollector::Slot.auto_token` current `T.untyped`
  - `CapabilityHelper::CaptureAnalysis.strategies` current `T.untyped`
  - `CapabilityHelper::CaptureAnalysis.heap_promote_names` current `T.untyped`
  - `CapabilityHelper::CaptureAnalysis.move_mark_names` current `T.untyped`
  - ... 324 more
- weak collection or union type: 49
  - `Capabilities::Conflict.set_a` current T::Array[`T.untyped`] -> T.any(Array, T::Array[`T.untyped`]) (runtime 2979)
  - `Capabilities::Conflict.set_b` current T::Array[`T.untyped`] -> T.any(Array, T::Array[`T.untyped`]) (runtime 2979)
  - `AST::Program.statements` current T::Array[`T.untyped`]
  - `AST::FunctionDef.params` current T::Array[`T.untyped`]
  - `AST::FunctionDef.captures` current T.nilable(T::Array[`T.untyped`])
  - `AST::FunctionDef.body` current T::Array[`T.untyped`]
  - `AST::StructDef.type_params` current T::Array[`T.untyped`]
  - `AST::ListLit.items` current T::Array[`T.untyped`] -> T.any(Array, T::Array[`T.untyped`]) (runtime 5115)
  - ... 41 more
- typed but nilable: 21
  - `AST::Cast.token` current T.nilable(Token)
  - `AST::Require.token` current T.nilable(Token)
  - `AST::IndexOp.token` current T.nilable(Token) -> Lexer::Token (runtime 60)
  - `AST::OrderByOp.token` current T.nilable(Token) -> Lexer::Token (runtime 31)
  - `AST::LimitOp.token` current T.nilable(Token) -> Lexer::Token (runtime 244)
  - `AST::UnnestOp.token` current T.nilable(Token) -> Lexer::Token (runtime 147)
  - `AST::DistinctOp.token` current T.nilable(Token) -> Lexer::Token (runtime 190)
  - `AST::SkipOp.token` current T.nilable(Token) -> Lexer::Token (runtime 95)
  - ... 13 more
- strongly typed: 321
  - `Capabilities::Conflict.message` current String -> String (static)
  - `FixableHelper::AnchorToken.line` current Integer -> Integer (static)
  - `FixableHelper::AnchorToken.column` current Integer -> Integer (static)
  - `AST::Program.token` current Lexer::Token -> Lexer::Token (static)
  - `AST::RequireNode.token` current Token
  - `AST::RequireNode.kind` current Symbol -> Symbol (static)
  - `AST::FunctionDef.token` current Token
  - `AST::FunctionDef.visibility` current Symbol -> Symbol (static)
  - ... 313 more

### Struct Field Type Candidates
- `OwnershipDataflow::OwnerEntry.allocator`; Symbol; runtime; 77640 call(s)
- `OwnershipDataflow::OwnerEntry.needs_cleanup`; T::Boolean; runtime; 77640 call(s)
- `OwnershipDataflow::OwnerEntry.state`; Symbol; runtime; 77640 call(s)
- `AST::FuncCall.args`; T.any(Array, T::Array[`T.untyped`]); runtime; 32152 call(s)
- `AST::FuncCall.name`; String; runtime; 32152 call(s)
- `OwnershipGraph::Node.kind`; Symbol; runtime; 29669 call(s)
- `OwnershipGraph::Node.line`; Integer; runtime; 29669 call(s)
- `OwnershipGraph::Node.path`; String; runtime; 29669 call(s)
- `OwnershipGraph::Node.scope_depth`; Integer; runtime; 29669 call(s)
- `OwnershipGraph::Node.state`; Symbol; runtime; 29669 call(s)
- `AST::MethodCall.name`; String; runtime; 24882 call(s)
- `BinaryOpResult.type`; Type; runtime; 23831 call(s)
- `OwnershipDataflow::DataflowStep.consumed`; Set; runtime; 21238 call(s)
- `OwnershipDataflow::DataflowStep.state`; Hash; runtime; 21238 call(s)
- `AST::StructLit.fields`; T.any(Hash, T::Hash[`T.untyped`, `T.untyped`]); runtime; 13077 call(s)
- `FsmTransform::Segments::Segment.stmts`; T.any(Array, T::Array[`T.untyped`]); runtime; 7484 call(s)
- `MIR::Call.args`; T.any(Array, T::Array[`T.untyped`]); runtime; 7168 call(s)
- `MIR::Call.callee`; String; runtime; 7168 call(s)
- `FsmOps::CallExpr.args`; T.any(Array, T::Array[`T.untyped`]); runtime; 5969 call(s)
- `AST::CopyNode.token`; Lexer::Token; runtime; 5301 call(s)
- `AST::ListLit.items`; T.any(Array, T::Array[`T.untyped`]); runtime; 5115 call(s)
- `FsmOps::AssignField.value`; T.any(FsmOps::AllocExpr, FsmOps::CallExpr); runtime; 4975 call(s)
- `FsmOps::StateFieldDecl.init_zig`; String; runtime; 4972 call(s)
- `FsmOps::StateFieldDecl.name`; String; runtime; 4972 call(s)
- `FsmOps::StateFieldDecl.zig_type`; String; runtime; 4972 call(s)
- `MIR::Param.name`; String; runtime; 4804 call(s)
- `AST::WithBlock.capabilities`; T.any(Array, T::Array[T::Hash[`T.untyped`, `T.untyped`]]); runtime; 3911 call(s)
- `MIR::MethodCall.args`; T.any(Array, T::Array[`T.untyped`]); runtime; 3845 call(s)
- `MIR::FnDef.params`; T.any(Array, T::Array[MIR::Param], T::Array[`T.untyped`]); runtime; 3456 call(s)
- `MIR::FsmStateArm.index`; Integer; runtime; 3324 call(s)
- `BinaryOpResult.storage`; Symbol; runtime; 3280 call(s)
- `AST::MatchStatement.cases`; T.any(Array, T::Array[T::Hash[`T.untyped`, `T.untyped`]]); runtime; 3142 call(s)
- `FsmOps::StmtCall.args`; T.any(Array, T::Array[`T.untyped`]); runtime; 2984 call(s)
- `Capabilities::Conflict.set_a`; T.any(Array, T::Array[`T.untyped`]); runtime; 2979 call(s)
- `Capabilities::Conflict.set_b`; T.any(Array, T::Array[`T.untyped`]); runtime; 2979 call(s)
- `AST::RangeLit.start`; T.any(AST::BinaryOp, AST::Identifier, AST::Literal); runtime; 2939 call(s)
- `MIR::StructInit.fields`; T.any(Array, T::Array[`T.untyped`], T::Array[T::Hash[`T.untyped`, `T.untyped`]]); runtime; 2879 call(s)
- `MIR::FieldDef.zig_type`; String; runtime; 2864 call(s)
- `CapabilityHelper::CaptureAnalysis.capture_symbols`; Hash; runtime; 2758 call(s)
- `CapabilityHelper::CaptureAnalysis.captures`; Hash; runtime; 2758 call(s)
- `CapabilityHelper::CaptureAnalysis.close_patterns`; Hash; runtime; 2758 call(s)
- `CapabilityHelper::CaptureAnalysis.has_affine_locked`; T::Boolean; runtime; 2758 call(s)
- `CapabilityHelper::CaptureAnalysis.has_local`; T::Boolean; runtime; 2758 call(s)
- `CapabilityHelper::CaptureAnalysis.has_non_escaping_capture`; T::Boolean; runtime; 2758 call(s)
- `CapabilityHelper::CaptureAnalysis.has_outer_ref`; T::Boolean; runtime; 2758 call(s)
- `CapabilityHelper::CaptureAnalysis.has_rc`; T::Boolean; runtime; 2758 call(s)
- `CapabilityHelper::CaptureAnalysis.has_sharded`; T::Boolean; runtime; 2758 call(s)
- `CapabilityHelper::CaptureAnalysis.has_shared`; T::Boolean; runtime; 2758 call(s)
- `CapabilityHelper::CaptureAnalysis.pointer_captures`; Set; runtime; 2758 call(s)
- `CapabilityHelper::CaptureAnalysis.resource_captures`; Set; runtime; 2758 call(s)

## Collection Type Report
- Array signature slots: 658 total, 111 strong, 547 weak, 167 nilable
- Hash signature slots: 361 total, 79 strong, 282 weak, 109 nilable

### Hash Record Struct Candidates (Shapes + Pressure)
- literal shape: a statically observed hash literal instantiation site in this candidate cluster
- similar keyset: a distinct hash key set grouped into the same likely record, e.g. `{name, id}` with `{name, id, type}`
- BodyRecord: 8 literal shape(s), 3 similar keyset(s), total pressure 119
  - common keys: body, kind, value
  - optional keys: binding, destructure, extra_values
  - read keys: binding(24), value(24), body(17), kind(9), extra_values(8), destructure(2)
  - accounts for: return 0, param 39, ivar 0, collection 80
  - related pressure records: local hash record c at src/mir/promotion_plan.rb (26); hash record param clause at src/mir/mir_lowering.rb:3426 (22); local hash record a at src/mir/mir_checker.rb (20); local hash record c at src/mir/control_flow.rb (17); local hash record c at src/mir/mir_pass.rb (17)
  - src/annotator.rb:1452 c[:binding]; receiver c
  - src/annotator.rb:1453 c[:value]; receiver c
  - src/annotator.rb:1454 c[:value]; receiver c
  - src/annotator.rb:1455 c[:value]; receiver c
  - suggested struct:
    class BodyRecord < T::Struct
      prop :binding, T.nilable(String)
      const :body, T.nilable(T::Array[`T.untyped`])
      prop :destructure, T.nilable(AST::StructPattern)
      prop :extra_values, `T.untyped`
      const :kind, Symbol
      const :value, AST::StructPattern
    end
- NameRecord: 2 literal shape(s), 1 similar keyset(s), total pressure 53
  - common keys: name, name_token, value
  - read keys: name(21), value(8), name_token(2)
  - accounts for: return 0, param 23, ivar 0, collection 30
  - related pressure records: local hash record f at src/mir/mir_lowering.rb (30); local hash record f at src/mir/mir_emitter.rb (25); local hash record param at src/annotator-helpers/with_match_check.rb (21); hash record return [] at src/mir/mir_lowering.rb:7292 (20); hash record return [] at src/annotator-helpers/fixable_helpers.rb:1627 (19)
  - src/annotator.rb:1368 f[:value]; receiver f
  - src/annotator.rb:1371 f[:name]; receiver f
  - src/annotator.rb:1372 f[:name_token]; receiver f
  - src/annotator.rb:1376 f[:name]; receiver f
  - suggested struct:
    class NameRecord < T::Struct
      const :name, T.nilable(String)
      const :name_token, T.nilable(Lexer::Token)
      const :value, Symbol
    end
- BodyRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 46
  - common keys: body, can_smash, parallel, pinned, stack_size
  - read keys: body(18), parallel(3), capture_analysis(2), pinned(2), can_smash(1), cond(1), stack_size(1)
  - accounts for: return 0, param 20, ivar 0, collection 26
  - related pressure records: local hash record a at src/mir/mir_checker.rb (20); local hash record c at src/mir/control_flow.rb (17); local hash record c at src/mir/mir_pass.rb (17); local hash record c at src/ast/ast.rb (14); local hash record c at src/backends/pipeline_rewriter.rb (14)
  - src/annotator.rb:5091 branch[:body]; receiver branch
  - src/annotator.rb:5093 branch[:body]; receiver branch
  - src/annotator.rb:5093 branch[:parallel]; receiver branch
  - src/annotator.rb:5096 branch[:parallel]; receiver branch
  - suggested struct:
    class BodyRecord < T::Struct
      const :body, T::Array[`T.untyped`]
      const :can_smash, T.nilable(T::Boolean)
      const :parallel, T.nilable(T::Boolean)
      const :pinned, T.nilable(T::Boolean)
      const :stack_size, `T.untyped`
    end
- ActionRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 41
  - common keys: action, retries, selectors, token
  - read keys: action(4), retries(4), bubble_types(3), matched_types(3), body(2), message(2), selectors(2), value(1)
  - accounts for: return 0, param 20, ivar 0, collection 21
  - related pressure records: hash record return [] at src/annotator-helpers/lock_helper.rb:109 (2); hash record param clause at src/annotator.rb:5035 (1); hash record return lock_error_clause at src/annotator-helpers/lock_helper.rb:384 (1); hash record return must at src/ast/parser.rb:3499 (1); local hash record clause at src/annotator-helpers/with_match_check.rb (1)
  - src/annotator-helpers/with_match_check.rb:414 clause[:selectors]; receiver clause
  - src/annotator.rb:976 h[:selectors]; receiver h
  - src/mir/fsm_lowering.rb:300 with_node.lock_error_clause[:retries]; receiver with_node.lock_error_clause
  - src/mir/mir_lowering.rb:2920 clause[:action]; receiver clause
  - suggested struct:
    class SelectorsRecord < T::Struct
      const :form, Symbol
      const :name, Symbol
      const :token, NilClass
    end

    class ActionRecord < T::Struct
      const :action, Symbol
      const :retries, Integer
      const :selectors, T::Array[SelectorsRecord]
      const :token, NilClass
    end
- BodyStmtsRecord: 2 literal shape(s), 1 similar keyset(s), total pressure 30
  - common keys: body_stmts, descriptor, fn_name, index, prologue_stmts, rt_suppress, tail
  - read keys: tail(8), body_stmts(4), index(4), prologue_stmts(4), fn_name(3), descriptor(2), rt_suppress(2), extra_prologue_zig(1)
  - accounts for: return 0, param 6, ivar 0, collection 24
  - related pressure records: local hash record spec at src/mir/fsm_transform/emit.rb (22); hash record param spec at src/mir/fsm_transform/emit.rb:697 (10); hash record param spec at src/mir/fsm_transform/emit.rb:209 (9); local hash record s at src/mir/fsm_transform/emit.rb (1)
  - src/mir/fsm_transform/emit.rb:115 s[:descriptor]; receiver s
  - src/mir/fsm_transform/emit.rb:118 s[:tail]; receiver s
  - src/mir/fsm_transform/emit.rb:118 s[:tail]; receiver s
  - src/mir/fsm_transform/emit.rb:119 s[:tail]; receiver s
  - suggested struct:
    class BodyStmtsRecord < T::Struct
      const :body_stmts, T::Array[`T.untyped`]
      const :descriptor, NilClass
      const :fn_name, T.nilable(String)
      const :index, `T.untyped`
      const :prologue_stmts, NilClass
      const :rt_suppress, String
      const :tail, `T.untyped`
    end
- TypeRecord: 14 literal shape(s), 6 similar keyset(s), total pressure 28
  - common keys: type
  - optional keys: default, mutable, name, required, sync, takes
  - read keys: type(10), default(4), name(4), mutable(3), takes(2)
  - accounts for: return 0, param 10, ivar 0, collection 18
  - related pressure records: local hash record param at src/annotator-helpers/function_analysis.rb (76); hash record return [] at src/annotator-helpers/function_analysis.rb:341 (41); local hash record p at src/mir/mir_lowering.rb (37); local hash record param at src/mir/mir_lowering.rb (37); hash record param param at src/annotator-helpers/function_analysis.rb:547 (32)
  - src/annotator-helpers/function_analysis.rb:685 p[:name]; receiver p
  - src/annotator-helpers/with_match_check.rb:55 p[:name]; receiver p
  - src/annotator.rb:601 p[:name]; receiver p
  - src/annotator.rb:602 p[:type]; receiver p
  - suggested struct:
    class TypeRecord < T::Struct
      prop :default, NilClass
      prop :mutable, T.nilable(T::Boolean)
      prop :name, T.nilable(String)
      prop :required, T.nilable(T::Boolean)
      prop :sync, T.nilable(T::Boolean)
      prop :takes, T.nilable(T::Boolean)
      const :type, Symbol
    end
- AddrExprRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 28
  - common keys: addr_expr, alias_name, guard_var, held_var, i, lock_expr, method
  - read keys: guard_var(9), held_var(5), alias_name(4), lock_expr(4), method(4), i(3), addr_expr(2)
  - accounts for: return 0, param 0, ivar 0, collection 28
  - related pressure records: local hash record e at src/mir/mir_lowering.rb (8)
  - src/mir/mir_lowering.rb:3503 e[:guard_var]; receiver e
  - src/mir/mir_lowering.rb:3503 e[:lock_expr]; receiver e
  - src/mir/mir_lowering.rb:3503 e[:method]; receiver e
  - src/mir/mir_lowering.rb:3506 e[:addr_expr]; receiver e
  - suggested struct:
    class AddrExprRecord < T::Struct
      const :addr_expr, String
      const :alias_name, String
      const :guard_var, String
      const :held_var, String
      const :i, `T.untyped`
      const :lock_expr, String
      const :method, `T.untyped`
    end
- BodyRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 27
  - common keys: body, name, params, return_type, token, visibility
  - read keys: name(5), params(4), return_type(3), token(3), body(2), visibility(1)
  - accounts for: return 0, param 9, ivar 0, collection 18
  - related pressure records: local hash record sel at src/annotator.rb (32); local hash record param at src/annotator-helpers/with_match_check.rb (21); hash record return [] at src/mir/mir_lowering.rb:7292 (20); local hash record a at src/mir/mir_checker.rb (20); local hash record b at src/mir/mir_pass.rb (20)
  - src/annotator-helpers/union.rb:21 req[:name]; receiver req
  - src/annotator-helpers/union.rb:22 req[:token]; receiver req
  - src/annotator-helpers/union.rb:22 req[:name]; receiver req
  - src/annotator-helpers/union.rb:24 req[:name]; receiver req
  - suggested struct:
    class BodyRecord < T::Struct
      const :body, T.nilable(T::Array[`T.untyped`])
      const :name, T.nilable(String)
      const :params, `T.untyped`
      const :return_type, T.nilable(Type)
      const :token, T.nilable(Lexer::Token)
      const :visibility, Symbol
    end
- NameRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 25
  - common keys: name, value
  - read keys: name(1), value(1)
  - accounts for: return 0, param 23, ivar 0, collection 2
  - related pressure records: local hash record f at src/mir/mir_lowering.rb (30); local hash record f at src/mir/mir_emitter.rb (25); local hash record param at src/annotator-helpers/with_match_check.rb (21); hash record return [] at src/mir/mir_lowering.rb:7292 (20); hash record return [] at src/annotator-helpers/fixable_helpers.rb:1627 (19)
  - src/mir/mir_emitter.rb:1348 f[:name]; receiver f
  - src/mir/mir_emitter.rb:1348 f[:value]; receiver f
  - suggested struct:
    class NameRecord < T::Struct
      const :name, String
      const :value, MIR::StructInit
    end
- ExprRecord: 2 literal shape(s), 1 similar keyset(s), total pressure 20
  - common keys: expr, name, name_token
  - read keys: expr(7), name(4), unwrapped_type(1)
  - accounts for: return 0, param 9, ivar 0, collection 11
  - related pressure records: local hash record param at src/annotator-helpers/with_match_check.rb (21); hash record return [] at src/mir/mir_lowering.rb:7292 (20); hash record return [] at src/annotator-helpers/fixable_helpers.rb:1627 (19); hash record return [] at src/mir/thunk_transform/emit.rb:104 (19); local hash record param at src/mir/concurrency_checks.rb (19)
  - src/annotator.rb:1303 b[:expr]; receiver b
  - src/annotator.rb:1304 b[:expr]; receiver b
  - src/annotator.rb:1306 b[:expr]; receiver b
  - src/annotator.rb:1306 b[:expr]; receiver b
  - suggested struct:
    class ExprRecord < T::Struct
      const :expr, MIR::FieldGet
      const :name, T.nilable(String)
      const :name_token, T.nilable(Lexer::Token)
    end
- AddrsRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 18
  - common keys: addrs, allocs, bytes, free_bytes, frees, live
  - read keys: addrs(2), allocs(2), bytes(2), free_bytes(1), frees(1)
  - accounts for: return 0, param 10, ivar 0, collection 8
  - related pressure records: local hash record s at src/tools/doctor.rb (61); local hash record v at src/tools/doctor.rb (8); local hash record vals at src/tools/doctor.rb (4); local hash record s at src/tools/pprof_converter.rb (3)
  - src/tools/pprof_converter.rb:145 s[:addrs]; receiver s
  - src/tools/pprof_converter.rb:149 s[:allocs]; receiver s
  - src/tools/pprof_converter.rb:150 s[:bytes]; receiver s
  - src/tools/pprof_converter.rb:151 s[:allocs]; receiver s
  - suggested struct:
    class AddrsRecord < T::Struct
      const :addrs, `T.untyped`
      const :allocs, Integer
      const :bytes, Integer
      const :free_bytes, Integer
      const :frees, Integer
      const :live, Integer
    end
- BindingRecord: 2 literal shape(s), 1 similar keyset(s), total pressure 15
  - common keys: binding, expr
  - read keys: expr(6), binding(4)
  - accounts for: return 0, param 6, ivar 0, collection 9
  - related pressure records: local hash record step at src/mir/mir_lowering.rb (11); local hash record step at src/annotator-helpers/capabilities.rb (8); hash record return pop at src/mir/fsm_lowering.rb:108 (7); hash record return pop at src/mir/mir_lowering.rb:3870 (6); local hash record step at src/annotator.rb (5)
  - src/annotator.rb:5307 step[:expr]; receiver step
  - src/annotator.rb:5308 step[:expr]; receiver step
  - src/annotator.rb:5308 step[:expr]; receiver step
  - src/annotator.rb:5310 step[:binding]; receiver step
  - suggested struct:
    class BindingRecord < T::Struct
      const :binding, T.nilable(String)
      const :expr, AST::Locatable
    end
- AllocsRecord: 8 literal shape(s), 3 similar keyset(s), total pressure 14
  - common keys: allocs, bytes
  - optional keys: addr, free_bytes, frees, inuse_allocs, inuse_bytes, live, trace
  - read keys: bytes(6), allocs(5)
  - accounts for: return 0, param 3, ivar 0, collection 11
  - related pressure records: local hash record s at src/tools/doctor.rb (61); local hash record v at src/tools/doctor.rb (8); local hash record vals at src/tools/doctor.rb (4)
  - src/tools/doctor.rb:1333 self_total[:bytes]; receiver self_total
  - src/tools/doctor.rb:1341 self_total[:bytes]; receiver self_total
  - src/tools/doctor.rb:1341 self_total[:allocs]; receiver self_total
  - src/tools/doctor.rb:1466 b[:bytes]; receiver b
  - suggested struct:
    class AllocsRecord < T::Struct
      prop :addr, `T.untyped`
      const :allocs, Integer
      const :bytes, Integer
      prop :free_bytes, T.nilable(Integer)
      prop :frees, T.nilable(Integer)
      prop :inuse_allocs, `T.untyped`
      prop :inuse_bytes, `T.untyped`
      prop :live, T.nilable(Integer)
      prop :trace, `T.untyped`
    end
- ArenaRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 14
  - common keys: arena, can_smash, can_smash_token, parallel, pinned, stack_size, stack_size_token
  - read keys: arena(1), can_smash(1), can_smash_token(1), parallel(1), pinned(1), stack_size(1), stack_size_token(1)
  - accounts for: return 0, param 7, ivar 0, collection 7
  - related pressure records: local hash record T.must(prefix) at src/ast/parser.rb (7); hash record return [] at src/ast/parser.rb:3771 (6); hash record return [] at src/ast/parser.rb:3697 (5); hash record return options at src/annotator-helpers/pipe_analysis.rb:1605 (1); hash record return options at src/annotator-helpers/pipe_analysis.rb:1606 (1)
  - src/ast/parser.rb:3815 T.must(prefix)[:stack_size]; receiver T.must(prefix)
  - src/ast/parser.rb:3815 T.must(prefix)[:pinned]; receiver T.must(prefix)
  - src/ast/parser.rb:3815 T.must(prefix)[:parallel]; receiver T.must(prefix)
  - src/ast/parser.rb:3815 T.must(prefix)[:arena]; receiver T.must(prefix)
  - suggested struct:
    class ArenaRecord < T::Struct
      const :arena, T::Boolean
      const :can_smash, T::Boolean
      const :can_smash_token, T.nilable(Lexer::Token)
      const :parallel, T::Boolean
      const :pinned, T::Boolean
      const :stack_size, `T.untyped`
      const :stack_size_token, T.nilable(Lexer::Token)
    end
- BodyRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 14
  - common keys: body, filters, items
  - read keys: body(1)
  - accounts for: return 0, param 13, ivar 0, collection 1
  - related pressure records: local hash record a at src/mir/mir_checker.rb (20); local hash record c at src/mir/control_flow.rb (17); local hash record c at src/mir/mir_pass.rb (17); local hash record c at src/ast/ast.rb (14); local hash record c at src/backends/pipeline_rewriter.rb (14)
  - src/annotator.rb:851 c[:body]; receiver c
  - suggested struct:
    class BodyRecord < T::Struct
      const :body, T.nilable(T::Array[`T.untyped`])
      const :filters, T::Array[T.nilable(T::Hash[`T.untyped`, `T.untyped`])]
      const :items, T::Array[T::Hash[`T.untyped`, `T.untyped`]]
    end
- ContendedRecord: 6 literal shape(s), 5 similar keyset(s), total pressure 12
  - common keys: contended, read_contended, read_total_wait_ns, total_wait_ns
  - optional keys: acquires, addr, caller_trace, max_hold_ns, max_wait_ns, read_acquires, read_max_wait_ns, total_hold_ns, trace, traces
  - read keys: contended(2), read_contended(2), read_total_wait_ns(2), total_wait_ns(2)
  - accounts for: return 0, param 4, ivar 0, collection 8
  - related pressure records: local hash record l at src/tools/pprof_converter.rb (26); local hash record l at src/tools/doctor.rb (20); local hash record r at src/tools/doctor.rb (20)
  - src/tools/doctor.rb:1537 b[:contended]; receiver b
  - src/tools/doctor.rb:1537 b[:read_contended]; receiver b
  - src/tools/doctor.rb:1538 a[:contended]; receiver a
  - src/tools/doctor.rb:1538 a[:read_contended]; receiver a
  - suggested struct:
    class ContendedRecord < T::Struct
      prop :acquires, T.nilable(Integer)
      prop :addr, T.nilable(String)
      prop :caller_trace, T.nilable(T::Array[`T.untyped`])
      const :contended, Integer
      prop :max_hold_ns, T.nilable(Integer)
      prop :max_wait_ns, T.nilable(Integer)
      prop :read_acquires, T.nilable(Integer)
      const :read_contended, Integer
      prop :read_max_wait_ns, T.nilable(Integer)
      const :read_total_wait_ns, Integer
      prop :total_hold_ns, T.nilable(Integer)
      const :total_wait_ns, Integer
      prop :trace, T.nilable(T::Array[`T.untyped`])
      prop :traces, `T.untyped`
    end
- CondZigRecord: 2 literal shape(s), 1 similar keyset(s), total pressure 10
  - common keys: cond_zig, value_zig
  - read keys: cond_ast(2), value_ast(2), cond_zig(1), value_zig(1)
  - accounts for: return 0, param 4, ivar 0, collection 6
  - related pressure records: local hash record bc at src/mir/mir_emitter.rb (4)
  - src/mir/mir_emitter.rb:783 bc.fetch(:cond_zig); receiver bc
  - src/mir/mir_emitter.rb:784 bc.fetch(:value_zig); receiver bc
  - src/mir/thunk_transform/emit.rb:95 bc[:cond_ast]; receiver bc
  - src/mir/thunk_transform/emit.rb:96 bc[:value_ast]; receiver bc
  - suggested struct:
    class CondZigRecord < T::Struct
      const :cond_zig, `T.untyped`
      const :value_zig, `T.untyped`
    end
- CommitsRecord: 6 literal shape(s), 4 similar keyset(s), total pressure 8
  - common keys: commits, reads, retries
  - optional keys: addr, caller_trace, multi_commits, struct_size, trace, traces, update_failures
  - read keys: retries(4), commits(2)
  - accounts for: return 0, param 2, ivar 0, collection 6
  - related pressure records: local hash record c at src/tools/pprof_converter.rb (34); hash record return first at src/tools/doctor.rb:933 (1)
  - src/tools/doctor.rb:1605 a[:commits]; receiver a
  - src/tools/doctor.rb:1605 b[:commits]; receiver b
  - src/tools/doctor.rb:1606 a[:retries]; receiver a
  - src/tools/doctor.rb:1606 b[:retries]; receiver b
  - suggested struct:
    class CommitsRecord < T::Struct
      prop :addr, T.nilable(String)
      prop :caller_trace, T.nilable(T::Array[`T.untyped`])
      const :commits, Integer
      prop :multi_commits, T.nilable(Integer)
      const :reads, Integer
      const :retries, Integer
      prop :struct_size, T.nilable(Integer)
      prop :trace, T.nilable(T::Array[`T.untyped`])
      prop :traces, `T.untyped`
      prop :update_failures, T.nilable(Integer)
    end
- PinnedRecord: 4 literal shape(s), 3 similar keyset(s), total pressure 8
  - common keys: pinned
  - optional keys: arena, can_smash, can_smash_token, parallel, stack_size, stack_size_token
  - read keys: can_smash(1), parallel(1), pinned(1), stack_size(1)
  - accounts for: return 0, param 4, ivar 0, collection 4
  - related pressure records: local hash record T.must(prefix) at src/ast/parser.rb (7); hash record return [] at src/ast/parser.rb:3771 (6); hash record return [] at src/ast/parser.rb:3697 (5); hash record return options at src/annotator-helpers/pipe_analysis.rb:1605 (1); hash record return options at src/annotator-helpers/pipe_analysis.rb:1606 (1)
  - src/ast/parser.rb:3741 T.must(prefix)[:pinned]; receiver T.must(prefix)
  - src/ast/parser.rb:3741 T.must(prefix)[:parallel]; receiver T.must(prefix)
  - src/ast/parser.rb:3741 T.must(prefix)[:stack_size]; receiver T.must(prefix)
  - src/ast/parser.rb:3741 T.must(prefix)[:can_smash]; receiver T.must(prefix)
  - suggested struct:
    class PinnedRecord < T::Struct
      prop :arena, T.nilable(T::Boolean)
      prop :can_smash, T.nilable(T::Boolean)
      prop :can_smash_token, NilClass
      prop :parallel, T.nilable(T::Boolean)
      const :pinned, T::Boolean
      prop :stack_size, `T.untyped`
      prop :stack_size_token, NilClass
    end
- AllocRecord: 21 literal shape(s), 5 similar keyset(s), total pressure 7
  - common keys: alloc
  - optional keys: elem_zig_type, has_moved_guard, kind, zig_type
  - read keys: alloc(3), zig_type(1)
  - accounts for: return 0, param 3, ivar 0, collection 4
  - related pressure records: hash record return [] at src/mir/mir_pass.rb:852 (15); hash record return [] at src/mir/mir_pass.rb:866 (15); hash record return [] at src/mir/mir_pass.rb:800 (14); local hash record vp at src/mir/mir_pass.rb (11); hash record return [] at src/mir/mir_pass.rb:823 (9)
  - src/mir/mir_lowering.rb:6264 node.reassign_cleanup[:zig_type]; receiver node.reassign_cleanup
  - src/mir/mir_lowering.rb:6265 node.reassign_cleanup[:alloc]; receiver node.reassign_cleanup
  - src/mir/mir_pass.rb:312 stmt.reassign_cleanup[:alloc]; receiver stmt.reassign_cleanup
  - src/mir/mir_pass.rb:317 stmt.field_pre_cleanup[:alloc]; receiver stmt.field_pre_cleanup
  - suggested struct:
    class AllocRecord < T::Struct
      const :alloc, Symbol
      prop :elem_zig_type, T.nilable(Object)
      prop :has_moved_guard, T.nilable(T::Boolean)
      prop :kind, T.nilable(Symbol)
      prop :zig_type, T.nilable(String)
    end
- NameRecord: 3 literal shape(s), 2 similar keyset(s), total pressure 7
  - common keys: name, stack_bytes
  - optional keys: zig_name
  - read keys: line(3), usage_pct(1)
  - accounts for: return 0, param 3, ivar 0, collection 4
  - related pressure records: local hash record param at src/annotator-helpers/with_match_check.rb (21); hash record return [] at src/mir/mir_lowering.rb:7292 (20); hash record return [] at src/annotator-helpers/fixable_helpers.rb:1627 (19); hash record return [] at src/mir/thunk_transform/emit.rb:104 (19); local hash record param at src/mir/concurrency_checks.rb (19)
  - src/tools/stack_verifier.rb:120 entry[:line]; receiver entry
  - src/tools/stack_verifier.rb:128 entry[:line]; receiver entry
  - src/tools/stack_verifier.rb:136 entry[:line]; receiver entry
  - src/tools/stack_verifier.rb:139 entry[:usage_pct]; receiver entry
  - suggested struct:
    class NameRecord < T::Struct
      const :name, String
      const :stack_bytes, T.nilable(Integer)
      prop :zig_name, NilClass
    end
- BytesRecord: 2 literal shape(s), 1 similar keyset(s), total pressure 7
  - common keys: bytes, reg
  - read keys: bytes(2), reg(2)
  - accounts for: return 0, param 3, ivar 0, collection 4
  - related pressure records: hash record hash literal at src/tools/stack_verifier.rb:285 (3); hash record hash literal at src/tools/stack_verifier.rb:80 (3)
  - src/tools/stack_verifier.rb:81 pending_mov[:reg]; receiver pending_mov
  - src/tools/stack_verifier.rb:83 pending_mov[:bytes]; receiver pending_mov
  - src/tools/stack_verifier.rb:286 pending_mov[:reg]; receiver pending_mov
  - src/tools/stack_verifier.rb:287 pending_mov[:bytes]; receiver pending_mov
  - suggested struct:
    class BytesRecord < T::Struct
      const :bytes, Integer
      const :reg, `T.untyped`
    end
- LayoutRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 7
  - common keys: layout, lock_rank, ownership, sync
  - read keys: lock_rank(3), layout(1), ownership(1), sync(1)
  - accounts for: return 0, param 1, ivar 0, collection 6
  - related pressure records: hash record return [] at src/annotator.rb:2560 (7); hash record return [] at src/annotator-helpers/function_analysis.rb:1020 (5)
  - src/ast/parser.rb:3611 dims[:ownership]; receiver dims
  - src/ast/parser.rb:3611 dims[:sync]; receiver dims
  - src/ast/parser.rb:3611 dims[:layout]; receiver dims
  - src/ast/parser.rb:3611 dims[:lock_rank]; receiver dims
  - suggested struct:
    class LayoutRecord < T::Struct
      const :layout, NilClass
      const :lock_rank, NilClass
      const :ownership, NilClass
      const :sync, NilClass
    end
- DescriptionRecord: 11 literal shape(s), 1 similar keyset(s), total pressure 6
  - common keys: description, sigil
  - read keys: description(1), sigil(1)
  - accounts for: return 0, param 4, ivar 0, collection 2
  - related pressure records: local hash record c at src/annotator-helpers/fixable_helpers.rb (9)
  - src/annotator-helpers/fixable_helpers.rb:976 c[:sigil]; receiver c
  - src/annotator-helpers/fixable_helpers.rb:976 c[:description]; receiver c
  - suggested struct:
    class DescriptionRecord < T::Struct
      const :description, String
      const :sigil, String
    end
- KeyExprRecord: 2 literal shape(s), 2 similar keyset(s), total pressure 6
  - common keys: key_expr, map_var, shard_count
  - optional keys: auto_detected, body_allocates_frame, key_allocates_frame
  - read keys: body_allocates_frame(1), key_allocates_frame(1), key_expr(1), shard_count(1)
  - accounts for: return 0, param 2, ivar 0, collection 4
  - related pressure records: hash record param ctx at src/backends/pipeline_host.rb:3554 (4); hash record return shard_context at src/backends/pipeline_host.rb:3493 (4); hash record return shard_context at src/mir/control_flow.rb:1685 (3); hash record return first at src/annotator-helpers/pipe_analysis.rb:1253 (1)
  - src/backends/pipeline_host.rb:3557 ctx[:shard_count]; receiver ctx
  - src/backends/pipeline_host.rb:3577 ctx[:key_expr]; receiver ctx
  - src/backends/pipeline_host.rb:3619 ctx[:key_allocates_frame]; receiver ctx
  - src/backends/pipeline_host.rb:3624 ctx[:body_allocates_frame]; receiver ctx
  - suggested struct:
    class KeyExprRecord < T::Struct
      prop :auto_detected, T.nilable(T::Boolean)
      prop :body_allocates_frame, T.nilable(T::Boolean)
      prop :key_allocates_frame, T.nilable(T::Boolean)
      const :key_expr, MIR::Ident
      const :map_var, AST::Identifier
      const :shard_count, `T.untyped`
    end
- BodyRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 6
  - common keys: body, pattern
  - read keys: body(1), pattern(1)
  - accounts for: return 0, param 4, ivar 0, collection 2
  - related pressure records: local hash record a at src/mir/mir_checker.rb (20); local hash record c at src/mir/control_flow.rb (17); local hash record c at src/mir/mir_pass.rb (17); local hash record c at src/ast/ast.rb (14); local hash record c at src/backends/pipeline_rewriter.rb (14)
  - src/mir/mir_emitter.rb:693 arm[:body]; receiver arm
  - src/mir/mir_emitter.rb:694 arm[:pattern]; receiver arm
  - suggested struct:
    class BodyRecord < T::Struct
      const :body, `T.untyped`
      const :pattern, String
    end
- DispatchRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 5
  - common keys: dispatch, exits, form, id, max_lifetime_ns, runs, scheds, spawns, total_lifetime_ns
  - read keys: runs(3), dispatch(1), scheds(1)
  - accounts for: return 0, param 1, ivar 0, collection 4
  - related pressure records: local hash record site at src/tools/doctor.rb (10); hash record return build_bounded_concurrent_callback at src/backends/pipeline_host.rb:4034 (7); hash record return build_bounded_concurrent_callback at src/backends/pipeline_host.rb:4064 (7); hash record return build_bounded_concurrent_callback at src/backends/pipeline_host.rb:4093 (7); hash record return build_bounded_concurrent_callback at src/backends/pipeline_host.rb:4164 (7)
  - src/tools/doctor.rb:528 site[:runs]; receiver site
  - src/tools/doctor.rb:528 site[:runs]; receiver site
  - src/tools/doctor.rb:531 site[:dispatch]; receiver site
  - src/tools/doctor.rb:582 site[:scheds]; receiver site
  - suggested struct:
    class DispatchRecord < T::Struct
      const :dispatch, T.nilable(String)
      const :exits, Integer
      const :form, T.nilable(String)
      const :id, Integer
      const :max_lifetime_ns, Integer
      const :runs, Integer
      const :scheds, Object
      const :spawns, Integer
      const :total_lifetime_ns, Integer
    end
- ElemZigRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 5
  - common keys: elem_zig, initial_capture, item_used, item_var, next_method, outer_stmts, range_let, source_name, stage_stmts
  - read keys: item_var(2)
  - accounts for: return 0, param 3, ivar 0, collection 2
  - related pressure records: hash record param p at src/backends/pipeline_host.rb:2657 (33); hash record param p at src/backends/pipeline_host.rb:2906 (4); hash record param p at src/backends/pipeline_host.rb:2993 (4); hash record return build_lazy_range_prefix at src/backends/pipeline_host.rb:2554 (3); hash record return build_lazy_range_prefix at src/backends/pipeline_host.rb:3051 (3)
  - src/backends/pipeline_host.rb:2847 p[:item_var]; receiver p
  - src/backends/pipeline_host.rb:2944 p[:item_var]; receiver p
  - suggested struct:
    class ElemZigRecord < T::Struct
      const :elem_zig, String
      const :initial_capture, String
      const :item_used, T::Boolean
      const :item_var, String
      const :next_method, String
      const :outer_stmts, T::Array[MIR::Let]
      const :range_let, T.nilable(MIR::Let)
      const :source_name, String
      const :stage_stmts, `T.untyped`
    end
- FunctionsRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 5
  - common keys: functions, source_file, warnings
  - read keys: warnings(3), functions(2)
  - accounts for: return 0, param 0, ivar 0, collection 5
  - related pressure records: hash record hash literal at src/tools/stack_verifier.rb:96 (5)
  - src/tools/stack_verifier.rb:121 report[:warnings]; receiver report
  - src/tools/stack_verifier.rb:129 report[:warnings]; receiver report
  - src/tools/stack_verifier.rb:137 report[:warnings]; receiver report
  - src/tools/stack_verifier.rb:147 report[:functions]; receiver report
  - suggested struct:
    class FunctionsRecord < T::Struct
      const :functions, T::Array[`T.untyped`]
      const :source_file, T.nilable(String)
      const :warnings, T::Array[`T.untyped`]
    end
- FilenameIdxRecord: 1 literal shape(s), 1 similar keyset(s), total pressure 4
  - common keys: filename_idx, id, name_idx, start_line, system_name_idx
  - read keys: id(1)
  - accounts for: return 2, param 1, ivar 0, collection 1
  - related pressure records: hash record return build_bounded_concurrent_callback at src/backends/pipeline_host.rb:4034 (7); hash record return build_bounded_concurrent_callback at src/backends/pipeline_host.rb:4064 (7); hash record return build_bounded_concurrent_callback at src/backends/pipeline_host.rb:4093 (7); hash record return build_bounded_concurrent_callback at src/backends/pipeline_host.rb:4164 (7); hash record return build_bounded_concurrent_callback at src/backends/pipeline_host.rb:4201 (7)
  - src/tools/pprof.rb:152 f[:id]; receiver f
  - suggested struct:
    class FilenameIdxRecord < T::Struct
      const :filename_idx, Integer
      const :id, Integer
      const :name_idx, Integer
      const :start_line, Integer
      const :system_name_idx, Integer
    end

### Weak Collection Slots With Runtime Candidates
- src/annotator-helpers/auto_inference.rb:65 `AutoConstraintCollector#collect!` return return: T::Hash[T::Array[`T.untyped`], AutoConstraintCollector::Slot] -> T::Hash[T::Array[T.any(Integer, String, Symbol)], AutoConstraintCollector::Slot] (61 call(s))
- src/annotator-helpers/auto_inference.rb:135 `AutoConstraintCollector#record_constraint` return return: T.nilable(T::Array[`T.untyped`]) -> T::Array[T::Hash[Symbol, `T.untyped`]] (1207 call(s))
- src/annotator-helpers/auto_inference.rb:149 `AutoConstraintCollector#record_call_site` return return: T.nilable(T::Array[`T.untyped`]) -> T::Array[T::Hash[Symbol, `T.untyped`]] (20 call(s))
- src/annotator-helpers/auto_inference.rb:348 `AutoUnifier#initialize` param slots: T::Hash[T::Array[`T.untyped`], AutoConstraintCollector::Slot] -> T::Hash[T::Array[T.any(Integer, String, Symbol)], AutoConstraintCollector::Slot] (32 call(s))
- src/annotator-helpers/auto_inference.rb:492 `AutoUnifier#stamp_map_pairs!` param resolved_slots: T::Hash[T::Array[`T.untyped`], AutoUnifier::Resolution] -> T::Hash[T::Array[T.any(Integer, String, Symbol)], AutoUnifier::Resolution] (22 call(s))
- src/annotator-helpers/auto_inference.rb:492 `AutoUnifier#stamp_map_pairs!` return return: T::Hash[Integer, T::Hash[`T.untyped`, `T.untyped`]] -> T::Hash[Integer, T::Hash[Symbol, AutoUnifier::Resolution]] (22 call(s))
- src/annotator-helpers/auto_inference.rb:530 `ShapeEvidenceCollector#initialize` param slots: T::Hash[T::Array[`T.untyped`], AutoConstraintCollector::Slot] -> T::Hash[T::Array[T.any(Integer, String, Symbol)], AutoConstraintCollector::Slot] (29 call(s))
- src/annotator-helpers/auto_inference.rb:536 `ShapeEvidenceCollector#collect!` return return: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[T::Array[T.any(Integer, String, Symbol)], AutoConstraintCollector::Slot] (29 call(s))
- src/annotator-helpers/auto_inference.rb:555 `ShapeEvidenceCollector#build_name_map` return return: T::Hash[String, T::Hash[`T.untyped`, `T.untyped`]] -> T::Hash[String, T::Hash[Symbol, T.nilable(AutoConstraintCollector::Slot)]] (40 call(s))
- src/annotator-helpers/auto_inference.rb:589 `ShapeEvidenceCollector#walk` param name_map: T::Hash[String, T::Hash[`T.untyped`, `T.untyped`]] -> T::Hash[String, T::Hash[Symbol, T.nilable(AutoConstraintCollector::Slot)]] (776 call(s))
- src/annotator-helpers/auto_inference.rb:615 `ShapeEvidenceCollector#record_method_call` param name_map: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[String, T::Hash[Symbol, T.nilable(AutoConstraintCollector::Slot)]] (10 call(s))
- src/annotator-helpers/auto_inference.rb:642 `ShapeEvidenceCollector#record_map_pair_evidence` param slots: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[Symbol, T.nilable(AutoConstraintCollector::Slot)] (3 call(s))
- src/annotator-helpers/auto_inference.rb:651 `ShapeEvidenceCollector#record_index_assign` param name_map: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[String, T::Hash[Symbol, T.nilable(AutoConstraintCollector::Slot)]] (4 call(s))
- src/annotator-helpers/auto_inference.rb:688 `OperatorEvidenceCollector#initialize` param slots: T::Hash[T::Array[`T.untyped`], AutoConstraintCollector::Slot] -> T::Hash[T::Array[T.any(Integer, String, Symbol)], AutoConstraintCollector::Slot] (26 call(s))
- src/annotator-helpers/auto_inference.rb:695 `OperatorEvidenceCollector#collect!` return return: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[T::Array[T.any(Integer, String, Symbol)], T::Set[Symbol]] (26 call(s))
- src/annotator-helpers/auto_inference.rb:713 `OperatorEvidenceCollector#build_name_map` return return: T::Hash[String, T::Array[`T.untyped`]] -> T::Hash[String, T::Array[T.any(Integer, String, Symbol)]] (37 call(s))
- src/annotator-helpers/auto_inference.rb:751 `OperatorEvidenceCollector#walk_binops` param name_to_slot: T::Hash[String, T::Array[`T.untyped`]] -> T::Hash[String, T::Array[T.any(Integer, String, Symbol)]] (1307 call(s))
- src/annotator-helpers/auto_inference.rb:778 `OperatorEvidenceCollector#record_binop` param name_to_slot: T::Hash[String, T::Array[`T.untyped`]] -> T::Hash[String, T::Array[T.any(Integer, String, Symbol)]] (22 call(s))
- src/annotator-helpers/capabilities.rb:126 `CapabilityHelper#validate_capability` return return: T.nilable(T::Array[T::Hash[`T.untyped`, `T.untyped`]]) -> T::Array[T::Hash[Symbol, Symbol]] (2101 call(s))
- src/annotator-helpers/capabilities.rb:362 `CapabilityHelper#record_predicate_call_site!` return return: T.nilable(T::Array[T::Hash[`T.untyped`, `T.untyped`]]) -> T::Array[T::Hash[Symbol, `T.untyped`]] (17826 call(s))
- src/annotator-helpers/capabilities.rb:379 `CapabilityHelper#validate_predicate_purity!` return return: T.nilable(T::Array[`T.untyped`]) -> T::Array[T::Hash[Symbol, `T.untyped`]] (4781 call(s))
- src/annotator-helpers/capabilities.rb:1030 `CapabilityHelper#_unified_capture_walk` param nodes: T::Array[`T.untyped`] -> T::Array[T::Hash[Symbol, `T.untyped`]] (17463 call(s))
- src/annotator-helpers/effects.rb:89 `EffectTracker#effects_init!` return return: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[String, Hash] (5760 call(s))
- src/annotator-helpers/effects.rb:1051 `EffectTracker#scan_for_calls` return return: T::Array[`T.untyped`] -> T::Array[T::Set[String]] (13317 call(s))
- src/annotator-helpers/fixable_helpers.rb:101 `FixableHelper#emit_registry_mismatch!` param candidates: T::Array[`T.untyped`] -> T::Array[Symbol] (7 call(s))
- src/annotator-helpers/fixable_helpers.rb:371 `FixableHelper#emit_use_of_moved_path_error!` param path: T::Array[`T.untyped`] -> T::Array[Symbol] (3 call(s))
- src/annotator-helpers/fixable_helpers.rb:713 `FixableHelper#emit_ambiguous_return_error!` param found_returns: T::Array[`T.untyped`] -> T::Array[T::Hash[Symbol, Symbol]] (5 call(s))
- src/annotator-helpers/fixable_helpers.rb:1251 `FixableHelper#emit_with_cap_mismatch!` param candidates: T::Array[`T.untyped`] -> T::Array[T::Hash[Symbol, String]] (9 call(s))
- src/annotator-helpers/fixable_helpers.rb:1371 `FixableHelper#auto_rank_candidates` return return: T::Array[T::Array[`T.untyped`]] -> T::Array[T::Array[T.nilable(T.any(String, Symbol))]] (22 call(s))
- src/annotator-helpers/fixable_helpers.rb:1427 `FixableHelper#build_auto_op_evidence_block` param candidates: T::Array[`T.untyped`] -> T::Array[T::Array[T.nilable(T.any(String, Symbol))]] (4 call(s))
- src/annotator-helpers/fixable_helpers.rb:1502 `FixableHelper#build_auto_replace_fixes` return return: T::Array[`T.untyped`] -> T::Array[Fix] (15 call(s))
- src/annotator-helpers/fixable_helpers.rb:1524 `FixableHelper#emit_auto_ambiguity_finding!` param op_evidence: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[T::Array[T.any(Integer, String, Symbol)], T::Set[Symbol]] (4 call(s))
- src/annotator-helpers/fixable_helpers.rb:1555 `FixableHelper#emit_auto_unresolved_finding!` param op_evidence: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[T::Array[T.any(Integer, String, Symbol)], T::Set[Symbol]] (9 call(s))
- src/annotator-helpers/fixable_helpers.rb:1659 `FixableHelper#build_auto_ambiguity_message` param observed_strs: T::Array[`T.untyped`] -> T::Array[String] (4 call(s))
- src/annotator-helpers/function_analysis.rb:719 `FunctionAnalysis#declare_and_verify_params` return return: T.nilable(T::Array[T::Hash[Symbol, `T.untyped`]]) -> T::Array[T::Hash[Symbol, `T.untyped`]] (9409 call(s))
- src/annotator-helpers/function_analysis.rb:814 `FunctionAnalysis#verify_captures!` return return: T.nilable(T::Array[`T.untyped`]) -> T::Array[T::Hash[Symbol, `T.untyped`]] (9415 call(s))
- src/annotator-helpers/function_analysis.rb:854 `FunctionAnalysis#declare_captures` return return: T.nilable(T::Array[`T.untyped`]) -> T::Array[T::Hash[Symbol, `T.untyped`]] (9403 call(s))
- src/annotator-helpers/function_analysis.rb:1007 `FunctionAnalysis#find_matching_intrinsic` param definitions: T::Array[`T.untyped`] -> T::Array[T::Hash[Symbol, `T.untyped`]] (16275 call(s))
- src/annotator-helpers/function_analysis.rb:1007 `FunctionAnalysis#find_matching_intrinsic` return return: T.nilable(T::Hash[Symbol, `T.untyped`]) -> T::Hash[Symbol, `T.untyped`] (16275 call(s))
- src/annotator-helpers/function_analysis.rb:1038 `FunctionAnalysis#format_intrinsic_args` param args: T::Array[`T.untyped`] -> T::Array[Symbol] (10 call(s))
- src/annotator-helpers/lock_helper.rb:42 `LockHelper#init_lock_analysis!` return return: T::Hash[`T.untyped`, `T.untyped`] -> T::Hash[String, Array] (5760 call(s))
- src/annotator-helpers/lock_helper.rb:83 `LockHelper#record_lock_clause_site!` return return: T.nilable(T::Array[T::Hash[`T.untyped`, `T.untyped`]]) -> T::Array[T::Hash[Symbol, T::Array[Symbol]]] (1788 call(s))
- src/annotator-helpers/lock_helper.rb:101 `LockHelper#check_nested_lock_reacquire!` return return: T.nilable(T::Array[T::Hash[Symbol, `T.untyped`]]) -> T::Array[T::Hash[Symbol, `T.untyped`]] (1945 call(s))
- src/annotator-helpers/lock_helper.rb:130 `LockHelper#check_lock_rank_ordering!` return return: T.nilable(T::Array[T::Hash[`T.untyped`, `T.untyped`]]) -> T::Array[T::Hash[Symbol, `T.untyped`]] (1942 call(s))
- src/annotator-helpers/lock_helper.rb:179 `LockHelper#record_with_acquire!` return return: T.nilable(T::Array[T::Hash[Symbol, `T.untyped`]]) -> T::Array[T::Hash[Symbol, `T.untyped`]] (1359 call(s))
- src/annotator-helpers/lock_helper.rb:259 `LockHelper#build_lock_graph` return return: T::Hash[Symbol, `T.untyped`] -> T::Hash[Symbol, T.any(T::Array[LockHelper::LockEdge], T::Hash[Symbol, T::Set[Symbol]], T::Set[Symbol])] (4927 call(s))
- src/annotator-helpers/lock_helper.rb:331 `LockHelper#check_lock_cycles!` return return: T.nilable(T::Array[`T.untyped`]) -> T::Array[T::Hash[Symbol, T::Array[Symbol]]] (4774 call(s))
- src/annotator-helpers/lock_helper.rb:350 `LockHelper#check_lock_handler_reachability!` return return: T.nilable(T::Array[`T.untyped`]) -> T::Array[T::Hash[Symbol, T::Array[Symbol]]] (4769 call(s))
- src/annotator-helpers/lock_helper.rb:381 `LockHelper#verify_handler_reachability!` param site: T::Hash[Symbol, `T.untyped`] -> T::Hash[Symbol, T::Array[Symbol]] (275 call(s))
- src/annotator-helpers/lock_helper.rb:381 `LockHelper#verify_handler_reachability!` return return: T.nilable(T::Array[T::Hash[Symbol, `T.untyped`]]) -> T::Array[T::Hash[Symbol, `T.untyped`]] (275 call(s))

### Weak Collection Slots Without Candidate
- src/annotator-helpers/auto_inference.rb:46 `AutoConstraintCollector#initialize` param fn_nodes: T::Hash[String, `T.untyped`]; key observations String; value observations AST::FunctionDef
- src/annotator-helpers/auto_inference.rb:77 `AutoConstraintCollector#register_signature_slots` return return: T::Hash[`T.untyped`, `T.untyped`]; key observations String; value observations AST::FunctionDef
- src/annotator-helpers/auto_inference.rb:165 `AutoConstraintCollector#record_return` return return: T.nilable(T::Array[`T.untyped`]); element observations are heterogeneous or AST/MIR-specific: AST::BinaryOp, AST::Identifier, AST::Literal, AST::UnaryOp
- src/annotator-helpers/auto_inference.rb:188 `AutoConstraintCollector#record_local` return return: T.nilable(T::Array[`T.untyped`]); element observations are heterogeneous or AST/MIR-specific: AST::Literal, Integer, Symbol
- src/annotator-helpers/auto_inference.rb:228 `AutoConstraintCollector#record_reassignment_sources` return return: T.nilable(T::Array[`T.untyped`]); element observations are heterogeneous or AST/MIR-specific: AST::Literal
- src/annotator-helpers/auto_inference.rb:415 `AutoUnifier#collect_observed_types` return return: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: Symbol, Type
- src/annotator-helpers/auto_inference.rb:530 `ShapeEvidenceCollector#initialize` param fn_nodes: T::Hash[String, `T.untyped`]; key observations String; value observations AST::FunctionDef
- src/annotator-helpers/auto_inference.rb:547 `ShapeEvidenceCollector#collect_in_function` return return: T.nilable(T::Array[`T.untyped`]); element observations are heterogeneous or AST/MIR-specific: AST::Assignment, AST::BindExpr, AST::MethodCall, AST::ReturnNode, AST::VarDecl
- src/annotator-helpers/auto_inference.rb:615 `ShapeEvidenceCollector#record_method_call` return return: T.nilable(T::Array[`T.untyped`]); element observations are heterogeneous or AST/MIR-specific: AST::Literal
- src/annotator-helpers/auto_inference.rb:642 `ShapeEvidenceCollector#record_map_pair_evidence` param args: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::Literal
- src/annotator-helpers/auto_inference.rb:642 `ShapeEvidenceCollector#record_map_pair_evidence` return return: T.nilable(T::Array[`T.untyped`]); element observations are heterogeneous or AST/MIR-specific: AST::Literal
- src/annotator-helpers/auto_inference.rb:651 `ShapeEvidenceCollector#record_index_assign` return return: T.nilable(T::Array[`T.untyped`]); element observations are heterogeneous or AST/MIR-specific: AST::Literal
- src/annotator-helpers/auto_inference.rb:688 `OperatorEvidenceCollector#initialize` param fn_nodes: T::Hash[String, `T.untyped`]; key observations String; value observations AST::FunctionDef
- src/annotator-helpers/auto_inference.rb:703 `OperatorEvidenceCollector#collect_in_function` return return: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::Assert, AST::Assignment, AST::BindExpr, AST::MethodCall, AST::ReturnNode, AST::VarDecl
- src/annotator-helpers/auto_inference.rb:778 `OperatorEvidenceCollector#record_binop` return return: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::BinaryOp, AST::Identifier, AST::Literal
- src/annotator-helpers/capabilities.rb:34 `Capabilities#errors_for` return return: T::Array[`T.untyped`]; no element observations
- src/annotator-helpers/capabilities.rb:428 `CapabilityHelper#validate_and_visit_with_guards!` return return: T.nilable(T::Array[T::Hash[`T.untyped`, `T.untyped`]]); method not observed at runtime
- src/annotator-helpers/capabilities.rb:482 `CapabilityHelper#visit_pre_clauses!` return return: T.nilable(T::Array[T::Hash[`T.untyped`, `T.untyped`]]); method not observed at runtime
- src/annotator-helpers/capabilities.rb:640 `CapabilityHelper#acquire_capability!` param cap: T::Hash[Symbol, `T.untyped`]; key observations Symbol; value observations AST::BinaryOp, AST::FuncCall, AST::GetField, AST::Identifier
- src/annotator-helpers/capabilities.rb:640 `CapabilityHelper#acquire_capability!` param expanded: T::Array[T::Hash[Symbol, `T.untyped`]]; element observations are heterogeneous or AST/MIR-specific: Hash
- src/annotator-helpers/capabilities.rb:752 `CapabilityHelper#declare_capability_scope!` param cap: T::Hash[Symbol, `T.untyped`]; key observations Symbol; value observations AST::BinaryOp, AST::FuncCall, AST::GetField, AST::Identifier
- src/annotator-helpers/capabilities.rb:965 `CapabilityHelper#analyze_fiber_captures` param body_exprs: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, AST::ForEach, AST::ForRange
- src/annotator-helpers/capabilities.rb:982 `CapabilityHelper#validate_fiber_captures!` param body: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::BinaryOp, AST::BindExpr, AST::Identifier, AST::WithBlock
- src/annotator-helpers/capabilities.rb:1004 `CapabilityHelper#walk_bg_capture_moves` param stmts: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::ForEach, AST::ForRange, AST::FuncCall
- src/annotator-helpers/capabilities.rb:1004 `CapabilityHelper#walk_bg_capture_moves` return return: T::Array[`T.untyped`]; element observations are heterogeneous or AST/MIR-specific: AST::Assignment, AST::BinaryOp, AST::BindExpr, AST::ForEach, AST::ForRange, AST::FuncCall
- src/annotator-helpers/capabilities.rb:1030 `CapabilityHelper#_unified_capture_walk` return return: T::Array[T::Hash[Symbol, `T.untyped`]]; element observations are heterogeneous or AST/MIR-specific: AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, AST::CloneNode
- src/annotator-helpers/capabilities.rb:1318 `CapabilityAudit#capability_audit_init!` return return: T::Hash[String, T::Hash[Symbol, `T.untyped`]]; key observations String; value observations Hash
- src/annotator-helpers/capabilities.rb:1325 `CapabilityAudit#record_capability_binding` return return: T.nilable(T::Hash[`T.untyped`, `T.untyped`]); key observations Symbol; value observations FalseClass, Integer, NilClass, String
- src/annotator-helpers/capabilities.rb:1369 `CapabilityAudit#finalize_capability_audit!` return return: T::Hash[String, T::Hash[Symbol, `T.untyped`]]; key observations String; value observations Hash
- src/annotator-helpers/effects.rb:202 `EffectTracker#compute_effects!` return return: T::Hash[`T.untyped`, `T.untyped`]; key observations String; value observations AST::FunctionDef
- ... 643 more

### Collection Blocker Pressure
- method_param points array at src/annotator-helpers/effects.rb:671; element observations are heterogeneous or AST/MIR-specific: Hash: 1 slot(s), 616927 observation(s)
  - mutation sites: src/annotator-helpers/effects.rb:791 (2007), src/annotator-helpers/effects.rb:798 (1573), src/annotator-helpers/effects.rb:794 (1244)
  - src/annotator-helpers/effects.rb:671 `EffectTracker#scan_suspend_points` param points: T::Array[T::Hash[Symbol, `T.untyped`]]
- method_param _borrowed_paths array at src/ast/scope.rb:24; no element observations: 1 slot(s), 490381 observation(s)
  - src/ast/scope.rb:24 `Scope#declare` param _borrowed_paths: T::Array[`T.untyped`]
- method_return strip_capability_suffix array at src/ast/type.rb:1966; element observations are heterogeneous or AST/MIR-specific: NilClass, String, Symbol: 1 slot(s), 476259 observation(s)
  - src/ast/type.rb:1966 `Type#strip_capability_suffix` return return: T::Array[`T.untyped`]
- method_return walk_all_nodes array at src/mir/control_flow.rb:1657; candidate still contains `T.untyped`: T::Array[`T.untyped`]: 1 slot(s), 358241 observation(s)
  - src/mir/control_flow.rb:1657 `LoopFrameAnalysis#walk_all_nodes` return return: T.nilable(T::Array[`T.untyped`])
- method_param body array at src/ast/ast.rb:18; element observations are heterogeneous or AST/MIR-specific: AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, AST::BlockExpr: 1 slot(s), 347740 observation(s)
  - src/ast/ast.rb:18 `AST#walk_body` param body: T::Array[`T.untyped`]
- method_return walk_body array at src/ast/ast.rb:18; element observations are heterogeneous or AST/MIR-specific: AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, AST::BlockExpr: 1 slot(s), 347658 observation(s)
  - src/ast/ast.rb:18 `AST#walk_body` return return: T.nilable(T::Array[`T.untyped`])
- method_param out array at src/annotator.rb:6256; element observations are heterogeneous or AST/MIR-specific: AST::FuncCall: 1 slot(s), 127511 observation(s)
  - mutation sites: src/annotator.rb:7295 (353)
  - src/annotator.rb:6256 `SemanticAnnotator#collect_self_calls` param out: T::Array[`T.untyped`]
- method_return collect_self_calls array at src/annotator.rb:6256; element observations are heterogeneous or AST/MIR-specific: AST::FuncCall: 1 slot(s), 127511 observation(s)
  - mutation sites: src/annotator.rb:7295 (353)
  - src/annotator.rb:6256 `SemanticAnnotator#collect_self_calls` return return: T::Array[`T.untyped`]
- method_param out array at src/annotator.rb:6272; element observations are heterogeneous or AST/MIR-specific: AST::ReturnNode: 1 slot(s), 118326 observation(s)
  - mutation sites: src/annotator.rb:7324 (1655)
  - src/annotator.rb:6272 `SemanticAnnotator#collect_returns` param out: T::Array[`T.untyped`]
- method_return collect_returns array at src/annotator.rb:6272; element observations are heterogeneous or AST/MIR-specific: AST::ReturnNode: 1 slot(s), 118326 observation(s)
  - mutation sites: src/annotator.rb:7324 (1655)
  - src/annotator.rb:6272 `SemanticAnnotator#collect_returns` return return: T::Array[`T.untyped`]
- method_return each_bg_block array at src/ast/ast.rb:60; element observations are heterogeneous or AST/MIR-specific: AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, AST::BreakNode: 1 slot(s), 55424 observation(s)
  - src/ast/ast.rb:60 `AST#each_bg_block` return return: T.nilable(T::Array[`T.untyped`])
- method_return process_pattern array at src/ast/parser.rb:474; element observations are heterogeneous or AST/MIR-specific: AST::BgStreamBlock, AST::BinaryOp, AST::CapabilityWrap, AST::CopyNode, AST::FuncCall, AST::GetField: 1 slot(s), 53270 observation(s)
  - mutation sites: src/ast/parser.rb:39 (11509)
  - src/ast/parser.rb:474 `Parser#process_pattern` return return: T.nilable(T::Array[`T.untyped`])
- method_return parse_block_body array at src/ast/parser.rb:1694; element observations are heterogeneous or AST/MIR-specific: AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, AST::BreakNode: 1 slot(s), 43956 observation(s)
  - src/ast/parser.rb:1694 `Parser#parse_block_body` return return: T.nilable(T::Array[`T.untyped`])
- method_return _bg_visit_recursive array at src/ast/ast.rb:67; element observations are heterogeneous or AST/MIR-specific: AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, AST::CapabilityWrap, AST::CopyNode: 1 slot(s), 35441 observation(s)
  - src/ast/ast.rb:67 `AST#_bg_visit_recursive` return return: T.nilable(T::Array[`T.untyped`])
- method_param result array at src/mir/mir_pass.rb:589; element observations are heterogeneous or AST/MIR-specific: AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, AST::BreakNode: 1 slot(s), 35337 observation(s)
  - mutation sites: src/mir/mir_pass.rb:418 (17375), src/mir/mir_pass.rb:422 (172), src/mir/mir_pass.rb:1437 (141)
  - src/mir/mir_pass.rb:589 `MIRPass#insert_bg_escape_promote!` param result: T::Array[`T.untyped`]
- method_param result array at src/mir/mir_pass.rb:630; element observations are heterogeneous or AST/MIR-specific: AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, AST::BreakNode: 1 slot(s), 35337 observation(s)
  - mutation sites: src/mir/mir_pass.rb:418 (17375), src/mir/mir_pass.rb:422 (172), src/mir/mir_pass.rb:1437 (141)
  - src/mir/mir_pass.rb:630 `MIRPass#insert_or_fallback_dupe!` param result: T::Array[`T.untyped`]
- method_param result array at src/mir/mir_pass.rb:881; element observations are heterogeneous or AST/MIR-specific: AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, AST::BreakNode: 1 slot(s), 35337 observation(s)
  - mutation sites: src/mir/mir_pass.rb:418 (17375), src/mir/mir_pass.rb:422 (172), src/mir/mir_pass.rb:1437 (141)
  - src/mir/mir_pass.rb:881 `MIRPass#insert_container_promote!` param result: T::Array[`T.untyped`]
- method_param params array at src/annotator-helpers/function_signature.rb:66; element observations are heterogeneous or AST/MIR-specific: Hash: 1 slot(s), 31599 observation(s)
  - src/annotator-helpers/function_signature.rb:66 `FunctionSignature#initialize` param params: T::Array[T::Hash[Symbol, `T.untyped`]]
- method_param result array at src/mir/mir_pass.rb:399; element observations are heterogeneous or AST/MIR-specific: AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, AST::BreakNode: 1 slot(s), 30036 observation(s)
  - mutation sites: src/mir/mir_pass.rb:418 (12177), src/mir/mir_pass.rb:1437 (141), src/mir/mir_pass.rb:1433 (138)
  - src/mir/mir_pass.rb:399 `MIRPass#insert_suppress_cleanup!` param result: T::Array[`T.untyped`]
- method_param result array at src/mir/mir_pass.rb:422; element observations are heterogeneous or AST/MIR-specific: AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, AST::BreakNode: 1 slot(s), 30035 observation(s)
  - mutation sites: src/mir/mir_pass.rb:418 (12177), src/mir/mir_pass.rb:1437 (141), src/mir/mir_pass.rb:1433 (138)
  - src/mir/mir_pass.rb:422 `MIRPass#insert_bg_give_suppress!` param result: T::Array[`T.untyped`]
- method_param result array at src/mir/mir_pass.rb:446; element observations are heterogeneous or AST/MIR-specific: AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, AST::BreakNode: 1 slot(s), 30035 observation(s)
  - mutation sites: src/mir/mir_pass.rb:418 (12177), src/mir/mir_pass.rb:1437 (141), src/mir/mir_pass.rb:1433 (138)
  - src/mir/mir_pass.rb:446 `MIRPass#insert_bg_resource_suppress!` param result: T::Array[`T.untyped`]
- method_param pattern array at src/ast/parser.rb:42; element observations are heterogeneous or AST/MIR-specific: String, Symbol: 1 slot(s), 28797 observation(s)
  - src/ast/parser.rb:42 `Parser#primary` param pattern: T.nilable(T::Array[`T.untyped`])
- method_return flush_pending array at src/mir/mir_lowering.rb:98; element observations are heterogeneous or AST/MIR-specific: MIR::AllocMark, MIR::Cleanup, MIR::ErrCleanup, MIR::Let: 1 slot(s), 27785 observation(s)
  - src/mir/mir_lowering.rb:98 `MIRLowering#flush_pending` return return: T::Array[`T.untyped`]
- method_return declare_type hash at src/ast/scope.rb:122; candidate still contains `T.untyped`: T::Hash[Symbol, T::Hash[T.any(String, Symbol), `T.untyped`]]: 1 slot(s), 26991 observation(s)
  - src/ast/scope.rb:122 `Scope#declare_type` return return: T::Hash[Symbol, `T.untyped`]
- method_param stmts array at src/annotator.rb:1095; element observations are heterogeneous or AST/MIR-specific: AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, AST::BlockExpr: 1 slot(s), 25399 observation(s)
  - src/annotator.rb:1095 `SemanticAnnotator#visit_stmts` param stmts: T.nilable(T::Array[`T.untyped`])
- method_param body array at src/mir/promotion_plan.rb:378; element observations are heterogeneous or AST/MIR-specific: AST::Assert, AST::Assignment, AST::BgBlock, AST::BinaryOp, AST::BindExpr, AST::DoBlock: 1 slot(s), 24223 observation(s)
  - src/mir/promotion_plan.rb:378 `CleanupClassifier#body_calls_promoted?` param body: T::Array[`T.untyped`]
- method_return coerce! array at src/ast/ast.rb:346; element observations are heterogeneous or AST/MIR-specific: NilClass, String, Symbol, Type: 1 slot(s), 21612 observation(s)
  - src/ast/ast.rb:346 `AST::Locatable#coerce!` return return: T::Array[`T.untyped`]
- method_return fork_lightweight hash at src/mir/ownership_graph.rb:212; key observations Symbol; value observations Hash, Integer: 1 slot(s), 21147 observation(s)
  - src/mir/ownership_graph.rb:212 `OwnershipGraph#fork_lightweight` return return: T::Hash[Symbol, T::Hash[String, T::Hash[Symbol, `T.untyped`]]]
- method_return errors_for array at src/annotator-helpers/capabilities.rb:34; no element observations: 1 slot(s), 19769 observation(s)
  - src/annotator-helpers/capabilities.rb:34 `Capabilities#errors_for` return return: T::Array[`T.untyped`]
- method_return resolve_resource_close array at src/ast/type.rb:932; element observations are heterogeneous or AST/MIR-specific: FalseClass, NilClass, String, TrueClass: 1 slot(s), 19769 observation(s)
  - src/ast/type.rb:932 `Type#resolve_resource_close` return return: T::Array[`T.untyped`]

### Runtime Collection Mutation Observations
- method_param: 113675 slot(s)
- ivar: 113332 slot(s)
- method_return: 111128 slot(s)
- struct_field: 32426 slot(s)
  - src/ast/lexer.rb:42 ivar @tokens; array; T::Array[Lexer::Token]; 653919 observation(s)
  - src/tools/lint_fix_rewriter.rb:68 method_param set; set; T::Set[String]; 561096 observation(s)
  - src/tools/lint_fix_rewriter.rb:89 method_param set; set; T::Set[String]; 560815 observation(s)
  - src/tools/lint_fix_rewriter.rb:197 method_param edits; array; T::Array[Hash]; 560247 observation(s)
  - src/tools/predicate_rewriter.rb:103 method_param edits; array; T::Array[Hash]; 552178 observation(s)
  - src/tools/method_rewriter.rb:138 method_param edits; array; T::Array[Hash]; 551576 observation(s)
  - src/tools/method_rewriter.rb:138 method_param methods; set; T::Set[String]; 551428 observation(s)
  - src/tools/method_rewriter.rb:65 method_param fns; set; T::Set[String]; 511544 observation(s)
  - src/tools/method_rewriter.rb:65 method_param methods; set; T::Set[`T.untyped`]; 509654 observation(s)
  - src/tools/formatter.rb:151 ivar @out; array; T::Array[Formatter::FormatLexer::Token]; 300641 observation(s)
  - src/annotator-helpers/effects.rb:671 method_param points; array; T::Array[Hash]; 192704 observation(s)
  - src/ast/type.rb:1966 method_return strip_capability_suffix; array; T::Array[T.nilable(String)]; 122214 observation(s)
  - src/ast/scope.rb:22 ivar @locals; hash; T::Hash[String, SymbolEntry]; 87262 observation(s)
  - src/ast/scope.rb:25 ivar @owned_names; set; T::Set[String]; 87262 observation(s)
  - src/ast/symbol_entry.rb:181 ivar @capabilities; set; T::Set[Symbol]; 85743 observation(s)
  - src/ast/scope.rb:24 method_param _borrowed_paths; array; T::Array[`T.untyped`]; 85186 observation(s)
  - src/ast/lexer.rb:42 ivar @tokens; array; T::Array[Lexer::Token]; 82293 observation(s)
  - src/annotator-helpers/effects.rb:671 method_param points; array; T::Array[Hash]; 69579 observation(s)
  - src/tools/lint_fix_rewriter.rb:211 method_param n; array; T::Array[`T.untyped`]; 69174 observation(s)
  - src/ast/type.rb:1966 method_return strip_capability_suffix; array; T::Array[T.nilable(String)]; 51798 observation(s)
  - src/tools/formatter.rb:2560 ivar @generic_bracket_indices; set; T::Set[Integer]; 50976 observation(s)
  - src/tools/formatter.rb:2561 ivar @struct_lit_brace_indices; set; T::Set[Integer]; 50976 observation(s)
  - src/ast/scope.rb:22 ivar @locals; hash; T::Hash[String, SymbolEntry]; 45871 observation(s)
  - src/ast/scope.rb:25 ivar @owned_names; set; T::Set[String]; 45871 observation(s)
  - src/ast/symbol_entry.rb:181 ivar @capabilities; set; T::Set[Symbol]; 45591 observation(s)
  - src/ast/scope.rb:24 method_param _borrowed_paths; array; T::Array[`T.untyped`]; 45342 observation(s)
  - src/ast/parser.rb:3905 method_return parse_comma_seq; array; T::Array[`T.untyped`]; 40091 observation(s)
  - src/ast/lexer.rb:42 ivar @tokens; array; T::Array[Lexer::Token]; 32772 observation(s)
  - src/ast/lexer.rb:42 ivar @tokens; array; T::Array[Lexer::Token]; 32772 observation(s)
  - src/ast/lexer.rb:42 ivar @tokens; array; T::Array[Lexer::Token]; 32772 observation(s)
  - src/ast/parser.rb:474 method_return process_pattern; array; T::Array[`T.untyped`]; 30052 observation(s)
  - src/ast/lexer.rb:42 ivar @tokens; array; T::Array[Lexer::Token]; 28485 observation(s)
  - src/ast/ast.rb:18 method_param body; array; T::Array[`T.untyped`]; 27179 observation(s)
  - src/ast/ast.rb:18 method_return walk_body; array; T::Array[`T.untyped`]; 27179 observation(s)
  - src/mir/control_flow.rb:1657 method_return walk_all_nodes; array; T::Array[`T.untyped`]; 27097 observation(s)
  - src/annotator-helpers/effects.rb:671 method_param points; array; T::Array[Hash]; 27047 observation(s)
  - src/annotator-helpers/effects.rb:671 method_param points; array; T::Array[Hash]; 27047 observation(s)
  - src/ast/ast.rb:18 method_param body; array; T::Array[`T.untyped`]; 26604 observation(s)
  - src/ast/ast.rb:18 method_return walk_body; array; T::Array[`T.untyped`]; 26604 observation(s)
  - src/ast/scope.rb:22 ivar @locals; hash; T::Hash[String, SymbolEntry]; 26418 observation(s)

### Collection Index Lookup Provenance
- provenance: the inferred origin of the collection receiver being indexed with `[]`, `fetch`, or similar lookup syntax
- receiver origin: the parameter, literal, forwarded return, instance variable, or local record that produced the indexed receiver
- weak index lookup: an index lookup where the receiver is unknown, `T.untyped`, or a weak collection type
- unknown receiver type: 2207
- weak collection receiver: 811
- typed lookup: 513
- typed collection receiver: 225
- non-collection or unresolved receiver: 87

### Unknown Or Weak Index Lookups By Receiver Origin
- local hash record c at src/tools/doctor.rb: 74
  - src/tools/doctor.rb:393 c[:pushes]; receiver c; index :pushes; receiver type unknown
  - src/tools/doctor.rb:393 c[:pops]; receiver c; index :pops; receiver type unknown
  - src/tools/doctor.rb:402 c[:capacity]; receiver c; index :capacity; receiver type unknown
  - src/tools/doctor.rb:403 c[:max_depth]; receiver c; index :max_depth; receiver type unknown
  - src/tools/doctor.rb:404 c[:pushes]; receiver c; index :pushes; receiver type unknown
- local hash record c at src/annotator.rb: 63
  - src/annotator.rb:797 c[:body]; receiver c; index :body; receiver type unknown
  - src/annotator.rb:851 c[:body]; receiver c; index :body; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/annotator.rb:1452 c[:binding]; receiver c; index :binding; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/annotator.rb:1453 c[:value]; receiver c; index :value; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/annotator.rb:1454 c[:value]; receiver c; index :value; receiver type T::Hash[`T.untyped`, `T.untyped`]
- local hash record s at src/tools/doctor.rb: 57
  - src/tools/doctor.rb:164 s[:trace]; receiver s; index :trace; receiver type unknown
  - src/tools/doctor.rb:209 s[:trace]; receiver s; index :trace; receiver type unknown
  - src/tools/doctor.rb:213 s[:bytes]; receiver s; index :bytes; receiver type unknown
  - src/tools/doctor.rb:214 s[:allocs]; receiver s; index :allocs; receiver type unknown
  - src/tools/doctor.rb:225 s[:trace]; receiver s; index :trace; receiver type unknown
- local hash record c at src/mir/mir_lowering.rb: 54
  - src/mir/mir_lowering.rb:1647 c[:body]; receiver c; index :body; receiver type unknown
  - src/mir/mir_lowering.rb:1647 c[:body]; receiver c; index :body; receiver type unknown
  - src/mir/mir_lowering.rb:1675 c[:body]; receiver c; index :body; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/mir/mir_lowering.rb:2288 c[:name]; receiver c; index :name; receiver type unknown
  - src/mir/mir_lowering.rb:2612 c[:capability]; receiver c; index :capability; receiver type unknown
- local hash record param at src/annotator-helpers/function_analysis.rb: 53
  - src/annotator-helpers/function_analysis.rb:72 param[:name]; receiver param; index :name; receiver type unknown
  - src/annotator-helpers/function_analysis.rb:73 param[:type]; receiver param; index :type; receiver type unknown
  - src/annotator-helpers/function_analysis.rb:74 param[:default]; receiver param; index :default; receiver type unknown
  - src/annotator-helpers/function_analysis.rb:75 param[:default]; receiver param; index :default; receiver type unknown
  - src/annotator-helpers/function_analysis.rb:76 param[:mutable]; receiver param; index :mutable; receiver type unknown
- local hash record d at src/tools/doctor.rb: 44
  - src/tools/doctor.rb:1471 d[:delta_bytes]; receiver d; index :delta_bytes; receiver type unknown
  - src/tools/doctor.rb:1471 d[:delta_allocs]; receiver d; index :delta_allocs; receiver type unknown
  - src/tools/doctor.rb:1472 d[:delta_bytes]; receiver d; index :delta_bytes; receiver type unknown
  - src/tools/doctor.rb:1480 d[:delta_bytes]; receiver d; index :delta_bytes; receiver type unknown
  - src/tools/doctor.rb:1482 d[:func]; receiver d; index :func; receiver type unknown
- hash record param cap at src/annotator-helpers/capabilities.rb:752: 43
  - src/annotator-helpers/capabilities.rb:755 cap[:var_node]; receiver cap; index :var_node; receiver type T::Hash[Symbol, `T.untyped`]
  - src/annotator-helpers/capabilities.rb:756 cap[:old_scope]; receiver cap; index :old_scope; receiver type T::Hash[Symbol, `T.untyped`]
  - src/annotator-helpers/capabilities.rb:759 cap[:var_node]; receiver cap; index :var_node; receiver type T::Hash[Symbol, `T.untyped`]
  - src/annotator-helpers/capabilities.rb:763 cap[:capability]; receiver cap; index :capability; receiver type T::Hash[Symbol, `T.untyped`]
  - src/annotator-helpers/capabilities.rb:763 cap[:capability]; receiver cap; index :capability; receiver type T::Hash[Symbol, `T.untyped`]
- local hash record p at src/mir/mir_lowering.rb: 40
  - src/mir/mir_lowering.rb:1171 p[:mutable]; receiver p; index :mutable; receiver type unknown
  - src/mir/mir_lowering.rb:1172 p[:type]; receiver p; index :type; receiver type unknown
  - src/mir/mir_lowering.rb:1172 p[:type]; receiver p; index :type; receiver type unknown
  - src/mir/mir_lowering.rb:1172 p[:type]; receiver p; index :type; receiver type unknown
  - src/mir/mir_lowering.rb:1175 p[:type]; receiver p; index :type; receiver type unknown
- local hash record f at src/annotator.rb: 36
  - src/annotator.rb:581 f[:type]; receiver f; index :type; receiver type unknown
  - src/annotator.rb:1044 f[:form]; receiver f; index :form; receiver type unknown
  - src/annotator.rb:1046 f[:value]; receiver f; index :value; receiver type unknown
  - src/annotator.rb:1048 f[:token]; receiver f; index :token; receiver type unknown
  - src/annotator.rb:1048 f[:value]; receiver f; index :value; receiver type unknown
- local hash record p at src/annotator.rb: 33
  - src/annotator.rb:265 p[:type]; receiver p; index :type; receiver type unknown
  - src/annotator.rb:265 p[:type]; receiver p; index :type; receiver type unknown
  - src/annotator.rb:544 p[:name]; receiver p; index :name; receiver type unknown
  - src/annotator.rb:545 p[:type]; receiver p; index :type; receiver type unknown
  - src/annotator.rb:546 p[:default]; receiver p; index :default; receiver type unknown
- local hash record e at src/mir/mir_lowering.rb: 32
  - src/mir/mir_lowering.rb:1281 e[:alloc]; receiver e; index :alloc; receiver type unknown
  - src/mir/mir_lowering.rb:3503 e[:guard_var]; receiver e; index :guard_var; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/mir/mir_lowering.rb:3503 e[:lock_expr]; receiver e; index :lock_expr; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/mir/mir_lowering.rb:3503 e[:method]; receiver e; index :method; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/mir/mir_lowering.rb:3506 e[:addr_expr]; receiver e; index :addr_expr; receiver type T::Hash[`T.untyped`, `T.untyped`]
- local hash record cap at src/mir/mir_lowering.rb: 31
  - src/mir/mir_lowering.rb:2623 cap[:var_node]; receiver cap; index :var_node; receiver type unknown
  - src/mir/mir_lowering.rb:2624 cap[:alias]; receiver cap; index :alias; receiver type unknown
  - src/mir/mir_lowering.rb:2637 cap[:var_node]; receiver cap; index :var_node; receiver type unknown
  - src/mir/mir_lowering.rb:2639 cap[:alias]; receiver cap; index :alias; receiver type unknown
  - src/mir/mir_lowering.rb:2640 cap[:resolved_type]; receiver cap; index :resolved_type; receiver type unknown
- hash record return [] at src/annotator-helpers/method_analysis.rb:60: 26
  - src/annotator-helpers/method_analysis.rb:73 defn[:arity]; receiver defn; index :arity; receiver type unknown
  - src/annotator-helpers/method_analysis.rb:73 defn[:arity]; receiver defn; index :arity; receiver type unknown
  - src/annotator-helpers/method_analysis.rb:74 defn[:arity]; receiver defn; index :arity; receiver type unknown
  - src/annotator-helpers/method_analysis.rb:77 defn[:arity]; receiver defn; index :arity; receiver type unknown
  - src/annotator-helpers/method_analysis.rb:83 defn[:validate]; receiver defn; index :validate; receiver type unknown
- local variable f: 26
  - src/tools/pprof_converter.rb:115 f[0]; receiver f; index 0; receiver type unknown
  - src/tools/pprof_converter.rb:118 f[1]; receiver f; index 1; receiver type unknown
  - src/tools/pprof_converter.rb:119 f[2]; receiver f; index 2; receiver type unknown
  - src/tools/pprof_converter.rb:120 f[3]; receiver f; index 3; receiver type unknown
  - src/tools/pprof_converter.rb:121 f[4]; receiver f; index 4; receiver type unknown
- local hash record r at src/tools/doctor.rb: 24
  - src/tools/doctor.rb:506 r[:runs]; receiver r; index :runs; receiver type unknown
  - src/tools/doctor.rb:507 r[:runs]; receiver r; index :runs; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:509 r[:runs]; receiver r; index :runs; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:511 r[:idx]; receiver r; index :idx; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/tools/doctor.rb:511 r[:runs]; receiver r; index :runs; receiver type T::Hash[`T.untyped`, `T.untyped`]
- local hash record schema at src/ast/type.rb: 22
  - src/ast/type.rb:942 schema[:close_zig]; receiver schema; index :close_zig; receiver type unknown
  - src/ast/type.rb:946 schema[:kind]; receiver schema; index :kind; receiver type unknown
  - src/ast/type.rb:1427 schema[:kind]; receiver schema; index :kind; receiver type unknown
  - src/ast/type.rb:1428 schema[:kind]; receiver schema; index :kind; receiver type unknown
  - src/ast/type.rb:1429 schema[:variants]; receiver schema; index :variants; receiver type unknown
- hash record param ctx at src/mir/fsm_transform/emit.rb:902: 21
  - src/mir/fsm_transform/emit.rb:904 ctx[:pin_mode]; receiver ctx; index :pin_mode; receiver type unknown
  - src/mir/fsm_transform/emit.rb:904 ctx[:pin_mode]; receiver ctx; index :pin_mode; receiver type unknown
  - src/mir/fsm_transform/emit.rb:905 ctx[:pin_mode]; receiver ctx; index :pin_mode; receiver type unknown
  - src/mir/fsm_transform/emit.rb:905 ctx[:pin_mode]; receiver ctx; index :pin_mode; receiver type unknown
  - src/mir/fsm_transform/emit.rb:905 ctx[:parallel]; receiver ctx; index :parallel; receiver type unknown
- local hash record f at src/tools/stack_verifier.rb: 21
  - src/tools/stack_verifier.rb:99 f[:name]; receiver f; index :name; receiver type unknown
  - src/tools/stack_verifier.rb:99 f[:stack_bytes]; receiver f; index :stack_bytes; receiver type unknown
  - src/tools/stack_verifier.rb:101 f[:name]; receiver f; index :name; receiver type unknown
  - src/tools/stack_verifier.rb:117 f[:stack_bytes]; receiver f; index :stack_bytes; receiver type unknown
  - src/tools/stack_verifier.rb:123 f[:name]; receiver f; index :name; receiver type unknown
- local hash record sel at src/annotator.rb: 20
  - src/annotator.rb:913 sel[:form]; receiver sel; index :form; receiver type unknown
  - src/annotator.rb:914 sel[:name]; receiver sel; index :name; receiver type unknown
  - src/annotator.rb:916 sel[:token]; receiver sel; index :token; receiver type unknown
  - src/annotator.rb:920 sel[:token]; receiver sel; index :token; receiver type unknown
  - src/annotator.rb:931 sel[:form]; receiver sel; index :form; receiver type unknown
- hash record param ctx at src/mir/fsm_transform/emit.rb:296: 18
  - src/mir/fsm_transform/emit.rb:300 ctx[:id]; receiver ctx; index :id; receiver type unknown
  - src/mir/fsm_transform/emit.rb:301 ctx[:bg_rt]; receiver ctx; index :bg_rt; receiver type unknown
  - src/mir/fsm_transform/emit.rb:302 ctx[:captured]; receiver ctx; index :captured; receiver type unknown
  - src/mir/fsm_transform/emit.rb:303 ctx[:bg_string_promotes]; receiver ctx; index :bg_string_promotes; receiver type unknown
  - src/mir/fsm_transform/emit.rb:304 ctx[:capture_close_zig]; receiver ctx; index :capture_close_zig; receiver type unknown
- hash record param result at src/ast/parser.rb:3097: 18
  - src/ast/parser.rb:3100 result[:ownership]; receiver result; index :ownership; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/ast/parser.rb:3103 result[:ownership]; receiver result; index :ownership; receiver type T::Hash[Symbol, Symbol]
  - src/ast/parser.rb:3106 result[:ownership]; receiver result; index :ownership; receiver type T::Hash[Symbol, Symbol]
  - src/ast/parser.rb:3109 result[:ownership]; receiver result; index :ownership; receiver type T::Hash[Symbol, Symbol]
  - src/ast/parser.rb:3112 result[:sync]; receiver result; index :sync; receiver type T::Hash[Symbol, Symbol]
- hash record return find_matching_intrinsic at src/annotator.rb:2524: 18
  - src/annotator.rb:2550 matched_def[:reject_when]; receiver matched_def; index :reject_when; receiver type unknown
  - src/annotator.rb:2550 matched_def[:reject_when]; receiver matched_def; index :reject_when; receiver type unknown
  - src/annotator.rb:2551 matched_def[:reject_error]; receiver matched_def; index :reject_error; receiver type unknown
  - src/annotator.rb:2560 matched_def[:return]; receiver matched_def; index :return; receiver type unknown
  - src/annotator.rb:2573 matched_def[:zig]; receiver matched_def; index :zig; receiver type unknown
- local hash record req at src/annotator-helpers/union.rb: 18
  - src/annotator-helpers/union.rb:21 req[:name]; receiver req; index :name; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/annotator-helpers/union.rb:22 req[:token]; receiver req; index :token; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/annotator-helpers/union.rb:22 req[:name]; receiver req; index :name; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/annotator-helpers/union.rb:24 req[:name]; receiver req; index :name; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/annotator-helpers/union.rb:28 req[:name]; receiver req; index :name; receiver type T::Hash[`T.untyped`, `T.untyped`]
- local variable args: 18
  - src/annotator-helpers/auto_inference.rb:628 args[0]; receiver args; index 0; receiver type T::Array[`T.untyped`]
  - src/annotator.rb:5567 args[idx]; receiver args; index idx; receiver type T::Array[`T.untyped`]
  - src/annotator.rb:5567 args[idx]; receiver args; index idx; receiver type T::Array[`T.untyped`]
  - src/annotator.rb:5599 args[param_index]; receiver args; index param_index; receiver type T::Array[`T.untyped`]
  - src/ast/std_lib.rb:213 args[0]; receiver args; index 0; receiver type unknown
- hash record return cleanup_entry at src/mir/mir_emitter.rb:985: 17
  - src/mir/mir_emitter.rb:988 entry[:has_moved_guard]; receiver entry; index :has_moved_guard; receiver type unknown
  - src/mir/mir_emitter.rb:989 entry[:zig_type]; receiver entry; index :zig_type; receiver type unknown
  - src/mir/mir_emitter.rb:995 entry[:elem_zig_type]; receiver entry; index :elem_zig_type; receiver type unknown
  - src/mir/mir_emitter.rb:999 entry[:via_pointer]; receiver entry; index :via_pointer; receiver type unknown
  - src/mir/mir_emitter.rb:1002 entry[:kind]; receiver entry; index :kind; receiver type unknown
- hash record return options at src/annotator-helpers/pipe_analysis.rb:388: 16
  - src/annotator-helpers/pipe_analysis.rb:401 opts["size"]; receiver opts; index "size"; receiver type unknown
  - src/annotator-helpers/pipe_analysis.rb:402 opts["size"]; receiver opts; index "size"; receiver type unknown
  - src/annotator-helpers/pipe_analysis.rb:403 opts["size"]; receiver opts; index "size"; receiver type unknown
  - src/annotator-helpers/pipe_analysis.rb:405 opts["size"]; receiver opts; index "size"; receiver type unknown
  - src/annotator-helpers/pipe_analysis.rb:407 opts["size"]; receiver opts; index "size"; receiver type unknown
- local hash record c at src/tools/pprof_converter.rb: 16
  - src/tools/pprof_converter.rb:68 c[:pushes]; receiver c; index :pushes; receiver type unknown
  - src/tools/pprof_converter.rb:68 c[:pops]; receiver c; index :pops; receiver type unknown
  - src/tools/pprof_converter.rb:272 c[:reads]; receiver c; index :reads; receiver type unknown
  - src/tools/pprof_converter.rb:272 c[:commits]; receiver c; index :commits; receiver type unknown
  - src/tools/pprof_converter.rb:275 c[:addr]; receiver c; index :addr; receiver type unknown
- local hash record l at src/tools/pprof_converter.rb: 16
  - src/tools/pprof_converter.rb:211 l[:acquires]; receiver l; index :acquires; receiver type unknown
  - src/tools/pprof_converter.rb:211 l[:read_acquires]; receiver l; index :read_acquires; receiver type unknown
  - src/tools/pprof_converter.rb:217 l[:addr]; receiver l; index :addr; receiver type unknown
  - src/tools/pprof_converter.rb:217 l[:caller_trace]; receiver l; index :caller_trace; receiver type unknown
  - src/tools/pprof_converter.rb:232 l[:addr]; receiver l; index :addr; receiver type unknown
- local hash record spec at src/mir/fsm_transform/emit.rb: 16
  - src/mir/fsm_transform/emit.rb:131 spec[:prologue_stmts]; receiver spec; index :prologue_stmts; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/mir/fsm_transform/emit.rb:132 spec[:index]; receiver spec; index :index; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/mir/fsm_transform/emit.rb:134 spec[:index]; receiver spec; index :index; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/mir/fsm_transform/emit.rb:137 spec[:fn_name]; receiver spec; index :fn_name; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/mir/fsm_transform/emit.rb:138 spec[:body_stmts]; receiver spec; index :body_stmts; receiver type T::Hash[`T.untyped`, `T.untyped`]
- forwarded return let at src/mir/ownership_graph.rb:43: 15
  - src/mir/ownership_graph.rb:96 @nodes[from]; receiver @nodes; index from; receiver type unknown
  - src/mir/ownership_graph.rb:114 @nodes[path]; receiver @nodes; index path; receiver type unknown
  - src/mir/ownership_graph.rb:123 @nodes[source]; receiver @nodes; index source; receiver type unknown
  - src/mir/ownership_graph.rb:151 @nodes[path]; receiver @nodes; index path; receiver type unknown
  - src/mir/ownership_graph.rb:156 @nodes[p]; receiver @nodes; index p; receiver type unknown
- hash record return let at src/tools/doctor.rb:1387: 15
  - src/tools/doctor.rb:74 @opts[:ignore]; receiver @opts; index :ignore; receiver type unknown
  - src/tools/doctor.rb:74 @opts[:ignore]; receiver @opts; index :ignore; receiver type unknown
  - src/tools/doctor.rb:75 @opts[:focus]; receiver @opts; index :focus; receiver type unknown
  - src/tools/doctor.rb:76 @opts[:focus]; receiver @opts; index :focus; receiver type unknown
  - src/tools/doctor.rb:81 @opts[:cumulative]; receiver @opts; index :cumulative; receiver type unknown
- local hash record op at src/mir/mir_lowering.rb: 15
  - src/mir/mir_lowering.rb:6450 op[:shard_direct_zig]; receiver op; index :shard_direct_zig; receiver type unknown
  - src/mir/mir_lowering.rb:6454 op[:shard_direct_value_transforms]; receiver op; index :shard_direct_value_transforms; receiver type unknown
  - src/mir/mir_lowering.rb:6454 op[:value_transforms]; receiver op; index :value_transforms; receiver type unknown
  - src/mir/mir_lowering.rb:6455 op[:value_transforms]; receiver op; index :value_transforms; receiver type unknown
  - src/mir/mir_lowering.rb:6493 op[:sharded_zig]; receiver op; index :sharded_zig; receiver type unknown
- local hash record r at src/tools/pprof_converter.rb: 15
  - src/tools/pprof_converter.rb:82 r[:id]; receiver r; index :id; receiver type unknown
  - src/tools/pprof_converter.rb:84 r[:id]; receiver r; index :id; receiver type unknown
  - src/tools/pprof_converter.rb:87 r[:pushes]; receiver r; index :pushes; receiver type unknown
  - src/tools/pprof_converter.rb:87 r[:pops]; receiver r; index :pops; receiver type unknown
  - src/tools/pprof_converter.rb:87 r[:push_blocked]; receiver r; index :push_blocked; receiver type unknown
- local hash record var_data at src/mir/mir_lowering.rb: 15
  - src/mir/mir_lowering.rb:973 var_data[:indirect_fields]; receiver var_data; index :indirect_fields; receiver type unknown
  - src/mir/mir_lowering.rb:974 var_data[:indirect_fields]; receiver var_data; index :indirect_fields; receiver type unknown
  - src/mir/mir_lowering.rb:981 var_data[:kind]; receiver var_data; index :kind; receiver type unknown
  - src/mir/mir_lowering.rb:982 var_data[:indirect_fields]; receiver var_data; index :indirect_fields; receiver type unknown
  - src/mir/mir_lowering.rb:983 var_data[:fields]; receiver var_data; index :fields; receiver type unknown
- hash record param m at src/tools/pprof.rb:273: 14
  - src/tools/pprof.rb:274 m[:id]; receiver m; index :id; receiver type unknown
  - src/tools/pprof.rb:275 m[:memory_start]; receiver m; index :memory_start; receiver type unknown
  - src/tools/pprof.rb:275 m[:memory_start]; receiver m; index :memory_start; receiver type unknown
  - src/tools/pprof.rb:276 m[:memory_limit]; receiver m; index :memory_limit; receiver type unknown
  - src/tools/pprof.rb:276 m[:memory_limit]; receiver m; index :memory_limit; receiver type unknown
- hash record return build_lazy_range_prefix at src/backends/pipeline_host.rb:3249: 14
  - src/backends/pipeline_host.rb:3250 p[:item_var]; receiver p; index :item_var; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/backends/pipeline_host.rb:3251 p[:source_name]; receiver p; index :source_name; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/backends/pipeline_host.rb:3251 p[:next_method]; receiver p; index :next_method; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/backends/pipeline_host.rb:3267 p[:source_name]; receiver p; index :source_name; receiver type T::Hash[`T.untyped`, `T.untyped`]
  - src/backends/pipeline_host.rb:3271 p[:initial_capture]; receiver p; index :initial_capture; receiver type T::Hash[`T.untyped`, `T.untyped`]
- hash record return let at src/annotator-helpers/capabilities.rb:545: 14
  - src/annotator-helpers/capabilities.rb:316 ctx[:kind]; receiver ctx; index :kind; receiver type unknown
  - src/annotator-helpers/capabilities.rb:318 ctx[:alias]; receiver ctx; index :alias; receiver type unknown
  - src/annotator-helpers/capabilities.rb:321 ctx[:sibling_aliases]; receiver ctx; index :sibling_aliases; receiver type unknown
  - src/annotator-helpers/capabilities.rb:336 ctx[:param_names]; receiver ctx; index :param_names; receiver type unknown
  - src/annotator-helpers/capabilities.rb:341 ctx[:fn_name]; receiver ctx; index :fn_name; receiver type unknown
- local hash record param at src/mir/mir_lowering.rb: 14
  - src/mir/mir_lowering.rb:1196 param[:name]; receiver param; index :name; receiver type unknown
  - src/mir/mir_lowering.rb:1196 param[:name]; receiver param; index :name; receiver type unknown
  - src/mir/mir_lowering.rb:1196 param[:name]; receiver param; index :name; receiver type unknown
  - src/mir/mir_lowering.rb:1197 param[:type]; receiver param; index :type; receiver type unknown
  - src/mir/mir_lowering.rb:1197 param[:type]; receiver param; index :type; receiver type unknown
- forwarded return let at src/annotator.rb:130: 13
  - src/annotator.rb:1495 @og[source_name]; receiver @og; index source_name; receiver type unknown
  - src/annotator.rb:1513 @og[source_name]; receiver @og; index source_name; receiver type unknown
  - src/annotator.rb:1513 @og[source_name]; receiver @og; index source_name; receiver type unknown
  - src/annotator.rb:1621 @og[c[:binding]]; receiver @og; index c[:binding]; receiver type unknown
  - src/annotator.rb:1912 @og&.[](name); receiver @og; index name; receiver type unknown
- hash record return [] at src/annotator.rb:2334: 13
  - src/annotator.rb:2357 method_def[:args]; receiver method_def; index :args; receiver type unknown
  - src/annotator.rb:2369 method_def[:zig]; receiver method_def; index :zig; receiver type unknown
  - src/annotator.rb:2370 method_def[:return]; receiver method_def; index :return; receiver type unknown
  - src/annotator.rb:2372 method_def[:allocates]; receiver method_def; index :allocates; receiver type unknown
  - src/annotator.rb:2373 method_def[:mutates_receiver]; receiver method_def; index :mutates_receiver; receiver type unknown

## Tuple-Like Array Report
- tuple-like array: an array literal whose position-specific element types look meaningful enough to model as a tuple/record
- confidence: `high` means the static shape is regular enough for a likely-safe tuple type; `review` means the shape is useful but needs human inspection
- Tuple-like array literals: 261
- Runtime-observed tuple-like array slots: 558

### Runtime Tuple-Like Array Slots
- src/ast/type.rb:1966 return strip_capability_suffix; [String, NilClass, NilClass]; 122214 call(s); complete, mixed, size 3
- src/ast/type.rb:1966 return strip_capability_suffix; [String, NilClass, NilClass]; 51798 call(s); complete, mixed, size 3
- src/ast/parser.rb:3905 return parse_comma_seq; [Lexer::Token, Array]; 40091 call(s); complete, mixed, size 2
- src/annotator-helpers/effects.rb:671 param points; [Hash, Hash]; 21456 call(s); complete, size 2
- src/ast/type.rb:1966 return strip_capability_suffix; [String, NilClass, NilClass]; 17027 call(s); complete, mixed, size 3
- src/ast/parser.rb:474 param pattern; [String, Symbol, Hash, String]; 15704 call(s); complete, mixed, size 4
- src/tools/lint_fix_rewriter.rb:197 param edits; [Hash, Hash]; 14707 call(s); complete, size 2
- src/ast/parser.rb:474 return process_pattern; [AST::BinaryOp, String]; 13021 call(s); complete, mixed, size 2
- src/annotator-helpers/effects.rb:671 param points; [Hash, Hash, Hash, Hash]; 11324 call(s); complete, size 4
- src/annotator-helpers/effects.rb:671 param points; [Hash, Hash, Hash]; 10060 call(s); complete, size 3
- src/tools/lint_fix_rewriter.rb:197 param edits; [Hash, Hash, Hash]; 9785 call(s); complete, size 3
- src/annotator-helpers/effects.rb:671 param points; [Hash, Hash]; 8117 call(s); complete, size 2
- src/ast/parser.rb:1618 return parse_effects_decl; [NilClass, NilClass]; 7440 call(s); complete, size 2
- src/tools/lint_fix_rewriter.rb:197 param edits; [Hash, Hash, Hash, Hash]; 6845 call(s); complete, size 4
- src/annotator-helpers/effects.rb:671 param points; [Hash, Hash, Hash, Hash, Hash, Hash]; 5276 call(s); complete, size 6
- src/ast/type.rb:1966 return strip_capability_suffix; [String, NilClass, NilClass]; 5215 call(s); complete, mixed, size 3
- src/ast/type.rb:1966 return strip_capability_suffix; [String, NilClass, NilClass]; 5215 call(s); complete, mixed, size 3
- src/ast/parser.rb:474 param pattern; [String, Symbol, Hash, String, Symbol, String]; 5070 call(s); complete, mixed, size 6
- src/ast/parser.rb:3905 return parse_comma_seq; [Lexer::Token, Array]; 5047 call(s); complete, mixed, size 2
- src/annotator-helpers/effects.rb:671 param points; [Hash, Hash, Hash, Hash, Hash]; 4982 call(s); complete, size 5
- src/ast/type.rb:932 return resolve_resource_close; [FalseClass, NilClass]; 4871 call(s); complete, mixed, size 2
- src/mir/alloc.rb:45 return resolve_resource_close; [FalseClass, NilClass]; 4871 call(s); complete, mixed, size 2
- src/tools/lint_fix_rewriter.rb:197 param edits; [Hash, Hash, Hash, Hash, Hash]; 4762 call(s); complete, size 5
- src/ast/type.rb:1966 return strip_capability_suffix; [String, NilClass, NilClass]; 4682 call(s); complete, mixed, size 3
- src/ast/type.rb:1966 return strip_capability_suffix; [String, NilClass, NilClass]; 4682 call(s); complete, mixed, size 3
- src/annotator-helpers/effects.rb:671 param points; [Hash, Hash]; 4636 call(s); complete, size 2
- src/ast/type.rb:1966 return strip_capability_suffix; [String, NilClass, NilClass]; 4495 call(s); complete, mixed, size 3
- src/ast/type.rb:1966 return strip_capability_suffix; [String, NilClass, NilClass]; 4495 call(s); complete, mixed, size 3
- src/ast/type.rb:1966 return strip_capability_suffix; [String, NilClass, NilClass]; 4495 call(s); complete, mixed, size 3
- src/ast/type.rb:1966 return strip_capability_suffix; [String, NilClass, NilClass]; 4112 call(s); complete, mixed, size 3
- [String, Symbol] appears 27 time(s), confidence high; first site src/ast/parser.rb:203
- [Symbol, Integer] appears 16 time(s), confidence high; first site src/annotator-helpers/auto_inference.rb:201
- [MIR::Let, MIR::ForStmt, MIR::BreakStmt] appears 13 time(s), confidence review; first site src/backends/pipeline_host.rb:874
- [MIR::AllocatorRef, MIR::Ident] appears 10 time(s), confidence review; first site src/backends/pipeline_host.rb:1064
- [MIR::Set, MIR::BreakStmt] appears 9 time(s), confidence review; first site src/backends/pipeline_host.rb:829
- [MIR::Let, MIR::IfStmt] appears 9 time(s), confidence review; first site src/backends/pipeline_host.rb:939
- [Symbol, T.nilable(String)] appears 8 time(s), confidence high; first site src/annotator-helpers/auto_inference.rb:168
- [T::Array[`T.untyped`], String] appears 7 time(s), confidence review; first site src/backends/pipeline_host.rb:483
- [T::Array[MIR::Let], T.nilable(T::Array[`T.untyped`]), T::Array[`T.untyped`], MIR::Ident] appears 6 time(s), confidence high; first site src/backends/pipeline_host.rb:2327
- [T::Boolean, NilClass] appears 6 time(s), confidence review; first site src/ast/error_registry.rb:130
- [Symbol, T::Hash[`T.untyped`, `T.untyped`]] appears 6 time(s), confidence review; first site src/ast/parser.rb:1633
- [Symbol, String] appears 4 time(s), confidence high; first site src/ast/parser.rb:29
- [T::Array[`T.untyped`], MIR::AddressOf] appears 4 time(s), confidence high; first site src/backends/pipeline_host.rb:4022
- [MIR::InlineZig, T.nilable(MIR::StructDef), T.nilable(MIR::Let), MIR::BreakStmt] appears 4 time(s), confidence high; first site src/backends/pipeline_host.rb:4332
- [MIR::Let, MIR::DeferStmt] appears 4 time(s), confidence review; first site src/backends/pipeline_host.rb:540
- [MIR::Set, MIR::Set, MIR::BreakStmt] appears 4 time(s), confidence review; first site src/backends/pipeline_host.rb:846
- [MIR::Let, MIR::WhileStmt] appears 4 time(s), confidence review; first site src/backends/pipeline_host.rb:1358
- [Symbol, NilClass] appears 3 time(s), confidence high; first site src/annotator-helpers/effects.rb:793
- [T::Boolean, String] appears 3 time(s), confidence review; first site src/ast/type.rb:934
- [MIR::Let, MIR::Let, MIR::ForStmt, MIR::BreakStmt] appears 3 time(s), confidence review; first site src/backends/pipeline_host.rb:908
- [MIR::Let, MIR::ExprStmt] appears 3 time(s), confidence review; first site src/backends/pipeline_host.rb:1084
- [AST::Assignment, AST::BreakNode] appears 3 time(s), confidence review; first site src/backends/pipeline_rewriter.rb:628
- [String, T::Array[`T.untyped`]] appears 3 time(s), confidence review; first site src/mir/mir_lowering.rb:5681
- [T::Array[`T.untyped`], T.nilable(Lexer::Token)] appears 2 time(s), confidence high; first site src/ast/parser.rb:2537
- [NilClass, Integer] appears 2 time(s), confidence high; first site src/tools/doctor.rb:553
- [MIR::IfStmt, MIR::Let, MIR::ForStmt, MIR::BreakStmt] appears 2 time(s), confidence review; first site src/backends/pipeline_host.rb:930
- [MIR::Ident, MIR::ListLength] appears 2 time(s), confidence review; first site src/backends/pipeline_host.rb:1137
- [MIR::Let, MIR::Let, MIR::ForStmt] appears 2 time(s), confidence review; first site src/backends/pipeline_host.rb:1302
- [MIR::Let, MIR::Let, MIR::Let, MIR::ExprStmt, MIR::Set] appears 2 time(s), confidence review; first site src/backends/pipeline_host.rb:1479
- [MIR::Ident, MIR::Ident, MIR::AddressOf] appears 2 time(s), confidence review; first site src/backends/pipeline_host.rb:1739
- [Symbol, MIR::FieldGet] appears 2 time(s), confidence review; first site src/backends/pipeline_host.rb:3478
- [AST::Assignment, AST::IfStatement] appears 2 time(s), confidence review; first site src/backends/pipeline_rewriter.rb:567
- [T::Array[`T.untyped`], T::Hash[`T.untyped`, `T.untyped`]] appears 2 time(s), confidence review; first site src/mir/fsm_transform/recursive_splitter.rb:816
- [String, String, T.nilable(String), T.nilable(String), String] appears 2 time(s), confidence review; first site src/mir/fsm_wrapper_emitter.rb:116
- [T::Boolean, Symbol] appears 2 time(s), confidence review; first site src/mir/mir_lowering.rb:2529
- [MIR::ExprStmt, MIR::ExprStmt, MIR::ReturnStmt] appears 2 time(s), confidence review; first site src/mir/mir_lowering.rb:3246
- [MIR::Ident, T.any(MIR::InlineBc, MIR::InlineZig), MIR::Ident] appears 2 time(s), confidence review; first site src/mir/mir_lowering.rb:6467
- [MIR::Let, MIR::DeferStmt, MIR::Let] appears 2 time(s), confidence review; first site src/mir/mir_lowering.rb:6683
- [MIR::Ident, MIR::MethodCall, MIR::Ident] appears 2 time(s), confidence review; first site src/mir/mir_lowering.rb:6737
- [T.nilable(Type), NilClass] appears 1 time(s), confidence high; first site src/ast/ast.rb:348
- [T.nilable(String), T.nilable(Type)] appears 1 time(s), confidence high; first site src/ast/parser.rb:1177
- [T::Array[MIR::Let], T.nilable(T::Array[`T.untyped`]), T::Array[`T.untyped`], MIR::Conditional] appears 1 time(s), confidence high; first site src/backends/pipeline_host.rb:2349
- [T::Array[MIR::Let], T.nilable(T::Array[`T.untyped`]), T::Array[MIR::IfStmt], MIR::Conditional] appears 1 time(s), confidence high; first site src/backends/pipeline_host.rb:2405
- [MIR::InlineZig, T.nilable(MIR::StructDef), T.nilable(MIR::Let), MIR::ExprStmt] appears 1 time(s), confidence high; first site src/backends/pipeline_host.rb:4462
- [T.nilable(String), NilClass] appears 1 time(s), confidence high; first site src/mir/mir_emitter.rb:684
- [T.nilable(Integer), Integer, String] appears 1 time(s), confidence high; first site src/tools/doctor.rb:511
- [MIR::FieldGet, MIR::Lit] appears 1 time(s), confidence review; first site src/annotator-helpers/auto_inference.rb:779
- [Symbol, NilClass, NilClass] appears 1 time(s), confidence review; first site src/annotator-helpers/fixable_helpers.rb:1588
- [T::Boolean, T::Hash[`T.untyped`, `T.untyped`]] appears 1 time(s), confidence review; first site src/ast/error_registry.rb:133
- [String, Symbol, T::Hash[`T.untyped`, `T.untyped`], String, Symbol, String] appears 1 time(s), confidence review; first site src/ast/parser.rb:121
