# Function Compilation Boundaries and Parallelization

Status: proposed, conditional go

Date: 2026-07-19

Scope: Ruby compiler annotation, semantic finalization, MIR preparation,
incremental reuse, and eventual function-granular concurrency

## Executive Decision

Do not undertake this as a Ruby Ractor project. Undertake it only as a bounded
compiler-authority refactor with four combined goals:

1. Make one function body an explicit semantic computation.
2. Separate local ownership/lifecycle preparation from whole-program graph
   propagation.
3. Give clean builds, incremental builds, and the future self-hosted compiler
   the same immutable phase products.
4. Make function jobs schedulable after those boundaries are correct.

Under that definition, the work is substantially synergistic with real current
architectural problems. It is not merely parallelization scaffolding. The
strongest evidence is the concentration of real bugs found by the semantic
generator in ownership transfer, allocator convergence, lifecycle planning,
generic instantiation, and preservation of derived type/effect information
between annotation and MIR.

The work is not a complete annotator/MIR cleanup. Important large problems will
remain in call lowering, pipeline lowering, FSM transformation, the broad
`FunctionSignature` mutation surface, and the large MIR checker. Those should
not be disguised as solved merely because a function-compilation API exists.

The recommendation is therefore:

- proceed through the semantic and MIR boundary refactors if self-hosting,
  compiler soundness, and broader incremental reuse are still primary goals;
- do not approve production concurrency until those boundaries independently
  improve the architecture and pass the semantic generator;
- stop if the implementation becomes a second compiler, serializes the Ruby
  object graph, introduces cache checks inside visitors/lowering rules, or
  cannot demonstrate at least a 20% clean-frontend speedup in a process-pool
  experiment;
- do not replace Sorbet runtime machinery merely to make Ruby Ractor work.

## What Exists Today

The existing incremental subsystem is a correct conservative MVP. It contains
1,148 Ruby lines under `compiler/ruby/incremental/` and already provides:

- deterministic function emission boundaries;
- persistent watch sessions;
- versioned primitive-only `.clearc` records;
- dependency fingerprints;
- reduced-source function compilation;
- byte-for-byte proof that a reduced-context function matches its full-build
  predecessor before reuse;
- exact clean fallback for unsupported changes.

It is not yet a semantic function cache. For a changed function it constructs
an isolated CLEAR source closure, invokes the normal whole compiler on that
smaller source, and replaces the previous emitted function only after checking
the result. This is safe, but it means the compiler still lacks:

```text
analyze_function(function_syntax, program_interface)
  -> FunctionSemanticResult
```

The current annotation products are frozen Ruby containers, but they are not
portable semantic interfaces. `ResolutionFacts` still retains `AST::Program`,
`Scope`, `FunctionRegistry`, AST protocol nodes, and other mutable compatibility
references. `TypedProgramFacts` retains those resolution facts, an
`OwnershipGraph`, and a lifecycle registry indexed partly by Ruby object IDs.

Likewise, MIR has function-shaped endpoints, but preparation is still
whole-program and mutation-driven:

- escape analysis mutates symbol storage;
- capture classification stamps AST nodes;
- cleanup classification is computed per function inside a whole-program pass;
- loop-frame analysis consumes the whole function table;
- `needs_rt` is propagated across the call graph;
- MIR markers are inserted back into the AST;
- function signatures are resynchronized from mutated function definitions.

## Evidence Reviewed

This design is based on four evidence sources:

1. A fresh phase profile of `examples/minivm/vm.clear` on this branch.
2. Decomplex over `compiler/ruby/annotator` and `compiler/ruby/mir`.
3. Espalier over the same source, supplied with Decomplex and NilKill evidence.
4. The executable semantic-gap ledgers and compiler fixes in
   `~/easy-vm-testing`.
5. The abandoned `origin/ownership-cleanup` implementation and its 291-line
   post-mortem.

Commands used for the static analysis were:

```bash
bundle exec gems/decomplex/exe/decomplex report \
  compiler/ruby/annotator compiler/ruby/mir \
  --output=/tmp/parallelization-decomplex.md

bundle exec gems/nil-kill/exe/nil-kill static \
  --root . --language ruby --source-role production \
  --output /tmp/parallelization-nil-kill-static.json \
  compiler/ruby/annotator compiler/ruby/mir

bundle exec gems/espalier/exe/espalier \
  --format report \
  --decomplex /tmp/parallelization-decomplex.json \
  --nil-kill /tmp/parallelization-nil-kill-analyzed.json \
  --output /tmp/parallelization-espalier.md \
  compiler/ruby/annotator compiler/ruby/mir
```

NilKill was a static-only run. It did not include runtime collection, so its
negative conclusions are about static type pressure, not runtime behavior.

## Ownership-Cleanup Post-Mortem

The abandoned branch had the right diagnosis and the wrong migration shape.
Ownership semantics were—and in several paths still are—reconstructed by AST,
annotation helpers, cleanup classification, MIR preparation, lowering, and the
emitter. The branch attempted to replace those authorities in one deletion-led
campaign. Its failed checkpoint changed 195 files, removed roughly 14,700
lines, added roughly 6,200, and left the compiler with:

- 41 unit failures and six integration failures;
- 29 transpile failures, including 11 crash/invalid-free cases;
- 58 positive fuzz runtime failures;
- 132 leak or double-free failures;
- 316 MIR invariant failures; and
- 47 stale negative tests that still exercised the deleted implementation.

The failure was architectural, not a long tail of ordinary bugs:

1. Old authority was deleted before the replacement was complete and proven.
2. The new resolver covered named cases, while lowerers continued making local
   ownership decisions and adding compatibility fallbacks.
3. The migration did not mechanically forbid semantic construction outside
   the proposed authority. At the failed checkpoint, 99 factory calls remained
   outside that boundary.
4. Contracts omitted allocator provenance and stable place identity, so later
   phases still needed context-sensitive reconstruction.
5. Tests were initially fail-fast. A crashing combined Zig test hid later
   failures, and a failed positive fuzz bundle hid its sibling cells.
6. Work continued after the first cross-product failures proved the boundary
   incomplete. Progress was reported by migrated call sites rather than by
   closed invariants and green executable witnesses.
7. The change simultaneously rewrote AST records, cleanup representation,
   resolver policy, MIR, lowering, checking, emission, and thousands of tests.
   There was no independently releasable intermediate state.

