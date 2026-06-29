# SlopCop Report

> Top true coverage gaps, ranked by fix-churn x structural
> deviance. Every dark arm is categorized; only GENUINE
> reachable ones are gaps. Apex = uncovered AND historically
> churned (boobytrap), structurally deviant (decomplex),
> and weakly verified when mutation facts are supplied.
> Owns categorization; consumes boobytrap (churn) and
> optional decomplex (spurious filter + deviance rank).

## Top True Gaps (55) — test these, ranked by fix-churn

| # | gap | method | churn | decomplex deviance |
|---|---|---|---|---|
| 1 | [`src/mir/mir_lowering.rb:3506`](../../src/mir/mir_lowering.rb#L3506) | `emit_stmts_zig` | 0.0763 | - |
| 2 | [`src/mir/mir.rb:1555`](../../src/mir/mir.rb#L1555) | `fetch` | 0.0615 | - |
| 3 | [`src/mir/lowering/functions.rb:681`](../../src/mir/lowering/functions.rb#L681) | `reentrance_guard_prologue` | 0.049 | - |
| 4 | [`src/mir/lowering/functions.rb:769`](../../src/mir/lowering/functions.rb#L769) | `takes_param_ownership_mir` | 0.049 | - |
| 5 | [`src/mir/lowering/functions.rb:1085`](../../src/mir/lowering/functions.rb#L1085) | `ownership_consumed_arg_names` | 0.049 | - |
| 6 | [`src/mir/lowering/functions.rb:1085`](../../src/mir/lowering/functions.rb#L1085) | `ownership_consumed_arg_names` | 0.049 | - |
| 7 | [`src/mir/lowering/functions.rb:1085`](../../src/mir/lowering/functions.rb#L1085) | `ownership_consumed_arg_names` | 0.049 | - |
| 8 | [`src/mir/lowering/functions.rb:1085`](../../src/mir/lowering/functions.rb#L1085) | `ownership_consumed_arg_names` | 0.049 | - |
| 9 | [`src/mir/lowering/functions.rb:1085`](../../src/mir/lowering/functions.rb#L1085) | `ownership_consumed_arg_names` | 0.049 | - |
| 10 | [`src/mir/lowering/control_flow.rb:470`](../../src/mir/lowering/control_flow.rb#L470) | `for_each_loop_stmt` | 0.038 | - |
| 11 | [`src/mir/lowering/control_flow.rb:1186`](../../src/mir/lowering/control_flow.rb#L1186) | `collect_returned_binding_names` | 0.038 | - |
| 12 | [`src/mir/lowering/control_flow.rb:1186`](../../src/mir/lowering/control_flow.rb#L1186) | `collect_returned_binding_names` | 0.038 | - |
| 13 | [`src/mir/lowering/control_flow.rb:1186`](../../src/mir/lowering/control_flow.rb#L1186) | `collect_returned_binding_names` | 0.038 | - |
| 14 | [`src/mir/lowering/control_flow.rb:1192`](../../src/mir/lowering/control_flow.rb#L1192) | `collect_returned_binding_names` | 0.038 | - |
| 15 | [`src/mir/lowering/expressions.rb:119`](../../src/mir/lowering/expressions.rb#L119) | `field_root` | 0.023 | - |
| 16 | [`src/mir/lowering/expressions.rb:207`](../../src/mir/lowering/expressions.rb#L207) | `lower_literal` | 0.023 | - |
| 17 | [`src/mir/lowering/expressions.rb:1298`](../../src/mir/lowering/expressions.rb#L1298) | `index_access_value` | 0.023 | - |
| 18 | [`src/mir/lowering/expressions.rb:1345`](../../src/mir/lowering/expressions.rb#L1345) | `index_collection_value` | 0.023 | - |
| 19 | [`src/mir/lowering/expressions.rb:1814`](../../src/mir/lowering/expressions.rb#L1814) | `lower_slice` | 0.023 | - |
| 20 | [`src/mir/lowering/variables.rb:1173`](../../src/mir/lowering/variables.rb#L1173) | `indexed_assignment_dispatch` | 0.0197 | - |
| 21 | [`src/backends/mir_emitter.rb:588`](../../src/backends/mir_emitter.rb#L588) | `emit_extern_trampoline` | 0.0154 | - |
| 22 | [`src/backends/mir_emitter.rb:1219`](../../src/backends/mir_emitter.rb#L1219) | `emit_with_match_prelude` | 0.0154 | - |
| 23 | [`src/backends/mir_emitter.rb:1279`](../../src/backends/mir_emitter.rb#L1279) | `emit_failure_action` | 0.0154 | - |
| 24 | [`src/backends/mir_emitter.rb:1328`](../../src/backends/mir_emitter.rb#L1328) | `emit_fallible_lock_acquire_expr` | 0.0154 | - |
| 25 | [`src/backends/mir_emitter.rb:1818`](../../src/backends/mir_emitter.rb#L1818) | `emit_catch_default_body` | 0.0154 | - |
| 26 | [`src/backends/mir_emitter.rb:2665`](../../src/backends/mir_emitter.rb#L2665) | `emit_cast` | 0.0154 | - |
| 27 | [`src/backends/mir_emitter.rb:2671`](../../src/backends/mir_emitter.rb#L2671) | `emit_cast` | 0.0154 | - |
| 28 | [`src/backends/mir_emitter.rb:2761`](../../src/backends/mir_emitter.rb#L2761) | `emit_type_sentinel` | 0.0154 | - |
| 29 | [`src/mir/rewriters/pipeline_rewriter.rb:179`](../../src/mir/rewriters/pipeline_rewriter.rb#L179) | `rewrite_pipeline` | 0.0145 | - |
| 30 | [`src/mir/rewriters/pipeline_rewriter.rb:317`](../../src/mir/rewriters/pipeline_rewriter.rb#L317) | `fuse_pipeline` | 0.0145 | - |
| 31 | [`src/mir/rewriters/pipeline_rewriter.rb:319`](../../src/mir/rewriters/pipeline_rewriter.rb#L319) | `fuse_pipeline` | 0.0145 | - |
| 32 | [`src/mir/rewriters/pipeline_rewriter.rb:321`](../../src/mir/rewriters/pipeline_rewriter.rb#L321) | `fuse_pipeline` | 0.0145 | - |
| 33 | [`src/mir/lowering/capabilities.rb:404`](../../src/mir/lowering/capabilities.rb#L404) | `borrowed_capability_binding` | 0.0122 | - |
| 34 | [`src/mir/lowering/capabilities.rb:434`](../../src/mir/lowering/capabilities.rb#L434) | `restrict_capability_binding` | 0.0122 | - |
| 35 | [`src/mir/fsm_transform/emit.rb:1401`](../../src/mir/fsm_transform/emit.rb#L1401) | `self.compute_sp_indices` | 0.0081 | - |
| 36 | [`src/mir/fsm_ops.rb:377`](../../src/mir/fsm_ops.rb#L377) | `lower_expr` | 0.0079 | - |
| 37 | [`src/semantic/bg_capture_classifier.rb:137`](../../src/semantic/bg_capture_classifier.rb#L137) | `self.apply_capture_storage_provenance!` | 0.0079 | - |
| 38 | [`src/mir/fsm_transform/recursive_splitter.rb:600`](../../src/mir/fsm_transform/recursive_splitter.rb#L600) | `self.remap_tail` | 0.0042 | - |
| 39 | [`src/mir/fsm_transform/segments.rb:335`](../../src/mir/fsm_transform/segments.rb#L335) | `self.contains_suspend_anywhere?` | 0.0042 | - |
| 40 | [`src/mir/fsm_transform/segments.rb:335`](../../src/mir/fsm_transform/segments.rb#L335) | `self.contains_suspend_anywhere?` | 0.0042 | - |
| 41 | [`src/semantic/concurrency_checks.rb:67`](../../src/semantic/concurrency_checks.rb#L67) | `self.check_hold_across_yield!` | 0.0036 | - |
| 42 | [`src/ast/parser.rb:1835`](../../src/ast/parser.rb#L1835) | `get_precedence` | 0.0005 | - |
| 43 | [`src/ast/type.rb:2004`](../../src/ast/type.rb#L2004) | `fsm_foreach_descriptor` | 0.0003 | - |
| 44 | [`src/ast/type.rb:3004`](../../src/ast/type.rb#L3004) | `needs_explicit_cleanup?` | 0.0003 | - |
| 45 | [`src/ast/type.rb:3728`](../../src/ast/type.rb#L3728) | `integer_range_target_type` | 0.0003 | - |
| 46 | [`src/annotator/helpers/fixable_helpers.rb:1357`](../../src/annotator/helpers/fixable_helpers.rb#L1357) | `emit_with_cap_mismatch!` | 0.0 | - |
| 47 | [`src/annotator/helpers/fixable_helpers.rb:1375`](../../src/annotator/helpers/fixable_helpers.rb#L1375) | `emit_with_cap_mismatch!` | 0.0 | - |
| 48 | [`src/annotator/helpers/fixable_helpers.rb:1375`](../../src/annotator/helpers/fixable_helpers.rb#L1375) | `emit_with_cap_mismatch!` | 0.0 | - |
| 49 | [`src/lsp/diagnostics.rb:123`](../../src/lsp/diagnostics.rb#L123) | `self.fallback_token_length` | 0.0 | - |
| 50 | [`src/lsp/diagnostics.rb:123`](../../src/lsp/diagnostics.rb#L123) | `self.fallback_token_length` | 0.0 | - |

- ...(+5 more genuine gaps)

## Category Summary
_1185 dark arms; only 55 are genuine gaps. The rest are not test targets:_

| category | arms | % | what it means |
|---|---|---|---|
| type_norm | 338 | 28.5% | type/null guard -- likely dead if runtime contracts were stricter |
| dead | 726 | 61.3% | decision never executes in coverage -- audit as missing test or statically-dead code |
| defensive | 15 | 1.3% | inert / invariant-pinned -- accept, exclude from denominator |
| spurious | 0 | 0.0% | span-precise redundant/cloned decision (decomplex) -- refactor or delete, NOT a test target (coarse duplication never excludes -- it stays a gap, flagged ⚠dup?) |
| ffi | 0 | 0.0% | external/boundary call -- needs an integration test |
| diagnostic | 51 | 4.3% | language diagnostic/error path -- reachable only by invalid input (negative test) |
| genuine | 55 | 4.6% | real reachable gap -- test it; ranked by fix-churn x decomplex structural deviance |

## Run Summary
- Repo: `/home/yahn/cheat`
- Files: 103; dark arms: 1185; genuine gaps: 55
- Coverage input: SimpleCov
- Mutation facts: not supplied
- Branch source: coverage=1185
- General engine: categorizes uncovered branches, ranks genuine gaps by consumed boobytrap churn x optional decomplex structural deviance. Project lexicons (external-boundary methods and domain diagnostic methods) are caller-supplied, not baked in (see docs/agents/design.md).
- decomplex join is span-precise (the arm's line falls inside the flagged decision's source extent); `†` marks a (file, method) fallback when no flagged span contained the arm. A ranked candidate, not a verdict (Engler discipline).
