# nil-kill Agent Progress

This note tracks the work that was planned during the latest nil-kill session but is not finished yet, plus the known limitations in the current implementation and the next highest-leverage opportunities.

## Current State

- The report can be generated with GitHub links and an excluded target set, for example excluding `src/tools`.
- The report now starts with project prioritization, hygiene overview, signature slot evidence, return hygiene, review actions, and collection/hash-record sections.
- Hash-record reporting is materially better: shapes, pressure, blockers, nested collection evidence, and similar keysets are surfaced.
- Hash-record auto-fix is routed through the verified loop instead of raw `apply --all` review actions.
- Hash-record rewriting uses parser-node-oriented matching for the main rewrite path, not broad regex replacement.
- Static param backflow exists as a verified-loop feature behind `loop --signature-backflow`.
- Static param backflow currently rejects candidates with weak/untyped types, `Object`, incompatible direct protocol requirements, or unresolved forwarding/capture gaps.
- The latest real-source verified loop improved params from `strong 1844, untyped 794` to `strong 1848, untyped 790` after reverting one semantically bad but Sorbet-clean candidate.

## Planned But Not Finished

- Recursive protocol analysis for forwarded params.
  - Current behavior blocks candidates when a param is forwarded to another helper or captured into an ivar.
  - Example source problem: `direct_index_get(ast_node)` forwarded `ast_node` to `direct_slice_backed_expr?`; static callsites suggested `Resolv::DNS::Name`, but the transitive helper needs AST-node behavior.
  - Needed: resolve helper calls, collect transitive protocol requirements, and only allow narrowing when the candidate satisfies the full protocol chain.

- Runtime-only param observation through the verified loop.
  - The report still has `candidate: runtime-only param observation` slots.
  - These are not currently promoted by a dedicated verified-loop mode.
  - Needed: reuse the same protocol preflight and verification rollback model as static backflow.

- Return signature autofix frontier.
  - Return slots did not improve in the latest phase.
  - What already exists: `propose_forwarded_return_chain_actions` plus `ForwardedReturnResolver` (`lib/nil_kill.rb:2119,2149`) resolve direct forwarded-return chains and emit `fix_sig_return` actions with HIGH/REVIEW confidence (specs at `spec/nil_kill_spec.rb:695-800`).
  - What is missing: no dedicated `loop --return-backflow` mode wires REVIEW return actions through the verified-rollback path the way `--signature-backflow` does for params. Collection-lookup returns, mixed-source returns, and weak collection-element returns are still unhandled.

- T.let self-correction loop.
  - nil-kill can inject/use `T.let` narrowly, and the hook can observe `T.let`, but the feedback is not wired into the main inference/reporting pipeline.
  - Needed: compare inferred `T.let` types against runtime observations, downgrade or correct bad inferences before reporting, and surface mismatches as evidence.

- Exhaustive hash-record promotion.
  - The current implementation can promote selected safe clusters, but it is not exhaustive across all producer/consumer/signature flows.
  - Needed: stronger cross-file propagation, recursive alias tracking, array/collection element propagation, optional keyset handling, and better shared-struct clustering.

- Cross-file cluster promotion coverage.
  - Some specs exist for cluster promotion/rollback, but coverage is not yet broad enough for the real-source cases we saw.
  - Needed: explicit tests for cross-file producer return signatures, consumer params, array element consumers, optional keysets, and rollback.

- Report design for denominator clarity.
  - Return hygiene rows show both section share and typed/untyped share, which is easy to misread.
  - Needed: table-like rendering or labels that make the denominator explicit.

- Default vs full report behavior.
  - The report supports collapsing long lists and a `--full` style, and `truncate_long_bullet_runs` (`lib/nil_kill.rb:6464`) now emits `- ... and N more (run with \`--full\` to see all)` when it truncates.
  - Remaining gap: the checked-in demo `report.md` should always be generated with `--full` so the public artifact stays exhaustive; verify that's wired into whatever produces it.

## Known Limitations And Bugs

- Static param backflow is intentionally conservative around forwarding gaps.
  - Any unresolved forwarded/captured param protocol currently blocks the action.
  - This avoids false positives, but it also leaves valid opportunities unclaimed.

- Static param backflow groups existing signatures by method name only.
  - If multiple classes define the same method name, backflow is skipped because the method is not singular.
  - This avoids unsafe cross-class matching, but leaves obvious class-scoped opportunities unresolved.
  - Better keying should include receiver/class when static callsites can provide it.

- Static callsite evidence can be too narrow without body protocol evidence.
  - Sorbet can accept a narrowed signature that is semantically wrong if the body is still compatible at the typechecker level.
  - The `Resolv::DNS::Name` case demonstrated this.
  - Verification is necessary but not sufficient for semantic intent; protocol analysis is the architectural guard.

- Runtime evidence can be coverage-biased.
  - A method not hit by runtime collection remains weak even if static evidence exists.
  - Runtime-only single-type observations may be correct or may be accidental coverage artifacts.