### What to retain

Do not cherry-pick the ownership resolver, model, deletion, or checkpoint.
Retain these ideas, independently and against current code:

- fail-complete positive fuzz isolation (already present as
  `tools/fuzz/fail_complete.rb` on this branch);
- fail-complete transpile execution, implemented in the normal transpile
  runner rather than as an unmaintained side script;
- an ownership-authority inventory that starts as a measured allowlist and
  becomes a CI prohibition one rule at a time;
- capability/tense/aggregate/generic cross-product witnesses;
- malformed-MIR tests expressed against the supported lifecycle-plan API;
- a closed set of lifecycle actions: borrow, move, retain, deep-copy, create,
  upgrade/downgrade, close, and destroy; and
- explicit allocator provenance plus stable place identity in every ownership
  plan.

### Rules that prevent a repeat

This project is additive-first. Existing behavior is removed only after the
new path is the production path, byte-identical on successful compilations,
diagnostic-identical on failures, and green under the complete corpus.

Each commit must:

1. Introduce or narrow exactly one authority boundary.
2. Keep the old implementation available only behind one explicit adapter;
   per-call-site fallback is forbidden.
3. Fail closed when a plan is missing; sentinel contracts, `contract ||
   fallback`, type-string reconstruction, and node-shape inference are
   forbidden in the new path.
4. Add a mechanical invariant before deleting the legacy producer it guards.
5. Run all unit, transpile, and fuzz lanes fail-completely.
6. Stop immediately if ownership/lifecycle repair occurs after plan
   publication or if a later phase discovers a new semantic owner.
7. Report analyzer and runtime deltas from the same target and command, not a
   subjective percentage-complete estimate.

The boundary refactor must therefore improve ownership architecture without
becoming a second attempt to replace all cleanup machinery at once.

## Measured MiniVM Baseline

The fresh profile used the production unchecked Sorbet mode:

```bash
bundle exec ruby tools/sample_compile_stacks.rb \
  --unchecked --top 8 \
  -o /tmp/ractor-vm-profile.json \
  examples/minivm/vm.clear
```

| Stage | Seconds | Share |
| --- | ---: | ---: |
| Lex | 0.147 | 1.0% |
| Parse | 0.252 | 1.8% |
| Annotation | 6.368 | 45.1% |
| Pipeline/string rewrites | 0.014 | 0.1% |
| Hoist | 0.143 | 1.0% |
| Pre-MIR type check | 0.073 | 0.5% |
| MIR pass | 1.688 | 12.0% |
| MIR lowering | 4.010 | 28.4% |
| MIR checker | 1.258 | 8.9% |
| Emission | 0.175 | 1.2% |
| Total | 14.128 | 100% |

Annotation itself was:

| Annotation phase | Seconds |
| --- | ---: |
| Resolution | 0.847 |
| Type analysis | 5.393 |
| Capability audit | 0.035 |
| Other annotation overhead | 0.094 |

The internal frontend time is lower than the roughly 18-20 second clean CLI
build because Ruby/compiler startup, CLI work, cache handling, and Zig command
overhead sit outside this phase timer.

### Function concentration

Existing per-function instrumentation shows that work is highly uneven:

| Function | Annotation | Lowering | Checking | Combined |
| --- | ---: | ---: | ---: | ---: |
| `runRegisterBytecode` | 2.531s | 2.097s | 0.835s | 5.463s |
| `loadPackedRegisterProgram` | 1.001s | 1.069s | 0.110s | 2.180s |
| `registerOpArity` | 0.102s | 0.084s | 0.009s | 0.195s |
| Typical small helper | 0.002-0.015s | 0.002-0.014s | under 0.006s | small |

This matters more than the machine's 32-core count. `runRegisterBytecode` is an
indivisible critical-path job under function-granular scheduling. Adding more
workers cannot shorten that job.

## Static Architecture Findings

The raw analyzer counts are not verdicts. They are useful here because several
independent detectors converge on exactly the objects that would have to be
split for function artifacts.

### Decomplex

For the annotator/MIR target, Decomplex reported:

| Signal | Count |
| --- | ---: |
| Cross-detector convergence units | 710 |
| Root-cause clusters | 629 |
| Decision pressure | 252 |
| State heatmap entries | 58 |
| Temporal ordering pressure | 17 |
| Missing abstractions | 137 |
| Reification misses | 13 |
| Derived-state staleness candidates | 8 |
| Implicit-control-flow protocols | 19 |
| Weighted inlined cognitive complexity | 263 |
| Locality drag | 48 |
| High-confidence operational discontinuities | 11 |
| Function LCOM candidates | 23 |

The most relevant findings were:

- `MIRLowering#lower` is both a dispatcher and a mutable-state coordinator.
- `FunctionAnalysis#visit_FunctionDef` and
  `MIRLoweringFunctions#lower_function_def` are top coordinator/complexity
  intersections.
- annotation has implicit write/read protocols such as preparing ownership
  transport before visiting a declaration value and computing FSM eligibility
  before enumerating suspend points;
- MIR has implicit protocols around pending statements, ownership hoisting,
  capture facts, pipeline contexts, and AST rewrites;
- the call and method lowering functions have multiple high-confidence
  internal phase discontinuities;
- list/hash annotation, binary classification, identifier lowering, allocator
  verification, and alias establishment still contain independently separable
  concerns.

Decomplex also propagates incomplete exponential known components through some
recursive MIR call paths. That is not proof that ordinary MIR lowering or
checking is exponential. The reports explicitly have unresolved call targets,
receiver types, and recursive progress. Treat those findings as an audit
request, not as a performance conclusion. Function-level work counters and
geometric input regressions remain the oracle.

### Espalier

Espalier indexed 399 owners, 3,993 functions, 301 state slots, 1,264 reads, 483
writes, and 35,245 delegation edges.

The highest relevant owner pressures were:

| Owner | Pressure | Methods | Important signal |
| --- | ---: | ---: | --- |
| `MIRLowering` | 1378.90 | 289 | 111 public methods; broad mutable coordinator |
| `MIRChecker` | 735.45 | 131 | broad checker/delegator surface |
| `MIRLoweringExpressions` | 626.80 | 116 | large domain fan-out |
| `MIRLoweringFunctions` | 580.80 | 93 | call/contract/ownership fan-out |
| `PipelineHost` | 533.95 | 95 | 18 state slots and many mutators |
| `PipeAnalysis` | 470.85 | 83 | annotation pipeline hub |
| `TypeAnalysisSession` | 337.75 | 87 | mutable traversal/audit/resolution lifecycle |
| `MIRPass` | 288.55 | 43 | 10 state slots; whole-program/local mixing |

