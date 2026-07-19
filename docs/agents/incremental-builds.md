# Incremental Ruby Compiler Builds

Status: Feasibility assessment

Branch baseline: `incremental` from `origin/master` at `466fae2fc`

## Decision

Function-granular incremental compilation is feasible without adding tens of
thousands of lines, but only if the first implementation is deliberately
conservative:

- Fully lex and parse a changed file on every incremental build.
- Incrementally reuse annotation, MIR, checking, and emitted Zig for unchanged
  top-level functions.
- Re-run cheap whole-program fixed-point analyses over cached summaries.
- Fall back to a full compile for type declarations, protocols,
  implementations, imports, global error declarations, sync policies, compiler
  changes, cache-version changes, or any dependency the compiler cannot prove
  unchanged.
- Store portable summaries and generated artifacts in `.clearc`; do not
  serialize the live Ruby AST object graph.
- Reassemble one generated Zig file from ordered fragments. Do not build a
  fragile in-place text patcher or split every function into a Zig module.

This is a medium-sized architectural project, not a parser rewrite. A useful
production implementation is likely 4,000-7,000 total lines including tests,
with approximately 2,500-4,000 production lines. A Rust-style general query
engine or a fully incremental parser would exceed that budget and is not
recommended now.

The go/no-go point should come after a small in-memory prototype proves that a
single changed leaf function can be independently annotated, lowered, checked,
and emitted while producing byte-identical Zig to a clean build.

## Measured Baseline

The current `vm.clear` has 2,741 source lines and 29 functions in the root file.
It also imports the register debugger files.

`tools/sample_compile_stacks.rb` measured the following on this checkout with
Sorbet runtime checks disabled. This times the Ruby compiler pipeline after it
has been loaded; it does not include Ruby process startup or Zig compilation.

| Stage | Seconds | Share |
| --- | ---: | ---: |
| Lex | 0.143 | 1.1% |
| Parse | 0.249 | 1.9% |
| Annotate | 6.164 | 46.5% |
| Pipeline and string rewrites | 0.013 | 0.1% |
| Hoist | 0.145 | 1.1% |
| Pre-MIR type check | 0.073 | 0.6% |
| MIR pass | 1.532 | 11.6% |
| MIR lowering | 3.621 | 27.3% |
| MIR checker | 1.161 | 8.8% |
| Zig emission | 0.141 | 1.1% |
| Total | 13.244 | 100% |

The observed user-facing Ruby transpilation time is closer to 20 seconds once
process startup, loading, CLI work, cache handling, and normal variance are
included.

Annotation is already strongly concentrated by function:

| Function | Body annotation | MIR lowering | MIR checking |
| --- | ---: | ---: | ---: |
| `runRegisterBytecode` | 2.531s | 2.097s | 0.835s |
| `loadPackedRegisterProgram` | 1.001s | 1.069s | 0.110s |
| `registerOpArity` | 0.102s | 0.084s | 0.009s |
| Typical small helper | 0.002-0.015s | 0.002-0.014s | under 0.006s |
| `main` | 0.001s | 0.002s | under 0.001s |

These figures establish two points:

1. Incremental lexing and parsing can save at most about 0.4 seconds on this
   workload. It is not the project that turns a 20-second edit cycle into a
   fast one.
2. Reusing unchanged function annotation and MIR can save almost all of the
   Ruby work for a trivial leaf-function edit.

## Expected Speedup For Trivial `vm.clear` Changes

The initial target is a change to the body of a small leaf function that does
not change its declared or derived semantic interface.

Expected warm costs inside a persistent compiler process:

| Work | Target |
| --- | ---: |
| Full lex and parse | 0.35-0.50s |
| Reconcile item fingerprints | 0.02-0.08s |
| Annotate changed function | 0.002-0.05s |
| Re-run summary-based global analyses | 0.05-0.30s |
| MIR prepare/lower/check changed function | 0.02-0.15s |
| Reassemble/write Zig and cache metadata | 0.05-0.20s |
| Expected total | 0.5-1.3s |

Allowing for implementation overhead and conservative invalidation, a realistic
acceptance target is under 1.5 seconds inside a warm compiler process.

For a one-shot `clear build` that loads `.clearc` from disk, Ruby startup and
compiler loading remain. A realistic target is 2-4 seconds rather than 0.5-1.3
seconds.

Against the current approximately 20-second user-facing Ruby transpilation:

- Warm `clear watch`: approximately 13x-40x faster, with a conservative target
  of at least 10x.
- One-shot `.clearc` build: approximately 5x-10x faster.
- A change inside `runRegisterBytecode` will not be trivial. That function alone
  currently costs about 5.5 seconds across annotation, lowering, and checking,
  so an incremental build changing it may still take 6-8 seconds.
