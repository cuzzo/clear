# Ruby-to-CLEAR semantic architecture recovery

## Finding

The self-hosting failures are not primarily a backlog of missing Ruby method
lowerings.  The transpiler has more than one authority for the same semantic
question.  Consequently a type, refinement, method dispatch, field, capture,
or ownership decision can vary with the lowering path that happens to ask it.
Source-level rewrites which make ordinary typed Ruby compile are therefore a
symptom, not an acceptable fix.

The 2026-07-29 whole-subtree inventory supports that conclusion:

| evidence | result | architectural implication |
| --- | ---: | --- |
| Espalier | `Transpiler`: 131 state slots, 495 methods, score 8687.50 | It is a mutable semantic coordinator, not an emitter. |
| Espalier | `CallLowerer#visit_call_node`: 351 conditional calls | Call dispatch is branch-driven rather than a resolved operation contract. |
| Decomplex | 619 state-based branches, 83 missing abstractions, 249 multi-detector convergences | The state is repeatedly interpreted at decision sites. |
| Nil-kill static | 2,065 state accesses; 14,103 local flow types; 429 nullable refinements | Flow facts exist, but are not represented as one total per-function result. |
| Nil-kill static | 13,737/16,089 eligible calls unresolved in the selected, non-closed subtree | Resolution cannot be repaired by more local guessing; it needs a closed program index. |

`TypedIR::FunctionAnalyzer` currently calls back into the host for resolution
and reads host instance variables directly.  `LocalAnalyzer`, `TypeEnv`,
`MetadataCollector`, `CallLowerer`, and the emitter each also derive overlapping
facts.  No phase is authoritative.

## Required authority boundary

The target pipeline is deliberately one-way:

```
Ruby AST + imported declarations
          |
          v
immutable ProgramIndex
  symbols, imports/includes, classes, fields, method signatures,
  registry/intrinsic contracts and source locations
          |
          v
immutable FunctionFacts (one per admitted function)
  expression type/value category, resolved call/field/constant,
  CFG flow refinements, closure captures, ownership and mutability facts
          |
          v
LoweringFrame
  emitted-name allocation, lexical output scope and formatting only
          |
          v
CLEAR emitter
```

The ProgramIndex and FunctionFacts are inputs to lowering.  The emitter may
format and materialize a fact, but it may not re-infer it.  A lowering that
needs a fact absent from FunctionFacts is a semantic-analysis defect, not an
invitation to consult an instance variable or add a syntax-shaped special case.

## Non-negotiable invariants

1. A node's resolved call, field, type, value category, and flow refinement
   have one source of truth for a function revision.
2. All Ruby source-level constructs that are valid under the supported typed
   subset lower through the same fact-backed path; compiler/ruby is not shaped
   to compensate for missing general lowering.
3. Intrinsics declare their receiver/argument/result/effect/ownership
   contracts.  Registry code consumes resolved contracts rather than inspecting
   syntax or `@local_types`.
4. Included-module methods, common union fields, optional narrowing, and
   block element bindings resolve from ProgramIndex/FunctionFacts, never from a
   one-off fallback branch.
5. Ownership and mutability are distinct FunctionFacts.  Lowering materializes
   `COPY`, retain, move, or a mutable local only from those facts.  It must not
   infer them from emitted text.
6. No semantic pass reaches through `instance_variable_get` into another
   phase.  Transitional adapters may expose explicit read-only interfaces only.

## Migration order

### 1. Freeze the metadata boundary

Extract a read-only `ProgramIndex` from the collected metadata.  Give it the
existing queries for method owner/signature, field, include ancestry, union
members, constants, and intrinsic contracts.  Replace `TypedIR` host callbacks
and direct instance-variable reads with this interface.  This is the first
enabling slice because it makes resolution repeatable and cacheable.

### 2. Make function analysis total

Turn the current TypedIR analysis into `FunctionFacts`, indexed by Prism node
identity/source span.  It owns types, resolved operations, narrowing, captures,
and value/ownership categories.  `LocalAnalyzer` becomes an implementation
detail of this phase rather than an alternate source of facts.

### 3. Lower resolved operations, not Ruby shapes

`CallLowerer` becomes a small dispatcher on `ResolvedCall` / intrinsic
contract.  Generic paths for `T.must`, optional predicates, `each`, collection
mutation, included methods, and union fields consume their fact records.
Syntax-based fallbacks are deleted once their fact-backed equivalent exists.

