# CLEAR Self-Hosting Plan

Status: proposed implementation plan, based on the `self-host-i` tree on
2026-07-17.

## Executive judgment

Incremental self-hosting through a MessagePack boundary is feasible and is the
right strategy. Translating the parser's current Ruby dependency closure in one
step is not.

The proposed order is directionally correct:

1. make `ruby-to-clear` emit the current CLEAR language;
2. establish a real cross-language wire contract;
3. port and prove the type and AST foundations in bounded slices;
4. port the parser after those dependencies are native CLEAR;
5. port resolution, type analysis, and capability audit;
6. run the CLEAR frontend with the Ruby MIR/backend through a MessagePack
   handoff;
7. port the remaining compiler stages and prove a stage1/stage2 bootstrap.

The adjustment is that `ast.rb` and `type.rb` should not be translated as two
unchanged monoliths. Both currently combine several phase-specific concerns.
Doing that would preserve the Ruby compiler's worst coupling in the
self-hosted compiler and make the wire format depend on private Ruby object
layout. We should first create explicit, versioned data contracts, then port
vertical slices behind the existing Ruby APIs.

The hybrid compiler is a valuable milestone, but it is not itself a self-host.
A self-host exists only when a compiler built by the Ruby stage0 can build a
stage2 compiler whose behavior and artifacts agree with stage1.

## What the current tree says

### Dependency size

The parser is only 5,787 lines across `parser.rb` and its seven grammar-domain
files, but its recursive Ruby `require_relative` closure is much larger:

| Starting unit | Files | Ruby LoC in recursive closure |
| --- | ---: | ---: |
| Lexer | 2 | 608 |
| Type | 7 | 7,247 |
| AST | 11 | 11,805 |
| Parser | 26 | 22,149 |
| Annotation pipeline | 165 | 108,363 |

The largest parser dependencies are:

| File | LoC | Why it is pulled in |
| --- | ---: | --- |
| `ast/type.rb` | 5,642 | Parser constructs semantic `Type` values |
| `ast/ast.rb` | 3,981 | Parser constructs production AST nodes |
| `ast/diagnostic_registry.rb` | 3,752 | Parser diagnostics |
| parser domain files | 5,010 | Actual grammar implementation |
| `ast/type_expression.rb` | 850 | Structural type syntax |
| `ast/lexer.rb` | 550 | Tokens and tokenization |
| `ast/schemas.rb` | 531 | Parsed declaration schemas |

The annotation closure reaches 108,363 lines partly because
`ResolutionPhase` requires `ModuleImporter`, and `ModuleImporter` compiles an
import all the way through MIR lowering and emission. That cycle must be split
before mechanically translating annotation. Otherwise a request to port the
frontend silently becomes a request to port nearly the whole compiler.

### `type.rb` is several systems in one file

`type.rb` has 438 methods. It currently owns all of the following:

- parsed and legacy type spelling;
- structural `TypeExpression` and `TypeShape` access;
- semantic type identity and compatibility;
- capability and placement mutation;
- operator typing and coercion;
- collection, stream, Tuple, generic, and tense queries;
- ownership, copy, promotion, and cleanup classification;
- schema-recursive layout decisions;
- resource-close behavior;
- direct Zig type rendering and backend-specific names.

This explains why the Type closure includes the Zig renderer. It also means a
single serialized `Type` object is not a stable contract: some fields are
syntax, some are semantic identity, some are inferred placement, and some are
backend projections.

The good foundation already exists in `TypeExpression`: types have a
structural representation. The plan should finish that separation rather than
serialize `Type`'s Ruby instance variables.

`ParsedTypeSyntax` is also a useful start, but it is not yet a full separation:
several parser type routines still construct `Type` and then wrap or extract
its `TypeExpression`. The parser is therefore still coupled to semantic Type
behavior despite the syntax wrapper.

### `ast.rb` is both syntax and a mutable compiler notebook

`ast.rb` contains roughly 188 class/module/Struct declarations, 424 methods,
and 115 `attr_accessor` declarations. Parser-created syntax nodes are later
stamped with:

- resolved types and coercions;
- symbols and function signatures;
- capability and effect facts;
- ownership and escape facts;
- call and collection dispatch classifications;
- rewrite metadata;
- MIR cleanup and allocation plans;
- FSM and thunk plans;
- backend-oriented storage decisions.

This is workable inside one Ruby process, but it is a poor wire model. Parsed
syntax, semantic facts, and MIR-preparation facts need separate tables joined
by stable node IDs. The Ruby compatibility layer may continue exposing the old
node accessors while the port proceeds.

### Existing phase architecture is useful but not yet serializable

Annotation now has three real public products:

1. `ResolutionFacts`;
2. `TypedProgramFacts`;
3. `CapabilityAuditReport`.

`AnnotationProducts` enforces their order and identity, which is exactly the
shape a self-host needs. However, the products still contain Ruby objects such
as `AST::Program`, `Scope`, `FunctionRegistry`, and `OwnershipGraph`.
`SemanticIndex` also exposes those objects directly. These are good in-process
contracts, not yet cross-process contracts.

`CompilerFrontend::Result` is a more immediate blocker: it returns the
`SemanticAnnotator` itself, and later stages call back into it for schema and
scope queries. A Ruby backend cannot consume a CLEAR frontend cleanly until
that receiver dependency is replaced by an explicit backend-input product.

### Existing MessagePack work is an oracle prototype

`tools/lexer_compat.rb` and `tools/parser_compat.rb` already compare Ruby and
CLEAR and write MessagePack artifacts. This is useful and should be retained.
It is not the production handoff yet:

