# Annotator Decomplex Cleanup

Snapshot source: `/tmp/decomplex-decomplex3-obvious10.md` and
`/tmp/slopcop-decomplex3-obvious10.md`.

Scope: annotator and annotator-helper architecture only. MIR lowering,
placement, ownership, and checker cleanup are tracked separately in
`docs/agents/mir-lowering-cleanup-tracker.md`.

## Current Signal

The current SlopCop report is not an annotator coverage guide: its run summary
only covers 3 files and the top true gaps are MIR/control-flow focused. Treat
annotator SlopCop work as a follow-up measurement task: regenerate SlopCop with
annotator coverage enabled before using it to prioritize tests.

Decomplex does give clear annotator action items. The strongest convergence
points are:

- `src/annotator/annotator.rb:5471` `handle_assign_move`
- `src/annotator/helpers/function_analysis.rb:193` `resolve_call`
- `src/annotator/annotator.rb:1459` `visit_MatchStatement`
- `src/annotator/annotator.rb:4739` `visit_WithBlock`
- `src/annotator/helpers/pipe_analysis.rb:805` `analyze_pipe_to_named_function`
- `src/annotator/helpers/pipe_analysis.rb:1462` `analyze_concurrent_op`
- `src/annotator/annotator.rb:5350` `visit_NextExpr`
- `src/annotator/annotator.rb:3602` `visit_StructLit`
- `src/annotator/annotator.rb:3357` `visit_GetField`
- `src/annotator/helpers/generic_analysis.rb:227` `validate_type_annotation!`
- `src/annotator/helpers/generic_analysis.rb:558` `propagate_collection_metadata!`
- `src/annotator/annotator.rb:3963` `visit_OrRescue`

## Architectural Wins

### 1. Reify Annotation Result Writes

Problem: decomplex reports many `.full_type` writes without `.storage`, and
some `.storage` writes without `.full_type`.

Representative findings:

- `function_analysis.rb:150` `resolve_call` writes `args[i].full_type`
- `function_analysis.rb:763` `declare_and_verify_params` writes `param.default.full_type`
- `pipe_analysis.rb:34` `visit_Smooth` writes `node.full_type`
- `pipe_analysis.rb:746/767/808` pipe call/identifier/named-function writes
- `test_annotation.rb` visitor methods write node types without storage

Correct shape: introduce a typed `AnnotationStamp` or `TypedNodeStamp` object
with `type`, `storage`, and optional `slot_size`. Make annotator callers stamp
through one helper, not direct field writes.

MIR comparison: same direction as `needs_rt` and storage single-writer work:
decide once at the authoritative pass boundary, then make later code read the
fact. Do not move scattered writes into another helper unless the helper owns
the invariant that `full_type` and `storage` are co-written.

### 2. Reify Call Resolution Facts

Problem: `resolve_call` is a major root-cause cluster for `sync`, `layout`,
`ownership`, `full_type`, hidden mutation, and derived-state drift.

Correct shape: create a typed `CallResolutionFact` returned by call resolution.
It should include:

- selected callable signature
- resolved arg types and storage
- return type and storage
- ownership/capability effects
- stdlib/intrinsic/user-call classification
- diagnostics/fixables to emit

Call sites should consume this fact rather than recomputing pieces of the
signature, expected/actual types, ownership, and capability state.

MIR comparison: mirrors `CallArgFacts` / call ownership contract direction.
The annotator should feed one authoritative call fact forward; MIR should not
infer call semantics that annotation already knew.

### 3. Reify Control-Flow Annotation Plans

Problem: `visit_MatchStatement`, `visit_WhileLoop`, `visit_WhileBindLoop`,
`visit_IfBind`, and `visit_NextExpr` all converge on `expr`, `state`, and
branch merge protocols. `state == :moved` is still reported as a reification
miss.

Correct shape: create typed branch/control-flow facts:

- `BranchFlowFact`: live/moved/initialized state at branch exit
- `MatchArmFact`: pattern bindings, narrowed type, branch result type/storage
- `LoopFlowFact`: condition binding, body facts, break/continue facts
- `NextExprFact`: promise/stream shape, result type/storage, ownership effect

