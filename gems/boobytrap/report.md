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
- The single highest-risk file is **`src/mir/mir_lowering.rb`** (hotspot=0.1606: fix_norm=1.0, branch gap=16.1%).
- 2 file(s) are within 50% of the top score (hotspot >= 0.0803); triage those first.

## Hotspots (56)
_normalized fix-churn x branch-gap; highest = most likely defect source._

| # | file | hotspot | fix_norm | branch gap | uncovered/total |
|---|------|---------|----------|-----------|-----------------|
| 1 | `src/mir/mir_lowering.rb` | 0.1606 | 1.0 | 16.1% | 163/1015 |
| 2 | `src/ast/std_lib.rb` | 0.0868 | 0.191 | 45.5% | 10/22 |
| 3 | `src/backends/pipeline_host.rb` | 0.0728 | 0.266 | 27.4% | 219/800 |
| 4 | `src/mir/mir_pass.rb` | 0.0646 | 0.257 | 25.2% | 76/302 |
| 5 | `src/mir/mir_emitter.rb` | 0.0474 | 0.27 | 17.5% | 70/399 |
| 6 | `src/mir/mir.rb` | 0.047 | 0.154 | 30.6% | 82/268 |
| 7 | `src/mir/control_flow.rb` | 0.0431 | 0.204 | 21.2% | 97/458 |
| 8 | `src/ast/ast.rb` | 0.0416 | 0.157 | 26.4% | 107/405 |
| 9 | `src/mir/hoist.rb` | 0.0391 | 0.144 | 27.1% | 134/494 |
| 10 | `src/mir/fsm_lowering.rb` | 0.0381 | 0.082 | 46.8% | 72/154 |
| 11 | `src/ast/diagnostic_registry.rb` | 0.0322 | 0.09 | 35.7% | 5/14 |
| 12 | `src/ast/type.rb` | 0.029 | 0.174 | 16.6% | 136/818 |
| 13 | `src/mir/escape_analysis.rb` | 0.0249 | 0.134 | 18.5% | 99/535 |
| 14 | `src/tools/doctor.rb` | 0.0233 | 0.033 | 70.5% | 351/498 |
| 15 | `src/mir/fsm_transform/emit.rb` | 0.0213 | 0.084 | 25.3% | 64/253 |
| 16 | `src/mir/mir_checker.rb` | 0.0202 | 0.087 | 23.3% | 182/782 |
| 17 | `src/ast/parser.rb` | 0.0195 | 0.114 | 17.1% | 183/1069 |
| 18 | `src/backends/transpiler.rb` | 0.0192 | 0.036 | 52.5% | 21/40 |
| 19 | `src/annotator/helpers/method_analysis.rb` | 0.0174 | 0.05 | 34.6% | 36/104 |
| 20 | `src/mir/bg_capture_classifier.rb` | 0.0174 | 0.054 | 32.4% | 12/37 |
| 21 | `src/mir/cleanup_classifier.rb` | 0.0147 | 0.05 | 29.2% | 170/582 |
| 22 | `src/ast/symbol_entry.rb` | 0.0144 | 0.047 | 30.8% | 8/26 |
| 23 | `src/mir/lowering/expressions.rb` | 0.0138 | 0.05 | 27.5% | 171/622 |
| 24 | `src/mir/lowering/functions.rb` | 0.0138 | 0.05 | 27.4% | 181/661 |
| 25 | `src/mir/fsm_transform/suspend_resolvers.rb` | 0.0134 | 0.034 | 38.8% | 19/49 |
| 26 | `src/mir/lowering/capabilities.rb` | 0.0114 | 0.052 | 22.1% | 57/258 |
| 27 | `src/annotator/helpers/function_analysis.rb` | 0.0113 | 0.05 | 22.4% | 100/446 |
| 28 | `src/ast/diagnostic_buckets.rb` | 0.0111 | 0.011 | 100.0% | 8/8 |
| 29 | `src/mir/fiber_ctx_builder.rb` | 0.0109 | 0.046 | 23.5% | 16/68 |
| 30 | `src/ast/scope.rb` | 0.0089 | 0.035 | 25.4% | 16/63 |
| 31 | `src/mir/ownership_graph.rb` | 0.0089 | 0.04 | 22.4% | 17/76 |
| 32 | `src/mir/lowering/variables.rb` | 0.0088 | 0.05 | 17.6% | 79/450 |
| 33 | `src/mir/pre_mir_type_check.rb` | 0.008 | 0.021 | 38.5% | 10/26 |
| 34 | `src/annotator/helpers/capabilities.rb` | 0.0069 | 0.025 | 28.1% | 154/549 |
| 35 | `src/mir/lowering/concurrency.rb` | 0.0066 | 0.052 | 12.8% | 29/226 |
| 36 | `src/mir/lowering/control_flow.rb` | 0.0063 | 0.026 | 24.5% | 87/355 |
| 37 | `src/annotator/annotator.rb` | 0.0059 | 0.025 | 23.9% | 576/2411 |
| 38 | `src/backends/pipeline_rewriter.rb` | 0.0059 | 0.024 | 24.6% | 45/183 |
| 39 | `src/mir/capture_strategy.rb` | 0.0059 | 0.018 | 31.7% | 19/60 |
| 40 | `src/mir/test_lowering.rb` | 0.0056 | 0.033 | 17.0% | 8/47 |
| 41 | `src/ast/fixable_error.rb` | 0.0056 | 0.01 | 57.1% | 8/14 |
| 42 | `src/mir/lowering/literals.rb` | 0.0054 | 0.026 | 21.2% | 11/52 |
| 43 | `src/mir/fsm_wrapper_emitter.rb` | 0.0045 | 0.019 | 24.1% | 21/87 |
| 44 | `src/mir/fsm_transform/recursive_splitter.rb` | 0.0042 | 0.012 | 34.6% | 46/133 |
| 45 | `src/annotator/helpers/generic_analysis.rb` | 0.0041 | 0.026 | 16.2% | 42/260 |
| 46 | `src/backends/importer.rb` | 0.004 | 0.04 | 10.0% | 4/40 |
| 47 | `src/ast/source_error.rb` | 0.0036 | 0.015 | 24.4% | 11/45 |
| 48 | `src/lsp/diagnostics.rb` | 0.0029 | 0.011 | 26.2% | 11/42 |
| 49 | `src/ast/diagnostic_examples.rb` | 0.0028 | 0.011 | 25.7% | 9/35 |
| 50 | `src/backends/pipeline_generator.rb` | 0.0025 | 0.01 | 25.0% | 10/40 |
| 51 | `src/backends/compiler_frontend.rb` | 0.0022 | 0.027 | 8.3% | 2/24 |
| 52 | `src/mir/fsm_transform/liveness.rb` | 0.0016 | 0.01 | 15.9% | 10/63 |
| 53 | `src/ast/lexer.rb` | 0.0008 | 0.005 | 17.5% | 20/114 |
| 54 | `src/lsp/server.rb` | 0.0004 | 0.012 | 3.0% | 1/33 |
| 55 | `src/mir/cleanup_entry.rb` | 0.0 | 0.02 | 0.0% | 0/4 |
| 56 | `src/ast/syntax_typo_scanner.rb` | 0.0 | 0.005 | 0.0% | 0/28 |

## Fixed But Unmeasured (8)
_files with recurring fixes but NO branch-coverage data -- recurring-fix code the corpus does not measure at all; itself a risk._

- `src/annotator.rb` (fix_norm=0.668)
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
- Fix commits matched: 916 (time span over whole history, unfiltered)
- Files ranked: 56; fixed-but-unmeasured: 8
- Branch-coverage resultset: present
- Method: vendored bugspots ([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) x SimpleCov branch gap; file granularity; zero deps (see [docs/agents/design.md](docs/agents/design.md))
