# Annotator Architecture and Type-Slop Assessment

## Decision

The annotator is in materially better shape than the parser for staged
translation: it already has named domains, phase objects, schema objects, and
several typed result records. It is not yet a good candidate for literal
Ruby-to-CLEAR translation, however. Its remaining problem is less "one giant
file" than a broad implicit host protocol shared by 45 files. Mixins mutate a
`SemanticAnnotator`, AST nodes are progressively stamped through dynamic
properties, and several large helpers combine resolution, validation,
diagnostics, and source rewriting.

Do not flatten these modules back into the façade and do not repair generated
CLEAR. Tighten the Ruby contracts and make phase inputs/outputs explicit first.
This assessment does not modify annotator source.

## Scope and Evidence

The run included `compiler/ruby/annotator/annotator.rb` and all 44 Ruby files in
`annotator/domains`, `annotator/helpers`, and `annotator/phases` (24,869 lines).
FactMine supplied the normalized facts used by all three consumers.

| Tool | Result after fact corrections | Meaning |
|---|---:|---|
| FactMine / Nil-kill | 45 files, 153 owners, 1,112 methods, 1,082 signatures, 20,117 calls | The subsystem boundary is large enough that method counts, state ownership, and call pressure must be reviewed by owner/phase, not file size alone. |
| Nil-kill | 3 dead-nil sites and 2 deterministic guards | Four unique source contracts require review; false facts found during the run were removed first. |
| Decomplex | 708 cross-detector convergence units, 280 root clusters, 119 decision-pressure findings | Useful ranking, but the volume is not a mandate to split every visitor. |
| Decomplex | 557 state-based branch units, 25 missing abstractions, 4 temporal-ordering owners | Type/ownership state drives much of the control flow. |
| Decomplex | superfluous-state candidates reduced from 51 to 15 after correcting external-accessor evidence | The original list substantially overstated dead state and was not trustworthy. |
| Decomplex | derived-state findings reduced from 14 to 0 after recognizing save/mutate/restore and normalization guards | The original findings were scoped-state protocols, not stale caches. |
| Espalier | 66 projected modules/classes, 1,112 functions, 75 state slots, 11,631 delegation edges | Delegation pressure, rather than raw instance-state count, is the dominant architectural issue. |
| Espalier | 4,170 architecture nodes and 13,315 edges | Corrected owner names contain no duplicated module prefixes. |

Raw Sorbet escape-hatch counts provide supporting pressure, not verdicts: 58
`T.untyped`, 137 `T.unsafe`, 93 `T.cast`, 218 `T.must`, 99 type aliases,
and 124 `T.any` occurrences. Many are justified at AST or reflection
boundaries; concentration and propagation matter more than the total.

## Confirmed Source-Contract Problems

### 1. Four guards disagree with declared contracts

Nil-kill identifies these source issues after correcting FactMine flow:

- `validate_destructure_target_type!` declares `target_type:
  Type::TypeInput`, which cannot be nil, then immediately checks
  `target_type.nil?`. Its caller supplies `Scope#resolve_type`, which returns a
  concrete `Type` even for an unknown name. The guard is dead under the current
  contract.
- `GenericAnalysis#apply_type_subst` declares `type_obj: Type::TypeInput`, then
  returns `Any` for nil. Either nil is an intentional input and the signature is
  wrong, or the branch is legacy. Call-site review should decide; the current
  contract cannot express both claims.
- `emit_auto_shape_resolved_finding!` proves `decl` is a `VarDecl` or
  `BindExpr`, then uses `decl&.type`. The safe navigation is redundant.
- `AutoSlotId#eql?` declares `other: AutoSlotId` and then checks
  `other.is_a?(AutoSlotId)`. Ruby equality protocols receive arbitrary objects,
  so the check is appropriate and the signature is too narrow.

These are Ruby cleanup tasks. They are not CLEAR autofix problems and should not
be hidden by generated casts.

### 2. Mixins depend on an implicit, dynamic host interface

Domain and helper modules repeatedly use `T.bind(self, SemanticAnnotator)`,
`T.unsafe(self).__send__`, `respond_to?`, and occasional `rescue nil` around
typing helpers. This means each module's real dependencies are neither its
parameters nor a declared interface; they are the full mutable annotator host.

