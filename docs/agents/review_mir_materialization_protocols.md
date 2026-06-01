# MIR Materialization Protocol Review

## Goal

Replace the implicit MIR ownership/materialization protocols with complete,
single-path emitters. Each item must delete the old local protocol it replaces,
migrate every caller to the new shape, and show its Decomplex and SlopCop
movement before moving on.

No compatibility paths are allowed. If a new architecture is introduced, the old
surface is removed in the same slice.

## Cross-Cutting Protocols

MIR currently spreads one logical operation across several files:

- decide whether a value owns memory (`ownership_effect`, `mir_allocates?`,
  `mir_owned_alloc`);
- decide where the value lives (`DestinationPlacementPlan`,
  `return_destination_alloc`, `placement_for_node`);
- create verification markers (`MIR::AllocMark`, `MIR::Cleanup`,
  `MIR::ErrCleanup`, `MIR::TransferMark`, `MIR::MoveMark`);
- choose cleanup metadata (`CleanupEntry`, `hoist_cleanup_entry`,
  `build_drop_entry!`);
- stamp target names onto allocating expressions
  (`stamp_allocating_result_target!`).

That contract is not represented as one data shape. Lowering sites therefore
repeat local branch ladders and must remember which side effects are required
for each ownership case.

## Offender Map

### 1. Variable Declaration Materialization

Files:

- `src/mir/lowering/variables.rb`
- `src/mir/mir_lowering.rb`
- `src/mir/hoist.rb`

Primary methods:

- `MIRLoweringVariables#lower_var_decl`
- `MIRLoweringVariables#build_var_decl_nodes`
- `MIRLoweringVariables#var_decl_alloc_mark`
- `MIRLoweringVariables#moved_guard_cleanup_entry`

Problem:

`build_var_decl_nodes` locally decides every combination of classifier cleanup,
owned-return calls, transferred owned bindings, inline Zig allocator metadata,
mutable ownership-bearing locals, and raw allocating expressions. Each arm then
repeats the same operations: choose alloc, build/drop cleanup entry, mark guarded
cleanup names, emit `AllocMark`, emit `Let`, maybe emit `Cleanup`.

Complete replacement:

Delete `build_var_decl_nodes` as a branch ladder and replace it with a typed
`VarDeclMaterializationPlan` that answers exactly one question: what marker
nodes surround this declaration? `lower_var_decl` should always receive an
array of MIR statements from the plan. The planner owns cleanup entry creation,
allocator selection, guarded-name marking, and allocation-marker creation.

Expected payoff:

This is the worst first target because it is self-contained: every declaration
already passes through one method and emits a small fixed output shape.

### 2. Destination Placement

Files:

- `src/mir/mir_lowering.rb`
- `src/mir/lowering/variables.rb`
- `src/mir/lowering/literals.rb`
- `src/mir/lowering/concurrency.rb`

Primary methods:

- `MIRLowering#place_value_for_destination`
- `MIRLowering#destination_placement_plan`
- `MIRLowering#place_owned_branch_value_for_destination`
- `MIRLowering#place_owned_alloc_mismatch_for_destination`
- `MIRLowering#return_destination_alloc`

Problem:

Destination placement already has a typed plan, but execution is still a case
statement that recursively calls other placement helpers. It knows about strings,
owned branch results, OR / OR_RESCUE, try/catch, heap indirects, and allocator
mismatch blocks.

Complete replacement:

Promote placement from "action enum plus case statement" to typed plan objects
that emit their own MIR node. Delete the shared case dispatcher after every
action is migrated. The new boundary should consume a typed source fact and
produce a placed MIR node, with no fallback to the old dispatcher.

Expected payoff:

Moderate to high. This is a foundation for `lower_smooth`, return lowering, and
block result placement. The first slice may be mixed if the typed plan classes
are introduced here and then reused by later items.

### 3. Hoist Allocation Materialization

Files:

- `src/mir/hoist.rb`
- `src/mir/mir_lowering.rb`
- `src/mir/mir_checker.rb`

Primary methods:

- `MIRHoistLowering#hoist_alloc`
- `MIRHoistLowering#hoist_normalized_alloc_expr`
- `MIRHoistLowering#mir_allocates?`
- `MIRHoistLowering#mir_owned_alloc`
- `MIRHoistLowering#hoist_cleanup_entry`
- `MIRHoistLowering#mir_alloc_mark_type_info`