- A change that alters a propagated effect, runtime requirement, stack tier,
  generic contract, or capability requirement can invalidate reverse callers.
  Its speedup depends on the size of that closure.
- A declaration-layout or global-policy change should initially fall back to a
  full build and receive no meaningful Ruby speedup.

If a prototype cannot put a small leaf edit below 2 seconds in a warm process,
the remaining project is unlikely to justify its complexity.

## Existing Assets

The compiler is closer to this boundary than a monolithic visitor would be:

- The lexer records file identity, byte offsets, and line/column ranges.
- Parsed nodes have `AST::SourceRange` values.
- The parser produces top-level declarations with usable source ranges.
- Annotation publishes explicit `ResolutionFacts`, `TypedProgramFacts`, and
  `CapabilityAuditReport` products.
- `FunctionBodySummary` already records callees, propagating callees, call
  sites, locals, bindings, assignments, escapes, `WITH` blocks, and suspend
  points.
- `SemanticIndex` provides function and body summaries.
- MIR lowering already has a per-function `lower` path.
- MIR checking already has `check_fn!`.
- `MIREmitter` can emit an individual `MIR::FnDef`.
- `ModuleImporter` already caches compiled modules for one compiler process.
- `ClearBuildSupport` already has an exact whole-input transpile cache keyed by
  compiler and dependency content.
- `write_if_changed` avoids touching an output whose content is identical.

The exact whole-input cache remains valuable. Incremental work begins only
after that cache misses.

## Current Blockers

### Mutable whole-program AST

Annotation, pipeline rewriting, hoisting, escape analysis, cleanup
classification, and MIR preparation stamp or rewrite the AST. A new parse does
not contain the semantic data needed by MIR. Reusing an emitted fragment is
easy; reconstructing a partially annotated Ruby AST from disk is not.

This is the central boundary to solve. The incremental cache must preserve the
facts needed to decide validity without making every Ruby AST class
serializable.

### Type analysis is not function-query shaped yet

`TypeAnalysisSession#execute_type_analysis!` owns an entire program run.
`analyze_program_bodies!` visits every body, and later finalization scans the
program again. `visit_FunctionDef` is internally function-shaped, but it is not
a public computation that accepts a resolved global environment and returns a
closed function result.

The minimum useful extraction is conceptually:

```text
analyze_function(parsed_function, resolved_environment)
  -> FunctionSemanticArtifact
```

That artifact must contain the annotated function needed by MIR during the
current process plus a portable summary/fingerprint for future processes.

### Whole-program facts can change after a body edit

CLEAR has more body-to-interface propagation than a simple C compiler:

- fallibility and error propagation;
- `needs_rt` and allocation behavior;
- inferred effects;
- reentrancy and recursion classification;
- stack tier and unbounded-stack propagation;
- caller synchronization propagation;
- lock acquisition graphs and lock-cycle SCCs;
- capability requirements and `WITH MATCH` validation;
- BG capture strategy, FSM eligibility, and suspend points;
- escape placement, cleanup recipes, and ownership transport;
- inferred return and `Auto` types.

A body hash match is enough to reuse a function. A body hash change is not
enough to decide that only that function's generated Zig changed. The changed
function must be reanalyzed, its derived semantic interface fingerprint must be
compared, and reverse dependents must be invalidated when that fingerprint
changes.

### Current semantic IDs are not stable across edits

`DefId` and `BodyId` are assigned from the function registry ordinal. Inserting
a function before another function changes later IDs even when their source is
unchanged. Those IDs are appropriate within one compilation but cannot be
`.clearc` keys.

The cache needs stable item keys based on canonical module path, declaration
kind, owner, and declared name. Local numeric IDs can be remapped when a cached
artifact is loaded.

This follows the same requirement described by rustc's stable `DefPathHash`
and local IDs: session-local ordinals cannot identify cached definitions across
source revisions.

### Global emission state

Generated Zig is not only a list of functions:

- `ErrorName` is a per-program enum.
- symbol literals are collected while emitting functions;
- C callback support contributes file-scope declarations;
- a source function can lower to multiple Zig functions, such as wrappers,
  inner functions, thunks, or FSM helpers;
- struct and union methods can be emitted inside their owner declaration;
- imports, protocol adapters, type definitions, FFI declarations, tests, and
  the runtime footer are program-level artifacts.

An incremental unit must therefore return an artifact with text plus explicit
file-scope contributions. A plain `function_name -> String` cache is
insufficient.

### Build directory identity is already stable for a source path

`clear` names the Zig build directory from the canonical source path, not the
source bytes. A body edit therefore retains the same directory in watch mode
and can preserve Zig's incremental state. Build flags still need to remain part
of the build signature, but no source-content directory migration is required
for this MVP.

