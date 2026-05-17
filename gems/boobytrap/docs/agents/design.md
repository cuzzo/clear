# boobytrap — design

## Why this exists

"Reduce complexity" is not actionable on its own. The useful question
is: **where is the complexity that is LIKELY the source of bugs?**
Raw cyclomatic complexity is a famously weak standalone defect
predictor (it mostly tracks size). The validated signal is
**fix-locality**: code that *keeps getting bug-fixed*, recently and
repeatedly. boobytrap ranks that, intersected with the test corpus's
**branch-coverage gap** — recurring-fix code that is *also* not pinned
by tests is the highest-probability latent-defect surface.

## Goal

One ranked report (like decomplex / nil-kill): the files most likely
to be the next bug source, triaged top-down. A hotspot is "look here
first," **never a verdict**.

## Method

```
hotspot(file) = normalized_fix_score(file) * branch_gap_fraction(file)
```

- **fix_score** — vendored bugspots: scan `git log` for commits whose
  message matches a fix regex, weight each by the bugspots logistic
  time-decay `1 / (1 + e^(-12t + 12))` (t in [0,1] over the span of
  fix commits), sum per file. Recent + repeated fixes dominate.
- **branch_gap** — `uncovered_arms / total_arms` from SimpleCov's
  `.resultset.json` (`enable_coverage :branch`), merged across every
  entry (a branch is covered if ANY entry took it). Same merge rule
  as `tools/branch_gap_report.rb`.
- Files with fixes but no branch data are reported separately
  ("Fixed But Unmeasured") — recurring-fix code the corpus does not
  measure at all is itself a risk, not something to silently drop.

Granularity is **file-level** in v0 (git history is natively
file-granular; bugspots and CodeScene are file-level too). Method-
level attribution (git blame + line-range mapping per fix commit,
joined with `branch_gap_report`'s per-method data) is the planned
refinement and the place this becomes maximally actionable.

## Prior art

- **FixCache / BugCache** (Kim et al., 2007) — cache fault-prone
  entities by change/temporal/spatial locality. The origin.
- **"Does Bug Prediction Support Human Developers?"** (Lewis et al.,
  Google, ICSE 2013) — found pure static defect prediction often
  *unactionable*; the signal that worked was recent + frequent
  bug-fix churn, time-decayed. boobytrap uses exactly that variant.
- **bugspots** (Igor Wiedler) — the canonical Ruby port of Google's
  rolling time-decay algorithm. We vendor its scoring (~10 lines),
  not its CLI (unmaintained, file-only, no join).
- **Nagappan & Ball** — code churn predicts defect density (raw
  churn; weaker than fix-filtered, hence we filter to fixes).
- **Adam Tornhill / CodeScene** (*Your Code as a Crime Scene*,
  *Software Design X-Rays*) — behavioral code analysis: complexity ∩
  change frequency = hotspots. The commercial reference design;
  boobytrap is the open, branch-coverage-joined, zero-dep slice of
  that idea targeted at this repo.

## Relationship to decomplex, nil-kill, and `churn`

| Tool | Question it answers | Overlap |
|---|---|---|
| **boobytrap** | *Where* is the code most likely to be a bug source? (risk localization) | — |
| **decomplex** | *What* decision is duplicated / half-applied? (structural defect) | none — disjoint question; boobytrap says "look at this file," decomplex says "this decision is re-derived" |
| **nil-kill** | *Which* nils/types pollute the codebase? (type pressure) | none — types, not risk or decisions |
| `churn` gem | How often does a file change? (activity) | superseded — raw churn conflates feature work with fault locality; boobytrap filters to fix commits, the validated signal |

The three first-party gems are complementary lenses on the same
codebase: boobytrap prioritizes *where* to look, decomplex explains
*what* structural defect is there, nil-kill removes a whole class of
type/nil ambiguity. boobytrap deliberately does **not** add a
complexity axis in v0 (the user scoped it to fix-churn × coverage);
complexity (Flog) is the documented optional third axis.

## Design principles

1. **Zero runtime deps.** stdlib + the `git` CLI only. The tool that
   audits the repo must not drag a dependency tree (matches
   decomplex; opposite of nil-kill's Sorbet+z3+runtime weight).
2. **Ranked, never a verdict.** A hotspot is a prioritization, not a
   bug claim. Triage top-down.
3. **Extraction separable from scoring.** `git` I/O is isolated from
   the pure scoring/merge/join functions, so the math is unit-tested
   without a repo. (`Bugspots.score`, `CoverageGap.from_resultset`,
   `Hotspot.rank` are all pure.)
4. **Honest degradation.** No resultset → fix-churn-only report,
   loudly flagged, never a silent wrong number.
5. **Self-tested.** 14 tests: scoring math, log parsing, resultset
   merge, the join/ranking, end-to-end over a synthetic git repo,
   and graceful no-coverage / no-fix degradation.

## Validated result (on this repo)

835 fix commits matched. Top hotspot: `src/mir/mir_lowering.rb`
(fix_norm 1.0 — the most-fixed, most-recently-fixed file — × 24.6%
branch gap), then `src/annotator.rb`, then `src/mir/control_flow.rb`
high in the list. These are precisely the memory-safety passes that
produced bugs #1/#2/#9 — the fix-locality signal independently points
at the same code the branch-coverage triage and decomplex flagged,
from a third direction (history), with no static analysis at all.
