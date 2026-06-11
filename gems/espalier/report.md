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
- Highest architecture-pressure owner: `MIRLowering` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb)) (score=721.10, state=1, methods=252).
- Highest coordinator/mutator collision: `FunctionAnalysis#visit_FunctionDef` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L175)) (score=126.70, writes=0, conditional calls=43).
- Highest state lifecycle pressure: `@errors` in `MIRChecker` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb)) (score=74.00, readers=40, writers=2).
- Start where architecture pressure overlaps Decomplex/Boobytrap/SlopCop/NilKill evidence; those are more likely root-cause work than local cleanup.

## Run Summary
- Modules/classes indexed: 647
- Functions indexed: 5325
- State slots indexed: 412
- Effect reads/writes: 740/560
- Delegation edges: 33903
- Manifest/source byte ratio: 45.75% (1823367 / 3985662)
- Manifest/source word ratio: 38.47% (147282 / 382893)

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
| 16 | `FunctionSignature` ([`src/annotator/helpers/function_signature.rb`](../../src/annotator/helpers/function_signature.rb)) | 264.75 | state-heavy, many-mutators, broad-delegator | 29 | 44 | 75 | 161 | extract phase-state records and split lifecycle ownership |
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
| 4 | `Annotator::Domains::Variables#finalize_decl_node!` ([`src/annotator/domains/variables.rb`](../../src/annotator/domains/variables.rb#L82)) | 106.00 | 0 | 0 | 39 | 44 | boobytrap=rank 38/hotspot 0.0062 | reify operation variants or split branch coordinator |
| 5 | `PipeAnalysis#analyze_concurrent_op` ([`src/annotator/helpers/pipe_analysis.rb`](../../src/annotator/helpers/pipe_analysis.rb#L1445)) | 105.90 | 0 | 0 | 24 | 51 | decomplex=6 detectors/score 13 | reify operation variants or split branch coordinator |
| 6 | `MIREmitter#emit` ([`src/mir/mir_emitter.rb`](../../src/mir/mir_emitter.rb#L53)) | 102.50 | 0 | 0 | 126 | 1 | boobytrap=rank 22/hotspot 8.147 | extract decision table or named policy helper |
| 7 | `MIRLoweringVariables#lower_bind_expr` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb#L708)) | 101.80 | 0 | 0 | 4 | 58 | boobytrap=rank 19/hotspot 8.927 | reify operation variants or split branch coordinator |
| 8 | `MIRLoweringFunctions#lower_function_def` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L287)) | 101.70 | 0 | 0 | 23 | 49 | boobytrap=rank 9/hotspot 13.772 | reify operation variants or split branch coordinator |
| 9 | `Annotator::Phases::BodyAnalysis#record_body_fact_node!` ([`src/annotator/phases/body_analysis.rb`](../../src/annotator/phases/body_analysis.rb#L326)) | 94.70 | 0 | 0 | 27 | 43 | boobytrap=rank 30/hotspot 6.683 | reify operation variants or split branch coordinator |
| 10 | `MIRChecker#check_fn!` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb#L356)) | 93.00 | 0 | 2 | 36 | 26 | decomplex=5 detectors/score 13, boobytrap=rank 20/hotspot 8.899 | reify operation variants or split branch coordinator |
| 11 | `Annotator::Domains::MemberAccess#visit_GetField` ([`src/annotator/domains/member_access.rb`](../../src/annotator/domains/member_access.rb#L61)) | 91.90 | 0 | 0 | 15 | 47 | - | reify operation variants or split branch coordinator |
| 12 | `Annotator::Domains::Errors#visit_ReturnNode` ([`src/annotator/domains/errors.rb`](../../src/annotator/domains/errors.rb#L369)) | 90.50 | 0 | 1 | 20 | 35 | boobytrap=rank 14/hotspot 12.313 | reify operation variants or split branch coordinator |
| 13 | `Parser#parse_function_def` ([`src/ast/parser.rb`](../../src/ast/parser.rb#L1269)) | 90.10 | 4 | 0 | 35 | 33 | - | reify operation variants or split branch coordinator |
| 14 | `FunctionAnalysis#resolve_call` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L330)) | 89.80 | 0 | 0 | 6 | 50 | decomplex=6 detectors/score 13, boobytrap=rank 40/hotspot 0.0048 | reify operation variants or split branch coordinator |
| 15 | `MIRLoweringControlFlow#for_each_loop_stmt` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb#L362)) | 88.10 | 0 | 0 | 6 | 49 | boobytrap=rank 21/hotspot 8.231 | reify operation variants or split branch coordinator |
| 16 | `Annotator::Domains::MemberAccess#visit_StructLit` ([`src/annotator/domains/member_access.rb`](../../src/annotator/domains/member_access.rb#L246)) | 86.70 | 0 | 0 | 17 | 43 | decomplex=6 detectors/score 12 | reify operation variants or split branch coordinator |
| 17 | `Type#compute_zig_type` ([`src/ast/type.rb`](../../src/ast/type.rb#L3392)) | 86.40 | 0 | 0 | 6 | 48 | - | reify operation variants or split branch coordinator |
| 18 | `MIRLowering#lower` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb#L877)) | 79.60 | 0 | 0 | 91 | 4 | boobytrap=rank 1/hotspot 22.664 | extract decision table or named policy helper |
| 19 | `PipelineRewriter#rewrite_pipeline` ([`src/backends/pipeline_rewriter.rb`](../../src/backends/pipeline_rewriter.rb#L97)) | 79.10 | 0 | 0 | 16 | 39 | - | reify operation variants or split branch coordinator |
| 20 | `Annotator::Domains::ExecutionBoundaries#visit_WithBlock` ([`src/annotator/domains/execution_boundaries.rb`](../../src/annotator/domains/execution_boundaries.rb#L12)) | 77.80 | 0 | 0 | 42 | 26 | - | reify operation variants or split branch coordinator |

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
| 1 | `@errors` | `MIRChecker` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb)) | 74.00 | 40 | 2 | Array | protocol interfaces: concat, << | wrap protocol in a small lifecycle object |
| 2 | `@result_type` | `MIR` ([`src/mir/mir.rb`](../../src/mir/mir.rb)) | 69.00 | 10 | 18 | T.nilable(Type) | - | centralize writes behind one owner |
| 3 | `@receiver_state` | `SemanticAnnotator` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb)) | 54.00 | 32 | 2 | SemanticAnnotator::ReceiverState | - | verify this state belongs on the owner |
| 4 | `@bindings` | `Scope` ([`src/ast/scope.rb`](../../src/ast/scope.rb)) | 33.50 | 13 | 2 | Scope::ScopeBindings | protocol interfaces: []=, [], key?, entries, length, keys | wrap protocol in a small lifecycle object |
| 5 | `@capabilities` | `Type` ([`src/ast/type.rb`](../../src/ast/type.rb)) | 33.00 | 14 | 4 | TypeCapabilities | - | centralize writes behind one owner |
| 6 | `@rt_name` | `MIREmitter` ([`src/mir/mir_emitter.rb`](../../src/mir/mir_emitter.rb)) | 33.00 | 14 | 4 | String | - | centralize writes behind one owner |
| 7 | `@pos` | `Parser` ([`src/ast/parser.rb`](../../src/ast/parser.rb)) | 31.50 | 11 | 5 | Integer | - | centralize writes behind one owner |
| 8 | `@lowering` | `PipelineLoweringBridge` ([`src/mir/lower/pipeline/pipeline_lowering_bridge.rb`](../../src/mir/lower/pipeline/pipeline_lowering_bridge.rb)) | 31.50 | 19 | 1 | MIRLowering | - | verify this state belongs on the owner |
| 9 | `@host` | `PipelineRangeLowerer` ([`src/mir/lower/pipeline/pipeline_range_lowerer.rb`](../../src/mir/lower/pipeline/pipeline_range_lowerer.rb)) | 31.50 | 19 | 1 | PipelineRangeLowerer::RuntimeHost | - | verify this state belongs on the owner |
| 10 | `@source_code` | `FixableHelper` ([`src/annotator/helpers/fixable_helpers.rb`](../../src/annotator/helpers/fixable_helpers.rb)) | 30.00 | 2 | 9 | T.nilable(String) | - | centralize writes behind one owner |
| 11 | `@range_lowerer` | `PipelineHost` ([`src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) | 28.50 | 17 | 1 | PipelineRangeLowerer | - | verify this state belongs on the owner |
| 12 | `@findings` | `FixCollector` ([`src/ast/fixable_error.rb`](../../src/ast/fixable_error.rb)) | 24.50 | 5 | 3 | - | protocol interfaces: nil?, <<, any?, count | wrap protocol in a small lifecycle object |
| 13 | `@tokens` | `Parser` ([`src/ast/parser.rb`](../../src/ast/parser.rb)) | 24.50 | 9 | 1 | Array | protocol interfaces: [] | wrap protocol in a small lifecycle object |
| 14 | `@flow` | `SymbolEntry` ([`src/ast/symbol_entry.rb`](../../src/ast/symbol_entry.rb)) | 24.00 | 12 | 2 | SymbolEntry::BindingFlowFacts | - | verify this state belongs on the owner |
| 15 | `@logger` | `LSP::Server` ([`src/lsp/server.rb`](../../src/lsp/server.rb)) | 24.00 | 14 | 1 | LSP::Logger | - | verify this state belongs on the owner |
| 16 | `@slots` | `AutoConstraintCollector` ([`src/annotator/helpers/auto_inference.rb`](../../src/annotator/helpers/auto_inference.rb)) | 23.00 | 8 | 1 | Hash | protocol interfaces: []=, [] | wrap protocol in a small lifecycle object |
| 17 | `@placeholders` | `MIR::InlineAllocMetadata` ([`src/mir/mir.rb`](../../src/mir/mir.rb)) | 23.00 | 8 | 1 | Hash | protocol interfaces: empty?, each, values, key?, [], each_key, dup, inspect | wrap protocol in a small lifecycle object |
| 18 | `@entries` | `Scope::ScopeBindings` ([`src/ast/scope.rb`](../../src/ast/scope.rb)) | 21.50 | 7 | 1 | Hash | protocol interfaces: [], []=, key?, keys, length, to_a, each | wrap protocol in a small lifecycle object |
| 19 | `@docs` | `LSP::DocumentStore` ([`src/lsp/document_store.rb`](../../src/lsp/document_store.rb)) | 21.50 | 7 | 1 | Hash | protocol interfaces: []=, [], delete, each_value | wrap protocol in a small lifecycle object |
| 20 | `@completed_nodes` | `OwnershipGraph` ([`src/semantic/ownership_graph.rb`](../../src/semantic/ownership_graph.rb)) | 21.50 | 3 | 3 | Hash | protocol interfaces: each, [] | wrap protocol in a small lifecycle object |

## Cross-Tool Overlap
_Architectural pressure with sibling-tool metadata already attached._

| # | method | architecture score | overlap |
|---|--------|--------------------|---------|
| 1 | `FunctionAnalysis#visit_FunctionDef` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L175)) | 126.70 | boobytrap=rank 40/hotspot 0.0048 |
| 2 | `FsmTransform::Emit#build_recursive` ([`src/mir/fsm_transform/emit.rb`](../../src/mir/fsm_transform/emit.rb#L687)) | 117.80 | slopcop=rank 1, boobytrap=rank 10/hotspot 13.696 |
| 3 | `Annotator::Domains::Variables#finalize_decl_node!` ([`src/annotator/domains/variables.rb`](../../src/annotator/domains/variables.rb#L82)) | 106.00 | boobytrap=rank 38/hotspot 0.0062 |
| 4 | `PipeAnalysis#analyze_concurrent_op` ([`src/annotator/helpers/pipe_analysis.rb`](../../src/annotator/helpers/pipe_analysis.rb#L1445)) | 105.90 | decomplex=6 detectors/score 13 |
| 5 | `MIREmitter#emit` ([`src/mir/mir_emitter.rb`](../../src/mir/mir_emitter.rb#L53)) | 102.50 | boobytrap=rank 22/hotspot 8.147 |
| 6 | `MIRLoweringVariables#lower_bind_expr` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb#L708)) | 101.80 | boobytrap=rank 19/hotspot 8.927 |
| 7 | `MIRLoweringFunctions#lower_function_def` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L287)) | 101.70 | boobytrap=rank 9/hotspot 13.772 |
| 8 | `Annotator::Phases::BodyAnalysis#record_body_fact_node!` ([`src/annotator/phases/body_analysis.rb`](../../src/annotator/phases/body_analysis.rb#L326)) | 94.70 | boobytrap=rank 30/hotspot 6.683 |
| 9 | `MIRChecker#check_fn!` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb#L356)) | 93.00 | decomplex=5 detectors/score 13, boobytrap=rank 20/hotspot 8.899 |
| 10 | `Annotator::Domains::Errors#visit_ReturnNode` ([`src/annotator/domains/errors.rb`](../../src/annotator/domains/errors.rb#L369)) | 90.50 | boobytrap=rank 14/hotspot 12.313 |
| 11 | `FunctionAnalysis#resolve_call` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L330)) | 89.80 | decomplex=6 detectors/score 13, boobytrap=rank 40/hotspot 0.0048 |
| 12 | `MIRLoweringControlFlow#for_each_loop_stmt` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb#L362)) | 88.10 | boobytrap=rank 21/hotspot 8.231 |
| 13 | `Annotator::Domains::MemberAccess#visit_StructLit` ([`src/annotator/domains/member_access.rb`](../../src/annotator/domains/member_access.rb#L246)) | 86.70 | decomplex=6 detectors/score 12 |
| 14 | `MIRLowering#lower` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb#L877)) | 79.60 | boobytrap=rank 1/hotspot 22.664 |
| 15 | `MIRLoweringLiterals#lower_list_lit` ([`src/mir/lowering/literals.rb`](../../src/mir/lowering/literals.rb#L81)) | 74.40 | boobytrap=rank 39/hotspot 1.166 |
| 16 | `MIRLoweringConcurrency#lower_bg_stream_block` ([`src/mir/lowering/concurrency.rb`](../../src/mir/lowering/concurrency.rb#L1000)) | 74.00 | slopcop=rank 23, boobytrap=rank 2/hotspot 22.35 |
| 17 | `Doctor#section_heap` ([`src/tools/doctor.rb`](../../src/tools/doctor.rb#L123)) | 71.40 | decomplex=8 detectors/score 16, slopcop=rank 45 |
| 18 | `MIRLoweringExpressions#index_access_value` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb#L1246)) | 70.20 | boobytrap=rank 35/hotspot 2.065 |
| 19 | `MIRLoweringExpressions#lower_struct_lit` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb#L1489)) | 69.80 | boobytrap=rank 35/hotspot 2.065 |
| 20 | `MIRChecker#check_linear_stmt!` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb#L575)) | 67.50 | boobytrap=rank 20/hotspot 8.899 |
