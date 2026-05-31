# Boobytrap Report

> Defect-risk hotspots: recurring bug-fix locality (bugspots, time-decayed) x branch-coverage gap.
> A ranking to triage **top-down**, never a verdict. A
> hotspot is "the code most likely to be a bug source,"
> not "a bug."

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Hotspots (56)](#hotspots-56)
- [Fixed But Unmeasured (8)](#fixed-but-unmeasured-8)
- [Run Summary](#run-summary)

## Project Prioritization
- The single highest-risk file is **`src/mir/mir_lowering.rb`** (hotspot=0.1498: fix_norm=1.0, branch gap=15.0%).
- 2 file(s) are within 50% of the top score (hotspot >= 0.0749); triage those first.

## Hotspots (56)
_normalized fix-churn x branch-gap; highest = most likely defect source._

| # | file | hotspot | fix_norm | branch gap | uncovered/total |
|---|------|---------|----------|-----------|-----------------|
| 1 | `src/mir/mir_lowering.rb` | 0.1498 | 1.0 | 15.0% | 152/1015 |
| 2 | `src/ast/std_lib.rb` | 0.0869 | 0.191 | 45.5% | 10/22 |
| 3 | `src/backends/pipeline_host.rb` | 0.0721 | 0.266 | 27.1% | 217/800 |
| 4 | `src/mir/mir_pass.rb` | 0.0639 | 0.257 | 24.8% | 75/302 |
| 5 | `src/mir/mir_emitter.rb` | 0.0454 | 0.27 | 16.8% | 67/399 |
| 6 | `src/mir/mir.rb` | 0.0444 | 0.154 | 28.7% | 77/268 |
| 7 | `src/ast/ast.rb` | 0.0416 | 0.157 | 26.4% | 107/405 |
| 8 | `src/mir/control_flow.rb` | 0.04 | 0.204 | 19.7% | 90/458 |
| 9 | `src/mir/hoist.rb` | 0.0386 | 0.146 | 26.5% | 131/494 |
| 10 | `src/ast/diagnostic_registry.rb` | 0.0323 | 0.091 | 35.7% | 5/14 |
| 11 | `src/mir/fsm_lowering.rb` | 0.0309 | 0.082 | 37.7% | 58/154 |
| 12 | `src/ast/type.rb` | 0.0271 | 0.175 | 15.5% | 127/818 |
| 13 | `src/mir/escape_analysis.rb` | 0.0246 | 0.134 | 18.3% | 98/535 |
| 14 | `src/tools/doctor.rb` | 0.0232 | 0.033 | 70.5% | 351/498 |
| 15 | `src/mir/fsm_transform/emit.rb` | 0.0211 | 0.084 | 25.1% | 65/259 |
| 16 | `src/mir/mir_checker.rb` | 0.02 | 0.087 | 23.0% | 180/782 |
| 17 | `src/ast/parser.rb` | 0.0191 | 0.113 | 16.8% | 180/1069 |
| 18 | `src/backends/transpiler.rb` | 0.0191 | 0.036 | 52.5% | 21/40 |
| 19 | `src/mir/bg_capture_classifier.rb` | 0.0189 | 0.054 | 35.1% | 13/37 |
| 20 | `src/ast/symbol_entry.rb` | 0.0144 | 0.047 | 30.8% | 8/26 |
| 21 | `src/mir/lowering/functions.rb` | 0.0137 | 0.051 | 26.9% | 178/661 |
| 22 | `src/mir/cleanup_classifier.rb` | 0.0134 | 0.051 | 26.5% | 154/582 |
| 23 | `src/mir/lowering/expressions.rb` | 0.0125 | 0.051 | 24.6% | 153/622 |
| 24 | `src/mir/fsm_transform/suspend_resolvers.rb` | 0.012 | 0.035 | 34.7% | 17/49 |
| 25 | `src/mir/lowering/capabilities.rb` | 0.0115 | 0.052 | 22.1% | 57/258 |
| 26 | `src/ast/diagnostic_buckets.rb` | 0.011 | 0.011 | 100.0% | 8/8 |
| 27 | `src/mir/fiber_ctx_builder.rb` | 0.0102 | 0.046 | 22.1% | 15/68 |
| 28 | `src/annotator/helpers/function_analysis.rb` | 0.0092 | 0.051 | 18.0% | 79/438 |
| 29 | `src/mir/ownership_graph.rb` | 0.0088 | 0.039 | 22.4% | 17/76 |
| 30 | `src/annotator/helpers/method_analysis.rb` | 0.0087 | 0.051 | 17.2% | 11/64 |
| 31 | `src/mir/lowering/variables.rb` | 0.0087 | 0.051 | 17.1% | 77/450 |
| 32 | `src/ast/scope.rb` | 0.0083 | 0.035 | 23.8% | 15/63 |
| 33 | `src/mir/pre_mir_type_check.rb` | 0.0081 | 0.021 | 38.5% | 10/26 |
| 34 | `src/mir/lowering/control_flow.rb` | 0.0062 | 0.026 | 23.9% | 85/355 |
| 35 | `src/backends/pipeline_rewriter.rb` | 0.0059 | 0.024 | 24.6% | 45/183 |
| 36 | `src/mir/capture_strategy.rb` | 0.0058 | 0.018 | 31.7% | 19/60 |
| 37 | `src/mir/test_lowering.rb` | 0.0056 | 0.033 | 17.0% | 8/47 |
| 38 | `src/ast/fixable_error.rb` | 0.0056 | 0.01 | 57.1% | 8/14 |
| 39 | `src/mir/lowering/literals.rb` | 0.0055 | 0.026 | 21.2% | 11/52 |
| 40 | `src/annotator/annotator.rb` | 0.005 | 0.025 | 20.2% | 475/2346 |

- ...(+16 more)

## Fixed But Unmeasured (8)
_files with recurring fixes but NO branch-coverage data -- recurring-fix code the corpus does not measure at all; itself a risk._

- `src/annotator.rb` (fix_norm=0.667)
- `src/tools/formatter.rb` (fix_norm=0.073)
- `src/tools/lint_fix_rewriter.rb` (fix_norm=0.022)
- `src/tools/fmt_verifier.rb` (fix_norm=0.021)
- `src/tools/method_rewriter.rb` (fix_norm=0.021)
- `src/tools/pprof.rb` (fix_norm=0.012)
- `src/tools/stack_verifier.rb` (fix_norm=0.011)
- `src/tools/pprof_converter.rb` (fix_norm=0.011)

## Run Summary
- Repo: `/home/yahn/cheat`
- Scope: `src/`
- Fix commits matched: 917 (time span over whole history, unfiltered)
- Files ranked: 56; fixed-but-unmeasured: 8
- Branch-coverage resultset: present
- Method: vendored bugspots ([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) x SimpleCov branch gap; file granularity; zero deps (see [docs/agents/design.md](docs/agents/design.md))
