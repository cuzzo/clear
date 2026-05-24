# MIR Lowering Cleanup Tracker

Goal: continue splitting MIR lowering by authoritative responsibilities, not by
metric appeasement. Each cleanup must make the code easier to reason about by
moving data to a typed boundary, reducing local re-derivation, or isolating a
lowering responsibility that already exists as a concept.

## Work Items

- [x] `material-owned-result-fact`: unify allocating / owned-result provenance
  into one typed fact path. The fact owns whether the expression produces owned
  storage, its allocator, target binding, cleanup shape, and whether the result
  must be hoisted. Var-decl lowering, hoist, and MIRChecker must read this fact
  instead of re-asking pieces of the question.
  Progress: added `MIR::OwnershipEffect`; allocation result facts, var-decl
  placement, hoist, and MIRChecker now consume the same effect object.
- [x] `material-placement-provenance`: make placement provenance a first-class
  MIR ownership fact for every owned-storage producer. This must cover calls,
  method calls, InlineZig, BlockExpr result producers, NEXT/COLLECT, DeepCopy,
  DupeSlice, aggregate constructors, and future producers through one
  verifier-visible path.
  Progress: owned-storage producers expose placement through
  `ownership_effect`; wrapper expressions forward it through Cast/Try/Block
  result shapes.
- [x] `material-node-ownership-effects`: replace the central
  `mir_allocates?` / `mir_owned_alloc` class-probing protocol with node/fact
  driven ownership effects. Adding a new ownership-significant MIR node should
  require declaring its fact, not updating parallel case statements.
  Progress: `mir_allocates?`, `mir_owned_alloc`, and MIRChecker
  `allocating_expr?` are compatibility readers over `ownership_effect`, not
  independent node-class ownership protocols.
- [x] `material-hard-type-invariants`: remove defensive nil/type probes on the
  touched MIR ownership paths by making post-annotation / post-lowering inputs
  non-nil typed facts. Incorrect missing data must fail at the boundary.
  Progress: return placement now uses `Type.from_node!` at post-annotation
  boundaries, and var-decl/result placement reads typed `OwnershipEffect`
  facts instead of soft-probing node classes.
- [x] `material-return-ownership-plan`: finish `ReturnOwnershipPlan` as the
  sole source for returned roots, moved roots, consumed roots, cleanup
  conversion, transfer marks, and final return emission.
  Progress: return lowering now emits transfer/move marks through
  `ReturnOwnershipPlan`; the old free-floating `returned_transfer_marks`
  helper was deleted.
- [ ] `slopcop-type-norm-burn-down`: audit expanded MIR SlopCop `type_norm`
  dark arms and remove defensive nil/type guards only when the upstream fact can
  be made non-nil / strongly typed. Do not replace them with equivalent guards
  elsewhere.
  Audit: expanded SlopCop reports 403 `type_norm` arms. Largest clusters are
  `escape_analysis` top-level walker logic (80), `lower_or_rescue` (14),
  `lower_binary_op` (10), `lower_match` (9), `lower_get_index` (8), catch
  reassign walkers (16 combined), and var-decl/init/indexed assignment helpers.
  Progress: ownership-transfer predicates no longer accept nil `Type` values;
  callers now use `Type.from_node!` where post-annotation type information is a
  hard invariant. Latest focused MIR snapshot is 448 `type_norm` arms because
  the new call ownership facts and generic AST moved-arg walker are currently
  uncovered; those arms are not acceptable as permanent defensive shape checks.
- [ ] `slopcop-dead-arm-audit`: audit expanded MIR SlopCop `dead` dark arms.
  Delete truly unreachable code or convert it into hard invariants when the
  compiler state model makes the branch impossible. Keep intentional diagnostic
  paths out of this bucket.
  Audit: expanded SlopCop reports 154 `dead` arms. Largest clusters are
  generated/top-level MIR dispatch arms, `linear_scope_decl_always_moves?`,
  `lower_match`, `var_decl_suppression`, `moved_arg_expr_members`,
  stream loop lowering, and var-decl node construction.
  Progress: deleted unused escape-analysis heap helpers and removed
  `moved_arg_expr_members`; the moved-arg path is now a generic AST traversal
  with only nested ownership scopes as explicit boundaries. Latest focused MIR
  snapshot is 145 `dead` arms.
