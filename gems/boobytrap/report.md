# Boobytrap Report

> Defect-risk hotspots: recurring bug-fix locality (bugspots, time-decayed) x branch-coverage gap.
> A ranking to triage **top-down**, never a verdict. A
> hotspot is "the code most likely to be a bug source,"
> not "a bug."

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Hotspots (101)](#hotspots-101)
- [Mostly Uncovered Methods (61)](#mostly-uncovered-methods-61)
- [State-Based Branch Hotspots (1639)](#statebased-branch-hotspots-1639)
- [Multi-File Fix Blast Radius (108)](#multifile-fix-blast-radius-108)
- [Fixed But Unmeasured (7)](#fixed-but-unmeasured-7)
- [Run Summary](#run-summary)

## Project Prioritization
- The single highest-risk file is **`src/mir/mir.rb`** (hotspot=0.2191: fix_norm=1.0, branch gap=21.9%).
- 3 file(s) are within 50% of the top score (hotspot >= 0.1096); triage those first.
- Highest state-based branch hotspot: `src/ast/ast.rb:initialize` (score=737.26, state branches=21, fix_norm=0.697, branch gap=14.9%).
- Highest multi-file fix blast radius: `src/mir/mir_lowering.rb` (score=36.689, avg files/fix=69.03, max=1828).

## Hotspots (101)
_normalized fix-churn x branch-gap; highest = most likely defect source._

| # | file | hotspot | fix_norm | branch gap | uncovered/total |
|---|------|---------|----------|-----------|-----------------|
| 1 | `src/mir/mir.rb` | 0.2191 | 1.0 | 21.9% | 55/251 |
| 2 | `src/mir/lower/pipeline/pipeline_records.rb` | 0.1564 | 0.313 | 50.0% | 1/2 |
| 3 | `src/mir/fiber_ctx_builder.rb` | 0.1217 | 0.602 | 20.2% | 19/94 |
| 4 | `src/mir/mir_lowering.rb` | 0.1041 | 0.96 | 10.8% | 114/1051 |
| 5 | `src/ast/ast.rb` | 0.1041 | 0.697 | 14.9% | 56/375 |
| 6 | `src/mir/lowering/functions.rb` | 0.1039 | 0.519 | 20.0% | 119/595 |
| 7 | `src/semantic/bg_capture_classifier.rb` | 0.0995 | 0.313 | 31.8% | 7/22 |
| 8 | `src/mir/mir_checker.rb` | 0.0972 | 0.744 | 13.1% | 107/819 |
| 9 | `src/mir/lowering/variables.rb` | 0.0954 | 0.745 | 12.8% | 51/398 |
| 10 | `src/mir/cleanup_classifier.rb` | 0.0916 | 0.455 | 20.1% | 116/576 |
| 11 | `src/semantic/escape_analysis.rb` | 0.0843 | 0.457 | 18.4% | 99/537 |
| 12 | `src/mir/lowering/capabilities.rb` | 0.0795 | 0.413 | 19.3% | 47/244 |
| 13 | `src/ast/std_lib.rb` | 0.0734 | 0.323 | 22.7% | 5/22 |
| 14 | `src/backends/mir_emitter.rb` | 0.07 | 0.613 | 11.4% | 75/657 |
| 15 | `src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb` | 0.0628 | 0.575 | 10.9% | 20/183 |
| 16 | `src/annotator/annotator.rb` | 0.0528 | 0.317 | 16.7% | 8/48 |
| 17 | `src/mir/lowering/concurrency.rb` | 0.0496 | 0.347 | 14.3% | 35/245 |
| 18 | `src/mir/mir_pass.rb` | 0.0495 | 0.284 | 17.5% | 48/275 |
| 19 | `src/mir/lowering/expressions.rb` | 0.0476 | 0.297 | 16.0% | 101/631 |
| 20 | `src/mir/hoist.rb` | 0.0457 | 0.325 | 14.1% | 66/469 |
| 21 | `src/mir/lower/pipeline/pipeline_materializer.rb` | 0.0419 | 0.321 | 13.0% | 6/46 |
| 22 | `src/mir/test_lowering.rb` | 0.0401 | 0.3 | 13.3% | 6/45 |
| 23 | `src/mir/fsm_transform/recursive_splitter.rb` | 0.037 | 0.169 | 22.0% | 18/82 |
| 24 | `src/semantic/concurrency_checks.rb` | 0.0368 | 0.137 | 26.9% | 14/52 |
| 25 | `src/mir/lower/pipeline/pipeline_host.rb` | 0.0341 | 0.313 | 10.9% | 6/55 |
| 26 | `src/semantic/capture_strategy.rb` | 0.0324 | 0.313 | 10.3% | 6/58 |
| 27 | `src/mir/fsm_transform/segments.rb` | 0.0324 | 0.169 | 19.2% | 14/73 |
| 28 | `src/mir/fsm_transform/emit.rb` | 0.0294 | 0.275 | 10.7% | 26/243 |
| 29 | `src/annotator/helpers/effects.rb` | 0.0258 | 0.305 | 8.5% | 23/272 |
| 30 | `src/annotator/domains/errors.rb` | 0.0198 | 0.169 | 11.8% | 20/170 |
| 31 | `src/mir/lowering/control_flow.rb` | 0.0184 | 0.101 | 18.2% | 61/335 |
| 32 | `src/mir/fsm_lowering.rb` | 0.0183 | 0.069 | 26.4% | 33/125 |
| 33 | `src/mir/control_flow.rb` | 0.0178 | 0.125 | 14.2% | 73/514 |
| 34 | `src/annotator/helpers/with_match_check.rb` | 0.0156 | 0.143 | 10.9% | 11/101 |
| 35 | `src/mir/fsm_transform/suspend_resolvers.rb` | 0.0136 | 0.333 | 4.1% | 2/49 |
| 36 | `src/mir/lower/pipeline/pipeline_range_lowerer.rb` | 0.0104 | 0.093 | 11.2% | 14/125 |
| 37 | `src/annotator/domains/control_flow.rb` | 0.0092 | 0.065 | 14.2% | 33/232 |
| 38 | `src/annotator/phases/body_analysis.rb` | 0.0074 | 0.137 | 5.5% | 3/55 |
| 39 | `src/ast/fixable_error.rb` | 0.0041 | 0.011 | 35.7% | 5/14 |
| 40 | `src/mir/lowering/literals.rb` | 0.0039 | 0.048 | 8.2% | 5/61 |

- ...(+61 more)

## Mostly Uncovered Methods (61)
_non-trivial methods (`>=5` executable lines) with very low line coverage; risk = missed lines x gap, plus Decomplex detector score, instance-state writes, and dark branches._

- Completely uncovered: 3
- <=10% covered: 11
- <=20% covered: 61
- <=50% covered: 358

| # | method | risk | covered | missed | decomplex | findings | writes | dark branches |
|---|--------|------|---------|--------|-----------|----------|--------|---------------|
| 1 | `src/backends/fsm_wrapper_emitter.rb:401` `render_tail` | 66.47 | 13/86 | 73 | 3 | 2 | 0 | 0 |
| 2 | `src/mir/lower/pipeline/pipeline_range_lowerer.rb:699` `lower_range_fold_observable` | 49.41 | 13/70 | 57 | 2 | 2 | 0 | 0 |
| 3 | `src/semantic/pass_work_profiler.rb:337` `to_csv` | 43.98 | 5/52 | 47 | 1 | 2 | 0 | 0 |
| 4 | `src/semantic/pass_work_profiler.rb:410` `to_table` | 43.98 | 5/52 | 47 | 1 | 2 | 0 | 0 |
| 5 | `src/tools/completions.rb:43` `bash` | 35.1 | 2/39 | 37 | 0 | 0 | 0 | 0 |
| 6 | `src/backends/mir_emitter.rb:1972` `emit_thunk_trampoline` | 31.8 | 9/45 | 36 | 2 | 1 | 0 | 0 |
| 7 | `src/backends/mir_emitter.rb:1314` `emit_fallible_lock_acquire_expr` | 30.78 | 5/32 | 27 | 5 | 3 | 0 | 1 |
| 8 | `src/mir/fsm_transform/context.rb:41` `with_extra_ctx_fields` | 27.13 | 2/31 | 29 | 0 | 0 | 0 | 0 |
| 9 | `src/mir/mir_lowering.rb:398` `initialize` | 24.15 | 2/27 | 25 | 0 | 0 | 1 | 0 |
| 10 | `src/mir/lower/pipeline/pipeline_range_lowerer.rb:587` `min_max_fold_plan` | 24.05 | 4/29 | 25 | 1 | 1 | 1 | 0 |
| 11 | `src/tools/clear_build_support.rb:87` `build_signature` | 22.2 | 2/20 | 18 | 4 | 3 | 0 | 0 |
| 12 | `src/mir/control_flow.rb:1768` `statement_like_expression_container?` | 20.74 | 2/17 | 15 | 5 | 16 | 0 | 0 |
| 13 | `src/tools/completions.rb:91` `zsh` | 20.35 | 3/26 | 23 | 0 | 0 | 0 | 0 |
| 14 | `src/mir/lower/pipeline/pipeline_range_lowerer.rb:552` `average_fold_plan` | 18.43 | 3/21 | 18 | 2 | 1 | 0 | 0 |
| 15 | `src/backends/mir_emitter.rb:1240` `wrap_conflict_handler` | 17.46 | 5/26 | 21 | 0 | 0 | 0 | 1 |
| 16 | `src/mir/lowering/expressions.rb:817` `smooth_snapshot_stmts` | 17.1 | 3/15 | 12 | 4 | 4 | 0 | 3 |
| 17 | `src/mir/mir_lowering.rb:2992` `union_variant_lowering_facts` | 17.0 | 0/8 | 8 | 6 | 3 | 0 | 0 |
| 18 | `src/mir/mir_checker.rb:277` `same_state?` | 16.36 | 2/11 | 9 | 0 | 0 | 9 | 0 |
| 19 | `src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb:130` `stream_allocating_args` | 15.77 | 2/15 | 13 | 3 | 1 | 0 | 0 |
| 20 | `src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb:147` `stream_each_args` | 15.77 | 2/15 | 13 | 3 | 1 | 0 | 0 |
| 21 | `src/mir/fsm_transform/recursive_splitter.rb:132` `add_synthetic_field` | 15.7 | 1/5 | 4 | 7 | 4 | 1 | 2 |
| 22 | `src/mir/lowering/capabilities.rb:1049` `default_failure_action` | 15.58 | 1/12 | 11 | 3 | 1 | 0 | 2 |
| 23 | `src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb:1222` `shard_capture_fields` | 15.33 | 2/12 | 10 | 4 | 3 | 0 | 2 |
| 24 | `src/mir/lower/pipeline/pipeline_batch_window_lowerer.rb:274` `bc_materialized_window_stmts` | 15.21 | 2/19 | 17 | 0 | 0 | 0 | 0 |
| 25 | `src/mir/lower/pipeline/pipeline_lowering_bridge.rb:122` `pipeline_alloc_mark_fact` | 14.76 | 4/21 | 17 | 0 | 0 | 1 | 0 |
| 26 | `src/mir/mir.rb:4461` `child_exprs` | 14.67 | 1/6 | 5 | 7 | 20 | 0 | 0 |
| 27 | `src/mir/fsm_transform/emit.rb:117` `with_facts` | 14.22 | 2/18 | 16 | 0 | 0 | 0 | 0 |
| 28 | `src/mir/lower/pipeline/pipeline_batch_window_lowerer.rb:304` `bc_materialized_loop_body` | 14.22 | 2/18 | 16 | 0 | 0 | 0 | 0 |
| 29 | `src/backends/mir_emitter.rb:2492` `emit_test_preamble` | 13.81 | 2/13 | 11 | 3 | 1 | 0 | 0 |
| 30 | `src/mir/mir.rb:4485` `ownership_effect` | 13.2 | 1/5 | 4 | 6 | 11 | 0 | 2 |
| 31 | `src/mir/fsm_transform/emit.rb:458` `prior_lock_release_stmts` | 12.31 | 2/13 | 11 | 2 | 2 | 0 | 0 |
| 32 | `src/mir/fsm_transform/recursive_splitter.rb:550` `lock_release_stmts` | 12.31 | 2/13 | 11 | 2 | 1 | 0 | 0 |
| 33 | `src/mir/fsm_lowering.rb:531` `lock_error_set_error_stmt` | 12.25 | 2/16 | 14 | 0 | 0 | 0 | 0 |
| 34 | `src/mir/mir_lowering.rb:1233` `append_ownership_finalized_node!` | 12.2 | 1/5 | 4 | 6 | 20 | 0 | 0 |
| 35 | `src/backends/mir_emitter.rb:2025` `emit_thunk_return_or_pop` | 11.86 | 2/11 | 9 | 3 | 1 | 0 | 0 |
| 36 | `src/mir/mir_lowering.rb:3782` `pipeline_host` | 11.5 | 0/10 | 10 | 1 | 3 | 0 | 0 |
| 37 | `src/mir/mir_lowering.rb:1069` `construct_lowered_body` | 11.5 | 0/7 | 7 | 3 | 2 | 0 | 0 |
| 38 | `src/lsp/server.rb:142` `handle_initialize` | 11.27 | 2/15 | 13 | 0 | 0 | 0 | 0 |
| 39 | `src/mir/lowering/capabilities.rb:993` `single_mutable_snapshot_txn` | 11.1 | 3/15 | 12 | 1 | 1 | 0 | 0 |
| 40 | `src/mir/mir_pass.rb:222` `finalized_runtime_input?` | 10.9 | 2/10 | 8 | 3 | 2 | 0 | 0 |

- ...(+21 more)

## State-Based Branch Hotspots (1639)
_Decomplex state-based branch density joined with fix-cache and branch coverage. These are branches over mutable/object state that are uncovered and/or historically fixed._

| # | method | risk | state branches | refs | fix_norm | branch gap | line gap | dark branches |
|---|--------|------|----------------|------|----------|------------|----------|---------------|
| 1 | `src/ast/ast.rb:initialize` | 737.26 | 21 | `rt.nil? | self[:bindings].nil? | self[:body].nil? | self[:borrowed].nil? | self[:capabilities].nil?` | 0.697 | 14.9% | 0.0% | 0 |
| 2 | `src/mir/cleanup_classifier.rb:classify_binding` | 430.24 | 13 | `facts.borrow_provenance | facts.container_borrow | facts.empty_initializer | facts.heap_storage | facts.mutable_binding_mutated` | 0.455 | 20.1% | 11.1% | 1 |
| 3 | `src/mir/mir_lowering.rb:mir_cast` | 367.17 | 10 | `from_t.dynamic? | from_t.fixed? | from_t.float? | from_t.fn_type? | from_t.integer?` | 0.96 | 10.8% | 30.0% | 0 |
| 4 | `src/mir/mir_checker.rb:check_fsm_structure!` | 289.2 | 10 | `cap.cleanup_at | cap.name | cleanup_step.nil? | fact.move_guarded | fact.name` | 0.744 | 13.1% | 46.7% | 0 |
| 5 | `src/mir/lowering/variables.rb:lower_var_decl_init` | 283.48 | 12 | `ft.fixed_soa? | ft.list_collection? | ft.pool? | ft.set_collection? | node.value` | 0.745 | 12.8% | 20.0% | 0 |
| 6 | `src/mir/lowering/functions.rb:lower_intrinsic` | 268.34 | 11 | `alloc_metadata.empty? | consumed_operands.empty? | entry.intrinsic_bc? | node.args | node.args.first` | 0.519 | 20.0% | 33.3% | 1 |
| 7 | `src/tools/formatter.rb:needs_space?` | 243.21 | 27 | `@generic_bracket_indices | @struct_lit_brace_indices | @struct_lit_brace_indices.empty? | a.raw | a.type` | 0.007 | 6.5% | 20.0% | 0 |
| 8 | `src/mir/fsm_transform/emit.rb:build_recursive` | 228.65 | 12 | `all_promoted.any? | ast_stmts.empty? | descriptor.nil? | lowered_mir.nil? | out.nil?` | 0.275 | 10.7% | 12.5% | 0 |
| 9 | `src/mir/mir_lowering.rb:owned_sink_plan` | 212.91 | 7 | `source.borrowed_union_sink | source.existing_owned_source | source.satisfies_rc_sink? | ti.any_rc? | ti.collection_value?` | 0.96 | 10.8% | 75.0% | 0 |
| 10 | `src/annotator/domains/execution_boundaries.rb:visit_NextExpr` | 206.94 | 15 | `async_shape.payload_type | async_shape.promise? | async_shape.shared_promise? | node.expr | promise_type.bounded_stream?` | 0.0 | 6.1% | 0.0% | 0 |
| 11 | `src/tools/formatter.rb:expand_if_while_for` | 205.89 | 22 | `out.length | t.raw | t.type | tj.raw | tj.type` | 0.007 | 6.5% | 9.1% | 0 |
| 12 | `src/annotator/domains/lifetimes.rb:finalize_scope` | 177.77 | 15 | `branch.nil? | info.mutable | info.mutated | info.ownership_kind | info.read` | 0.0 | 18.5% | 0.0% | 0 |
| 13 | `src/mir/lowering/expressions.rb:lower_copy` | 174.67 | 8 | `dst_ti.collection? | dst_ti.direct_indexable_collection? | dst_ti.string? | ti.any_rc? | ti.any_sync?` | 0.297 | 16.0% | 10.3% | 2 |
| 14 | `src/mir/lowering/control_flow.rb:for_each_loop_stmt` | 160.58 | 8 | `ct.bounded_stream? | ct.dynamic_field_array? | ct.dynamic_stream? | ct.fixed_soa? | ct.inf_stream?` | 0.101 | 18.2% | 38.5% | 2 |
| 15 | `src/mir/mir_checker.rb:check_fsm_destroy_cleanup_action!` | 157.01 | 7 | `action.name | action.source_kind | action.target | close_plan.empty? | entry.alloc` | 0.744 | 13.1% | 62.5% | 0 |
| 16 | `src/mir/mir_checker.rb:cleanup_source_owns_value?` | 151.89 | 5 | `MIR::OwnershipEffect.of(init).produces_owned | cleanup.cleanup_entry | cleanup.cleanup_entry.match_as? | init.ownership_consumption | init.ownership_consumption.names` | 0.744 | 13.1% | 25.0% | 4 |
| 17 | `src/mir/lowering/functions.rb:ast_expr_produces_heap?` | 146.96 | 8 | `node.borrow_provenance? | node.heap_storage? | node.needs_heap_create | node.op | node.rodata_provenance?` | 0.519 | 20.0% | 5.9% | 8 |
| 18 | `src/annotator/domains/errors.rb:visit_ReturnNode` | 141.11 | 9 | `expected.heap_return_storage? | expected.plain_return_payload_type | inline_bg_sources.any? | raw_value.nil? | value.full_type!(context: "return expression storage").requires_move?` | 0.169 | 11.8% | 0.0% | 0 |
| 19 | `src/annotator/domains/execution_boundaries.rb:visit_BgBlock` | 140.08 | 12 | `analysis.has_affine_locked | analysis.has_local | analysis.has_sharded | analysis_result.has_local | analysis_result.has_non_escaping_capture` | 0.0 | 6.1% | 0.0% | 0 |
| 20 | `src/mir/fiber_ctx_builder.rb:rc_payload_zig_type` | 133.99 | 7 | `payload.any_sync? | payload.atomic? | payload.indirect? | payload.locked? | payload.map?` | 0.602 | 20.2% | 7.1% | 4 |
| 21 | `src/mir/mir_lowering.rb:lower_union_def` | 130.81 | 6 | `de.kind | deinit_stmts.any? | fact.inline_struct | helper_structs.any? | node.type_params` | 0.96 | 10.8% | 67.2% | 0 |
| 22 | `src/annotator/helpers/function_analysis.rb:visit_FunctionDef` | 125.21 | 12 | `candidate_snap_types.size | catch_body_scan.references_snapshot | fn_type_params.any? | node.name | node.reentrance_kind` | 0.015 | 14.2% | 0.0% | 0 |
| 23 | `src/mir/hoist.rb:collect_stmt_hoists!` | 122.43 | 9 | `arg.value | right_type.collection? | stmt.expr | stmt.name | stmt.value` | 0.325 | 14.1% | 12.5% | 0 |
| 24 | `src/mir/mir_checker.rb:check_fn!` | 120.46 | 8 | `node.body | node.body.ptr | node.fn_def | node.init | node.object_id` | 0.744 | 13.1% | 9.1% | 0 |
| 25 | `src/annotator/domains/member_access.rb:visit_StructLit` | 119.84 | 10 | `field_names.empty? | missing.any? | node.fields | node.fields.empty? | node.fields.length` | 0.008 | 8.1% | 0.0% | 0 |
| 26 | `src/mir/lowering/expressions.rb:lower_identifier` | 116.85 | 8 | `capability_state.atomic_emit_raw | node.atomic_borrow | node.fn_ref | node.heap_dupe_result | node.name` | 0.297 | 16.0% | 37.5% | 1 |
| 27 | `src/annotator/domains/expressions.rb:visit_CapabilityWrap` | 116.42 | 10 | `node.atomic? | node.atomic_ptr? | node.capability? | node.indirect? | node.layout` | 0.0 | 5.8% | 0.0% | 0 |
| 28 | `src/annotator/helpers/function_analysis.rb:resolve_call` | 114.78 | 11 | `arg.full_type!(context: "extern argument").soa? | call_type.error_union? | comptime_type_args.any? | entry.storage | node.args` | 0.015 | 14.2% | 0.0% | 0 |
| 29 | `src/mir/lowering/functions.rb:lower_extern_struct` | 111.58 | 7 | `items.length | mod_parts.first | mod_parts[1..].any? | node.as_type | node.field_decls` | 0.519 | 20.0% | 8.3% | 1 |
| 30 | `src/ast/std_lib.rb:(top-level)` | 107.16 | 11 | `arg_type.numeric? | arg_type.string? | elem.resolved | key_type.numeric? | key_type.string?` | 0.323 | 22.7% | 0.0% | 0 |
| 31 | `src/annotator/helpers/function_analysis.rb:declare_and_verify_params` | 104.35 | 10 | `fams.empty? | field_names.empty? | missing.any? | param.default | param.sync` | 0.015 | 14.2% | 0.0% | 0 |
| 32 | `src/mir/lowering/functions.rb:lower_function_def` | 102.08 | 6 | `final_zig_type.error_union? | node.can_fail | node.can_fail.nil? | node.mutual_thunk_plan | node.thunk_plan` | 0.519 | 20.0% | 16.7% | 0 |
| 33 | `src/tools/doctor.rb:diff_mvcc` | 101.44 | 7 | `after.empty? | before.empty? | d[:after_retries].positive? | d[:after_retries].zero? | d[:before_retries].positive?` | 0.0 | 20.8% | 33.3% | 0 |
| 34 | `src/semantic/escape_analysis.rb:expr_produces_heap?` | 96.63 | 7 | `node.borrow_provenance? | node.heap_storage? | node.op | node.rodata_provenance? | node.storage` | 0.457 | 18.4% | 0.0% | 0 |
| 35 | `src/mir/cleanup_classifier.rb:classify_collection` | 96.17 | 7 | `ti.any_rc? | ti.fixed_soa? | ti.list_collection? | ti.map? | ti.pool?` | 0.455 | 20.1% | 11.1% | 1 |
| 36 | `src/mir/lowering/expressions.rb:lower_or_rescue` | 93.62 | 14 | `ex.message | facts.left_is_error | facts.target | node.right` | 0.297 | 16.0% | 11.1% | 0 |
| 37 | `src/mir/lowering/expressions.rb:index_access_value` | 93.62 | 7 | `map_ft.numeric_map? | map_ft.sharded? | map_ft.striped? | plan.optional? | plan.target_ast.metatype` | 0.297 | 16.0% | 11.1% | 0 |
| 38 | `src/tools/doctor.rb:diff_locks` | 92.99 | 7 | `after.empty? | before.empty? | d[:after_wait].positive? | d[:after_wait].zero? | d[:before_wait].positive?` | 0.0 | 20.8% | 22.2% | 0 |
| 39 | `src/mir/lowering/functions.rb:lower_method_call` | 90.32 | 5 | `node.args | node.extern_call | node.generic_type_args | node.generic_type_args.any? | node.name` | 0.519 | 20.0% | 40.0% | 1 |
| 40 | `src/ast/type.rb:accepts?` | 87.77 | 8 | `other_type.any? | other_type.byte? | other_type.error_union? | other_type.map? | other_type.numeric?` | 0.002 | 9.5% | 0.0% | 0 |

- ...(+1599 more)

## Multi-File Fix Blast Radius (108)
_Time-decayed fix commits where a file repeatedly changes with many other files. High rows are bug fixes whose blast radius is cross-module, not local._

| # | file | score | fixes | avg files/fix | max files | top co-touched files |
|---|------|-------|-------|---------------|-----------|----------------------|
| 1 | `src/mir/mir_lowering.rb` | 36.689 | 32 | 69.03 | 1828 | spec/mir_gap_burn_spec.rb (1.42); src/mir/mir.rb (1.171); src/mir/lowering/variables.rb (1.158); src/mir/mir_checker.rb (1.157); zig/runtime/runtime-header.zig (0.989) |
| 2 | `src/mir/mir.rb` | 33.651 | 12 | 167.92 | 1828 | src/mir/mir_lowering.rb (1.171); src/mir/mir_checker.rb (1.157); src/mir/lowering/variables.rb (1.157); spec/mir_gap_burn_spec.rb (1.156); zig/runtime/runtime-header.zig (0.988) |
| 3 | `src/mir/lowering/variables.rb` | 29.415 | 6 | 27.83 | 36 | src/mir/mir_lowering.rb (1.158); src/mir/mir.rb (1.157); src/mir/mir_checker.rb (1.157); spec/mir_gap_burn_spec.rb (1.156); spec/transpiler_spec.rb (0.989) |
| 4 | `src/mir/mir_checker.rb` | 29.401 | 6 | 327.33 | 1828 | src/mir/mir.rb (1.157); src/mir/mir_lowering.rb (1.157); src/mir/lowering/variables.rb (1.157); spec/mir_gap_burn_spec.rb (1.156); spec/transpiler_spec.rb (0.988) |
| 5 | `src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb` | 24.434 | 3 | 27.67 | 30 | spec/mir_gap_burn_spec.rb (0.894); src/mir/mir_lowering.rb (0.894); src/ast/ast.rb (0.749); src/mir/lowering/variables.rb (0.631); src/mir/mir.rb (0.631) |
| 6 | `src/ast/ast.rb` | 22.67 | 13 | 151.08 | 1828 | src/mir/mir_lowering.rb (0.786); spec/mir_gap_burn_spec.rb (0.774); src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb (0.749); src/mir/mir.rb (0.524); src/mir/mir_checker.rb (0.511) |
| 7 | `src/mir/fiber_ctx_builder.rb` | 21.745 | 6 | 321.0 | 1828 | src/mir/mir_lowering.rb (0.936); spec/pipeline_backend_coverage_spec.rb (0.907); spec/mir_gap_burn_spec.rb (0.907); src/mir/lowering/functions.rb (0.762); src/mir/mir.rb (0.645) |
| 8 | `src/mir/lowering/functions.rb` | 18.29 | 7 | 22.29 | 36 | src/mir/mir_lowering.rb (0.789); spec/mir_gap_burn_spec.rb (0.787); spec/pipeline_backend_coverage_spec.rb (0.762); src/mir/fiber_ctx_builder.rb (0.762); src/mir/lowering/variables.rb (0.527) |
| 9 | `src/semantic/escape_analysis.rb` | 17.546 | 3 | 17.0 | 30 | spec/annotator_gap_burndown_spec.rb (0.699); spec/mir_gap_burn_spec.rb (0.699); src/mir/mir.rb (0.499); benchmarks/clear-only/tail_call_loop/README.md (0.487); benchmarks/clear-only/tail_call_loop/bench_tail_call.cht (0.487) |
| 10 | `src/backends/mir_emitter.rb` | 15.98 | 2 | 17.5 | 30 | benchmarks/clear-only/tail_call_loop/README.md (0.487); benchmarks/clear-only/tail_call_loop/bench_tail_call.cht (0.487); benchmarks/concurrent/10_shard_vs_locked/TIMEOUT (0.487); spec/allocation_strategy_spec.rb (0.487); spec/annotator_gap_burndown_spec.rb (0.487) |
| 11 | `src/mir/fsm_transform/suspend_resolvers.rb` | 14.582 | 4 | 477.25 | 1828 | src/mir/mir_lowering.rb (0.517); spec/fsm_suspend_resolvers_spec.rb (0.516); spec/transpiler_spec.rb (0.488); spec/vm_bg_capture_bugs_spec.rb (0.488); src/mir/mir.rb (0.488) |
| 12 | `src/mir/fsm_ops.rb` | 14.122 | 2 | 929.0 | 1828 | benchmarks/clear-only/tail_call_loop/README.md (0.487); benchmarks/clear-only/tail_call_loop/bench_tail_call.cht (0.487); spec/allocation_strategy_spec.rb (0.487); spec/capture_strategy_spec.rb (0.487); spec/fsm_cleanup_invariant_spec.rb (0.487) |
| 13 | `src/mir/lower/pipeline/pipeline_host.rb` | 14.111 | 1 | 30.0 | 30 | benchmarks/clear-only/tail_call_loop/README.md (0.487); benchmarks/clear-only/tail_call_loop/bench_tail_call.cht (0.487); benchmarks/concurrent/10_shard_vs_locked/TIMEOUT (0.487); spec/allocation_strategy_spec.rb (0.487); spec/annotator_gap_burndown_spec.rb (0.487) |
| 14 | `src/mir/lower/pipeline/pipeline_lowering_bridge.rb` | 14.111 | 1 | 30.0 | 30 | benchmarks/clear-only/tail_call_loop/README.md (0.487); benchmarks/clear-only/tail_call_loop/bench_tail_call.cht (0.487); benchmarks/concurrent/10_shard_vs_locked/TIMEOUT (0.487); spec/allocation_strategy_spec.rb (0.487); spec/annotator_gap_burndown_spec.rb (0.487) |
| 15 | `src/mir/lower/pipeline/pipeline_records.rb` | 14.111 | 1 | 30.0 | 30 | benchmarks/clear-only/tail_call_loop/README.md (0.487); benchmarks/clear-only/tail_call_loop/bench_tail_call.cht (0.487); benchmarks/concurrent/10_shard_vs_locked/TIMEOUT (0.487); spec/allocation_strategy_spec.rb (0.487); spec/annotator_gap_burndown_spec.rb (0.487) |
| 16 | `src/semantic/bg_capture_classifier.rb` | 14.111 | 1 | 30.0 | 30 | benchmarks/clear-only/tail_call_loop/README.md (0.487); benchmarks/clear-only/tail_call_loop/bench_tail_call.cht (0.487); benchmarks/concurrent/10_shard_vs_locked/TIMEOUT (0.487); spec/allocation_strategy_spec.rb (0.487); spec/annotator_gap_burndown_spec.rb (0.487) |
| 17 | `src/semantic/capture_strategy.rb` | 14.111 | 1 | 30.0 | 30 | benchmarks/clear-only/tail_call_loop/README.md (0.487); benchmarks/clear-only/tail_call_loop/bench_tail_call.cht (0.487); benchmarks/concurrent/10_shard_vs_locked/TIMEOUT (0.487); spec/allocation_strategy_spec.rb (0.487); spec/annotator_gap_burndown_spec.rb (0.487) |
| 18 | `src/mir/cleanup_classifier.rb` | 11.958 | 5 | 21.0 | 36 | src/mir/mir_lowering.rb (0.515); src/mir/mir.rb (0.514); spec/transpiler_spec.rb (0.502); src/ast/std_lib.rb (0.502); src/mir/lowering/functions.rb (0.502) |
| 19 | `src/mir/lowering/concurrency.rb` | 11.39 | 7 | 20.71 | 36 | src/mir/mir_lowering.rb (0.445); spec/mir_lowering_spec.rb (0.438); src/mir/fiber_ctx_builder.rb (0.436); spec/concurrency_spec.rb (0.409); examples/minivm/bc_emitter.rb (0.407) |
| 20 | `src/ast/std_lib.rb` | 11.087 | 6 | 324.5 | 1828 | src/mir/mir_lowering.rb (0.502); spec/transpiler_spec.rb (0.502); src/mir/cleanup_classifier.rb (0.502); src/mir/lowering/functions.rb (0.502); src/mir/lowering/variables.rb (0.502) |
| 21 | `src/mir/lower/pipeline/pipeline_materializer.rb` | 11.0 | 1 | 23.0 | 23 | benchmarks/concurrent/02_concurrent_search/bench.cht (0.5); benchmarks/concurrent/18_atomic_counter/bench.cht (0.5); benchmarks/runner.rb (0.5); examples/minivm/vm-tests/values/string_eq.stack.bc (0.5); examples/minivm/vm-tests/values/string_loop_temp.stack.bc (0.5) |
| 22 | `src/annotator/annotator.rb` | 10.261 | 5 | 22.0 | 31 | examples/minivm/register_bc_emitter.rb (0.486); sorbet/rbi/clear-attr-accessors.rbi (0.475); spec/mir_gap_burn_spec.rb (0.475); src/annotator/helpers/effects.rb (0.475); examples/minivm/bc_emitter.rb (0.274) |
| 23 | `src/annotator/helpers/effects.rb` | 9.96 | 2 | 21.5 | 26 | examples/minivm/register_bc_emitter.rb (0.475); sorbet/rbi/clear-attr-accessors.rbi (0.475); spec/mir_gap_burn_spec.rb (0.475); src/annotator/annotator.rb (0.475); examples/minivm/bc_emitter.rb (0.262) |
| 24 | `src/mir/lowering/capabilities.rb` | 8.722 | 9 | 15.78 | 36 | src/mir/mir.rb (0.518); spec/mir_lowering_spec.rb (0.517); gems/decomplex/report.md (0.377); gems/espalier/report.md (0.377); gems/nil-kill/report.md (0.377) |
| 25 | `src/mir/hoist.rb` | 8.402 | 12 | 17.17 | 36 | spec/mir_gap_burn_spec.rb (0.382); examples/minivm/register_bc_emitter.rb (0.368); src/mir/lowering/concurrency.rb (0.242); src/mir/mir_pass.rb (0.24); src/semantic/escape_analysis.rb (0.225) |
| 26 | `src/mir/fsm_transform/emit.rb` | 7.24 | 7 | 276.29 | 1828 | src/mir/mir_lowering.rb (0.293); spec/mir_lowering_spec.rb (0.293); src/mir/lowering/concurrency.rb (0.293); src/mir/fiber_ctx_builder.rb (0.292); sorbet/rbi/clear-attr-accessors.rbi (0.273) |
| 27 | `src/ast/diagnostic_registry.rb` | 6.621 | 4 | 472.75 | 1828 | spec/concurrency_spec.rb (0.264); spec/mir_lowering_spec.rb (0.264); src/mir/fsm_transform/emit.rb (0.264); src/mir/mir_lowering.rb (0.264); src/mir/lowering/concurrency.rb (0.264) |
| 28 | `src/mir/fsm_transform/recursive_splitter.rb` | 6.572 | 2 | 927.0 | 1828 | examples/minivm/bc_emitter.rb (0.262); sorbet/rbi/clear-attr-accessors.rbi (0.262); spec/concurrency_spec.rb (0.262); spec/fsm_classifier_spec.rb (0.262); spec/fsm_recursive_splitter_spec.rb (0.262) |
| 29 | `src/mir/fsm_transform/segments.rb` | 6.572 | 2 | 927.0 | 1828 | examples/minivm/bc_emitter.rb (0.262); sorbet/rbi/clear-attr-accessors.rbi (0.262); spec/concurrency_spec.rb (0.262); spec/fsm_classifier_spec.rb (0.262); spec/fsm_recursive_splitter_spec.rb (0.262) |
| 30 | `src/annotator/domains/errors.rb` | 6.561 | 1 | 26.0 | 26 | examples/minivm/bc_emitter.rb (0.262); examples/minivm/register_bc_emitter.rb (0.262); sorbet/rbi/clear-attr-accessors.rbi (0.262); spec/concurrency_spec.rb (0.262); spec/fsm_classifier_spec.rb (0.262) |
| 31 | `src/annotator/phases/declaration_index.rb` | 6.561 | 1 | 26.0 | 26 | examples/minivm/bc_emitter.rb (0.262); examples/minivm/register_bc_emitter.rb (0.262); sorbet/rbi/clear-attr-accessors.rbi (0.262); spec/concurrency_spec.rb (0.262); spec/fsm_classifier_spec.rb (0.262) |
| 32 | `src/mir/mir_pass.rb` | 4.764 | 14 | 143.86 | 1828 | sorbet/rbi/clear-attr-accessors.rbi (0.406); src/mir/hoist.rb (0.24); spec/mir_gap_burn_spec.rb (0.237); src/ast/ast.rb (0.218); src/annotator/annotator.rb (0.213) |
| 33 | `src/mir/lowering/control_flow.rb` | 3.973 | 3 | 26.33 | 36 | src/mir/hoist.rb (0.157); src/mir/lowering/capabilities.rb (0.157); examples/minivm/bc_emitter.rb (0.156); examples/minivm/register_bc_emitter.rb (0.156); spec/concurrency_spec.rb (0.146) |
| 34 | `src/ast/schemas.rb` | 3.773 | 2 | 927.5 | 1828 | examples/minivm/bc_emitter.rb (0.145); spec/capabilities_spec.rb (0.145); spec/concurrency_spec.rb (0.145); spec/fsm_classifier_spec.rb (0.145); spec/fsm_wrapper_emitter_spec.rb (0.145) |
| 35 | `src/mir/lower/pipeline/pipeline_range_lowerer.rb` | 3.762 | 1 | 27.0 | 27 | examples/minivm/bc_emitter.rb (0.145); examples/minivm/register_bc_emitter.rb (0.145); spec/capabilities_spec.rb (0.145); spec/concurrency_spec.rb (0.145); spec/fsm_classifier_spec.rb (0.145) |
| 36 | `src/annotator/helpers/with_match_check.rb` | 3.483 | 2 | 13.0 | 17 | sorbet/rbi/clear-attr-accessors.rbi (0.223); examples/minivm/register_bc_emitter.rb (0.212); spec/annotator_gap_burndown_spec.rb (0.212); spec/gen_attr_rbi_spec.rb (0.212); spec/mir_gap_burn_spec.rb (0.212) |
| 37 | `src/annotator/phases/body_analysis.rb` | 3.399 | 1 | 17.0 | 17 | examples/minivm/register_bc_emitter.rb (0.212); sorbet/rbi/clear-attr-accessors.rbi (0.212); spec/annotator_gap_burndown_spec.rb (0.212); spec/gen_attr_rbi_spec.rb (0.212); spec/mir_gap_burn_spec.rb (0.212) |
| 38 | `src/semantic/concurrency_checks.rb` | 3.399 | 1 | 17.0 | 17 | examples/minivm/register_bc_emitter.rb (0.212); sorbet/rbi/clear-attr-accessors.rbi (0.212); spec/annotator_gap_burndown_spec.rb (0.212); spec/gen_attr_rbi_spec.rb (0.212); spec/mir_gap_burn_spec.rb (0.212) |
| 39 | `src/mir/lowering/expressions.rb` | 2.015 | 6 | 16.33 | 36 | .github/workflows/ci.yml (0.34); zig/lib/partitioned-map-test.zig (0.34); zig/partitioned-map-test.zig (0.34); src/mir/lowering/capabilities.rb (0.092); sorbet/rbi/clear-attr-accessors.rbi (0.09) |
| 40 | `src/README.md` | 1.886 | 2 | 918.0 | 1828 | spec/higher_order_spec.rb (0.268); zig/lib/data-structures.zig (0.268); zig/runtime/sharded-list-test.zig (0.268); zig/runtime/soa-list-test.zig (0.268); src/annotator/README.md (0.268) |

- ...(+68 more)

## Fixed But Unmeasured (7)
_files with recurring fixes but NO branch-coverage data -- recurring-fix code the corpus does not measure at all; itself a risk._

- `src/README.md` (fix_norm=0.172)
- `src/annotator/README.md` (fix_norm=0.172)
- `src/mir/README.md` (fix_norm=0.172)
- `src/annotator/helpers/intrinsic_emit.rb` (fix_norm=0.019)
- `src/annotator.rb` (fix_norm=0.0)
- `src/lsp/README.md` (fix_norm=0.0)
- `src/mir/thunk_transform.rb` (fix_norm=0.0)

## Run Summary
- Repo: `/home/yahn/cheat`
- Scope: `src/`
- Fix commits matched: 116 (time span over whole history, unfiltered)
- Files ranked: 101; fixed-but-unmeasured: 7
- State-based branch hotspots: 1639; multi-file fix blast rows: 108
- Branch-coverage resultset: present
- Method: vendored bugspots ([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) x SimpleCov branch gap; method gaps use Decomplex detector scores (see [docs/agents/design.md](docs/agents/design.md))
