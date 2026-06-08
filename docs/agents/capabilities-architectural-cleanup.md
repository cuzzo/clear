# Capabilities Architectural Cleanup Plan

Branch focus: `architectural-review`.

This plan targets the remaining capability architecture problem identified in
the architectural review:

- `src/annotator/helpers/capabilities.rb` still mixes validation, alias
  construction, predicate purity, audit, lock facts, and type/symbol mutation.
- `src/mir/lowering/capabilities.rb` still consumes a mix of annotated facts,
  raw `AST::Capability`, hash-shaped compatibility data, and local
  sync/storage/layout rediscovery.
- Capability semantics are memory-safety semantics. They decide lock behavior,
  snapshot behavior, atomic access, borrow/restrict aliasing, capture safety,
  and cleanup obligations. They need one owner.

The desired end-state is not a second compatibility layer. The desired
end-state is:

```text
AST::Capability
  -> CapabilityRequest
  -> CapabilityTargetFact
  -> CapabilityTransition
  -> WithCapabilityPlan
  -> MIR lowering / checker / backend
```

Annotation owns source-language capability validation and fact production. MIR
lowering consumes checked facts. MIR lowering must not rediscover source
capability semantics from raw AST shape, stale symbols, or repeated
sync/storage/layout checks.

## Final Implementation Status

Status: implemented for the architectural boundary.

The migration now has one typed capability authority:

- raw `AST::Capability` values are converted into `CapabilityRequest`;
- source target resolution is captured as `CapabilityTargetFact`;
- validated/deferred capability semantics are represented as
  `CapabilityTransition`;
- each `WITH` block carries a `WithCapabilityPlan`;
- MIR capability lowering consumes plan/fact data instead of raw capability
  hashes or local sync/storage/layout rediscovery;
- deferred capability validation stores typed transition facts;
- production guardrails reject raw MIR capability semantic consumers and stale
  private-function-registry reach-ins.

The metric result needed one correction pass after the initial implementation.
The original final snapshot compared against a stale SlopCop coverage shape and
also missed an untracked new source file in the changed-line coverage bucket.
That was a real measurement bug. The follow-up pass:

- covered every line and branch in `src/semantic/capability_plan.rb`;
- fixed Decomplex state-branch-density false positives for immutable Sorbet
  structs/facts;
- regenerated SlopCop and Boobytrap from a fresh full coverage resultset;
- verified changed/untracked `src` coverage directly, including the new file.

The core architectural risk was removed: MIR no longer re-derives capability
meaning from source-shape fragments. The current source delta is not a large
source-code expansion for this slice: tracked `src` is `+265/-479` and the new
typed `src/semantic/capability_plan.rb` file is 349 lines, for a net `src`
movement of roughly +135 lines before staging.

Final validation artifacts:

- Decomplex: `tmp/capabilities-arch-cleanup/decomplex-after-final-slopfix.md`
- Decomplex delta: `tmp/capabilities-arch-cleanup/decomplex-delta-after-final-slopfix.md`
- SlopCop: `tmp/capabilities-arch-cleanup/slopcop-after-slopfix.md`
- Boobytrap: `tmp/capabilities-arch-cleanup/boobytrap-after-slopfix-src.md`
- Nil-Kill: `tmp/capabilities-arch-cleanup/nil-kill-final.md`
- Full Ruby coverage: `tmp/capabilities-arch-cleanup/coverage-after-slopfix/.resultset.json`

Final Decomplex delta from the pre-capability-cleanup snapshot:

| Metric | Before | After | Delta |
|---|---:|---:|---:|
| Total findings | 5927 | 5859 | -68 |
| Cross-detector convergence | 1802 | 1786 | -16 |
| Root-cause clusters | 476 | 478 | +2 |
| Decision pressure | 284 | 283 | -1 |
| State heatmap | 576 | 577 | +1 |
| State-based branch density | 1619 | 1616 | -3 |
| Temporal ordering pressure | 14 | 14 | 0 |
| Missing abstractions | 187 | 187 | 0 |
| Reification misses | 6 | 6 | 0 |
| Semantic predicate aliases | 5 | 5 | 0 |
| Exact predicate aliases | 15 | 15 | 0 |
| Inconsistent rename clones | 71 | 71 | 0 |
| Flay similarity | 50 | 0 | -50 |
| Neglected updates | 657 | 658 | +1 |
| Derived-state staleness | 140 | 139 | -1 |
| Neglected conditions | 10 | 10 | 0 |
| Neglected path conditions | 1444 | 1432 | -12 |
| Oversized predicates | 9 | 9 | 0 |
| Broken protocols | 398 | 392 | -6 |
| False simplicity | 1007 | 1011 | +4 |
| Fat unions | 11 | 11 | 0 |

Final Nil-Kill type-soundness delta from the pre-capability-cleanup snapshot:

| Slot category | Total | Strong | Weak | Untyped | Nilable |
|---|---:|---:|---:|---:|---:|
| Param inputs | +2 | +5 | -1 | -2 | +3 |
| Returns | +14 | +15 | 0 | -1 | +1 |
| Struct/class fields & ivars | 0 | -1 | 0 | +1 | 0 |
| Arrays/Sets/Hashmaps | 0 | +1 | -1 | 0 | -1 |

Final SlopCop and Boobytrap movement:

- SlopCop against the original stale snapshot: dark arms 2844 -> 3029 (+185),
  genuine gaps 1080 -> 1304 (+224). This is not caused by uncovered new
  capability code: the new capability-plan file is 100% line/branch covered,
  and changed/untracked `src` lines are 100% covered. The increase is a
  repo-wide aggregate coverage-shape/category shift across existing MIR and
  annotator files.
- SlopCop against a clean HEAD worktree with the same fresh full coverage
  procedure: dark arms 3049 -> 3029 (-20), genuine gaps 1308 -> 1304 (-4).
- Boobytrap mostly uncovered methods: 0 -> 0 (0)
- Boobytrap state-based branch hotspots: 1619 -> 1616 (-3)
- Boobytrap fixed-but-unmeasured: 5 -> 5 (0)

Coverage and typing acceptance checks:

- `bundle exec srb tc`: pass
- focused capability/MIR/architecture specs: pass
- stack-check integration spec: pass
- full non-integration coverage run: `5615 examples, 0 failures`
- full non-integration coverage: 99.43% line, 85.51% branch
- changed/untracked `src` executable lines: 420/420, 100.0%
- changed/untracked `src` branch arms: 120/130, 92.3%
- `src/semantic/capability_plan.rb`: 100% line coverage, 100% branch coverage

## Current Problem

Capability logic grew incrementally across several phase boundaries:

- `Type` and `SymbolEntry` carry storage, sync, layout, ownership, and
  observable facts.
- `AST::Capability` carries parsed source intent.
- `CapabilityHelper` validates source intent, builds aliases, records
  predicate contexts, records audit facts, and updates lock/deferred validation
  state.
- Effects and lock helpers consume partial capability information.
- MIR capability lowering sometimes consumes stamped facts and sometimes
  reconstructs capability meaning from `AST::Capability`, symbol state, type
  state, or compatibility hashes.

That creates semantic drift pressure. If annotation and MIR disagree about the
meaning of `WITH EXCLUSIVE`, `WITH SNAPSHOT`, `WITH BORROWED`, or field-level
capabilities, the compiler can reject valid code or emit unsafe code.

## Non-Goals

- Do not redesign the user-facing capability syntax.
- Do not introduce a parallel compatibility path.
- Do not move backend emission into annotation.
- Do not make MIR validate source-language capability rules.
- Do not remove all capability branches by hiding them in a generic bag.
- Do not force unrelated ownership graph cleanup into this pass.

## Acceptance Criteria

- Decomplex should improve decisively in capability-related protocol and state
  pressure, or the slice must be reassessed before continuing.