- [ ] `OwnershipTransferPlan`: reify ownership-transfer emission into a typed
  fact object that owns consumed roots, transfer target, guarded-move
  requirement, and emitted marks. Call sites must not manually remember the
  TransferMark/MoveMark protocol.
  Progress: `MIRLowering::OwnershipTransferPlan` now owns paired
  `TransferMark`/`MoveMark` emission for pre-terminator transfers,
  BG-capture transfers, and MIR consumed-root transfers.
- [x] `AllocatingResultFact`: reify `mir_allocates?`, target-var stamping,
  allocator choice, and alloc-target mutation into one typed result fact so
  hoist/lowering/checker paths cannot forget half the allocation protocol.
  Progress: implicit allocating `Let` handling now produces an
  `AllocatingResultFact` before emitting `AllocMark`; the fact now carries the
  same `MIR::OwnershipEffect` consumed by hoist and MIRChecker.
- [x] `CallOwnershipFacts`: expand the existing call-argument facts so stdlib,
  intrinsic, UFCS, and normal calls share the same typed ownership contract
  path. No stdlib-specific ownership side channel.
  Progress: added `MIRLoweringFunctions::CallOwnershipFacts`; normal callable
  contracts and stdlib/intrinsic TAKES handling now read the same typed
  consumed-name/takes-index fact instead of repeatedly interpreting arg specs.
  The registry conversion now treats method `takes_args` as user-argument
  indexes, so receiver mutation is not mistaken for receiver ownership
  consumption.
- [x] `ReturnOwnershipPlan`: make return lowering consume one typed plan for
  returned names, moved roots, consumed roots, converted cleanup names, and
  final transfer marks.
  Progress: `ReturnOwnershipPlan` now carries explicit returned roots, moved
  roots, consumed roots, and direct MIR value roots separately, with a single
  derived `returned_names` set and authoritative transfer mark emission.
- [x] `stdlib-arg-fact-boundary`: complete the stdlib/intrinsic argument
  boundary so intrinsic lowering consumes typed argument facts, not raw
  `arg_spec` Array/Hash shape checks. `CallOwnershipFacts` is only complete
  when TAKES, coercion, materialization, and hoist decisions all read the same
  typed per-argument fact.
- [x] `canonical-ast-child-walker`: replace inline AST `members` traversal in
  moved-arg ownership collection with one canonical child iterator. The moved
  ownership path may define semantic stop points, but it must not own Array /
  Hash / Locatable traversal mechanics.
- [x] `typed-node-aliases`: define weak node aliases for the two syntax trees
  and use them at the public helper boundary where a method actually consumes
  AST or MIR nodes. `AST::Node` aliases the existing AST locatable marker,
  `MIR::Node` aliases `MIR::Stmt | MIR::Expr`, and generic MIR walkers now
  accept containers honestly while yielding only `MIR::Node` values.
- [ ] `dead-arm-second-pass`: audit the current 145 SlopCop `dead` arms and
  delete only code that is provably unreachable or convert impossible states to
  hard invariants. Do not extract helpers solely to satisfy SlopCop.
- [x] `#1` pass/fact contract enforcement: make pass ordering a typed runtime
  contract, not documentation. A pass may only mark the next registered stage,
  consumers must require their input stage, and architecture specs must fail if
  MIR-relevant stages are added outside the contract.
- [x] `#3` material MIR lowering reduction: only split `mir_lowering` seams when
  the split deletes local decisions. Priority targets are var-decl emission and
  call/result ownership lowering; both must read finalized typed facts rather
  than re-derive heap/frame/cleanup/ownership locally.
  Progress: var-decl alloc marker construction now has one helper path, generic
  `Id` exclusion is a typed fact, and declaration placement no longer reads
  intrinsic operation allocation directives. Call argument ownership lowering
  now has one typed `CallArgFacts` path shared by normal calls and UFCS method
  calls, so TAKES/COPY/allocator shaping is no longer duplicated. Owned-result
  finalization now has one helper path shared by normal calls and UFCS method
  calls.