- CLEAR prints an ad hoc canonical text encoding;
- Ruby parses that text into generic values;
- Ruby then writes MessagePack;
- parser objects are discovered through reflection and instance variables;
- the corpus is currently a smoke corpus;
- the schema represents comparison output, not a backend-consumable AST.

The production protocol must encode and decode MessagePack bytes on both
sides, use explicit node/type schemas, and reject missing, duplicate, unknown,
oversized, or cyclic data safely.

### `ruby-to-clear` is close structurally but behind the language

The last measured audit in `docs/agents/self-host.md` reported 96.32% clean
nonblank source lines and 99.69% handled Prism-node sites across the compiler.
Those numbers show that automatic migration remains credible. They are not a
build or behavior-equivalence claim.

The current translator still emits several pre-change CLEAR forms, including:

- bang-suffixed mutating functions and calls instead of explicit `&value`;
- `||` and `&&` in generated expressions;
- raw `&`, `|`, and related Ruby operator spellings where CLEAR now expects
  `BIT_AND`, `BIT_OR`, and `XOR`;
- postfix collection types such as `T[]` in many inference paths;
- Tuple construction through `CAST([a, b] AS Tuple<A, B>)` and Tuple indexing;
- mutable receiver temporaries based on the old bang-method convention.

This must be corrected before generated compiler files are judged. Autofix can
be used as a migration oracle, but generated files that only pass after
autofix are translator failures. Generated CLEAR should not be manually
maintained.

## Performance case for the hybrid compiler

A fresh unchecked MiniVM profile on this branch measured compile through Zig
source emission as follows:

| Stage | Seconds | Percent of measured total |
| --- | ---: | ---: |
| Lex | 0.147 | 1.2% |
| Parse | 0.247 | 1.9% |
| Annotation | 5.677 | 44.8% |
| Rewrites, hoist, pre-MIR, MIR pass | 1.780 | 14.0% |
| MIR lowering | 3.654 | 28.8% |
| MIR checker | 1.037 | 8.2% |
| MIR emission | 0.137 | 1.1% |
| Total | 12.678 | 100% |

Within annotation:

| Annotation phase | Self seconds | Calls |
| --- | ---: | ---: |
| Resolution | 0.848 | 3 |
| Type analysis | 4.697 | 3 |
| Capability audit | 0.033 | 3 |
| Outside named phases | 0.099 | — |

The three calls are the main program plus imported MiniVM modules. Resolution
also triggers full module compilation through `ModuleImporter`, so its
inclusive work is larger than its self time.

For the measured compile-to-emission workload:

- lex + parse + annotation are 47.9% of total time;
- annotation alone is 44.8%;
- type analysis alone is 37.0%.

Amdahl's law gives the realistic expectation:

| Ported work | CLEAR speedup | Ideal total reduction before handoff |
| --- | ---: | ---: |
| Annotation only | 2x | 22.4% |
| Annotation only | 3x | 29.9% |
| Annotation only | 4x | 33.6% |
| Lex + parse + annotation | 2x | 23.9% |
| Lex + parse + annotation | 3x | 31.9% |
| Lex + parse + annotation | 4x | 35.9% |

Therefore a 30-40% reduction is plausible, not guaranteed. It requires:

- roughly a 3-4x speedup in the ported frontend;
- one process handoff per package build, not per phase or file;
- serialization, process startup, and Ruby hydration below roughly 0.2s on
  MiniVM;
- no duplicated Ruby shadow execution in normal production mode;
- measurement of transpilation separately from the later Zig compiler build.

If the CLEAR implementation is only twice as fast, the likely win is closer to
20-24%. If `clear build` time includes a large Zig build, the end-to-end
percentage will be smaller even though transpilation improves as expected.

## Target architecture

The first production hybrid should look like this:

```text
Ruby CLI / build driver
  -> one framed MessagePack CompilePackageRequest
  -> CLEAR frontend worker
       source loading and module graph
       lexer
       parser
       resolution
       type analysis
       capability audit
  <- one TypedPackageSnapshot plus diagnostics
  -> Ruby snapshot hydrator / BackendInput adapter
  -> rewrites + hoist + MIR pass
  -> MIR lowering + checker + emitter
  -> Zig source
```

The worker should initially be a subprocess, not Ruby FFI:

- a crash cannot corrupt the Ruby process;
- ownership and GC boundaries remain explicit;
- exact request bytes are reproducible test artifacts;
- process startup is negligible relative to a 5-13 second compile;
- the same protocol can later support a persistent compiler daemon.

The protocol should use length-prefixed frames over stdin/stdout. Human logs
must go to stderr. A request ID, schema version, compiler revision, language
mode, target, source hashes, and module graph hash must be in every envelope.

### Do not make annotation call back into Ruby

Bidirectional RPC for `REQUIRE`, scope lookup, or schema lookup would recreate
the current coupling with more failure modes. The CLEAR worker should own the
complete frontend module graph for a request. It should return a snapshot for
the root and every imported module. The Ruby backend can then lower those
modules in dependency order.

To enable this, split the current `ModuleImporter` into:

1. module path/package resolution and source loading;
2. frontend export/import resolution;
3. backend module lowering and emission.

Resolution should consume an immutable `ModuleExportIndex`, not a Ruby
`CompiledModule` containing MIR and emitted Zig.

## Wire contracts

MessagePack is the transport, not the schema. Define one neutral schema
manifest and generate both Ruby and CLEAR codecs from it. Generated codecs are
checked in and are never reflection-based. The manifest and generator must
eventually be runnable by the stage1 compiler, but the initial generator may
remain Ruby stage0 tooling.