### Zig incremental compilation is useful but not a correctness oracle

Zig 0.16 can incrementally analyze a changed source file and its official
release notes report millisecond small-edit rebuilds, but the feature still has
known bugs and miscompilations and is disabled by default. CLEAR should retain
a non-incremental verification mode and compare incremental artifacts against
clean builds in tests.

## Designs Considered

### 1. Full source hash only

This is the current transpile cache.

- Complexity: already implemented.
- Hit behavior: excellent when nothing changed.
- Edit behavior: zero reuse after any byte changes.
- Decision: retain as the first cache level, but it does not solve edit builds.

### 2. Incremental lexer and parser first

Possible implementations include lexer checkpoints, reparsing the smallest
top-level range, an immutable green/red syntax tree, or adopting Tree-sitter.

- Benefit on `vm.clear`: at most about 0.4 seconds today.
- CLEAR complications: interpolated strings start nested lexers; comments and
  strings affect delimiter recognition; parser constructs are contextual; all
  ranges after an edit must move; resource-budget accounting must remain
  global.
- Tree-sitter would create a second grammar and a second parser correctness
  surface. It is an incremental concrete-syntax-tree library, but adopting it
  would not make CLEAR's existing semantic AST incremental.
- Decision: do not implement now. Full parsing is the inexpensive and safer
  change detector.

### 3. Serialize the entire annotated Ruby AST

Ruby `Marshal` could persist the current object graph with little initial code.

- Benefit: unchanged functions could be restored with all incidental stamps.
- Problems: class-layout fragility, cycles and aliases, proc/lambda fields,
  importer references, source locations, mutable registry identity, security
  concerns, non-portability to the self-hosted compiler, and poor cache-schema
  control.
- Decision: reject. `.clearc` must be a versioned, language-independent data
  format made of primitive values and explicit records.

### 4. General red-green query engine

Rust and Salsa model compiler work as pure keyed queries, record dependencies
during execution, and reuse a cached result when all inputs remain green. When
an input changed, recomputation can still be backdated if the output
fingerprint did not change.

- Benefit: most accurate long-term model.
- Problem: the Ruby compiler is not query-shaped. It uses mutable AST stamps,
  shared scopes, registries, and ordered phase sessions. Retrofitting a general
  engine would force a broad compiler rewrite before delivering edit latency.
- Expected size: well beyond 10,000 lines once persistence, stable hashing,
  cycle handling, diagnostics, and migration tests are included.
- Decision: use the red-green idea, not a general query engine.

### 5. File-level incremental compilation

Compile unchanged imported `.clear` modules from cache and fully compile the
changed root file.

- Benefit: small extension of `ModuleImporter`; useful for normal multi-file
  projects.
- Limitation: `vm.clear` puts its two dominant functions in one root file, so a
  root edit still pays nearly all current work.
- Decision: implement module-interface fingerprints as part of `.clearc`, but
  do not stop at file granularity.

### 6. Function artifact cache with conservative invalidation

Fully parse, compare stable top-level item fingerprints, reanalyze changed
functions, re-run global summary computations, lower/check only invalidated
functions, and reuse other emitted artifacts.

- Benefit: directly attacks more than 90% of the measured Ruby cost for small
  `vm.clear` edits.
- Complexity: material but bounded.
- Correctness: conservative full-build fallback covers unsupported changes.
- Decision: recommended.

## Recommended Architecture

### Code placement and containment

Incremental behavior should not be sprinkled through annotation, MIR, or the
emitter. Cache policy belongs in one new subsystem:

```text
compiler/ruby/incremental/
  compilation_session.rb   # clean/incremental orchestration
  cache_store.rb            # atomic .clearc read/write/versioning
  cache_schema.rb           # portable MessagePack records
  fingerprints.rb           # stable item/interface/artifact hashes
  item_reconciler.rb        # old/new parsed declaration matching
  dependency_graph.rb       # typed edges and reverse invalidation
  invalidation.rb           # red/green/full-fallback decisions
  emitted_artifact.rb       # Zig fragments and global contributions
  artifact_assembler.rb     # deterministic complete Zig output
```

Expected production-code distribution:

| Location | Purpose | Estimated LoC |
| --- | --- | ---: |
| `compiler/ruby/incremental/` | All cache, fingerprint, graph, invalidation, reconciliation, and assembly policy | 1,300-2,200 |
| Annotation boundary refactor | Extract one-function analysis and summary replay; no cache awareness | 300-650 |
| MIR boundary refactor | Separate local preparation, graph propagation, and function materialization; no cache awareness | 400-800 |
| Emitter/transpiler boundary | Return explicit fragments/global contributions | 100-250 |
| CLI/build/watch integration | Stable session/build path and cache selection | 100-250 |
| Total production | | 2,200-4,150 |

