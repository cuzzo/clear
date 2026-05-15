# fix-cache: find the code most likely to be the source of bugs.

 * fix-cache answers "where is the complexity that is *likely causing
   my bugs*" -- not "what is the most complex code" (raw complexity is
   a weak bug predictor).
 * It vendors the **bugspots** algorithm (Google's time-decayed
   bug-fix-locality prediction, Lewis et al. ICSE'13 -- the actionable
   FixCache variant) and joins it with **branch-coverage gap**.
 * Zero runtime dependencies: stdlib + the `git` CLI. It produces one
   ranked report, like decomplex and nil-kill.

## What is a *hotspot*?

```
hotspot = normalized_fix_score x branch_coverage_gap
```

A file that **keeps getting bug-fixed** (recently, repeatedly) AND is
**under-exercised by the test corpus** is the highest-probability place
for the next bug. fix_score is the bugspots logistic time-decay over
fix commits; branch gap is uncovered decision arms / total, merged
across every SimpleCov resultset entry. High on both = look here first.

## How well does it work?

On CLEAR's compiler (835 fix commits in history) the top hotspot is
`src/mir/mir_lowering.rb` (fix_norm 1.0 -- the most-fixed, most-recent
-- x 24.6% branch gap), followed by `src/annotator.rb` and
`src/mir/control_flow.rb`. Those are exactly the memory-safety passes
behind bugs #1/#2/#9: the fix-history signal independently points at
the same code branch-coverage triage and decomplex flagged, from a
third direction, with no static analysis.

## How do I use it?

```
# Full report (markdown), like this gem's report.md:
fix-cache report --repo=. --coverage=coverage/.resultset.json \
                 --output=report.md

# Restrict ranking to part of the codebase (repeatable). The
# committed report.md is generated with --only=src/ -- the fix
# time-decay baseline still spans the WHOLE history; only which
# files are ranked is filtered:
fix-cache report --only=src/
fix-cache report --only=src/ --only=lib/

# No coverage data? It degrades to fix-churn-only, loudly flagged:
fix-cache report --repo=.
```

`--only=PATH` takes a repo-relative path prefix and is repeatable.
Scoping to `src/` is the recommended default for this repo: it
removes test/tooling/example noise so the hotspot ranking is the
production compiler only.

The resultset is SimpleCov's `coverage/.resultset.json` with
`enable_coverage :branch` (the repo already produces this; see
`tools/branch_gap_report.rb`). See [report.md](report.md) for a demo
over CLEAR's compiler.

### Reading the report

- **Project Prioritization** -- the single highest-risk file and how
  many are within 50% of it (triage those first).
- **Hotspots** -- ranked table: file, hotspot, fix_norm, branch gap,
  uncovered/total arms.
- **Fixed But Unmeasured** -- files with recurring fixes but *no*
  branch-coverage data. Recurring-fix code the corpus does not measure
  at all is itself a risk; it is surfaced, not dropped.

## What fix-cache does NOT do

 * **It does not claim bugs.** A hotspot is a prioritization. Triage
   top-down; the code may be fine.
 * **No complexity axis (v0).** Scoped to fix-churn x coverage.
   Complexity (Flog) is the documented optional third axis.
 * **File granularity (v0).** Method-level attribution (git blame x
   per-method branch gap) is the planned refinement.
 * **Not duplication or type analysis.** That is decomplex (what
   decision is duplicated) and nil-kill (which nils/types pollute).
   fix-cache only says *where* to look; the other two say *what* is
   wrong there. The three are complementary lenses.

## FAQ

**Why not the `churn` gem?** Raw churn measures activity and conflates
feature development with fault-proneness. fix-cache filters to fix
commits -- the signal Google's study found actually actionable.

**Why not the bugspots CLI directly?** It is file-only, unmaintained,
and produces a ranking you must re-localize by hand. We vendor its
~10-line scoring and join it with coverage so the output is directly
actionable in this repo's workflow.

**Does commit-message quality matter?** Yes -- the fix regex keys on
messages. CLEAR's CLAUDE.md mandates standalone "Fix ..." commits, so
the heuristic is reliable here.

## Links

 * [Design, prior art, boundaries](docs/agents/design.md)
 * [Demo report over CLEAR's compiler](report.md)
