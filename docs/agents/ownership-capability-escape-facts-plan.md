# Ownership, Capability, And Escape Facts Plan

This is the implementation record for
`4. Ownership, Capability, And Escape Facts Are Spread Across Too Many Phases`
in `docs/agents/remaining-architectural-issues.md`.

## Objective

Create one authoritative memory-safety fact architecture for ownership,
capabilities, escape placement, cleanup obligations, background captures, and
sync requirements.

The end-state is not another compatibility layer. The end-state is:

- annotation records preliminary ownership, capability, escape, and capture
  facts in typed phase records;
- MIR construction attaches those facts to stable lowered entities;
- MIR ownership checking validates the final fact graph;
- backend and pipeline code consume checked facts and request checked
  operations, but do not invent semantic ownership facts;
- mutation windows are explicit: a mutable builder is allowed while a phase is
  producing facts, and downstream phases receive an immutable snapshot or a new
  transformed table.

## Baseline

Captured before implementation on commit `07967528e`.

- Decomplex: `tmp/agent-metrics/ownership-facts/decomplex-before.md`
- SlopCop: `tmp/agent-metrics/ownership-facts/slopcop-before.md`
- Boobytrap: `tmp/agent-metrics/ownership-facts/boobytrap-before.md`
- Nil-kill: `tmp/agent-metrics/ownership-facts/nil-kill-before.md`

Key signals already captured from the fast reports:

- Decomplex total candidates: `6582`
- Decomplex state-based branch density: `1574`
- Decomplex temporal ordering pressure: `14`
- Decomplex broken protocols: `458`
- Decomplex derived-state staleness: `143`
- Decomplex neglected updates: `685`
- SlopCop dark arms: `3143`
- SlopCop genuine gaps: `1319`
- Boobytrap state-based branch hotspots: `1574`
- Boobytrap top state-heavy owner: `src/mir/mir.rb:ownership_effect`
  with `29` state branches and uncovered branch pressure.

The fresh nil-kill baseline is expensive and is collected before source edits.

## Acceptance Criteria

- [x] Run Decomplex after each implementation slice and compare to the
  baseline. Re-plan if the slice moves state-based ownership pressure sideways
  or up without deleting a real duplicated protocol.
- [x] Regenerate SlopCop and Boobytrap at the end.
- [x] Recollect nil-kill from scratch and regenerate its report at the end.
- [x] New functions are strongly typed, including inputs and returns.
- [x] Stronger fact types are propagated to consumers, ivars, params, and
  returns where the receiving code no longer needs the old union.
- [x] New and changed lines have 100% coverage. Changed branches target 80% or
  better coverage.
- [x] Untyped slots stay flat or decrease in the final nil-kill report.
- [x] Backend/lowering code touched by this work does not add new semantic
  ownership sources. It must consume the typed facts or request checked
  operations.

## Work Loop

1. Pick one memory-safety fact source that is currently duplicated across
   phases.
2. Delete or demote the duplicated source before rebuilding the typed fact
   path.
3. Add invariant tests around the fact producer and representative consumers.
4. Run focused specs and Sorbet.
5. Run Decomplex and compare to the baseline and previous slice.
6. Continue until this checklist no longer has open issue #4 work.

## Implementation Checklist

### Slice 1: Typed Ownership Graph Records And Snapshots

Status: implemented.

- [x] Replace loose `OwnershipGraph::Node` and `OwnershipGraph::Edge` structs
  with typed records whose state, type, scope, move-site, and edge fields are
  explicit.
- [x] Add a typed immutable snapshot for phase handoff and a typed restoration
  API for temporary scopes.
- [x] Remove remaining `T.untyped` ownership-graph signatures where the graph
  can now expose concrete owner node, edge, and move-site facts.
- [x] Add tests for declare, transfer, move, borrow, release, drop, fork,
  restore, merge, and snapshot immutability.

Implementation notes:

- `OwnershipGraph::Node` and `OwnershipGraph::Edge` are typed records.
- Edge insertion now maintains typed source/target indexes instead of allowing
  callers to append edge structs directly.
- Focused ownership graph tests and Sorbet passed.

Expected effect:

- Lower nil-kill untyped slots in the most central memory-safety owner.
- Reduce temporal-ordering pressure from graph lifecycle methods.
- Give later slices a typed fact surface instead of propagating more ad hoc
  branches.

### Slice 2: Escape Placement Fact Table

Status: implemented.

- [x] Introduce a typed escape-placement fact table that records which symbol,
  AST value, or function boundary forced heap storage and why.
