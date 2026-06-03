# Annotator Coverage Audit

Generated: 2026-06-03

Scope: Ruby source files under `src/annotator/`.

This document is the starting checklist for burning annotator coverage down to
intentional line coverage. A file is checked only when all of the following are
true:

* missing lines are covered, or explicitly accepted as impractical defensive
  compiler-error paths;
* the file has been reviewed against `src/annotator/README.md`;
* any architecture, brittleness, or correctness issue is fixed or deliberately
  recorded as follow-up work.

## Coverage Baseline

Fresh coverage was generated into `/tmp/cheat-annotator-coverage-unit` and
collated with `SimpleCov::ResultMerger` using the same filters as
`spec/collate_coverage.rb`.

Commands included in this baseline:

```sh
COVERAGE=1 COVERAGE_DIR=/tmp/cheat-annotator-coverage-unit bundle exec prspec spec/
TRANSPILE_GEN_JOBS=4 COVERAGE=1 COVERAGE_ISOLATED=1 COVERAGE_DIR=/tmp/cheat-annotator-coverage-unit bundle exec ruby transpile-tests/gen.rb
COVERAGE=1 COVERAGE_DIR=/tmp/cheat-annotator-coverage-unit bundle exec ruby tools/corpus_transpile_coverage.rb
COVERAGE=1 COVERAGE_DIR=/tmp/cheat-annotator-coverage-unit bundle exec ruby tools/bc_lower_coverage.rb --jobs 4
COVERAGE=1 COVERAGE_DIR=/tmp/cheat-annotator-coverage-unit bundle exec ruby tools/bc_lower_coverage.rb --jobs 4 --include-large
```

Run results:

* RSpec: `5280 examples, 0 failures`.
* `transpile-tests/gen.rb`: `470` files processed.
* Corpus transpile: `185` transpiled, `3` skipped by the driver.
* BC lowering sweep: `681` eligible files attempted across four shards, with
  `4` files skipped for size in the non-large sweep.
* BC lowering include-large sweep: all `685` eligible files attempted across
  four shards; raised files were counted as coverage up to the raise.

Initial collated baseline:

* Project line coverage: `98.05%`.
* Project branch coverage: `83.48%`.
* Annotator line coverage: `97.93%` (`9633 / 9837`).
* Annotator uncovered executable lines: `204`.
* Collated resultset count: `10`.

Final post-burndown coverage:

* Project line coverage: `98.35%`.
* Project branch coverage: `84.11%`.
* Annotator line coverage: `100.00%` (`9839 / 9839`).
* Annotator uncovered executable lines: `0`.
* Collated resultset count: `36`.

## README Reality Check

`src/annotator/README.md` broadly matches the implementation: it describes the
phase/domain/helper include split, the multi-pass declaration/signature/body
order, the MIR boundary, and current messy areas.

The README now also includes a facts/work-products strategy matching the MIR
plan/fact strategy at the right abstraction level. The additions spell out:

* persistent facts such as AST `full_type`, `Scope`/`SymbolEntry`,
  `FunctionSignature`, capability/lock facts, Auto evidence, BG capture facts,
  effect/fallibility/stack metadata, lifetime facts, and `MIRPassState`;
* short-lived work products such as `BranchAnalysisResult`,
  `DeferredWithValidation`, lock graph records, Auto unifier results, pipeline
  descriptors, intrinsic registry entries, and reentrance/thunk candidates;
* rules for when to stamp a fact versus keep a local work product.

Architecture tension to keep watching after burn-down:

* `SemanticAnnotator` is still the central mutable owner for many unrelated
  phase concerns. The README's desired typed phase contexts are not fully real
  yet.
* Several domains still mutate `SymbolEntry`, AST metadata, and function
  signatures directly. That is workable only while single-writer conventions are
  maintained.
* Capability, execution-boundary, lifetime, effects, and pipeline logic are the
  main complexity clusters. Coverage work should prefer simplification or typed
  records over adding tests for obsolete hash-shaped branches.

## File Checklist

Grade scale: `A` = focused and low-risk; `B` = solid but complex or transitional;
`C` = working but structurally overloaded or brittle.

