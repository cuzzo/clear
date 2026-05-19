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
| params               |   1744  |   598   |               |               |
| returns              |    735  |   542   |               |               |
| collections          |    825  |     7   |               |               |
| structs/ivars        |      8  |    47   |               |               |
| structs/ivars `T.let`|    123 (slots) |  |          |               |
| **TOTAL (src/ raw token)** | **2609** | **952** |       |               |

(Categories overlap by construction: a `T.untyped` inside `T::Hash[..]` inside a
`params(...)` is counted in params, collections, and TOTAL. TOTAL is the canonical
headline raw-token count.)

### Sorbet global (`/tmp/srb-metrics-baseline.json`) -- status: GREEN (0 errors)

| Metric | Baseline | AFTER |
|---|--:|--:|
| `types.input.untyped.usages` | 25431 | |
| `types.input.methods.typechecked` / `.total` | 6123 / 7885 | |
| `types.input.sends.typed` / `.total` | 59306 / 81118 | |
| `types.sig.count` | 6963 | |
| files sigil strict / true / false | 79 / 4 / 3 | |

### decomplex (`gems/decomplex/report.md`, 97 files, 13 detectors)

| Metric | Baseline | AFTER |
|---|--:|--:|
| Total candidates | 12257 | |
| Convergence units (>=2 detectors) | 1167 | |
| Root-cause clusters | 326 | |
| Decision Pressure | 257 | |
| Missing Abstractions | 206 | |
| Reification Misses | 133 | |
| Derived-State Staleness | 252 | |
| Broken Protocols | 1815 | |
| Neglected Conditions | 47 | |
| Neglected Path Conditions | 2100 | |
| Neglected Updates | 6798 | |
| False Simplicity | 616 | |
| Fat Unions | 10 | |
| Top in-scope unit | `mir_lowering.rb:6163 lower_var_decl` -- 8 detectors, score 15, 86 findings | |

### boobytrap (`gems/boobytrap/report.md`, whole repo, 65 files ranked)

| Metric | Baseline | AFTER |
|---|--:|--:|
| #1 hotspot `src/mir/mir_lowering.rb` | 0.3181 (fix 1.0, gap 31.8%, 2842/8934) | |
| #2 `src/annotator.rb` | 0.2415 (fix 0.772, gap 31.3%, 1538/4920) | |
| `src/mir/escape_analysis.rb` | 0.0385 (gap 27.6%, 186/674) | |
| Fix commits matched | 869 | |

### slopcop (`gems/slopcop/report.md`, 3 MIR files)

| Metric | Baseline | AFTER |
|---|--:|--:|
| dark arms | 3413 | |
| genuine gaps | 390 (11.4%) | |
| type_norm | 763 (22.4%) | |
| diagnostic | 1569 (46.0%) | |
| Top-5 genuine gaps | all `mir_lowering.rb lower_var_decl` (churn 1.0, deviance 20) | |

## Progress log

| Unit | Commit | Notes |
|---|---|---|
| 0 baseline | `dc4590a59` | reports regenerated |
| 0 metrics | (this doc) | typing + gem baseline captured |
