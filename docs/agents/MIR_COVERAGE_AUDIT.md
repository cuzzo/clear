# MIR Coverage Audit

Generated: 2026-06-03

Scope: Ruby source files under `src/mir/`.

This document is the completed checklist for burning MIR down to intentional
line coverage. A file is checked only when all of the following are true:

* missing lines are covered, or explicitly accepted as impractical defensive
  compiler-error paths;
* the file has been reviewed against `src/mir/README.md`;
* any architecture, brittleness, or correctness issue is fixed or deliberately
  recorded as follow-up work.

## Coverage Baseline

Fresh coverage was generated into `/tmp/cheat-mir-coverage-unit` and collated
with `SimpleCov::ResultMerger` using the same filters as
`spec/collate_coverage.rb`.

Commands included in this baseline:

```sh
COVERAGE=1 COVERAGE_DIR=/tmp/cheat-mir-coverage-unit bundle exec prspec spec/
TRANSPILE_GEN_JOBS=4 COVERAGE=1 COVERAGE_ISOLATED=1 COVERAGE_DIR=/tmp/cheat-mir-coverage-unit bundle exec ruby transpile-tests/gen.rb
COVERAGE=1 COVERAGE_DIR=/tmp/cheat-mir-coverage-unit bundle exec ruby tools/corpus_transpile_coverage.rb
COVERAGE=1 COVERAGE_DIR=/tmp/cheat-mir-coverage-unit bundle exec ruby tools/bc_lower_coverage.rb --jobs 4
COVERAGE=1 COVERAGE_DIR=/tmp/cheat-mir-coverage-unit bundle exec ruby tools/bc_lower_coverage.rb --jobs 4 --include-large
```

Run results:

* RSpec: `5205 examples, 0 failures`.
* `transpile-tests/gen.rb`: `470` files processed.
* Corpus transpile: `185` transpiled, `3` skipped by the driver.
* BC lowering sweep: all `685` eligible files attempted across four shards;
  raised files were counted as coverage up to the raise, by design.

Final collated baseline:

* Project line coverage: `96.91%`.
* Project branch coverage: `81.33%`.
* MIR line coverage: `97.07%` (`16659 / 17162`).
* MIR uncovered executable lines: `503`.
* Collated resultset count: `10`.

The existing fuzz corpus under `transpile-tests/fuzz` is included through
`transpile-tests/gen.rb`. This baseline did not generate a new fuzz matrix.

## Burn-Down Status

All files under `src/mir/` are now checked. The file table below records the
current closure state: every MIR file is at `100.00%` line coverage with `0`
missing executable lines, and each row was reviewed against the README
facts/plans architecture while covering the gaps.

Final correctness verification:

```sh
bundle exec rspec spec/
```

Result: `5280 examples, 0 failures`.

## README Reality Check

`src/mir/README.md` now reflects the current pass order, includes a high-level
facts/plans strategy, and lists the support files that were missing from the
old file map: `alloc.rb`, `cleanup_entry.rb`, `fiber_ctx_builder.rb`,
`materialization.rb`, and `test_lowering.rb`.

The architecture description broadly matches reality:

* pass order is enforced by `spec/architecture_invariants_spec.rb`;
* storage and cleanup placement have one-writer invariant tests;
* MIR has invariant tests preventing regex-driven text rewriting;
* ownership-significant node classes and callable contracts are explicitly
  registered.

Remaining architecture tension to watch while burning down coverage:

* Some lowering/emission paths still carry transitional Zig strings or template
  metadata. That is acceptable only when ownership contracts and allocation
  metadata make the escape hatch visible to `MIRChecker`.
* `MIRLowering` and several `lowering/*` modules are still large responsibility
  clusters. Their plan/fact objects are the right direction, but the modules
  should be split only when the split removes real coupling.
* FSM lowering is partly structural and partly string-rendered wrapper logic.
  Coverage should prioritize every fallback, cleanup arm, and ownership-transfer
  bridge around suspend/resume boundaries.

## File Checklist

Grade scale: `A` = focused and low-risk; `B` = solid but complex or transitional;
`C` = working but structurally overloaded or brittle.