- [x] `lower_or_rescue`: extract typed facts for OR / OR_RESCUE lowering so the
  lowering body reads a finalized shape instead of recomputing nullable state
  and catch behavior inline.
- [x] `lower_indexed_assignment`: split target/index/value preparation from
  mutation emission; remove repeated collection-shape probes by relying on a
  typed assignment plan.
- [x] `lower_match`: split scrutinee setup, arm lowering, and result assembly so
  match lowering does not own unrelated control-flow bookkeeping decisions.
- [x] `lower_var_decl`: split binding facts, cleanup facts, allocation marker
  emission, and init lowering into typed helper records. This remains the
  largest hotspot and must be handled last enough that the smaller patterns are
  established first.
- [x] `needs_rt`: make MIR lowering consume only finalized runtime metadata.
  User functions without a post-MIRPass `needs_rt` value now fail hard instead
  of defaulting to "probably true"; intrinsic/runtime calls read their typed
  registry contract.
- [x] `stdlib_def` / ownership effect reads: synthetic MIR InlineZig producers
  now attach typed `FunctionSignature` contracts instead of raw Hash literals,
  and MIR consumers use typed allocation / mutation / ownership predicates.
- [x] `lower_for_each` and `lower_for_range`: split loop fact collection into
  typed plan objects so loop emission reads one authoritative shape.
- [x] `lower_return`: split return value placement and returned-binding
  collection into a typed return plan before final MIR emission.
- [x] `decomplex-loop-scope-facts`: replace duplicated loop/scope local
  binding scanners in cleanup classification, escape placement, and MIR
  control-flow analysis with one typed `MIR::LocalBindingFacts` boundary.
  The fact owns direct loop-body traversal, binding names, binding cleanup
  entries, and frame-allocation binding lists.
  Progress: added `MIR::LocalBindingAnalysis`; cleanup classifier, escape
  placement, loop-frame analysis, and loop-frame specs now consume this shared
  fact instead of owning parallel scanners.
- [x] `decomplex-placement-fact`: finish centralizing `:frame | :heap`
  placement reads behind typed placement / ownership facts. MIR lowering and
  emission may read finalized placement; they must not make fresh heap/frame
  decisions locally.
  Progress: added `MIR::Placement` as the allocator normalization/rendering
  boundary for MIR lowering, MIR emission, and pipeline-host inline Zig.
- [x] `decomplex-return-function-plans`: continue shrinking
  `lower_return` and `lower_function_def` by reifying implicit ownership,
  cleanup, catch/default, and result protocols into typed plans that delete
  local protocol reconstruction.
  Progress: return ownership planning is in place from the prior ownership
  work; function-entry prologue construction now reads one typed
  `FunctionEntryPlan` instead of interleaving runtime frame setup,
  reentrance/recursion guards, unused-param suppressions, mutable scalar
  shadows, and TAKES ownership markers inside `lower_function_def`. Catch
  lowering now returns `CatchLoweringPlan`, and `MIR::CatchWrapper` receives
  typed `CatchReassign` / `CatchClauseMeta` facts instead of positional arrays
  and raw Hash metadata.
- [x] `decomplex-function-prologue-plan`: reify function-entry MIR construction
  into typed facts/plans. Frame save/restore, non-reentrant guards,
  recursion-yield checks, unused-param suppressions, mutable scalar shadows,
  and TAKES parameter ownership markers must be built from one plan instead of
  interleaved inside `lower_function_def`.
  Progress: added `FunctionEntryPlan`; `lower_function_def` consumes finalized
  prologue and TAKES marker arrays instead of assembling independent entry
  protocols inline.
