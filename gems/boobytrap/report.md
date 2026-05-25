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
- The single highest-risk file is **`src/mir/mir_lowering.rb`** (hotspot=0.4229: fix_norm=1.0, branch gap=42.3%).
- 2 file(s) are within 50% of the top score (hotspot >= 0.2115); triage those first.

## Hotspots (62)
_normalized fix-churn x branch-gap; highest = most likely defect source._

| # | file | hotspot | fix_norm | branch gap | uncovered/total |
|---|------|---------|----------|-----------|-----------------|
| 1 | `src/mir/mir_lowering.rb` | 0.4229 | 1.0 | 42.3% | 425/1005 |
| 2 | `src/annotator.rb` | 0.4203 | 0.746 | 56.3% | 1382/2454 |
| 3 | `src/backends/pipeline_host.rb` | 0.1764 | 0.215 | 82.1% | 667/812 |
| 4 | `src/ast/std_lib.rb` | 0.1437 | 0.158 | 90.9% | 20/22 |
| 5 | `src/mir/mir_emitter.rb` | 0.1217 | 0.271 | 45.0% | 166/369 |
| 6 | `src/annotator-helpers/fixable_helpers.rb` | 0.0996 | 0.102 | 97.3% | 319/328 |
| 7 | `src/ast/parser.rb` | 0.0824 | 0.128 | 64.2% | 686/1069 |
| 8 | `src/mir/mir_pass.rb` | 0.0797 | 0.227 | 35.1% | 128/365 |
| 9 | `src/mir/control_flow.rb` | 0.0727 | 0.197 | 36.8% | 219/595 |
| 10 | `src/ast/diagnostic_registry.rb` | 0.072 | 0.072 | 100.0% | 14/14 |
| 11 | `src/ast/ast.rb` | 0.0697 | 0.174 | 40.0% | 134/335 |
| 12 | `src/annotator-helpers/function_analysis.rb` | 0.0652 | 0.105 | 62.2% | 280/450 |
| 13 | `src/annotator-helpers/effects.rb` | 0.0619 | 0.158 | 39.3% | 143/364 |
| 14 | `src/ast/type.rb` | 0.0491 | 0.138 | 35.6% | 281/790 |
| 15 | `src/backends/importer.rb` | 0.045 | 0.045 | 100.0% | 40/40 |
| 16 | `src/backends/transpiler.rb` | 0.0404 | 0.041 | 97.5% | 39/40 |
| 17 | `src/mir/mir.rb` | 0.0387 | 0.086 | 44.9% | 44/98 |
| 18 | `src/mir/escape_analysis.rb` | 0.0376 | 0.122 | 30.7% | 201/655 |
| 19 | `src/mir/test_lowering.rb` | 0.035 | 0.036 | 97.9% | 46/47 |
| 20 | `src/annotator-helpers/capabilities.rb` | 0.0289 | 0.05 | 57.4% | 316/551 |
| 21 | `src/ast/symbol_entry.rb` | 0.0279 | 0.052 | 53.8% | 14/26 |
| 22 | `src/mir/mir_checker.rb` | 0.0262 | 0.069 | 37.8% | 344/910 |
| 23 | `src/mir/fiber_ctx_builder.rb` | 0.0251 | 0.052 | 48.3% | 29/60 |
| 24 | `src/mir/ownership_graph.rb` | 0.0218 | 0.045 | 48.7% | 37/76 |
| 25 | `src/mir/fsm_transform/emit.rb` | 0.0197 | 0.065 | 30.1% | 62/206 |
| 26 | `src/annotator-helpers/pipe_analysis.rb` | 0.0173 | 0.02 | 87.9% | 492/560 |
| 27 | `src/ast/scope.rb` | 0.0164 | 0.04 | 41.3% | 26/63 |
| 28 | `src/backends/pipeline_rewriter.rb` | 0.016 | 0.026 | 60.5% | 118/195 |
| 29 | `src/mir/fsm_lowering.rb` | 0.0158 | 0.033 | 48.0% | 60/125 |
| 30 | `src/annotator-helpers/function_signature.rb` | 0.0151 | 0.033 | 46.0% | 23/50 |
| 31 | `src/ast/source_error.rb` | 0.0136 | 0.017 | 80.0% | 36/45 |
| 32 | `src/mir/hoist.rb` | 0.0127 | 0.044 | 28.7% | 104/362 |
| 33 | `src/annotator-helpers/union.rb` | 0.0127 | 0.019 | 65.6% | 42/64 |
| 34 | `src/mir/bg_capture_classifier.rb` | 0.0118 | 0.032 | 37.1% | 13/35 |
| 35 | `tools/fuzz/templates/takes_move_modality.rb` | 0.0111 | 0.1 | 11.1% | 1/9 |
| 36 | `src/mir/fsm_wrapper_emitter.rb` | 0.0108 | 0.021 | 50.6% | 44/87 |
| 37 | `src/backends/pipeline_generator.rb` | 0.0106 | 0.011 | 95.0% | 38/40 |
| 38 | `src/backends/compiler_frontend.rb` | 0.0102 | 0.031 | 33.3% | 8/24 |
| 39 | `src/mir/capture_strategy.rb` | 0.0101 | 0.021 | 48.0% | 24/50 |
| 40 | `src/mir/pre_mir_type_check.rb` | 0.0086 | 0.022 | 38.5% | 10/26 |

