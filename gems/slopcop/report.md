# SlopCop Report

> Top true coverage gaps, ranked by fix-churn x structural
> deviance. Every dark arm is categorized; only GENUINE
> reachable ones are gaps. Apex = uncovered AND historically
> churned (boobytrap) AND structurally deviant (decomplex).
> Owns categorization; consumes boobytrap (churn) and
> optional decomplex (spurious filter + deviance rank).

## Top True Gaps (1195) — test these, ranked by fix-churn

| # | gap | method | churn | decomplex deviance |
|---|---|---|---|---|
| 1 | [`src/mir/mir.rb:641`](../../src/mir/mir.rb#L641) | `(top-level)` | 0.9486 | **8** (False Simplicity) |
| 2 | [`src/mir/mir.rb:717`](../../src/mir/mir.rb#L717) | `each_node_inner` | 0.9486 | **8** (False Simplicity) |
| 3 | [`src/mir/mir.rb:735`](../../src/mir/mir.rb#L735) | `each_surface_node_inner` | 0.9486 | **8** (False Simplicity) |
| 4 | [`src/mir/mir.rb:966`](../../src/mir/mir.rb#L966) | `(top-level)` | 0.9486 | **8** (False Simplicity) |
| 5 | [`src/mir/mir.rb:2544`](../../src/mir/mir.rb#L2544) | `body_slots` | 0.9486 | **8** (False Simplicity) |
| 6 | [`src/mir/mir.rb:3151`](../../src/mir/mir.rb#L3151) | `child_exprs` | 0.9486 | **8** (False Simplicity) |
| 7 | [`src/mir/mir.rb:3185`](../../src/mir/mir.rb#L3185) | `child_exprs` | 0.9486 | **8** (False Simplicity) |
| 8 | [`src/mir/mir.rb:3811`](../../src/mir/mir.rb#L3811) | `child_exprs` | 0.9486 | **8** (False Simplicity) |
| 9 | [`src/mir/mir_lowering.rb:593`](../../src/mir/mir_lowering.rb#L593) | `destination_type` | 0.9103 | **8** (False Simplicity) |
| 10 | [`src/mir/lowering/variables.rb:662`](../../src/mir/lowering/variables.rb#L662) | `field_access_moves_owner?` | 0.7062 | **10** † (Broken Protocols, Decision Pressure, False Simplicity, +1) |
| 11 | [`src/mir/mir.rb:3554`](../../src/mir/mir.rb#L3554) | `ownership_effect` | 0.9486 | **6** (False Simplicity) |
| 12 | [`src/mir/mir.rb:4645`](../../src/mir/mir.rb#L4645) | `ownership_effect` | 0.9486 | **6** (False Simplicity) |
| 13 | [`src/mir/mir.rb:4655`](../../src/mir/mir.rb#L4655) | `ownership_effect` | 0.9486 | **6** (False Simplicity) |
| 14 | [`src/mir/mir.rb:4754`](../../src/mir/mir.rb#L4754) | `ownership_effect` | 0.9486 | **6** (False Simplicity) |
| 15 | [`src/mir/mir_lowering.rb:316`](../../src/mir/mir_lowering.rb#L316) | `ast_void_type?` | 0.9103 | **6** † (Decision Pressure, State-Based Branch Density) |
| 16 | [`src/mir/lowering/functions.rb:1687`](../../src/mir/lowering/functions.rb#L1687) | `lower_intrinsic` | 0.4928 | **12** (Locality Drag, Weighted Inlined Cognitive Complexity) |
| 17 | [`src/mir/lowering/variables.rb:574`](../../src/mir/lowering/variables.rb#L574) | `lower_var_decl_init` | 0.7062 | **8** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 18 | [`src/mir/lowering/variables.rb:581`](../../src/mir/lowering/variables.rb#L581) | `lower_var_decl_init` | 0.7062 | **8** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 19 | [`src/mir/lowering/variables.rb:587`](../../src/mir/lowering/variables.rb#L587) | `lower_var_decl_init` | 0.7062 | **8** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 20 | [`src/mir/lowering/variables.rb:597`](../../src/mir/lowering/variables.rb#L597) | `lower_var_decl_init` | 0.7062 | **8** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 21 | [`src/mir/lowering/variables.rb:602`](../../src/mir/lowering/variables.rb#L602) | `lower_var_decl_init` | 0.7062 | **8** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 22 | [`src/mir/lowering/variables.rb:625`](../../src/mir/lowering/variables.rb#L625) | `source_already_has_declared_capability?` | 0.7062 | **8** (State-Based Branch Density) |
| 23 | [`src/mir/lowering/variables.rb:626`](../../src/mir/lowering/variables.rb#L626) | `source_already_has_declared_capability?` | 0.7062 | **8** (State-Based Branch Density) |
| 24 | [`src/mir/lowering/variables.rb:627`](../../src/mir/lowering/variables.rb#L627) | `source_already_has_declared_capability?` | 0.7062 | **8** (State-Based Branch Density) |
| 25 | [`src/mir/lowering/variables.rb:730`](../../src/mir/lowering/variables.rb#L730) | `lower_bind_expr` | 0.7062 | **8** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 26 | [`src/mir/lowering/variables.rb:750`](../../src/mir/lowering/variables.rb#L750) | `lower_bind_expr` | 0.7062 | **8** (False Simplicity, State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 27 | [`src/mir/lowering/variables.rb:1136`](../../src/mir/lowering/variables.rb#L1136) | `lower_template_indexed_assignment` | 0.7062 | **8** † (Decision Pressure, False Simplicity, State-Based Branch Density) |
| 28 | [`src/mir/lowering/variables.rb:1150`](../../src/mir/lowering/variables.rb#L1150) | `lower_template_indexed_assignment` | 0.7062 | **8** (State-Based Branch Density) |
| 29 | [`src/mir/lowering/variables.rb:1287`](../../src/mir/lowering/variables.rb#L1287) | `lower_auto_lock_assignment` | 0.7062 | **8** (State-Based Branch Density) |
| 30 | [`src/mir/mir_checker.rb:418`](../../src/mir/mir_checker.rb#L418) | `check_fn!` | 0.7057 | **8** (Locality Drag, State-Based Branch Density, Temporal Ordering Pressure, +1) |
| 31 | [`src/mir/mir_checker.rb:496`](../../src/mir/mir_checker.rb#L496) | `verify_structural_ownership_contracts!` | 0.7057 | **8** (Temporal Ordering Pressure) |
| 32 | [`src/mir/mir_checker.rb:547`](../../src/mir/mir_checker.rb#L547) | `structural_consumed_names` | 0.7057 | **8** (Temporal Ordering Pressure) |
| 33 | [`src/mir/mir_checker.rb:580`](../../src/mir/mir_checker.rb#L580) | `check_linear_stmt!` | 0.7057 | **8** (Temporal Ordering Pressure, Weighted Inlined Cognitive Complexity) |
| 34 | [`src/mir/mir_checker.rb:1263`](../../src/mir/mir_checker.rb#L1263) | `ownership_registry_errors` | 0.7057 | **8** (State-Based Branch Density) |
| 35 | [`src/mir/mir_checker.rb:1584`](../../src/mir/mir_checker.rb#L1584) | `check_fsm_structure!` | 0.7057 | **8** (Weighted Inlined Cognitive Complexity) |
| 36 | [`src/mir/mir_checker.rb:1611`](../../src/mir/mir_checker.rb#L1611) | `check_fsm_structure!` | 0.7057 | **8** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 37 | [`src/mir/mir_checker.rb:2343`](../../src/mir/mir_checker.rb#L2343) | `verify_ownership_contract_operands!` | 0.7057 | **8** (State-Based Branch Density) |
| 38 | [`src/mir/mir_checker.rb:2890`](../../src/mir/mir_checker.rb#L2890) | `check_expr_sources_for_unhoisted` | 0.7057 | **8** (Operational Discontinuity) |
| 39 | [`src/mir/fiber_ctx_builder.rb:296`](../../src/mir/fiber_ctx_builder.rb#L296) | `build` | 0.5711 | **10** (Weighted Inlined Cognitive Complexity) |
| 40 | [`src/mir/fiber_ctx_builder.rb:312`](../../src/mir/fiber_ctx_builder.rb#L312) | `build` | 0.5711 | **10** (Weighted Inlined Cognitive Complexity) |
| 41 | [`src/semantic/escape_analysis.rb:917`](../../src/semantic/escape_analysis.rb#L917) | `function_facts` | 0.4336 | **12** (False Simplicity) |
| 42 | [`src/semantic/escape_analysis.rb:1035`](../../src/semantic/escape_analysis.rb#L1035) | `owning_return_needs_heap_placement?` | 0.4336 | **12** † (Decision Pressure, Derived-State Staleness, False Simplicity, +1) |
| 43 | [`src/semantic/escape_analysis.rb:1038`](../../src/semantic/escape_analysis.rb#L1038) | `owning_return_needs_heap_placement?` | 0.4336 | **12** † (Decision Pressure, Derived-State Staleness, False Simplicity, +1) |
| 44 | [`src/semantic/escape_analysis.rb:1045`](../../src/semantic/escape_analysis.rb#L1045) | `owning_return_needs_heap_placement?` | 0.4336 | **12** (State-Based Branch Density) |
| 45 | [`src/ast/ast.rb:385`](../../src/ast/ast.rb#L385) | `walk_body` | 0.6613 | **8** (False Simplicity) |
| 46 | [`src/ast/ast.rb:826`](../../src/ast/ast.rb#L826) | `each_capture_analysis` | 0.6613 | **8** (False Simplicity, State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 47 | [`src/ast/ast.rb:831`](../../src/ast/ast.rb#L831) | `each_capture_analysis` | 0.6613 | **8** (False Simplicity, State-Based Branch Density, Weighted Inlined Cognitive Complexity) |
| 48 | [`src/ast/ast.rb:2618`](../../src/ast/ast.rb#L2618) | `child_bodies` | 0.6613 | **8** (False Simplicity) |
| 49 | [`src/ast/ast.rb:2624`](../../src/ast/ast.rb#L2624) | `child_bodies` | 0.6613 | **8** (False Simplicity, State-Based Branch Density) |
| 50 | [`src/ast/ast.rb:2625`](../../src/ast/ast.rb#L2625) | `child_bodies` | 0.6613 | **8** (False Simplicity, State-Based Branch Density) |

- ...(+1145 more genuine gaps)

> decomplex attribution on listed gaps: **796 span-precise**, **311 method-coarse (†)**, **47 ⚠dup?** (possibly redundant, not localised -- verify before testing). Coarse rows are whole-method: treat as a hint, not an arm-level discriminator.

## Category Summary
_2622 dark arms; only 1195 are genuine gaps. The rest are not test targets:_

| category | arms | % | what it means |
|---|---|---|---|
| type_norm | 697 | 26.6% | type/nil guard -- likely dead if runtime contracts were stricter |
| dead | 73 | 2.8% | decision never executes in coverage -- audit as missing test or statically-dead code |
| defensive | 42 | 1.6% | inert / invariant-pinned -- accept, exclude from denominator |
| spurious | 72 | 2.7% | span-precise redundant/cloned decision (decomplex) -- refactor or delete, NOT a test target (coarse duplication never excludes -- it stays a gap, flagged ⚠dup?) |
| ffi | 0 | 0.0% | external/boundary call -- needs an integration test |
| diagnostic | 543 | 20.7% | error/raise/diagnostic path -- reachable only by invalid input (negative test) |
| genuine | 1195 | 45.6% | real reachable gap -- test it; ranked by fix-churn x decomplex structural deviance |

## Run Summary
- Repo: `/home/yahn/cheat`
- Files: 120; dark arms: 2622; genuine gaps: 1195
- General engine: categorizes uncovered branches, ranks genuine gaps by consumed boobytrap churn x optional decomplex structural deviance. Project lexicons (external-boundary methods and domain diagnostic methods) are caller-supplied, not baked in (see docs/agents/design.md).
- decomplex join is span-precise (the arm's line falls inside the flagged decision's source extent); `†` marks a (file, method) fallback when no flagged span contained the arm. A ranked candidate, not a verdict (Engler discipline).