The existing-phase changes are reusable architectural APIs, not incremental
branches. The prohibited shape is code such as `if incremental?` inside a type
visitor, escape-analysis rule, lowerer dispatch, checker, or emitter template.

The intended control flow is:

```text
Incremental::CompilationSession
  -> choose green/red items
  -> call the normal function-analysis API for red items
  -> call normal whole-program summary APIs
  -> call the normal MIR preparation/lowering/checking APIs for red items
  -> reuse closed artifacts for green items
  -> assemble one complete output
```

Clean compilation should use the same extracted phase APIs with every item
marked red. This prevents the incremental path from becoming a second compiler.

`CompilerFrontend` and `ZigTranspiler` should each gain one coordinator-level
entry point. They should not own cache storage or invalidation logic.

### Two cache levels

```text
source and dependency bytes
  -> exact whole-build hash hit
       -> return cached Zig
  -> miss
       -> full lex and parse
       -> reconcile top-level items with .clearc
       -> incrementally compile safe body-only changes
       -> otherwise full compile
```

The first level is the current `.clear-transpile-cache`. The second level is a
versioned `.clearc` artifact.

### Stable item key

Use:

```text
hash(canonical_module_path, owner_path, declaration_kind, declared_name)
```

Examples:

- `file.clear / function / parseLine`
- `file.clear / implementation Cache / method / get`
- `file.clear / struct Cache / definition / Cache`
- `file.clear / test block name / test / case name`

Duplicate declarations are already illegal, so source ordinals should not be
part of normal identity. Anonymous or repeated test constructs can use a
stable explicit test name; otherwise their containing test block is the cache
unit.

### Fingerprints

Each item should carry separate fingerprints:

| Fingerprint | Purpose |
| --- | --- |
| Exact source | Detect byte-identical item reuse, including source maps |
| Syntax | Token kinds and payloads, excluding absolute offsets |
| Declared interface | Name, owner, parameters, types, generic bounds, return, capabilities, effects, visibility |
| Body input | Body syntax plus relevant compiler flags |
| Semantic interface | Derived return, fallibility, effects, runtime need, stack/reentrance metadata, ownership/capability contract |
| Output artifact | MIR/checker contract version and emitted Zig fragments |

Absolute offsets and line numbers must not be part of semantic fingerprints.
They do affect diagnostics and `// CLR:` source mapping, so output reuse also
requires an exact item-source match or a separately regenerated source map.

The first version should require exact item bytes for output reuse. A comment or
whitespace edit inside a function can conservatively rebuild that function.
Comments before a function only change its absolute position; the assembler can
update its item start metadata without invalidating semantics.

### Portable `.clearc` contents

Use MessagePack, which is already a project dependency and is usable by both
Ruby and CLEAR. Store only arrays, maps with fixed schemas, strings, integers,
booleans, and byte strings.

```text
ClearCache
  format_version
  compiler_fingerprint
  target_fingerprint
  build_flags_fingerprint
  root_module
  source_files[]
    canonical_path
    content_hash
    imports[]
  global_interface
    fingerprint
    error_types
    link_inputs
    sync_policy_fingerprint
  items[]
    stable_key
    kind
    owner
    source_range
    fingerprints
    dependencies[]
    semantic_summary
    emitted_fragments[]
    file_scope_contributions
```

Do not store `AST::Node`, `Type`, `Scope`, `SymbolEntry`, `T::Struct`, `Proc`, or
Ruby class names. The cache schema should survive the self-hosting transition.

### Dependency kinds

The cache needs explicit typed edges, not one undifferentiated set:

| Edge | Invalidate when |
| --- | --- |
| Function call | Callee semantic interface changes |
| Type use | Nominal layout or semantic type interface changes |
| Protocol/conformance | Requirement or selected implementation changes |
| Capability/effect | Required family, inferred effect, fallibility, or runtime need changes |
| Ownership/lifecycle | Layout cleanup or transfer contract changes |
| Global policy | Sync policy or error registry changes |
| Import | Imported public interface changes |

`FunctionBodySummary#callees` and `#propagating_callees` provide the first call
edges. Type uses can initially be collected conservatively by walking parsed
type syntax and resolved member/call facts. Unknown dependencies force a full
compile.

### Invalidation algorithm

1. Validate `.clearc` format, compiler, target, flags, and dependency graph.
2. Lex and parse the changed source.
3. Match top-level items by stable key.
4. If a non-function declaration changed, perform a full compile in the first
   implementation.
5. Mark added, removed, or body-changed functions red.
6. Reanalyze each red function against the newly resolved global environment.
7. Compare its new semantic-interface fingerprint with the cached fingerprint.
8. If the semantic interface changed, mark reverse dependents red.
9. Re-run whole-program summary algorithms to a fixed point.
10. If those algorithms change another function's emitted semantic metadata,
    mark that function red and repeat.
