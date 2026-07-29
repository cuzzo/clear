# Runtime Semantic Evidence v1

Status: implementation architecture. The prior ad-hoc, unused
`fact-mine.runtime-value-evidence.v1` shape is replaced in place. There is no
compatibility contract and no dual emission.

## Decision

Runtime analysis uses one versioned, language-neutral protocol with two
top-level messages:

1. FactMine emits a **Trace Plan** containing exact, typed source anchors and the
   evidence required at each anchor.
2. NilKill consumes that plan and emits **Runtime Semantic Evidence** containing
   only observed runtime facts, capture status, and provenance for those exact
   anchors.

FactMine is the sole owner of source parsing, CFG/DFG propagation, semantic
closure, SCIP generation, and Big-O completeness. NilKill is the sole owner of
executing workloads and faithfully observing runtime values and dispatch.

The canonical schema is Protobuf, like SCIP. Rust generates its binding during
the build and Ruby checks in its generated binding. ProtoJSON encoded through
those bindings and
compressed as `.json.gz` remains the default human-inspectable artifact. A
binary protobuf encoding may be added without changing protocol semantics.

The protocols intentionally reuse SCIP concepts and types:

- tool metadata;
- canonical project-relative documents;
- explicit position encoding;
- typed, zero-based, half-open ranges;
- canonical SCIP symbols for semantic entities;
- document-local symbols for source anchors.

They do not pretend that ordinary SCIP can represent runtime values. Runtime
domains, execution counts, correlation, capture completeness, and run
provenance are companion facts referencing SCIP-style symbols and occurrences.

## Why the prior ad-hoc shape is not an adequate specification

The repository has a nominal v1 data shape, but it is not a complete protocol:

- Its only canonical definition is a Rust `serde` struct. NilKill independently
  constructs Ruby hashes and duplicates the schema-version string.
- Unknown fields are accepted, so a misspelled producer field can be silently
  discarded.
- Methods and calls are joined by path, owner, name, kind, line, selector, and
  suffix heuristics. The evidence does not reference FactMine-generated source
  identities.
- No source or anchor digest proves that evidence belongs to the analyzed
  source revision.
- A line and selector are not a unique callsite identity.
- Flattened `types`, `singletons`, `elements`, `targets`, result domains, and
  truth values lose receiver-target-result correlations.
- `target_observation_complete` has no precise world or capture semantics.
  Current merging can turn a mixed group complete when any row has a target.
- An absent record cannot distinguish unexecuted, not instrumented, unsupported,
  dropped, filtered, stale, or producer failure.
- Producer-side filtering of test code discards observations and forces
  receiver-only reconstruction in the consumer.
- Runtime type identities are unqualified strings rather than canonical
  semantic entities.
- The consumer implementation combines validation, heuristic source matching,
  value propagation, target inference, stdlib synthesis, SCIP encoding, and
  several dozen regression tests in one approximately 5,000-line module.
- NilKill tests its serializer and some synthetic events; FactMine tests many
  handwritten examples. The two projects do not run the same independent
  conformance corpus.

There are useful v1 tests, but they are regression tests for implementation
examples, not proof that an arbitrary conforming producer will work.

## Semantic authority

Runtime evidence never claims all possible program behavior.

`MODELED_RUNS` means:

- every execution of an instrumented anchor in the listed successful runs was
  captured unless the anchor says otherwise;
- the value and target alternatives are complete only for those captured
  executions;
- unobserved inputs, unexecuted branches, and future monkey-patching remain
  outside the modeled world.

FactMine may report `complete_under_modeled_runs`, but must not silently relabel
that as compiler-proven or universally complete. Every exported completeness
result retains its authority.

`capture_complete` is distinct from `semantic_closed`:

- capture completeness is a producer attestation about the selected executions;
- semantic closure is a FactMine proof that every alternative relevant to an
  operation has a target and cost under the selected authority.

Line coverage proves neither property.

## Protocol A: Trace Plan

FactMine generates the plan after parsing and normalizing source. NilKill does
not discover callsites or reconstruct source flow.

