# SlopCop — design

## What it is (and why it is a general gem)

A flat uncovered-count is unactionable: gaps are not equal. SlopCop is
a **general engine**: it categorizes every dark branch arm by
reachability class and ranks the genuine ones by consumed fix-cache
churn — "the top true gaps to test, in order." It is a gem for the
same reason fix-cache is: a coherent, reusable, versioned product
with its own identity. "It's an aggregation" argues for *consuming*
the others, not against gem status.

## Generality / no baked-in lexicon

The earlier objection was correct: the first cut baked CLEAR jargon
(`.cht`, `fuzz`, `nil-kill`) and CLEAR's FFI method names into the
gem. Fixed:

- **Vocabulary is generic.** Category actions are
  testing-strategy-neutral ("error/raise path — invalid input only",
  "external/boundary — integration test"). No project jargon.
- **The project lexicon is caller-supplied.** `ffi_boundary:` (the
  external/boundary method names) defaults to empty in the gem; the
  consuming project passes its own (CLEAR's set lives in the CLI
  `exe/slopcop`, not the library). `DIAGNOSTIC_MIDS` is general Ruby
  (`raise`/`fail`/`abort`).

The *engine* — categorize uncovered branches, rank genuine by churn —
is general to any Ruby project with branch coverage + git history.

## Boundary

OWNS gap-categorization (AST-structural per-arm classifier, dead/live
decision split, category rollup, the gap ranking). CONSUMES the
sibling `fix-cache` gem for churn (require_relative, not re-derived)
and an optional nil-kill verdict for `type_norm`. Re-derives nothing.

## Categories

| category | meaning | not a test target? |
|---|---|---|
| `type_norm` | type/nil guard (`is_a?`/`kind_of?`/`nil?`/`respond_to?`/safe-nav) | yes — likely dead if the contract were strictly typed |
| `dead` | no sibling arm ever taken: decision never executes | yes — audit/delete |
| `defensive` | live, inert/invariant-pinned | yes — accept |
| `ffi` | caller-declared external/boundary method | special — integration test |
| `diagnostic` | arm raises/diagnoses | special — invalid-input only |
| `genuine` | live, reachable, input-determined | **NO — this is the gap; ranked by churn** |

## Report shape (per the user's ask)

Leads with **Top True Gaps**: every `genuine` arm, repo-relative +
markdown-linked (`[src/x.rb:226](src/x.rb#L226)`), ranked by the
file's normalized fix-cache churn. Then a compact category summary
(not a per-file %-table — that was unhelpful). The actionable list
is the headline; the rest is context.

## AST-structural, never a line regex

SimpleCov parent tuple → decision kind; arm `(line,col)` span → AST
node; the decision's *condition* (parent first child, where a
type-guard lives) and the arm body are inspected.

## Honest v0 precision caveats (Engler: ranked, refine)

- `diagnostic` over-greedy: tags any arm whose subtree contains
  `raise`/`fail`/`abort` anywhere, not "the arm IS primarily a
  raise." Over-counts. Refine: require it to be the dominant outcome.
- `type_norm` under-counted: no intra-procedural `local =
  recv.accessor` resolution, so a guard on a local sourced from
  `.type_info` is missed unless syntactically on the accessor. Refine
  by consuming decomplex's local→contract resolution (don't re-derive).
- The Top-True-Gaps ranking and the categorization *shape* are sound
  and validated (top genuine sites are the exact cleanup/ownership
  methods that produced real bugs B1–B4); the per-category
  percentages are candidates to tighten, not verdicts.

## Self-tested

`test/classifier_test.rb` (incl. a real stdlib-`Coverage` resultset
integration), `test/rollup_test.rb` (real temp git repo + churn
overlay). 6 runs / 30 assertions / 0 failures.
