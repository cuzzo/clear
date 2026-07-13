# CLEAR self-hosting readiness audit

Status: **Core compiler gates restored; not ready for the self-hosting cut-over**
Audited revision: `171f1f3caeb5` plus the pending `graphs` readiness fixes
Audit date: 2026-07-10

## Executive verdict

CLEAR has an unusually ambitious and substantially implemented core: affine
ownership, capability-selected storage and synchronization, tense values,
pipelines, deterministic cleanup, generics, function values, a fiber runtime,
and now object-style cyclic data through `@node`. The strongest parts already
support CLEAR's intended identity: ordinary code can stay high level while a
binding or type declaration selects a lower-level realization without changing
the surrounding algorithm.

The repository is not yet ready for self-hosting as an execution project, but
the immediate compiler-composition crisis found by the first audit has been
resolved. The exact unit suite, exact integration suite, all 474 transpile
programs, module/FFI integration, MiniVM native execution, and the normal Zig
runtime lane now pass. The safe-index migration also uncovered and fixed
optional-promise typing, forwarded mutable-list pointer shape, generic return
ownership, fixed-array cleanup classification, and stale double-destruction in
Rc payload cleanup.

The remaining readiness risk is now architectural and corpus-wide rather than
"the compiler cannot compose its own implemented features": strict
examples/benchmarks are not yet an honest gate; the WALKTHROUGH harness still
does not execute the document; real programs barely dogfood generics or
function values; the package/build plan and minimum self-host standard library
remain implicit; `@node` still uses a type/runtime-wide lifetime domain; and
the repository's Sorbet/RuboCop lanes have large pre-existing baselines.

Some of those failures are stale tests and examples, not missing language
implementation. In particular, range and open-stream pipelines, `@split`,
sync polymorphism, and `@node` all have current implementation/spec evidence.
The audit therefore distinguishes four states throughout:

1. **implemented and proven** by an end-to-end or integration test;
2. **implemented but composition-broken** in a broader gate;
3. **documentation/example drift**, where implementation should remain and the
   corpus should be migrated;
4. **a real semantic or implementation gap**.

The recommended next milestone is a **self-hosting readiness release**, not the
self-host itself. It should make the existing language coherent, strict, and
dogfooded; define the minimum static protocol abstraction needed by the
compiler; and land an explicit build/package plan. Once its acceptance gates
are green, begin self-hosting in vertical slices.

## Decision rubric

Recommendations in this document are ordered by these goals:

1. **Minimize global complexity; maximize local reasoning.** A declaration or
   expression should carry the facts needed to understand it. Avoid hidden
   process-wide policy, action-at-a-distance, and phase-order protocols.
2. **Maximize optionality, especially polymorphic synchronization.** Code
   should state the semantic requirement while callers retain freedom to pick
   a valid storage/synchronization realization.
3. **Minimize cognitive complexity through progressive disclosure.** The safe,
   ergonomic path should require few concepts. Specialists may opt into layout,
   allocation, scheduling, or unchecked escape hatches when measurement
   justifies them.
4. **Maximize safety.** Invalid lifetimes, stale handles, races, unchecked
   indexing, ownership errors, and unhandled effect families should be rejected
   statically where possible and checked deterministically otherwise.

These goals rule out importing a Rust-like trait/lifetime vocabulary merely
because the compiler needs abstraction. They also rule out solving ergonomics
with hidden global lifetime domains whose behavior cannot be inferred locally.

## Evidence and confidence

### Current gates

