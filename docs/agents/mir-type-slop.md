# MIR Architecture and Type-Slop Assessment

## Decision

The MIR subsystem is substantially healthier than the parser and annotator. It
already has typed MIR node classes, explicit pass ordering, typed ownership and
placement facts, a CFG/dataflow ownership pass, and a fail-closed checker. The
architecture in `mir-architecture.md` and `mir-simplicity-completion-epic.md`
is the correct direction and should not be replaced.

It is not yet a good input for a literal, readable Ruby-to-CLEAR translation.
The main remaining obstacle is the Ruby implementation of the lowering host:
mixins repeatedly assert a giant implicit `MIRLowering` protocol, rescue the
assertion, and dynamically probe AST/MIR properties. A transpiler can reproduce
that behavior, but the result would contain artificial exception flow,
reflection, casts, and optional recovery that do not belong in the typed MIR
design.

Clean the host and phase contracts in Ruby, then regenerate. Do not manually
repair those patterns in generated CLEAR.

## Scope and Evidence

The assessment covered all 55 Ruby files under `compiler/ruby/mir` (44,707
lines). FactMine generated one normalized fact set consumed by Nil-kill,
Decomplex, and Espalier.

| Tool or source scan | Result after corrections | Meaning |
|---|---:|---|
| FactMine / Nil-kill | 523 owners, 2,626 methods, 39,966 calls, 415 structs | The corpus is large, but its named MIR domains and facts are visible to shared analysis. |
| Nil-kill | 0 dead-nil checks, 0 deterministic guards | Five real contract contradictions were corrected and two FactMine false positives were removed. |
| Decomplex | 1,096 convergence units, 399 root clusters, 159 decision-pressure findings | The ranking identifies real coordinator pressure; it is not evidence that every large lowering switch should be split. |
| Decomplex | 72 superfluous-state, 7 derived-state findings | Nearly all remaining findings are partial-corpus, lexical-binding, intentional snapshot, or counter-protocol limitations. |
| Espalier | 410 owners, 2,626 functions, 203 state slots, 23,116 delegation edges | MIR lowering is dominated by implicit host collaboration, not by an absence of domain types. |
| Espalier | 8,231 architecture nodes, 25,572 edges | `MIRLowering` remains the highest-pressure owner (score 1,143.15; 270 methods; fan-out 96). |
| Espalier | `PipelineHost`: 18 state slots, 12 components, fragmentation 0.71 | Pipeline lowering still concentrates several distinct state/collaboration roles. |
| Source scan | 375 `T.bind`, 375 `rescue nil`, 280 `respond_to?` | The implicit host and dynamic-property protocols are the largest translation-readiness problem. |
| Source scan | 239 `T.unsafe`, 296 `T.cast`, 252 `T.must`, 132 `T.untyped` | Escape hatches remain concentrated at AST annotation, ownership, cleanup, and host boundaries. |

Of the 375 bind/rescue sites, 307 are the exact expression
`T.bind(self, MIRLowering) rescue nil`. This is not meaningful compiler error
handling. It is a runtime-tolerated substitute for a declared mixin host
contract and would become especially poor CLEAR.

## Source Problems Corrected During This Pass

The following were narrow contract defects, not architectural refactors:

- `MIRLoweringGeneratedId`, `MIR::LoweredNodeId`, and `MIR::LoweredBodyId`
  declared equality arguments as their own class and then checked the class.
  Ruby equality methods accept arbitrary objects, so their `==` and `eql?`
  parameters now use the appropriately broad boundary type.
- `type_info_for` returns a concrete `Type`; two safe-navigation calls on that
  result were removed.
- `mir_cast` declares `from_type: Type`; its impossible fallback conversion was
  removed.
- `owned_sink_source_entry` returns a concrete `CleanupEntry`, including a
  typed `NONE` sentinel; three redundant safe-navigation calls were removed.
- `MIRPass#transform_body` declares an array; its impossible non-array return
  branch was removed.
- Two pass results assigned only to unexposed, unread instance variables were
  removed. `escape_placement_facts` was deliberately retained because it is an
  explicit typed pass-output API, even though a partial-corpus scan cannot see
  every consumer.