- [x] `decomplex-next-expr-plan`: reify NEXT lowering into a typed result plan
  that owns source kind, result type, allocator, method name, and whether inline
  Zig is required. `lower_next_expr` should emit the plan, not rediscover
  promise-list/observable/string/owned-result placement branch by branch.
  Progress: added `NextExprPlan`; var-decl facts and NEXT emission now share
  the same typed promise/result/allocator facts, and pipeline-host allocator
  rendering goes through `MIR::Placement`. The plan carries a typed
  `MIR::Node` inner expression, and branch-local NEXT state now uses
  shape-specific names so the method no longer presents false stale-state
  coupling between promise-list and observable-string branches.
- [x] `decomplex-typed-catch-and-void-facts`: replace repeated catch/default
  tuple guards and repeated AST-void-type checks with typed lowering facts.
  Progress: added `CatchLoweringPlan`, `MIR::CatchReassign`,
  `MIR::CatchClauseMeta`, `function_catch_clauses`, `default_catch_body`, and
  one `ast_void_type?` predicate consumed by FSM and concurrency lowering.
  Decomplex Missing Abstractions moved 216 -> 213 across the obvious-win
  passes; SlopCop `type_norm` moved 199 -> 194 and genuine gaps 80 -> 77.
- [ ] `decomplex-mir-hotspots`: audit the current convergence hotspots
  (`lower_next_expr`, `lower_do_block`, `lower_smooth`, hoist, escape analysis,
  cleanup classifier) and only change code where a typed fact/plan deletes a
  real duplicated decision.
  Progress: current metrics show the loop-scope and placement changes reduced
  Missing Abstractions, Neglected Conditions, Broken Protocols, and SlopCop
  genuine gaps. The remaining high-confidence targets are listed in the latest
  report notes. Latest obvious-win pass reduced Decomplex Derived-State
  Staleness from 152 to 150 by deleting misleading cross-branch local state
  reuse in NEXT lowering; no SlopCop denominator change. A follow-up
  intrinsic pass made receiver type a single typed fact at the top of
  `lower_intrinsic`, tightened the intrinsic node boundary to function/method
  calls, and removed the remaining intrinsic stale-state report entry,
  bringing Derived-State Staleness to 149. The catch/default and void-type
  passes lowered Missing Abstractions to 213, SlopCop `type_norm` to 194, and
  SlopCop genuine gaps to 77 without adding behavior exceptions.

## Current Report Backlog

Snapshot: `/tmp/decomplex-decomplex3-obvious6.md` and
`/tmp/slopcop-decomplex3-obvious6.md` after commit `90c4bb918`.
These are the obvious material cleanup targets. The list is grouped by the
state/protocol that should be reified, not by every individual metric line.

### Tier 1: MIR / Memory / Lowering

- [ ] `report-mir-lower-function-plan`: continue shrinking
  `lower_function_def` by moving parameter typing, return typing, post/catch
  wrapper choice, and inner/outer function emission into typed plans. Current
  convergence still reports `lower_function_def` with 111 findings.
- [ ] `report-mir-return-plan-followup`: finish reducing `lower_return` by
  making every returned-value path read `ReturnOwnershipPlan`; no local
  reconstruction of returned roots, moved roots, cleanup conversion, or final
  MIR emission.
- [ ] `report-mir-smooth-plan`: reify `lower_smooth` pipeline facts so source,
  fallback, ownership, optional/error handling, and cleanup decisions are
  computed once and read by emission.
- [ ] `report-mir-hash-literal-plan`: reify `lower_hash_lit` element/key/value
  type, allocator, ownership effect, and cleanup facts. Current report flags
  stale derived state and path-condition pressure in that method.
- [ ] `report-mir-stdlib-def-effect`: make `stdlib_def`, `zig_pattern`,
  callable ownership, allocation effect, and mutation target one typed call
  effect object. Current root-cause clusters still show these as separately
  read/written facts across hoist, var lowering, and intrinsic lowering.
- [ ] `report-mir-next-shape-fact`: unify observable/promise NEXT shape logic
  behind one predicate/fact. The remaining repeated tuple is
  `promise_type.observable? | promise_type.tense_type&.array?`.