11. Run hoist, escape/cleanup preparation, MIR lowering, MIR checking, and Zig
    emission only for red functions.
12. Reuse green emitted artifacts.
13. Rebuild global contributions and assemble items in source order.
14. Atomically publish the Zig output and `.clearc` only after every check
    succeeds.

This is the useful subset of rustc/Salsa red-green evaluation: explicit inputs,
stable fingerprints, reverse dependencies, recomputation, output comparison,
and backdating. It does not require a generic runtime query framework.

### Function semantic artifact boundary

Extract one production API from `TypeAnalysisSession` rather than duplicating
visitor logic:

```text
FunctionSemanticArtifact
  annotated_function
  body_summary
  diagnostics
  ownership_facts
  capability_audit_inputs
  semantic_interface
```

Full compilation should call the same function API for every function.
Incremental compilation calls it only for red functions and replays cached
portable summaries for green functions. There must not be separate full and
incremental annotators.

Whole-program analysis should consume a table of function summaries rather
than assuming it can rediscover facts by walking every function body. This is
also the architectural change most likely to benefit eventual self-hosting.

### MIR boundary

The existing lowering/checking boundary is already close:

```text
annotated function + resolved schemas + lifecycle facts
  -> MIR preparation artifact
  -> MIR FnDef(s)
  -> check_fn!
  -> emitted artifact
```

The difficult part is `MIRPass`, not `MIRLowering`:

- escape analysis currently begins over the complete function table;
- cleanup classification loops over all functions;
- loop-frame analysis is program-wide;
- `needs_rt` is propagated over a reconstructed call graph;
- MIR nodes are inserted back into the AST.

Refactor these into:

1. per-function local preparation;
2. summary-based graph propagation;
3. per-function MIR materialization.

The same full-build path must use those APIs. Do not add an incremental MIR
shortcut that bypasses `LifecyclePlan`, escape analysis, or `MIRChecker`.

### Generated Zig artifacts

Represent an emitted item as:

```text
EmittedArtifact
  stable_item_key
  fragments[]
  symbol_literals[]
  runtime_features[]
  source_map_entries[]
```

A source function may produce more than one fragment. Global prelude and footer
generation merges all item contributions deterministically.

Do not split each function into a separate Zig file. Zig imports create
namespaces rather than textual inclusion, private declarations stop being
file-local peers, and mutually dependent functions would require awkward
module cycles or rewritten calls.

Do not implement byte-offset surgery on the previous `.zig` file. Emission is
only 0.141 seconds for `vm.clear`; assembling cached strings is cheaper and much
safer. The semantic requirement is that only the invalidated declaration text
changes. It is not necessary to preserve the old file's inode or write only a
small byte range.

Keep the generated root path and Zig cache directories stable in watch mode.
Zig's incremental compiler can then compare the new file contents and reuse its
own analysis/codegen state.

## Incremental Parsing Recommendation

### Initial implementation

Always lex and parse the complete changed file.

This provides:

- authoritative nesting and declaration boundaries;
- current source ranges and diagnostics;
- no duplicate grammar;
- no stale lexer-state checkpoints;
- a bounded 0.4-second cost on the current largest motivating file.

Use top-level source ranges to fingerprint and reconcile declarations after the
parse.

### Possible later optimization

If full parse time grows above 10% of successful warm incremental build time,
add top-level declaration reuse:

1. Lex the complete file.
2. Build a balanced top-level declaration boundary index from tokens.
3. Reparse only declarations whose exact token fingerprint changed.
4. Reuse immutable parsed syntax for the others.

Even this should come after parsed syntax is separate from semantic stamps.
Incremental lexing should come later still. It needs restartable lexical states
for normal source, strings, interpolation, escapes, and comments.

Tree-sitter is appropriate for an editor concrete syntax tree, but replacing or
shadowing the compiler parser with it is not justified for a 0.25-second parse.

## CLEAR-Specific Invalidation Rules

### Safe first-version body-only changes

Attempt incremental compilation when all of these hold:

- the same files and import edges exist;
- top-level declaration keys are unchanged;
- no type, protocol, conformance, implementation owner, extern declaration,
  error declaration, test container, or sync policy changed;
- changed functions retain the same declared signature and generic bounds;
- build mode, ownership mode, target, compiler, stdlib, and runtime inputs are
  unchanged;
- all dependencies referenced by cached artifacts are present and understood.

The function can still change its derived interface. Red-green comparison and
reverse invalidation handle that case.

### Immediate full-build fallback

Fall back on:

- struct, enum, union, tuple-layout, collection-layout, or capability-layout
  declaration changes;