After these changes and the analyzer corrections below, the MIR corpus has no
known Nil-kill dead-nil or deterministic-guard findings.

## Confirmed Remaining Source-Contract Problems

### 1. The lowering mixins have an implicit universal host

Lowering modules use `T.bind(self, MIRLowering) rescue nil` inside individual
methods. The assertion is both too broad and too late: it says every helper may
depend on the whole 270-method host, and the rescue converts a type assertion
into production control flow.

Replace it with declared, typed host capabilities. Existing pipeline `Host`
interfaces show the intended direction. Capabilities should be grouped by real
needs such as type/schema lookup, binding/materialization, diagnostics,
ownership facts, and MIR construction. A module must not depend on the entire
lowerer merely because it needs three host operations.

If Sorbet cannot express a module constraint directly enough, pass an explicit
typed context object. Do not translate the rescued assertions.

### 2. Dynamic annotation probing loses phase guarantees

`respond_to?` and `T.unsafe` are used around `result_type`, `coerced_type`,
`stdlib_def`, ownership consumption, layout transport, source locations, heap
creation, and cleanup/transfer facts. Many of these values are legitimate, but
their existence should be guaranteed by the phase that produces them.

Follow the existing single-writer architecture:

- add a closed typed annotation or decision record for each ownership- or
  placement-significant family;
- stamp it in one phase;
- require it at the consuming boundary;
- hard-fail when a required fact is absent;
- keep reflection only in a narrow adapter for genuinely heterogeneous legacy
  AST nodes.

The source already documents post-annotation typing and typed ownership plans.
This is completion of that design, not a new IR rewrite.

### 3. `MIRLowering` is still an oversized coordinator surface

Espalier reports 270 methods, 103 public methods, and collaboration with 96
owners. `MIRLowering#lower` alone has 73 unconditional and 104 conditional
calls. Some breadth is intrinsic to closed AST dispatch, but public host
surface and semantic decision-making are mixed with mechanical node creation.

First extract capability interfaces and typed decisions. Only then split the
largest methods where resolution/analysis and MIR construction form distinct
boundaries. Moving branches into private helpers without changing their inputs
would not solve the translation problem.

### 4. Pipeline state is partitioned physically, not yet contractually

`PipelineHost` has 18 state slots spread over 12 cohesion components. The
existing specialized lowerers are useful, but several still reach through a
bridge or host for source shape, materialization, allocator, binding, and
terminal decisions.

Complete the typed pipeline source, terminal, allocator, and ownership facts in
the existing simplicity epic. Each specialized lowerer should consume a small
immutable plan plus an explicit emission context.

### 5. Some structural unions still flatten values and lists

Aliases such as `LoweredMir`, `NodeRoot`, `DeferBody`, and several FSM context
lists admit either one node or an array of nodes; some FSM lists also permit
nested arrays. These are not optional arrays, and no ordinary nilable-array
anti-pattern was found. They are nevertheless shape-erasing contracts that
force repeated flattening.

Prefer a named sequence/result type at boundaries that repeatedly normalize
one-or-many values. Retain a union only where the distinction itself is
semantic. The two nilable `SegmentStmt | Array[SegmentStmt]` parameters in the
recursive splitter need review as a three-state protocol, not a mechanical
"replace nil with empty" edit.

### 6. Generic tree walking remains dangerous near ownership decisions

FSM, thunk, cleanup, and lowering code still contains dynamic node/property
walks. The existing epic correctly distinguishes structural, lexical, and
ownership-significant traversal. Any walker that can affect allocation,
cleanup, transfer, capture, escape, or checker-visible facts must use a closed
typed traversal API. Emission-only walkers may remain only behind an explicit
fence that prevents them from creating ownership facts.

## Tool Defects Found and Corrected

### FactMine

- Local-flow extraction merged structural reads with a textual identifier
  scan. Identifiers mentioned only in comments became fake DFG dependencies.
  Text scanning is now a fallback only when the normalized tree supplies no
  structural reads. The low-level regression constructs language-neutral
  normalized nodes; it does not embed Ruby source.