| Surface | Command or evidence | Result | Classification |
|---|---|---:|---|
| Ruby unit CI | `bundle exec prspec compiler/spec/ --format json` | **6,293/6,293 pass** | Core unit composition restored |
| Ruby integration CI | `bundle exec prspec compiler/spec/ --tag integration --format progress` | **236/236 pass** | Includes LSP, native MiniVM/debugger, and `@node` RAII integration |
| Transpile corpus | `TRANSPILE_GEN_JOBS=$(nproc) bundle exec ruby transpile-tests/gen.rb` | **474/474 generate** | Safe-index migration complete for this corpus |
| Module/FFI integration | `zig build test` in both integration projects | **pass / pass** | Cross-module and native-boundary smoke are green |
| `@node` RAII integration | `node_raii_integration_spec.rb --tag integration` | **1/1 pass** | Implemented and proven for cyclic payload cleanup at the tested function boundary |
| Pipeline/sync focused specs | legacy pipeline matrix + sync-polymorphism integration | **22/22 pass** | Current implementation contradicts several stale benchmark README claims |
| Fuzz matrix | targeted affected-template matrices | final **458/458 pass** across the eight migration-sensitive templates, plus **30/30** focused escape-mechanism cells; an earlier 488-cell diagnostic run found four stale templates that are now repaired | Re-run all five clean CI shards; do not call the full fuzz gate proven yet |
| Benchmark smoke (partial) | `benchmarks/runner.rb --smoke --all --cores=2` | First 17 concurrent directories inspected; **10 CLEAR builds failed** | Stopped after the failure pattern was established; useful as build evidence, not a complete benchmark result |
| Zig runtime suites | `zig build test` | **pass**, including all 14 paged-slot-map tests and bounds-safe forwarded-list lookup | Strong runtime base; one direct generated-root link requires the normal assembly-aware build path |
| Register MiniVM | native golden runner plus integration aggregate | runner builds and executes; **198 golden examples pass with four explicit pending emitter shapes** | The separate 245-case allowlist still needs a clean dedicated run |
| Self-host translator audit | `ruby-to-clear-audit` over `compiler/ruby/**/*.rb` | 99.06% useful LoC; 145 complete, 23 partial, 1 failed | Encouraging syntax coverage, **not** semantic/build readiness |

The older 53-unit/32-integration/3-transpile/81-fuzz counts remain useful as the
baseline that triggered this repair, but they are no longer the current state.
The repository-wide Sorbet typecheck and signature-only RuboCop commands still
fail independently with broad pre-existing debt; do not conflate those static
baselines with the restored compiler behavior gates.

### Why CI currently overstates corpus health

The repository does have examples/benchmarks jobs, but their names are stronger
than their contracts:

- `tools/corpus_transpile_coverage.rb` catches every exception, prints
  “skipped,” and exits successfully.
- `tools/corpus_runtime_coverage.rb` is non-strict in CI. It exits successfully
  if anything passed, even when other programs failed.
- `tools/clear-nil-kill-transpile-corpus.sh` and its REQUIRE generator contain
  explicit exclusions for MiniVM and concurrency programs that do not compile.
- the REQUIRE-wrapper corpus proves that modules can be imported, not that each
  application entry point builds and runs.

This is useful coverage collection, but it is not a buildability gate. Rename
coverage-only jobs accordingly and add a strict manifest of supported programs.
Known failures may remain in a visible, expiring quarantine; they must not be
silently counted as a green corpus.

## WALKTHROUGH audit

### The WALKTHROUGH is not actually tested

`compiler/spec/doc_examples_spec.rb` searches root-level `WALKTHROUGH.md`, but
the file is `docs/WALKTHROUGH.md`. It therefore extracts zero WALKTHROUGH code
blocks. Of the 40 CLEAR fences in the document, 23 are also marked
`illustrative`, and the harness intentionally skips illustrative blocks.
Manual extraction found that many remaining blocks are declarations,
intentional compiler-error demonstrations, or non-self-contained fragments;
the current wrapper cannot classify those correctly.

Replace the harness with metadata-aware documentation tests:

- `compile`, `run`, `compile-error CODE`, and `illustrative` block kinds;
- optional shared prelude/module context;
- exact source path and line in failures;
- no automatic wrapping of declaration blocks inside `FN main`.

This is a local-reasoning feature: users should be able to trust the nearest
language example without reconciling it against compiler specs.

### Direct contradictions and drift

1. The primitive table calls `String` affine, while the ownership section says
   strings are Copy types that can be freely reused. Current ownership and
   cleanup tests use `COPY` for owned strings. **Fix the WALKTHROUGH**, retaining
   explicit affine ownership and deep-copy syntax.
2. The quick capability reference omits important implemented capabilities,
   including `@node`, `@split`, `@soa`, `@set`, `@versioned`, `@atomic`, and
   `@observable`.
3. The graph section is current enough to show object-style `@node`, but the
   quick reference still says only `@link` creates cyclic graphs.
4. The walkthrough says `@sharded` automatically pins work, while detailed
   collection docs distinguish ordinary sharded access from `SHARD` routing
   and contain more precise restrictions. Replace the broad claim with the
   exact supported patterns and link to executable integration cases.