| Done | File | Coverage | Missing lines | Grade | Initial findings |
| --- | --- | ---: | ---: | --- | --- |
| [x] | `src/annotator/annotator.rb` | `100.00%` | `0` | `C+` | Closed by focused coverage for nil type stamps, direct extern visitor dispatch, and mutual MAX_DEPTH stack validation traversal. The facade still owns broad mutable pass state; future work should keep pushing logic into phase/domain helpers. |
| [x] | `src/annotator/domains/control_flow.rb` | `100.00%` | `0` | `B-` | Closed by focused coverage for tokenless match diagnostics, MethodCall variant names, struct extra-patterns, TRUE identifier loops, scalar loop bodies, and capture-move loop exemptions. Fixed a brittle union destructure path so unknown fields stop after the diagnostic instead of deriving `Type.new(nil)`. |
| [x] | `src/annotator/domains/errors.rb` | `100.00%` | `0` | `B-` | Closed by focused coverage for OR EXIT pre-seeding, sync-policy handler bodies, DIE, type-only error registration, inline BG return diagnostics, WITH-scoped indexed returns, and OR EXIT/BREAK/optional fallback branches. Dense but aligned with the README fact model. |
| [x] | `src/annotator/domains/execution_boundaries.rb` | `100.00%` | `0` | `B-` | Closed by focused coverage for fallible-source walking, snapshot policy fallback failures, multi-object atomic fallback names, unknown capability fallbacks, BG error-union result stripping, arena/parallel rejection, and pinned-parent capture diagnostics. Deleted an unused type alias and fixed the pinned-parent BG check to use the saved parent state. |
| [x] | `src/annotator/domains/expressions.rb` | `100.00%` | `0` | `B` | Closed by focused coverage for unary/literal/default/placeholder fallbacks, scalar bind-var typing, invalid `@local:atomic:indirect`, and expression-mode IF/MATCH diagnostics. Fixed quiet-diagnostic recovery for unknown literals and empty/missing IF/MATCH expression branches by stamping `Any` instead of continuing into nil. |
| [x] | `src/annotator/domains/lifetimes.rb` | `100.00%` | `0` | `C+` | Closed by focused coverage for scoped storage/move diagnostics, root traversal, resource and future drops, tied-assignment fix dispatch, parameter source-name fallback, root variable traversal, and specific move-action preservation. Fixed `lookup_source_name` so its documented function-parameter fallback is reachable. |
| [x] | `src/annotator/domains/member_access.rb` | `100.00%` | `0` | `B` | Closed by focused coverage for optional index unwraps, moved wildcard field access, non-array slice fallback, and empty heap-list typing. No production changes needed. |
| [x] | `src/annotator/domains/variables.rb` | `100.00%` | `0` | `B-` | Closed by focused coverage for observable terminal invariant errors, bare affine `@versioned` notes, undefined identifier returns, assignment target dispatch, invalid targets, undefined assignments, and immutable assignment diagnostics with/without fixes. Removed an unreachable duplicate observable-terminal mismatch block. |
| [x] | `src/annotator/helpers/auto_inference.rb` | `100.00%` | `0` | `B+` | Reviewed and already covered. Architecture is coherent around typed slot IDs, collector/unifier result objects, and shape-evidence work products; no burn-down change needed. |
| [x] | `src/annotator/helpers/capabilities.rb` | `100.00%` | `0` | `C+` | Closed by focused coverage for static conflict callbacks, write-locked read deferral/direct diagnostics, VIEW field diagnostics, guarded snapshot rejection, inferred ATOMIC/unknown capabilities, sync-field binding loss, BORROWED write-lock rejection, plain string-map capture cleanup, and parallel capture validation. Still a mixed-responsibility helper; future cleanup should split capability validation, scope declaration, predicate analysis, and capture analysis. |
| [x] | `src/annotator/helpers/effects.rb` | `100.00%` | `0` | `B-` | Closed by focused coverage for fallibility rescue/fallback branches, TIGHT-loop method-call diagnostics, and mutual-recursion diagnostics without an arrow token. Simplified stack-tier promotion so the final escalation arm is reachable instead of preserving a dead defensive branch. |
| [x] | `src/annotator/helpers/fixable_helpers.rb` | `100.00%` | `0` | `B` | Closed by focused coverage for moved-path fallback wording, capability fix insertion/fixable emission, and Auto return ambiguity's union-name fallback. Diagnostic helper remains broad but is intentionally presentation-focused. |
| [x] | `src/annotator/helpers/function_analysis.rb` | `100.00%` | `0` | `C+` | Closed by focused coverage for undefined/not-callable/symbol call-resolution fallbacks, receiver allocator lookup, TAKES borrowed-field diagnostics, frame allocator inheritance for explicit COPY, missing capture diagnostics, and borrowed-return lifetime diagnostics. Fixed `verify_return` so a non-associated lifetime path stops after the diagnostic instead of dereferencing nil. |
| [x] | `src/annotator/helpers/function_context.rb` | `100.00%` | `0` | `A-` | Reviewed and already covered. Focused per-routine fact object for return facts, runtime-use counters, loop/conditional depth, type params, lifetimes, and stack bytes; matches the README with no changes needed. |
| [x] | `src/annotator/helpers/function_return.rb` | `100.00%` | `0` | `A-` | Closed by focused coverage for the impossible return-kind fallback. Replaced the old silent `Any` fallback with an explicit compiler-bug raise so invalid `FunctionReturn` state cannot mask bad intrinsic metadata. |
| [x] | `src/annotator/helpers/function_signature.rb` | `100.00%` | `0` | `A` | Reviewed and covered. Focused typed signature object matching the README's function fact model. Fixed `dup` to preserve split fallibility metadata (`alloc_fault` and `error_fallible`) alongside `can_fail`. |
| [x] | `src/annotator/helpers/generic_analysis.rb` | `100.00%` | `0` | `B` | Closed by focused coverage for container-source tracing through collection indexing and optional unwrap. Architecture remains broad but cohesive around generic validation, substitution, and borrow-source metadata. |
| [x] | `src/annotator/helpers/intrinsic_emit.rb` | `100.00%` | `0` | `A-` | Reviewed and already covered. Data-only typed intrinsic emission descriptor for stdlib registry conversion; no changes needed. |
| [x] | `src/annotator/helpers/intrinsic_registry.rb` | `100.00%` | `0` | `B` | Closed by focused coverage for proc-valued emit labels, unmapped registry-key rejection, nested registry pointer fallback, Proc return descriptor rejection, and direct registry conversion. Table-driven converter remains appropriate. |
| [x] | `src/annotator/helpers/lock_helper.rb` | `100.00%` | `0` | `B` | Closed by focused coverage for self-loop SCC reachability in lock-handler validation. Lock graph records still match the README and no production change was needed. |
| [x] | `src/annotator/helpers/method_analysis.rb` | `100.00%` | `0` | `B` | Closed by focused coverage for table-driven collection-method diagnostic recovery after unknown methods and arity errors. The helper remains small and consistent with the registry architecture. |
| [x] | `src/annotator/helpers/pipe_analysis.rb` | `100.00%` | `0` | `C+` | Closed by focused coverage for invalid pipe destinations, COLLECT validation, InfStream TAKE_WHILE/DISTINCT paths, bounded/invalid batch windows, JOIN shared-key validation, RECOVER error-union stripping, invalid EACH/TAP recovery, multi-map shard notes, numeric shard-key diagnostics, and concurrent WHERE/result guards. Removed a dead `analyze_shard_each_op` nil-shard fallback that was unreachable under the method signature and call sites. This remains the main complexity hotspot and should be split by pipeline family in a future architecture pass. |
| [x] | `src/annotator/helpers/reentrance.rb` | `100.00%` | `0` | `B` | Closed by focused coverage for no-edit MAX_DEPTH mutual-cycle findings, direct self-recursive THUNK validation no-ops, and missing return-token fallbacks while building mutual-thunk migration fixes. Reentrance/thunk facts still align with the README work-product model. |
| [x] | `src/annotator/helpers/test_annotation.rb` | `100.00%` | `0` | `B-` | Closed by focused coverage for `ASSERT_RAISES` visiting/stamping and strict-test traversal through both runtime IO builtins and user functions with IO effects. The helper is intentionally thin and still matches the test-grammar architecture. |
| [x] | `src/annotator/helpers/union.rb` | `100.00%` | `0` | `A-` | Removed an unreachable fallback after enum/union schema dispatch; typed schema predicates already guarantee the prior branches return. Focused union helper remains coherent. |
| [x] | `src/annotator/helpers/with_match_check.rb` | `100.00%` | `0` | `B` | Closed by focused coverage for missing-REQUIRES errors without the shim warning, call-site arguments with no capability family, and polymorphic unhandled-error warnings. WITH MATCH validation remains coherent but transitional because it can still restamp inferred requires. |
| [x] | `src/annotator/phases/annotation_boundary.rb` | `100.00%` | `0` | `A-` | Reviewed and already covered. Focused MIR boundary invariant; no changes needed. |
| [x] | `src/annotator/phases/auto_finalization.rb` | `100.00%` | `0` | `A` | Reviewed and already covered. Thin phase wrapper over Auto inference; no changes needed. |
| [x] | `src/annotator/phases/body_analysis.rb` | `100.00%` | `0` | `B+` | Closed by direct coverage for body-summary accessors. Small coherent fact-store wrapper for call graph, fallibility seeds, and fn-pointer summaries. |
| [x] | `src/annotator/phases/builtin_environment.rb` | `100.00%` | `0` | `A` | Reviewed and already covered. Thin builtin setup phase; no changes needed. |
| [x] | `src/annotator/phases/declaration_index.rb` | `100.00%` | `0` | `A-` | Reviewed and already covered. Focused typed declaration-index work product; no changes needed. |
| [x] | `src/annotator/phases/deferred_validation.rb` | `100.00%` | `0` | `B+` | Closed by direct coverage for deferred WITH replay diagnostics and queue clearing. Architecture is intentionally narrow and matches the caller-sync propagation boundary. |
| [x] | `src/annotator/phases/expression_domains.rb` | `100.00%` | `0` | `B-` | Closed by direct coverage for `native_call`, tokenless static-method errors, intrinsic no-overload/reject recovery, and extern method allocation accounting. Fixed unknown static types to return after the diagnostic and removed an unreachable static-call receiver-mutation branch. |
| [x] | `src/annotator/phases/program_finalization.rb` | `100.00%` | `0` | `A-` | Reviewed and already covered. Focused post-pass orchestration and final metadata stamping; no changes needed. |
| [x] | `src/annotator/phases/signature_registration.rb` | `100.00%` | `0` | `A-` | Reviewed and already covered. Switched extern owner-method registration to `resolve_type_definition` so the phase no longer depends on the scope type-store's internal hash shape. |
| [x] | `src/annotator/phases/signature_registry.rb` | `100.00%` | `0` | `A-` | Reviewed and already covered. Focused typed signature factory; no changes needed. |
| [x] | `src/annotator/phases/type_registration.rb` | `100.00%` | `0` | `A-` | Reviewed and already covered. Focused typed schema registration phase; no changes needed. |
| [x] | `src/annotator/phases/whole_program_semantics.rb` | `100.00%` | `0` | `B+` | Closed by direct coverage for the schema-lookup fallback passed into BG capture classification. Phase ordering matches the README. |

