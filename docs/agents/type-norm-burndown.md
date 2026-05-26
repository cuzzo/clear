# Type Norm Burndown

Goal: drive annotation and post-annotation type flow to one authoritative
contract. After annotation, every AST value that reaches rewriting, MIR,
cleanup, lowering, checker, or backend code must have a concrete `Type`.
Consumers must read that fact directly and fail hard if it is missing. They
must not probe for it, re-normalize it optionally, or rebuild it from shape.

## Acceptance Criteria

- [x] `AST::Locatable#full_type!` is the only post-annotation AST type read API
  used by burned-down consumers. A missing or `:Untyped` type is a compiler
  invariant failure, not a nil branch.
- [x] Optional type probes are gone from post-annotation code:
  `respond_to?(:full_type)`, `respond_to?("full_type")`, `full_type_or`, and
  optional `Type.from_node(...)` are forbidden outside explicit producer/raw
  metadata boundaries.
- [x] Optional receiver reads of annotation facts are forbidden in scoped
  compiler code. `x&.full_type` and `x.full_type&.` are both rejected; callers
  must prove the node exists and then use `full_type!`.
- [x] Direct `.full_type` reads in MIR post-annotation consumers are either:
  converted to `.full_type!`, or documented as producer-side stamping /
  synthetic-node construction where the value is being written or copied.
- [x] All new/modified type-flow structs are strongly typed. No new
  `T.untyped`, nilable arrays, or hash-as-tuple protocols are allowed for type
  facts.
- [x] Post-annotation MIR/backend allocation and ownership facts never use the
  `:Untyped` sentinel. Any allocation marker must carry an authoritative
  `Type` derived from the allocation producer, or fail during lowering.
- [x] Annotation producers stamp type/storage through a single typed mechanism
  or a small sanctioned producer set. Downstream consumers never decide storage
  from raw AST shape.
- [x] MIR and backend code only consume authoritative annotation facts or MIR
  facts. They do not use optional type availability to choose behavior.
- [x] Architecture specs fail on every prohibited pattern above, with small
  allowlists only for raw signature/schema metadata and AST producer code.
- [x] `bundle exec srb tc` passes.
- [x] Full unit specs pass.
- [x] Transpile tests pass.
- [x] Fuzz tests pass with zero hidden/inactive known compiler bugs.
- [x] Decomplex/slopcop/boobytrap are regenerated and reviewed; type-flow
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
- `PreMirTypeCheck`, which is the only boundary allowed to mention the
  `:Untyped` sentinel because it rejects that state before MIR lowering.

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
- [x] MIR/backend allocation facts no longer manufacture `Type.new(:Untyped)`;
  the architecture spec rejects regressions.
- [x] Annotator producer/consumer split for direct reads.
- [x] Auto inference slot identity and result facts are typed objects
  (`AutoSlotId`, typed slot/result structs), not tuple arrays or anonymous
  Struct bags.
- [x] Annotator optional `full_type` receiver reads are guarded by the
  architecture spec and burned down in the current scoped set.
- [x] `pipe_analysis` consumer reads are burned down to `full_type!`; remaining
  `.full_type` sites there are producer writes/copies.
- [x] Annotation stamping single mechanism / sanctioned producer set.
- [x] Full validation and metrics after complete burndown.

## Latest Validation Snapshot

- `bundle exec srb tc`: pass.
- `bundle exec rspec`: 4865 examples, 0 failures, 1 pending.
- `./clear test transpile-tests/`: 568 passed, 0 memory leaks.
- `ruby tools/fuzz/run.rb --matrix`: 1569 run, 1569 ok, `in_dev=0`,
  0 fail, 0 leak, 0 MIR error, 0 unexpected pass.
- `COVERAGE=1 bundle exec rspec`: 4865 examples, 0 failures, 1 pending;
  line coverage 91.15%, branch coverage 62.54%.
- Fresh reports: `tmp/metrics-type-norm-complete/decomplex.md`,
  `tmp/metrics-type-norm-complete/slopcop.md`, and
  `tmp/metrics-type-norm-complete/boobytrap.md`.
- Decomplex versus `tmp/metrics-type-norm-final`: total fell from 10650 to
  6760. `full_type` remains visible but is no longer the dominant scatter:
  the cluster is down to 167 findings. Broken Protocols rose from 1443 to
  1504 and False Simplicity from 714 to 716 because the explicit
  `stamp_type!` producer is now the single visible mutation boundary; this is
  the intended architecture. It should be tested/observed as the sanctioned
  writer, not split apart to satisfy the metric.
- SlopCop and Boobytrap are unchanged versus `tmp/metrics-type-norm-final`
  when run with the same `src/` scope and fresh coverage.

## Completion Checklist

- [x] `classify-annotator-type-reads`: inventory every annotator and annotator
  helper `.full_type` / `Type.from_node` read, and classify it as producer
  stamping, raw metadata normalization, or post-annotation consumer behavior.
- [x] `spec-annotator-consumer-contract`: add architecture specs that reject
  post-annotation annotator consumers branching on type availability. Consumers
  must use `full_type!` or a typed fact object.
- [x] `spec-producer-allowlist`: make producer writes explicit and small. A
  write/copy to `.full_type` is allowed only in annotator producer code,
  parser/AST construction, synthetic AST rewrite construction, or tests.
- [x] `annotator-consumer-full-type-burndown`: convert invalid annotator
  consumer direct reads to `full_type!` or to a strongly typed fact passed from
  the producer.
- [x] `annotation-stamping-mechanism`: introduce one typed stamping path for
  annotation facts, or a deliberately small sanctioned producer set, so storage
  and type writes are not ad hoc.
- [x] `type-flow-struct-burndown`: replace new/modified hash-as-tuple and
  positional-array type-flow facts with `T::Struct` or concrete typed helper
  objects.
- [x] `nilable-array-burndown`: remove defensive nilable-array protocols from
  type-flow paths. Empty non-nil arrays represent absence.
- [x] `mir-backend-read-audit`: rerun the MIR/backend audit after annotator
  changes and ensure no downstream pass regained optional type decisions.
- [x] `validation-full`: run Sorbet, full RSpec, transpile-tests, and the fuzz
  matrix with `in_dev=0`, zero leaks, zero MIR errors, and zero unexpected
  passes.
- [x] `metrics-final`: regenerate decomplex, SlopCop, and Boobytrap. Any
  type-flow metric that moves the wrong way must be fixed or documented with a
  concrete architectural reason.
- [ ] `completion-commit`: commit and push the completed increment.