The strongest state-lifecycle pressure included:

| State | Readers | Writers | Meaning |
| --- | ---: | ---: | --- |
| `MIRLowering#state` | 175 | 1 | one context supplies most lowering rules |
| `MIRLowering#active_lifecycle_registry` | 47 | 23 | lifecycle authority switched dynamically |
| `TypeAnalysisSession#traversal_state` | 36 | 5 | function/local traversal state |
| `TypeAnalysisSession#audit_inputs` | 29 | 5 | body work accumulates global audit input |
| `TypeAnalysisSession#resolution` | 21 | 5 | supposedly published context is repeatedly adopted/reset |

Espalier also reports `FunctionSignature` as 79 public methods, five private
methods, and 25 public mutators. Its intrinsic contract, analysis facts, and
contract are lifecycle state. A portable `ProgramInterface` cannot safely be a
thin wrapper around that mutable object.

The analyzer produced no useful privatization candidate list in this run. That
does not negate the broad API findings. Included lowering mixins and dynamic
host protocols make source-level ownership/visibility difficult to attribute.
The explicit 111/178 public/private split on `MIRLowering` and 79/5 split on
`FunctionSignature` are the stronger evidence.

### NilKill

NilKill reported:

- 114 files, 4,032 functions, and 315 fields;
- 26 static actions;
- 12 repeated-type alias recommendations;
- zero diagnostics;
- a highest `type-next` unlock of only five facts.

Most actions are redundant `T.must`, `nil?`, or `is_a?` guards after existing
contracts already establish the type. Nil/type ambiguity is not the primary
architectural problem in this surface. The dominant problem is semantic state
and temporal authority, not missing Sorbet annotations.

This matters to project scope: a function-artifact project should not turn into
another broad typing campaign. It should use explicit phase records to delete
some guards naturally, but NilKill cleanup alone will not create the needed
boundary.

## Real Bug Evidence from `~/easy-vm-testing`

The `easy-vm-testing` checkout contains three committed semantic-generator
expansions above the common `466fae2fc` baseline:

- `928025b2d` — complete semantic program generator;
- `d24966530` — advanced semantic oracle campaigns;
- `57139adae` — complete SELECT tense semantic matrix.

Its executable ledgers retain 33 fixed compiler gaps:

- 21 in `SemanticGaps`;
- 12 in `SemanticAdvanced`.

This branch does not yet contain those three commits. The testing checkout also
has uncommitted compiler/spec work as of this review. This project will not
depend on that dirty implementation; it will preserve the checkout and convert
its exposed failures into independent witnesses.

### Gaps directly relevant to the proposed boundary

At least 18 of the 33 committed gaps center directly on facts that should cross
the proposed annotation/MIR boundary:

- managed values nested in lists, maps, structs, tuples, and generic returns;
- source/destination allocator transport;
- ownership transfer into `TAKES`, owned sinks, and block results;
- cleanup of temporary tuples and optional/`OR_ELSE` branches;
- allocator convergence at lazy control-flow joins;
- lifecycle behavior for shared/multiowned strings, lists, maps, and tuples;
- generic identity return ownership and runtime requirements;
- ordered fallible/optional/stream wrapper preservation;
- stream result cardinality and fallible future payload lowering.

Representative bugs include:

| Gap | Architectural failure exposed |
| --- | --- |
| `takes_direct_list_literal` | transfer was emitted without an allocation source |
| `tuple_temporary_copy_leak` | temporary aggregate lifecycle was reconstructed incorrectly |
| `nested_owned_sink_allocator_transport` | nested move bypassed destination allocator transport |
| `collection_literal_child_allocator_transport` | child ownership was not represented in the containing artifact |
| `optional_owned_branch_allocator_convergence` | branch results reached lowering with inconsistent allocator facts |
| `tuple_temporary_allocator_convergence` | child and aggregate cleanup authorities disagreed |
| `managed_copy_give_takes_plain_parameter` | wrapper/payload ownership contract drifted at a call boundary |
| `generic_identity_owned_return` | generic return lost concrete ownership/runtime requirements |
| `select_outer_fallible_tense_lowering` | ordered semantic wrappers were flattened before execution lowering |
| `select_fallible_future_payload_lowering` | nested error payload facts were lost through FSM storage/lowering |

Several other gaps are partly related because a stronger function interface
would preserve contextual type/effect facts, but their implementation defects
remain local to pipelines, literals, or calls. A few are orthogonal, such as an
emitter-parentheses bug and a mismatched diagnostic code.

### Additional uncommitted testing evidence

The dirty testing checkout contains further fixes in annotation, hoisting,
lowering, the MIR checker, and `Semantic::LifecycleRegistry`. Those edits expose
the same recurring weaknesses:

- concrete generic field lifecycle types were absent from the annotation-time
  registry;
- lowerers had to decide ownership from implicit field allocator metadata;
- an ownership fact could be refreshed after a node was considered finalized;
- lazy `OR_ELSE` branch ownership became known too late for normal hoisting;
- aggregate children could acquire an owner after aggregate finalization;
- source type and coerced destination representation selected different copy
  strategies;
- anonymous borrowed aggregate arguments did not have a caller-side owner.

The important lesson is not that every edit in that dirty checkout is already
the correct final fix. The lesson is that ownership and lifecycle facts are
still being discovered or reconstructed at several different times by several
different subsystems. That is precisely what the proposed MIR planning boundary
must eliminate.

### Baseline decision for `fv`

Do not rebase this work directly onto the committed `fv` tip (`57139adae`). A
clean-worktree validation of that exact commit produced 12 failures among 7,088
non-integration unit examples. The failures cover asynchronous SELECT results,
semantic-equivalence generated values, managed `OR_ELSE` and tuple lowering,
visibility/audit gates, `for-each`, and legacy pipeline expectations. This is a
red base before any boundary-refactor code is applied.