| Done | File | Coverage | Missing lines | Grade | Initial findings |
| --- | --- | ---: | ---: | --- | --- |
| [x] | `src/mir/alloc.rb` | `100.00%` | `0` | `A-` | Closed: removed the unused `resolve_resource_close` argument, tightened `T.bind` usage, reused `current_loop_depth`, and fixed indentation. No dead code or missing lines remain. |
| [x] | `src/mir/cleanup_classifier.rb` | `100.00%` | `0` | `B+` | Closed: removed a redundant atomic-pointer classifier arm plus dead/unused classifier plumbing, and covered field pre-cleanup, transfer payload, MATCH AS, capture, owned-return, optional NEXT, array literal, string-concat, and heap-composite edges. Full unit merged coverage reports `624 / 624` lines. |
| [x] | `src/mir/cleanup_entry.rb` | `100.00%` | `0` | `A-` | Closed: reviewed against README facts/plans model. The `Hash` subclass is an intentional compatibility boundary for existing cleanup-plan consumers; no file-local dead code or missing lines remain. |
| [x] | `src/mir/control_flow.rb` | `100.00%` | `0` | `B+` | Closed: covered CFG terminator, ownership-entry equality/hash, cleanup-decision error handling, linear-scope fallthrough, BG capture transfer, raw-symbol move fallback, field-move rescue, and complex GIVE read checks. Fixed `BasicBlock#terminator`'s Sorbet return signature. |
| [x] | `src/mir/fiber_ctx_builder.rb` | `100.00%` | `0` | `B+` | Closed: covered promoted capture specs, FreshHeapCopy result detection, and defensive malformed-type cleanup fallbacks. The mixed Zig/MIR output remains an intentional boundary adapter for current BG/DO/pipeline call sites. |
| [x] | `src/mir/fsm_lowering.rb` | `100.00%` | `0` | `B` | Closed: covered result-transfer mark facade, nested MOVE/struct/list ownership roots, and owned-result guard clearing. Ambient `MIRLowering` state remains an intentional module boundary for the current FSM transform. |
| [x] | `src/mir/fsm_ops.rb` | `100.00%` | `0` | `A-` | Closed: covered try statement calls, string/Zig literal expression paths, bounded-slice lowering, lowerer arg overflow, and explicit unknown op errors. Added the missing `mir` require so the Lowerer is self-contained. |
| [x] | `src/mir/fsm_transform.rb` | `100.00%` | `0` | `B` | Closed: covered unsupported foreach local promotion fallback. The file remains a thin facade around splitter/liveness/resolver/emitter stages; no dead code found. |
| [x] | `src/mir/fsm_transform/emit.rb` | `100.00%` | `0` | `B` | Closed: covered legacy `next_step` bind routing, structure-source filtering, ctx fact name normalization, CondBranch condition variants, unsupported descriptor tails, Done result lowering, and promoted cleanup lifting. Compacted one Sorbet signature coverage artifact. |
| [x] | `src/mir/fsm_transform/liveness.rb` | `100.00%` | `0` | `A-` | Closed: covered string-target assignment definitions. Liveness remains focused and matches the README segment/fact model. |
| [x] | `src/mir/fsm_transform/recursive_splitter.rb` | `100.00%` | `0` | `B` | Closed: removed a dead outer `UnsupportedShape` rescue and covered builder-finalize guards, catch-block rejection, unhandled pivots, unsupported/unknown foreach descriptors, lower-to-Zig rescue, and tail remapping fallbacks. |
| [x] | `src/mir/fsm_transform/segments.rb` | `100.00%` | `0` | `B+` | Closed: covered while/with/catch suspend-detection branches and modernized the segment spec's stdlib fixture to use typed `FunctionSignature` metadata. |
| [x] | `src/mir/fsm_transform/suspend_resolvers.rb` | `100.00%` | `0` | `B+` | Closed: covered unbound IO finish values, non-future NEXT fallback, cleanup-bearing NEXT guards, and defensive ownership-type failures. Fixed malformed non-future NEXT result typing so it no longer silently becomes `void`. |
| [x] | `src/mir/fsm_wrapper_emitter.rb` | `100.00%` | `0` | `B-` | Closed: covered raw generic resume text passthrough, dispatch pre-body skip rendering, and unknown tail validation. Renderer still has legacy string paths, but no file-local dead code found. |
| [x] | `src/mir/hoist.rb` | `100.00%` | `0` | `B-` | Closed: covered AST escape/temp-placement edges, MIR allocation type inference, nested body normalization, IfBind/IfChain transfer insertion, cleanup-effect fallbacks, and wrapper alias guards. Removed unreachable result-type branches shadowed by the generic `result_type` fast path, removed duplicate lowered-allocation bookkeeping, and fixed BlockExpr cleanup to use `OwnershipEffect#target_var`. |
| [x] | `src/mir/lowering/capabilities.rb` | `100.00%` | `0` | `B` | Closed: covered field capability naming/sync/target branches, local RESTRICT binding, VIEW release binding, snapshot/non-snapshot WITH MATCH probes, hash/function return scans, guard-fail/PRE fallbacks, and unknown lock actions. Widened capability var-node typing to the actual Identifier/GetField contract. |
| [x] | `src/mir/lowering/concurrency.rb` | `100.00%` | `0` | `B` | Closed: covered capture ownership mirror matching, all unsafe BG capture refusal guidance variants, and the defensive typed-FSM lowering invariant. No production changes needed in this pass. |
| [x] | `src/mir/lowering/control_flow.rb` | `100.00%` | `0` | `B+` | Closed: covered loop frame-scope stamping for IfChain/WithMatchDispatch, infinite-stream foreach lowering, union match variant fallbacks, malformed return payload typing, no-cleanup returned bindings, and missing needs_rt metadata. Deleted unreachable duplicate union/WHEN fallback branches. |
| [x] | `src/mir/lowering/expressions.rb` | `100.00%` | `0` | `B-` | Closed: covered literal escaping, unary/binary operator edges, union comparisons and payload access, OR_ELSE fallback/exit/pass/break facts, map/set indexing, struct/union field typing, slice-element defensive fallback, COPY/CLONE/MOVE/CAP branches, and allocator metadata paths. Fixed unit-variant construction/comparison to normalize string vs symbol schema keys. The module remains broad and is still a candidate for future split by expression family. |
| [x] | `src/mir/lowering/functions.rb` | `100.00%` | `0` | `B-` | Closed: covered fact-object fallbacks, frame-struct return normalization, finalized `needs_rt` invariants, empty POST debug wrapping, borrowed callable contracts, stdlib signature mismatch diagnostics, generic method type args, arg-dependent owned-return decisions, intrinsic symbol errors, stdlib ownership fallback contracts, extern direct/trampoline allocation paths, and lambda capture fallback. The module still carries several responsibilities and should only be split along real call/extern/lambda boundaries. |
| [x] | `src/mir/lowering/literals.rb` | `100.00%` | `0` | `B+` | Closed: covered recursive list element storage, BC bounded-stream list lowering, scalar list-plan fallback, and capability-wrapped hash literal empty/non-empty allocator paths. Fixed non-empty capability-wrapped hash literals to populate the bare map and then wrap the typed result. |
| [x] | `src/mir/lowering/variables.rb` | `100.00%` | `0` | `B-` | Closed: covered placement facts, capability wrapping, source-owned var init, string cleanup ownership, transfer-only var plans, heap-carry reassignment cleanup, list-copy init, field-owner move marks, direct indexed owned sinks, concat map keys, and auto-lock no-cleanup paths. Fixed heap-carry reassignment type lookup and deleted unreachable legacy indexed-template branches. |
| [x] | `src/mir/materialization.rb` | `100.00%` | `0` | `A` | Closed: reviewed against the README plan-object model. `MaterializationPacket` and `BindingMaterialization` remain focused ordering helpers for `AllocMark`, `Let`, and optional cleanup statements; no dead code or missing lines found. |
| [x] | `src/mir/mir.rb` | `100.00%` | `0` | `B` | Closed: covered surface-node collection, inline allocation metadata validation/accessors, pass-state setter, branch body slots, raw ownership-contract validation, stream boundary facts, FSM result stringification, method/cast try-unwrapping, owned try/orelse effects, and heap-return optional ownership typing. The file remains large but its node/fact APIs match the README plan/fact architecture. |
| [x] | `src/mir/mir_checker.rb` | `100.00%` | `0` | `B+` | Closed: covered checker diagnostics for typed allocation marks, structural ownership consumption, linear traversal, aggregate allocator mismatches, boundary facts, FSM guard/result facts, callable/inline contracts, unhoisted allocation helpers, frame-rewind edges, and registry checks. Fixed linear traversal so manual cases with no `body_slots` are reached instead of skipped by the generic expression fast path. |
| [x] | `src/mir/mir_emitter.rb` | `100.00%` | `0` | `C+` | Closed: covered dispatch-only MIR renderers, sharded-map template substitution and template errors, snapshot retry wrappers, multi-cell snapshot and WITH MATCH emitters, multi IF-bind emission, success-only reassignment cleanup, index allocator branches, defensive strategy errors, cast variants, open slices, sentinels, and block-shaped defers. Fixed `wrap_conflict_handler`'s Sorbet signature so documented integer retry counts are accepted at runtime. |
| [x] | `src/mir/mir_lowering.rb` | `100.00%` | `0` | `C+` | Closed: covered destination-placement plans, owned try/OR placement, discarded allocating statements, module/program require routing, numeric cast variants, import helper lowering for BC, ownership operand/fact helpers, BG/stream/move-root collectors, receiver/root fallbacks, const-block parsing, task spawn dispatch, inline-struct deinit fallbacks, pipeline cleanup/index ownership facts, and borrowed-union sink branches. Deleted a dead duplicate `bare_zig_type` definition shadowed by the later typed helper. The file remains a broad orchestrator, but its plan/fact helpers now match the README strategy. |
| [x] | `src/mir/mir_pass.rb` | `100.00%` | `0` | `B` | Closed: covered runtime-needs detection for BG/WITH forms, transaction/view/poly/error WITH modes, return-expression unwrapping, borrow-check failure propagation, BG inner-binding recursion, consumed-name walking for field/move/return shapes, defensive field-move typing, MATCH-AS cleanup markers, while-bind/if-bind cleanup markers, and escaping MOVE collection. No production changes needed; pass orchestration and AST stamping still match the README. |
| [x] | `src/mir/placement.rb` | `100.00%` | `0` | `A-` | Closed: covered `BindingFact#frame?`. Tiny, focused placement helper; no production issues found. |
| [x] | `src/mir/pre_mir_type_check.rb` | `100.00%` | `0` | `B+` | Closed: covered normal boundary ICE formatting, the `PREMIR_SURVEY=1` inventory path, structural Hash/Array/Struct walking, leaves, and violation location capture. The checker is small and matches the README AST-to-MIR boundary invariant. |
| [x] | `src/mir/test_lowering.rb` | `100.00%` | `0` | `B` | Closed: covered assert-raises with named errors, LET reference recursion through arrays, stub local rename maps, returns/sequence/WITH intercepts, sequence stub lowering for list and scalar values, WITH stub lowering, and unknown stub kind errors. Synthetic test/stub lowering scopes cleanup state carefully and matches the README test-lowering boundary. |
| [x] | `src/mir/thunk_transform.rb` | `100.00%` | `0` | `A` | Closed: reviewed as the facade for recursive splitter and emitter modules. It matches the README boundary and has no file-local dead code. |
| [x] | `src/mir/thunk_transform/emit.rb` | `100.00%` | `0` | `B+` | Closed: reviewed trampoline and mutual-trampoline plan consumption. The string-emitted Zig body is an intentional emitter boundary guarded by non-fallible return checks; no new issue found. |
| [x] | `src/mir/thunk_transform/recursive_splitter.rb` | `100.00%` | `0` | `B+` | Closed: reviewed simple and mutual recurrence shape matching. It is fully covered and aligns with the README plan/fact strategy; no dead code found. |

