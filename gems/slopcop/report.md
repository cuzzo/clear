# SlopCop Report

> Top true coverage gaps, ranked by fix-churn x structural
> deviance. Every dark arm is categorized; only GENUINE
> reachable ones are gaps. Apex = uncovered AND historically
> churned (boobytrap) AND structurally deviant (decomplex).
> Owns categorization; consumes boobytrap (churn) and
> optional decomplex (spurious filter + deviance rank).

## Top True Gaps (1386) — test these, ranked by fix-churn

| # | gap | method | churn | decomplex deviance |
|---|---|---|---|---|
| 1 | [`src/mir/fsm_transform/emit.rb:689`](../../src/mir/fsm_transform/emit.rb#L689) | `build_recursive` | 0.4576 | **12** (State-Based Branch Density) |
| 2 | [`src/mir/fsm_transform/emit.rb:728`](../../src/mir/fsm_transform/emit.rb#L728) | `build_recursive` | 0.4576 | **12** † (Decision Pressure, Derived-State Staleness, False Simplicity, +1) |
| 3 | [`src/mir/fsm_transform/emit.rb:755`](../../src/mir/fsm_transform/emit.rb#L755) | `build_recursive` | 0.4576 | **12** † (Decision Pressure, Derived-State Staleness, False Simplicity, +1) |
| 4 | [`src/mir/fsm_transform/emit.rb:797`](../../src/mir/fsm_transform/emit.rb#L797) | `build_recursive` | 0.4576 | **12** † (Decision Pressure, Derived-State Staleness, False Simplicity, +1) |
| 5 | [`src/mir/fsm_transform/emit.rb:929`](../../src/mir/fsm_transform/emit.rb#L929) | `build_recursive` | 0.4576 | **12** (False Simplicity) |
| 6 | [`src/mir/fsm_transform/emit.rb:934`](../../src/mir/fsm_transform/emit.rb#L934) | `build_recursive` | 0.4576 | **12** (State-Based Branch Density) |
| 7 | [`src/mir/hoist.rb:159`](../../src/mir/hoist.rb#L159) | `collect_stmt_hoists!` | 0.5603 | **10** † (Decision Pressure, False Simplicity, Neglected Path Conditions, +1) |
| 8 | [`src/mir/hoist.rb:168`](../../src/mir/hoist.rb#L168) | `collect_stmt_hoists!` | 0.5603 | **10** (State-Based Branch Density) |
| 9 | [`src/mir/hoist.rb:173`](../../src/mir/hoist.rb#L173) | `collect_stmt_hoists!` | 0.5603 | **10** (State-Based Branch Density) |
| 10 | [`src/mir/hoist.rb:1102`](../../src/mir/hoist.rb#L1102) | `stamp_allocating_result_target!` | 0.5603 | **10** (State-Based Branch Density) |
| 11 | [`src/mir/hoist.rb:1106`](../../src/mir/hoist.rb#L1106) | `stamp_allocating_result_target!` | 0.5603 | **10** (State-Based Branch Density) |
| 12 | [`src/mir/hoist.rb:1107`](../../src/mir/hoist.rb#L1107) | `stamp_allocating_result_target!` | 0.5603 | **10** (State-Based Branch Density) |
| 13 | [`src/ast/ast.rb:384`](../../src/ast/ast.rb#L384) | `walk_body` | 0.6426 | **8** (False Simplicity) |
| 14 | [`src/ast/ast.rb:825`](../../src/ast/ast.rb#L825) | `each_capture_analysis` | 0.6426 | **8** (False Simplicity, State-Based Branch Density) |
| 15 | [`src/ast/ast.rb:830`](../../src/ast/ast.rb#L830) | `each_capture_analysis` | 0.6426 | **8** (False Simplicity, State-Based Branch Density) |
| 16 | [`src/ast/ast.rb:2505`](../../src/ast/ast.rb#L2505) | `child_bodies` | 0.6426 | **8** (False Simplicity) |
| 17 | [`src/ast/ast.rb:2511`](../../src/ast/ast.rb#L2511) | `child_bodies` | 0.6426 | **8** (False Simplicity, State-Based Branch Density) |
| 18 | [`src/ast/ast.rb:2512`](../../src/ast/ast.rb#L2512) | `child_bodies` | 0.6426 | **8** (False Simplicity, State-Based Branch Density) |
| 19 | [`src/mir/mir_pass.rb:477`](../../src/mir/mir_pass.rb#L477) | `transform_body` | 0.4777 | **10** (False Simplicity, State-Based Branch Density) |
| 20 | [`src/mir/fiber_ctx_builder.rb:291`](../../src/mir/fiber_ctx_builder.rb#L291) | `build` | 0.4665 | **10** † (Decision Pressure, False Simplicity, Neglected Path Conditions, +1) |
| 21 | [`src/mir/fiber_ctx_builder.rb:307`](../../src/mir/fiber_ctx_builder.rb#L307) | `build` | 0.4665 | **10** † (Decision Pressure, False Simplicity, Neglected Path Conditions, +1) |
| 22 | [`src/mir/lowering/concurrency.rb:398`](../../src/mir/lowering/concurrency.rb#L398) | `lower_do_block` | 0.5855 | **8** † (Decision Pressure, False Simplicity) |
| 23 | [`src/mir/lowering/concurrency.rb:1035`](../../src/mir/lowering/concurrency.rb#L1035) | `lower_bg_stream_block` | 0.5855 | **8** (State-Based Branch Density) |
| 24 | [`src/mir/lowering/concurrency.rb:1050`](../../src/mir/lowering/concurrency.rb#L1050) | `lower_bg_stream_block` | 0.5855 | **8** (State-Based Branch Density) |
| 25 | [`src/mir/lowering/concurrency.rb:1063`](../../src/mir/lowering/concurrency.rb#L1063) | `lower_bg_stream_block` | 0.5855 | **8** † (Decision Pressure, False Simplicity, State-Based Branch Density) |
| 26 | [`src/mir/lowering/concurrency.rb:1124`](../../src/mir/lowering/concurrency.rb#L1124) | `lower_bg_stream_block` | 0.5855 | **8** † (Decision Pressure, False Simplicity, State-Based Branch Density) |
| 27 | [`src/mir/lowering/concurrency.rb:1241`](../../src/mir/lowering/concurrency.rb#L1241) | `lower_next_expr` | 0.5855 | **8** (State-Based Branch Density) |
| 28 | [`src/mir/lowering/functions.rb:1684`](../../src/mir/lowering/functions.rb#L1684) | `lower_intrinsic` | 0.3184 | **12** † ⚠dup? (Decision Pressure, Derived-State Staleness, False Simplicity, +2) |
| 29 | [`src/mir/hoist.rb:197`](../../src/mir/hoist.rb#L197) | `allocating?` | 0.5603 | **8** † (Decision Pressure, False Simplicity) |
| 30 | [`src/mir/hoist.rb:549`](../../src/mir/hoist.rb#L549) | `mir_allocates?` | 0.5603 | **8** † (Broken Protocols, Decision Pressure) |
| 31 | [`src/mir/hoist.rb:809`](../../src/mir/hoist.rb#L809) | `normalize_allocating_mir_stmt!` | 0.5603 | **8** (State-Based Branch Density) |
| 32 | [`src/mir/hoist.rb:832`](../../src/mir/hoist.rb#L832) | `normalize_allocating_mir_stmt!` | 0.5603 | **8** (State-Based Branch Density) |
| 33 | [`src/mir/hoist.rb:948`](../../src/mir/hoist.rb#L948) | `normalize_allocating_result_expr!` | 0.5603 | **8** (False Simplicity) |
| 34 | [`src/mir/hoist.rb:1221`](../../src/mir/hoist.rb#L1221) | `cleanup_entry_for_owned_result` | 0.5603 | **8** (State-Based Branch Density) |
| 35 | [`src/mir/hoist.rb:1222`](../../src/mir/hoist.rb#L1222) | `cleanup_entry_for_owned_result` | 0.5603 | **8** (State-Based Branch Density) |
| 36 | [`src/mir/hoist.rb:1229`](../../src/mir/hoist.rb#L1229) | `cleanup_entry_for_owned_result` | 0.5603 | **8** † (Decision Pressure, False Simplicity, State-Based Branch Density) |
| 37 | [`src/mir/mir_lowering.rb:584`](../../src/mir/mir_lowering.rb#L584) | `destination_type` | 0.5413 | **8** (False Simplicity) |
| 38 | [`src/mir/mir_lowering.rb:1006`](../../src/mir/mir_lowering.rb#L1006) | `apply_lowered_coercion` | 0.5413 | **8** † (Decision Pressure, False Simplicity, State-Based Branch Density) |
| 39 | [`src/mir/mir_lowering.rb:2231`](../../src/mir/mir_lowering.rb#L2231) | `ownership_operands_for_sink_value` | 0.5413 | **8** † (Broken Protocols, Decision Pressure, State-Based Branch Density) |
| 40 | [`src/mir/mir_lowering.rb:3172`](../../src/mir/mir_lowering.rb#L3172) | `imported_module_dependency_items` | 0.5413 | **8** (State-Based Branch Density) |
| 41 | [`src/mir/mir_lowering.rb:3560`](../../src/mir/mir_lowering.rb#L3560) | `owned_sink_plan` | 0.5413 | **8** (State-Based Branch Density) |
| 42 | [`src/mir/mir_lowering.rb:3561`](../../src/mir/mir_lowering.rb#L3561) | `owned_sink_plan` | 0.5413 | **8** (State-Based Branch Density) |
| 43 | [`src/ast/ast.rb:469`](../../src/ast/ast.rb#L469) | `borrowed_ownership_view?` | 0.6426 | **6** (False Simplicity) |
| 44 | [`src/annotator/annotator.rb:486`](../../src/annotator/annotator.rb#L486) | `with_held_locks` | 0.5147 | **8** (False Simplicity, Temporal Ordering Pressure) |
| 45 | [`src/tools/doctor.rb:143`](../../src/tools/doctor.rb#L143) | `section_heap` | 0.0 | **16** (State-Based Branch Density) |
| 46 | [`src/tools/doctor.rb:188`](../../src/tools/doctor.rb#L188) | `section_heap` | 0.0 | **16** (State-Based Branch Density) |
| 47 | [`src/tools/doctor.rb:212`](../../src/tools/doctor.rb#L212) | `section_heap` | 0.0 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +5) |
| 48 | [`src/tools/doctor.rb:269`](../../src/tools/doctor.rb#L269) | `section_heap` | 0.0 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +5) |
| 49 | [`src/annotator/helpers/effects.rb:435`](../../src/annotator/helpers/effects.rb#L435) | `compute_needs_rt!` | 0.4963 | **8** † (Decision Pressure, False Simplicity, State-Based Branch Density) |
| 50 | [`src/annotator/helpers/effects.rb:436`](../../src/annotator/helpers/effects.rb#L436) | `compute_needs_rt!` | 0.4963 | **8** † (Decision Pressure, False Simplicity, State-Based Branch Density) |

- ...(+1336 more genuine gaps)

> decomplex attribution on listed gaps: **781 span-precise**, **484 method-coarse (†)**, **76 ⚠dup?** (possibly redundant, not localised -- verify before testing). Coarse rows are whole-method: treat as a hint, not an arm-level discriminator.

## Category Summary
_3174 dark arms; only 1386 are genuine gaps. The rest are not test targets:_

| category | arms | % | what it means |
|---|---|---|---|
| type_norm | 917 | 28.9% | type/nil guard -- likely dead if runtime contracts were stricter |
| dead | 77 | 2.4% | decision never executes in coverage -- audit as missing test or statically-dead code |
| defensive | 62 | 2.0% | inert / invariant-pinned -- accept, exclude from denominator |
| spurious | 82 | 2.6% | span-precise redundant/cloned decision (decomplex) -- refactor or delete, NOT a test target (coarse duplication never excludes -- it stays a gap, flagged ⚠dup?) |
| ffi | 0 | 0.0% | external/boundary call -- needs an integration test |
| diagnostic | 650 | 20.5% | error/raise/diagnostic path -- reachable only by invalid input (negative test) |
| genuine | 1386 | 43.7% | real reachable gap -- test it; ranked by fix-churn x decomplex structural deviance |

## Run Summary
- Repo: `/home/yahn/cheat`
- Files: 127; dark arms: 3174; genuine gaps: 1386
- General engine: categorizes uncovered branches, ranks genuine gaps by consumed boobytrap churn x optional decomplex structural deviance. Project lexicons (external-boundary methods and domain diagnostic methods) are caller-supplied, not baked in (see docs/agents/design.md).
- decomplex join is span-precise (the arm's line falls inside the flagged decision's source extent); `†` marks a (file, method) fallback when no flagged span contained the arm. A ranked candidate, not a verdict (Engler discipline).
