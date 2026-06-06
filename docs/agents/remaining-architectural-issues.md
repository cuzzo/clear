# Remaining Architectural Issues

This document tracks the larger architecture problems surfaced by the current
reports:

- `gems/espalier/report.md`
- `gems/decomplex/report.md`
- `gems/boobytrap/report.md`
- `gems/slopcop/report.md`
- `gems/nil-kill/report.md`

The goal is not to make individual methods prettier. The goal is to reduce
macro-complexity, make compiler state explicit, improve memory-safety
correctness, and move the implementation closer to the architecture shape used
by mature compilers such as `rustc`: typed phase boundaries, stable IDs, typed
IRs, explicit analyses, and code generation that consumes checked facts rather
than rediscovering semantics from mutable incidental state.

This is not a recommendation to copy `rustc` wholesale. Clear has different
constraints. The useful lesson is architectural: keep syntax, semantic facts,
lowered IR, ownership analysis, and backend emission separated enough that each
phase has explicit inputs, explicit outputs, and limited mutable state.

## 1. MIR Lowering Is A Mega-Owner And Implicit State Machine

### Problem

`MIRLowering` is currently the largest architecture-pressure owner. Espalier
reports `MIRLowering` at the top of state owner pressure with 57 state slots,
226 methods, 145 state touches, and broad delegation. Boobytrap also ranks
`src/mir/mir_lowering.rb` as the highest risk file, with the highest multi-file
fix blast radius: fixes touching it average many other files and have a very
large historical maximum blast radius.

This means MIR lowering is not just "a large file". It is acting as a mutable
compiler phase coordinator, semantic interpreter, ownership fact manager, and
backend preparation layer at the same time. That creates implicit temporal
ordering pressure: callers and helper modules must know which state exists,
which state has already been initialized, and which state is safe to consume.

### Why It Matters For Memory Safety

Memory safety depends on ownership, lifetime, cleanup, aliasing, and effect facts
being correct before codegen. If MIR lowering recomputes or mutates those facts
opportunistically, codegen can become sensitive to call ordering and incidental
state. That is exactly the kind of architecture where missing cleanup, stale
ownership state, or incorrect transfer state can hide behind successful local
tests.

### Rustc-Aligned Direction

Rust's compiler does not rely on one mutable lowering object to carry all
semantic, ownership, and codegen state. It moves through explicit
representations and analyses: AST/HIR-like syntax structures, typed semantic
facts, MIR, borrow checking over MIR, then codegen-oriented lowering.

The Clear compiler should move toward the same shape:

- AST and annotation facts are inputs.
- MIR construction is a typed construction phase.
- Ownership and cleanup facts are checked over stable MIR entities.
- Backend emission consumes already-checked MIR and facts.

### Status

Implemented in the current MIR lowering refactor. The detailed record is in
`docs/agents/mir-lowering-mega-owner-plan.md`.

The completed work removed `MIRLowering` from Decomplex temporal ordering
pressure, moved broad state into typed phase owners, removed migrated dynamic
lowerer reflection paths, and converted several mutation-heavy helpers into
typed plan-producing APIs. Follow-up work should focus on the remaining
state-based branch density in the newly explicit helper decisions, not on
restoring broad mutable lowerer state.

Closure note: final verification is recorded in
`docs/agents/mir-lowering-mega-owner-plan.md`. Decomplex total candidates fell
`7300 -> 6773`; cross-detector convergence fell `1821 -> 1803`; neglected
updates fell `1156 -> 685`; neglected path conditions fell `1663 -> 1581`;
and `MIRLowering` no longer appears as the temporal-ordering owner. SlopCop
dark arms fell `3287 -> 3220` and genuine gaps fell `1342 -> 1327`. Nil-kill
untyped slots stayed flat or dropped: params `981 -> 942`, returns `228 ->
225`, fields/ivars `1017 -> 860`, collections `0 -> 0`; hash-record pressure
fell `184 / 285 -> 183 / 281`.

### /plan

Detailed implementation checklist:
`docs/agents/mir-lowering-mega-owner-plan.md`.

1. Define a `LoweringInput` object containing the immutable inputs needed to
   build MIR for one compilation unit or function.
2. Split broad lowerer state into phase-specific context objects. Prefer names
   like `FunctionLoweringCtx`, `OwnershipLoweringCtx`, and `CleanupPlanBuilder`
   over shared `@current_*` state.
