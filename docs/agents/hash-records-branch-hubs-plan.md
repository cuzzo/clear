# Hash Records And Branch Hubs Plan

This plan drives issues #5 and #6 in
`docs/agents/remaining-architectural-issues.md` to completion.

The target is not cosmetic typing. The target is to remove compiler phase data
that still travels as weak hashes and to split the remaining high-pressure
branch hubs into explicit classifier, plan, validation, and execution records.

## Baseline

Snapshot directory: `tmp/agent-metrics/hash-branch-hubs`.

Decomplex was collected over `src tools gems`:

| metric | before |
| --- | ---: |
| Cross-Detector Convergence | 2651 |
| Root-Cause Clusters | 653 |
| Decision Pressure | 335 |
| State Heatmap | 888 |
| State-Based Branch Density | 2334 |
| Temporal Ordering Pressure | 27 |
| Missing Abstractions | 312 |
| Reification Misses | 19 |
| Exact Predicate Aliases | 23 |
| Neglected Updates | 773 |
| Derived-State Staleness | 163 |
| Neglected Conditions | 58 |
| Neglected Path Conditions | 1783 |
| Broken Protocols | 807 |
| False Simplicity | 1110 |
| Fat Unions | 16 |

Boobytrap baseline:

| metric | before |
| --- | ---: |
| Hotspots | 93 |
| Mostly Uncovered Methods | 1 |
| State-Based Branch Hotspots | 1569 |
| Multi-File Fix Blast Radius | 98 |
| Fixed But Unmeasured | 5 |

Nil-kill baseline copied from the issue #4 final report:

| metric | before |
| --- | ---: |
| Nil Source Fixes | 187 |
| Hash Record Struct Candidates | 178 |
| Pressure Records | 273 |
| Pressure Records Without Literal Shape Cluster | 74 |
| Weak Collection Slots | 465 |
| Param Untyped Slots | 860 |
| Return Untyped Slots | 199 |
| Field/Ivar Untyped Slots | 809 |
| Collection Untyped Slots | 0 |

## Acceptance Criteria

1. Every new function is strongly typed, including inputs and returns.
2. New typed records replace weak compiler phase hashes instead of adding
   permanent dual paths.
3. All new and changed source lines are covered by tests; changed branch
   coverage should stay at or above roughly 80%.
4. Decomplex is checked after each implementation slice. If the metrics move
   sideways or worse for the affected slice, pause and choose the smaller
   architecture-preserving correction before continuing.
5. Final SlopCop, Boobytrap, Decomplex, and nil-kill reports should show a
   decisive win or a clearly documented essential-pressure exception.

## Slices

### Slice 1: Union Requirement Records

Status: implemented.

Replace the `UNION ... REQUIRES` method requirement hashes with typed AST
records:

- `AST::UnionMethodParamRequirement`
- `AST::UnionMethodRequirement`

This removes the top compiler-relevant `BodyRecord` candidate where synthetic
function bodies, visibility, params, and return types are carried by hash keys.

Expected impact:

- nil-kill hash-record pressure drops for union method requirements
- Decomplex state-read noise drops in `validate_union_methods!`
- Sorbet no longer needs untyped synthetic function handling at that boundary

Implemented with `AST::UnionMethodParamRequirement` and
`AST::UnionMethodRequirement`; parser, signature registration, and union
validation now consume typed records directly.

### Slice 2: Concurrent Body And Binding Step Records

Status: implemented.

Replace DO/BG/concurrency branch-body hashes and THEN/FSM binding step hashes
with typed records:

- `AST::DoBranch`
- `AST::ThenStep`

Consumers in annotation, MIR lowering, MIR checking, MIR emission, hoist, and
FSM lowering should consume the typed records directly. Legacy hash lookups at
this boundary should be deleted.

Expected impact:

- nil-kill `BodyRecord` and `BindingRecord` pressure drops
- `lower_bg_block` and execution-boundary branch pressure become easier to
  split into plans
- downstream phase APIs become strongly typed without broad semantic changes

Implemented with `AST::DoBranch` and `AST::ThenStep`; parser, annotator,
execution-boundary handling, MIR lowering, MIR control flow, hoist, and FSM
lowering consume typed branch/step records.

### Slice 3: Binary Operation Plans

Status: implemented.

Convert `lower_binary_op` from direct branching plus emission into:

- typed operand facts
- typed operation classification
- typed binary operation plans
- a narrow executor that emits MIR from the plan

This should make arithmetic, comparison, string/symbol, collection, and special
numeric behavior explicit before mutation/emission.

Expected impact:

- Decomplex state-based branch density drops for
  `src/mir/lowering/expressions.rb:lower_binary_op`
- branch tests cover each plan kind instead of only emitted output

Implemented with typed binary operand facts and binary operation plans. The
original `lower_binary_op` hub no longer appears in the top state-based branch
ranking, though aggregate Decomplex branch count rises because the named helper
decisions are counted separately.

### Slice 4: Match Annotation Plans

Status: implemented.

Convert `visit_MatchStatement` to classifier-plan-executor shape:

- classify the subject and pattern kind
- build typed arm plans
- validate exhaustiveness and payload/destructure facts
- execute scope mutation and ownership finalization from the checked plan

