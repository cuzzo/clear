# SlopCop Report

> Top true coverage gaps, ranked by fix-churn x structural
> deviance. Every dark arm is categorized; only GENUINE
> reachable ones are gaps. Apex = uncovered AND historically
> churned (boobytrap) AND structurally deviant (decomplex).
> Owns categorization; consumes boobytrap (churn) and
> optional decomplex (spurious filter + deviance rank).

## Top True Gaps (1267) — test these, ranked by fix-churn

| # | gap | method | churn | decomplex deviance |
|---|---|---|---|---|
| 1 | [`src/mir/mir_lowering.rb:1395`](../../src/mir/mir_lowering.rb#L1395) | `implicit_allocating_result_fact` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 2 | [`src/mir/mir_lowering.rb:1938`](../../src/mir/mir_lowering.rb#L1938) | `lower_body_with_break` | 1.0 | **8** † ⚠dup? (Broken Protocols, Decision Pressure, Missing Abstractions) |
| 3 | [`src/mir/mir_lowering.rb:1943`](../../src/mir/mir_lowering.rb#L1943) | `lower_body_with_break` | 1.0 | **8** † ⚠dup? (Broken Protocols, Decision Pressure, Missing Abstractions) |
| 4 | [`src/mir/mir_lowering.rb:2159`](../../src/mir/mir_lowering.rb#L2159) | `extract_root_var_name` | 1.0 | **6** † ⚠dup? (Decision Pressure, Missing Abstractions) |
| 5 | [`src/backends/pipeline_host.rb:336`](../../src/backends/pipeline_host.rb#L336) | `substitute_placeholders` | 0.266 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 6 | [`src/backends/pipeline_host.rb:346`](../../src/backends/pipeline_host.rb#L346) | `substitute_placeholders` | 0.266 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 7 | [`src/backends/pipeline_host.rb:383`](../../src/backends/pipeline_host.rb#L383) | `substitute_placeholders` | 0.266 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 8 | [`src/backends/pipeline_host.rb:410`](../../src/backends/pipeline_host.rb#L410) | `substitute_placeholders` | 0.266 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 9 | [`src/backends/pipeline_host.rb:424`](../../src/backends/pipeline_host.rb#L424) | `substitute_placeholders` | 0.266 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 10 | [`src/backends/pipeline_host.rb:431`](../../src/backends/pipeline_host.rb#L431) | `substitute_placeholders` | 0.266 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 11 | [`src/backends/pipeline_host.rb:438`](../../src/backends/pipeline_host.rb#L438) | `substitute_placeholders` | 0.266 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 12 | [`src/mir/mir_lowering.rb:959`](../../src/mir/mir_lowering.rb#L959) | `materialize_statement_discard` | 1.0 | **4** † (Broken Protocols, False Simplicity, Neglected Updates) |
| 13 | [`src/mir/mir_lowering.rb:1368`](../../src/mir/mir_lowering.rb#L1368) | `finalize_nested_mir_expr_bodies!` | 1.0 | **4** † (Broken Protocols, False Simplicity) |
| 14 | [`src/mir/mir_lowering.rb:2009`](../../src/mir/mir_lowering.rb#L2009) | `lower_module` | 1.0 | **4** † (Broken Protocols, False Simplicity) |
| 15 | [`src/mir/mir_lowering.rb:232`](../../src/mir/mir_lowering.rb#L232) | `ast_void_type?` | 1.0 | **3** † (Decision Pressure) |
| 16 | [`src/ast/type.rb:2377`](../../src/ast/type.rb#L2377) | `compute_zig_type` | 0.1746 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 17 | [`src/mir/mir_lowering.rb:482`](../../src/mir/mir_lowering.rb#L482) | `place_owned_try_catch_for_destination` | 1.0 | **2** † (False Simplicity, Neglected Updates) |
| 18 | [`src/mir/mir_lowering.rb:553`](../../src/mir/mir_lowering.rb#L553) | `place_string_or_for_heap_destination` | 1.0 | **2** † (False Simplicity, Neglected Updates) |
| 19 | [`src/mir/mir_lowering.rb:557`](../../src/mir/mir_lowering.rb#L557) | `place_string_or_for_heap_destination` | 1.0 | **2** † (False Simplicity, Neglected Updates) |
| 20 | [`src/mir/mir_lowering.rb:565`](../../src/mir/mir_lowering.rb#L565) | `place_string_or_for_heap_destination` | 1.0 | **2** † (False Simplicity, Neglected Updates) |
| 21 | [`src/mir/mir_lowering.rb:600`](../../src/mir/mir_lowering.rb#L600) | `place_string_value_for_heap_destination` | 1.0 | **1** (False Simplicity) |
| 22 | [`src/mir/mir_lowering.rb:832`](../../src/mir/mir_lowering.rb#L832) | `lower_body` | 1.0 | **1** † (False Simplicity) |
| 23 | [`src/mir/mir_lowering.rb:1906`](../../src/mir/mir_lowering.rb#L1906) | `discard_owned_zig_type` | 1.0 | **1** † (False Simplicity) |
| 24 | [`src/mir/mir_lowering.rb:2595`](../../src/mir/mir_lowering.rb#L2595) | `merge_module_schemas!` | 1.0 | **1** † (False Simplicity) |
| 25 | [`src/mir/mir_lowering.rb:2598`](../../src/mir/mir_lowering.rb#L2598) | `merge_module_schemas!` | 1.0 | **1** † (False Simplicity) |
| 26 | [`src/mir/mir_lowering.rb:2601`](../../src/mir/mir_lowering.rb#L2601) | `merge_module_schemas!` | 1.0 | **1** † (False Simplicity) |
| 27 | [`src/mir/mir_lowering.rb:2802`](../../src/mir/mir_lowering.rb#L2802) | `zig_format_for_type` | 1.0 | **1** † (Broken Protocols) |
| 28 | [`src/mir/lowering/expressions.rb:455`](../../src/mir/lowering/expressions.rb#L455) | `lower_smooth` | 0.0508 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 29 | [`src/mir/lowering/expressions.rb:494`](../../src/mir/lowering/expressions.rb#L494) | `lower_smooth` | 0.0508 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 30 | [`src/mir/lowering/expressions.rb:500`](../../src/mir/lowering/expressions.rb#L500) | `lower_smooth` | 0.0508 | **16** (Broken Protocols) |
| 31 | [`src/mir/lowering/expressions.rb:506`](../../src/mir/lowering/expressions.rb#L506) | `lower_smooth` | 0.0508 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 32 | [`src/mir/lowering/expressions.rb:546`](../../src/mir/lowering/expressions.rb#L546) | `lower_smooth` | 0.0508 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 33 | [`src/mir/lowering/expressions.rb:548`](../../src/mir/lowering/expressions.rb#L548) | `lower_smooth` | 0.0508 | **16** (Neglected Path Conditions) |
| 34 | [`src/mir/lowering/expressions.rb:576`](../../src/mir/lowering/expressions.rb#L576) | `lower_smooth` | 0.0508 | **16** (False Simplicity) |
| 35 | [`src/mir/lowering/expressions.rb:577`](../../src/mir/lowering/expressions.rb#L577) | `lower_smooth` | 0.0508 | **16** (False Simplicity) |
| 36 | [`src/mir/lowering/variables.rb:440`](../../src/mir/lowering/variables.rb#L440) | `build_var_decl_nodes` | 0.0508 | **16** (False Simplicity) |
| 37 | [`src/mir/lowering/variables.rb:455`](../../src/mir/lowering/variables.rb#L455) | `build_var_decl_nodes` | 0.0508 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +4) |
| 38 | [`src/mir/lowering/variables.rb:460`](../../src/mir/lowering/variables.rb#L460) | `build_var_decl_nodes` | 0.0508 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +4) |
| 39 | [`src/mir/lowering/variables.rb:489`](../../src/mir/lowering/variables.rb#L489) | `build_var_decl_nodes` | 0.0508 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +4) |
| 40 | [`src/tools/doctor.rb:131`](../../src/tools/doctor.rb#L131) | `section_heap` | 0.0329 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 41 | [`src/tools/doctor.rb:142`](../../src/tools/doctor.rb#L142) | `section_heap` | 0.0329 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 42 | [`src/tools/doctor.rb:211`](../../src/tools/doctor.rb#L211) | `section_heap` | 0.0329 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 43 | [`src/tools/doctor.rb:232`](../../src/tools/doctor.rb#L232) | `section_heap` | 0.0329 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 44 | [`src/tools/doctor.rb:237`](../../src/tools/doctor.rb#L237) | `section_heap` | 0.0329 | **16** (False Simplicity) |
| 45 | [`src/tools/doctor.rb:240`](../../src/tools/doctor.rb#L240) | `section_heap` | 0.0329 | **16** (False Simplicity) |
| 46 | [`src/tools/doctor.rb:242`](../../src/tools/doctor.rb#L242) | `section_heap` | 0.0329 | **16** (False Simplicity) |
| 47 | [`src/tools/doctor.rb:243`](../../src/tools/doctor.rb#L243) | `section_heap` | 0.0329 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 48 | [`src/tools/doctor.rb:247`](../../src/tools/doctor.rb#L247) | `section_heap` | 0.0329 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 49 | [`src/tools/doctor.rb:264`](../../src/tools/doctor.rb#L264) | `section_heap` | 0.0329 | **16** (Neglected Path Conditions) |
| 50 | [`src/tools/doctor.rb:266`](../../src/tools/doctor.rb#L266) | `section_heap` | 0.0329 | **16** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |

- ...(+1217 more genuine gaps)

> decomplex attribution on listed gaps: **417 span-precise**, **772 method-coarse (†)**, **168 ⚠dup?** (possibly redundant, not localised -- verify before testing). Coarse rows are whole-method: treat as a hint, not an arm-level discriminator.

## Category Summary
_4169 dark arms; only 1267 are genuine gaps. The rest are not test targets:_

| category | arms | % | what it means |
|---|---|---|---|
| type_norm | 1170 | 28.1% | type/nil guard -- likely dead if runtime contracts were stricter |
| dead | 714 | 17.1% | decision never executes in coverage -- audit as missing test or statically-dead code |
| defensive | 40 | 1.0% | inert / invariant-pinned -- accept, exclude from denominator |
| spurious | 78 | 1.9% | span-precise redundant/cloned decision (decomplex) -- refactor or delete, NOT a test target (coarse duplication never excludes -- it stays a gap, flagged ⚠dup?) |
| ffi | 0 | 0.0% | external/boundary call -- needs an integration test |
| diagnostic | 900 | 21.6% | error/raise/diagnostic path -- reachable only by invalid input (negative test) |
| genuine | 1267 | 30.4% | real reachable gap -- test it; ranked by fix-churn x decomplex structural deviance |

## Run Summary
- Repo: `/home/yahn/cheat`
- Files: 84; dark arms: 4169; genuine gaps: 1267
- General engine: categorizes uncovered branches, ranks genuine gaps by consumed boobytrap churn x optional decomplex structural deviance. Project lexicons (external-boundary methods and domain diagnostic methods) are caller-supplied, not baked in (see docs/agents/design.md).
- decomplex join is span-precise (the arm's line falls inside the flagged decision's source extent); `†` marks a (file, method) fallback when no flagged span contained the arm. A ranked candidate, not a verdict (Engler discipline).
