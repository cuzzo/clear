# Boobytrap Report

> Defect-risk hotspots: recurring bug-fix locality (bugspots, time-decayed) x branch-coverage gap.
> A ranking to triage **top-down**, never a verdict. A
> hotspot is "the code most likely to be a bug source,"
> not "a bug."

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Hotspots (62)](#hotspots-62)
- [Fixed But Unmeasured (2198)](#fixed-but-unmeasured-2198)
- [Run Summary](#run-summary)

## Project Prioritization
- The single highest-risk file is **`src/mir/mir_lowering.rb`** (hotspot=0.239: fix_norm=1.0, branch gap=23.9%).
- 2 file(s) are within 50% of the top score (hotspot >= 0.1195); triage those first.

## Hotspots (62)
_normalized fix-churn x branch-gap; highest = most likely defect source._

| # | file | hotspot | fix_norm | branch gap | uncovered/total |
|---|------|---------|----------|-----------|-----------------|
| 1 | `src/mir/mir_lowering.rb` | 0.239 | 1.0 | 23.9% | 653/2732 |
| 2 | `src/annotator.rb` | 0.2001 | 0.875 | 22.9% | 570/2494 |
| 3 | `src/ast/std_lib.rb` | 0.1149 | 0.203 | 56.7% | 17/30 |
| 4 | `src/backends/pipeline_host.rb` | 0.0736 | 0.302 | 24.4% | 198/812 |
| 5 | `src/annotator-helpers/fixable_helpers.rb` | 0.0644 | 0.178 | 36.2% | 118/326 |
| 6 | `src/mir/control_flow.rb` | 0.0574 | 0.232 | 24.7% | 170/687 |
| 7 | `src/backends/transpiler.rb` | 0.0393 | 0.071 | 55.0% | 22/40 |
| 8 | `src/mir/mir_checker.rb` | 0.0378 | 0.118 | 31.9% | 138/432 |
| 9 | `src/mir/escape_analysis.rb` | 0.0351 | 0.143 | 24.6% | 112/455 |
| 10 | `src/mir/mir_pass.rb` | 0.0349 | 0.147 | 23.8% | 100/420 |
| 11 | `src/ast/ast.rb` | 0.0348 | 0.159 | 22.0% | 47/214 |
| 12 | `src/annotator-helpers/function_analysis.rb` | 0.0347 | 0.181 | 19.2% | 89/464 |
| 13 | `src/tools/doctor.rb` | 0.0325 | 0.064 | 50.8% | 253/498 |
| 14 | `src/ast/diagnostic_registry.rb` | 0.0309 | 0.086 | 35.7% | 5/14 |
| 15 | `src/mir/mir_emitter.rb` | 0.0303 | 0.224 | 13.5% | 54/399 |
| 16 | `src/ast/parser.rb` | 0.03 | 0.188 | 16.0% | 170/1064 |
| 17 | `tools/fuzz/templates/loop_local_method_temp.rb` | 0.028 | 0.028 | 100.0% | 15/15 |
| 18 | `src/ast/type.rb` | 0.0278 | 0.166 | 16.8% | 130/774 |
| 19 | `src/mir/promotion_plan.rb` | 0.0268 | 0.104 | 25.8% | 119/461 |
| 20 | `tools/fuzz/templates/cond_or_fallback.rb` | 0.026 | 0.028 | 92.9% | 26/28 |
| 21 | `src/annotator-helpers/capabilities.rb` | 0.0237 | 0.088 | 27.1% | 145/536 |
| 22 | `tools/fuzz/templates/promise_handle_capture.rb` | 0.0233 | 0.023 | 100.0% | 5/5 |
| 23 | `tools/fuzz/templates/lifetimed_return.rb` | 0.0218 | 0.023 | 93.9% | 31/33 |
| 24 | `src/ast/diagnostic_buckets.rb` | 0.0214 | 0.021 | 100.0% | 8/8 |
| 25 | `tools/fuzz/templates/stream_into_boundary.rb` | 0.0213 | 0.023 | 91.5% | 43/47 |
| 26 | `src/mir/bg_capture_classifier.rb` | 0.0179 | 0.055 | 32.6% | 14/43 |
| 27 | `src/ast/scope.rb` | 0.0166 | 0.067 | 24.6% | 16/65 |
| 28 | `src/mir/ownership_graph.rb` | 0.0162 | 0.077 | 21.1% | 16/76 |
| 29 | `src/mir/fsm_transform/emit.rb` | 0.0156 | 0.079 | 19.7% | 36/183 |
| 30 | `src/annotator-helpers/pipe_analysis.rb` | 0.0122 | 0.034 | 35.7% | 212/594 |
| 31 | `src/tools/formatter.rb` | 0.0115 | 0.143 | 8.0% | 77/962 |
| 32 | `src/ast/fixable_error.rb` | 0.0115 | 0.02 | 57.1% | 8/14 |
| 33 | `src/annotator-helpers/function_signature.rb` | 0.011 | 0.022 | 50.0% | 9/18 |
| 34 | `src/annotator-helpers/effects.rb` | 0.0106 | 0.064 | 16.5% | 56/339 |
| 35 | `src/tools/pprof_converter.rb` | 0.0098 | 0.021 | 45.7% | 42/92 |
| 36 | `src/tools/method_rewriter.rb` | 0.009 | 0.041 | 22.0% | 28/127 |
| 37 | `src/mir/fsm_wrapper_emitter.rb` | 0.0089 | 0.037 | 24.1% | 21/87 |
| 38 | `src/mir/capture_strategy.rb` | 0.0081 | 0.036 | 22.4% | 13/58 |
| 39 | `src/mir/fsm_transform/recursive_splitter.rb` | 0.0081 | 0.023 | 34.7% | 52/150 |
| 40 | `src/tools/lint_fix_rewriter.rb` | 0.008 | 0.042 | 18.9% | 24/127 |

- ...(+22 more)

## Fixed But Unmeasured (2198)
_files with recurring fixes but NO branch-coverage data -- recurring-fix code the corpus does not measure at all; itself a risk._

- `examples/minivm/bc_emitter.rb` (fix_norm=0.795)
- `src/transpiler.rb` (fix_norm=0.441)
- `examples/minivm/_bc_runner.cht` (fix_norm=0.314)
- `zig/runtime/scheduler.zig` (fix_norm=0.294)
- `clear` (fix_norm=0.282)
- `zig/runtime/runtime-header.zig` (fix_norm=0.268)
- `zig/lib/parking-lot.zig` (fix_norm=0.245)
- `spec/mir_lowering_spec.rb` (fix_norm=0.241)
- `zig/runtime-header.zig` (fix_norm=0.239)
- `src/mir_lowering.rb` (fix_norm=0.23)
- `spec/transpiler_spec.rb` (fix_norm=0.215)
- `zig/runtime/parking-lot-loom.zig` (fix_norm=0.197)
- `spec/annotator_spec.rb` (fix_norm=0.196)
- `zig/runtime/stream-test.zig` (fix_norm=0.195)
- `zig/parking-lot-loom-test.zig` (fix_norm=0.167)
- `spec/clear_fmt_spec.rb` (fix_norm=0.162)
- `zig/build.zig` (fix_norm=0.142)
- `spec/clear_fix_spec.rb` (fix_norm=0.137)
- `zig/runtime/queues.zig` (fix_norm=0.128)
- `src/promotion_plan.rb` (fix_norm=0.126)
- `src/mir/mir.rb` (fix_norm=0.116)
- `benchmarks/runner.rb` (fix_norm=0.111)
- `spec/loop_frame_analysis_spec.rb` (fix_norm=0.109)
- `zig/lib/data-structures.zig` (fix_norm=0.108)
- `src/ownership_generator.rb` (fix_norm=0.108)
- `src/control_flow.rb` (fix_norm=0.108)
- `src/type.rb` (fix_norm=0.106)
- `.github/workflows/ci.yml` (fix_norm=0.095)
- `spec/mir_checker_spec.rb` (fix_norm=0.094)
- `zig/runtime/spsc.zig` (fix_norm=0.087)
- `src/ast.rb` (fix_norm=0.079)
- `spec/capabilities_spec.rb` (fix_norm=0.074)
- `src/pipeline_generator.rb` (fix_norm=0.073)
- `zig/parking-lot-test.zig` (fix_norm=0.073)
- `spec/concurrency_spec.rb` (fix_norm=0.071)
- `tools/nil-kill.rb` (fix_norm=0.07)
- `zig/parking-lot-cycle-test.zig` (fix_norm=0.069)
- `spec/mir_emitter_spec.rb` (fix_norm=0.067)
- `zig/scheduler.zig` (fix_norm=0.066)
- `CLAUDE.md` (fix_norm=0.063)

## Run Summary
- Repo: `/home/yahn/cheat`
- Scope: whole repo
- Fix commits matched: 842 (time span over whole history, unfiltered)
- Files ranked: 62; fixed-but-unmeasured: 2198
- Branch-coverage resultset: present
- Method: vendored bugspots ([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) x SimpleCov branch gap; file granularity; zero deps (see [docs/agents/design.md](docs/agents/design.md))
