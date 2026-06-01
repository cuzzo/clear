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
- Highest architecture-pressure owner: `SemanticAnnotator` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb)) (score=1434.65, state=39, methods=209).
- Highest coordinator/mutator collision: `Type#initialize` ([`src/ast/type.rb`](../../src/ast/type.rb#L230)) (score=233.80, writes=40, conditional calls=14).
- Highest state lifecycle pressure: `@errors` in `MIRChecker` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb)) (score=74.00, readers=40, writers=2).
- Start where architecture pressure overlaps Decomplex/Boobytrap/SlopCop/NilKill evidence; those are more likely root-cause work than local cleanup.

## Run Summary
- Modules/classes indexed: 254
- Functions indexed: 3645
- State slots indexed: 675
- Effect reads/writes: 867/1020
- Delegation edges: 27029
- Manifest/source byte ratio: 44.60% (1586636 / 3557789)
- Manifest/source word ratio: 35.43% (129654 / 365977)

## State Owner Pressure
_State-heavy owners with broad method/delegation surfaces._

| # | owner | score | state | methods | state touches | delegations | suggested refactor |
|---|-------|-------|-------|---------|---------------|-------------|--------------------|
| 1 | `SemanticAnnotator` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb)) | 1434.65 | 39 | 209 | 138 | 2879 | extract phase-state records and split lifecycle ownership |
| 2 | `PipelineHost` ([`src/backends/pipeline_host.rb`](../../src/backends/pipeline_host.rb)) | 1011.05 | 22 | 133 | 115 | 2035 | extract phase-state records and split lifecycle ownership |
| 3 | `MIRLowering` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb)) | 931.65 | 53 | 209 | 133 | 1339 | extract phase-state records and split lifecycle ownership |
| 4 | `Type` ([`src/ast/type.rb`](../../src/ast/type.rb)) | 726.60 | 47 | 152 | 146 | 872 | extract phase-state records and split lifecycle ownership |
| 5 | `Parser` ([`src/ast/parser.rb`](../../src/ast/parser.rb)) | 601.35 | 7 | 137 | 41 | 1257 | separate coordinator from mechanism helpers |
| 6 | `MIRLoweringFunctions` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb)) | 493.00 | 23 | 70 | 44 | 892 | extract phase-state records and split lifecycle ownership |
| 7 | `MIRLoweringExpressions` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb)) | 478.60 | 20 | 67 | 49 | 856 | extract phase-state records and split lifecycle ownership |
| 8 | `MIR` ([`src/mir/mir.rb`](../../src/mir/mir.rb)) | 476.70 | 10 | 280 | 50 | 522 | separate coordinator from mechanism helpers |
| 9 | `MIRChecker` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb)) | 438.35 | 2 | 105 | 48 | 885 | separate coordinator from mechanism helpers |
| 10 | `PipeAnalysis` ([`src/annotator/helpers/pipe_analysis.rb`](../../src/annotator/helpers/pipe_analysis.rb)) | 409.85 | 3 | 66 | 4 | 1007 | separate coordinator from mechanism helpers |
| 11 | `MIRLoweringControlFlow` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb)) | 365.35 | 16 | 53 | 45 | 593 | separate coordinator from mechanism helpers |
| 12 | `MIREmitter` ([`src/mir/mir_emitter.rb`](../../src/mir/mir_emitter.rb)) | 357.05 | 7 | 110 | 15 | 703 | separate coordinator from mechanism helpers |
| 13 | `MIRLoweringVariables` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb)) | 339.85 | 12 | 39 | 35 | 647 | separate coordinator from mechanism helpers |
| 14 | `Formatter::Emitter` ([`src/tools/formatter.rb`](../../src/tools/formatter.rb)) | 319.40 | 3 | 103 | 6 | 684 | separate coordinator from mechanism helpers |
| 15 | `EffectTracker` ([`src/annotator/helpers/effects.rb`](../../src/annotator/helpers/effects.rb)) | 244.75 | 11 | 35 | 43 | 329 | separate coordinator from mechanism helpers |
| 16 | `AST::Locatable` ([`src/ast/ast.rb`](../../src/ast/ast.rb)) | 241.15 | 21 | 61 | 55 | 93 | extract phase-state records and split lifecycle ownership |
| 17 | `FixableHelper` ([`src/annotator/helpers/fixable_helpers.rb`](../../src/annotator/helpers/fixable_helpers.rb)) | 239.35 | 1 | 60 | 11 | 509 | separate coordinator from mechanism helpers |
| 18 | `MIRLoweringConcurrency` ([`src/mir/lowering/concurrency.rb`](../../src/mir/lowering/concurrency.rb)) | 238.85 | 13 | 26 | 32 | 391 | separate coordinator from mechanism helpers |
| 19 | `CleanupClassifier` ([`src/mir/cleanup_classifier.rb`](../../src/mir/cleanup_classifier.rb)) | 232.90 | 0 | 65 | 0 | 554 | separate coordinator from mechanism helpers |
| 20 | `EscapeAnalysis` ([`src/mir/escape_analysis.rb`](../../src/mir/escape_analysis.rb)) | 232.20 | 0 | 79 | 0 | 528 | separate coordinator from mechanism helpers |

