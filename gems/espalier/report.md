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
- Highest architecture-pressure owner: `ClearParser` ([`/home/yahn/cheat/src/ast/parser.rb`](../../src/ast/parser.rb)) (score=315.10, state=61, methods=145).
- Highest coordinator/mutator collision: `MIRLoweringFunctions::FunctionState#activate!` ([`/home/yahn/cheat/src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L191)) (score=45.00, writes=9, conditional calls=0).
- Highest state lifecycle pressure: `receiver_state` in `SemanticAnnotator` ([`/home/yahn/cheat/src/annotator/annotator.rb`](../../src/annotator/annotator.rb)) (score=43.50, readers=27, writers=1).
- Highest encapsulation pressure: `PipelineHost` ([`/home/yahn/cheat/src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) (score=330.60, public=94, state=20, public mutators=2).
- Lowest owner state cohesion: `PipelineHost` ([`/home/yahn/cheat/src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) (score=160.82, components=11, fragmentation=0.70).
- Start where architecture pressure overlaps Decomplex/Boobytrap/SlopCop/NilKill evidence; those are more likely root-cause work than local cleanup.

## Run Summary
- Modules/classes indexed: 556
- Functions indexed: 5590
- State slots indexed: 936
- Effect reads/writes: 977/338
- Delegation edges: 1260

## State Owner Pressure
_State-heavy owners with broad method/delegation surfaces._

| # | owner | score | flags | state | methods | state touches | delegations | suggested refactor |
|---|-------|-------|-------|-------|---------|---------------|-------------|--------------------|
| 1 | `ClearParser` ([`/home/yahn/cheat/src/ast/parser.rb`](../../src/ast/parser.rb)) | 315.10 | state-heavy, many-mutators, low-cohesion-candidate | 61 | 145 | 27 | 22 | extract phase-state records and split lifecycle ownership |
| 2 | `Type` ([`/home/yahn/cheat/src/ast/type.rb`](../../src/ast/type.rb)) | 276.20 | state-heavy | 7 | 276 | 55 | 56 | audit cohesion before local cleanup |
| 3 | `MIRLowering` ([`/home/yahn/cheat/src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb)) | 255.25 | state-heavy, low-cohesion-candidate | 17 | 257 | 24 | 55 | audit cohesion before local cleanup |
| 4 | `PipelineHost` ([`/home/yahn/cheat/src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) | 237.60 | state-heavy | 20 | 94 | 74 | 84 | extract phase-state records and split lifecycle ownership |
| 5 | `FunctionSignature` ([`/home/yahn/cheat/src/annotator/helpers/function_signature.rb`](../../src/annotator/helpers/function_signature.rb)) | 213.20 | state-heavy, many-mutators | 24 | 80 | 52 | 68 | extract phase-state records and split lifecycle ownership |
| 6 | `PipelineConcurrentLowerer` ([`/home/yahn/cheat/src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb`](../../src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb)) | 200.80 | - | 2 | 87 | 92 | 92 | audit cohesion before local cleanup |
| 7 | `SymbolEntry` ([`/home/yahn/cheat/src/ast/symbol_entry.rb`](../../src/ast/symbol_entry.rb)) | 157.40 | state-heavy, many-mutators, low-cohesion-candidate | 26 | 56 | 27 | 24 | extract phase-state records and split lifecycle ownership |
| 8 | `MIREmitter` ([`/home/yahn/cheat/src/backends/mir_emitter.rb`](../../src/backends/mir_emitter.rb)) | 149.55 | state-heavy, low-cohesion-candidate | 7 | 197 | 5 | 1 | audit cohesion before local cleanup |
| 9 | `SemanticAnnotator` ([`/home/yahn/cheat/src/annotator/annotator.rb`](../../src/annotator/annotator.rb)) | 142.50 | state-heavy | 14 | 70 | 34 | 42 | audit cohesion before local cleanup |
| 10 | `Formatter::Emitter` ([`/home/yahn/cheat/src/tools/formatter.rb`](../../src/tools/formatter.rb)) | 135.45 | - | 3 | 104 | 38 | 47 | audit cohesion before local cleanup |
| 11 | `FunctionAnalysis` ([`/home/yahn/cheat/src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb)) | 121.20 | state-heavy, low-cohesion-candidate | 30 | 52 | 0 | 0 | extract phase-state records and split lifecycle ownership |
| 12 | `OwnershipDataflow` ([`/home/yahn/cheat/src/mir/control_flow.rb`](../../src/mir/control_flow.rb)) | 106.60 | state-heavy | 5 | 55 | 34 | 48 | audit cohesion before local cleanup |
| 13 | `LSP::Server` ([`/home/yahn/cheat/src/lsp/server.rb`](../../src/lsp/server.rb)) | 104.85 | state-heavy | 14 | 21 | 32 | 31 | audit cohesion before local cleanup |
| 14 | `MIRPass` ([`/home/yahn/cheat/src/mir/mir_pass.rb`](../../src/mir/mir_pass.rb)) | 104.80 | state-heavy, low-cohesion-candidate | 19 | 43 | 14 | 12 | audit cohesion before local cleanup |
| 15 | `PipelineListLowerer` ([`/home/yahn/cheat/src/mir/lower/pipeline/pipeline_list_lowerer.rb`](../../src/mir/lower/pipeline/pipeline_list_lowerer.rb)) | 104.40 | - | 0 | 19 | 60 | 60 | audit cohesion before local cleanup |
| 16 | `Scope` ([`/home/yahn/cheat/src/ast/scope.rb`](../../src/ast/scope.rb)) | 96.05 | state-heavy | 10 | 35 | 28 | 27 | audit cohesion before local cleanup |
| 17 | `MIRChecker` ([`/home/yahn/cheat/src/mir/mir_checker.rb`](../../src/mir/mir_checker.rb)) | 95.35 | - | 4 | 127 | 4 | 1 | audit cohesion before local cleanup |
| 18 | `OwnershipGraph` ([`/home/yahn/cheat/src/semantic/ownership_graph.rb`](../../src/semantic/ownership_graph.rb)) | 90.65 | state-heavy, low-cohesion-candidate | 12 | 34 | 19 | 27 | audit cohesion before local cleanup |
| 19 | `MIRLoweringExpressions` ([`/home/yahn/cheat/src/mir/lowering/expressions.rb`](../../src/mir/lowering/expressions.rb)) | 88.80 | state-heavy, low-cohesion-candidate | 8 | 108 | 0 | 0 | audit cohesion before local cleanup |
| 20 | `Annotator::Domains::ControlFlow` ([`/home/yahn/cheat/src/annotator/domains/control_flow.rb`](../../src/annotator/domains/control_flow.rb)) | 87.60 | state-heavy, low-cohesion-candidate | 20 | 46 | 0 | 0 | extract phase-state records and split lifecycle ownership |

## Encapsulation Pressure
_Owners where public API, mutable state, and internal-helper evidence suggest implementation detail is leaking._

| # | owner | score | flags | public/private | state | public state | public mutators | internal helpers | fan-out | suggested refactor |
|---|-------|-------|-------|----------------|-------|--------------|-----------------|------------------|---------|--------------------|
| 1 | `PipelineHost` ([`/home/yahn/cheat/src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) | 330.60 | state-heavy, broad-public-api, public-state-surface, public-mutators, lifecycle-state | 94/0 | 20 | 69 | 2 | - | 0 | extract a smaller state/context owner behind this public surface |
| 2 | `ClearParser` ([`/home/yahn/cheat/src/ast/parser.rb`](../../src/ast/parser.rb)) | 314.00 | state-heavy, broad-public-api, public-state-surface, public-mutators | 145/0 | 61 | 23 | 4 | - | 0 | extract a smaller state/context owner behind this public surface |
| 3 | `Type` ([`/home/yahn/cheat/src/ast/type.rb`](../../src/ast/type.rb)) | 307.50 | state-heavy, broad-public-api, public-state-surface, public-mutators, lifecycle-state | 276/0 | 7 | 52 | 3 | - | 0 | narrow public state access through a smaller query/session object |
| 4 | `FunctionSignature` ([`/home/yahn/cheat/src/annotator/helpers/function_signature.rb`](../../src/annotator/helpers/function_signature.rb)) | 274.60 | state-heavy, broad-public-api, public-state-surface, public-mutators, lifecycle-state | 80/0 | 24 | 42 | 6 | - | 0 | split mutable lifecycle state from the public facade |
| 5 | `MIRLowering` ([`/home/yahn/cheat/src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb)) | 212.20 | state-heavy, broad-public-api, public-state-surface | 257/0 | 17 | 23 | 1 | - | 0 | extract a smaller state/context owner behind this public surface |
| 6 | `SymbolEntry` ([`/home/yahn/cheat/src/ast/symbol_entry.rb`](../../src/ast/symbol_entry.rb)) | 177.80 | state-heavy, broad-public-api, public-state-surface, public-mutators | 56/0 | 26 | 17 | 4 | - | 0 | extract a smaller state/context owner behind this public surface |
| 7 | `SemanticAnnotator` ([`/home/yahn/cheat/src/annotator/annotator.rb`](../../src/annotator/annotator.rb)) | 172.40 | state-heavy, broad-public-api, public-state-surface, public-mutators | 70/0 | 14 | 29 | 2 | - | 0 | extract a smaller state/context owner behind this public surface |
| 8 | `Formatter::Emitter` ([`/home/yahn/cheat/src/tools/formatter.rb`](../../src/tools/formatter.rb)) | 152.30 | broad-public-api, public-state-surface | 104/0 | 3 | 34 | 1 | - | 0 | narrow public state access through a smaller query/session object |
| 9 | `PipelineConcurrentLowerer` ([`/home/yahn/cheat/src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb`](../../src/mir/lower/pipeline/pipeline_concurrent_lowerer.rb)) | 144.10 | broad-public-api, public-state-surface | 87/0 | 2 | 36 | 0 | - | 0 | narrow public state access through a smaller query/session object |
| 10 | `MIREmitter` ([`/home/yahn/cheat/src/backends/mir_emitter.rb`](../../src/backends/mir_emitter.rb)) | 135.80 | state-heavy, broad-public-api, public-state-surface, public-mutators | 197/0 | 7 | 5 | 4 | - | 0 | verify the broad public surface is intentional |
| 11 | `Scope` ([`/home/yahn/cheat/src/ast/scope.rb`](../../src/ast/scope.rb)) | 122.10 | state-heavy, broad-public-api, public-state-surface, public-mutators, lifecycle-state | 35/0 | 10 | 18 | 2 | - | 0 | extract a smaller state/context owner behind this public surface |
| 12 | `AST::Locatable` ([`/home/yahn/cheat/src/ast/ast.rb`](../../src/ast/ast.rb)) | 118.30 | state-heavy, broad-public-api, public-state-surface, public-mutators | 61/0 | 8 | 10 | 5 | - | 0 | split mutable lifecycle state from the public facade |
| 13 | `LSP::Server` ([`/home/yahn/cheat/src/lsp/server.rb`](../../src/lsp/server.rb)) | 117.10 | state-heavy, broad-public-api, public-state-surface, lifecycle-state | 21/0 | 14 | 18 | 0 | - | 0 | extract a smaller state/context owner behind this public surface |
| 14 | `OwnershipDataflow` ([`/home/yahn/cheat/src/mir/control_flow.rb`](../../src/mir/control_flow.rb)) | 114.80 | state-heavy, broad-public-api, public-state-surface | 55/0 | 5 | 24 | 0 | - | 0 | narrow public state access through a smaller query/session object |
| 15 | `OwnershipGraph` ([`/home/yahn/cheat/src/semantic/ownership_graph.rb`](../../src/semantic/ownership_graph.rb)) | 108.80 | state-heavy, broad-public-api, public-state-surface, public-mutators, lifecycle-state | 34/0 | 12 | 12 | 2 | - | 0 | extract a smaller state/context owner behind this public surface |
| 16 | `FunctionAnalysis` ([`/home/yahn/cheat/src/annotator/helpers/function_analysis.rb`](../../src/annotator/helpers/function_analysis.rb)) | 103.60 | state-heavy, broad-public-api | 52/0 | 30 | 0 | 0 | - | 0 | verify the broad public surface is intentional |
| 17 | `PipelineLoweringBridge` ([`/home/yahn/cheat/src/mir/lower/pipeline/pipeline_lowering_bridge.rb`](../../src/mir/lower/pipeline/pipeline_lowering_bridge.rb)) | 92.40 | broad-public-api, public-state-surface | 21/0 | 3 | 21 | 1 | - | 0 | narrow public state access through a smaller query/session object |
| 18 | `MIRPass` ([`/home/yahn/cheat/src/mir/mir_pass.rb`](../../src/mir/mir_pass.rb)) | 92.20 | state-heavy, broad-public-api, public-state-surface | 43/0 | 19 | 6 | 0 | - | 0 | extract a smaller state/context owner behind this public surface |
| 19 | `Pprof::Profile` ([`/home/yahn/cheat/src/tools/pprof.rb`](../../src/tools/pprof.rb)) | 87.90 | state-heavy, public-state-surface, public-mutators | 16/0 | 15 | 7 | 2 | - | 0 | extract a smaller state/context owner behind this public surface |
| 20 | `PipelinePlaceholderRewriter` ([`/home/yahn/cheat/src/mir/lower/pipeline/pipeline_context.rb`](../../src/mir/lower/pipeline/pipeline_context.rb)) | 84.90 | state-heavy, broad-public-api, public-state-surface | 22/0 | 17 | 6 | 0 | - | 0 | extract a smaller state/context owner behind this public surface |

## Owner State Cohesion
_Class-level LCOM-style state clusters: methods connected through shared instance state._

| # | owner | score | flags | state | stateful methods | components | bridges | largest | fragmentation | isolated | sample components | suggested refactor |
|---|-------|-------|-------|-------|------------------|------------|---------|---------|---------------|----------|-------------------|--------------------|
| 1 | `PipelineHost` ([`/home/yahn/cheat/src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) | 160.82 | split-state-components, high-fragmentation, isolated-state-methods | 20 | 67 | 11 | - | 20 (0.30) | 0.70 | 4 | 20m/2s list_lowerer, scalar_lowerer: lower_all, lower_any; 17m/1s range_lowerer: bc_for_iter_range, build_lazy_range_prefix; 12m/3s binding_chain_lowerer, lowering_bridge: bc_target?, build_concurrent_lowerer | split state clusters into smaller owner/context objects |
| 2 | `ClearParser` ([`/home/yahn/cheat/src/ast/parser.rb`](../../src/ast/parser.rb)) | 105.40 | split-state-components, high-fragmentation | 61 | 20 | 6 | - | 8 (0.40) | 0.60 | 0 | 8m/1s tokens: current, emit_consume_error_with_fix; 3m/1s pos: consume, consume_number; 3m/1s stmt_rules: parse_bg_body_stmt, parse_statement | split state clusters into smaller owner/context objects |
| 3 | `SymbolEntry` ([`/home/yahn/cheat/src/ast/symbol_entry.rb`](../../src/ast/symbol_entry.rb)) | 89.79 | split-state-components, high-fragmentation, isolated-state-methods | 26 | 7 | 5 | - | 2 (0.29) | 0.71 | 3 | 2m/1s flow: flow_snapshot, invalidate!; 2m/1s reg: mark_mutated!, mark_read!; 1m/1s lifetime: lifetime= | split state clusters into smaller owner/context objects |
| 4 | `Type` ([`/home/yahn/cheat/src/ast/type.rb`](../../src/ast/type.rb)) | 69.30 | split-state-components, high-fragmentation | 7 | 48 | 4 | - | 24 (0.50) | 0.50 | 1 | 24m/1s shape: array?, auto?; 16m/1s capabilities: apply_capabilities!, collection; 7m/1s placement: apply_placement!, frame? | split state clusters into smaller owner/context objects |
| 5 | `FsmTransform::RecursiveSplitter::Builder` ([`/home/yahn/cheat/src/mir/fsm_transform/recursive_splitter.rb`](../../src/mir/fsm_transform/recursive_splitter.rb)) | 62.00 | split-state-components, high-fragmentation, isolated-state-methods | 5 | 6 | 4 | - | 3 (0.50) | 0.50 | 3 | 3m/2s alias_overrides_for, segments: fill, finalize; 1m/1s synthetic_fields: add_synthetic_field; 1m/1s next_lock_index: reserve_lock_index | split state clusters into smaller owner/context objects |
| 6 | `AST::Locatable` ([`/home/yahn/cheat/src/ast/ast.rb`](../../src/ast/ast.rb)) | 44.20 | split-state-components, isolated-state-methods | 8 | 6 | 3 | - | 4 (0.67) | 0.33 | 2 | 4m/2s coerced_type, type_object: base_type, coerce!; 1m/1s coerced_type_object: coerced_type; 1m/1s full_type: typed? | review isolated state concerns before adding more API |
| 7 | `AST` ([`/home/yahn/cheat/src/ast/ast.rb`](../../src/ast/ast.rb)) | 37.70 | high-fragmentation | 8 | 4 | 2 | - | 2 (0.50) | 0.50 | 0 | 2m/2s next_user_id, stdlib_frozen: self.register_type!, self.reset_user_types!; 2m/1s body: self.each_bg_block, self.lambda_body_nodes | verify these state clusters belong on one owner |
| 8 | `OwnershipDataflow` ([`/home/yahn/cheat/src/mir/control_flow.rb`](../../src/mir/control_flow.rb)) | 30.25 | - | 5 | 9 | 2 | - | 6 (0.67) | 0.33 | 0 | 6m/3s block_in, block_out: analyze!, block_exit_cleanup_summaries; 3m/1s fn_node: cleanup_decisions!, cleanup_entry_pairs | verify these state clusters belong on one owner |

## Collaboration Meshes
_Owner-to-owner webs from manifest-visible delegation targets._

None.

## Mediator/Reification Candidates
_Dense or broad collaboration clusters where a missing or overloaded role object may exist._

None.

## Coordinator/Mutator Collisions
_Methods that both mutate phase state and coordinate many calls._

| # | method | score | reads | writes | always | conditional | overlap | suggested refactor |
|---|--------|-------|-------|--------|--------|-------------|---------|--------------------|
| 1 | `MIRLoweringFunctions::FunctionState#activate!` ([`/home/yahn/cheat/src/mir/lowering/functions.rb`](../../src/mir/lowering/functions.rb#L191)) | 45.00 | 0 | 9 | 0 | 0 | - | move writes behind a smaller state object or transaction helper |
| 2 | `FunctionSignature#replace_import_mutable_state!` ([`/home/yahn/cheat/src/annotator/helpers/function_signature.rb`](../../src/annotator/helpers/function_signature.rb#L622)) | 30.70 | 3 | 1 | 14 | 0 | - | extract decision table or named policy helper |
| 3 | `Annotator::Phases::BodyFactFrame#restore_context` ([`/home/yahn/cheat/src/annotator/phases/body_analysis.rb`](../../src/annotator/phases/body_analysis.rb#L89)) | 25.00 | 0 | 5 | 0 | 0 | - | move writes behind a smaller state object or transaction helper |
| 4 | `ZigTranspiler#transpile_mir` ([`/home/yahn/cheat/src/backends/transpiler.rb`](../../src/backends/transpiler.rb#L71)) | 22.30 | 1 | 4 | 1 | 0 | - | extract decision table or named policy helper |
| 5 | `SymbolEntry#initialize_copy` ([`/home/yahn/cheat/src/ast/symbol_entry.rb`](../../src/ast/symbol_entry.rb#L429)) | 15.00 | 0 | 3 | 0 | 0 | - | extract decision table or named policy helper |
| 6 | `FunctionSignature#dup` ([`/home/yahn/cheat/src/annotator/helpers/function_signature.rb`](../../src/annotator/helpers/function_signature.rb#L595)) | 14.20 | 2 | 0 | 14 | 0 | - | extract decision table or named policy helper |
| 7 | `Formatter::FormatLexer#advance` ([`/home/yahn/cheat/src/tools/formatter.rb`](../../src/tools/formatter.rb#L246)) | 13.50 | 3 | 1 | 5 | 0 | - | extract decision table or named policy helper |
| 8 | `Scope#initialize_copy` ([`/home/yahn/cheat/src/ast/scope.rb`](../../src/ast/scope.rb#L158)) | 12.30 | 1 | 2 | 1 | 0 | - | extract decision table or named policy helper |
| 9 | `ZigTranspiler#transpile_as_module` ([`/home/yahn/cheat/src/backends/transpiler.rb`](../../src/backends/transpiler.rb#L167)) | 12.30 | 1 | 2 | 1 | 0 | - | extract decision table or named policy helper |
| 10 | `Formatter::Emitter#format_line_body` ([`/home/yahn/cheat/src/tools/formatter.rb`](../../src/tools/formatter.rb#L2632)) | 12.30 | 1 | 2 | 1 | 0 | - | extract decision table or named policy helper |
| 11 | `MIRLowering#record_ownership_finalization_surface_node!` ([`/home/yahn/cheat/src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb#L1405)) | 12.10 | 1 | 1 | 7 | 0 | - | extract decision table or named policy helper |
| 12 | `SemanticAnnotator#annotate!` ([`/home/yahn/cheat/src/annotator/annotator.rb`](../../src/annotator/annotator.rb#L554)) | 10.00 | 0 | 2 | 0 | 0 | - | extract decision table or named policy helper |
| 13 | `FunctionSignature#sync_from_function_def!` ([`/home/yahn/cheat/src/annotator/helpers/function_signature.rb`](../../src/annotator/helpers/function_signature.rb#L672)) | 10.00 | 0 | 2 | 0 | 0 | - | extract decision table or named policy helper |
| 14 | `Pprof::Profile#set_period_type` ([`/home/yahn/cheat/src/tools/pprof.rb`](../../src/tools/pprof.rb#L100)) | 10.00 | 0 | 2 | 0 | 0 | - | extract decision table or named policy helper |
| 15 | `Lexer#advance_pos` ([`/home/yahn/cheat/src/ast/lexer.rb`](../../src/ast/lexer.rb#L301)) | 9.60 | 2 | 1 | 2 | 0 | - | extract decision table or named policy helper |
| 16 | `SymbolEntry#lifetime=` ([`/home/yahn/cheat/src/ast/symbol_entry.rb`](../../src/ast/symbol_entry.rb#L151)) | 8.90 | 1 | 1 | 3 | 0 | - | extract decision table or named policy helper |
| 17 | `AST::Locatable#coerce!` ([`/home/yahn/cheat/src/ast/ast.rb`](../../src/ast/ast.rb#L1071)) | 8.10 | 1 | 1 | 2 | 0 | - | extract decision table or named policy helper |
| 18 | `SemanticAnnotator#with_predicate_context` ([`/home/yahn/cheat/src/annotator/annotator.rb`](../../src/annotator/annotator.rb#L414)) | 7.30 | 1 | 1 | 1 | 0 | - | extract decision table or named policy helper |
| 19 | `AST::BodySlot#replace` ([`/home/yahn/cheat/src/ast/ast.rb`](../../src/ast/ast.rb#L36)) | 7.30 | 1 | 1 | 1 | 0 | - | extract decision table or named policy helper |
| 20 | `Scope#install_entry` ([`/home/yahn/cheat/src/ast/scope.rb`](../../src/ast/scope.rb#L140)) | 7.30 | 1 | 1 | 1 | 0 | - | extract decision table or named policy helper |

## Conditional Delegation Hubs
_Branchy orchestration boundaries, independent of direct state writes._

| # | method | conditional calls | always calls | state touches | suggested refactor |
|---|--------|-------------------|--------------|---------------|--------------------|

## State Lifecycle Pressure
_State slots with many readers/writers or protocol-shaped behavior._

| # | state | owner | score | readers | writers | type | protocol evidence | suggested refactor |
|---|-------|-------|-------|---------|---------|------|-------------------|--------------------|
| 1 | `receiver_state` | `SemanticAnnotator` ([`/home/yahn/cheat/src/annotator/annotator.rb`](../../src/annotator/annotator.rb)) | 43.50 | 27 | 1 | - | - | verify this state belongs on the owner |
| 2 | `facts` | `FunctionSignature` ([`/home/yahn/cheat/src/annotator/helpers/function_signature.rb`](../../src/annotator/helpers/function_signature.rb)) | 42.00 | 22 | 3 | - | - | verify this state belongs on the owner |
| 3 | `lowering` | `PipelineLoweringBridge` ([`/home/yahn/cheat/src/mir/lower/pipeline/pipeline_lowering_bridge.rb`](../../src/mir/lower/pipeline/pipeline_lowering_bridge.rb)) | 37.50 | 21 | 2 | - | - | verify this state belongs on the owner |
| 4 | `contract` | `FunctionSignature` ([`/home/yahn/cheat/src/annotator/helpers/function_signature.rb`](../../src/annotator/helpers/function_signature.rb)) | 36.00 | 16 | 4 | - | - | centralize writes behind one owner |
| 5 | `shape` | `Type` ([`/home/yahn/cheat/src/ast/type.rb`](../../src/ast/type.rb)) | 36.00 | 24 | 0 | - | - | verify this state belongs on the owner |
| 6 | `state` | `MIRLowering` ([`/home/yahn/cheat/src/mir/mir_lowering.rb`](../../src/mir/mir_lowering.rb)) | 36.00 | 22 | 1 | - | - | verify this state belongs on the owner |
| 7 | `host` | `PipelineRangeLowerer` ([`/home/yahn/cheat/src/mir/lower/pipeline/pipeline_range_lowerer.rb`](../../src/mir/lower/pipeline/pipeline_range_lowerer.rb)) | 28.50 | 19 | 0 | - | - | verify this state belongs on the owner |
| 8 | `range_lowerer` | `PipelineHost` ([`/home/yahn/cheat/src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) | 25.50 | 17 | 0 | - | - | verify this state belongs on the owner |
| 9 | `capabilities` | `Type` ([`/home/yahn/cheat/src/ast/type.rb`](../../src/ast/type.rb)) | 24.00 | 16 | 0 | - | - | verify this state belongs on the owner |
| 10 | `logger` | `LSP::Server` ([`/home/yahn/cheat/src/lsp/server.rb`](../../src/lsp/server.rb)) | 21.00 | 14 | 0 | - | - | verify this state belongs on the owner |
| 11 | `bindings` | `Scope` ([`/home/yahn/cheat/src/ast/scope.rb`](../../src/ast/scope.rb)) | 18.00 | 10 | 1 | - | - | verify this state belongs on the owner |
| 12 | `list_lowerer` | `PipelineHost` ([`/home/yahn/cheat/src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) | 18.00 | 12 | 0 | - | - | verify this state belongs on the owner |
| 13 | `lowering_bridge` | `PipelineHost` ([`/home/yahn/cheat/src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) | 16.50 | 11 | 0 | - | - | verify this state belongs on the owner |
| 14 | `nodes` | `OwnershipGraph` ([`/home/yahn/cheat/src/semantic/ownership_graph.rb`](../../src/semantic/ownership_graph.rb)) | 15.00 | 6 | 2 | - | - | verify this state belongs on the owner |
| 15 | `scalar_lowerer` | `PipelineHost` ([`/home/yahn/cheat/src/mir/lower/pipeline/pipeline_host.rb`](../../src/mir/lower/pipeline/pipeline_host.rb)) | 13.50 | 9 | 0 | - | - | verify this state belongs on the owner |
| 16 | `slots` | `MIR::InlineAllocMetadata` ([`/home/yahn/cheat/src/mir/mir.rb`](../../src/mir/mir.rb)) | 13.50 | 7 | 1 | - | - | verify this state belongs on the owner |
| 17 | `source_code` | `FixableHelper` ([`/home/yahn/cheat/src/annotator/helpers/fixable_helpers.rb`](../../src/annotator/helpers/fixable_helpers.rb)) | 12.00 | 8 | 0 | - | - | verify this state belongs on the owner |
| 18 | `tokens` | `ClearParser` ([`/home/yahn/cheat/src/ast/parser.rb`](../../src/ast/parser.rb)) | 12.00 | 8 | 0 | - | - | verify this state belongs on the owner |
| 19 | `entries` | `Scope::ScopeBindings` ([`/home/yahn/cheat/src/ast/scope.rb`](../../src/ast/scope.rb)) | 12.00 | 6 | 1 | - | - | verify this state belongs on the owner |
| 20 | `parent` | `Scope` ([`/home/yahn/cheat/src/ast/scope.rb`](../../src/ast/scope.rb)) | 12.00 | 8 | 0 | - | - | verify this state belongs on the owner |

## Privatization Candidates
_Public methods that likely should be private: same-owner callers, no manifest-visible external receiver calls, and helper/protocol evidence._

None.