- `Object` and `T.nilable(Object)` are treated as non-informative for static backflow.
  - This is correct for auto-fix, but the report should make clear that these are blocked because they do not improve precision.

- Forwarded return blockers are still less actionable than high-pressure hash-map sections.
  - They now show better evidence, but they do not yet consistently point to one verified fix that unlocks many slots.

- Hash-record clustering is still heuristic.
  - Similar keysets and shared pressure can identify likely shared structs, but unrelated records can still look similar.
  - Eligibility/blocker logic prevents many unsafe edits, but the report can still be noisy.

- Hash-record mutation handling is conservative.
  - Dynamic keys and mutation generally block promotion.
  - We deliberately deprioritized safe-mutation support because construction-phase mutation is often better fixed by changing source style.

- Nested collection evidence is improved but incomplete.
  - Weak types like `T::Array[T.untyped]`, `T::Hash[T.untyped, T.untyped]`, and nested hash/array values still block many promotions.

- The CST rewrite node matching still has one known fragility.
  - Matching by line plus source slice can choose the wrong node if identical expressions appear twice on the same line.
  - The verified loop should catch behavioral breakage, but a more precise node identity model would be better.

- Report exclusions are easy to misunderstand.
  - Excluding `src/tools` changes target indexing, but some aggregate-looking numbers may remain close if the excluded directory had little effect on that metric.
  - The run summary now records excluded targets, but the report could do more to show delta versus the previous run.

- `apply --all` must remain unsafe for review actions.
  - Review actions and verified apply actions are different concepts.
  - Raw bulk application of review actions can break the codebase and should remain gated/neutered unless explicitly running a debug-only path.

## Next Biggest Opportunities

1. Return signature autofix frontier through the verified loop.
   - Why it matters: return hygiene has been the stalled metric across the last few phases, the forwarded-return resolver already emits actions, and adding a `--return-backflow` loop mode reuses existing scaffolding (`signature_backflow_review_actions` is the template).
   - Acceptance signal: `Return slots strong` rises, untyped return buckets for forwarded returns / collection lookup / mixed sources shrink, and the loop reports applied actions rather than skipped actions.

2. Verified runtime-only param narrowing.
   - Why it matters: there are still dozens of runtime-only param candidates and `--try-levenshtein` only fires when name/type similarity matches.
   - Acceptance signal: `candidate: runtime-only param observation` drops, `Param slots strong` rises, and the verified loop reports applied actions rather than skipped actions.

3. Recursive protocol analysis for signature backflow.
   - Why it matters: it turns currently blocked static-callsite candidates into safe candidates without relying on Sorbet trial-and-error, but the single blocking example (`Resolv::DNS::Name`) suggests the population is small relative to returns.
   - Acceptance signal: the report moves slots out of `blocked: forwarded return argument` or runtime-only candidate buckets into verified `fix_sig_param` actions, with no semantic false positives.

4. T.let observation feedback loop.
   - Why it matters: it can reduce false positives before report generation instead of discovering them during source verification.
   - Acceptance signal: injected/inferred `T.let` mismatches are visible in evidence, and incorrect inferred actions are downgraded before appearing as review or loop candidates.

5. Hash-record promotion propagation completeness.
   - Why it matters: this remains the largest structural cleanup opportunity.
   - Acceptance signal: selected high-pressure records can be promoted across producers, consumers, returns, params, arrays, and optional keysets while passing the verified loop.

6. Better report prioritization by "one fix unlocks many slots."
   - Why it matters: users should not have to read the full report to know what to do first.
   - Acceptance signal: the top summary highlights actions by expected slot impact and links directly to the relevant evidence.

7. Denominator-aware report tables.
   - Why it matters: rows like `addressed: void: 219 (10.1%); typed 219 (100.0%)` are technically correct but confusing.
   - Acceptance signal: each table labels total share separately from typed/untyped share.

8. Stronger class-scoped callsite indexing.
   - Why it matters: method-name-only grouping skips safe opportunities when common method names appear in multiple classes.
   - Acceptance signal: static backflow can safely handle class-qualified callsites without merging unrelated methods.

## Suggested Next Work Order

1. Split `lib/nil_kill.rb` (~9.7k lines) into one file per top-level class, with a thin `lib/nil_kill.rb` entry point that requires them and re-runs the existing `CLI` dispatch (modelled on the repo-root `clear` CLI). No behavior change.
2. Add `loop --return-backflow` that promotes REVIEW `fix_sig_return` actions sourced from `forwarded_return_chain` (and any other safe return sources) through the verified-rollback path, mirroring `--signature-backflow`.
3. Extend return-backflow to direct collection-lookup returns where the receiver origin produces a strong element type, then re-run the loop on `src` excluding `src/tools` and record the slot delta.
4. Add verified runtime-only param narrowing using the same preflight scaffolding.
5. Add recursive protocol collection for params forwarded to helpers.
6. Expand hash-record promotion specs around cross-file clusters and optional keysets.
7. Tighten report rendering for denominators.
