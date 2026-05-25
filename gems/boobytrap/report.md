# Boobytrap Report

> Defect-risk hotspots: recurring bug-fix locality (bugspots, time-decayed) x branch-coverage gap.
> A ranking to triage **top-down**, never a verdict. A
> hotspot is "the code most likely to be a bug source,"
> not "a bug."

## Table of Contents
- [Project Prioritization](#project-prioritization)
- [Hotspots (62)](#hotspots-62)
- [Fixed But Unmeasured (2375)](#fixed-but-unmeasured-2375)
- [Run Summary](#run-summary)

## Project Prioritization
- The single highest-risk file is **`src/mir/mir_lowering.rb`** (hotspot=0.4201: fix_norm=1.0, branch gap=42.0%).
- 2 file(s) are within 50% of the top score (hotspot >= 0.2101); triage those first.

## Hotspots (62)
_normalized fix-churn x branch-gap; highest = most likely defect source._

| # | file | hotspot | fix_norm | branch gap | uncovered/total |
|---|------|---------|----------|-----------|-----------------|
| 1 | `src/mir/mir_lowering.rb` | 0.4201 | 1.0 | 42.0% | 1262/3004 |
| 2 | `src/annotator.rb` | 0.4175 | 0.745 | 56.0% | 1374/2452 |
| 3 | `src/backends/pipeline_host.rb` | 0.1742 | 0.213 | 81.8% | 664/812 |
| 4 | `src/ast/std_lib.rb` | 0.1432 | 0.157 | 90.9% | 20/22 |
| 5 | `src/mir/mir_emitter.rb` | 0.1205 | 0.271 | 44.4% | 504/1135 |
| 6 | `src/annotator-helpers/fixable_helpers.rb` | 0.0985 | 0.101 | 97.3% | 319/328 |
| 7 | `src/ast/parser.rb` | 0.0817 | 0.128 | 64.0% | 684/1069 |
| 8 | `src/mir/mir_pass.rb` | 0.0783 | 0.229 | 34.3% | 123/359 |
| 9 | `src/ast/diagnostic_registry.rb` | 0.072 | 0.072 | 100.0% | 28/28 |
| 10 | `src/mir/control_flow.rb` | 0.0719 | 0.198 | 36.3% | 209/575 |
| 11 | `src/ast/ast.rb` | 0.0655 | 0.175 | 37.5% | 135/360 |
| 12 | `src/annotator-helpers/effects.rb` | 0.0627 | 0.159 | 39.4% | 142/360 |
| 13 | `src/annotator-helpers/function_analysis.rb` | 0.0623 | 0.104 | 60.0% | 270/450 |
| 14 | `src/ast/type.rb` | 0.048 | 0.138 | 34.8% | 278/800 |
| 15 | `src/backends/importer.rb` | 0.045 | 0.045 | 100.0% | 40/40 |
| 16 | `src/mir/mir.rb` | 0.0447 | 0.086 | 52.1% | 270/518 |
| 17 | `src/backends/transpiler.rb` | 0.0401 | 0.041 | 97.5% | 39/40 |
| 18 | `src/mir/escape_analysis.rb` | 0.0379 | 0.122 | 31.0% | 341/1100 |
| 19 | `src/mir/test_lowering.rb` | 0.0353 | 0.036 | 97.9% | 46/47 |
| 20 | `src/annotator-helpers/capabilities.rb` | 0.0287 | 0.05 | 57.6% | 315/547 |
| 21 | `src/ast/symbol_entry.rb` | 0.028 | 0.052 | 53.8% | 14/26 |
| 22 | `src/mir/mir_checker.rb` | 0.0277 | 0.069 | 40.3% | 1386/3443 |
| 23 | `src/mir/fiber_ctx_builder.rb` | 0.026 | 0.052 | 50.0% | 30/60 |
| 24 | `src/mir/ownership_graph.rb` | 0.0217 | 0.045 | 48.7% | 37/76 |
| 25 | `src/mir/fsm_transform/emit.rb` | 0.0177 | 0.065 | 27.2% | 53/195 |
| 26 | `src/mir/hoist.rb` | 0.0165 | 0.045 | 36.5% | 331/907 |
| 27 | `src/ast/scope.rb` | 0.0163 | 0.039 | 41.3% | 26/63 |
| 28 | `src/annotator-helpers/pipe_analysis.rb` | 0.0162 | 0.019 | 83.4% | 467/560 |
| 29 | `src/mir/fsm_lowering.rb` | 0.0159 | 0.033 | 48.0% | 60/125 |
| 30 | `src/annotator-helpers/function_signature.rb` | 0.0152 | 0.033 | 46.0% | 23/50 |
| 31 | `src/backends/pipeline_rewriter.rb` | 0.0151 | 0.027 | 56.9% | 111/195 |
| 32 | `src/ast/source_error.rb` | 0.0134 | 0.017 | 80.0% | 36/45 |
| 33 | `src/annotator-helpers/union.rb` | 0.0126 | 0.019 | 65.6% | 42/64 |
| 34 | `src/mir/bg_capture_classifier.rb` | 0.0117 | 0.032 | 37.1% | 13/35 |
| 35 | `tools/fuzz/templates/takes_move_modality.rb` | 0.0113 | 0.101 | 11.1% | 1/9 |
| 36 | `src/mir/fsm_wrapper_emitter.rb` | 0.0106 | 0.021 | 50.6% | 44/87 |
| 37 | `src/backends/pipeline_generator.rb` | 0.0105 | 0.011 | 95.0% | 38/40 |
| 38 | `src/mir/capture_strategy.rb` | 0.0104 | 0.021 | 50.0% | 26/52 |
| 39 | `src/backends/compiler_frontend.rb` | 0.0101 | 0.03 | 33.3% | 8/24 |
| 40 | `src/mir/pre_mir_type_check.rb` | 0.0087 | 0.023 | 38.5% | 10/26 |

- ...(+22 more)

## Fixed But Unmeasured (2375)
_files with recurring fixes but NO branch-coverage data -- recurring-fix code the corpus does not measure at all; itself a risk._

- `examples/minivm/bc_emitter.rb` (fix_norm=0.484)
- `zig/runtime/runtime-header.zig` (fix_norm=0.275)
- `src/transpiler.rb` (fix_norm=0.247)
- `src/mir/promotion_plan.rb` (fix_norm=0.204)
- `spec/mir_lowering_spec.rb` (fix_norm=0.178)
- `examples/minivm/_bc_runner.cht` (fix_norm=0.176)
- `zig/runtime/scheduler.zig` (fix_norm=0.167)
- `clear` (fix_norm=0.159)
- `sorbet/rbi/clear-attr-accessors.rbi` (fix_norm=0.158)
- `spec/annotator_spec.rb` (fix_norm=0.151)
- `src/mir/escape_graph.rb` (fix_norm=0.149)
- `spec/transpiler_spec.rb` (fix_norm=0.14)
- `zig/lib/parking-lot.zig` (fix_norm=0.138)
- `docs/agents/vm-bugs.md` (fix_norm=0.136)
- `zig/runtime-header.zig` (fix_norm=0.134)
- `src/mir_lowering.rb` (fix_norm=0.127)
- `spec/loop_frame_analysis_spec.rb` (fix_norm=0.121)
- `zig/runtime/parking-lot-loom.zig` (fix_norm=0.113)
- `zig/runtime/stream-test.zig` (fix_norm=0.112)
- `examples/minivm/register_bc_emitter.rb` (fix_norm=0.097)
- `zig/parking-lot-loom-test.zig` (fix_norm=0.096)
- `spec/clear_fmt_spec.rb` (fix_norm=0.093)
- `src/tools/formatter.rb` (fix_norm=0.083)
- `zig/lib/data-structures.zig` (fix_norm=0.082)
- `zig/build.zig` (fix_norm=0.08)
- `spec/mir_emitter_spec.rb` (fix_norm=0.079)
- `transpile-tests/known-failing/README.md` (fix_norm=0.079)
- `examples/minivm/docs/agents/compiler-bug-root-causes.md` (fix_norm=0.078)
- `examples/minivm/docs/agents/stack-vm-fiber-replication.md` (fix_norm=0.078)
- `spec/clear_fix_spec.rb` (fix_norm=0.076)
- `zig/runtime/cleanup-test.zig` (fix_norm=0.074)
- `zig/runtime/queues.zig` (fix_norm=0.073)
- `src/promotion_plan.rb` (fix_norm=0.07)
- `spec/cleanup_plan_spec.rb` (fix_norm=0.068)
- `benchmarks/runner.rb` (fix_norm=0.062)
- `src/ownership_generator.rb` (fix_norm=0.061)
- `src/control_flow.rb` (fix_norm=0.06)
- `src/type.rb` (fix_norm=0.059)
- `benchmarks/24_json_api/server.cht` (fix_norm=0.055)
- `.github/workflows/ci.yml` (fix_norm=0.055)

## Run Summary
- Repo: `/home/yahn/cheat`
- Scope: whole repo
- Fix commits matched: 908 (time span over whole history, unfiltered)
- Files ranked: 62; fixed-but-unmeasured: 2375
- Branch-coverage resultset: present
- Method: vendored bugspots ([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) x SimpleCov branch gap; file granularity; zero deps (see [docs/agents/design.md](docs/agents/design.md))