- SlopCop genuine gaps for capability files should drop or stay flat.
- Boobytrap state-based branch hotspots should drop or stay flat.
- Nil-Kill untyped slots must stay flat or decrease.
- New code and changed code must be strongly typed.
- New/changed executable lines must have 100% coverage.
- New/changed branches should have at least 80% coverage.
- MIR capability lowering must not consume raw `AST::Capability` arrays or
  hash-shaped capability specs in production paths after the migration slice
  that replaces them.
- No dual path: delete old rediscovery logic before rebuilding each replacement
  path, then make tests fail red and pass green.

## Baseline To Capture Before Implementation

Before code changes, capture:

- Decomplex full `src` report.
- Decomplex focused report for:
  - `src/annotator/helpers/capabilities.rb`
  - `src/annotator/domains/execution_boundaries.rb`
  - `src/annotator/helpers/effects.rb`
  - `src/annotator/helpers/lock_helper.rb`
  - `src/mir/lowering/capabilities.rb`
  - `src/mir/lowering/concurrency.rb`
- SlopCop full repo report using the default coverage baseline.
- Boobytrap full `src` report.
- Nil-Kill full `src` report after a fresh collect.
- Current raw capability consumer inventory:
  - `AST::Capability`
  - `T::Hash[Symbol, ...]` capability specs
  - direct `cap[:capability]`, `cap[:var_node]`, `cap[:alias]`,
    `cap[:guard_expr]`, `cap[:on_clauses]`, and related hash reads.

## Target Types

### `CapabilityRequest`

Parsed source intent, with no semantic target interpretation.

Fields:

- source `AST::Capability`
- kind
- target node
- requested alias
- alias mutability
- guard expression
- fallible clauses
- source span/token metadata

Purpose:

- isolate raw AST/hash reads at the parser-to-annotation boundary;
- give the rest of annotation a typed request object.

### `CapabilityTargetFact`

Resolved target identity and target properties.

Fields:

- target kind: local, param, field, index-borrow target
- stable target name
- symbol entry, if any
- field owner/path, if any
- source type
- sync
- storage
- layout
- ownership
- observable/future state
- capture/live-symbol override status

Purpose:

- replace repeated `cap_var_sync`, `cap_var_storage`, `cap_var_layout`, and
  MIR-side `with_cap_sync_storage` rediscovery;
- make stale-symbol handling explicit before lowering.

### `CapabilityTransition`

Validated source-language transition from request + target.

Fields:

- request
- target
- result: accepted, rejected, deferred
- capability family: lock, restrict, borrowed, snapshot, view, ownership clone,
  atomic
- alias shape
- required sync/storage/layout
- diagnostic/fix metadata for rejected transitions
- deferred validation reason, if param sync has not propagated
- effect contribution: suspends, can fail, mutates, pure guard requirement

Purpose:

- make validation a typed result, not a chain of ad hoc branch side effects;
- centralize user-facing capability rule decisions.

### `WithCapabilityPlan`

Final immutable plan consumed by MIR.

Fields:

- all accepted transitions
- alias declarations
- lock acquisition facts
- lock release/cleanup facts
- fallible lock clause facts
- snapshot transaction facts
- atomic pointer snapshot facts
- RC unwrap facts
- borrowed/restrict alias facts
- guard predicate facts
- MIR lowering names/materialization hints

Purpose:

- make MIR lowering a mechanical consumer;
- delete raw capability semantic rediscovery from
  `MIRLoweringCapabilities#lower_with_block`.

## Implementation Slices

### Slice 1: Inventory And Guardrails

Status: implemented.

Tasks:

1. Add a lightweight architecture invariant spec that lists sanctioned raw
   `AST::Capability` consumers.
2. Add a failing guardrail for production MIR lowering reading raw capability
   hashes or raw `AST::Capability` arrays as semantic authority.
3. Inventory current raw readers and classify them:
   - parser/AST boundary: allowed temporarily;
   - annotation request builder: allowed;
   - validation/fact builder: allowed only through typed request/target;
   - MIR lowering/checker/backend: should become forbidden.