3. Move stateful helper behavior toward plan-returning APIs. A helper should
   return a typed `LoweringPlan`, `OwnershipTransferPlan`, or `CleanupPlan`
   instead of mutating broad lowerer state.
4. Introduce stable typed IDs for lowered entities: locals, places, allocations,
   functions, blocks, and temporaries. Avoid deriving ownership identity from
   strings, AST node object identity, or ad hoc hashes.
5. Make MIR construction and ownership checking separate phases. MIR lowering
   should not be both the producer of facts and the final judge of whether those
   facts are valid.
6. Add a metric gate for this area: state slot count, state-based branch
   density, and multi-file fix blast radius should decrease after each major
   migration.

## 2. PipelineHost Is Acting Like A Second Compiler

### Problem

`PipelineHost` ranks near the top of Espalier's state owner pressure and
Decomplex temporal ordering pressure. It has many public methods, substantial
state, broad delegation, and a large branch coverage gap in Boobytrap. The
`@lowering` lifecycle is especially concerning because it creates a bridge from
backend pipeline behavior back into MIR lowering internals.

This suggests pipeline lowering is not represented as an explicit compiler IR.
Instead, the host appears to orchestrate control flow, state, lowering calls,
concurrency behavior, and backend-facing decisions directly.

### Why It Matters For Memory Safety

Pipelines, concurrency, batch windows, background work, and stream-like behavior
are memory-safety sensitive. They affect capture lifetimes, transfer timing,
cleanup ownership, synchronization, and aliasing. If those decisions are encoded
as backend control flow around a mutable lowerer, they are harder to audit and
harder to test as semantic facts.

### Rustc-Aligned Direction

The better compiler shape is to reify pipeline semantics into an intermediate
representation before backend emission. The backend should consume a checked
pipeline plan, not infer it while emitting code.

### /plan

1. Introduce a typed pipeline IR with explicit variants such as map, filter,
   reduce, batch window, concurrent stage, stream source, and stream sink.
2. Move pipeline semantic analysis into a pass that produces typed facts:
   capture facts, ownership transfer facts, concurrency facts, and cleanup
   requirements.
3. Make `PipelineHost` a coordinator over typed pipeline plans rather than a
   broad mutable owner. Its job should become orchestration, not semantic
   interpretation.
4. Replace direct `@lowering` protocol dependence with a narrow adapter or
   builder interface. Pipeline lowering should request specific MIR operations,
   not reach into general lowerer lifecycle state.
5. Create invariant tests around concurrent and stream pipeline plans before
   changing emission behavior. These tests should assert ownership and cleanup
   facts, not just generated text.

## 3. The Type Model Is Too Loose At Phase Boundaries

### Problem

Nil-kill reports heavy union and nilability pressure around `.type`,
`.return_type`, `full_type!`, `SymbolEntry`, `Scope`, and `Type`. Decomplex and
Espalier also show `Type` as a high-pressure owner with substantial state and
many normalization sites. The codebase has many places where a value may be a
`Type`, `Symbol`, `String`, `NilClass`, or loosely typed collection depending on
phase.

That is a phase-boundary problem. Syntax-level type expressions, resolved
semantic types, inferred types, backend layout types, and diagnostic fallback
values should not all travel through the same loose channels.

### Why It Matters For Memory Safety

Ownership and memory-safety logic depends on knowing whether a value is affine,
copyable, borrowed, heap-backed, stack-backed, nullable, synchronized, or
capability-restricted. If type values are loose unions at phase boundaries, the
compiler can accidentally ask memory-safety questions of syntax placeholders,
symbols, nil sentinels, or partially resolved values.

### Rustc-Aligned Direction

Rustc separates syntax-level type expressions from resolved, interned semantic
types. The exact data model does not need to match Rust, but Clear should move
toward canonical resolved type identities and explicit type kinds.

### /plan

1. Introduce or strengthen a canonical resolved type representation, ideally
   with stable `TypeId` values and explicit type-kind variants.
2. Separate parser type syntax from resolved semantic types. A parsed annotation
   should not be interchangeable with a checked type.
3. Tighten `.type`, `.return_type`, and `full_type!` contracts so callers know
   exactly which phase representation they are receiving.
4. Replace `Symbol | Type | nil` style flows with explicit sum types or typed
   result objects. A missing type, unresolved type, inferred type, and concrete
   type should be distinguishable without sentinel values.
