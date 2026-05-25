# SlopCop Report

> Top true coverage gaps, ranked by fix-churn x structural
> deviance. Every dark arm is categorized; only GENUINE
> reachable ones are gaps. Apex = uncovered AND historically
> churned (boobytrap) AND structurally deviant (decomplex).
> Owns categorization; consumes boobytrap (churn) and
> optional decomplex (spurious filter + deviance rank).

## Top True Gaps (299) — test these, ranked by fix-churn

| # | gap | method | churn | decomplex deviance |
|---|---|---|---|---|
| 1 | [`src/mir/mir_lowering.rb:243`](../../src/mir/mir_lowering.rb#L243) | `place_value_for_destination` | 1.0 | **10** † (Broken Protocols, Decision Pressure, Neglected Path Conditions) |
| 2 | [`src/mir/mir_lowering.rb:397`](../../src/mir/mir_lowering.rb#L397) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 3 | [`src/mir/mir_lowering.rb:410`](../../src/mir/mir_lowering.rb#L410) | `lower` | 1.0 | **10** (False Simplicity) |
| 4 | [`src/mir/mir_lowering.rb:420`](../../src/mir/mir_lowering.rb#L420) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 5 | [`src/mir/mir_lowering.rb:421`](../../src/mir/mir_lowering.rb#L421) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 6 | [`src/mir/mir_lowering.rb:439`](../../src/mir/mir_lowering.rb#L439) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 7 | [`src/mir/mir_lowering.rb:445`](../../src/mir/mir_lowering.rb#L445) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 8 | [`src/mir/mir_lowering.rb:453`](../../src/mir/mir_lowering.rb#L453) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 9 | [`src/mir/mir_lowering.rb:461`](../../src/mir/mir_lowering.rb#L461) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 10 | [`src/mir/mir_lowering.rb:464`](../../src/mir/mir_lowering.rb#L464) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 11 | [`src/mir/mir_lowering.rb:467`](../../src/mir/mir_lowering.rb#L467) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 12 | [`src/mir/mir_lowering.rb:468`](../../src/mir/mir_lowering.rb#L468) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 13 | [`src/mir/mir_lowering.rb:469`](../../src/mir/mir_lowering.rb#L469) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 14 | [`src/mir/mir_lowering.rb:475`](../../src/mir/mir_lowering.rb#L475) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 15 | [`src/mir/mir_lowering.rb:477`](../../src/mir/mir_lowering.rb#L477) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 16 | [`src/mir/mir_lowering.rb:478`](../../src/mir/mir_lowering.rb#L478) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 17 | [`src/mir/mir_lowering.rb:479`](../../src/mir/mir_lowering.rb#L479) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 18 | [`src/mir/mir_lowering.rb:480`](../../src/mir/mir_lowering.rb#L480) | `lower` | 1.0 | **10** (Broken Protocols) |
| 19 | [`src/mir/mir_lowering.rb:483`](../../src/mir/mir_lowering.rb#L483) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 20 | [`src/mir/mir_lowering.rb:490`](../../src/mir/mir_lowering.rb#L490) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 21 | [`src/mir/mir_lowering.rb:491`](../../src/mir/mir_lowering.rb#L491) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 22 | [`src/mir/mir_lowering.rb:494`](../../src/mir/mir_lowering.rb#L494) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 23 | [`src/mir/mir_lowering.rb:495`](../../src/mir/mir_lowering.rb#L495) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 24 | [`src/mir/mir_lowering.rb:496`](../../src/mir/mir_lowering.rb#L496) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 25 | [`src/mir/mir_lowering.rb:497`](../../src/mir/mir_lowering.rb#L497) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 26 | [`src/mir/mir_lowering.rb:498`](../../src/mir/mir_lowering.rb#L498) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 27 | [`src/mir/mir_lowering.rb:499`](../../src/mir/mir_lowering.rb#L499) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 28 | [`src/mir/mir_lowering.rb:500`](../../src/mir/mir_lowering.rb#L500) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 29 | [`src/mir/mir_lowering.rb:501`](../../src/mir/mir_lowering.rb#L501) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 30 | [`src/mir/mir_lowering.rb:502`](../../src/mir/mir_lowering.rb#L502) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 31 | [`src/mir/mir_lowering.rb:503`](../../src/mir/mir_lowering.rb#L503) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 32 | [`src/mir/mir_lowering.rb:504`](../../src/mir/mir_lowering.rb#L504) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 33 | [`src/mir/mir_lowering.rb:505`](../../src/mir/mir_lowering.rb#L505) | `lower` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 34 | [`src/mir/mir_lowering.rb:533`](../../src/mir/mir_lowering.rb#L533) | `lower_body` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 35 | [`src/mir/mir_lowering.rb:537`](../../src/mir/mir_lowering.rb#L537) | `lower_body` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 36 | [`src/mir/mir_lowering.rb:561`](../../src/mir/mir_lowering.rb#L561) | `lower_body` | 1.0 | **10** (False Simplicity) |
| 37 | [`src/mir/mir_lowering.rb:564`](../../src/mir/mir_lowering.rb#L564) | `lower_body` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 38 | [`src/mir/mir_lowering.rb:565`](../../src/mir/mir_lowering.rb#L565) | `lower_body` | 1.0 | **10** (False Simplicity) |
| 39 | [`src/mir/mir_lowering.rb:1647`](../../src/mir/mir_lowering.rb#L1647) | `lower_drop` | 1.0 | **10** (False Simplicity) |
| 40 | [`src/mir/mir_lowering.rb:2566`](../../src/mir/mir_lowering.rb#L2566) | `rc_retain_needed?` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 41 | [`src/mir/mir_lowering.rb:684`](../../src/mir/mir_lowering.rb#L684) | `append_ownership_transfers_for_mir_body` | 1.0 | **8** (False Simplicity) |
| 42 | [`src/mir/mir_lowering.rb:703`](../../src/mir/mir_lowering.rb#L703) | `append_ownership_transfers_for_mir_body` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 43 | [`src/mir/mir_lowering.rb:704`](../../src/mir/mir_lowering.rb#L704) | `append_ownership_transfers_for_mir_body` | 1.0 | **8** (False Simplicity) |
| 44 | [`src/mir/mir_lowering.rb:704`](../../src/mir/mir_lowering.rb#L704) | `append_ownership_transfers_for_mir_body` | 1.0 | **8** (False Simplicity) |
| 45 | [`src/mir/mir_lowering.rb:705`](../../src/mir/mir_lowering.rb#L705) | `append_ownership_transfers_for_mir_body` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 46 | [`src/mir/mir_lowering.rb:782`](../../src/mir/mir_lowering.rb#L782) | `ownership_facts_for_mir_node` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 47 | [`src/mir/mir_lowering.rb:900`](../../src/mir/mir_lowering.rb#L900) | `pre_terminator_transfer_marks` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 48 | [`src/mir/mir_lowering.rb:911`](../../src/mir/mir_lowering.rb#L911) | `pre_terminator_transfer_marks` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 49 | [`src/mir/mir_lowering.rb:913`](../../src/mir/mir_lowering.rb#L913) | `pre_terminator_transfer_marks` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 50 | [`src/mir/mir_lowering.rb:950`](../../src/mir/mir_lowering.rb#L950) | `implicit_allocating_result_fact` | 1.0 | **8** † (Decision Pressure, False Simplicity) |

- ...(+249 more genuine gaps)

> decomplex attribution on listed gaps: **33 span-precise**, **167 method-coarse (†)**, **12 ⚠dup?** (possibly redundant, not localised -- verify before testing). Coarse rows are whole-method: treat as a hint, not an arm-level discriminator.

## Category Summary
_1812 dark arms; only 299 are genuine gaps. The rest are not test targets:_

| category | arms | % | what it means |
|---|---|---|---|
| type_norm | 487 | 26.9% | type/nil guard -- likely dead if the contract were strictly typed |
| dead | 171 | 9.4% | decision never executes in coverage -- audit as missing test or statically-dead code |
| defensive | 169 | 9.3% | inert / invariant-pinned -- accept, exclude from denominator |
| spurious | 21 | 1.2% | span-precise redundant/cloned decision (decomplex) -- refactor or delete, NOT a test target (coarse duplication never excludes -- it stays a gap, flagged ⚠dup?) |
| ffi | 132 | 7.3% | external/boundary call -- needs an integration test |
| diagnostic | 533 | 29.4% | error/raise path -- reachable only by invalid input (negative test) |
| genuine | 299 | 16.5% | real reachable gap -- test it; ranked by fix-churn x decomplex structural deviance |

## Run Summary
- Repo: `/home/yahn/cheat`
- Files: 3; dark arms: 1812; genuine gaps: 299
- General engine: categorizes uncovered branches, ranks genuine gaps by consumed boobytrap churn x optional decomplex structural deviance. Project lexicon (external-boundary methods) is caller-supplied, not baked in (see docs/agents/design.md).
- decomplex join is span-precise (the arm's line falls inside the flagged decision's source extent); `†` marks a (file, method) fallback when no flagged span contained the arm. A ranked candidate, not a verdict (Engler discipline).