Problem:

Hoisting is the closest thing to an allocation materializer, but it exposes many
small queries instead of one authoritative result. Callers ask whether a value
allocates, ask which allocator it uses, ask for cleanup metadata, and then emit
their own markers.

Complete replacement:

Introduce a typed allocation materialization object that contains the producer
node, target name, allocator, type, cleanup entry, transfer behavior, and emitted
statements. Migrate hoist callers to request the object and append its statements.
Delete the public query chain for callers that should not make ownership
decisions themselves.

Expected payoff:

High, but riskier than variable declarations. This touches many paths and should
come after the var-decl slice proves the materialization object shape.

### 4. Smooth Pipeline Lowering

Files:

- `src/mir/lowering/expressions.rb`
- `src/mir/mir_lowering.rb`
- `src/mir/hoist.rb`

Primary method:

- `MIRLoweringExpressions#lower_smooth`

Problem:

Smooth lowering has to thread pipeline source, destination placement, snapshot
handling, ownership, and cleanup through one expression method. SlopCop and
Decomplex both keep finding it because several hidden ownership protocols meet
there.

Complete replacement:

Reify smooth lowering as a typed pipeline materialization plan. It should own
source lowering, optional snapshot, destination placement, and final ownership
markers. Delete the old `lower_smooth` internal branch protocol.

Expected payoff:

High after destination placement and hoist materialization exist. Starting here
first risks adding abstractions without deleting enough old code.

### 5. Background Block Lowering

Files:

- `src/mir/lowering/concurrency.rb`
- `src/mir/capture_strategy.rb`
- `src/mir/mir_lowering.rb`
- `src/mir/hoist.rb`

Primary method:

- `MIRLoweringConcurrency#lower_bg_block`

Problem:

`capture_strategy.rb` already describes the intended capture/marker plan, but
`lower_bg_block` still performs much of the marker emission and result placement
itself. That keeps capture strategy, runtime context fields, and ownership
markers coupled in one long method.

Complete replacement:

Finish migrating BG lowering to consume capture strategy marker plans directly.
Delete the local marker emission branches once every capture mode is represented
in `CaptureStrategy`.

Expected payoff:

High, but only if completed. Partial migration is explicitly not valuable.

### 6. Capability WITH Block Lowering

Files:

- `src/mir/lowering/capabilities.rb`
- `src/mir/mir_lowering.rb`
- `src/mir/hoist.rb`

Primary method:

- `MIRLoweringCapabilities#lower_with_block`

Problem:

WITH lowering owns capability alias setup, unwrap maps, cleanup markers, and
block result materialization. It is smaller than BG lowering but has the same
shape: state setup and ownership cleanup are interleaved.

Complete replacement:

Create one typed WITH lowering plan that contains alias bindings, unwrap-map
changes, body lowering, and cleanup emission. Delete direct marker branches from
`lower_with_block`.

Expected payoff:

Moderate. Worth doing after the shared materialization helpers exist.

### 7. Intrinsic Lowering

Files:

- `src/mir/lowering/functions.rb`
- `src/mir/mir_lowering.rb`
- `src/mir/hoist.rb`

Primary method:

- `MIRLoweringFunctions#lower_intrinsic`

Problem:

Intrinsic lowering builds stdlib call facts and ownership facts locally. It is
less structurally bad than variable declarations or BG lowering, but it still
duplicates call-result ownership materialization.

Complete replacement:

Make intrinsic lowering produce a typed call materialization fact consumed by the
same allocation materializer used by variable declarations and hoisting. Delete
intrinsic-only ownership marker branches.

Expected payoff:

Moderate, mostly from reuse after hoist materialization.

## Execution Order

1. Replace variable declaration materialization.
2. Replace destination placement execution.
3. Replace hoist allocation materialization.
4. Replace smooth pipeline lowering.
5. Finish background block capture marker migration.
6. Replace WITH block materialization.
7. Replace intrinsic call materialization.

Each item gets its own before/after metric snapshot. A mixed first result is
acceptable only when it deletes an old protocol and creates a reused architecture
that the following items immediately consume.

## Session Results

Baseline:

- `tmp/agent-metrics/decomplex-before-mir-materialization.md`
- `tmp/agent-metrics/slopcop-before-mir-materialization.md`