5. Prioritize nil-kill's high-pressure union and nilability sites before broad
   cosmetic typing work. The goal is to delete guards and normalizers, not add
   annotations around the existing ambiguity.

## 4. Ownership, Capability, And Escape Facts Are Spread Across Too Many Phases

### Problem

The reports point repeatedly at ownership and capability state: `MIR#ownership_effect`,
`@result_type`, `@capabilities`, ownership transfer helpers, capture analysis,
lifetimes, background/concurrency lowering, and checker state. These concerns
appear in annotation, MIR, MIR checking, lowering, and pipeline/backend code.

That distribution is expected in a compiler, but the problem is that the facts
do not appear to have a single authoritative representation with clear mutation
rules. When ownership logic is rediscovered in multiple phases, the compiler can
develop inconsistent answers.

### Why It Matters For Memory Safety

This is the most directly memory-safety-sensitive issue. The compiler needs one
consistent story for moves, borrows, escaping values, cleanup ownership,
capabilities, background captures, and synchronization requirements. If those
facts are implicit or duplicated, one path can produce code that another path
would have rejected.

### Rustc-Aligned Direction

Rustc performs borrow and move reasoning over MIR-level places and facts. The
important architectural lesson is that ownership checking happens over a
lowered, explicit representation with stable identities, not over scattered AST
conditions and backend side effects.

### /plan

1. Define one authoritative ownership fact graph over stable IDs. It should
   model owners, borrows, moves, aliases, cleanup obligations, escapes,
   capabilities, and synchronization requirements.
2. Make annotation produce preliminary facts, MIR construction attach those
   facts to stable MIR entities, and ownership checking validate the final
   graph.
3. Forbid backend emission from inventing ownership facts. Backend code may
   consume facts and request checked operations, but it should not be a semantic
   source of truth.
4. Make mutation windows explicit. Once an ownership fact table is frozen for a
   phase, downstream passes should either read it immutably or produce a new
   transformed table.
5. Add invariant tests for invalid moves, double cleanup, escaping borrows,
   background captures, capability violations, and sync requirements.

## 5. Weak Hash Records And Untyped Phase Bags Hide Compiler State

### Problem

Nil-kill reports many weak hash record candidates, including repeated
`BodyRecord`, binding, allocation, capture, and element-shape records. It also
reports high pressure from untyped struct/class fields, weak collections, and
unknown collection lookups.

These are not merely typing opportunities. In a compiler, hash-shaped phase
records often become implicit state machines: a key is present only after one
helper ran, omitted if another path was taken, or set to nil to mean several
different things.

### Why It Matters For Memory Safety

Memory-safety data cannot safely live in ambiguous maps. Missing keys, nil
defaults, stringly typed tags, and heterogeneous payloads can cause cleanup,
ownership, and capture logic to silently fall back to the wrong behavior.

### Rustc-Aligned Direction

Compiler phase data should be typed and explicit. Rustc relies heavily on typed
data structures, arenas, stable IDs, and query results. Clear should promote
high-pressure hash records into named domain records when doing so eliminates
ambiguous phase state.

### /plan

1. Promote the highest-pressure hash records into named typed records. Start
   with records involved in MIR lowering, concurrency, ownership, captures, and
   function bodies.
2. Name records by domain, not by generic shape. Prefer
   `ConcurrentBodyPlan`, `FunctionBodyShape`, `CapturePlan`, or
   `AllocationPlan` over generic `BodyRecord`.
3. Delete the old hash path when a typed record lands. Do not allow both shapes
   to remain live unless there is a temporary adapter with a removal date.
4. Distinguish absent, unresolved, invalid, and intentionally empty fields with
   explicit variants rather than nil or missing keys.
5. Use nil-kill to verify that the migration removes untyped slots, weak
   collection lookups, and repeated guard code.

## 6. Branch Hubs Mix Classification, Diagnostics, Mutation, And Emission

### Problem

Boobytrap, Espalier, Decomplex, and SlopCop converge on large state-based branch
hubs: match statement annotation, binary operation lowering, generic validation,
function signature verification, FSM emission, match lowering, intrinsic
lowering, and pipeline lowering.

Some branching is essential. The architectural smell is that many of these
branches appear to classify semantic cases, emit diagnostics, mutate state, call
other phases, and produce output in the same method.

