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
- Highest architecture-pressure owner: `MIRLowering` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb)) (score=721.45, state=1, methods=252).
- Highest coordinator/mutator collision: `FunctionAnalysis#visit_FunctionDef` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L200)) (score=125.00, writes=0, conditional calls=42).
- Highest state lifecycle pressure: `@errors` in `MIRChecker` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb)) (score=74.00, readers=40, writers=2).
- Strongest visibility-tightening candidate: `Type#any?` ([`src/ast/type.rb`](../../src/ast/type.rb#L1656)) (score=8.00, internal callers=4).
- Highest encapsulation pressure: `MIR` ([`src/mir/mir.rb`](../../src/mir/mir.rb)) (score=497.80, public=330, state=10, public mutators=35).
- Lowest owner state cohesion: `PipelineHost` ([`src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) (score=161.41, components=12, fragmentation=0.71).
- Broadest collaboration mesh: `MIRLowering` hub (score=347.24, owners=47, edges=46).
- Strongest mediator/reification candidate: `PipelineHost`, `AST`, `MIR::CallableContract`, `PipelineBatchWindowLowerer`, `PipelineBindingChainLowerer`, `PipelineConcurrentLowerer`  +17 (score=126.64, terms=pipeline).
- Start where architecture pressure overlaps Decomplex/Boobytrap/SlopCop/NilKill evidence; those are more likely root-cause work than local cleanup.

## Run Summary
- Modules/classes indexed: 657
- Functions indexed: 5444
- State slots indexed: 400
- Effect reads/writes: 761/532
- Delegation edges: 34178
- Manifest/source byte ratio: 84.89% (3452959 / 4067767)
- Manifest/source word ratio: 68.07% (263572 / 387225)

## State Owner Pressure
_State-heavy owners with broad method/delegation surfaces._

| # | owner | score | flags | state | methods | state touches | delegations | suggested refactor |
|---|-------|-------|-------|-------|---------|---------------|-------------|--------------------|
| 1 | `MIRLowering` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb)) | 721.45 | broad-delegator | 1 | 252 | 2 | 1611 | separate coordinator from mechanism helpers |
| 2 | `Parser` ([`src/ast/parser.rb`](../../src/ast/parser.rb)) | 617.15 | state-heavy, many-mutators, broad-delegator | 7 | 144 | 39 | 1297 | separate coordinator from mechanism helpers |
| 3 | `MIREmitter` ([`src/mir/mir_emitter.rb`](../../src/mir/mir_emitter.rb)) | 609.20 | state-heavy, many-mutators, broad-delegator | 7 | 191 | 29 | 1228 | separate coordinator from mechanism helpers |
| 4 | `Type` ([`src/ast/type.rb`](../../src/ast/type.rb)) | 588.35 | state-heavy, many-mutators, broad-delegator, cohesive-value-facade | 9 | 275 | 37 | 1327 | review remaining public API breadth; delegation is mostly value facade |
| 5 | `MIR` ([`src/mir/mir.rb`](../../src/mir/mir.rb)) | 529.45 | state-heavy, many-mutators, broad-delegator | 10 | 330 | 53 | 571 | separate coordinator from mechanism helpers |
| 6 | `MIRChecker` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb)) | 469.05 | broad-delegator | 2 | 120 | 48 | 947 | separate coordinator from mechanism helpers |
| 7 | `MIRLoweringExpressions` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb)) | 453.30 | broad-delegator | 0 | 108 | 0 | 1110 | separate coordinator from mechanism helpers |
| 8 | `PipeAnalysis` ([`src/annotator/helpers/pipe_analysis.rb`](../../src/annotator/helpers/pipe_analysis.rb)) | 388.25 | broad-delegator | 0 | 76 | 0 | 979 | separate coordinator from mechanism helpers |
| 9 | `MIRLoweringFunctions` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb)) | 368.55 | broad-delegator | 0 | 77 | 0 | 921 | separate coordinator from mechanism helpers |
| 10 | `PipelineHost` ([`src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) | 356.45 | state-heavy, many-mutators, broad-delegator | 18 | 94 | 95 | 363 | separate coordinator from mechanism helpers |
| 11 | `Formatter::Emitter` ([`src/tools/formatter.rb`](../../src/tools/formatter.rb)) | 319.65 | broad-delegator | 3 | 104 | 6 | 683 | separate coordinator from mechanism helpers |
| 12 | `MIRLoweringVariables` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb)) | 301.65 | broad-delegator | 0 | 60 | 0 | 759 | separate coordinator from mechanism helpers |
| 13 | `PipelineConcurrentLowerer` ([`src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb`](../../src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb)) | 298.00 | broad-delegator | 0 | 79 | 0 | 716 | separate coordinator from mechanism helpers |
| 14 | `MIRLoweringControlFlow` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb)) | 296.50 | broad-delegator | 0 | 73 | 0 | 722 | separate coordinator from mechanism helpers |
| 15 | `AST` ([`src/ast/ast.rb`](../../src/ast/ast.rb)) | 273.00 | many-mutators, broad-delegator | 2 | 191 | 5 | 404 | separate coordinator from mechanism helpers |
| 16 | `FunctionAnalysis` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb)) | 253.45 | broad-delegator | 0 | 52 | 0 | 635 | separate coordinator from mechanism helpers |
| 17 | `FixableHelper` ([`src/annotator/helpers/fixable_helpers.rb`](../../src/annotator/helpers/fixable_helpers.rb)) | 241.80 | many-mutators, broad-delegator | 1 | 60 | 11 | 516 | separate coordinator from mechanism helpers |
| 18 | `EscapeAnalysis` ([`src/semantic/escape_analysis.rb`](../../src/semantic/escape_analysis.rb)) | 240.65 | broad-delegator | 0 | 82 | 0 | 547 | separate coordinator from mechanism helpers |
| 19 | `CleanupClassifier` ([`src/mir/cleanup_classifier.rb`](../../src/mir/cleanup_classifier.rb)) | 237.70 | broad-delegator | 0 | 73 | 0 | 554 | separate coordinator from mechanism helpers |
| 20 | `MIRLoweringConcurrency` ([`src/mir/lowering/concurrency.rb`](../../src/mir/lowering/concurrency.rb)) | 229.40 | broad-delegator | 0 | 58 | 0 | 556 | separate coordinator from mechanism helpers |

## Encapsulation Pressure
_Owners where public API, mutable state, and internal-helper evidence suggest implementation detail is leaking._

