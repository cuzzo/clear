# MIR Lowering Cleanup Tracker

Goal: continue splitting MIR lowering by authoritative responsibilities, not by
metric appeasement. Each cleanup must make the code easier to reason about by
moving data to a typed boundary, reducing local re-derivation, or isolating a
lowering responsibility that already exists as a concept.

## Work Items

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