## Missing Line Detail

| File | Missing executable lines |
| --- | --- |
| `src/annotator/annotator.rb` | none |
| `src/annotator/domains/control_flow.rb` | none |
| `src/annotator/domains/errors.rb` | none |
| `src/annotator/domains/execution_boundaries.rb` | none |
| `src/annotator/domains/expressions.rb` | none |
| `src/annotator/domains/lifetimes.rb` | none |
| `src/annotator/domains/member_access.rb` | none |
| `src/annotator/domains/variables.rb` | none |
| `src/annotator/helpers/auto_inference.rb` | none |
| `src/annotator/helpers/capabilities.rb` | none |
| `src/annotator/helpers/effects.rb` | none |
| `src/annotator/helpers/fixable_helpers.rb` | none |
| `src/annotator/helpers/function_analysis.rb` | none |
| `src/annotator/helpers/function_context.rb` | none |
| `src/annotator/helpers/function_return.rb` | none |
| `src/annotator/helpers/function_signature.rb` | none |
| `src/annotator/helpers/generic_analysis.rb` | none |
| `src/annotator/helpers/intrinsic_emit.rb` | none |
| `src/annotator/helpers/intrinsic_registry.rb` | none |
| `src/annotator/helpers/lock_helper.rb` | none |
| `src/annotator/helpers/method_analysis.rb` | none |
| `src/annotator/helpers/pipe_analysis.rb` | none |
| `src/annotator/helpers/reentrance.rb` | none |
| `src/annotator/helpers/test_annotation.rb` | none |
| `src/annotator/helpers/union.rb` | none |
| `src/annotator/helpers/with_match_check.rb` | none |
| `src/annotator/phases/annotation_boundary.rb` | none |
| `src/annotator/phases/auto_finalization.rb` | none |
| `src/annotator/phases/body_analysis.rb` | none |
| `src/annotator/phases/builtin_environment.rb` | none |
| `src/annotator/phases/declaration_index.rb` | none |
| `src/annotator/phases/deferred_validation.rb` | none |
| `src/annotator/phases/expression_domains.rb` | none |
| `src/annotator/phases/program_finalization.rb` | none |
| `src/annotator/phases/signature_registration.rb` | none |
| `src/annotator/phases/signature_registry.rb` | none |
| `src/annotator/phases/type_registration.rb` | none |
| `src/annotator/phases/whole_program_semantics.rb` | none |

## Burn-Down Result

Burn-down followed source order for the full architecture walk so state
ownership was reviewed where it is introduced:

1. `annotator.rb`
2. `domains/*`
3. `helpers/*`
4. `phases/*`

All files in `src/annotator/` are checked off with no uncovered executable
lines in the final collated result.