| # | owner | score | flags | public/private | state | public state | public mutators | internal helpers | fan-out | suggested refactor |
|---|-------|-------|-------|----------------|-------|--------------|-----------------|------------------|---------|--------------------|
| 1 | `MIR` ([`src/mir/mir.rb`](../../src/mir/mir.rb)) | 497.80 | state-heavy, broad-public-api, public-state-surface, public-mutators, lifecycle-state, stateful-fanout | 330/0 | 10 | 41 | 35 | - | 7 | split mutable lifecycle state from the public facade |
| 2 | `Type` ([`src/ast/type.rb`](../../src/ast/type.rb)) | 241.64 | state-heavy, broad-public-api, public-state-surface, public-mutators, internal-public-helpers, lifecycle-state, stateful-fanout, cohesive-value-facade | 239/36 | 9 | 24 | 7 | `any?` | 10 | review public behavior breadth; composed value delegation is cohesive |
| 3 | `FunctionSignature` ([`src/annotator/helpers/function_signature.rb`](../../src/annotator/helpers/function_signature.rb)) | 166.83 | broad-public-api, public-state-surface, lifecycle-state, stateful-fanout | 74/6 | 2 | 39 | 0 | - | 7 | narrow public state access through a smaller query/session object |
| 4 | `SemanticAnnotator` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb)) | 153.80 | state-heavy, broad-public-api, public-state-surface, lifecycle-state, stateful-fanout | 34/34 | 9 | 26 | 1 | - | 11 | extract a smaller state/context owner behind this public surface |
| 5 | `SymbolEntry` ([`src/ast/symbol_entry.rb`](../../src/ast/symbol_entry.rb)) | 150.32 | state-heavy, broad-public-api, public-state-surface, public-mutators, lifecycle-state, cohesive-value-facade | 51/5 | 14 | 15 | 3 | - | 3 | review public behavior breadth; composed value delegation is cohesive |
| 6 | `Pprof::Profile` ([`src/tools/pprof.rb`](../../src/tools/pprof.rb)) | 150.01 | state-heavy, public-state-surface, public-mutators, lifecycle-state | 9/7 | 15 | 8 | 5 | - | 1 | split mutable lifecycle state from the public facade |
| 7 | `PipelineHost` ([`src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) | 145.58 | state-heavy, public-state-surface, lifecycle-state, stateful-fanout | 9/85 | 18 | 5 | 0 | - | 22 | extract a smaller state/context owner behind this public surface |
| 8 | `AST::Locatable` ([`src/ast/ast.rb`](../../src/ast/ast.rb)) | 135.70 | broad-public-api, public-state-surface, public-mutators, lifecycle-state | 61/0 | 4 | 17 | 5 | - | 2 | narrow public state access through a smaller query/session object |
| 9 | `AST` ([`src/ast/ast.rb`](../../src/ast/ast.rb)) | 124.50 | broad-public-api, public-state-surface, public-mutators | 191/0 | 2 | 5 | 5 | - | 1 | verify the broad public surface is intentional |
| 10 | `Scope` ([`src/ast/scope.rb`](../../src/ast/scope.rb)) | 121.07 | state-heavy, broad-public-api, public-state-surface, lifecycle-state | 32/3 | 7 | 18 | 1 | - | 4 | narrow public state access through a smaller query/session object |
| 11 | `OwnershipGraph` ([`src/semantic/ownership_graph.rb`](../../src/semantic/ownership_graph.rb)) | 107.29 | state-heavy, public-state-surface, public-mutators, lifecycle-state, cohesive-value-facade | 19/15 | 7 | 13 | 2 | - | 4 | review public behavior breadth; composed value delegation is cohesive |
| 12 | `Parser` ([`src/ast/parser.rb`](../../src/ast/parser.rb)) | 98.53 | state-heavy, public-state-surface, lifecycle-state, stateful-fanout | 18/126 | 7 | 4 | 1 | - | 19 | check whether public orchestration should move to a coordinator |
| 13 | `MIRLowering` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb)) | 90.29 | broad-public-api, stateful-fanout | 90/162 | 1 | 1 | 0 | - | 46 | check whether public orchestration should move to a coordinator |
| 14 | `LSP::DocumentStore` ([`src/lsp/document_store.rb`](../../src/lsp/document_store.rb)) | 88.10 | public-state-surface, public-mutators | 12/0 | 3 | 12 | 4 | - | 0 | narrow public state access through a smaller query/session object |
| 15 | `FixableHelper` ([`src/annotator/helpers/fixable_helpers.rb`](../../src/annotator/helpers/fixable_helpers.rb)) | 84.12 | broad-public-api, public-state-surface, public-mutators | 35/25 | 1 | 6 | 5 | - | 5 | verify the broad public surface is intentional |
| 16 | `MIRChecker::LinearOwnershipSnapshot` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb)) | 81.14 | state-heavy, public-state-surface, lifecycle-state | 8/1 | 9 | 5 | 0 | - | 0 | extract a smaller state/context owner behind this public surface |
| 17 | `LSP::Server` ([`src/lsp/server.rb`](../../src/lsp/server.rb)) | 80.20 | state-heavy, lifecycle-state, stateful-fanout | 3/18 | 11 | 3 | 0 | - | 7 | verify the broad public surface is intentional |
| 18 | `MIRPass` ([`src/mir/mir_pass.rb`](../../src/mir/mir_pass.rb)) | 79.70 | state-heavy, lifecycle-state, stateful-fanout | 4/39 | 11 | 2 | 1 | - | 18 | check whether public orchestration should move to a coordinator |
| 19 | `PipelineLoweringBridge` ([`src/mir/lower/pipeline/pipeline_lowering_bridge.rb`](../../src/mir/lower/pipeline/pipeline_lowering_bridge.rb)) | 79.50 | broad-public-api, public-state-surface | 20/0 | 1 | 20 | 0 | - | 1 | narrow public state access through a smaller query/session object |
| 20 | `PipelineRangeLowerer` ([`src/mir/lower/pipeline/pipeline_range_lowerer.rb`](../../src/mir/lower/pipeline/pipeline_range_lowerer.rb)) | 73.87 | broad-public-api, public-state-surface, stateful-fanout | 22/15 | 1 | 13 | 0 | - | 15 | narrow public state access through a smaller query/session object |

## Owner State Cohesion
_Class-level LCOM-style state clusters: methods connected through shared instance state._

| # | owner | score | flags | state | stateful methods | components | bridges | largest | fragmentation | isolated | sample components | suggested refactor |
|---|-------|-------|-------|-------|------------------|------------|---------|---------|---------------|----------|-------------------|--------------------|
| 1 | `PipelineHost` ([`src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) | 161.41 | split-state-components, high-fragmentation, isolated-state-methods, orchestration-bridges | 18 | 69 | 12 | `lower_dispatch_plan`, `lower_soa_scalar_fold`, `visit_pipeline_expr_mir` | 20 (0.29) | 0.71 | 4 | 20m/2s @list_lowerer, @scalar_lowerer: lower_all, lower_any; 17m/1s @range_lowerer: bc_for_iter_range, build_lazy_range_prefix; 12m/5s @binding_chain_lowerer, @do_rt_name: bc_target?, build_concurrent_lowerer | split state clusters into smaller owner/context objects |
| 2 | `MIREmitter` ([`src/mir/mir_emitter.rb`](../../src/mir/mir_emitter.rb)) | 83.30 | split-state-components, isolated-state-methods, orchestration-bridges | 7 | 20 | 6 | `alloc_expr`, `emit`, `emit_alloc_slice`  +117 | 14 (0.70) | 0.30 | 4 | 14m/1s @rt_name: alloc_zig, emit_allocator_ref; 2m/1s @flow_alias_name: emit_flow_stmt, emit_polymorphic_mutate_flow; 1m/1s @deep_copy_counter: emit_deep_copy | review isolated state concerns before adding more API |
| 3 | `Parser` ([`src/ast/parser.rb`](../../src/ast/parser.rb)) | 65.30 | split-state-components, orchestration-bridges | 7 | 20 | 4 | `parse_extern_decl`, `parse_extern_fn`, `parse_sigil_construct`  +94 | 12 (0.60) | 0.40 | 0 | 12m/2s @pos, @tokens: consume, consume_number; 3m/2s @gradual, @last_requires_clauses: parse_argument_list, parse_function_def; 3m/1s @suppress_struct_lit: parse_lit, parse_match_expr | verify these state clusters belong on one owner |
| 4 | `AST::Locatable` ([`src/ast/ast.rb`](../../src/ast/ast.rb)) | 64.32 | split-state-components, high-fragmentation | 4 | 17 | 4 | - | 7 (0.41) | 0.59 | 1 | 7m/1s @storage_override: borrow_provenance?, frame_provenance?; 6m/1s @type_object: base_type, coerce!; 3m/1s @coerced_type_object: coerced_type, coerced_type= | split state clusters into smaller owner/context objects |
| 5 | `OwnershipGraph` ([`src/semantic/ownership_graph.rb`](../../src/semantic/ownership_graph.rb)) | 54.30 | split-state-components, isolated-state-methods, orchestration-bridges | 7 | 18 | 4 | `borrow`, `release_borrow`, `find_borrow_conflict` | 14 (0.78) | 0.22 | 2 | 14m/4s @children, @completed_nodes: [], add_edge; 2m/1s @scope_depth: pop_scope!, push_scope!; 1m/1s @edges_by_source: edges_from | review isolated state concerns before adding more API |
| 6 | `FsmTransform::RecursiveSplitter::Builder` ([`src/mir/fsm_transform/recursive_splitter.rb`](../../src/mir/fsm_transform/recursive_splitter.rb)) | 41.11 | split-state-components, isolated-state-methods | 5 | 7 | 3 | - | 5 (0.71) | 0.29 | 2 | 5m/3s @alias_overrides_for, @current_alias_overrides: fill, finalize; 1m/1s @synthetic_fields: add_synthetic_field; 1m/1s @next_lock_index: reserve_lock_index | review isolated state concerns before adding more API |
| 7 | `StackVerifier` ([`src/tools/stack_verifier.rb`](../../src/tools/stack_verifier.rb)) | 30.95 | orchestration-bridges | 3 | 4 | 2 | `analyze`, `compute_main_optimal_tier`, `compute_optimal_tiers` | 3 (0.75) | 0.25 | 1 | 3m/1s @module_prefix: extract_frame_sizes, verify_tail_calls; 1m/2s @binary_path, @objdump_output: objdump_output | verify these state clusters belong on one owner |

## Collaboration Meshes
_Owner-to-owner webs from manifest-visible delegation targets._

| # | kind | score | owners | edges/calls | density | bidirectional | shared terms | top edges | suggested review |
|---|------|-------|--------|-------------|---------|---------------|--------------|-----------|------------------|
| 1 | hub | 347.24 | `MIRLowering`, `AST`, `CleanupEntry`, `FunctionSignature`, `IntrinsicRegistry`, `MIR`  +41 | 46/148 | 0.02 | 0 | - | MIRLowering -> Type (40); MIRLowering -> AST (13); MIRLowering -> MIR::OwnershipOperandFact (8); MIRLowering -> MIR (7); MIRLowering -> FunctionSignature (6) | check whether stateful collaboration belongs behind a mediator |
| 2 | hub | 232.21 | `MIRLoweringFunctions`, `AST`, `CleanupEntry`, `FunctionSignature`, `IntrinsicRegistry`, `MIR`  +23 | 28/93 | 0.03 | 0 | - | MIRLoweringFunctions -> Type (22); MIRLoweringFunctions -> FunctionSignature (11); MIRLoweringFunctions -> MIR::CallableContract (8); MIRLoweringFunctions -> MIR::OwnershipOperandFact (7); MIRLoweringFunctions -> AST (5) | verify this fan-out is an intentional facade/coordinator |
| 3 | hub | 206.62 | `PipelineHost`, `AST`, `MIR::CallableContract`, `PipelineBatchWindowLowerer`, `PipelineBindingChainLowerer`, `PipelineConcurrentLowerer`  +17 | 22/108 | 0.04 | 0 | pipeline | PipelineHost -> PipelineLoweringBridge (24); PipelineHost -> PipelineRangeLowerer (18); PipelineHost -> PipelineListLowerer (13); PipelineHost -> PipelineScalarLowerer (10); PipelineHost -> PipelineMaterializer (9) | check whether stateful collaboration belongs behind a mediator |
| 4 | hub | 196.52 | `MIRLoweringExpressions`, `AST`, `CleanupEntry`, `FunctionSignature`, `IntrinsicEmit`, `IntrinsicRegistry`  +17 | 22/85 | 0.04 | 0 | - | MIRLoweringExpressions -> Type (43); MIRLoweringExpressions -> AST (7); MIRLoweringExpressions -> MIR::CallableContract (6); MIRLoweringExpressions -> MIR::EnumTag (3); MIRLoweringExpressions -> Schemas (3) | verify this fan-out is an intentional facade/coordinator |
| 5 | hub | 195.00 | `MIRLoweringConcurrency`, `AST`, `AST::ThenStep`, `AsyncResultShape`, `CapabilityHelper::CaptureAnalysis`, `CleanupEntry`  +19 | 24/51 | 0.04 | 0 | - | MIRLoweringConcurrency -> Type (12); MIRLoweringConcurrency -> MIR::CallableContract (9); MIRLoweringConcurrency -> FiberCtxBuilder (3); MIRLoweringConcurrency -> CleanupEntry (2); MIRLoweringConcurrency -> MIR::ContextFieldDecl (2) | verify this fan-out is an intentional facade/coordinator |
| 6 | hub | 177.89 | `PipelineRangeLowerer`, `AST`, `CompilerError`, `FunctionSignature`, `MIR`, `MIR::CallableContract`  +10 | 15/84 | 0.06 | 0 | - | PipelineRangeLowerer -> PipelineRangeLowerer::Host (37); PipelineRangeLowerer -> Type (15); PipelineRangeLowerer -> MIR::CallableContract (9); PipelineRangeLowerer -> FunctionSignature (4); PipelineRangeLowerer -> MIR::OwnershipContract (4) | check whether stateful collaboration belongs behind a mediator |
| 7 | hub | 174.34 | `MIRPass`, `AST`, `BgCaptureClassifier`, `BorrowChecker`, `CleanupClassifier`, `CleanupClassifier::CleanupClassificationPlan`  +13 | 18/47 | 0.05 | 0 | - | MIRPass -> AST (13); MIRPass -> Type (8); MIRPass -> FunctionSignature (4); MIRPass -> CleanupClassifier::CleanupClassificationPlan (3); MIRPass -> CleanupEntry (3) | check whether stateful collaboration belongs behind a mediator |
| 8 | hub | 163.95 | `Parser`, `AST::DoBranch`, `AST::ErrorAction`, `AST::ErrorClause`, `AST::ErrorSelector`, `AST::FunctionDef`  +14 | 19/37 | 0.05 | 0 | - | Parser -> Type (8); Parser -> AST::WithBlock (5); Parser -> AST::ErrorSelector (2); Parser -> AST::ThenStep (2); Parser -> Edit (2) | check whether stateful collaboration belongs behind a mediator |
| 9 | hub | 159.14 | `MIRLoweringVariables`, `AST`, `CleanupEntry`, `FunctionSignature`, `IntrinsicRegistry`, `MIR::CallableContract`  +12 | 17/56 | 0.06 | 0 | - | MIRLoweringVariables -> MIR::MaterializationPacket (10); MIRLoweringVariables -> Type (9); MIRLoweringVariables -> MIR::Placement (7); MIRLoweringVariables -> AST (6); MIRLoweringVariables -> MIR::OwnershipEffect (5) | verify this fan-out is an intentional facade/coordinator |
| 10 | hub | 149.60 | `OwnershipDataflow`, `AST`, `AST::FunctionDef`, `FunctionCFG`, `MIR::LocalBindingAnalysis`, `OwnershipDataflow::CleanupDecision`  +8 | 13/37 | 0.07 | 2 | dataflow, ownership | OwnershipDataflow -> FunctionCFG (11); OwnershipDataflow -> AST (7); OwnershipDataflow -> OwnershipDataflow::OwnerEntry (5); OwnershipDataflow -> MIR::LocalBindingAnalysis (2); OwnershipDataflow -> OwnershipDataflow::CleanupDecision (2) | check whether stateful collaboration belongs behind a mediator |
| 11 | hub | 135.88 | `FunctionSignature`, `FunctionReturn`, `FunctionSignature::AnalysisFacts`, `FunctionSignature::Contract`, `IntrinsicArgSpec`, `IntrinsicContract`  +2 | 7/107 | 0.13 | 1 | - | FunctionSignature -> FunctionSignature::AnalysisFacts (50); FunctionSignature -> FunctionSignature::Contract (47); FunctionSignature -> Type (4); FunctionSignature -> IntrinsicContract (2); FunctionSignature -> IntrinsicEmit (2) | check whether stateful collaboration belongs behind a mediator |
| 12 | hub | 130.97 | `Type`, `CompilerError`, `Schemas`, `Schemas::ResourceClosePlan`, `TypeCapabilities`, `TypeCapabilitySuffix`  +5 | 10/56 | 0.09 | 0 | - | Type -> Schemas (25); Type -> TypeCapabilities (16); Type -> TypeCapabilitySuffix (3); Type -> CompilerError (2); Type -> Schemas::ResourceClosePlan (2) | facade fan-out is mostly value/stateless collaboration; review remaining breadth |
| 13 | hub | 127.36 | `ModuleImporter`, `CompilerError`, `FunctionSignature`, `Hoist`, `Lexer`, `MIREmitter`  +11 | 16/24 | 0.06 | 0 | - | ModuleImporter -> Parser (4); ModuleImporter -> FunctionSignature (2); ModuleImporter -> Lexer (2); ModuleImporter -> MIRPassState (2); ModuleImporter -> PipelineRewriter (2) | check whether stateful collaboration belongs behind a mediator |
| 14 | hub | 126.18 | `CleanupClassifier`, `AST`, `CleanupClassifier::BindingCleanupFacts`, `CleanupClassifier::CleanupClassificationPlan`, `CleanupEntry`, `FunctionSignature`  +5 | 10/76 | 0.09 | 0 | - | CleanupClassifier -> AST (21); CleanupClassifier -> Type (20); CleanupClassifier -> Schemas (19); CleanupClassifier -> FunctionSignature (4); CleanupClassifier -> SymbolEntry (3) | verify this fan-out is an intentional facade/coordinator |
| 15 | hub | 123.33 | `MIRLoweringCapabilities`, `AST`, `CapabilityPlan`, `CleanupEntry`, `MIR::BindingMaterialization`, `MIR::CallableContract`  +9 | 14/45 | 0.07 | 0 | - | MIRLoweringCapabilities -> CapabilityPlan (12); MIRLoweringCapabilities -> MIR::CallableContract (10); MIRLoweringCapabilities -> Type (5); MIRLoweringCapabilities -> AST (3); MIRLoweringCapabilities -> MIR::EnumTag (3) | verify this fan-out is an intentional facade/coordinator |
| 16 | hub | 119.13 | `CapabilityHelper`, `AST`, `CapabilityHelper::CaptureAnalysis`, `CapabilityHelper::CaptureContext`, `CapabilityHelper::PredicateContext`, `CapabilityPlan`  +9 | 14/33 | 0.07 | 0 | capability | CapabilityHelper -> Type (9); CapabilityHelper -> CapabilityPlan (6); CapabilityHelper -> CapabilityHelper::PredicateContext (3); CapabilityHelper -> Edit (2); CapabilityHelper -> Fix (2) | verify this fan-out is an intentional facade/coordinator |
| 17 | hub | 118.69 | `FsmTransform::Emit`, `CleanupEntry`, `FsmTransform::Emit::ExpandedLockSegment`, `FsmTransform::Emit::FsmBodyItem`, `FsmTransform::Emit::FsmSegmentFacts`, `FsmTransform::Emit::FsmSegmentSpec`  +10 | 15/28 | 0.06 | 0 | fsm | FsmTransform::Emit -> FsmTransform::Segments (4); FsmTransform::Emit -> FsmTransform::SuspendResolvers (4); FsmTransform::Emit -> MIR (4); FsmTransform::Emit -> MIR::FsmDestroyCleanup (3); FsmTransform::Emit -> CleanupEntry (2) | verify this fan-out is an intentional facade/coordinator |
| 18 | hub | 118.20 | `PipelineConcurrentLowerer`, `AST`, `FiberCtxBuilder`, `MIR`, `MIR::CallableContract`, `MIR::EnumTag`  +8 | 13/47 | 0.07 | 0 | - | PipelineConcurrentLowerer -> Type (26); PipelineConcurrentLowerer -> MIR::CallableContract (4); PipelineConcurrentLowerer -> AST (3); PipelineConcurrentLowerer -> FiberCtxBuilder (2); PipelineConcurrentLowerer -> MIR::EnumTag (2) | verify this fan-out is an intentional facade/coordinator |
| 19 | hub | 114.70 | `MIRChecker`, `DiagnosticRegistry`, `FunctionSignature`, `MIR`, `MIR::OwnershipEffect`, `MIR::Placement`  +4 | 9/38 | 0.10 | 0 | - | MIRChecker -> MIR (10); MIRChecker -> MIR::Placement (8); MIRChecker -> FunctionSignature (5); MIRChecker -> MIR::OwnershipEffect (5); MIRChecker -> MIRChecker::LinearOwnershipState (3) | check whether stateful collaboration belongs behind a mediator |
| 20 | hub | 114.00 | `MIRLoweringControlFlow`, `AST`, `CleanupEntry`, `MIR::BindingMaterialization`, `MIR::CallableContract`, `MIR::EnumSwitchPattern`  +8 | 13/32 | 0.07 | 0 | - | MIRLoweringControlFlow -> Type (11); MIRLoweringControlFlow -> MIR::CallableContract (6); MIRLoweringControlFlow -> AST (2); MIRLoweringControlFlow -> CleanupEntry (2); MIRLoweringControlFlow -> MIR::BindingMaterialization (2) | verify this fan-out is an intentional facade/coordinator |

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
| 1 | `FunctionAnalysis#visit_FunctionDef` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L200)) | 125.00 | 0 | 0 | 67 | 42 | decomplex=5 detectors/score 11, boobytrap=rank 40/hotspot 0.0047 | reify operation variants or split branch coordinator |
| 2 | `FsmTransform::Emit#build_recursive` ([`src/mir/fsm_transform/emit.rb`](../../src/mir/fsm_transform/emit.rb#L687)) | 117.80 | 0 | 0 | 58 | 42 | slopcop=rank 1, boobytrap=rank 10/hotspot 11.145 | reify operation variants or split branch coordinator |
| 3 | `PipelineHost#initialize` ([`src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb#L42)) | 112.80 | 0 | 18 | 16 | 0 | - | move writes behind a smaller state object or transaction helper |
| 4 | `MIREmitter#emit` ([`src/mir/mir_emitter.rb`](../../src/mir/mir_emitter.rb#L53)) | 102.50 | 0 | 0 | 126 | 1 | boobytrap=rank 22/hotspot 6.363 | extract decision table or named policy helper |
| 5 | `MIRLoweringVariables#lower_bind_expr` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb#L708)) | 101.80 | 0 | 0 | 4 | 58 | boobytrap=rank 19/hotspot 6.96 | reify operation variants or split branch coordinator |
| 6 | `MIRLoweringFunctions#lower_function_def` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L291)) | 100.00 | 0 | 0 | 23 | 48 | boobytrap=rank 9/hotspot 11.208 | reify operation variants or split branch coordinator |
| 7 | `Annotator::Domains::Variables#finalize_decl_node!` ([`src/annotator/domains/variables.rb`](../../src/annotator/domains/variables.rb#L75)) | 97.50 | 0 | 0 | 39 | 39 | decomplex=6 detectors/score 12, boobytrap=rank 38/hotspot 0.006 | reify operation variants or split branch coordinator |
| 8 | `Annotator::Phases::BodyAnalysis#record_body_fact_node!` ([`src/annotator/phases/body_analysis.rb`](../../src/annotator/phases/body_analysis.rb#L320)) | 94.70 | 0 | 0 | 27 | 43 | boobytrap=rank 30/hotspot 5.356 | reify operation variants or split branch coordinator |
| 9 | `MIRChecker#check_fn!` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb#L356)) | 93.00 | 0 | 2 | 36 | 26 | boobytrap=rank 20/hotspot 6.937 | reify operation variants or split branch coordinator |
| 10 | `Annotator::Domains::Errors#visit_ReturnNode` ([`src/annotator/domains/errors.rb`](../../src/annotator/domains/errors.rb#L369)) | 90.50 | 0 | 1 | 20 | 35 | decomplex=5 detectors/score 11, boobytrap=rank 14/hotspot 10.072 | reify operation variants or split branch coordinator |
| 11 | `FunctionAnalysis#resolve_call` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L350)) | 89.80 | 0 | 0 | 6 | 50 | decomplex=7 detectors/score 15, boobytrap=rank 40/hotspot 0.0047 | reify operation variants or split branch coordinator |
| 12 | `MIRLoweringControlFlow#for_each_loop_stmt` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb#L362)) | 88.10 | 0 | 0 | 6 | 49 | boobytrap=rank 21/hotspot 6.427 | reify operation variants or split branch coordinator |
| 13 | `Annotator::Domains::MemberAccess#visit_StructLit` ([`src/annotator/domains/member_access.rb`](../../src/annotator/domains/member_access.rb#L262)) | 86.70 | 0 | 0 | 17 | 43 | - | reify operation variants or split branch coordinator |
| 14 | `PipelineRewriter#rewrite_pipeline` ([`src/backends/pipeline_rewriter.rb`](../../src/backends/pipeline_rewriter.rb#L97)) | 80.80 | 0 | 0 | 16 | 40 | - | reify operation variants or split branch coordinator |
| 15 | `MIRLowering#lower` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb#L877)) | 79.60 | 0 | 0 | 91 | 4 | boobytrap=rank 1/hotspot 18.141 | extract decision table or named policy helper |
| 16 | `Parser#parse_function_def` ([`src/ast/parser.rb`](../../src/ast/parser.rb#L1277)) | 78.70 | 2 | 0 | 33 | 29 | - | reify operation variants or split branch coordinator |
| 17 | `Annotator::Domains::ExecutionBoundaries#visit_WithBlock` ([`src/annotator/domains/execution_boundaries.rb`](../../src/annotator/domains/execution_boundaries.rb#L12)) | 77.80 | 0 | 0 | 42 | 26 | decomplex=7 detectors/score 13 | reify operation variants or split branch coordinator |
| 18 | `Type#compute_zig_type` ([`src/ast/type.rb`](../../src/ast/type.rb#L3477)) | 75.40 | 0 | 0 | 5 | 42 | - | reify operation variants or split branch coordinator |
| 19 | `MIRLoweringLiterals#lower_list_lit` ([`src/mir/lowering/literals.rb`](../../src/mir/lowering/literals.rb#L81)) | 74.40 | 0 | 0 | 25 | 32 | boobytrap=rank 39/hotspot 0.902 | reify operation variants or split branch coordinator |
| 20 | `MIRLoweringConcurrency#lower_bg_stream_block` ([`src/mir/lowering/concurrency.rb`](../../src/mir/lowering/concurrency.rb#L1000)) | 74.00 | 0 | 0 | 50 | 20 | slopcop=rank 26, boobytrap=rank 2/hotspot 17.887 | reify operation variants or split branch coordinator |

## Conditional Delegation Hubs
_Branchy orchestration boundaries, independent of direct state writes._

| # | method | conditional calls | always calls | state touches | suggested refactor |
|---|--------|-------------------|--------------|---------------|--------------------|
| 1 | `MIRLoweringVariables#lower_bind_expr` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb#L708)) | 58 | 4 | 0 | replace branch hub with reified operation dispatch |
| 2 | `FunctionAnalysis#resolve_call` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L350)) | 50 | 6 | 0 | replace branch hub with reified operation dispatch |
| 3 | `MIRLoweringControlFlow#for_each_loop_stmt` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb#L362)) | 49 | 6 | 0 | replace branch hub with reified operation dispatch |
| 4 | `MIRLoweringFunctions#lower_function_def` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L291)) | 48 | 23 | 0 | replace branch hub with reified operation dispatch |
| 5 | `Annotator::Phases::BodyAnalysis#record_body_fact_node!` ([`src/annotator/phases/body_analysis.rb`](../../src/annotator/phases/body_analysis.rb#L320)) | 43 | 27 | 0 | replace branch hub with reified operation dispatch |
| 6 | `Annotator::Domains::MemberAccess#visit_StructLit` ([`src/annotator/domains/member_access.rb`](../../src/annotator/domains/member_access.rb#L262)) | 43 | 17 | 0 | replace branch hub with reified operation dispatch |
| 7 | `FunctionAnalysis#visit_FunctionDef` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L200)) | 42 | 67 | 0 | replace branch hub with reified operation dispatch |
| 8 | `FsmTransform::Emit#build_recursive` ([`src/mir/fsm_transform/emit.rb`](../../src/mir/fsm_transform/emit.rb#L687)) | 42 | 58 | 0 | replace branch hub with reified operation dispatch |
| 9 | `Type#compute_zig_type` ([`src/ast/type.rb`](../../src/ast/type.rb#L3477)) | 42 | 5 | 0 | replace branch hub with reified operation dispatch |
| 10 | `PipelineRewriter#rewrite_pipeline` ([`src/backends/pipeline_rewriter.rb`](../../src/backends/pipeline_rewriter.rb#L97)) | 40 | 16 | 0 | replace branch hub with reified operation dispatch |
| 11 | `Annotator::Domains::Variables#finalize_decl_node!` ([`src/annotator/domains/variables.rb`](../../src/annotator/domains/variables.rb#L75)) | 39 | 39 | 0 | replace branch hub with reified operation dispatch |
| 12 | `MIRLoweringExpressions#index_access_value` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb#L1255)) | 38 | 7 | 0 | replace branch hub with reified operation dispatch |
| 13 | `Annotator::Domains::Errors#visit_ReturnNode` ([`src/annotator/domains/errors.rb`](../../src/annotator/domains/errors.rb#L369)) | 35 | 20 | 1 | replace branch hub with reified operation dispatch |
| 14 | `Annotator::Domains::ExecutionBoundaries#visit_NextExpr` ([`src/annotator/domains/execution_boundaries.rb`](../../src/annotator/domains/execution_boundaries.rb#L841)) | 35 | 4 | 0 | replace branch hub with reified operation dispatch |
| 15 | `FsmLowering#lower_step_stmts` ([`src/mir/fsm_lowering.rb`](../../src/mir/fsm_lowering.rb#L79)) | 35 | 4 | 0 | replace branch hub with reified operation dispatch |
| 16 | `MIRLoweringExpressions#lower_struct_lit` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb#L1499)) | 34 | 15 | 0 | replace branch hub with reified operation dispatch |
| 17 | `MIRLoweringLiterals#lower_list_lit` ([`src/mir/lowering/literals.rb`](../../src/mir/lowering/literals.rb#L81)) | 32 | 25 | 0 | replace branch hub with reified operation dispatch |
| 18 | `Type#merge_capabilities_from!` ([`src/ast/type.rb`](../../src/ast/type.rb#L1378)) | 32 | 9 | 0 | replace branch hub with reified operation dispatch |
| 19 | `FunctionAnalysis#declare_and_verify_params` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L1009)) | 31 | 16 | 0 | replace branch hub with reified operation dispatch |
| 20 | `CleanupClassifier#self.classify_binding` ([`src/mir/cleanup_classifier.rb`](../../src/mir/cleanup_classifier.rb)) | 31 | 16 | 0 | replace branch hub with reified operation dispatch |

## State Lifecycle Pressure
_State slots with many readers/writers or protocol-shaped behavior._

| # | state | owner | score | readers | writers | type | protocol evidence | suggested refactor |
|---|-------|-------|-------|---------|---------|------|-------------------|--------------------|
| 1 | `@errors` | `MIRChecker` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb)) | 74.00 | 40 | 2 | T::Array[T.untyped] | protocol interfaces: <<, concat | wrap protocol in a small lifecycle object |
| 2 | `@result_type` | `MIR` ([`src/mir/mir.rb`](../../src/mir/mir.rb)) | 69.00 | 10 | 18 | T.nilable(Type) | - | centralize writes behind one owner |
| 3 | `@receiver_state` | `SemanticAnnotator` ([`src/annotator/annotator.rb`](../../src/annotator/annotator.rb)) | 54.00 | 32 | 2 | ReceiverState | - | verify this state belongs on the owner |
| 4 | `@facts` | `FunctionSignature` ([`src/annotator/helpers/function_signature.rb`](../../src/annotator/helpers/function_signature.rb)) | 46.50 | 27 | 2 | AnalysisFacts | - | verify this state belongs on the owner |
| 5 | `@bindings` | `Scope` ([`src/ast/scope.rb`](../../src/ast/scope.rb)) | 33.50 | 13 | 2 | ScopeBindings | protocol interfaces: [], []=, entries, key?, keys, length | wrap protocol in a small lifecycle object |
| 6 | `@capabilities` | `Type` ([`src/ast/type.rb`](../../src/ast/type.rb)) | 33.00 | 14 | 4 | TypeCapabilities | - | centralize writes behind one owner |
| 7 | `@rt_name` | `MIREmitter` ([`src/mir/mir_emitter.rb`](../../src/mir/mir_emitter.rb)) | 33.00 | 14 | 4 | String | - | centralize writes behind one owner |
| 8 | `@lowering` | `PipelineLoweringBridge` ([`src/mir/lower/pipeline/pipeline_lowering_bridge.rb`](../../src/mir/lower/pipeline/pipeline_lowering_bridge.rb)) | 31.50 | 19 | 1 | MIRLowering | - | verify this state belongs on the owner |
| 9 | `@host` | `PipelineRangeLowerer` ([`src/mir/lower/pipeline/pipeline_range_lowerer.rb`](../../src/mir/lower/pipeline/pipeline_range_lowerer.rb)) | 31.50 | 19 | 1 | PipelineRangeLowerer::Host | - | verify this state belongs on the owner |
| 10 | `@source_code` | `FixableHelper` ([`src/annotator/helpers/fixable_helpers.rb`](../../src/annotator/helpers/fixable_helpers.rb)) | 30.00 | 2 | 9 | T.nilable(String) | - | centralize writes behind one owner |
| 11 | `@contract` | `FunctionSignature` ([`src/annotator/helpers/function_signature.rb`](../../src/annotator/helpers/function_signature.rb)) | 30.00 | 18 | 1 | Contract | - | verify this state belongs on the owner |
| 12 | `@pos` | `Parser` ([`src/ast/parser.rb`](../../src/ast/parser.rb)) | 30.00 | 10 | 5 | Integer | - | centralize writes behind one owner |
| 13 | `@range_lowerer` | `PipelineHost` ([`src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) | 28.50 | 17 | 1 | PipelineRangeLowerer | - | verify this state belongs on the owner |
| 14 | `@findings` | `FixCollector` ([`src/ast/fixable_error.rb`](../../src/ast/fixable_error.rb)) | 24.50 | 5 | 3 | - | protocol interfaces: <<, any?, count, nil? | wrap protocol in a small lifecycle object |
| 15 | `@flow` | `SymbolEntry` ([`src/ast/symbol_entry.rb`](../../src/ast/symbol_entry.rb)) | 24.00 | 12 | 2 | BindingFlowFacts | - | verify this state belongs on the owner |
| 16 | `@logger` | `LSP::Server` ([`src/lsp/server.rb`](../../src/lsp/server.rb)) | 24.00 | 14 | 1 | Logger | - | verify this state belongs on the owner |
| 17 | `@slots` | `AutoConstraintCollector` ([`src/annotator/helpers/auto_inference.rb`](../../src/annotator/helpers/auto_inference.rb)) | 23.00 | 8 | 1 | SlotMap | protocol interfaces: [], []= | wrap protocol in a small lifecycle object |
| 18 | `@tokens` | `Parser` ([`src/ast/parser.rb`](../../src/ast/parser.rb)) | 23.00 | 8 | 1 | - | protocol interfaces: [] | wrap protocol in a small lifecycle object |
| 19 | `@placeholders` | `MIR::InlineAllocMetadata` ([`src/mir/mir.rb`](../../src/mir/mir.rb)) | 23.00 | 8 | 1 | T::Hash[T.any(Symbol, String), Symbol] | protocol interfaces: [], dup, each, each_key, empty?, inspect, key?, values | wrap protocol in a small lifecycle object |
| 20 | `@entries` | `Scope::ScopeBindings` ([`src/ast/scope.rb`](../../src/ast/scope.rb)) | 21.50 | 7 | 1 | T::Hash[String, SymbolEntry] | protocol interfaces: [], []=, each, key?, keys, length, to_a | wrap protocol in a small lifecycle object |

## Privatization Candidates
_Public methods that likely should be private: same-owner callers, no manifest-visible external receiver calls, and helper/protocol evidence._

| # | method | score | confidence | internal callers | state touches | reason |
|---|--------|-------|------------|------------------|---------------|--------|
| 1 | `Type#any?` ([`src/ast/type.rb`](../../src/ast/type.rb#L1656)) | 8.00 | high | accepts?, needs_explicit_cleanup?, scalar_slot?, struct? | 0 | public but only has same-owner callers; coordinates 1 internal call(s); helper-shaped name; no manifest-visible external receiver call |
| 2 | `FmtVerifier#verify` ([`src/tools/fmt_verifier.rb`](../../src/tools/fmt_verifier.rb#L42)) | 7.50 | medium | verify_dir | 0 | public but only has same-owner callers; single internal caller: verify_dir; coordinates 3 internal call(s); no manifest-visible external receiver call |
| 3 | `Annotator::Domains::Lifetimes#lifetime_sources_for_value` ([`src/annotator/domains/lifetimes.rb`](../../src/annotator/domains/lifetimes.rb#L799)) | 6.50 | medium | verify_tied_assignment! | 0 | public but only has same-owner callers; single internal caller: verify_tied_assignment!; coordinates 1 internal call(s); no manifest-visible external receiver call |
| 4 | `ErrorHelper#diagnostic_message` ([`src/ast/source_error.rb`](../../src/ast/source_error.rb#L76)) | 6.50 | medium | fixable! | 0 | public but only has same-owner callers; single internal caller: fixable!; coordinates 1 internal call(s); no manifest-visible external receiver call |
| 5 | `CleanupClassifier::FrozenCleanupFacts#live_entry_for_node` ([`src/mir/cleanup_classifier.rb`](../../src/mir/cleanup_classifier.rb#L109)) | 6.50 | medium | with_live_entry_for_node | 0 | public but only has same-owner callers; single internal caller: with_live_entry_for_node; coordinates 1 internal call(s); no manifest-visible external receiver call |
| 6 | `CleanupClassifier::FrozenCleanupFacts#entry_for` ([`src/mir/cleanup_classifier.rb`](../../src/mir/cleanup_classifier.rb#L91)) | 6.00 | medium | live_entry_for | 0 | public but only has same-owner callers; single internal caller: live_entry_for; no manifest-visible external receiver call |

## Cross-Tool Overlap
_Architectural pressure with sibling-tool metadata already attached._

| # | method | architecture score | overlap |
|---|--------|--------------------|---------|
| 1 | `FunctionAnalysis#visit_FunctionDef` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L200)) | 125.00 | decomplex=5 detectors/score 11, boobytrap=rank 40/hotspot 0.0047 |
| 2 | `FsmTransform::Emit#build_recursive` ([`src/mir/fsm_transform/emit.rb`](../../src/mir/fsm_transform/emit.rb#L687)) | 117.80 | slopcop=rank 1, boobytrap=rank 10/hotspot 11.145 |
| 3 | `MIREmitter#emit` ([`src/mir/mir_emitter.rb`](../../src/mir/mir_emitter.rb#L53)) | 102.50 | boobytrap=rank 22/hotspot 6.363 |
| 4 | `MIRLoweringVariables#lower_bind_expr` ([`src/mir/lowering/variables.rb`](../../src/mir/lowering/variables.rb#L708)) | 101.80 | boobytrap=rank 19/hotspot 6.96 |
| 5 | `MIRLoweringFunctions#lower_function_def` ([`src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L291)) | 100.00 | boobytrap=rank 9/hotspot 11.208 |
| 6 | `Annotator::Domains::Variables#finalize_decl_node!` ([`src/annotator/domains/variables.rb`](../../src/annotator/domains/variables.rb#L75)) | 97.50 | decomplex=6 detectors/score 12, boobytrap=rank 38/hotspot 0.006 |
| 7 | `Annotator::Phases::BodyAnalysis#record_body_fact_node!` ([`src/annotator/phases/body_analysis.rb`](../../src/annotator/phases/body_analysis.rb#L320)) | 94.70 | boobytrap=rank 30/hotspot 5.356 |
| 8 | `MIRChecker#check_fn!` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb#L356)) | 93.00 | boobytrap=rank 20/hotspot 6.937 |
| 9 | `Annotator::Domains::Errors#visit_ReturnNode` ([`src/annotator/domains/errors.rb`](../../src/annotator/domains/errors.rb#L369)) | 90.50 | decomplex=5 detectors/score 11, boobytrap=rank 14/hotspot 10.072 |
| 10 | `FunctionAnalysis#resolve_call` ([`src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb#L350)) | 89.80 | decomplex=7 detectors/score 15, boobytrap=rank 40/hotspot 0.0047 |
| 11 | `MIRLoweringControlFlow#for_each_loop_stmt` ([`src/mir/lowering/control_flow.rb`](../../src/mir/lowering/control_flow.rb#L362)) | 88.10 | boobytrap=rank 21/hotspot 6.427 |
| 12 | `MIRLowering#lower` ([`src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb#L877)) | 79.60 | boobytrap=rank 1/hotspot 18.141 |
| 13 | `Annotator::Domains::ExecutionBoundaries#visit_WithBlock` ([`src/annotator/domains/execution_boundaries.rb`](../../src/annotator/domains/execution_boundaries.rb#L12)) | 77.80 | decomplex=7 detectors/score 13 |
| 14 | `MIRLoweringLiterals#lower_list_lit` ([`src/mir/lowering/literals.rb`](../../src/mir/lowering/literals.rb#L81)) | 74.40 | boobytrap=rank 39/hotspot 0.902 |
| 15 | `MIRLoweringConcurrency#lower_bg_stream_block` ([`src/mir/lowering/concurrency.rb`](../../src/mir/lowering/concurrency.rb#L1000)) | 74.00 | slopcop=rank 26, boobytrap=rank 2/hotspot 17.887 |
| 16 | `Doctor#section_heap` ([`src/tools/doctor.rb`](../../src/tools/doctor.rb#L123)) | 71.40 | slopcop=rank 49 |
| 17 | `MIRLoweringExpressions#index_access_value` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb#L1255)) | 70.20 | slopcop=rank 19, boobytrap=rank 32/hotspot 3.093 |
| 18 | `MIRLoweringExpressions#lower_struct_lit` ([`src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb#L1499)) | 69.80 | boobytrap=rank 32/hotspot 3.093 |
| 19 | `PipeAnalysis#analyze_concurrent_op` ([`src/annotator/helpers/pipe_analysis.rb`](../../src/annotator/helpers/pipe_analysis.rb#L1422)) | 69.30 | decomplex=6 detectors/score 12 |
| 20 | `MIRChecker#check_linear_stmt!` ([`src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb#L575)) | 67.50 | boobytrap=rank 20/hotspot 6.937 |
