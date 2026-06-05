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

### /plan

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

## Suggested Priority

1. Ownership/capability fact graph and MIR lowering separation.
2. Type model tightening at phase boundaries.
3. Pipeline IR and pipeline host containment.
4. High-pressure hash record promotion in memory-sensitive paths.
5. Branch hub classifier-plan-executor migrations.
6. Coverage and invariant tests around the above.
7. Phase API stabilization to reduce future blast radius.

The ordering matters. Local cleanup should wait when it does not reduce hidden
state, implicit control flow, or memory-safety ambiguity. The highest-value work
is the work that makes compiler facts explicit and prevents later phases from
guessing.