The three commits remain valuable: they are executable semantic-oracle work
plus compiler fixes intended to make those oracles pass. Leaving the oracles
out would knowingly use a weaker test baseline. First create and validate a
clean `fv-stabilized` integration base. If the 12 unit failures have bounded
fixes and transpile/fuzz then pass, rebase onto that stabilized base. If the
failures expand into another broad repair campaign, port the generator/oracle
commits and their independently valid compiler fixes onto this branch instead.

Do **not** rebase onto the dirty `~/easy-vm-testing` worktree. Its additional
444-line compiler/runtime patch is valuable failure evidence, but it contains
late ownership repair in MIR lowering and new lifecycle-shape substitution.
Those edits have not been committed or independently validated, and several
are examples of the authority duplication this design is intended to remove.
Preserve the checkout untouched. Convert each exposed failure into a witness
on the clean `fv` baseline, then fix it through the new authoritative plan.

The integration order is therefore:

1. Fetch the local committed `fv` ref into this repository.
2. Validate that exact ref in a separate clean worktree.
3. Stabilize the 12 existing unit failures in an isolated branch, then run
   transpile and fuzz fail-completely.
4. Rebase onto the stabilized base only if all three lanes are green; otherwise
   port the oracle surface without its broken implementation changes.
5. Re-run all gates and capture the new performance/analyzer baseline.
6. Reproduce the dirty checkout's additional failures as tests, without
   copying its late-lowering repairs.

## Synergy Assessment

### Annotation refactor: strongly synergistic

The annotation refactor can directly improve current architecture if it does
all of the following:

- distinguishes declared program contracts from derived body facts;
- gives each function a fresh traversal state and diagnostic sink;
- returns a closed `LocalFunctionFacts` value instead of relying on a later
  scan of mutated AST and signature objects;
- moves effect, fallibility, `needs_rt`, stack tier, reentrance, lock, and
  caller-sync propagation into explicit summary-table computations;
- replaces mutation of published `FunctionSignature` objects with an immutable
  declared contract plus immutable derived contract;
- constructs lifecycle inventory from concrete instantiated types, not only
  symbolic declarations and whatever types happen to be found by walking the
  final AST;
- makes capability auditing consume function results rather than retain a
  mutable program-wide `audit_inputs` accumulator during body traversal.

Those changes address Espalier's `traversal_state`, `audit_inputs`, resolution,
and `FunctionSignature` lifecycle pressure. They also make hidden temporal
ordering visible in the type system.

The refactor is mostly orthogonal if it merely adds:

```ruby
def analyze_function(fn)
  visit_FunctionDef(fn)
end
```

around the existing session while the function still reads and writes global
scope, registry, signatures, and AST state. That would create a nominal API,
not an independent computation.

### MIR refactor: strongly synergistic, with the highest correctness value

The MIR split should establish one authority for each fact:

| Fact | Sole producer | Consumers |
| --- | --- | --- |
| Concrete lifecycle plan | annotation semantic planning | local MIR planning, lowering, checker |
| Local ownership/escape facts | function MIR planner | program graph propagation, materializer |
| Cleanup classification | function MIR planner after placement input is final | materializer, checker |
| Call/effect/runtime summary | local semantic analysis | whole-program fixed point |
| Final `needs_rt`/stack/effect result | program graph propagation | function materializer and emission |
| Ownership transfer plan | function MIR planner | materializer and checker |
| Generated-name seed/range | deterministic function input | lowering and artifact assembly |

The materializer must consume these plans. It must not infer lifecycle from Zig
types, allocator symbols, node classes, or the presence of an emitted cleanup.
It must not patch a supposedly finalized node because a child was hoisted later.

This directly addresses the bug pattern in `easy-vm-testing` and the analyzer's
dynamic `active_lifecycle_registry`, pending-statement, and coordinator/mutator
pressure.

The refactor does not automatically simplify:

- the 114-arm `MIRLowering#lower` dispatch;
- complex `lower_func_call`/`lower_method_call` routing;
- pipeline materialization and concurrent pipeline lowering;
- FSM liveness/splitting/emission;
- all of `MIRChecker`'s internal ownership-state logic.

Those remain real architectural debt. The function materializer should narrow
their public protocol and provide explicit inputs, but this project should not
rewrite every lowering domain.

### Incremental integration: mostly orthogonal product work

Incremental integration itself is cache and build-system logic:

- fingerprints;
- red/green decisions;
- reverse invalidation;
- portable encoding;
- cache publication/recovery;
- artifact assembly.

That work is necessary to realize reuse but does little to clean up annotation
or MIR on its own. Its architectural value comes from being forced to consume
the exact same products as a clean build. Roughly one quarter to one third of
the additional production code should live in `compiler/ruby/incremental/`.

## Proposed Architecture

### Overview

```text
source
  |
  v
lex + parse
  |
  v
DeclarationResolver
  -> ProgramInterface
       - declared types/schemas
       - declared function contracts
       - protocols/implementations
       - imports and public dependency keys
       - source-level policies
  |
  +---------------- function jobs ----------------+
  |                                                |
  v                                                v
FunctionAnalyzer(fn, ProgramInterface)        FunctionAnalyzer(...)
  -> LocalFunctionFacts                         -> LocalFunctionFacts
       - typed-node facts
       - calls/dependencies
       - direct effects/failure/runtime use
       - capability/capture/lock facts
       - local ownership/type inventory
       - diagnostics
  +-----------------------+------------------------+
                          |
                          v
ProgramSemanticFinalizer(all LocalFunctionFacts)
  -> DerivedProgramFacts
       - fixed-point effects/fallibility/needs_rt
       - stack/reentrance/FSM decisions
       - caller synchronization
       - lock/capability results
       - finalized function contracts
       - concrete lifecycle registry
                          |
  +---------------- MIR local jobs ----------------+
  |                                                |
  v                                                v
FunctionMIRPlanner(fn facts, derived facts)    FunctionMIRPlanner(...)
  -> FunctionMIRPlan                            -> FunctionMIRPlan
       - escape placement
       - cleanup plan
       - ownership transfers
       - loop/frame facts
       - lowering input/context
  +-----------------------+------------------------+
                          |
                          v
ProgramMIRPropagation(all FunctionMIRPlans)
  -> ProgramMIRFacts
       - graph-dependent placement/runtime adjustments
       - deterministic global contributions
                          |
  +---------- materialize/check/emit jobs ----------+
  |                                                  |
  v                                                  v
FunctionMaterializer -> MIR -> Checker          FunctionMaterializer -> ...
  -> FunctionCompilationArtifact
                          |
                          v
deterministic program artifact assembly
```

