# Architectural Invariants Audit

Date: 2026-06-10
Branch: `architectural-review`

Sources audited:

- `CLAUDE.md`
- `src/README.md`
- `src/annotator/README.md`
- `src/mir/README.md`
- Existing mechanical guardrails in `spec/architecture_invariants_spec.rb`
- Project-local invariant patterns surfaced during the recent architectural work

This is a due-diligence audit, not a formal proof. The scan combined source review with targeted `rg` searches for the major invariant failure modes: pre-emission Zig strings, RawZig/InlineZig/ZigTemplate, page allocator use, direct `CheatLib` calls, MIR regex/text rewriting, emitter allocator decisions, MIRChecker heuristic decisions, raw hash-shaped phase records, direct annotator errors, and stale ownership contract APIs.

Mechanical guardrail status:

- `bundle exec rspec spec/architecture_invariants_spec.rb`
- Result: `75 examples, 0 failures`

## Severity Key

- **Red**: hard invariant violation with credible correctness risk, or a memory-safety boundary that can make the compiler accept/emit incorrect behavior.
- **Yellow**: invariant pressure or compatibility debt. Not proven broken today, but it weakens the architecture or leaves a path for latent bugs.
- **Green**: no invalidation found in this audit, and/or a mechanical guardrail already covers the invariant.

## Open Findings

