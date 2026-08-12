# Language-Specific Type Inference Architecture

Status: course-correction design and migration contract

Date: 2026-07-13

Related documents:

- `gems/ruby-to-clear/docs/agents/cfg.md`
- `gems/ruby-to-clear/docs/agents/dfg.md`
- `gems/fact-mine/docs/agents/architecture.md`
- `gems/fact-mine/docs/agents/normalization-boundary.md`

## Decision

FactMine's type inference must be split into a language-neutral inference
engine and explicit language type-semantics implementations. Language type
semantics do not belong in syntax adapters, CFG builders, generic dataflow
analyses, or scattered `match language` branches in the engine.

The new boundary should be:

```text
concrete source
      |
      v
syntax/<language>.rs and AST adapter
  concrete syntax -> normalized executable IR
      |
      v
generic CFG and dataflow
  places, effects, reachability, definitions, liveness
      |
      +-------------------------------+
      |                               |
      v                               v
generic inference engine       type_semantics/<language>.rs
  worklist and state             type spelling and meaning
  joins and invalidation         annotations and casts
  evidence/completeness          standard-library summaries
  call/return propagation        language-specific narrowing
      |                               |
      +---------------+---------------+
                      v
             flow-resolved type facts
```

Ruby and Python are the initial supported type-semantics implementations
because Nil-kill predominantly supports those languages. Structural CFG and
dataflow facts remain available for every FactMine language without implying
that every language has a production-quality type inference implementation.

## Why This Is a Separate Adapter Class

Syntax adapters answer questions such as:

- Is this concrete tree-sitter node an assignment?
- Which child is the receiver or condition?
- How is a binding represented in normalized IR?
- Which concrete construct means return, break, rescue, or callback?

Type-semantics adapters answer different questions:

- What does `T.nilable(String)` or `Optional[str]` mean?
- Which annotation syntax denotes a union, collection, or unknown type?
- Does a call represent a cast, assertion, type predicate, or no-return?
- What type does a known standard-library operation return?
- How should a nil/None guard narrow a type on each CFG edge?
- How is a shared semantic type rendered back into source-language spelling?

Combining these responsibilities would make the syntax layer depend on
Nil-kill policy and make ordinary CFG extraction pay for type-system details.
It would also encourage syntax normalization to encode Sorbet, Python typing,
or standard-library knowledge in otherwise language-neutral nodes.

The proposed source tree is therefore a new sibling subsystem:

```text
src/
  type_inference/
    mod.rs
    engine.rs
    state.rs
    transfer.rs
    evidence.rs
    fact_store.rs
    summaries.rs
    type_expr.rs
    type_semantics.rs
    languages/
      mod.rs
      ruby.rs
      python.rs
  syntax/
    ... existing normalization and CFG inputs only ...
```

`syntax/<language>.rs` may identify normalized constructs needed by all
consumers. It must not parse type expressions, recognize Sorbet/Python typing
APIs, format inferred types, or implement inference transfer functions.

## Current Problem

`src/type_inference.rs` is currently about 6,500 lines. It was extracted from
`profile.rs` as part of the Rust Nil-kill migration and is invoked by
`profile::extract` for `Profile::NilKill`. Espalier shares the `TypeExpr`
representation and core profile records, but does not run the full Nil-kill
visitor.

The file currently combines several distinct responsibilities:

1. A multi-language `TypeExpr` parser and renderer.
2. AST traversal and method/scope bookkeeping.
3. A method-wide local type environment.
4. Ruby/Sorbet and Python annotation interpretation.
5. Known call and standard-library return summaries.
6. Nil/None guard and conditional handling.
7. Container and record-shape inference.
8. Call/return and parameter-origin propagation.
9. Nil-kill-specific evidence collection.
10. Profile output mutation and prepass coordination.

That shape makes language support difficult to assess. A generic-looking
visitor can silently contain Ruby/Python assumptions, and adding another
language encourages more conditionals rather than a bounded implementation.
The method-wide `local_types` map also cannot represent types at individual CFG
program points, which is the immediate reason the new dataflow facts matter.

## Shared Semantic Types

The engine should operate on a language-neutral semantic lattice. `TypeExpr`
can remain the initial representation, but its parsing and rendering must move
out of its core operations.

The shared representation should cover:

- unknown/untyped;
- never/no-return;
- nil/null;
- named nominal types;
- booleans and numeric/string/symbol primitives;
- parameterized array, set, map/hash, tuple, and record types;
- unions and optionals;
- callable types; and
- explicit incomplete/conflicting evidence.

Shared code owns canonicalization, equality, union construction, nil removal,
join/widening, and completeness. It must not know strings such as
`T.nilable`, `T.any`, `Optional`, `Union`, `None`, `NilClass`, or
`T::Boolean`.

## Type-Semantics Interface

The exact Rust API may evolve, but its capabilities should resemble:

