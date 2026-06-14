# Separation of Concerns Metrics

## Goal

Add two Decomplex detectors that rank functions whose local body looks
like multiple independent concerns trapped in one scope:

- **Function LCOM**: independent local data-flow components inside one
  method.
- **Operational Discontinuity**: structural step boundaries where the
  active local variable set resets.

Both detectors are heuristics. They do not prove bad design. They point
reviewers at functions where a cohesive name may be hiding multiple
pipelines or phases.

## Home

The implementation belongs in `gems/decomplex`, not Espalier.

Decomplex owns function-local complexity heuristics: AST shape, local
data flow, statement boundaries, variable lifetimes, and report
ranking. Espalier can later consume these findings as architecture
annotations, but it should not own the extraction or scoring.

## Shared Support

Create `Decomplex::LocalFlow` as the common support layer for these
metrics. It should expose conservative method summaries built from the
stdlib Ruby AST:

- owner, method name, file, line, span
- ordered top-level method statements
- local assignments and reads per statement
- local def-use dependency edges
- local variable live ranges
- structural boundaries caused by blank lines or comment-only lines

This support layer intentionally stays intra-procedural. It should not
use whole-program points-to, dynamic dispatch, or CFG construction.

## Function LCOM

Classic LCOM asks whether class methods share fields. Function LCOM
downscales that idea:

1. Collect method-local variables.
2. Add an undirected edge between the assigned local and every local read
   by that assignment.
3. Add an undirected edge between locals co-used in the same side-effect,
   branch predicate, return, yield, or call argument.
4. Count connected components among locals that participate in at least
   one assignment/read.

A method is a candidate when it has multiple substantial components.
This means the body contains independent local pipelines that do not
interact before they are consumed.

### Guardrails

- Ignore tiny methods: require a minimum local count and statement count.
- Ignore components of size 1 unless they carry enough statement weight.
- Do not treat `case` arms as separate concerns merely because they are
  alternatives.
- Include side-effect/call argument co-use edges so a method that
  ultimately combines variables in `persist(user, invoice, log)` is not
  misread as three unrelated pipelines.

## Operational Discontinuity

This detector looks for implicit sub-function boundaries:

1. A structural boundary exists between two top-level statements when
   there is a blank line or comment-only line between them.
2. At that boundary, previously active locals are dead after the
   boundary.
3. New locals are introduced after the boundary.

The strongest candidate is a method with repeated boundary resets:
validation phase, calculation phase, persistence/logging phase, all in
one method.

### Guardrails

- Require both a structural boundary and a lifecycle reset.
- Require locals on both sides of the reset.
- Ignore boundaries inside nested lambdas/classes/methods.
- Rank by reset strength, new locals, and repeated phase count.
- Publish a tier-2 high-confidence subtype when a finding has repeated
  resets, explicit phase/step/numbered comments, or a high score.
- Keep `parse_*` grammar alternatives review-only unless they carry an
  explicit phase marker.

## Report Placement

Start Function LCOM as tier 3. Operational Discontinuity is split:
high-confidence findings are tier 2, while the remaining broad
review-only findings stay tier 3.

Suggested section descriptions:

- `Function LCOM`: independent local data-flow components inside one
  method -- possible mixed concerns.
- `Operational Discontinuity (High Confidence)`: strong blank/comment
  phase boundary where local variable lifetimes reset -- likely implicit
  sub-function boundary.
- `Operational Discontinuity`: blank/comment phase boundary where local
  variable lifetimes reset -- possible implicit sub-function boundary.

## Evaluation

After implementation, regenerate a Decomplex report and inspect the top
findings:

- Are top Function LCOM findings actually multi-pipeline methods?
- Are top Operational Discontinuity findings real phase splits?
- Are there noisy false positives caused by test setup, simple parsing,
  or builder-style code?

If the first report is noisy, tune thresholds rather than adding
unrelated refactors.

## Initial Evaluation

The first run over `src/annotator` and `src/ast` produced 34 Function
LCOM findings. The top false-positive pattern was one-line copy/builder
lanes: many independent field assignments later joined into a value
object. Requiring each component to span at least two locals and at
least two statements reduced that to 8.

A second pass showed the weak tail still contained small cohesive
helpers and parser option parsers. Raising Function LCOM's default score
threshold from 30 to 40 reduced the section from 8 to 4 findings while
keeping the stronger multi-phase candidates.

Operational Discontinuity produced 18 findings. Splitting out the
high-confidence subtype produced 6 tier-2 findings and 12 review-only
tier-3 findings on `src/annotator` and `src/ast`. The parser grammar
guard moved `parse_bg_body_stmt` back to review-only while preserving the
strong annotator/type phase findings.

## Current Finding Review

### Function LCOM