| Severity | Invariant | Finding | Location(s) | Correctness / memory-safety impact |
| --- | --- | --- | --- | --- |
| Red | MiniVM must not parse Zig strings | Active MiniVM still parses `node.code.to_s` / `mir_node.code.to_s` with regex and string scans for catch wrappers and InlineZig-style helpers. | `examples/minivm/bc_emitter.rb:4582`, `examples/minivm/bc_emitter.rb:4878`, `examples/minivm/bc_emitter.rb:4942` | High backend correctness risk. This directly violates `CLAUDE.md`. It is not a Zig runtime memory-safety bug, but it means the MiniVM backend can silently diverge from structural semantics. |
| Yellow | MiniVM family should not depend on InlineZig parsing | Register MiniVM emitter also parses `expr.code.to_s` for `CheatLib.len` and integer intrinsics. `CLAUDE.md` names `bc_emitter.rb` as the active MiniVM, but this is the same class of debt. | `examples/minivm/register_bc_emitter.rb:7556` | Medium backend correctness risk if this path is active or becomes active again. |
| Done | MIREmitter should not choose allocators | ~~`MIR::FreezeExpr` encodes `ownership_effect` as heap-owned, but the emitted allocator is hard-coded as `@rt_name.heapAlloc()` in the emitter instead of being an explicit MIR allocator operand.~~ Completed 2026-06-10: `FreezeExpr` now carries a typed `MIR::AllocatorRef`; lowering sets it and emission renders the explicit operand. Decomplex delta vs baseline: no net change. | `src/mir/mir.rb`, `src/mir/mir_emitter.rb`, `src/mir/lowering/expressions.rb` | Resolved. |
| Done | MIREmitter should be a pure template over explicit MIR shape | ~~`emit_deep_copy` and `emit_container_init` inspect Zig type strings or generated Zig type expressions to choose emission shape.~~ Completed 2026-06-10: `DeepCopy` carries `copy_shape`, and ArrayList empty initialization uses explicit `:array_list_empty`. Decomplex delta vs baseline: no net change, with the `emit_deep_copy` site-level decision pressure resolved. | `src/mir/mir.rb`, `src/mir/mir_emitter.rb`, `src/mir/lowering`, `src/mir/lower/pipeline` | Resolved for the audited emitter type-prefix decisions. |
| Done | MIRChecker should verify facts, not recover meaning from rendered/name-shaped text | ~~FSM destroy validation uses guard-name prefixes and rendered expression text to verify lock target shape.~~ Completed 2026-06-10: `FsmDestroyLockRelease` now carries `ctx_id` and `guard_index`, derives `guard_field`, and MIRChecker validates typed facts instead of parsing guard names/rendered lock refs. Decomplex delta vs baseline: no net change. | `src/mir/mir.rb`, `src/mir/mir_checker.rb`, `src/mir/fsm_transform/emit.rb` | Resolved for FSM destroy lock validation. |
| Done | FSM emission should remain structural | ~~FSM segment runtime-ref suppression is derived from rendered body/setup text.~~ Completed 2026-06-10: suppression is now derived from structural MIR `Ident` references via `mir_nodes_reference_ident?`. Decomplex delta vs baseline: no net change. | `src/mir/fsm_transform/emit.rb` | Resolved. |
| Done | All `CheatLib` calls should pass through registries except explicit marker calls | ~~Pipeline lowerers construct non-marker `CheatLib` call names directly.~~ Completed 2026-06-10: pipeline lowerers now construct typed `MIR::RuntimeCall` nodes with closed `MIR::RuntimeCallSpec` contracts; emission renders the equivalent `MIR::Call` at the final edge. Decomplex delta vs baseline: no net change. | `src/mir/mir.rb`, `src/mir/mir_emitter.rb`, `src/mir/lower/pipeline/*` | Resolved for pipeline runtime helper calls. |
| Done | Ownership consumption should use typed operands, not legacy name arrays | ~~`OwnershipContract#consumes` remains as a compatibility read path and can be constructed from names into `OwnershipOperandFact.owned_binding(..., Type.new(:Any), "legacy ownership contract")`.~~ Completed 2026-06-10: `OwnershipContract` no longer accepts or exposes name-list consumption; callers build/read typed `OwnershipOperandFact` values and derive owned names only as a read-only projection. Decomplex delta vs baseline: no net change; `consumes` cluster gone. | `src/mir/mir.rb`, `src/mir/mir_checker.rb`, `src/mir/mir_lowering.rb` | Resolved. |
| Done | Cross-phase data should be typed records, not hashes acting as structs | ~~Thunk/FSM helpers still read param/liveness data as hash-shaped records.~~ Completed 2026-06-10: thunk params now pass through `ThunkParamFact`; FSM liveness returns `CrossSegmentVarFact`; conservative FSM local promotion uses `PromotedLocalFact`. Decomplex delta vs baseline: no net change; `type` cluster shrank. | `src/mir/thunk_transform/emit.rb`, `src/mir/fsm_transform.rb`, `src/mir/fsm_transform/liveness.rb`, `src/mir/fsm_transform/emit.rb` | Resolved for thunk params, FSM liveness declaration facts, and FSM promoted-local facts. |
| Done | Scope branch flow and stable symbol identity should be separated cleanly | ~~`src/annotator/README.md` still identifies branch deep-copy/stale `SymbolEntry` references as a smell, with `Scope.live_param_syms` as mitigation.~~ Completed 2026-06-10: README and `SymbolEntry` comments now describe the current composed-scope/copy-on-write contract, and `scope_composition_spec` covers canonical parameter symbols after branch-local materialization. No fresh violation was found. | `src/annotator/README.md`, `src/ast/scope.rb`, `src/ast/symbol_entry.rb`, `spec/scope_composition_spec.rb` | Resolved as an audited/documented invariant with regression coverage; no code-path refactor was warranted. |

## Invariant-by-Invariant Audit

### INV-001: Active MiniVM Must Never Parse Zig Code Strings

Source: `CLAUDE.md`

Status: **Red**

Due diligence:

- Searched active MiniVM and register MiniVM emitters for `InlineZig`, `RawZig`, `code.to_s`, and known parser helpers.

Findings:

- `examples/minivm/bc_emitter.rb:4582` parses a rendered catch-wrapper function string to recover the inner call and args.
- `examples/minivm/bc_emitter.rb:4878` scans `mir_node.code.to_s` for lock guards, aliases, and context accesses.
- `examples/minivm/bc_emitter.rb:4942` parses `node.code.to_s` to recover an identifier for pipe item access.
- `examples/minivm/register_bc_emitter.rb:7556` parses InlineZig-shaped code for `CheatLib.len` and integer intrinsics.

Impact:

- High backend correctness risk. The MiniVM can disagree with AST/MIR semantics when rendered Zig changes.
- Not directly a Zig runtime memory-safety violation, but it violates a hard backend invariant.

