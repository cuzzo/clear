# SlopCop Report

> Top true coverage gaps, ranked by fix-churn x structural
> deviance. Every dark arm is categorized; only GENUINE
> reachable ones are gaps. Apex = uncovered AND historically
> churned (boobytrap) AND structurally deviant (decomplex).
> Owns categorization; consumes boobytrap (churn) and
> optional decomplex (spurious filter + deviance rank).

## Top True Gaps (145) — test these, ranked by fix-churn

| # | gap | method | churn | decomplex deviance |
|---|---|---|---|---|
| 1 | [`src/mir/mir_lowering.rb:5977`](../../src/mir/mir_lowering.rb#L5977) | `lower_var_decl` | 1.0 | **20** (Derived-State Staleness) |
| 2 | [`src/mir/mir_lowering.rb:6058`](../../src/mir/mir_lowering.rb#L6058) | `lower_var_decl` | 1.0 | **20** (Derived-State Staleness) |
| 3 | [`src/mir/mir_lowering.rb:6091`](../../src/mir/mir_lowering.rb#L6091) | `lower_var_decl` | 1.0 | **20** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +5) |
| 4 | [`src/mir/mir_lowering.rb:6099`](../../src/mir/mir_lowering.rb#L6099) | `lower_var_decl` | 1.0 | **20** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +5) |
| 5 | [`src/mir/mir_lowering.rb:4963`](../../src/mir/mir_lowering.rb#L4963) | `lower_smooth` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 6 | [`src/mir/mir_lowering.rb:5016`](../../src/mir/mir_lowering.rb#L5016) | `lower_smooth` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 7 | [`src/mir/mir_lowering.rb:5018`](../../src/mir/mir_lowering.rb#L5018) | `lower_smooth` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 8 | [`src/mir/mir_lowering.rb:5032`](../../src/mir/mir_lowering.rb#L5032) | `lower_smooth` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 9 | [`src/mir/mir_lowering.rb:6360`](../../src/mir/mir_lowering.rb#L6360) | `lower_indexed_assignment` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 10 | [`src/mir/mir_lowering.rb:6361`](../../src/mir/mir_lowering.rb#L6361) | `lower_indexed_assignment` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 11 | [`src/mir/mir_lowering.rb:6362`](../../src/mir/mir_lowering.rb#L6362) | `lower_indexed_assignment` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 12 | [`src/mir/mir_lowering.rb:6984`](../../src/mir/mir_lowering.rb#L6984) | `lower_match` | 1.0 | **16** (False Simplicity) |
| 13 | [`src/mir/mir_lowering.rb:7008`](../../src/mir/mir_lowering.rb#L7008) | `lower_match` | 1.0 | **16** (Broken Protocols) |
| 14 | [`src/mir/mir_lowering.rb:7068`](../../src/mir/mir_lowering.rb#L7068) | `lower_match` | 1.0 | **16** (False Simplicity) |
| 15 | [`src/mir/mir_lowering.rb:7069`](../../src/mir/mir_lowering.rb#L7069) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 16 | [`src/mir/mir_lowering.rb:7088`](../../src/mir/mir_lowering.rb#L7088) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 17 | [`src/mir/mir_lowering.rb:7090`](../../src/mir/mir_lowering.rb#L7090) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 18 | [`src/mir/mir_lowering.rb:7093`](../../src/mir/mir_lowering.rb#L7093) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 19 | [`src/mir/mir_lowering.rb:7095`](../../src/mir/mir_lowering.rb#L7095) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 20 | [`src/mir/mir_lowering.rb:1571`](../../src/mir/mir_lowering.rb#L1571) | `build_catch_clauses` | 1.0 | **14** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 21 | [`src/mir/mir_lowering.rb:2402`](../../src/mir/mir_lowering.rb#L2402) | `lower_hash_lit` | 1.0 | **14** (Derived-State Staleness, Neglected Path Conditions) |
| 22 | [`src/mir/mir_lowering.rb:2403`](../../src/mir/mir_lowering.rb#L2403) | `lower_hash_lit` | 1.0 | **14** (Derived-State Staleness, Neglected Path Conditions) |
| 23 | [`src/mir/mir_lowering.rb:2429`](../../src/mir/mir_lowering.rb#L2429) | `lower_hash_lit` | 1.0 | **14** † (Decision Pressure, Derived-State Staleness, False Simplicity, +1) |
| 24 | [`src/mir/mir_lowering.rb:6823`](../../src/mir/mir_lowering.rb#L6823) | `lower_for_each` | 1.0 | **14** † ⚠dup? (Decision Pressure, Derived-State Staleness, False Simplicity, +2) |
| 25 | [`src/mir/mir_lowering.rb:6825`](../../src/mir/mir_lowering.rb#L6825) | `lower_for_each` | 1.0 | **14** † ⚠dup? (Decision Pressure, Derived-State Staleness, False Simplicity, +2) |
| 26 | [`src/mir/mir_lowering.rb:858`](../../src/mir/mir_lowering.rb#L858) | `build_drop_entry!` | 1.0 | **12** (Derived-State Staleness) |
| 27 | [`src/mir/mir_lowering.rb:880`](../../src/mir/mir_lowering.rb#L880) | `build_drop_entry!` | 1.0 | **12** (Decision Pressure, False Simplicity) |
| 28 | [`src/mir/mir_lowering.rb:2020`](../../src/mir/mir_lowering.rb#L2020) | `lower_intrinsic` | 1.0 | **12** (False Simplicity) |
| 29 | [`src/mir/mir_lowering.rb:2552`](../../src/mir/mir_lowering.rb#L2552) | `build_field_path_zig` | 1.0 | **12** (Neglected Conditions) |
| 30 | [`src/mir/mir_lowering.rb:2786`](../../src/mir/mir_lowering.rb#L2786) | `lower_with_block` | 1.0 | **12** † (Broken Protocols, Decision Pressure, False Simplicity, +2) |
| 31 | [`src/mir/mir_lowering.rb:2835`](../../src/mir/mir_lowering.rb#L2835) | `lower_with_block` | 1.0 | **12** † (Broken Protocols, Decision Pressure, False Simplicity, +2) |
| 32 | [`src/mir/mir_lowering.rb:2851`](../../src/mir/mir_lowering.rb#L2851) | `lower_with_block` | 1.0 | **12** † (Broken Protocols, Decision Pressure, False Simplicity, +2) |
| 33 | [`src/mir/mir_lowering.rb:5351`](../../src/mir/mir_lowering.rb#L5351) | `lower_get_index` | 1.0 | **12** † (Broken Protocols, Decision Pressure, False Simplicity, +2) |
| 34 | [`src/mir/mir_lowering.rb:5371`](../../src/mir/mir_lowering.rb#L5371) | `lower_struct_lit` | 1.0 | **12** † (Decision Pressure, Derived-State Staleness, False Simplicity) |
| 35 | [`src/mir/mir_lowering.rb:5372`](../../src/mir/mir_lowering.rb#L5372) | `lower_struct_lit` | 1.0 | **12** † (Decision Pressure, Derived-State Staleness, False Simplicity) |
| 36 | [`src/mir/mir_lowering.rb:5426`](../../src/mir/mir_lowering.rb#L5426) | `lower_struct_lit` | 1.0 | **12** † (Decision Pressure, Derived-State Staleness, False Simplicity) |
| 37 | [`src/mir/mir_lowering.rb:951`](../../src/mir/mir_lowering.rb#L951) | `lower_struct_def` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity, +1) |
| 38 | [`src/mir/mir_lowering.rb:1382`](../../src/mir/mir_lowering.rb#L1382) | `lower_function_def` | 1.0 | **10** † ⚠dup? (Decision Pressure, False Simplicity, Missing Abstractions, +1) |
| 39 | [`src/mir/mir_lowering.rb:1528`](../../src/mir/mir_lowering.rb#L1528) | `build_post_outer_fn` | 1.0 | **10** † ⚠dup? (Broken Protocols, Decision Pressure, False Simplicity, +2) |
| 40 | [`src/mir/mir_lowering.rb:1647`](../../src/mir/mir_lowering.rb#L1647) | `walk_catch_body_for_reassigns` | 1.0 | **10** (Broken Protocols, False Simplicity) |
| 41 | [`src/mir/mir_lowering.rb:1658`](../../src/mir/mir_lowering.rb#L1658) | `walk_catch_body_for_reassigns` | 1.0 | **10** (Broken Protocols) |
| 42 | [`src/mir/mir_lowering.rb:3100`](../../src/mir/mir_lowering.rb#L3100) | `emit_fallible_lock_binding` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 43 | [`src/mir/mir_lowering.rb:4801`](../../src/mir/mir_lowering.rb#L4801) | `lower_binary_op` | 1.0 | **10** † (Decision Pressure, Derived-State Staleness) |
| 44 | [`src/mir/mir_lowering.rb:4817`](../../src/mir/mir_lowering.rb#L4817) | `lower_binary_op` | 1.0 | **10** † (Decision Pressure, Derived-State Staleness) |
| 45 | [`src/mir/mir_lowering.rb:4827`](../../src/mir/mir_lowering.rb#L4827) | `lower_binary_op` | 1.0 | **10** † (Decision Pressure, Derived-State Staleness) |
| 46 | [`src/mir/mir_lowering.rb:4828`](../../src/mir/mir_lowering.rb#L4828) | `lower_binary_op` | 1.0 | **10** † (Decision Pressure, Derived-State Staleness) |
| 47 | [`src/mir/mir_lowering.rb:4861`](../../src/mir/mir_lowering.rb#L4861) | `lower_binary_op` | 1.0 | **10** † (Decision Pressure, Derived-State Staleness) |
| 48 | [`src/mir/mir_lowering.rb:6189`](../../src/mir/mir_lowering.rb#L6189) | `lower_bind_expr` | 1.0 | **10** (Broken Protocols) |
| 49 | [`src/mir/mir_lowering.rb:260`](../../src/mir/mir_lowering.rb#L260) | `owned_value_temp_needs_cleanup?` | 1.0 | **8** (Broken Protocols) |
| 50 | [`src/mir/mir_lowering.rb:289`](../../src/mir/mir_lowering.rb#L289) | `copy_container_borrow_if_needed` | 1.0 | **8** † (Broken Protocols, Decision Pressure) |

- ...(+95 more genuine gaps)

> decomplex attribution on listed gaps: **34 span-precise**, **100 method-coarse (†)**, **11 ⚠dup?** (possibly redundant, not localised -- verify before testing). Coarse rows are whole-method: treat as a hint, not an arm-level discriminator.

## Category Summary
_935 dark arms; only 145 are genuine gaps. The rest are not test targets:_

| category | arms | % | what it means |
|---|---|---|---|
| type_norm | 194 | 20.7% | type/nil guard -- likely dead if the contract were strictly typed |
| dead | 36 | 3.9% | decision never executes -- audit as dead code, delete |
| defensive | 82 | 8.8% | inert / invariant-pinned -- accept, exclude from denominator |
| spurious | 13 | 1.4% | span-precise redundant/cloned decision (decomplex) -- refactor or delete, NOT a test target (coarse duplication never excludes -- it stays a gap, flagged ⚠dup?) |
| ffi | 37 | 4.0% | external/boundary call -- needs an integration test |
| diagnostic | 428 | 45.8% | error/raise path -- reachable only by invalid input (negative test) |
| genuine | 145 | 15.5% | real reachable gap -- test it; ranked by fix-churn x decomplex structural deviance |

## Run Summary
- Repo: `/home/yahn/cheat`
- Files: 3; dark arms: 935; genuine gaps: 145
- General engine: categorizes uncovered branches, ranks genuine gaps by consumed boobytrap churn x optional decomplex structural deviance. Project lexicon (external-boundary methods) is caller-supplied, not baked in (see docs/agents/design.md).
- decomplex join is span-precise (the arm's line falls inside the flagged decision's source extent); `†` marks a (file, method) fallback when no flagged span contained the arm. A ranked candidate, not a verdict (Engler discipline).