5. Several benchmark READMEs claim that range/open-stream pipelines and split
   streams are missing. Current pipeline and `@split` specs prove those claims
   stale. **Fix those examples/READMEs**, unless a full build exposes a narrower
   backend failure.

### Material missing from the WALKTHROUGH

The walkthrough should teach the common path first, then link to advanced
chapters for costs and escape hatches. It currently lacks or barely covers:

- generic functions, inference, constraints, and generic error messages;
- function values/callbacks, reentrancy, and why `NON_REENTRANT` sometimes
  appears;
- `METHOD` and the intended abstraction/encapsulation model;
- maps and sets as ordinary collections;
- tests (`TEST`, `WHEN`, assertions) and package-local test execution;
- capability-polymorphic function boundaries with `REQUIRES`;
- `WITH POLYMORPHIC` and the sync-family model;
- atomics, MVCC/versioned values, observables, and when they are advanced tools;
- cancellation, stream ownership, and structured concurrency boundaries;
- package/module resolution, native dependencies, and build outputs;
- diagnostics and `clear fix` as part of the progressive-disclosure design;
- the explicit unsafe/FFI boundary (`@raw`, EXTERN ownership, CLOSE);
- the safe-index rule: every `@list` index introduces a fresh optional
  boundary, while one `?.` covers the following non-optional member chain.

Do not put all of those mechanisms in the first tour. The first path should be
“values, functions, structs, optionals, collections, ownership, errors, tests.”
Capabilities, tense, sync polymorphism, custom layout, and FFI should be
graduated layers.

## Examples and benchmarks: what they prove

There are 117 example and 71 benchmark CLEAR files, totaling about 26,307
lines. They exercise a wide surface, but usage is highly uneven:

- 24 `REQUIRE` and 14 FFI declarations show real module/native integration;
- no example or benchmark defines a generic type or generic function, despite
  extensive generic unit specs;
- function types occur only four times and `Any` twice;
- `COPY` occurs about 1,070 times, concentrated in compiler/interpreter-style
  programs such as the BC runner, Scheme runner, sus-int, MAL, and GraphDB;
- only 22 `REQUIRES` clauses appear, mostly in one generated runner;
- there are 69 `EFFECTS` clauses and 79 `TIGHT` occurrences.

The absence of generic dogfooding is a more important readiness signal than
the number of generic specs. Add at least one generic container/algorithm and
one generic callback-based real program to the strict corpus before relying on
generics for self-hosting.

### Safe list indexing: core migration complete, strict corpus audit remains

The compiler specs, transpile corpus, MAL interpreter path, MiniVM sources and
goldens, and affected fuzz templates now use explicit fallback, `IF ... AS`, or
safe navigation. Promise-list indexing is also `?~T` (optional promise), kept
distinct from `~?T` (promise/stream producing an optional value).

The implementation should **not** be weakened to make those examples pass.
Bounds-safe indexing satisfies the safety goal, and the diagnostic offers the
correct `?.` fix. The remaining strict examples/benchmarks manifest should
verify no less-traveled program still relies on the old rule, and a repository
check should reject newly introduced unsafe index chains. Where a loop proves
an index in range, an explicit checked-to-
proven operation may be offered as an advanced zero-branch escape hatch, but
only if the compiler can validate the proof or the syntax visibly marks an
unsafe assertion.

### Existing program workarounds that indicate real pressure

- MiniVM comments say list parameters cannot be passed through some emitter
  paths and that mutable `@list` escape promotion across files can select
  incompatible allocators and double-free. These are real self-host blockers,
  not stylistic complaints.
- Puck VM documents temporary-lifetime and OR-default binding workarounds.
- GraphDB documents a list-from-struct `COPY` problem.
- `benchmarks/tofix.md` records a high-concurrency slab segfault, a nested-lock
  false positive, concurrent GraphDB failures, and frame-arena `ArrayList`
  growth waste.

Each workaround should become a minimal regression integration test. Delete
the workaround only after that test passes through parser, annotation, MIR,
Zig compilation, and execution.

### Benchmark interpretation

The graph benchmark is one of the better readiness artifacts because it names
non-equivalent safety guarantees and measures cache-scale transitions.
At one million nodes:

- the safe paged slot map is 1.21x unchecked direct-index C overall;
- random reads are 1.18x direct-index C;
- it is 3% faster than corrected CLEAR Pool overall and retains an estimated
  7.96 MiB after 99% collapse versus Pool's 45.78 MiB;
- CLEAR LINK/RESOLVE now matches idiomatic Rust Rc/Weak phase by phase and is
  about 1% faster overall;
- Go remains competitive on random reads, but is much slower on churn and
  collapse in this forced-GC workload;
- cache-resident slot-map random reads are still 1.51x–2.24x direct-index C.

The idiomatic `@node` acceptance benchmark is within 1.17x of manual safe Zig
for steady-state reads and writes in the recorded README run, with about 4.1%
more peak RSS. A later run in `docs/agents/graph.md` is slightly faster in the
steady-state trace. Treat that variance as a reason to retain distributions,
machine metadata, and regression thresholds—not as proof that generated code
is intrinsically faster.

The benchmark still needs cleanup-bearing payloads, natural and forced Go GC,
99.9% collapse, p50/p95/p99 operation latency, concurrent readers/writers, and
an explicit deletion surface before it is an acceptance gate for every graph
claim. Smoke mode is a build/behavior check, not a performance comparison; its
short runtimes are dominated by startup and scheduling.

## Type system, generics, and abstraction

### What exists

The compiler has meaningful generic support: generic structs, unions and
functions; inference; nested substitution; capability preservation; generic
struct literals; generic MATCH; and sync-family monomorphization. It also has
first-class function types and callback reentrancy constraints.

### What remains incomplete

- the generic cleanup and return-ownership failures found by this audit are
  fixed, but no real program dogfoods generic definitions;
- nested generic parsing and some generic union payload shapes are explicitly
  limited;
- erased capabilities such as `String@symbol` cannot participate correctly in
  generic type predicates;
- FN-typed parameters cannot express the full capability surface;
- there is no user-facing interface/protocol/trait abstraction.

The last point matters for self-hosting. A compiler has families of nodes,
walkers, emitters, diagnostics, streams, allocators, and collection algorithms.
Without a common static contract, those become either `Any`, large tagged-union
switches, duplicated functions, or global knowledge of every concrete type.
All four outcomes conflict with local reasoning and safety.

### Recommended minimal protocol design

Implement **static structural protocols**, with progressive disclosure:

1. Ordinary generic functions infer the operations they require from their
   body. Callers need no declaration and pay no runtime dispatch.
2. A named `PROTOCOL` is optional and primarily useful at public/module
   boundaries, in diagnostics, and for documentation. Types satisfy it
   structurally; no mandatory `implements` ceremony.
3. Monomorphization remains the default. Storage, ownership, sync, and layout
   capabilities remain orthogonal axes and flow through specialization.
4. A visibly explicit `DYN Protocol` (name provisional) is the later escape
   hatch for heterogeneous runtime dispatch. It must expose allocation/vtable
   cost in its type and should not be required for self-hosting the normal AST
   walk.
5. `REQUIRES` continues to express capability/effect families. Do not overload
   protocols with synchronization realization.

This gives the compiler the abstraction it needs without imposing Rust's trait
system on ordinary users. Before committing syntax, prototype three real
self-host slices: an AST walker, a diagnostic sink, and an ordering operation
for generic collections.

## Ownership, capabilities, and local reasoning

### Strengths

- declaration-site capabilities are a strong “decision made once” mechanism;
- bounds-safe list indexing is the right default;
- explicit `TAKES`, `GIVE`, `COPY`, and `CLOSE` make ownership transfer and
  resource cleanup reviewable;
- the compiler emits useful cost diagnostics for unnecessary locks, Arc, SOA,
  and versioned storage;
- `REQUIRES` lets functions state semantic synchronization families instead of
  concrete wrapper types.

### Pressure points

The compiler/interpreter examples' heavy `COPY` concentration suggests that
the current ownership surface becomes cognitively expensive for AST-like data.
Do not respond with implicit deep copies. Instead:

- finish borrow/escape behavior for collection parameters and cross-module
  helpers;
- make ownership inference and diagnostics reliable across module boundaries;
- add local read-only views/borrows that do not expose allocator plumbing;
- preserve explicit `COPY` when a real duplicate allocation occurs;
- measure generated compiler code for accidental cloning.

