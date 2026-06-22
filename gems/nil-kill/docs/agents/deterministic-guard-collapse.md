# Deterministic Guard Collapse

## Goal

Nil-kill should identify conditions that look dynamic but are actually
deterministic under the known type/evidence contract, then rank the
highest-value fixes:

1. type the origin so many guards disappear,
2. replace/dead-code a provably constant predicate,
3. surface runtime-only dominance for review without pretending it is proof.

This is the nil-kill side of the "OverEngineeredCalculator" report: find
accidental state/control-flow branches whose outcome is already determined by
local facts, signatures, or runtime producer evidence.

## Existing Facts

Nil-kill already has most of the substrate:

- StaticAnalysis facts include `dead_nil_checks` for provably dead safe-navigation and
  `.nil?` checks.
- StaticAnalysis facts include `deterministic_guards` for `is_a?(Type)` / `kind_of?(Type)`
  guards and resolves the guarded receiver back to a canonical origin
  (`param`, `attr`, `ivar`, `hashkey`, `call`, or local fallback).
- `Report#guard_collapse_rows` joins those guards with runtime producer
  evidence and already reports "always Type: collapse, all guards die".
- Runtime collection records method return classes, param classes, ivar
  assignments, collection shapes, and collect coverage.

The missing piece is a first-class "deterministic guard" fact/action/report
surface that handles more than nil checks and makes proof strength explicit.

## Proof Tiers

Every finding must carry a `proof_tier`:

- `static_proven`: the predicate is deterministic from syntax plus current
  local/source facts. Example: `if tracking_id > 0` immediately after
  deterministic initialization/increment, or `if x.is_a?(String)` where `x`
  has a known non-union `String` type.
- `contract_proven`: the predicate is deterministic if one named origin
  contract is tightened. Example: every observed producer for `.type_info` is
  `Type`, so all `.type_info.is_a?(Type)` guards collapse after typing that
  origin.
- `observed_always`: runtime evidence saw only one predicate result, but the
  static contract does not prove it. This is high-value review material, not an
  automatic rewrite.
- `unsafe_to_rewrite`: the branch may be deterministic in one corpus but has
  dynamic state, callback, reflection, external IO, or insufficient coverage.

Only `static_proven` and verified `contract_proven` work should become
automatic changes. `observed_always` is report-only until a static proof or
verified loop confirms it.

## Scope

Initial implementation focuses on Ruby nil-kill targets and keeps the detector
source-local and branch-local:

- equality/inequality and numeric comparisons where both sides are literals,
- class guards: `is_a?`, `kind_of?`, `instance_of?`,
- nil predicates, with existing dead-nil paths continuing to handle the
  existing nil-check action surface,
- boolean literals.

It deliberately does not attempt whole-program symbolic execution, points-to,
safe-navigation rewrites, standalone predicate-call rewriting, or arbitrary
arithmetic. Those belong in future z3-backed extensions.

## Implementation Plan

1. Add `deterministic_guards` to `NilKill::Store#facts`.
2. Extend Tree-sitter fact mining:
   - collect deterministic guard facts from `if` / `unless` predicates,
   - trust only locals/params, ivars, and literal subjects for branch
     proof, not arbitrary call-return names,
   - include `path`, `line`, `method`, `class`, `code`, `predicate`,
     `truth_value`, `proof_tier`, `reason`, and canonical origin fields.
3. Extend `Infer#build_actions`:
   - emit `replace_deterministic_guard` review actions for `static_proven`
     branch predicates,
   - leave `contract_proven` aggregation to the report because the best fix is
     usually "type this origin", not "delete N guards one by one".
4. Extend `Report`:
   - add a "Deterministic Guard Collapse" section near Union Decomplexity,
   - summarize static facts and existing guard-collapse rows in one place,
   - rank by collapsible guard count, proof tier, and method/site count.
5. Extend `Apply` only after the report proves high value. The first pass
   should not rewrite arbitrary `if` bodies; it should surface and rank.
6. Tests:
   - StaticAnalysis records static deterministic class/nil/literal guards,
   - `Infer` converts static facts into review actions,
   - `Report` renders static and contract-proven collapse rows,
   - existing nil-kill specs continue to pass.

## Safety Rules

- Never delete an `else` or branch body from runtime-only evidence.
- Never treat collect coverage as proof of all possible paths.
- Prefer typing the origin over deleting guards when the same origin drives
  multiple guards.
- Any automatic rewrite must pass the existing nil-kill verified loop. If a
  rewrite cannot be locally proven and mechanically verified, it stays REVIEW.

## Expected High-Value Output

The report should surface rows like:

```text
- static_proven true at src/foo.rb:42 `x.is_a?(String)` -- `x` has static type String
- 17 guards collapse | `.type_info` across 9 methods -> always `Type`: type origin, delete normalizers
- observed_always true at src/bar.rb:88 `feature.enabled?` -- 284/284 observed true; review, not automated rewrite
```

This gives agents a ranked work queue: type or normalize the source of truth,
then remove the now-dead defensive decisions.
