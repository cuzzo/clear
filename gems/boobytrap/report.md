# Boobytrap Report

> Defect-risk hotspots: recurring bug-fix locality (bugspots, time-decayed) x branch-coverage gap.
> A ranking to triage **top-down**, never a verdict. A
> hotspot is "the code most likely to be a bug source,"
> not "a bug."

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Hotspots (79)](#hotspots-79)
- [Fixed But Unmeasured (779)](#fixed-but-unmeasured-779)
- [Run Summary](#run-summary)

## Project Prioritization
- The single highest-risk file is **`src/mir/mir_lowering.rb`** (hotspot=0.1498: fix_norm=1.0, branch gap=15.0%).
- 2 file(s) are within 50% of the top score (hotspot >= 0.0749); triage those first.

## Hotspots (79)
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
| 27 | `tools/fuzz/templates/takes_move_modality.rb` | 0.0103 | 0.093 | 11.1% | 1/9 |
| 28 | `src/mir/fiber_ctx_builder.rb` | 0.0102 | 0.046 | 22.1% | 15/68 |
| 29 | `src/annotator/helpers/function_analysis.rb` | 0.0092 | 0.051 | 18.0% | 79/438 |
| 30 | `src/mir/ownership_graph.rb` | 0.0088 | 0.039 | 22.4% | 17/76 |
| 31 | `src/annotator/helpers/method_analysis.rb` | 0.0087 | 0.051 | 17.2% | 11/64 |
| 32 | `src/mir/lowering/variables.rb` | 0.0087 | 0.051 | 17.1% | 77/450 |
| 33 | `tools/fuzz/templates/collection_sink_escape_matrix.rb` | 0.0083 | 0.025 | 33.3% | 7/21 |
| 34 | `src/ast/scope.rb` | 0.0083 | 0.035 | 23.8% | 15/63 |
| 35 | `src/mir/pre_mir_type_check.rb` | 0.0081 | 0.021 | 38.5% | 10/26 |
| 36 | `tools/fuzz/templates/infallible_signature.rb` | 0.0077 | 0.056 | 13.8% | 4/29 |
| 37 | `tools/fuzz/templates/ownership_surface_smoke.rb` | 0.0068 | 0.036 | 18.8% | 9/48 |
| 38 | `tools/fuzz/templates/list_append_modality.rb` | 0.0063 | 0.038 | 16.7% | 1/6 |
| 39 | `src/mir/lowering/control_flow.rb` | 0.0062 | 0.026 | 23.9% | 85/355 |
| 40 | `src/backends/pipeline_rewriter.rb` | 0.0059 | 0.024 | 24.6% | 45/183 |

- ...(+39 more)

## Fixed But Unmeasured (779)
_files with recurring fixes but NO branch-coverage data -- recurring-fix code the corpus does not measure at all; itself a risk._

- `src/annotator.rb` (fix_norm=0.667)
- `examples/minivm/bc_emitter.rb` (fix_norm=0.475)
- `zig/runtime/runtime-header.zig` (fix_norm=0.298)
- `spec/mir_lowering_spec.rb` (fix_norm=0.209)
- `sorbet/rbi/clear-attr-accessors.rbi` (fix_norm=0.197)
- `spec/transpiler_spec.rb` (fix_norm=0.175)
- `examples/minivm/_bc_runner.cht` (fix_norm=0.154)
- `zig/runtime/scheduler.zig` (fix_norm=0.147)
- `clear` (fix_norm=0.14)
- `spec/annotator_spec.rb` (fix_norm=0.135)
- `zig/runtime/stream-test.zig` (fix_norm=0.125)
- `docs/agents/vm-bugs.md` (fix_norm=0.124)
- `zig/lib/parking-lot.zig` (fix_norm=0.122)
- `spec/loop_frame_analysis_spec.rb` (fix_norm=0.109)
- `zig/runtime/parking-lot-loom.zig` (fix_norm=0.099)
- `zig/lib/data-structures.zig` (fix_norm=0.098)
- `examples/minivm/register_bc_emitter.rb` (fix_norm=0.089)
- `zig/parking-lot-loom-test.zig` (fix_norm=0.085)
- `spec/clear_fmt_spec.rb` (fix_norm=0.083)
- `spec/generics_spec.rb` (fix_norm=0.082)
- `.github/workflows/ci.yml` (fix_norm=0.075)
- `src/tools/formatter.rb` (fix_norm=0.073)
- `spec/mir_checker_spec.rb` (fix_norm=0.072)
- `transpile-tests/known-failing/README.md` (fix_norm=0.072)
- `spec/mir_emitter_spec.rb` (fix_norm=0.072)
- `examples/minivm/docs/agents/compiler-bug-root-causes.md` (fix_norm=0.071)
- `examples/minivm/docs/agents/stack-vm-fiber-replication.md` (fix_norm=0.071)
- `zig/build.zig` (fix_norm=0.07)
- `tools/fuzz/README.md` (fix_norm=0.068)
- `spec/clear_fix_spec.rb` (fix_norm=0.067)
- `zig/runtime/cleanup-test.zig` (fix_norm=0.066)
- `zig/runtime/queues.zig` (fix_norm=0.064)
- `tools/bc_lower_coverage.rb` (fix_norm=0.064)
- `spec/concurrency_spec.rb` (fix_norm=0.062)
- `spec/cleanup_plan_spec.rb` (fix_norm=0.061)
- `CLAUDE.md` (fix_norm=0.059)
- `spec/escape_promotion_matrix_spec.rb` (fix_norm=0.056)
- `tools/fuzz/surface_registry.rb` (fix_norm=0.056)
- `benchmarks/runner.rb` (fix_norm=0.055)
- `benchmarks/24_json_api/server.cht` (fix_norm=0.05)

## Run Summary
- Repo: `/home/yahn/cheat`
- Scope: whole repo
- Fix commits matched: 917 (time span over whole history, unfiltered)
- Files ranked: 79; fixed-but-unmeasured: 779
- Branch-coverage resultset: present
- Method: vendored bugspots ([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) x SimpleCov branch gap; file granularity; zero deps (see [docs/agents/design.md](docs/agents/design.md))
