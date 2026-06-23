# Decomplex Report

> Decision-level duplication and neglected-condition analysis.
> Every entry is a ranked **candidate** (Engler's discipline),
> never a verdict -- *POSSIBLE* findings, triaged by a human.
> Sections are ordered by SIGNAL TIER (1 = lowest false
> positive), not by volume. Items within a section are
> frequency-ranked. Triage tier 1, top-of-list, first.

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Cross-Detector Convergence (1)](#cross-detector-convergence-1)
- [Root-Cause Clusters (6)](#root-cause-clusters-6)
- [Decision Pressure (1)](#decision-pressure-1)
- [Redundant Nil Guards (0)](#redundant-nil-guards-0)
- [State Heatmap (0)](#state-heatmap-0)
- [State-Based Branch Density (1)](#statebased-branch-density-1)
- [Temporal Ordering Pressure (0)](#temporal-ordering-pressure-0)
- [Missing Abstractions (1)](#missing-abstractions-1)
- [Reification Misses (1)](#reification-misses-1)
- [Semantic Predicate Aliases (1)](#semantic-predicate-aliases-1)
- [Exact Predicate Aliases (0)](#exact-predicate-aliases-0)
- [Inconsistent Rename Clones (0)](#inconsistent-rename-clones-0)
- [Structural Similarity (Type-2/3) (0)](#structural-similarity-type23-0)
- [Neglected Updates (1)](#neglected-updates-1)
- [Derived-State Staleness (1)](#derivedstate-staleness-1)
- [Neglected Conditions (1)](#neglected-conditions-1)
- [Neglected Path Conditions (1)](#neglected-path-conditions-1)
- [Oversized Predicates (0)](#oversized-predicates-0)
- [Broken Protocols (1)](#broken-protocols-1)
- [Implicit Control Flow (0)](#implicit-control-flow-0)
- [Weighted Inlined Cognitive Complexity (0)](#weighted-inlined-cognitive-complexity-0)
- [Locality Drag (0)](#locality-drag-0)
- [Operational Discontinuity (High Confidence) (0)](#operational-discontinuity-high-confidence-0)
- [Function LCOM (0)](#function-lcom-0)
- [Operational Discontinuity (0)](#operational-discontinuity-0)
- [False Simplicity (1)](#false-simplicity-1)
- [Fat Unions (0)](#fat-unions-0)
- [Run Summary](#run-summary)

## Project Prioritization
_Ordered by signal tier (1 = highest signal / lowest FP), then by volume._

- **[tier 1]** [Decision Pressure (1)](#decision-pressure-1): ELIMINABLE guard-pressure per loose contract (nil/is_a?/respond_to?/safe-nav/rescue-nil) -> tighten the contract once / nil-kill: DELETE. essential dispatch + pure c-uses are split out, NEVER summed (Rapps-Weyuker p-use; McCabe)
- **[tier 1]** [State-Based Branch Density (1)](#statebased-branch-density-1): branch decisions over mutable/object state -- state + control-flow pressure
- **[tier 1]** [Missing Abstractions (1)](#missing-abstractions-1): guard tuple recomputed across >=2 decision units
- **[tier 1]** [Reification Misses (1)](#reification-misses-1): an existing predicate reinvented inline -- invariant #16
- **[tier 1]** [Semantic Predicate Aliases (1)](#semantic-predicate-aliases-1): one decision, multiple names (receiver/polarity folded)
- **[tier 2]** [Neglected Updates (1)](#neglected-updates-1): co-written state, one write missing -- *POSSIBLE* redundant-state desync
- **[tier 2]** [Derived-State Staleness (1)](#derivedstate-staleness-1): b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug
- **[tier 2]** [Neglected Conditions (1)](#neglected-conditions-1): dispatch/conjunction minus one element -- *POSSIBLE* bug
- **[tier 3]** [Neglected Path Conditions (1)](#neglected-path-conditions-1): nested-if/&& guard set minus one atom -- *POSSIBLE* bug (noisy)
- **[tier 3]** [Broken Protocols (1)](#broken-protocols-1): co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)
- **[tier 3]** [False Simplicity (1)](#false-simplicity-1): looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/reflection/reopen -- *POSSIBLE* (noisy)

## Cross-Detector Convergence (1)
_(file, method) units flagged by >=2 INDEPENDENT detectors -- the strongest triage signal: agreement outranks any single detector's volume. Tier-weighted (1=3, 2=2, 3=1). **Start here.**_

- `facts/report.rb:18` (checkout) -- **11 detectors** [score 24, 15 findings]: Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Neglected Updates, Reification Misses, Semantic Predicate Aliases, State-Based Branch Density

### By file
- `facts/report.rb` -- 11 detectors across 1 method(s): Broken Protocols, Decision Pressure, Derived-State Staleness, False Simplicity, Missing Abstractions, Neglected Conditions, Neglected Path Conditions, Neglected Updates, Reification Misses, Semantic Predicate Aliases, State-Based Branch Density

## Root-Cause Clusters (6)
_Findings across >=2 INDEPENDENT detectors that name the SAME entity -- 'N findings are really one invariant'. Convergence says where to look; this says **what one fix collapses the cluster**. Ranked candidate, not a verdict._

- **[name]** `storage` -- **7 detectors** [score 17] across 1 unit(s), 7 findings: Decision Pressure, Derived-State Staleness, False Simplicity, Neglected Updates, Reification Misses, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `facts/report.rb:18` (checkout) ; `facts/report.rb:20` (checkout) ; `facts/report.rb:14` (checkout) ; `facts/report.rb:13` (checkout)
- **[name]** `ready` -- **3 detectors** [score 9] across 1 unit(s), 3 findings: Reification Misses, Semantic Predicate Aliases, State-Based Branch Density
  - FIX: reify ONE named predicate/decision and call it everywhere
  - `facts/report.rb:20` (checkout) ; `facts/report.rb:14` (checkout) ; `facts/report.rb:13` (checkout)
- **[tuple]** `ready | valid` -- **3 detectors** [score 6] across 2 unit(s), 3 findings: Missing Abstractions, Neglected Conditions, Neglected Path Conditions
  - FIX: reify ONE named predicate/decision and call it everywhere
  - `facts/report.rb:10` (checkout) ; `facts/report.rb:30` (refund) ; `facts/report.rb:11` (checkout) ; `facts/report.rb:15` (checkout)
- **[name]** `READY` -- **2 detectors** [score 6] across 1 unit(s), 2 findings: Reification Misses, Semantic Predicate Aliases
  - FIX: reify ONE named predicate/decision and call it everywhere
  - `facts/report.rb:14` (checkout) ; `facts/report.rb:13` (checkout)
- **[name]** `provenance` -- **2 detectors** [score 4] across 1 unit(s), 2 findings: Derived-State Staleness, Neglected Updates
  - FIX: single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape
  - `facts/report.rb:12` (checkout) ; `facts/report.rb:17` (checkout)
- **[name]** `valid` -- **2 detectors** [score 3] across 1 unit(s), 2 findings: Neglected Conditions, Neglected Path Conditions
  - FIX: converging structural debt -- resolve once at the named entity
  - `facts/report.rb:11` (checkout) ; `facts/report.rb:15` (checkout)

## Decision Pressure (1)
_ELIMINABLE guard-pressure per loose contract (nil/is_a?/respond_to?/safe-nav/rescue-nil) -> tighten the contract once / nil-kill: DELETE. essential dispatch + pure c-uses are split out, NEVER summed (Rapps-Weyuker p-use; McCabe)_

- `.storage` -- ELIMINABLE guard-pressure **2** across 1 method(s) -> tighten contract / nil-kill: DELETE  (+1 essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)
  - `facts/report.rb:18` (checkout)

## Redundant Nil Guards (0)
_nil checks / safe-nav dominated by an earlier non-nil proof -- delete repeated control flow or tighten the type_

None.

## State Heatmap (0)
_state fields ranked by write/read/re-derivation scatter -- tangled mutable state should get one owner_

None.

## State-Based Branch Density (1)
_branch decisions over mutable/object state -- state + control-flow pressure_

- `facts/report.rb:20` (checkout) -- **1** state-based branch decision(s), refs=`storage` score=1
  - example predicate: `storage.ready?`

## Temporal Ordering Pressure (0)
_public mutable lifecycle surfaces that create implicit state-machine ordering_

None.

## Missing Abstractions (1)
_guard tuple recomputed across >=2 decision units_

- **[conjunction]** support=2 scatter=2 rank=
  - tuple: `ready | valid`
  - `facts/report.rb:10` (checkout) ; `facts/report.rb:30` (refund)

## Reification Misses (1)
_an existing predicate reinvented inline -- invariant #16_

- predicate `ready?` reinvented inline at `facts/report.rb:14` (checkout) (`storage == READY`)

## Semantic Predicate Aliases (1)
_one decision, multiple names (receiver/polarity folded)_

- `ready? = prepared?` == `storage == READY`
  - `facts/report.rb:13` (checkout)

## Exact Predicate Aliases (0)
_identical one-line predicate body under >=2 names_

None.

## Inconsistent Rename Clones (0)
_pasted block with inconsistent identifier mapping -- *POSSIBLE* missed rename bug_

None.

## Structural Similarity (Type-2/3) (0)
_Tree-sitter structural clone pressure: Type-2 renamed clones and Type-3 fuzzy clones -- refactor pressure, not a verdict_

None.

## Neglected Updates (1)
_co-written state, one write missing -- *POSSIBLE* redundant-state desync_

- *POSSIBLE* (support=3) `facts/report.rb:12` (checkout) writes `.storage` but NOT `.provenance` (recv `order`)

## Derived-State Staleness (1)
_b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug_

- *POSSIBLE* `facts/report.rb:17` (checkout): `storage` derived from `provenance` (line 17); `provenance` reassigned line 22, `storage` not recomputed

## Neglected Conditions (1)
_dispatch/conjunction minus one element -- *POSSIBLE* bug_

- *POSSIBLE* (support=2) `facts/report.rb:11` (checkout) -- MISSING `valid` from `ready | valid`

## Neglected Path Conditions (1)
_nested-if/&& guard set minus one atom -- *POSSIBLE* bug (noisy)_

- *POSSIBLE* (support=2) `facts/report.rb:15` (checkout) -- MISSING `valid` from `ready | valid`

## Oversized Predicates (0)
_predicate with >3 condition atoms -- use an existing helper or extract a named predicate_

None.

## Broken Protocols (1)
_co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)_

- *POSSIBLE* conf=0.8 support=4 `facts/report.rb:16` (checkout) does `open` without `close`

## Implicit Control Flow (0)
_state-dependent internal call order exists -- hidden lifecycle/control-flow pressure_

None.

## Weighted Inlined Cognitive Complexity (0)
_same-owner helper chain hides cognitive load behind a low-looking orchestration method_

None.

## Locality Drag (0)
_local initialized far before first use while unrelated work runs -- move setup closer or extract a private phase_

None.

## Operational Discontinuity (High Confidence) (0)
_strong blank/comment phase boundary where local variable lifetimes reset -- likely implicit sub-function boundary_

None.

## Function LCOM (0)
_independent local data-flow components inside one method -- *POSSIBLE* mixed concerns_

None.

## Operational Discontinuity (0)
_blank/comment phase boundary where local variable lifetimes reset -- *POSSIBLE* implicit sub-function boundary_

None.

## False Simplicity (1)
_looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/reflection/reopen -- *POSSIBLE* (noisy)_

- *POSSIBLE* [hidden_mutation] scatter=1 support=1 `storage=` -- `facts/report.rb:19` (checkout)

## Fat Unions (0)
_case dispatch over class consts whose arms read mostly variant-invariant members -- product-vs-sum decomposition candidate (extraction -> nil-kill) -- *POSSIBLE*_

None.

## Run Summary
- Files analyzed: 1
- Detectors: 25 (all shipped, self-tested)
- Convergence: 1 unit(s) flagged by >=2 independent detectors
- Root-cause clusters: 6 (one fix collapses each)
- Total candidates: 11
- Method: stdlib AST only, intra-procedural, zero deps, no CFG / no points-to; Type-2/3 similarity uses Tree-sitter structural fingerprints (see docs/agents/design.md)