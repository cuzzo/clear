# Annotator Genuine Gaps Burndown

## Baseline

Current comparison point:
`tmp/decomplex-4-audit/after-capability-view-tense-direct-20260530-134352`

- SlopCop: 1208 dark arms, 280 genuine, 360 type_norm.
- Boobytrap annotator hotspots: `method_analysis.rb` 31/100 uncovered branches, `function_analysis.rb` 83/436, `capabilities.rb` 121/453, `annotator.rb` 544/2395.
- Decomplex convergence hotspots include `handle_assign_move`, `resolve_call`, `visit_WithBlock`, pipe analysis, and method resolution.

## Epic Rules

- Prefer deleting branches or tightening existing contracts over adding compensating branches.
- Do not move complexity sideways into new walkers, parallel dispatch tables, or test-only production hooks.
- A source change is worth keeping when it closes a meaningful gap cluster and real source LOC stays flat or decreases, unless the added code fixes an architectural correctness hole.
- Tests are the fallback when a branch is genuinely semantic and should remain. Expand existing specs or fuzz templates when possible; avoid one-off tests that close one branch with dozens of lines.
- After each item, regenerate full coverage and SlopCop, Boobytrap, and Decomplex reports. Keep the item only if most metrics move in the right direction or the correctness win is obvious.

## Top Work Items

1. **Collection method registry contract**
   - Target: `src/annotator/helpers/method_analysis.rb`.
   - Cause: collection method resolution repeatedly treats `emit` and `zig` as optional, even though `POOL_METHODS`, `SET_METHODS`, and `MAP_METHODS` are emit-driven registries.
   - Plan: prove registry totality, tighten the annotator to use that contract, and add one invariant spec so future registry edits cannot silently reintroduce nullable emit paths.
   - Expected impact: close at least 10 branch gaps with lower source complexity.

2. **Field access capability gate**
   - Target: `visit_GetField`.
   - Cause: capability/access checks still mix receiver typing, gate selection, and diagnostic branches.
   - Plan: look for an existing stamped access fact or a smaller predicate that can replace repeated local branching. If that requires a new walker or broad state object, reject it and cover dangerous cases with existing capability specs.

3. **Struct/union literal payload shaping**
   - Target: `visit_StructLit` and related finalize paths.
   - Cause: heap, indirect, variant, and ownership payload cases branch independently.
   - Plan: determine whether payload classification can reuse one existing type/cleanup contract. Only proceed if it deletes duplicated source branches.

4. **Named function pipe analysis**
   - Target: `analyze_pipe_to_named_function`.
   - Cause: pipe input typing and diagnostic paths are high-rank genuine gaps.
   - Plan: first check whether call resolution already computes enough facts. If not, expand the pipe fuzz matrix where one template can exercise many receiver/input shapes.

5. **Assignment target shapes**
   - Target: `visit_Assignment` and index/field assignment helpers.
   - Cause: local, field, index, capability, and moved-value cases branch in one path.
   - Plan: reuse existing target resolution where possible. If the branches represent real language cases, add compact integration coverage rather than new production abstractions.

6. **Bind/match/while-bind optional paths**
   - Target: `visit_IfBind`, `visit_MatchStatement`, `visit_WhileBindLoop`.
   - Cause: optional/error-union destructuring and ownership combinations are undercovered.
   - Plan: prefer expanding existing bind/match specs or a small fuzz matrix because these branches are mostly semantic rather than removable architecture.

7. **Capability validation edge cases**
   - Target: `capabilities.rb`.
   - Cause: representable but rare modality conflicts remain uncovered.
   - Plan: use tiny direct unit tests only where the branch is a true validation case; delete impossible guards when invariants prove them unreachable.

8. **Lifetime and borrow-source diagnostics**
   - Target: function/method return lifetime helpers.
   - Cause: wildcard, named, fallback, and diagnostic source paths remain partially uncovered.
   - Plan: expand existing lifetime specs when one snippet covers multiple source forms. Avoid adding new lifetime machinery unless it removes duplicated derivation.

## Execution Loop

For each item:

1. Snapshot the current reports under `tmp/decomplex-4-audit/`.
2. Audit whether each target branch is a real semantic case, defensive noise, or a classifier false positive.
3. Implement the smallest deletion or contract tightening that is architecturally correct.
4. Run focused specs first.
5. Regenerate full coverage:
   `COVERAGE=1 bundle exec prspec spec/`,
   `COVERAGE=1 bundle exec ruby transpile-tests/gen.rb`,
   `COVERAGE=1 bundle exec ruby tools/fuzz/run.rb --matrix --skip-quarantined --out /tmp/clear-fuzz-ci --clean`,
   `COVERAGE=1 bundle exec ruby tools/bc_lower_coverage.rb --jobs 32`,
   `bundle exec ruby spec/collate_coverage.rb`.
6. Regenerate SlopCop, Boobytrap, and Decomplex reports for `src/annotator`.
7. Compare against the prior snapshot and reject the item if the gap closure ratio is poor and no clear correctness improvement exists.
