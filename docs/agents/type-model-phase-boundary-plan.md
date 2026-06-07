# Type Model Phase Boundary Plan

This is the implementation record for
`3. The Type Model Is Too Loose At Phase Boundaries` in
`docs/agents/remaining-architectural-issues.md`.

## Objective

Stop allowing parser syntax, unresolved placeholders, resolved semantic types,
function signatures, ownership/storage overlays, and backend layout spellings to
travel through the same loose `Symbol | String | Type | nil` channels.

The end-state is not another compatibility wrapper. The end-state is that each
compiler phase receives the typed representation it is allowed to reason about:

- parser/type-syntax boundaries may normalize raw syntax into `Type`;
- annotation-owned AST declarations expose `Type` slots, with `nil` used only
  where absence is a real language state;
- scope bindings and function signatures expose concrete `Type` values;
- post-annotation consumers use concrete type facts and fail closed when facts
  are missing;
- backend/MIR code consumes resolved `Type` facts, not raw symbols or fallback
  sentinels.

## Baseline

Captured before implementation on commit `8fd972d8b`.

- Decomplex: `tmp/agent-metrics/type-model-boundary/decomplex-before.md`
- SlopCop: `tmp/agent-metrics/type-model-boundary/slopcop-before.md`
- Boobytrap: `tmp/agent-metrics/type-model-boundary/boobytrap-before.md`
- Nil-kill: `tmp/agent-metrics/type-model-boundary/nil-kill-before.md`

Key signals:

- Decomplex total candidates: `6063`
- Decomplex state-based branch density: `1575`
- Decomplex broken protocols: `463`
- Decomplex fat unions: `11`
- SlopCop genuine gaps: `1305`
- SlopCop dark arms: `3206`
- Boobytrap state-based branch hotspots: `1575`
- Nil-kill high-pressure contracts:
  - `.type`: `33` runtime collapses across `25` methods
  - `.return_type`: `14` runtime collapses across `11` methods
  - `full_type!`: `22` runtime collapses across `16` methods
  - `.element_type`: `5` runtime collapses
  - param `AST#type=`: runtime evidence always `Type`

## Acceptance Criteria

- [x] Run Decomplex after each implementation slice and compare to the
  baseline. Re-plan if the slice moves phase-boundary pressure sideways or up
  without deleting a real protocol.
- [x] Regenerate SlopCop and Boobytrap at the end.
- [x] Recollect nil-kill from scratch and regenerate its report at the end.
- [x] New functions are strongly typed, including inputs and returns.
- [x] Stronger boundary types are propagated to consumers, ivars, params, and
  returns where the receiving code no longer needs the old union.
- [x] New and changed lines have 100% coverage. Changed branches target 80% or
  better coverage.
- [x] Untyped slots stay flat or decrease in the final nil-kill report.

## Work Loop

1. Tighten one boundary owner.
2. Delete downstream guards/fallbacks made impossible by that boundary.
3. Add targeted tests for the owner and representative consumers.
4. Run Sorbet and focused specs.
5. Run Decomplex and compare.
6. Keep going until issue #3 no longer has loose phase-boundary work in this
   checklist.

## Implementation Checklist

### Slice 1: AST Parameter And Capture Type Slots

Status: complete.

- [x] Make `AST::Param#type` and `AST::Capture#type` expose non-nil `Type`.
- [x] Normalize missing direct-test construction to `Type.new(:Any)`, matching
  parser behavior.
- [x] Remove downstream `param.type || Type.new(:Any)`, `param.type&.`, and
  equivalent `p.type` fallback branches.
- [x] Add tests for nil construction, symbol/string construction, Type
  construction, setter behavior, and downstream signature/annotation copies.

### Slice 2: Function Return Boundary

Status: complete.

- [x] Keep `AST::FunctionDef#return_type` nilable only for the real language
  state: omitted `RETURNS`.
- [x] Introduce explicit helpers for declared-or-default return type instead
  of repeating `return_type || Type.new(:Any)` / `|| :Void` at consumers.
- [x] Tighten `FunctionSignature` and `FunctionContext` construction so their
  public return type is always concrete `Type`.
- [x] Remove call-site `return_type.is_a?(Type)` checks that are no longer
  reachable.

### Slice 3: Scope Binding Type Boundary

Status: complete.

- [x] Tighten `Scope#declare` and `SymbolEntry` initialization so binding type
  input is explicit and scope readers always receive `Type`.
- [x] Replace `Scope#resolve_type` raw symbol fallback with a concrete `Type`
  reader, or split the raw-name query into a separate API with a precise name.
- [x] Remove consumers that call `Type.new(entry.type)` defensively.

### Slice 4: Schema And Field Type Boundary

Status: complete.

- [x] Make struct/union schema fields carry concrete `Type` values after
  registration.
- [x] Delete repeated `field.type.is_a?(Type) ? field.type : Type.new(...)`
  branches in annotation, cleanup, and type sizing.
- [x] Add guardrail tests so new schema field metadata cannot regress to raw
  symbols or nil.

### Slice 5: Post-Annotation Type Fact Consumers

Status: complete.

