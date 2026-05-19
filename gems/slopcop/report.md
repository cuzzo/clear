# SlopCop Report

> Top true coverage gaps, ranked by fix-churn x structural
> deviance. Every dark arm is categorized; only GENUINE
> reachable ones are gaps. Apex = uncovered AND historically
> churned (boobytrap) AND structurally deviant (decomplex).
> Owns categorization; consumes boobytrap (churn) and
> optional decomplex (spurious filter + deviance rank).

## Top True Gaps (387) — test these, ranked by fix-churn

| # | gap | method | churn | decomplex deviance |
|---|---|---|---|---|
| 1 | [`src/mir/mir_lowering.rb:6186`](../../src/mir/mir_lowering.rb#L6186) | `lower_var_decl` | 1.0 | **20** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +5) |
| 2 | [`src/mir/mir_lowering.rb:6286`](../../src/mir/mir_lowering.rb#L6286) | `lower_var_decl` | 1.0 | **20** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +5) |
| 3 | [`src/mir/mir_lowering.rb:6301`](../../src/mir/mir_lowering.rb#L6301) | `lower_var_decl` | 1.0 | **20** † ⚠dup? (Broken Protocols, Decision Pressure, Derived-State Staleness, +5) |
| 4 | [`src/mir/mir_lowering.rb:2368`](../../src/mir/mir_lowering.rb#L2368) | `lower_list_lit` | 1.0 | **16** (Neglected Path Conditions) |
| 5 | [`src/mir/mir_lowering.rb:2369`](../../src/mir/mir_lowering.rb#L2369) | `lower_list_lit` | 1.0 | **16** (Broken Protocols) |
| 6 | [`src/mir/mir_lowering.rb:2373`](../../src/mir/mir_lowering.rb#L2373) | `lower_list_lit` | 1.0 | **16** (Broken Protocols, Neglected Path Conditions) |
| 7 | [`src/mir/mir_lowering.rb:2374`](../../src/mir/mir_lowering.rb#L2374) | `lower_list_lit` | 1.0 | **16** (Neglected Path Conditions) |
| 8 | [`src/mir/mir_lowering.rb:2375`](../../src/mir/mir_lowering.rb#L2375) | `lower_list_lit` | 1.0 | **16** (Neglected Path Conditions) |
| 9 | [`src/mir/mir_lowering.rb:2379`](../../src/mir/mir_lowering.rb#L2379) | `lower_list_lit` | 1.0 | **16** (Derived-State Staleness, Neglected Path Conditions) |
| 10 | [`src/mir/mir_lowering.rb:2397`](../../src/mir/mir_lowering.rb#L2397) | `lower_list_lit` | 1.0 | **16** (Neglected Path Conditions) |
| 11 | [`src/mir/mir_lowering.rb:2398`](../../src/mir/mir_lowering.rb#L2398) | `lower_list_lit` | 1.0 | **16** (False Simplicity, Neglected Path Conditions, Neglected Updates) |
| 12 | [`src/mir/mir_lowering.rb:2398`](../../src/mir/mir_lowering.rb#L2398) | `lower_list_lit` | 1.0 | **16** (False Simplicity, Neglected Path Conditions, Neglected Updates) |
| 13 | [`src/mir/mir_lowering.rb:2402`](../../src/mir/mir_lowering.rb#L2402) | `lower_list_lit` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 14 | [`src/mir/mir_lowering.rb:2415`](../../src/mir/mir_lowering.rb#L2415) | `lower_list_lit` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 15 | [`src/mir/mir_lowering.rb:2429`](../../src/mir/mir_lowering.rb#L2429) | `lower_list_lit` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 16 | [`src/mir/mir_lowering.rb:5083`](../../src/mir/mir_lowering.rb#L5083) | `lower_smooth` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 17 | [`src/mir/mir_lowering.rb:5084`](../../src/mir/mir_lowering.rb#L5084) | `lower_smooth` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 18 | [`src/mir/mir_lowering.rb:5170`](../../src/mir/mir_lowering.rb#L5170) | `lower_smooth` | 1.0 | **16** (Broken Protocols, Neglected Path Conditions) |
| 19 | [`src/mir/mir_lowering.rb:5174`](../../src/mir/mir_lowering.rb#L5174) | `lower_smooth` | 1.0 | **16** (Derived-State Staleness) |
| 20 | [`src/mir/mir_lowering.rb:5175`](../../src/mir/mir_lowering.rb#L5175) | `lower_smooth` | 1.0 | **16** (Derived-State Staleness) |
| 21 | [`src/mir/mir_lowering.rb:5180`](../../src/mir/mir_lowering.rb#L5180) | `lower_smooth` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 22 | [`src/mir/mir_lowering.rb:5181`](../../src/mir/mir_lowering.rb#L5181) | `lower_smooth` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 23 | [`src/mir/mir_lowering.rb:5190`](../../src/mir/mir_lowering.rb#L5190) | `lower_smooth` | 1.0 | **16** (Broken Protocols, Derived-State Staleness, False Simplicity, +1) |
| 24 | [`src/mir/mir_lowering.rb:5196`](../../src/mir/mir_lowering.rb#L5196) | `lower_smooth` | 1.0 | **16** (Derived-State Staleness, False Simplicity) |
| 25 | [`src/mir/mir_lowering.rb:5199`](../../src/mir/mir_lowering.rb#L5199) | `lower_smooth` | 1.0 | **16** (Derived-State Staleness, False Simplicity) |
| 26 | [`src/mir/mir_lowering.rb:6545`](../../src/mir/mir_lowering.rb#L6545) | `lower_indexed_assignment` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 27 | [`src/mir/mir_lowering.rb:6575`](../../src/mir/mir_lowering.rb#L6575) | `lower_indexed_assignment` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 28 | [`src/mir/mir_lowering.rb:6576`](../../src/mir/mir_lowering.rb#L6576) | `lower_indexed_assignment` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 29 | [`src/mir/mir_lowering.rb:6576`](../../src/mir/mir_lowering.rb#L6576) | `lower_indexed_assignment` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 30 | [`src/mir/mir_lowering.rb:6744`](../../src/mir/mir_lowering.rb#L6744) | `lower_indexed_assignment` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 31 | [`src/mir/mir_lowering.rb:6757`](../../src/mir/mir_lowering.rb#L6757) | `lower_indexed_assignment` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 32 | [`src/mir/mir_lowering.rb:6780`](../../src/mir/mir_lowering.rb#L6780) | `lower_indexed_assignment` | 1.0 | **16** (Neglected Path Conditions) |
| 33 | [`src/mir/mir_lowering.rb:6781`](../../src/mir/mir_lowering.rb#L6781) | `lower_indexed_assignment` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 34 | [`src/mir/mir_lowering.rb:6788`](../../src/mir/mir_lowering.rb#L6788) | `lower_indexed_assignment` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +3) |
| 35 | [`src/mir/mir_lowering.rb:7201`](../../src/mir/mir_lowering.rb#L7201) | `lower_match` | 1.0 | **16** (Neglected Path Conditions) |
| 36 | [`src/mir/mir_lowering.rb:7231`](../../src/mir/mir_lowering.rb#L7231) | `lower_match` | 1.0 | **16** (False Simplicity) |
| 37 | [`src/mir/mir_lowering.rb:7239`](../../src/mir/mir_lowering.rb#L7239) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 38 | [`src/mir/mir_lowering.rb:7240`](../../src/mir/mir_lowering.rb#L7240) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 39 | [`src/mir/mir_lowering.rb:7280`](../../src/mir/mir_lowering.rb#L7280) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 40 | [`src/mir/mir_lowering.rb:7280`](../../src/mir/mir_lowering.rb#L7280) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 41 | [`src/mir/mir_lowering.rb:7281`](../../src/mir/mir_lowering.rb#L7281) | `lower_match` | 1.0 | **16** (False Simplicity) |
| 42 | [`src/mir/mir_lowering.rb:7285`](../../src/mir/mir_lowering.rb#L7285) | `lower_match` | 1.0 | **16** (False Simplicity, Neglected Path Conditions) |
| 43 | [`src/mir/mir_lowering.rb:7290`](../../src/mir/mir_lowering.rb#L7290) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 44 | [`src/mir/mir_lowering.rb:7290`](../../src/mir/mir_lowering.rb#L7290) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 45 | [`src/mir/mir_lowering.rb:7291`](../../src/mir/mir_lowering.rb#L7291) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 46 | [`src/mir/mir_lowering.rb:7293`](../../src/mir/mir_lowering.rb#L7293) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 47 | [`src/mir/mir_lowering.rb:7293`](../../src/mir/mir_lowering.rb#L7293) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 48 | [`src/mir/mir_lowering.rb:7293`](../../src/mir/mir_lowering.rb#L7293) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 49 | [`src/mir/mir_lowering.rb:7298`](../../src/mir/mir_lowering.rb#L7298) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |
| 50 | [`src/mir/mir_lowering.rb:7300`](../../src/mir/mir_lowering.rb#L7300) | `lower_match` | 1.0 | **16** † (Broken Protocols, Decision Pressure, Derived-State Staleness, +2) |

- ...(+337 more genuine gaps)

> decomplex attribution on listed gaps: **85 span-precise**, **272 method-coarse (†)**, **48 ⚠dup?** (possibly redundant, not localised -- verify before testing). Coarse rows are whole-method: treat as a hint, not an arm-level discriminator.

## Category Summary
_3413 dark arms; only 387 are genuine gaps. The rest are not test targets:_

| category | arms | % | what it means |
|---|---|---|---|
| type_norm | 795 | 23.3% | type/nil guard -- likely dead if the contract were strictly typed |
| dead | 252 | 7.4% | decision never executes -- audit as dead code, delete |
| defensive | 246 | 7.2% | inert / invariant-pinned -- accept, exclude from denominator |
| spurious | 32 | 0.9% | span-precise redundant/cloned decision (decomplex) -- refactor or delete, NOT a test target (coarse duplication never excludes -- it stays a gap, flagged ⚠dup?) |
| ffi | 181 | 5.3% | external/boundary call -- needs an integration test |
| diagnostic | 1520 | 44.5% | error/raise path -- reachable only by invalid input (negative test) |
| genuine | 387 | 11.3% | real reachable gap -- test it; ranked by fix-churn x decomplex structural deviance |

## Run Summary
- Repo: `/home/yahn/cheat`
- Files: 3; dark arms: 3413; genuine gaps: 387
- General engine: categorizes uncovered branches, ranks genuine gaps by consumed boobytrap churn x optional decomplex structural deviance. Project lexicon (external-boundary methods) is caller-supplied, not baked in (see docs/agents/design.md).
- decomplex join is span-precise (the arm's line falls inside the flagged decision's source extent); `†` marks a (file, method) fallback when no flagged span contained the arm. A ranked candidate, not a verdict (Engler discipline).