Prefer arrays with fixed field numbers over arbitrary maps for high-volume
records. Maps are acceptable for envelopes and diagnostics where extensibility
is useful. All enum values need stable numeric tags; Ruby class names and
symbols are not wire tags.

### Required envelopes

1. `CompilePackageRequest`
   - protocol/schema version;
   - request ID and operation;
   - root file and source bytes or content-addressed source table;
   - package paths and target triple;
   - language/ownership mode and strict-test flags;
   - resource budgets.

2. `TokenSnapshot`
   - source ID;
   - stable token-kind tag;
   - tagged payload;
   - byte start/end offsets;
   - start/end line and column.

3. `SyntaxSnapshot`
   - source table;
   - range table;
   - node table keyed by stable `NodeId`;
   - node kind and syntax-only fields;
   - root node IDs;
   - parsed `TypeExpression` table.

4. `ResolvedProgramSnapshot`
   - `DefId`, `BodyId`, `ScopeId`, `LocalId`, and `PlaceId` tables;
   - declaration and module export indexes;
   - schemas and function contracts;
   - node-to-definition/name-resolution facts.

5. `TypedProgramSnapshot`
   - interned semantic types keyed by `TypeId`;
   - node-to-type and coercion tables;
   - call resolution and generic substitutions;
   - body summaries, effects, ownership, capture, lifetime, and capability
     facts needed after annotation;
   - backend-visible schema and signature tables.

6. `CapabilityAuditSnapshot`
   - checked functions/sites;
   - solved capability/effect/lock facts that later stages consume;
   - success marker and invariant counts.

7. `DiagnosticSnapshot`
   - stable diagnostic code and severity;
   - source range and related ranges;
   - structured arguments;
   - fix edits;
   - phase and cause chain.

### Identity, cycles, and ownership

Repeated objects must be interned and referenced by IDs. Do not recursively
duplicate `Type`, schema, scope, symbol, or function-signature objects.

The decoder must allocate a request-owned arena, validate all table indexes,
and publish immutable snapshots only after full validation. Mutable compiler
state belongs to a phase-local context, not to decoded syntax records. This
maps naturally to CLEAR's ownership model and avoids per-node reference-count
traffic.

The protocol must enforce limits for bytes, strings, collection lengths,
nesting, table sizes, and referenced IDs. Malformed MessagePack must produce a
stable diagnostic or protocol failure, never a crash or uncontrolled
allocation.

### Equivalence means behavior, not Ruby layout

For `type.rb`, create operation requests that cover every public operation
used by the parser, annotator, or backend:

- parse and normalize;
- canonical semantic key and source rendering;
- tense/capability/collection decomposition;
- equality, acceptance, coercion, and binary operators;
- Tuple/generic/stream/future queries;
- placement, copy, promotion, cleanup, and resource classification under an
  explicit schema context;
- Zig projection while it remains part of the compatibility surface;
- every mutator as `before + operation -> after`.

For `ast.rb`, prove:

- Ruby encode -> CLEAR decode -> CLEAR encode -> Ruby decode;
- CLEAR encode -> Ruby decode -> Ruby encode -> CLEAR decode;
- canonical syntax snapshots agree for parser inputs;
- traversal/body-slot behavior agrees;
- source ranges and diagnostics agree;
- semantic facts attach to the same node IDs;
- old Ruby accessor behavior agrees with the side-table adapter.

NaN, infinity, signed zero, UInt64 boundaries, invalid UTF-8 source bytes,
symbols versus strings, absent versus explicit nil, deterministic map order,
and unknown schema versions all need direct cases.

## Phased implementation plan

Each phase below must land as a sequence of small commits. A generated file is
never hand-fixed: change Ruby source, translator metadata, or the translator,
then regenerate.

### Phase 0: Pin the baseline and repair `ruby-to-clear`

Deliverables:

- Record raw G1-G5 verifier results for the compiler seed set.
- Add current CLEAR syntax to the translator's typed IR and emitter.
- Replace generated bang mutability with `TAKES MUTABLE` and explicit `&` at
  mutable lvalue call sites; anonymous values and always-mutable fields follow
  normal CLEAR rules.
- Emit `AND`, `OR`, `XOR`, `BIT_AND`, and `BIT_OR` correctly.
- Emit current inline collection/type syntax.
- Emit `Tuple{...}`, `Tuple<T...>`, and `._N`; never Tuple array indexing.
- Understand `IMPLEMENTATION`, `METHOD`, current generic bounds, and current
  union/type spellings where Ruby source maps to them.
- Lower Ruby operations that can fail to explicit `TRY` at the
  generated leaf and mark that generated function `RETURNS !T`. Do not silently
  substitute Ruby sentinel values such as `String#to_i`'s zero.
- Provide `clear fix --propagate-fallible --loop` as the follow-up migration
  pass for a generated module: it adds `!` through its caller chain and wraps
  otherwise-unhandled generated call sites in `TRY`. The compiler's
  normal fallibility fixed point is the sole authority for this; ruby-to-CLEAR
  must not maintain a second call graph.
- Upgrade the verifier so raw success, autofix-assisted success, build success,
  and behavioral success remain separate.

Exit gate:

- lexer and selected Type/AST seed files compile from freshly generated raw
  CLEAR with no unsupported marker; where a module has an intentionally
  staged cross-file failure contract, the propagated-autofix result is tracked
  separately and must converge deterministically;
- translator specs contain positive and negative cases for every language
  change above;
- the generated output hash is deterministic.

### Phase 1: Build the production wire foundation

Deliverables:

- A minimal bounded MessagePack implementation usable from CLEAR.
- Framed stdin/stdout request handling.
- The schema manifest and Ruby/CLEAR codec generator.
- Source, range, token, diagnostic, type-expression, and node-ID codecs.
- Cross-language round-trip and malformed-input tests.
- Adapt `lexer_compat.rb` to compare native MessagePack payloads rather than a
  CLEAR textual intermediate.

Exit gate:

- both languages independently produce byte-identical canonical payloads for
  the oracle corpus;
- decoders reject every malformed/oversized fixture safely;
- encode/decode cost and payload size are reported for MiniVM.

### Phase 2: Extract and port the type kernel

Refactor Ruby behind the existing `Type` facade into:

1. immutable type syntax (`TypeExpression`);
2. canonical semantic type identity and interning;
3. type relations, operators, and coercion;
4. capabilities and placement;
5. ownership/layout/cleanup queries;
6. backend Zig rendering.

The port order should be 1 through 5. Zig rendering may remain Ruby until the
backend moves, provided its input is the canonical semantic type rather than
private `Type` state.

Exit gate:

- every production Type operation is represented in the MessagePack oracle;
- Ruby and CLEAR agree over fixtures plus generated type/capability nesting;
- semantic type IDs are deterministic and interned;
- parser-facing Type dependencies no longer require Zig rendering;
- no compatibility method reconstructs semantic identity through legacy type
  strings.

### Phase 3: Extract and port syntax AST and schemas

Deliverables:

- An explicit closed AST node registry.
- Syntax-only node records with stable IDs and source ranges.
- Separate semantic and MIR-preparation side tables.
- Ruby adapters that preserve current AST accessors for existing passes.
- Ported declaration schemas, params, struct fields, source errors, diagnostic
  definitions, and resource budget.
- Generated visitors/walkers from the node registry.

The 3,752-line diagnostic registry is mostly data and should be generated from
one source, not translated as hand-written logic.

Exit gate:

- every syntax node round-trips Ruby <-> CLEAR;
- traversal order and body ownership are identical;
- adding a node without codec and visitor coverage fails generation/CI;
- parser dependencies use the syntax AST and TypeExpression layers, not the
  fully annotated mutable AST.

### Phase 4: Port the parser by grammar domain

Port in the existing module order, keeping one cursor, one resource budget,
and one precedence model:

1. parser state, delimiters, and diagnostics;
2. type syntax;
3. expressions and postfix operations;
4. predicates and refinement bindings;
5. statements and control flow;
6. declarations and definitions;
7. collections, capabilities, and tenses.

Exit gate:

- canonical AST equivalence on transpile tests, fuzz-generated valid sources,
  examples, benchmarks, docs, and hostile-source fixtures;
- diagnostic code, span, and fix equivalence for invalid inputs;
- parse-format-parse equivalence;
- geometric depth/time/memory budgets pass;
- no crash, hang, uncontrolled allocation, or non-diagnostic exception;
- no accepted-language change is hidden in a porting commit.

At this point the CLEAR lexer/parser is production-capable, but using it alone
will save only about 3% on MiniVM. Its primary value is unlocking annotation.

### Phase 5: Create the Ruby backend boundary before porting annotation

Do this in Ruby first. Replace `CompilerFrontend::Result#annotator` with an
explicit `BackendInput` assembled from current Ruby annotation products.

Deliverables:

- schema lookup, imported signatures, body summaries, ownership facts, and
  module exports are explicit fields/services over immutable data;
- rewrites, hoist, MIR pass, and lowering cannot call a
  `SemanticAnnotator` receiver;
- `ModuleImporter` has separate frontend and backend responsibilities;
- a Ruby snapshot can serialize, hydrate, and produce identical MIR/Zig.

Exit gate:

- Ruby frontend -> MessagePack -> Ruby backend matches the current in-process
  compiler on MIR, diagnostics, and emitted Zig;
- no backend source requires `SemanticAnnotator`;
- round-trip overhead is below the provisional 0.2s MiniVM budget or has a
  measured optimization plan.

This phase proves the eventual hybrid seam without debugging two languages at
once.

### Phase 6: Port module resolution and contracts

Port the small, closed foundations first:

- semantic IDs;
- declaration index;
- module export index;
- schema and signature contracts;
- scopes and symbol entries as phase-local state;
- intrinsic/builtin registries;
- implementation/conformance registration.

Resolution should operate over parsed modules and export indexes. It must not
invoke MIR lowering or emission.

Exit gate:

- `ResolutionFacts` has a serializable counterpart with no Ruby object;
- multi-module, package, visibility, generic, FFI, and circular-import cases
  match Ruby;
- module caching keys include source, compiler, target, mode, and schema
  versions;
- resolution performs no Ruby callback.

### Phase 7: Port type analysis in bounded domains

This is the largest performance and correctness milestone. Port the existing
domain structure rather than the 108k-line require closure:

1. variables, bindings, and destructuring;
2. expression and member access;
3. calls, signatures, generics, and unions;
4. control flow and refinement facts;
5. functions, returns, errors, and Auto finalization;
6. execution boundaries, BG/DO/STREAM, and captures;
7. ownership, lifetimes, and effect facts;
8. whole-program constraint finalization.

Each slice consumes an explicit context and publishes fact tables keyed by
stable IDs. Do not reproduce a giant shared annotator receiver in CLEAR.

Exit gate:

- node types, coercions, call targets, signatures, body summaries, diagnostics,
  and semantic IDs agree on the complete corpus;
- each domain has mutation and negative diagnostic coverage;
- constraint solvers have convergence and resource budgets;
- MiniVM CLEAR type analysis is materially faster than Ruby's current 4.7s.