Clean compilation marks every function red and runs this exact pipeline.
Incremental compilation reuses green inputs/results and reruns fixed points over
the complete summary table. A future worker coordinator schedules the same
function calls without changing compiler semantics.

### `ProgramInterface`

`ProgramInterface` is a portable, immutable declaration product. It must not
retain AST nodes, scopes, function registries, callbacks, or Ruby object IDs.

Conceptual contents:

```text
ProgramInterface
  schema_version
  module_key
  language_mode
  source_policy_fingerprint
  imports[]
  types: StableTypeKey -> DeclaredTypeRecord
  functions: StableFunctionKey -> DeclaredFunctionContract
  protocols: StableProtocolKey -> ProtocolContract
  implementations[]
  sync_policy
  error_declarations[]
```

All identities must be stable across insertion/reordering. Session-local
`DefId`, `BodyId`, object IDs, and registry ordinals may appear only in a
current-process adapter.

`DeclaredFunctionContract` contains source-declared facts only. Inferred
fallibility, runtime use, effects, stack tier, and caller synchronization belong
in `DerivedFunctionContract`. Mixing the two recreates the current mutation
problem.

### Function analysis products

The current-process result and portable result should be separate:

```text
FunctionAnalysisResult              # Ruby process-local
  function_key
  typed function syntax/adapter
  local facts
  diagnostics

PortableFunctionSummary             # MessagePack/CLEAR boundary
  function_key
  body_fingerprint
  declared_interface_fingerprint
  direct_dependencies[]
  direct effects/failure/runtime facts
  call-site facts
  capability/capture/lock facts
  ownership/type inventory keys
  diagnostic fingerprint
```

The portable summary describes semantics; it does not serialize the annotated
Ruby AST. During migration, a `FunctionFactApplier` may stamp a freshly parsed
AST for existing MIR consumers, but it must be the single compatibility seam.
Long term, MIR should query function facts by stable node/place IDs rather than
AST instance variables.

### Whole-program finalization

Whole-program algorithms should become pure or bounded-mutation computations
over summary maps:

```text
finalize_effects(summary_map) -> effect_map
finalize_fallibility(summary_map) -> fallibility_map
finalize_runtime_requirements(summary_map, local_mir_summaries) -> needs_rt_map
finalize_stack_tiers(summary_map) -> stack_tier_map
finalize_reentrance(summary_map) -> reentrance_map
finalize_caller_sync(summary_map) -> caller_sync_map
finalize_lock_graph(summary_map) -> lock_report
```

They may use internal work queues, but their returned values are immutable and
their results must not depend on function visitation order.

A function's derived-interface fingerprint is computed from the subset of
these results visible to callers or downstream code generation. If a changed
body produces the same derived interface, reverse callers remain green.

### Lifecycle authority

`Semantic::LifecycleRegistry` is the right direction: it states that lowering
must not reconstruct copy/drop policy. The boundary project should complete
that architecture:

- inventory concrete generic instantiations and intermediate tense/collection
  shapes before MIR planning;
- key binding plans by stable place IDs rather than Ruby `object_id`;
- publish the registry once in `DerivedProgramFacts`;
- remove dynamic lifecycle-registry replacement from the lowerer;
- require every allocating, copying, retaining, transferring, closing, and
  dropping plan to cite a lifecycle-plan key;
- make missing lifecycle facts a stable compiler invariant error;
- prohibit lowerers and emitters from selecting a copy/drop strategy from Zig
  representation strings.

### `FunctionMIRPlan`

```text
FunctionMIRPlan
  function_key
  semantic_fingerprint
  local_places[]
  escape_placements: PlaceId -> Placement
  cleanup_plans: PlaceId -> CleanupPlan
  ownership_transfers[]
  loop_frame_plan
  capture_plan
  local_runtime_requirements
  lifecycle_keys[]
  generated_name_seed
```

The plan is complete before materialization. Normalization and hoisting may
produce MIR nodes, but they may not discover a new owner or cleanup policy that
was absent from the plan. If a normalization genuinely introduces a compiler
temporary, it must use a typed `TemporaryMaterializationPlan` produced through
the same ownership/lifecycle authority.

This rule is intentionally aimed at the testing-branch bugs where anonymous
aggregate children, lazy branches, or coerced copies became owners too late.

### `FunctionCompilationArtifact`

```text
FunctionCompilationArtifact
  function_key
  source_fingerprint
  declared_interface_fingerprint
  derived_interface_fingerprint
  dependency_fingerprint
  portable_function_summary
  portable_mir_summary
  emitted_fragments[]
  global_contributions
  source_map_entries[]
  diagnostics[]
  checker_proof_fingerprint
```

The cache artifact contains only primitive, bounded, versioned records. MIR and
AST objects remain current-process products and are never unmarshaled from
`.clearc`.

The checker proof fingerprint is not a substitute for checking new MIR. It
only establishes that a cached emitted fragment came from a previously checked
artifact under the same compiler/schema/invariant version.

## API and Visibility Cleanup

The architecture should expose a small protocol:

```text
DeclarationResolver#resolve
FunctionAnalyzer#analyze
ProgramSemanticFinalizer#finalize
FunctionMIRPlanner#plan
ProgramMIRPropagator#propagate
FunctionMaterializer#materialize
FunctionMIRChecker#check
ArtifactAssembler#assemble
```

Everything else is internal mechanism. This is not metric gaming: callers
should no longer be required to invoke hidden setup/finalization methods in a
specific order. Each public operation owns its full lifecycle and returns a
closed result.

Do not use `send` or reflection to reach private compiler methods. Do not make a
method private while retaining external call sites through dynamic dispatch.
Privatization is valid only after the public coordinator encapsulates the
necessary order.

For `MIRLowering`, the target is not necessarily one Ruby class. Existing
domain modules may remain, but a caller should see a function materializer with
one compilation entry point and a few read-only result queries—not 111 public
lowering helpers.

## Code Placement and Size

This work should be concentrated, but not mainly under `incremental/`:

| Location | Additional production LoC | Purpose |
| --- | ---: | --- |
| `compiler/ruby/semantic` or `compiler/ruby/compiler` | 300-600 | portable program/function records and final contracts |
| `compiler/ruby/annotator/phases` | 450-800 | independent body analysis and summary finalization |
| `compiler/ruby/mir` | 650-1,100 | local planning, graph propagation, materialization seam |
| `compiler/ruby/incremental` | 300-600 | artifact persistence, invalidation, replacement |
| emitter/compiler coordination | 100-200 | explicit fragments and clean-build orchestration |
| optional process coordinator | 150-300 | scheduling and deterministic join |
| **Total production** | **1,950-3,600** | |
| Tests/tools | 2,000-4,000 | differential, invariant, fuzz, scheduling, cache tests |

Expected effort is four to seven weeks for one engineer, assuming the testing
branch fixes are first reconciled and the semantic generator remains green.

The core boundary should remain useful without incremental compilation. Cache
policy belongs in `compiler/ruby/incremental`; semantic facts and normal phase
APIs do not.

## Expected Performance

### What can move in parallel

The following is plausibly function-local after the refactor:

- most of the 5.393 seconds of body type analysis;
- local escape/cleanup/lifecycle planning within the 1.688-second MIR pass;
- 4.010 seconds of MIR lowering;
- 1.258 seconds of MIR checking;
- small per-function emission work.

The following remains serial or fixed-point coordinated:

- lex/parse;
- declaration/import resolution;
- program-interface construction;
- effect/fallibility/runtime/stack/caller-sync/lock graph propagation;
- deterministic global contribution assembly;
- the largest individual function job.

### Expected clean-build result

An optimistic Amdahl calculation with 80% perfectly parallel work and four
workers suggests up to roughly 2.5x. That is not realistic for MiniVM because
work is badly imbalanced and `runRegisterBytecode` alone costs about 5.5
seconds across the candidate stages.

A more realistic model is:

```text
serial/fixed-point work                  2.0-3.0s
largest function critical path          5.5-6.5s
scheduling/serialization/merge overhead 0.5-1.0s
                                         --------
expected internal frontend              8.0-10.5s
```

Against the fresh 14.1-second internal baseline, the expected improvement is
approximately 1.35x-1.75x. Against an 18-20 second clean CLI build, the expected
result is approximately 13-16 seconds because startup and downstream work do
not disappear.

Confidence levels:

| Claim | Confidence | Reason |
| --- | --- | --- |
| Annotation/MIR dominate current time | high (0.95) | direct phase timings are stable across runs |
| Function jobs expose a material parallel fraction | medium-high (0.75) | measured per-function concentration, but global/local split is not implemented |
| Internal frontend reaches 8-10.5s | medium (0.60) | critical path is measured; local MIR-pass fraction and worker overhead are estimated |
| CLI build reaches 13-16s | medium-low (0.50) | Ruby startup, process behavior, memory COW, and Zig variance remain |
| More than four workers materially help MiniVM | low (0.20) | the largest function dominates |

The performance experiment must report median and p95 over repeated clean
builds with worker counts 1, 2, 4, 8, and 32. It must also report CPU time,
peak RSS, bytes copied/serialized, and per-function queue wait/run time.

### Incremental result

The existing best warm edit is already 1.13 seconds. A real semantic function
artifact might reduce it to roughly 0.6-0.9 seconds, but this is not enough to
justify the project by itself.

The larger incremental benefit is behavioral coverage:

- multiple changed functions;
- precise caller invalidation;
- derived-interface backdating;
- more body changes without reduced-source proof compilation;
- eventually selected signature/protocol/type changes.

## Ruby Concurrency Choice

Ruby Ractor is not currently a viable execution engine for this compiler:

- constructing `Lexer` inside a secondary Ractor fails because Sorbet's method
  wrapper closes over an unshareable `Proc`;
- requiring compiler code inside a Ractor fails through RubyGems' non-shareable
  activation monitor;
- the compiler contains thousands of Sorbet signatures and hundreds of
  `T::Struct` classes;
- AST, scope, schema lookup callbacks, and mutable semantic products are not
  shareable.

Do not remove Sorbet runtime typing or duplicate an unsigged worker compiler to
work around this.

After the function boundary exists, use a bounded persistent `fork` process
pool as the Ruby performance experiment. It can exploit copy-on-write after
compiler loading while still enforcing share-nothing function inputs/results.
The future CLEAR compiler can replace the scheduler with native CLEAR tasks
without changing semantic APIs.

The process pool is optional. The semantic/MIR refactor must be accepted on its
own architectural and incremental merits before concurrency code is merged.

## Required Invariants

1. Clean compilation and incremental compilation call the same semantic and
   MIR APIs.
2. Function analysis cannot mutate another function's local facts.
3. Published `ProgramInterface`, local summaries, derived facts, lifecycle
   registry, MIR plans, and artifacts are immutable.
4. Whole-program results are independent of function visitation order.
5. No semantic cache entry is keyed by Ruby object identity or session ordinal.
6. Every generated owner, transfer, cleanup, copy, retain, close, and drop is
   authorized by a lifecycle/ownership plan.
7. Lowering never reconstructs lifecycle policy from Zig strings or node-class
   guesses.
8. Normalization cannot introduce an unplanned owner. Compiler temporaries use
   the same typed materialization API as source bindings.
9. MIR checking is mandatory before publication of a new emitted artifact.
10. A corrupt, stale, unknown-version, or incomplete cache always falls back to
    a clean build.
11. Diagnostic order and generated Zig are deterministic across worker counts
    and scheduling orders.
12. One-worker execution is the reference implementation, not a separate slow
    path.

## Verification Plan

### Reconcile the testing evidence first

Before refactoring boundaries:

1. Commit and review the remaining `easy-vm-testing` changes.
2. Rebase or port the three semantic-generator commits and accepted compiler
   fixes onto the working baseline.
3. Run every positive witness in the 33-gap ledgers.
4. Establish a clean baseline for unit, transpile, fuzz, examples, benchmarks,
   leak, Sorbet, and Zig gates.

Refactoring on a branch that lacks known semantic fixes makes differential
equivalence much less valuable: it can faithfully preserve known-bad behavior.

### Function-isolation oracle

For every suitable corpus program:

1. Analyze all functions in source order.
2. Analyze them in reverse order.
3. Analyze them in multiple seeded random orders.
4. Analyze each function in a fresh function session.
5. Compare portable local summaries and final derived program facts exactly.

Any order dependency is evidence that the function input is incomplete or that
body analysis still mutates hidden global state.

