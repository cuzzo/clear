# Review: Annotator Match and WITH Ownership

## Scope

This reviews the architecture pressure around annotator ownership/state flow in
`visit_MatchStatement`, `visit_WithBlock`, and capability helper paths.

Primary files:

- `src/annotator/annotator.rb`
- `src/annotator/helpers/capabilities.rb`
- `src/annotator/helpers/lock_helper.rb`
- `src/annotator/helpers/effects.rb`
- `src/annotator/helpers/union.rb`

## Evidence

Espalier reports:

- `SemanticAnnotator`
  - state slots: 39
  - functions: 206
- `SemanticAnnotator#visit_MatchStatement`
  - reads: 1
  - writes: 1
  - always-called methods: 38
  - conditionally-called methods: 72
- `SemanticAnnotator#visit_WithBlock`
  - reads: 5
  - writes: 5
  - always-called methods: 39
  - conditionally-called methods: 28
- `CapabilityHelper#validate_capability`
  - writes: 1
  - always-called methods: 4
  - conditionally-called methods: 18
- `CapabilityHelper#acquire_capability!`
  - always-called methods: 13
  - conditionally-called methods: 24
- `CapabilityHelper#declare_capability_scope!`
  - writes: 1
  - always-called methods: 6
  - conditionally-called methods: 40

`visit_MatchStatement` handles all of these in one visitor:

- subject typing
- enum/union classification
- generic union substitution
- MATCH TAKES ownership consumption
- branch analysis closures
- pattern typing
- multi-pattern validation
- payload binding
- indirect payload binding
- destructuring field declaration
- duplicate-pattern detection
- exhaustiveness diagnostics
- expression-result typing

`visit_WithBlock` handles all of these in one visitor:

- invalid WITH MATCH shape rejection
- capability expansion
- nested lock and rank checks
- blocking/suspension effect recording
- held-lock state push/pop
- snapshot transaction purity tracking
- scope declaration
- guard validation
- arm-specific effect consensus
- borrow release
- lock error clause validation
- runtime requirement stamping
- post-pass lock clause site recording

Important ambient annotator state involved in these paths includes:

- `@match_pattern_context`
- `@with_block_depth`
- `@held_locks`
- `@held_lock_types`
- `@inside_snapshot_txn`
- `@snapshot_txn_violations`
- `@deferred_with_validations`

## /plan

1. Split `visit_MatchStatement` by extracting pure-ish analysis objects:
   - `MatchSubjectFacts`
   - `MatchArmFacts`
   - `MatchPayloadBindingPlan`
2. Start with helper extraction for facts already computed inline:
   enum/union kind, generic substitution, variant names, payload type, and
   destructure field schema.
3. Replace `@match_pattern_context` toggling with a scoped helper such as
   `with_match_pattern_context { ... }` so state restore is guaranteed.
4. Split `visit_WithBlock` by extracting a `WithBlockFacts` or
   `WithCapabilityResolution` object from the capability hashes already being
   mutated.
5. Move held-lock push/pop into a scoped helper:
   `with_held_locks(expanded_capabilities, node) { ... }`.
6. Move snapshot transaction push/pop into a scoped helper:
   `with_snapshot_transaction_body(node) { ... }`.
7. Keep visitor behavior intact. The first goal is to make state lifetimes and
   facts explicit, not to change type-system rules.
8. Regenerate NilKill, Decomplex, SlopCop, and Boobytrap after each extraction.
   Revert any helper that adds branches without deleting real branch surface.

## Easy Path Assessment

There is an obvious easy path for state-lifetime cleanup. There is not an easy
path for fully simplifying MATCH and WITH semantics in one pass.

The best first step is scoped state helpers. They are small and directly attack
the fragile part of the current architecture: ambient state that must be
restored correctly.

The next step is fact objects for MATCH payload binding and WITH capability
resolution. Those are worthwhile only if they replace mutated hashes and inline
branch clusters rather than becoming parallel data structures.

## Downstream Payoff

Expected payoff is high for correctness and moderate for raw metrics:

- reduces risk of leaked annotator state after errors or future early returns
- gives MIR lowering better structured facts for MATCH/WITH
- makes capability validation less dependent on mutable hashes
- gives coverage tools clearer, smaller functions to rank
- improves diagnostics maintainability around variant payloads and lock/snapshot
  rules

This area is likely to find real bugs because it is where ownership, typing,
effects, and lowering contracts converge.

## Risk

Risk is moderate. The logic is user-facing and compiler-critical. Broad
rewrites would be risky, but scoped-state helpers and fact extraction can be
done incrementally.

## Recommendation

Do before v0.1 only in targeted form:

- add scoped state helpers for match-pattern context, held locks, and snapshot
  transaction state
- extract WITH capability resolution facts if they replace mutated hash logic
- defer a broader MATCH visitor split unless metrics or bugs justify it

