# Architectural Goals

Branch focus: `architectural-review`.

This file records the current high-leverage goals from the architecture review.
The immediate target is not a broad rewrite of Annotator or MIR. The goal is to
remove the remaining loose FSM/thunk transformation boundaries that still make
memory-safety behavior hard to inspect.

## Current Assessment

- MIR has the best near-term payoff. The recent pipeline, MIR lowering, and FSM
  finalizer work already established a typed-plan pattern, so additional
  cleanup can be incremental.
- Annotator still has important issues, but most material improvements there are
  larger phase-state refactors: explicit phase contexts, fewer shared
  `SemanticAnnotator` fields, typed capability transitions, and tighter
  declaration/assignment plans.
- FSM/thunk transform code is the next focused area because it sits near
  memory-safety behavior and still has leftover hash/Struct records that hide
  protocol shape from Sorbet and review tooling.

## Immediate Goals

1. Replace loose FSM unified-emission context/spec hashes with typed records.
   The transform should build one typed `FsmEmitContext` and typed
   `FsmSegmentSpec` values, then pass those through dispatch assembly,
   structure extraction, lock expansion, and owned-result cleanup registration.

2. Replace loose thunk splitter plan records with typed records. Simple and
   mutual thunk detection should return typed base-case, recursive-combine, and
   mutual-tail facts instead of anonymous hashes and raw `Struct` records.

## Acceptance Criteria

- No new untyped helper APIs.
- New and changed functions must carry precise Sorbet signatures.
- Changed/new lines must be covered at 100%.
- Changed/new branches should be covered above 80%.
- Decomplex should be regenerated after the implementation. If a small metric
  increase comes from making previously hidden protocol state explicit, record it
  honestly instead of weakening the invariant.

## Deferred Larger Work

- Full Annotator phase-state extraction.
- Immutable or finalized `FunctionSignature`, `Type`, and `SymbolEntry`
  lifecycles.
- Typed stdlib/intrinsic contract records at the source table layer.
- Full thunk/FSM splitters converging on one shared typed segment-plan model.
