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
  testing-strategy-neutral ("diagnostic/error path — invalid input
  only", "external/boundary — integration test"). No project jargon.
- **Language lexicons are shared.** Type/null guards and default
  diagnostic/error forms come from `Decomplex::Syntax` language
  lexicons, so Ruby, Python, JavaScript/TypeScript, Go, Rust, and Zig
  do not share one Ruby-shaped regex table.
- **Project lexicons are caller-supplied.** `ffi_boundary:` (external
  or boundary method names) and `diagnostic_mids:` (domain helpers that
  report invalid input) default to empty in the gem; consuming projects
  pass their own.

The *engine* — categorize uncovered branches, rank genuine by churn —
is general to supported Tree-sitter languages with normalized coverage
and git history.

## Boundary

OWNS gap-categorization (parser-structural per-arm classifier, dead/live
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

Flay-backed Type-2/Type-3 similarity is consumed only through
decomplex's published finding contract. SlopCop never shells out to
Flay and never interprets clone clusters itself; a precise similarity
span can classify a gap as `spurious`, while a method-coarse overlap
only flags `⚠dup?` for human verification.

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
| `type_norm` | language-profile type/null guard | yes — likely dead if the code's runtime contracts were stricter |
| `dead` | no sibling arm ever taken in coverage: decision never executes in the measured corpus | yes — audit as missing test; delete only if static reachability agrees |
| `defensive` | live, inert/invariant-pinned | yes — accept |
| `spurious` | decomplex: decision is redundant/cloned/re-derived | yes — refactor or delete; resolving the decomplex finding collapses the arm |
| `ffi` | caller-declared external/boundary method | special — integration test |
| `diagnostic` | arm uses a language diagnostic/error form or calls a caller-declared invalid-input diagnostic helper | special — invalid-input only |
| `genuine` | live, reachable, input-determined | **NO — this is the gap; ranked by churn × decomplex structural deviance** |

## Report shape (per the user's ask)

Leads with **Top True Gaps**: every `genuine` arm, repo-relative +
markdown-linked (`[src/x.rb:226](src/x.rb#L226)`), ranked by the
file's normalized boobytrap churn. Then a compact category summary
(not a per-file %-table — that was unhelpful). The actionable list
is the headline; the rest is context.

## Parser-structural, language lexicons for text

Boobytrap normalizes coverage into Tree-sitter branch arms. For
coverage formats that only expose lines, SlopCop consumes the
line-to-arm inference from Boobytrap; for legacy Ruby branch tuples,
Boobytrap adapts those tuples to the same arm coverage contract. The
decision predicate and arm body are classified with the
`Decomplex::Syntax` language lexicon.

## Honest v0 precision caveats (Engler: ranked, refine)

- `diagnostic` precision depends on the caller-provided helper list:
  include methods that report invalid input, not ordinary logging or
  warning calls.
- `diagnostic` over-greedy: tags any arm whose subtree contains a
  language diagnostic/error form anywhere, not "the arm IS primarily
  a diagnostic." Over-counts. Refine: require it to be the dominant
  outcome.
- `type_norm` under-counted: no intra-procedural `local =
  recv.accessor` resolution, so a guard on a local sourced from
  `.type_info` is missed unless syntactically on the accessor. Refine
  by consuming decomplex's local→contract resolution (don't re-derive).
- The Top-True-Gaps ranking and the categorization *shape* are sound
  and validated (top genuine sites are the exact cleanup/ownership
  methods that produced real bugs B1–B4); the per-category
  percentages are candidates to tighten, not verdicts.

## Self-tested

`test/classifier_test.rb` (incl. real stdlib-`Coverage` resultset
integration and caller-supplied diagnostic lexicon coverage),
`test/rollup_test.rb` (real temp git repo + churn overlay).