- protocol or implementation changes;
- generic binder or bound changes;
- import graph changes;
- extern ABI or link changes;
- global error registration changes;
- sync policy changes;
- `Auto` in a public or cross-function surface;
- unknown indirect function calls;
- cache corruption, missing edge kinds, or version mismatch.

These cases can become incremental later, but they are not needed to prove
large speedups for ordinary function-body editing.

### Generics

CLEAR emits generic functions that Zig specializes through comptime. A generic
body change invalidates that generic function's emitted artifact. A generic
signature or constraint change initially triggers a full build.

The cache must fingerprint the generic source definition, not attempt to cache
every Zig specialization. Zig owns specialization and target code reuse.

### Capabilities and polymorphic synchronization

Capability behavior is part of the semantic interface even when the declared
value type is unchanged. The fingerprint must include:

- `REQUIRES` families;
- inferred/propagated synchronization requirements;
- `WITH POLYMORPHIC` decisions;
- lock acquisitions and relevant lock graph edges;
- capture strategy and storage requirements;
- runtime and fallibility requirements.

A changed function that alters any of these invalidates callers or relevant
whole-program audits. Treating only parameter and return types as an interface
would be unsound in CLEAR.

### Ownership and lifecycle

Cached Zig is reusable only when its checked ownership contract remains valid.
Every artifact fingerprint must include the versions/fingerprints of:

- referenced type layouts;
- lifecycle plans;
- escape placement inputs;
- cleanup classification;
- ownership transport facts;
- MIR checker contract version.

Incremental compilation must never infer ownership from cached Zig text.

## Correctness Strategy

Incremental correctness is a compiler soundness concern. A stale successful
artifact is worse than a slow rebuild.

### Primary oracle

For every incremental test:

```text
clean compile(source revision N)
incremental compile(revision N-1 cache, source revision N)

assert:
  diagnostics are identical
  normalized MIR artifact fingerprints are identical
  generated Zig is byte-identical
  Zig build/run result is identical
```

Byte-identical Zig is intentionally stricter than runtime equivalence and makes
missed invalidation easy to diagnose.

### Required edit matrix

- body literal change in a leaf function;
- body control-flow change;
- changed callee whose semantic interface remains equal;
- changed callee whose fallibility changes;
- changed callee whose `needs_rt` changes;
- changed callee whose effects or capability requirements change;
- direct, mutual, and indirect recursion changes;
- BG/FSM/suspend-point changes;
- ownership escape and cleanup changes;
- function insertion, deletion, rename, and reorder;
- signature, generic, type-layout, protocol, implementation, extern, import,
  error-registry, and sync-policy changes;
- whitespace/comment edits before and inside a function;
- cache corruption and format/compiler version mismatch;
- changes that introduce and then fix a diagnostic.

### Mutation-derived incremental fuzzing

Start from examples, benchmarks, transpile tests, and fuzz-generated valid
programs. Apply one bounded edit, compile incrementally, compile cleanly, and
compare all outputs. Preserve minimized mismatches as permanent regression
tests.

The oracle is not merely "no crash". It is exact equivalence with a clean
build.

### Differential mutation framework

A high-volume framework is straightforward once the incremental compiler has a
session API. It should live under tools rather than in production code:

```text
tools/incremental-testing/
  differential_runner.rb
  mutation_catalog.rb
  source_inventory.rb
  result_comparator.rb
  minimizer.rb
```

The runner should:

1. Load a valid source from `examples/`, `benchmarks/`, `transpile-tests/`, or
   the generated fuzz corpus.
2. Perform a clean baseline compilation and retain its `.clearc`.
3. Discover mutation points from lexer tokens and AST source ranges.
4. Apply one deterministic mutation or a short sequence of mutations.
5. Compile the revision from the previous incremental session/cache.
6. Compile the same revision cleanly with incremental CLEAR compilation
   disabled.
7. Compare structured status, diagnostic identity/ranges/fixes, emitted
   artifact fingerprints, and exact Zig bytes.
8. On a mismatch, save the original source, edit sequence, seed, cache state,
   clean result, and incremental result.
9. Minimize both the source and edit sequence and promote the result to a
   permanent test.

Useful syntax-aware mutations include:

- insert/remove blank lines and comments before or within an item;
- replace same-typed integer, float, string, symbol, and boolean literals;
- replace compatible arithmetic, comparison, and boolean operators;
- add, remove, or reorder a body statement;
- alter an `IF`, `MATCH`, loop, pipeline, `WITH`, BG, or error-handling body;
- add/remove a call edge;
- change a leaf into a fallible, allocating, reentrant, capability-sensitive,
  or suspending function;
- insert, remove, rename, and reorder functions;
- change signatures, generic bounds, types, implementations, imports, externs,
  sync policy, and error declarations to prove full-build fallback;
