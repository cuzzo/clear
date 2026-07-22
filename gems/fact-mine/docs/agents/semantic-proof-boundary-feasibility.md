# Semantic proof-boundary feasibility for FactMine consumers

## Decision

Do **not** start a cross-language compiler-integration programme or add ten
thousand lines of analysis on the assumption that it will make FactMine
materially more complete.

Do first build a small, shared **proof-boundary contract** and measure the
largest uncertainty buckets on real closed build targets. Then run at most one
language-specific semantic-backend pilot, with explicit stop criteria.

This work is justified only if the pilot removes a material fraction of a T1
metric's *actionable* uncertainty or noise. It is not justified merely because
it replaces one `unknown` with a differently sourced heuristic.

The proposed order is:

1. Make every semantic fact say what it proves, which authority supplied it,
   and which boundaries remain open.
2. Measure unknowns by cause and by affected consumer metric.
3. Pilot a compiler-semantic import only for the highest-yield language and
   fact family.
4. Keep or stop the backend using the measured thresholds below.

The first step is useful independently of any compiler backend. The later
steps are deliberately conditional.

## The gap, precisely

FactMine already has a strong normalized-source pipeline:

- normalized AST, CFG, def-use, dominance, liveness, local flow types, and
  nil refinements;
- nullable state facts that distinguish `definitely_null`,
  `definitely_non_null`, `maybe_null`, and `unknown`;
- exact method identities, direct local call resolution, candidate target
  sets, call-resolution coverage, and explicit missing-resolution reasons;
- reviewed external/stdlib summaries;
- optional language-server/SCIP production that can attach semantic symbols,
  exact project definitions, external identities, and closed candidate sets.

The existing optional semantic path is shared rather than language-specific:
`src/lsp_scip.rs` owns transport and project joins, while language adapters
supply narrow language descriptors. This is the correct ownership model and
should be extended rather than bypassed.

## SCIP and compiler front ends are complementary

Adding `go/types`, the TypeScript compiler API, a Python type checker, or a
Clang semantic sidecar does **not** obsolete SCIP for the product as a whole.
It can, however, make SCIP unnecessary for a particular language's local
semantic extraction. Native and SCIP facts must be able to coexist without
either being mandatory for the other.

| Capability | Current LSP/SCIP layer | Native language front end | Correct combined use |
| --- | --- | --- | --- |
| Portable symbol identity and cross-language schema | Strong: emits/joins semantic symbols, project definitions, external identities, and candidate sets | Language-specific identity only | FactMine owns canonical IDs; project native facts to SCIP only when portability/navigation needs it |
| Build-target source selection | Depends on language-server workspace configuration | Strong when loaded through `go/packages`, `tsconfig`, Cargo metadata, a Python environment/config, or `compile_commands.json` | Native loader declares the build target; SCIP records resulting symbols |
| Name/import/module resolution | Useful definition lookup, but server-dependent | Strong for the selected build/configuration | Native result supplies authoritative local resolution directly to FactMine; SCIP is optional projection/fallback |
| Types, overloads, generics, and declared nullability | Symbol-oriented only; not a complete typed fact source | Strong where the language exposes these semantics | Import typed facts through one FactMine envelope with `authority: compiler` |
| Flow nullness, alias/effect summaries, callback behavior | Not supplied by SCIP as a general contract | Varies; no listed front end makes all effects closed | Use compiler facts to close only named boundaries; retain CFG/DFG and explicit unknowns |
| External/dependency navigation | Strong common representation | Often tied to one toolchain or unavailable for source-less dependencies | Use either backend's canonical external identity plus the reviewed summary registry; SCIP is useful where a portable index exists |
| Long-tail language support | Good common baseline | Expensive to build and maintain per language | SCIP-only is an explicit lower-capability tier, not a hidden approximation |

