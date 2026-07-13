# Complexity Coverage Audit

Status: implemented and measured on `compiler/ruby`, excluding `compiler/ruby/tools/**`.

## Result semantics

Espalier now reports two different claims instead of conflating them:

- `big_o` / `big_o_space` are authoritative totals. They are `unknown` if any reachable operation lacks a proved bound.
- `big_o_known_component` / `big_o_space_known_component` retain the strongest component that static evidence does prove.
- `big_o_complete` / `big_o_space_complete` state whether the total is complete.

This corrects the previous behavior, which labeled a known structural component as the method's complete complexity even when an external call or callback could perform arbitrary work.

## Compiler corpus measurement

The corpus contains 5,578 functions.

| Claim | Complete | Partial/unknown |
| --- | ---: | ---: |
| Runtime total | 378 (6.78%) | 5,200 (93.22%) |
| Auxiliary-space total | 372 (6.67%) | 5,206 (93.33%) |

The low complete-total percentage is not a regression in structural analysis. It is the honest result of requiring every reachable call to have a bound. Most compiler functions contain at least one unresolved receiver, external call, or callback. Those functions still retain reviewable known components:

| Known runtime component | Functions |
| --- | ---: |
| O(1) | 4,254 |
| O(N) | 1,181 |
| O(N log N) | 12 |
| O(N²) | 124 |
| O(N³) | 2 |
| structurally unknown | 5 |

The former report had 953 `unknown` results, but those figures were lower bounds presented as totals. They must not be compared directly with the new authoritative-total count.

## Structural progress

Compared with the pre-change normalized facts:

| Root fact | Before | After | Change |
| --- | ---: | ---: | ---: |
| Methods with unknown iterator execution | 276 | 220 | -56 (-20.3%) |
| Unknown iterator facts | 390 | 303 | -87 (-22.3%) |
| Methods with unknown direct-recursion progress | 93 | 92 | -1 |

New evidence emitted by FactMine:

- 55 callback-parameter invocation facts, allowing user-defined wrappers and traversals to be distinguished.
- 46 deferred closure regions, preventing lambda/proc bodies from being charged to closure creation.
- 815 typed receiver call-cost facts, including auxiliary-space costs.
- visited-set guarded structural-recursion facts.
- argument size-change facts used to prove the safe, single-branch subset of mutually recursive components.

Known components propagate through incomplete callees. For example, the receiver-state golden regression retains its proven O(N³) component while its authoritative total remains unknown if arbitrary leaf work is unresolved.

## Architecture boundary

Espalier consumes only normalized facts and contains no new language-specific inference. Ruby syntax, callback vocabulary, deferred-constructor recognition, and standard-library cost tables live in FactMine's Ruby syntax adapter. The generic FactMine complexity pass operates on adapter-provided semantics and normalized type/flow facts.

## Remaining work

The dominant remaining gap is receiver/callee resolution, not loop or recursion recognition. Raising authoritative coverage requires more complete type and call-target facts, followed by language-adapter cost summaries for resolved library calls. Espalier must not recover coverage by assuming an unresolved call is O(1).

## Verification

- FactMine: 272 unit tests plus 20 integration/oracle tests passed.
- FactMine line coverage: 95.27% overall; the changed `syntax/complexity_facts.rs` pass is 96.91% line-covered.
- Every Espalier test file, including the cross-layer Big-O golden corpus, passed.