The compiler itself contains substantial comments and tooling around hidden
phase-order protocols. Self-hosting should not reproduce those protocols in
CLEAR. Prefer typed intermediate facts and constructors that make invalid
phase states unrepresentable.

## `@node`: strong surface, unresolved lifetime domain

The public surface is aligned with CLEAR's goals:

```clear
STRUCT Node {
  left: ?Node@node,
  children: Node@node[]@list,
  id: Int64
}

MUTABLE root: Node@node = Node{ id: 1 };
root.left = Node{ id: 2 };
root.children.append(Node{ id: 3 });
```

Expected-type coercion hides insertion, handles stay four bytes, lookup checks
generation/liveness, payloads may move, empty tail pages are decommitted, and a
real integration test proves cyclic resource payloads close before the tested
caller continues. This is much better than exposing Pool/SlotMap mechanics.

However, v1 uses one hidden store for each `(Runtime instance, payload type)`
and lexical leases clear it on the outermost release. Consequences:

- two independent graphs of the same node type share one reclamation domain;
- replacing an edge does not delete an unreachable vertex;
- a root leaving a nested block does not necessarily reclaim its graph;
- explicit early deletion is not yet in the language;
- `@node` is local/affine only; concurrent graph sharing has no policy yet.

Therefore “automatic graph RAII” currently means deterministic arena cleanup
at a shared type-store lease boundary, not per-root reachability cleanup. The
WALKTHROUGH and design doc must say that precisely.

Before self-hosting uses `@node` for compiler structures, choose one of these
semantics deliberately:

1. **Preferred:** compiler-inferred lexical graph regions. The common syntax
   remains unchanged; region identity is inferred and propagated through
   calls. An explicit region/capacity form appears only when two domains must
   interact or a graph must outlive its inferred scope.
2. Keep the per-runtime/type store, but name it honestly as a typed runtime
   arena and do not promise per-graph RAII. This is simpler but introduces
   hidden global coupling and coarse resource lifetime.

Do not add tracing reachability collection merely to preserve the current
surface. It would compromise deterministic cleanup and performance. Also do
not expose `GraphId`/Pool operations as the default; that would discard the
ergonomic achievement. Add explicit deletion only after its alias/stale-handle
semantics and cleanup behavior are integration-tested.

## Tense, effects, and concurrency

### What is promising

Tense (`~T`) provides one vocabulary for promises and streams, while BG/DO,
pipelines, and capability-selected synchronization offer high optionality.
`@split` and open/range pipeline paths have current specs. Sync polymorphism's
precedence and family rejection suite is green in isolation. The distinction
between semantic family (`SNAPSHOTTED`, `LOCKED`) and concrete realization is
exactly the right direction.

### What must be completed

- The walkthrough omits `REQUIRES` and `WITH POLYMORPHIC`, so users cannot
  discover one of CLEAR's most important features.
- The sync design document still marks multi-family comptime lowering partial.
  Existing tests cover annotation, rejection, and emitted fragments more than
  a complete runtime matrix across realizations.
- Function-value reentrancy currently produces warnings and is barely
  dogfooded outside specs. The default callback path needs a simpler locally
  visible rule and an end-to-end strict-corpus program.
- The focused stream-composition and optional-promise indexing defects found by
  this audit are fixed; cancellation and failure propagation still lack one
  complete runtime story.
- Cancellation, task lifetime, and failure propagation need one structured
  concurrency story and end-to-end tests.

Keep purity/effect inference as the default. Do not require an `@pure`
annotation merely to remove a hidden runtime parameter or enable fusion. An
optional explicit effect contract is useful at public boundaries and for
verification, but ordinary local functions should get the zero-cost result by
inference.

## Post-`@node` assessment: Rust-like ceremony CLEAR can avoid

`@node` establishes a useful design pattern: users state the semantic shape
once, expected-type coercion handles ordinary construction and assignment, and
the compiler synthesizes the storage/handle machinery. Applying that pattern
elsewhere reveals several places where CLEAR still exposes machinery that is
useful to the compiler but unnecessary for most programmers.

### 1. Infer borrow and return-lifetime contracts locally

