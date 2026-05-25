# SlopCop Report

> Top true coverage gaps, ranked by fix-churn x structural
> deviance. Every dark arm is categorized; only GENUINE
> reachable ones are gaps. Apex = uncovered AND historically
> churned (boobytrap) AND structurally deviant (decomplex).
> Owns categorization; consumes boobytrap (churn) and
> optional decomplex (spurious filter + deviance rank).

## Top True Gaps (431) — test these, ranked by fix-churn

| # | gap | method | churn | decomplex deviance |
|---|---|---|---|---|
| 1 | [`src/mir/mir_lowering.rb:630`](../../src/mir/mir_lowering.rb#L630) | `lower_body` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 2 | [`src/mir/mir_lowering.rb:634`](../../src/mir/mir_lowering.rb#L634) | `lower_body` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 3 | [`src/mir/mir_lowering.rb:658`](../../src/mir/mir_lowering.rb#L658) | `lower_body` | 1.0 | **10** (False Simplicity) |
| 4 | [`src/mir/mir_lowering.rb:1095`](../../src/mir/mir_lowering.rb#L1095) | `implicit_allocating_result_fact` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 5 | [`src/mir/mir_lowering.rb:1792`](../../src/mir/mir_lowering.rb#L1792) | `lower_drop` | 1.0 | **10** (False Simplicity, Neglected Updates) |
| 6 | [`src/mir/mir_lowering.rb:1865`](../../src/mir/mir_lowering.rb#L1865) | `lower_union_def` | 1.0 | **10** † (Broken Protocols, Decision Pressure, False Simplicity) |
| 7 | [`src/mir/mir_lowering.rb:2409`](../../src/mir/mir_lowering.rb#L2409) | `emit_builtin` | 1.0 | **10** (False Simplicity) |
| 8 | [`src/mir/mir_lowering.rb:494`](../../src/mir/mir_lowering.rb#L494) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 9 | [`src/mir/mir_lowering.rb:507`](../../src/mir/mir_lowering.rb#L507) | `lower` | 1.0 | **8** (False Simplicity, Neglected Updates) |
| 10 | [`src/mir/mir_lowering.rb:517`](../../src/mir/mir_lowering.rb#L517) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 11 | [`src/mir/mir_lowering.rb:518`](../../src/mir/mir_lowering.rb#L518) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 12 | [`src/mir/mir_lowering.rb:536`](../../src/mir/mir_lowering.rb#L536) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 13 | [`src/mir/mir_lowering.rb:542`](../../src/mir/mir_lowering.rb#L542) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 14 | [`src/mir/mir_lowering.rb:550`](../../src/mir/mir_lowering.rb#L550) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 15 | [`src/mir/mir_lowering.rb:558`](../../src/mir/mir_lowering.rb#L558) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 16 | [`src/mir/mir_lowering.rb:561`](../../src/mir/mir_lowering.rb#L561) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 17 | [`src/mir/mir_lowering.rb:564`](../../src/mir/mir_lowering.rb#L564) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 18 | [`src/mir/mir_lowering.rb:565`](../../src/mir/mir_lowering.rb#L565) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 19 | [`src/mir/mir_lowering.rb:566`](../../src/mir/mir_lowering.rb#L566) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 20 | [`src/mir/mir_lowering.rb:572`](../../src/mir/mir_lowering.rb#L572) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 21 | [`src/mir/mir_lowering.rb:574`](../../src/mir/mir_lowering.rb#L574) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 22 | [`src/mir/mir_lowering.rb:575`](../../src/mir/mir_lowering.rb#L575) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 23 | [`src/mir/mir_lowering.rb:576`](../../src/mir/mir_lowering.rb#L576) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 24 | [`src/mir/mir_lowering.rb:577`](../../src/mir/mir_lowering.rb#L577) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 25 | [`src/mir/mir_lowering.rb:580`](../../src/mir/mir_lowering.rb#L580) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 26 | [`src/mir/mir_lowering.rb:587`](../../src/mir/mir_lowering.rb#L587) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 27 | [`src/mir/mir_lowering.rb:588`](../../src/mir/mir_lowering.rb#L588) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 28 | [`src/mir/mir_lowering.rb:591`](../../src/mir/mir_lowering.rb#L591) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 29 | [`src/mir/mir_lowering.rb:592`](../../src/mir/mir_lowering.rb#L592) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 30 | [`src/mir/mir_lowering.rb:593`](../../src/mir/mir_lowering.rb#L593) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 31 | [`src/mir/mir_lowering.rb:594`](../../src/mir/mir_lowering.rb#L594) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 32 | [`src/mir/mir_lowering.rb:595`](../../src/mir/mir_lowering.rb#L595) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 33 | [`src/mir/mir_lowering.rb:596`](../../src/mir/mir_lowering.rb#L596) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 34 | [`src/mir/mir_lowering.rb:598`](../../src/mir/mir_lowering.rb#L598) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 35 | [`src/mir/mir_lowering.rb:599`](../../src/mir/mir_lowering.rb#L599) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 36 | [`src/mir/mir_lowering.rb:600`](../../src/mir/mir_lowering.rb#L600) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 37 | [`src/mir/mir_lowering.rb:601`](../../src/mir/mir_lowering.rb#L601) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 38 | [`src/mir/mir_lowering.rb:602`](../../src/mir/mir_lowering.rb#L602) | `lower` | 1.0 | **8** † (Decision Pressure, False Simplicity, Neglected Updates) |
| 39 | [`src/mir/mir_lowering.rb:613`](../../src/mir/mir_lowering.rb#L613) | `apply_lowered_coercion` | 1.0 | **8** (Broken Protocols) |
| 40 | [`src/mir/mir_lowering.rb:614`](../../src/mir/mir_lowering.rb#L614) | `apply_lowered_coercion` | 1.0 | **8** † (Broken Protocols, Decision Pressure) |
| 41 | [`src/mir/mir_lowering.rb:1129`](../../src/mir/mir_lowering.rb#L1129) | `ownership_transfers_for_stmt` | 1.0 | **8** † (Broken Protocols, Decision Pressure) |
| 42 | [`src/mir/mir_lowering.rb:1131`](../../src/mir/mir_lowering.rb#L1131) | `ownership_transfers_for_stmt` | 1.0 | **8** † (Broken Protocols, Decision Pressure) |
| 43 | [`src/mir/mir_lowering.rb:1320`](../../src/mir/mir_lowering.rb#L1320) | `collect_bg_capture_transfer_roots` | 1.0 | **8** (False Simplicity) |
| 44 | [`src/mir/mir_lowering.rb:1352`](../../src/mir/mir_lowering.rb#L1352) | `collect_moved_arg_roots` | 1.0 | **8** † ⚠dup? (Decision Pressure, False Simplicity, Missing Abstractions) |
| 45 | [`src/mir/mir_lowering.rb:1356`](../../src/mir/mir_lowering.rb#L1356) | `collect_moved_arg_roots` | 1.0 | **8** † ⚠dup? (Decision Pressure, False Simplicity, Missing Abstractions) |
| 46 | [`src/mir/mir_lowering.rb:1360`](../../src/mir/mir_lowering.rb#L1360) | `collect_moved_arg_roots` | 1.0 | **8** (False Simplicity) |
| 47 | [`src/mir/mir_lowering.rb:1381`](../../src/mir/mir_lowering.rb#L1381) | `walk_ast_for_moved_args` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 48 | [`src/mir/mir_lowering.rb:1451`](../../src/mir/mir_lowering.rb#L1451) | `stamp_source_line!` | 1.0 | **8** † (Decision Pressure, False Simplicity) |
| 49 | [`src/mir/mir_lowering.rb:1499`](../../src/mir/mir_lowering.rb#L1499) | `lower_program` | 1.0 | **8** (False Simplicity) |
| 50 | [`src/mir/mir_lowering.rb:1502`](../../src/mir/mir_lowering.rb#L1502) | `lower_program` | 1.0 | **8** (False Simplicity) |

- ...(+381 more genuine gaps)

> decomplex attribution on listed gaps: **103 span-precise**, **286 method-coarse (†)**, **37 ⚠dup?** (possibly redundant, not localised -- verify before testing). Coarse rows are whole-method: treat as a hint, not an arm-level discriminator.

## Category Summary
_1821 dark arms; only 431 are genuine gaps. The rest are not test targets:_

| category | arms | % | what it means |
|---|---|---|---|
| type_norm | 374 | 20.5% | type/nil guard -- likely dead if the contract were strictly typed |
| dead | 477 | 26.2% | decision never executes in coverage -- audit as missing test or statically-dead code |
| defensive | 7 | 0.4% | inert / invariant-pinned -- accept, exclude from denominator |
| spurious | 16 | 0.9% | span-precise redundant/cloned decision (decomplex) -- refactor or delete, NOT a test target (coarse duplication never excludes -- it stays a gap, flagged ⚠dup?) |
| ffi | 147 | 8.1% | external/boundary call -- needs an integration test |
| diagnostic | 369 | 20.3% | error/raise path -- reachable only by invalid input (negative test) |
| genuine | 431 | 23.7% | real reachable gap -- test it; ranked by fix-churn x decomplex structural deviance |

## Run Summary
- Repo: `/home/yahn/cheat`
- Files: 7; dark arms: 1821; genuine gaps: 431
- General engine: categorizes uncovered branches, ranks genuine gaps by consumed boobytrap churn x optional decomplex structural deviance. Project lexicon (external-boundary methods) is caller-supplied, not baked in (see docs/agents/design.md).
- decomplex join is span-precise (the arm's line falls inside the flagged decision's source extent); `†` marks a (file, method) fallback when no flagged span contained the arm. A ranked candidate, not a verdict (Engler discipline).