The annotator should merge these facts with one branch-merge API. Local visitors
should not manually reconstruct movement, storage, and result typing.

MIR comparison: same lesson as MIR checker hardening: the checker/later pass
can only verify simple invariants if the producer emits simple facts. Branch
state cannot be stored as scattered symbols and ad hoc hashes.

### 4. Reify Capability Binding Facts

Problem: `cap_var_sync`, `cap_var_layout`, `cap_var_storage`,
`validate_capability`, `acquire_capability!`, `visit_WithBlock`, and
`record_capability_binding` still show repeated `symbol/full_type/sync/layout`
protocols.

Correct shape: create a typed `CapabilityBindingFact` with:

- source root and display name
- source symbol, source type, storage
- sync family and ownership family
- access mode requested by WITH
- emitted alias/binding type and storage
- fallible sync policy requirements
- capture/parallel safety flags

This should replace symbol/type probing across `cap_var_*` helpers and should
be the only input to WITH validation and alias declaration.

MIR comparison: analogous to MIR `OwnershipTransferPlan` and capability
lowering wrapper tables. The fact should make lock/shared/local decisions data
lookups, not repeated `if sync/storage/type` checks.

### 5. Reify Pipeline Analysis Facts

Problem: `analyze_pipe_to_named_function`, `analyze_pipe_to_func_call`,
`analyze_concurrent_op`, and related stream/concurrent helpers still maintain
parallel facts about source shape, stage kind, terminal kind, observable
terminal, result type, storage, and sharding/capture state.

Correct shape: create typed pipeline facts:

- `PipelineSourceFact`: source type, element type, stream/list/range shape
- `PipelineStageFact`: operation family, predicate/result expression type,
  placeholder binding facts
- `PipelineTerminalFact`: terminal kind, result type/storage, observable facts
- `ConcurrentPipelineFact`: capture analysis, shard facts, fallible behavior

Annotation should produce these facts once; pipeline rewriting and MIR lowering
should read them. This is the annotator-side version of the MIR pipeline source
shape cleanup.

### 6. Reify Type Annotation / Generic Propagation

Problem: `validate_type_annotation!` and `propagate_collection_metadata!`
still show derived-state staleness around schema/expected/collection metadata.

Correct shape: use a typed `TypeAnnotationFact` / `GenericBindingFact`:

- declared type
- normalized type
- schema, if applicable
- capability metadata
- collection metadata source
- propagated element ownership/sync

Do not recompute collection/generic/capability pieces at downstream call sites.

MIR comparison: this is the annotator equivalent of collapsing placement and
cleanup classification into facts before MIR emission.

## Smaller Wins

- `visit_OrRescue`: remove the `payload_type` / `wrapped_type` clone drift by
  extracting a typed error-payload fact.
- `visit_Assignment`: replace the `AST::GetField | AST::GetIndex |
  AST::Identifier | String` target union with an assignment target fact.
- `analyze_select_family_op`: replace `IndexOp | OrderByOp | SelectOp |
  WhereOp` expression-shape branching with a pipeline op fact.
- `auto_inference.walk`: replace broad primitive/hash/type unions with typed
  slot records where the code is actually handling inferred shape state.
- `analyze_control_flow_branches`: replace raw `state == :moved` checks with an
  ownership/flow-state predicate or fact.

## Suggested Order

1. Add `AnnotationStamp` and route all new/full-type storage writes through it.
2. Build `CallResolutionFact` and migrate `resolve_call`.
3. Build `CapabilityBindingFact` and migrate `visit_WithBlock`/capability
   helpers.
4. Build pipeline analysis facts and migrate `pipe_analysis`.
5. Build branch/control-flow facts for match/if/while/next.
6. Regenerate SlopCop with annotator coverage enabled, then add tests against
   the remaining genuine annotator gaps.

## Non-Goals

- Do not reorganize annotator files merely to move complexity.
- Do not create typed and untyped paths.
- Do not add local exceptions for individual syntax forms unless the exception
  is represented as a typed fact consumed uniformly.
- Do not make MIR infer annotator decisions that the annotator already knew.