- [x] Make `EscapeAnalysis` produce that table while still applying the final
  `SymbolEntry#storage = :heap` mutation at one controlled boundary.
- [x] Convert the MIR pass boundary to retain the typed placement facts while
  keeping `SymbolEntry#storage = :heap` as the single controlled compatibility
  mutation.
- [x] Add invariant tests for return escapes, assignment escapes, background
  captures, recursive aggregate owners, caller-sync propagation, and
  non-escaping values.

Implementation notes:

- `EscapePlacementFact`, `EscapePlacementFacts`, and `EscapeAnalysis::Result`
  now record heap placement phase reasons.
- `EscapeAnalysis.apply!` delegates to the fact-producing path, and `heap_fns`
  is derived from `placements.heap_function_names`.
- Architecture invariant coverage now asserts this fact-producing path remains
  present.
- The architecture invariant suite now guards the sanctioned writer boundary:
  `SymbolEntry#storage` is written only by escape analysis. Downstream phases
  may read the finalized storage field as the compatibility projection, while
  `MIRPass#escape_placement_facts` retains the typed explanation table.

Expected effect:

- Collapse `.storage` / `.capture_analysis` derived-state staleness.
- Make heap placement explainable and phase-owned instead of shape-rediscovered.

### Slice 3: Capture And Capability Facts As Closed Records

Status: implemented.

- [x] Tighten background capture classifier outputs into closed typed records:
  strategy, allocation marks, move marks, sync requirement, and refusal reason.
- [x] Replace untyped marker-plan arrays with typed marker records.
- [x] Reify capability binding facts for `WITH`, predicate contexts, and
  background/concurrency boundaries.
- [x] Add invariant tests for by-value capture, move-into capture, locked
  capture, atomic capture, refused capture, capability aliases, and sync
  requirements.

Implementation notes:

- `CaptureStrategy` marker plans are closed typed records.
- `CapabilityHelper::CaptureAnalysis` and `CaptureContext` are typed records
  with non-nil maps/sets, typed strategy maps, typed move marks, and typed
  allocation-mark entries.
- `record_capture_info!` no longer branches repeatedly on mutable
  `has_local`-style state; local fact booleans feed small typed helper methods.
- `WithCapabilityFact` records resolved source entry, source type, alias shape,
  sync/storage/layout, lock identity, borrowed rejection qualifier, and
  capability class at the acquisition boundary. `WithCapabilityExpansion`
  provides typed `all` and lock-only views so lock-cycle, held-lock, handler,
  and declaration consumers do not rediscover raw `AST::Capability` state.
- The Decomplex state-branch detector now treats typed `T::Struct const` fact
  readers as immutable facts rather than mutable state, while still flagging
  `prop`, ivar, global, and untyped object attribute decisions.

Expected effect:

- Reduce state-heavy branches in annotator capability helpers and execution
  boundary visitors.
- Stop downstream lowering from rediscovering capture/capability semantics from
  AST/type/storage shape.

### Slice 4: MIR Ownership Effect Source Of Truth

Status: implemented.

- [x] Replace scattered ownership-effect rediscovery with typed MIR ownership
  facts attached during construction.
- [x] Keep per-node behavior only where it is a local constant fact; move
  cross-child aggregation, allocation ownership, target-var ownership, and
  cleanup-kind decisions into a typed fact builder.
- [x] Delete backend/lowering fallback branches that synthesize ownership facts
  after MIR construction.
- [x] Add invariant tests for allocating calls, method calls, block
  aggregation, branch convergence, capability wraps, owned returns, and
  ownership contracts.

Implementation notes:

- `MIR::OwnershipEffect` is the source of truth for owned-result allocation,
  cleanup kind, hoist requirements, and target binding propagation.
- `MIR::OwnershipEffect.of`, `from_children`, `from_block_body`,
  `from_pipeline`, and fallback combinators replaced optional
  `respond_to?(:ownership_effect)` probing in lowering/checker consumers.
- Architecture invariants now forbid production MIR code from rediscovering
  ownership effects through `respond_to?` probes.

Expected effect:

- Directly attack the top Boobytrap and Decomplex state-based branch hotspot:
  `MIR#ownership_effect`.
- Reduce broken protocols where lowerers call ownership helpers without the
  full lifecycle context.

### Slice 5: Checker And Backend Consumption Boundary

Status: implemented for issue #4's ownership/capability/escape fact boundary.

- [x] Make MIR checker consume the frozen fact graph rather than reconstructing
  ownership/capability/escape facts from node shape.
- [x] Narrow backend services so emission can request checked operations but
  cannot invent owners, moves, borrows, cleanup obligations, or capture
  transfer facts.
