# Boobytrap Report

> Defect-risk hotspots: recurring bug-fix locality (bugspots, time-decayed) x branch-coverage gap.
> A ranking to triage **top-down**, never a verdict. A
> hotspot is "the code most likely to be a bug source,"
> not "a bug."

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Hotspots (0)](#hotspots-0)
- [Mostly Uncovered Methods (1)](#mostly-uncovered-methods-1)
- [State-Based Branch Hotspots (2)](#statebased-branch-hotspots-2)
- [Multi-File Fix Blast Radius (1)](#multifile-fix-blast-radius-1)
- [Lineage Unit Risk (0)](#lineage-unit-risk-0)
- [Fixed But Unmeasured (1)](#fixed-but-unmeasured-1)
- [Run Summary](#run-summary)

## Project Prioritization
_No hotspots: no fix-churn x coverage-gap overlap found._

## Hotspots (0)
_normalized fix-churn x branch-gap; highest = most likely defect source._

None.

## Mostly Uncovered Methods (1)
_non-trivial methods (`>=5` executable lines) with very low line coverage; risk = missed lines x gap, Decomplex detector score, instance-state writes, dark branches, fix history, mutation verification, and named-test exposure when supplied._

- Completely uncovered: 1
- <=10% covered: 1
- <=20% covered: 1
- <=50% covered: 1

| # | method | risk | covered | missed | fix_norm | lineage | decomplex | findings | writes | dark branches |
|---|--------|------|---------|--------|----------|---------|-----------|----------|--------|---------------|
| 1 | `a.go:3` `testFunc` | 15.00 | 0/6 | 6 | 1.0 | 0 | 1 | [{"type"=>"unused_return"}] | 0 | 0 |

## State-Based Branch Hotspots (2)
_Decomplex state-based branch density joined with fix-cache and branch coverage. These are branches over mutable/object state that are uncovered and/or historically fixed._

| # | method | risk | state branches | refs | fix_norm | branch gap | line gap | dark branches |
|---|--------|------|----------------|------|----------|------------|----------|---------------|
| 1 | `b.py:testFunc` | 5.00 | 4 | `x | y` | 1.0 | 0.0% | 0.0% | 0 |
| 2 | `a.go:testFunc` | 0.00 | 4 | `x | y` | 1.0 | 0.0% | 100.0% | 0 |

## Multi-File Fix Blast Radius (1)
_Time-decayed fix commits where a file repeatedly changes with many other files. High rows are bug fixes whose blast radius is cross-module, not local._

| # | file | score | fixes | avg files/fix | max files | top co-touched files |
|---|------|-------|-------|---------------|-----------|----------------------|
| 1 | `a.go` | 1.0 | 1 | 3.0 | 3 | b.py (0.5); c.rb (0.5) |

## Lineage Unit Risk (0)
_Optional Lineage SQLite overlay: time-decayed semantic `FIX`/`CHANGE` events at logical-unit granularity. Pure moves are shown but do not add risk._

_No Lineage database supplied._

## Fixed But Unmeasured (1)
_files with recurring fixes but NO branch-coverage data -- recurring-fix code the corpus does not measure at all; itself a risk._

- `a.go` (fix_norm=1.0)

## Run Summary
- Repo: `[REPO_ROOT]`
- Scope: `a.go/`
- Fix commits matched: 1 (time span over whole history, unfiltered)
- Files ranked: 0; fixed-but-unmeasured: 1
- State-based branch hotspots: 2; multi-file fix blast rows: 1
- Branch-coverage resultset: absent
- Mutation facts: not supplied
- Test exposure facts: not supplied
- Lineage DB: not supplied
- Method: vendored bugspots ([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) x normalized coverage branch gap; method gaps use Decomplex detector scores, fix history, mutation verification, and named-test exposure when supplied (see [docs/agents/design.md](docs/agents/design.md))