Wildcard and named return-lifetime syntax (`RETURNS *:T`) is valuable as an
advanced public contract, but requiring Rust-like lifetime relationships in
ordinary helpers would violate progressive disclosure. Infer them from local
data flow for private functions and monomorphized generics. Ask for an explicit
contract only when a public boundary is ambiguous, recursive inference does not
converge, or the author wants to promise a narrower stable API. Diagnostics
should offer the inferred contract as an autofix.

### 2. Infer capability requirements; declare them at durable boundaries

The compiler already detects that `WITH` requires a locked family and emits a
warning that it is temporarily auto-inferring `REQUIRES x: LOCKED`. Make that
the normal rule for local/private functions. Preserve explicit `REQUIRES` for
public APIs, capability-polymorphic design, documentation, and cases with more
than one valid semantic family. This is analogous to `@node`: infer the
mechanism from the operation while keeping the semantic choice visible where
callers need it.

### 3. Use structural protocols, not nominal trait ceremony

The self-hosted compiler needs reusable contracts, but ordinary types should
not need `impl` blocks or orphan/coherence rules merely to be walked, formatted,
or ordered. Infer structural requirements for local generic code and allow an
optional named `PROTOCOL` at public boundaries. Add explicit dynamic dispatch
only as a visibly costly escape hatch. This is the highest-value generalization
of the `@node` tradeoff.

### 4. Keep conditional collection access composable through one safe boundary

The intended rule is `x?.foo.bar`: one safe navigation handles the one optional
boundary; later members are ordinary when their receivers are non-optional.
The migration exposed separate lowering paths for field chains, method calls,
intrinsic methods, mutation, and generated Zig. The read-side paths now retain
the typed optional in MIR and accept `x?.foo.bar()` for a single optional
boundary. Keep those paths unified as the compiler evolves so users do not
need `(x?.foo OR_ELSE default).bar()` merely to satisfy a backend detail. For
mutation, `items[i]?.field = value` is the explicit conditional form: when the
index/optional receiver is missing, the write is skipped and the right-hand
side is not evaluated. This matches the expression's visible `?.` boundary.
Use `IF items[i] AS item` with an `ELSE` branch when absence must be handled
rather than intentionally ignored.

### 5. Make move syntax destination-driven where the choice is unique

`TAKES` on the callee is the durable ownership contract. At a call site where
the source cannot be used afterward and no copy is requested, the compiler can
insert the move without requiring repetitive `GIVE`; diagnostics can show the
inferred move and offer explicit `GIVE` when reviewability matters. Never infer
`COPY`, because that hides real allocation and changes performance. Preserve
explicit moves for ambiguous branches, partial moves, and unsafe/FFI boundaries.

### 6. Infer callback effects for local higher-order code

Requiring every local callback parameter to spell Rust-like effect and
reentrancy bounds makes simple higher-order code look more dangerous than it
is. Infer callback effects through private functions and monomorphized call
sites. Require explicit `NON_REENTRANT`/reentrant contracts only at public,
stored, escaping, or dynamically dispatched callback boundaries. This keeps
polymorphic sync optionality without hiding scheduler or stack costs.

### 7. Do not generalize `@node` into hidden process-global magic

The ergonomic lesson is compiler-synthesized local machinery, not global
registries. The next `@node` step should be inferred lexical graph regions, not
more type-wide stores. The same constraint applies to interning, caches,
observables, and task groups: default domains should be locally inferable and
explicit handles should appear only when values cross domains.

### What should remain explicit

Some Rust-like-looking controls are carrying real semantic weight and should
not be erased: `COPY` when allocation occurs; `LINK`/`RESOLVE` for open,
independent lifetimes; `CLOSE` and EXTERN ownership; `@shared` when values cross
schedulers; unsafe bounds assertions; and dynamic dispatch. CLEAR should remove
proof ceremony when the compiler already has the proof, not conceal costs or
weaken lifetime and race safety.

## Modules, build system, standard library, and tooling

### Build/package system is a self-hosting blocker

The current CLI scans source for REQUIRE/EXTERN, copies Zig modules, rewrites
imports, heuristically preloads allocator support, always links libc, and calls
Zig directly. It does not yet have an explicit package graph or durable native
dependency metadata for system libraries, include paths, C sources, frameworks,
target conditions, and cache signatures.

Do not move this implicit behavior wholesale into the CLEAR compiler. Define a
typed build plan first:

- canonical module identity and cycle rules;
- package root and visibility;
- generated dependency graph;
- target/profile/features as explicit inputs;
- native library/include/framework metadata;
- reproducible cache keys and build outputs;
- a small stable compiler-to-Zig boundary.

This reduces global complexity: build behavior becomes data that can be
inspected locally instead of scattered source scans and path heuristics.

### Minimum self-host standard library

The translator audit shows the compiler depends heavily on files/paths, JSON,
regex/scanning, process execution, sets/maps, CLI parsing, and diagnostics.
Before translating production compiler modules, provide tested CLEAR APIs for:

- bytes and UTF-8 text as distinct, interoperable types;
- paths, files, directories, and buffered I/O;
- process spawning, exit status, stdout/stderr, and environment;
- regex or a purpose-built scanner abstraction;
- JSON parse/generate;
- maps, sets, sorting/ordering, and iterators/pipelines over them;
- command-line option parsing;
- checked numeric conversion and overflow;
- source locations, diagnostic rendering, and structured compiler errors.

The API should be high-level first. Allocator choice, buffer reuse, mmap,
zero-copy slices, and raw OS handles are opt-in performance layers.

### Tooling

`clear fix` and high-quality diagnostics are strategic assets because they let
CLEAR strengthen safety without imposing migration guesswork. Before
self-hosting:

- make `clear fmt`, build, run, test, benchmark, fix, and doctor contracts
  stable and documented;
- make `--help` real for every tool (the benchmark runner currently interprets
  it as a path);
- ensure diagnostics have stable codes and executable fix tests;
- test LSP against a built binary in a hermetic integration fixture;
- add compile-time and peak-memory budgets for the compiler itself.

## Self-hosting plan

The current 99.06% ruby-to-clear textual coverage is useful, but it measures
whether syntax can be translated, not whether the result type-checks, builds,
runs, or reproduces compiler output. The remaining dynamic/reflection sites
(`send`, `public_send`, `const_get`, `define_method`) and block-local control
flow are disproportionately important.

Use vertical stages with equivalence gates:

### Stage 0 — readiness release

- all required gates green in clean, randomized, and parallel runs;
- strict supported examples/benchmarks manifest green;
- safe-index migration complete;
- minimal structural protocol decision and prototype complete;
- build plan and minimum stdlib contracts accepted;
- `@node` lifetime-domain semantics decided and documented.

### Stage 1 — leaf libraries

Translate immutable source locations, tokens, small enums/unions, diagnostic
records, and pure helpers. Compare serialized outputs against Ruby.

### Stage 2 — lexer and parser

Run both implementations on the entire corpus and fuzz matrix. Require
byte-for-byte token equivalence and normalized AST equivalence, including
invalid programs and diagnostic spans.

### Stage 3 — semantic/type front end

Translate scopes, types, schemas, generics, ownership, and capabilities. This
stage depends on protocols and reliable recursive data. Differentially compare
types, diagnostics, moves, effects, and capability families.

### Stage 4 — MIR and verification

Translate typed lowering plans before emitters. Require normalized MIR equality
and checker agreement. Avoid porting mutable phase-order state when a typed
fact can replace it.

### Stage 5 — Zig emission and build planning

Compare normalized generated Zig and execute both outputs. Then have the CLEAR
compiler emit the explicit build plan; keep the Ruby driver as an oracle until
reproducibility and cache tests pass.

### Stage 6 — staged bootstrap

Build compiler A with Ruby, use A to build compiler B, then B to build C.
Require B/C output equivalence, full corpus success, fuzz success, runtime
hammer success, and compiler performance/memory within agreed budgets.

Do not delete the Ruby oracle until two-stage equivalence is routine in CI.

## Prioritized work

### P0 — before self-host implementation

Completed in this repair: the exact unit/integration gates, transpile corpus,
MiniVM native path, module/FFI tests, and normal Zig runtime lane are green;
the safe-index migration covers those surfaces and all 458 cells across the
eight migration-sensitive fuzz templates now pass without failures, leaks,
MIR errors, or unexpected passes. CI should confirm all five fuzz shards in
fresh runners.

Next, in priority order:

1. **Make corpus gates honest.** Add a strict supported-program manifest and
   visible expiring quarantine; stop treating swallowed failures as green.
2. **Fix end-to-end generics/function values.** Add real dogfood programs and
   compile/run tests, not only annotator/code-string assertions.