### Why It Matters For Memory Safety

Memory-safety-sensitive branches should be inspectable as decisions. If a branch
both decides ownership behavior and mutates emitted state, it is hard to prove
that all ownership cases were handled before mutation occurred.

### Rustc-Aligned Direction

Prefer explicit analysis results followed by consumers. A classifier decides
what case exists. A validator checks it. A lowering pass consumes a checked plan.
An emitter emits from the plan. This reduces state-based branch density because
decisions become typed values.

### /plan

1. Convert the highest-risk branch hubs to classifier-plan-executor shape.
2. Make classifiers return sealed variants or typed plan records. Avoid returning
   loosely tagged hashes.
3. Move diagnostics into structured reason objects created during
   classification or validation.
4. Keep executors narrow. They should switch over already-classified variants
   and perform limited mutation.
5. Prioritize branch hubs that are also uncovered or fix-cache hotspots:
   `ownership_effect`, `lower_binary_op`, `visit_MatchStatement`,
   `validate_type_annotation!`, `verify_function_signature!`, `lower_match`,
   `lower_bg_block`, and pipeline lowering methods.

## 7. Coverage Gaps Mask Architectural Defects In Memory-Sensitive Areas

### Problem

Boobytrap and SlopCop show substantial uncovered branch and dark-arm pressure in
MIR lowering, MIR, pipeline lowering, type handling, formatter/tooling, and
annotation. The most important architecture concern is not raw uncovered line
count. It is uncovered state-based branch density in files that also have churn,
fix-cache history, and broad state ownership.

### Why It Matters For Memory Safety

A memory-safety compiler can be wrong in narrow edge cases. Those edge cases are
often branch arms: nilability fallback, ownership transfer exception, capture
mode, concurrent path, intrinsic special case, cleanup skip, or diagnostic-only
branch that accidentally permits emission.

### Rustc-Aligned Direction

Safety-sensitive compiler behavior should be tested at the invariant level. Text
goldens are useful, but they are not enough. The compiler should also expose
facts that tests can assert directly: ownership graph state, cleanup obligations,
borrow validity, capture mode, capability requirements, and emitted MIR shape.

### /plan

1. For every major architecture change above, add tests before the refactor that
   pin the current intended behavior.
2. Add invariant tests over MIR and ownership facts, not just generated output.
3. Treat uncovered state-based branch hotspots as priority targets when choosing
   refactor order.
4. Require regenerated Boobytrap, SlopCop, Decomplex, Espalier, and nil-kill
   reports for large compiler architecture changes.
5. Reject refactors that reduce method-local complexity while increasing
   state-owner pressure, temporal ordering pressure, or multi-file fix blast
   radius.

## 8. Multi-File Fix Blast Radius Shows Missing Phase APIs

### Problem

Boobytrap reports very high multi-file fix blast radius for `src/mir/mir_lowering.rb`
and related compiler files. This means bug fixes frequently cross parser, AST,
MIR, lowering, checker, backend, and specs together. Some cross-phase work is
normal in a compiler. But frequent broad fix commits suggest the architecture is
missing stable phase APIs.

### Why It Matters For Memory Safety

When a memory-safety fix must touch many files, it is easy to repair one path
and leave another path inconsistent. Broad fixes also make review harder: a
reviewer must understand syntax, semantics, MIR, ownership, and backend behavior
simultaneously.

### Rustc-Aligned Direction

Mature compilers reduce blast radius with stable phase products. Parser changes
produce syntax. Annotation produces semantic facts. MIR lowering consumes typed
facts. Ownership checking consumes MIR-level places. Backend emission consumes
checked IR. A feature may cross phases, but each phase should have a clear API
for what it accepts and produces.

### /plan

1. Define explicit phase API contracts for parser output, annotation facts, MIR
   construction input, ownership analysis output, and backend emission input.
2. Introduce adapters where needed, but keep them temporary. The goal is to move
   callers to stable phase APIs, not add another abstraction layer forever.
3. Track fix blast radius as an architecture metric. A successful phase-boundary
   migration should reduce the number of files touched by routine bug fixes.
4. Review new features by phase: syntax shape, semantic facts, MIR plan,
   ownership impact, backend emission. Avoid feature patches that directly wire
   all phases together through shared mutable state.
