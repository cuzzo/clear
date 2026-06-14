# SlopCop Report

> Top true coverage gaps, ranked by fix-churn x structural
> deviance. Every dark arm is categorized; only GENUINE
> reachable ones are gaps. Apex = uncovered AND historically
> churned (boobytrap), structurally deviant (decomplex),
> and weakly verified when mutation facts are supplied.
> Owns categorization; consumes boobytrap (churn) and
> optional decomplex (spurious filter + deviance rank).

## Top True Gaps (4587) — test these, ranked by fix-churn

| # | gap | method | churn | decomplex deviance | verification | profile |
|---|---|---|---|---|---|---|
| 1 | [`src/mir/mir_lowering.rb:640`](../../src/mir/mir_lowering.rb#L640) | `heap_indirect_destination?` | 0.9765 | **10** (False Simplicity, Operational Discontinuity) | no mutation / missing | lurking disaster |
| 2 | [`src/ast/ast.rb:1096`](../../src/ast/ast.rb#L1096) | `finalize_storage!` | 0.7285 | **12** (False Simplicity, State-Based Branch Density) | no mutation / missing | lurking disaster |
| 3 | [`src/mir/mir_lowering.rb:2258`](../../src/mir/mir_lowering.rb#L2258) | `ownership_operands_for_sink_value` | 0.9765 | **8** (Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 4 | [`src/mir/mir_lowering.rb:3506`](../../src/mir/mir_lowering.rb#L3506) | `pipeline_alloc_mark_fact` | 0.9765 | **8** † (Decision Pressure, False Simplicity, State-Based Branch Density) | no mutation / missing | lurking disaster |
| 5 | [`src/mir/mir_lowering.rb:3519`](../../src/mir/mir_lowering.rb#L3519) | `pipeline_alloc_mark_fact` | 0.9765 | **8** † (Decision Pressure, False Simplicity, State-Based Branch Density) | no mutation / missing | lurking disaster |
| 6 | [`src/mir/mir_lowering.rb:3639`](../../src/mir/mir_lowering.rb#L3639) | `owned_sink_plan` | 0.9765 | **8** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 7 | [`src/mir/lowering/functions.rb:1001`](../../src/mir/lowering/functions.rb#L1001) | `cross_boundary_arg` | 0.5083 | **14** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) | no mutation / missing | lurking disaster |
| 8 | [`src/mir/lowering/functions.rb:1011`](../../src/mir/lowering/functions.rb#L1011) | `cross_boundary_arg` | 0.5083 | **14** (Decision Pressure, State-Based Branch Density) | no mutation / missing | lurking disaster |
| 9 | [`src/mir/lowering/functions.rb:1017`](../../src/mir/lowering/functions.rb#L1017) | `cross_boundary_arg` | 0.5083 | **14** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) | no mutation / missing | lurking disaster |
| 10 | [`src/mir/lowering/functions.rb:1021`](../../src/mir/lowering/functions.rb#L1021) | `cross_boundary_arg` | 0.5083 | **14** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) | no mutation / missing | lurking disaster |
| 11 | [`src/mir/lowering/functions.rb:1022`](../../src/mir/lowering/functions.rb#L1022) | `cross_boundary_arg` | 0.5083 | **14** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) | no mutation / missing | lurking disaster |
| 12 | [`src/mir/mir_lowering.rb:1996`](../../src/mir/mir_lowering.rb#L1996) | `ownership_transfers_for_stmt` | 0.9765 | **6** † (Decision Pressure, State-Based Branch Density) | no mutation / missing | lurking disaster |
| 13 | [`src/mir/mir_lowering.rb:2310`](../../src/mir/mir_lowering.rb#L2310) | `owned_binding_visible?` | 0.9765 | **6** (State-Based Branch Density) | no mutation / missing | lurking disaster |
| 14 | [`src/mir/lowering/variables.rb:1036`](../../src/mir/lowering/variables.rb#L1036) | `lower_map_indexed_assignment` | 0.6717 | **10** (Locality Drag, State-Based Branch Density) | no mutation / missing | lurking disaster |
| 15 | [`src/mir/lowering/variables.rb:1041`](../../src/mir/lowering/variables.rb#L1041) | `lower_map_indexed_assignment` | 0.6717 | **10** (Locality Drag, State-Based Branch Density) | no mutation / missing | lurking disaster |
| 16 | [`src/mir/lowering/variables.rb:1041`](../../src/mir/lowering/variables.rb#L1041) | `lower_map_indexed_assignment` | 0.6717 | **10** (Locality Drag, State-Based Branch Density) | no mutation / missing | lurking disaster |
| 17 | [`src/mir/lowering/variables.rb:1044`](../../src/mir/lowering/variables.rb#L1044) | `lower_map_indexed_assignment` | 0.6717 | **10** (Locality Drag, State-Based Branch Density) | no mutation / missing | lurking disaster |
| 18 | [`src/mir/lowering/functions.rb:1620`](../../src/mir/lowering/functions.rb#L1620) | `lower_intrinsic` | 0.5083 | **12** (Decision Pressure, Locality Drag, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 19 | [`src/mir/lowering/functions.rb:1627`](../../src/mir/lowering/functions.rb#L1627) | `lower_intrinsic` | 0.5083 | **12** (Decision Pressure, Locality Drag, State-Based Branch Density, +1) | no mutation / missing | lurking disaster |
| 20 | [`src/mir/lowering/functions.rb:1629`](../../src/mir/lowering/functions.rb#L1629) | `lower_intrinsic` | 0.5083 | **12** (Decision Pressure, Locality Drag, State-Based Branch Density, +1) | no mutation / missing | lurking disaster |
| 21 | [`src/mir/lowering/functions.rb:1637`](../../src/mir/lowering/functions.rb#L1637) | `lower_intrinsic` | 0.5083 | **12** (Locality Drag, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 22 | [`src/mir/lowering/functions.rb:1647`](../../src/mir/lowering/functions.rb#L1647) | `lower_intrinsic` | 0.5083 | **12** (Locality Drag, State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 23 | [`src/mir/lowering/functions.rb:1649`](../../src/mir/lowering/functions.rb#L1649) | `lower_intrinsic` | 0.5083 | **12** (Locality Drag, State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 24 | [`src/mir/lowering/functions.rb:1669`](../../src/mir/lowering/functions.rb#L1669) | `lower_intrinsic` | 0.5083 | **12** (Locality Drag, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 25 | [`src/mir/lowering/functions.rb:1695`](../../src/mir/lowering/functions.rb#L1695) | `lower_intrinsic` | 0.5083 | **12** (Locality Drag, State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 26 | [`src/mir/lowering/functions.rb:1703`](../../src/mir/lowering/functions.rb#L1703) | `lower_intrinsic` | 0.5083 | **12** (Decision Pressure, Locality Drag, State-Based Branch Density, +1) | no mutation / missing | lurking disaster |
| 27 | [`src/mir/lowering/functions.rb:1705`](../../src/mir/lowering/functions.rb#L1705) | `lower_intrinsic` | 0.5083 | **12** (Decision Pressure, Locality Drag, State-Based Branch Density, +1) | no mutation / missing | lurking disaster |
| 28 | [`src/ast/ast.rb:739`](../../src/ast/ast.rb#L739) | `_bg_visit_recursive` | 0.7285 | **8** (False Simplicity) | no mutation / missing | lurking disaster |
| 29 | [`src/mir/lowering/variables.rb:218`](../../src/mir/lowering/variables.rb#L218) | `var_decl_facts` | 0.6717 | **8** (Locality Drag, State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 30 | [`src/mir/lowering/variables.rb:221`](../../src/mir/lowering/variables.rb#L221) | `var_decl_facts` | 0.6717 | **8** (Decision Pressure, Locality Drag, State-Based Branch Density, +1) | no mutation / missing | lurking disaster |
| 31 | [`src/mir/lowering/variables.rb:262`](../../src/mir/lowering/variables.rb#L262) | `var_decl_facts` | 0.6717 | **8** (Decision Pressure, Locality Drag, State-Based Branch Density, +1) | no mutation / missing | lurking disaster |
| 32 | [`src/mir/lowering/variables.rb:266`](../../src/mir/lowering/variables.rb#L266) | `var_decl_facts` | 0.6717 | **8** (Locality Drag, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 33 | [`src/mir/lowering/variables.rb:421`](../../src/mir/lowering/variables.rb#L421) | `classified_cleanup_var_decl_plan` | 0.6717 | **8** (State-Based Branch Density) | no mutation / missing | lurking disaster |
| 34 | [`src/mir/lowering/variables.rb:426`](../../src/mir/lowering/variables.rb#L426) | `classified_cleanup_var_decl_plan` | 0.6717 | **8** (Broken Protocols, False Simplicity, State-Based Branch Density) | no mutation / missing | lurking disaster |
| 35 | [`src/mir/lowering/variables.rb:560`](../../src/mir/lowering/variables.rb#L560) | `lower_var_decl_init` | 0.6717 | **8** (Decision Pressure, State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 36 | [`src/mir/lowering/variables.rb:566`](../../src/mir/lowering/variables.rb#L566) | `lower_var_decl_init` | 0.6717 | **8** (Decision Pressure, State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 37 | [`src/mir/lowering/variables.rb:571`](../../src/mir/lowering/variables.rb#L571) | `lower_var_decl_init` | 0.6717 | **8** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 38 | [`src/mir/lowering/variables.rb:572`](../../src/mir/lowering/variables.rb#L572) | `lower_var_decl_init` | 0.6717 | **8** (Decision Pressure, State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 39 | [`src/mir/lowering/variables.rb:578`](../../src/mir/lowering/variables.rb#L578) | `lower_var_decl_init` | 0.6717 | **8** (Decision Pressure, State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 40 | [`src/mir/lowering/variables.rb:579`](../../src/mir/lowering/variables.rb#L579) | `lower_var_decl_init` | 0.6717 | **8** (Decision Pressure, State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 41 | [`src/mir/lowering/variables.rb:585`](../../src/mir/lowering/variables.rb#L585) | `lower_var_decl_init` | 0.6717 | **8** (Decision Pressure, State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 42 | [`src/mir/lowering/variables.rb:586`](../../src/mir/lowering/variables.rb#L586) | `lower_var_decl_init` | 0.6717 | **8** (Decision Pressure, State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 43 | [`src/mir/lowering/variables.rb:587`](../../src/mir/lowering/variables.rb#L587) | `lower_var_decl_init` | 0.6717 | **8** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 44 | [`src/mir/lowering/variables.rb:591`](../../src/mir/lowering/variables.rb#L591) | `lower_var_decl_init` | 0.6717 | **8** (Decision Pressure, State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 45 | [`src/mir/lowering/variables.rb:592`](../../src/mir/lowering/variables.rb#L592) | `lower_var_decl_init` | 0.6717 | **8** (False Simplicity, State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 46 | [`src/mir/lowering/variables.rb:600`](../../src/mir/lowering/variables.rb#L600) | `lower_var_decl_init` | 0.6717 | **8** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 47 | [`src/mir/lowering/variables.rb:606`](../../src/mir/lowering/variables.rb#L606) | `lower_var_decl_init` | 0.6717 | **8** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 48 | [`src/mir/lowering/variables.rb:610`](../../src/mir/lowering/variables.rb#L610) | `lower_var_decl_init` | 0.6717 | **8** (Decision Pressure, State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 49 | [`src/mir/lowering/variables.rb:612`](../../src/mir/lowering/variables.rb#L612) | `lower_var_decl_init` | 0.6717 | **8** (State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 50 | [`src/mir/lowering/variables.rb:1096`](../../src/mir/lowering/variables.rb#L1096) | `lower_template_indexed_assignment` | 0.6717 | **8** (State-Based Branch Density) | no mutation / missing | lurking disaster |
| 51 | [`src/mir/lowering/variables.rb:1099`](../../src/mir/lowering/variables.rb#L1099) | `lower_template_indexed_assignment` | 0.6717 | **8** (Decision Pressure, State-Based Branch Density) | no mutation / missing | lurking disaster |
| 52 | [`src/mir/lowering/variables.rb:1138`](../../src/mir/lowering/variables.rb#L1138) | `lower_template_indexed_assignment` | 0.6717 | **8** † (Decision Pressure, False Simplicity, State-Based Branch Density) | no mutation / missing | lurking disaster |
| 53 | [`src/mir/lowering/variables.rb:1150`](../../src/mir/lowering/variables.rb#L1150) | `lower_template_indexed_assignment` | 0.6717 | **8** (State-Based Branch Density) | no mutation / missing | lurking disaster |
| 54 | [`src/mir/lowering/variables.rb:1280`](../../src/mir/lowering/variables.rb#L1280) | `lower_auto_lock_assignment` | 0.6717 | **8** (State-Based Branch Density) | no mutation / missing | lurking disaster |
| 55 | [`src/mir/lowering/variables.rb:1308`](../../src/mir/lowering/variables.rb#L1308) | `lower_auto_lock_assignment` | 0.6717 | **8** (State-Based Branch Density) | no mutation / missing | lurking disaster |
| 56 | [`src/mir/lowering/functions.rb:294`](../../src/mir/lowering/functions.rb#L294) | `lower_function_def` | 0.5083 | **10** (Decision Pressure, Locality Drag, State-Based Branch Density, +1) | no mutation / missing | lurking disaster |
| 57 | [`src/mir/lowering/functions.rb:300`](../../src/mir/lowering/functions.rb#L300) | `lower_function_def` | 0.5083 | **10** (Locality Drag, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 58 | [`src/mir/lowering/functions.rb:302`](../../src/mir/lowering/functions.rb#L302) | `lower_function_def` | 0.5083 | **10** (False Simplicity, Locality Drag, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 59 | [`src/mir/lowering/functions.rb:303`](../../src/mir/lowering/functions.rb#L303) | `lower_function_def` | 0.5083 | **10** (Decision Pressure, False Simplicity, Locality Drag, +1) | no mutation / missing | lurking disaster |
| 60 | [`src/mir/lowering/functions.rb:323`](../../src/mir/lowering/functions.rb#L323) | `lower_function_def` | 0.5083 | **10** (Locality Drag, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 61 | [`src/mir/lowering/functions.rb:334`](../../src/mir/lowering/functions.rb#L334) | `lower_function_def` | 0.5083 | **10** (Locality Drag, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 62 | [`src/mir/lowering/functions.rb:336`](../../src/mir/lowering/functions.rb#L336) | `lower_function_def` | 0.5083 | **10** (Locality Drag, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 63 | [`src/mir/lowering/functions.rb:364`](../../src/mir/lowering/functions.rb#L364) | `lower_function_def` | 0.5083 | **10** (Locality Drag, State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 64 | [`src/mir/lowering/functions.rb:366`](../../src/mir/lowering/functions.rb#L366) | `lower_function_def` | 0.5083 | **10** (Locality Drag, State-Based Branch Density, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 65 | [`src/mir/lowering/functions.rb:373`](../../src/mir/lowering/functions.rb#L373) | `lower_function_def` | 0.5083 | **10** (Locality Drag, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 66 | [`src/mir/lowering/functions.rb:377`](../../src/mir/lowering/functions.rb#L377) | `lower_function_def` | 0.5083 | **10** (False Simplicity, Locality Drag, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 67 | [`src/mir/lowering/functions.rb:378`](../../src/mir/lowering/functions.rb#L378) | `lower_function_def` | 0.5083 | **10** (Decision Pressure, False Simplicity, Locality Drag, +2) | no mutation / missing | lurking disaster |
| 68 | [`src/mir/lowering/functions.rb:390`](../../src/mir/lowering/functions.rb#L390) | `lower_function_def` | 0.5083 | **10** (Locality Drag, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 69 | [`src/mir/lowering/functions.rb:393`](../../src/mir/lowering/functions.rb#L393) | `lower_function_def` | 0.5083 | **10** (Locality Drag, Weighted Inlined Cognitive Complexity) | no mutation / missing | lurking disaster |
| 70 | [`src/mir/lowering/functions.rb:396`](../../src/mir/lowering/functions.rb#L396) | `lower_function_def` | 0.5083 | **10** (Locality Drag, Neglected Path Conditions, State-Based Branch Density, +1) | no mutation / missing | lurking disaster |
| 71 | [`src/mir/lowering/functions.rb:398`](../../src/mir/lowering/functions.rb#L398) | `lower_function_def` | 0.5083 | **10** (Locality Drag, Neglected Path Conditions, State-Based Branch Density, +1) | no mutation / missing | lurking disaster |
| 72 | [`src/mir/lowering/functions.rb:812`](../../src/mir/lowering/functions.rb#L812) | `build_post_outer_fn` | 0.5083 | **10** (Locality Drag) | no mutation / missing | lurking disaster |
| 73 | [`src/mir/lowering/functions.rb:851`](../../src/mir/lowering/functions.rb#L851) | `build_post_outer_fn` | 0.5083 | **10** (Locality Drag, State-Based Branch Density) | no mutation / missing | lurking disaster |
| 74 | [`src/mir/lowering/functions.rb:857`](../../src/mir/lowering/functions.rb#L857) | `build_post_outer_fn` | 0.5083 | **10** (Locality Drag, State-Based Branch Density) | no mutation / missing | lurking disaster |
| 75 | [`src/mir/lowering/variables.rb:65`](../../src/mir/lowering/variables.rb#L65) | `binding_placement_fact` | 0.6717 | **6** † (Decision Pressure, State-Based Branch Density) | no mutation / missing | lurking disaster |

- ...(+4512 more genuine gaps)

> decomplex attribution on listed gaps: **3358 span-precise**, **786 method-coarse (†)**, **91 ⚠dup?** (possibly redundant, not localised -- verify before testing). Coarse rows are whole-method: treat as a hint, not an arm-level discriminator.

## Category Summary
_6909 dark arms; only 4587 are genuine gaps. The rest are not test targets:_

| category | arms | % | what it means |
|---|---|---|---|
| type_norm | 992 | 14.4% | type/nil guard -- likely dead if runtime contracts were stricter |
| dead | 38 | 0.6% | decision never executes in coverage -- audit as missing test or statically-dead code |
| defensive | 574 | 8.3% | inert / invariant-pinned -- accept, exclude from denominator |
| spurious | 409 | 5.9% | span-precise redundant/cloned decision (decomplex) -- refactor or delete, NOT a test target (coarse duplication never excludes -- it stays a gap, flagged ⚠dup?) |
| ffi | 0 | 0.0% | external/boundary call -- needs an integration test |
| diagnostic | 309 | 4.5% | error/raise/diagnostic path -- reachable only by invalid input (negative test) |
| genuine | 4587 | 66.4% | real reachable gap -- test it; ranked by fix-churn x decomplex structural deviance |

## Run Summary
- Repo: `/home/yahn/litedb`
- Files: 133; dark arms: 6909; genuine gaps: 4587
- Coverage input: SimpleCov
- Mutation facts: litedb-mutant-facts.json
- Branch source: coverage=836, tree_sitter_static=6073
- General engine: categorizes uncovered branches, ranks genuine gaps by consumed boobytrap churn x optional decomplex structural deviance. Project lexicons (external-boundary methods and domain diagnostic methods) are caller-supplied, not baked in (see docs/agents/design.md).
- decomplex join is span-precise (the arm's line falls inside the flagged decision's source extent); `†` marks a (file, method) fallback when no flagged span contained the arm. A ranked candidate, not a verdict (Engler discipline).