- ...(+22 more)

## Fixed But Unmeasured (2375)
_files with recurring fixes but NO branch-coverage data -- recurring-fix code the corpus does not measure at all; itself a risk._

- `examples/minivm/bc_emitter.rb` (fix_norm=0.49)
- `zig/runtime/runtime-header.zig` (fix_norm=0.275)
- `src/transpiler.rb` (fix_norm=0.25)
- `src/mir/promotion_plan.rb` (fix_norm=0.203)
- `spec/mir_lowering_spec.rb` (fix_norm=0.179)
- `examples/minivm/_bc_runner.cht` (fix_norm=0.178)
- `zig/runtime/scheduler.zig` (fix_norm=0.169)
- `clear` (fix_norm=0.161)
- `sorbet/rbi/clear-attr-accessors.rbi` (fix_norm=0.156)
- `spec/annotator_spec.rb` (fix_norm=0.152)
- `src/mir/escape_graph.rb` (fix_norm=0.146)
- `spec/transpiler_spec.rb` (fix_norm=0.141)
- `zig/lib/parking-lot.zig` (fix_norm=0.14)
- `zig/runtime-header.zig` (fix_norm=0.136)
- `docs/agents/vm-bugs.md` (fix_norm=0.135)
- `src/mir_lowering.rb` (fix_norm=0.129)
- `spec/loop_frame_analysis_spec.rb` (fix_norm=0.121)
- `zig/runtime/parking-lot-loom.zig` (fix_norm=0.114)
- `zig/runtime/stream-test.zig` (fix_norm=0.113)
- `zig/parking-lot-loom-test.zig` (fix_norm=0.097)
- `examples/minivm/register_bc_emitter.rb` (fix_norm=0.096)
- `spec/clear_fmt_spec.rb` (fix_norm=0.094)
- `src/tools/formatter.rb` (fix_norm=0.083)
- `zig/lib/data-structures.zig` (fix_norm=0.082)
- `zig/build.zig` (fix_norm=0.081)
- `spec/mir_emitter_spec.rb` (fix_norm=0.079)
- `transpile-tests/known-failing/README.md` (fix_norm=0.078)
- `spec/clear_fix_spec.rb` (fix_norm=0.078)
- `examples/minivm/docs/agents/compiler-bug-root-causes.md` (fix_norm=0.077)
- `examples/minivm/docs/agents/stack-vm-fiber-replication.md` (fix_norm=0.077)
- `zig/runtime/queues.zig` (fix_norm=0.074)
- `zig/runtime/cleanup-test.zig` (fix_norm=0.073)
- `src/promotion_plan.rb` (fix_norm=0.071)
- `spec/cleanup_plan_spec.rb` (fix_norm=0.068)
- `benchmarks/runner.rb` (fix_norm=0.063)
- `src/ownership_generator.rb` (fix_norm=0.061)
- `src/control_flow.rb` (fix_norm=0.061)
- `src/type.rb` (fix_norm=0.06)
- `.github/workflows/ci.yml` (fix_norm=0.055)
- `benchmarks/24_json_api/server.cht` (fix_norm=0.055)

## Run Summary
- Repo: `/home/yahn/cheat`
- Scope: whole repo
- Fix commits matched: 907 (time span over whole history, unfiltered)
- Files ranked: 62; fixed-but-unmeasured: 2375
- Branch-coverage resultset: present
- Method: vendored bugspots ([Google ICSE'13 time-decay](docs/agents/design.md#prior-art)) x SimpleCov branch gap; file granularity; zero deps (see [docs/agents/design.md](docs/agents/design.md))
