# Decomplex fixture and coverage gap analysis

Date: 2026-06-20

## Current measured state

The shared detector examples now run in both places:

- Ruby: `gems/decomplex/test/examples_oracle_test.rb`
- Rust: `gems/decomplex/rust/tests/examples_oracle.rs`

Current shared fixture grid:

- 15 languages.
- 24 detectors.
- 360 detector/language fixture cells.
- 0 missing fixture cells.

Current Rust coverage from `cargo llvm-cov`, with Rust test code excluded from the line counts:

- Rust production: 68,796 / 84,602 executable lines, 81.32%.
- Rust detectors: 5,728 / 6,725 executable lines, 85.17%.

The largest earlier false signal was stale Rust-only detector code. Several low-coverage detector paths were not missing fixture coverage; they were code paths Ruby no longer owns in detectors:

- `state_branch_density`: removed the normalized-AST fallback scanner. Ruby consumes mined `branch_decisions`.
- `fat_union`: removed the normalized-root fallback scanner. Ruby consumes dispatch facts.
- `false_simplicity`: moved semantic-effect classification into syntax facts. The detector now consumes `semantic_effect_sites`.
- `state_mesh`: removed normalized-root read/write fallback behavior. The detector now consumes state facts.
- `temporal_ordering_pressure`: now discovers owners from both owner and function facts like Ruby.
- `weighted_inlined_cognitive_complexity` and `locality_drag`: moved local complexity scoring to `Document#local_complexity_scores`, matching Ruby's syntax fact boundary.

## Detectors below 90% Rust LoC coverage

These are the remaining detector implementation files below 90% after the architecture cleanup:

| Detector | Coverage | Primary gap |
| --- | ---: | --- |
| `sequence_mine` | 62.07% | One fixture hits only the positive pair. It misses ignored/declarative calls, nested protocol events, confidence filters, denominator branches, and sort tie-breaks. |
| `derived_state` | 65.38% | Fixture hits one stale derived variable. It misses multi-write ordering, self-dependency exclusion, no-reassignment, and recomputed-derived negatives. |
| `redundant_nil_guard` | 69.57% | Fixture is too narrow for guard shapes. Needs safe navigation, explicit nil checks, chained guards, local reassignment, and negative useful guards. |
| `decision_pressure` | 79.01% | Fixture hits local contract assignment only. It misses essential dispatch, rescue-nil, receiver/index/local contract canonicalization, conditional assignment rejection, and ranking. |
| `state_branch_density` | 79.44% | Fixture hits one non-nested state predicate. It misses wrapper suppression for nested branches and multi-row ranking. |
| `false_simplicity` | 79.59% | Oracle asserts only `kind`. It misses detail/support/scatter, top-level effects, monkeypatch/core owner cases, reopen cases, and grouping/ranking. |
| `state_mesh` | 81.35% | Fixture has one field. It misses multi-field percentiles, semantic-alias re-derivations, custom fields, and graph details. |
| `path_condition` | 84.38% | Fixture hits one neglected condition. It misses action/guard extraction variants, support/confidence filters, span containment, and negative paths. |
| `weighted_inlined_cognitive_complexity` | 84.81% | Architecture is now correct; fixture still needs multi-finding ranking, shared public step weighting, cycle/visited guard, and missing-callee branches. |
| `structural_topology` | 84.85% | Fixture misses self-call exclusion, singleton/static scoped names, multi-line source spans, hidden Ruby owner wrappers, and enclosing-span helper branches. |
| `local_flow` | 86.93% | The oracle is stronger than before but still not broad enough for all syntax categories. Needs local-flow semantic cases by grammar feature. |
| `locality_drag` | 89.89% | Needs one more case for low-complexity/short-gap negatives, rewrite-before-use, related gap expansion, and ranking. |

## Fixture strategy

The plan is sound, with one correction: do not write fixtures to cover code that should not exist in detectors. First delete or move misplaced detector-owned syntax work, then expand fixtures around the remaining legitimate detector behavior.

Use these fixture layers:

1. Keep the existing `examples/<language>/<detector>.<suffix>` files as smoke tests.
2. Add case fixtures where one file per detector is not enough. Preferred layout:
   - `examples/<language>/<detector>/<case>.<suffix>`
   - `examples/oracles/<detector>/<case>.json`
3. Keep oracles shared across languages. Only scrub location/SARIF fields; do not collapse semantic fields to counts when the detector behavior depends on the omitted fields.
4. Run both engines against the same oracle projection:
   - Ruby for cross-engine parity.
   - Rust integration tests for Rust CI truth and Rust LCOV coverage.

## Immediate fixture expansion order

Highest leverage order:

1. `sequence_mine`: add support/confidence negative cases and nested protocol events.
2. `derived_state`: add stale, recomputed, self-dependent, and multi-write cases.
3. `redundant_nil_guard`: add guard-shape matrix and useful-guard negatives.
4. `state_branch_density`: add nested wrapper suppression and multi-row ranking.
5. `decision_pressure`: add essential dispatch and rescue-nil cases.
6. `false_simplicity`: strengthen projection to include `kind`, `detail`, `support`, and `scatter`, then add effect and monkeypatch cases.
7. `state_mesh`: add multi-field/re-derivation/custom-field cases.
8. `local_flow`: add syntax-facts-style fixtures for reads/writes/dependencies/co-uses across declarations, destructuring, member/index writes, loops, closures, and cleanup blocks.

## Root-cause/report/SARIF plan

Ignoring reporting for the current detector pass is reasonable. The downstream plan should still be:

1. Create a shared facts JSON oracle containing detector outputs and syntax facts.
2. Feed that JSON into Ruby and Rust root-cause code and compare a stable projected output.
3. Reuse the same facts JSON for report and SARIF snapshot tests later.

That gives coverage for root cause, convergence, report, and SARIF without multiplying language fixtures. The JSON should contain full facts, not a detector-specific subset, so later stages can share it.
