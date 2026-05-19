# Boobytrap Report

> Defect-risk hotspots: recurring bug-fix locality (bugspots, time-decayed) x branch-coverage gap.
> A ranking to triage **top-down**, never a verdict. A
> hotspot is "the code most likely to be a bug source,"
> not "a bug."

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Hotspots (65)](#hotspots-65)
- [Fixed But Unmeasured (2342)](#fixed-but-unmeasured-2342)
- [Run Summary](#run-summary)

## Project Prioritization
- The single highest-risk file is **`src/mir/mir_lowering.rb`** (hotspot=0.3181: fix_norm=1.0, branch gap=31.8%).
- 2 file(s) are within 50% of the top score (hotspot >= 0.1591); triage those first.

## Hotspots (65)
_normalized fix-churn x branch-gap; highest = most likely defect source._

| # | file | hotspot | fix_norm | branch gap | uncovered/total |
|---|------|---------|----------|-----------|-----------------|
| 1 | `src/mir/mir_lowering.rb` | 0.3181 | 1.0 | 31.8% | 2842/8934 |
| 2 | `src/annotator.rb` | 0.2415 | 0.772 | 31.3% | 1538/4920 |
| 3 | `src/ast/std_lib.rb` | 0.1042 | 0.187 | 55.8% | 29/52 |
| 4 | `src/backends/pipeline_host.rb` | 0.073 | 0.239 | 30.5% | 421/1381 |
| 5 | `src/mir/control_flow.rb` | 0.0726 | 0.237 | 30.6% | 385/1257 |
| 6 | `src/annotator-helpers/fixable_helpers.rb` | 0.059 | 0.141 | 41.8% | 152/364 |
| 7 | `src/mir/mir_emitter.rb` | 0.0483 | 0.255 | 19.0% | 158/833 |
| 8 | `src/ast/diagnostic_registry.rb` | 0.0469 | 0.069 | 67.9% | 19/28 |
| 9 | `src/mir/mir_pass.rb` | 0.0457 | 0.193 | 23.6% | 207/876 |
| 10 | `src/annotator-helpers/function_analysis.rb` | 0.0427 | 0.144 | 29.6% | 264/892 |
| 11 | `src/ast/parser.rb` | 0.0419 | 0.175 | 23.9% | 505/2112 |
| 12 | `src/ast/ast.rb` | 0.0409 | 0.151 | 27.1% | 134/494 |
| 13 | `src/mir/mir_checker.rb` | 0.0386 | 0.095 | 40.7% | 348/854 |
| 14 | `src/mir/escape_analysis.rb` | 0.0385 | 0.139 | 27.6% | 186/674 |
| 15 | `src/mir/promotion_plan.rb` | 0.0338 | 0.133 | 25.4% | 205/808 |
| 16 | `src/ast/type.rb` | 0.0329 | 0.158 | 20.8% | 317/1524 |
| 17 | `src/backends/transpiler.rb` | 0.0313 | 0.057 | 55.0% | 22/40 |
| 18 | `src/tools/doctor.rb` | 0.026 | 0.051 | 50.8% | 253/498 |
| 19 | `tools/fuzz/templates/ownership_surface_smoke.rb` | 0.0244 | 0.025 | 95.9% | 47/49 |
| 20 | `tools/fuzz/templates/loop_local_method_temp.rb` | 0.0227 | 0.023 | 100.0% | 15/15 |
| 21 | `src/annotator-helpers/capabilities.rb` | 0.0223 | 0.07 | 31.9% | 300/939 |
| 22 | `src/mir/ownership_graph.rb` | 0.0222 | 0.061 | 36.2% | 55/152 |
| 23 | `tools/fuzz/templates/cond_or_fallback.rb` | 0.0211 | 0.023 | 92.9% | 26/28 |
| 24 | `tools/fuzz/templates/promise_handle_capture.rb` | 0.0187 | 0.019 | 100.0% | 5/5 |
| 25 | `src/mir/fsm_transform/emit.rb` | 0.0181 | 0.089 | 20.4% | 57/280 |
| 26 | `tools/fuzz/templates/lifetimed_return.rb` | 0.0175 | 0.019 | 93.9% | 31/33 |
| 27 | `src/ast/diagnostic_buckets.rb` | 0.0171 | 0.017 | 100.0% | 8/8 |
| 28 | `src/annotator-helpers/effects.rb` | 0.0164 | 0.077 | 21.4% | 128/599 |
| 29 | `src/ast/symbol_entry.rb` | 0.0153 | 0.042 | 36.7% | 11/30 |
| 30 | `src/ast/scope.rb` | 0.0148 | 0.054 | 27.3% | 35/128 |
| 31 | `src/mir/bg_capture_classifier.rb` | 0.0143 | 0.044 | 32.6% | 14/43 |
| 32 | `src/mir/fsm_lowering.rb` | 0.0129 | 0.044 | 29.2% | 35/120 |
| 33 | `src/annotator-helpers/pipe_analysis.rb` | 0.0108 | 0.027 | 39.8% | 456/1146 |
| 34 | `src/mir/fiber_ctx_builder.rb` | 0.0096 | 0.071 | 13.6% | 3/22 |
| 35 | `src/annotator-helpers/function_context.rb` | 0.0094 | 0.019 | 50.0% | 2/4 |
| 36 | `src/tools/formatter.rb` | 0.0092 | 0.114 | 8.0% | 77/962 |
| 37 | `src/ast/fixable_error.rb` | 0.0091 | 0.016 | 57.1% | 8/14 |
| 38 | `src/backends/importer.rb` | 0.009 | 0.061 | 14.9% | 7/47 |
| 39 | `src/annotator-helpers/function_signature.rb` | 0.0084 | 0.018 | 47.6% | 20/42 |
| 40 | `src/backends/pipeline_rewriter.rb` | 0.0078 | 0.036 | 22.1% | 77/349 |

- ...(+25 more)

## Fixed But Unmeasured (2342)
_files with recurring fixes but NO branch-coverage data -- recurring-fix code the corpus does not measure at all; itself a risk._

- `examples/minivm/bc_emitter.rb` (fix_norm=0.68)
- `src/transpiler.rb` (fix_norm=0.348)
- `zig/runtime/runtime-header.zig` (fix_norm=0.264)
- `examples/minivm/_bc_runner.cht` (fix_norm=0.248)
- `zig/runtime/scheduler.zig` (fix_norm=0.234)
- `clear` (fix_norm=0.223)
- `spec/transpiler_spec.rb` (fix_norm=0.195)
- `zig/lib/parking-lot.zig` (fix_norm=0.194)
- `spec/mir_lowering_spec.rb` (fix_norm=0.192)
- `zig/runtime-header.zig` (fix_norm=0.188)
- `src/mir_lowering.rb` (fix_norm=0.181)
- `docs/agents/vm-bugs.md` (fix_norm=0.179)
- `spec/loop_frame_analysis_spec.rb` (fix_norm=0.163)
- `zig/runtime/parking-lot-loom.zig` (fix_norm=0.157)
- `zig/runtime/stream-test.zig` (fix_norm=0.155)
- `spec/annotator_spec.rb` (fix_norm=0.155)
- `zig/parking-lot-loom-test.zig` (fix_norm=0.133)
- `spec/clear_fmt_spec.rb` (fix_norm=0.129)
- `examples/minivm/register_bc_emitter.rb` (fix_norm=0.128)
- `src/mir/mir.rb` (fix_norm=0.118)
- `zig/build.zig` (fix_norm=0.112)
- `spec/clear_fix_spec.rb` (fix_norm=0.108)
- `examples/minivm/docs/agents/compiler-bug-root-causes.md` (fix_norm=0.102)
- `examples/minivm/docs/agents/stack-vm-fiber-replication.md` (fix_norm=0.102)
- `zig/runtime/queues.zig` (fix_norm=0.102)
- `src/promotion_plan.rb` (fix_norm=0.099)
- `benchmarks/runner.rb` (fix_norm=0.087)
- `zig/lib/data-structures.zig` (fix_norm=0.086)
- `src/ownership_generator.rb` (fix_norm=0.085)
- `src/control_flow.rb` (fix_norm=0.085)
- `src/type.rb` (fix_norm=0.083)
- `spec/mir_emitter_spec.rb` (fix_norm=0.079)
- `transpile-tests/known-failing/README.md` (fix_norm=0.077)
- `.github/workflows/ci.yml` (fix_norm=0.076)
- `spec/mir_checker_spec.rb` (fix_norm=0.074)
- `zig/runtime/cleanup-test.zig` (fix_norm=0.071)
- `sorbet/rbi/clear-attr-accessors.rbi` (fix_norm=0.07)
- `zig/runtime/spsc.zig` (fix_norm=0.069)
- `zig/lib/partitioned-map-test.zig` (fix_norm=0.069)
- `spec/cleanup_plan_spec.rb` (fix_norm=0.064)

## Run Summary
- Repo: `/home/yahn/cheat`
- Scope: whole repo
- Fix commits matched: 869 (time span over whole history, unfiltered)
- Files ranked: 65; fixed-but-unmeasured: 2342
- Branch-coverage resultset: present
- Method: vendored bugspots ([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) x SimpleCov branch gap; file granularity; zero deps (see [docs/agents/design.md](docs/agents/design.md))
