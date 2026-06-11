# Boobytrap Report

> Defect-risk hotspots: recurring bug-fix locality (bugspots, time-decayed) x branch-coverage gap.
> A ranking to triage **top-down**, never a verdict. A
> hotspot is "the code most likely to be a bug source,"
> not "a bug."

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Hotspots (100)](#hotspots-100)
- [Mostly Uncovered Methods (5)](#mostly-uncovered-methods-5)
- [State-Based Branch Hotspots (1611)](#statebased-branch-hotspots-1611)
- [Multi-File Fix Blast Radius (107)](#multifile-fix-blast-radius-107)
- [Fixed But Unmeasured (7)](#fixed-but-unmeasured-7)
- [Run Summary](#run-summary)

## Project Prioritization
- The single highest-risk file is **`src/ast/diagnostic_registry.rb`** (hotspot=0.15: fix_norm=0.42, branch gap=35.7%).
- 16 file(s) are within 50% of the top score (hotspot >= 0.075); triage those first.
- Highest state-based branch hotspot: `src/ast/ast.rb:initialize` (score=867.47, state branches=21, fix_norm=1.0, branch gap=14.7%).
- Highest multi-file fix blast radius: `src/mir/mir_lowering.rb` (score=22.664, avg files/fix=71.87, max=1828).

## Hotspots (100)
_normalized fix-churn x branch-gap; highest = most likely defect source._

| # | file | hotspot | fix_norm | branch gap | uncovered/total |
|---|------|---------|----------|-----------|-----------------|
| 1 | `src/ast/diagnostic_registry.rb` | 0.15 | 0.42 | 35.7% | 5/14 |
| 2 | `src/ast/ast.rb` | 0.1475 | 1.0 | 14.7% | 55/373 |
| 3 | `src/mir/fiber_ctx_builder.rb` | 0.1472 | 0.726 | 20.3% | 30/148 |
| 4 | `src/annotator/annotator.rb` | 0.1393 | 0.801 | 17.4% | 8/46 |
| 5 | `src/mir/mir_pass.rb` | 0.1297 | 0.743 | 17.5% | 96/550 |
| 6 | `src/mir/lowering/concurrency.rb` | 0.1277 | 0.911 | 14.0% | 60/428 |
| 7 | `src/mir/hoist.rb` | 0.1227 | 0.872 | 14.1% | 66/469 |
| 8 | `src/mir/fsm_transform/emit.rb` | 0.1076 | 0.712 | 15.1% | 37/245 |
| 9 | `src/mir/lowering/functions.rb` | 0.1001 | 0.495 | 20.2% | 119/589 |
| 10 | `src/semantic/concurrency_checks.rb` | 0.0954 | 0.354 | 26.9% | 14/52 |
| 11 | `src/mir/fsm_transform/recursive_splitter.rb` | 0.095 | 0.418 | 22.7% | 20/88 |
| 12 | `src/mir/lowering/capabilities.rb` | 0.0938 | 0.479 | 19.6% | 94/480 |
| 13 | `src/mir/mir_lowering.rb` | 0.0874 | 0.842 | 10.4% | 279/2689 |
| 14 | `src/mir/fsm_transform/segments.rb` | 0.0802 | 0.418 | 19.2% | 14/73 |
| 15 | `src/semantic/escape_analysis.rb` | 0.08 | 0.375 | 21.4% | 117/548 |
| 16 | `src/mir/mir.rb` | 0.078 | 0.347 | 22.5% | 56/249 |
| 17 | `src/annotator/helpers/effects.rb` | 0.0653 | 0.772 | 8.5% | 46/544 |
| 18 | `src/mir/cleanup_classifier.rb` | 0.0645 | 0.352 | 18.3% | 99/540 |
| 19 | `src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb` | 0.0598 | 0.674 | 8.9% | 15/169 |
| 20 | `src/mir/control_flow.rb` | 0.0569 | 0.33 | 17.2% | 91/528 |
| 21 | `src/mir/fsm_lowering.rb` | 0.0548 | 0.193 | 28.3% | 36/127 |
| 22 | `src/mir/lowering/control_flow.rb` | 0.051 | 0.276 | 18.5% | 62/335 |
| 23 | `src/annotator/domains/errors.rb` | 0.0492 | 0.418 | 11.8% | 40/340 |
| 24 | `src/annotator/helpers/with_match_check.rb` | 0.0405 | 0.372 | 10.9% | 11/101 |
| 25 | `src/mir/mir_checker.rb` | 0.0382 | 0.301 | 12.7% | 102/804 |
| 26 | `src/mir/lowering/variables.rb` | 0.038 | 0.302 | 12.6% | 50/398 |
| 27 | `src/mir/lowering/expressions.rb` | 0.0364 | 0.219 | 16.6% | 207/1244 |
| 28 | `src/backends/importer.rb` | 0.0354 | 0.354 | 10.0% | 4/40 |
| 29 | `src/mir/mir_emitter.rb` | 0.034 | 0.279 | 12.2% | 77/632 |
| 30 | `src/mir/fsm_wrapper_emitter.rb` | 0.0302 | 0.256 | 11.8% | 13/110 |
| 31 | `src/backends/compiler_frontend.rb` | 0.0295 | 0.354 | 8.3% | 2/24 |
| 32 | `src/mir/lower/pipeline/pipeline_range_lowerer.rb` | 0.0286 | 0.256 | 11.2% | 14/125 |
| 33 | `src/annotator/domains/control_flow.rb` | 0.0246 | 0.182 | 13.5% | 31/230 |
| 34 | `src/annotator/phases/body_analysis.rb` | 0.018 | 0.354 | 5.1% | 3/59 |
| 35 | `src/ast/fixable_error.rb` | 0.0131 | 0.031 | 42.9% | 6/14 |
| 36 | `src/mir/lowering/literals.rb` | 0.0107 | 0.131 | 8.2% | 5/61 |
| 37 | `src/mir/fsm_transform/suspend_resolvers.rb` | 0.0089 | 0.054 | 16.3% | 8/49 |
| 38 | `src/annotator/domains/variables.rb` | 0.0062 | 0.044 | 14.4% | 31/216 |
| 39 | `src/annotator/helpers/intrinsic_registry.rb` | 0.0051 | 0.052 | 9.8% | 9/92 |
| 40 | `src/annotator/helpers/function_analysis.rb` | 0.0048 | 0.039 | 12.4% | 58/469 |

- ...(+60 more)

## Mostly Uncovered Methods (5)
_non-trivial methods (`>=5` executable lines) with very low line coverage; risk = missed lines x gap, plus Decomplex detector score, instance-state writes, and dark branches._

- Completely uncovered: 0
- <=10% covered: 1
- <=20% covered: 5
- <=50% covered: 10

| # | method | risk | covered | missed | decomplex | findings | writes | dark branches |
|---|--------|------|---------|--------|-----------|----------|--------|---------------|
| 1 | `src/mir/mir.rb:4465` `child_exprs` | 14.67 | 1/6 | 5 | 7 | 20 | 0 | 0 |
| 2 | `src/mir/mir_emitter.rb:1185` `emit_sorted_lock_acquire_panic` | 11.08 | 1/13 | 12 | 0 | 0 | 0 | 0 |
| 3 | `src/mir/mir.rb:4489` `ownership_effect` | 8.7 | 1/5 | 4 | 3 | 7 | 0 | 2 |
| 4 | `src/mir/lowering/functions.rb:94` `coerce_zig` | 6.17 | 1/6 | 5 | 0 | 0 | 0 | 4 |
| 5 | `src/mir/lowering/state.rb:54` `with_rt_name` | 4.7 | 1/5 | 4 | 1 | 3 | 0 | 0 |

## State-Based Branch Hotspots (1611)
_Decomplex state-based branch density joined with fix-cache and branch coverage. These are branches over mutable/object state that are uncovered and/or historically fixed._

| # | method | risk | state branches | refs | fix_norm | branch gap | line gap | dark branches |
|---|--------|------|----------------|------|----------|------------|----------|---------------|
| 1 | `src/ast/ast.rb:initialize` | 867.47 | 21 | `rt.nil? | self[:bindings].nil? | self[:body].nil? | self[:borrowed].nil? | self[:capabilities].nil?` | 1.0 | 14.7% | 0.0% | 0 |
| 2 | `src/mir/fsm_transform/emit.rb:build_recursive` | 386.23 | 14 | `all_promoted.any? | ast_stmts.empty? | descriptor.nil? | lowered_mir.nil? | name.empty?` | 0.712 | 15.1% | 0.0% | 0 |
| 3 | `src/mir/cleanup_classifier.rb:classify_binding` | 353.57 | 13 | `facts.borrow_provenance | facts.container_borrow | facts.empty_initializer | facts.heap_storage | facts.mutable_binding_mutated` | 0.352 | 18.3% | 0.0% | 0 |
| 4 | `src/annotator/domains/errors.rb:visit_ReturnNode` | 267.84 | 13 | `expected.heap_return_storage? | expected.plain_return_payload_type | inline_bg_sources.any? | node.value | node.value.full_type!(context: "return expression storage").requires_move?` | 0.418 | 11.8% | 0.0% | 0 |
| 5 | `src/mir/mir_lowering.rb:mir_cast` | 264.31 | 10 | `from_t.dynamic? | from_t.fixed? | from_t.float? | from_t.fn_type? | from_t.integer?` | 0.842 | 10.4% | 0.0% | 0 |
| 6 | `src/annotator/domains/variables.rb:finalize_decl_node!` | 217.28 | 13 | `cap_tok.value | final_type.collection | fixes.any? | fixes.empty? | node.type` | 0.044 | 14.4% | 0.0% | 0 |
| 7 | `src/annotator/domains/execution_boundaries.rb:visit_NextExpr` | 207.04 | 15 | `async_shape.payload_type | async_shape.promise? | async_shape.shared_promise? | node.expr | promise_type.bounded_stream?` | 0.0 | 6.2% | 0.0% | 0 |
| 8 | `src/tools/formatter.rb:needs_space?` | 204.89 | 27 | `@generic_bracket_indices | @struct_lit_brace_indices | @struct_lit_brace_indices.empty? | a.raw | a.type` | 0.018 | 6.5% | 0.0% | 0 |
| 9 | `src/mir/lowering/functions.rb:lower_intrinsic` | 197.68 | 11 | `alloc_metadata.empty? | consumed_operands.empty? | entry.intrinsic_bc? | node.args | node.args.first` | 0.495 | 20.2% | 0.0% | 0 |
| 10 | `src/tools/formatter.rb:expand_if_while_for` | 190.79 | 22 | `out.length | t.raw | t.type | tj.raw | tj.type` | 0.018 | 6.5% | 0.0% | 0 |
| 11 | `src/semantic/escape_analysis.rb:propagate_caller_sync!` | 183.54 | 11 | `call_site.fn_var_call | callee_fn.params | entry.storage | entry.sync | fn_nodes.empty?` | 0.375 | 21.4% | 0.0% | 0 |
| 12 | `src/annotator/domains/lifetimes.rb:finalize_scope` | 179.13 | 15 | `branch.nil? | info.mutable | info.mutated | info.ownership_kind | info.read` | 0.0 | 19.4% | 0.0% | 0 |
| 13 | `src/mir/lowering/variables.rb:lower_var_decl_init` | 175.87 | 12 | `ft.fixed_soa? | ft.list_collection? | ft.pool? | ft.set_collection? | node.value` | 0.302 | 12.6% | 0.0% | 0 |
| 14 | `src/annotator/helpers/function_analysis.rb:visit_FunctionDef` | 163.45 | 14 | `candidate_snap_types.size | catch_body_scan.references_snapshot | fn_type_params.any? | node.name | node.reentrance_kind` | 0.039 | 12.4% | 0.0% | 0 |
| 15 | `src/mir/lowering/expressions.rb:lower_copy` | 161.11 | 8 | `dst_ti.collection? | dst_ti.direct_indexable_collection? | dst_ti.string? | ti.any_rc? | ti.any_sync?` | 0.219 | 16.6% | 6.3% | 4 |
| 16 | `src/mir/hoist.rb:collect_stmt_hoists!` | 153.75 | 9 | `arg.value | right_type.collection? | stmt.expr | stmt.name | stmt.value` | 0.872 | 14.1% | 0.0% | 0 |
| 17 | `src/mir/mir_checker.rb:check_fsm_structure!` | 146.61 | 10 | `cap.cleanup_at | cap.name | cleanup_step.nil? | fact.move_guarded | fact.name` | 0.301 | 12.7% | 0.0% | 0 |
| 18 | `src/annotator/domains/execution_boundaries.rb:visit_BgBlock` | 140.15 | 12 | `analysis.has_affine_locked | analysis.has_local | analysis.has_sharded | analysis_result.has_local | analysis_result.has_non_escaping_capture` | 0.0 | 6.2% | 0.0% | 0 |
| 19 | `src/mir/lowering/control_flow.rb:for_each_loop_stmt` | 139.66 | 8 | `ct.bounded_stream? | ct.dynamic_field_array? | ct.dynamic_stream? | ct.fixed_soa? | ct.inf_stream?` | 0.276 | 18.5% | 3.4% | 2 |
| 20 | `src/ast/parser.rb:parse_function_def` | 131.01 | 10 | `@gradual | @pos | @tokens | @tokens[@pos + 1].value | T.must(cap_tok).value` | 0.021 | 6.9% | 0.0% | 0 |
| 21 | `src/mir/fiber_ctx_builder.rb:rc_payload_zig_type` | 130.78 | 7 | `payload.any_sync? | payload.atomic? | payload.indirect? | payload.locked? | payload.map?` | 0.726 | 20.3% | 0.0% | 0 |
| 22 | `src/mir/lowering/functions.rb:ast_expr_produces_heap?` | 129.39 | 8 | `node.borrow_provenance? | node.heap_storage? | node.needs_heap_create | node.op | node.rodata_provenance?` | 0.495 | 20.2% | 0.0% | 0 |
| 23 | `src/annotator/domains/member_access.rb:visit_StructLit` | 120.99 | 10 | `field_names.empty? | missing.any? | node.fields | node.fields.empty? | node.fields.length` | 0.021 | 7.7% | 0.0% | 0 |
| 24 | `src/annotator/domains/expressions.rb:visit_CapabilityWrap` | 116.42 | 10 | `node.atomic? | node.atomic_ptr? | node.capability? | node.indirect? | node.layout` | 0.0 | 5.8% | 0.0% | 0 |
| 25 | `src/annotator/helpers/function_analysis.rb:resolve_call` | 115.58 | 11 | `arg.full_type!(context: "extern argument").soa? | call_type.error_union? | comptime_type_args.any? | entry.storage | node.args` | 0.039 | 12.4% | 0.0% | 0 |
| 26 | `src/annotator/helpers/capabilities.rb:predicate_impurity_reason` | 114.62 | 10 | `call.can_fail | call.extern_call | call.matched_stdlib_def | effects.empty? | extern_effects.empty?` | 0.028 | 11.5% | 0.0% | 0 |
| 27 | `src/mir/mir_lowering.rb:owned_sink_plan` | 113.85 | 7 | `source.borrowed_union_sink | source.existing_owned_source | source.satisfies_rc_sink? | ti.any_rc? | ti.collection_value?` | 0.842 | 10.4% | 0.0% | 0 |
| 28 | `src/annotator/helpers/function_analysis.rb:declare_and_verify_params` | 105.07 | 10 | `fams.empty? | field_names.empty? | missing.any? | param.default | param.sync` | 0.039 | 12.4% | 0.0% | 0 |
| 29 | `src/annotator/domains/errors.rb:visit_OrRescue` | 103.01 | 13 | `node.left | node.left.error_union_type | node.right | t_left_type.error_union? | t_left_type.optional?` | 0.418 | 11.8% | 0.0% | 0 |
| 30 | `src/mir/lowering/functions.rb:lower_extern_struct` | 100.63 | 7 | `items.length | mod_parts.first | mod_parts[1..].any? | node.as_type | node.field_decls` | 0.495 | 20.2% | 0.0% | 0 |
| 31 | `src/annotator/domains/member_access.rb:visit_GetField` | 96.8 | 8 | `check.empty? | field_type.indirect? | field_type.optional? | node.is_assignment_lhs | node.target` | 0.021 | 7.7% | 0.0% | 0 |
| 32 | `src/ast/ast.rb:finalize_storage!` | 96.39 | 7 | `final_type.fn_type? | type_obj.any_sync? | type_obj.heap? | type_obj.list_collection? | val_ti.link?` | 1.0 | 14.7% | 0.0% | 0 |
| 33 | `src/ast/ast.rb:body_slots` | 96.39 | 6 | `match_case.body | node.body | node.default_case | node.do_branch | node.else_branch` | 1.0 | 14.7% | 0.0% | 0 |
| 34 | `src/semantic/escape_analysis.rb:expr_produces_heap?` | 93.44 | 7 | `node.borrow_provenance? | node.heap_storage? | node.op | node.rodata_provenance? | node.storage` | 0.375 | 21.4% | 0.0% | 0 |
| 35 | `src/ast/type.rb:accepts?` | 88.5 | 8 | `other_type.any? | other_type.byte? | other_type.error_union? | other_type.map? | other_type.numeric?` | 0.003 | 10.3% | 0.0% | 0 |
| 36 | `src/annotator/domains/member_access.rb:visit_GetIndex` | 88.0 | 8 | `index_type_info.numeric? | index_type_info.string? | node.target | node.target.metatype | result_type.optional?` | 0.021 | 7.7% | 0.0% | 0 |
| 37 | `src/mir/mir_checker.rb:cleanup_source_owns_value?` | 87.96 | 5 | `MIR::OwnershipEffect.of(init).produces_owned | cleanup.cleanup_entry | cleanup.cleanup_entry.match_as? | init.ownership_consumption | init.ownership_consumption.names` | 0.301 | 12.7% | 0.0% | 0 |
| 38 | `src/mir/lowering/functions.rb:lower_function_def` | 86.26 | 6 | `final_zig_type.error_union? | node.can_fail | node.can_fail.nil? | node.mutual_thunk_plan | node.thunk_plan` | 0.495 | 20.2% | 0.0% | 0 |
| 39 | `src/mir/mir_pass.rb:finalize_needs_rt!` | 85.98 | 7 | `@fn_nodes | @fn_nodes[c].needs_rt | callees[name].any? | fn.body | fn.needs_rt` | 0.743 | 17.5% | 0.0% | 0 |
| 40 | `src/ast/type.rb:accepts_array?` | 85.18 | 7 | `T.must(element_type).any? | other_type.array? | other_type.bounded_stream? | other_type.dynamic_stream? | other_type.element_type` | 0.003 | 10.3% | 0.0% | 0 |

- ...(+1571 more)

## Multi-File Fix Blast Radius (107)
_Time-decayed fix commits where a file repeatedly changes with many other files. High rows are bug fixes whose blast radius is cross-module, not local._

| # | file | score | fixes | avg files/fix | max files | top co-touched files |
|---|------|-------|-------|---------------|-----------|----------------------|
| 1 | `src/mir/mir_lowering.rb` | 22.664 | 30 | 71.87 | 1828 | spec/mir_lowering_spec.rb (0.91); src/mir/lowering/concurrency.rb (0.872); src/mir/fiber_ctx_builder.rb (0.855); spec/mir_gap_burn_spec.rb (0.848); spec/mir_emitter_spec.rb (0.818) |
| 2 | `src/mir/lowering/concurrency.rb` | 22.35 | 7 | 20.71 | 36 | src/mir/mir_lowering.rb (0.872); spec/mir_lowering_spec.rb (0.858); src/mir/fiber_ctx_builder.rb (0.855); spec/concurrency_spec.rb (0.796); examples/minivm/bc_emitter.rb (0.794) |
| 3 | `src/mir/fiber_ctx_builder.rb` | 21.02 | 5 | 380.6 | 1828 | spec/mir_lowering_spec.rb (0.855); src/mir/mir_lowering.rb (0.855); src/mir/lowering/concurrency.rb (0.855); examples/minivm/bc_emitter.rb (0.794); spec/concurrency_spec.rb (0.794) |
| 4 | `src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb` | 20.145 | 2 | 26.5 | 27 | examples/minivm/bc_emitter.rb (0.794); examples/minivm/register_bc_emitter.rb (0.794); spec/concurrency_spec.rb (0.794); spec/fsm_classifier_spec.rb (0.794); spec/mir_emitter_spec.rb (0.794) |
| 5 | `src/annotator/annotator.rb` | 19.565 | 5 | 22.0 | 31 | examples/minivm/register_bc_emitter.rb (0.931); sorbet/rbi/clear-attr-accessors.rbi (0.91); spec/mir_gap_burn_spec.rb (0.91); src/annotator/helpers/effects.rb (0.91); examples/minivm/bc_emitter.rb (0.515) |
| 6 | `src/annotator/helpers/effects.rb` | 18.996 | 2 | 21.5 | 26 | examples/minivm/register_bc_emitter.rb (0.91); sorbet/rbi/clear-attr-accessors.rbi (0.91); spec/mir_gap_burn_spec.rb (0.91); src/annotator/annotator.rb (0.91); examples/minivm/bc_emitter.rb (0.493) |
| 7 | `src/mir/hoist.rb` | 17.058 | 12 | 17.17 | 36 | spec/mir_gap_burn_spec.rb (0.77); examples/minivm/register_bc_emitter.rb (0.74); src/mir/lowering/concurrency.rb (0.508); src/mir/mir_pass.rb (0.473); src/semantic/escape_analysis.rb (0.442) |
| 8 | `src/ast/ast.rb` | 16.397 | 12 | 161.17 | 1828 | sorbet/rbi/clear-attr-accessors.rbi (0.879); src/mir/lowering/concurrency.rb (0.695); src/mir/mir_lowering.rb (0.569); src/mir/lowering/functions.rb (0.565); spec/mir_lowering_spec.rb (0.544) |
| 9 | `src/mir/lowering/functions.rb` | 13.772 | 6 | 22.17 | 36 | src/ast/ast.rb (0.565); spec/mir_lowering_spec.rb (0.547); src/mir/mir_lowering.rb (0.547); spec/mir_gap_burn_spec.rb (0.544); examples/minivm/bc_emitter.rb (0.515) |
| 10 | `src/mir/fsm_transform/emit.rb` | 13.696 | 7 | 276.29 | 1828 | src/mir/mir_lowering.rb (0.557); spec/mir_lowering_spec.rb (0.557); src/mir/lowering/concurrency.rb (0.557); src/mir/fiber_ctx_builder.rb (0.554); sorbet/rbi/clear-attr-accessors.rbi (0.513) |
| 11 | `src/ast/diagnostic_registry.rb` | 12.405 | 4 | 472.75 | 1828 | spec/concurrency_spec.rb (0.495); spec/mir_lowering_spec.rb (0.495); src/mir/fsm_transform/emit.rb (0.495); src/mir/mir_lowering.rb (0.495); src/mir/lowering/concurrency.rb (0.495) |
| 12 | `src/mir/fsm_transform/recursive_splitter.rb` | 12.324 | 2 | 927.0 | 1828 | examples/minivm/bc_emitter.rb (0.493); sorbet/rbi/clear-attr-accessors.rbi (0.493); spec/concurrency_spec.rb (0.493); spec/fsm_classifier_spec.rb (0.493); spec/fsm_recursive_splitter_spec.rb (0.493) |
| 13 | `src/mir/fsm_transform/segments.rb` | 12.324 | 2 | 927.0 | 1828 | examples/minivm/bc_emitter.rb (0.493); sorbet/rbi/clear-attr-accessors.rbi (0.493); spec/concurrency_spec.rb (0.493); spec/fsm_classifier_spec.rb (0.493); spec/fsm_recursive_splitter_spec.rb (0.493) |
| 14 | `src/annotator/domains/errors.rb` | 12.313 | 1 | 26.0 | 26 | examples/minivm/bc_emitter.rb (0.493); examples/minivm/register_bc_emitter.rb (0.493); sorbet/rbi/clear-attr-accessors.rbi (0.493); spec/concurrency_spec.rb (0.493); spec/fsm_classifier_spec.rb (0.493) |
| 15 | `src/annotator/phases/declaration_index.rb` | 12.313 | 1 | 26.0 | 26 | examples/minivm/bc_emitter.rb (0.493); examples/minivm/register_bc_emitter.rb (0.493); sorbet/rbi/clear-attr-accessors.rbi (0.493); spec/concurrency_spec.rb (0.493); spec/fsm_classifier_spec.rb (0.493) |
| 16 | `src/mir/lowering/capabilities.rb` | 9.617 | 8 | 16.25 | 36 | src/mir/hoist.rb (0.328); src/mir/lowering/control_flow.rb (0.325); examples/minivm/bc_emitter.rb (0.322); examples/minivm/register_bc_emitter.rb (0.322); src/mir/lowering/concurrency.rb (0.317) |
| 17 | `src/mir/mir_pass.rb` | 9.406 | 14 | 143.86 | 1828 | sorbet/rbi/clear-attr-accessors.rbi (0.804); src/mir/hoist.rb (0.473); spec/mir_gap_burn_spec.rb (0.469); src/ast/ast.rb (0.438); src/annotator/annotator.rb (0.419) |
| 18 | `src/mir/mir.rb` | 9.234 | 9 | 216.67 | 1828 | src/mir/mir_lowering.rb (0.382); src/mir/hoist.rb (0.382); spec/mir_lowering_spec.rb (0.379); src/mir/mir_checker.rb (0.355); src/mir/lowering/variables.rb (0.355) |
| 19 | `src/mir/lowering/variables.rb` | 8.927 | 4 | 28.5 | 36 | spec/mir_lowering_spec.rb (0.356); src/mir/hoist.rb (0.356); src/mir/mir_lowering.rb (0.356); src/mir/mir.rb (0.355); src/mir/mir_checker.rb (0.355) |
| 20 | `src/mir/mir_checker.rb` | 8.899 | 4 | 477.75 | 1828 | spec/mir_lowering_spec.rb (0.355); src/mir/mir.rb (0.355); src/mir/mir_lowering.rb (0.355); src/mir/hoist.rb (0.355); src/mir/lowering/variables.rb (0.355) |
| 21 | `src/mir/lowering/control_flow.rb` | 8.231 | 3 | 26.33 | 36 | src/mir/hoist.rb (0.325); src/mir/lowering/capabilities.rb (0.325); examples/minivm/bc_emitter.rb (0.322); examples/minivm/register_bc_emitter.rb (0.322); spec/concurrency_spec.rb (0.304) |
| 22 | `src/mir/mir_emitter.rb` | 8.147 | 10 | 195.4 | 1828 | src/mir/mir_lowering.rb (0.328); src/mir/mir.rb (0.328); spec/mir_emitter_spec.rb (0.326); spec/concurrency_spec.rb (0.304); spec/mir_lowering_spec.rb (0.304) |
| 23 | `src/ast/schemas.rb` | 7.843 | 2 | 927.5 | 1828 | examples/minivm/bc_emitter.rb (0.301); spec/capabilities_spec.rb (0.301); spec/concurrency_spec.rb (0.301); spec/fsm_classifier_spec.rb (0.301); spec/fsm_wrapper_emitter_spec.rb (0.301) |
| 24 | `src/mir/fsm_wrapper_emitter.rb` | 7.843 | 2 | 927.5 | 1828 | examples/minivm/bc_emitter.rb (0.301); spec/capabilities_spec.rb (0.301); spec/concurrency_spec.rb (0.301); spec/fsm_classifier_spec.rb (0.301); spec/fsm_wrapper_emitter_spec.rb (0.301) |
| 25 | `src/mir/lower/pipeline/pipeline_range_lowerer.rb` | 7.832 | 1 | 27.0 | 27 | examples/minivm/bc_emitter.rb (0.301); examples/minivm/register_bc_emitter.rb (0.301); spec/capabilities_spec.rb (0.301); spec/concurrency_spec.rb (0.301); spec/fsm_classifier_spec.rb (0.301) |
| 26 | `src/annotator/helpers/with_match_check.rb` | 6.847 | 2 | 13.0 | 17 | sorbet/rbi/clear-attr-accessors.rbi (0.438); examples/minivm/register_bc_emitter.rb (0.418); spec/annotator_gap_burndown_spec.rb (0.418); spec/gen_attr_rbi_spec.rb (0.418); spec/mir_gap_burn_spec.rb (0.418) |
| 27 | `src/semantic/escape_analysis.rb` | 6.755 | 2 | 10.5 | 17 | src/mir/hoist.rb (0.442); examples/minivm/register_bc_emitter.rb (0.418); sorbet/rbi/clear-attr-accessors.rbi (0.418); spec/annotator_gap_burndown_spec.rb (0.418); spec/gen_attr_rbi_spec.rb (0.418) |
| 28 | `src/backends/compiler_frontend.rb` | 6.694 | 2 | 922.5 | 1828 | sorbet/rbi/clear-attr-accessors.rbi (0.418); src/backends/importer.rb (0.418); src/mir/mir_pass.rb (0.418); tools/gen_attr_rbi.rb (0.418); examples/minivm/register_bc_emitter.rb (0.418) |
| 29 | `src/backends/importer.rb` | 6.694 | 3 | 617.67 | 1828 | sorbet/rbi/clear-attr-accessors.rbi (0.418); src/backends/compiler_frontend.rb (0.418); src/mir/mir_pass.rb (0.418); tools/gen_attr_rbi.rb (0.418); examples/minivm/register_bc_emitter.rb (0.418) |
| 30 | `src/annotator/phases/body_analysis.rb` | 6.683 | 1 | 17.0 | 17 | examples/minivm/register_bc_emitter.rb (0.418); sorbet/rbi/clear-attr-accessors.rbi (0.418); spec/annotator_gap_burndown_spec.rb (0.418); spec/gen_attr_rbi_spec.rb (0.418); spec/mir_gap_burn_spec.rb (0.418) |
| 31 | `src/semantic/concurrency_checks.rb` | 6.683 | 1 | 17.0 | 17 | examples/minivm/register_bc_emitter.rb (0.418); sorbet/rbi/clear-attr-accessors.rbi (0.418); spec/annotator_gap_burndown_spec.rb (0.418); spec/gen_attr_rbi_spec.rb (0.418); spec/mir_gap_burn_spec.rb (0.418) |
| 32 | `src/README.md` | 3.511 | 2 | 918.0 | 1828 | spec/higher_order_spec.rb (0.5); zig/lib/data-structures.zig (0.5); zig/runtime/sharded-list-test.zig (0.5); zig/runtime/soa-list-test.zig (0.5); src/annotator/README.md (0.5) |
| 33 | `src/annotator/README.md` | 3.5 | 1 | 8.0 | 8 | spec/higher_order_spec.rb (0.5); src/README.md (0.5); src/mir/README.md (0.5); tools/fuzz/templates/mir_checker_negative_matrix.rb (0.5); zig/lib/data-structures.zig (0.5) |
| 34 | `src/mir/README.md` | 3.5 | 1 | 8.0 | 8 | spec/higher_order_spec.rb (0.5); src/README.md (0.5); src/annotator/README.md (0.5); tools/fuzz/templates/mir_checker_negative_matrix.rb (0.5); zig/lib/data-structures.zig (0.5) |
| 35 | `src/mir/lowering/expressions.rb` | 2.065 | 5 | 18.8 | 36 | src/mir/lowering/capabilities.rb (0.196); sorbet/rbi/clear-attr-accessors.rbi (0.194); spec/coverage_tools_spec.rb (0.194); src/annotator/domains/control_flow.rb (0.194); tools/zig_coverage_support.rb (0.194) |
| 36 | `src/mir/cleanup_classifier.rb` | 1.887 | 4 | 20.5 | 36 | src/ast/ast.rb (0.411); src/mir/mir_pass.rb (0.39); src/mir/control_flow.rb (0.389); sorbet/rbi/clear-attr-accessors.rbi (0.386); src/mir/mir_lowering.rb (0.028) |
| 37 | `src/mir/control_flow.rb` | 1.64 | 8 | 237.63 | 1828 | src/mir/mir_pass.rb (0.389); src/mir/cleanup_classifier.rb (0.389); sorbet/rbi/clear-attr-accessors.rbi (0.386); src/ast/ast.rb (0.386); src/backends/pipeline_host.rb (0.002) |
| 38 | `src/mir/fsm_lowering.rb` | 1.307 | 6 | 318.67 | 1828 | src/mir/hoist.rb (0.207); src/mir/lowering/concurrency.rb (0.207); src/ast/ast.rb (0.202); gems/nil-kill/lib/nil_kill/static_diff_audit.rb (0.202); gems/nil-kill/spec/static_diff_audit_spec.rb (0.202) |
| 39 | `src/mir/lowering/literals.rb` | 1.166 | 4 | 15.5 | 36 | src/mir/mir_lowering.rb (0.089); spec/mir_lowering_spec.rb (0.064); src/mir/fsm_transform/emit.rb (0.064); src/mir/fsm_transform/suspend_resolvers.rb (0.064); src/mir/lowering/concurrency.rb (0.064) |
| 40 | `src/annotator/domains/control_flow.rb` | 1.135 | 2 | 7.5 | 9 | sorbet/rbi/clear-attr-accessors.rbi (0.215); src/mir/lowering/capabilities.rb (0.215); spec/coverage_tools_spec.rb (0.194); src/mir/lowering/expressions.rb (0.194); tools/zig_coverage_support.rb (0.194) |

- ...(+67 more)

## Fixed But Unmeasured (7)
_files with recurring fixes but NO branch-coverage data -- recurring-fix code the corpus does not measure at all; itself a risk._

- `src/README.md` (fix_norm=0.424)
- `src/annotator/README.md` (fix_norm=0.424)
- `src/mir/README.md` (fix_norm=0.424)
- `src/annotator/helpers/intrinsic_emit.rb` (fix_norm=0.052)
- `src/annotator.rb` (fix_norm=0.001)
- `src/lsp/README.md` (fix_norm=0.0)
- `src/mir/thunk_transform.rb` (fix_norm=0.0)

## Run Summary
- Repo: `/home/yahn/cheat`
- Scope: `src/`
- Fix commits matched: 111 (time span over whole history, unfiltered)
- Files ranked: 100; fixed-but-unmeasured: 7
- State-based branch hotspots: 1611; multi-file fix blast rows: 107
- Branch-coverage resultset: present
- Method: vendored bugspots ([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) x SimpleCov branch gap; method gaps use Decomplex detector scores (see [docs/agents/design.md](docs/agents/design.md))
