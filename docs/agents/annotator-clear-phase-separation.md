# Annotator Clear Phase Separation Plan

Branch focus: `architectural-review`.

This plan targets the annotator state machine that still lives inside
`SemanticAnnotator`. The conceptual phases already exist in
`src/annotator/README.md`; the architectural gap is that the phases still share
one broad mutable receiver through mixins and instance variables.

The goal is not to invent a Rust clone. The goal is to move toward the same
compiler shape: explicit phase inputs, explicit phase results, and semantic
facts that downstream phases consume mechanically.

## Baseline Snapshot

Initial snapshot files:

- `tmp/annotator-clear-phase/decomplex-before.md`
- `tmp/annotator-clear-phase/slopcop-before.md`
- `tmp/annotator-clear-phase/boobytrap-before.md`
- `tmp/annotator-clear-phase/annotator-ivars-before.txt`

Initial Decomplex counts for `src`:

| Detector | Count |
| --- | ---: |
| Cross-Detector Convergence | 1806 |
| Root-Cause Clusters | 477 |
| Decision Pressure | 287 |
| State Heatmap | 579 |
| State-Based Branch Density | 1619 |
| Temporal Ordering Pressure | 14 |
| Missing Abstractions | 187 |
| Reification Misses | 6 |
| Semantic Predicate Aliases | 5 |
| Exact Predicate Aliases | 15 |
| Inconsistent Rename Clones | 71 |
| Flay Similarity (Type-2/3) | 50 |
| Neglected Updates | 688 |
| Derived-State Staleness | 140 |
| Neglected Conditions | 10 |
| Neglected Path Conditions | 1438 |
| Oversized Predicates | 9 |
| Broken Protocols | 396 |
| False Simplicity | 999 |
| Fat Unions | 11 |

Initial Boobytrap counts:

| Detector | Count |
| --- | ---: |
| Hotspots | 93 |
| Mostly Uncovered Methods | 0 |
| State-Based Branch Hotspots | 1619 |
| Multi-File Fix Blast Radius | 1974 |
| Fixed But Unmeasured | 1881 |

Initial SlopCop counts:

| Metric | Count |
| --- | ---: |
| Dark arms | 2908 |
| Genuine gaps | 1112 |

Initial Nil-Kill counts:

- Target dirs: `src`
- Methods indexed: 4902
- Runtime-observed methods: 997
- Missing sigs: 91
- Existing sigs: 4811
- Existing/candidate `T.let` sites: 1152
- Sorbet errors captured: 0

Initial Nil-Kill project prioritization:

| Bucket | Count |
| --- | ---: |
| Nil Source Fixes | 181 |
| Union / `T.any` Candidates | 507 |
| Hash Record Struct Candidates | 166 |
| Hash Record Pressure Records | 239 |

Initial Nil-Kill type soundness:

| Slot category | Total | Strong | Weak | Untyped | Nilable |
| --- | ---: | ---: | ---: | ---: | ---: |
| Param inputs | 6048 | 5129 | 135 | 784 | 660 |
| Returns | 3461 | 3238 | 33 | 190 | 686 |
| Struct/class fields & ivars | 1621 | 799 | 25 | 797 | 203 |
| Arrays/Sets/Hashmaps | 2051 | 1606 | 445 | 0 | 262 |

The fresh collect used `NIL_KILL_ALLOW_STAGE_FAILURES=1` because the integration
golden harness timed out on one traced fixture after the unit/spec/fuzz/example
stages had produced usable runtime evidence. The final comparison should use the
same collection mode unless that integration timeout is resolved first.

## Problem Statement

`SemanticAnnotator` currently coordinates construction, builtin registration,
declaration indexing, type registration, signature registration, function body
analysis, Auto finalization, whole-program semantic propagation, deferred
validation, and annotation completion. Those are valid phases, but they are
implemented as included modules sharing the same receiver state.

The failure mode is an implicit lifecycle:

- A phase reads fields initialized by construction or another phase without an
  explicit input object.
- A visitor mutates broad state that a later phase consumes by convention.
- A helper uses the receiver as an ambient context instead of accepting the
  facts it needs.
