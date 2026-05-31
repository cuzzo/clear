# Annotator Simplification Burndown

Scope: evaluate three simplification tracks independently:

1. Type contract cleanup.
2. Hash record replacement / reification.
3. Decomplex hotspot cleanup.

Each item gets its own baseline, change, after snapshot, and commit. The
evaluation for each item must say one of:

- **Worth it**: metrics improved or the code became materially simpler with no
  regression.
- **Continue**: the first slice moved in the right direction but needs another
  slice to pay for itself.
- **Scrap**: metrics moved the wrong way, the code got more complex, or the
  change only moved complexity around.

Bug fixes override the metrics. If fixing a real bug worsens a simplification
metric, keep the bug fix and record the tradeoff.

## Baseline Snapshot

Generated May 31, 2026 from the current working tree before this burndown.
Nil-kill was run with `--allow-stale-runtime` because the stored runtime
evidence predates the current source; use nil-kill as directional static/type
pressure until fresh evidence is collected.

Commands:

```bash
ruby gems/decomplex/exe/decomplex report src --output=/tmp/decomplex-burndown-before.md
ruby gems/slopcop/exe/slopcop report --output=/tmp/slopcop-burndown-before.md
ruby gems/boobytrap/exe/boobytrap report --output=/tmp/boobytrap-burndown-before.md
NIL_KILL_TARGETS=src bundle exec tools/nil-kill report --allow-stale-runtime --hygiene > /tmp/nil-kill-burndown-before.md
```

Metrics:

- SlopCop: 4051 dark arms, 1184 genuine gaps, 1162 type_norm arms, 899 diagnostic arms.
- Decomplex: 1349 cross-detector convergence units, 297 decision-pressure findings, 190 missing-abstraction findings.
- Boobytrap: top hotspot remains `src/mir/mir_lowering.rb` at 0.1498; annotator entries start at `src/annotator/helpers/function_analysis.rb` rank 29, hotspot 0.0092, 79/438 uncovered branches.
- Nil-kill: 3578 methods indexed, 194 missing sigs, 3384 existing sigs, 1250 candidate `T.let` sites.
- Nil-kill type pressure: param inputs 1293 untyped / 348 nilable; returns 340 untyped / 459 nilable; fields 1184 untyped / 142 nilable; collections 747 untyped / 319 nilable.

## Item 1: Type Contract Cleanup

Candidate signals:

- Nil-kill union decomplexity points at `.type`, `full_type!()`, and `.return_type` guards.
- Decomplex decision pressure still reports broad guard pressure around `.value`, `.symbol`, `.target`, `.emit`, `.full_type!`, `.name`, `.type`, and `.current_fn_ctx`.

Plan:

- Prefer narrowing an existing seam over deleting individual branches.
- Remove only guards that are already guaranteed by a typed writer or authoritative accessor.
- Snapshot reports after the slice and decide whether the contract cleanup should continue.

Status: continue.

Slice 1:

- Change: narrowed `FunctionSignature#return_type=` and
  `FunctionContext#return_type=` to the actual accepted contract, and removed
  one redundant `Type`/non-`Type` branch at call result stamping.
- Validation: `bundle exec srb tc`; `bundle exec prspec
  spec/annotator_gap_burndown_spec.rb spec/first_class_function_spec.rb
  spec/mir_lowering_spec.rb`.
- After metrics:
  - SlopCop: 4051 -> 4035 dark arms; 1162 -> 1139 type_norm arms; 1184 -> 1188 genuine gaps.
  - Decomplex: 1349 convergence units unchanged; 297 decision-pressure unchanged; 190 missing-abstraction unchanged. `resolve_call` dropped out of the top excerpt captured by the baseline comparison.
  - Boobytrap: unchanged for annotator `function_analysis.rb` at rank 29, 79/438 uncovered branches.
  - Nil-kill hygiene summary unchanged.
- Evaluation: **Continue**. The contract cleanup removed type-normalization pressure, but the small slice did not move nil-kill totals and converted/shifted a few SlopCop arms into genuine gaps. Continue only where a seam deletes repeated guards across multiple readers; do not do one-off sig tightening as a standalone win.

## Item 2: Hash Record Replacement / Reification

Candidate signals:

- Nil-kill reports 226 hash-record struct candidates.
- Annotator local pressure includes predicate context records, capability records, sync-policy selector records, union-field request records, and pipe option records.

Plan:

- Start with a small local hash shape that has clear ownership and no cross-file serialization contract.
- Replace raw `[:key]` consumers with a typed value object.
- Do not reify parser/AST public hashes unless the replacement can be carried through all consumers.

Status: pending.

## Item 3: Decomplex Hotspot Cleanup

Candidate signals:

- `src/annotator/annotator.rb:5427` `handle_assign_move`: 7 detectors, score 13, 54 findings.
- `src/annotator/annotator.rb:4710` `visit_WithBlock`: 6 detectors, score 11, 88 findings.
- `src/annotator/helpers/pipe_analysis.rb:1527` `analyze_concurrent_op`: 6 detectors, score 11, 70 findings.
- `src/annotator/annotator.rb:1978` `visit_WhileBindLoop`: 6 detectors, score 11, 38 findings.
- `src/annotator/helpers/function_analysis.rb:182` `resolve_call`: 5 detectors, score 10, 108 findings.

Plan:

- Pick the hotspot where a bounded extraction deletes repeated decision logic.
- Avoid large architectural rewrites unless the first slice proves the metric and readability payoff.
- Snapshot reports after the slice and decide whether to continue or stop.

Status: pending.

## Progress Log

- Item 1 slice 1 committed separately. Continue only with broader seam cleanup.