Expected result:

- No behavior change yet.
- Clear red tests identifying the migration boundary.

### Slice 2: Build `CapabilityRequest`

Status: implemented.

Tasks:

1. Introduce typed `CapabilityRequest`.
2. Add a request builder that converts `AST::Capability` into request objects.
3. Replace capability helper loops that read raw `cap[:...]` values with
   request accessors.
4. Keep raw `AST::Capability` only at the builder boundary.
5. Add request-builder tests for:
   - identifier targets;
   - field targets;
   - index borrow targets;
   - alias/no alias;
   - mutable alias;
   - guard expression;
   - fallible clauses;
   - source token/span preservation.

Red/green rule:

- First make validation paths require `CapabilityRequest`; existing raw-cap
  call sites should fail.
- Then update call sites.

Expected metric movement:

- Nil-Kill hash-record pressure down or flat.
- Decomplex broken protocols down or flat.
- No state heatmap increase.

### Slice 3: Build `CapabilityTargetFact`

Status: implemented.

Tasks:

1. Introduce typed `CapabilityTargetFact`.
2. Move target resolution into one builder:
   - identifier target;
   - field target;
   - index target for `BORROWED`;
   - live captured symbol override for BG/DO/CONCURRENT contexts.
3. Replace `cap_var_sync`, `cap_var_storage`, and `cap_var_layout` with target
   fact reads in annotation.
4. Replace MIR-side target rediscovery where possible with fact reads.
5. Add tests for stale-symbol scenarios, especially capability use inside
   fiber-like callbacks where live capture symbols are authoritative.

Red/green rule:

- Delete or demote direct target rediscovery helpers before replacing their
  call sites.

Expected metric movement:

- Decomplex state heatmap down in annotator capability helpers and MIR
  capability lowering.
- Boobytrap state-based branch hotspots down or flat.
- Fewer repeated sync/storage/layout decisions.

### Slice 4: Build `CapabilityTransition`

Status: implemented.

Tasks:

1. Introduce typed transition result objects.
2. Move validation branches from `validate_capability` into transition
   construction.
3. Make rejected/deferred transitions explicit data:
   - diagnostic key;
   - fix candidates;
   - deferred validation reason;
   - required target facts.
4. Keep `error!` / `fixable!` emission as a consumer of rejected transitions,
   not as the primary validation control flow.
5. Add tests for every capability family:
   - `EXCLUSIVE`;
   - `write_locked_read`;
   - `RESTRICT`;
   - `BORROWED`;
   - `VIEW`;
   - `MATERIALIZED_VIEW`;
   - `SNAPSHOT`;
   - `multiowned`;
   - `shared`;
   - `ATOMIC`;
   - unknown capability.

Red/green rule:

- Make `validate_capability` delegate to transition construction and remove
  family-specific behavior from it before adding compatibility wrappers.

Expected metric movement:

- Decomplex decision pressure and false simplicity should improve or stay
  flat.
- SlopCop genuine gaps should fall because transition builder tests can cover
  family cases without full lowering tests.

### Slice 5: Build `WithCapabilityPlan`

Status: implemented.

Tasks:

1. Introduce typed `WithCapabilityPlan`.
2. Build the plan from accepted/deferred transitions after validation.
3. Move alias declarations, lock-only views, fallible clause facts, snapshot
   facts, atomic pointer facts, and RC unwrap facts into the plan.
4. Update held-lock, lock-cycle, effect, deferred validation, predicate, and
   audit consumers to consume the plan.
5. Keep mutation boundaries explicit:
   - annotation may still declare alias symbols at one controlled point;
   - downstream consumers read the plan.

Red/green rule:

- Delete the old `WithCapabilityExpansion` consumers as each plan consumer
  lands. Do not keep expansion and plan as parallel semantic authorities.

Expected metric movement:

- Broken protocols down.
- State heatmap down.
- Nil-Kill untyped/weak slots down or flat.

### Slice 6: MIR Consumes Plan Only