### Phase 8: Port capability audit and enable the hybrid frontend

Capability audit is small in runtime but mandatory for soundness. Port it only
after typed facts agree.

Rollout:

1. shadow mode runs both frontends and returns Ruby output;
2. CI records every semantic/diagnostic divergence;
3. `--frontend=clear` opt-in returns the CLEAR snapshot;
4. preview default may fall back to Ruby with an explicit warning and retained
   artifact;
5. release default removes silent fallback.

Exit gate:

- Ruby and CLEAR agree on the full valid/invalid corpus;
- capability, effect, lock, ownership, and lifetime negative tests agree;
- the hybrid path is at least 25% faster on MiniVM and a representative corpus;
- the 30-40% target is accepted only if the corpus median demonstrates it;
- p95 handoff overhead stays within budget.

### Phase 9: Port the normalized middle and MIR

Port in data-boundary order:

1. pipeline and string-concat rewrites;
2. hoist/typed normalization;
3. escape and ownership facts that correctly belong after hoist;
4. MIR data model;
5. MIR pass and cleanup/control-flow analysis;
6. MIR lowering;
7. MIR checker.

Use MessagePack phase snapshots as differential oracles. Once a CLEAR stage is
the production owner, remove its Ruby implementation after an agreed deprecation
window rather than maintaining two permanent compilers.

### Phase 10: Port emission, driver, and build orchestration

Port the emitter last. It is easy to compare but depends on every prior
contract. Then port the compiler driver, package resolution, cache, CLI,
filesystem/process adapters, and build orchestration needed to invoke Zig.

Exit gate:

- the CLEAR compiler emits byte-identical Zig where ordering is specified and
  semantically identical normalized Zig elsewhere;
- all examples, benchmarks, transpile tests, fuzz gates, and integration tests
  build under the CLEAR compiler;
- Ruby is no longer needed for a normal compiler invocation.

### Phase 11: Prove the bootstrap

Use explicit stage terminology:

- stage0: trusted Ruby compiler and pinned Zig toolchain;
- stage1: CLEAR compiler built by stage0;
- stage2: CLEAR compiler built by stage1.

Required proof:

- stage1 builds stage2 from a clean tree;
- stage1 and stage2 compiler outputs agree under a documented normalization;
- stage2 compiles the full conformance corpus;
- clean bootstrap is reproducible from the pinned stage0 artifact;
- the trust chain, tool versions, source hashes, and generated schema hashes
  are recorded.

Only this milestone is self-hosting.

## Effort and critical path

These are engineering-effort ranges, not calendar promises. They assume the
current translator and generated frontend work are retained where correct,
but include differential tests and production gates rather than only getting a
file to parse.

| Work | Estimated focused effort |
| --- | ---: |
| Translator/current-language repair | 1-2 engineer-weeks |
| Wire schema, MessagePack, and codec safety | 1-3 engineer-weeks |
| Type separation and Type kernel port | 2-4 engineer-weeks |
| Syntax AST/schema separation and port | 2-4 engineer-weeks |
| Parser port and full equivalence | 3-6 engineer-weeks |
| Ruby backend boundary and module split | 2-4 engineer-weeks |
| Resolution/contracts port | 3-5 engineer-weeks |
| Type-analysis port | 6-10 engineer-weeks |
| Capability audit and hybrid rollout | 2-4 engineer-weeks |
| Normalization, MIR, checker, and lowering | 8-14 engineer-weeks |
| Emitter, driver, build, and bootstrap | 4-8 engineer-weeks |

The likely hybrid-frontend critical path is 22-42 engineer-weeks. A complete
release-quality self-host is more plausibly 34-64 engineer-weeks. Mechanical
translation can shorten individual implementation slices, but it does not
remove the schema, oracle, module-boundary, or bootstrap work.

The stop/go checkpoints are:

1. after Phase 0, verify that raw build failures are concentrated enough for
   automatic translation to remain the primary strategy;
2. after Phase 2, verify that canonical Type identity works without legacy
   strings before expanding the port;
3. after Phase 5, reject the proposed hybrid boundary if all-Ruby
   serialize/hydrate cannot reproduce identical MIR and Zig;
4. during Phase 7, compare each domain immediately rather than waiting for a
   complete annotator;
5. after Phase 8 shadow mode, enable the CLEAR frontend only if correctness and
   measured speed both justify it.

## Test strategy

Every implementation commit must keep new and changed executable lines at
100% LoC coverage. Test in this order:

1. transpile tests and end-to-end compiler fixtures;
2. existing or expanded fuzz matrices;
3. integration-style compiler specs that start from CLEAR source strings;
4. targeted unit tests for codecs, table validation, or otherwise unreachable
   branches.

Run Ruby specs through `prspec`.

The self-host matrix needs independent dimensions:

| Dimension | Required evidence |
| --- | --- |
| Translation | Raw generated CLEAR parses and builds; no autofix credit |
| Codec | Ruby/CLEAR round-trip, cross-version rejection, malformed fuzzing |
| Lexer | Exact token values and ranges; hostile byte/source corpus |
| Parser | AST goldens, diagnostics, format round-trip, grammar fuzzing |
| Type | Operation-level differential property tests |
| Resolution | Multi-module exports, visibility, cycles, cache determinism |
| Type analysis | Typed facts, diagnostics, mutations, constraint budgets |
| Capabilities | Negative soundness matrix and polymorphic synchronization |
| Boundary | Ruby round-trip MIR/Zig equivalence |
| Runtime | Result/output/error equivalence on examples and benchmarks |
| Bootstrap | stage1/stage2 artifact and behavior equivalence |