- edit, revert, and then reapply the same mutation to catch stale revision
  state;
- apply several edits to different functions in one session.

The existing fuzz infrastructure already supplies deterministic seeds, corpus
generation, sharding, preserved failures, coverage matrices, and hundreds of
valid ownership/capability/tense combinations. The incremental runner should
consume those generated programs and source surfaces rather than create a
second language generator. `AST::SourceRange` and lexer offsets provide the
edit locations.

Exact Zig equality makes most cases cheap after Ruby compilation: if the Zig
bytes match, running Zig cannot distinguish the incremental result from the
clean result. Build and run a representative subset to verify the harness and
source-map behavior; do not pay Zig compilation cost for every mutation.

Suggested scale:

| Lane | Cases | Purpose |
| --- | ---: | --- |
| Focused specs | 30-60 | Every invalidation and fallback rule |
| Pull request | 100-300 | Small examples, transpile tests, fuzz samples, and 10-30 `vm.clear` edits |
| Nightly | 1,000-5,000 | Full example/benchmark/fuzz inventory and multi-edit sequences |
| Release verification | Targeted plus sampled native runs | Clean/incremental/Zig end-to-end equivalence |

One thousand independent clean `vm.clear` compiles would cost several CPU
hours, so it is the wrong corpus distribution. Use thousands of mutations over
small and medium programs, shard them across processes, and retain a smaller
targeted set for the expensive MiniVM. Ruby compiler globals make process
sharding safer than threads.

Estimated framework size is 500-900 lines for the runner/comparator/storage and
300-700 lines for the reusable mutation catalog and minimizer. The framework
is not the difficult part of incremental compilation. The difficult part is
creating closed semantic artifacts and sound dependency fingerprints for it to
test.

### Runtime guardrail

Provide:

- `--no-incremental-clear` to bypass `.clearc` while optionally retaining Zig
  incremental compilation;
- `CLEAR_VERIFY_INCREMENTAL=1` to run both incremental and clean Ruby
  compilation and fail on any artifact difference;
- structured invalidation logs explaining every green/red/full-fallback
  decision.

Release and CI builds should continue to use clean compilation until the
differential suite has substantial history.

## MVP Implementation Result

The in-memory Phase 1 MVP is implemented under `compiler/ruby/incremental/`.
It uses a deliberately narrow fast path:

- fully lex and parse the new source;
- reconcile root functions by stable module/name keys and token fingerprints;
- accept exactly one body-only edit to a root function with no user-code
  callers or callees and no source-line-layout change;
- preserve declarations and line positions while masking other root function
  definitions;
- run the changed function through the ordinary annotator, lifecycle/MIR
  preparation, MIR lowering, and strict MIR checker;
- resume `MIREmitter` from its exact pre-function state;
- reject changes to the emitted function contract, global emission state, or
  program error registry;
- deterministically reassemble cached checked fragments; and
- clean-compile every unsupported edit.

The production implementation is approximately 660 physical lines including
strict type declarations and comments. Incremental policy remains contained in
`compiler/ruby/incremental/`; the only phase-boundary changes are a checked-MIR
result in `ZigTranspiler` and explicit top-level emission-state snapshots in
`MIREmitter`.

Measured on `examples/minivm/vm.clear`, changing one same-width fallback
literal inside the isolated `loadRegisterOps` function produced byte-identical
Zig in 5.21 seconds versus 28.81 seconds for a clean compilation, an 82%
latency reduction. The initial compilation was 29.90 seconds. This proves the
artifact boundary and substantial reuse value, but it misses the proposed
under-2-second go/no-go target. Roughly five seconds of declaration/import/type
environment reconstruction remains even after the large function bodies are
removed. Reaching the original target requires replayable resolution/type
environment summaries; adding more source masking will not solve it.

`tools/incremental-testing/` now performs clean-versus-incremental differential
literal mutations and edit/revert cycles. Its fixture run covers 95.1% of the
incremental production subsystem by lines; targeted `prspec` examples close
all executable production lines in that subsystem to 100%.

## Implementation Phases And Size

### Phase 0: Stable watch/build identity and measurement

Work:

- make watch build directories stable across source edits;
- add stage, cache-hit, invalidation, and per-function counters;
- add a clean-versus-incremental benchmark command;
- define stable item keys and canonical fingerprints.

Estimate: 300-600 production/test lines, 2-4 days.

Acceptance:

- the Zig watcher remains on one build directory across edits;
- baseline behavior is unchanged;
- every incremental decision is measurable.

### Phase 1: In-memory leaf-function prototype

Work:

- reconcile fully parsed top-level items;
- extract the function semantic artifact boundary;
- retain green function artifacts in a persistent Ruby watch process;
- reanalyze, lower, check, and emit one changed leaf function;
- reassemble and compare with a clean full compile.