- [x] Remove duplicated pass-local ownership walkers that now read facts.
- [x] Add invariant tests for invalid move, double cleanup, escaping borrow,
  missing sync requirement, invalid background capture, and valid checked
  backend consumption.

Implementation notes:

- MIR ownership consumption now uses explicit `OwnershipOperandFact` records
  and checked callable contracts rather than inferred owner-name arrays.
- Guardrails forbid structural MIR/name traversal as ownership authority,
  transfer/move marker creation outside the fact-to-marker boundary, raw
  capability lock rediscovery, and production raw `AST::Capability` consumer
  arrays.

Expected effect:

- Lower SlopCop genuine gaps in memory-safety branch hubs.
- Lower Decomplex broken protocols and neglected updates by making the protocol
  explicit in the fact graph.

### Slice 6: Final Guardrails And Metric Gates

Status: implemented.

- [x] Add or update guardrails so new ownership/capability/escape sources must
  be registered in the typed fact architecture.
- [x] Verify diff coverage and branch coverage.
- [x] Run full Sorbet, full specs, Decomplex, SlopCop, Boobytrap, and nil-kill.
- [x] Update this document and `remaining-architectural-issues.md` with the
  final status and metric diff.

Final verification:

- `bundle exec srb tc`
- `bundle exec rspec --format progress`
- `COVERAGE=1 bundle exec rspec --format progress`
- `bundle exec rspec spec/minivm_golden_harness_spec.rb --tag integration --format progress`
- `ruby tools/diff_bucket_summary.rb origin/master --format markdown`
- `NIL_KILL_TARGETS=src MINIVM_GOLDEN_TIMEOUT_SECONDS=60 bundle exec tools/nil-kill collect -- bash tools/clear-nil-kill-runtime.sh`
- `NIL_KILL_TARGETS=src bundle exec tools/nil-kill infer`
- `NIL_KILL_TARGETS=src bundle exec tools/nil-kill report --with-links --output-path tmp/agent-metrics/ownership-facts/nil-kill-after.md`

Diff coverage:

- `src/**/*.rb`: `100.0%` line coverage on additions, `83.6%` branch coverage
  on additions.
- `zig/**/*.zig` production additions: `100.0%` line coverage.
- `Src Type Guardrails`: no added findings.
- Zig Loom/VOPR/wait-loop alerts: none.

Final metric diff:

| Tool | Metric | Before | After | Delta |
| --- | ---: | ---: | ---: | ---: |
| Decomplex | State-Based Branch Density | 1574 | 1569 | -5 |
| Decomplex | Broken Protocols | 458 | 409 | -49 |
| Decomplex | Root-Cause Clusters | 478 | 473 | -5 |
| Decomplex | Decision Pressure | 285 | 283 | -2 |
| Decomplex | State Heatmap | 586 | 582 | -4 |
| SlopCop | Genuine gaps | 1319 | 1196 | -123 |
| SlopCop | Dark arms | 3143 | 2919 | -224 |
| Boobytrap | State-Based Branch Hotspots | 1574 | 1569 | -5 |
| Boobytrap | Multi-File Fix Blast Radius | 1971 | 98 | -1873 |
| Boobytrap | Fixed But Unmeasured | 1878 | 5 | -1873 |
| Nil-kill | Param untyped slots | 866 | 860 | -6 |
| Nil-kill | Return untyped slots | 202 | 199 | -3 |
| Nil-kill | Field/ivar untyped slots | 847 | 809 | -38 |
| Nil-kill | Collection weak slots | 481 | 465 | -16 |
| Nil-kill | Nil-source fixes | 190 | 187 | -3 |
| Nil-kill | Union/T.any candidates | 533 | 531 | -2 |
| Nil-kill | Hash record candidates | 179 | 178 | -1 |
| Nil-kill | Hash record pressure | 278 | 273 | -5 |

Nilable slot movement was mixed because the indexed strong slot population grew:
params `623 -> 638`, returns `656 -> 664`, fields/ivars `207 -> 205`, and
collections `269 -> 264`. The untyped and weak slots still moved down, and the
new nilable count is not from reintroducing loose untyped fact paths.

## Open Design Constraints

- Do not add dual semantic paths. Temporary adapters are allowed only when a
  slice deletes the old producer in the same pass.
- Do not move complexity by centralizing every branch into one giant dispatcher.
  Closed typed records should reduce repeated state decisions; a single
  enormous case statement is not a win.
- Prefer stable IDs and typed records over object identity, strings, raw AST
  shape, or weak hashes.
- Preserve compiler behavior first, then delete guards made impossible by the
  new fact boundary.