- [ ] `report-mir-id-transfer-predicate`: replace repeated
  `ti.generic_instance? && ti.generic_base == :Id` with one authoritative
  Type predicate used by annotator, MIRPass, lowering, and MIRChecker.
- [ ] `report-mir-local-binding-completeness`: resolve the neglected
  `AST::Assignment | AST::BindExpr | AST::VarDecl` differences in
  `MIR::LocalBindingFacts`, MIRPass consumed-name collection, FSM liveness,
  and migration helpers. If assignments are intentionally excluded in a reader,
  encode that as a separate typed fact.
- [ ] `report-mir-control-flow-node-kind`: reify control-flow/splitting node
  families used by FSM transform, cleanup classifier, escape analysis, and
  control-flow walkers. Current repeated dispatch sets disagree on
  `CatchBlock`, `DoBlock`, `MatchStatement`, and loop/with nodes.
- [ ] `report-mir-capture-analysis-fact`: make capture analysis a non-nil typed
  fact for BG/DO/FSM/control-flow paths. Current root-cause cluster shows
  `capture_analysis` read defensively across control-flow and lowering.
- [ ] `report-mir-call-owned-result-fact`: collapse `call_owned_return?`,
  `call_owned_return_from_args?`, `heap_carry_return_vars`, lifetime reads, and
  return type cleanup checks into a typed `CallResultOwnership` fact.
- [ ] `report-mir-place-value-plan`: tighten
  `place_value_for_destination` / `place_or_branch_value_for_destination` so
  allocation, destination type, and ownership effect are a single fact.
- [ ] `report-mir-implicit-alloc-mark-fact`: finish the
  `AllocatingResultFact` migration for `implicit_alloc_mark_for_mir_node` and
  remove remaining local probes of allocating MIR shapes.
- [ ] `report-mir-discard-owned-type`: reify discard/owned-zig type
  classification so `discard_owned_zig_type` is not rechecking type shape
  locally.
- [ ] `report-mir-collect-stdlib-consumed-roots`: delete the remaining
  stdlib-specific consumed-root collection path by making all stdlib,
  intrinsic, UFCS, and normal calls emit the same typed ownership contract.
- [ ] `report-mir-reentrant-kind`: replace repeated
  `:reentrant | :reentrant_max_depth | :reentrant_tail_call` dispatch with one
  effect/reentrance predicate shared by annotator, MIRPass, and lowering.
- [ ] `report-mir-sync-family-kind`: replace repeated
  `:ATOMIC | :LOCKED | :VERSIONED` and
  `:always_mutable | :atomic | :local | :locked | :versioned | :write_locked`
  dispatch with a typed sync-family classifier. This should also decide whether
  missing `:local` is real or intentional in lowering capability wrappers.
- [ ] `report-mir-rc-emit-helper`: unify identical
  `emit_rc_retain` / `emit_rc_downgrade` / `emit_weak_upgrade` emission behind
  one retained/weak handle operation fact, not three copied emitter methods.
- [ ] `report-mir-empty-marker-plan`: remove copied empty-array defaults
  (`child_bodies`, `marker_plan`, `with_alias_ownership_marks`) by giving
  capability/capture strategies explicit empty objects.

### Tier 1: Annotation / Type State

- [ ] `report-type-finalize-storage`: fix `AST::Locatable#finalize_storage!`
  stale derived state (`value_sync`, `t`) by splitting value/type/symbol
  normalization into typed immutable facts.
- [ ] `report-type-zig-compute-plan`: fix `Type#compute_zig_type` stale
  derived state (`inner_zig` from `base_zig`) and repeated ownership/layout
  dispatch by reifying a typed `ZigTypePlan`.
- [ ] `report-type-capability-predicates`: replace inline `sync == :atomic`,
  `sync == :local`, `sync == :locked`, `sync == :write_locked`, and
  `sync == :versioned` checks with existing predicates or add missing
  predicates where the receiver is not a `Type`.
- [ ] `report-type-ownership-predicates`: replace inline
  `ownership == :shared` and `ownership == :multiowned` in `Type` storage logic
  with existing `shared?` / `multiowned?` predicates.
