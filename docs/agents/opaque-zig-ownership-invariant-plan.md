# Opaque Zig Ownership Invariant Plan

Status: active; RawZig removal from `src/` complete

Owner: Codex

Date: 2026-06-04

## Goal

Guarantee that no compiler-emitted opaque Zig text can allocate, free, transfer,
store, borrow, or return owned memory without a typed MIR ownership fact that
`MIRChecker` verifies before emission.

The intended end state is stronger than "document the rule": the compiler must
fail closed when a new `RawZig`, `InlineZig`, template string, or emitter helper
hides ownership behavior from the checker.

## Hard Invariant

No allocation or cleanup may be hidden in Zig text.

Allowed ownership-affecting codegen surfaces:

1. Structural MIR nodes with `ownership_effect`, allocator, cleanup, transfer,
   and child traversal facts.
2. Registry-backed calls (`FunctionSignature`, `CallableContract`,
   `OwnershipContract`, `IntrinsicEmit`) whose allocator and ownership behavior
   are explicit.
3. `InlineZig` only when it is a single expression, has an audited contract, and
   contains no opaque allocator/cleanup tokens.

Forbidden unless the checker rejects it:

1. `RawZig` containing `alloc`, `Allocator`, `heapAlloc`, `frameAlloc`, `create`,
   `destroy`, `dupe`, `concat`, `append`, `put`, `deinit`, `free`, `cleanup`,
   `retain`, `release`, `give`, or move/ownership side effects.
2. `InlineZig` with those same tokens unless the operation is represented by
   structured metadata and the code is proven to be a single expression.
3. Any emitter helper that directly emits `CheatLib.cleanup`, allocator calls, or
   deinit/free logic outside a MIR node dedicated to that operation.

## Current Evidence

The codebase already has pieces of the intended architecture:

1. `MIR::OwnershipEffect`, `AllocMark`, `Cleanup`, `TransferMark`, and
   `OwnershipContract`.
2. `MIRChecker` rejects `INLINE_NO_CONTRACT`, `OPAQUE_ZIG_OWNERSHIP`,
   `INLINE_ALLOC_MISMATCH`, and allocator/cleanup mismatches.
3. `InlineZig` carries `stdlib_def`, `allocs`, `target_var`, and
   `opaque_ownership_operations` audit metadata.
4. `MIR::OWNERSHIP_SIGNIFICANT_NODE_TYPES` lists ownership-bearing MIR surfaces.

The remaining risk is architectural drift: a new code path can still introduce
opaque Zig text unless tests make that impossible.

## RawZig / InlineZig Inventory

Inventory command:
`rg -n "MIR::InlineZig\.new" src --glob '*.rb'`

This table lists every production creation site under `src/`. Risk is about
whether the site could hide ownership, allocation, cleanup, control flow,
aliasing, or concurrency semantics from structural MIR. Low-risk entries are
still migration debt because `InlineZig` is not the desired architecture for
non-trivial code. `RawZig` has been removed from `src/`.

