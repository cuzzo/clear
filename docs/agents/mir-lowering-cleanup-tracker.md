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
- [ ] `decomplex-return-function-plans`: continue shrinking
  `lower_return` and `lower_function_def` by reifying implicit ownership,
  cleanup, catch/default, and result protocols into typed plans that delete
  local protocol reconstruction.
  Progress: return ownership planning is in place from the prior ownership
  work; the remaining hotspot is `lower_function_def` prologue/catch/default
  protocol construction.
- [ ] `decomplex-mir-hotspots`: audit the current convergence hotspots
  (`lower_next_expr`, `lower_do_block`, `lower_smooth`, hoist, escape analysis,
  cleanup classifier) and only change code where a typed fact/plan deletes a
  real duplicated decision.
  Progress: current metrics show the loop-scope and placement changes reduced
  Missing Abstractions, Neglected Conditions, Broken Protocols, and SlopCop
  genuine gaps. The remaining high-confidence targets are listed in the latest
  report notes.

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