### Clean/artifact differential oracle

For hundreds to thousands of mutations across examples, benchmarks,
transpile-tests, and generated semantic programs:

- clean sequential Zig must be byte-identical to artifact-assembled Zig;
- diagnostics must have identical codes, ranges, and deterministic order;
- worker counts 1/2/4/8/32 must produce identical results;
- randomized scheduling and worker restart must not change output;
- deleting or corrupting `.clearc` may change performance only;
- unsupported edits must report a reason and cleanly fall back.

### Ownership/lifecycle invariants

Add structural tests proving:

- every allocating MIR value has one allocation provenance;
- every transfer references an existing owner;
- every owner has exactly one terminal transfer/cleanup per path;
- all lifecycle keys used by MIR were published before MIR planning;
- generic instantiated field types are present in lifecycle inventory;
- no pass after plan publication changes ownership/lifecycle facts;
- lowering cannot execute when a required local or program plan is absent;
- the checker traverses every MIR statement and ownership-significant node.

Use the semantic generator's managed aggregate, optional/fallible, generic,
capability, pipeline, and stream families as positive fuzz inputs. Do not rely
only on manually constructed AST/MIR nodes.

### Coverage and mutation requirements

- 100% changed-line coverage for production Ruby changes;
- preference order: transpile/integration semantic programs, fuzz generation,
  compiler specs using CLEAR strings, then targeted record/invariant units;
- mutation tests must kill removal of lifecycle lookup, dependency edges,
  invalidation propagation, checker invocation, and deterministic merge logic;
- run unit specs through `prspec`.

## Analyzer Acceptance Criteria

Run the same analyzer target before and after each architectural phase. Do not
expect every raw count to fall when explicit records add types and methods.
Require directional improvements in the intended owners:

- `TypeAnalysisSession` state lifecycle and owner pressure decrease;
- `audit_inputs` and mutable resolution adoption disappear from body analysis;
- published function contracts have no public mutation protocol;
- `MIRPass` no longer mixes local planning, graph propagation, AST insertion,
  and signature resynchronization;
- `MIRLowering#active_lifecycle_registry` dynamic write pressure disappears;
- `MIRLowering` exposes a materially smaller public API;
- implicit-control-flow findings involving pending ownership/lifecycle setup
  decrease;
- no new high-confidence derived-state-staleness or broken-protocol findings;
- NilKill diagnostics remain zero and type pressure does not regress.

If metrics merely move from `MIRLowering` into a new `FunctionMaterializer`
without reducing responsibilities or public ordering requirements, the phase
has failed architecturally.

## Commit Sequence and Gates

Every numbered item is an independently reviewable commit. After each commit,
run the same Decomplex, Espalier, and static-only NilKill target over
`compiler/ruby/annotator` and `compiler/ruby/mir`, record the compact metrics,
and delete large intermediate evidence files. Also run unit specs through
`prspec`, all transpile tests, and the full fuzz matrix. A red stage is amended
or reverted; it is never used as the base for the next commit.

The stable per-stage metric ledger records at least:

- Decomplex convergence units, root clusters, decision/state/temporal
  pressure, implicit control, derived-state staleness, broken protocols, WICC,
  and locality;
- Espalier owner pressure/public-private/state counts for
  `TypeAnalysisSession`, `FunctionSignature`, `MIRPass`, `MIRLowering`,
  `MIRChecker`, `PipeAnalysis`, and `PipelineHost`;
- NilKill function/field/action/diagnostic counts; and
- MiniVM annotation, MIR pass, lowering, checking, total, and peak RSS.

Raw project-wide totals may rise when explicit immutable records replace
implicit state. Acceptance depends on the named owners and protocols improving,
with no compensating new god object.

### Commit 0: design, baseline, and authority guardrails

Work:

- document the ownership post-mortem and this boundary design;
- stabilize and integrate the committed `fv` semantic-oracle work without
  accepting a red baseline;
- add a current-code ownership/lifecycle authority inventory in report-only
  mode;
- make transpile execution fail-complete if the current runner still hides
  siblings after a crash; and
- capture all gates and analyzer/profile baselines.

Gate:

- all executable gap ledgers have no outstanding positive witness;
- current clean build is stable;
- no boundary refactor begins on known-unfixed ownership/lifecycle defects.

### Commit 1: immutable declared `ProgramInterface`

Work:

- introduce stable portable declaration records;
- split source-declared function contracts from inferred facts;
- publish stable type/function/protocol keys; and
- keep the mutable registry/AST compatibility adapter at one boundary.

Gate:

- sequential clean Zig and diagnostics remain exact;
- no portable record holds AST, `Type`, `Scope`, Proc, registry, or object ID.

### Commit 2: local function analysis products

Work:

- create fresh per-function traversal/audit state;
- return `LocalFunctionFacts`;
- retain one explicit AST fact-application adapter while MIR still consumes
  annotated syntax; and
- add source/reverse/random function-order equivalence tests.

Gate:

- function-order oracle passes;
- MiniVM annotation remains within 10% of baseline before parallelism.

### Commit 3: pure program semantic finalization

Work:

- derive effects, fallibility, runtime use, stack tier, reentrance,
  caller-sync, locks, and finalized contracts from the complete local-summary
  map;
- return immutable `DerivedProgramFacts`; and
- make clean compilation use declared plus derived contracts.

Gate:

- final results are invariant under summary iteration order;
- published signatures have no inferred-fact mutation protocol;
- `TypeAnalysisSession` mutable audit and resolution lifecycle pressure falls.

### Commit 4: complete lifecycle and stable-place authority

Work:

- inventory concrete instantiated generic, collection, capability, and tense
  shapes before MIR;
- key lifecycle/binding plans by stable place identity;
- add the closed action vocabulary and fail-closed plan lookup; and
- reproduce the uncommitted `fv` lifecycle/ownership witnesses without copying
  their lowering repairs.

Gate:

- every lifecycle key required by MIR is published before MIR planning;
- no type-string or Zig-shape lifecycle fallback exists on the new path;
- generic/aggregate/optional/capability cross-products pass leak checking.

### Commit 5: local `FunctionMIRPlan`

Work:

- move escape placement, capture, cleanup, transfer, loop-frame, temporary, and
  local-runtime preparation into one per-function plan;