3. **Resolve cross-module collection borrow/escape and allocator provenance.**
   This blocks compiler-shaped programs and has memory-safety implications.
4. **Specify the build plan and minimum stdlib.** Prove it with one multi-module
   package using JSON, filesystem, regex/scanning, and a native dependency.
5. **Decide `@node` lifetime domains.** Align WALKTHROUGH, implementation, and
   RAII claims; add two-independent-graphs and nested-scope tests.
6. **Prototype minimal static protocols** on three compiler use cases.
7. **Finish safe-navigation mutation semantics (completed on `graphs`).**
   Read-side fields and methods implement the documented `x?.foo.bar()`
   single-boundary rule. Conditional assignment uses
   `items[i]?.field = value`; absence skips both the write and RHS evaluation.
   `IF-AS` remains the explicit form when absence needs an `ELSE` action.
8. **Pay down or explicitly baseline static-analysis debt.** The current
   Sorbet and signature-lint commands are not green and should not remain
   ambiguous CI signals.

### P1 — early self-host stages

1. Complete multi-family sync-polymorphic runtime lowering and execute every
   concrete-family cross-pair.
2. Define structured cancellation/task failure and test nested BG/DO lifetimes.
3. Finish generic nesting, generic union payloads, capability-aware type
   metadata, and callback capability constraints as demanded by real slices.
4. Add bytes, checked casts, robust path/process APIs, JSON, scanner/regex, CLI,
   ordering, and collection iteration to the stdlib.
5. Turn every documented workaround into a regression test and remove it.
6. Add compiler differential harnesses and stage artifacts.

### P2 — optimization and broader optionality

1. Add measured capacity/region hints and explicit deletion for `@node` without
   exposing pool mechanics in the default path.
2. Add an explicit dynamic-protocol escape hatch only when a real heterogeneous
   workload requires it.
3. Extend graph benchmarks with cleanup, latency, concurrency, and platform
   page-reclamation matrices.
4. Add optimizer explanations: why a value allocated, retained, locked,
   failed to fuse, or required a runtime parameter.
5. Expand BC/register VM coverage after the primary compiler path is stable.

## What not to do

- Do not begin by mechanically translating 97,000 Ruby lines because the
  translator reports 99% textual coverage.
- Do not weaken optional indexing or ownership checks to rescue stale examples.
- Do not introduce mandatory traits, explicit allocator parameters, pool IDs,
  or graph managers into ordinary code.
- Do not make users annotate purity, lifetimes, synchronization realization,
  or graph capacity when the compiler can infer them safely.
- Do not hide lifetime, package, or synchronization policy in process-global
  registries without a locally visible semantic boundary.
- Do not treat microbenchmarks as universal ratios; retain safety-equivalent
  baselines, cache-size curves, memory, and tail latency.
- Do not preserve Ruby compiler architecture where it relies on reflection,
  mutable phase order, or broad `respond_to?` protocols. Self-hosting is the
  opportunity to encode those facts locally and statically.

## Readiness acceptance checklist

Self-hosting implementation can begin when all of the following are true:

- [ ] exact unit and integration CI commands pass repeatedly with randomized
      order and parallelism;
- [ ] all 474 transpile tests pass;
- [ ] the full non-quarantined fuzz matrix passes with zero unexpected pass;
- [ ] the register MiniVM meets its stated allowlist gate;
- [ ] every program in the strict examples/benchmarks manifest builds, and
      runnable programs execute successfully;
- [ ] WALKTHROUGH executable blocks are tested and contradictions removed;
- [ ] generics and function values are used by at least two real strict-corpus
      programs;
- [ ] the protocol prototype supports the three compiler use cases without
      runtime dispatch on the default path;
- [ ] build-plan and minimum-stdlib integration package passes on supported
      platforms;
- [ ] `@node` independent-domain, escape, cleanup, stale-handle, and resource
      tests match the documented semantics;
- [ ] sync polymorphism executes across every admitted concrete family;
- [ ] Stage 1 differential harness compares Ruby and CLEAR artifacts;
- [ ] compiler time and peak-memory budgets are recorded before the port.

When these are green, CLEAR will not merely have enough syntax to express its
compiler. It will have the local contracts, safety guarantees, optionality,
and integration discipline needed to keep that compiler understandable after
it is self-hosted.