Recommended fix:

- Replace these paths with structural AST/MIR bytecode ops or explicit MiniVM lowering facts.
- If no structural representation exists, raise `Unimplemented` instead of parsing rendered Zig.

### INV-002: Compiler Passes Own Their Facts And Stamp The AST Once

Source: `CLAUDE.md`, `src/README.md`, `src/annotator/README.md`, `src/mir/README.md`

Status: **Green / Yellow**

Due diligence:

- Reviewed pass-order guardrails in `spec/architecture_invariants_spec.rb`.
- Checked the current README contracts for annotator/MIR boundaries.
- Scanned for broad post-pass re-derivation patterns in MIRChecker and MIREmitter.

Findings:

- Pass order and several single-writer boundaries are mechanically guarded.
- Yellow residuals are covered under INV-007, INV-008, INV-010, INV-012, and INV-029.

Impact:

- The main fact ownership model is intact, but a few edge records remain string/hash/name based.

Recommended fix:

- Continue replacing compatibility surfaces with frozen typed fact records at pass boundaries.

### INV-003: Downstream Passes Must Read Semantic Stamps/Facts, Not Re-Derive Source Semantics

Source: `CLAUDE.md`, `src/annotator/README.md`, `src/mir/README.md`

Status: **Done**

Due diligence:

- Searched MIRChecker/MIREmitter for `is_a?`, `respond_to?`, name/string tests, and type-spelling checks at correctness boundaries.

Findings:

- The major historical broad re-derivations are guarded by architecture specs.
- Remaining yellow cases:
  - ~~FSM destroy target validation uses name/rendered-text checks (`src/mir/mir_checker.rb:1779`, `src/mir/mir_checker.rb:1796`).~~ Completed 2026-06-10.
- ~~Emitter string-shape decisions remain in deep-copy/container initialization (`src/mir/mir_emitter.rb:2111`, `src/mir/mir_emitter.rb:2130`).~~ Completed 2026-06-10.

Impact:

- Medium correctness risk where semantic meaning is still recovered from representation shape.

Recommended fix:

- Complete for FSM destroy actions.
- Complete for the audited deep-copy/container-init sites.

### INV-004: MIRLowering Owns Memory Decisions

Source: `CLAUDE.md`, `src/mir/README.md`

Status: **Done**

Due diligence:

- Scanned emitter and transpiler for allocator choices, storage decisions, and type/schema lookups.
- Verified no `std.heap.page_allocator` use in `src/`.

Findings:

- ~~`MIR::FreezeExpr` reports heap ownership but the emitter spells `@rt_name.heapAlloc()` directly (`src/mir/mir_emitter.rb:2207`).~~ Completed 2026-06-10: `FreezeExpr` carries `MIR::AllocatorRef`; `lower_freeze` supplies it; `emit_freeze` renders `node.alloc_ref`.
- Most other allocator calls are template rendering from explicit MIR alloc fields.

Impact:

- Resolved for freeze allocator provenance.

Recommended fix:

- Complete.

### INV-005: Cleanup Node Type Encodes Cleanup Policy

Source: `CLAUDE.md`, `src/mir/README.md`

Status: **Green**

Due diligence:

- Relied on `spec/architecture_invariants_spec.rb` cleanup-entry and ownership-significant node checks.
- Reviewed recent cleanup/facts architecture in `src/mir/README.md`.

Findings:

- No direct invalidation found.
- `CleanupEntry` remains a compatibility `Hash` subclass by design, but guarded raw lifecycle writes reduce risk.

Impact:

- Low current risk.

Recommended fix:

- Eventually remove `CleanupEntry < Hash` compatibility after all consumers are typed.

### INV-006: MIRChecker Verifies Explicit Facts; It Must Not Decide Ownership, Allocator, Or Cleanup Policy

Source: `CLAUDE.md`, `src/mir/README.md`

Status: **Done**

Due diligence:

- Scanned `src/mir/mir_checker.rb` for flag/name/string heuristics and ownership-source fallback patterns.
- Ran the architecture invariant spec.

Findings:

- Major historical heuristics are mechanically blocked.
- Remaining yellow cases:
  - ~~FSM lock target proof depends on rendered/name-shaped checks (`src/mir/mir_checker.rb:1779`, `src/mir/mir_checker.rb:1796`, `src/mir/mir_checker.rb:1825`).~~ Completed 2026-06-10 for lock destroy validation.
  - ~~`OwnershipContract#consumes` name-list compatibility remains (`src/mir/mir_checker.rb:1012`, `src/mir/mir_checker.rb:2549`).~~ Completed 2026-06-10; ownership contracts now expose typed operand facts and a derived read-only `owned_operand_names` projection.

Impact:

- Medium memory-safety-adjacent risk. These do not appear to decide cleanup today, but they weaken proof quality.

Recommended fix:

- Complete for FSM destroy lock actions.
- Completed 2026-06-10: deleted `OwnershipContract#consumes`; all callers use typed operand facts or the derived `owned_operand_names` projection.

### INV-007: MIREmitter Is A Pure Template Layer

Source: `CLAUDE.md`, `src/mir/README.md`

Status: **Done**

Due diligence:

- Scanned `src/mir/mir_emitter.rb` for type inspection, allocator choice, storage/schema lookup, and string-shape checks.

Findings:

- No broad semantic analysis or schema lookup found in the emitter.
- Completed 2026-06-10:
  - ~~`emit_deep_copy` checks `node.zig_type.start_with?` and emits Zig comptime type tests (`src/mir/mir_emitter.rb:2111`).~~
  - ~~`emit_container_init` chooses `.empty` vs `{}` by Zig type prefix (`src/mir/mir_emitter.rb:2130`).~~
  - ~~`emit_freeze` hard-codes `heapAlloc()` (`src/mir/mir_emitter.rb:2207`).~~

Impact:

- Resolved for the audited emitter strategy decisions.

Recommended fix:

- Complete for the audited sites.

### INV-008: Each Binding Has One Allocator Provenance

Source: `CLAUDE.md`, `src/README.md`, `src/mir/README.md`

Status: **Green / Yellow**

Due diligence:

- Searched for `std.heap.page_allocator` and direct allocator overrides.
- Reviewed allocation rendering in MIREmitter and FreezeExpr.

Findings:

- No `std.heap.page_allocator` use in `src/`.
- Most MIR allocation nodes carry alloc fields.
- ~~Yellow residual: `FreezeExpr` allocator is implicit in node kind/emitter instead of explicit data.~~ Completed 2026-06-10.

Impact:

- Low-to-medium current risk; the known residual is narrow.

Recommended fix:

- Complete for `FreezeExpr`.

### INV-009: Every Allocation Must Be Cleaned On Every Path

Source: `CLAUDE.md`, `src/README.md`, `src/mir/README.md`

Status: **Green**

Due diligence:

- Relied on MIR cleanup classifier/checker guardrails and architecture invariant spec.
- Looked for direct untracked allocation emit patterns.

Findings:

- No direct invalidation found.

Impact:

- Low current risk.

Recommended fix:

- Keep adding targeted fuzz/coverage whenever new allocation MIR nodes are introduced.

### INV-010: No Cleanup Without A Corresponding Allocation

Source: `CLAUDE.md`, `src/README.md`, `src/mir/README.md`

Status: **Green**

Due diligence:

- Relied on MIRChecker cleanup/finalizer checks and architecture invariant spec.

Findings:

- No direct invalidation found.

Impact:

- Low current risk.

Recommended fix:

- Keep cleanup facts typed and fail-closed.

### INV-011: Moved Values Must Never Be Cleaned Again

Source: `CLAUDE.md`, `src/README.md`, `src/mir/README.md`

Status: **Green / Yellow**

Due diligence:

- Reviewed ownership contract compatibility and MIRChecker move/consume surfaces.

Findings:

- Typed ownership operand facts are the intended path.
- Yellow residual: legacy name-list `consumes` compatibility still exists, which is weaker than explicit typed operands.

Impact:

- Medium architecture risk if new code accidentally revives name-only consumption.

Recommended fix:

- Delete legacy `consumes` construction/read APIs once remaining callers use operands.

### INV-012: Frame Allocations Must Not Escape

