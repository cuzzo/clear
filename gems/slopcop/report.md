# SlopCop Report

> Top true coverage gaps, ranked by fix-churn x structural
> deviance. Every dark arm is categorized; only GENUINE
> reachable ones are gaps. Apex = uncovered AND historically
> churned (boobytrap) AND structurally deviant (decomplex).
> Owns categorization; consumes boobytrap (churn) and
> optional decomplex (spurious filter + deviance rank).

## Top True Gaps (86) — test these, ranked by fix-churn

| # | gap | method | churn | decomplex deviance |
|---|---|---|---|---|
| 1 | [`src/mir/mir_lowering.rb:1395`](../../src/mir/mir_lowering.rb#L1395) | `implicit_allocating_result_fact` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 2 | [`src/mir/mir_lowering.rb:906`](../../src/mir/mir_lowering.rb#L906) | `append_transfer_marks_to_body!` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 3 | [`src/mir/mir_lowering.rb:1476`](../../src/mir/mir_lowering.rb#L1476) | `ownership_transfer_operands_for_node` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 4 | [`src/mir/mir_lowering.rb:1876`](../../src/mir/mir_lowering.rb#L1876) | `transfer_binding_name` | 1.0 | **8** (Broken Protocols) |
| 5 | [`src/mir/mir_lowering.rb:232`](../../src/mir/mir_lowering.rb#L232) | `ast_void_type?` | 1.0 | **3** † (Decision Pressure) |
| 6 | [`src/mir/mir_lowering.rb:1687`](../../src/mir/mir_lowering.rb#L1687) | `ownership_operands_for_sink_value` | 1.0 | **3** † (Decision Pressure) |
| 7 | [`src/mir/mir_lowering.rb:1938`](../../src/mir/mir_lowering.rb#L1938) | `lower_body_with_break` | 1.0 | **3** † (Decision Pressure) |
| 8 | [`src/mir/mir_lowering.rb:1943`](../../src/mir/mir_lowering.rb#L1943) | `lower_body_with_break` | 1.0 | **3** † (Decision Pressure) |
| 9 | [`src/mir/mir_lowering.rb:2159`](../../src/mir/mir_lowering.rb#L2159) | `extract_root_var_name` | 1.0 | **3** † (Decision Pressure) |
| 10 | [`src/mir/mir_lowering.rb:553`](../../src/mir/mir_lowering.rb#L553) | `place_string_or_for_heap_destination` | 1.0 | **2** † (False Simplicity, Neglected Updates) |
| 11 | [`src/mir/mir_lowering.rb:557`](../../src/mir/mir_lowering.rb#L557) | `place_string_or_for_heap_destination` | 1.0 | **2** † (False Simplicity, Neglected Updates) |
| 12 | [`src/mir/mir_lowering.rb:565`](../../src/mir/mir_lowering.rb#L565) | `place_string_or_for_heap_destination` | 1.0 | **2** † (False Simplicity, Neglected Updates) |
| 13 | [`src/mir/mir_lowering.rb:959`](../../src/mir/mir_lowering.rb#L959) | `materialize_statement_discard` | 1.0 | **2** † (False Simplicity, Neglected Updates) |
| 14 | [`src/mir/escape_analysis.rb:821`](../../src/mir/escape_analysis.rb#L821) | `owning_return_needs_heap_placement?` | 0.1344 | **12** † (Decision Pressure, Derived-State Staleness, False Simplicity) |
| 15 | [`src/mir/escape_analysis.rb:824`](../../src/mir/escape_analysis.rb#L824) | `owning_return_needs_heap_placement?` | 0.1344 | **12** † (Decision Pressure, Derived-State Staleness, False Simplicity) |
| 16 | [`src/mir/escape_analysis.rb:831`](../../src/mir/escape_analysis.rb#L831) | `owning_return_needs_heap_placement?` | 0.1344 | **12** † (Decision Pressure, Derived-State Staleness, False Simplicity) |
| 17 | [`src/mir/mir_lowering.rb:352`](../../src/mir/mir_lowering.rb#L352) | `place_value_for_destination` | 1.0 | **1** † (Broken Protocols) |
| 18 | [`src/mir/mir_lowering.rb:482`](../../src/mir/mir_lowering.rb#L482) | `place_owned_try_catch_for_destination` | 1.0 | **1** † (False Simplicity) |
| 19 | [`src/mir/mir_lowering.rb:485`](../../src/mir/mir_lowering.rb#L485) | `place_owned_try_catch_for_destination` | 1.0 | **1** † (False Simplicity) |
| 20 | [`src/mir/mir_lowering.rb:600`](../../src/mir/mir_lowering.rb#L600) | `place_string_value_for_heap_destination` | 1.0 | **1** (False Simplicity) |
| 21 | [`src/mir/mir_lowering.rb:832`](../../src/mir/mir_lowering.rb#L832) | `lower_body` | 1.0 | **1** † (False Simplicity) |
| 22 | [`src/mir/mir_lowering.rb:1368`](../../src/mir/mir_lowering.rb#L1368) | `finalize_nested_mir_expr_bodies!` | 1.0 | **1** † (False Simplicity) |
| 23 | [`src/mir/mir_lowering.rb:1903`](../../src/mir/mir_lowering.rb#L1903) | `discard_owned_zig_type` | 1.0 | **1** † (False Simplicity) |
| 24 | [`src/mir/mir_lowering.rb:1906`](../../src/mir/mir_lowering.rb#L1906) | `discard_owned_zig_type` | 1.0 | **1** † (False Simplicity) |
| 25 | [`src/mir/mir_lowering.rb:2595`](../../src/mir/mir_lowering.rb#L2595) | `merge_module_schemas!` | 1.0 | **1** † (False Simplicity) |
| 26 | [`src/mir/mir_lowering.rb:2598`](../../src/mir/mir_lowering.rb#L2598) | `merge_module_schemas!` | 1.0 | **1** † (False Simplicity) |
| 27 | [`src/mir/mir_lowering.rb:2601`](../../src/mir/mir_lowering.rb#L2601) | `merge_module_schemas!` | 1.0 | **1** † (False Simplicity) |
| 28 | [`src/mir/mir_lowering.rb:2802`](../../src/mir/mir_lowering.rb#L2802) | `zig_format_for_type` | 1.0 | **1** † (Broken Protocols) |
| 29 | [`src/mir/control_flow.rb:1382`](../../src/mir/control_flow.rb#L1382) | `update_shard_contexts!` | 0.2036 | **10** (False Simplicity) |
| 30 | [`src/mir/control_flow.rb:1386`](../../src/mir/control_flow.rb#L1386) | `update_shard_contexts!` | 0.2036 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 31 | [`src/mir/mir_lowering.rb:579`](../../src/mir/mir_lowering.rb#L579) | `place_owned_branch_value_for_destination` | 1.0 | - |
| 32 | [`src/mir/mir_lowering.rb:2496`](../../src/mir/mir_lowering.rb#L2496) | `lower_or_exit` | 1.0 | - |
| 33 | [`src/mir/escape_analysis.rb:239`](../../src/mir/escape_analysis.rb#L239) | `unify_caller_attr` | 0.1344 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 34 | [`src/mir/escape_analysis.rb:501`](../../src/mir/escape_analysis.rb#L501) | `mark_capture_analysis_heap!` | 0.1344 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 35 | [`src/mir/control_flow.rb:140`](../../src/mir/control_flow.rb#L140) | `build_body` | 0.2036 | **8** † (Decision Pressure, False Simplicity) |
| 36 | [`src/mir/control_flow.rb:279`](../../src/mir/control_flow.rb#L279) | `stmt_can_fail?` | 0.2036 | **8** † (Broken Protocols, Decision Pressure) |
| 37 | [`src/mir/control_flow.rb:436`](../../src/mir/control_flow.rb#L436) | `cleanup_summary` | 0.2036 | **8** † (Decision Pressure, False Simplicity) |
| 38 | [`src/mir/control_flow.rb:714`](../../src/mir/control_flow.rb#L714) | `make_owner_entry` | 0.2036 | **8** (Decision Pressure) |
| 39 | [`src/mir/control_flow.rb:715`](../../src/mir/control_flow.rb#L715) | `make_owner_entry` | 0.2036 | **8** † (Decision Pressure, False Simplicity) |
| 40 | [`src/mir/control_flow.rb:754`](../../src/mir/control_flow.rb#L754) | `transfer_stmt` | 0.2036 | **8** (False Simplicity) |
| 41 | [`src/mir/control_flow.rb:765`](../../src/mir/control_flow.rb#L765) | `transfer_stmt` | 0.2036 | **8** (Fat Unions) |
| 42 | [`src/mir/control_flow.rb:790`](../../src/mir/control_flow.rb#L790) | `transfer_stmt` | 0.2036 | **8** (False Simplicity) |
| 43 | [`src/mir/control_flow.rb:796`](../../src/mir/control_flow.rb#L796) | `transfer_stmt` | 0.2036 | **8** (False Simplicity) |
| 44 | [`src/mir/control_flow.rb:823`](../../src/mir/control_flow.rb#L823) | `collect_ownership_transfers` | 0.2036 | **8** † (Decision Pressure, False Simplicity) |
| 45 | [`src/mir/control_flow.rb:854`](../../src/mir/control_flow.rb#L854) | `collect_ownership_transfers` | 0.2036 | **8** (False Simplicity) |
| 46 | [`src/mir/control_flow.rb:879`](../../src/mir/control_flow.rb#L879) | `collect_ownership_transfers` | 0.2036 | **8** (False Simplicity) |
| 47 | [`src/mir/control_flow.rb:883`](../../src/mir/control_flow.rb#L883) | `collect_ownership_transfers` | 0.2036 | **8** (False Simplicity) |
| 48 | [`src/mir/control_flow.rb:900`](../../src/mir/control_flow.rb#L900) | `collect_explicit_in` | 0.2036 | **8** † ⚠dup? (Decision Pressure, False Simplicity, Missing Abstractions) |
| 49 | [`src/mir/control_flow.rb:910`](../../src/mir/control_flow.rb#L910) | `collect_explicit_moves` | 0.2036 | **8** † ⚠dup? (Decision Pressure, False Simplicity, Missing Abstractions) |
| 50 | [`src/mir/control_flow.rb:942`](../../src/mir/control_flow.rb#L942) | `collect_share_transfer` | 0.2036 | **8** † (Decision Pressure, False Simplicity) |
| 51 | [`src/mir/control_flow.rb:944`](../../src/mir/control_flow.rb#L944) | `collect_share_transfer` | 0.2036 | **8** (False Simplicity) |
| 52 | [`src/mir/control_flow.rb:1532`](../../src/mir/control_flow.rb#L1532) | `handle_with_block` | 0.2036 | **8** † (Decision Pressure, False Simplicity) |
| 53 | [`src/mir/escape_analysis.rb:177`](../../src/mir/escape_analysis.rb#L177) | `propagate_caller_sync!` | 0.1344 | **8** † (Decision Pressure, False Simplicity) |
| 54 | [`src/mir/escape_analysis.rb:426`](../../src/mir/escape_analysis.rb#L426) | `mark_receiver_allocations_in_loop!` | 0.1344 | **8** † ⚠dup? (Decision Pressure, False Simplicity, Missing Abstractions) |
| 55 | [`src/mir/escape_analysis.rb:428`](../../src/mir/escape_analysis.rb#L428) | `mark_receiver_allocations_in_loop!` | 0.1344 | **8** (False Simplicity) |
| 56 | [`src/mir/escape_analysis.rb:524`](../../src/mir/escape_analysis.rb#L524) | `mark_takes_args_heap!` | 0.1344 | **8** † (Decision Pressure, False Simplicity) |
| 57 | [`src/mir/escape_analysis.rb:607`](../../src/mir/escape_analysis.rb#L607) | `propagate_hoist_dependencies!` | 0.1344 | **8** † ⚠dup? (Decision Pressure, False Simplicity, Missing Abstractions) |
| 58 | [`src/mir/escape_analysis.rb:756`](../../src/mir/escape_analysis.rb#L756) | `binding_symbol_map` | 0.1344 | **8** (False Simplicity) |
| 59 | [`src/mir/escape_analysis.rb:961`](../../src/mir/escape_analysis.rb#L961) | `heap_return_from_args?` | 0.1344 | **8** † (Decision Pressure, False Simplicity) |
| 60 | [`src/mir/control_flow.rb:1343`](../../src/mir/control_flow.rb#L1343) | `outer_frame_receiver_alloc?` | 0.2036 | **6** † ⚠dup? (Decision Pressure, Missing Abstractions) |
| 61 | [`src/mir/control_flow.rb:38`](../../src/mir/control_flow.rb#L38) | `walk_expr_node` | 0.2036 | **4** † (Broken Protocols, False Simplicity) |
| 62 | [`src/mir/escape_analysis.rb:374`](../../src/mir/escape_analysis.rb#L374) | `aggregate_owner_requires_heap?` | 0.1344 | **3** † (Decision Pressure) |
| 63 | [`src/mir/escape_analysis.rb:376`](../../src/mir/escape_analysis.rb#L376) | `aggregate_owner_requires_heap?` | 0.1344 | **3** † (Decision Pressure) |
| 64 | [`src/mir/escape_analysis.rb:915`](../../src/mir/escape_analysis.rb#L915) | `call_result_is_heap?` | 0.1344 | **3** † (Decision Pressure) |
| 65 | [`src/mir/escape_analysis.rb:919`](../../src/mir/escape_analysis.rb#L919) | `call_result_is_heap?` | 0.1344 | **3** † (Decision Pressure) |
| 66 | [`src/mir/escape_analysis.rb:920`](../../src/mir/escape_analysis.rb#L920) | `call_result_is_heap?` | 0.1344 | **3** † (Decision Pressure) |
| 67 | [`src/mir/control_flow.rb:66`](../../src/mir/control_flow.rb#L66) | `add_successor` | 0.2036 | **1** (False Simplicity) |
| 68 | [`src/mir/control_flow.rb:67`](../../src/mir/control_flow.rb#L67) | `add_successor` | 0.2036 | **1** (False Simplicity) |
| 69 | [`src/mir/control_flow.rb:351`](../../src/mir/control_flow.rb#L351) | `(top-level)` | 0.2036 | **1** † (False Simplicity) |
| 70 | [`src/mir/control_flow.rb:629`](../../src/mir/control_flow.rb#L629) | `init_entry_state` | 0.2036 | **1** † (False Simplicity) |
| 71 | [`src/mir/control_flow.rb:1291`](../../src/mir/control_flow.rb#L1291) | `analyze!` | 0.2036 | **1** † (False Simplicity) |
| 72 | [`src/mir/control_flow.rb:1481`](../../src/mir/control_flow.rb#L1481) | `line_info` | 0.2036 | **1** (Broken Protocols) |
| 73 | [`src/mir/escape_analysis.rb:81`](../../src/mir/escape_analysis.rb#L81) | `apply!` | 0.1344 | **1** (False Simplicity) |
| 74 | [`src/mir/escape_analysis.rb:85`](../../src/mir/escape_analysis.rb#L85) | `apply!` | 0.1344 | **1** (False Simplicity) |
| 75 | [`src/mir/escape_analysis.rb:86`](../../src/mir/escape_analysis.rb#L86) | `apply!` | 0.1344 | **1** (False Simplicity) |
| 76 | [`src/mir/escape_analysis.rb:90`](../../src/mir/escape_analysis.rb#L90) | `apply!` | 0.1344 | **1** † (False Simplicity) |
| 77 | [`src/mir/escape_analysis.rb:111`](../../src/mir/escape_analysis.rb#L111) | `validate_escape_sinks!` | 0.1344 | **1** (False Simplicity) |
| 78 | [`src/mir/escape_analysis.rb:112`](../../src/mir/escape_analysis.rb#L112) | `validate_escape_sinks!` | 0.1344 | **1** (False Simplicity) |
| 79 | [`src/mir/escape_analysis.rb:114`](../../src/mir/escape_analysis.rb#L114) | `validate_escape_sinks!` | 0.1344 | **1** † (False Simplicity) |
| 80 | [`src/mir/escape_analysis.rb:129`](../../src/mir/escape_analysis.rb#L129) | `validate_handler_registry!` | 0.1344 | **1** (False Simplicity) |
| 81 | [`src/mir/escape_analysis.rb:132`](../../src/mir/escape_analysis.rb#L132) | `validate_handler_registry!` | 0.1344 | **1** † (False Simplicity) |
| 82 | [`src/mir/escape_analysis.rb:699`](../../src/mir/escape_analysis.rb#L699) | `type_requires_owned_storage?` | 0.1344 | **1** † (Broken Protocols) |
| 83 | [`src/mir/escape_analysis.rb:701`](../../src/mir/escape_analysis.rb#L701) | `type_requires_owned_storage?` | 0.1344 | **1** † (Broken Protocols) |
| 84 | [`src/mir/escape_analysis.rb:1048`](../../src/mir/escape_analysis.rb#L1048) | `mark_reassigned_symbol_heap!` | 0.1344 | **1** † (False Simplicity) |
| 85 | [`src/mir/control_flow.rb:681`](../../src/mir/control_flow.rb#L681) | `join_state` | 0.2036 | - |
| 86 | [`src/mir/control_flow.rb:682`](../../src/mir/control_flow.rb#L682) | `join_state` | 0.2036 | - |

> decomplex attribution on listed gaps: **23 span-precise**, **59 method-coarse (†)**, **5 ⚠dup?** (possibly redundant, not localised -- verify before testing). Coarse rows are whole-method: treat as a hint, not an arm-level discriminator.

## Category Summary
_341 dark arms; only 86 are genuine gaps. The rest are not test targets:_

| category | arms | % | what it means |
|---|---|---|---|
| type_norm | 137 | 40.2% | type/nil guard -- likely dead if the contract were strictly typed |
| dead | 38 | 11.1% | decision never executes in coverage -- audit as missing test or statically-dead code |
| defensive | 5 | 1.5% | inert / invariant-pinned -- accept, exclude from denominator |
| spurious | 1 | 0.3% | span-precise redundant/cloned decision (decomplex) -- refactor or delete, NOT a test target (coarse duplication never excludes -- it stays a gap, flagged ⚠dup?) |
| ffi | 4 | 1.2% | external/boundary call -- needs an integration test |
| diagnostic | 70 | 20.5% | error/raise path -- reachable only by invalid input (negative test) |
| genuine | 86 | 25.2% | real reachable gap -- test it; ranked by fix-churn x decomplex structural deviance |

## Run Summary
- Repo: `/home/yahn/cheat`
- Files: 3; dark arms: 341; genuine gaps: 86
- General engine: categorizes uncovered branches, ranks genuine gaps by consumed boobytrap churn x optional decomplex structural deviance. Project lexicon (external-boundary methods) is caller-supplied, not baked in (see docs/agents/design.md).
- decomplex join is span-precise (the arm's line falls inside the flagged decision's source extent); `†` marks a (file, method) fallback when no flagged span contained the arm. A ranked candidate, not a verdict (Engler discipline).
