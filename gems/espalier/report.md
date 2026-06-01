# Espalier Architecture Report

> Architecture-level state, effect, and delegation synthesis.
> Findings are review candidates, not verdicts.

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Run Summary](#run-summary)
- [State Owner Pressure](#state-owner-pressure)
- [Coordinator/Mutator Collisions](#coordinatormutator-collisions)
- [Conditional Delegation Hubs](#conditional-delegation-hubs)
- [State Lifecycle Pressure](#state-lifecycle-pressure)
- [Cross-Tool Overlap](#cross-tool-overlap)

## Project Prioritization
- Highest architecture-pressure owner: `SemanticAnnotator` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb)) (score=1435.95, state=39, methods=211).
- Highest coordinator/mutator collision: `Type#initialize` ([`src/ast/type.rb`](../../src/ast/type.rb#L296)) (score=235.50, writes=40, conditional calls=15).
- Highest state lifecycle pressure: `@errors` in `MIRChecker` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb)) (score=74.00, readers=40, writers=2).
- Start where architecture pressure overlaps Decomplex/Boobytrap/SlopCop/NilKill evidence; those are more likely root-cause work than local cleanup.

## Run Summary
- Modules/classes indexed: 276
- Functions indexed: 3833
- State slots indexed: 679
- Effect reads/writes: 876/1017
- Delegation edges: 27663
- Manifest/source byte ratio: 46.02% (1645783 / 3576547)
- Manifest/source word ratio: 36.60% (134004 / 366161)

## State Owner Pressure
_State-heavy owners with broad method/delegation surfaces._

| # | owner | score | state | methods | state touches | delegations | suggested refactor |
|---|-------|-------|-------|---------|---------------|-------------|--------------------|
| 1 | `SemanticAnnotator` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb)) | 1435.95 | 39 | 211 | 141 | 2869 | extract phase-state records and split lifecycle ownership |
| 2 | `PipelineHost` ([`src/backends/pipeline_host.rb`](../../src/backends/pipeline_host.rb)) | 984.50 | 22 | 131 | 114 | 1966 | extract phase-state records and split lifecycle ownership |
| 3 | `MIRLowering` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb)) | 927.25 | 53 | 211 | 133 | 1323 | extract phase-state records and split lifecycle ownership |
| 4 | `Type` ([`src/ast/type.rb`](../../src/ast/type.rb)) | 802.35 | 47 | 185 | 148 | 1025 | extract phase-state records and split lifecycle ownership |
| 5 | `Parser` ([`src/ast/parser.rb`](../../src/ast/parser.rb)) | 615.70 | 7 | 144 | 41 | 1286 | separate coordinator from mechanism helpers |
| 6 | `MIRLoweringExpressions` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb)) | 507.55 | 20 | 79 | 52 | 905 | extract phase-state records and split lifecycle ownership |
| 7 | `MIRLoweringFunctions` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb)) | 504.70 | 23 | 75 | 44 | 914 | extract phase-state records and split lifecycle ownership |
| 8 | `MIR` ([`src/mir/mir.rb`](../../src/mir/mir.rb)) | 480.60 | 10 | 283 | 50 | 528 | separate coordinator from mechanism helpers |
| 9 | `MIRChecker` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb)) | 439.65 | 2 | 106 | 48 | 887 | separate coordinator from mechanism helpers |
| 10 | `PipeAnalysis` ([`src/annotator/helpers/pipe_analysis.rb`](../../src/annotator/helpers/pipe_analysis.rb)) | 405.85 | 3 | 71 | 4 | 987 | separate coordinator from mechanism helpers |
| 11 | `MIRLoweringVariables` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb)) | 374.20 | 12 | 49 | 35 | 728 | separate coordinator from mechanism helpers |
| 12 | `MIRLoweringControlFlow` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb)) | 364.70 | 16 | 54 | 46 | 586 | separate coordinator from mechanism helpers |
| 13 | `MIREmitter` ([`src/mir/mir_emitter.rb`](../../src/mir/mir_emitter.rb)) | 359.65 | 7 | 112 | 15 | 707 | separate coordinator from mechanism helpers |
| 14 | `Formatter::Emitter` ([`src/tools/formatter.rb`](../../src/tools/formatter.rb)) | 320.10 | 3 | 103 | 6 | 686 | separate coordinator from mechanism helpers |
| 15 | `MIRLoweringCapabilities` ([`src/mir/lowering/capabilities.rb`](../../src/mir/lowering/capabilities.rb)) | 272.60 | 9 | 73 | 19 | 480 | separate coordinator from mechanism helpers |
| 16 | `MIRLoweringConcurrency` ([`src/mir/lowering/concurrency.rb`](../../src/mir/lowering/concurrency.rb)) | 257.80 | 13 | 36 | 32 | 428 | separate coordinator from mechanism helpers |
| 17 | `AST` ([`src/ast/ast.rb`](../../src/ast/ast.rb)) | 243.15 | 2 | 171 | 5 | 353 | separate coordinator from mechanism helpers |
| 18 | `EffectTracker` ([`src/annotator/helpers/effects.rb`](../../src/annotator/helpers/effects.rb)) | 243.00 | 11 | 35 | 43 | 324 | separate coordinator from mechanism helpers |
| 19 | `AST::Locatable` ([`src/ast/ast.rb`](../../src/ast/ast.rb)) | 241.15 | 21 | 61 | 55 | 93 | extract phase-state records and split lifecycle ownership |
| 20 | `FixableHelper` ([`src/annotator/helpers/fixable_helpers.rb`](../../src/annotator/helpers/fixable_helpers.rb)) | 239.35 | 1 | 60 | 11 | 509 | separate coordinator from mechanism helpers |

