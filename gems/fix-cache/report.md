# Fix-Cache Report

> Defect-risk hotspots: recurring bug-fix locality (bugspots, time-decayed) x branch-coverage gap.
> A ranking to triage **top-down**, never a verdict. A
> hotspot is "the code most likely to be a bug source,"
> not "a bug."

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Hotspots (57)](#hotspots-57)
- [Fixed But Unmeasured (44)](#fixed-but-unmeasured-44)
- [Run Summary](#run-summary)

## Project Prioritization
- The single highest-risk file is **`src/mir/mir_lowering.rb`** (hotspot=0.2463: fix_norm=1.0, branch gap=24.6%).
- 2 file(s) are within 50% of the top score (hotspot >= 0.1232); triage those first.

## Hotspots (57)
_normalized fix-churn x branch-gap; highest = most likely defect source._

| # | file | hotspot | fix_norm | branch gap | uncovered/total |
|---|------|---------|----------|-----------|-----------------|
| 1 | `src/mir/mir_lowering.rb` | 0.2463 | 1.0 | 24.6% | 673/2732 |
| 2 | `src/annotator.rb` | 0.1938 | 0.848 | 22.9% | 570/2494 |
| 3 | `src/ast/std_lib.rb` | 0.115 | 0.203 | 56.7% | 17/30 |
| 4 | `src/backends/pipeline_host.rb` | 0.1011 | 0.303 | 33.4% | 271/812 |
| 5 | `src/annotator-helpers/fixable_helpers.rb` | 0.0644 | 0.178 | 36.2% | 118/326 |
| 6 | `src/mir/control_flow.rb` | 0.057 | 0.23 | 24.7% | 170/687 |
| 7 | `src/backends/transpiler.rb` | 0.0393 | 0.071 | 55.0% | 22/40 |
| 8 | `src/mir/mir_checker.rb` | 0.0377 | 0.118 | 31.9% | 138/432 |
| 9 | `src/mir/escape_analysis.rb` | 0.035 | 0.142 | 24.6% | 112/455 |
| 10 | `src/mir/mir_pass.rb` | 0.0349 | 0.147 | 23.8% | 100/420 |
| 11 | `src/ast/ast.rb` | 0.0348 | 0.158 | 22.0% | 47/214 |
| 12 | `src/annotator-helpers/function_analysis.rb` | 0.0347 | 0.181 | 19.2% | 89/464 |
| 13 | `src/tools/doctor.rb` | 0.0324 | 0.064 | 50.8% | 253/498 |
| 14 | `src/ast/diagnostic_registry.rb` | 0.0308 | 0.086 | 35.7% | 5/14 |
| 15 | `src/mir/mir_emitter.rb` | 0.0302 | 0.223 | 13.5% | 54/399 |
| 16 | `src/ast/parser.rb` | 0.03 | 0.188 | 16.0% | 170/1064 |
| 17 | `src/ast/type.rb` | 0.0277 | 0.165 | 16.8% | 130/774 |
| 18 | `src/mir/promotion_plan.rb` | 0.0269 | 0.104 | 25.8% | 119/461 |
| 19 | `src/annotator-helpers/capabilities.rb` | 0.0238 | 0.088 | 27.1% | 145/536 |
| 20 | `src/ast/diagnostic_buckets.rb` | 0.0214 | 0.021 | 100.0% | 8/8 |
| 21 | `src/mir/bg_capture_classifier.rb` | 0.0179 | 0.055 | 32.6% | 14/43 |
| 22 | `src/ast/scope.rb` | 0.0165 | 0.067 | 24.6% | 16/65 |
| 23 | `src/mir/ownership_graph.rb` | 0.0161 | 0.077 | 21.1% | 16/76 |
| 24 | `src/mir/fsm_transform/emit.rb` | 0.0156 | 0.079 | 19.7% | 36/183 |
| 25 | `src/annotator-helpers/pipe_analysis.rb` | 0.0122 | 0.034 | 35.7% | 212/594 |
| 26 | `src/ast/fixable_error.rb` | 0.0116 | 0.02 | 57.1% | 8/14 |
| 27 | `src/tools/formatter.rb` | 0.0114 | 0.143 | 8.0% | 77/962 |
| 28 | `src/annotator-helpers/function_signature.rb` | 0.011 | 0.022 | 50.0% | 9/18 |
| 29 | `src/annotator-helpers/effects.rb` | 0.0106 | 0.064 | 16.5% | 56/339 |
| 30 | `src/tools/pprof_converter.rb` | 0.0097 | 0.021 | 45.7% | 42/92 |
| 31 | `src/tools/method_rewriter.rb` | 0.009 | 0.041 | 22.0% | 28/127 |
| 32 | `src/mir/fsm_wrapper_emitter.rb` | 0.0089 | 0.037 | 24.1% | 21/87 |
| 33 | `src/mir/capture_strategy.rb` | 0.0081 | 0.036 | 22.4% | 13/58 |
| 34 | `src/mir/fsm_transform/recursive_splitter.rb` | 0.008 | 0.023 | 34.7% | 52/150 |
| 35 | `src/tools/lint_fix_rewriter.rb` | 0.008 | 0.042 | 18.9% | 24/127 |
| 36 | `src/mir/fiber_ctx_builder.rb` | 0.0077 | 0.056 | 13.6% | 3/22 |
| 37 | `src/ast/source_error.rb` | 0.0074 | 0.03 | 24.4% | 11/45 |
| 38 | `src/tools/pprof.rb` | 0.0071 | 0.023 | 30.4% | 14/46 |
| 39 | `src/tools/fmt_verifier.rb` | 0.0068 | 0.041 | 16.7% | 3/18 |
| 40 | `src/mir/fsm_lowering.rb` | 0.0067 | 0.023 | 28.8% | 23/80 |

- ...(+17 more)

## Fixed But Unmeasured (44)
_files with recurring fixes but NO branch-coverage data -- recurring-fix code the corpus does not measure at all; itself a risk._

- `src/transpiler.rb` (fix_norm=0.444)
- `src/mir_lowering.rb` (fix_norm=0.232)
- `src/promotion_plan.rb` (fix_norm=0.127)
- `src/mir/mir.rb` (fix_norm=0.116)
- `src/control_flow.rb` (fix_norm=0.109)
- `src/ownership_generator.rb` (fix_norm=0.109)
- `src/type.rb` (fix_norm=0.107)
- `src/ast.rb` (fix_norm=0.079)
- `src/pipeline_generator.rb` (fix_norm=0.074)
- `src/std_lib.rb` (fix_norm=0.053)
- `src/mir_emitter.rb` (fix_norm=0.05)
- `src/mir_checker.rb` (fix_norm=0.049)
- `src/pipeline_host.rb` (fix_norm=0.045)
- `src/function_analysis.rb` (fix_norm=0.045)
- `src/alloc.rb` (fix_norm=0.037)
- `src/generic_analysis.rb` (fix_norm=0.036)
- `src/parser.rb` (fix_norm=0.034)
- `src/static_leak_checker.rb` (fix_norm=0.028)
- `src/mir_pass.rb` (fix_norm=0.024)
- `src/annotator-helpers/function_context.rb` (fix_norm=0.023)
- `src/pipeline_rewriter.rb` (fix_norm=0.021)
- `src/mir.rb` (fix_norm=0.019)
- `src/capabilities.rb` (fix_norm=0.017)
- `src/pipe_analysis.rb` (fix_norm=0.017)
- `src/method_analysis.rb` (fix_norm=0.014)
- `src/union.rb` (fix_norm=0.014)
- `src/effects.rb` (fix_norm=0.011)
- `src/stack_verifier.rb` (fix_norm=0.009)
- `src/ownership_graph.rb` (fix_norm=0.008)
- `src/lexer.rb` (fix_norm=0.007)
- `src/importer.rb` (fix_norm=0.007)
- `src/escape_analysis.rb` (fix_norm=0.006)
- `src/compiler_frontend.rb` (fix_norm=0.006)
- `src/symbol_entry.rb` (fix_norm=0.005)
- `src/zig_type_mapper.rb` (fix_norm=0.004)
- `src/string_concat_rewriter.rb` (fix_norm=0.004)
- `src/ownership_tracker.rb` (fix_norm=0.002)
- `src/scope.rb` (fix_norm=0.002)
- `src/compiler.rb` (fix_norm=0.0)
- `src/source_error.rb` (fix_norm=0.0)

## Run Summary
- Repo: `/home/yahn/cheat`
- Scope: `src/`
- Fix commits matched: 836 (time span over whole history, unfiltered)
- Files ranked: 57; fixed-but-unmeasured: 44
- Branch-coverage resultset: present
- Method: vendored bugspots ([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) x SimpleCov branch gap; file granularity; zero deps (see [docs/agents/design.md](docs/agents/design.md))