### 4. Delete mutable semantic scope

Replace emitter-scoped `@local_types`, `@renames`,
`@narrowed_optional_storage_locals`, and
`@active_narrowed_binding_names` with a scoped LoweringFrame keyed by facts.
The frame may allocate output locals; it cannot change what a source node
means.

## Regression policy

Every discovered self-host failure receives a minimal ruby-to-clear regression
first.  The regression asserts both valid CLEAR syntax and the semantic
property that mattered (single evaluation, non-null block element, resolved
included method, ownership materialization, etc.).  A compiler/ruby rewrite is
allowed only when it expresses a real target-language or ownership boundary;
otherwise the correction belongs in the generic transpiler.

Existing targeted regressions for typed `String#+`, non-local nullable
predicates, and `Hash#delete_if` are the first examples of this policy.  The
same policy now covers stable typed block-element materialization for `each`
and the other recovered semantics below.

## Implemented recovery

The recovery pass now establishes the authority boundary above rather than
adding compiler-specific rewrites:

- `ProgramIndex` is the immutable authority for declarations, explicit method
  provenance, fields, includes, signatures, constructor contracts, common
  union projections, sentinels, and intrinsic contracts.
- Per-function facts carry resolved calls and fields, callback element types,
  flow refinements, parameter mutation, capture information, and value
  categories into lowering.
- Explicit Ruby methods take precedence over storage fields with the same
  name. Closed-world unique dispatch is available for ordinary calls, while
  operators remain intrinsic and cannot accidentally bind to an unrelated
  user method.
- Optional narrowing, `T.must`, recursive union guards, included methods,
  `find` predicates, and collection iteration all consume shared facts.
- Safe navigation materializes an impure receiver exactly once. Collection
  iteration binds a non-mutated element once, while mutation preserves the
  indexed place needed by the generic copy/mutate/store-back path.
- Default argument normalization is one callee-side mechanism shared by
  methods and constructor wrappers, including renamed CLEAR parameters.
- Sentinel and collection declarations are emitted through canonical CLEAR
  types (`[]T`, `{K}V`) rather than legacy postfix renderings.
- Metadata discovery is bounded to the actual project. In particular a source
  below `/tmp` can no longer promote `/tmp` and `/` to recursive scan roots.

The focused semantic/support suite runs 83 examples in about 1.2 seconds and
the main transpiler suite runs 672 examples in about 1.7 seconds on the
32-core self-host machine. Before bounding metadata discovery, the transpiler
suite took about 113 seconds and emitted host-wide filesystem warnings. This
is an approximately 60-fold correction of that accidental scan cost.

## Verification architecture

`ruby-to-clear-verify --changed` is dependency-closed: it selects roots from a
reverse dependency graph but compiles each selected root with its complete
generated dependency closure. Its reuse fingerprint now includes a
content-derived hash of the ruby-to-clear and fact-mine toolchains, not only
the compiler source revision. A worktree transpiler change therefore cannot
silently reuse stale G0-G2 artifacts.

The intended feedback modes are:

1. focused semantic and shrink specs for a generic bug;
2. dependency-closed `--changed` verification from a completed full baseline;
3. a periodic 188-root cold G0-G4 run as the authoritative measurement.

The cold run still performs substantial duplicate initialization and semantic
analysis across root processes. That cost is a separate throughput problem;
it must not be confused with correctness or worked around by using stale
generated CLEAR.

## Transpiler versus manual completion

The decision unit is a unique semantic blocker, not a failed root. One shared
provider can amplify a single defect across most of the 188 roots.

Continue generic transpiler work when a remaining failure is in a shared
provider, represents normal typed Ruby semantics, or affects multiple roots.
Manual CLEAR is reasonable only as a small, checked overlay for a stable set
of true leaf units whose behavior is target-specific and whose ownership
boundary cannot be expressed in the supported Ruby contract.

Do not hand-edit generated CLEAR in place. That creates a second source of
truth, is overwritten by regeneration, and prevents the verifier from proving
that Ruby remains the source program. If a manual tail is selected, give it an
explicit manifest and divergence check, and keep generated and handwritten
units visibly separate.

After the architecture recovery, broad transpiler feature investment should
stop. Future transpiler changes should be limited to high-fanout generic
semantic defects proven by minimal regressions. The final cold G3 blocker
inventory determines whether the remaining tail meets the narrow overlay
criterion.