5. Use the compiler reports as acceptance criteria. Large changes should reduce
   at least one of: owner pressure, state lifecycle pressure, temporal ordering
   pressure, state-based branch density, or multi-file fix blast radius.

## Prioritized Implementation Plan

The strategic priority and the next implementation priority are not the same.
The full ownership/capability fact graph is probably the largest architecture
win, but it has the most unknowns and the highest blast radius. The next work
should choose a slice that is still memory-safety-relevant, overlaps multiple
reports, is local enough to finish with strong coverage, and creates typed
phase products that later make the larger ownership work easier.

### Ranking Criteria

- **Impact**: reduces memory-safety ambiguity, state/control-flow complexity,
  fix blast radius, or high-pressure report findings.
- **Ease**: can be implemented as a local migration with existing tests and
  without inventing new compiler semantics.
- **Unknowns**: how much behavior must be rediscovered before the work is safe.
- **Confidence**: likelihood that the change can be completed cleanly and
  improve metrics without opening a rewrite.

### Evidence Used

- Espalier ranks `PipelineHost` as the #2 state owner pressure site and
  `MIRLowering` as #3.
- Boobytrap ranks `src/mir/mir_lowering.rb` as the highest defect-risk file and
  `src/mir/lower/pipeline/pipeline_host.rb` as #3.
- Nil-kill points at repeated weak hash records in `PipelineHost`, especially
  `build_lazy_range_prefix`, and capability-lowering hash records in
  `src/mir/lowering/capabilities.rb`.
- Decomplex shows broad convergence around ownership, sync/layout state,
  pipeline analysis/lowering, and loose phase contracts.

### Recommended Order

| priority | work | impact | ease | unknowns | confidence | why now |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| P0 | **Typed PipelineHost phase records** | High | High | Low | Very high | Big overlap: Espalier #2 owner, Boobytrap #3 hotspot, nil-kill repeated weak hash records. Local, testable, and already partially started by typed callback records. |
| P1 | **Typed capability/guard plan records** | High | Medium-high | Low-medium | High | Directly memory-safety-sensitive lock/capability state. Nil-kill identifies concrete hash records; implementation should be mostly local to capability helpers. |
| P2 | **OwnershipGraph typed node table and place IDs** | Very high | Medium | Medium | Medium-high | Smaller gateway into the larger ownership fact graph. It addresses memory safety directly without trying to split all MIR lowering first. |
| P3 | **PipeAnalysis option/result records** | High | Medium | Medium | Medium | Decomplex flags pipeline analysis heavily. This pairs well with P0 but is earlier-phase semantic analysis, so it has more behavior to preserve. |
| P4 | **Function/body lowering context records in MIRLowering** | Very high | Medium-low | Medium-high | Medium | Important, but it touches the highest-risk file. Do after P0/P1 establish the pattern and tests. |
| P5 | **Type phase boundary tightening** | Very high | Low-medium | High | Medium-low | Huge payoff, but high unknowns because `Type` currently carries syntax, semantic, backend, and fallback roles. Start only with a narrow sub-boundary. |
| P6 | **Full ownership/capability fact graph separation** | Highest | Low | Highest | Medium-low | Correct strategic destination, but too large for the first high-confidence win. Use P1/P2/P4 to reduce unknowns first. |

## P0 Design: Typed PipelineHost Phase Records

### Why This Is The Best First Win

`PipelineHost` has the best impact-to-risk ratio. It is a top architecture
pressure owner, a high Boobytrap hotspot, and a nil-kill weak-record cluster,
but many of the highest-confidence fixes are representational: replace
hash-shaped phase bags with typed records while preserving behavior.

This is not cosmetic typing. The current lazy-range prefix hash encodes a
mini state machine:

- `range_let` exists only for non-variable stream sources.
- `source_name` and `next_method` define the source lifecycle.
- `outer_stmts` and `stage_stmts` must be emitted in a specific order.
- `item_var`, `initial_capture`, and `item_used` encode capture semantics.
- `elem_zig` carries element type information that downstream code assumes.

Making that record typed turns hidden temporal assumptions into explicit
fields. It also gives later Pipeline IR work a concrete first data product.

### Proposed Records

```ruby
class LazyRangePrefix < T::Struct
  const :range_let, T.nilable(MIR::Let)
  const :source_name, String
  const :next_method, String
  const :outer_stmts, T::Array[MIR::Emittable]
  const :stage_stmts, T::Array[MIR::Emittable]
  const :item_var, String
  const :initial_capture, String
  const :item_used, T::Boolean
  const :elem_zig, String
end
```

