# Espalier Architecture Report

> Architecture-level state, effect, and delegation synthesis.
> Findings are review candidates, not verdicts.

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Run Summary](#run-summary)
- [State Owner Pressure](#state-owner-pressure)
- [Encapsulation Pressure](#encapsulation-pressure)
- [Owner State Cohesion](#owner-state-cohesion)
- [Collaboration Meshes](#collaboration-meshes)
- [Mediator/Reification Candidates](#mediatorreification-candidates)
- [Coordinator/Mutator Collisions](#coordinatormutator-collisions)
- [Conditional Delegation Hubs](#conditional-delegation-hubs)
- [State Lifecycle Pressure](#state-lifecycle-pressure)
- [Privatization Candidates](#privatization-candidates)
- [Cross-Tool Overlap](#cross-tool-overlap)

## Project Prioritization
- Highest architecture-pressure owner: `MIRLowering` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb)) (score=738.10, state=1, methods=257).
- Highest coordinator/mutator collision: `FunctionAnalysis#visit_FunctionDef` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L200)) (score=125.00, writes=0, conditional calls=42).
- Highest state lifecycle pressure: `@errors` in `MIRChecker` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb)) (score=75.50, readers=41, writers=2).
- Strongest visibility-tightening candidate: `Type#any?` ([`src/ast/type.rb`](../../src/ast/type.rb#L1662)) (score=8.00, internal callers=4).
- Highest encapsulation pressure: `MIR` ([`src/mir/mir.rb`](../../src/mir/mir.rb)) (score=395.80, public=329, state=5, public mutators=25).
- Lowest owner state cohesion: `PipelineHost` ([`src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) (score=161.41, components=12, fragmentation=0.71).
- Broadest collaboration mesh: `MIRLowering` hub (score=347.24, owners=47, edges=46).
- Strongest mediator/reification candidate: `PipelineHost`, `AST`, `MIR::CallableContract`, `PipelineBatchWindowLowerer`, `PipelineBindingChainLowerer`, `PipelineConcurrentLowerer`  +17 (score=126.64, terms=pipeline).
- Start where architecture pressure overlaps Decomplex/Boobytrap/SlopCop/NilKill evidence; those are more likely root-cause work than local cleanup.

## Run Summary
- Modules/classes indexed: 662
- Functions indexed: 5505
- State slots indexed: 391
- Effect reads/writes: 772/522
- Delegation edges: 34427
- Manifest/source byte ratio: 85.45% (3494609 / 4089706)
- Manifest/source word ratio: 68.35% (265802 / 388879)

## State Owner Pressure
_State-heavy owners with broad method/delegation surfaces._

| # | owner | score | flags | state | methods | state touches | delegations | suggested refactor |
|---|-------|-------|-------|-------|---------|---------------|-------------|--------------------|
| 1 | `MIRLowering` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb)) | 738.10 | broad-delegator | 1 | 257 | 2 | 1650 | separate coordinator from mechanism helpers |
| 2 | `MIREmitter` ([`src/backends/mir_emitter.rb`](../../src/backends/mir_emitter.rb)) | 625.50 | state-heavy, many-mutators, broad-delegator | 7 | 196 | 29 | 1266 | separate coordinator from mechanism helpers |
| 3 | `ClearParser` ([`src/ast/parser.rb`](../../src/ast/parser.rb)) | 617.15 | state-heavy, many-mutators, broad-delegator | 7 | 144 | 39 | 1297 | separate coordinator from mechanism helpers |
| 4 | `Type` ([`src/ast/type.rb`](../../src/ast/type.rb)) | 577.60 | state-heavy, many-mutators, broad-delegator, cohesive-value-facade | 7 | 275 | 35 | 1326 | review remaining public API breadth; delegation is mostly value facade |
| 5 | `MIR` ([`src/mir/mir.rb`](../../src/mir/mir.rb)) | 493.80 | state-heavy, many-mutators, broad-delegator | 5 | 329 | 42 | 580 | separate coordinator from mechanism helpers |
| 6 | `MIRChecker` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb)) | 489.45 | broad-delegator | 3 | 127 | 52 | 971 | separate coordinator from mechanism helpers |
| 7 | `MIRLoweringExpressions` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb)) | 451.90 | broad-delegator | 0 | 108 | 0 | 1106 | separate coordinator from mechanism helpers |
| 8 | `PipeAnalysis` ([`src/annotator/helpers/pipe_analysis.rb`](../../src/annotator/helpers/pipe_analysis.rb)) | 388.25 | broad-delegator | 0 | 76 | 0 | 979 | separate coordinator from mechanism helpers |
| 9 | `MIRLoweringFunctions` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb)) | 370.90 | broad-delegator | 0 | 78 | 0 | 926 | separate coordinator from mechanism helpers |
| 10 | `PipelineHost` ([`src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) | 356.80 | state-heavy, many-mutators, broad-delegator | 18 | 94 | 95 | 364 | separate coordinator from mechanism helpers |
| 11 | `PipelineConcurrentLowerer` ([`src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb`](../../src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb)) | 327.65 | broad-delegator | 0 | 87 | 0 | 787 | separate coordinator from mechanism helpers |
| 12 | `AST` ([`src/ast/ast.rb`](../../src/ast/ast.rb)) | 321.75 | state-heavy, many-mutators, broad-delegator | 5 | 207 | 20 | 413 | separate coordinator from mechanism helpers |
| 13 | `Formatter::Emitter` ([`src/tools/formatter.rb`](../../src/tools/formatter.rb)) | 319.65 | broad-delegator | 3 | 104 | 6 | 683 | separate coordinator from mechanism helpers |
| 14 | `MIRLoweringVariables` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb)) | 302.95 | broad-delegator | 0 | 61 | 0 | 761 | separate coordinator from mechanism helpers |
| 15 | `MIRLoweringControlFlow` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb)) | 296.50 | broad-delegator | 0 | 73 | 0 | 722 | separate coordinator from mechanism helpers |
| 16 | `FunctionAnalysis` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb)) | 253.10 | broad-delegator | 0 | 52 | 0 | 634 | separate coordinator from mechanism helpers |
| 17 | `EscapeAnalysis` ([`src/semantic/escape_analysis.rb`](../../src/semantic/escape_analysis.rb)) | 247.60 | broad-delegator | 0 | 86 | 0 | 560 | separate coordinator from mechanism helpers |
| 18 | `CleanupClassifier` ([`src/mir/cleanup_classifier.rb`](../../src/mir/cleanup_classifier.rb)) | 245.00 | broad-delegator | 0 | 77 | 0 | 568 | separate coordinator from mechanism helpers |
| 19 | `FixableHelper` ([`src/annotator/helpers/fixable_helpers.rb`](../../src/annotator/helpers/fixable_helpers.rb)) | 241.80 | many-mutators, broad-delegator | 1 | 60 | 11 | 516 | separate coordinator from mechanism helpers |
| 20 | `MIRLoweringConcurrency` ([`src/mir/lowering/concurrency.rb`](../../src/mir/lowering/concurrency.rb)) | 229.40 | broad-delegator | 0 | 58 | 0 | 556 | separate coordinator from mechanism helpers |

## Encapsulation Pressure
_Owners where public API, mutable state, and internal-helper evidence suggest implementation detail is leaking._

| # | owner | score | flags | public/private | state | public state | public mutators | internal helpers | fan-out | suggested refactor |
|---|-------|-------|-------|----------------|-------|--------------|-----------------|------------------|---------|--------------------|
| 1 | `MIR` ([`src/mir/mir.rb`](../../src/mir/mir.rb)) | 395.80 | state-heavy, broad-public-api, public-state-surface, public-mutators, lifecycle-state, stateful-fanout | 329/0 | 5 | 31 | 25 | - | 6 | split mutable lifecycle state from the public facade |
| 2 | `AST` ([`src/ast/ast.rb`](../../src/ast/ast.rb)) | 223.00 | state-heavy, broad-public-api, public-state-surface, public-mutators, lifecycle-state | 207/0 | 5 | 19 | 10 | - | 1 | split mutable lifecycle state from the public facade |
| 3 | `Type` ([`src/ast/type.rb`](../../src/ast/type.rb)) | 219.04 | state-heavy, broad-public-api, public-state-surface, public-mutators, internal-public-helpers, lifecycle-state, stateful-fanout, cohesive-value-facade | 239/36 | 7 | 22 | 5 | `any?` | 10 | review public behavior breadth; composed value delegation is cohesive |
| 4 | `FunctionSignature` ([`src/annotator/helpers/function_signature.rb`](../../src/annotator/helpers/function_signature.rb)) | 166.83 | broad-public-api, public-state-surface, lifecycle-state, stateful-fanout | 74/6 | 2 | 39 | 0 | - | 7 | narrow public state access through a smaller query/session object |
| 5 | `SemanticAnnotator` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb)) | 153.73 | state-heavy, broad-public-api, public-state-surface, lifecycle-state, stateful-fanout | 34/36 | 9 | 26 | 1 | - | 11 | extract a smaller state/context owner behind this public surface |
| 6 | `Pprof::Profile` ([`src/tools/pprof.rb`](../../src/tools/pprof.rb)) | 150.01 | state-heavy, public-state-surface, public-mutators, lifecycle-state | 9/7 | 15 | 8 | 5 | - | 1 | split mutable lifecycle state from the public facade |
| 7 | `PipelineHost` ([`src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) | 145.58 | state-heavy, public-state-surface, lifecycle-state, stateful-fanout | 9/85 | 18 | 5 | 0 | - | 22 | extract a smaller state/context owner behind this public surface |
| 8 | `SymbolEntry` ([`src/ast/symbol_entry.rb`](../../src/ast/symbol_entry.rb)) | 144.34 | state-heavy, broad-public-api, public-state-surface, public-mutators, lifecycle-state, cohesive-value-facade | 51/5 | 14 | 13 | 3 | - | 3 | review public behavior breadth; composed value delegation is cohesive |
| 9 | `AST::Locatable` ([`src/ast/ast.rb`](../../src/ast/ast.rb)) | 135.70 | broad-public-api, public-state-surface, public-mutators, lifecycle-state | 61/0 | 4 | 17 | 5 | - | 2 | narrow public state access through a smaller query/session object |
| 10 | `Scope` ([`src/ast/scope.rb`](../../src/ast/scope.rb)) | 121.07 | state-heavy, broad-public-api, public-state-surface, lifecycle-state | 32/3 | 7 | 18 | 1 | - | 4 | narrow public state access through a smaller query/session object |
| 11 | `OwnershipGraph` ([`src/semantic/ownership_graph.rb`](../../src/semantic/ownership_graph.rb)) | 107.29 | state-heavy, public-state-surface, public-mutators, lifecycle-state, cohesive-value-facade | 19/15 | 7 | 13 | 2 | - | 4 | review public behavior breadth; composed value delegation is cohesive |
| 12 | `ClearParser` ([`src/ast/parser.rb`](../../src/ast/parser.rb)) | 98.53 | state-heavy, public-state-surface, lifecycle-state, stateful-fanout | 18/126 | 7 | 4 | 1 | - | 19 | check whether public orchestration should move to a coordinator |
| 13 | `MIRLowering` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb)) | 92.71 | broad-public-api, internal-public-helpers, stateful-fanout | 93/164 | 1 | 1 | 0 | `heap_owned_async_boundary_destination?` | 46 | hide internal helpers behind the public entrypoint |
| 14 | `LSP::DocumentStore` ([`src/lsp/document_store.rb`](../../src/lsp/document_store.rb)) | 88.10 | public-state-surface, public-mutators | 12/0 | 3 | 12 | 4 | - | 0 | narrow public state access through a smaller query/session object |
| 15 | `FixableHelper` ([`src/annotator/helpers/fixable_helpers.rb`](../../src/annotator/helpers/fixable_helpers.rb)) | 84.12 | broad-public-api, public-state-surface, public-mutators | 35/25 | 1 | 6 | 5 | - | 5 | verify the broad public surface is intentional |
| 16 | `PipelineLoweringBridge` ([`src/mir/lower/pipeline/pipeline_lowering_bridge.rb`](../../src/mir/lower/pipeline/pipeline_lowering_bridge.rb)) | 82.80 | broad-public-api, public-state-surface | 21/0 | 1 | 21 | 0 | - | 1 | narrow public state access through a smaller query/session object |
| 17 | `MIRChecker::LinearOwnershipSnapshot` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb)) | 81.14 | state-heavy, public-state-surface, lifecycle-state | 8/1 | 9 | 5 | 0 | - | 0 | extract a smaller state/context owner behind this public surface |
| 18 | `LSP::Server` ([`src/lsp/server.rb`](../../src/lsp/server.rb)) | 80.20 | state-heavy, lifecycle-state, stateful-fanout | 3/18 | 11 | 3 | 0 | - | 7 | verify the broad public surface is intentional |
| 19 | `MIRPass` ([`src/mir/mir_pass.rb`](../../src/mir/mir_pass.rb)) | 79.70 | state-heavy, lifecycle-state, stateful-fanout | 4/39 | 11 | 2 | 1 | - | 18 | check whether public orchestration should move to a coordinator |
| 20 | `PipelineRangeLowerer` ([`src/mir/lower/pipeline/pipeline_range_lowerer.rb`](../../src/mir/lower/pipeline/pipeline_range_lowerer.rb)) | 73.87 | broad-public-api, public-state-surface, stateful-fanout | 22/15 | 1 | 13 | 0 | - | 15 | narrow public state access through a smaller query/session object |

## Owner State Cohesion
_Class-level LCOM-style state clusters: methods connected through shared instance state._

| # | owner | score | flags | state | stateful methods | components | bridges | largest | fragmentation | isolated | sample components | suggested refactor |
|---|-------|-------|-------|-------|------------------|------------|---------|---------|---------------|----------|-------------------|--------------------|
| 1 | `PipelineHost` ([`src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) | 161.41 | split-state-components, high-fragmentation, isolated-state-methods, orchestration-bridges | 18 | 69 | 12 | `lower_dispatch_plan`, `lower_soa_scalar_fold`, `visit_pipeline_expr_mir` | 20 (0.29) | 0.71 | 4 | 20m/2s @list_lowerer, @scalar_lowerer: lower_all, lower_any; 17m/1s @range_lowerer: bc_for_iter_range, build_lazy_range_prefix; 12m/5s @binding_chain_lowerer, @do_rt_name: bc_target?, build_concurrent_lowerer | split state clusters into smaller owner/context objects |
| 2 | `MIREmitter` ([`src/backends/mir_emitter.rb`](../../src/backends/mir_emitter.rb)) | 83.30 | split-state-components, isolated-state-methods, orchestration-bridges | 7 | 20 | 6 | `alloc_expr`, `emit`, `emit_alloc_slice`  +120 | 14 (0.70) | 0.30 | 4 | 14m/1s @rt_name: alloc_zig, emit_allocator_ref; 2m/1s @flow_alias_name: emit_flow_stmt, emit_polymorphic_mutate_flow; 1m/1s @deep_copy_counter: emit_deep_copy | review isolated state concerns before adding more API |
| 3 | `AST` ([`src/ast/ast.rb`](../../src/ast/ast.rb)) | 74.75 | split-state-components, high-fragmentation, isolated-state-methods | 5 | 4 | 4 | - | 1 (0.25) | 0.75 | 4 | 1m/1s @fn_type_params: fn_type_params=; 1m/1s @type_object: full_type; 1m/1s @owner_type_params: owner_type_params= | split state clusters into smaller owner/context objects |
| 4 | `AST` ([`src/ast/error_registry.rb`](../../src/ast/error_registry.rb)) | 74.75 | split-state-components, high-fragmentation, isolated-state-methods | 5 | 4 | 4 | - | 1 (0.25) | 0.75 | 4 | 1m/1s @fn_type_params: fn_type_params=; 1m/1s @type_object: full_type; 1m/1s @owner_type_params: owner_type_params= | split state clusters into smaller owner/context objects |
| 5 | `ClearParser` ([`src/ast/parser.rb`](../../src/ast/parser.rb)) | 65.30 | split-state-components, orchestration-bridges | 7 | 20 | 4 | `parse_extern_decl`, `parse_extern_fn`, `parse_sigil_construct`  +94 | 12 (0.60) | 0.40 | 0 | 12m/2s @pos, @tokens: consume, consume_number; 3m/2s @gradual, @last_requires_clauses: parse_argument_list, parse_function_def; 3m/1s @suppress_struct_lit: parse_lit, parse_match_expr | verify these state clusters belong on one owner |
| 6 | `AST::Locatable` ([`src/ast/ast.rb`](../../src/ast/ast.rb)) | 64.32 | split-state-components, high-fragmentation | 4 | 17 | 4 | - | 7 (0.41) | 0.59 | 1 | 7m/1s @storage_override: borrow_provenance?, frame_provenance?; 6m/1s @type_object: base_type, coerce!; 3m/1s @coerced_type_object: coerced_type, coerced_type= | split state clusters into smaller owner/context objects |
| 7 | `OwnershipGraph` ([`src/semantic/ownership_graph.rb`](../../src/semantic/ownership_graph.rb)) | 54.30 | split-state-components, isolated-state-methods, orchestration-bridges | 7 | 18 | 4 | `borrow`, `release_borrow`, `find_borrow_conflict` | 14 (0.78) | 0.22 | 2 | 14m/4s @children, @completed_nodes: [], add_edge; 2m/1s @scope_depth: pop_scope!, push_scope!; 1m/1s @edges_by_source: edges_from | review isolated state concerns before adding more API |
| 8 | `FsmTransform::RecursiveSplitter::Builder` ([`src/mir/fsm_transform/recursive_splitter.rb`](../../src/mir/fsm_transform/recursive_splitter.rb)) | 41.11 | split-state-components, isolated-state-methods | 5 | 7 | 3 | - | 5 (0.71) | 0.29 | 2 | 5m/3s @alias_overrides_for, @current_alias_overrides: fill, finalize; 1m/1s @synthetic_fields: add_synthetic_field; 1m/1s @next_lock_index: reserve_lock_index | review isolated state concerns before adding more API |
| 9 | `StackVerifier` ([`src/tools/stack_verifier.rb`](../../src/tools/stack_verifier.rb)) | 30.95 | orchestration-bridges | 3 | 4 | 2 | `analyze`, `compute_main_optimal_tier`, `compute_optimal_tiers` | 3 (0.75) | 0.25 | 1 | 3m/1s @module_prefix: extract_frame_sizes, verify_tail_calls; 1m/2s @binary_path, @objdump_output: objdump_output | verify these state clusters belong on one owner |

## Collaboration Meshes
_Owner-to-owner webs from manifest-visible delegation targets._

| # | kind | score | owners | edges/calls | density | bidirectional | shared terms | top edges | suggested review |
|---|------|-------|--------|-------------|---------|---------------|--------------|-----------|------------------|
| 1 | hub | 347.24 | `MIRLowering`, `AST`, `CleanupEntry`, `FunctionSignature`, `IntrinsicRegistry`, `MIR`  +41 | 46/159 | 0.02 | 0 | - | MIRLowering -> Type (43); MIRLowering -> AST (14); MIRLowering -> MIR::Placement (11); MIRLowering -> MIR::OwnershipEffect (8); MIRLowering -> MIR::OwnershipOperandFact (8) | check whether stateful collaboration belongs behind a mediator |
| 2 | hub | 238.17 | `MIRLoweringFunctions`, `AST`, `CleanupEntry`, `FunctionSignature`, `IntrinsicRegistry`, `MIR`  +24 | 29/93 | 0.03 | 0 | - | MIRLoweringFunctions -> Type (22); MIRLoweringFunctions -> FunctionSignature (11); MIRLoweringFunctions -> MIR::CallableContract (8); MIRLoweringFunctions -> MIR::OwnershipOperandFact (7); MIRLoweringFunctions -> AST (5) | verify this fan-out is an intentional facade/coordinator |
| 3 | hub | 206.62 | `PipelineHost`, `AST`, `MIR::CallableContract`, `PipelineBatchWindowLowerer`, `PipelineBindingChainLowerer`, `PipelineConcurrentLowerer`  +17 | 22/109 | 0.04 | 0 | pipeline | PipelineHost -> PipelineLoweringBridge (25); PipelineHost -> PipelineRangeLowerer (18); PipelineHost -> PipelineListLowerer (13); PipelineHost -> PipelineScalarLowerer (10); PipelineHost -> PipelineMaterializer (9) | check whether stateful collaboration belongs behind a mediator |
| 4 | hub | 196.52 | `MIRLoweringExpressions`, `AST`, `CleanupEntry`, `FunctionSignature`, `IntrinsicEmit`, `IntrinsicRegistry`  +17 | 22/85 | 0.04 | 0 | - | MIRLoweringExpressions -> Type (43); MIRLoweringExpressions -> AST (7); MIRLoweringExpressions -> MIR::CallableContract (6); MIRLoweringExpressions -> MIR::EnumTag (3); MIRLoweringExpressions -> Schemas (3) | verify this fan-out is an intentional facade/coordinator |
| 5 | hub | 195.00 | `MIRLoweringConcurrency`, `AST`, `AST::ThenStep`, `AsyncResultShape`, `CapabilityHelper::CaptureAnalysis`, `CleanupEntry`  +19 | 24/51 | 0.04 | 0 | - | MIRLoweringConcurrency -> Type (12); MIRLoweringConcurrency -> MIR::CallableContract (9); MIRLoweringConcurrency -> FiberCtxBuilder (3); MIRLoweringConcurrency -> CleanupEntry (2); MIRLoweringConcurrency -> MIR::ContextFieldDecl (2) | verify this fan-out is an intentional facade/coordinator |
| 6 | hub | 177.89 | `PipelineRangeLowerer`, `AST`, `CompilerError`, `FunctionSignature`, `MIR`, `MIR::CallableContract`  +10 | 15/84 | 0.06 | 0 | - | PipelineRangeLowerer -> PipelineRangeLowerer::Host (37); PipelineRangeLowerer -> Type (15); PipelineRangeLowerer -> MIR::CallableContract (9); PipelineRangeLowerer -> FunctionSignature (4); PipelineRangeLowerer -> MIR::OwnershipContract (4) | check whether stateful collaboration belongs behind a mediator |
| 7 | hub | 174.34 | `MIRPass`, `AST`, `BgCaptureClassifier`, `BorrowChecker`, `CleanupClassifier`, `CleanupClassifier::CleanupClassificationPlan`  +13 | 18/47 | 0.05 | 0 | - | MIRPass -> AST (13); MIRPass -> Type (8); MIRPass -> FunctionSignature (4); MIRPass -> CleanupClassifier::CleanupClassificationPlan (3); MIRPass -> CleanupEntry (3) | check whether stateful collaboration belongs behind a mediator |
| 8 | hub | 163.95 | `ClearParser`, `AST::DoBranch`, `AST::ErrorAction`, `AST::ErrorClause`, `AST::ErrorSelector`, `AST::FunctionDef`  +14 | 19/37 | 0.05 | 0 | - | ClearParser -> Type (8); ClearParser -> AST::WithBlock (5); ClearParser -> AST::ErrorSelector (2); ClearParser -> AST::ThenStep (2); ClearParser -> ClearParser::BgPrefix (2) | check whether stateful collaboration belongs behind a mediator |
| 9 | hub | 159.14 | `MIRLoweringVariables`, `AST`, `CleanupEntry`, `FunctionSignature`, `IntrinsicRegistry`, `MIR::CallableContract`  +12 | 17/56 | 0.06 | 0 | - | MIRLoweringVariables -> MIR::MaterializationPacket (10); MIRLoweringVariables -> Type (9); MIRLoweringVariables -> MIR::Placement (7); MIRLoweringVariables -> AST (6); MIRLoweringVariables -> MIR::OwnershipEffect (5) | verify this fan-out is an intentional facade/coordinator |
| 10 | hub | 149.60 | `OwnershipDataflow`, `AST`, `AST::FunctionDef`, `FunctionCFG`, `MIR::LocalBindingAnalysis`, `OwnershipDataflow::CleanupDecision`  +8 | 13/37 | 0.07 | 2 | dataflow, ownership | OwnershipDataflow -> FunctionCFG (11); OwnershipDataflow -> AST (7); OwnershipDataflow -> OwnershipDataflow::OwnerEntry (5); OwnershipDataflow -> MIR::LocalBindingAnalysis (2); OwnershipDataflow -> OwnershipDataflow::CleanupDecision (2) | check whether stateful collaboration belongs behind a mediator |
| 11 | hub | 135.88 | `FunctionSignature`, `FunctionReturn`, `FunctionSignature::AnalysisFacts`, `FunctionSignature::Contract`, `IntrinsicArgSpec`, `IntrinsicContract`  +2 | 7/107 | 0.13 | 1 | - | FunctionSignature -> FunctionSignature::AnalysisFacts (50); FunctionSignature -> FunctionSignature::Contract (47); FunctionSignature -> Type (4); FunctionSignature -> IntrinsicContract (2); FunctionSignature -> IntrinsicEmit (2) | check whether stateful collaboration belongs behind a mediator |
| 12 | hub | 135.49 | `PipelineConcurrentLowerer`, `AST`, `FiberCtxBuilder`, `MIR`, `MIR::CallableContract`, `MIR::ContextFieldDecl`  +10 | 15/54 | 0.06 | 0 | - | PipelineConcurrentLowerer -> Type (28); PipelineConcurrentLowerer -> MIR::CallableContract (4); PipelineConcurrentLowerer -> AST (3); PipelineConcurrentLowerer -> FiberCtxBuilder (3); PipelineConcurrentLowerer -> MIR::ContextFieldDecl (2) | verify this fan-out is an intentional facade/coordinator |
| 13 | hub | 130.97 | `Type`, `CompilerError`, `Schemas`, `Schemas::ResourceClosePlan`, `TypeCapabilities`, `TypeCapabilitySuffix`  +5 | 10/56 | 0.09 | 0 | - | Type -> Schemas (25); Type -> TypeCapabilities (16); Type -> TypeCapabilitySuffix (3); Type -> CompilerError (2); Type -> Schemas::ResourceClosePlan (2) | facade fan-out is mostly value/stateless collaboration; review remaining breadth |
| 14 | hub | 127.36 | `ModuleImporter`, `ClearParser`, `CompilerError`, `FunctionSignature`, `Hoist`, `Lexer`  +11 | 16/24 | 0.06 | 0 | - | ModuleImporter -> ClearParser (4); ModuleImporter -> FunctionSignature (2); ModuleImporter -> Lexer (2); ModuleImporter -> MIRPassState (2); ModuleImporter -> PipelineRewriter (2) | check whether stateful collaboration belongs behind a mediator |
| 15 | hub | 126.18 | `CleanupClassifier`, `AST`, `CleanupClassifier::BindingCleanupFacts`, `CleanupClassifier::CleanupClassificationPlan`, `CleanupEntry`, `FunctionSignature`  +5 | 10/79 | 0.09 | 0 | - | CleanupClassifier -> AST (22); CleanupClassifier -> Type (20); CleanupClassifier -> Schemas (19); CleanupClassifier -> FunctionSignature (6); CleanupClassifier -> SymbolEntry (3) | verify this fan-out is an intentional facade/coordinator |
| 16 | hub | 123.33 | `MIRLoweringCapabilities`, `AST`, `CapabilityPlan`, `CleanupEntry`, `MIR::BindingMaterialization`, `MIR::CallableContract`  +9 | 14/45 | 0.07 | 0 | - | MIRLoweringCapabilities -> CapabilityPlan (12); MIRLoweringCapabilities -> MIR::CallableContract (10); MIRLoweringCapabilities -> Type (5); MIRLoweringCapabilities -> AST (3); MIRLoweringCapabilities -> MIR::EnumTag (3) | verify this fan-out is an intentional facade/coordinator |
| 17 | hub | 120.09 | `FsmTransform::Emit`, `CleanupEntry`, `FsmTransform::Emit::ExpandedLockSegment`, `FsmTransform::Emit::FsmBodyItem`, `FsmTransform::Emit::FsmSegmentFacts`, `FsmTransform::Emit::FsmSegmentSpec`  +10 | 15/29 | 0.06 | 0 | fsm | FsmTransform::Emit -> FsmTransform::Segments (5); FsmTransform::Emit -> FsmTransform::SuspendResolvers (4); FsmTransform::Emit -> MIR (4); FsmTransform::Emit -> MIR::FsmDestroyCleanup (3); FsmTransform::Emit -> CleanupEntry (2) | verify this fan-out is an intentional facade/coordinator |
| 18 | hub | 119.13 | `CapabilityHelper`, `AST`, `CapabilityHelper::CaptureAnalysis`, `CapabilityHelper::CaptureContext`, `CapabilityHelper::PredicateContext`, `CapabilityPlan`  +9 | 14/33 | 0.07 | 0 | capability | CapabilityHelper -> Type (9); CapabilityHelper -> CapabilityPlan (6); CapabilityHelper -> CapabilityHelper::PredicateContext (3); CapabilityHelper -> Edit (2); CapabilityHelper -> Fix (2) | verify this fan-out is an intentional facade/coordinator |
| 19 | hub | 114.00 | `MIRLoweringControlFlow`, `AST`, `CleanupEntry`, `MIR::BindingMaterialization`, `MIR::CallableContract`, `MIR::EnumSwitchPattern`  +8 | 13/32 | 0.07 | 0 | - | MIRLoweringControlFlow -> Type (11); MIRLoweringControlFlow -> MIR::CallableContract (6); MIRLoweringControlFlow -> AST (2); MIRLoweringControlFlow -> CleanupEntry (2); MIRLoweringControlFlow -> MIR::BindingMaterialization (2) | verify this fan-out is an intentional facade/coordinator |
| 20 | hub | 110.10 | `PipelineMaterializer`, `CleanupEntry`, `MIR::CallableContract`, `MIR::OwnershipEffect`, `MIR::OwnershipTransferPlan`, `MIR::Placement`  +4 | 9/31 | 0.10 | 0 | - | PipelineMaterializer -> PipelineMaterializer::Host (12); PipelineMaterializer -> MIR::CallableContract (8); PipelineMaterializer -> CleanupEntry (4); PipelineMaterializer -> MIR::Placement (2); PipelineMaterializer -> MIR::OwnershipEffect (1) | check whether stateful collaboration belongs behind a mediator |

## Mediator/Reification Candidates
_Dense or broad collaboration clusters where a missing or overloaded role object may exist._

| # | owners | score | shared terms | driver | evidence | suggested refactor |
|---|--------|-------|--------------|--------|----------|--------------------|
| 1 | `PipelineHost`, `AST`, `MIR::CallableContract`, `PipelineBatchWindowLowerer`, `PipelineBindingChainLowerer`, `PipelineConcurrentLowerer`  +17 | 126.64 | pipeline | `PipelineHost` | 23 owners; 22 owner edges; density=0.04; hub fan-out=22; existing role PipelineHost is overloaded | split a smaller Pipeline context/mediator out of PipelineHost |
| 2 | `OwnershipDataflow`, `AST`, `AST::FunctionDef`, `FunctionCFG`, `MIR::LocalBindingAnalysis`, `OwnershipDataflow::CleanupDecision`  +8 | 104.28 | dataflow, ownership | `OwnershipDataflow` | 14 owners; 13 owner edges; density=0.07; bidirectional=2; hub fan-out=13; no manifest-visible role owner | look for a missing Dataflow coordinator/context boundary |
| 3 | `LSP::Server`, `LSP::Analyzer`, `LSP::CodeActions`, `LSP::Diagnostics`, `LSP::DocumentStore`, `LSP::Hover`  +2 | 65.51 | lsp | `LSP::Server` | 8 owners; 7 owner edges; density=0.13; hub fan-out=7; existing role LSP::Server is overloaded | split a smaller Lsp context/mediator out of LSP::Server |
| 4 | `FsmTransform::RecursiveSplitter`, `AST`, `CapabilityPlan`, `FsmTransform::RecursiveSplitter::Builder`, `FsmTransform::RecursiveSplitter::SegmentList`, `FsmTransform::Segments`  +1 | 48.12 | fsm, transform | `FsmTransform::RecursiveSplitter::Builder` | 7 owners; 6 owner edges; density=0.14; hub fan-out=6; existing role FsmTransform::RecursiveSplitter::Builder is overloaded | split a smaller Fsm context/mediator out of FsmTransform::RecursiveSplitter::Builder |
| 5 | `MIRLoweringLiterals`, `MIR`, `MIR::CallableContract`, `MIR::OwnershipContract`, `MIRLoweringLiterals::HashLiteralCapabilityPlan`, `MIRLoweringLiterals::HashLiteralPlan`  +2 | 46.08 | literals | `MIRLoweringLiterals` | 8 owners; 7 owner edges; density=0.13; hub fan-out=7; no manifest-visible role owner | look for a missing Literals coordinator/context boundary |
| 6 | `Annotator::Phases::BodyAnalysis`, `Annotator::Phases::BodyFactFrame`, `Semantic::BodyIdentity`, `Semantic::CallSiteId`, `Semantic::LocalId`, `Semantic::PlaceId`  +1 | 43.43 | semantic, id | `Annotator::Phases::BodyAnalysis` | 7 owners; 6 owner edges; density=0.14; hub fan-out=6; no manifest-visible role owner | look for a missing Semantic coordinator/context boundary |

## Coordinator/Mutator Collisions
_Methods that both mutate phase state and coordinate many calls._

| # | method | score | reads | writes | always | conditional | overlap | suggested refactor |
|---|--------|-------|-------|--------|--------|-------------|---------|--------------------|
| 1 | `FunctionAnalysis#visit_FunctionDef` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L200)) | 125.00 | 0 | 0 | 67 | 42 | - | reify operation variants or split branch coordinator |
| 2 | `PipelineHost#initialize` ([`src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb#L42)) | 112.80 | 0 | 18 | 16 | 0 | boobytrap=rank 13/hotspot 14.111 | move writes behind a smaller state object or transaction helper |
| 3 | `MIREmitter#emit` ([`src/backends/mir_emitter.rb`](../../src/backends/mir_emitter.rb#L55)) | 103.30 | 0 | 0 | 127 | 1 | boobytrap=rank 10/hotspot 15.98 | extract decision table or named policy helper |
| 4 | `MIRLoweringVariables#lower_bind_expr` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb#L709)) | 101.80 | 0 | 0 | 4 | 58 | slopcop=rank 25, boobytrap=rank 3/hotspot 29.415 | reify operation variants or split branch coordinator |
| 5 | `FsmTransform::Emit#self.build_recursive` ([`src/mir/fsm_transform/emit.rb`](../../src/mir/fsm_transform/emit.rb#L679)) | 100.60 | 0 | 0 | 45 | 38 | boobytrap=rank 26/hotspot 7.24 | reify operation variants or split branch coordinator |
| 6 | `MIRLoweringFunctions#lower_function_def` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L291)) | 100.00 | 0 | 0 | 23 | 48 | decomplex=7 detectors/score 14, boobytrap=rank 8/hotspot 18.29 | reify operation variants or split branch coordinator |
| 7 | `Annotator::Phases::BodyAnalysis#record_body_fact_node!` ([`src/annotator/phases/body_analysis.rb`](../../src/annotator/phases/body_analysis.rb#L328)) | 96.40 | 0 | 0 | 27 | 44 | boobytrap=rank 37/hotspot 3.399 | reify operation variants or split branch coordinator |
| 8 | `MIRChecker#check_fn!` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb#L361)) | 95.30 | 1 | 2 | 37 | 26 | decomplex=8 detectors/score 19, slopcop=rank 30, boobytrap=rank 4/hotspot 29.401 | reify operation variants or split branch coordinator |
| 9 | `Annotator::Domains::Variables#finalize_decl_node!` ([`src/annotator/domains/variables.rb`](../../src/annotator/domains/variables.rb#L75)) | 94.10 | 0 | 0 | 39 | 37 | decomplex=7 detectors/score 14 | reify operation variants or split branch coordinator |
| 10 | `FunctionAnalysis#resolve_call` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L350)) | 89.80 | 0 | 0 | 6 | 50 | decomplex=7 detectors/score 15 | reify operation variants or split branch coordinator |
| 11 | `MIRLoweringControlFlow#for_each_loop_stmt` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb#L361)) | 88.10 | 0 | 0 | 6 | 49 | boobytrap=rank 33/hotspot 3.973 | reify operation variants or split branch coordinator |
| 12 | `Annotator::Domains::Errors#visit_ReturnNode` ([`src/annotator/domains/errors.rb`](../../src/annotator/domains/errors.rb#L369)) | 87.10 | 0 | 1 | 20 | 33 | boobytrap=rank 30/hotspot 6.561 | reify operation variants or split branch coordinator |
| 13 | `Annotator::Domains::MemberAccess#visit_StructLit` ([`src/annotator/domains/member_access.rb`](../../src/annotator/domains/member_access.rb#L264)) | 86.70 | 0 | 0 | 17 | 43 | - | reify operation variants or split branch coordinator |
| 14 | `PipelineRewriter#rewrite_pipeline` ([`src/mir/rewriters/pipeline_rewriter.rb`](../../src/mir/rewriters/pipeline_rewriter.rb#L94)) | 80.80 | 0 | 0 | 16 | 40 | - | reify operation variants or split branch coordinator |
| 15 | `MIRLowering#lower` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb#L918)) | 79.60 | 0 | 0 | 91 | 4 | boobytrap=rank 1/hotspot 36.689 | extract decision table or named policy helper |
| 16 | `ClearParser#parse_function_def` ([`src/ast/parser.rb`](../../src/ast/parser.rb#L1280)) | 77.80 | 2 | 0 | 34 | 28 | - | reify operation variants or split branch coordinator |
| 17 | `Annotator::Domains::ExecutionBoundaries#visit_WithBlock` ([`src/annotator/domains/execution_boundaries.rb`](../../src/annotator/domains/execution_boundaries.rb#L12)) | 77.80 | 0 | 0 | 42 | 26 | decomplex=7 detectors/score 13 | reify operation variants or split branch coordinator |
| 18 | `Type#compute_zig_type` ([`src/ast/type.rb`](../../src/ast/type.rb#L3490)) | 75.40 | 0 | 0 | 5 | 42 | - | reify operation variants or split branch coordinator |
| 19 | `MIRLoweringLiterals#lower_list_lit` ([`src/mir/lowering/literals.rb`](../../src/mir/lowering/literals.rb#L81)) | 74.40 | 0 | 0 | 25 | 32 | boobytrap=rank 40/hotspot 0.0039 | reify operation variants or split branch coordinator |
| 20 | `MIRLoweringConcurrency#lower_bg_stream_block` ([`src/mir/lowering/concurrency.rb`](../../src/mir/lowering/concurrency.rb#L1000)) | 74.00 | 0 | 0 | 50 | 20 | boobytrap=rank 19/hotspot 11.39 | reify operation variants or split branch coordinator |

## Conditional Delegation Hubs
_Branchy orchestration boundaries, independent of direct state writes._

| # | method | conditional calls | always calls | state touches | suggested refactor |
|---|--------|-------------------|--------------|---------------|--------------------|
| 1 | `MIRLoweringVariables#lower_bind_expr` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb#L709)) | 58 | 4 | 0 | replace branch hub with reified operation dispatch |
| 2 | `FunctionAnalysis#resolve_call` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L350)) | 50 | 6 | 0 | replace branch hub with reified operation dispatch |
| 3 | `MIRLoweringControlFlow#for_each_loop_stmt` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb#L361)) | 49 | 6 | 0 | replace branch hub with reified operation dispatch |
| 4 | `MIRLoweringFunctions#lower_function_def` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L291)) | 48 | 23 | 0 | replace branch hub with reified operation dispatch |
| 5 | `Annotator::Phases::BodyAnalysis#record_body_fact_node!` ([`src/annotator/phases/body_analysis.rb`](../../src/annotator/phases/body_analysis.rb#L328)) | 44 | 27 | 0 | replace branch hub with reified operation dispatch |
| 6 | `Annotator::Domains::MemberAccess#visit_StructLit` ([`src/annotator/domains/member_access.rb`](../../src/annotator/domains/member_access.rb#L264)) | 43 | 17 | 0 | replace branch hub with reified operation dispatch |
| 7 | `FunctionAnalysis#visit_FunctionDef` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L200)) | 42 | 67 | 0 | replace branch hub with reified operation dispatch |
| 8 | `Type#compute_zig_type` ([`src/ast/type.rb`](../../src/ast/type.rb#L3490)) | 42 | 5 | 0 | replace branch hub with reified operation dispatch |
| 9 | `PipelineRewriter#rewrite_pipeline` ([`src/mir/rewriters/pipeline_rewriter.rb`](../../src/mir/rewriters/pipeline_rewriter.rb#L94)) | 40 | 16 | 0 | replace branch hub with reified operation dispatch |
| 10 | `FsmTransform::Emit#self.build_recursive` ([`src/mir/fsm_transform/emit.rb`](../../src/mir/fsm_transform/emit.rb#L679)) | 38 | 45 | 0 | replace branch hub with reified operation dispatch |
| 11 | `MIRLoweringExpressions#index_access_value` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb#L1255)) | 38 | 3 | 0 | replace branch hub with reified operation dispatch |
| 12 | `Annotator::Domains::Variables#finalize_decl_node!` ([`src/annotator/domains/variables.rb`](../../src/annotator/domains/variables.rb#L75)) | 37 | 39 | 0 | replace branch hub with reified operation dispatch |
| 13 | `Annotator::Domains::ExecutionBoundaries#visit_NextExpr` ([`src/annotator/domains/execution_boundaries.rb`](../../src/annotator/domains/execution_boundaries.rb#L842)) | 35 | 4 | 0 | replace branch hub with reified operation dispatch |
| 14 | `FsmLowering#lower_step_stmts` ([`src/mir/fsm_lowering.rb`](../../src/mir/fsm_lowering.rb#L78)) | 35 | 4 | 0 | replace branch hub with reified operation dispatch |
| 15 | `MIRLoweringExpressions#lower_struct_lit` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb#L1492)) | 34 | 15 | 0 | replace branch hub with reified operation dispatch |
| 16 | `Annotator::Domains::Errors#visit_ReturnNode` ([`src/annotator/domains/errors.rb`](../../src/annotator/domains/errors.rb#L369)) | 33 | 20 | 1 | replace branch hub with reified operation dispatch |
| 17 | `MIRLoweringLiterals#lower_list_lit` ([`src/mir/lowering/literals.rb`](../../src/mir/lowering/literals.rb#L81)) | 32 | 25 | 0 | replace branch hub with reified operation dispatch |
| 18 | `Type#merge_capabilities_from!` ([`src/ast/type.rb`](../../src/ast/type.rb#L1383)) | 32 | 9 | 0 | replace branch hub with reified operation dispatch |
| 19 | `FunctionAnalysis#declare_and_verify_params` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L1011)) | 31 | 16 | 0 | replace branch hub with reified operation dispatch |
| 20 | `CleanupClassifier#self.classify_binding` ([`src/mir/cleanup_classifier.rb`](../../src/mir/cleanup_classifier.rb)) | 31 | 16 | 0 | replace branch hub with reified operation dispatch |

## State Lifecycle Pressure
_State slots with many readers/writers or protocol-shaped behavior._

| # | state | owner | score | readers | writers | type | protocol evidence | suggested refactor |
|---|-------|-------|-------|---------|---------|------|-------------------|--------------------|
| 1 | `@errors` | `MIRChecker` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb)) | 75.50 | 41 | 2 | T::Array[T.untyped] | protocol interfaces: <<, concat | wrap protocol in a small lifecycle object |
| 2 | `@result_type` | `MIR` ([`src/mir/mir.rb`](../../src/mir/mir.rb)) | 69.00 | 10 | 18 | T.nilable(Type) | - | centralize writes behind one owner |
| 3 | `@receiver_state` | `SemanticAnnotator` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb)) | 54.00 | 32 | 2 | ReceiverState | - | verify this state belongs on the owner |
| 4 | `@facts` | `FunctionSignature` ([`src/annotator/helpers/function_signature.rb`](../../src/annotator/helpers/function_signature.rb)) | 46.50 | 27 | 2 | AnalysisFacts | - | verify this state belongs on the owner |
| 5 | `@bindings` | `Scope` ([`src/ast/scope.rb`](../../src/ast/scope.rb)) | 33.50 | 13 | 2 | ScopeBindings | protocol interfaces: [], []=, entries, key?, keys, length | wrap protocol in a small lifecycle object |
| 6 | `@capabilities` | `Type` ([`src/ast/type.rb`](../../src/ast/type.rb)) | 33.00 | 14 | 4 | TypeCapabilities | - | centralize writes behind one owner |
| 7 | `@rt_name` | `MIREmitter` ([`src/backends/mir_emitter.rb`](../../src/backends/mir_emitter.rb)) | 33.00 | 14 | 4 | String | - | centralize writes behind one owner |
| 8 | `@lowering` | `PipelineLoweringBridge` ([`src/mir/lower/pipeline/pipeline_lowering_bridge.rb`](../../src/mir/lower/pipeline/pipeline_lowering_bridge.rb)) | 33.00 | 20 | 1 | MIRLowering | - | verify this state belongs on the owner |
| 9 | `@host` | `PipelineRangeLowerer` ([`src/mir/lower/pipeline/pipeline_range_lowerer.rb`](../../src/mir/lower/pipeline/pipeline_range_lowerer.rb)) | 31.50 | 19 | 1 | PipelineRangeLowerer::Host | - | verify this state belongs on the owner |
| 10 | `@source_code` | `FixableHelper` ([`src/annotator/helpers/fixable_helpers.rb`](../../src/annotator/helpers/fixable_helpers.rb)) | 30.00 | 2 | 9 | T.nilable(String) | - | centralize writes behind one owner |
| 11 | `@contract` | `FunctionSignature` ([`src/annotator/helpers/function_signature.rb`](../../src/annotator/helpers/function_signature.rb)) | 30.00 | 18 | 1 | Contract | - | verify this state belongs on the owner |
| 12 | `@pos` | `ClearParser` ([`src/ast/parser.rb`](../../src/ast/parser.rb)) | 30.00 | 10 | 5 | Integer | - | centralize writes behind one owner |
| 13 | `@range_lowerer` | `PipelineHost` ([`src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) | 28.50 | 17 | 1 | PipelineRangeLowerer | - | verify this state belongs on the owner |
| 14 | `@logger` | `LSP::Server` ([`src/lsp/server.rb`](../../src/lsp/server.rb)) | 24.00 | 14 | 1 | Logger | - | verify this state belongs on the owner |
| 15 | `@slots` | `AutoConstraintCollector` ([`src/annotator/helpers/auto_inference.rb`](../../src/annotator/helpers/auto_inference.rb)) | 23.00 | 8 | 1 | SlotMap | protocol interfaces: [], []= | wrap protocol in a small lifecycle object |
| 16 | `@tokens` | `ClearParser` ([`src/ast/parser.rb`](../../src/ast/parser.rb)) | 23.00 | 8 | 1 | - | protocol interfaces: [] | wrap protocol in a small lifecycle object |
| 17 | `@type_params` | `AST` ([`src/ast/ast.rb`](../../src/ast/ast.rb)) | 22.50 | 3 | 6 | T::Array[String] | - | centralize writes behind one owner |
| 18 | `@entries` | `Scope::ScopeBindings` ([`src/ast/scope.rb`](../../src/ast/scope.rb)) | 21.50 | 7 | 1 | T::Hash[String, SymbolEntry] | protocol interfaces: [], []=, each, key?, keys, length, to_a | wrap protocol in a small lifecycle object |
| 19 | `@docs` | `LSP::DocumentStore` ([`src/lsp/document_store.rb`](../../src/lsp/document_store.rb)) | 21.50 | 7 | 1 | T::Hash[T.untyped, T.untyped] | protocol interfaces: [], []=, delete, each_value | wrap protocol in a small lifecycle object |
| 20 | `@completed_nodes` | `OwnershipGraph` ([`src/semantic/ownership_graph.rb`](../../src/semantic/ownership_graph.rb)) | 21.50 | 3 | 3 | T::Hash[PlaceId, OwnershipGraph::Node] | protocol interfaces: [], each | wrap protocol in a small lifecycle object |

## Privatization Candidates
_Public methods that likely should be private: same-owner callers, no manifest-visible external receiver calls, and helper/protocol evidence._

| # | method | score | confidence | internal callers | state touches | reason |
|---|--------|-------|------------|------------------|---------------|--------|
| 1 | `Type#any?` ([`src/ast/type.rb`](../../src/ast/type.rb#L1662)) | 8.00 | high | accepts?, needs_explicit_cleanup?, scalar_slot?, struct? | 0 | public but only has same-owner callers; coordinates 1 internal call(s); helper-shaped name; no manifest-visible external receiver call |
| 2 | `MIRLowering#heap_owned_async_boundary_destination?` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb#L656)) | 7.50 | medium | destination_placement_plan | 0 | public but only has same-owner callers; single internal caller: destination_placement_plan; helper-shaped name; no manifest-visible external receiver call |
| 3 | `Annotator::Domains::Lifetimes#lifetime_sources_for_value` ([`src/annotator/domains/lifetimes.rb`](../../src/annotator/domains/lifetimes.rb#L799)) | 6.50 | medium | verify_tied_assignment! | 0 | public but only has same-owner callers; single internal caller: verify_tied_assignment!; coordinates 1 internal call(s); no manifest-visible external receiver call |
| 4 | `ErrorHelper#diagnostic_message` ([`src/ast/source_error.rb`](../../src/ast/source_error.rb#L76)) | 6.50 | medium | fixable! | 0 | public but only has same-owner callers; single internal caller: fixable!; coordinates 1 internal call(s); no manifest-visible external receiver call |
| 5 | `CleanupClassifier::FrozenCleanupFacts#live_entry_for_node` ([`src/mir/cleanup_classifier.rb`](../../src/mir/cleanup_classifier.rb#L109)) | 6.50 | medium | with_live_entry_for_node | 0 | public but only has same-owner callers; single internal caller: with_live_entry_for_node; coordinates 1 internal call(s); no manifest-visible external receiver call |
| 6 | `CleanupClassifier::FrozenCleanupFacts#entry_for` ([`src/mir/cleanup_classifier.rb`](../../src/mir/cleanup_classifier.rb#L91)) | 6.00 | medium | live_entry_for | 0 | public but only has same-owner callers; single internal caller: live_entry_for; no manifest-visible external receiver call |

## Cross-Tool Overlap
_Architectural pressure with sibling-tool metadata already attached._

| # | method | architecture score | overlap |
|---|--------|--------------------|---------|
| 1 | `MIREmitter#emit` ([`src/backends/mir_emitter.rb`](../../src/backends/mir_emitter.rb#L55)) | 103.30 | boobytrap=rank 10/hotspot 15.98 |
| 2 | `MIRLoweringVariables#lower_bind_expr` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb#L709)) | 101.80 | slopcop=rank 25, boobytrap=rank 3/hotspot 29.415 |
| 3 | `FsmTransform::Emit#self.build_recursive` ([`src/mir/fsm_transform/emit.rb`](../../src/mir/fsm_transform/emit.rb#L679)) | 100.60 | boobytrap=rank 26/hotspot 7.24 |
| 4 | `MIRLoweringFunctions#lower_function_def` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L291)) | 100.00 | decomplex=7 detectors/score 14, boobytrap=rank 8/hotspot 18.29 |
| 5 | `Annotator::Phases::BodyAnalysis#record_body_fact_node!` ([`src/annotator/phases/body_analysis.rb`](../../src/annotator/phases/body_analysis.rb#L328)) | 96.40 | boobytrap=rank 37/hotspot 3.399 |
| 6 | `MIRChecker#check_fn!` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb#L361)) | 95.30 | decomplex=8 detectors/score 19, slopcop=rank 30, boobytrap=rank 4/hotspot 29.401 |
| 7 | `Annotator::Domains::Variables#finalize_decl_node!` ([`src/annotator/domains/variables.rb`](../../src/annotator/domains/variables.rb#L75)) | 94.10 | decomplex=7 detectors/score 14 |
| 8 | `FunctionAnalysis#resolve_call` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L350)) | 89.80 | decomplex=7 detectors/score 15 |
| 9 | `MIRLoweringControlFlow#for_each_loop_stmt` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb#L361)) | 88.10 | boobytrap=rank 33/hotspot 3.973 |
| 10 | `Annotator::Domains::Errors#visit_ReturnNode` ([`src/annotator/domains/errors.rb`](../../src/annotator/domains/errors.rb#L369)) | 87.10 | boobytrap=rank 30/hotspot 6.561 |
| 11 | `MIRLowering#lower` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb#L918)) | 79.60 | boobytrap=rank 1/hotspot 36.689 |
| 12 | `Annotator::Domains::ExecutionBoundaries#visit_WithBlock` ([`src/annotator/domains/execution_boundaries.rb`](../../src/annotator/domains/execution_boundaries.rb#L12)) | 77.80 | decomplex=7 detectors/score 13 |
| 13 | `MIRLoweringLiterals#lower_list_lit` ([`src/mir/lowering/literals.rb`](../../src/mir/lowering/literals.rb#L81)) | 74.40 | boobytrap=rank 40/hotspot 0.0039 |
| 14 | `MIRLoweringConcurrency#lower_bg_stream_block` ([`src/mir/lowering/concurrency.rb`](../../src/mir/lowering/concurrency.rb#L1000)) | 74.00 | boobytrap=rank 19/hotspot 11.39 |
| 15 | `MIRLoweringExpressions#lower_struct_lit` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb#L1492)) | 69.80 | boobytrap=rank 39/hotspot 2.015 |
| 16 | `PipeAnalysis#analyze_concurrent_op` ([`src/annotator/helpers/pipe_analysis.rb`](../../src/annotator/helpers/pipe_analysis.rb#L1423)) | 69.30 | decomplex=8 detectors/score 16 |
| 17 | `MIRChecker#check_linear_stmt!` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb#L579)) | 67.50 | decomplex=7 detectors/score 15, slopcop=rank 33, boobytrap=rank 4/hotspot 29.401 |
| 18 | `MIRLoweringExpressions#index_access_value` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb#L1255)) | 67.00 | boobytrap=rank 39/hotspot 2.015 |
| 19 | `MIRLoweringFunctions#lower_intrinsic` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L1590)) | 65.80 | decomplex=7 detectors/score 16, slopcop=rank 16, boobytrap=rank 8/hotspot 18.29 |
| 20 | `CleanupClassifier#self.classify_binding` ([`src/mir/cleanup_classifier.rb`](../../src/mir/cleanup_classifier.rb)) | 65.50 | boobytrap=rank 18/hotspot 11.958 |
