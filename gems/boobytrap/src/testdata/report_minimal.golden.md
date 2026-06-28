# Boobytrap Report

> Defect-risk hotspots: recurring bug-fix locality (bugspots, time-decayed) x branch-coverage gap.
> A ranking to triage **top-down**, never a verdict. A
> hotspot is "the code most likely to be a bug source,"
> not "a bug."

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Hotspots (1)](#hotspots-1)
- [Mostly Uncovered Methods (1)](#mostly-uncovered-methods-1)
- [State-Based Branch Hotspots (2)](#statebased-branch-hotspots-2)
- [Multi-File Fix Blast Radius (1)](#multifile-fix-blast-radius-1)
- [Lineage Unit Risk (2)](#lineage-unit-risk-2)
- [Fixed But Unmeasured (0)](#fixed-but-unmeasured-0)
- [Run Summary](#run-summary)

## Project Prioritization
- The single highest-risk file is **`b.py`** (hotspot=1.0: fix_norm=1.0, branch gap=100.0%).
- 1 file(s) are within 50% of the top score (hotspot >= 0.5000); triage those first.
- Highest state-based branch hotspot: `b.py:testFunc` (score=21.00, state branches=4, fix_norm=1.000, branch gap=100.0%).
- Highest multi-file fix blast radius: `b.py` (score=1.0, avg files/fix=3.0, max=3).
- Highest empirical method risk: `b.py:1` `testFunc` (risk=32.00, fix_norm=1.0, verification=not supplied, tests=lineage: 3 tests; spec;unit; mutant killed 1/2).
- Highest lineage unit risk: `a.go` `testFunc` (risk=10.5, fixes=2, changes=5, moves=1).
- WARNING: no branch-coverage resultset supplied; only fix-churn is shown (gap assumed unknown).

## Hotspots (1)
_normalized fix-churn x branch-gap; highest = most likely defect source._

| # | file | hotspot | fix_norm | branch gap | uncovered/total |
|---|------|---------|----------|-----------|-----------------|
| 1 | `b.py` | 1.0 | 1.0 | 100.0% | 1/1 |

## Mostly Uncovered Methods (1)
_non-trivial methods (`>=5` executable lines) with very low line coverage; risk = missed lines x gap, Decomplex detector score, instance-state writes, dark branches, fix history, mutation verification, and named-test exposure when supplied._

- Completely uncovered: 1
- <=10% covered: 1
- <=20% covered: 1
- <=50% covered: 1

| # | method | risk | covered | missed | fix_norm | lineage | decomplex | verification | tests | profile | writes | dark branches |
|---|--------|------|---------|--------|----------|---------|-----------|--------------|-------|---------|--------|---------------|
| 1 | `b.py:1` `testFunc` | 32.00 | 0/6 | 6 | 1.0 | 10.5 (f2/c5/m1) | 1 | not supplied | lineage: 3 tests; spec;unit; mutant killed 1/2 | mutation-killed exposure (lineage) | 0 | 1 |

## State-Based Branch Hotspots (2)
_Decomplex state-based branch density joined with fix-cache and branch coverage. These are branches over mutable/object state that are uncovered and/or historically fixed._

| # | method | risk | state branches | refs | fix_norm | branch gap | line gap | dark branches |
|---|--------|------|----------------|------|----------|------------|----------|---------------|
| 1 | `b.py:testFunc` | 21.00 | 4 | `x | y` | 1.0 | 100.0% | 100.0% | 1 |
| 2 | `a.go:testFunc` | 5.00 | 4 | `x | y` | 1.0 | 0.0% | 0.0% | 0 |

## Multi-File Fix Blast Radius (1)
_Time-decayed fix commits where a file repeatedly changes with many other files. High rows are bug fixes whose blast radius is cross-module, not local._

| # | file | score | fixes | avg files/fix | max files | top co-touched files |
|---|------|-------|-------|---------------|-----------|----------------------|
| 1 | `b.py` | 1.0 | 1 | 3.0 | 3 | a.go (0.5); c.rb (0.5) |

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
- Scope: `b.py`
- Fix commits matched: 1 (time span over whole history, unfiltered)
- Files ranked: 1; fixed-but-unmeasured: 0
- State-based branch hotspots: 2; multi-file fix blast rows: 1
- Branch-coverage resultset: ABSENT (fix-churn only)
- Mutation facts: not supplied
- Test exposure facts: not supplied
- Lineage DB: coverage.json
- Method: vendored bugspots ([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) x normalized coverage branch gap; method gaps use Decomplex detector scores, fix history, mutation verification, and named-test exposure when supplied (see [docs/agents/design.md](docs/agents/design.md))