| Site | Reason | Risk | Suspicion / required direction |
| --- | --- | --- | --- |
| `src/backends/pipeline_host.rb:3205` | `obs_consumer_spawn` | Critical | Multi-statement spawn scaffold allocates a consumer context, transfers a stream source into a fiber, and relies on closed-form cleanup inside the opaque block. This still needs a dedicated observable-consumer spawn MIR/runtime bridge before it can be removed without increasing complexity. |
| `src/mir/lowering/variables.rb:1124` | `index_set` | High | Registry template can mutate indexed storage, allocate, and consume/move the assigned value. It carries metadata, but this is a structural indexed-store operation disguised as a template. |
| `src/mir/lowering/functions.rb:2032` | `extern_trampoline` | High | Builds callback trampoline code, root-stack switching, error propagation, and potentially allocator-backed return handling in one opaque block. This should be a dedicated MIR/runtime trampoline node. |
| `src/mir/lowering/capabilities.rb:612` | `with_block_bindings` | High | Emits lock/capability binding setup as joined Zig strings with fallible clauses. Capability acquisition and alias materialization are architecture-critical and should stay structural. |
| `src/backends/pipeline_host.rb:3397` | `obs_reduce_publish` | Medium/High | CAS loop and observable state mutation inside opaque Zig. No obvious allocator, but concurrency correctness is hidden from MIR. Replacing it cleanly likely requires a typed AtomicReduce publish node or runtime helper that can take the reducer body safely. |
| `src/mir/mir_lowering.rb:2850` | `static_call` | Medium | Registry-backed stdlib call template. Acceptable only while `matched_stdlib_def` is complete and audited; long-term, common calls should lower to structural MIR or typed call nodes. |
| `src/mir/mir_lowering.rb:3201` | `builtin_*` | Medium | Registry-backed builtin template. Same constraint as `static_call`: metadata must remain complete or this becomes opaque behavior. |
| `src/mir/lowering/functions.rb:1706` | `intrinsic` | Medium | Registry-backed intrinsic template with allocation and ownership metadata. Safer than ad-hoc Zig, but still template opacity. |
| `src/backends/pipeline_host.rb:4143` | `task_cfg` | Low/Medium | Generated task config literal. Ownership-neutral, but still opaque configuration syntax. |
| `src/mir/lowering/expressions.rb:958` | `or_exit_type` | Low | Enum-to-int expression only. Low memory risk; can become a small structural cast/literal helper later. |
| `src/backends/pipeline_host.rb:4106` | `bounded_workers_usize` | Low | `@intCast` expression only. Low memory risk; should become structural cast eventually. |
| `src/backends/pipeline_host.rb:4123` | `bounded_batch_usize` | Low | `@intCast` expression only. Low memory risk; should become structural cast eventually. |
| `src/backends/pipeline_host.rb:4403` | `stream_conc_capacity_user` | Low | `@intCast` expression only. Low memory risk. |
| `src/backends/pipeline_host.rb:4667` | `concurrent_reduce_min_init` | Low | Sentinel literal expression. Low memory risk. |
| `src/backends/pipeline_host.rb:4669` | `concurrent_reduce_max_init` | Low | Sentinel literal expression. Low memory risk. |
| `src/backends/pipeline_host.rb:4687` | `concurrent_reduce_kind` | Low | Enum literal expression. Low memory risk. |

Resolved in the InlineZig burndown:

- `obs_alloc`, `obs_wg_init`, `obs_set_completion`, and
  `obs_distinct_publish` now lower through structural MIR call/cast/try-catch
  nodes.
- `next_promise_list` now lowers through `MIR::NextPromiseList`.
- Test-only `test_preamble`, `assert_raises`, `pending_skip`, and
  `assert_eq_*` now lower through structural test MIR.
- `post_outer_body`, guard-failure error flow, bounded concurrent pointer
  casts, default stream capacity, and const-cast pipe-item helpers now have
  structural MIR nodes.
- Final production `MIR::InlineZig.new` producers were removed. Registry-backed
  template expressions now use `MIR::ZigTemplate`. The structural static-call,
  builtin, and indexed-store paths carry child MIR args; the broader
  pre-rendered intrinsic/spawn/trampoline surfaces remain documented below as
  follow-up structuralization debt. All of them keep the typed
  ownership/allocator metadata protocol from the old expression node.

### Final InlineZig Burndown Plan / Results

1. `obs_consumer_spawn`
   - Plan: stop constructing `InlineZig` directly; move the audited spawn block
     onto the typed template carrier while preserving the ownership contract
     that consumes the source stream binding.
   - Result: `PipelineHost` emits `MIR::ZigTemplate` for the spawn scaffold.
     This is still the highest-risk remaining Zig template because the scaffold
     contains fiber context transfer and should eventually become a dedicated
     observable-consumer spawn node/runtime bridge.
2. `static_call`
   - Plan: keep static-call registry templates, but carry lowered MIR args
     structurally so the emitter substitutes them and the checker can traverse
     child expressions.
   - Result: `lower_static_call` now returns `MIR::ZigTemplate` with MIR args
     and `matched_stdlib_def`.
3. `builtin_*`
   - Plan: make builtin registry calls use the same structured template carrier
     as static calls; BC still uses `InlineBc`.
   - Result: `emit_builtin` returns `MIR::ZigTemplate` on Zig targets and
     `MIR::InlineBc` on BC targets.
4. `with_block_bindings`
   - Plan: remove the direct `InlineZig` construction for WITH alias prelude
     text while keeping its borrow/fallible-clause metadata attached.
   - Result: WITH binding prelude text is carried by `MIR::ZigTemplate`. This
     remains medium-risk debt because the binding lines are still emitted as a
     pre-rendered Zig prelude; a future pass should split every WITH binding
     into dedicated structural guard/alias nodes.
5. `index_set`
   - Plan: replace pre-rendered indexed-store templates with a named-argument
     template node so target/index/value remain MIR children and ownership
     transfer metadata stays attached to the store.
   - Result: non-map indexed assignment uses `MIR::ZigTemplate` with
     `{ target:, index:, value: }` children plus allocator metadata and target
     variable facts.