For example, `go/types` maps identifiers to objects, computes expression types
and constants, and recommends `go/packages` for complete packages. It does not
by itself supply interprocedural effect summaries, a whole-program call graph,
or a proof that an arbitrary nil guard is removable. Clang tooling similarly
uses a compilation database to select the actual command line and exposes the
Clang AST, but its own documentation warns that LibTooling is not a stable API
for clients unwilling to track AST changes. A Clang integration should
therefore be a version-pinned sidecar with FactMine's stable JSON import
contract, not a Rust dependency on Clang internals. [Go `types`](https://pkg.go.dev/go/types), [Clang LibTooling](https://clang.llvm.org/docs/LibTooling.html), [Clang tooling interface guidance](https://clang.llvm.org/docs/Tooling.html)

For Go specifically, a `go/packages` load with `go/types` `TypesInfo` can
directly provide selected build files, package/import identity, declarations,
uses, expression types, method sets, and signatures. FactMine can join those
facts to its digest/span-derived IDs without asking an LSP or producing SCIP.
That does **not** close effects, pointer/interface flow, callbacks, or arbitrary
nilness; it simply means SCIP is not required to obtain the Go facts that
`go/types` owns.

The architecture is consequently a fan-in, not a mandatory pipeline:

```text
native build/type frontend (optional, per language) ─┐
  emits typed semantic evidence                        │
LSP/SCIP import (optional, per language) ─────────────┼─> FactMine canonical
  emits portable symbol/index evidence                 │   semantic facts +
                                                       │   ProofBoundary
                                                       ▼
                                      Decomplex / Espalier / NilKill / Lineage
```

FactMine may project either source into SCIP for external navigation or a
portable artifact, but no consumer requires SCIP to consume native facts.

Neither input is allowed to overwrite a stronger fact silently. A native
frontend may close `dispatch` or `contracts`; it cannot erase an
`unknown_call_effect`, FFI, alias, or dynamic-dispatch blocker merely because
it resolved a symbol. SCIP remains useful as an optional portable
identity/projection layer, for source-less external symbols, and as the only
semantic input available to languages without a maintained native backend. It
is not required for Go, or any other language, once its native backend emits
the needed canonical FactMine facts directly.

The gap is that a consumer cannot consistently answer this question for an
individual fact:

> Is this conclusion a local normalized-AST observation, a closed CFG proof,
> a declared contract, a compiler-resolved fact, a finite candidate set, or a
> heuristic that crossed an unknown boundary?

Today, the answer is spread across unrelated fields:

- local CFG and nullable rows use `complete` and `unknown_reasons`;
- calls use `confidence`, `target_provenance`, `candidate_targets`,
  `unresolved_reason`, `resolution_missing_proof`, and
  `empty_domain_cause`;
- corpus closure is tracked separately by consumers;
- Espalier separately records complexity bound qualities and assumptions.

Those fields are individually useful, but `complete: true` is not a portable
proof claim. For example, it may mean that FactMine modeled the local CFG; it
does not necessarily mean that every callee, effect, alias, build
configuration, dependency, or externally supplied nullability contract is
closed.

Consequently, a downstream consumer can safely say:

> A modeled nullable root creates these review obligations.

It cannot generally say:

> This nil guard is unreachable in every execution of the actual build, so
> remove it.

That distinction also affects architecture and complexity findings. A missing
call target can hide a state write, protocol effect, callback, recursive edge,
or non-constant operation; a guessed type can fabricate an owner or a cheap
call. Decomplex and Espalier are right to consume FactMine rather than recreate
language analysis, but they inherit its semantic boundaries.

## What already works and must not be duplicated

### Existing call identity is not the main missing subsystem

FactMine already emits calls, call graph edges, flow-local types, exact
project targets, and candidate targets. Espalier already performs cross-file
target projection, SCC/fixed-point aggregation, and explicitly represents
incomplete complexity results.

The prior closed-corpus experiment in
`minimal-call-graph-feasibility.md` is decisive evidence against an unmeasured
rewrite:

- a maximal simple name/type resolver could make under **1.7 percentage
  points** of functions complete in the compiler/ruby experiment;
- an exact native-summary expansion over 35 repositories improved known-time
  coverage by **0.54 percentage points** (4,946 to 5,036 complete functions);
- a compact graph over current facts therefore cannot plausibly move a
  roughly 20–30% known corpus to 80%.

Do not move Espalier's graph into FactMine as a claimed completeness fix. A
future compact graph may be justified as a measured latency improvement, but
that is a separate decision.

### Current nullable analysis is intentionally conservative

FactMine's nullable state only reports `maybe_null` after proven null and
non-null definitions join. An unresolved producer is `unknown`, not
`maybe_null`. NilKill groups complete facts into a **review-only** pressure
report and deliberately has no source text, AST, or CFG of its own.

That conservative separation is a feature. The work below must preserve it:
unknown semantic input lowers proof strength; it must not be converted into a
new positive finding merely to increase coverage.

## Impact on Decomplex and Espalier

| Consumer surface | Present protection | Remaining impact from the gap | Desired change |
| --- | --- | --- | --- |
| Decomplex redundant nil guard | Normalized guard semantics, CFG dominance, local invalidation | A report can overstate how safely a guard may be deleted when calls, aliases, contracts, or build scope are open | Attach a proof tier and blockers; reserve "safe removal candidate" wording for a closed proof |
| Decomplex state/protocol findings | Complete-corpus gates for selected detectors; confidence on several reports | Missing call/effect identity can hide writers, readers, callbacks, and lifecycle transitions, producing noise or missed topology | Carry call/effect closure to each finding and surface the exact boundary |
| Espalier Big-O | `unknown`, completeness flags, candidate-max qualities, assumptions | Unknown callee cost/type/cardinality causes incomplete bounds; incorrect identity can poison SCCs and propagation | Consume a canonical proof boundary and compiler-backed exact/candidate identities where available |
| Architecture artifact / Lineage | Exact IDs where FactMine has them; unresolved calls remain external/partial | Missing build/module identity produces absent or misdirected relationships | Keep unresolved edges explicit and add semantic authority/provenance |
| NilKill static pressure | Complete local nullable facts; review-only output | Cannot distinguish a local proof from a build-closed non-null invariant | Report causal pressure plus proof tier; do not auto-edit guards |

The gap therefore affects T1 metrics, but not uniformly. It is most important
where a result depends on interprocedural identity or effect semantics:

1. exact/closed call and callback identity for Espalier bounds and architectural
   edges;
2. mutation, escape, and nullability contracts for nil-pressure precision;
3. receiver/type identity for type-driven operation cost and protocol effects.

Purely structural Decomplex detectors continue to work without compiler
integration. They should not be held hostage to it.

## Proposed shared proof-boundary contract

Add one versioned public structure, embedded in semantic facts that make
cross-node or cross-file claims. It should be a compact value object, not a
second analysis graph.

Illustrative shape:

```json
{
  "authority": ["normalized_cfg", "declared_contract"],
  "scope": "intra_procedural",
  "coverage": {
    "source": "parsed",
    "cfg": "closed",
    "dispatch": "open",
    "effects": "open",
    "contracts": "declared_only",
    "corpus": "selected_target"
  },
  "assumptions": ["callee Foo.bar honors @NonNull return"],
  "blockers": ["unknown_call_effect"],
  "tier": "modeled_local"
}
```

Required properties:

- **Monotonicity:** importing more evidence may strengthen a proof only when
  it closes a named boundary. It must never silently erase an existing
  blocker.
- **Composability:** a nullable summary, call record, complexity result, and
  Decomplex finding can all preserve the same boundary vocabulary.
- **Authority separation:** distinguish `compiler`, `declared_contract`,
  `normalized_cfg`, `reviewed_model`, and `heuristic`. SCIP identity is not a
  compiler proof of a callee's effects or nullability.
- **No false globality:** `intra_procedural` must remain distinct from
  `closed_project` and `closed_build_target`.
- **Stable unknowns:** blockers are canonical machine-readable values, not
  free-form strings. Human detail can remain alongside them.

The existing fields should remain temporarily for wire compatibility, then be
derived from this structure. Do not make consumers infer proof tier from
multiple strings indefinitely.

## Work plan and estimates

Estimates include production code plus dedicated oracle/fixture coverage. They
are planning ranges, not a commitment to add every phase.

| Phase | Work | Estimated production LoC | Estimated test/oracle LoC | Effort | Expected impact |
| --- | --- | ---: | ---: | --- | --- |
| 0 | Instrument and measure current unknowns by language, fact family, consumer, and boundary cause | 250–500 | 250–500 | 3–5 days | Converts speculation into a ranked ROI decision; no precision claim yet |
| 1 | Add `ProofBoundary`, project legacy fields, and require consumer policy gates | 700–1,300 | 700–1,200 | 2–3 weeks | Reduces overstatement/noise across Decomplex, Espalier, NilKill, and Lineage; makes remaining gaps actionable |
| 2 | Shared semantic-evidence import envelope: versioned file digest/span/symbol joins, authority validation, fixture harness | 600–1,100 | 600–1,000 | 2–3 weeks | Makes a compiler backend additive and canonical instead of creating consumer-specific engines |
| 3a | One C# Roslyn nullable/type/call pilot | 1,200–2,500 | 700–1,400 | 3–5 weeks | Potentially high for nullable and receiver facts in `Nullable=enable` closed projects; must be measured |
| 3b | One Java JSpecify/NullAway or javac semantic pilot | 1,500–3,000 | 800–1,600 | 4–6 weeks | Potentially high in consistently annotated projects; lower in framework-heavy/unannotated projects |
| 3c | Go `go/packages`/SSA or NilAway evidence pilot | 1,500–3,000 | 800–1,500 | 4–6 weeks | Better package/type/null-flow closure; likely less benefit than C#/Java for proof-quality guard removal |
| 3d | C/C++ compile-database/Clang semantic pilot | 2,500–5,000 | 1,200–2,500 | 6–10 weeks | Useful exact build/config/type facts, but alias/effect closure remains limited; highest integration risk |

Do not schedule 3a–3d together. Phase 0 and Phase 1 are the recommended
maximum initial commitment: **950–1,800 production LoC**, **950–1,700 test
LoC**, and roughly **3–5 engineer-weeks**. They improve trust calibration even
if every compiler pilot is rejected.

One selected semantic pilot would bring the initial programme to roughly
**2,800–5,400 production LoC**, not 10k+. A multi-language rollout can easily
exceed 10k production LoC and is explicitly out of scope until each language
proves its own return on investment.

## Operational cost: binary size, build time, and scan latency

A native semantic backend must not turn `fact-mine-rust` into a bundle of
foreign compilers. The current SCIP path already establishes the appropriate
process boundary: the Rust executable starts an external language server and
imports a stable result. A Go backend should use the same model, but with a
small, version-pinned Go helper that loads a requested target through
`go/packages`, reads `go/types`/optional SSA facts, and writes FactMine's
versioned semantic-evidence JSON. It must be built in release packaging and
invoked as an executable. It must **not** invoke `go run` during a scan and
must not embed Go through cgo/FFI.

That design separates the costs that otherwise get conflated:

| Surface | Direct `go/packages`/`go/types` helper | Effect on `fact-mine-rust` | Policy |
| --- | --- | --- | --- |
| Rust release binary size | Rust gains only a small launcher, protocol validation, and fact importer; it does not link the Go runtime, `go/types`, or `x/tools` | Expected to be a small code-size delta rather than a multi-megabyte toolchain payload; establish the exact baseline before implementation | Enforce a release-binary delta budget in the pilot; reject a design that pulls a Go runtime or compiler implementation into the Rust binary |
| Installed distribution size | The helper and its Go dependencies are a separate, multi-megabyte artifact, or the host must explicitly provide a compatible helper | No hidden Rust-binary growth, but packaging has an additional versioned artifact | Ship/check a helper checksum and version, or make the backend unavailable with an explicit `native_backend_unavailable` boundary; never silently fall back to guessed semantics |
| Rust compilation time | The normal Cargo build compiles only the launcher/importer; it does not compile Go packages | Near-current FactMine Rust compilation cost, apart from the small Rust integration | Keep the helper in a separately cached build/release step; do not add a Rust binding to Go/Clang/TypeScript internals |
| Helper build / CI setup | First build compiles the helper and its Go module graph; clean CI must also obtain a compatible Go SDK and module cache | No change to Cargo's dependency graph, but CI/image setup and cache keys grow | Pin Go and helper module versions; cache by SDK version, helper lockfile, `go.mod`/`go.sum`, and target platform; record setup failure as a fact boundary |
| Cold scan latency | Package loading, export-data loading, and type checking are roughly proportional to the selected package graph and are materially slower than parsing a file with Tree-sitter | Rust remains fast; the added wall time belongs to the opt-in semantic phase | Run once per closed build target, not once per source file or candidate call; bound concurrency and report load/type-check time separately |
| Incremental/repeated scans | A content/configuration-keyed semantic-fact cache can avoid repeating unchanged target loads | The Rust process reads compact evidence rather than retaining a compiler heap | Cache only when source digests, `go.mod`, `go.sum`, build tags, GOOS/GOARCH, Go version, helper version, and relevant environment agree; otherwise invalidate |
| Peak memory | The Go helper owns package/type/SSA memory and exits after producing evidence | FactMine's Rust resident set need not contain the Go type graph | Stream or shard evidence by package; measure helper peak RSS independently and impose a corpus-specific ceiling |

There is no honest fixed byte or millisecond estimate before selecting target
corpora: Go package-graph size, module-cache warmth, generated code, build
tags, and dependency count dominate it. The meaningful estimate is
architectural: a process-sidecar design keeps the **Rust binary and Cargo
compile time close to today's baseline**, while accepting an opt-in additional
native helper artifact, cold-start cost, and temporary helper memory. Linking
or embedding the frontend would move those multi-megabyte and compatibility
costs into every FactMine invocation and is rejected for this programme.

Phase 0 must record these measurements for the existing source-only path and
for any pilot on cold and warm caches:

- stripped `fact-mine-rust` release bytes and helper/distribution bytes;
- Cargo clean and incremental wall time, plus helper clean and cached build
  wall time;
- end-to-end scan wall time, package-load/type-check time, and FactMine import
  time for representative small, median, and dependency-scale targets;
- peak RSS for the Rust process and helper separately;
- cache hit rate and invalidation reason;
- semantic-fact bytes emitted per package and per source LoC.

The backend is accepted only when it passes the semantic criteria below **and**
its measured warm-target overhead is proportionate to the T1 improvement. The
pilot plan must set numerical budgets from the source-only baseline before
implementation—for example, a bounded Rust release-binary delta, a bounded
warm-scan multiplier, and a bounded helper RSS ceiling for each selected CI
class. A backend that improves a narrow metric but makes normal FactMine scans
or distribution materially heavier is a stop result, not an acceptable hidden
trade-off.

## Tiered language strategy

The project may choose deeper semantic integration for languages that account
for most analysed code and materially affect T1 metrics. That is a capacity
decision, not a claim that SCIP is insufficient or that every high-volume
language deserves a full compiler backend.

### Tier 1: optional native semantic evidence; SCIP projection/fallback

For selected critical languages—currently candidates are TypeScript, Go,
Python, Rust, and C/C++—use the following bounded approach after Phase 0
demonstrates an eligible blocker distribution:

| Language | Native semantic source | High-confidence facts worth importing | Important limit / expected scope |
| --- | --- | --- | --- |
| TypeScript | TypeScript `Program`/`TypeChecker` loaded from the actual `tsconfig` | module resolution, symbols, types, overload/signature selection, declared `strictNullChecks` context | The public API exposes types and symbols, not a stable general-purpose flow-nullness/effect API; JavaScript, `any`, proxies, decorators, and dynamic imports remain open. Estimate: 1,500–3,000 production LoC for a pilot. |
| Go | `go/packages` plus `go/types`; add SSA only if Phase 0 proves function-value/callback identity is the dominant blocker | package/build-tag identity, objects, expression types, method sets, declared signatures, direct static callees | These facts feed FactMine directly; SCIP is optional for indexing/navigation. `go/types` is not a general effect/nullness prover. NilAway may provide separately-labelled diagnostic evidence, never an automatic proof. Estimate: 1,500–3,000 production LoC. |
| Python | Pyright or mypy project analysis loaded from its actual environment/configuration | configured import identity, declared/inferred type information, typed-stub contracts | Python remains open-world at runtime; monkey patching, `Any`, dynamic imports, and incomplete stubs must remain blockers. Estimate: 1,500–3,000 production LoC. |
| Rust | Cargo metadata plus rust-analyzer/LSP facts; retain SCIP identity | crate/package identity, symbol/call identity, declared types, trait candidates where exposed | Do not begin with `rustc_private`: it requires compiler-internal components and is not a stable product interface. Rust safe references already reduce nil-specific benefit; prove a call/type/complexity ROI first. Estimate: 900–2,000 production LoC. |
| C/C++ | Version-pinned Clang sidecar loaded from `compile_commands.json` | active preprocessor configuration, AST declaration/type/overload identity, explicit nullability annotations, finite virtual candidates where proven | Highest build and maintenance cost; raw aliases, casts, macros, FFI, and data races still prevent global effect/null proofs. Estimate: 2,500–5,000 production LoC. |

The TypeScript compiler API exposes a `Program` and `TypeChecker`; `go/types`
and `go/packages` provide package-level type checking and object identity; and
Pyright requires configuration/type stubs for its best analysis. Rust compiler
internals are available through `rustc_private` only with extra compiler
components, so they are a poor first stable integration surface. [TypeScript Compiler API](https://github.com/microsoft/TypeScript/wiki/Using-the-Compiler-API), [Go `types`](https://pkg.go.dev/go/types), [Pyright configuration](https://github.com/microsoft/pyright/blob/main/docs/configuration.md), [Rust compiler drivers](https://rustc-dev-guide.rust-lang.org/rustc-driver/external-rustc-drivers.html)

These ranges are not additive until each pilot passes the acceptance criteria.
Implementing all five without evidence would be roughly **6,400–16,000
production LoC** before tests and would violate this document's decision.

### Tier 2: SCIP/LSP only

Lower-volume or future languages, including OCaml, F#, Clojure, Perl, and any
language without a reproducible native semantic backend, should use the common
LSP/SCIP route exclusively:

- emit/consume exact semantic symbols when their language server provides
  them;
- retain source-normalized FactMine structural/CFG facts where supported;
- mark type, dispatch, effect, and build closure as open when SCIP cannot
  prove them;
- never compensate with a consumer-specific resolver.

This is a deliberate capability tier. It still supports accurate identity,
architecture navigation, structural Decomplex analysis, and explicitly
incomplete Espalier results. It does not make compiler-level nullness or
effect-removal claims.

## Phase 0: the required measurement before a backend decision

### 2026-07-22 parser-to-normalizer baseline

Before measuring compiler-semantic gaps, we measured the lower boundary shared
by every supported language: whether a parser-recognized call is retained as a
normalized FactMine call. The 24 pinned repositories in Lineage's
cross-language mini-corpus were replayed with the documented production source
policy and per-file language inference.

| Metric | Before | After | Change |
| --- | ---: | ---: | ---: |
| Raw parser call sites | 22,004 | 22,004 | 0 |
| Raw calls with no matched normalized call | 1,305 | 731 | -574 (-44.0%) |
| Of those, inside an executable function | 1,152 | 608 | -544 (-47.2%) |
| Normalized calls with no parser counterpart | 575 | 254 | -321 (-55.8%) |
| Retained normalized calls | 21,274 | 21,527 | +253 |
| Exact project targets | 4,461 | 4,498 | +37 |

The first part of the reduction is measurement correction: structural span
matching recognizes a normalized callable access (`receiver.member`) as the
same source operation as the parser's enclosing invocation
(`receiver.member()`). The second part is an extraction correction: exported
zero-argument receiver methods and calls in Go `if` initializers are now
retained. The four Go corpus targets alone fell from 175 to 48 raw-only calls
(-72.6%).

This is a meaningful false-negative and observability win, but it is **not**
a proof of semantic completeness. The added calls are predominantly unresolved
without build/type/effect evidence, so the accounted-call rate moved from
34.35% to 34.16% while the denominator became more honest. This is exactly why
consumers must carry a local proof boundary rather than interpreting a larger
or smaller coverage percentage as safety.

Run a reproducible closed-build-target corpus, not a directory of convenient
source files. For each target/language/profile, record:

- executable call sites and their exact, closed-candidate, external-modelled,
  and unresolved proportions;
- nullable states/operations/guards by proof tier and blocker;
- type-driven operations by receiver-type and operation-model blocker;
- callbacks, reflection, FFI, generated code, and dynamic dispatch separately;
- Decomplex findings whose confidence or text would change if the relevant
  boundary were closed;
- Espalier functions whose time/space result is incomplete, grouped by the
  *first* missing proof;
- a manually labelled sample of current high-priority findings, including
  false-positive rate and missed-positive rate.

The report must answer, per language, not merely overall:

```text
Of incomplete T1 results, what percentage is blocked by a fact a selected
compiler backend can actually provide, versus external behavior, dynamic
dispatch, missing library model, or inherently open-world semantics?
```

Without this denominator, a coverage percentage is not a decision metric.

## Pilot acceptance and stop criteria

Proceed from Phase 1 to one language pilot only if Phase 0 shows all of:

1. At least **15 percentage points** of the relevant incomplete T1 output is
   blocked by facts that the selected backend can provide on the actual build
   targets.
2. A labelled sample predicts either a **30% or greater reduction in
   actionable false positives** or capture of **30% or greater of currently
   missed actionable positives** in that affected slice.
3. The resulting fact can be joined to FactMine identities without weakening
   source-digest/span correctness or producing a second resolver in a
   consumer.
4. The compiler/backend is available reproducibly in CI for the selected
   targets and its output identifies configuration/version failures explicitly.

Stop after the pilot unless it demonstrates both:

- at least **5 percentage points** improvement in the affected T1 completeness
  or exactness metric; and
- the labelled precision/recall change predicted above.

Also stop if most remaining blockers are `external_effect`, `dynamic_dispatch`,
`callback_unknown`, `ffi_boundary`, or `unmodelled_operation`. Adding another
compiler query will not close those boundaries.

These thresholds deliberately reject the "80% to 81%" outcome. They accept a
smaller implementation only when it materially lowers noise, captures a large
remaining false-negative class, or unlocks multiple T1 consumers at once.

## Recommended first semantic pilot

The initial measurement should choose the language. Before spending on a Tier 1
backend, rank the critical-language corpus by *eligible blocker share* and T1
impact, not by raw lines of code. A language that represents 40% of source but
whose uncertainty is mostly FFI/dynamic behavior is a worse pilot than a
smaller language with a large, closable null/type/call boundary.

If a decision is required before measurement, prefer **C#** over C/C++ for a
nullness-specific pilot:

- nullable reference type annotations and compiler null-state analysis give a
  natural authoritative input for non-null proof;
- Roslyn can associate results with resolved symbols and source spans;
- the language has fewer raw aliasing/undefined-behavior escape hatches than
  native code;
- the result can improve nullable guards, receiver type identity, call
  identity, and operation modelling together.

Java is a close alternative when the target corpus is consistently
JSpecify/NullAway annotated. Among the proposed Tier 1 languages, TypeScript
or Go are credible first pilots only when Phase 0 shows their unresolved T1
slice is dominated by build/type/symbol identity rather than dynamic behavior.
C/C++ should not be first merely because it has many pointer checks: a larger
share of its uncertainty is likely to be real open-world ownership/effect
uncertainty rather than a missing compiler fact.

The pilot must import only stable semantic facts:

- resolved declaration/symbol identity or a finite candidate set;
- declared and flow-refined nullability/type state at a source location;
- explicit API contract annotations;
- build target/configuration identity.

It must not import compiler diagnostic text as truth, scrape a human report,
or expose a compiler AST to Decomplex/Espalier/NilKill.

## Work explicitly out of scope

The following remain open after every reasonable implementation phase:

| Remaining boundary | Why it remains | Correct FactMine treatment |
| --- | --- | --- |
| Runtime inputs, external services, persistence schemas | The source/build cannot prove their values | Declared contract or `unknown`; runtime evidence is separate |
| Reflection, plugins, dynamic loading, generated code | Target set may be created outside the static corpus | Finite model/candidate set only when explicitly supplied; otherwise open |
| FFI/native calls | Effects, ownership, and nullability are not derivable from syntax | Reviewed contract or unknown boundary |
| C/C++ pointer aliasing, casts, UB, data races | Full sound modelling is expensive and may be invalidated by the program itself | Conservative effect/alias blocker; never infer non-null from absence of evidence |
| Callback behavior and virtual dispatch outside a closed set | Candidate implementation/effect set is open | Closed candidate set with explicit maximum, or unknown |
| Intent of a guard | A technically unreachable check may log, recover, enforce an API, or document an invariant | Review unless an edit policy separately proves behavior preservation |
| General termination and arbitrary semantic equivalence | Fundamentally undecidable | No attempt to prove universally |

Runtime tracing can add an `observed` authority for prioritization, but it
never upgrades an open static boundary into `statically_proven`.

## Consumer policy after Phase 1

Use the same proof vocabulary, but keep the consumer actions different:

- **NilKill:** causal review report only. Show roots, obligations, authority,
  and blockers. Never infer that unobserved null is impossible.
- **Decomplex:** keep structural findings independent. For redundant-guard
  findings, phrase results as `locally dominated` by default; emit `safe
  removal candidate` only for a closed proof and side-effect-free condition.
- **Espalier:** preserve existing `unknown`/candidate-max/assumption policy.
  A compiler fact may close identity or type boundaries, but an unknown cost or
  cardinality remains unknown.
- **Architecture/Lineage:** retain unresolved external edges and their proof
  boundary rather than inventing a target.

## Verification plan

Every phase needs golden/oracle coverage, not only unit coverage:

1. Fact JSON compatibility fixtures for legacy fields and new proof-boundary
   projections.
2. Multi-file fixtures for exact target, closed candidate set, external
   symbol, unknown effect, unannotated contract, and changed build
   configuration.
3. Consumer parity fixtures proving that Decomplex, Espalier, NilKill, and
   architecture artifacts preserve the same authority/blocker instead of
   reclassifying it.
4. Differential corpus report committed or versioned as a test artifact:
   before/after denominator, changed T1 results, precision sample, and runtime
   cost.
5. A hard regression that a compiler fact cannot erase an unresolved effect,
   alias, FFI, or dynamic-dispatch blocker without an explicit corresponding
   proof.

## Final recommendation

Approve Phase 0 and Phase 1. They are bounded, cross-cutting, and improve the
honesty and usefulness of existing Decomplex, Espalier, NilKill, and Lineage
results without promising impossible whole-program certainty.

Do **not** approve a language backend yet. Select one only after the measured
unknown-cause report demonstrates that it can move a meaningful T1 slice. The
existing call-graph and native-registry experiments are evidence that a broad
unmeasured "more semantic analysis" effort can consume thousands of lines for
sub-one-percentage-point gains. The proof-boundary contract and hard pilot
gates are how FactMine avoids that outcome.