Define small typed host capabilities (scope access, type stamping, diagnostics,
ownership, registry lookup) or pass an explicit phase context. A module should
depend only on the capabilities it calls. Decomplex and Espalier can then measure
real collaborations instead of a universal host edge.

### 3. `SemanticAnnotator` remains a lifecycle-heavy service locator

Espalier ranks `SemanticAnnotator` highest for encapsulation pressure (167.04):
36 public methods, 11 state slots, and a broad stateful fan-out. Its
`receiver_state` alone has 36 readers and 2 writers. The existing phase split is
the right direction, but phases still reach back through the host for mutable
registries, scopes, ownership state, diagnostics, and current-function context.

Move phase-owned data into explicit input/output records. Keep the façade as the
orchestrator that advances phases; do not make it the mutable API every helper
can query.

### 4. Three helpers are overloaded coordinators

Espalier ranks `PipeAnalysis` (score 439.35, 76 methods), `FixableHelper`
(354.90, 66 methods), and `FunctionAnalysis` (342.50, 54 methods) as the largest
delegation owners.

- Split `PipeAnalysis` by operation family and share a typed pipeline context.
  Windowing, terminal reductions, collection transforms, and concurrent/sharded
  validation should not share one undifferentiated helper surface.
- Split `FunctionAnalysis#resolve_call` into target resolution, argument
  verification/coercion, capability/effect validation, and result stamping.
  It is the top Decomplex convergence method (6 detectors, 110 findings).
- Split `FixableHelper` into diagnostic construction, source-location/edit
  construction, and domain-specific fix policies. A diagnostic emitter should
  not need the whole source-rewrite toolkit.

### 5. Visitor methods combine coordination and semantic mutation

The strongest Espalier coordinator/mutator candidates are
`visit_StructLit`, `visit_FunctionDef`, `finalize_decl_node!`,
`visit_WithBlock`, `visit_ReturnNode`, `resolve_call`, and
`record_body_fact_node!`. These methods commonly:

1. resolve a type/schema/target;
2. validate ownership or effects;
3. mutate several AST annotations;
4. emit a diagnostic or fix;
5. update phase/global state.

Extract typed decision records first. The visitor can then apply one decision
mechanically. Merely splitting lines into private methods would lower local
complexity without fixing the hidden data contract.

### 6. Dynamic AST stamping is broadly distributed

The 137 `T.unsafe` uses cluster around optional AST properties such as ownership
transport, async result shape, capture analysis, external effects, and
metatype/schema details. Some properties are legitimate annotations, but
`respond_to?` plus dynamic assignment makes phase completeness unprovable.

Create phase result tables or typed annotation records keyed by node identity.
If properties remain on AST nodes, declare a closed typed protocol per node
family and make the phase that initializes each property explicit.

### 7. Repeated unions and arrays should reuse existing domain aliases

FactMine emitted two high-confidence alias recommendations:

- use `Annotator::Domains::DeclarationNode` at three lifetime helper slots that
  repeat `T.any(AST::VarDecl, AST::BindExpr)`;
- use `FunctionAnalysis::CallArgList` at two argument-verification slots that
  repeat `T::Array[AST::Locatable]`.

These are small, safe consistency repairs. The single-use
`DiagnosticKwValue` recommendation is review-only and does not justify another
alias by itself.

### 8. One nilable array remains intentionally suspicious

`comptime_is_a_type_param_refinement` returns
`T.nilable(T::Array[T.untyped])`. Review both dimensions: nil versus empty must
represent distinct states, and the array element should have a named record or
tuple contract. This is exactly the kind of shape that becomes opaque and
cast-heavy in CLEAR.

## Tool Defects Found and Corrected

### FactMine

- Three-level owner qualification joined already-qualified stack entries and
  produced owners such as `Annotator::Annotator::Domains`. This broke signature
  lookup and every downstream fact keyed by owner. Owner qualification now uses
  the immediate fully qualified parent, with a three-level integration test.
- A union containing `NilClass` was treated as deterministically non-nil unless
  it used the dedicated `Nilable` node. Generic guard analysis now uses the
  normalized type tree's `is_non_nil` predicate.
- Short-circuit expressions inferred the known operand when the other operand
  was unknown. `known || unknown` can no longer prove a concrete result type.
