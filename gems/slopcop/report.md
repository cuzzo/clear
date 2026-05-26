# SlopCop Report

> Top true coverage gaps, ranked by fix-churn x structural
> deviance. Every dark arm is categorized; only GENUINE
> reachable ones are gaps. Apex = uncovered AND historically
> churned (boobytrap) AND structurally deviant (decomplex).
> Owns categorization; consumes boobytrap (churn) and
> optional decomplex (spurious filter + deviance rank).

## Top True Gaps (198) — test these, ranked by fix-churn

| # | gap | method | churn | decomplex deviance |
|---|---|---|---|---|
| 1 | [`src/mir/mir_lowering.rb:418`](../../src/mir/mir_lowering.rb#L418) | `place_string_or_for_heap_destination` | 1.0 | **12** † (Decision Pressure, Derived-State Staleness, False Simplicity) |
| 2 | [`src/mir/mir_lowering.rb:425`](../../src/mir/mir_lowering.rb#L425) | `place_string_or_for_heap_destination` | 1.0 | **12** (False Simplicity) |
| 3 | [`src/mir/mir_lowering.rb:428`](../../src/mir/mir_lowering.rb#L428) | `place_string_or_for_heap_destination` | 1.0 | **12** † (Decision Pressure, Derived-State Staleness, False Simplicity) |
| 4 | [`src/mir/mir_lowering.rb:429`](../../src/mir/mir_lowering.rb#L429) | `place_string_or_for_heap_destination` | 1.0 | **12** † (Decision Pressure, Derived-State Staleness, False Simplicity) |
| 5 | [`src/mir/mir_lowering.rb:2234`](../../src/mir/mir_lowering.rb#L2234) | `filter_zig_blocks` | 1.0 | **12** † ⚠dup? (Decision Pressure, Derived-State Staleness, False Simplicity, +1) |
| 6 | [`src/mir/mir_lowering.rb:1177`](../../src/mir/mir_lowering.rb#L1177) | `implicit_allocating_result_fact` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 7 | [`src/mir/mir_lowering.rb:2406`](../../src/mir/mir_lowering.rb#L2406) | `emit_builtin` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 8 | [`src/mir/mir_lowering.rb:480`](../../src/mir/mir_lowering.rb#L480) | `alloc_mark_type_info` | 1.0 | **8** (False Simplicity) |
| 9 | [`src/mir/mir_lowering.rb:1232`](../../src/mir/mir_lowering.rb#L1232) | `ownership_transfers_for_mir` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 10 | [`src/mir/mir_lowering.rb:1234`](../../src/mir/mir_lowering.rb#L1234) | `ownership_transfers_for_mir` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 11 | [`src/mir/mir_lowering.rb:1408`](../../src/mir/mir_lowering.rb#L1408) | `collect_moved_arg_roots` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 12 | [`src/mir/mir_lowering.rb:1543`](../../src/mir/mir_lowering.rb#L1543) | `lower_program` | 1.0 | **8** (False Simplicity) |
| 13 | [`src/mir/mir_lowering.rb:1553`](../../src/mir/mir_lowering.rb#L1553) | `lower_program` | 1.0 | **8** (False Simplicity) |
| 14 | [`src/mir/mir_lowering.rb:1562`](../../src/mir/mir_lowering.rb#L1562) | `lower_program` | 1.0 | **8** (False Simplicity) |
| 15 | [`src/mir/mir_lowering.rb:1907`](../../src/mir/mir_lowering.rb#L1907) | `lower_union_def` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 16 | [`src/mir/mir_lowering.rb:1916`](../../src/mir/mir_lowering.rb#L1916) | `lower_union_def` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 17 | [`src/mir/mir_lowering.rb:1921`](../../src/mir/mir_lowering.rb#L1921) | `lower_union_def` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 18 | [`src/mir/mir_lowering.rb:1954`](../../src/mir/mir_lowering.rb#L1954) | `lower_union_def` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 19 | [`src/mir/mir_lowering.rb:1957`](../../src/mir/mir_lowering.rb#L1957) | `lower_union_def` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 20 | [`src/mir/mir_lowering.rb:2523`](../../src/mir/mir_lowering.rb#L2523) | `strip_try` | 1.0 | **8** † (Broken Protocols, Derived-State Staleness, False Simplicity) |
| 21 | [`src/mir/mir_lowering.rb:2527`](../../src/mir/mir_lowering.rb#L2527) | `strip_try` | 1.0 | **8** † (Broken Protocols, Derived-State Staleness, False Simplicity) |
| 22 | [`src/mir/mir_lowering.rb:2638`](../../src/mir/mir_lowering.rb#L2638) | `owned_sink_plan` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 23 | [`src/mir/mir_lowering.rb:870`](../../src/mir/mir_lowering.rb#L870) | `visible_guarded_cleanup_names_for_transfer` | 1.0 | **4** † (Broken Protocols, False Simplicity) |
| 24 | [`src/mir/mir_lowering.rb:1367`](../../src/mir/mir_lowering.rb#L1367) | `with_ownership_consumption` | 1.0 | **4** (False Simplicity) |
| 25 | [`src/mir/mir_lowering.rb:1796`](../../src/mir/mir_lowering.rb#L1796) | `mir_cast` | 1.0 | **3** † (Decision Pressure) |
| 26 | [`src/mir/mir_lowering.rb:1797`](../../src/mir/mir_lowering.rb#L1797) | `mir_cast` | 1.0 | **3** † (Decision Pressure) |
| 27 | [`src/mir/mir_lowering.rb:1800`](../../src/mir/mir_lowering.rb#L1800) | `mir_cast` | 1.0 | **3** † (Decision Pressure) |
| 28 | [`src/mir/mir_lowering.rb:1801`](../../src/mir/mir_lowering.rb#L1801) | `mir_cast` | 1.0 | **3** † (Decision Pressure) |
| 29 | [`src/mir/mir_lowering.rb:2714`](../../src/mir/mir_lowering.rb#L2714) | `borrowed_union_sink_source?` | 1.0 | **3** † (Decision Pressure) |
| 30 | [`src/mir/mir_lowering.rb:458`](../../src/mir/mir_lowering.rb#L458) | `place_string_value_for_heap_destination` | 1.0 | **1** † (False Simplicity) |
| 31 | [`src/mir/mir_lowering.rb:503`](../../src/mir/mir_lowering.rb#L503) | `scoped_owning_branch_value` | 1.0 | **1** † (False Simplicity) |
| 32 | [`src/mir/mir_lowering.rb:507`](../../src/mir/mir_lowering.rb#L507) | `scoped_owning_branch_value` | 1.0 | **1** † (False Simplicity) |
| 33 | [`src/mir/mir_lowering.rb:510`](../../src/mir/mir_lowering.rb#L510) | `scoped_owning_branch_value` | 1.0 | **1** (False Simplicity) |
| 34 | [`src/mir/mir_lowering.rb:672`](../../src/mir/mir_lowering.rb#L672) | `lower_body` | 1.0 | **1** † (False Simplicity) |
| 35 | [`src/mir/mir_lowering.rb:681`](../../src/mir/mir_lowering.rb#L681) | `lower_body` | 1.0 | **1** (False Simplicity) |
| 36 | [`src/mir/mir_lowering.rb:853`](../../src/mir/mir_lowering.rb#L853) | `register_visible_alloc_names!` | 1.0 | **1** † (False Simplicity) |
| 37 | [`src/mir/mir_lowering.rb:1635`](../../src/mir/mir_lowering.rb#L1635) | `with_decl_alloc` | 1.0 | **1** † (False Simplicity) |
| 38 | [`src/mir/mir_lowering.rb:1639`](../../src/mir/mir_lowering.rb#L1639) | `with_decl_alloc` | 1.0 | **1** † (False Simplicity) |
| 39 | [`src/mir/mir_lowering.rb:2163`](../../src/mir/mir_lowering.rb#L2163) | `merge_module_schemas!` | 1.0 | **1** (False Simplicity) |
| 40 | [`src/mir/mir_lowering.rb:2341`](../../src/mir/mir_lowering.rb#L2341) | `lower_struct_pattern` | 1.0 | **1** † (False Simplicity) |
| 41 | [`src/mir/mir_lowering.rb:2345`](../../src/mir/mir_lowering.rb#L2345) | `lower_struct_pattern` | 1.0 | **1** † (False Simplicity) |
| 42 | [`src/mir/mir_lowering.rb:2585`](../../src/mir/mir_lowering.rb#L2585) | `with_fiber_capture_map` | 1.0 | **1** † (False Simplicity) |
| 43 | [`src/mir/mir_lowering.rb:2736`](../../src/mir/mir_lowering.rb#L2736) | `make_rc_retain` | 1.0 | **1** (False Simplicity) |
| 44 | [`src/mir/mir_lowering.rb:2738`](../../src/mir/mir_lowering.rb#L2738) | `make_rc_retain` | 1.0 | **1** † (False Simplicity) |
| 45 | [`src/mir/mir_checker.rb:1434`](../../src/mir/mir_checker.rb#L1434) | `scan_expr_for_hpt_leak!` | 0.0688 | **12** † (Broken Protocols, Decision Pressure, False Simplicity, +1) |
| 46 | [`src/mir/mir_lowering.rb:161`](../../src/mir/mir_lowering.rb#L161) | `(top-level)` | 1.0 | - |
| 47 | [`src/mir/mir_lowering.rb:191`](../../src/mir/mir_lowering.rb#L191) | `(top-level)` | 1.0 | - |
| 48 | [`src/mir/mir_lowering.rb:300`](../../src/mir/mir_lowering.rb#L300) | `runtime_binding_name` | 1.0 | - |
| 49 | [`src/mir/mir_lowering.rb:347`](../../src/mir/mir_lowering.rb#L347) | `destination_placement_plan` | 1.0 | **0** † ⚠dup? (Reification Misses) |
| 50 | [`src/mir/mir_lowering.rb:395`](../../src/mir/mir_lowering.rb#L395) | `place_owned_orelse_for_destination` | 1.0 | - |

- ...(+148 more genuine gaps)

> decomplex attribution on listed gaps: **36 span-precise**, **83 method-coarse (†)**, **4 ⚠dup?** (possibly redundant, not localised -- verify before testing). Coarse rows are whole-method: treat as a hint, not an arm-level discriminator.

## Category Summary
_999 dark arms; only 198 are genuine gaps. The rest are not test targets:_

| category | arms | % | what it means |
|---|---|---|---|
| type_norm | 240 | 24.0% | type/nil guard -- likely dead if the contract were strictly typed |
| dead | 14 | 1.4% | decision never executes in coverage -- audit as missing test or statically-dead code |
| defensive | 129 | 12.9% | inert / invariant-pinned -- accept, exclude from denominator |
| spurious | 0 | 0.0% | span-precise redundant/cloned decision (decomplex) -- refactor or delete, NOT a test target (coarse duplication never excludes -- it stays a gap, flagged ⚠dup?) |
| ffi | 25 | 2.5% | external/boundary call -- needs an integration test |
| diagnostic | 393 | 39.3% | error/raise path -- reachable only by invalid input (negative test) |
| genuine | 198 | 19.8% | real reachable gap -- test it; ranked by fix-churn x decomplex structural deviance |

## Run Summary
- Repo: `/home/yahn/cheat`
- Files: 3; dark arms: 999; genuine gaps: 198
- General engine: categorizes uncovered branches, ranks genuine gaps by consumed boobytrap churn x optional decomplex structural deviance. Project lexicon (external-boundary methods) is caller-supplied, not baked in (see docs/agents/design.md).
- decomplex join is span-precise (the arm's line falls inside the flagged decision's source extent); `†` marks a (file, method) fallback when no flagged span contained the arm. A ranked candidate, not a verdict (Engler discipline).
