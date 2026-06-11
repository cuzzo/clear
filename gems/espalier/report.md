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
- [Privatization Candidates](#privatization-candidates)
- [Cross-Tool Overlap](#cross-tool-overlap)

## Project Prioritization
- Highest architecture-pressure owner: `MIRLowering` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb)) (score=721.10, state=1, methods=252).
- Highest coordinator/mutator collision: `FunctionAnalysis#visit_FunctionDef` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L175)) (score=126.70, writes=0, conditional calls=43).
- Highest state lifecycle pressure: `@result_type` in `MIR` ([`src/mir/mir.rb`](../../src/mir/mir.rb)) (score=69.00, readers=10, writers=18).
- Strongest visibility-tightening candidate: `MIRLowering#emit_expr` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb#L3365)) (score=8.50, internal callers=1).
- Start where architecture pressure overlaps Decomplex/Boobytrap/SlopCop/NilKill evidence; those are more likely root-cause work than local cleanup.

## Run Summary
- Modules/classes indexed: 647
- Functions indexed: 5325
- State slots indexed: 412
- Effect reads/writes: 740/560
- Delegation edges: 33916
- Manifest/source byte ratio: 82.42% (3290544 / 3992315)
- Manifest/source word ratio: 64.54% (247278 / 383155)

## State Owner Pressure
_State-heavy owners with broad method/delegation surfaces._