- [ ] `report-type-layout-predicates`: replace inline `layout == :indirect`
  with the existing `indirect?` predicate or a typed annotation-layout fact.
- [ ] `report-annotator-full-type-storage-contract`: audit the high-volume
  `.full_type` / `.storage` co-update cluster. The expected architecture is:
  annotation writes type, escape writes storage, and any co-write exception
  must be deleted or represented as a typed phase fact.
- [ ] `report-annotator-resolve-call-fact`: reify `resolve_call` output into a
  typed call-resolution object carrying signature, return type, lifetime,
  ownership/sync/layout/provenance, coerced type, and stdlib/intrinsic emit
  facts. This is the largest root-cause cluster by volume.
- [ ] `report-annotator-params-fact`: reify
  `declare_and_verify_params` output so param defaults, full type,
  storage/provenance, ownership, and callable contracts are one typed object.
- [ ] `report-annotator-generic-propagation-fact`: reify
  `propagate_declared_type_to_value!` and
  `propagate_collection_metadata!`; current report shows stale `coll_src` from
  `decl_t` and repeated full_type/storage/provenance writes.
- [ ] `report-annotator-capability-var-fact`: replace defensive
  `cap_var_sync`, `cap_var_layout`, `cap_var_storage`, and `cap_var_name`
  probes with one typed capability target fact.
- [ ] `report-annotator-validate-capability-plan`: fix stale
  `atomic_ptr_ok` derived from `syn` and move capability validation inputs into
  one immutable plan.
- [ ] `report-annotator-control-flow-state`: replace inline `state == :moved`
  in `analyze_control_flow_branches` and ownership graph state handling with a
  typed ownership-state predicate/object.
- [ ] `report-annotator-return-expected-fact`: fix `visit_ReturnNode` stale
  `expected_void_compatible` after `expected` changes by deriving return
  expectation once from a typed return context.
- [ ] `report-annotator-assignment-target-fact`: fix `visit_Assignment` stale
  `tname` after `target` changes by using one typed assignment target fact.
- [ ] `report-annotator-struct-literal-plan`: reify `visit_StructLit` field,
  storage, move/copy, and cleanup facts. It remains a high convergence hotspot.
- [ ] `report-annotator-get-field-plan`: reify `visit_GetField` target,
  schema, optional/error, and ownership facts. It remains a high convergence
  hotspot.
- [ ] `report-annotator-next-expr-plan`: align `visit_NextExpr` annotation
  facts with MIR `NextExprPlan`; no duplicated observable/promise shape logic.
- [ ] `report-annotator-match-plan`: split `visit_MatchStatement` into typed
  scrutinee/arm/pattern/result facts. Current report still shows the largest
  Missing Abstraction around `AST::GetField | AST::MethodCall` arms.
- [ ] `report-annotator-while-loop-plan`: reify loop condition/body/scope
  facts for `visit_WhileLoop` and `visit_WhileBindLoop`; they remain top
  convergence hotspots.
- [ ] `report-annotator-with-block-plan`: reify capability/sync/resource facts
  for `visit_WithBlock`; current report flags it as a top convergence hotspot.
- [ ] `report-annotator-auto-shape-fact`: replace `slot.respond_to?(:shape) &&
  slot.shape` guards with a typed auto-inference slot shape object.
- [ ] `report-annotator-auto-predicate`: unify `auto?` / `auto_type?` into one
  predicate consumed by auto inference and importer.
- [ ] `report-annotator-void-statement-visitors`: replace identical
  `visit_PassStmt`, `visit_OrRaise`, `visit_OrBreak`, `visit_OrPass`, and
  `visit_OrPrune` bodies with one typed void-statement annotation path.

### Tier 1: Pipeline / Formatter / Tooling

- [ ] `report-pipeline-smooth-chain-fact`: replace repeated
  `BinaryOp && op == :SMOOTH` checks in annotator, pipeline host, and pipeline
  rewriter with one `smooth_chain?` / chain decomposition fact.
