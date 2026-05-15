# prick — design

## Why this exists (and why it IS a gem)

A flat "673/2732 uncovered" is unactionable: gaps are not equal.
prick is the **capstone** — it turns the raw coverage gap into a
prioritised, categorical answer. It was promoted from the one-off
`tools/branch_prick.rb` probe because it is a coherent, reusable,
versioned product with its own identity, exactly like fix-cache (which
is itself an aggregation gem). "It's an aggregation" is an argument to
*consume* the other tools, not against gem status.

## Boundary

OWNS the gap-categorization analysis (the per-arm classifier, the
dead/live decision split, the categorical rollup). CONSUMES
`fix-cache` (churn) via the sibling gem; CONSUMES an optional nil-kill
verdict for type_norm removability. Re-derives nothing.

## Categories (the user's model: not all gaps equal)

| category | meaning | action |
|---|---|---|
| `type_norm` | arm/decision guards a type/nil check (`is_a?`/`kind_of?`/`nil?`/`respond_to?`/safe-nav) | likely removable — CONFIRM with nil-kill; a typed contract kills the whole cluster |
| `dead` | no sibling arm of the decision ever taken: decision never executes | audit as dead code → delete (complexity down) |
| `defensive` | live decision, inert/invariant-pinned (empty else, `nil`) | accept + annotate, drop from denominator |
| `ffi` | extern/require/module boundary | a few targeted `.cht` |
| `diagnostic` | arm raises/diagnoses | one negative unit spec (fuzz cannot reach) |
| `genuine` | live, reachable, input-determined, none of the above | the REAL gap — test it |

The one genuinely-new signal: **`genuine` arms × fix-cache churn =
"bugs highly likely HERE"** — the small actionable slice.

## Classification is AST-structural

Never a regex over the arm line. The SimpleCov parent tuple gives the
decision kind; the arm's `(line,col)` span is matched to an AST node;
the decision's CONDITION (parent node's first child — where a
type-guard lives) and the arm body are inspected. The FFI-boundary
method set and diagnostic message names are the only per-project
lexicon.

## Honest v0 precision caveats (Engler discipline: ranked, refine)

- `diagnostic` is **over-greedy**: it tags any arm whose subtree
  contains `raise`/`fail`/`abort` *anywhere*, not "the arm IS
  primarily a raise". Over-counts vs the older probe (305 vs 16).
  Refinement: require the raise to be the arm's dominant outcome.
- `type_norm` is **under-counted**: the classifier does not do
  decomplex's intra-procedural `local = recv.accessor` resolution, so
  a guard on a local that came from `.type_info` is missed unless the
  guard is syntactically on the accessor. Refinement: fold in
  decomplex's local→contract resolution (consume, don't re-derive).
- Net: the *shape* and the bug-likely join are sound and empirically
  validated (top genuine sites are the exact cleanup/ownership
  methods that produced bugs B1–B4); the per-category percentages are
  candidates to tighten, not verdicts.

## Validated result (src/mir/{mir_lowering,control_flow,escape_analysis})

935 dark arms: diagnostic 305 (32.6%), genuine 273 (29.2%), type_norm
229 (24.5%), dead 68 (7.3%), ffi 46 (4.9%), defensive 14 (1.5%).
Bugs-highly-likely #1: `src/mir/mir_lowering.rb` — 187 genuine arms ×
churn 1.0; top sites `hoist_alloc`, `owned_value_temp_needs_cleanup?`
— the exact methods behind B1–B4. The synthesis points at real bugs.

## Self-tested

`test/classifier_test.rb` (incl. a real stdlib-`Coverage` resultset
integration), `test/rollup_test.rb` (real temp git repo + churn
overlay). 6 runs / 30 assertions / 0 failures.