- Tests can validate final behavior while still missing protocol failures at
  phase boundaries.

The implementation target is to replace ambient receiver state with typed
phase-local context and result objects, starting with the state that creates the
largest amount of read/write scatter.

## Target Architecture

The target annotator architecture keeps `SemanticAnnotator` as the public entry
point for now, but makes it a coordinator over typed phase objects.

```text
SemanticAnnotator
  -> AnnotationInput
  -> BuiltinEnvironmentResult
  -> DeclarationIndex
  -> TypeRegistrationResult
  -> SignatureRegistrationResult
  -> BodyAnalysisContext / BodyAnalysisResult
  -> WholeProgramSemanticFacts
  -> DeferredValidationResult
  -> AnnotationResult
```

The first implementation milestone does not need every object above. It should
establish the pattern with the highest-pressure shared state and then repeat it
only where the metric feedback supports the work.

### Rules

- New cross-phase data must be a typed class or `T::Struct`.
- New functions must have precise Sorbet signatures.
- New and changed code must avoid `T.untyped` unless it is at a genuine
  external boundary.
- A phase may hold mutable fields internally while running, but its public
  result must expose stable typed facts.
- Prefer one `@phase_state` field over many receiver fields only when it reduces
  state scatter and protocol pressure. Do not hide arbitrary state inside a
  generic bag.
- The zero-ivar annotator goal is directional: every removed shared receiver
  field is a win, but forcing all state through awkward parameter threading is
  not a win.

## Implementation Buckets

### 1. Function Registry And Body Analysis State

Problem state:

- `@fn_nodes`
- `@synthetic_fns`
- `@body_summaries`
- function-context stack interactions around body analysis

Plan:

1. Introduce a typed `Annotator::FunctionRegistry`.
2. Move function node lookup, synthetic-function tracking, and body-summary
   tracking behind named methods.
3. Update signature registration, body analysis, whole-program semantics, Auto
   finalization, and MIR-facing consumers to use the registry surface.
4. Add focused unit tests proving registration, lookup, synthetic tracking, and
   summary recording.
5. Run focused annotator tests, Sorbet, changed-line coverage audit, and
   Decomplex.

Expected metric movement:

- State heatmap down or flat.
- State-based branch density down or flat.
- Broken protocols down if `@fn_nodes` lifecycle pairs become named registry
  operations.
- Nil-Kill untyped slots flat or down because the registry surface is strongly
  typed.

### 2. Scope And Current-Function Context Boundary

Problem state:

- `@scope_stack`
- `@function_context_stack`
- loop/conditional/smooth depth fields used as ambient context

Plan:

1. Introduce typed scope and function-context stack adapters with block-scoped
   push/pop APIs.
2. Replace open-coded stack mutation with `with_scope` and
   `with_function_context` style operations where those APIs reduce protocol
   pressure.
3. Keep direct visitors readable; do not force every local lookup through a
   verbose abstraction if metrics move sideways.
4. Add tests for stack restoration on normal exits and diagnostics.
5. Run focused tests, coverage audit, Sorbet, and Decomplex.

Expected metric movement:

- Temporal ordering pressure down or flat.
- Broken protocols down from explicit push/pop bracketing.
- SlopCop dark arms should not increase materially because guard surfaces do
  not change.

### 3. Capability, Lock, And Effect Phase State

Problem state:

- `@held_locks`
- `@held_lock_types`
- `@deferred_with_validations`
- `@fn_direct_effects`
- `@call_site_context`
- `@call_site_arg_families`
- `@capability_audit`

Plan:

1. Extract typed state records only where the existing helper already has a
   coherent lifecycle.
2. Convert lifecycle pairs to block APIs or named recorders.
3. Preserve the current semantic checks, but remove ambient mutation from
   unrelated visitor methods.
4. Add negative tests around lock restoration, deferred validation recording,
   and effect propagation.
5. Run focused tests, coverage audit, Sorbet, and Decomplex.

Expected metric movement:

- Broken protocols down.
- State-based branch density down in capability/effect helpers.
- Boobytrap state-based hotspots should improve for annotator helper files.

### 4. Ownership Graph And Flow State

Problem state:

