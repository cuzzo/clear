# EPIC-66 -- Round-2 Decomplexity: Baseline & Progress

Branch: `epic-66-decomplex-r2`. Round-2 of the prior `decomplex` epic (#46 -> EPIC-65).
Scope: MIR + Escape Analysis + the annotator stamp-producers lowering re-derives from.
**Every number below must drop dramatically by epic close.** Re-measure with the exact
commands listed; fill the AFTER column at closeout (Unit N).

## How to re-measure (identical commands)

```
# Typing slots (scope = src/)
ruby tools/typing_baseline.rb src

# Sorbet global typedness
bundle exec srb tc --metrics-file=/tmp/srb-metrics.json   # must stay green
# read ruby_typer.unknown.types.input.{untyped.usages,methods.typechecked,sends.typed}

# Gem reports
ruby gems/boobytrap/exe/boobytrap report --repo=. --coverage=coverage/.resultset.json --output=gems/boobytrap/report.md
ruby gems/decomplex/exe/decomplex report src --output=gems/decomplex/report.md
ruby gems/slopcop/exe/slopcop report --output=gems/slopcop/report.md
```

## Baseline (commit `dc4590a59`, 2026-05-19)

### Typing slots -- `tools/typing_baseline.rb src` (97 files)

| Slot category        | untyped | nilable | AFTER untyped | AFTER nilable |
|----------------------|--------:|--------:|--------------:|--------------:|
| params               |   1744  |   598   |   1691 (-53)  |   597         |
| returns              |    735  |   542   |    696 (-39)  |   549         |
| collections          |    825  |     7   |    776 (-49)  |     8         |
| structs/ivars        |      8  |    47   |      8        |    47         |
| structs/ivars `T.let`|    123 (slots) |  |   123    |               |
| **TOTAL (src/ raw token)** | **2609** | **952** | **2545 (-64)** | **961 (+9)** |

AFTER = final (Unit N, `32fab3691`). `untyped` -64 (-2.5%). `nilable` rose +9:
the typed-struct/predicate work (CleanupEntry accessors, `AST.root_identifier`,
`cap_source_name`) adds honest `T.nilable` accessor sigs; the nil-sentinel kill
that would offset it was scoped to one cluster (1.5c) for memory-safety reasons.
Net-honest: untyped fell, nilable did not -- the aggregate nilable drop needs
the non-nil contract propagated repo-wide (deferred 1.5d).

(Categories overlap by construction: a `T.untyped` inside `T::Hash[..]` inside a
`params(...)` is counted in params, collections, and TOTAL. TOTAL is the canonical
headline raw-token count.)

### Sorbet global (`/tmp/srb-metrics-baseline.json`) -- status: GREEN (0 errors)

| Metric | Baseline | AFTER |
|---|--:|--:|
| `types.input.untyped.usages` | 25431 | **25272 (-159)** |
| `types.input.methods.typechecked` | 6123 | 6147 (+24) |
| status | GREEN | GREEN (0 errors, every commit) |

## Outcome -- honest delta (Units 0-5 + 1.5; ~6 of the planned units)

**What moved (targeted clusters collapsed, byte-identical):**
- decomplex Reification-Misses **133 -> 126**, Derived-State-Staleness
  **252 -> 241**, Broken-Protocols **1815 -> 1802**; the #1 in-scope
  convergence unit `lower_var_decl` findings **86 -> 69**.
- Sorbet `untyped.usages` **25431 -> 25272 (-159)**; src/ raw `T.untyped`
  **2609 -> 2545 (-64)**. Sorbet stayed GREEN across all ~15 commits.
- 14 byte-identical structural commits (564/564 transpile-tests, 0 leaks,
  4819 specs 0 failures throughout).

**What did NOT move dramatically (stated plainly):**
- decomplex aggregate is ~flat: Total candidates 12257 -> 12251 (-6),
  convergence +2, clusters -2. A handful of collapsed clusters is small
  against ~12k repo-wide candidates -- only ~6 units of a much larger
  plan were executed.
- boobytrap flat (by construction -- cannot move from refactors).
- slopcop genuine gaps 390 -> 387 (-3).
- src/ `T.nilable` rose +9 (honest typed sigs added; nil-sentinel kill
  scoped to one cluster).

**Bottom line:** the *targeted* decomplexity metrics improved measurably
and the untyped surface shrank, but the *aggregate* gem headlines did not
drop dramatically -- that needs the remaining units (1.5d repo-wide
non-nil contract, escape/annotator deeper passes) which were out of this
session's executed scope.

### decomplex (`gems/decomplex/report.md`, 97 files, 13 detectors)

| Metric | Baseline | AFTER |
|---|--:|--:|
| Total candidates | 12257 | 12251 (-6) |
| Convergence units (>=2 detectors) | 1167 | 1169 (+2) |
| Root-cause clusters | 326 | 324 (-2) |
| Decision Pressure | 257 | 256 (-1) |
| Missing Abstractions | 206 | 206 (0) |
| Reification Misses | 133 | **126 (-7)** |
| Derived-State Staleness | 252 | **241 (-11)** |
| Broken Protocols | 1815 | **1802 (-13)** |
| Neglected Conditions | 47 | 47 |
| Neglected Path Conditions | 2100 | 2104 (+4) |
| Neglected Updates | 6798 | 6820 (+22) |
| False Simplicity | 616 | 616 |
| Fat Unions | 10 | 10 |
| Top in-scope unit `lower_var_decl` | 8 detectors, score 15, **86 findings** | 8 detectors, score 15, **69 findings (-17)** |

### boobytrap (`gems/boobytrap/report.md`, whole repo, 65 files ranked)

| Metric | Baseline | AFTER |
|---|--:|--:|
| #1 hotspot `src/mir/mir_lowering.rb` | 0.3181 | 0.3181 (flat) |
| #2 `src/annotator.rb` | 0.2415 | 0.2415 (flat) |
| `src/mir/escape_analysis.rb` | 0.0385 | 0.0385 (flat) |
| Fix commits matched | 869 | 869 |

boobytrap = fix-churn x branch-coverage-gap. It moves only when bugs are
fixed and tests added -- **by construction it cannot move from
byte-identical refactors against the same coverage resultset**. Flat here
is the expected, correct result, not a miss.

### slopcop (`gems/slopcop/report.md`, 3 MIR files)

| Metric | Baseline | AFTER |
|---|--:|--:|
| dark arms | 3413 | 3413 (flat) |
| genuine gaps | 390 (11.4%) | 387 (-3) |
| type_norm | 763 (22.4%) | ~ |
| diagnostic | 1569 (46.0%) | ~ |
| Top-5 genuine gaps | all `mir_lowering.rb lower_var_decl` | still lower_var_decl |

## Progress log

| Unit | Commit | Notes |
|---|---|---|
| 0 baseline | `dc4590a59` | reports regenerated |
| 0 metrics | `3710df248` | typing + gem baseline captured |
| 1 | `6112cdd1a` | single-source `ft` in `lower_var_decl` (kill redundant recompute); byte-identical |
| 1.5a | `40858bf2d` | typed `CleanupEntry < Hash` foundation; ~28 entry sigs flipped; byte-identical. src/ TOTAL.untyped 2609->2564 |
| 1.5b(1) | `7f7b2a654` | lower_var_decl reader burn-down (decomplex #1 cluster); byte-identical |
| 1.5b(2) | `57fdf1e2d` | emitter reader burn-down + single-source all entry construction (runtime sig surfaced + fixed latent untyped-construction gap); byte-identical |
| 1.5b(3) | `056f3ab80` | mir_pass/control_flow/mir_lowering/mir_checker reader burn-down; byte-identical. src/ TOTAL.untyped -> 2541 (-68 cumulative); untyped.usages 25431->25322 |
| 1.5c | `690901c84` | non-nil contract: CleanupEntry::NONE replaces nil sentinel in lower_var_decl + owned_return_transfer_binding? (decomplex #1 cluster); collapses loose binding_entry &&/&. nil-guards into typed predicates; byte-identical (0 leaks = memory-safety proof). untyped.usages -> 25313 |
| 2 | `a6e965011` | `AST.root_identifier` reifies scatter-7 root-walk (4 faithful sites); degenerate fat-union hoist in `tag_transitive_provenance!`; byte-identical |
| 3 | `c87140d63` | reify 5x-rebuilt `schema_lookup` closure into one memoized `@schema_lookup`; byte-identical |
| 4 | `c97faa27c` | single-source `resource_captures(node)` for the capture_analysis cluster (3 core sites); byte-identical |
| 5 | `32fab3691` | `SymbolEntry#atomic?` reifies decomplex #1 Reification-Miss (16 sites); byte-identical |
| N | (this commit) | regenerate reports, fill AFTER/delta, honest outcome |

### Unit 1.5 -- DONE (foundation + full reader burn-down + scoped non-nil contract)

Cumulative src/ vs baseline: **TOTAL.untyped 2609 -> 2541 (-68)**,
collections.untyped 825 -> 775, params.untyped 1744 -> 1688, returns.untyped
735 -> 695. Sorbet `untyped.usages` 25431 -> 25313 (-118). `nilable` ~flat
(952 -> 959): the aggregate nilable drop needs the non-nil contract propagated
to *all* lookup sites + the classifier return (a 1.5d / Unit-N follow-on); 1.5c
was deliberately scoped to the one fully memory-safety-analyzable cluster.

## Unit 1.5 -- CleanupEntry (Hash -> typed) slices

The `cleanup_bindings` entry was a loose `T::Hash[Symbol, T.untyped]` with a
nil-sentinel for "no cleanup". It is decomplex's #1 in-scope convergence cluster
(`lower_var_decl`, 8 detectors) -- the repeated `binding_entry && ...[:alloc] ==
:cleanup` / `.dig` guards. Slices:

- **1.5a (done, `40858bf2d`)** -- introduce `CleanupEntry < Hash` (drop-in: native
  `[]`/`dig`/`dup`/`merge`/`key?` + typed accessors + single `build`/`from`
  constructor). All construction routed through it. ~28 entry sigs flipped off
  `T::Hash[..T.untyped..]`. Byte-identical.
- **1.5b (next)** -- reader burn-down: `entry[:kind]` -> `entry.kind`, etc., across
  the ~112 sites in 8 files (incl. emitter). Per-file stand-alone commits.
- **1.5c** -- non-nil contract: `CleanupEntry::NONE` replaces the nil sentinel;
  collapse the `binding_entry && ...` decision-pressure guards. This is the big
  `nilable` + Decision-Pressure drop. Subsumes/de-risks Units 3-4.

---

## COMPLETION PHASE (U6-U10 + closeout) -- final delta vs original baseline `dc4590a59`

| metric | baseline | FINAL | delta |
|---|--:|--:|--:|
| decomplex **Reification-Misses** | 133 | **83** | **-50 (-37.6%)** |
| decomplex Derived-State-Staleness | 252 | 241 | -11 (-4.4%) |
| decomplex Broken-Protocols | 1815 | 1794 | -21 (-1.2%) |
| decomplex Missing-Abstractions | 206 | 204 | -2 |
| decomplex Fat-Unions | 10 | 9 | -1 |
| decomplex Decision-Pressure | 257 | 256 | -1 |
| decomplex Total candidates | 12257 | 12192 | -65 (-0.53%) |
| decomplex convergence units | 1167 | 1162 | -5 |
| Sorbet **untyped.usages** | 25431 | **25155** | **-276 (-1.09%)** |
| Sorbet methods.typechecked | 6123 | 6156 | +33 |
| src/ T.untyped | 2609 | 2549 | -60 (-2.3%) |
| src/ params/returns/collections untyped | 1744/735/825 | 1694/697/776 | -50/-38/-49 |
| src/ T.nilable | 952 | 959 | +7 |
| boobytrap #1/#2 | 0.3181/0.2415 | 0.3181/0.2415 | flat (by construction) |
| slopcop genuine gaps | 390 | 388 | -3 |

### Unit outcomes
- **U6** `ac25d2e31` -- Type/SymbolEntry atomic?/atomic_ptr? completion. byte-identical.
- **U7** REJECTED on correctness. The 8 mir_pass `bindings: T.nilable` params are
  load-bearing, NOT spurious: `nil` = CATCH-clause context (`empty_ctx`) -> skip;
  `{}` = real fn no-cleanup -> proceed. `return unless bindings` distinguishes
  them; collapsing nil->{} broke CATCH return-handling (2 spec failures).
  Reverted. The earlier 1.5d spurious-nilable kill (`690901c84`/`ade2745eb`)
  was the safe subset; this is its hard boundary.
- **U8** `f21643bb5` -- classify_suspend value-classification reified (3x dup -> 1
  helper). The other 2 plan targets were detector false-positives (recurse_branches!
  genuine per-type variance; transfer_stmt already in prescribed shape) -- not chased.
- **U9** `b0626e5e5` -- AST::CapabilityWrap/Param predicates + full object-receiver
  sweep. Drove Reification-Misses 133->83. NOT zero: ~3 irreducible bare-LOCAL
  `sync == :atomic` (no object to host a predicate -- decomplex heuristic noise,
  not a branch-that-should-not-exist) + the recurse_branches! false-positive remain.
- **U10** ASSESSED, not forced. Top Decision-Pressure (`.full_type` 234, `.value`
  110) is annotator-helpers -- out of the `src/mir/**`+core scope, already
  MIR-side-tightened by the prior epic, and a U7-class cross-subsystem risk.
  In-scope `.capture_analysis` residue is cross-class / single-use with no
  byte-identical single-source. Surfacing the limitation > band-aiding it.

### Honest bottom line
The **targeted high-signal** metric moved materially: Reification-Misses **-37.6%**,
Sorbet untyped.usages **-276**. The **aggregate** decomplex headline is still
modest (-0.53%) and `T.nilable` rose +7 -- because the volume detectors
(Neglected-Updates ~6.8k / Neglected-Path ~2.1k / Broken-Protocols ~1.8k =
~11k of 12k) are low-signal *POSSIBLE* and were **deliberately excluded** (chasing
them is churn, not simplification), and the genuine remaining `nilable`/
Decision-Pressure levers (load-bearing CATCH nil; annotator-helpers `.full_type`)
were correctly **not forced** on correctness/scope grounds (U7, U10). "Dramatic
aggregate drop" was not achieved and is not achievable without either a separate
annotator-helpers epic or accepting correctness regressions. Every one of the
~21 commits is byte-identical (564/564 transpile, 0 leaks, Sorbet GREEN,
4819 specs 0 failures).