Source: `CLAUDE.md`, `src/mir/README.md`

Status: **Green**

Due diligence:

- Relied on escape-analysis and pass-stage architecture specs.
- Searched for direct page allocator and frame allocator overrides.

Findings:

- No direct invalidation found.

Impact:

- Low current risk.

Recommended fix:

- Keep escape placement facts as the only source of storage/provenance.

### INV-013: Loop Frame Allocation Must Restore Frame Marks

Source: `CLAUDE.md`, `src/mir/README.md`

Status: **Green**

Due diligence:

- Reviewed frame save/restore rendering surfaces and existing architecture specs.

Findings:

- No direct invalidation found.

Impact:

- Low current risk.

Recommended fix:

- Keep loop frame allocation tests mandatory when loop lowering changes.

### INV-014: Transpiler Must Make Zero Memory Decisions

Source: `CLAUDE.md`

Status: **Green**

Due diligence:

- Searched transpiler/emitter memory-sensitive patterns.

Findings:

- No direct transpiler memory-decision invalidation found.

Impact:

- Low current risk.

Recommended fix:

- Keep memory decisions in MIR lowering/facts.

### INV-015: Stdlib Registry And Type Registry Are The Single Source For Stdlib/Intrinsic Contracts

Source: `CLAUDE.md`, `src/annotator/README.md`, `src/mir/README.md`

Status: **Yellow**

Due diligence:

- Searched for direct non-marker `CheatLib` construction outside registry paths.

Findings:

- ~~Direct non-marker calls in pipeline lowerers.~~ Completed 2026-06-10:
  - `CheatLib.BatchWindow(...).init` is represented by `MIR::RuntimeCalls.batch_window_init_spec`.
  - `CheatLib.eql` is represented by `MIR::RuntimeCalls.eql_spec`.
  - `CheatLib.threadCount` is represented by `MIR::RuntimeCalls.thread_count_spec`.
  - `CheatLib.obs.AtomicReduce(...).init` is represented by `MIR::RuntimeCalls.atomic_reduce_init_spec`.
- Marker-style calls such as `CheatLib.cleanup` were not counted as violations.

Impact:

- Resolved for pipeline helpers. Ownership/fallibility/allocation metadata is centralized in typed runtime-call specs, and the lowerers no longer spell those helper calls directly.

Recommended fix:

- Continue routing any new non-marker runtime helper through `MIR::RuntimeCalls` or a stdlib/intrinsic registry record.

### INV-016: Error Paths Must Preserve Allocator Identity

Source: `CLAUDE.md`, `src/mir/README.md`

Status: **Green**

Due diligence:

- Relied on cleanup/err-cleanup architecture specs and allocation provenance scans.

Findings:

- No direct invalidation found.

Impact:

- Low current risk.

Recommended fix:

- Keep `ErrCleanup` and error-path ownership tests on all new fallible allocation lowering.

### INV-017: Union Cleanup Must Use The Declared Allocator

Source: `CLAUDE.md`, `src/mir/README.md`

Status: **Green**

Due diligence:

- Relied on cleanup classifier/checker invariants.

Findings:

- No direct invalidation found.

Impact:

- Low current risk.

Recommended fix:

- Keep union cleanup allocator tests mandatory when union storage changes.

### INV-018: All `CheatLib` Access Must Be Contracted, Except Explicit Marker Calls

Source: `CLAUDE.md`, `src/mir/README.md`

Status: **Done**

Due diligence:

- Same scan as INV-015.

Findings:

- ~~Same direct pipeline helper calls as INV-015.~~ Completed 2026-06-10 with typed `MIR::RuntimeCall` specs.

Impact:

- Medium contract drift risk.

Recommended fix:

- Use a typed runtime-call contract registry for internal helpers that are not user-visible stdlib entries.

### INV-019: `RawZig`, `InlineZig`, And `ZigTemplate` Are Unsafe Outside Final Emission Edges

Source: `CLAUDE.md`, `src/mir/README.md`

Status: **Green for `src/`, Red for MiniVM parsing**

Due diligence:

- Searched production source for `RawZig.new`, `InlineZig.new`, `ZigTemplate.new`, `ZigLit`, `RawZig`, `InlineZig`, and `ZigTemplate`.

Findings:

- No production `src/` hits.
- MiniVM still parses code strings as covered by INV-001.

Impact:

- Core compiler source is clean for these classes.
- MiniVM remains a backend correctness issue.

Recommended fix:

- Keep architecture invariant specs blocking reintroduction in `src/`.
- Remove MiniVM string parsing separately.

### INV-020: Callee-Takes Source Must Be Marked Moved At The Call Edge

Source: `CLAUDE.md`, `src/mir/README.md`

Status: **Green / Yellow**

Due diligence:

- Reviewed ownership consumption surfaces and architecture guardrails.

Findings:

- Typed `OwnershipOperandFact` paths exist and are mechanically guarded.
- ~~Yellow residual: legacy `OwnershipContract#consumes` name-list API still exposes a weaker representation.~~ Completed 2026-06-10.

Impact:

- Medium memory-safety architecture risk if new code uses legacy name consumption.

Recommended fix:

- Delete legacy consumes API and update remaining readers to operate on typed operands only.

### INV-021: Cleanup Contracts Are Inherited From Declaration/Initializer Facts

Source: `CLAUDE.md`, `src/mir/README.md`

Status: **Green**

Due diligence:

- Relied on architecture specs blocking cleanup contract inference from arbitrary subtrees and name visibility.

Findings:

- No direct invalidation found.

Impact:

- Low current risk.

Recommended fix:

- Keep cleanup ownership facts fail-closed.

### INV-022: Container Shape Dispatch Should Be Centralized And Not Re-Derived From Local Shape Heuristics

Source: `CLAUDE.md`, `src/mir/README.md`

Status: **Green / Yellow**

Due diligence:

- Checked direct length lowering and stdlib shape handling.

Findings:

- `lower_direct_length` explicitly refuses list/array/container shape re-derivation and falls back to `CheatLib.len`.
- Remaining yellow pressure exists in stdlib registry Zig snippets for `empty?`/`present?` using comptime `@hasField` patterns. These are registry-level emitter templates, not local lowering heuristics.

Impact:

- Low-to-medium. This appears architecturally acceptable today because the dispatch lives in the registry/runtime contract, but it remains string-template based.

Recommended fix:

- If this area changes, prefer a typed container-length/query runtime-call contract rather than more ad hoc registry Zig strings.

### INV-023: Storage And Provenance Facts Live On Declarations; EscapeAnalysis Is The Single Writer

Source: `CLAUDE.md`, `src/mir/README.md`

Status: **Green**

Due diligence:

- Relied on architecture spec restrictions on storage/provenance writers.

Findings:

- No direct invalidation found.

Impact:

- Low current risk.

Recommended fix:

- Keep new escape scenarios in `src/mir/escape_analysis.rb`/typed semantic placement facts, not MIRPass or checker.

### INV-024: FSM Emission Uses One General Transform

Source: `CLAUDE.md`, `src/mir/README.md`

Status: **Yellow**

Due diligence:

- Reviewed FSM transform emit surface for string/rendered-text recovery.

Findings:

- No old multi-path `makeBg`/`go` style special-case emission found in this audit.
- ~~Yellow residual: runtime-ref suppression uses rendered segment text (`src/mir/fsm_transform/emit.rb:945`).~~ Completed 2026-06-10.
- ~~Yellow residual: destroy validation uses string conventions in MIRChecker (`src/mir/mir_checker.rb:1779`, `src/mir/mir_checker.rb:1796`).~~ Completed 2026-06-10.

Impact:

- Low-to-medium. The major red flag appears gone; residual string checks are narrower.

Recommended fix:

- Complete for typed destroy-target and segment runtime-use facts.

### INV-025: New Escape Scenarios Belong In EscapeAnalysis, Not MIRPass Or MIRChecker

Source: `CLAUDE.md`

Status: **Green**

Due diligence:

- Relied on placement writer architecture specs and reviewed README ownership.

Findings:

- No direct invalidation found.

Impact:

- Low current risk.

Recommended fix:

- Keep adding escape cases in EscapeAnalysis with tests.