Conceptual schema:

```protobuf
message TracePlan {
  uint32 protocol_version = 1;
  ToolInfo producer = 2;
  string project_root = 3;
  bytes plan_digest = 4;
  repeated PlannedDocument documents = 5;
  repeated EvidenceRequest requests = 6;
}

message PlannedDocument {
  string relative_path = 1;
  string language = 2;
  scip.PositionEncoding position_encoding = 3;
  bytes content_sha256 = 4;
}

message SourceAnchor {
  // A document-local SCIP symbol generated by FactMine.
  string symbol = 1;
  string relative_path = 2;
  SourceRange range = 3;
  AnchorKind kind = 4;
  string enclosing_symbol = 5;
  bytes semantic_digest = 6;
  string display_name = 7; // informational, never a join key
}

message EvidenceRequest {
  SourceAnchor anchor = 1;
  repeated EvidenceKind required = 2;
  optional SourceAnchor activation_anchor = 3;
  optional uint32 parameter_ordinal = 4;
}
```

Required anchor kinds include function entry, function return, call selector,
state read/write, callback entry, collection operation, and branch predicate.
The language adapter recognizes native syntax; the common profile pass assigns
anchors and requirements.

Anchor IDs and semantic digests have separate purposes:

- the local symbol is a stable lookup key across plan/evidence;
- the semantic digest determines whether cached evidence may be reused;
- the document digest detects stale source;
- only FactMine may relocate unchanged anchors into a new plan.

This supplies the correctness foundation for incremental collection. NilKill
never guesses that an old path/line remains equivalent.

## Protocol B: Runtime Semantic Evidence

Evidence is grouped by exact plan anchor and correlated execution alternative.
It does not flatten independent unions.

Conceptual schema:

```protobuf
message RuntimeEvidence {
  uint32 protocol_version = 1;
  ToolInfo producer = 2;
  Authority authority = 3; // MODELED_RUNS
  bytes trace_plan_digest = 4;
  repeated EnvironmentClaim environment = 5;
  repeated Run runs = 6;
  repeated AnchorEvidence anchors = 7;
}

message AnchorEvidence {
  string anchor_symbol = 1;
  bytes anchor_semantic_digest = 2;
  CaptureSummary capture = 3;
  repeated ExecutionBucket executions = 4;
}

message CaptureSummary {
  CaptureStatus status = 1;
  repeated string run_ids = 2;
  uint64 observed_executions = 3;
  uint64 dropped_executions = 4;
  string reason = 5;
}

enum CaptureStatus {
  CAPTURE_STATUS_UNSPECIFIED = 0;
  COMPLETE_FOR_RUNS = 1;
  NOT_EXECUTED = 2;
  PARTIAL = 3;
  NOT_INSTRUMENTED = 4;
  UNSUPPORTED = 5;
  STALE = 6;
  FAILED_CAPTURE = 7;
}

message ExecutionBucket {
  uint64 count = 1;
  ValueSet receiver = 2;
  RuntimeTarget target = 3;
  ValueSet result = 4;
  optional bool boolean_result = 5;
  Provenance provenance = 6;
  ValueSet value = 7; // parameter, return, or state boundary
}
```

One bucket represents one correlated
`receiver -> actual target -> result -> predicate result` alternative. Identical
buckets may be counted and merged. Different alternatives must never be
cross-multiplied.

Values are recursive, bounded summaries:

```protobuf
message RuntimeValue {
  string type_symbol = 1;
  optional string singleton_symbol = 2;
  SourceRole source_role = 3;
  oneof shape {
    SequenceShape sequence = 4;
    MappingShape mapping = 5;
    RecordShape record = 6;
    TupleShape tuple = 7;
  }
  bool truncated = 8;
}

message ValueSet {
  repeated WeightedValue alternatives = 1;
  bool truncated = 2;
}

message WeightedValue {
  RuntimeValue value = 1;
  uint64 count = 2;
}
```

