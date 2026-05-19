# slopcop - CI gate (branch-truth + tech-debt ratchet)

## Why this exists

CodeCov (and line-coverage % in general) is insufficient for what we
need from CI:

- It reports a **flat percentage**, not *which* branch arms are dark
  or whether they matter. "Coverage 78.4% (-0.2%)" is unactionable -
  exactly the problem SlopCop was built to fix offline; this doc
  brings that fix to the PR.
- It is **line**, not **branch-arm**, oriented. The dangerous gap is a
  specific never-taken decision arm in a churned, structurally-deviant
  method - CodeCov cannot say that.
- It has **no tech-debt-expansion signal**. A PR that adds an
  untested reachable branch, or grows a known decomplex root-cause
  cluster, or pushes a file deeper into a boobytrap hotspot, passes
  CodeCov silently. We want CI to say: *you are expanding reeking
  debt in code you are already editing - clean it up in this commit
  instead.*

SlopCop is the capstone (it already consumes boobytrap churn + the
decomplex verdict); this doc is SlopCop extended to a PR gate. The
tech-debt-expansion half is powered by **decomplex Delta** (the
before/after mode); SlopCop consumes it - it does not re-derive it.

## Goal

A CI step that posts, per PR, the **delta** of three already-existing
signals restricted to the files the PR touches, and gates on that
delta - never on absolute scores.

1. **Branch truth** - the genuine uncovered arms the PR *added or left*
   in changed files, categorized + ranked (SlopCop's normal output,
   diffed against the merge base).
2. **Debt ratchet** - decomplex root-cause clusters and boobytrap
   hotspots that this PR *grew*, with the "clean it here" nudge.
3. A machine verdict (JSON) + a human Markdown comment + a Checks
   conclusion. The gem emits these; it does NOT call the GitHub API.

Non-goal: gating on absolute debt. Legacy debt must not block every
PR. The gate is a **ratchet on touched code only** (see below).

## The ratchet (the core idea)

Compute each signal on the **merge base** and on the **PR head**, diff
restricted to files the PR modifies:

- A *new* genuine gap in a changed hunk -> flagged ("you added an
  untested reachable branch here").
- An existing decomplex root-cause cluster whose finding count grew on
  a file the PR touched -> flagged ("this PR expands known tech debt
  at X; you are already in this code - resolve the cluster here").
- A file the PR pushed into a worse boobytrap hotspot band -> noted.
- Net debt on touched files *decreased* -> pass, and say so.

Rationale: you cannot make code you are editing worse, and you are
nudged to clean what you are already touching. Untouched legacy debt
is reported as context, never as a blocker. This is the
Engler-discipline ratchet: candidates and a *delta* policy, not an
absolute verdict.

## Policy (configurable, default warn)

| condition (touched files only) | default | strict |
|---|---|---|
| new `genuine` gap in a changed hunk | warn (annotate) | fail |
| decomplex root-cause cluster grew | warn | fail |
| `spurious` (span-precise) arm added | warn ("delete, don't write") | fail |
| boobytrap hotspot band worsened | comment only | warn |
| net touched-file debt decreased | success + praise | success |
| decomplex/coverage unavailable | neutral + LOUD banner (never silent pass) | neutral |

Thresholds live in a caller-supplied config (the gem ships none - same
"no project lexicon baked in" discipline as `--ffi`). Default is
**warn, do not block**; `--strict` makes the table's strict column the
Checks conclusion.

## GitHub mechanics (the gem stays general + dep-free)

The gem produces two artifacts and nothing else:

- `slopcop ci --base=<sha> --head=<sha> --coverage-base=... --coverage-head=...`
  emits (a) `slopcop-ci.md` (the idempotent PR comment body) and
  (b) `slopcop-ci.json` (machine verdict: per-file deltas, the
  conclusion, annotation coordinates `file:line:arm`).
- A thin CI wrapper in the *consuming repo* (a ~30-line GitHub Action,
  documented here, not shipped in the gem) posts/updates the single
  PR comment (idempotent by a marker), sets the Checks conclusion from
  the JSON, and emits inline **annotations on the exact dark branch
  lines** - the arm-level, categorized signal CodeCov cannot give.

No `octokit`, no GitHub SDK, no network in the gem (zero runtime deps,
stdlib + git + the sibling gems only - SlopCop's existing boundary).
The repo owns the posting; the gem owns the analysis + verdict. This
keeps the gem a general engine usable by any host/CI.

## What the PR comment contains

1. **Verdict line** - pass / warn / fail + the one-sentence reason.
2. **New true gaps in this PR** - the SlopCop Top-True-Gaps table
   filtered to added/changed dark arms, churn x decomplex deviance
   ranked, repo-linked, with the precise/`†`/`⚠dup?` markers intact.
3. **Debt you expanded** - decomplex root-cause clusters that grew on
   touched files, each with "fix here" framing + blast radius.
4. **Context (not gating)** - net touched-file delta; untouched
   legacy hotspots for awareness only.
5. **Banner** if any signal was unavailable (never a silent green).

## Boundary

- SlopCop owns the CI *surface* (the diff view, the policy, the
  comment/verdict shape). The before/after *engine* is decomplex
  Delta (#3), consumed read-only. Churn is boobytrap, consumed.
  SlopCop re-derives none of it.
- The gem never posts to GitHub; it emits Markdown + JSON. The repo's
  Action wires the post. This is deliberate (general engine, no SDK
  weight, testable offline).
- Gate is a delta-ratchet on touched files, never an absolute bar.

## Honest caveats

- **Two analysis runs per PR.** decomplex is seconds; boobytrap base
  is cheap (git history). The real cost is **two coverage
  resultsets** - base and head - which CI must produce (SlopCop
  already requires one; the gate requires the base one too, e.g. from
  a cached base-branch test run). Without the base resultset the gate
  degrades to "head-only, no delta" and says so loudly.
- **Touched-files restriction.** Cross-file debt a PR *triggers* but
  does not textually touch can be missed. Documented limitation, same
  ranked-candidate posture as the rest of the toolchain - the gate is
  a nudge, not a proof.
- **Stable identity across base/head** uses decomplex Delta's
  line-insensitive key (detector + entity + unit). A method rename
  reads as resolve+add; the comment shows both raw and key-matched
  deltas so a reviewer can tell.
- **Default is non-blocking.** A ratchet that blocks on day one gets
  disabled. Ship `warn`, let a repo opt into `--strict` once the
  baseline is clean.