| # | owner | score | flags | state | methods | state touches | delegations | suggested refactor |
|---|-------|-------|-------|-------|---------|---------------|-------------|--------------------|
| 1 | `MIRLowering` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb)) | 721.10 | broad-delegator | 1 | 252 | 2 | 1610 | separate coordinator from mechanism helpers |
| 2 | `Type` ([`src/ast/type.rb`](../../src/ast/type.rb)) | 707.05 | state-heavy, many-mutators, broad-delegator | 9 | 271 | 37 | 1323 | separate coordinator from mechanism helpers |
| 3 | `Parser` ([`src/ast/parser.rb`](../../src/ast/parser.rb)) | 619.90 | state-heavy, many-mutators, broad-delegator | 7 | 144 | 41 | 1298 | separate coordinator from mechanism helpers |
| 4 | `MIREmitter` ([`src/mir/mir_emitter.rb`](../../src/mir/mir_emitter.rb)) | 609.20 | state-heavy, many-mutators, broad-delegator | 7 | 191 | 29 | 1228 | separate coordinator from mechanism helpers |
| 5 | `MIR` ([`src/mir/mir.rb`](../../src/mir/mir.rb)) | 529.45 | state-heavy, many-mutators, broad-delegator | 10 | 330 | 53 | 571 | separate coordinator from mechanism helpers |
| 6 | `MIRChecker` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb)) | 469.05 | broad-delegator | 2 | 120 | 48 | 947 | separate coordinator from mechanism helpers |
| 7 | `MIRLoweringExpressions` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb)) | 453.05 | broad-delegator | 0 | 107 | 0 | 1111 | separate coordinator from mechanism helpers |
| 8 | `PipeAnalysis` ([`src/annotator/helpers/pipe_analysis.rb`](../../src/annotator/helpers/pipe_analysis.rb)) | 377.85 | broad-delegator | 0 | 68 | 0 | 963 | separate coordinator from mechanism helpers |
| 9 | `MIRLoweringFunctions` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb)) | 368.90 | broad-delegator | 0 | 77 | 0 | 922 | separate coordinator from mechanism helpers |
| 10 | `PipelineHost` ([`src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) | 367.05 | state-heavy, many-mutators, broad-delegator | 19 | 93 | 100 | 355 | separate coordinator from mechanism helpers |
| 11 | `Formatter::Emitter` ([`src/tools/formatter.rb`](../../src/tools/formatter.rb)) | 319.65 | broad-delegator | 3 | 104 | 6 | 683 | separate coordinator from mechanism helpers |
| 12 | `MIRLoweringVariables` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb)) | 301.65 | broad-delegator | 0 | 60 | 0 | 759 | separate coordinator from mechanism helpers |
| 13 | `PipelineConcurrentLowerer` ([`src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb`](../../src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb)) | 298.00 | broad-delegator | 0 | 79 | 0 | 716 | separate coordinator from mechanism helpers |
| 14 | `MIRLoweringControlFlow` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb)) | 296.50 | broad-delegator | 0 | 73 | 0 | 722 | separate coordinator from mechanism helpers |
| 15 | `AST` ([`src/ast/ast.rb`](../../src/ast/ast.rb)) | 267.90 | many-mutators, broad-delegator | 2 | 186 | 5 | 398 | separate coordinator from mechanism helpers |
| 16 | `FunctionSignature` ([`src/annotator/helpers/function_signature.rb`](../../src/annotator/helpers/function_signature.rb)) | 265.45 | state-heavy, many-mutators, broad-delegator | 29 | 44 | 75 | 163 | extract phase-state records and split lifecycle ownership |
| 17 | `FunctionAnalysis` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb)) | 247.00 | broad-delegator | 0 | 50 | 0 | 620 | separate coordinator from mechanism helpers |
| 18 | `EscapeAnalysis` ([`src/semantic/escape_analysis.rb`](../../src/semantic/escape_analysis.rb)) | 240.65 | broad-delegator | 0 | 82 | 0 | 547 | separate coordinator from mechanism helpers |
| 19 | `FixableHelper` ([`src/annotator/helpers/fixable_helpers.rb`](../../src/annotator/helpers/fixable_helpers.rb)) | 238.65 | many-mutators, broad-delegator | 1 | 60 | 11 | 507 | separate coordinator from mechanism helpers |
| 20 | `CleanupClassifier` ([`src/mir/cleanup_classifier.rb`](../../src/mir/cleanup_classifier.rb)) | 237.70 | broad-delegator | 0 | 73 | 0 | 554 | separate coordinator from mechanism helpers |

## Coordinator/Mutator Collisions
_Methods that both mutate phase state and coordinate many calls._

| # | method | score | reads | writes | always | conditional | overlap | suggested refactor |
|---|--------|-------|-------|--------|--------|-------------|---------|--------------------|
| 1 | `FunctionAnalysis#visit_FunctionDef` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L175)) | 126.70 | 0 | 0 | 67 | 43 | boobytrap=rank 40/hotspot 0.0048 | reify operation variants or split branch coordinator |
| 2 | `FsmTransform::Emit#build_recursive` ([`src/mir/fsm_transform/emit.rb`](../../src/mir/fsm_transform/emit.rb#L687)) | 117.80 | 0 | 0 | 58 | 42 | slopcop=rank 1, boobytrap=rank 10/hotspot 13.696 | reify operation variants or split branch coordinator |
| 3 | `PipelineHost#initialize` ([`src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb#L42)) | 117.00 | 0 | 19 | 15 | 0 | - | move writes behind a smaller state object or transaction helper |
| 4 | `Annotator::Domains::Variables#finalize_decl_node!` ([`src/annotator/domains/variables.rb`](../../src/annotator/domains/variables.rb#L82)) | 106.00 | 0 | 0 | 39 | 44 | privacy_candidate=true, privacy_score=7.0, privacy_confidence=medium, boobytrap=rank 38/hotspot 0.0062 | reify operation variants or split branch coordinator |
| 5 | `PipeAnalysis#analyze_concurrent_op` ([`src/annotator/helpers/pipe_analysis.rb`](../../src/annotator/helpers/pipe_analysis.rb#L1445)) | 105.90 | 0 | 0 | 24 | 51 | decomplex=7 detectors/score 15 | reify operation variants or split branch coordinator |
| 6 | `MIREmitter#emit` ([`src/mir/mir_emitter.rb`](../../src/mir/mir_emitter.rb#L53)) | 102.50 | 0 | 0 | 126 | 1 | boobytrap=rank 22/hotspot 8.147 | extract decision table or named policy helper |
| 7 | `MIRLoweringVariables#lower_bind_expr` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb#L708)) | 101.80 | 0 | 0 | 4 | 58 | boobytrap=rank 19/hotspot 8.927 | reify operation variants or split branch coordinator |
| 8 | `MIRLoweringFunctions#lower_function_def` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L287)) | 101.70 | 0 | 0 | 23 | 49 | boobytrap=rank 9/hotspot 13.772 | reify operation variants or split branch coordinator |
| 9 | `Annotator::Phases::BodyAnalysis#record_body_fact_node!` ([`src/annotator/phases/body_analysis.rb`](../../src/annotator/phases/body_analysis.rb#L326)) | 94.70 | 0 | 0 | 27 | 43 | boobytrap=rank 30/hotspot 6.683 | reify operation variants or split branch coordinator |
| 10 | `MIRChecker#check_fn!` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb#L356)) | 93.00 | 0 | 2 | 36 | 26 | decomplex=7 detectors/score 17, boobytrap=rank 20/hotspot 8.899 | reify operation variants or split branch coordinator |
| 11 | `Annotator::Domains::MemberAccess#visit_GetField` ([`src/annotator/domains/member_access.rb`](../../src/annotator/domains/member_access.rb#L61)) | 91.90 | 0 | 0 | 15 | 47 | - | reify operation variants or split branch coordinator |
| 12 | `Annotator::Domains::Errors#visit_ReturnNode` ([`src/annotator/domains/errors.rb`](../../src/annotator/domains/errors.rb#L369)) | 90.50 | 0 | 1 | 20 | 35 | boobytrap=rank 14/hotspot 12.313 | reify operation variants or split branch coordinator |
| 13 | `Parser#parse_function_def` ([`src/ast/parser.rb`](../../src/ast/parser.rb#L1269)) | 90.10 | 4 | 0 | 35 | 33 | decomplex=7 detectors/score 14 | reify operation variants or split branch coordinator |
| 14 | `FunctionAnalysis#resolve_call` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L330)) | 89.80 | 0 | 0 | 6 | 50 | decomplex=7 detectors/score 15, boobytrap=rank 40/hotspot 0.0048 | reify operation variants or split branch coordinator |
| 15 | `MIRLoweringControlFlow#for_each_loop_stmt` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb#L362)) | 88.10 | 0 | 0 | 6 | 49 | privacy_candidate=true, privacy_score=5.0, privacy_confidence=low, boobytrap=rank 21/hotspot 8.231 | reify operation variants or split branch coordinator |
| 16 | `Annotator::Domains::MemberAccess#visit_StructLit` ([`src/annotator/domains/member_access.rb`](../../src/annotator/domains/member_access.rb#L246)) | 86.70 | 0 | 0 | 17 | 43 | - | reify operation variants or split branch coordinator |
| 17 | `Type#compute_zig_type` ([`src/ast/type.rb`](../../src/ast/type.rb#L3392)) | 86.40 | 0 | 0 | 6 | 48 | - | reify operation variants or split branch coordinator |
| 18 | `MIRLowering#lower` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb#L877)) | 79.60 | 0 | 0 | 91 | 4 | boobytrap=rank 1/hotspot 22.664 | extract decision table or named policy helper |
| 19 | `PipelineRewriter#rewrite_pipeline` ([`src/backends/pipeline_rewriter.rb`](../../src/backends/pipeline_rewriter.rb#L97)) | 79.10 | 0 | 0 | 16 | 39 | - | reify operation variants or split branch coordinator |
| 20 | `Annotator::Domains::ExecutionBoundaries#visit_WithBlock` ([`src/annotator/domains/execution_boundaries.rb`](../../src/annotator/domains/execution_boundaries.rb#L12)) | 77.80 | 0 | 0 | 42 | 26 | decomplex=7 detectors/score 13 | reify operation variants or split branch coordinator |

## Conditional Delegation Hubs
_Branchy orchestration boundaries, independent of direct state writes._

| # | method | conditional calls | always calls | state touches | suggested refactor |
|---|--------|-------------------|--------------|---------------|--------------------|
| 1 | `MIRLoweringVariables#lower_bind_expr` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb#L708)) | 58 | 4 | 0 | replace branch hub with reified operation dispatch |
| 2 | `PipeAnalysis#analyze_concurrent_op` ([`src/annotator/helpers/pipe_analysis.rb`](../../src/annotator/helpers/pipe_analysis.rb#L1445)) | 51 | 24 | 0 | replace branch hub with reified operation dispatch |
| 3 | `FunctionAnalysis#resolve_call` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L330)) | 50 | 6 | 0 | replace branch hub with reified operation dispatch |
| 4 | `MIRLoweringFunctions#lower_function_def` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L287)) | 49 | 23 | 0 | replace branch hub with reified operation dispatch |
| 5 | `MIRLoweringControlFlow#for_each_loop_stmt` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb#L362)) | 49 | 6 | 0 | replace branch hub with reified operation dispatch |
| 6 | `Type#compute_zig_type` ([`src/ast/type.rb`](../../src/ast/type.rb#L3392)) | 48 | 6 | 0 | replace branch hub with reified operation dispatch |
| 7 | `Annotator::Domains::MemberAccess#visit_GetField` ([`src/annotator/domains/member_access.rb`](../../src/annotator/domains/member_access.rb#L61)) | 47 | 15 | 0 | replace branch hub with reified operation dispatch |
| 8 | `Annotator::Domains::Variables#finalize_decl_node!` ([`src/annotator/domains/variables.rb`](../../src/annotator/domains/variables.rb#L82)) | 44 | 39 | 0 | replace branch hub with reified operation dispatch |
| 9 | `FunctionAnalysis#visit_FunctionDef` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L175)) | 43 | 67 | 0 | replace branch hub with reified operation dispatch |
| 10 | `Annotator::Phases::BodyAnalysis#record_body_fact_node!` ([`src/annotator/phases/body_analysis.rb`](../../src/annotator/phases/body_analysis.rb#L326)) | 43 | 27 | 0 | replace branch hub with reified operation dispatch |
| 11 | `Annotator::Domains::MemberAccess#visit_StructLit` ([`src/annotator/domains/member_access.rb`](../../src/annotator/domains/member_access.rb#L246)) | 43 | 17 | 0 | replace branch hub with reified operation dispatch |
| 12 | `FsmTransform::Emit#build_recursive` ([`src/mir/fsm_transform/emit.rb`](../../src/mir/fsm_transform/emit.rb#L687)) | 42 | 58 | 0 | replace branch hub with reified operation dispatch |
| 13 | `PipelineRewriter#rewrite_pipeline` ([`src/backends/pipeline_rewriter.rb`](../../src/backends/pipeline_rewriter.rb#L97)) | 39 | 16 | 0 | replace branch hub with reified operation dispatch |
| 14 | `MIRLoweringExpressions#index_access_value` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb#L1246)) | 38 | 7 | 0 | replace branch hub with reified operation dispatch |
| 15 | `Annotator::Domains::Variables#visit_BindExpr` ([`src/annotator/domains/variables.rb`](../../src/annotator/domains/variables.rb#L275)) | 36 | 3 | 0 | replace branch hub with reified operation dispatch |
| 16 | `Annotator::Domains::Errors#visit_ReturnNode` ([`src/annotator/domains/errors.rb`](../../src/annotator/domains/errors.rb#L369)) | 35 | 20 | 1 | replace branch hub with reified operation dispatch |
| 17 | `Annotator::Domains::ExecutionBoundaries#visit_NextExpr` ([`src/annotator/domains/execution_boundaries.rb`](../../src/annotator/domains/execution_boundaries.rb#L829)) | 35 | 4 | 0 | replace branch hub with reified operation dispatch |
| 18 | `FsmLowering#lower_step_stmts` ([`src/mir/fsm_lowering.rb`](../../src/mir/fsm_lowering.rb#L79)) | 35 | 4 | 0 | replace branch hub with reified operation dispatch |
| 19 | `MIRLoweringExpressions#lower_struct_lit` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb#L1489)) | 34 | 15 | 0 | replace branch hub with reified operation dispatch |
| 20 | `Parser#parse_function_def` ([`src/ast/parser.rb`](../../src/ast/parser.rb#L1269)) | 33 | 35 | 4 | replace branch hub with reified operation dispatch |

## State Lifecycle Pressure
_State slots with many readers/writers or protocol-shaped behavior._

| # | state | owner | score | readers | writers | type | protocol evidence | suggested refactor |
|---|-------|-------|-------|---------|---------|------|-------------------|--------------------|
| 1 | `@result_type` | `MIR` ([`src/mir/mir.rb`](../../src/mir/mir.rb)) | 69.00 | 10 | 18 | T.nilable(Type) | - | centralize writes behind one owner |
| 2 | `@errors` | `MIRChecker` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb)) | 66.00 | 40 | 2 | T::Array[T.untyped] | - | verify this state belongs on the owner |
| 3 | `@receiver_state` | `SemanticAnnotator` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb)) | 54.00 | 32 | 2 | ReceiverState | - | verify this state belongs on the owner |
| 4 | `@capabilities` | `Type` ([`src/ast/type.rb`](../../src/ast/type.rb)) | 33.00 | 14 | 4 | TypeCapabilities | - | centralize writes behind one owner |
| 5 | `@rt_name` | `MIREmitter` ([`src/mir/mir_emitter.rb`](../../src/mir/mir_emitter.rb)) | 33.00 | 14 | 4 | String | - | centralize writes behind one owner |
| 6 | `@pos` | `Parser` ([`src/ast/parser.rb`](../../src/ast/parser.rb)) | 31.50 | 11 | 5 | Integer | - | centralize writes behind one owner |
| 7 | `@lowering` | `PipelineLoweringBridge` ([`src/mir/lower/pipeline/pipeline_lowering_bridge.rb`](../../src/mir/lower/pipeline/pipeline_lowering_bridge.rb)) | 31.50 | 19 | 1 | MIRLowering | - | verify this state belongs on the owner |
| 8 | `@host` | `PipelineRangeLowerer` ([`src/mir/lower/pipeline/pipeline_range_lowerer.rb`](../../src/mir/lower/pipeline/pipeline_range_lowerer.rb)) | 31.50 | 19 | 1 | PipelineRangeLowerer::Host | - | verify this state belongs on the owner |
| 9 | `@source_code` | `FixableHelper` ([`src/annotator/helpers/fixable_helpers.rb`](../../src/annotator/helpers/fixable_helpers.rb)) | 30.00 | 2 | 9 | T.nilable(String) | - | centralize writes behind one owner |
| 10 | `@range_lowerer` | `PipelineHost` ([`src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) | 28.50 | 17 | 1 | PipelineRangeLowerer | - | verify this state belongs on the owner |
| 11 | `@bindings` | `Scope` ([`src/ast/scope.rb`](../../src/ast/scope.rb)) | 25.50 | 13 | 2 | ScopeBindings | - | verify this state belongs on the owner |
| 12 | `@flow` | `SymbolEntry` ([`src/ast/symbol_entry.rb`](../../src/ast/symbol_entry.rb)) | 24.00 | 12 | 2 | BindingFlowFacts | - | verify this state belongs on the owner |
| 13 | `@logger` | `LSP::Server` ([`src/lsp/server.rb`](../../src/lsp/server.rb)) | 24.00 | 14 | 1 | Logger | - | verify this state belongs on the owner |
| 14 | `@list_lowerer` | `PipelineHost` ([`src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) | 21.00 | 12 | 1 | PipelineListLowerer | - | verify this state belongs on the owner |
| 15 | `@parent` | `Scope` ([`src/ast/scope.rb`](../../src/ast/scope.rb)) | 18.00 | 8 | 2 | T.nilable(Scope) | - | verify this state belongs on the owner |
| 16 | `@zig_type_cache` | `Type` ([`src/ast/type.rb`](../../src/ast/type.rb)) | 18.00 | 0 | 6 | T.nilable(String) | - | centralize writes behind one owner |
| 17 | `@current_pipe_label` | `PipelineHost` ([`src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) | 18.00 | 0 | 6 | T.nilable(String) | - | centralize writes behind one owner |
| 18 | `@lowering_bridge` | `PipelineHost` ([`src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) | 18.00 | 10 | 1 | PipelineLoweringBridge | - | verify this state belongs on the owner |
| 19 | `@findings` | `FixCollector` ([`src/ast/fixable_error.rb`](../../src/ast/fixable_error.rb)) | 16.50 | 5 | 3 | - | - | verify this state belongs on the owner |
| 20 | `@tokens` | `Parser` ([`src/ast/parser.rb`](../../src/ast/parser.rb)) | 16.50 | 9 | 1 | - | - | verify this state belongs on the owner |

## Privatization Candidates
_Public methods that likely should be private: same-owner callers, no manifest-visible external receiver calls, and helper/protocol evidence._

| # | method | score | confidence | internal callers | state touches | reason |
|---|--------|-------|------------|------------------|---------------|--------|
| 1 | `MIRLowering#emit_expr` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb#L3365)) | 8.50 | high | emit_stmts_zig | 0 | public but only has same-owner callers; single internal caller: emit_stmts_zig; coordinates 2 internal call(s); helper-shaped name; no manifest-visible external receiver call |
| 2 | `SemanticAnnotator#with_loop_context` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb#L311)) | 8.00 | high | analyze_loop_control_flow_branches | 1 | public but only has same-owner callers; single internal caller: analyze_loop_control_flow_branches; stateful step reads=1 writes=0; coordinates 1 internal call(s); no manifest-visible external receiver call |
| 3 | `Annotator::Domains::ControlFlow#check_match_exhaustiveness!` ([`src/annotator/domains/control_flow.rb`](../../src/annotator/domains/control_flow.rb#L629)) | 8.00 | high | visit_MatchStatement | 0 | public but only has same-owner callers; single internal caller: visit_MatchStatement; coordinates 1 internal call(s); helper-shaped name; no manifest-visible external receiver call |
| 4 | `Annotator::Domains::ControlFlow#declare_match_destructure_fields!` ([`src/annotator/domains/control_flow.rb`](../../src/annotator/domains/control_flow.rb#L581)) | 8.00 | high | declare_match_destructure_bindings! | 0 | public but only has same-owner callers; single internal caller: declare_match_destructure_bindings!; coordinates 1 internal call(s); helper-shaped name; no manifest-visible external receiver call |
| 5 | `Annotator::Domains::ControlFlow#reject_duplicate_match_patterns!` ([`src/annotator/domains/control_flow.rb`](../../src/annotator/domains/control_flow.rb#L614)) | 8.00 | high | visit_MatchStatement | 0 | public but only has same-owner callers; single internal caller: visit_MatchStatement; coordinates 1 internal call(s); helper-shaped name; no manifest-visible external receiver call |
| 6 | `Annotator::Domains::ControlFlow#validate_match_pattern_types!` ([`src/annotator/domains/control_flow.rb`](../../src/annotator/domains/control_flow.rb#L468)) | 8.00 | high | analyze_value_match_case! | 0 | public but only has same-owner callers; single internal caller: analyze_value_match_case!; coordinates 1 internal call(s); helper-shaped name; no manifest-visible external receiver call |
| 7 | `Annotator::Domains::ControlFlow#visit_match_patterns!` ([`src/annotator/domains/control_flow.rb`](../../src/annotator/domains/control_flow.rb#L453)) | 8.00 | high | analyze_value_match_case! | 0 | public but only has same-owner callers; single internal caller: analyze_value_match_case!; coordinates 1 internal call(s); helper-shaped name; no manifest-visible external receiver call |
| 8 | `Annotator::Domains::Errors#return_type_compatible?` ([`src/annotator/domains/errors.rb`](../../src/annotator/domains/errors.rb#L513)) | 8.00 | high | visit_ReturnNode | 0 | public but only has same-owner callers; single internal caller: visit_ReturnNode; coordinates 1 internal call(s); helper-shaped name; no manifest-visible external receiver call |
| 9 | `Annotator::Domains::ExecutionBoundaries#mark_unrequired_polymorphic_with_runtime!` ([`src/annotator/domains/execution_boundaries.rb`](../../src/annotator/domains/execution_boundaries.rb#L226)) | 8.00 | high | mark_with_runtime_requirements! | 0 | public but only has same-owner callers; single internal caller: mark_with_runtime_requirements!; coordinates 1 internal call(s); helper-shaped name; no manifest-visible external receiver call |
| 10 | `Annotator::Domains::ExecutionBoundaries#validate_no_multi_object_atomic!` ([`src/annotator/domains/execution_boundaries.rb`](../../src/annotator/domains/execution_boundaries.rb#L460)) | 8.00 | high | visit_WithBlock | 0 | public but only has same-owner callers; single internal caller: visit_WithBlock; coordinates 1 internal call(s); helper-shaped name; no manifest-visible external receiver call |
| 11 | `Annotator::Domains::ExecutionBoundaries#with_block_uses_runtime?` ([`src/annotator/domains/execution_boundaries.rb`](../../src/annotator/domains/execution_boundaries.rb#L210)) | 8.00 | high | mark_with_runtime_requirements! | 0 | public but only has same-owner callers; single internal caller: mark_with_runtime_requirements!; coordinates 1 internal call(s); helper-shaped name; no manifest-visible external receiver call |
| 12 | `Annotator::Domains::Lifetimes#bg_capture_independent?` ([`src/annotator/domains/lifetimes.rb`](../../src/annotator/domains/lifetimes.rb#L1011)) | 8.00 | high | bg_lifetime_sources | 0 | public but only has same-owner callers; single internal caller: bg_lifetime_sources; coordinates 1 internal call(s); helper-shaped name; no manifest-visible external receiver call |
| 13 | `Annotator::Domains::Lifetimes#collect_bg_sources_walk` ([`src/annotator/domains/lifetimes.rb`](../../src/annotator/domains/lifetimes.rb#L964)) | 8.00 | high | collect_bg_sources_in_expr | 0 | public but only has same-owner callers; single internal caller: collect_bg_sources_in_expr; coordinates 1 internal call(s); helper-shaped name; no manifest-visible external receiver call |
| 14 | `Annotator::Domains::Lifetimes#reject_borrowed_index_assignment_move!` ([`src/annotator/domains/lifetimes.rb`](../../src/annotator/domains/lifetimes.rb#L376)) | 8.00 | high | handle_assignment_path_move! | 0 | public but only has same-owner callers; single internal caller: handle_assignment_path_move!; coordinates 1 internal call(s); helper-shaped name; no manifest-visible external receiver call |
| 15 | `Annotator::Domains::Variables#finalize_decl_node!` ([`src/annotator/domains/variables.rb`](../../src/annotator/domains/variables.rb#L82)) | 8.00 | high | visit_BindExpr, visit_VarDecl | 0 | public but only has same-owner callers; coordinates 4 internal call(s); helper-shaped name; no manifest-visible external receiver call |
| 16 | `CapabilityHelper#declare_restrict_capability!` ([`src/annotator/helpers/capabilities.rb`](../../src/annotator/helpers/capabilities.rb#L923)) | 8.00 | high | declare_capability_projection! | 0 | public but only has same-owner callers; single internal caller: declare_capability_projection!; coordinates 1 internal call(s); helper-shaped name; no manifest-visible external receiver call |
| 17 | `CapabilityHelper#declare_snapshot_capability!` ([`src/annotator/helpers/capabilities.rb`](../../src/annotator/helpers/capabilities.rb#L968)) | 8.00 | high | declare_capability_projection! | 0 | public but only has same-owner callers; single internal caller: declare_capability_projection!; coordinates 1 internal call(s); helper-shaped name; no manifest-visible external receiver call |
| 18 | `CapabilityHelper#record_capture_local!` ([`src/annotator/helpers/capabilities.rb`](../../src/annotator/helpers/capabilities.rb#L1102)) | 8.00 | high | declare_borrowed_capability!, declare_restrict_alias!, declare_snapshot_capability!, declare_unwrapped_capability_alias!, declare_view_capability! | 0 | public but only has same-owner callers; coordinates 1 internal call(s); helper-shaped name; no manifest-visible external receiver call |
| 19 | `CapabilityHelper#with_capability_fact` ([`src/annotator/helpers/capabilities.rb`](../../src/annotator/helpers/capabilities.rb#L827)) | 8.00 | high | acquire_capability! | 0 | public but only has same-owner callers; single internal caller: acquire_capability!; coordinates 5 internal call(s); no manifest-visible external receiver call |
| 20 | `EffectTracker#assign_async_stack_tier!` ([`src/annotator/helpers/effects.rb`](../../src/annotator/helpers/effects.rb#L885)) | 8.00 | high | finalize_async_execution_shapes! | 0 | public but only has same-owner callers; single internal caller: finalize_async_execution_shapes!; coordinates 1 internal call(s); helper-shaped name; no manifest-visible external receiver call |

## Cross-Tool Overlap
_Architectural pressure with sibling-tool metadata already attached._

| # | method | architecture score | overlap |
|---|--------|--------------------|---------|
| 1 | `FunctionAnalysis#visit_FunctionDef` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L175)) | 126.70 | boobytrap=rank 40/hotspot 0.0048 |
| 2 | `FsmTransform::Emit#build_recursive` ([`src/mir/fsm_transform/emit.rb`](../../src/mir/fsm_transform/emit.rb#L687)) | 117.80 | slopcop=rank 1, boobytrap=rank 10/hotspot 13.696 |
| 3 | `Annotator::Domains::Variables#finalize_decl_node!` ([`src/annotator/domains/variables.rb`](../../src/annotator/domains/variables.rb#L82)) | 106.00 | privacy_candidate=true, privacy_score=7.0, privacy_confidence=medium, boobytrap=rank 38/hotspot 0.0062 |
| 4 | `PipeAnalysis#analyze_concurrent_op` ([`src/annotator/helpers/pipe_analysis.rb`](../../src/annotator/helpers/pipe_analysis.rb#L1445)) | 105.90 | decomplex=7 detectors/score 15 |
| 5 | `MIREmitter#emit` ([`src/mir/mir_emitter.rb`](../../src/mir/mir_emitter.rb#L53)) | 102.50 | boobytrap=rank 22/hotspot 8.147 |
| 6 | `MIRLoweringVariables#lower_bind_expr` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb#L708)) | 101.80 | boobytrap=rank 19/hotspot 8.927 |
| 7 | `MIRLoweringFunctions#lower_function_def` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L287)) | 101.70 | boobytrap=rank 9/hotspot 13.772 |
| 8 | `Annotator::Phases::BodyAnalysis#record_body_fact_node!` ([`src/annotator/phases/body_analysis.rb`](../../src/annotator/phases/body_analysis.rb#L326)) | 94.70 | boobytrap=rank 30/hotspot 6.683 |
| 9 | `MIRChecker#check_fn!` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb#L356)) | 93.00 | decomplex=7 detectors/score 17, boobytrap=rank 20/hotspot 8.899 |
| 10 | `Annotator::Domains::Errors#visit_ReturnNode` ([`src/annotator/domains/errors.rb`](../../src/annotator/domains/errors.rb#L369)) | 90.50 | boobytrap=rank 14/hotspot 12.313 |
| 11 | `Parser#parse_function_def` ([`src/ast/parser.rb`](../../src/ast/parser.rb#L1269)) | 90.10 | decomplex=7 detectors/score 14 |
| 12 | `FunctionAnalysis#resolve_call` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L330)) | 89.80 | decomplex=7 detectors/score 15, boobytrap=rank 40/hotspot 0.0048 |
| 13 | `MIRLoweringControlFlow#for_each_loop_stmt` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb#L362)) | 88.10 | privacy_candidate=true, privacy_score=5.0, privacy_confidence=low, boobytrap=rank 21/hotspot 8.231 |
| 14 | `MIRLowering#lower` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb#L877)) | 79.60 | boobytrap=rank 1/hotspot 22.664 |
| 15 | `Annotator::Domains::ExecutionBoundaries#visit_WithBlock` ([`src/annotator/domains/execution_boundaries.rb`](../../src/annotator/domains/execution_boundaries.rb#L12)) | 77.80 | decomplex=7 detectors/score 13 |
| 16 | `MIRLoweringLiterals#lower_list_lit` ([`src/mir/lowering/literals.rb`](../../src/mir/lowering/literals.rb#L81)) | 74.40 | boobytrap=rank 39/hotspot 1.166 |
| 17 | `MIRLoweringConcurrency#lower_bg_stream_block` ([`src/mir/lowering/concurrency.rb`](../../src/mir/lowering/concurrency.rb#L1000)) | 74.00 | slopcop=rank 23, boobytrap=rank 2/hotspot 22.35 |
| 18 | `Doctor#section_heap` ([`src/tools/doctor.rb`](../../src/tools/doctor.rb#L123)) | 71.40 | privacy_candidate=true, privacy_score=7.0, privacy_confidence=medium, decomplex=7 detectors/score 15, slopcop=rank 45 |
| 19 | `MIRLoweringExpressions#index_access_value` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb#L1246)) | 70.20 | privacy_candidate=true, privacy_score=5.5, privacy_confidence=low, boobytrap=rank 35/hotspot 2.065 |
| 20 | `MIRLoweringExpressions#lower_struct_lit` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb#L1489)) | 69.80 | boobytrap=rank 35/hotspot 2.065 |