### Variable Declaration Materialization

Status: implemented.

Change:

- Deleted `build_var_decl_nodes`.
- Added `VarDeclMaterializationPlan`.
- `lower_var_decl` now consumes one statement-array materialization surface.

Metrics:

- Decomplex: `build_var_decl_nodes` disappeared from top findings.
- SlopCop: the repeated score-16 `build_var_decl_nodes` entries disappeared.
- Mixed aggregate: Decomplex Broken Protocols rose because the previous branch
  ladder became several small typed helper methods. This is acceptable only as a
  foundation for broader ownership materialization; it should not be repeated as
  a standalone pattern unless the helpers get reused.

### Destination Placement Execution

Status: implemented, low-confidence payoff.

Change:

- Moved the execution dispatcher from `place_value_for_destination` onto
  `DestinationPlacementPlan#place`.
- Kept the existing plan-selection surface.

Metrics:

- Decomplex was effectively flat after this slice.
- SlopCop line-based movement is noisy because coverage was not regenerated
  after line shifts.

Evaluation:

- This is architectural cleanup, but not enough by itself. A more valuable next
  destination-placement slice would delete the action-symbol dispatcher entirely
  by using typed placement action objects.

### Hoist Allocation Materialization

Status: implemented.

Change:

- Added `HoistedAllocationPlan`.
- Both `hoist_alloc` and `hoist_normalized_alloc_expr` now build the same typed
  `AllocMark` / `Let` / cleanup packet.
- Deleted dead `pick_node_alloc`.

Metrics:

- Decomplex Broken Protocols improved from the prior slice: 507 -> 505.
- Several old hoist allocation packet entries disappeared or moved out of the
  top SlopCop pressure.

Evaluation:

- Worth keeping. This is a real shared materialization boundary and should be
  the object future lowering paths consume.

### Smooth Pipeline Lowering

Status: implemented.

Change:

- Deleted the monolithic `lower_smooth` body.
- Split complex pipeline, COLLECT, RECOVER, snapshot, and simple call-pipe
  lowering into separate strongly typed helpers.

Metrics:

- Decomplex Broken Protocols improved from the hoist slice: 505 -> 501.
- `lower_smooth` disappeared as the top MIR expression hotspot.
- SlopCop no longer lists the score-16 `lower_smooth` entry.

Evaluation:

- Worth keeping. This eliminated a major hotspot without introducing a dual
  path.

### Background Block Lowering

Status: not implemented in this session.

Reason:

- `lower_bg_block` owns capture strategy consumption, runtime context text,
  body lowering, result placement, FSM transform fallback, and checker-visible
  MIR mirroring. A complete replacement means moving those concerns into typed
  BG capture/body/result plans and deleting the inline branches. A partial split
  would leave dual architecture and is not acceptable.

Next complete slice:

- Introduce a typed BG body lowering plan that owns `flat_steps`, `run_body`,
  `stmt_code`, and `result_line`.
- Migrate both pre-step and last-step lowering to it.
- Delete the inline `flat_steps` / `with_bg_fiber_body_context` block from
  `lower_bg_block`.

### WITH Block Materialization

Status: not implemented in this session.

Reason:

- `lower_with_block` mixes capability acquisition, fallible lock clauses,
  alias/unwrap maps, MVCC structured nodes, legacy Zig text, and body wrapping.
  A complete replacement needs a typed capability binding plan and a typed body
  plan. Extracting only helper methods would preserve the mixed protocol and
  add churn.

Next complete slice:

- Create a typed `WithCapabilityBindingPlan` for each capability.
- Make each plan emit either structured MIR nodes or explicit legacy Zig text.
- Delete the per-capability `case` from `lower_with_block` once every capability
  arm has migrated.

### Intrinsic Call Materialization

Status: not implemented in this session.

Reason:

- `lower_intrinsic` should consume the hoist allocation plan and a typed stdlib
  argument materialization plan. It is smaller than BG/WITH, but the complete
  replacement should follow the same no-dual-path rule: first reify stdlib
  argument materialization, then delete the local TAKES/hoist loops.

Next complete slice:

- Build a typed `StdlibArgumentMaterializationPlan` from `StdlibCallFacts`.
- Use it to lower receiver/args, owned sinks, hoists, and consumed operands.
- Delete the local `mir_args` mutation loops.