```rust
trait TypeSemantics: Sync {
    fn language(&self) -> Language;

    fn parse_annotation(&self, text: &str) -> TypeResult;
    fn render_type(&self, ty: &SemanticType) -> String;

    fn literal_type(&self, literal: &NormalizedLiteral) -> SemanticType;
    fn annotation_for_parameter(&self, function: &Node, name: &str)
        -> TypeResult;
    fn annotation_for_return(&self, function: &Node) -> TypeResult;

    fn classify_type_call(&self, call: &NormalizedCall)
        -> Option<TypeOperation>;
    fn known_call_summary(&self, call: &ResolvedCallShape)
        -> Option<CallTypeSummary>;
    fn predicate_narrowing(&self, predicate: &NormalizedPredicate)
        -> NarrowingResult;

    fn implicit_nil(&self, construct: ImplicitValueSite) -> bool;
    fn truthiness(&self, ty: &SemanticType) -> Truthiness;
}
```

Every result that may be incomplete should carry evidence and an explicit
reason. `None` should mean “this adapter does not recognize the construct,” not
“the construct is safe” or “the type is definitely unknown.”

The interface must receive normalized constructs and public dataflow facts.
It must not receive raw tree-sitter nodes. If a language semantic operation
cannot be expressed from normalized input, the missing normalization belongs
in the language syntax/AST adapter and should be added as a generally named
normalized construct.

## Generic Engine Responsibilities

The language-neutral engine owns:

- function and lexical-scope traversal over normalized IR;
- a flow state keyed by stable `PlaceId`;
- deterministic forward worklist execution over CFG edges;
- joins, widening, invalidation, and loop convergence;
- reaching-definition and dominance queries;
- interprocedural scheduling and summary convergence;
- completeness propagation;
- source-linked evidence construction; and
- publication of flow type, return, parameter, and origin facts.

The engine must never branch on `Language`, inspect source spelling for a
type-system API, or format a language-specific annotation.

## Ruby Semantics Module

`type_inference/languages/ruby.rs` should own at least:

- Sorbet `sig`, `params`, `returns`, `void`, `T.untyped`, and `T.noreturn`;
- `T.nilable`, `T.any`, `T::Array`, `T::Hash`, `T::Set`, tuples, and shapes;
- `T.let`, `T.cast`, `T.must`, `T.assert_type!`, and `T.absurd`;
- `is_a?`, `kind_of?`, `nil?`, truthiness, and Ruby implicit nil;
- Ruby core/standard-library call summaries used by Nil-kill;
- Sorbet RBI-derived summaries supplied through a typed summary interface;
- Ruby-specific block/iterator type behavior after syntax normalization; and
- rendering semantic types as Sorbet-compatible spellings.

This is legitimate Ruby-specific code. It must not leak into generic CFG,
dataflow, or engine modules.

## Python Semantics Module

`type_inference/languages/python.rs` should own at least:

- `None`, `Any`, `Optional`, `Union`, PEP 604 `|`, and built-in generics;
- `typing`/`typing_extensions` equivalents that Nil-kill supports;
- annotations on parameters, returns, and assignments;
- `is None`, `is not None`, `isinstance`, truthiness, and implicit `None`;
- Python collection and standard-library summaries used by Nil-kill;
- Python exception/no-return conventions; and
- rendering semantic types as supported Python annotations.

Ruby concepts such as Sorbet casts and Python concepts such as `isinstance`
should converge to shared operations like `Cast`, `AssertNonNil`,
`TypePredicate`, and `NoReturn`, rather than being interpreted in the engine.

## Relationship to CFG and Dataflow

CFG/dataflow should improve Nil-kill without acquiring Nil-kill semantics.
FactMine's shared layer publishes:

- stable places;
- reads, definitions, and mutations;
- feasible control-flow edges;
- reachability and dominance;
- reaching definitions and def-use;
- liveness; and
- normalized literal/value hints where syntax alone proves them.

The inference engine combines those facts with a selected `TypeSemantics`
implementation. For a local read, it resolves the place and program point,
looks up the definitions reaching that use, transfers the definition types,
and joins only feasible predecessors. A complete flow type may override a
coarser method-wide fallback; an incomplete flow type may not.

This directly fixes cases such as:

```ruby
if ready
  value = "ok"
else
  return
end

consume(value)
```

The definition in the returning arm cannot reach `consume`. The generic
reaching-definition fact establishes that; Ruby semantics establishes that the
surviving literal is `String`; Nil-kill publishes both the type and evidence.

## Profile Boundary

`profile::extract(Profile::NilKill)` should select a semantics implementation
from an explicit registry:

```rust
let semantics = type_semantics::for_language(document.language)
    .ok_or(TypeInferenceUnavailable { language, reason })?;
```

Unsupported languages should still produce normal structural profile facts.
They should publish a capability record explaining that flow type inference is
unavailable. They must not fall back to Ruby parsing or generic string guesses.

Nil-kill profile output should include:

- inference language and semantics version;
- capability/completeness status;
- place and use-site identity;
- inferred semantic and rendered type;
- reaching definition evidence;
- narrowing/dominance evidence when applicable; and
- unknown or conflict reasons.

## Migration Plan

### Stage 1: Freeze and characterize

1. Add behavior tests for Ruby and Python profile fixtures before movement.
2. Inventory every source-spelling check and language conditional in
   `type_inference.rs`.