| Finding | Value | Disposition |
| --- | --- | --- |
| `src/annotator/helpers/function_analysis.rb:89` `analyze_routine` | High | Real split between routine analysis and return-context capture/restore. Worth addressing when touching function analysis; candidate extraction is an explicit return-capture frame/helper. |
| `src/ast/parser.rb:2370` `parse_raise_stmt` | Low/medium | Mostly grammar alternatives for legacy string raise vs typed raise. Keep as tier-3 review signal; not enough value to force a parser refactor. |
| `src/ast/parser.rb:1988` `parse_if_chain` | Medium | Real parser breadth: condition, shorthand arrow, bind forms, parens, else chain. Useful review signal, but parser grammar alternatives should not be tier-2 by themselves. |
| `src/annotator/helpers/capabilities.rb:457` `predicate_impurity_reason` | Medium | Two lookup sources are mixed: call/stdlib metadata and user function effects. Extraction could clarify the contract, but current size is not urgent. |

Findings removed by the score threshold increase from 30 to 40:

| Removed finding | Reason |
| --- | --- |
| `src/ast/parser.rb:1251` `source_slice_between` | Cohesive source-slice helper; low-value false positive. |
| `src/ast/parser.rb:2923` `parse_concurrent_op` | Small option parser plus inner parse; acceptable parser shape. |
| `src/annotator/helpers/function_analysis.rb:840` `atomic_cell_to_atomic_param?` | Small guard/helper split; not a separation-of-concerns problem. |
| `src/ast/type.rb:3234` `self.strip_capability_suffix_from` | Cohesive suffix parser. Mild review value, but acceptable to drop from the default report. |

Function LCOM should remain tier 3. The threshold tuning now skips most
obvious false positives without losing the stronger annotator findings,
but parser grammar alternatives still need human review.

### Operational Discontinuity

| Finding | Value | Disposition |
| --- | --- | --- |
| `src/ast/type.rb:3392` `compute_zig_type` | High | Strong signal. The method is a large type-to-Zig dispatcher with numbered phases. Worth extracting collection/map/generic handlers during Type work. |
| `src/ast/type.rb:2610` `slot_size` | Low/medium | Cohesive size dispatcher. The numbered comments trigger a true reset, but action value is modest because the method is small. |
| `src/annotator/phases/annotation_boundary.rb:28` `verify_annotation_boundary!` | Medium/high | Real verification phases: boundary violations, deferred validations, signatures. Worth extracting diagnostic checks. |
| `src/annotator/domains/member_access.rb:61` `visit_GetField` | High | Real visitor overload: target visit, moved-path validation, field/capability resolution. Worth splitting when editing member access. |
| `src/ast/parser.rb:3870` `parse_bg_body_stmt` | Medium | Parser alternative plus then-chain parsing. Useful signal, but grammar code should stay tier-3 unless paired with other metrics. |
| `src/annotator/helpers/effects.rb:402` `compute_needs_rt!` | High | Clear two-phase pass: local runtime need computation and imported callee seeding. Worth extracting phase helpers. |
| `src/annotator/helpers/effects.rb:955` `compute_stack_tiers!` | High | Explicit phase 1/phase 2 call-graph propagation. Worth extracting phase helpers. |
| `src/ast/type.rb:745` `initialize` | Medium | Constructor has shape/capability setup phases. Real complexity, but constructor refactors are higher risk. |
| `src/annotator/domains/lifetimes.rb:114` `visit_CopyNode` | High | Copy storage classification and deep-copy detection are distinct. Worth extracting. |
| `src/ast/parser.rb:1916` `parse_unary` | Low/medium | Small grammar alternative for unary and reserved override syntax. Not an action item by itself. |
| `src/ast/parser.rb:3596` `parse_cap_join` | Low/medium | Cohesive parser loop after first capability segment. Low urgency. |
| `src/annotator/domains/execution_boundaries.rb:226` `mark_unrequired_polymorphic_with_runtime!` | Medium | Bound lookup and marking are separable. Candidate for a small helper if this area changes. |
| `src/annotator/domains/lifetimes.rb:769` `lookup_source_name` | Low/medium | Scope scan plus function-param fallback. Acceptable fallback helper shape. |
| `src/annotator/helpers/generic_analysis.rb:608` `find_container_source` | Medium/high | Distinct source forms are mixed. Worth splitting by source case if generic analysis is edited. |
| `src/annotator/phases/auto_finalization.rb:22` `apply_auto_resolution_stamps!` | Medium/high | Clear two-phase finalization: slots then affected functions/signatures. Worth extracting helper phases. |
| `src/annotator/phases/body_analysis.rb:435` `analyze_program_bodies!` | Low/medium | Small explicit pass over declarations then synthetic functions. Not worth action alone. |
| `src/ast/parser.rb:2888` `type_annotation_source` | Low/medium | Special polymorphic-shared handling plus source reconstruction. Small and cohesive enough. |
| `src/ast/type.rb:2828` `needs_cleanup?` | Medium | Special cleanup cases plus general schema check. Extraction could clarify, but urgency is modest. |

Operational Discontinuity is more valuable than Function LCOM on this
codebase. The high-confidence subtype is useful enough for tier 2 after
the parser guard. The remaining broad section should stay tier 3 because
it still intentionally retains small blank-line resets and grammar
alternatives as review prompts.