Estimate: 800-1,500 production/test lines, 1-2 weeks.

Acceptance:

- byte-identical Zig for the safe edit matrix;
- under 2 seconds for a trivial `vm.clear` leaf edit;
- no ownership, lifecycle, or checker bypass;
- unsupported edits explicitly fall back to a full compile.

Stop the project if this phase requires duplicating the annotator or MIR
pipeline, or if it cannot meet the latency target.

### Phase 2: Summary-based propagation

Work:

- make whole-program effect/capability/stack/lock computations consume
  function summary tables;
- compute semantic-interface fingerprints;
- add reverse call/dependency invalidation;
- separate per-function MIR preparation from graph propagation;
- support changes whose derived interface invalidates callers.

Estimate: 1,200-2,000 production/test lines, 2-3 weeks.

Acceptance:

- caller closures invalidate correctly;
- unchanged derived outputs are backdated and do not invalidate callers;
- full compilation uses the same summary APIs.

### Phase 3: Portable `.clearc`

Work:

- define versioned MessagePack records;
- persist fingerprints, summaries, dependency edges, and emitted artifacts;
- load green artifacts in a new Ruby process;
- add atomic publication and corruption recovery;
- keep the schema consumable by the future CLEAR compiler.

Estimate: 700-1,300 production/test lines, 1-2 weeks.

Acceptance:

- one-shot trivial edits transpile in 2-4 seconds;
- deleting `.clearc` changes performance only, never output;
- old, corrupt, or incompatible caches fail closed to a clean build.

### Phase 4: Broaden only from measured demand

Candidates:

- type/interface changes with typed dependency invalidation;
- protocol/conformance changes;
- finer source-map regeneration;
- top-level incremental parsing;
- cross-module public-interface backdating.

Do not schedule this phase until telemetry shows which full-build fallbacks are
common enough to matter.

## Approximate Total Cost

| Scope | Production LoC | Test/tool LoC | Effort |
| --- | ---: | ---: | ---: |
| Feasibility prototype | 500-1,000 | 300-700 | 1-2 weeks |
| Safe body-only incremental builds | 2,500-4,000 | 1,500-3,000 | 4-7 weeks |
| General query engine plus incremental parser | 8,000-15,000+ | comparable | multiple months |

The recommended body-only system stays below the prohibited tens-of-thousands
range. The general system does not.

## Final Assessment

- Incremental parsing is easy to overvalue here. It addresses about 3% of the
  measured Ruby pipeline.
- Function-granular annotation/MIR reuse has high potential because two
  `vm.clear` functions dominate the work and small helpers are individually
  cheap.
- The compiler's current phase products, body summaries, per-function lowering,
  and per-function checking make a bounded implementation plausible.
- Mutable AST stamps and whole-program MIR preparation are the real work.
- A `.clearc` containing portable summaries and emitted artifacts is coherent;
  a serialized Ruby object graph is not.
- Literal in-place `.zig` patching provides little value. Deterministically
  reassembling one Zig file from cached fragments is simpler, safer, and fast.
- The first prototype should target persistent `clear watch`; portable
  cross-process `.clearc` reuse follows only after the semantic boundary works.
- The project should proceed through Phase 1 only. Continue beyond it if the
  prototype stays under roughly 1,500 lines, produces byte-identical clean
  output, and makes trivial `vm.clear` edits complete in under 2 seconds.

## External Design References

- [rustc incremental compilation](https://rustc-dev-guide.rust-lang.org/queries/incremental-compilation.html): query dependency DAG and red-green validation.
- [rustc incremental compilation in detail](https://rustc-dev-guide.rust-lang.org/queries/incremental-compilation-in-detail.html): stable definition identities, stable fingerprints, cache promotion, and codegen-unit reuse.
- [Salsa red-green algorithm](https://salsa-rs.github.io/salsa/reference/algorithm.html): memoized tracked functions, backdating equal outputs, and durability.
- [Salsa overview](https://salsa-rs.github.io/salsa/overview.html): explicit input, tracked, and interned query data.
- [Swift 5.2 compiler requests](https://www.swift.org/blog/swift-5.2-released/): immutable declarations, lazy request evaluation, caching, and dependency tracking replacing coarse mutable validation.
- [Swift dependency-file model](https://download.swift.org/docs/assets/generics.pdf): provided/required names and replaying dependencies of cached requests.
- [Tree-sitter](https://tree-sitter.github.io/tree-sitter/): incremental concrete syntax tree parsing and changed-range reuse.
- [Zig 0.16 incremental compilation](https://ziglang.org/download/0.16.0/release-notes.html#Incremental-Compilation): persistent watch mode, dependency-graph improvements, expected small-edit latency, and current correctness caveats.