Container type and contained alternatives remain nested in the same value.
Record members remain attached to the exact record type. Mapping summaries
retain key/value association to the precision needed by FactMine. Depth,
cardinality, redaction, or sampling limits set `truncated`; they never silently
produce a closed domain.

`RuntimeTarget` contains one canonical SCIP symbol when the provider can produce
one, the exact runtime definition identity when available, package/version
coordinates, native/workspace/dependency classification, and source role. The
producer records test doubles and mocking targets truthfully. FactMine applies
production-analysis policy; NilKill does not erase observations.

Every requested anchor appears exactly once in the evidence, including
`NOT_EXECUTED` anchors. Missing anchors are protocol errors, not ordinary
unobserved calls.

## Responsibility boundary

### FactMine owns

- source parsing and language syntax normalization;
- trace-plan anchors, requirements, semantic digests, and relocation;
- protocol validation against the exact plan and source;
- normalized CFG/DFG propagation;
- callback, branch, iteration, state, and collection relationships;
- joining runtime targets to project/compiler SCIP;
- language-owned semantic normalization through an adapter;
- stdlib/dependency cost joins;
- closed-world checks and authority labels;
- inferred SCIP output and Big-O analysis.

### NilKill shared infrastructure owns

- executing complete or incremental workloads;
- run and shard identities;
- ensuring every requested anchor receives a capture status;
- lossless aggregation of identical correlated execution buckets;
- function-level evidence ownership and replacement;
- atomic compressed output;
- dropped-event accounting and producer attestation.

### NilKill language providers own

- VM/runtime hooks and source instrumentation;
- obtaining receiver, target, result, and predicate observations;
- mapping native runtime entities to canonical runtime SCIP symbols;
- bounded value/shape inspection;
- identifying the source and package coordinates of runtime entities;
- reporting unsupported evidence explicitly.

They do not parse source for flow, infer owners through assignments, filter
non-production evidence, infer call targets at unexecuted sites, or decide
Big-O closure.

### FactMine language adapters own

A deliberately small runtime extension to the existing syntax adapter:

- normalization of a provider's runtime entity identity;
- mapping native/stdlib runtime targets to the language's canonical SCIP
  package identity;
- native dispatch relationships that the language runtime defines (for example
  mixins or prototype ancestry);
- implicit runtime operations that have no explicit source call.

The shared overlay never contains `if language == ...`. New adapter methods
must be justified by a cross-language normalized concept and exercised by the
adapter conformance suite.

## Conformance testing

Correctness is established in layers. Repository completion percentages are
benchmarks, not protocol tests.

### 1. Schema and semantic validator

`fact-mine runtime-evidence validate --plan PLAN --evidence EVIDENCE`
must reject:

- unknown protocol versions and fields;
- malformed SCIP symbols or ranges;
- non-canonical paths or inconsistent position encodings;
- plan, document, or anchor digest mismatches;
- missing or duplicate requested anchors;
- counts inconsistent with capture summaries;
- `COMPLETE_FOR_RUNS` with dropped events, truncation, failed runs, or missing
  required fields;
- targets or values whose source role/provenance is missing;
- evidence referring to a different enclosing symbol or anchor kind.

Checked-in valid and invalid fixtures are consumed by both generated Rust and
Ruby bindings.

### 2. FactMine consumer conformance

FactMine tests use a synthetic normalized IR plus hand-authored, validator-clean
evidence. They do not invoke NilKill. Golden cases cover:

- exact callsite and definition joins;
- parameter, return, state, and callback propagation;
- receiver-target-result correlation;
- multiple receiver alternatives where all targets close;
- one unresolved alternative preventing closure;
- collection element/key/value projections;
- record accessors and generated declarations;
- branch capability and truthiness refinement;
- test replacement evidence retained but not trusted as production identity;
- stdlib/native target normalization;
- unexecuted, partial, truncated, stale, and unsupported evidence;
- source movement with valid and invalid relocation;
- incremental merge and replacement.

The expected result includes exact inferred SCIP occurrences, normalized
domains, call costs, completeness authority, and gap reasons.

