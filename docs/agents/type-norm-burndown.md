# Type Norm Burndown

Goal: drive annotation and post-annotation type flow to one authoritative
contract. After annotation, every AST value that reaches rewriting, MIR,
cleanup, lowering, checker, or backend code must have a concrete `Type`.
Consumers must read that fact directly and fail hard if it is missing. They
must not probe for it, re-normalize it optionally, or rebuild it from shape.

## Acceptance Criteria

- [ ] `AST::Locatable#full_type!` is the only post-annotation AST type read API
  used by burned-down consumers. A missing or `:Untyped` type is a compiler
  invariant failure, not a nil branch.
- [x] Optional type probes are gone from post-annotation code:
  `respond_to?(:full_type)`, `respond_to?("full_type")`, `full_type_or`, and
  optional `Type.from_node(...)` are forbidden outside explicit producer/raw
  metadata boundaries.
- [x] Direct `.full_type` reads in MIR post-annotation consumers are either:
  converted to `.full_type!`, or documented as producer-side stamping /
  synthetic-node construction where the value is being written or copied.
- [ ] All new/modified type-flow structs are strongly typed. No new
  `T.untyped`, nilable arrays, or hash-as-tuple protocols are allowed for type
  facts.
- [ ] Annotation producers stamp type/storage through a single typed mechanism
  or a small sanctioned producer set. Downstream consumers never decide storage
  from raw AST shape.
- [ ] MIR and backend code only consume authoritative annotation facts or MIR
  facts. They do not use optional type availability to choose behavior.
- [ ] Architecture specs fail on every prohibited pattern above, with small
  allowlists only for raw signature/schema metadata and AST producer code.
- [ ] `bundle exec srb tc` passes.
- [ ] Full unit specs pass.
- [ ] Transpile tests pass.
- [ ] Fuzz tests pass with zero hidden/inactive known compiler bugs.
- [ ] Decomplex/slopcop/boobytrap are regenerated and reviewed; type-flow
  complexity must move down or have a written architectural justification.

## Sanctioned Boundaries

Producer boundaries may write or copy `full_type`:

- Parser literal defaults and AST storage/type accessors.
- Annotator and annotator helpers while producing annotation facts.
- Rewriters/hoist while constructing synthetic AST nodes from already typed
  source nodes.
- Tests that build AST nodes directly, provided they stamp required facts.

Raw metadata boundaries may normalize non-AST type payloads:

- Function signatures and return type declarations.
- Schema / union variant metadata.
- MIR structs whose field is already typed as `Type`.

Every other use is a burndown target.

## Work Loop

1. Inventory all optional type probes and direct post-annotation type reads.
2. Classify each site as producer/raw metadata/consumer.
3. Add or tighten architecture specs before changing the implementation.
4. Convert one source area at a time to `full_type!` or a typed fact object.
5. Run Sorbet plus targeted specs for that source area.
6. Repeat until the architecture specs cover the whole post-annotation surface.
7. Run full validation and metrics before declaring completion.

## Current Status

- [x] First hard accessor landed: `AST::Locatable#full_type!`.
- [x] First burned-down file set guarded by architecture specs.
- [x] Scoped post-annotation optional-probe ban across annotator/MIR/backends.
- [x] MIR direct-read classification and conversion.
- [x] Backend direct-read classification and conversion.
- [ ] Annotator producer/consumer split for direct reads.
- [ ] Annotation stamping single mechanism.
- [ ] Full validation and metrics after complete burndown.