3. Classify each as shared lattice, engine, Ruby semantics, Python semantics,
   evidence, container inference, or obsolete fallback.
4. Add an architecture test preventing new language conditionals in the
   monolith during migration.

Exit gate: every existing branch has an owner and representative fixture.

### Stage 2: Extract semantic types

1. Move `TypeExpr` to `type_inference/type_expr.rs`.
2. Separate canonical semantic construction from parsing/rendering.
3. Move Ruby parsing/rendering to `languages/ruby.rs`.
4. Move Python parsing/rendering to `languages/python.rs`.
5. Keep compatibility serialization at the profile boundary.

Exit gate: generic `type_expr.rs` contains no language names or annotation
spellings.

### Stage 3: Extract adapters and registry

1. Introduce the `TypeSemantics` trait and capability record.
2. Move cast/assert/predicate recognition into Ruby/Python modules.
3. Move standard-library return summaries into the corresponding modules.
4. Make profile selection explicit; do not default to Ruby.

Exit gate: the generic engine contains no `match language` branches.

### Stage 4: Replace method-wide local inference

1. Build a `FlowTypeIndex` once per document from CFG/dataflow identity.
2. Key state by `PlaceId` and CFG node, not local name alone.
3. Run transfers with the shared deterministic worklist.
4. Preserve the existing visitor only for fact collection not yet migrated.
5. Remove offset, AST ancestry, and manual branch-merge fallbacks as their
   dataflow equivalents reach fixture parity.

Exit gate: early returns, loops, guard invalidation, and branch joins are
covered for both Ruby and Python.

### Stage 5: Split evidence and interprocedural inference

1. Move `FactStore` and evidence builders to dedicated modules.
2. Extract call/return summary convergence from AST traversal.
3. Separate container/record shape inference from scalar type flow.
4. Require completeness and provenance on every Tier 1 result.

Exit gate: the former `type_inference.rs` is a small module facade or removed.

## Architecture Enforcement

Add tests that fail when:

- `type_inference/engine.rs`, `state.rs`, or `transfer.rs` contains language
  enum matches or Ruby/Python type spellings;
- `syntax/` imports `type_inference` or recognizes Sorbet/typing APIs solely
  for inference;
- a language semantics module imports raw tree-sitter types;
- a non-Ruby/Python language silently selects Ruby or Python semantics;
- a Tier 1 flow type lacks reaching-definition and completeness evidence; or
- a consumer recomputes control flow from source order.

Allow concrete type spellings only under:

- `type_inference/languages/`;
- language-specific tests/fixtures; and
- compatibility serialization tests.

## Testing Matrix

Both Ruby and Python require paired positive and negative fixtures for:

- explicit annotation parsing and rendering;
- nil/None optionals and unions;
- cast/assert operations;
- type predicates and invalidating writes;
- branch joins and one-arm early returns;
- zero-iteration and multi-iteration loops;
- exception/rescue paths and guaranteed cleanup;
- known and unknown calls;
- collections, tuples, and record/hash shapes;
- closure capture and mutation; and
- interprocedural return/parameter propagation.

Cross-language equivalence tests should assert that analogous Ruby and Python
programs produce the same semantic type state and evidence shape, while their
rendered annotation strings remain language-specific.

## Effort Estimate

This is a refactor of a roughly 6,500-line implementation plus a large test
module, not a rewrite from scratch.

Estimated production movement and replacement:

| Work | Estimated LoC |
| --- | ---: |
| Shared type representation and lattice | 500-800 |
| Semantics trait, registry, and capabilities | 250-450 |
| Ruby semantics extraction | 900-1,400 |
| Python semantics extraction | 650-1,050 |
| Generic flow engine integration | 700-1,200 |
| Evidence/fact-store split | 400-700 |
| Compatibility facade and deletion cleanup | 200-400 |

Most of those lines should be moved or simplified from the current file.
Net-new production code is likely 1,000-2,000 lines, with 1,500-2,500 lines of
new or reorganized tests. A realistic focused effort is 3-5 weeks after the
shared CFG/dataflow facts are stable. Attempting it before those facts settle
would force the engine boundary to change twice.

Adding a future language requires a new `languages/<language>.rs`, explicit
registry admission, and its fixture matrix. It should require no engine or CFG
changes. A language with conventional annotations and standard-library
summaries is estimated at 500-1,000 production lines; a language with a richer
type system may require more and should not be advertised as supported until
its capability gates pass.

## Immediate Course

The current CFG/dataflow work should continue without waiting for this full
refactor. Its Nil-kill vertical slice may use a small, clearly marked bridge in
the existing visitor, limited to complete reaching-definition-backed facts for
Ruby and Python. It must not add new language branches to the shared dataflow
engine.

After the liveness and flow-type slices prove value:

1. build a document-level `FlowTypeIndex` rather than scanning facts per read;
2. begin Stage 1 of this migration;
3. move parsing/rendering before moving complex inference rules; and
4. delete each legacy path only after Ruby and Python fixture parity.

This keeps the immediate consumer work useful while making the long-term
boundary explicit and enforceable.
