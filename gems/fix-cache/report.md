# Fix-Cache Report

> Defect-risk hotspots: recurring bug-fix locality (bugspots, time-decayed) x branch-coverage gap.
> A ranking to triage **top-down**, never a verdict. A
> hotspot is "the code most likely to be a bug source,"
> not "a bug."

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Hotspots (57)](#hotspots-57)
- [Fixed But Unmeasured (2176)](#fixed-but-unmeasured-2176)
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
| 6 | `src/mir/control_flow.rb` | 0.0569 | 0.23 | 24.7% | 170/687 |
| 7 | `src/backends/transpiler.rb` | 0.0392 | 0.071 | 55.0% | 22/40 |
| 8 | `src/mir/mir_checker.rb` | 0.0377 | 0.118 | 31.9% | 138/432 |
| 9 | `src/mir/escape_analysis.rb` | 0.0349 | 0.142 | 24.6% | 112/455 |
| 10 | `src/mir/mir_pass.rb` | 0.0349 | 0.147 | 23.8% | 100/420 |
| 11 | `src/ast/ast.rb` | 0.0348 | 0.158 | 22.0% | 47/214 |
| 12 | `src/annotator-helpers/function_analysis.rb` | 0.0347 | 0.181 | 19.2% | 89/464 |
| 13 | `src/tools/doctor.rb` | 0.0324 | 0.064 | 50.8% | 253/498 |
| 14 | `src/ast/diagnostic_registry.rb` | 0.0308 | 0.086 | 35.7% | 5/14 |
| 15 | `src/mir/mir_emitter.rb` | 0.0302 | 0.223 | 13.5% | 54/399 |
| 16 | `src/ast/parser.rb` | 0.03 | 0.187 | 16.0% | 170/1064 |
| 17 | `src/ast/type.rb` | 0.0277 | 0.165 | 16.8% | 130/774 |
| 18 | `src/mir/promotion_plan.rb` | 0.0269 | 0.104 | 25.8% | 119/461 |
| 19 | `src/annotator-helpers/capabilities.rb` | 0.0238 | 0.088 | 27.1% | 145/536 |
| 20 | `src/ast/diagnostic_buckets.rb` | 0.0213 | 0.021 | 100.0% | 8/8 |
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
| 37 | `src/ast/source_error.rb` | 0.0075 | 0.03 | 24.4% | 11/45 |
| 38 | `src/tools/pprof.rb` | 0.0071 | 0.023 | 30.4% | 14/46 |
| 39 | `src/tools/fmt_verifier.rb` | 0.0068 | 0.041 | 16.7% | 3/18 |
| 40 | `src/mir/fsm_lowering.rb` | 0.0066 | 0.023 | 28.8% | 23/80 |

- ...(+17 more)

## Fixed But Unmeasured (2176)
_files with recurring fixes but NO branch-coverage data -- recurring-fix code the corpus does not measure at all; itself a risk._

- `examples/minivm/bc_emitter.rb` (fix_norm=0.8)
- `src/transpiler.rb` (fix_norm=0.445)
- `examples/minivm/_bc_runner.cht` (fix_norm=0.315)
- `zig/runtime/scheduler.zig` (fix_norm=0.294)
- `clear` (fix_norm=0.283)
- `zig/runtime/runtime-header.zig` (fix_norm=0.268)
- `zig/lib/parking-lot.zig` (fix_norm=0.245)
- `spec/mir_lowering_spec.rb` (fix_norm=0.242)
- `zig/runtime-header.zig` (fix_norm=0.241)
- `src/mir_lowering.rb` (fix_norm=0.233)
- `spec/transpiler_spec.rb` (fix_norm=0.216)
- `spec/annotator_spec.rb` (fix_norm=0.197)
- `zig/runtime/parking-lot-loom.zig` (fix_norm=0.197)
- `zig/runtime/stream-test.zig` (fix_norm=0.195)
- `zig/parking-lot-loom-test.zig` (fix_norm=0.167)
- `spec/clear_fmt_spec.rb` (fix_norm=0.161)
- `zig/build.zig` (fix_norm=0.142)
- `spec/clear_fix_spec.rb` (fix_norm=0.139)
- `zig/runtime/queues.zig` (fix_norm=0.128)
- `src/promotion_plan.rb` (fix_norm=0.127)
- `src/mir/mir.rb` (fix_norm=0.116)
- `benchmarks/runner.rb` (fix_norm=0.111)
- `src/control_flow.rb` (fix_norm=0.109)
- `src/ownership_generator.rb` (fix_norm=0.109)
- `zig/lib/data-structures.zig` (fix_norm=0.109)
- `spec/loop_frame_analysis_spec.rb` (fix_norm=0.109)
- `src/type.rb` (fix_norm=0.107)
- `.github/workflows/ci.yml` (fix_norm=0.095)
- `spec/mir_checker_spec.rb` (fix_norm=0.094)
- `zig/runtime/spsc.zig` (fix_norm=0.086)
- `src/ast.rb` (fix_norm=0.079)
- `spec/capabilities_spec.rb` (fix_norm=0.075)
- `src/pipeline_generator.rb` (fix_norm=0.074)
- `zig/parking-lot-test.zig` (fix_norm=0.073)
- `spec/concurrency_spec.rb` (fix_norm=0.071)
- `tools/nil-kill.rb` (fix_norm=0.07)
- `zig/parking-lot-cycle-test.zig` (fix_norm=0.07)
- `spec/mir_emitter_spec.rb` (fix_norm=0.067)
- `zig/scheduler.zig` (fix_norm=0.067)
- `CLAUDE.md` (fix_norm=0.063)

## Run Summary
- Repo: `/home/yahn/cheat`
- Fix commits matched: 835
- Files ranked: 57; fixed-but-unmeasured: 2176
- Branch-coverage resultset: present
- Method: vendored bugspots (Google ICSE'13 time-decay) x SimpleCov branch gap; file granularity; zero deps (see docs/agents/design.md)