## Coordinator/Mutator Collisions
_Methods that both mutate phase state and coordinate many calls._

| # | method | score | reads | writes | always | conditional | overlap | suggested refactor |
|---|--------|-------|-------|--------|--------|-------------|---------|--------------------|
| 1 | `Type#initialize` ([`src/ast/type.rb`](../../src/ast/type.rb#L296)) | 235.50 | 0 | 40 | 0 | 15 | boobytrap=rank 12/hotspot 0.0271 | move writes behind a smaller state object or transaction helper |
| 2 | `Type#parse_raw_input` ([`src/ast/type.rb`](../../src/ast/type.rb#L2234)) | 166.30 | 1 | 21 | 7 | 26 | boobytrap=rank 12/hotspot 0.0271 | move writes behind a smaller state object or transaction helper |
| 3 | `SemanticAnnotator#visit_MatchStatement` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb#L1631)) | 157.60 | 1 | 0 | 40 | 73 | - | reify operation variants or split branch coordinator |
| 4 | `MIRLoweringFunctions#lower_function_def` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L223)) | 125.40 | 1 | 3 | 28 | 45 | boobytrap=rank 21/hotspot 0.0137 | reify operation variants or split branch coordinator |
| 5 | `FunctionAnalysis#verify_function_signature!` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L277)) | 121.40 | 0 | 0 | 20 | 62 | boobytrap=rank 28/hotspot 0.0092 | reify operation variants or split branch coordinator |
| 6 | `MIRLoweringVariables#lower_bind_expr` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb#L724)) | 121.30 | 2 | 3 | 4 | 53 | boobytrap=rank 31/hotspot 0.0087 | reify operation variants or split branch coordinator |
| 7 | `SemanticAnnotator#visit_FunctionDef` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb#L780)) | 115.30 | 6 | 0 | 50 | 39 | - | reify operation variants or split branch coordinator |
| 8 | `FsmTransform::Emit#build_recursive` ([`src/mir/fsm_transform/emit.rb`](../../src/mir/fsm_transform/emit.rb#L498)) | 113.30 | 0 | 0 | 46 | 45 | slopcop=rank 61, boobytrap=rank 15/hotspot 0.0211 | reify operation variants or split branch coordinator |
| 9 | `MIRLoweringConcurrency#lower_bg_block` ([`src/mir/lowering/concurrency.rb`](../../src/mir/lowering/concurrency.rb#L376)) | 113.00 | 2 | 5 | 47 | 22 | decomplex=5 detectors/score 10, boobytrap=rank 40/hotspot 0.0049 | move writes behind a smaller state object or transaction helper |
| 10 | `PipelineHost#lower_each` ([`src/backends/pipeline_host.rb`](../../src/backends/pipeline_host.rb#L2247)) | 108.80 | 3 | 4 | 10 | 39 | boobytrap=rank 3/hotspot 0.0721 | reify operation variants or split branch coordinator |
| 11 | `MIRLoweringConcurrency#lower_bg_stream_block` ([`src/mir/lowering/concurrency.rb`](../../src/mir/lowering/concurrency.rb#L798)) | 108.40 | 1 | 6 | 39 | 21 | boobytrap=rank 40/hotspot 0.0049 | move writes behind a smaller state object or transaction helper |
| 12 | `SemanticAnnotator#finalize_decl_node!` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb#L2789)) | 106.80 | 0 | 0 | 40 | 44 | - | reify operation variants or split branch coordinator |
| 13 | `PipeAnalysis#analyze_concurrent_op` ([`src/annotator/helpers/pipe_analysis.rb`](../../src/annotator/helpers/pipe_analysis.rb#L1429)) | 104.20 | 0 | 0 | 24 | 50 | decomplex=6 detectors/score 11 | reify operation variants or split branch coordinator |
| 14 | `PipelineHost#lower_batch_window` ([`src/backends/pipeline_host.rb`](../../src/backends/pipeline_host.rb#L1684)) | 102.10 | 0 | 1 | 26 | 39 | boobytrap=rank 3/hotspot 0.0721 | reify operation variants or split branch coordinator |
| 15 | `AST::Locatable#finalize_storage!` ([`src/ast/ast.rb`](../../src/ast/ast.rb#L999)) | 101.40 | 0 | 1 | 6 | 48 | decomplex=5 detectors/score 11, slopcop=rank 37, boobytrap=rank 7/hotspot 0.0404 | reify operation variants or split branch coordinator |
| 16 | `MIRLoweringControlFlow#for_each_loop_stmt` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb#L324)) | 101.30 | 0 | 2 | 6 | 45 | boobytrap=rank 34/hotspot 0.0062 | reify operation variants or split branch coordinator |
| 17 | `FunctionAnalysis#resolve_call` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L92)) | 100.50 | 0 | 1 | 7 | 47 | decomplex=5 detectors/score 10, boobytrap=rank 28/hotspot 0.0092 | reify operation variants or split branch coordinator |
| 18 | `MIRLoweringFunctions#lower_intrinsic` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L1573)) | 95.80 | 1 | 1 | 29 | 33 | boobytrap=rank 21/hotspot 0.0137 | reify operation variants or split branch coordinator |
| 19 | `MIRChecker#check_fn!` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb#L219)) | 95.50 | 0 | 2 | 37 | 27 | boobytrap=rank 16/hotspot 0.02 | reify operation variants or split branch coordinator |
| 20 | `SemanticAnnotator#visit_WithBlock` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb#L4603)) | 92.50 | 3 | 1 | 36 | 26 | - | reify operation variants or split branch coordinator |

## Conditional Delegation Hubs
_Branchy orchestration boundaries, independent of direct state writes._

| # | method | conditional calls | always calls | state touches | suggested refactor |
|---|--------|-------------------|--------------|---------------|--------------------|
| 1 | `SemanticAnnotator#visit_MatchStatement` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb#L1631)) | 73 | 40 | 1 | replace branch hub with reified operation dispatch |
| 2 | `FunctionAnalysis#verify_function_signature!` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L277)) | 62 | 20 | 0 | replace branch hub with reified operation dispatch |
| 3 | `MIRLoweringVariables#lower_bind_expr` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb#L724)) | 53 | 4 | 5 | replace branch hub with reified operation dispatch |
| 4 | `PipeAnalysis#analyze_concurrent_op` ([`src/annotator/helpers/pipe_analysis.rb`](../../src/annotator/helpers/pipe_analysis.rb#L1429)) | 50 | 24 | 0 | replace branch hub with reified operation dispatch |
| 5 | `MIRLoweringExpressions#lower_binary_op` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb#L262)) | 49 | 7 | 1 | replace branch hub with reified operation dispatch |
| 6 | `AST::Locatable#finalize_storage!` ([`src/ast/ast.rb`](../../src/ast/ast.rb#L999)) | 48 | 6 | 1 | replace branch hub with reified operation dispatch |
| 7 | `FunctionAnalysis#resolve_call` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L92)) | 47 | 7 | 1 | replace branch hub with reified operation dispatch |
| 8 | `GenericAnalysis#validate_type_annotation!` ([`src/annotator/helpers/generic_analysis.rb`](../../src/annotator/helpers/generic_analysis.rb#L73)) | 47 | 5 | 0 | replace branch hub with reified operation dispatch |
| 9 | `FsmTransform::Emit#build_recursive` ([`src/mir/fsm_transform/emit.rb`](../../src/mir/fsm_transform/emit.rb#L498)) | 45 | 46 | 0 | replace branch hub with reified operation dispatch |
| 10 | `MIRLoweringFunctions#lower_function_def` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L223)) | 45 | 28 | 4 | replace branch hub with reified operation dispatch |
| 11 | `MIRLoweringControlFlow#for_each_loop_stmt` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb#L324)) | 45 | 6 | 2 | replace branch hub with reified operation dispatch |
| 12 | `SemanticAnnotator#finalize_decl_node!` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb#L2789)) | 44 | 40 | 0 | replace branch hub with reified operation dispatch |
| 13 | `SemanticAnnotator#visit_GetField` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb#L3455)) | 44 | 9 | 4 | replace branch hub with reified operation dispatch |
| 14 | `Type#compute_zig_type` ([`src/ast/type.rb`](../../src/ast/type.rb#L2537)) | 44 | 6 | 3 | replace branch hub with reified operation dispatch |
| 15 | `MIRLoweringControlFlow#lower_match` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb#L517)) | 42 | 18 | 0 | replace branch hub with reified operation dispatch |
| 16 | `SemanticAnnotator#visit_StructLit` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb#L3645)) | 42 | 17 | 0 | replace branch hub with reified operation dispatch |
| 17 | `PipelineRewriter#rewrite_pipeline` ([`src/backends/pipeline_rewriter.rb`](../../src/backends/pipeline_rewriter.rb#L102)) | 40 | 16 | 0 | replace branch hub with reified operation dispatch |
| 18 | `CapabilityHelper#declare_capability_scope!` ([`src/annotator/helpers/capabilities.rb`](../../src/annotator/helpers/capabilities.rb#L804)) | 40 | 6 | 1 | replace branch hub with reified operation dispatch |
| 19 | `SemanticAnnotator#visit_FunctionDef` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb#L780)) | 39 | 50 | 6 | replace branch hub with reified operation dispatch |
| 20 | `PipelineHost#lower_batch_window` ([`src/backends/pipeline_host.rb`](../../src/backends/pipeline_host.rb#L1684)) | 39 | 26 | 1 | replace branch hub with reified operation dispatch |

## State Lifecycle Pressure
_State slots with many readers/writers or protocol-shaped behavior._

| # | state | owner | score | readers | writers | type | protocol evidence | suggested refactor |
|---|-------|-------|-------|---------|---------|------|-------------------|--------------------|
| 1 | `@errors` | `MIRChecker` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb)) | 74.00 | 40 | 2 | Array | protocol interfaces: concat, << | wrap protocol in a small lifecycle object |
| 2 | `@lowering` | `PipelineHost` ([`src/backends/pipeline_host.rb`](../../src/backends/pipeline_host.rb)) | 66.50 | 37 | 1 | MIRLowering | protocol interfaces: with_fiber_capture_map, task_config_zig, shard_context=, lower, lower_body, instance_variable_get, pipeline_alloc_mark_fact, mir_schema_lookup, pipeline_index_insert_with_ownership, pipeline_owned_cleanup_entry, emit_builtin, instance_variable_set, emit_expr, lower_head, append_ownership_transfers_for_mir_body | wrap protocol in a small lifecycle object |
| 3 | `@result_type` | `MIR` ([`src/mir/mir.rb`](../../src/mir/mir.rb)) | 60.00 | 8 | 16 | T.nilable(Type) | - | centralize writes behind one owner |
| 4 | `@og` | `SemanticAnnotator` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb)) | 50.00 | 26 | 1 | OwnershipGraph | protocol interfaces: fork_lightweight, restore_lightweight, nodes, [], moved?, edges, release_borrow, declare, borrow, can_write?, live?, transfer, mark_moved, drop, clear_completed_snapshot!, prune_scope! | wrap protocol in a small lifecycle object |
| 5 | `@fn_nodes` | `EffectTracker` ([`src/annotator/helpers/effects.rb`](../../src/annotator/helpers/effects.rb)) | 42.00 | 0 | 14 | T.nilable(T::Hash[String, AST::FunctionDef]) | - | centralize writes behind one owner |
| 6 | `@call_graph` | `EffectTracker` ([`src/annotator/helpers/effects.rb`](../../src/annotator/helpers/effects.rb)) | 38.00 | 0 | 10 | T.untyped | protocol interfaces: each, [], each_key | wrap protocol in a small lifecycle object |
| 7 | `@nodes` | `OwnershipGraph` ([`src/mir/ownership_graph.rb`](../../src/mir/ownership_graph.rb)) | 33.50 | 15 | 1 | Hash | protocol interfaces: empty?, []=, [], select, delete, each, keys | wrap protocol in a small lifecycle object |
| 8 | `@pos` | `Parser` ([`src/ast/parser.rb`](../../src/ast/parser.rb)) | 31.50 | 11 | 5 | Integer | - | centralize writes behind one owner |
| 9 | `@union_schemas` | `MIRLoweringExpressions` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb)) | 30.50 | 1 | 7 | T.untyped | protocol interfaces: key?, dig, [] | wrap protocol in a small lifecycle object |
| 10 | `@source_code` | `FixableHelper` ([`src/annotator/helpers/fixable_helpers.rb`](../../src/annotator/helpers/fixable_helpers.rb)) | 30.00 | 2 | 9 | T.untyped | - | centralize writes behind one owner |
| 11 | `@fn_nodes` | `SemanticAnnotator` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb)) | 29.00 | 12 | 1 | Hash | protocol interfaces: each_value, each, []=, key?, [] | wrap protocol in a small lifecycle object |
| 12 | `@sync` | `Type` ([`src/ast/type.rb`](../../src/ast/type.rb)) | 27.00 | 12 | 3 | T.nilable(Symbol) | - | verify this state belongs on the owner |
| 13 | `@current_pipe_label` | `PipelineHost` ([`src/backends/pipeline_host.rb`](../../src/backends/pipeline_host.rb)) | 27.00 | 0 | 9 | T.nilable(String) | - | centralize writes behind one owner |
| 14 | `@locals` | `Scope` ([`src/ast/scope.rb`](../../src/ast/scope.rb)) | 26.00 | 8 | 2 | Hash | protocol interfaces: []=, [] | wrap protocol in a small lifecycle object |
| 15 | `@findings` | `FixCollector` ([`src/ast/fixable_error.rb`](../../src/ast/fixable_error.rb)) | 24.50 | 5 | 3 | - | protocol interfaces: nil?, <<, any?, count | wrap protocol in a small lifecycle object |
| 16 | `@tokens` | `Parser` ([`src/ast/parser.rb`](../../src/ast/parser.rb)) | 24.50 | 9 | 1 | Array | protocol interfaces: [] | wrap protocol in a small lifecycle object |
| 17 | `@pending_stmts` | `MIRHoistLowering` ([`src/mir/hoist.rb`](../../src/mir/hoist.rb)) | 24.50 | 5 | 3 | - | protocol interfaces: concat | wrap protocol in a small lifecycle object |
| 18 | `@ownership` | `Type` ([`src/ast/type.rb`](../../src/ast/type.rb)) | 24.00 | 10 | 3 | T.nilable(Symbol) | - | verify this state belongs on the owner |
| 19 | `@logger` | `LSP::Server` ([`src/lsp/server.rb`](../../src/lsp/server.rb)) | 24.00 | 14 | 1 | LSP::Logger | - | verify this state belongs on the owner |
| 20 | `@slots` | `AutoConstraintCollector` ([`src/annotator/helpers/auto_inference.rb`](../../src/annotator/helpers/auto_inference.rb)) | 23.00 | 8 | 1 | Hash | protocol interfaces: []=, [] | wrap protocol in a small lifecycle object |

## Cross-Tool Overlap
_Architectural pressure with sibling-tool metadata already attached._

| # | method | architecture score | overlap |
|---|--------|--------------------|---------|
| 1 | `Type#parse_raw_input` ([`src/ast/type.rb`](../../src/ast/type.rb#L2234)) | 166.30 | boobytrap=rank 12/hotspot 0.0271 |
| 2 | `MIRLoweringFunctions#lower_function_def` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L223)) | 125.40 | boobytrap=rank 21/hotspot 0.0137 |
| 3 | `FunctionAnalysis#verify_function_signature!` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L277)) | 121.40 | boobytrap=rank 28/hotspot 0.0092 |
| 4 | `MIRLoweringVariables#lower_bind_expr` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb#L724)) | 121.30 | boobytrap=rank 31/hotspot 0.0087 |
| 5 | `FsmTransform::Emit#build_recursive` ([`src/mir/fsm_transform/emit.rb`](../../src/mir/fsm_transform/emit.rb#L498)) | 113.30 | slopcop=rank 61, boobytrap=rank 15/hotspot 0.0211 |
| 6 | `MIRLoweringConcurrency#lower_bg_block` ([`src/mir/lowering/concurrency.rb`](../../src/mir/lowering/concurrency.rb#L376)) | 113.00 | decomplex=5 detectors/score 10, boobytrap=rank 40/hotspot 0.0049 |
| 7 | `PipelineHost#lower_each` ([`src/backends/pipeline_host.rb`](../../src/backends/pipeline_host.rb#L2247)) | 108.80 | boobytrap=rank 3/hotspot 0.0721 |
| 8 | `MIRLoweringConcurrency#lower_bg_stream_block` ([`src/mir/lowering/concurrency.rb`](../../src/mir/lowering/concurrency.rb#L798)) | 108.40 | boobytrap=rank 40/hotspot 0.0049 |
| 9 | `PipeAnalysis#analyze_concurrent_op` ([`src/annotator/helpers/pipe_analysis.rb`](../../src/annotator/helpers/pipe_analysis.rb#L1429)) | 104.20 | decomplex=6 detectors/score 11 |
| 10 | `PipelineHost#lower_batch_window` ([`src/backends/pipeline_host.rb`](../../src/backends/pipeline_host.rb#L1684)) | 102.10 | boobytrap=rank 3/hotspot 0.0721 |
| 11 | `AST::Locatable#finalize_storage!` ([`src/ast/ast.rb`](../../src/ast/ast.rb#L999)) | 101.40 | decomplex=5 detectors/score 11, slopcop=rank 37, boobytrap=rank 7/hotspot 0.0404 |
| 12 | `MIRLoweringControlFlow#for_each_loop_stmt` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb#L324)) | 101.30 | boobytrap=rank 34/hotspot 0.0062 |
| 13 | `FunctionAnalysis#resolve_call` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L92)) | 100.50 | decomplex=5 detectors/score 10, boobytrap=rank 28/hotspot 0.0092 |
| 14 | `MIRLoweringFunctions#lower_intrinsic` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L1573)) | 95.80 | boobytrap=rank 21/hotspot 0.0137 |
| 15 | `MIRChecker#check_fn!` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb#L219)) | 95.50 | boobytrap=rank 16/hotspot 0.02 |
| 16 | `MIRLowering#lower` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb#L769)) | 92.10 | boobytrap=rank 1/hotspot 0.1498 |
| 17 | `SemanticAnnotator#visit_ReturnNode` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb#L2206)) | 92.00 | slopcop=rank 41 |
| 18 | `MIRLoweringExpressions#lower_binary_op` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb#L262)) | 90.40 | boobytrap=rank 23/hotspot 0.0125 |
| 19 | `Parser#parse_function_def` ([`src/ast/parser.rb`](../../src/ast/parser.rb#L1256)) | 90.10 | slopcop=rank 59, boobytrap=rank 17/hotspot 0.0191 |
| 20 | `SemanticAnnotator#visit_GetField` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb#L3455)) | 88.00 | decomplex=6 detectors/score 10 |