6. `intrinsic`
   - Plan: remove the direct `InlineZig` producer for generic stdlib intrinsic
     templates while keeping registry ownership facts, allocator metadata,
     result type, and copied-consumed facts.
   - Result: generic intrinsic lowering emits `MIR::ZigTemplate`. This is
     lower risk than direct `InlineZig`, but still a broad template surface:
     high-risk intrinsics should continue migrating to dedicated structural MIR
     nodes when doing so reduces complexity.
7. `extern_trampoline`
   - Plan: stop returning `InlineZig` for root-stack callback trampolines while
     preserving the existing allocator/result metadata.
   - Result: extern trampoline lowering returns `MIR::ZigTemplate`. This remains
     high-risk debt because the trampoline is multi-statement control flow; the
     best final form is a dedicated `ExternTrampoline` MIR node whose emitter
     owns the scaffold shape.

Current production constructor inventory:

`rg -n "MIR::InlineZig\.new|InlineZig\.new" src --glob '*.rb'`

Result after this burndown: no production lowerer/back-end constructor sites.
There are now no `MIR::InlineZig.new` / `InlineZig.new` constructor calls under
`src/`. The node type still exists as a legacy checker/emitter surface and for
negative checker fixtures, but production lowerers no longer construct it
directly.

Final metrics for this pass:

- Decomplex baseline (`HEAD` before this pass): 5841 total candidates.
- Decomplex after: 5841 total candidates. This is flat overall, but mixed by
  cluster. Collapsed clusters: `ownership_contract` 8 -> 6, `stdlib_def`
  14 -> 10, `allocs` 11 -> 9. New/grown clusters: `child_bodies` NEW with
  2 findings, `is_a` 203 -> 204, `frame` 15 -> 17, `with_decl_alloc`
  7 -> 11. This should be treated as a mixed decomplex result even though the
  net candidate count stayed flat.
- Untyped slot baseline (`tools/typing_baseline.rb src`, same `HEAD`): total
  `T.untyped` 2395, params 1585, returns 523, struct/ivar slots 19.
- Untyped slot after: total `T.untyped` 2395, params 1585, returns 523,
  struct/ivar slots 19. All requested untyped counts stayed flat.

Support/consumer sites are also part of the current opaque-Zig surface:

1. `src/mir/mir.rb` defines `InlineZig`, audit metadata, and warnings. The
   comments already describe it as an ownership escape hatch; the next step is
   to keep tightening executable invariants around the remaining producers.
2. `src/mir/mir_checker.rb` verifies contracts, allocator metadata,
   target-var metadata, and rejects opaque ownership operations. This is the
   correct enforcement layer, but it must be backed by static creation-site
   gates so new producers cannot bypass it.
3. `src/mir/mir_emitter.rb` substitutes `InlineZig` placeholders. This file
   must stay mechanically dumb: rendering only, no ownership decisions.
4. `src/mir/hoist.rb`, `src/mir/lowering/variables.rb`, and
   `src/mir/lowering/control_flow.rb` inspect `InlineZig` allocator metadata
   during lowering/hoisting. These are legitimate until the producers are
   converted, but they are debt created by opaque allocation templates.
5. `src/ast/diagnostic_registry.rb` documents checker diagnostics for
   `InlineZig`. This is not suspicious; it should be kept in sync with the
   stronger invariant.
6. `examples/minivm/bc_emitter.rb` and
   `examples/minivm/register_bc_emitter.rb` reject, pattern-match, or partially
   translate some `InlineZig` shapes for the VM paths. This is suspicious as a
   compatibility layer: the VM should consume structural MIR, not parse
   Zig-shaped escape hatches.
7. `tools/fuzz/templates/mir_checker_negative_matrix.rb` intentionally
   constructs bad `InlineZig` nodes for negative checker coverage. This is not
   product code and should remain as test input for the invariant.

## Guarantee Strategy

## RawZig Removal Plan

Status: complete

Objective: remove `RawZig` entirely from `src/`, not merely stop producing it.
After this burn-down, compiler MIR may not define, emit, check, or lower through
a raw Zig statement node. Test-only negative coverage must use `InlineZig` or a
purpose-built structural fixture instead.

### Baseline Metrics

Captured on 2026-06-04 before the refactor:

1. `ruby gems/decomplex/exe/decomplex report src --output=/tmp/rawzig-decomplex-before.md`
   - Cross-Detector Convergence: 1434
   - Root-Cause Clusters: 354
   - Decision Pressure: 297
   - Missing Abstractions: 200
   - Reification Misses: 25
   - Semantic Predicate Aliases: 5
   - Exact Predicate Aliases: 10
   - Inconsistent Rename Clones: 71
   - Flay Similarity: 0
   - Neglected Updates: 1276
   - Derived-State Staleness: 146
   - Neglected Conditions: 11
   - Neglected Path Conditions: 1692
   - Oversized Predicates: 13
   - Broken Protocols: 1353
   - False Simplicity: 881
   - Fat Unions: 12
2. `ruby tools/typing_baseline.rb src`
   - Total `T.untyped`: 2392
   - Param slots with `T.untyped`: 1582
   - Return slots with `T.untyped`: 521
   - Struct/ivar slots with `T.untyped`: 19

Acceptance gate: every decomplex count and every untyped slot count must be less
than or equal to this baseline after the refactor. Any new Ruby lines must be
covered by focused specs; branch coverage for the touched behavior should stay
at or above the project target of about 80%.

### Design

1. Replace the local/stdlib `REQUIRE` RawZig producer with structural module
   MIR. The importer already preserves imported module MIR as `mir_items`; the
   lowering should wrap those items in a `ModuleNamespace` node that emits
   `const namespace = struct { ... };`.
2. Carry imported type definitions structurally as `type_items` on
   `ModuleImporter::CompiledModule`. Filter visible type items by the imported
   AST and same-directory/package visibility, preserving the existing
   "emit each imported type once" behavior.
3. Keep bytecode imports structural. The BC path can keep returning imported
   helper `FnDef`s because the VM call emitter already strips namespace prefixes
   when resolving helper functions.
4. Delete the `RawZig` MIR node class, its stdlib-def coercion registration, its
   ownership-significant registration, MIRChecker branches, and MIREmitter
   branches.
5. Remove RawZig-specific diagnostics and tests. Negative checker coverage
   should now assert that `InlineZig` without a contract fails closed, because
   there is no RawZig node left to instantiate.
6. Add an architecture invariant that fails if the token `RawZig` appears under
   `src/` again. The invariant is intentionally lexical: reintroducing the name
   should require an explicit architecture decision, not a casual helper.
7. Update docs and comments in `src/` so they describe the new invariant:
   statement-level raw Zig is gone; expression-level opaque Zig is limited to
   audited `InlineZig`.

### Results

Captured on 2026-06-04 after the refactor:

1. Source inventory:
   - `rg -n "\bRawZig\b|MIR::RawZig|RAW_NO_CONTRACT|RAW_UNJUSTIFIED" src --glob '*.rb' --glob '*.md'`
   - Result: no matches under `src/`.
2. `ruby gems/decomplex/exe/decomplex report src --output=/tmp/rawzig-decomplex-after.md`
   - Cross-Detector Convergence: 1430
   - Root-Cause Clusters: 354
   - Decision Pressure: 297
   - Missing Abstractions: 199
   - Reification Misses: 25
   - Semantic Predicate Aliases: 5
   - Exact Predicate Aliases: 10
   - Inconsistent Rename Clones: 71
   - Flay Similarity: 0
   - Neglected Updates: 1276
   - Derived-State Staleness: 143
   - Neglected Conditions: 11
   - Neglected Path Conditions: 1664
   - Oversized Predicates: 13
   - Broken Protocols: 1332
   - False Simplicity: 881
   - Fat Unions: 12
3. `ruby tools/typing_baseline.rb src`
   - Total `T.untyped`: 2388
   - Param slots with `T.untyped`: 1581
   - Return slots with `T.untyped`: 520
   - Struct/ivar slots with `T.untyped`: 19
4. Focused coverage:
   - `COVERAGE=1 COVERAGE_DIR=/tmp/rawzig_cov bundle exec rspec spec/architecture_invariants_spec.rb spec/diagnostic_registry_spec.rb spec/mir_emitter_spec.rb spec/fsm_wrapper_emitter_spec.rb spec/boobytrap_method_coverage_spec.rb spec/mir_checker_spec.rb spec/mir_gap_burn_spec.rb spec/mir_lowering_spec.rb spec/fsm_suspend_resolvers_spec.rb spec/pipeline_legacy_matrix_spec.rb`
   - Result: 684 examples, 0 failures.
   - Added executable source lines: 78/78 covered.
   - Added-line branch arms: 56/56 covered.

