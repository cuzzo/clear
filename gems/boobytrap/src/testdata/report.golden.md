# Boobytrap Report

> Defect-risk hotspots: recurring bug-fix locality (bugspots, time-decayed) x branch-coverage gap.
> A ranking to triage **top-down**, never a verdict. A
> hotspot is "the code most likely to be a bug source,"
> not "a bug."

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Hotspots (1)](#hotspots-1)
- [Mostly Uncovered Methods (0)](#mostly-uncovered-methods-0)
- [State-Based Branch Hotspots (2)](#statebased-branch-hotspots-2)
- [Multi-File Fix Blast Radius (1)](#multifile-fix-blast-radius-1)
- [Lineage Unit Risk (2)](#lineage-unit-risk-2)
- [Fixed But Unmeasured (0)](#fixed-but-unmeasured-0)
- [Run Summary](#run-summary)

## Project Prioritization
- The single highest-risk file is **`a.go`** (hotspot=0.5: fix_norm=1.0, branch gap=50.0%).
- 1 file(s) are within 50% of the top score (hotspot >= 0.2500); triage those first.
- Highest state-based branch hotspot: `a.go:testFunc` (score=8.00, state branches=4, fix_norm=1.000, branch gap=50.0%).
- Highest multi-file fix blast radius: `a.go` (score=1.0, avg files/fix=3.0, max=3).
- Highest lineage unit risk: `a.go` `testFunc` (risk=10.5, fixes=2, changes=5, moves=1).

## Hotspots (1)
_normalized fix-churn x branch-gap; highest = most likely defect source._

| # | file | hotspot | fix_norm | branch gap | uncovered/total |
|---|------|---------|----------|-----------|-----------------|
| 1 | `a.go` | 0.5 | 1.0 | 50.0% | 1/2 |

## Mostly Uncovered Methods (0)
_non-trivial methods (`>=5` executable lines) with very low line coverage; risk = missed lines x gap, Decomplex detector score, instance-state writes, dark branches, fix history, mutation verification, and named-test exposure when supplied._

None.

## State-Based Branch Hotspots (2)
_Decomplex state-based branch density joined with fix-cache and branch coverage. These are branches over mutable/object state that are uncovered and/or historically fixed._

| # | method | risk | state branches | refs | fix_norm | branch gap | line gap | dark branches |
|---|--------|------|----------------|------|----------|------------|----------|---------------|
| 1 | `a.go:testFunc` | 8.00 | 4 | `x | y` | 1.0 | 50.0% | 33.3% | 1 |
| 2 | `b.py:testFunc` | 5.00 | 4 | `x | y` | 1.0 | 0.0% | 0.0% | 0 |

## Multi-File Fix Blast Radius (1)
_Time-decayed fix commits where a file repeatedly changes with many other files. High rows are bug fixes whose blast radius is cross-module, not local._

| # | file | score | fixes | avg files/fix | max files | top co-touched files |
|---|------|-------|-------|---------------|-----------|----------------------|
| 1 | `a.go` | 1.0 | 1 | 3.0 | 3 | b.py (0.5); c.rb (0.5) |

## Lineage Unit Risk (2)
_Optional Lineage SQLite overlay: time-decayed semantic `FIX`/`CHANGE` events at logical-unit granularity. Pure moves are shown but do not add risk._

| # | unit | risk | fixes | changes | moves | events |
|---|------|------|-------|---------|-------|--------|
| 1 | `a.go` `testFunc` | 10.5 | 2 | 5 | 1 | 0 |
| 2 | `b.py` `testFunc` | 10.5 | 2 | 5 | 1 | 0 |

## Fixed But Unmeasured (0)
_files with recurring fixes but NO branch-coverage data -- recurring-fix code the corpus does not measure at all; itself a risk._

None.

## Run Summary
- Repo: `[REPO_ROOT]`
- Scope: `a.go/`
- Fix commits matched: 1 (time span over whole history, unfiltered)
- Files ranked: 1; fixed-but-unmeasured: 0
- State-based branch hotspots: 2; multi-file fix blast rows: 1
- Branch-coverage resultset: coverage.json + tree-sitter static fallback
- Mutation facts: mutation.json
- Test exposure facts: exposure.json
- Lineage DB: coverage.json
- Method: vendored bugspots ([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) x normalized coverage branch gap; method gaps use Decomplex detector scores, fix history, mutation verification, and named-test exposure when supplied (see [docs/agents/design.md](docs/agents/design.md))
