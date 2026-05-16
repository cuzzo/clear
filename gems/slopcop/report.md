# SlopCop Report

> Top true coverage gaps to test, ranked by fix-churn.
> Every dark branch arm is categorized; only the GENUINE
> reachable ones are gaps worth testing. Owns
> categorization; consumes fix-cache for churn.

## Top True Gaps (273) — test these, ranked by fix-churn

| # | gap | method | churn |
|---|---|---|---|
| 1 | [`src/mir/mir_lowering.rb:226`](../../src/mir/mir_lowering.rb#L226) | `hoist_alloc` | 1.0 |
| 2 | [`src/mir/mir_lowering.rb:244`](../../src/mir/mir_lowering.rb#L244) | `hoist_owned_value_temp` | 1.0 |
| 3 | [`src/mir/mir_lowering.rb:255`](../../src/mir/mir_lowering.rb#L255) | `owned_value_temp_needs_cleanup?` | 1.0 |
| 4 | [`src/mir/mir_lowering.rb:260`](../../src/mir/mir_lowering.rb#L260) | `owned_value_temp_needs_cleanup?` | 1.0 |
| 5 | [`src/mir/mir_lowering.rb:261`](../../src/mir/mir_lowering.rb#L261) | `owned_value_temp_needs_cleanup?` | 1.0 |
| 6 | [`src/mir/mir_lowering.rb:270`](../../src/mir/mir_lowering.rb#L270) | `container_borrow_expr?` | 1.0 |
| 7 | [`src/mir/mir_lowering.rb:289`](../../src/mir/mir_lowering.rb#L289) | `copy_container_borrow_if_needed` | 1.0 |
| 8 | [`src/mir/mir_lowering.rb:290`](../../src/mir/mir_lowering.rb#L290) | `copy_container_borrow_if_needed` | 1.0 |
| 9 | [`src/mir/mir_lowering.rb:361`](../../src/mir/mir_lowering.rb#L361) | `cleanup_entry_for_heap_result` | 1.0 |
| 10 | [`src/mir/mir_lowering.rb:362`](../../src/mir/mir_lowering.rb#L362) | `cleanup_entry_for_heap_result` | 1.0 |
| 11 | [`src/mir/mir_lowering.rb:369`](../../src/mir/mir_lowering.rb#L369) | `cleanup_entry_for_heap_result` | 1.0 |
| 12 | [`src/mir/mir_lowering.rb:435`](../../src/mir/mir_lowering.rb#L435) | `lower` | 1.0 |
| 13 | [`src/mir/mir_lowering.rb:462`](../../src/mir/mir_lowering.rb#L462) | `lower` | 1.0 |
| 14 | [`src/mir/mir_lowering.rb:499`](../../src/mir/mir_lowering.rb#L499) | `lower` | 1.0 |
| 15 | [`src/mir/mir_lowering.rb:517`](../../src/mir/mir_lowering.rb#L517) | `lower_body` | 1.0 |
| 16 | [`src/mir/mir_lowering.rb:529`](../../src/mir/mir_lowering.rb#L529) | `lower_body` | 1.0 |
| 17 | [`src/mir/mir_lowering.rb:544`](../../src/mir/mir_lowering.rb#L544) | `lower_body_with_break` | 1.0 |
| 18 | [`src/mir/mir_lowering.rb:552`](../../src/mir/mir_lowering.rb#L552) | `lower_body_with_break` | 1.0 |
| 19 | [`src/mir/mir_lowering.rb:557`](../../src/mir/mir_lowering.rb#L557) | `lower_body_with_break` | 1.0 |
| 20 | [`src/mir/mir_lowering.rb:583`](../../src/mir/mir_lowering.rb#L583) | `lower_program` | 1.0 |
| 21 | [`src/mir/mir_lowering.rb:589`](../../src/mir/mir_lowering.rb#L589) | `lower_program` | 1.0 |
| 22 | [`src/mir/mir_lowering.rb:674`](../../src/mir/mir_lowering.rb#L674) | `alloc_expr` | 1.0 |
| 23 | [`src/mir/mir_lowering.rb:681`](../../src/mir/mir_lowering.rb#L681) | `alloc_from_sym` | 1.0 |
| 24 | [`src/mir/mir_lowering.rb:682`](../../src/mir/mir_lowering.rb#L682) | `alloc_from_sym` | 1.0 |
| 25 | [`src/mir/mir_lowering.rb:700`](../../src/mir/mir_lowering.rb#L700) | `coerce_stdlib_arg` | 1.0 |
| 26 | [`src/mir/mir_lowering.rb:709`](../../src/mir/mir_lowering.rb#L709) | `coerce_stdlib_arg` | 1.0 |
| 27 | [`src/mir/mir_lowering.rb:750`](../../src/mir/mir_lowering.rb#L750) | `resolve_alloc_sym` | 1.0 |
| 28 | [`src/mir/mir_lowering.rb:774`](../../src/mir/mir_lowering.rb#L774) | `alloc_zig_str` | 1.0 |
| 29 | [`src/mir/mir_lowering.rb:775`](../../src/mir/mir_lowering.rb#L775) | `alloc_zig_str` | 1.0 |
| 30 | [`src/mir/mir_lowering.rb:893`](../../src/mir/mir_lowering.rb#L893) | `resolve_decl_stdlib_alloc` | 1.0 |
| 31 | [`src/mir/mir_lowering.rb:915`](../../src/mir/mir_lowering.rb#L915) | `lower_promote` | 1.0 |
| 32 | [`src/mir/mir_lowering.rb:951`](../../src/mir/mir_lowering.rb#L951) | `lower_struct_def` | 1.0 |
| 33 | [`src/mir/mir_lowering.rb:1061`](../../src/mir/mir_lowering.rb#L1061) | `lower_union_def` | 1.0 |
| 34 | [`src/mir/mir_lowering.rb:1245`](../../src/mir/mir_lowering.rb#L1245) | `lower_function_def` | 1.0 |
| 35 | [`src/mir/mir_lowering.rb:1434`](../../src/mir/mir_lowering.rb#L1434) | `lower_function_def` | 1.0 |
| 36 | [`src/mir/mir_lowering.rb:1519`](../../src/mir/mir_lowering.rb#L1519) | `build_post_outer_fn` | 1.0 |
| 37 | [`src/mir/mir_lowering.rb:1528`](../../src/mir/mir_lowering.rb#L1528) | `build_post_outer_fn` | 1.0 |
| 38 | [`src/mir/mir_lowering.rb:1602`](../../src/mir/mir_lowering.rb#L1602) | `build_catch_clauses` | 1.0 |
| 39 | [`src/mir/mir_lowering.rb:1647`](../../src/mir/mir_lowering.rb#L1647) | `collect_catch_reassigns` | 1.0 |
| 40 | [`src/mir/mir_lowering.rb:1662`](../../src/mir/mir_lowering.rb#L1662) | `walk_catch_body_for_reassigns` | 1.0 |
| 41 | [`src/mir/mir_lowering.rb:1672`](../../src/mir/mir_lowering.rb#L1672) | `walk_catch_body_for_reassigns` | 1.0 |
| 42 | [`src/mir/mir_lowering.rb:1675`](../../src/mir/mir_lowering.rb#L1675) | `walk_catch_body_for_reassigns` | 1.0 |
| 43 | [`src/mir/mir_lowering.rb:1856`](../../src/mir/mir_lowering.rb#L1856) | `lower_method_call` | 1.0 |
| 44 | [`src/mir/mir_lowering.rb:1982`](../../src/mir/mir_lowering.rb#L1982) | `lower_intrinsic` | 1.0 |
| 45 | [`src/mir/mir_lowering.rb:2177`](../../src/mir/mir_lowering.rb#L2177) | `extern_call_args_zig` | 1.0 |
| 46 | [`src/mir/mir_lowering.rb:2274`](../../src/mir/mir_lowering.rb#L2274) | `lower_lambda` | 1.0 |
| 47 | [`src/mir/mir_lowering.rb:2361`](../../src/mir/mir_lowering.rb#L2361) | `lower_list_lit` | 1.0 |
| 48 | [`src/mir/mir_lowering.rb:2373`](../../src/mir/mir_lowering.rb#L2373) | `lower_list_lit` | 1.0 |
| 49 | [`src/mir/mir_lowering.rb:2379`](../../src/mir/mir_lowering.rb#L2379) | `lower_list_lit` | 1.0 |
| 50 | [`src/mir/mir_lowering.rb:2402`](../../src/mir/mir_lowering.rb#L2402) | `lower_hash_lit` | 1.0 |

- ...(+223 more genuine gaps)

## Category Summary
_935 dark arms; only 273 are genuine gaps. The rest are not test targets:_

| category | arms | % | what it means |
|---|---|---|---|
| type_norm | 229 | 24.5% | type/nil guard -- likely dead if the contract were strictly typed |
| dead | 68 | 7.3% | decision never executes -- audit as dead code, delete |
| defensive | 14 | 1.5% | inert / invariant-pinned -- accept, exclude from denominator |
| ffi | 46 | 4.9% | external/boundary call -- needs an integration test |
| diagnostic | 305 | 32.6% | error/raise path -- reachable only by invalid input (negative test) |
| genuine | 273 | 29.2% | real reachable gap -- test it; ranked by fix-churn below |

## Run Summary
- Repo: `/home/yahn/cheat`
- Files: 3; dark arms: 935; genuine gaps: 273
- General engine: categorizes uncovered branches, ranks genuine gaps by consumed fix-cache churn. Project lexicon (external-boundary methods) is caller-supplied, not baked in (see docs/agents/design.md).
