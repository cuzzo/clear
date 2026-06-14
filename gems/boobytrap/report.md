# Boobytrap Report

> Defect-risk hotspots: recurring bug-fix locality (bugspots, time-decayed) x branch-coverage gap.
> A ranking to triage **top-down**, never a verdict. A
> hotspot is "the code most likely to be a bug source,"
> not "a bug."

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Hotspots (100)](#hotspots-100)
- [Mostly Uncovered Methods (3)](#mostly-uncovered-methods-3)
- [State-Based Branch Hotspots (1620)](#statebased-branch-hotspots-1620)
- [Multi-File Fix Blast Radius (107)](#multifile-fix-blast-radius-107)
- [Fixed But Unmeasured (7)](#fixed-but-unmeasured-7)
- [Run Summary](#run-summary)

## Project Prioritization
- The single highest-risk file is **`src/ast/diagnostic_registry.rb`** (hotspot=0.1537: fix_norm=0.43, branch gap=35.7%).
- 16 file(s) are within 50% of the top score (hotspot >= 0.0769); triage those first.
- Highest state-based branch hotspot: `src/ast/ast.rb:initialize` (score=841.88, state branches=21, fix_norm=0.941, branch gap=14.7%).
- Highest multi-file fix blast radius: `src/mir/mir_lowering.rb` (score=18.141, avg files/fix=71.87, max=1828).

## Hotspots (100)
_normalized fix-churn x branch-gap; highest = most likely defect source._

| # | file | hotspot | fix_norm | branch gap | uncovered/total |
|---|------|---------|----------|-----------|-----------------|
| 1 | `src/ast/diagnostic_registry.rb` | 0.1537 | 0.43 | 35.7% | 5/14 |
| 2 | `src/mir/fiber_ctx_builder.rb` | 0.1476 | 0.728 | 20.3% | 30/148 |
| 3 | `src/ast/ast.rb` | 0.1475 | 1.0 | 14.7% | 55/373 |
| 4 | `src/annotator/annotator.rb` | 0.1413 | 0.812 | 17.4% | 8/46 |
| 5 | `src/mir/mir_pass.rb` | 0.1295 | 0.742 | 17.5% | 96/550 |
| 6 | `src/mir/lowering/concurrency.rb` | 0.1272 | 0.907 | 14.0% | 60/428 |
| 7 | `src/mir/lowering/expressions.rb` | 0.1235 | 0.742 | 16.6% | 207/1244 |
| 8 | `src/mir/hoist.rb` | 0.1209 | 0.859 | 14.1% | 66/469 |
| 9 | `src/mir/fsm_transform/emit.rb` | 0.1078 | 0.714 | 15.1% | 37/245 |
| 10 | `src/mir/lowering/functions.rb` | 0.1018 | 0.504 | 20.2% | 119/589 |
| 11 | `src/mir/fsm_transform/recursive_splitter.rb` | 0.0973 | 0.428 | 22.7% | 20/88 |
| 12 | `src/semantic/concurrency_checks.rb` | 0.0958 | 0.356 | 26.9% | 14/52 |
| 13 | `src/mir/lowering/capabilities.rb` | 0.0913 | 0.466 | 19.6% | 94/480 |
| 14 | `src/mir/mir_lowering.rb` | 0.0874 | 0.843 | 10.4% | 279/2689 |
| 15 | `src/mir/fsm_transform/segments.rb` | 0.0821 | 0.428 | 19.2% | 14/73 |
| 16 | `src/semantic/escape_analysis.rb` | 0.0802 | 0.376 | 21.4% | 117/548 |
| 17 | `src/mir/mir.rb` | 0.0762 | 0.339 | 22.5% | 56/249 |
| 18 | `src/annotator/helpers/effects.rb` | 0.0663 | 0.784 | 8.5% | 46/544 |
| 19 | `src/mir/cleanup_classifier.rb` | 0.0642 | 0.35 | 18.3% | 99/540 |
| 20 | `src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb` | 0.0602 | 0.678 | 8.9% | 15/169 |
| 21 | `src/mir/control_flow.rb` | 0.0567 | 0.329 | 17.2% | 91/528 |
| 22 | `src/mir/fsm_lowering.rb` | 0.0529 | 0.187 | 28.3% | 36/127 |
| 23 | `src/annotator/domains/errors.rb` | 0.0504 | 0.428 | 11.8% | 40/340 |
| 24 | `src/mir/lowering/control_flow.rb` | 0.0499 | 0.27 | 18.5% | 62/335 |
| 25 | `src/annotator/helpers/with_match_check.rb` | 0.0406 | 0.373 | 10.9% | 11/101 |
| 26 | `src/mir/mir_checker.rb` | 0.0373 | 0.294 | 12.7% | 102/804 |
| 27 | `src/mir/lowering/variables.rb` | 0.0371 | 0.295 | 12.6% | 50/398 |
| 28 | `src/backends/importer.rb` | 0.0356 | 0.356 | 10.0% | 4/40 |
| 29 | `src/mir/mir_emitter.rb` | 0.0332 | 0.273 | 12.2% | 77/632 |
| 30 | `src/backends/compiler_frontend.rb` | 0.0297 | 0.356 | 8.3% | 2/24 |
| 31 | `src/mir/fsm_wrapper_emitter.rb` | 0.0295 | 0.25 | 11.8% | 13/110 |
| 32 | `src/mir/lower/pipeline/pipeline_range_lowerer.rb` | 0.028 | 0.25 | 11.2% | 14/125 |
| 33 | `src/annotator/domains/control_flow.rb` | 0.0236 | 0.175 | 13.5% | 31/230 |
| 34 | `src/annotator/phases/body_analysis.rb` | 0.0181 | 0.356 | 5.1% | 3/59 |
| 35 | `src/ast/fixable_error.rb` | 0.0127 | 0.03 | 42.9% | 6/14 |
| 36 | `src/mir/lowering/literals.rb` | 0.0104 | 0.126 | 8.2% | 5/61 |
| 37 | `src/mir/fsm_transform/suspend_resolvers.rb` | 0.0085 | 0.052 | 16.3% | 8/49 |
| 38 | `src/annotator/domains/variables.rb` | 0.006 | 0.042 | 14.4% | 31/216 |
| 39 | `src/annotator/helpers/intrinsic_registry.rb` | 0.0049 | 0.05 | 9.8% | 9/92 |
| 40 | `src/annotator/helpers/function_analysis.rb` | 0.0047 | 0.038 | 12.4% | 58/469 |

- ...(+60 more)

## Mostly Uncovered Methods (3)
_non-trivial methods (`>=5` executable lines) with very low line coverage; risk = missed lines x gap, plus Decomplex detector score, instance-state writes, and dark branches._

- Completely uncovered: 0
- <=10% covered: 1
- <=20% covered: 3
- <=50% covered: 8

| # | method | risk | covered | missed | decomplex | findings | writes | dark branches |
|---|--------|------|---------|--------|-----------|----------|--------|---------------|
| 1 | `src/mir/mir_emitter.rb:1185` `emit_sorted_lock_acquire_panic` | 14.08 | 1/13 | 12 | 2 | 1 | 0 | 0 |
| 2 | `src/mir/lowering/functions.rb:94` `coerce_zig` | 6.17 | 1/6 | 5 | 0 | 0 | 0 | 4 |
| 3 | `src/mir/lowering/state.rb:54` `with_rt_name` | 4.7 | 1/5 | 4 | 1 | 3 | 0 | 0 |

## State-Based Branch Hotspots (1620)
_Decomplex state-based branch density joined with fix-cache and branch coverage. These are branches over mutable/object state that are uncovered and/or historically fixed._

| # | method | risk | state branches | refs | fix_norm | branch gap | line gap | dark branches |
|---|--------|------|----------------|------|----------|------------|----------|---------------|
| 1 | `src/ast/ast.rb:initialize` | 841.88 | 21 | `rt.nil? | self[:bindings].nil? | self[:body].nil? | self[:borrowed].nil? | self[:capabilities].nil?` | 0.941 | 14.7% | 0.0% | 0 |
| 2 | `src/mir/fsm_transform/emit.rb:build_recursive` | 376.98 | 14 | `all_promoted.any? | ast_stmts.empty? | descriptor.nil? | lowered_mir.nil? | name.empty?` | 0.671 | 15.1% | 0.0% | 0 |
| 3 | `src/mir/cleanup_classifier.rb:classify_binding` | 347.56 | 13 | `facts.borrow_provenance | facts.container_borrow | facts.empty_initializer | facts.heap_storage | facts.mutable_binding_mutated` | 0.329 | 18.3% | 0.0% | 0 |
| 4 | `src/annotator/domains/errors.rb:visit_ReturnNode` | 265.0 | 13 | `expected.heap_return_storage? | expected.plain_return_payload_type | inline_bg_sources.any? | node.value | node.value.full_type!(context: "return expression storage").requires_move?` | 0.403 | 11.8% | 0.0% | 0 |
| 5 | `src/mir/mir_lowering.rb:mir_cast` | 257.27 | 10 | `from_t.dynamic? | from_t.fixed? | from_t.float? | from_t.fn_type? | from_t.integer?` | 0.793 | 10.4% | 0.0% | 0 |
| 6 | `src/mir/lowering/expressions.rb:lower_copy` | 220.85 | 8 | `dst_ti.collection? | dst_ti.direct_indexable_collection? | dst_ti.string? | ti.any_rc? | ti.any_sync?` | 0.698 | 16.6% | 6.3% | 2 |
| 7 | `src/annotator/domains/variables.rb:finalize_decl_node!` | 216.24 | 13 | `cap_tok.value | final_type.collection | fixes.any? | fixes.empty? | node.type` | 0.039 | 14.4% | 0.0% | 0 |
| 8 | `src/annotator/domains/execution_boundaries.rb:visit_NextExpr` | 207.04 | 15 | `async_shape.payload_type | async_shape.promise? | async_shape.shared_promise? | node.expr | promise_type.bounded_stream?` | 0.0 | 6.2% | 0.0% | 0 |
| 9 | `src/tools/formatter.rb:needs_space?` | 204.68 | 27 | `@generic_bracket_indices | @struct_lit_brace_indices | @struct_lit_brace_indices.empty? | a.raw | a.type` | 0.017 | 6.5% | 0.0% | 0 |
| 10 | `src/mir/lowering/functions.rb:lower_intrinsic` | 194.9 | 11 | `alloc_metadata.empty? | consumed_operands.empty? | entry.intrinsic_bc? | node.args | node.args.first` | 0.474 | 20.2% | 0.0% | 0 |
| 11 | `src/tools/formatter.rb:expand_if_while_for` | 190.61 | 22 | `out.length | t.raw | t.type | tj.raw | tj.type` | 0.017 | 6.5% | 0.0% | 0 |
| 12 | `src/semantic/escape_analysis.rb:propagate_caller_sync!` | 180.74 | 11 | `call_site.fn_var_call | callee_fn.params | entry.storage | entry.sync | fn_nodes.empty?` | 0.354 | 21.4% | 0.0% | 0 |
| 13 | `src/annotator/domains/lifetimes.rb:finalize_scope` | 179.13 | 15 | `branch.nil? | info.mutable | info.mutated | info.ownership_kind | info.read` | 0.0 | 19.4% | 0.0% | 0 |
| 14 | `src/mir/lowering/variables.rb:lower_var_decl_init` | 172.49 | 12 | `ft.fixed_soa? | ft.list_collection? | ft.pool? | ft.set_collection? | node.value` | 0.277 | 12.6% | 0.0% | 0 |
| 15 | `src/annotator/helpers/function_analysis.rb:visit_FunctionDef` | 162.98 | 14 | `candidate_snap_types.size | catch_body_scan.references_snapshot | fn_type_params.any? | node.name | node.reentrance_kind` | 0.036 | 12.4% | 0.0% | 0 |
| 16 | `src/mir/hoist.rb:collect_stmt_hoists!` | 148.5 | 9 | `arg.value | right_type.collection? | stmt.expr | stmt.name | stmt.value` | 0.808 | 14.1% | 0.0% | 0 |
| 17 | `src/mir/mir_checker.rb:check_fsm_structure!` | 143.79 | 10 | `cap.cleanup_at | cap.name | cleanup_step.nil? | fact.move_guarded | fact.name` | 0.276 | 12.7% | 0.0% | 0 |
| 18 | `src/annotator/domains/execution_boundaries.rb:visit_BgBlock` | 140.15 | 12 | `analysis.has_affine_locked | analysis.has_local | analysis.has_sharded | analysis_result.has_local | analysis_result.has_non_escaping_capture` | 0.0 | 6.2% | 0.0% | 0 |
| 19 | `src/mir/lowering/control_flow.rb:for_each_loop_stmt` | 137.28 | 8 | `ct.bounded_stream? | ct.dynamic_field_array? | ct.dynamic_stream? | ct.fixed_soa? | ct.inf_stream?` | 0.254 | 18.5% | 3.4% | 2 |
| 20 | `src/ast/parser.rb:parse_function_def` | 130.75 | 10 | `@gradual | @pos | @tokens | @tokens[@pos + 1].value | T.must(cap_tok).value` | 0.019 | 6.9% | 0.0% | 0 |
| 21 | `src/mir/fiber_ctx_builder.rb:rc_payload_zig_type` | 127.67 | 7 | `payload.any_sync? | payload.atomic? | payload.indirect? | payload.locked? | payload.map?` | 0.685 | 20.3% | 0.0% | 0 |
| 22 | `src/mir/lowering/functions.rb:ast_expr_produces_heap?` | 127.57 | 8 | `node.borrow_provenance? | node.heap_storage? | node.needs_heap_create | node.op | node.rodata_provenance?` | 0.474 | 20.2% | 0.0% | 0 |
| 23 | `src/annotator/domains/member_access.rb:visit_StructLit` | 120.76 | 10 | `field_names.empty? | missing.any? | node.fields | node.fields.empty? | node.fields.length` | 0.019 | 7.7% | 0.0% | 0 |
| 24 | `src/annotator/domains/expressions.rb:visit_CapabilityWrap` | 116.42 | 10 | `node.atomic? | node.atomic_ptr? | node.capability? | node.indirect? | node.layout` | 0.0 | 5.8% | 0.0% | 0 |
| 25 | `src/annotator/helpers/function_analysis.rb:resolve_call` | 115.25 | 11 | `arg.full_type!(context: "extern argument").soa? | call_type.error_union? | comptime_type_args.any? | entry.storage | node.args` | 0.036 | 12.4% | 0.0% | 0 |
| 26 | `src/mir/lowering/expressions.rb:lower_or_rescue` | 110.91 | 14 | `ex.message | facts.left_is_error | facts.target | node.right` | 0.698 | 16.6% | 0.0% | 0 |
| 27 | `src/mir/lowering/expressions.rb:lower_identifier` | 110.91 | 8 | `capability_state.atomic_emit_raw | node.atomic_borrow | node.fn_ref | node.heap_dupe_result | node.name` | 0.698 | 16.6% | 0.0% | 0 |
| 28 | `src/mir/lowering/expressions.rb:index_access_value` | 110.91 | 7 | `map_ft.numeric_map? | map_ft.sharded? | map_ft.striped? | plan.optional? | plan.target_ast.metatype` | 0.698 | 16.6% | 0.0% | 0 |
| 29 | `src/mir/mir_lowering.rb:owned_sink_plan` | 110.83 | 7 | `source.borrowed_union_sink | source.existing_owned_source | source.satisfies_rc_sink? | ti.any_rc? | ti.collection_value?` | 0.793 | 10.4% | 0.0% | 0 |
| 30 | `src/annotator/helpers/function_analysis.rb:declare_and_verify_params` | 104.77 | 10 | `fams.empty? | field_names.empty? | missing.any? | param.default | param.sync` | 0.036 | 12.4% | 0.0% | 0 |
| 31 | `src/annotator/domains/errors.rb:visit_OrRescue` | 101.92 | 13 | `node.left | node.left.error_union_type | node.right | t_left_type.error_union? | t_left_type.optional?` | 0.403 | 11.8% | 0.0% | 0 |
| 32 | `src/mir/lowering/functions.rb:lower_extern_struct` | 99.22 | 7 | `items.length | mod_parts.first | mod_parts[1..].any? | node.as_type | node.field_decls` | 0.474 | 20.2% | 0.0% | 0 |
| 33 | `src/ast/ast.rb:finalize_storage!` | 93.54 | 7 | `final_type.fn_type? | type_obj.any_sync? | type_obj.heap? | type_obj.list_collection? | val_ti.link?` | 0.941 | 14.7% | 0.0% | 0 |
| 34 | `src/ast/ast.rb:body_slots` | 93.54 | 6 | `match_case.body | node.body | node.default_case | node.do_branch | node.else_branch` | 0.941 | 14.7% | 0.0% | 0 |
| 35 | `src/semantic/escape_analysis.rb:expr_produces_heap?` | 92.01 | 7 | `node.borrow_provenance? | node.heap_storage? | node.op | node.rodata_provenance? | node.storage` | 0.354 | 21.4% | 0.0% | 0 |
| 36 | `src/ast/type.rb:accepts?` | 88.5 | 8 | `other_type.any? | other_type.byte? | other_type.error_union? | other_type.map? | other_type.numeric?` | 0.003 | 10.3% | 0.0% | 0 |
| 37 | `src/annotator/domains/member_access.rb:visit_GetIndex` | 87.82 | 8 | `index_type_info.numeric? | index_type_info.string? | node.target | node.target.metatype | result_type.optional?` | 0.019 | 7.7% | 0.0% | 0 |
| 38 | `src/mir/mir_checker.rb:cleanup_source_owns_value?` | 86.27 | 5 | `MIR::OwnershipEffect.of(init).produces_owned | cleanup.cleanup_entry | cleanup.cleanup_entry.match_as? | init.ownership_consumption | init.ownership_consumption.names` | 0.276 | 12.7% | 0.0% | 0 |
| 39 | `src/ast/type.rb:accepts_array?` | 85.18 | 7 | `T.must(element_type).any? | other_type.array? | other_type.bounded_stream? | other_type.dynamic_stream? | other_type.element_type` | 0.003 | 10.3% | 0.0% | 0 |
| 40 | `src/mir/lowering/functions.rb:lower_function_def` | 85.05 | 6 | `final_zig_type.error_union? | node.can_fail | node.can_fail.nil? | node.mutual_thunk_plan | node.thunk_plan` | 0.474 | 20.2% | 0.0% | 0 |

- ...(+1580 more)

## Multi-File Fix Blast Radius (107)
_Time-decayed fix commits where a file repeatedly changes with many other files. High rows are bug fixes whose blast radius is cross-module, not local._

| # | file | score | fixes | avg files/fix | max files | top co-touched files |
|---|------|-------|-------|---------------|-----------|----------------------|
| 1 | `src/mir/mir_lowering.rb` | 18.141 | 30 | 71.87 | 1828 | spec/mir_lowering_spec.rb (0.728); src/mir/lowering/concurrency.rb (0.698); src/mir/fiber_ctx_builder.rb (0.685); spec/mir_gap_burn_spec.rb (0.68); spec/mir_emitter_spec.rb (0.657) |
| 2 | `src/mir/lowering/concurrency.rb` | 17.887 | 7 | 20.71 | 36 | src/mir/mir_lowering.rb (0.698); spec/mir_lowering_spec.rb (0.687); src/mir/fiber_ctx_builder.rb (0.685); spec/concurrency_spec.rb (0.64); examples/minivm/bc_emitter.rb (0.638) |
| 3 | `src/mir/fiber_ctx_builder.rb` | 16.855 | 5 | 380.6 | 1828 | spec/mir_lowering_spec.rb (0.685); src/mir/mir_lowering.rb (0.685); src/mir/lowering/concurrency.rb (0.685); examples/minivm/bc_emitter.rb (0.638); spec/concurrency_spec.rb (0.638) |
| 4 | `src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb` | 16.182 | 2 | 26.5 | 27 | examples/minivm/bc_emitter.rb (0.638); examples/minivm/register_bc_emitter.rb (0.638); spec/concurrency_spec.rb (0.638); spec/fsm_classifier_spec.rb (0.638); spec/mir_emitter_spec.rb (0.638) |
| 5 | `src/annotator/annotator.rb` | 15.88 | 5 | 22.0 | 31 | examples/minivm/register_bc_emitter.rb (0.754); sorbet/rbi/clear-attr-accessors.rbi (0.738); spec/mir_gap_burn_spec.rb (0.738); src/annotator/helpers/effects.rb (0.738); examples/minivm/bc_emitter.rb (0.421) |
| 6 | `src/annotator/helpers/effects.rb` | 15.428 | 2 | 21.5 | 26 | examples/minivm/register_bc_emitter.rb (0.738); sorbet/rbi/clear-attr-accessors.rbi (0.738); spec/mir_gap_burn_spec.rb (0.738); src/annotator/annotator.rb (0.738); examples/minivm/bc_emitter.rb (0.403) |
| 7 | `src/mir/hoist.rb` | 13.437 | 12 | 17.17 | 36 | spec/mir_gap_burn_spec.rb (0.609); examples/minivm/register_bc_emitter.rb (0.586); src/mir/lowering/concurrency.rb (0.394); src/mir/mir_pass.rb (0.378); src/semantic/escape_analysis.rb (0.354) |
| 8 | `src/ast/ast.rb` | 13.261 | 12 | 161.17 | 1828 | sorbet/rbi/clear-attr-accessors.rbi (0.71); src/mir/lowering/concurrency.rb (0.558); src/mir/mir_lowering.rb (0.462); src/mir/lowering/functions.rb (0.459); spec/mir_lowering_spec.rb (0.442) |
| 9 | `src/mir/lowering/functions.rb` | 11.208 | 6 | 22.17 | 36 | src/ast/ast.rb (0.459); spec/mir_lowering_spec.rb (0.445); src/mir/mir_lowering.rb (0.445); spec/mir_gap_burn_spec.rb (0.442); examples/minivm/bc_emitter.rb (0.421) |
| 10 | `src/mir/fsm_transform/emit.rb` | 11.145 | 7 | 276.29 | 1828 | src/mir/mir_lowering.rb (0.452); spec/mir_lowering_spec.rb (0.452); src/mir/lowering/concurrency.rb (0.452); src/mir/fiber_ctx_builder.rb (0.45); sorbet/rbi/clear-attr-accessors.rbi (0.419) |
| 11 | `src/ast/diagnostic_registry.rb` | 10.151 | 4 | 472.75 | 1828 | spec/concurrency_spec.rb (0.405); spec/mir_lowering_spec.rb (0.405); src/mir/fsm_transform/emit.rb (0.405); src/mir/mir_lowering.rb (0.405); src/mir/lowering/concurrency.rb (0.405) |
| 12 | `src/mir/fsm_transform/recursive_splitter.rb` | 10.083 | 2 | 927.0 | 1828 | examples/minivm/bc_emitter.rb (0.403); sorbet/rbi/clear-attr-accessors.rbi (0.403); spec/concurrency_spec.rb (0.403); spec/fsm_classifier_spec.rb (0.403); spec/fsm_recursive_splitter_spec.rb (0.403) |
| 13 | `src/mir/fsm_transform/segments.rb` | 10.083 | 2 | 927.0 | 1828 | examples/minivm/bc_emitter.rb (0.403); sorbet/rbi/clear-attr-accessors.rbi (0.403); spec/concurrency_spec.rb (0.403); spec/fsm_classifier_spec.rb (0.403); spec/fsm_recursive_splitter_spec.rb (0.403) |
| 14 | `src/annotator/domains/errors.rb` | 10.072 | 1 | 26.0 | 26 | examples/minivm/bc_emitter.rb (0.403); examples/minivm/register_bc_emitter.rb (0.403); sorbet/rbi/clear-attr-accessors.rbi (0.403); spec/concurrency_spec.rb (0.403); spec/fsm_classifier_spec.rb (0.403) |
| 15 | `src/annotator/phases/declaration_index.rb` | 10.072 | 1 | 26.0 | 26 | examples/minivm/bc_emitter.rb (0.403); examples/minivm/register_bc_emitter.rb (0.403); sorbet/rbi/clear-attr-accessors.rbi (0.403); spec/concurrency_spec.rb (0.403); spec/fsm_classifier_spec.rb (0.403) |
| 16 | `src/mir/mir_pass.rb` | 7.504 | 14 | 143.86 | 1828 | sorbet/rbi/clear-attr-accessors.rbi (0.642); src/mir/hoist.rb (0.378); spec/mir_gap_burn_spec.rb (0.374); src/ast/ast.rb (0.347); src/annotator/annotator.rb (0.336) |
| 17 | `src/mir/lowering/capabilities.rb` | 7.501 | 8 | 16.25 | 36 | src/mir/hoist.rb (0.256); src/mir/lowering/control_flow.rb (0.254); examples/minivm/bc_emitter.rb (0.252); examples/minivm/register_bc_emitter.rb (0.252); src/mir/lowering/concurrency.rb (0.248) |
| 18 | `src/mir/mir.rb` | 7.201 | 9 | 216.67 | 1828 | src/mir/mir_lowering.rb (0.298); src/mir/hoist.rb (0.297); spec/mir_lowering_spec.rb (0.295); src/mir/mir_checker.rb (0.276); src/mir/lowering/variables.rb (0.276) |
| 19 | `src/mir/lowering/variables.rb` | 6.96 | 4 | 28.5 | 36 | spec/mir_lowering_spec.rb (0.277); src/mir/hoist.rb (0.277); src/mir/mir_lowering.rb (0.277); src/mir/mir.rb (0.276); src/mir/mir_checker.rb (0.276) |
| 20 | `src/mir/mir_checker.rb` | 6.937 | 4 | 477.75 | 1828 | spec/mir_lowering_spec.rb (0.276); src/mir/mir.rb (0.276); src/mir/mir_lowering.rb (0.276); src/mir/hoist.rb (0.276); src/mir/lowering/variables.rb (0.276) |
| 21 | `src/mir/lowering/control_flow.rb` | 6.427 | 3 | 26.33 | 36 | src/mir/hoist.rb (0.254); src/mir/lowering/capabilities.rb (0.254); examples/minivm/bc_emitter.rb (0.252); examples/minivm/register_bc_emitter.rb (0.252); spec/concurrency_spec.rb (0.237) |
| 22 | `src/mir/mir_emitter.rb` | 6.363 | 10 | 195.4 | 1828 | src/mir/mir_lowering.rb (0.256); src/mir/mir.rb (0.256); spec/mir_emitter_spec.rb (0.254); spec/concurrency_spec.rb (0.237); spec/mir_lowering_spec.rb (0.237) |
| 23 | `src/ast/schemas.rb` | 6.121 | 2 | 927.5 | 1828 | examples/minivm/bc_emitter.rb (0.235); spec/capabilities_spec.rb (0.235); spec/concurrency_spec.rb (0.235); spec/fsm_classifier_spec.rb (0.235); spec/fsm_wrapper_emitter_spec.rb (0.235) |
| 24 | `src/mir/fsm_wrapper_emitter.rb` | 6.121 | 2 | 927.5 | 1828 | examples/minivm/bc_emitter.rb (0.235); spec/capabilities_spec.rb (0.235); spec/concurrency_spec.rb (0.235); spec/fsm_classifier_spec.rb (0.235); spec/fsm_wrapper_emitter_spec.rb (0.235) |
| 25 | `src/mir/lower/pipeline/pipeline_range_lowerer.rb` | 6.11 | 1 | 27.0 | 27 | examples/minivm/bc_emitter.rb (0.235); examples/minivm/register_bc_emitter.rb (0.235); spec/capabilities_spec.rb (0.235); spec/concurrency_spec.rb (0.235); spec/fsm_classifier_spec.rb (0.235) |
| 26 | `src/annotator/helpers/with_match_check.rb` | 5.485 | 2 | 13.0 | 17 | sorbet/rbi/clear-attr-accessors.rbi (0.351); examples/minivm/register_bc_emitter.rb (0.335); spec/annotator_gap_burndown_spec.rb (0.335); spec/gen_attr_rbi_spec.rb (0.335); spec/mir_gap_burn_spec.rb (0.335) |
| 27 | `src/semantic/escape_analysis.rb` | 5.412 | 2 | 10.5 | 17 | src/mir/hoist.rb (0.354); examples/minivm/register_bc_emitter.rb (0.335); sorbet/rbi/clear-attr-accessors.rbi (0.335); spec/annotator_gap_burndown_spec.rb (0.335); spec/gen_attr_rbi_spec.rb (0.335) |
| 28 | `src/backends/importer.rb` | 5.368 | 3 | 617.67 | 1828 | sorbet/rbi/clear-attr-accessors.rbi (0.335); src/backends/compiler_frontend.rb (0.335); src/mir/mir_pass.rb (0.335); tools/gen_attr_rbi.rb (0.335); examples/minivm/register_bc_emitter.rb (0.335) |
| 29 | `src/backends/compiler_frontend.rb` | 5.367 | 2 | 922.5 | 1828 | sorbet/rbi/clear-attr-accessors.rbi (0.335); src/backends/importer.rb (0.335); src/mir/mir_pass.rb (0.335); tools/gen_attr_rbi.rb (0.335); examples/minivm/register_bc_emitter.rb (0.335) |
| 30 | `src/annotator/phases/body_analysis.rb` | 5.356 | 1 | 17.0 | 17 | examples/minivm/register_bc_emitter.rb (0.335); sorbet/rbi/clear-attr-accessors.rbi (0.335); spec/annotator_gap_burndown_spec.rb (0.335); spec/gen_attr_rbi_spec.rb (0.335); spec/mir_gap_burn_spec.rb (0.335) |
| 31 | `src/semantic/concurrency_checks.rb` | 5.356 | 1 | 17.0 | 17 | examples/minivm/register_bc_emitter.rb (0.335); sorbet/rbi/clear-attr-accessors.rbi (0.335); spec/annotator_gap_burndown_spec.rb (0.335); spec/gen_attr_rbi_spec.rb (0.335); spec/mir_gap_burn_spec.rb (0.335) |
| 32 | `src/mir/lowering/expressions.rb` | 3.093 | 6 | 16.33 | 36 | .github/workflows/ci.yml (0.5); zig/lib/partitioned-map-test.zig (0.5); zig/partitioned-map-test.zig (0.5); src/mir/lowering/capabilities.rb (0.151); sorbet/rbi/clear-attr-accessors.rbi (0.149) |
| 33 | `src/README.md` | 2.88 | 2 | 918.0 | 1828 | spec/higher_order_spec.rb (0.41); zig/lib/data-structures.zig (0.41); zig/runtime/sharded-list-test.zig (0.41); zig/runtime/soa-list-test.zig (0.41); src/annotator/README.md (0.41) |
| 34 | `src/annotator/README.md` | 2.869 | 1 | 8.0 | 8 | spec/higher_order_spec.rb (0.41); src/README.md (0.41); src/mir/README.md (0.41); tools/fuzz/templates/mir_checker_negative_matrix.rb (0.41); zig/lib/data-structures.zig (0.41) |
| 35 | `src/mir/README.md` | 2.869 | 1 | 8.0 | 8 | spec/higher_order_spec.rb (0.41); src/README.md (0.41); src/annotator/README.md (0.41); tools/fuzz/templates/mir_checker_negative_matrix.rb (0.41); zig/lib/data-structures.zig (0.41) |
| 36 | `src/mir/cleanup_classifier.rb` | 1.503 | 4 | 20.5 | 36 | src/ast/ast.rb (0.326); src/mir/mir_pass.rb (0.31); src/mir/control_flow.rb (0.309); sorbet/rbi/clear-attr-accessors.rbi (0.307); src/mir/mir_lowering.rb (0.022) |
| 37 | `src/mir/control_flow.rb` | 1.31 | 8 | 237.63 | 1828 | src/mir/mir_pass.rb (0.309); src/mir/cleanup_classifier.rb (0.309); sorbet/rbi/clear-attr-accessors.rbi (0.307); src/ast/ast.rb (0.307); src/backends/pipeline_host.rb (0.002) |
| 38 | `src/mir/fsm_lowering.rb` | 1.016 | 6 | 318.67 | 1828 | src/mir/hoist.rb (0.159); src/mir/lowering/concurrency.rb (0.159); src/ast/ast.rb (0.155); gems/nil-kill/lib/nil_kill/static_diff_audit.rb (0.155); gems/nil-kill/spec/static_diff_audit_spec.rb (0.155) |
| 39 | `src/mir/lowering/literals.rb` | 0.902 | 4 | 15.5 | 36 | src/mir/mir_lowering.rb (0.068); spec/mir_lowering_spec.rb (0.049); src/mir/fsm_transform/emit.rb (0.049); src/mir/fsm_transform/suspend_resolvers.rb (0.049); src/mir/lowering/concurrency.rb (0.049) |
| 40 | `src/annotator/domains/control_flow.rb` | 0.873 | 2 | 7.5 | 9 | sorbet/rbi/clear-attr-accessors.rbi (0.165); src/mir/lowering/capabilities.rb (0.165); spec/coverage_tools_spec.rb (0.149); src/mir/lowering/expressions.rb (0.149); tools/zig_coverage_support.rb (0.149) |

- ...(+67 more)

## Fixed But Unmeasured (7)
_files with recurring fixes but NO branch-coverage data -- recurring-fix code the corpus does not measure at all; itself a risk._

- `src/README.md` (fix_norm=0.436)
- `src/annotator/README.md` (fix_norm=0.436)
- `src/mir/README.md` (fix_norm=0.436)
- `src/annotator/helpers/intrinsic_emit.rb` (fix_norm=0.05)
- `src/annotator.rb` (fix_norm=0.001)
- `src/lsp/README.md` (fix_norm=0.0)
- `src/mir/thunk_transform.rb` (fix_norm=0.0)

## Run Summary
- Repo: `/home/yahn/cheat`
- Scope: `src/`
- Fix commits matched: 112 (time span over whole history, unfiltered)
- Files ranked: 100; fixed-but-unmeasured: 7
- State-based branch hotspots: 1620; multi-file fix blast rows: 107
- Branch-coverage resultset: present
- Method: vendored bugspots ([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) x SimpleCov branch gap; method gaps use Decomplex detector scores (see [docs/agents/design.md](docs/agents/design.md))