- Safe-navigation call inference discarded the nil path after resolving the
  called method's concrete return type. A later call in the chain could then
  manufacture a false non-nil proof. `QCALL` results now retain nilability.
  The regression is a Ruby profile fixture plus Nil-kill oracle, so it covers
  parsing through final facts rather than testing an inline snippet.

No language-specific behavior was added to shared FactMine flow logic.

### Decomplex

The dead-state detector recognized same-named accessors on external receivers
but missed an accessor invoked on `self` by another method. Such a call now
prevents an unsound dead-state verdict; direct recursion is excluded. The test
uses normalized JSON facts and contains no language syntax.

### Nil-kill

The normalized schema-v2 analyzer generated runtime nullability actions but
dropped `dead_nil_checks` and `deterministic_guards` from `static.facts`, even
though the legacy action path supported them. It now emits schema-v2 actions
from those normalized facts, deduplicates them by stable action identity, and
resolves language from fact/file/evidence metadata. A Python JSON oracle proves
the implementation is language-neutral and that nil-check guards are not
double-reported through both fact families.

## Analyzer Capabilities Still Missing

### FactMine: lexical binding and place identity

The seven remaining derived-state findings expose a shared DFG limitation:
locals are compared by spelling rather than stable lexical binding/place ID.
The same block-parameter name in independent blocks can appear to be one value.
FactMine should assign stable binding identities in language adapters during
normalization and carry those IDs through shared local-flow/DFG facts. Shared
analysis must not learn Ruby block syntax.

### Decomplex: protocol-aware derived state

Once binding IDs exist, Decomplex should consume def-use identity instead of
bare names. It should also distinguish:

- snapshot-before-rename from a cached derived field;
- consume-current-then-increment counters from stale duplicated state;
- an accumulation side effect performed while constructing another result;
- unread-in-this-corpus from globally dead state.

These are graph/protocol distinctions, not Ruby variable-name heuristics. Some
counter/snapshot cases should remain review findings unless the proof is strong.

### Espalier: host-capability and phase matrices

Espalier should aggregate normalized capability calls and phase-fact writes /
reads. The useful output is a matrix showing which phase owns a fact, which
later phases consume it, and which modules bypass the intended boundary. This
would separate intrinsic MIR node fan-out from accidental universal-host
coupling.

### Nil-kill: optional collection state

Nil-kill should issue a cautious review action when a nilable collection is
initialized and consumed identically to an empty collection. It must preserve
nil when the source demonstrates a meaningful third state. This operates on a
normalized type and flow fact; it must not parse Sorbet spelling in Nil-kill.

## Recommended Cleanup Sequence

1. Replace rescued `T.bind(self, MIRLowering)` calls with declared capability
   interfaces or explicit typed contexts.
2. Finish post-annotation fact contracts and remove `respond_to?`/`T.unsafe`
   probes from ownership-, cleanup-, escape-, and placement-significant paths.
3. Complete the existing typed pipeline source/terminal/allocator plans and
   reduce `PipelineHost` state components.
4. Replace repeatedly normalized one-or-many unions with named sequence/result
   types; review the two genuinely three-state FSM inputs manually.
5. Close all ownership-significant traversal over registered node families.
6. Add FactMine lexical binding/place IDs, then rerun Decomplex before changing
   source based on the remaining derived-state list.
7. Split only those coordinator methods that still mix semantic decisions with
   mechanical MIR construction after their inputs are typed.

## Translation Readiness Criteria

MIR is ready for a readable Ruby-to-CLEAR attempt when:

- production lowering contains no rescued type-bind assertions;
- each lowering module declares a bounded host/context protocol;
- ownership-, placement-, cleanup-, escape-, and result-type facts are read
  through closed typed contracts rather than property probes;
- one-or-many result contracts are normalized at their producer boundary;
- ownership-significant walkers use registered typed traversal APIs;
- FactMine emits no known false nil-flow or comment-derived dependencies;
- Nil-kill static facts survive the normalized action pipeline;
- Sorbet, MIR unit/integration tests, message-pack stages, and Ruby-to-CLEAR
  generation pass before any manual CLEAR edits begin.

The subsystem does not need another wholesale typed-IR redesign. It needs the
Ruby implementation to consistently honor the typed MIR architecture it has
already adopted.