Property tests enforce monotonic safety:

- reordering or duplicating identical buckets does not change the result;
- removing evidence cannot improve semantic closure;
- changing complete capture to partial cannot improve completeness;
- adding an unresolved alternative cannot preserve a closed callsite;
- stale or ambiguous evidence never joins;
- a covered line alone never resolves a call;
- no inference crosses an enclosing-function or anchor boundary.

### 3. NilKill producer conformance

A shared provider harness runs small real programs and compares emitted evidence
with semantic golden expectations. Ruby is the first implementation; Python,
JavaScript, and PHP must pass the same scenario catalog before integration.

Provider fixtures cover:

- instance, class/module, inherited, mixed-in, and native calls;
- overloaded/dynamic targets at one callsite;
- parameters, returns, state, callbacks, and nested containers;
- generated accessors invisible to ordinary call TracePoint;
- short-circuit and ternary branches;
- exceptions and non-local exits;
- test doubles and monkey patches with correct source roles;
- anonymous classes/records;
- dropped/truncated evidence;
- zero executions;
- multiple runs and incremental replacement.

These tests assert evidence only. They do not accept a favorable Big-O result as
proof that tracing was correct.

### 4. End-to-end contract fixtures

For each supported runtime language:

```
fixture source + fixture workload
        -> FactMine trace plan
        -> NilKill provider
        -> protocol validator
        -> FactMine runtime SCIP
        -> exact expected SCIP + Big-O result
```

The same fixture is also run with a synthetic perfect producer. A failure then
localizes to plan/consumer, provider, or integration rather than becoming a
repository-level metric mystery.

## Implementation layout

```text
protocol/runtime-evidence/v1/
  runtime_evidence.proto
  conformance/

gems/fact-mine/src/
  runtime_protocol.rs    # generated binding wrapper, plan, strict validator
  runtime_evidence.rs    # canonical-to-normalized overlay and SCIP export

gems/nil-kill/lib/nil_kill/runtime/
  protocol/runtime_evidence_pb.rb
  evidence_protocol.rb   # generated binding adapter only
  value_evidence_emitter.rb
  evidence_merger.rb
  scip_emitter.rb

gems/nil-kill/lib/nil_kill/languages/providers/<language>/
  runtime_tracer.*
  runtime_identity.*
```

No language-specific code belongs in a shared file.

## Cutover implemented

1. The v1 `.proto`, generated bindings, strict validator, and shared valid and
   invalid corpus are the only public runtime-evidence contract.
2. FactMine generates the exact plan and a private anchor-to-normalized-IR
   binding table from the same source snapshot.
3. NilKill reads the plan and writes every artifact through the generated Ruby
   binding. Unknown or malformed fields fail before collection or merge.
4. FactMine rebuilds the plan, requires the same plan digest, validates every
   evidence row, and joins only through the private exact binding table.
5. The former path/name/line ad-hoc JSON shape has no production parser or CLI
   entry point. FactMine's private normalized facts are not a wire format.
6. Incremental merge replaces evidence by run and anchor. Unchanged semantic
   anchors may relocate; changed or new anchors become `STALE`.

## Cutover acceptance criteria

- One canonical protocol definition generates both producer and consumer types.
- The validator proves exact plan/source compatibility before analysis.
- Every planned anchor has explicit capture status.
- Receiver, target, result, and predicate observations remain correlated.
- No source path/name/line heuristic is used to join runtime evidence.
- FactMine passes the consumer golden corpus without NilKill.
- Ruby passes the shared producer corpus without relying on FactMine inference.
- End-to-end fixtures pass with exact SCIP and completeness outputs.
- All safety properties pass under randomized ordering, merging, omission, and
  alternative expansion.
- Incremental and full collection produce semantically identical evidence for
  unchanged final source and workload sets.
- SlopCop regressions are explained by authority/gap diagnostics; an older,
  unsound percentage is not restored merely to hit a number.

Only after these criteria hold should work resume on repository-specific
covered-line gaps.