Likely follow-on records:

- `PipelineSourceSetup`: setup statements plus source/items pointer for list,
  stream, and bounded-stream sources.
- `ObservableFoldPlan`: accumulator allocation, publish statements, source
  cleanup, and terminal kind.
- `BcIterRange`: already exists as a tuple alias; convert to a named record if
  it starts accumulating more fields.

### /plan

1. Add `LazyRangePrefix` as a `T::Struct` in `PipelineHost`.
2. Change `build_lazy_range_prefix` to return `LazyRangePrefix`.
3. Replace all `p[:...]` reads in range/observable pipeline lowering with field
   accessors.
4. Delete `RangeFoldPrefix = T::Hash[Symbol, Object]` if no caller still needs
   it.
5. Add focused tests that assert the plan shape directly:
   - range source has a `range_let`;
   - variable stream source has no `range_let`;
   - `LIMIT`, `SKIP`, `WHERE`, and `TAKE_WHILE` populate ordered stage
     statements;
   - observable cleanup uses the plan's `item_var`;
   - bytecode paths consume the same plan fields.
6. Run `bundle exec srb tc`, targeted pipeline specs, full specs, and
   `tools/diff_bucket_summary.rb` to verify source guardrails and nil-kill
   pressure improve or stay flat.

### Acceptance Criteria

- No new `T::Hash[T.untyped, T.untyped]` or hash-record guardrail findings in
  `PipelineHost`.
- Nil-kill weak hash-record entries for `build_lazy_range_prefix` disappear or
  decrease materially after recollection.
- PipelineHost behavior is unchanged in existing specs.
- New tests cover every newly added/changed line and the meaningful branches in
  the plan builder.
- Decomplex and Espalier metrics should improve or remain flat for
  `PipelineHost`; any local increase must be explained.

### PipelineHost Completion Checklist

The WIP refactor deleted the legacy backend host/generator, moved MIR pipeline
lowering to `src/mir/lower/pipeline`, and split materializer, range, each,
batch-window, set-index, context, and concurrent lowerers. The remaining work is
the rest of the same architectural issue, not a separate cleanup:

- [x] **PipelinePlan dispatch record**: decode `AST::BinaryOp` pipeline shape
  into a typed plan before dispatch. `PipelineHost#lower_pipeline` should stop
  re-reading `lhs`, `rhs`, `lhs_type`, SOA/range/binding facts, and operation
  class directly in a branch hub.
- [x] **PipelineScalarLowerer**: move count/sum/average/min/max/any/all/find
  materialized scalar terminals out of `PipelineHost`, with a typed services
  object for expression lowering, block construction, labels, and type
  translation.
- [x] **PipelineListLowerer**: move materialized list/filter/transform
  terminals (`WHERE`, `SELECT`, `LIMIT`, `TAKE_WHILE`, `SKIP`, `DISTINCT`,
  `UNNEST`, `REDUCE`, `WINDOW`, `ORDER_BY`, `JOIN`, `TAP`) out of
  `PipelineHost`, preserving ownership/cleanup behavior through typed
  materializer services.
- [x] **PipelineObservableLowerer**: move range-observable terminal scaffolding
  and allocation/catch/publish helpers out of `PipelineHost`, so range and
  set-index lowerers consume an explicit observable terminal plan instead of
  host callbacks.
- [x] **Binding-chain lowering plan**: replace `BindingUnnestChain` plus
  `lower_binding_fold` hash/name plumbing with typed binding-chain fold records
  that make outer binding, inner binding, stage wrapping, and bytecode wrapping
  explicit.
- [x] **Narrow final host API**: after the extractions, `PipelineHost` should
  primarily own context stack, service construction, top-level plan dispatch,
  and the narrow adapter to `MIRLowering`. Any remaining direct `@lowering`
  call must be justified as an adapter operation.
- [x] **Metric and coverage closure**: rerun Decomplex, SlopCop, and nil-kill
  from the midpoint snapshot to final. Decomplex and SlopCop should move down
  overall; nil-kill untyped slots must stay flat or decrease; 100% of
  added/changed lines and roughly 80%+ changed branches must be covered.