## Coordinator/Mutator Collisions
_Methods that both mutate phase state and coordinate many calls._

| # | method | score | reads | writes | always | conditional | overlap | suggested refactor |
|---|--------|-------|-------|--------|--------|-------------|---------|--------------------|
| 1 | `Type#initialize` ([`src/ast/type.rb`](../../src/ast/type.rb#L230)) | 233.80 | 0 | 40 | 0 | 14 | boobytrap=rank 12/hotspot 0.0271 | move writes behind a smaller state object or transaction helper |
| 2 | `MIRLoweringConcurrency#lower_bg_block` ([`src/mir/lowering/concurrency.rb`](../../src/mir/lowering/concurrency.rb#L347)) | 173.50 | 2 | 5 | 61 | 51 | boobytrap=rank 40/hotspot 0.0049 | move writes behind a smaller state object or transaction helper |
| 3 | `Type#compute_zig_type` ([`src/ast/type.rb`](../../src/ast/type.rb#L2229)) | 164.30 | 6 | 0 | 5 | 89 | decomplex=7 detectors/score 12, slopcop=rank 16, boobytrap=rank 12/hotspot 0.0271 | reify operation variants or split branch coordinator |
| 4 | `SemanticAnnotator#visit_MatchStatement` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb#L1598)) | 157.60 | 1 | 0 | 40 | 73 | decomplex=6 detectors/score 10 | reify operation variants or split branch coordinator |
| 5 | `MIRLoweringCapabilities#lower_with_block` ([`src/mir/lowering/capabilities.rb`](../../src/mir/lowering/capabilities.rb#L165)) | 149.30 | 0 | 6 | 41 | 45 | boobytrap=rank 25/hotspot 0.0115 | move writes behind a smaller state object or transaction helper |
| 6 | `Type#parse_raw_input` ([`src/ast/type.rb`](../../src/ast/type.rb#L2051)) | 147.80 | 1 | 21 | 3 | 17 | boobytrap=rank 12/hotspot 0.0271 | move writes behind a smaller state object or transaction helper |
| 7 | `MIRLoweringFunctions#lower_intrinsic` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L1560)) | 129.80 | 2 | 2 | 40 | 44 | boobytrap=rank 21/hotspot 0.0137 | reify operation variants or split branch coordinator |
| 8 | `MIRLoweringExpressions#lower_smooth` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb#L430)) | 127.50 | 1 | 3 | 3 | 58 | decomplex=6 detectors/score 10, slopcop=rank 28, boobytrap=rank 23/hotspot 0.0125 | reify operation variants or split branch coordinator |
| 9 | `MIRLoweringVariables#lower_bind_expr` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb#L677)) | 121.30 | 2 | 3 | 4 | 53 | boobytrap=rank 31/hotspot 0.0087 | reify operation variants or split branch coordinator |
| 10 | `FunctionAnalysis#verify_function_signature!` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L277)) | 119.70 | 0 | 0 | 20 | 61 | boobytrap=rank 28/hotspot 0.0092 | reify operation variants or split branch coordinator |
| 11 | `MIRLoweringFunctions#lower_function_def` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L215)) | 117.80 | 1 | 3 | 27 | 41 | decomplex=5 detectors/score 10, boobytrap=rank 21/hotspot 0.0137 | reify operation variants or split branch coordinator |
| 12 | `SemanticAnnotator#visit_FunctionDef` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb#L745)) | 115.30 | 6 | 0 | 50 | 39 | - | reify operation variants or split branch coordinator |
| 13 | `SemanticAnnotator#finalize_decl_node!` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb#L2753)) | 113.60 | 0 | 0 | 40 | 48 | - | reify operation variants or split branch coordinator |
| 14 | `FsmTransform::Emit#build_recursive` ([`src/mir/fsm_transform/emit.rb`](../../src/mir/fsm_transform/emit.rb#L498)) | 113.30 | 0 | 0 | 46 | 45 | boobytrap=rank 15/hotspot 0.0211 | reify operation variants or split branch coordinator |
| 15 | `PipelineHost#lower_each` ([`src/backends/pipeline_host.rb`](../../src/backends/pipeline_host.rb#L2262)) | 111.20 | 3 | 4 | 13 | 39 | boobytrap=rank 3/hotspot 0.0721 | reify operation variants or split branch coordinator |
| 16 | `PipeAnalysis#analyze_concurrent_op` ([`src/annotator/helpers/pipe_analysis.rb`](../../src/annotator/helpers/pipe_analysis.rb#L1440)) | 110.90 | 0 | 0 | 26 | 53 | decomplex=6 detectors/score 11 | reify operation variants or split branch coordinator |
| 17 | `MIRLoweringConcurrency#lower_bg_stream_block` ([`src/mir/lowering/concurrency.rb`](../../src/mir/lowering/concurrency.rb#L704)) | 108.40 | 1 | 6 | 39 | 21 | boobytrap=rank 40/hotspot 0.0049 | move writes behind a smaller state object or transaction helper |
| 18 | `CapabilityHelper#record_capture_info!` ([`src/annotator/helpers/capabilities.rb`](../../src/annotator/helpers/capabilities.rb#L1023)) | 104.80 | 0 | 1 | 6 | 50 | - | reify operation variants or split branch coordinator |
| 19 | `PipelineHost#lower_batch_window` ([`src/backends/pipeline_host.rb`](../../src/backends/pipeline_host.rb#L1699)) | 102.10 | 0 | 1 | 26 | 39 | boobytrap=rank 3/hotspot 0.0721 | reify operation variants or split branch coordinator |
| 20 | `AST::Locatable#finalize_storage!` ([`src/ast/ast.rb`](../../src/ast/ast.rb#L886)) | 101.40 | 0 | 1 | 6 | 48 | decomplex=5 detectors/score 11, slopcop=rank 69, boobytrap=rank 7/hotspot 0.0404 | reify operation variants or split branch coordinator |

## Conditional Delegation Hubs
_Branchy orchestration boundaries, independent of direct state writes._

| # | method | conditional calls | always calls | state touches | suggested refactor |
|---|--------|-------------------|--------------|---------------|--------------------|
| 1 | `Type#compute_zig_type` ([`src/ast/type.rb`](../../src/ast/type.rb#L2229)) | 89 | 5 | 6 | replace branch hub with reified operation dispatch |
| 2 | `SemanticAnnotator#visit_MatchStatement` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb#L1598)) | 73 | 40 | 1 | replace branch hub with reified operation dispatch |
| 3 | `FunctionAnalysis#verify_function_signature!` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L277)) | 61 | 20 | 0 | replace branch hub with reified operation dispatch |
| 4 | `MIRLoweringExpressions#lower_smooth` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb#L430)) | 58 | 3 | 4 | replace branch hub with reified operation dispatch |
| 5 | `PipeAnalysis#analyze_concurrent_op` ([`src/annotator/helpers/pipe_analysis.rb`](../../src/annotator/helpers/pipe_analysis.rb#L1440)) | 53 | 26 | 0 | replace branch hub with reified operation dispatch |
| 6 | `GenericAnalysis#validate_type_annotation!` ([`src/annotator/helpers/generic_analysis.rb`](../../src/annotator/helpers/generic_analysis.rb#L73)) | 53 | 5 | 0 | replace branch hub with reified operation dispatch |
| 7 | `MIRLoweringVariables#lower_bind_expr` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb#L677)) | 53 | 4 | 5 | replace branch hub with reified operation dispatch |
| 8 | `MIRLoweringConcurrency#lower_bg_block` ([`src/mir/lowering/concurrency.rb`](../../src/mir/lowering/concurrency.rb#L347)) | 51 | 61 | 7 | replace branch hub with reified operation dispatch |
| 9 | `MethodAnalysis#resolve_typed_method` ([`src/annotator/helpers/method_analysis.rb`](../../src/annotator/helpers/method_analysis.rb#L59)) | 51 | 16 | 0 | replace branch hub with reified operation dispatch |
| 10 | `CapabilityHelper#record_capture_info!` ([`src/annotator/helpers/capabilities.rb`](../../src/annotator/helpers/capabilities.rb#L1023)) | 50 | 6 | 1 | replace branch hub with reified operation dispatch |
| 11 | `MIRLoweringExpressions#lower_binary_op` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb#L249)) | 49 | 7 | 1 | replace branch hub with reified operation dispatch |
| 12 | `SemanticAnnotator#finalize_decl_node!` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb#L2753)) | 48 | 40 | 0 | replace branch hub with reified operation dispatch |
| 13 | `AST::Locatable#finalize_storage!` ([`src/ast/ast.rb`](../../src/ast/ast.rb#L886)) | 48 | 6 | 1 | replace branch hub with reified operation dispatch |
| 14 | `FunctionAnalysis#resolve_call` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L92)) | 47 | 7 | 1 | replace branch hub with reified operation dispatch |
| 15 | `FsmTransform::Emit#build_recursive` ([`src/mir/fsm_transform/emit.rb`](../../src/mir/fsm_transform/emit.rb#L498)) | 45 | 46 | 0 | replace branch hub with reified operation dispatch |
| 16 | `MIRLoweringCapabilities#lower_with_block` ([`src/mir/lowering/capabilities.rb`](../../src/mir/lowering/capabilities.rb#L165)) | 45 | 41 | 6 | replace branch hub with reified operation dispatch |
| 17 | `MIRLoweringFunctions#lower_intrinsic` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L1560)) | 44 | 40 | 4 | replace branch hub with reified operation dispatch |
| 18 | `SemanticAnnotator#visit_GetField` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb#L3425)) | 44 | 9 | 4 | replace branch hub with reified operation dispatch |
| 19 | `MIRLoweringControlFlow#for_each_loop_stmt` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb#L320)) | 44 | 6 | 2 | replace branch hub with reified operation dispatch |
| 20 | `PipelineRewriter#rewrite_pipeline` ([`src/backends/pipeline_rewriter.rb`](../../src/backends/pipeline_rewriter.rb#L100)) | 42 | 19 | 0 | replace branch hub with reified operation dispatch |

## State Lifecycle Pressure
_State slots with many readers/writers or protocol-shaped behavior._

| # | state | owner | score | readers | writers | type | protocol evidence | suggested refactor |
|---|-------|-------|-------|---------|---------|------|-------------------|--------------------|
| 1 | `@errors` | `MIRChecker` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb)) | 74.00 | 40 | 2 | Array | protocol interfaces: concat, << | wrap protocol in a small lifecycle object |
| 2 | `@lowering` | `PipelineHost` ([`src/backends/pipeline_host.rb`](../../src/backends/pipeline_host.rb)) | 68.00 | 38 | 1 | MIRLowering | protocol interfaces: with_fiber_capture_map, send, shard_context=, lower, lower_body, instance_variable_get, instance_variable_set | wrap protocol in a small lifecycle object |
| 3 | `@result_type` | `MIR` ([`src/mir/mir.rb`](../../src/mir/mir.rb)) | 60.00 | 8 | 16 | T.nilable(Type) | - | centralize writes behind one owner |
| 4 | `@og` | `SemanticAnnotator` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb)) | 50.00 | 26 | 1 | OwnershipGraph | protocol interfaces: fork_lightweight, restore_lightweight, nodes, [], moved?, edges, release_borrow, declare, borrow, can_write?, live?, transfer, mark_moved, drop, clear_completed_snapshot!, prune_scope! | wrap protocol in a small lifecycle object |
| 5 | `@fn_nodes` | `EffectTracker` ([`src/annotator/helpers/effects.rb`](../../src/annotator/helpers/effects.rb)) | 42.00 | 0 | 14 | T.nilable(T::Hash[String, AST::FunctionDef]) | - | centralize writes behind one owner |
| 6 | `@call_graph` | `EffectTracker` ([`src/annotator/helpers/effects.rb`](../../src/annotator/helpers/effects.rb)) | 38.00 | 0 | 10 | T.untyped | protocol interfaces: each, [], each_key | wrap protocol in a small lifecycle object |
| 7 | `@nodes` | `OwnershipGraph` ([`src/mir/ownership_graph.rb`](../../src/mir/ownership_graph.rb)) | 33.50 | 15 | 1 | Hash | protocol interfaces: empty?, []=, [], select, delete, each, keys | wrap protocol in a small lifecycle object |
| 8 | `@pos` | `Parser` ([`src/ast/parser.rb`](../../src/ast/parser.rb)) | 31.50 | 11 | 5 | Integer | - | centralize writes behind one owner |
| 9 | `@union_schemas` | `MIRLoweringExpressions` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb)) | 30.50 | 1 | 7 | T.untyped | protocol interfaces: key?, dig, [] | wrap protocol in a small lifecycle object |
| 10 | `@source_code` | `FixableHelper` ([`src/annotator/helpers/fixable_helpers.rb`](../../src/annotator/helpers/fixable_helpers.rb)) | 30.00 | 2 | 9 | T.untyped | - | centralize writes behind one owner |
| 11 | `@rt_name` | `MIRLoweringCapabilities` ([`src/mir/lowering/capabilities.rb`](../../src/mir/lowering/capabilities.rb)) | 30.00 | 2 | 9 | T.untyped | - | centralize writes behind one owner |
| 12 | `@fn_nodes` | `SemanticAnnotator` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb)) | 29.00 | 12 | 1 | Hash | protocol interfaces: each_value, each, []=, key?, [] | wrap protocol in a small lifecycle object |
| 13 | `@sync` | `Type` ([`src/ast/type.rb`](../../src/ast/type.rb)) | 27.00 | 12 | 3 | NilClass | - | verify this state belongs on the owner |
| 14 | `@current_pipe_label` | `PipelineHost` ([`src/backends/pipeline_host.rb`](../../src/backends/pipeline_host.rb)) | 27.00 | 0 | 9 | NilClass | - | centralize writes behind one owner |
| 15 | `@locals` | `Scope` ([`src/ast/scope.rb`](../../src/ast/scope.rb)) | 26.00 | 8 | 2 | Hash | protocol interfaces: []=, [] | wrap protocol in a small lifecycle object |
| 16 | `@findings` | `FixCollector` ([`src/ast/fixable_error.rb`](../../src/ast/fixable_error.rb)) | 24.50 | 5 | 3 | - | protocol interfaces: nil?, <<, any?, count | wrap protocol in a small lifecycle object |
| 17 | `@tokens` | `Parser` ([`src/ast/parser.rb`](../../src/ast/parser.rb)) | 24.50 | 9 | 1 | Array | protocol interfaces: [] | wrap protocol in a small lifecycle object |
| 18 | `@pending_stmts` | `MIRHoistLowering` ([`src/mir/hoist.rb`](../../src/mir/hoist.rb)) | 24.50 | 5 | 3 | - | protocol interfaces: <<, concat | wrap protocol in a small lifecycle object |
| 19 | `@logger` | `LSP::Server` ([`src/lsp/server.rb`](../../src/lsp/server.rb)) | 24.00 | 14 | 1 | LSP::Logger | - | verify this state belongs on the owner |
| 20 | `@slots` | `AutoConstraintCollector` ([`src/annotator/helpers/auto_inference.rb`](../../src/annotator/helpers/auto_inference.rb)) | 23.00 | 8 | 1 | Hash | protocol interfaces: []=, [] | wrap protocol in a small lifecycle object |

## Cross-Tool Overlap
_Architectural pressure with sibling-tool metadata already attached._

| # | method | architecture score | overlap |
|---|--------|--------------------|---------|
| 1 | `MIRLoweringConcurrency#lower_bg_block` ([`src/mir/lowering/concurrency.rb`](../../src/mir/lowering/concurrency.rb#L347)) | 173.50 | boobytrap=rank 40/hotspot 0.0049 |
| 2 | `Type#compute_zig_type` ([`src/ast/type.rb`](../../src/ast/type.rb#L2229)) | 164.30 | decomplex=7 detectors/score 12, slopcop=rank 16, boobytrap=rank 12/hotspot 0.0271 |
| 3 | `SemanticAnnotator#visit_MatchStatement` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb#L1598)) | 157.60 | decomplex=6 detectors/score 10 |
| 4 | `MIRLoweringCapabilities#lower_with_block` ([`src/mir/lowering/capabilities.rb`](../../src/mir/lowering/capabilities.rb#L165)) | 149.30 | boobytrap=rank 25/hotspot 0.0115 |
| 5 | `Type#parse_raw_input` ([`src/ast/type.rb`](../../src/ast/type.rb#L2051)) | 147.80 | boobytrap=rank 12/hotspot 0.0271 |
| 6 | `MIRLoweringFunctions#lower_intrinsic` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L1560)) | 129.80 | boobytrap=rank 21/hotspot 0.0137 |
| 7 | `MIRLoweringExpressions#lower_smooth` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb#L430)) | 127.50 | decomplex=6 detectors/score 10, slopcop=rank 28, boobytrap=rank 23/hotspot 0.0125 |
| 8 | `MIRLoweringVariables#lower_bind_expr` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb#L677)) | 121.30 | boobytrap=rank 31/hotspot 0.0087 |
| 9 | `FunctionAnalysis#verify_function_signature!` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L277)) | 119.70 | boobytrap=rank 28/hotspot 0.0092 |
| 10 | `MIRLoweringFunctions#lower_function_def` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L215)) | 117.80 | decomplex=5 detectors/score 10, boobytrap=rank 21/hotspot 0.0137 |
| 11 | `FsmTransform::Emit#build_recursive` ([`src/mir/fsm_transform/emit.rb`](../../src/mir/fsm_transform/emit.rb#L498)) | 113.30 | boobytrap=rank 15/hotspot 0.0211 |
| 12 | `PipelineHost#lower_each` ([`src/backends/pipeline_host.rb`](../../src/backends/pipeline_host.rb#L2262)) | 111.20 | boobytrap=rank 3/hotspot 0.0721 |
| 13 | `PipeAnalysis#analyze_concurrent_op` ([`src/annotator/helpers/pipe_analysis.rb`](../../src/annotator/helpers/pipe_analysis.rb#L1440)) | 110.90 | decomplex=6 detectors/score 11 |
| 14 | `MIRLoweringConcurrency#lower_bg_stream_block` ([`src/mir/lowering/concurrency.rb`](../../src/mir/lowering/concurrency.rb#L704)) | 108.40 | boobytrap=rank 40/hotspot 0.0049 |
| 15 | `PipelineHost#lower_batch_window` ([`src/backends/pipeline_host.rb`](../../src/backends/pipeline_host.rb#L1699)) | 102.10 | boobytrap=rank 3/hotspot 0.0721 |
| 16 | `AST::Locatable#finalize_storage!` ([`src/ast/ast.rb`](../../src/ast/ast.rb#L886)) | 101.40 | decomplex=5 detectors/score 11, slopcop=rank 69, boobytrap=rank 7/hotspot 0.0404 |
| 17 | `FunctionAnalysis#resolve_call` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L92)) | 100.50 | decomplex=5 detectors/score 10, boobytrap=rank 28/hotspot 0.0092 |
| 18 | `MIRLoweringControlFlow#for_each_loop_stmt` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb#L320)) | 99.60 | boobytrap=rank 34/hotspot 0.0062 |
| 19 | `MethodAnalysis#resolve_typed_method` ([`src/annotator/helpers/method_analysis.rb`](../../src/annotator/helpers/method_analysis.rb#L59)) | 99.50 | boobytrap=rank 30/hotspot 0.0087 |
| 20 | `MIRChecker#check_fn!` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb#L219)) | 95.50 | boobytrap=rank 16/hotspot 0.02 |
