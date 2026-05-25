# SlopCop — design

## What it is (and why it is a general gem)

A flat uncovered-count is unactionable: gaps are not equal. SlopCop is
a **general engine**: it categorizes every dark branch arm by
reachability class and ranks the genuine ones by consumed boobytrap
churn — "the top true gaps to test, in order." It is a gem for the
same reason boobytrap is: a coherent, reusable, versioned product
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
decision split, category rollup, the gap ranking). CONSUMES, all
read-only / re-derives nothing: the sibling `boobytrap` gem for churn
(require_relative); an optional nil-kill verdict for `type_norm`; and
optional `decomplex` for two things — the negative `spurious` filter
(a gap whose decision is redundant/cloned: refactor, do not test) and
the positive structural-deviance amplifier on `genuine` gaps. The
`Classifier` stays decomplex-agnostic and dependency-free; ALL
sibling-gem consumption lives in `Rollup` (the consumer layer).

**Apex thesis.** The one set worth a human's attention is
*uncovered ∧ legitimate ∧ in a buggy path*: a `genuine` gap (survives
every not-a-test-target filter) that is both historically churned
(boobytrap) and structurally deviant (decomplex). `genuine` ranking
is `priority = churn_norm + deviance_norm` (both [0,1]; `-churn`
tiebreak, so behaviour is IDENTICAL when decomplex is absent —
deviance 0 → priority == churn). "Buggy path" has two complementary
proxies: boobytrap = *historical* (bug-fix locality), decomplex
neglected-condition / broken-protocol / convergence = *structural,
now*. Neither proves a bug; their agreement is the prior (Engler).

decomplex is dual-role: `spurious` (exclude — refactor not test) and
deviance (amplify a surviving `genuine`). decomplex publishes each
finding's decision source extent `[fl,fc,ll,lc]`; the join is
**span-precise first**, `(file, method)` fallback (`†`) when no
flagged span contains the arm. The hardened policy is asymmetric, by
the rule *a silently suppressed real gap is the worst failure*:

- **`spurious` (a hard exclude — the arm LEAVES the gap list) is
  returned ONLY on the span-precise path.** A coarse method-join
  duplication signal must never silently delete a test target.
- A coarse duplication signal **never changes category**: the arm
  stays `genuine` (still testable — the safe direction) and is
  surfaced as `⚠dup?` ("possibly redundant, not localised — verify"),
  visible, never hidden.
- **Deviance is floored at the method value** (`max(span, method)`):
  precise attribution can only ADD specificity, never push an arm
  below its coarse peers (no precision-penalty inversion).
- **Decomplex unavailable/errored is a LOUD banner**, never a silent
  churn-only report that looks healthy. decomplex asserts its own
  span contract at `Report#sections_data` (fails in its own tests,
  naming the detector), so a bad span surfaces at the owner, not as a
  cryptic downstream crash.

Measured, CLEAR 3 hottest files: precise-only exclusion took
`spurious` 104 → **21** (the 21 are span-exact: the arm is literally
inside a duplicated/cloned decision). The **83** arms previously
excluded on a coarse basis returned to `genuine` (237 → 320), each
flagged `⚠dup?` — real test targets no longer silently dropped.
`†`/`⚠dup?` counts are surfaced in an explicit per-report caveat
line. Still a ranked candidate, not a verdict (same discipline as the
`type_norm`/`diagnostic` v0 caveats below).

## Categories

| category | meaning | not a test target? |
|---|---|---|
| `type_norm` | type/nil guard (`is_a?`/`kind_of?`/`nil?`/`respond_to?`/safe-nav) | yes — likely dead if the contract were strictly typed |
| `dead` | no sibling arm ever taken in coverage: decision never executes in the measured corpus | yes — audit as missing test; delete only if static reachability agrees |
| `defensive` | live, inert/invariant-pinned | yes — accept |
| `spurious` | decomplex: decision is redundant/cloned/re-derived | yes — refactor or delete; resolving the decomplex finding collapses the arm |
| `ffi` | caller-declared external/boundary method | special — integration test |
| `diagnostic` | arm raises/diagnoses | special — invalid-input only |
| `genuine` | live, reachable, input-determined | **NO — this is the gap; ranked by churn × decomplex structural deviance** |

## Report shape (per the user's ask)

Leads with **Top True Gaps**: every `genuine` arm, repo-relative +
markdown-linked (`[src/x.rb:226](src/x.rb#L226)`), ranked by the
file's normalized boobytrap churn. Then a compact category summary
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
