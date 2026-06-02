# Annotator Phase State Handoffs

## Updated Grade

```text
Architecture Design:  A-  (was B+)
Implementation Quality: A-  (was B+)
```

The annotator is no longer an anchor. The architecture is now: 8 phases with
typed handoffs, 7 visitor domains, 11 focused helpers, and a thin 1,186-line
orchestrator. This is Go/Zig-tier internal architecture.

What keeps it from A:

- The phases are include modules, not explicit phase objects with
  context -> result signatures. The plan called for typed phase contexts; the
  implementation uses module mixins that still read from `SemanticAnnotator`
  ivars. That is the next structural step, but it is optimization, not
  necessity.
- The include chain means the annotator is still one object with shared mutable
  state. It is organized, not isolated. Fully isolated phases would be A-tier.

Practical verdict: v0.1 ready on architecture. The 82% line reduction and 91%
visitor extraction means contributors can find things. A new developer sees
"function body analysis happens in `phases/body_analysis.rb`, IF/MATCH in
`domains/control_flow.rb`" rather than "everything is in one 6,500-line file."
That is the bar for v0.1.

## Current State

The refactor split behavior by compilation phase and visitor domain, but the
handoff mechanism is still the `SemanticAnnotator` instance. Phase modules read
and write shared state such as `@fn_nodes`, `@current_fn_ctx`, `@og`,
`@program_node`, `@branch_terminated`, lock state, sync policy state, and
capability audit state.

That is acceptable for v0.1 because the ownership of behavior is now legible.
It is not A-tier because state flow is implicit: a phase can accidentally depend
on any ivar the orchestrator has.

## Target Shape

The next architecture should make each phase a small object or callable module
with an explicit context and result:

- `DeclarationIndexContext -> DeclarationIndexResult`
- `SignatureRegistrationContext -> SignatureRegistryResult`
- `BodySummaryContext -> BodySummaryResult`
- `FunctionBodyContext -> FunctionBodyResult`
- `WholeProgramContext -> WholeProgramResult`
- `DeferredValidationContext -> DeferredValidationResult`
- `FinalizationContext -> FinalizationResult`

The visitor domains can remain modules initially, but they should receive a
phase-local context instead of reaching through the full annotator object. The
important rule is no dual path: once a phase owns a state bucket, direct writes
to the old annotator ivar for that bucket are deleted in the same commit.

## State Buckets

These buckets should be isolated first:

- Function registry state: `@fn_nodes`, `@synthetic_fns`, signature tables, and
  generated helper functions.
- Current function state: `@current_fn_ctx`, return facts, heap count, current
  function node/name, and reentrance metadata.
- Scope and ownership state: `current_scope`, `@og`, scope depth, deferred
  drops, and branch merge snapshots.
- Diagnostic state: source code, fixable collector, warning policy, and
  diagnostic registry context.
- Capability/effect state: capability audit, lock rank graph, held locks,
  sync policy handlers, and effect propagation tables.
- Execution-boundary state: BG pinning, stream yield types, WITH depth, and
  cross-scheduler capture facts.

## Migration Order

1. **Return facts and deferred drops.** These are currently hash-shaped records
   crossing phase boundaries. Reifying them gives immediate guardrail and
   state-flow wins.
2. **Function body context.** Move `current_fn_ctx`, branch termination, and
   scope finalization into a typed body-analysis context/result pair.
3. **Capability/effect context.** This has the highest reliability value, but
   it is more load-bearing. Do it after body state is explicit.
4. **Program-level validation context.** Move sync policy, deferred validation,
   lock graph, and reentrance checks into a whole-program validation result.
5. **Thin orchestrator cleanup.** After the above, `SemanticAnnotator` should
   sequence phase objects and expose only compatibility-free visitor dispatch.

## State Cleanup Progress

- [x] Return facts: reified into typed function-body summaries.
- [x] Deferred drops: reified into typed deferred-drop records.
- [x] Deferred WITH validations: reified as `DeferredWithValidation` and flushed
  from the deferred-validation phase.
- [x] Branch analysis results: branch snapshots, drops, and termination are
  carried as `BranchAnalysisResult` rather than parallel arrays.
- [x] Capability audit records: the old hash payload was replaced with
  `CapabilityAudit::BindingAuditRecord`; mutation/capture updates now go
  through named audit operations.
- [x] Lock validation records: lock edges, held-call sites, clause sites, and
  graph results are typed records instead of ad hoc hashes.
- [x] Current function stack: `@function_context_stack` is typed as
  `T::Array[FunctionContext]`, direct stack mutation is behind
  `push_function_context!` / `pop_function_context!`, and readers that require a
  function body use `current_fn_ctx!`.

### Latest Measurement

Round baseline: `tmp/agent-metrics/decomplex-before-state-finish.md`.
Round final: `tmp/agent-metrics/decomplex-after-state-finish.md`.

```text
Cross-Detector Convergence: 398 -> 400 (+2)
Root-Cause Clusters:        114 -> 114 (0)
Decision Pressure:          117 -> 116 (-1)
Missing Abstractions:        38 -> 37  (-1)
Neglected Updates:          235 -> 235 (0)
Derived-State Staleness:     11 -> 12  (+1)
Neglected Path Conditions:  487 -> 487 (0)
Broken Protocols:           711 -> 715 (+4)
False Simplicity:           404 -> 410 (+6)
```

Assessment: architecturally worthwhile but not a decisive decomplex win. The
cleanup deleted real untyped/hash handoff state and made the current-function
stack strongly typed. Decomplex penalized the added typed record/context
operations as extra protocol and false-simplicity surface. The next improvement
should not add more record wrappers unless it also deletes a larger branch hub.

## Acceptance Criteria

- No new `T.untyped` in `src/`.
- No hash-record handoffs for newly migrated phase state.
- All writers for a migrated state bucket go through the new context/result.
- Old ivar writes for that state bucket are deleted in the same commit.
- `bundle exec srb tc` passes.
- `bundle exec prspec` target groups pass, and full GitHub-equivalent suites are
  run before merge.
- Diff coverage for added `src/` lines remains 100%; branch coverage should stay
  near or above 80% where practical.
- Decomplex and SlopCop must move in the correct direction or the migration is
  treated as incomplete or reverted.

## Expected Benefit

The A-tier payoff is not another file split. It is explicit state transfer:
reviewers can see exactly what a phase consumes, what it produces, and which
later phase depends on that result. That should reduce accidental branch
coupling, make coverage targets more meaningful, and make future compiler
changes safer because phase state cannot be mutated from unrelated visitor code.