Do not compare only successful programs. Diagnostics and fix edits are compiler
outputs and require the same compatibility bar.

## Performance gates

Record, per corpus item and per module:

- process startup;
- MessagePack encode/write/read/decode;
- snapshot validation and Ruby hydration;
- lex, parse, resolution, type analysis, audit;
- rewrites, hoist, MIR pass, lower, check, emit;
- peak RSS, allocation count, payload bytes, and cache hits;
- cold and warm runs.

Initial budgets for MiniVM:

- one frontend worker process per package build;
- total wire + validation + hydration below 0.2s;
- establish the payload baseline before ratcheting it; a provisional guardrail
  is below 10x source bytes and below 32 MiB for MiniVM;
- no phase slower than its Ruby counterpart when enabled by default;
- hybrid median at least 25% faster before rollout;
- 30-40% is a stretch/acceptance target measured over the representative
  corpus, not inferred from one profile.

Keep a long-lived worker/daemon as a later optimization. Do not add daemon
state before the one-shot protocol is deterministic and safe.

## Principal risks and mitigations

### Accidental architecture preservation

Risk: automatic translation reproduces Ruby's mutable AST notebook and Type
monolith.

Mitigation: port wire schemas and phase products, preserve old Ruby APIs only
through temporary adapters, and prohibit Ruby object layout from the protocol.

### Translator success that is only syntactic

Risk: a file has no unsupported marker but uses stale syntax, `Any`, wrong
ownership, or incorrect control flow.

Mitigation: keep G1-G5 separate; raw build and behavioral oracle gates are
mandatory. Autofix-assisted output never counts as raw success.

### Module-import recursion

Risk: CLEAR resolution asks Ruby to compile imports, causing nested processes,
duplicated work, or frontend/backend cycles.

Mitigation: the CLEAR worker owns the full frontend module graph and exchanges
only module export indexes and final package snapshots.

### Snapshot incompleteness

Risk: Ruby MIR reads an undocumented annotation field that was omitted from
the wire format.

Mitigation: first force the all-Ruby compiler through the serialized
`BackendInput`; prohibit callbacks to `SemanticAnnotator`; make missing facts
fail at the boundary with node/range context.

### Type identity drift

Risk: semantically equal types acquire different IDs or capabilities are
attached to the wrong collection layer.

Mitigation: canonical structural types, explicit capability-per-layer fields,
interning, randomized nesting/tenses/capabilities, and Ruby/CLEAR semantic-key
oracles.

### Ownership overhead in compiler data

Risk: a literal translation adds reference counting or copies to every node.

Mitigation: request arenas, immutable published tables, integer IDs, borrowed
phase views, and phase-local mutation. Use CLEAR capabilities where they express
real sharing, not to decorate every compiler record.

### Diagnostic regressions

Risk: semantic behavior agrees but errors lose spans, fixes, or clarity.

Mitigation: diagnostics are a first-class wire product with exact negative
snapshots and mutation tests.

### Long-lived dual implementation

Risk: Ruby and CLEAR diverge while both receive features.

Mitigation: time-box shadow mode, designate one owner per completed phase, and
remove migrated Ruby behavior after the compatibility window.

### Bootstrap circularity

Risk: the compiler requires a feature only the new compiler can build.

Mitigation: pin stage0, keep schema/code generators stage0-compatible until
their CLEAR replacements work, and require stage1/stage2 bootstrap in CI before
dropping stage0 support.

## First commit sequence

### Pre-self-host translation gate

Before porting another compiler file, classify every generated workaround by
owner. A construct that is awkward in generated CLEAR is not automatically a
CLEAR language gap.

The 2026-07-20 `Type` audit found:

| Generated shape | Actual cause | Owner / decision |
| --- | --- | --- |
| `type__new(...)` | Ruby `new` must allocate a complete value, invoke translated `initialize`, and return it | Keep the generated factory. CLEAR already supports optional/default parameters; this is not evidence for constructor overloading. |
| `value:? = maybe_value()` | CLEAR intentionally rejects silently inferred optional bindings | ruby-to-CLEAR must emit `:?`. This is implemented and regression-tested. Ruby has no native error-union or temporal return types, so `:!`/`:~` need no speculative Ruby inference. |
| `WITH POLYMORPHIC self` and `@multiowned` around value-like compiler types | ruby-to-CLEAR treated every ordinary Ruby class as identity-bearing and ignored `# ruby-to-clear: value` | Fix the translator. A value-marked class must remain an ordinary CLEAR value across reopenings. Do not weaken CLEAR ownership rules. |
| `unsupportedRuby` in omitted `T::Struct` fields | Required-file defaults were rendered before local constructor metadata was indexed | Keep default expression nodes and render them after metadata collection. Do not add a second constructor path to CLEAR. |
| `return` inside `each`/`each_value` | Ruby non-local block return has no direct CLEAR pipeline meaning | Prefer explicit loops in translated output or a Ruby source cleanup. Do not add non-local closure returns to CLEAR; they complicate control flow and lifetime analysis. |
| Long positional generated factory calls | CLEAR has no named call arguments | Defer as a language decision. Signature-aware positional lowering is exact. Named calls would improve human-authored APIs and diagnostics, but are not required for semantic self-hosting and would touch parser, annotation, MIR, formatting, and function-value rules. |
| Collection-valued parameter defaults | Previously recorded as unsupported | No longer a gap. Current CLEAR accepts and type-checks defaults such as `xs: []Int64 = []` and `table: {String}Int64 = {}`. Ruby defaults still need fresh-value semantic tests. |
| A frozen Ruby `Set` emitted as `names = [...] |> DIST` at module scope | ruby-to-CLEAR preserved the collection's runtime representation instead of its constant semantics | Fix before the next port. A closed frozen membership table should lower to immutable compile-time data or a generated membership function. It must not allocate a mutable process-global set. |
| A top-level owned collection reaches Zig as `var ...; defer cleanup(...)` | CLEAR's frontend currently accepts a lifetime it cannot emit: Zig does not permit a top-level `defer` | Fix the compiler validation now. Until a real module-initialization/termination model exists, reject cleanup-bearing top-level values with a source diagnostic. Never let valid-looking CLEAR fail later as malformed Zig. |
| `type.clear -> struct_field.clear -> type.clear` | the Ruby object graph is recursive and generated type references create package edges even when the Ruby `require` graph looks one-way | Fix the boundary before file-by-file Type migration. Parsed type syntax and field declarations must live in an acyclic foundation package; semantic `Type` can then depend on that package. Do not teach the package loader to compile arbitrary cycles as an expedient. |
| `Any` in generated `StructField`, schema defaults, and function-signature payloads | genuine Ruby `T.untyped`/union erasure at a few boundaries, plus translator loss of known union members | Audit now. Replace wire-facing `Any` with closed unions or typed syntax records. Retain `Any` only at an explicitly documented dynamic compatibility boundary; it cannot appear in the native frontend snapshot. |
| Repeated `CAST(... AS TypeExpression)` | Ruby models the TypeExpression interface as a Sorbet module union; CLEAR requires a concrete closed union conversion | Mostly translator/manual representation work, not a new cast feature. The self-hosted syntax package should define one closed `TypeExpression` union so constructors produce it directly and callers do not repeatedly reassert the type. |
| `FrontendResourceBudget@multiowned` stored in `Lexer`, but constructor parameters are plain `?FrontendResourceBudget` | Ruby passes one identity-bearing mutable budget through nested lexers; CLEAR deliberately forbids `@multiowned` parameter annotations and plain parameters borrow only the payload | Resolve before self-hosting. This is not a legal `COPY` conversion: structural copying would create independent budget state, while copying an Rc handle without retain is unsound. Define the bind-time contract for retaining a caller's local multi-owner identity (likely a `LOCAL` requirement plus explicit `CLONE`/retain transport), then make ruby-to-CLEAR emit that contract. Do not weaken the MIR ownership verifier or silently upgrade the budget to `@shared`. |

The capability gap should preserve CLEAR's bind-time model rather than put
`@multiowned` back into ordinary parameter types. The most coherent candidate
is a retained-parameter contract: a plain `T` parameter constrained to a local
multi-owner binding, with an explicit effect saying that the call may retain
that identity. Inside the function, `CLONE parameter` would mean a real Rc
retain, not a structural payload copy. In illustrative syntax:

```ruby clear illustrative
FN lexer(source: String, budget: FrontendResourceBudget) RETURNS Lexer
  REQUIRES budget: LOCAL
  EFFECTS RETAINS budget
->
  RETURN Lexer{ budget: CLONE budget, source: COPY source };
END
```

The exact spelling needs to be reconciled with existing `REQUIRES`/`EFFECTS`
syntax. The semantic requirements do not: the call site must supply an existing
local Rc identity, MIR must emit one retain, the callee may store the retained
handle, and ordinary borrowed parameters must remain non-escaping. This is a
general capability feature needed by caches, graph contexts, compiler budgets,
and other local identity graphs; it is not a lexer-specific exception.

After the two translator ownership/metadata fixes, fresh `type.rb` output fell
from 6,121 to 4,817 lines, all 305 invented polymorphic receiver scopes were
removed, and constructor placeholders fell from ten to three. The remaining
three are the same non-local-return pattern in
`parallel_boundary_forbidden_reason`; they are not a reason to expand CLEAR's
language semantics.

Work that should happen before the next phase:

1. require zero `unsupportedRuby` sites for each seed file before manual edits;
2. keep honoring explicit value-vs-identity metadata across required files and
   reopened Ruby classes;
3. lower known optional Ruby locals with `:?` and retain explicit unwrapping;
4. produce explicit loops for enumerable blocks with non-local control flow,
   or simplify the Ruby source where that produces better compiler code;
5. audit generated `Any` and capability changes as semantic failures, not just
   syntax cleanup.
6. reject cleanup-bearing top-level values before Zig emission and lower frozen
   static membership tables without runtime global ownership;
7. break the `Type`/`StructField`/schema package SCC at the parsed-type-syntax
   boundary rather than adding cyclic package compilation;
8. require every file admitted to a phase to pass raw G1, frontend/MIR G3, Zig
   G4, and its behavioral oracle. A checked-in hand-edited file must not mask a
   generated dependency failure.
9. prove identity-preserving transport for a local `@multiowned` value passed
   through a function and retained in another object. The lexer budget oracle
   is the first acceptance case; nested lexers must observe the same nesting
   counter, not a copied budget.

Work that should not block the next phase:

- named call arguments;
- a special public constructor protocol solely to replace `type__new`;
- non-local return from CLEAR lambdas/pipeline blocks;
- generic `Auto` wrappers that would weaken the target type system.

### Pre-self-host stop/go criteria

The next phase may begin once the following narrow conditions hold:

1. `lexer.rb` and the committed `lexer.clear` agree on the complete lexer
   corpus, not merely compilation. The raw generator must also remain G4-clean.
2. The Type foundation (`TypeExpression`, capabilities, `StructField`, and
   schema field metadata) has an acyclic package graph and a MessagePack oracle.