The acceptance gates passed: decomplex counts are all less than or equal to the
baseline, untyped param/return/ivar slots are all less than or equal to the
baseline, and new executable source coverage is complete.

### 1. Add A Static Token Gate

Create an architecture spec that scans all Ruby code under `src/` for direct
string emission of ownership-sensitive Zig tokens.

The scan should classify each hit as one of:

1. structural MIR node implementation,
2. registry metadata,
3. explicit allowlisted legacy site with an issue link,
4. violation.

The allowlist must be small, file/line anchored, and treated as debt. A broad
file-level allowlist is not acceptable.

### 2. Make RawZig Ownership-Hostile By Default

`MIR::RawZig` should be valid only for text that cannot affect ownership. If it
has any ownership-sensitive token, construction or `MIRChecker` must require an
explicit `mark_opaque_ownership_operations!`-style fact and then reject it for
compiler MIR.

Long term: remove `RawZig` from production MIR entirely. Keep it only for
negative checker tests and target-specific non-memory text that has no ownership
tokens.

### 3. Strengthen InlineZig Contracts

`InlineZig` should remain only for expression-level templates. The checker must
reject it when:

1. it contains statement separators or declarations,
2. it contains ownership-sensitive tokens but has no `stdlib_def` or
   `FunctionSignature`,
3. it has allocator placeholders but no `allocs` map,
4. it has `allocs` but no `target_var` where a target binding/container is
   required,
5. it returns owned memory but does not expose `ownership_effect`.

### 4. Emitter Must Be Dumb

Add an architecture spec that scans `src/mir/mir_emitter.rb` for direct ownership
decisions. The emitter may render structural nodes, but it must not decide:

1. which allocator owns a value,
2. whether cleanup is needed,
3. whether a value is moved or transferred,
4. whether cleanup is guarded.

Any helper that emits cleanup/allocation text must correspond to a structural
MIR node and a checker invariant.

### 5. Closed Ownership Surface Test

Add a spec that compares:

1. all MIR classes/structs with `ownership_effect`,
2. `MIR::OWNERSHIP_SIGNIFICANT_NODE_TYPES`,
3. `MIRChecker::LINEAR_STATEMENT_NODE_TYPES`,
4. emitter dispatch arms.

The test should fail when a new MIR node can be emitted but is absent from
ownership traversal or checker registration.

### 6. Generated Program Audit

Add a post-lowering audit pass in tests that walks generated MIR for representative
programs and fails on:

1. `RawZig` in compiler MIR,
2. `InlineZig` with ownership-sensitive tokens and no contract,
3. direct `CheatLib.cleanup` outside structural cleanup nodes,
4. allocator text in string templates where no `AllocatorRef`/contract exists.

Run this audit over:

1. `transpile-tests/`,
2. full fuzz matrix,
3. examples/benchmarks coverage corpus,
4. targeted negative fixtures for known dangerous tokens.

### 7. CI Gates

Add separate CI jobs or integrate into existing fast Ruby specs:

1. `architecture_invariants_spec`: static token gate and closed surface check.
2. `mir_checker_spec`: negative examples for every forbidden opaque pattern.
3. `mir_lowering_spec`: corpus walk proving no production fixture emits
   ownership-opaque Zig.

The invariant should be fast enough to run before expensive Zig CI.

## Migration Checklist

1. Inventory all current `RawZig` creation sites and classify them.
2. Inventory all `InlineZig` sites with ownership-sensitive tokens.
3. Convert high-risk sites to structural MIR first:
   - observable allocation/spawn helpers,
   - pipeline materialization,
   - sharded map mutation,
   - cleanup/deinit/free paths.
4. Add temporary pinpoint allowlist entries only where conversion is not in the
   same change.
5. Delete each allowlist entry as the corresponding structural node lands.
6. Make `RawZig` ownership tokens a hard failure once the allowlist is empty.

## Acceptance Criteria

1. Adding `MIR::RawZig.new("rt.heapAlloc().create(T)", ...)` in production
   lowering fails a fast architecture/checker spec.
2. Adding `MIR::InlineZig.new("try list.append(rt.heapAlloc(), x)", ...)`
   without allocator and callable metadata fails.
3. Adding direct cleanup/allocation string emission in `MIREmitter` fails unless
   it is rendering a structural ownership node.
4. The full transpile, fuzz, and examples/benchmarks MIR corpus passes the audit.
5. The allowlist is reviewed in `docs/agents` and shrinks monotonically.
