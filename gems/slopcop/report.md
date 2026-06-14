# SlopCop Report

> Top true coverage gaps, ranked by fix-churn x structural
> deviance. Every dark arm is categorized; only GENUINE
> reachable ones are gaps. Apex = uncovered AND historically
> churned (boobytrap) AND structurally deviant (decomplex).
> Owns categorization; consumes boobytrap (churn) and
> optional decomplex (spurious filter + deviance rank).

## Top True Gaps (1217) — test these, ranked by fix-churn

| # | gap | method | churn | decomplex deviance |
|---|---|---|---|---|
| 1 | [`src/mir/fsm_transform/emit.rb:689`](../../src/mir/fsm_transform/emit.rb#L689) | `build_recursive` | 0.4591 | **12** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 2 | [`src/mir/fsm_transform/emit.rb:728`](../../src/mir/fsm_transform/emit.rb#L728) | `build_recursive` | 0.4591 | **12** (Weighted Inlined Cognitive Complexity) |
| 3 | [`src/mir/fsm_transform/emit.rb:755`](../../src/mir/fsm_transform/emit.rb#L755) | `build_recursive` | 0.4591 | **12** (Weighted Inlined Cognitive Complexity) |
| 4 | [`src/mir/fsm_transform/emit.rb:797`](../../src/mir/fsm_transform/emit.rb#L797) | `build_recursive` | 0.4591 | **12** (Weighted Inlined Cognitive Complexity) |
| 5 | [`src/mir/fsm_transform/emit.rb:929`](../../src/mir/fsm_transform/emit.rb#L929) | `build_recursive` | 0.4591 | **12** (False Simplicity, Weighted Inlined Cognitive Complexity) |
| 6 | [`src/mir/fsm_transform/emit.rb:934`](../../src/mir/fsm_transform/emit.rb#L934) | `build_recursive` | 0.4591 | **12** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 7 | [`src/mir/hoist.rb:159`](../../src/mir/hoist.rb#L159) | `collect_stmt_hoists!` | 0.5527 | **10** (Weighted Inlined Cognitive Complexity) |
| 8 | [`src/mir/hoist.rb:168`](../../src/mir/hoist.rb#L168) | `collect_stmt_hoists!` | 0.5527 | **10** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 9 | [`src/mir/hoist.rb:173`](../../src/mir/hoist.rb#L173) | `collect_stmt_hoists!` | 0.5527 | **10** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 10 | [`src/mir/hoist.rb:1035`](../../src/mir/hoist.rb#L1035) | `normalize_allocating_used_expr` | 0.5527 | **10** (Weighted Inlined Cognitive Complexity) |
| 11 | [`src/mir/hoist.rb:1036`](../../src/mir/hoist.rb#L1036) | `normalize_allocating_used_expr` | 0.5527 | **10** (Weighted Inlined Cognitive Complexity) |
| 12 | [`src/ast/ast.rb:384`](../../src/ast/ast.rb#L384) | `walk_body` | 0.6434 | **8** (False Simplicity) |
| 13 | [`src/ast/ast.rb:825`](../../src/ast/ast.rb#L825) | `each_capture_analysis` | 0.6434 | **8** (False Simplicity, State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 14 | [`src/ast/ast.rb:830`](../../src/ast/ast.rb#L830) | `each_capture_analysis` | 0.6434 | **8** (False Simplicity, State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 15 | [`src/ast/ast.rb:2505`](../../src/ast/ast.rb#L2505) | `child_bodies` | 0.6434 | **8** (False Simplicity) |
| 16 | [`src/ast/ast.rb:2511`](../../src/ast/ast.rb#L2511) | `child_bodies` | 0.6434 | **8** (False Simplicity, State-Based Branch Density) |
| 17 | [`src/ast/ast.rb:2512`](../../src/ast/ast.rb#L2512) | `child_bodies` | 0.6434 | **8** (False Simplicity, State-Based Branch Density) |
| 18 | [`src/mir/lowering/expressions.rb:607`](../../src/mir/lowering/expressions.rb#L607) | `string_comparison_operand` | 0.4777 | **10** (Broken Protocols, False Simplicity, State-Based Branch Density) |
| 19 | [`src/mir/lowering/expressions.rb:1287`](../../src/mir/lowering/expressions.rb#L1287) | `index_access_value` | 0.4777 | **10** (State-Based Branch Density) |
| 20 | [`src/mir/lowering/expressions.rb:1309`](../../src/mir/lowering/expressions.rb#L1309) | `index_access_value` | 0.4777 | **10** (State-Based Branch Density) |
| 21 | [`src/mir/lowering/expressions.rb:1323`](../../src/mir/lowering/expressions.rb#L1323) | `index_access_value` | 0.4777 | **10** (Neglected Path Conditions, State-Based Branch Density) |
| 22 | [`src/mir/mir_pass.rb:477`](../../src/mir/mir_pass.rb#L477) | `transform_body` | 0.4774 | **10** (False Simplicity, State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 23 | [`src/mir/fiber_ctx_builder.rb:306`](../../src/mir/fiber_ctx_builder.rb#L306) | `build` | 0.4687 | **10** (False Simplicity, Weighted Inlined Cognitive Complexity) |
| 24 | [`src/mir/fiber_ctx_builder.rb:317`](../../src/mir/fiber_ctx_builder.rb#L317) | `build` | 0.4687 | **10** (Neglected Path Conditions, Weighted Inlined Cognitive Complexity) |
| 25 | [`src/mir/lowering/concurrency.rb:398`](../../src/mir/lowering/concurrency.rb#L398) | `lower_do_block` | 0.5836 | **8** † (Decision Pressure, False Simplicity) |
| 26 | [`src/mir/lowering/concurrency.rb:1035`](../../src/mir/lowering/concurrency.rb#L1035) | `lower_bg_stream_block` | 0.5836 | **8** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 27 | [`src/mir/lowering/concurrency.rb:1050`](../../src/mir/lowering/concurrency.rb#L1050) | `lower_bg_stream_block` | 0.5836 | **8** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 28 | [`src/mir/lowering/concurrency.rb:1063`](../../src/mir/lowering/concurrency.rb#L1063) | `lower_bg_stream_block` | 0.5836 | **8** (Weighted Inlined Cognitive Complexity) |
| 29 | [`src/mir/lowering/concurrency.rb:1124`](../../src/mir/lowering/concurrency.rb#L1124) | `lower_bg_stream_block` | 0.5836 | **8** (Weighted Inlined Cognitive Complexity) |
| 30 | [`src/mir/lowering/concurrency.rb:1241`](../../src/mir/lowering/concurrency.rb#L1241) | `lower_next_expr` | 0.5836 | **8** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 31 | [`src/mir/hoist.rb:197`](../../src/mir/hoist.rb#L197) | `allocating?` | 0.5527 | **8** † (Decision Pressure, False Simplicity) |
| 32 | [`src/mir/hoist.rb:899`](../../src/mir/hoist.rb#L899) | `normalize_allocating_mir_stmt!` | 0.5527 | **8** (Weighted Inlined Cognitive Complexity) |
| 33 | [`src/mir/hoist.rb:1258`](../../src/mir/hoist.rb#L1258) | `cleanup_entry_for_owned_result` | 0.5527 | **8** † (Decision Pressure, False Simplicity, State-Based Branch Density) |
| 34 | [`src/mir/hoist.rb:1260`](../../src/mir/hoist.rb#L1260) | `cleanup_entry_for_owned_result` | 0.5527 | **8** (False Simplicity) |
| 35 | [`src/mir/hoist.rb:1264`](../../src/mir/hoist.rb#L1264) | `cleanup_entry_for_owned_result` | 0.5527 | **8** (State-Based Branch Density) |
| 36 | [`src/mir/mir_lowering.rb:584`](../../src/mir/mir_lowering.rb#L584) | `destination_type` | 0.5422 | **8** (False Simplicity) |
| 37 | [`src/mir/mir_lowering.rb:1006`](../../src/mir/mir_lowering.rb#L1006) | `apply_lowered_coercion` | 0.5422 | **8** (Weighted Inlined Cognitive Complexity) |
| 38 | [`src/mir/mir_lowering.rb:2231`](../../src/mir/mir_lowering.rb#L2231) | `ownership_operands_for_sink_value` | 0.5422 | **8** (Weighted Inlined Cognitive Complexity) |
| 39 | [`src/mir/mir_lowering.rb:3172`](../../src/mir/mir_lowering.rb#L3172) | `imported_module_dependency_items` | 0.5422 | **8** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 40 | [`src/mir/mir_lowering.rb:3560`](../../src/mir/mir_lowering.rb#L3560) | `owned_sink_plan` | 0.5422 | **8** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 41 | [`src/mir/mir_lowering.rb:3561`](../../src/mir/mir_lowering.rb#L3561) | `owned_sink_plan` | 0.5422 | **8** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 42 | [`src/annotator/annotator.rb:486`](../../src/annotator/annotator.rb#L486) | `with_held_locks` | 0.5228 | **8** (Temporal Ordering Pressure) |
| 43 | [`src/ast/ast.rb:469`](../../src/ast/ast.rb#L469) | `borrowed_ownership_view?` | 0.6434 | **6** (False Simplicity) |
| 44 | [`src/annotator/helpers/effects.rb:435`](../../src/annotator/helpers/effects.rb#L435) | `function_needs_runtime_directly?` | 0.5046 | **8** † (Decision Pressure, False Simplicity, State-Based Branch Density) |
| 45 | [`src/annotator/helpers/effects.rb:436`](../../src/annotator/helpers/effects.rb#L436) | `function_needs_runtime_directly?` | 0.5046 | **8** (State-Based Branch Density) |
| 46 | [`src/annotator/helpers/effects.rb:1057`](../../src/annotator/helpers/effects.rb#L1057) | `assign_base_stack_tiers!` | 0.5046 | **8** † (Decision Pressure, False Simplicity, Neglected Updates, +1) |
| 47 | [`src/annotator/helpers/effects.rb:1058`](../../src/annotator/helpers/effects.rb#L1058) | `assign_base_stack_tiers!` | 0.5046 | **8** † (Decision Pressure, False Simplicity, Neglected Updates, +1) |
| 48 | [`src/annotator/helpers/effects.rb:1147`](../../src/annotator/helpers/effects.rb#L1147) | `max_tier_for_calls` | 0.5046 | **8** (State-Based Branch Density) |
| 49 | [`src/tools/doctor.rb:143`](../../src/tools/doctor.rb#L143) | `section_heap` | 0.0 | **16** (State-Based Branch Density) |
| 50 | [`src/tools/doctor.rb:188`](../../src/tools/doctor.rb#L188) | `section_heap` | 0.0 | **16** (State-Based Branch Density) |

- ...(+1167 more genuine gaps)

> decomplex attribution on listed gaps: **772 span-precise**, **348 method-coarse (†)**, **59 ⚠dup?** (possibly redundant, not localised -- verify before testing). Coarse rows are whole-method: treat as a hint, not an arm-level discriminator.

## Category Summary
_2824 dark arms; only 1217 are genuine gaps. The rest are not test targets:_

| category | arms | % | what it means |
|---|---|---|---|
| type_norm | 774 | 27.4% | type/nil guard -- likely dead if runtime contracts were stricter |
| dead | 60 | 2.1% | decision never executes in coverage -- audit as missing test or statically-dead code |
| defensive | 90 | 3.2% | inert / invariant-pinned -- accept, exclude from denominator |
| spurious | 76 | 2.7% | span-precise redundant/cloned decision (decomplex) -- refactor or delete, NOT a test target (coarse duplication never excludes -- it stays a gap, flagged ⚠dup?) |
| ffi | 0 | 0.0% | external/boundary call -- needs an integration test |
| diagnostic | 607 | 21.5% | error/raise/diagnostic path -- reachable only by invalid input (negative test) |
| genuine | 1217 | 43.1% | real reachable gap -- test it; ranked by fix-churn x decomplex structural deviance |

## Run Summary
- Repo: `/home/yahn/cheat`
- Files: 127; dark arms: 2824; genuine gaps: 1217
- General engine: categorizes uncovered branches, ranks genuine gaps by consumed boobytrap churn x optional decomplex structural deviance. Project lexicons (external-boundary methods and domain diagnostic methods) are caller-supplied, not baked in (see docs/agents/design.md).
- decomplex join is span-precise (the arm's line falls inside the flagged decision's source extent); `†` marks a (file, method) fallback when no flagged span contained the arm. A ranked candidate, not a verdict (Engler discipline).
