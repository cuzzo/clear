# SlopCop Report

> Top true coverage gaps, ranked by fix-churn x structural
> deviance. Every dark arm is categorized; only GENUINE
> reachable ones are gaps. Apex = uncovered AND historically
> churned (boobytrap) AND structurally deviant (decomplex).
> Owns categorization; consumes boobytrap (churn) and
> optional decomplex (spurious filter + deviance rank).

## Top True Gaps (1102) — test these, ranked by fix-churn

| # | gap | method | churn | decomplex deviance |
|---|---|---|---|---|
| 1 | [`src/mir/mir_lowering.rb:1368`](../../src/mir/mir_lowering.rb#L1368) | `ownership_fact_source` | 1.0 | **8** (Decision Pressure) |
| 2 | [`src/mir/mir_lowering.rb:1828`](../../src/mir/mir_lowering.rb#L1828) | `collect_bg_capture_transfer_roots` | 1.0 | **8** (False Simplicity) |
| 3 | [`src/mir/mir_lowering.rb:692`](../../src/mir/mir_lowering.rb#L692) | `return_destination_alloc` | 1.0 | **4** † (Broken Protocols, False Simplicity) |
| 4 | [`src/mir/mir_lowering.rb:2078`](../../src/mir/mir_lowering.rb#L2078) | `lower_module` | 1.0 | **4** † (Broken Protocols, False Simplicity) |
| 5 | [`src/ast/type.rb:2377`](../../src/ast/type.rb#L2377) | `compute_zig_type` | 0.1749 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 6 | [`src/mir/mir_lowering.rb:557`](../../src/mir/mir_lowering.rb#L557) | `place_owned_try_catch_for_destination` | 1.0 | **2** † (False Simplicity, Neglected Updates) |
| 7 | [`src/mir/mir_lowering.rb:600`](../../src/mir/mir_lowering.rb#L600) | `place_owned_alloc_mismatch_for_destination` | 1.0 | **2** † (False Simplicity, Neglected Updates) |
| 8 | [`src/mir/mir_lowering.rb:2113`](../../src/mir/mir_lowering.rb#L2113) | `with_decl_alloc` | 1.0 | **2** (False Simplicity) |
| 9 | [`src/mir/lowering/expressions.rb:505`](../../src/mir/lowering/expressions.rb#L505) | `lower_smooth` | 0.08 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 10 | [`src/mir/mir_lowering.rb:902`](../../src/mir/mir_lowering.rb#L902) | `append_pending_packet_nodes!` | 1.0 | **1** † (False Simplicity) |
| 11 | [`src/mir/lowering/variables.rb:437`](../../src/mir/lowering/variables.rb#L437) | `build_var_decl_nodes` | 0.0511 | **16** (Derived-State Staleness) |
| 12 | [`src/mir/lowering/variables.rb:440`](../../src/mir/lowering/variables.rb#L440) | `build_var_decl_nodes` | 0.0511 | **16** (False Simplicity) |
| 13 | [`src/mir/lowering/variables.rb:493`](../../src/mir/lowering/variables.rb#L493) | `build_var_decl_nodes` | 0.0511 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 14 | [`src/tools/doctor.rb:131`](../../src/tools/doctor.rb#L131) | `section_heap` | 0.0329 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 15 | [`src/tools/doctor.rb:142`](../../src/tools/doctor.rb#L142) | `section_heap` | 0.0329 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 16 | [`src/tools/doctor.rb:211`](../../src/tools/doctor.rb#L211) | `section_heap` | 0.0329 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 17 | [`src/tools/doctor.rb:232`](../../src/tools/doctor.rb#L232) | `section_heap` | 0.0329 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 18 | [`src/tools/doctor.rb:237`](../../src/tools/doctor.rb#L237) | `section_heap` | 0.0329 | **16** (False Simplicity) |
| 19 | [`src/tools/doctor.rb:240`](../../src/tools/doctor.rb#L240) | `section_heap` | 0.0329 | **16** (False Simplicity) |
| 20 | [`src/tools/doctor.rb:242`](../../src/tools/doctor.rb#L242) | `section_heap` | 0.0329 | **16** (False Simplicity) |
| 21 | [`src/tools/doctor.rb:243`](../../src/tools/doctor.rb#L243) | `section_heap` | 0.0329 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 22 | [`src/tools/doctor.rb:247`](../../src/tools/doctor.rb#L247) | `section_heap` | 0.0329 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 23 | [`src/tools/doctor.rb:264`](../../src/tools/doctor.rb#L264) | `section_heap` | 0.0329 | **16** (Neglected Path Conditions) |
| 24 | [`src/tools/doctor.rb:266`](../../src/tools/doctor.rb#L266) | `section_heap` | 0.0329 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 25 | [`src/tools/doctor.rb:268`](../../src/tools/doctor.rb#L268) | `section_heap` | 0.0329 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 26 | [`src/tools/doctor.rb:271`](../../src/tools/doctor.rb#L271) | `section_heap` | 0.0329 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 27 | [`src/tools/doctor.rb:273`](../../src/tools/doctor.rb#L273) | `section_heap` | 0.0329 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 28 | [`src/tools/doctor.rb:275`](../../src/tools/doctor.rb#L275) | `section_heap` | 0.0329 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 29 | [`src/tools/doctor.rb:283`](../../src/tools/doctor.rb#L283) | `section_heap` | 0.0329 | **16** (False Simplicity) |
| 30 | [`src/tools/doctor.rb:292`](../../src/tools/doctor.rb#L292) | `section_heap` | 0.0329 | **16** (False Simplicity) |
| 31 | [`src/tools/doctor.rb:295`](../../src/tools/doctor.rb#L295) | `section_heap` | 0.0329 | **16** (False Simplicity) |
| 32 | [`src/annotator/annotator.rb:3725`](../../src/annotator/annotator.rb#L3725) | `visit_StructLit` | 0.025 | **16** (False Simplicity) |
| 33 | [`src/backends/pipeline_host.rb:3740`](../../src/backends/pipeline_host.rb#L3740) | `lower_concurrent` | 0.2661 | **12** (False Simplicity) |
| 34 | [`src/mir/mir_lowering.rb:402`](../../src/mir/mir_lowering.rb#L402) | `next_stream_literal_id` | 1.0 | - |
| 35 | [`src/mir/mir_lowering.rb:2927`](../../src/mir/mir_lowering.rb#L2927) | `direct_index_get` | 1.0 | - |
| 36 | [`src/ast/type.rb:1776`](../../src/ast/type.rb#L1776) | `elem_has_heap_internals?` | 0.1749 | **12** † (Broken Protocols, Decision Pressure, False Simplicity, +1) |
| 37 | [`src/ast/ast.rb:907`](../../src/ast/ast.rb#L907) | `finalize_storage!` | 0.1573 | **12** (False Simplicity) |
| 38 | [`src/ast/ast.rb:912`](../../src/ast/ast.rb#L912) | `finalize_storage!` | 0.1573 | **12** (False Simplicity) |
| 39 | [`src/ast/ast.rb:988`](../../src/ast/ast.rb#L988) | `finalize_storage!` | 0.1573 | **12** (False Simplicity) |
| 40 | [`src/mir/lowering/control_flow.rb:300`](../../src/mir/lowering/control_flow.rb#L300) | `for_each_plan` | 0.0261 | **14** † (Decision Pressure, Derived-State Staleness, False Simplicity, +2) |
| 41 | [`src/annotator/annotator.rb:2238`](../../src/annotator/annotator.rb#L2238) | `visit_ReturnNode` | 0.025 | **14** (False Simplicity) |
| 42 | [`src/mir/hoist.rb:120`](../../src/mir/hoist.rb#L120) | `collect_stmt_hoists!` | 0.1464 | **12** (False Simplicity) |
| 43 | [`src/mir/hoist.rb:132`](../../src/mir/hoist.rb#L132) | `collect_stmt_hoists!` | 0.1464 | **12** † (Broken Protocols, Decision Pressure, False Simplicity, +1) |
| 44 | [`src/mir/hoist.rb:141`](../../src/mir/hoist.rb#L141) | `collect_stmt_hoists!` | 0.1464 | **12** (False Simplicity) |
| 45 | [`src/mir/hoist.rb:144`](../../src/mir/hoist.rb#L144) | `collect_stmt_hoists!` | 0.1464 | **12** (False Simplicity) |
| 46 | [`src/mir/escape_analysis.rb:821`](../../src/mir/escape_analysis.rb#L821) | `owning_return_needs_heap_placement?` | 0.1345 | **12** † (Decision Pressure, Derived-State Staleness, False Simplicity) |
| 47 | [`src/mir/escape_analysis.rb:824`](../../src/mir/escape_analysis.rb#L824) | `owning_return_needs_heap_placement?` | 0.1345 | **12** † (Decision Pressure, Derived-State Staleness, False Simplicity) |
| 48 | [`src/mir/escape_analysis.rb:831`](../../src/mir/escape_analysis.rb#L831) | `owning_return_needs_heap_placement?` | 0.1345 | **12** † (Decision Pressure, Derived-State Staleness, False Simplicity) |
| 49 | [`src/mir/mir_pass.rb:320`](../../src/mir/mir_pass.rb#L320) | `return_expr_needs_allocator?` | 0.2579 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 50 | [`src/mir/mir_pass.rb:321`](../../src/mir/mir_pass.rb#L321) | `return_expr_needs_allocator?` | 0.2579 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 51 | [`src/mir/mir_pass.rb:403`](../../src/mir/mir_pass.rb#L403) | `pre_mark_bg_resource_captures!` | 0.2579 | **10** (False Simplicity) |
| 52 | [`src/mir/mir_pass.rb:441`](../../src/mir/mir_pass.rb#L441) | `transform_body` | 0.2579 | **10** (False Simplicity) |
| 53 | [`src/mir/mir_pass.rb:547`](../../src/mir/mir_pass.rb#L547) | `walk_consumed` | 0.2579 | **10** † (Decision Pressure, False Simplicity, Neglected Path Conditions) |
| 54 | [`src/mir/mir_pass.rb:565`](../../src/mir/mir_pass.rb#L565) | `walk_consumed` | 0.2579 | **10** † (Decision Pressure, False Simplicity, Neglected Path Conditions) |
| 55 | [`src/mir/mir_pass.rb:568`](../../src/mir/mir_pass.rb#L568) | `walk_consumed` | 0.2579 | **10** (False Simplicity) |
| 56 | [`src/mir/mir_pass.rb:590`](../../src/mir/mir_pass.rb#L590) | `walk_consumed` | 0.2579 | **10** † (Decision Pressure, False Simplicity, Neglected Path Conditions) |
| 57 | [`src/mir/mir_pass.rb:681`](../../src/mir/mir_pass.rb#L681) | `stamp_match_as_cleanup!` | 0.2579 | **10** (False Simplicity) |
| 58 | [`src/mir/mir_pass.rb:690`](../../src/mir/mir_pass.rb#L690) | `stamp_match_as_cleanup!` | 0.2579 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 59 | [`src/ast/parser.rb:1283`](../../src/ast/parser.rb#L1283) | `parse_function_def` | 0.1132 | **12** † (Broken Protocols, Decision Pressure, False Simplicity, +2) |
| 60 | [`src/mir/mir_checker.rb:1579`](../../src/mir/mir_checker.rb#L1579) | `scan_expr_for_hpt_leak!` | 0.0869 | **12** † (Broken Protocols, Decision Pressure, False Simplicity, +1) |
| 61 | [`src/mir/fsm_transform/emit.rb:532`](../../src/mir/fsm_transform/emit.rb#L532) | `build_recursive` | 0.0843 | **12** † ⚠dup? (Decision Pressure, Derived-State Staleness, False Simplicity, +1) |
| 62 | [`src/mir/fsm_transform/emit.rb:559`](../../src/mir/fsm_transform/emit.rb#L559) | `build_recursive` | 0.0843 | **12** † ⚠dup? (Decision Pressure, Derived-State Staleness, False Simplicity, +1) |
| 63 | [`src/mir/fsm_transform/emit.rb:586`](../../src/mir/fsm_transform/emit.rb#L586) | `build_recursive` | 0.0843 | **12** † ⚠dup? (Decision Pressure, Derived-State Staleness, False Simplicity, +1) |
| 64 | [`src/mir/fsm_transform/emit.rb:609`](../../src/mir/fsm_transform/emit.rb#L609) | `build_recursive` | 0.0843 | **12** † ⚠dup? (Decision Pressure, Derived-State Staleness, False Simplicity, +1) |
| 65 | [`src/mir/fsm_transform/emit.rb:614`](../../src/mir/fsm_transform/emit.rb#L614) | `build_recursive` | 0.0843 | **12** (False Simplicity) |
| 66 | [`src/mir/fsm_transform/emit.rb:626`](../../src/mir/fsm_transform/emit.rb#L626) | `build_recursive` | 0.0843 | **12** (False Simplicity) |
| 67 | [`src/mir/fsm_transform/emit.rb:674`](../../src/mir/fsm_transform/emit.rb#L674) | `build_recursive` | 0.0843 | **12** † ⚠dup? (Decision Pressure, Derived-State Staleness, False Simplicity, +1) |
| 68 | [`src/mir/fsm_transform/emit.rb:766`](../../src/mir/fsm_transform/emit.rb#L766) | `build_recursive` | 0.0843 | **12** (False Simplicity) |
| 69 | [`src/mir/fsm_transform/emit.rb:771`](../../src/mir/fsm_transform/emit.rb#L771) | `build_recursive` | 0.0843 | **12** † ⚠dup? (Decision Pressure, Derived-State Staleness, False Simplicity, +1) |
| 70 | [`src/mir/fsm_lowering.rb:124`](../../src/mir/fsm_lowering.rb#L124) | `lower_step_stmts` | 0.0825 | **12** † ⚠dup? (Broken Protocols, Decision Pressure, False Simplicity, +2) |
| 71 | [`src/mir/fsm_lowering.rb:132`](../../src/mir/fsm_lowering.rb#L132) | `lower_step_stmts` | 0.0825 | **12** † ⚠dup? (Broken Protocols, Decision Pressure, False Simplicity, +2) |
| 72 | [`src/mir/fsm_lowering.rb:141`](../../src/mir/fsm_lowering.rb#L141) | `lower_step_stmts` | 0.0825 | **12** (Neglected Path Conditions) |
| 73 | [`src/mir/fsm_lowering.rb:150`](../../src/mir/fsm_lowering.rb#L150) | `lower_step_stmts` | 0.0825 | **12** † ⚠dup? (Broken Protocols, Decision Pressure, False Simplicity, +2) |
| 74 | [`src/mir/lowering/expressions.rb:1006`](../../src/mir/lowering/expressions.rb#L1006) | `index_access_value` | 0.08 | **12** † (Broken Protocols, Decision Pressure, False Simplicity, +2) |
| 75 | [`src/mir/lowering/expressions.rb:1035`](../../src/mir/lowering/expressions.rb#L1035) | `index_access_value` | 0.08 | **12** (False Simplicity, Neglected Path Conditions, Neglected Updates) |
| 76 | [`src/mir/lowering/expressions.rb:1038`](../../src/mir/lowering/expressions.rb#L1038) | `index_access_value` | 0.08 | **12** (Neglected Path Conditions) |
| 77 | [`src/mir/control_flow.rb:754`](../../src/mir/control_flow.rb#L754) | `transfer_stmt` | 0.2038 | **10** (False Simplicity) |
| 78 | [`src/mir/control_flow.rb:765`](../../src/mir/control_flow.rb#L765) | `transfer_stmt` | 0.2038 | **10** (Fat Unions) |
| 79 | [`src/mir/control_flow.rb:790`](../../src/mir/control_flow.rb#L790) | `transfer_stmt` | 0.2038 | **10** (False Simplicity) |
| 80 | [`src/mir/control_flow.rb:796`](../../src/mir/control_flow.rb#L796) | `transfer_stmt` | 0.2038 | **10** (False Simplicity) |

- ...(+1022 more genuine gaps)

> decomplex attribution on listed gaps: **348 span-precise**, **666 method-coarse (†)**, **142 ⚠dup?** (possibly redundant, not localised -- verify before testing). Coarse rows are whole-method: treat as a hint, not an arm-level discriminator.

## Category Summary
_3920 dark arms; only 1102 are genuine gaps. The rest are not test targets:_

| category | arms | % | what it means |
|---|---|---|---|
| type_norm | 1053 | 26.9% | type/nil guard -- likely dead if runtime contracts were stricter |
| dead | 737 | 18.8% | decision never executes in coverage -- audit as missing test or statically-dead code |
| defensive | 144 | 3.7% | inert / invariant-pinned -- accept, exclude from denominator |
| spurious | 49 | 1.3% | span-precise redundant/cloned decision (decomplex) -- refactor or delete, NOT a test target (coarse duplication never excludes -- it stays a gap, flagged ⚠dup?) |
| ffi | 0 | 0.0% | external/boundary call -- needs an integration test |
| diagnostic | 835 | 21.3% | error/raise/diagnostic path -- reachable only by invalid input (negative test) |
| genuine | 1102 | 28.1% | real reachable gap -- test it; ranked by fix-churn x decomplex structural deviance |

## Run Summary
- Repo: `/home/yahn/cheat`
- Files: 87; dark arms: 3920; genuine gaps: 1102
- General engine: categorizes uncovered branches, ranks genuine gaps by consumed boobytrap churn x optional decomplex structural deviance. Project lexicons (external-boundary methods and domain diagnostic methods) are caller-supplied, not baked in (see docs/agents/design.md).
- decomplex join is span-precise (the arm's line falls inside the flagged decision's source extent); `†` marks a (file, method) fallback when no flagged span contained the arm. A ranked candidate, not a verdict (Engler discipline).
