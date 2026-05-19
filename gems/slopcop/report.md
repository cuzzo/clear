# SlopCop Report

> Top true coverage gaps, ranked by fix-churn x structural
> deviance. Every dark arm is categorized; only GENUINE
> reachable ones are gaps. Apex = uncovered AND historically
> churned (boobytrap) AND structurally deviant (decomplex).
> Owns categorization; consumes boobytrap (churn) and
> optional decomplex (spurious filter + deviance rank).

## Top True Gaps (390) — test these, ranked by fix-churn

| # | gap | method | churn | decomplex deviance |
|---|---|---|---|---|
| 1 | [`src/mir/mir_lowering.rb:6175`](../../src/mir/mir_lowering.rb#L6175) | `lower_var_decl` | 1.0 | **20** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +5) |
| 2 | [`src/mir/mir_lowering.rb:6289`](../../src/mir/mir_lowering.rb#L6289) | `lower_var_decl` | 1.0 | **20** (False Simplicity, Neglected Updates) |
| 3 | [`src/mir/mir_lowering.rb:6301`](../../src/mir/mir_lowering.rb#L6301) | `lower_var_decl` | 1.0 | **20** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +5) |
| 4 | [`src/mir/mir_lowering.rb:6359`](../../src/mir/mir_lowering.rb#L6359) | `lower_var_decl` | 1.0 | **20** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +5) |
| 5 | [`src/mir/mir_lowering.rb:6360`](../../src/mir/mir_lowering.rb#L6360) | `lower_var_decl` | 1.0 | **20** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +5) |
| 6 | [`src/mir/mir_lowering.rb:6360`](../../src/mir/mir_lowering.rb#L6360) | `lower_var_decl` | 1.0 | **20** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +5) |
| 7 | [`src/mir/mir_lowering.rb:6361`](../../src/mir/mir_lowering.rb#L6361) | `lower_var_decl` | 1.0 | **20** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +5) |
| 8 | [`src/mir/mir_lowering.rb:2361`](../../src/mir/mir_lowering.rb#L2361) | `lower_list_lit` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 9 | [`src/mir/mir_lowering.rb:2368`](../../src/mir/mir_lowering.rb#L2368) | `lower_list_lit` | 1.0 | **16** (Neglected Path Conditions) |
| 10 | [`src/mir/mir_lowering.rb:2369`](../../src/mir/mir_lowering.rb#L2369) | `lower_list_lit` | 1.0 | **16** (Derived-State Staleness, Neglected Path Conditions) |
| 11 | [`src/mir/mir_lowering.rb:2373`](../../src/mir/mir_lowering.rb#L2373) | `lower_list_lit` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 12 | [`src/mir/mir_lowering.rb:2374`](../../src/mir/mir_lowering.rb#L2374) | `lower_list_lit` | 1.0 | **16** (Neglected Path Conditions) |
| 13 | [`src/mir/mir_lowering.rb:2375`](../../src/mir/mir_lowering.rb#L2375) | `lower_list_lit` | 1.0 | **16** (Neglected Path Conditions) |
| 14 | [`src/mir/mir_lowering.rb:2379`](../../src/mir/mir_lowering.rb#L2379) | `lower_list_lit` | 1.0 | **16** (Neglected Path Conditions) |
| 15 | [`src/mir/mir_lowering.rb:2413`](../../src/mir/mir_lowering.rb#L2413) | `lower_list_lit` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 16 | [`src/mir/mir_lowering.rb:5127`](../../src/mir/mir_lowering.rb#L5127) | `lower_smooth` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 17 | [`src/mir/mir_lowering.rb:5167`](../../src/mir/mir_lowering.rb#L5167) | `lower_smooth` | 1.0 | **16** (Derived-State Staleness) |
| 18 | [`src/mir/mir_lowering.rb:5170`](../../src/mir/mir_lowering.rb#L5170) | `lower_smooth` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 19 | [`src/mir/mir_lowering.rb:5180`](../../src/mir/mir_lowering.rb#L5180) | `lower_smooth` | 1.0 | **16** (Broken Protocols, Derived-State Staleness, False Simplicity, +1) |
| 20 | [`src/mir/mir_lowering.rb:5186`](../../src/mir/mir_lowering.rb#L5186) | `lower_smooth` | 1.0 | **16** (Derived-State Staleness, False Simplicity) |
| 21 | [`src/mir/mir_lowering.rb:5187`](../../src/mir/mir_lowering.rb#L5187) | `lower_smooth` | 1.0 | **16** (Derived-State Staleness, False Simplicity) |
| 22 | [`src/mir/mir_lowering.rb:5187`](../../src/mir/mir_lowering.rb#L5187) | `lower_smooth` | 1.0 | **16** (Derived-State Staleness, False Simplicity) |
| 23 | [`src/mir/mir_lowering.rb:5196`](../../src/mir/mir_lowering.rb#L5196) | `lower_smooth` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 24 | [`src/mir/mir_lowering.rb:5199`](../../src/mir/mir_lowering.rb#L5199) | `lower_smooth` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 25 | [`src/mir/mir_lowering.rb:6545`](../../src/mir/mir_lowering.rb#L6545) | `lower_indexed_assignment` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 26 | [`src/mir/mir_lowering.rb:6728`](../../src/mir/mir_lowering.rb#L6728) | `lower_indexed_assignment` | 1.0 | **16** (Broken Protocols) |
| 27 | [`src/mir/mir_lowering.rb:6744`](../../src/mir/mir_lowering.rb#L6744) | `lower_indexed_assignment` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 28 | [`src/mir/mir_lowering.rb:6752`](../../src/mir/mir_lowering.rb#L6752) | `lower_indexed_assignment` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 29 | [`src/mir/mir_lowering.rb:7150`](../../src/mir/mir_lowering.rb#L7150) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 30 | [`src/mir/mir_lowering.rb:7216`](../../src/mir/mir_lowering.rb#L7216) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 31 | [`src/mir/mir_lowering.rb:7231`](../../src/mir/mir_lowering.rb#L7231) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 32 | [`src/mir/mir_lowering.rb:7253`](../../src/mir/mir_lowering.rb#L7253) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 33 | [`src/mir/mir_lowering.rb:7254`](../../src/mir/mir_lowering.rb#L7254) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 34 | [`src/mir/mir_lowering.rb:7255`](../../src/mir/mir_lowering.rb#L7255) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 35 | [`src/mir/mir_lowering.rb:7275`](../../src/mir/mir_lowering.rb#L7275) | `lower_match` | 1.0 | **16** (False Simplicity, Neglected Path Conditions) |
| 36 | [`src/mir/mir_lowering.rb:7276`](../../src/mir/mir_lowering.rb#L7276) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 37 | [`src/mir/mir_lowering.rb:7280`](../../src/mir/mir_lowering.rb#L7280) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 38 | [`src/mir/mir_lowering.rb:7280`](../../src/mir/mir_lowering.rb#L7280) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 39 | [`src/mir/mir_lowering.rb:7281`](../../src/mir/mir_lowering.rb#L7281) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 40 | [`src/mir/mir_lowering.rb:7285`](../../src/mir/mir_lowering.rb#L7285) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 41 | [`src/mir/mir_lowering.rb:7288`](../../src/mir/mir_lowering.rb#L7288) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 42 | [`src/mir/mir_lowering.rb:7289`](../../src/mir/mir_lowering.rb#L7289) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 43 | [`src/mir/mir_lowering.rb:7290`](../../src/mir/mir_lowering.rb#L7290) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 44 | [`src/mir/mir_lowering.rb:7290`](../../src/mir/mir_lowering.rb#L7290) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 45 | [`src/mir/mir_lowering.rb:7291`](../../src/mir/mir_lowering.rb#L7291) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 46 | [`src/mir/mir_lowering.rb:7293`](../../src/mir/mir_lowering.rb#L7293) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 47 | [`src/mir/mir_lowering.rb:7293`](../../src/mir/mir_lowering.rb#L7293) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 48 | [`src/mir/mir_lowering.rb:7293`](../../src/mir/mir_lowering.rb#L7293) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 49 | [`src/mir/mir_lowering.rb:7298`](../../src/mir/mir_lowering.rb#L7298) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 50 | [`src/mir/mir_lowering.rb:7300`](../../src/mir/mir_lowering.rb#L7300) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |

- ...(+340 more genuine gaps)

> decomplex attribution on listed gaps: **91 span-precise**, **261 method-coarse (†)**, **42 ⚠dup?** (possibly redundant, not localised -- verify before testing). Coarse rows are whole-method: treat as a hint, not an arm-level discriminator.

## Category Summary
_3413 dark arms; only 390 are genuine gaps. The rest are not test targets:_

| category | arms | % | what it means |
|---|---|---|---|
| type_norm | 763 | 22.4% | type/nil guard -- likely dead if the contract were strictly typed |
| dead | 272 | 8.0% | decision never executes -- audit as dead code, delete |
| defensive | 233 | 6.8% | inert / invariant-pinned -- accept, exclude from denominator |
| spurious | 34 | 1.0% | span-precise redundant/cloned decision (decomplex) -- refactor or delete, NOT a test target (coarse duplication never excludes -- it stays a gap, flagged ⚠dup?) |
| ffi | 152 | 4.5% | external/boundary call -- needs an integration test |
| diagnostic | 1569 | 46.0% | error/raise path -- reachable only by invalid input (negative test) |
| genuine | 390 | 11.4% | real reachable gap -- test it; ranked by fix-churn x decomplex structural deviance |

## Run Summary
- Repo: `/home/yahn/cheat`
- Files: 3; dark arms: 3413; genuine gaps: 390
- General engine: categorizes uncovered branches, ranks genuine gaps by consumed boobytrap churn x optional decomplex structural deviance. Project lexicon (external-boundary methods) is caller-supplied, not baked in (see docs/agents/design.md).
- decomplex join is span-precise (the arm's line falls inside the flagged decision's source extent); `†` marks a (file, method) fallback when no flagged span contained the arm. A ranked candidate, not a verdict (Engler discipline).