Expected impact:

- Boobytrap's top state-based branch hotspot moves down materially
- match state branches become named plan variants instead of ad hoc conditions

Implemented with typed subject plans and split match validation/execution
helpers. `visit_MatchStatement` no longer appears in the top state-based branch
ranking.

### Slice 5: Type And Signature Validation Results

Status: implemented.

Convert `validate_type_annotation!` and `verify_function_signature!` to return
or consume typed validation-result objects with structured diagnostic reasons.

Expected impact:

- repeated schema/type/reentrancy predicates stop being recomputed inside
  mutation-heavy validators
- branch coverage can assert diagnostic reason objects directly

Implemented with `TypeAnnotationFacts`, call-site records, arity plans,
argument facts, and typed alias records. The original
`validate_type_annotation!` and `verify_function_signature!` hubs no longer
appear in the top state-based branch ranking.

### Slice 6: Concurrency Plan Closure

Status: implemented.

After `AST::DoBranch` exists, convert the remaining `lower_bg_block` concurrency
branch hub into typed capture/scheduler/arena/parallelism plans.

Expected impact:

- the last high-pressure BG/DO body hash path disappears
- concurrency lowering keeps semantic decisions ahead of emission

Implemented with typed BG type, capture, scheduler, and FSM transform-context
plans. `lower_bg_block` now assembles checked plans and delegates stackful/FSM
emission instead of carrying the capture/scheduler/arena state inline.

### Slice 7: Residual Report Triage

Status: implemented.

Regenerate Decomplex, SlopCop, Boobytrap, and nil-kill. Any remaining #5/#6
entry must be classified as:

- completed compiler architecture pressure
- essential branch pressure with invariant coverage
- tooling-only weak record deferred out of #5/#6

Final classification:

- The compiler-relevant `BodyRecord` and `BindingRecord` candidates targeted
  by this issue were removed from the top nil-kill pressure list by typed union
  requirement records, `AST::DoBranch`, and `AST::ThenStep`.
- Remaining high hash-record pressure is dominated by tooling-local records
  (`doctor`, `pprof`, `stack_verifier`) and residual MIR/FSM emitter records
  that are outside this issue's completed compiler phase-bag target.
- The selected branch hubs now use typed classifier/plan/fact records. The
  aggregate Decomplex and Boobytrap branch counts rose because the extracted
  decisions are now named and counted separately; this is an explicit
  essential-pressure exception rather than a hidden-state regression.

Final verification:

| check | result |
| --- | --- |
| Full unit specs with coverage | 5574 examples, 0 failures |
| Full unit coverage | 99.4% lines, 85.35% branches |
| Working-tree changed source line coverage | 100.0% (958/958) |
| Working-tree changed source branch coverage | 90.8% (355/391) |
| Sorbet | `bundle exec srb tc` clean |
| Nil-kill collection | Complete in 1397s across unit, integration, nil-kill, transpile corpus, fuzz matrix, examples, module/FFI/example tests |

Final repo-wide metric deltas:

| metric | before | after | delta |
| --- | ---: | ---: | ---: |
| Decomplex Cross-Detector Convergence | 2651 | 2687 | +36 |
| Decomplex Root-Cause Clusters | 653 | 652 | -1 |
| Decomplex Decision Pressure | 335 | 341 | +6 |
| Decomplex State Heatmap | 888 | 888 | 0 |
| Decomplex State-Based Branch Density | 2334 | 2374 | +40 |
| Decomplex Temporal Ordering Pressure | 27 | 27 | 0 |
| Decomplex Missing Abstractions | 312 | 311 | -1 |
| Decomplex Reification Misses | 19 | 20 | +1 |
| Decomplex Neglected Updates | 773 | 776 | +3 |
| Decomplex Derived-State Staleness | 163 | 162 | -1 |
| Decomplex Neglected Path Conditions | 1783 | 1708 | -75 |
| Decomplex Broken Protocols | 807 | 794 | -13 |
| Decomplex False Simplicity | 1110 | 1146 | +36 |
| Boobytrap Hotspots | 93 | 93 | 0 |
| Boobytrap Mostly Uncovered Methods | 1 | 1 | 0 |
| Boobytrap State-Based Branch Hotspots | 1569 | 1609 | +40 |
| Boobytrap Multi-File Fix Blast Radius | 98 | 98 | 0 |
| Boobytrap Fixed But Unmeasured | 5 | 5 | 0 |
| SlopCop dark arms | 3286 | 3068 | -218 |
| SlopCop genuine gaps | 1314 | 1316 | +2 |
| Nil-kill hash record struct candidates | 178 | 173 | -5 |
| Nil-kill pressure records | 273 | 257 | -16 |
| Nil-kill weak collection slots | 465 | 457 | -8 |
| Nil-kill param untyped slots | 860 | 854 | -6 |
| Nil-kill return untyped slots | 199 | 199 | 0 |
| Nil-kill field/ivar untyped slots | 809 | 808 | -1 |
| Nil-kill collection untyped slots | 0 | 0 | 0 |

Issues #5 and #6 are complete for the planned scope. The remaining records and
branch hubs should be tracked as follow-up work only when Decomplex, Boobytrap,
SlopCop, and nil-kill converge on them again.