- [ ] `report-pipeline-concurrent-op-plan`: reify concurrent op analysis in
  `analyze_concurrent_op`; it remains a top convergence hotspot with fat-union
  pressure.
- [ ] `report-pipeline-concurrent-select-each-options`: centralize
  `parallel=true` option parsing for bounded/stream select/each concurrent
  paths.
- [ ] `report-pipeline-select-family`: centralize `AST::SelectOp |
  AST::WhereOp` family handling across concurrent and non-concurrent pipeline
  analysis.
- [ ] `report-pipeline-substitute-placeholders`: fix stale `new_mc` derived
  from `new_target` after target rewrite in `PipelineHost#substitute_placeholders`.
- [ ] `report-pipeline-rewriter-recursive-body`: fix stale `skip_if` after
  `cond` changes in recursive pipeline rewriter.
- [ ] `report-formatter-block-token-set`: reify the formatter block-boundary
  token set (`END/FN/FOR/IF/START/TEST/WHEN/WHILE`) so every scanner consumes
  the same constant and neglected `START` cases cannot recur.
- [ ] `report-formatter-depth-zero-predicate`: centralize
  `bdepth.zero? && kdepth.zero?` style arm-boundary predicates.
- [ ] `report-formatter-match-body-clones`: resolve the Type-3 clone cluster
  around `emit_match_body` / `emit_fn_block` / wrapping helpers where `+` and
  `-` are drifted.
- [ ] `report-formatter-stale-index-derived-state`: audit and fix formatter
  stale-index findings (`needs_space?`, `find_s_chains`,
  `branch_end_for_inline_expansion`, `expand_concurrent_drops`,
  `capability_chain_colon?`, `find_fn_arrow`).
- [ ] `report-tools-doctor-heap-section`: fix `doctor#section_heap` stale
  `addrs` after `sites` changes and decide whether `line` metadata should be a
  typed task-site object.
- [ ] `report-tools-diagnostic-scan`: fix stale `j` after `i` changes in
  diagnostic example scanning.

### Tier 2: SlopCop Coverage / Audit Backlog

- [ ] `report-slopcop-type-norm-194`: burn down the remaining 194 `type_norm`
  dark arms by tightening source contracts; do not replace them with equivalent
  guards elsewhere.
- [ ] `report-slopcop-dead-74`: audit the remaining 74 dead arms and delete
  genuinely unreachable code or convert impossible paths to hard invariants.
- [ ] `report-slopcop-genuine-77`: after structural cleanup, add fuzz/unit
  coverage for the remaining 77 genuine gaps, prioritizing MIR lowering,
  `mir_lowering`, and `control_flow` entries in the SlopCop top table.
- [ ] `report-slopcop-ffi-21`: classify the 21 FFI dark arms as real external
  integration cases or dead/invariant cases; add integration coverage only for
  the real boundary behavior.
- [ ] `report-slopcop-diagnostic-243`: add negative tests only for diagnostic
  branches that correspond to user-facing compiler errors; otherwise mark as
  invariant or delete.

### Lower Priority / Probably Noisy

- [ ] `report-schema-kind-predicate-noise`: inspect schema predicates reported
  as exact aliases (`enum?`, `resource?`, `union?`, `struct?`). These may be
  legitimate sum-type query methods; only change if a typed schema kind object
  deletes real duplicated dispatch.
- [ ] `report-mir-stmt-expr-predicate-noise`: inspect `stmt?` / `expr?` exact
  alias noise. Do not refactor unless it removes a real MIR protocol burden.

## Acceptance Criteria

- New helper data is `T::Struct` or concrete typed methods, not hashes or
  positional arrays.
- No new storage, allocation, cleanup, or ownership decisions are introduced.
  Lowering may only consume facts from annotation, escape, cleanup
  classification, and pass state.
- No new `T.untyped` public seams unless the existing MIR node union forces it.
- `bundle exec srb tc` passes.
- Focused MIR/escape/ownership specs pass after each completed item.
- Full `bundle exec rspec spec` passes before commit.