## Missing Line Detail

| File | Missing executable lines |
| --- | --- |
| `src/mir/alloc.rb` | none |
| `src/mir/cleanup_classifier.rb` | none |
| `src/mir/cleanup_entry.rb` | none |
| `src/mir/control_flow.rb` | none |
| `src/mir/fiber_ctx_builder.rb` | none |
| `src/mir/fsm_lowering.rb` | none |
| `src/mir/fsm_ops.rb` | none |
| `src/mir/fsm_transform.rb` | none |
| `src/mir/fsm_transform/emit.rb` | none |
| `src/mir/fsm_transform/liveness.rb` | none |
| `src/mir/fsm_transform/recursive_splitter.rb` | none |
| `src/mir/fsm_transform/segments.rb` | none |
| `src/mir/fsm_transform/suspend_resolvers.rb` | none |
| `src/mir/fsm_wrapper_emitter.rb` | none |
| `src/mir/hoist.rb` | none |
| `src/mir/lowering/capabilities.rb` | `none` |
| `src/mir/lowering/concurrency.rb` | `none` |
| `src/mir/lowering/control_flow.rb` | `none` |
| `src/mir/lowering/expressions.rb` | `none` |
| `src/mir/lowering/functions.rb` | `none` |
| `src/mir/lowering/literals.rb` | `none` |
| `src/mir/lowering/variables.rb` | `none` |
| `src/mir/materialization.rb` | none |
| `src/mir/mir_lowering.rb` | none |
| `src/mir/mir_pass.rb` | none |
| `src/mir/placement.rb` | none |
| `src/mir/pre_mir_type_check.rb` | none |
| `src/mir/test_lowering.rb` | none |
| `src/mir/thunk_transform.rb` | none |
| `src/mir/thunk_transform/emit.rb` | none |
| `src/mir/thunk_transform/recursive_splitter.rb` | none |

## Completed Burn-Down Path

The audit was closed one file at a time. Small, focused files were used to prove
the checklist mechanics, then the larger ownership-critical files were burned
down and reviewed: `cleanup_classifier.rb`, `hoist.rb`, `mir_lowering.rb`,
`mir_checker.rb`, and `mir_emitter.rb`.