- `@og`
- `@og_scope_depth`
- ownership branch merge state
- capture/move suppression state

Plan:

1. Prefer a narrow typed ownership-analysis context over direct `@og` access.
2. Convert visitor code to ask the context for named operations instead of
   reaching into graph internals.
3. Keep `OwnershipGraph` itself in `src/semantic`; the annotator owns the phase
   context, not the graph model.
4. Add tests around branch merge, move suppression, and scope restoration.
5. Run focused tests, coverage audit, Sorbet, and Decomplex.

Expected metric movement:

- State heatmap down.
- State-based branch density down in `domains/control_flow.rb`,
  `domains/variables.rb`, and `domains/lifetimes.rb`.
- Nil-Kill field/ivar pressure flat or down if direct graph ivars are removed.

## Progress Log

| Step | Status | Notes |
| --- | --- | --- |
| Baseline Decomplex | Done | `src` report captured before implementation. |
| Baseline Boobytrap | Done | Report captured before implementation. |
| Baseline SlopCop | Done | Report captured before implementation. |
| Baseline Nil-Kill | Done | Fresh collect completed with one tolerated integration timeout. |
| Bucket 1 | Done | Introduced typed `Annotator::FunctionRegistry`; removed annotator-owned `@fn_nodes`, `@body_summaries`, and `@synthetic_fns`; direct changed-line audit: 68/68 executable `src` lines and 8/8 changed branch arms covered. Decomplex pulse: convergence -4, decision pressure -1, state heatmap -1, neglected updates -25, broken protocols +1, false simplicity +7. |
| Bucket 2 | Done | Added block-scoped function-context analysis with `ensure` unwinding; cumulative changed-line audit: 81/81 executable `src` lines and 11/12 changed branch arms covered. Decomplex pulse versus baseline stayed mixed: convergence -4, decision pressure -1, state heatmap -1, neglected updates -25, broken protocols +1, false simplicity +9. |
| Bucket 3 | Done | Extracted direct effects, call-site context, and call-site argument-family facts into typed `EffectTracker::EffectState`; final changed-line audit after implementation: 142/142 executable `src` lines and 16/18 changed branch arms covered. Decomplex pulse versus baseline: convergence -4, root-cause clusters -1, decision pressure -3, state heatmap -3, neglected updates -31, broken protocols +2, false simplicity +8. |
| Bucket 4 | Reviewed/deferred | Ownership graph state is still high-value, but direct `@og` access is spread through ownership/lifetime/control-flow domains and tests use graph fakes. A correct extraction should be a dedicated ownership-domain refactor rather than forcing this pass through a weakly typed graph abstraction. |
| Final Nil-Kill | Done | Fresh final collect completed in 1046s with `integration-specs` tolerated by `NIL_KILL_ALLOW_STAGE_FAILURES=1`, matching the baseline mode. Unit specs, Nil-Kill specs, fuzz matrix, transpile corpus, examples, module integration, FFI integration, and example tests completed; integration specs had two tolerated failures, including a MiniVM timeout. |

## Final Result

Implemented:

- Added a typed `Annotator::FunctionRegistry` and moved function node lookup,
  synthetic function tracking, body summaries, call graph queries, propagation
  queries, and direct raise/fnptr checks behind that registry.
- Removed annotator-owned `@fn_nodes`, `@body_summaries`, and `@synthetic_fns`
  state. Remaining `@fn_nodes` references are constructor-injected state inside
  `AutoConstraintCollector`/related Auto helpers or comments.
- Replaced the function-context helper with explicit `begin`/`ensure`
  restoration in `visit_FunctionDef`, so function-context unwind is visible at
  the lifecycle boundary.
- Added typed `EffectTracker::EffectState` for direct effects, call-site
  context, and call-site argument-family facts, replacing three independent
  effect ivars with one typed phase-state object and named accessors.
- Updated consumers in body analysis, signature registration, union synthesis,
  execution-boundary analysis, reentrance analysis, lifetimes, capabilities,
  pipe analysis, function analysis, and tests.

Deferred:

- Ownership graph extraction remains open. It is a real architectural target,
  but the current direct `@og` use is spread through ownership-heavy domains and
  tests use graph fakes. A useful extraction should be a dedicated ownership
  domain refactor with a typed graph facade, not a thin bag around the existing
  graph.

