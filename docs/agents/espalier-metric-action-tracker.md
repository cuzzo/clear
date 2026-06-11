# Espalier Metric Action Tracker

This tracker records the five Espalier metrics added on the `manual-review`
branch and the cleanup status for each. Espalier findings are review candidates:
each metric gets an explicit action pass, and individual findings are either
fixed, deferred because the required refactor is intentionally larger, or used
to tune the metric.

Baseline report: `gems/espalier/report.md` after commit
`afaf4d32b Add Espalier owner cohesion metrics`.

## Workstreams

| Metric | Baseline count | Status | Action standard |
|---|---:|---|---|
| Privatization Candidates | 1065 raw candidates, top 20 shown | Acted, not exhausted | Make methods private when the method is a same-owner helper and no external API contract is evident. Tune if the metric reports framework/API surface as privateable. |
| Encapsulation Pressure | 50 | Acted via overlap | Act where a public surface can be narrowed cheaply, especially when it overlaps privacy/cohesion evidence. Defer broad data-model or compiler IR API redesign. |
| Owner State Cohesion | 8 | Acted and tuned | Act on small/local state splits or record a larger refactor plan when the finding points at a known architectural owner. Tune if simple feature flags or accessors dominate. |
| Collaboration Meshes | 55 | Tuned | Act only where a missing mediator/context can be introduced locally. Defer broad compiler phase reshaping unless it overlaps an active cleanup. |
| Mediator/Reification Candidates | 10 | Acted via small extraction and tuning | Prefer small role/context objects over moving large subsystems. Defer when the candidate would require a cross-phase architecture change. |

## Pass Log

### Privatization Candidates

Action:

- Made 19 top-ranked annotator/helper methods private where calls are same-owner
  helper calls and tests already use `send` or singleton stubs when they need
  direct access:
  `with_loop_context`, match-pattern helpers, return compatibility helper,
  WITH runtime/atomic helpers, BG lifetime walkers, declaration finalization,
  capability fact/capture helpers, and async stack-tier assignment.

Outcome:

- Raw candidates: `1065 -> 1044` after regeneration.
- Useful-action rate for the reviewed top-20 baseline rows: `19/20` useful.
  The remaining top item, `MIRLowering#emit_expr`, is probably actionable but
  outside the annotator-focused low-risk pass and should be handled with the MIR
  lowering visibility surface.

Signal/noise:

- Strong signal for same-owner helpers.
- Needs batching: the raw count is intentionally broad and should be consumed
  by owner/module, not as one giant todo list.

### Owner State Cohesion

Action:

- Extracted `PassWorkProfiler::RecordStore`, `StageStack`, and
  `WorkFrameStack` to move independent profiler state concerns behind typed
  owners.
- Extracted `PipelineLabelState` from `PipelineHost` to own pipeline label
  sequence/current-label state.
- Tuned the metric to suppress tiny helper-object facades after state has been
  extracted.

Outcome:

- Reported rows: `8 -> 7`.
- `PassWorkProfiler::Profiler` dropped from the report after the refactor and
  tuning.
- `PipelineHost` improved but remains the top finding:
  score `163.10 -> 161.41`, state `19 -> 18`, stateful methods `72 -> 69`,
  isolated components `5 -> 4`.

Signal/noise:

- High value for large owners: `PipelineHost`, `AST::Locatable`,
  `OwnershipGraph`.
- The profiler result showed the metric needed the helper-object suppression
  rule; with that rule, current signal is cleaner.

### Encapsulation Pressure

Action:

- The privatization pass narrowed public API surface on `SemanticAnnotator` and
  annotator helper modules.
- `PipelineLabelState` removed one direct mutable state slot from
  `PipelineHost`.

Outcome:

- `SemanticAnnotator`: public/private `38/30 -> 37/31`, public state methods
  `30 -> 29`, score `182.29 -> 177.42`.
- `PipelineHost`: state `19 -> 18`, private methods `82 -> 83`, fan-out
  increased by one before collaboration graph tuning because the new state owner
  was visible to the graph; score still improved `151.79 -> 142.49`.
- Total rows: `50 -> 51`. The extra row is not enough to justify unrelated
  cleanup; the meaningful overlapping owners improved.

Signal/noise:

- Useful as a prioritizer, not a direct refactor queue. Top rows such as `MIR`,
  `Type`, and `MIRLowering` imply broad API design work and should be handled as
  separate architecture tasks, not opportunistic cleanup.

### Collaboration Meshes

Action:

- Tuned owner-edge construction to ignore small record/value-object targets
  (`*Fact`, `*Record`, `*Result`, `*Shape`, `*Site`, `*Spec`, `*State`, etc.)
  when they have no delegation behavior and tiny state/method surfaces.
- Added a regression test so helper/value objects do not create synthetic
  collaboration hubs.

Outcome:

- Rows: `55 -> 51`.
- `MIRLowering` hub score `390.66 -> 347.24`.
- `PipelineHost` hub score `238.45 -> 206.62`, owners `28 -> 23`, edge count
  `27 -> 22`.

Signal/noise:

- Good macro signal once value objects are suppressed.
- Still too broad for direct cleanup. It should drive architecture planning and
  overlap checks with cohesion/encapsulation, not local edits by itself.

### Mediator/Reification Candidates

Action:

- Extracted the small `PipelineLabelState` role object from `PipelineHost`.
- Reused the collaboration graph value-object suppression so mediator candidates
  do not count the new helper as more architecture pressure.

Outcome:

- Rows: `10 -> 9`.
- `PipelineHost` mediator candidate score `144.15 -> 126.64`, owners `28 -> 23`,
  edge count `27 -> 22`.
- `FsmTransform::Emit` and `CapabilityHelper` remain strong candidates, but the
  required changes are larger than a safe local pass.

Signal/noise:

- High value when paired with a concrete overlap (`PipelineHost` also has owner
  cohesion and encapsulation pressure).
- Too subjective to auto-fix. It should produce design tasks for known owners
  rather than automatic extractions.
