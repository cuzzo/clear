# Boobytrap

Boobytrap helps you find the code most likely to be the source of bugs.
It does not ask "what is the most complex code?" Raw complexity is a weak
bug predictor. Boobytrap asks which code keeps getting bug-fixed,
recently and repeatedly, and whether that same code is under-tested.

In plain terms: Boobytrap tells you where to look first. Decomplex and
Nil-kill can help explain what is wrong when you get there.

## Getting Started

If you want to contribute, see [CONTRIBUTING.md](CONTRIBUTING.md).

### Prerequisites

- Ruby 3.x
- Bundler
- A git repository
- Optional branch coverage, mutation, test exposure, or Lineage data

From this repository:

```bash
bundle exec gems/boobytrap/exe/boobytrap report \
  --repo=. \
  --coverage=coverage/.resultset.json \
  --output=gems/boobytrap/report.md
```

For this repo, scoping to production compiler code is usually the most
useful default:

```bash
bundle exec gems/boobytrap/exe/boobytrap report \
  --repo=. \
  --coverage=coverage/.resultset.json \
  --only=src/ \
  --output=/tmp/boobytrap.md
```

No coverage data? Boobytrap still runs, but it loudly degrades to
fix-churn-only evidence:

```bash
bundle exec gems/boobytrap/exe/boobytrap report --repo=.
```

## Outputs

Boobytrap outputs a Markdown report that ranks defect-risk hotspots for
human review or LLM-assisted triage.

### Markdown Report

```bash
bundle exec gems/boobytrap/exe/boobytrap report \
  --repo=. \
  --coverage=coverage/.resultset.json \
  --output=report.md
```

The report opens with project prioritization, then shows ranked
hotspots, mostly uncovered methods, state-based branch hotspots,
multi-file fix blast radius, optional Lineage unit risk, fixed-but-
unmeasured files, and a run summary. See [report.md](report.md) for a
generated example over CLEAR.

## Evidence Inputs

Boobytrap's core score is:

```text
hotspot = normalized_fix_score x branch_coverage_gap
```

- `fix_score` is a time-decayed score from bug-fix commits.
- `branch_coverage_gap` is uncovered decision arms divided by total
  decision arms.
- High on both means the code is historically bug-prone and weakly
  pinned by the current test corpus.

### Coverage

`--coverage` accepts Boobytrap-normalized coverage inputs:

- SimpleCov `.resultset.json`;
- kcov output directories;
- kcov Cobertura XML;
- kcov codecov JSON;
- coverage.py JSON;
- Nil-kill branch coverage JSON.

### Lineage

Add logical-unit history from Lineage:

```bash
bundle exec gems/boobytrap/exe/boobytrap report \
  --repo=. \
  --coverage=coverage/.resultset.json \
  --lineage-db=/tmp/lineage.db \
  --output=/tmp/boobytrap.md
```

Semantic `FIX` and `CHANGE` events add risk; pure moves are shown
separately and do not add risk.

### Test Exposure

Add named-test exposure facts:

```bash
bundle exec gems/boobytrap/exe/boobytrap report \
  --repo=. \
  --coverage=coverage/.resultset.json \
  --test-exposure=/tmp/test-exposure.json \
  --output=/tmp/boobytrap.md
```

When `--lineage-db` contains `test_exposure_events`, Boobytrap can use
the same signal from Lineage history without a separate side-input file.
Direct `--test-exposure` wins when both are supplied to avoid
double-counting the same current test run.

### Mutation Facts

Add `mutant-facts/v1` evidence:

```bash
bundle exec gems/boobytrap/exe/boobytrap report \
  --repo=. \
  --coverage=coverage/.resultset.json \
  --mutation=/tmp/mutant-facts.json \
  --output=/tmp/boobytrap.md
```

Mutation facts help separate scary-looking but well-verified code from
weakly verified empirical risk.

## Scope

Use `--only=PATH` to restrict which files are ranked:

```bash
bundle exec gems/boobytrap/exe/boobytrap report \
  --repo=. \
  --coverage=coverage/.resultset.json \
  --only=src/ \
  --only=zig/runtime/
```

The fix time-decay baseline still spans the whole repository history.
`--only` changes which files are displayed, not how historical recency is
calculated.

Use `--exclude=GLOB` to exclude generated, cache, or otherwise irrelevant
paths from source scans and rankings.

## Supported Languages Roadmap

Boobytrap's history signal is language-neutral. Coverage and source-file
support flow through Boobytrap coverage normalization and Decomplex
source filtering.

- [x] Ruby: used for CLEAR compiler review.
- [x] Zig: used for CLEAR runtime review.
- [ ] Python: experimentally supported.
- [ ] JavaScript: experimentally supported.
- [ ] TypeScript: experimentally supported.
- [ ] Go: experimentally supported.
- [ ] Rust: experimentally supported.

## Boundaries

Boobytrap does not:

- claim that a hotspot is a bug;
- collect coverage;
- run tests;
- run mutation testing;
- explain structural complexity by itself;
- infer nilability or type pressure;
- replace Decomplex, SlopCop, Nil-kill, Lineage, fuzzing, mutation, or
  type checks.

It ranks likely bug sources. A good finding should make a human say:
"this is where review and testing attention probably has the highest
return."

Boobytrap does not detect lint issues or code smells, as packages for
that already exist in every language.

## FAQ

**Why not the `churn` gem?** Raw churn measures activity and conflates
feature development with fault-proneness. Boobytrap filters to fix
commits -- the signal Google's study found actually actionable.

**Why not the bugspots CLI directly?** It is file-only, unmaintained,
and produces a ranking you must re-localize by hand. We vendor its
~10-line scoring and join it with coverage so the output is directly
actionable in this repo's workflow.

**Does commit-message quality matter?** Yes -- the fix regex keys on
messages. CLEAR's CLAUDE.md mandates standalone "Fix ..." commits, so
the heuristic is reliable here.

## Links

- [CLEAR compiler](../../README.md)
- [Decomplex](../decomplex/README.md): identifies complex state and
  control-flow pressure.
- [SlopCop](../slopcop/README.md): categorizes uncovered branches and
  ranks the true test gaps.
- [Lineage](../lineage/README.md): renders history and verification
  evidence next to source.
- [Nil-kill](../nil-kill/README.md): traces nil and type pressure back
  to its source.
