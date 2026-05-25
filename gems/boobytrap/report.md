# Boobytrap Report

> Defect-risk hotspots: recurring bug-fix locality (bugspots, time-decayed) x branch-coverage gap.
> A ranking to triage **top-down**, never a verdict. A
> hotspot is "the code most likely to be a bug source,"
> not "a bug."

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Hotspots (48)](#hotspots-48)
- [Fixed But Unmeasured (57)](#fixed-but-unmeasured-57)
- [Run Summary](#run-summary)

## Project Prioritization
- The single highest-risk file is **`src/mir/mir_lowering.rb`** (hotspot=0.4207: fix_norm=1.0, branch gap=42.1%).
- 2 file(s) are within 50% of the top score (hotspot >= 0.2104); triage those first.

## Hotspots (48)
_normalized fix-churn x branch-gap; highest = most likely defect source._

| # | file | hotspot | fix_norm | branch gap | uncovered/total |
|---|------|---------|----------|-----------|-----------------|
| 1 | `src/mir/mir_lowering.rb` | 0.4207 | 1.0 | 42.1% | 414/984 |
| 2 | `src/annotator.rb` | 0.4175 | 0.745 | 56.0% | 1374/2452 |
| 3 | `src/backends/pipeline_host.rb` | 0.1737 | 0.213 | 81.5% | 662/812 |
| 4 | `src/ast/std_lib.rb` | 0.1432 | 0.157 | 90.9% | 20/22 |
| 5 | `src/mir/mir_emitter.rb` | 0.1208 | 0.271 | 44.5% | 170/382 |
| 6 | `src/annotator-helpers/fixable_helpers.rb` | 0.0985 | 0.101 | 97.3% | 319/328 |
| 7 | `src/ast/parser.rb` | 0.0817 | 0.128 | 64.0% | 684/1069 |
| 8 | `src/mir/mir_pass.rb` | 0.0783 | 0.229 | 34.3% | 123/359 |
| 9 | `src/ast/diagnostic_registry.rb` | 0.072 | 0.072 | 100.0% | 14/14 |
| 10 | `src/mir/control_flow.rb` | 0.0719 | 0.198 | 36.3% | 209/575 |
| 11 | `src/ast/ast.rb` | 0.0655 | 0.175 | 37.5% | 135/360 |
| 12 | `src/annotator-helpers/effects.rb` | 0.0627 | 0.159 | 39.4% | 142/360 |
| 13 | `src/annotator-helpers/function_analysis.rb` | 0.0623 | 0.104 | 60.0% | 270/450 |
| 14 | `src/ast/type.rb` | 0.048 | 0.138 | 34.8% | 278/800 |
| 15 | `src/backends/importer.rb` | 0.045 | 0.045 | 100.0% | 40/40 |
| 16 | `src/mir/mir.rb` | 0.0423 | 0.086 | 49.4% | 79/160 |
| 17 | `src/backends/transpiler.rb` | 0.0401 | 0.041 | 97.5% | 39/40 |
| 18 | `src/mir/escape_analysis.rb` | 0.038 | 0.122 | 31.0% | 171/551 |
| 19 | `src/mir/test_lowering.rb` | 0.0353 | 0.036 | 97.9% | 46/47 |
| 20 | `src/annotator-helpers/capabilities.rb` | 0.0287 | 0.05 | 57.6% | 315/547 |
| 21 | `src/ast/symbol_entry.rb` | 0.028 | 0.052 | 53.8% | 14/26 |
| 22 | `src/mir/mir_checker.rb` | 0.0265 | 0.069 | 38.5% | 304/790 |
| 23 | `src/mir/fiber_ctx_builder.rb` | 0.026 | 0.052 | 50.0% | 30/60 |
| 24 | `src/mir/ownership_graph.rb` | 0.0217 | 0.045 | 48.7% | 37/76 |
| 25 | `src/mir/fsm_transform/emit.rb` | 0.0177 | 0.065 | 27.2% | 53/195 |
| 26 | `src/ast/scope.rb` | 0.0163 | 0.039 | 41.3% | 26/63 |
| 27 | `src/annotator-helpers/pipe_analysis.rb` | 0.0161 | 0.019 | 82.9% | 464/560 |
| 28 | `src/mir/fsm_lowering.rb` | 0.0159 | 0.033 | 48.0% | 60/125 |
| 29 | `src/annotator-helpers/function_signature.rb` | 0.0152 | 0.033 | 46.0% | 23/50 |
| 30 | `src/backends/pipeline_rewriter.rb` | 0.0147 | 0.027 | 55.4% | 108/195 |
| 31 | `src/ast/source_error.rb` | 0.0134 | 0.017 | 80.0% | 36/45 |
| 32 | `src/mir/hoist.rb` | 0.0132 | 0.045 | 29.3% | 105/358 |
| 33 | `src/annotator-helpers/union.rb` | 0.0126 | 0.019 | 65.6% | 42/64 |
| 34 | `src/mir/bg_capture_classifier.rb` | 0.0117 | 0.032 | 37.1% | 13/35 |
| 35 | `src/mir/fsm_wrapper_emitter.rb` | 0.0106 | 0.021 | 50.6% | 44/87 |
| 36 | `src/backends/pipeline_generator.rb` | 0.0105 | 0.011 | 95.0% | 38/40 |
| 37 | `src/mir/capture_strategy.rb` | 0.0104 | 0.021 | 50.0% | 26/52 |
| 38 | `src/backends/compiler_frontend.rb` | 0.0101 | 0.03 | 33.3% | 8/24 |
| 39 | `src/mir/pre_mir_type_check.rb` | 0.0087 | 0.023 | 38.5% | 10/26 |
| 40 | `src/ast/fixable_error.rb` | 0.008 | 0.011 | 71.4% | 10/14 |

- ...(+8 more)

## Fixed But Unmeasured (57)
_files with recurring fixes but NO branch-coverage data -- recurring-fix code the corpus does not measure at all; itself a risk._

- `src/transpiler.rb` (fix_norm=0.247)
- `src/mir/promotion_plan.rb` (fix_norm=0.204)
- `src/mir/escape_graph.rb` (fix_norm=0.149)
- `src/mir_lowering.rb` (fix_norm=0.127)
- `src/tools/formatter.rb` (fix_norm=0.083)
- `src/promotion_plan.rb` (fix_norm=0.07)
- `src/ownership_generator.rb` (fix_norm=0.061)
- `src/control_flow.rb` (fix_norm=0.06)
- `src/type.rb` (fix_norm=0.059)
- `src/ast.rb` (fix_norm=0.044)
- `src/pipeline_generator.rb` (fix_norm=0.041)
- `src/tools/doctor.rb` (fix_norm=0.037)
- `src/std_lib.rb` (fix_norm=0.03)
- `src/mir_emitter.rb` (fix_norm=0.027)
- `src/mir_checker.rb` (fix_norm=0.027)
- `src/function_analysis.rb` (fix_norm=0.025)
- `src/pipeline_host.rb` (fix_norm=0.025)
- `src/tools/lint_fix_rewriter.rb` (fix_norm=0.025)
- `src/tools/fmt_verifier.rb` (fix_norm=0.024)
- `src/tools/method_rewriter.rb` (fix_norm=0.024)
- `src/alloc.rb` (fix_norm=0.021)
- `src/generic_analysis.rb` (fix_norm=0.02)
- `src/parser.rb` (fix_norm=0.019)
- `src/static_leak_checker.rb` (fix_norm=0.015)
- `src/lsp/server.rb` (fix_norm=0.014)
- `src/tools/pprof.rb` (fix_norm=0.014)
- `src/mir_pass.rb` (fix_norm=0.013)
- `src/tools/stack_verifier.rb` (fix_norm=0.013)
- `src/ast/diagnostic_buckets.rb` (fix_norm=0.012)
- `src/ast/diagnostic_examples.rb` (fix_norm=0.012)
- `src/lsp/diagnostics.rb` (fix_norm=0.012)
- `src/tools/pprof_converter.rb` (fix_norm=0.012)
- `src/pipeline_rewriter.rb` (fix_norm=0.012)
- `src/mir.rb` (fix_norm=0.01)
- `src/capabilities.rb` (fix_norm=0.01)
- `src/pipe_analysis.rb` (fix_norm=0.009)
- `src/method_analysis.rb` (fix_norm=0.008)
- `src/union.rb` (fix_norm=0.008)
- `src/effects.rb` (fix_norm=0.006)
- `src/ast/syntax_typo_scanner.rb` (fix_norm=0.006)

## Run Summary
- Repo: `/home/yahn/cheat`
- Scope: `src/`
- Fix commits matched: 908 (time span over whole history, unfiltered)
- Files ranked: 48; fixed-but-unmeasured: 57
- Branch-coverage resultset: present
- Method: vendored bugspots ([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) x SimpleCov branch gap; file granularity; zero deps (see [docs/agents/design.md](docs/agents/design.md))
