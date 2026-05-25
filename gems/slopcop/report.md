# SlopCop Report

> Top true coverage gaps, ranked by fix-churn x structural
> deviance. Every dark arm is categorized; only GENUINE
> reachable ones are gaps. Apex = uncovered AND historically
> churned (boobytrap) AND structurally deviant (decomplex).
> Owns categorization; consumes boobytrap (churn) and
> optional decomplex (spurious filter + deviance rank).

## Top True Gaps (1650) — test these, ranked by fix-churn

| # | gap | method | churn | decomplex deviance |
|---|---|---|---|---|
| 1 | [`src/mir/mir_lowering.rb:544`](../../src/mir/mir_lowering.rb#L544) | `lower_body` | 1.0 | **12** † (Broken Protocols, Decision Pressure, False Simplicity, +2) |
| 2 | [`src/annotator.rb:3324`](../../src/annotator.rb#L3324) | `visit_GetField` | 0.7463 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 3 | [`src/annotator.rb:3330`](../../src/annotator.rb#L3330) | `visit_GetField` | 0.7463 | **16** (False Simplicity) |
| 4 | [`src/annotator.rb:3340`](../../src/annotator.rb#L3340) | `visit_GetField` | 0.7463 | **16** (False Simplicity, Neglected Updates) |
| 5 | [`src/annotator.rb:3368`](../../src/annotator.rb#L3368) | `visit_GetField` | 0.7463 | **16** (False Simplicity) |
| 6 | [`src/annotator.rb:3372`](../../src/annotator.rb#L3372) | `visit_GetField` | 0.7463 | **16** (False Simplicity) |
| 7 | [`src/annotator.rb:3376`](../../src/annotator.rb#L3376) | `visit_GetField` | 0.7463 | **16** (False Simplicity) |
| 8 | [`src/annotator.rb:3386`](../../src/annotator.rb#L3386) | `visit_GetField` | 0.7463 | **16** (False Simplicity) |
| 9 | [`src/annotator.rb:3400`](../../src/annotator.rb#L3400) | `visit_GetField` | 0.7463 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 10 | [`src/annotator.rb:3420`](../../src/annotator.rb#L3420) | `visit_GetField` | 0.7463 | **16** (Neglected Path Conditions) |
| 11 | [`src/annotator.rb:3536`](../../src/annotator.rb#L3536) | `visit_StructLit` | 0.7463 | **16** (False Simplicity) |
| 12 | [`src/annotator.rb:3557`](../../src/annotator.rb#L3557) | `visit_StructLit` | 0.7463 | **16** (Neglected Path Conditions) |
| 13 | [`src/annotator.rb:3574`](../../src/annotator.rb#L3574) | `visit_StructLit` | 0.7463 | **16** (False Simplicity) |
| 14 | [`src/annotator.rb:3587`](../../src/annotator.rb#L3587) | `visit_StructLit` | 0.7463 | **16** (Broken Protocols) |
| 15 | [`src/annotator.rb:3598`](../../src/annotator.rb#L3598) | `visit_StructLit` | 0.7463 | **16** (False Simplicity) |
| 16 | [`src/annotator.rb:3615`](../../src/annotator.rb#L3615) | `visit_StructLit` | 0.7463 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 17 | [`src/annotator.rb:3671`](../../src/annotator.rb#L3671) | `visit_StructLit` | 0.7463 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 18 | [`src/annotator.rb:3678`](../../src/annotator.rb#L3678) | `visit_StructLit` | 0.7463 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 19 | [`src/annotator.rb:3685`](../../src/annotator.rb#L3685) | `visit_StructLit` | 0.7463 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 20 | [`src/annotator.rb:3696`](../../src/annotator.rb#L3696) | `visit_StructLit` | 0.7463 | **16** (False Simplicity) |
| 21 | [`src/annotator.rb:3701`](../../src/annotator.rb#L3701) | `visit_StructLit` | 0.7463 | **16** (False Simplicity) |
| 22 | [`src/annotator.rb:5489`](../../src/annotator.rb#L5489) | `handle_assign_move` | 0.7463 | **16** (Broken Protocols) |
| 23 | [`src/mir/mir_lowering.rb:246`](../../src/mir/mir_lowering.rb#L246) | `place_value_for_destination` | 1.0 | **10** † ⚠dup? (Broken Protocols, Decision Pressure, Missing Abstractions, +2) |
| 24 | [`src/mir/mir_lowering.rb:684`](../../src/mir/mir_lowering.rb#L684) | `collect_ownership_surface_nodes` | 1.0 | **10** † ⚠dup? (Broken Protocols, Decision Pressure, False Simplicity, +1) |
| 25 | [`src/mir/mir_lowering.rb:1276`](../../src/mir/mir_lowering.rb#L1276) | `lower_program` | 1.0 | **10** (False Simplicity) |
| 26 | [`src/mir/mir_lowering.rb:1633`](../../src/mir/mir_lowering.rb#L1633) | `lower_union_def` | 1.0 | **10** (Broken Protocols) |
| 27 | [`src/mir/mir_lowering.rb:1652`](../../src/mir/mir_lowering.rb#L1652) | `lower_union_def` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 28 | [`src/mir/mir_lowering.rb:2384`](../../src/mir/mir_lowering.rb#L2384) | `materialize_owned_sink_value` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 29 | [`src/annotator.rb:2077`](../../src/annotator.rb#L2077) | `visit_ReturnNode` | 0.7463 | **14** (False Simplicity) |
| 30 | [`src/annotator.rb:2094`](../../src/annotator.rb#L2094) | `visit_ReturnNode` | 0.7463 | **14** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 31 | [`src/annotator.rb:2158`](../../src/annotator.rb#L2158) | `visit_ReturnNode` | 0.7463 | **14** (False Simplicity) |
| 32 | [`src/annotator.rb:2178`](../../src/annotator.rb#L2178) | `visit_ReturnNode` | 0.7463 | **14** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 33 | [`src/annotator.rb:2195`](../../src/annotator.rb#L2195) | `visit_ReturnNode` | 0.7463 | **14** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 34 | [`src/annotator.rb:3114`](../../src/annotator.rb#L3114) | `visit_Assignment` | 0.7463 | **14** (Fat Unions) |
| 35 | [`src/annotator.rb:3123`](../../src/annotator.rb#L3123) | `visit_Assignment` | 0.7463 | **14** (False Simplicity, Fat Unions) |
| 36 | [`src/mir/mir_lowering.rb:730`](../../src/mir/mir_lowering.rb#L730) | `ownership_facts_for_mir_node` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 37 | [`src/mir/mir_lowering.rb:1017`](../../src/mir/mir_lowering.rb#L1017) | `collect_mir_consumed_roots` | 1.0 | **8** (False Simplicity) |
| 38 | [`src/mir/mir_lowering.rb:1123`](../../src/mir/mir_lowering.rb#L1123) | `collect_moved_arg_roots` | 1.0 | **8** (False Simplicity) |
| 39 | [`src/mir/mir_lowering.rb:1127`](../../src/mir/mir_lowering.rb#L1127) | `collect_moved_arg_roots` | 1.0 | **8** (False Simplicity) |
| 40 | [`src/mir/mir_lowering.rb:1600`](../../src/mir/mir_lowering.rb#L1600) | `lower_struct_def` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 41 | [`src/mir/mir_lowering.rb:2466`](../../src/mir/mir_lowering.rb#L2466) | `rc_retain_needed?` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 42 | [`src/annotator.rb:668`](../../src/annotator.rb#L668) | `visit_FunctionDef` | 0.7463 | **12** (False Simplicity) |
| 43 | [`src/annotator.rb:673`](../../src/annotator.rb#L673) | `visit_FunctionDef` | 0.7463 | **12** (False Simplicity) |
| 44 | [`src/annotator.rb:676`](../../src/annotator.rb#L676) | `visit_FunctionDef` | 0.7463 | **12** (False Simplicity) |
| 45 | [`src/annotator.rb:677`](../../src/annotator.rb#L677) | `visit_FunctionDef` | 0.7463 | **12** (False Simplicity) |
| 46 | [`src/annotator.rb:688`](../../src/annotator.rb#L688) | `visit_FunctionDef` | 0.7463 | **12** † (Broken Protocols, Decision Pressure, False Simplicity, +2) |
| 47 | [`src/annotator.rb:712`](../../src/annotator.rb#L712) | `visit_FunctionDef` | 0.7463 | **12** (False Simplicity) |
| 48 | [`src/annotator.rb:728`](../../src/annotator.rb#L728) | `visit_FunctionDef` | 0.7463 | **12** (False Simplicity) |
| 49 | [`src/annotator.rb:732`](../../src/annotator.rb#L732) | `visit_FunctionDef` | 0.7463 | **12** (False Simplicity) |
| 50 | [`src/annotator.rb:748`](../../src/annotator.rb#L748) | `visit_FunctionDef` | 0.7463 | **12** (False Simplicity) |

- ...(+1600 more genuine gaps)

> decomplex attribution on listed gaps: **548 span-precise**, **927 method-coarse (†)**, **195 ⚠dup?** (possibly redundant, not localised -- verify before testing). Coarse rows are whole-method: treat as a hint, not an arm-level discriminator.

## Category Summary
_9753 dark arms; only 1650 are genuine gaps. The rest are not test targets:_

| category | arms | % | what it means |
|---|---|---|---|
| type_norm | 2381 | 24.4% | type/nil guard -- likely dead if the contract were strictly typed |
| dead | 3195 | 32.8% | decision never executes -- audit as dead code, delete |
| defensive | 108 | 1.1% | inert / invariant-pinned -- accept, exclude from denominator |
| spurious | 96 | 1.0% | span-precise redundant/cloned decision (decomplex) -- refactor or delete, NOT a test target (coarse duplication never excludes -- it stays a gap, flagged ⚠dup?) |
| ffi | 0 | 0.0% | external/boundary call -- needs an integration test |
| diagnostic | 2323 | 23.8% | error/raise path -- reachable only by invalid input (negative test) |
| genuine | 1650 | 16.9% | real reachable gap -- test it; ranked by fix-churn x decomplex structural deviance |

## Run Summary
- Repo: `/home/yahn/cheat`
- Files: 77; dark arms: 9753; genuine gaps: 1650
- General engine: categorizes uncovered branches, ranks genuine gaps by consumed boobytrap churn x optional decomplex structural deviance. Project lexicon (external-boundary methods) is caller-supplied, not baked in (see docs/agents/design.md).
- decomplex join is span-precise (the arm's line falls inside the flagged decision's source extent); `†` marks a (file, method) fallback when no flagged span contained the arm. A ranked candidate, not a verdict (Engler discipline).