Status: implemented.

Tasks:

1. Replace MIR lowering capability inputs with `WithCapabilityPlan`.
2. Delete `CapabilitySpec` and hash-shaped capability semantic paths from
   production MIR lowering.
3. Replace `with_capability_specs`, `with_capability_binding_context`, and
   related raw-cap readers with plan consumers.
4. Keep backend emission mechanical:
   - emit lock acquire/release from lock facts;
   - emit snapshot transaction from snapshot facts;
   - emit alias/unwrap from alias facts;
   - emit fallible lock actions from fallible clause facts.
5. Add representative MIR/golden tests:
   - exclusive lock with release;
   - sorted multi-lock acquire;
   - fallible lock with retry and fallback;
   - snapshot read;
   - mutable snapshot transaction;
   - atomic pointer snapshot;
   - borrowed alias;
   - restrict alias;
   - field target;
   - captured target inside BG/DO/CONCURRENT.

Red/green rule:

- Guardrail should fail until MIR no longer consumes raw capability specs.
- Delete old helper paths before final green.

Expected metric movement:

- Decomplex broken protocols and state-based branch density down in
  `src/mir/lowering/capabilities.rb`.
- SlopCop genuine gaps down in MIR capability lowering.

### Slice 7: Audit And Diagnostics Become Consumers

Status: implemented.

Tasks:

1. Make capability audit consume transition/plan facts.
2. Make diagnostic fix generation consume rejected transition data rather than
   recomputing source facts.
3. Remove remaining capability audit hash/field compatibility records where
   possible.
4. Add tests for over-engineering warnings:
   - `@local` never shared;
   - `@shared` never crosses scheduler/core;
   - locked but never mutated;
   - versioned/atomic capability mismatch;
   - guard alias misuse.

Expected metric movement:

- Nil-Kill hash-record pressure down or flat.
- Decomplex neglected updates down or flat.

### Slice 8: Final Guardrails And Metrics

Status: implemented.

Tasks:

1. Run full focused and broad tests:
   - Sorbet;
   - capability specs;
   - WITH specs;
   - concurrency/BG specs;
   - MIR lowering specs;
   - relevant integration/golden tests.
2. Run changed-line and branch coverage audits.
3. Regenerate:
   - Decomplex full repo;
   - SlopCop;
   - Boobytrap;
   - Nil-Kill fresh collect/infer/report.
4. Update this doc with final deltas.
5. Update `docs/agents/architectural-review.md` and
   `docs/agents/remaining-architectural-issues.md` if the rating/status
   changes.

## Correctness Invariants

After this cleanup:

- Every source capability has exactly one `CapabilityRequest`.
- Every target-dependent rule consumes exactly one `CapabilityTargetFact`.
- Every source-language capability decision is represented by a
  `CapabilityTransition`.
- Every `WITH` block has one `WithCapabilityPlan` before MIR lowering.
- Production MIR lowering does not read raw `AST::Capability` semantic fields.
- Production MIR lowering does not infer sync/storage/layout from stale
  symbols when a target fact exists.
- Lock, snapshot, atomic, borrowed, restrict, view, and alias behavior are all
  plan facts, not rediscovered branches.

## Why This Is Worth Doing

Capabilities are the language's memory-safety and synchronization contract.
They are not local style metadata.

The current system mostly works, but it requires too many files to agree by
convention. That is the exact shape that creates expensive bugs:

- annotation validates one fact;
- lowering re-derives a slightly different fact;
- tests cover the common path;
- a BG/capture/field/param/snapshot edge case escapes.

Typed capability facts make the compiler easier to reason about because each
phase has one job:

- parser records syntax;
- annotator validates source intent and builds facts;
- semantic phases enrich facts;
- MIR lowering emits from facts;
- MIR checker validates final memory-safety behavior;
- backend emits checked operations.

The payoff should be lower branch density, fewer broken protocol warnings,
lower SlopCop gap pressure, and most importantly a smaller chance that a
capability bug becomes a memory-safety bug.