Annotator ivar pressure moved in the right direction for this pass:

| Metric | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Unique `@...` tokens in `src/annotator` | 142 | 139 | -3 |
| Total `@...` references in `src/annotator` | 961 | 830 | -131 |

This count includes annotation-like tokens in comments and language examples,
so it is a pressure indicator rather than a pure Ruby instance-variable count.
The targeted production receiver state was removed.

### Final Decomplex Diff

Report files:

- `tmp/annotator-clear-phase/decomplex-before.md`
- `tmp/annotator-clear-phase/decomplex-final.md`

| Detector | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Cross-Detector Convergence | 1806 | 1802 | -4 |
| Root-Cause Clusters | 477 | 476 | -1 |
| Decision Pressure | 287 | 284 | -3 |
| State Heatmap | 579 | 576 | -3 |
| State-Based Branch Density | 1619 | 1619 | 0 |
| Temporal Ordering Pressure | 14 | 14 | 0 |
| Missing Abstractions | 187 | 187 | 0 |
| Reification Misses | 6 | 6 | 0 |
| Semantic Predicate Aliases | 5 | 5 | 0 |
| Exact Predicate Aliases | 15 | 15 | 0 |
| Inconsistent Rename Clones | 71 | 71 | 0 |
| Flay Similarity (Type-2/3) | 50 | 50 | 0 |
| Neglected Updates | 688 | 657 | -31 |
| Derived-State Staleness | 140 | 140 | 0 |
| Neglected Conditions | 10 | 10 | 0 |
| Neglected Path Conditions | 1438 | 1444 | +6 |
| Oversized Predicates | 9 | 9 | 0 |
| Broken Protocols | 396 | 398 | +2 |
| False Simplicity | 999 | 1007 | +8 |
| Fat Unions | 11 | 11 | 0 |

Assessment: the result is a net Decomplex win on convergence, root-cause
clusters, decision pressure, state heatmap, and especially neglected updates.
The remaining negative movement is modest and localized to the cost of adding
typed facade/accessor surface: neglected path conditions +6, broken protocols
+2, and false simplicity +8. Bucket 4 was deferred because forcing ownership
state into a facade in this pass looked more likely to worsen those signals
than to produce a real design improvement.

### Final SlopCop Diff

Report files:

- `tmp/annotator-clear-phase/slopcop-before.md`
- `tmp/annotator-clear-phase/slopcop-final-global.md`

Both reports use the default `coverage/.resultset.json` baseline coverage file.
The focused changed-code coverage report is also saved at
`tmp/annotator-clear-phase/slopcop-final.md`, but it is not used for this
project-wide before/after comparison.

| Metric | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Files | 122 | 122 | 0 |
| Dark arms | 2908 | 2844 | -64 |
| Genuine gaps | 1112 | 1080 | -32 |

### Final Boobytrap Diff

Report files:

- `tmp/annotator-clear-phase/boobytrap-before.md`
- `tmp/annotator-clear-phase/boobytrap-final-global.md`

Both reports use the default `coverage/.resultset.json` baseline coverage file
and `--only=src/`.

| Detector | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Hotspots | 93 | 93 | 0 |
| Mostly Uncovered Methods | 0 | 0 | 0 |
| State-Based Branch Hotspots | 1619 | 1619 | 0 |
| Multi-File Fix Blast Radius | 1974 | 98 | -1876 |
| Fixed But Unmeasured | 1881 | 5 | -1876 |

### Final Nil-Kill Diff

Report files:

- `tmp/annotator-clear-phase/nil-kill-before.md`
- `tmp/annotator-clear-phase/nil-kill-final.md`

| Metric | Before | After | Delta |
| --- | ---: | ---: | ---: |
| Methods indexed | 4902 | 4927 | +25 |
| Runtime-observed methods | 997 | 998 | +1 |
| Missing sigs | 91 | 91 | 0 |
| Existing sigs | 4811 | 4836 | +25 |
| Existing/candidate `T.let` sites | 1152 | 1112 | -40 |
| Sorbet errors captured | 0 | 0 | 0 |
| Nil Source Fixes | 181 | 181 | 0 |
| Union / `T.any` Candidates | 507 | 507 | 0 |
| Hash Record Struct Candidates | 166 | 166 | 0 |
| Hash Record Pressure Records | 239 | 240 | +1 |

