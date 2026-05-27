# Boobytrap Report

> Defect-risk hotspots: recurring bug-fix locality (bugspots, time-decayed) x branch-coverage gap.
> A ranking to triage **top-down**, never a verdict. A
> hotspot is "the code most likely to be a bug source,"
> not "a bug."

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Hotspots (45)](#hotspots-45)
- [Fixed But Unmeasured (6)](#fixed-but-unmeasured-6)
- [Run Summary](#run-summary)

## Project Prioritization
- The single highest-risk file is **`src/mir/mir_lowering.rb`** (hotspot=0.288: fix_norm=1.0, branch gap=28.8%).
- 2 file(s) are within 50% of the top score (hotspot >= 0.144); triage those first.

## Hotspots (45)
_normalized fix-churn x branch-gap; highest = most likely defect source._

| # | file | hotspot | fix_norm | branch gap | uncovered/total |
|---|------|---------|----------|-----------|-----------------|
| 1 | `src/mir/mir_lowering.rb` | 0.288 | 1.0 | 28.8% | 564/1958 |
| 2 | `src/annotator.rb` | 0.1765 | 0.745 | 23.7% | 581/2452 |
| 3 | `src/backends/pipeline_host.rb` | 0.1052 | 0.213 | 49.4% | 740/1498 |
| 4 | `src/ast/std_lib.rb` | 0.0716 | 0.157 | 45.5% | 10/22 |
| 5 | `src/mir/mir_pass.rb` | 0.0645 | 0.229 | 28.2% | 198/702 |
| 6 | `src/mir/mir_emitter.rb` | 0.0632 | 0.271 | 23.3% | 89/382 |
| 7 | `src/mir/control_flow.rb` | 0.0528 | 0.198 | 26.7% | 267/1000 |
| 8 | `src/ast/ast.rb` | 0.0481 | 0.175 | 27.5% | 165/600 |
| 9 | `src/mir/mir.rb` | 0.0362 | 0.086 | 42.2% | 124/294 |
| 10 | `src/ast/type.rb` | 0.0273 | 0.138 | 19.8% | 158/800 |
| 11 | `src/mir/escape_analysis.rb` | 0.0268 | 0.122 | 21.9% | 217/989 |
| 12 | `src/tools/doctor.rb` | 0.0262 | 0.037 | 70.5% | 351/498 |
| 13 | `src/ast/diagnostic_registry.rb` | 0.0257 | 0.072 | 35.7% | 5/14 |
| 14 | `src/backends/transpiler.rb` | 0.0216 | 0.041 | 52.5% | 21/40 |
| 15 | `src/ast/parser.rb` | 0.0213 | 0.128 | 16.7% | 178/1069 |
| 16 | `src/mir/mir_checker.rb` | 0.019 | 0.069 | 27.6% | 218/790 |
| 17 | `src/mir/fsm_lowering.rb` | 0.0183 | 0.033 | 55.1% | 70/127 |
| 18 | `src/mir/fiber_ctx_builder.rb` | 0.0173 | 0.052 | 33.3% | 20/60 |
| 19 | `src/ast/symbol_entry.rb` | 0.016 | 0.052 | 30.8% | 8/26 |
| 20 | `src/mir/hoist.rb` | 0.0153 | 0.045 | 33.8% | 215/636 |
| 21 | `src/mir/fsm_transform/emit.rb` | 0.0144 | 0.065 | 22.1% | 43/195 |
| 22 | `src/mir/test_lowering.rb` | 0.0138 | 0.036 | 38.3% | 18/47 |
| 23 | `src/ast/diagnostic_buckets.rb` | 0.0124 | 0.012 | 100.0% | 8/8 |
| 24 | `src/mir/bg_capture_classifier.rb` | 0.0108 | 0.032 | 34.3% | 12/35 |
| 25 | `src/ast/scope.rb` | 0.01 | 0.039 | 25.4% | 16/63 |
| 26 | `src/mir/ownership_graph.rb` | 0.01 | 0.045 | 22.4% | 17/76 |
| 27 | `src/mir/pre_mir_type_check.rb` | 0.0087 | 0.023 | 38.5% | 10/26 |
| 28 | `src/backends/pipeline_rewriter.rb` | 0.0072 | 0.027 | 27.1% | 78/288 |
| 29 | `src/mir/fsm_transform/recursive_splitter.rb` | 0.0067 | 0.014 | 48.9% | 65/133 |
| 30 | `src/ast/fixable_error.rb` | 0.0064 | 0.011 | 57.1% | 8/14 |
| 31 | `src/tools/stack_verifier.rb` | 0.0058 | 0.013 | 45.5% | 51/112 |
| 32 | `src/mir/fsm_wrapper_emitter.rb` | 0.0051 | 0.021 | 24.1% | 21/87 |
| 33 | `src/backends/importer.rb` | 0.0045 | 0.045 | 10.0% | 4/40 |
| 34 | `src/mir/capture_strategy.rb` | 0.0044 | 0.021 | 21.2% | 11/52 |
| 35 | `src/ast/source_error.rb` | 0.0041 | 0.017 | 24.4% | 11/45 |
| 36 | `src/mir/fsm_transform/suspend_resolvers.rb` | 0.0035 | 0.01 | 35.1% | 20/57 |
| 37 | `src/lsp/diagnostics.rb` | 0.0033 | 0.012 | 26.2% | 11/42 |
| 38 | `src/ast/diagnostic_examples.rb` | 0.0032 | 0.012 | 25.7% | 9/35 |
| 39 | `src/backends/pipeline_generator.rb` | 0.0028 | 0.011 | 25.0% | 10/40 |
| 40 | `src/backends/compiler_frontend.rb` | 0.0025 | 0.03 | 8.3% | 2/24 |

- ...(+5 more)

## Fixed But Unmeasured (6)
_files with recurring fixes but NO branch-coverage data -- recurring-fix code the corpus does not measure at all; itself a risk._

- `src/tools/formatter.rb` (fix_norm=0.083)
- `src/tools/lint_fix_rewriter.rb` (fix_norm=0.025)
- `src/tools/fmt_verifier.rb` (fix_norm=0.024)
- `src/tools/method_rewriter.rb` (fix_norm=0.024)
- `src/tools/pprof.rb` (fix_norm=0.014)
- `src/tools/pprof_converter.rb` (fix_norm=0.012)

## Run Summary
- Repo: `/home/yahn/cheat`
- Scope: `src/`
- Fix commits matched: 908 (time span over whole history, unfiltered)
- Files ranked: 45; fixed-but-unmeasured: 6
- Branch-coverage resultset: present
- Method: vendored bugspots ([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) x SimpleCov branch gap; file granularity; zero deps (see [docs/agents/design.md](docs/agents/design.md))