Status note: the observable terminal implementation is owned by
`PipelineRangeLowerer`; the remaining `PipelineHost` observable methods are
adapter shims for existing direct test/caller surface, not implementation
owners.

Closure note: final changed-line coverage is 669/669 (100.0%) and changed-branch
coverage is 108/122 (88.5%). Decomplex total fell 15665 -> 15322, with the
largest drops in inconsistent rename clones, neglected path conditions, broken
protocols, and false simplicity. SlopCop dark arms fell 8276 -> 3287 in the
original reports. A follow-up controlled full-coverage rerun showed the apparent
genuine-gap jump was measurement drift: the narrow midpoint report had only 71
files, while the controlled midpoint had 117 files and already had 1354 genuine
gaps. Apples-to-apples full-coverage SlopCop was 3303 -> 3287 dark arms and
1354 -> 1354 genuine gaps under the same direct-report invocation; with bundled
decomplex attribution, final genuine gaps were 1342 because 12 additional arms
classified as spurious. Either way, the refactor did not add genuine gaps.
Nil-kill untyped slots stayed flat or fell: params 989 -> 981, returns 229 ->
228, fields/ivars 1017 -> 1017, collections 0 -> 0. The nil-kill collection
completed with the same expected failed workload stages as the midpoint
snapshot: `integration-specs` and `examples-build`.

## P1 Design: Typed Capability/Guard Plan Records

### Why This Comes Second

Capability and guard lowering is directly memory-safety-sensitive: it affects
locked access, aliasing, guard variables, address expressions, and cleanup
requirements. Nil-kill identifies concrete weak hash records in
`src/mir/lowering/capabilities.rb`, so the unknowns are bounded.

The work should follow P0 because it is the same architectural pattern applied
to a more safety-sensitive subsystem: replace phase bags with named records,
then make consumers read explicit fields.

### /plan

1. Identify the specific local hash records named by nil-kill, especially the
   `cap` and `e` records in capability lowering.
2. Introduce domain records such as `CapabilityAliasPlan`,
   `LockGuardEmission`, or `WithAliasPlan`. Use names from the actual code path,
   not generic `CapRecord`.
3. Convert constructors first, then consumers. Do not keep hash and struct
   paths live in parallel except through a temporary private adapter.
4. Add invariant tests around lock guard ordering, alias owner/alloc state,
   address expression emission, and cleanup/restore behavior.
5. Re-run nil-kill and Decomplex to verify the migration removes weak lookups
   and state-based branch pressure rather than moving it.

## P2 Design: OwnershipGraph Typed Node Table

### Why This Is The First Ownership-Graph Slice

The full ownership fact graph is the strategic destination, but the smallest
high-confidence gateway is to make the existing ownership graph's node table
typed and explicit. Nil-kill reports weak indexing around `@nodes`, and
Boobytrap already ranks `src/mir/ownership_graph.rb` as a risk file. This gives
us a direct memory-safety win without splitting all of MIR lowering.

### /plan

1. Audit `OwnershipGraph` node payloads and operations: create, move, borrow,
   drop, alias, and lookup.
2. Introduce typed IDs or a typed key wrapper if string keys currently mix
   bindings, places, paths, and synthetic temporaries.
3. Type `@nodes` as a map from the stable key type to a named node record.
4. Replace weak lookups with methods that encode absence explicitly:
   `fetch_node`, `node?`, `ensure_node`, or a typed result object.
5. Add invariant tests for move/drop/borrow edge cases before broad callers are
   changed.

## Work To Defer

The following remain strategically important, but they should not be first if
the objective is a confident high-impact win:

- **Full MIRLowering separation**: huge payoff, but it touches the highest
  Boobytrap hotspot and many mutable phase assumptions. Start by extracting
  typed records from the seams before splitting the coordinator.
- **Type model overhaul**: likely one of the biggest long-term wins, but the
  current `Type` object carries too many roles. Begin only with narrow
  sub-boundaries after the pipeline/capability record migrations prove the
  pattern.
- **General branch-hub rewrites**: classifier-plan-executor is correct, but it
  becomes risky if done before the data products are typed. Do it after the
  relevant plan records exist.

The ordering matters. Local cleanup should wait when it does not reduce hidden
state, implicit control flow, or memory-safety ambiguity. The highest-value
near-term work is the work that makes compiler facts explicit and prevents
later phases from guessing, while keeping the implementation small enough to
test thoroughly.