| Slot category | Metric | Before | After | Delta |
| --- | --- | ---: | ---: | ---: |
| Param inputs | total | 6048 | 6065 | +17 |
| Param inputs | strong | 5129 | 5146 | +17 |
| Param inputs | weak | 135 | 135 | 0 |
| Param inputs | untyped | 784 | 784 | 0 |
| Param inputs | nilable | 660 | 662 | +2 |
| Returns | total | 3461 | 3478 | +17 |
| Returns | strong | 3238 | 3255 | +17 |
| Returns | weak | 33 | 33 | 0 |
| Returns | untyped | 190 | 190 | 0 |
| Returns | nilable | 686 | 689 | +3 |
| Struct/class fields & ivars | total | 1621 | 1608 | -13 |
| Struct/class fields & ivars | strong | 799 | 801 | +2 |
| Struct/class fields & ivars | weak | 25 | 25 | 0 |
| Struct/class fields & ivars | untyped | 797 | 782 | -15 |
| Struct/class fields & ivars | nilable | 203 | 204 | +1 |
| Arrays/Sets/Hashmaps | total | 2051 | 2029 | -22 |
| Arrays/Sets/Hashmaps | strong | 1606 | 1586 | -20 |
| Arrays/Sets/Hashmaps | weak | 445 | 443 | -2 |
| Arrays/Sets/Hashmaps | untyped | 0 | 0 | 0 |
| Arrays/Sets/Hashmaps | nilable | 262 | 238 | -24 |

Assessment: new method slots are strongly typed; param and return untyped slots
stayed flat, field/ivar untyped slots dropped by 15, and `T.let` pressure
dropped by 40. Nilable counts rose slightly in param/return/field categories
because the added typed surfaces include existing optional contracts; collection
nilability dropped materially.

## Verification

- `bundle exec srb tc`
- `bundle exec rspec spec/annotator_function_registry_spec.rb`
- `bundle exec rspec spec/annotator_gap_burndown_spec.rb spec/stack_tier_spec.rb`
- `bundle exec rspec spec/annotator_gap_burndown_spec.rb:3671 spec/annotator_gap_burndown_spec.rb:924 spec/annotator_gap_burndown_spec.rb:1899 spec/annotator_gap_burndown_spec.rb:3232`
- `bundle exec rspec spec/annotator_gap_burndown_spec.rb:924 spec/annotator_gap_burndown_spec.rb:3664`
- `COVERAGE=1 COVERAGE_DIR=tmp/annotator-clear-phase/coverage-final bundle exec rspec spec/annotator_function_registry_spec.rb spec/stack_tier_spec.rb spec/annotator_phase_completion_spec.rb spec/annotator_signature_registration_spec.rb spec/boobytrap_method_coverage_spec.rb spec/annotator_gap_burndown_spec.rb spec/gradual_typing_spec.rb`
- Changed executable `src` line audit from
  `tmp/annotator-clear-phase/coverage-final/.resultset.json`: 142/142
  covered, 36 non-code changed lines.
- Changed branch-arm audit from the same resultset: 16/18 covered, 88.89%.
- `NIL_KILL_ALLOW_STAGE_FAILURES=1 bundle exec tools/nil-kill collect -- bash tools/clear-nil-kill-runtime.sh`
- `bundle exec tools/nil-kill infer`
- `bundle exec tools/nil-kill report --output-path tmp/annotator-clear-phase/nil-kill-final.md`

## Completion Criteria

- Decomplex is regenerated after every bucket and compared to the previous
  checkpoint.
- Final Decomplex, SlopCop, Boobytrap, and Nil-Kill reports are regenerated and
  compared to this baseline.
- Changed and added source lines have 100% coverage.
- Changed and added branches have at least 80% coverage.
- Sorbet passes for typed files.
- New and changed functions are strongly typed.
- The final doc update records what was completed, what was deferred, and why.