3. No translated compiler module can pass the CLEAR frontend and then fail Zig
   because ownership cleanup was emitted at module scope.
4. Every remaining `Any`, `CAST`, generated factory, and polymorphic receiver in
   the Type foundation has an explicit disposition. Counts alone are not a
   quality gate: each use must be either required by the model or removed.
5. `ruby-to-clear` emits `:?` for known optional Ruby results. It must not weaken
   CLEAR's no-inferred-optional rule, and it must not invent `:!` or `:~` for
   Ruby semantics that do not have those result wrappers.
6. The generated lexer passes the behavioral oracle with the shared resource
   budget enabled. MIR must contain retain/release operations for the same
   local identity and no structural `DeepCopy` of an Rc/Arc handle.

These are prerequisites because they prevent semantic drift or invalid target
code. Named arguments, general cyclic modules, Ruby exception emulation, and a
public constructor protocol are not prerequisites and should not delay the
first proven frontend slices.

### Whole-compiler unsupported-Ruby audit

The same 2026-07-20 verifier run covered all 213 Ruby compiler files and
114,742 source lines. Raw translation reached G1 for 168 files (78.87% of
files, 67.25% of source lines), but only six files reached native G4. Forty-five
T0 failures remain. They divide into different ownership classes and must not
all become CLEAR features:

| Ruby construct | Count | Disposition |
| --- | ---: | --- |
| `ensure` | 13 | Refactor Ruby to explicit resource scopes or existing RAII/CLOSE constructs. Do not import Ruby unwinding semantics. |
| complex `rescue` | 6 | Refactor compiler boundaries to explicit fallible results. Improve ruby-to-CLEAR only for narrow, statically equivalent rescue forms. |
| global variable access | 6 | Remove hidden compiler state and pass an explicit context/session. This is Ruby architectural cleanup. |
| constructor keyword/unknown-field calls | 7 | Improve metadata collection and signature-aware positional lowering. This does not require named CLEAR calls. |
| shell interpolation (`xstring`) | 2 | Use an explicit process API if the compiler genuinely needs it; do not add shell syntax to CLEAR. |
| implicit regexp state / dynamic regexp / regexp replacement blocks | 5 | Prefer explicit match values. Add a dynamic regex constructor or callback replacement to the standard library only where it is independently useful and safe. |
| reflection (`const_get`, dynamic `is_a?`) | 2 | Replace with closed unions or explicit registries in Ruby. Do not add runtime reflection to the self-hosting substrate. |
| collection/block control-flow mismatches | 2 | Lower to explicit loops or clean the Ruby. Do not add Ruby non-local block returns. |
| encoding/method-shape edge cases | 2 | Preserve UTF-8 semantics and fix translator method dispatch where statically knowable. |

The dominant G3 failure is not one of those syntax constructs: 49 independent
roots reach the same generated package cycle,
`type.clear -> struct_field.clear -> type.clear`. That makes the acyclic Type
foundation a much higher-value prerequisite than implementing scattered Ruby
features.

The rebased ruby-to-CLEAR golden suite also needs a deliberate migration to the
current CLEAR surface. Its old branch expectations still spell legacy arrays,
logical operators, implicit returns, mutating bang names, and earlier ownership
rules; 332 of 562 examples currently fail when run together. Those failures
must be classified and updated before treating the translator as green. They
are not evidence that the current compiler baseline regressed: the rebased
compiler's 7,197 non-integration examples pass independently.

The first useful commits should be:

1. Add current-language failing fixtures to `ruby-to-clear` for mutability,
   operators, inline types, Tuples, methods, and generics.
2. Make those fixtures emit raw buildable CLEAR and regenerate the lexer seed.
3. Define the frontend wire schema envelope, stable IDs, tokens, ranges, and
   diagnostics.
4. Add bounded Ruby and CLEAR MessagePack primitives plus cross-language codec
   tests.
5. Convert lexer compatibility to native MessagePack and expand its corpus.
6. Extract TypeExpression/canonical type identity behind the Ruby `Type`
   facade.
7. Add the Type operation oracle and port type syntax/identity to CLEAR.
8. Split Zig rendering and legacy-string compatibility out of the parser's
   Type dependency.
9. Generate the closed syntax AST registry and codecs.
10. Port syntax AST/schemas and prove full round-trip/traversal equivalence.
11. Port parser state/type grammar, then the remaining parser domains one at a
    time.
12. Introduce all-Ruby serialized `BackendInput` and remove backend calls to
    `SemanticAnnotator`.

These commits create material progress immediately: the translator becomes
usable again, the lexer becomes a real independently executable stage, Type
and AST become bounded units, and every later port uses a durable boundary.

## Definition of success

The plan succeeds when:

- freshly generated CLEAR, not manually repaired output, is the source of the
  self-hosted compiler;
- each migrated phase has Ruby/CLEAR behavioral equivalence and hostile-input
  coverage;
- the hybrid CLEAR frontend/Ruby backend is the measured default and produces
  the same diagnostics, MIR, and Zig as the Ruby frontend;
- stage0 builds stage1, stage1 builds stage2, and stage1/stage2 agree;
- stage2 passes compiler specs, transpile tests, fuzzing, examples, benchmarks,
  integration tests, mutation gates, and bootstrap reproducibility checks;
- the resulting CLEAR compiler uses explicit immutable phase products rather
  than a translated Ruby-shaped shared-state object graph.

The core operating rule is:

> Translate volume automatically, define boundaries deliberately, compare every
> phase independently, and never debug a later divergence that an earlier
> oracle could have caught.