- [x] Audit remaining `Type.from_node`, `is_a?(Type)`, and `Type.new(x || ...)`
  sites under annotator/MIR/backend consumers.
- [x] Keep normalization only at raw syntax/metadata producers.
- [x] Convert consumers to concrete `Type` facts or explicit typed result
  objects.

### Slice 6: Stable Type Identity

Status: complete.

- [x] Add a stable type identity API to `Type` that names the semantic type
  without using raw parser payloads.
- [x] Migrate memory-safety consumers that only need identity away from raw
  `resolved` symbols when they are using that symbol as a phase boundary.
- [x] Keep Zig spelling and backend layout concerns outside the identity API.

## Implemented Boundary Changes

- `AST::Param#type`, `AST::Capture#type`, and `AST::StructField#type` now expose
  concrete `Type` values, with direct-test nil construction normalized at the
  AST boundary.
- Function return handling now distinguishes omitted source annotations from
  annotation-default and MIR-lowering defaults through explicit helper APIs.
- `FunctionSignature`, `FunctionContext`, `Scope`, and `SymbolEntry` now carry
  concrete type facts instead of rediscovering `Type | Symbol | String | nil`
  at consumers.
- Schema registration normalizes struct, union, and inline variant payload
  fields into typed AST records before downstream annotation, cleanup, and MIR
  consumers see them.
- Post-annotation type stamping fails closed at the boundary and preserves
  already-resolved `Type` identity.
- `TypeId` gives ownership and cleanup consumers a stable semantic identity
  without relying on raw parser payloads or backend Zig spellings.

## Metric Diff

Fast repo-wide reports after implementation:

| metric | before | after | diff |
| --- | ---: | ---: | ---: |
| Decomplex total | 6063 | 6046 | -17 |
| Decomplex broken protocols | 463 | 458 | -5 |
| Decomplex missing abstractions | 192 | 189 | -3 |
| Decomplex neglected path conditions | 1583 | 1575 | -8 |
| Decomplex state-based branch density | 1575 | 1574 | -1 |
| SlopCop dark arms | 3206 | 3143 | -63 |
| SlopCop type-normalization arms | 934 | 888 | -46 |
| SlopCop diagnostic arms | 769 | 757 | -12 |
| SlopCop genuine gaps | 1305 | 1319 | +14 |
| Boobytrap state-based branch hotspots | 1575 | 1574 | -1 |
| Nil-kill nil source fixes | 196 | 192 | -4 |
| Nil-kill union / `T.any` candidates | 545 | 540 | -5 |
| Nil-kill `.type` guard collapses | 33 | 28 | -5 |
| Nil-kill `.return_type` guard collapses | 14 | 7 | -7 |
| Nil-kill `full_type!()` guard collapses | 22 | 21 | -1 |
| Nil-kill `.element_type` guard collapses | 5 | 0 | -5 |
| Nil-kill param untyped slots | 885 | 877 | -8 |
| Nil-kill return untyped slots | 208 | 202 | -6 |
| Nil-kill field/ivar untyped slots | 858 | 847 | -11 |
| Nil-kill collection untyped slots | 0 | 0 | 0 |

SlopCop genuine gaps rose by `+14` while dark arms fell by `-63` and
type-normalization arms fell by `-46`. That is an acceptable repo-wide category
migration for this issue: the refactor moved some previously
type-normalization-shaped dark arms into ordinary testable behavior while
deleting loose boundary pressure. The post-status guardrail cleanup adds `0`
SlopCop genuine gaps on its changed source lines.

## Verification

- `bundle exec rspec --format progress`
  - `5557 examples, 0 failures`
  - line coverage `99.39% (46064 / 46347)`
  - branch coverage `85.09% (18208 / 21399)`
- `bundle exec srb tc`
  - no errors
- `bundle exec ruby tools/diff_bucket_summary.rb origin/master --format markdown`
  - `src/**/*.rb` changed-line coverage: `100.0%`
  - `src/**/*.rb` changed-branch coverage: `86.2%`
  - no added `src/**/*.rb` type guardrail findings
  - no added production Zig lines require missing Loom/VOPR/wait-loop alerts
- `ruby gems/slopcop/exe/slopcop report --output=tmp/agent-metrics/type-model-boundary/slopcop-after-guardrail-fix.md`
  - `3143` dark arms; `1319` genuine gaps
  - current guardrail cleanup changed-line genuine gaps: `0`
- `NIL_KILL_TARGETS=src NK_JOBS=8 bundle exec tools/nil-kill collect -- bash tools/clear-nil-kill-runtime.sh`
  - fresh runtime recollection completed in `1333s`
- `NIL_KILL_TARGETS=src bundle exec tools/nil-kill infer`
  - completed with `0` captured Sorbet errors in the resulting report
- `NIL_KILL_TARGETS=src bundle exec tools/nil-kill report --output-path=tmp/agent-metrics/type-model-boundary/nil-kill-after.md`
  - final nil-kill report generated

## Completion Notes

Issue #3 is implemented. Remaining type looseness reported by nil-kill is now
outside this issue's phase-boundary scope and should be triaged under the
hash-record, ownership-fact, and branch-hub issues.