- require generated compiler temporaries to use the same plan API; and
- retain existing materialization behind a single plan-consuming adapter.

Gate:

- all ownership/lifecycle generator witnesses pass under leak checking;
- no plan depends on function scheduling order;
- `MIRPass` no longer mixes these local analyses with program propagation.

### Commit 6: program MIR propagation and plan-only materialization

Work:

- make graph-dependent runtime/placement propagation consume function plans
  and return immutable `ProgramMIRFacts`;
- make materialization consume lifecycle/ownership/cleanup plans without local
  semantic reconstruction;
- remove dynamic lifecycle-registry replacement and late finalized-node repair;
  and
- keep the MIR checker mandatory before publication.

Gate:

- the authority inventory forbids the retired reconstruction classes;
- missing contracts are stable internal errors, never fallbacks;
- `MIRPass` and `MIRLowering` architecture metrics improve rather than move;
- emitted Zig and diagnostics remain exact.

### Commit 7: narrow compiler APIs and delete compatibility state

Work:

- make the clean compiler call only the public phase coordinators;
- minimize public methods and ordering-sensitive call sequences;
- delete the now-unused mutable signature, AST-stamping, and lifecycle adapters;
  and
- remove redundant nil/type guards exposed by total records.

Gate:

- no production `send`/reflection crosses visibility boundaries;
- Espalier public surface and state ownership pressure materially improve;
- Decomplex reports no new helper-only fragmentation, broken protocol, or
  hidden temporal ordering.

### Commit 8: incremental artifact adoption

Work:

- store portable summaries and finalized emitted artifacts;
- replace reduced-source recompilation where the new interface is sufficient;
- support multi-function and derived-interface invalidation;
- retain conservative fallbacks.

Gate:

- exact clean/incremental oracle passes across the mutation corpus;
- current 1.13-second warm leaf performance does not regress;
- supported-edit rate improves materially on recorded edit traces.

### Commit 9: tools-only concurrency experiment

Work:

- add a tools-only/process-pool coordinator;
- schedule function jobs by historical cost;
- collect deterministic outputs and measure CPU/RSS/serialization.

Gate:

- at least 20% median clean-frontend improvement on MiniVM;
- no worse than 10% p95 regression on small programs;
- acceptable peak RSS;
- byte-identical output under randomized schedules.

Only after this gate should production concurrency be considered.

### Commit 10: production scheduler, only if Commit 9 passes

Work:

- move the proven bounded process coordinator behind the normal clean-build
  phase APIs;
- retain worker count one as the reference path; and
- add deterministic scheduling, worker restart, and resource telemetry.

Gate:

- all worker counts produce byte-identical Zig and diagnostic-identical
  failures;
- median/p95/RSS thresholds from Commit 9 continue to hold in the production
  CLI;
- cold and warm results are reported separately.

If Commit 9 misses its speed/RSS gate, omit Commit 10. Commits 0-8 remain the
soundness, self-hosting, and incremental deliverable.

## Reasons Not to Do This Work

There are legitimate reasons to stop or defer:

### Incremental latency alone does not justify it

Warm leaf edits already take 1.13 seconds. Spending roughly 2,000-3,600
production lines only to save another few hundred milliseconds would be a poor
trade.

### Clean-build speedup is meaningful but not dramatic

Function-level scheduling cannot split `runRegisterBytecode`. The likely clean
CLI improvement is about 18-35%, not an order of magnitude. If performance is
the sole objective, profiling and optimizing the two hottest functions or
reducing repeated type-shape work may have a better LoC/payoff ratio.

### Ractor is not unlocked by semantic artifacts alone

Current Sorbet/Ruby runtime constraints still prevent compiler execution in a
secondary Ractor. If Ractor specifically is a hard requirement, this project
does not satisfy it without a much larger and unjustified runtime-type rewrite.

### The compiler is still discovering soundness bugs

The testing branch found 33 committed gaps and additional uncommitted
lifecycle/ownership issues. Freezing an incomplete semantic contract into a
portable cache can make bad architecture harder to change. The bug fixes and
their positive witnesses must lead the refactor, not follow it.

### A giant `ProgramInterface` can become a new god object

If every compiler detail is copied into one record, the project merely replaces
implicit shared state with an enormous explicit bag of state. Inputs should be
layered declared/derived/schema/function products with narrow consumers.

### Parallel processes increase memory use

Ruby copy-on-write helps only while workers do not mutate many shared pages.
Annotation and lowering allocate heavily. Peak RSS and allocator behavior can
erase the wall-time benefit or make CI less stable.

### Local lowering debt remains

The boundary does not make pipeline, FSM, call, literal, or checker internals
simple. If the project claims those wins without metric and code evidence, it
is overstating its result.

## Stop Conditions

Stop or redesign if any of the following occurs:

1. More than approximately 2,200 core production lines are added before clean
   compilation uses the new semantic and MIR boundaries.
2. More than approximately 3,600 total production lines are required for the
   bounded design before optional concurrency.
3. A portable record needs Ruby `Marshal`, AST nodes, `Type`, `Scope`, Procs, or
   object IDs.
4. Clean and incremental paths require separate semantic rules.
5. Cache-awareness appears inside annotation visitors or MIR lowering rules.
6. Ownership/lifecycle facts are still repaired after materialization begins.
7. Function results depend on visitation or scheduling order.
8. Analyzer pressure merely moves to newly named classes.
9. The process-pool experiment cannot improve MiniVM clean frontend time by at
   least 20%.
10. Peak memory or small-program latency makes the default build materially
    worse.

## Final Recommendation

The annotation and MIR boundary work is justified as soundness and self-hosting
architecture, with incremental reuse as a second benefit and concurrency as an
experiment. It is not justified as a Ractor optimization or solely as a way to
reduce the already-fast 1.13-second leaf-edit path.

The most valuable outcome is not four workers. It is a compiler in which:

- one function's semantic inputs are explicit;
- local and global facts have single authorities;
- ownership/lifecycle policy is complete before lowering;
- clean, incremental, hybrid Ruby/CLEAR, and parallel compilation use the same
  operations;
- the semantic generator can permute function order and prove that hidden
  mutable context no longer affects results.

Proceed through Commits 0-8 under the stated LoC, analyzer, performance, and
semantic-oracle gates. Decide whether to add the production scheduler only
after the tools-only concurrency experiment proves that the architecture pays
for itself independently.