- Ruby `Module#name` nilability and Sorbet alias expansion were corrected during
  the parser pass. Ruby spelling/semantics remain in Ruby-specific modules; the
  owner, union, and short-circuit repairs are language-neutral.

FactMine's architecture tests enforce that concrete grammar and language
lexicons remain in designated language files/adapters.

### Decomplex

- The dead-state detector ignored reads through public accessors on external
  receivers. It now treats a same-named external accessor message as evidence
  that a field is not provably dead. Annotator false positives fell from 51 to
  15. This is a conservative language-neutral rule over normalized call facts.
- The derived-state detector treated scoped save/mutate/restore variables and
  predicates that intentionally drive source normalization as stale caches.
  Generic dependency tests now recognize both protocols; annotator findings
  fell from 14 to 0.

The remaining `semantic_index` dead-state candidate demonstrates a closed-world
limitation: its readers live in compiler frontend/importer files outside this
45-file run. Decomplex should eventually label such results "unread in corpus"
unless the input is declared closed-world. It must not gain Ruby-specific
accessor parsing to solve this.

### Espalier and Nil-kill

Espalier consumed the corrected owners and now reports zero duplicated owner
prefixes. Its earlier direct-load/root initialization defect is covered by load
tests. No additional Espalier-specific semantic defect was found in this pass.

Nil-kill correctly retained the four source-contract contradictions above after
FactMine false facts were removed. Its detectors required no Ruby-specific
special case.

## Analyzer Work Still Worth Building

### FactMine facts

Add normalized, cross-language facts for:

- phase annotation writes and reads, distinct from ordinary object state;
- explicit public field/accessor exposure emitted by each language adapter;
- host-capability calls made by mixins/modules;
- declared type pressure (untyped leaves, union width, nilable collections,
  cast/assertion concentration);
- decision records that are constructed and then applied to multiple targets.

Language adapters may recognize `attr_reader`, properties, fields, or equivalent
syntax, but shared FactMine code should receive only normalized accessor facts.

### Decomplex

Consume declared type-pressure facts rather than searching for Sorbet syntax.
Rank methods where type pressure converges with state/branch pressure. Treat
partial-corpus dead state explicitly as provisional. Continue suppressing scoped
state protocols based on dependency structure, not variable names.

### Espalier

Aggregate host capabilities and phase annotation edges. The most useful new
view is a phase matrix: which phase owns each annotation, which later phases
read it, and which helpers bypass the intended boundary. This would make phase
leaks more actionable than another raw delegation count.

### Nil-kill

Continue owning contradictions between nilability and flow. Add cautious review
actions for nilable collections and equality/protocol signatures that are too
narrow for the runtime protocol. The rule should operate on normalized protocol
and type facts, not Ruby method names in Nil-kill core.

## Recommended Cleanup Sequence

1. Resolve the four proven contract contradictions and adopt the two existing
   high-confidence aliases.
2. Define typed host capabilities or a phase context; migrate one small domain
   module to prove the boundary.
3. Split `resolve_call` around a typed call-resolution decision record.
4. Split `PipeAnalysis` by operation family with a shared typed context.
5. Separate diagnostic/fix policy from source-edit construction in
   `FixableHelper`.
6. Inventory dynamic AST annotations by owning phase and replace open-ended
   `respond_to?`/`T.unsafe` stamping with typed records.
7. Re-run Sorbet, annotator/compiler integration tests, and the three analyzers
   before attempting Ruby-to-CLEAR translation.

## Translation Readiness Criteria

The annotator is ready for a serious translation attempt when:

- the four static contract contradictions are resolved;
- a domain/helper declares a small host interface instead of assuming the full
  `SemanticAnnotator` surface;
- call resolution produces a typed decision before mutating AST/state;
- every dynamic annotation has one owning phase and a typed reader contract;
- remaining `T.unsafe` is concentrated at documented adapter boundaries;
- nilable collections have a documented third-state meaning;
- FactMine owner and flow facts remain clean on the full subsystem;
- Decomplex partial-corpus findings are not presented as closed-world verdicts;
- annotator/compiler tests pass before regeneration.

The current architecture is worth refining, not discarding. The direction is
additive: make the existing domains and phases real typed boundaries so the
CLEAR emitter receives resolved semantic decisions rather than reconstructing
them from mutable Ruby objects.
