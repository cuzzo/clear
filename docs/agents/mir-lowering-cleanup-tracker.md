# MIR Lowering Cleanup Tracker

Goal: continue splitting MIR lowering by authoritative responsibilities, not by
metric appeasement. Each cleanup must make the code easier to reason about by
moving data to a typed boundary, reducing local re-derivation, or isolating a
lowering responsibility that already exists as a concept.

## Work Items

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