### INV-026: Ownership And Capabilities Are Binding Facts, Not Type Semantics

Source: `CLAUDE.md`, `src/annotator/README.md`

Status: **Green / Yellow**

Due diligence:

- Reviewed annotator README, capability guardrails, and searched for raw capability hashes in MIR.

Findings:

- Capability facts have moved substantially toward typed records and are mechanically guarded.
- ~~Yellow residual: scope/branch-flow identity is still acknowledged as not ideal in the annotator README.~~ Completed 2026-06-10: the README now describes composed scopes and copy-on-write branch entries.

Impact:

- Current risk is low after the composed-scope migration; stale parameter-symbol reads are guarded by `Scope.live_param_syms` and covered by `scope_composition_spec`.

Recommended fix:

- Continue separating stable symbol identity from mutable branch-flow state; do not reintroduce eager branch deep-copying or direct storage-axis mutation through branch-local captured entries.

### INV-027: Pre-MIR Type Check Means Post-Annotation Consumers Can Require `full_type!`

Source: `src/mir/README.md`, `src/annotator/README.md`

Status: **Green**

Due diligence:

- Relied on architecture specs that forbid defensive optional `full_type` probes in scoped consumers.

Findings:

- No direct invalidation found.

Impact:

- Low current risk.

Recommended fix:

- Keep fail-closed `full_type!` use in MIR consumers.

### INV-028: Cross-Phase Records Must Be Typed, Not Hashes Or Arrays Acting As Structs

Source: `src/annotator/README.md`, `src/mir/README.md`, current project conventions

Status: **Yellow**

Due diligence:

- Searched `src/annotator`, `src/mir`, and `src/semantic` for untyped hashes and symbol-key record access at phase boundaries.

Findings:

- ~~Thunk transform uses param hash-style access at a recursion/frame boundary (`src/mir/thunk_transform/emit.rb:97`, `src/mir/thunk_transform/emit.rb:239`, `src/mir/thunk_transform/emit.rb:319`).~~ Completed 2026-06-10 with `ThunkParamFact`.
- ~~FSM liveness returns and consumes hash-shaped declaration info (`src/mir/fsm_transform/liveness.rb:218`, `src/mir/fsm_transform/emit.rb:729`).~~ Completed 2026-06-10 with `CrossSegmentVarFact`.
- ~~FSM conservative local promotion used hash-shaped `{ name:, zig_type:, is_suspend_result: }` records.~~ Completed 2026-06-10 with `PromotedLocalFact`.

Impact:

- Resolved for the audited async/recursion phase-boundary records.

Recommended fix:

- Continue requiring typed records for new phase-boundary data.

### INV-029: Annotator User Errors Should Go Through Central Error Helpers

Source: project-local annotator invariant; reinforced by recent cleanup

Status: **Green**

Due diligence:

- Searched `src/annotator` for direct `CompilerError.new`, `$stderr.puts`, direct user-facing `hint:` strings, and broad `raise` usage.

Findings:

- No direct `CompilerError.new` or `$stderr.puts` hits in `src/annotator`.
- Remaining `raise` / `Kernel.raise` instances are internal invariant failures, not user-facing semantic diagnostics.

Impact:

- Low current risk.

Recommended fix:

- Keep semantic diagnostics centralized through `error!`/mapping helpers; leave internal invariant raises only where they truly indicate compiler bugs.

### INV-030: Pass Order Is A Compiler Contract

Source: `src/mir/README.md`, `src/README.md`

Status: **Green**

Due diligence:

- Relied on `PassState` and architecture specs checking compiler frontend/importer/MIRPass order.

Findings:

- No direct invalidation found.

Impact:

- Low current risk.

Recommended fix:

- Keep every new phase transition explicit in `src/semantic/pass_state.rb`.

### INV-031: PipelineHost Coordinates, Domain Lowerers Own Domain Logic, PlanBuilder Owns Source/Terminal Recognition

Source: `src/mir/README.md`

Status: **Green / Yellow**

Due diligence:

- Reviewed direct pipeline lowerer calls and current `CheatLib` construction findings.

Findings:

- The broad PipelineHost second-compiler problem appears resolved.
- Yellow residual: some pipeline domain lowerers directly construct runtime helper calls instead of using a contract registry.

Impact:

- Medium contract drift risk, not a broad PipelineHost regression.

Recommended fix:

- Add a typed internal runtime-call contract layer for pipeline helper calls.

### INV-032: No Regex/Text Rewriting In MIR For Semantic Cleanup Or Ownership

Source: `src/mir/README.md`, architecture invariant specs

Status: **Green / Yellow**

Due diligence:

- Ran architecture invariant spec.
- Searched FSM/MIR transform surfaces for rendered-text recovery.

Findings:

- Mechanical regex/text-rewrite guardrail is green.
- ~~Yellow residual: non-regex rendered-text introspection remains for runtime-ref suppression and checker expression-shape validation.~~ Completed 2026-06-10 for FSM runtime-ref suppression and lock destroy validation.

Impact:

- Low-to-medium. No current finding shows cleanup relocation by regex, but text-derived decisions still exist.

Recommended fix:

- Complete for the audited FSM uses.

### INV-033: Emission Is The Only Layer That Writes Zig

Source: `CLAUDE.md`, `src/mir/README.md`, current project invariant from recent ZigTemplate removal

Status: **Green / Yellow**

Due diligence:

- Searched production `src/` for RawZig/InlineZig/ZigTemplate and pre-emission Zig literal classes.
- Reviewed registry Zig pattern usage and emitter contexts.

Findings:

- No `RawZig`, `InlineZig`, `ZigTemplate`, or `ZigLit` in production `src/`.
- Yellow residual: stdlib registry entries still contain Zig pattern strings by design, and emitter context carries type-spelling fields. These are emitter-edge contracts, not MIRChecker-visible semantic cheats.

Impact:

- Low-to-medium. The hard red flags are gone from core `src/`, but the registry/template boundary still needs discipline.

Recommended fix:

- Keep registry strings confined to final emitter contracts; prefer closed typed emitter specs for new stdlib/intrinsic behavior.

### INV-034: Annotator Phase State Should Be Narrow, Typed, And Local

Source: `src/annotator/README.md`

Status: **Green / Yellow**

Due diligence:

- Reviewed annotator README current state and searched for stale direct error/state patterns.

Findings:

- Annotator state is improved and mostly behind typed helper/state objects.
- Yellow residual: README still acknowledges the include surface as an area that is not ideal. ~~The scope branch-flow/state split note is stale.~~ Completed 2026-06-10 with composed-scope documentation and regression coverage.

Impact:

- Medium semantic correctness/maintainability risk, lower than MIR memory-safety boundaries.

Recommended fix:

- Continue moving phase work products into local typed pass contexts and keep only durable facts on AST/symbol/signature objects.

## Findings That Were Explicitly Not Found

- No `std.heap.page_allocator` use in `src/`.
- No production `RawZig`, `InlineZig`, `ZigTemplate`, or `ZigLit` in `src/`.
- No direct `CompilerError.new` or `$stderr.puts` in `src/annotator`.
- No failing architecture invariant specs.
- No evidence that the old FSM cleanup relocation-by-rendered-template red flag still exists.
- No evidence that the transpiler is making memory allocation/cleanup decisions.

## Recommended Priority Order

1. **Fix MiniVM Zig parsing.** This is the only hard red finding and directly violates `CLAUDE.md`.
2. **Make `MIR::FreezeExpr` carry allocator provenance explicitly.** Narrow memory-safety architecture win.
3. **Replace FSM destroy string/name proof with typed lock-target facts.** This strengthens async cleanup correctness.
4. **Move remaining direct `CheatLib` pipeline helper calls behind typed contracts.** Completed 2026-06-10 with typed `MIR::RuntimeCall` specs.
5. **Delete legacy `OwnershipContract#consumes` name-list compatibility.** Completed 2026-06-10.
6. **Typed-record cleanup for thunk params and FSM liveness declaration facts.** Completed 2026-06-10.
7. **Move emitter type-string choices into explicit MIR strategies.** Good cleanup, but likely less urgent than the memory/ownership boundary items.
