# Decomplex Tree-sitter Migration Design

Status: implemented. This document is kept as migration context; references to
RubyVM, Prism, or temporary dual parser modes describe the pre-migration plan,
not current production parser paths.

## Goal

Make Decomplex usable on most source languages by replacing the
Ruby-only parser boundary with Tree-sitter-backed language adapters,
while preserving the existing Ruby output contract.

For Decomplex specifically, the current Ruby-only dependency is
`RubyVM::AbstractSyntaxTree`, not Prism. The broader `gems/` parser
migration still applies: sibling gems such as Espalier and nil-kill use
Prism, SlopCop uses `RubyVM::AbstractSyntaxTree`, and all of them
benefit from the same eventual Tree-sitter syntax layer. This document
scopes the first step to Decomplex because Boobytrap, SlopCop, and
Espalier consume Decomplex results directly.

Non-goals:

- Do not change Markdown output for existing Ruby runs.
- Do not change `Report#sections_data`, `StateBranchDensity.scan`, or
  `RubyTopology.scan` consumer contracts until downstream gems are
  migrated.
- Do not build a sound whole-program analyzer. Decomplex stays a
  ranked-candidate miner over local syntax and lightweight facts.
- Do not require every detector to work equally well on every language
  on day one. Missing support should be explicit and quiet, not a
  crash.

## Parser Inventory Across `gems/`

The repository currently has three parser situations:

| Gem | Parser state | Migration implication |
|---|---|---|
| Decomplex | Uses `RubyVM::AbstractSyntaxTree`; no Prism dependency. | First target is still Decomplex because it publishes the structural-risk contract other gems consume. The work is "replace Ruby-only AST access," not "swap Prism calls" inside Decomplex. |
| SlopCop | Uses `RubyVM::AbstractSyntaxTree` for coverage-arm classification and optionally consumes Decomplex. | SlopCop should keep consuming Decomplex findings unchanged while Decomplex moves parser internals. A later SlopCop migration can reuse the same syntax facade. |
| Espalier | Uses Prism for its own AST extraction and calls `Decomplex::RubyTopology.scan`. | Decomplex must preserve `RubyTopology` for Espalier; Espalier's Prism extractor can later move to Tree-sitter or consume generalized Decomplex topology. |
| Nil-kill | Uses Prism extensively for source indexing, rewrites, instrumentation, and z3 evidence extraction. | Nil-kill is not a Decomplex consumer, but it is the largest Prism migration surface. Decomplex's syntax facade should avoid Decomplex-only assumptions so shared parser work remains possible. |
| Boobytrap | Does not parse source through Decomplex internals; consumes Decomplex report data. | Boobytrap should not know or care whether Decomplex used RubyVM or Tree-sitter. |

This plan therefore treats Decomplex as the contract owner and parser
abstraction pilot. Once Decomplex can publish identical Ruby findings
from Tree-sitter-backed facts, the same facade can be evaluated for the
larger Prism-heavy gems.

## Existing Decomplex Contract

Decomplex currently exposes two categories of API.

### Human output

`Decomplex::Report#to_markdown` renders:

- stable section names and section ordering from `Report::SECTIONS`
- `file:method:line` locations rendered through `Report#nav`
- top-25 ranked findings per section
- convergence and root-cause summaries
- a run summary

The migration should not add parser names, language tags, or altered
wording to existing Ruby output unless that is a deliberate later
report-version change.

### Machine output

Sibling gems consume these exact shapes:

| Consumer | Current dependency on Decomplex | Compatibility requirement |
|---|---|---|
| Boobytrap | `Decomplex::Report.new(files).sections_data`, `Convergence.rollup`, `StateBranchDensity.scan(files).findings` | Keep `[title, tier, findings]`; keep `Score` inputs keyed by `[relpath, method]`; keep state branch hashes with `:file`, `:at`, `:decisions`, `:state_refs`, `:score`, `:predicate`. |
| SlopCop | `Report#sections_data`, `Convergence.locations`, `Convergence.parse_loc`, finding `:spans` | Keep location strings in `file:method:line` form; keep `:spans` as `{ loc => [first_line, first_col, last_line, last_col] }`; preserve the span invariant asserted by `sections_data`. |
| Espalier | `Decomplex::RubyTopology.scan(files)` and report-text parsing of convergence rows | Keep `RubyTopology::Graph`, `Method`, and `Edge` shapes for Ruby; do not break convergence Markdown row format before Espalier stops parsing it. |
| Delta / CLI | `Delta.snapshot(rep.sections_data, rep.root_clusters)` | Keep root clusters and section findings stable enough for line-insensitive before/after identity. |

The most important invariant is that Decomplex owns findings and
locations. Consumers read verdicts; they must not re-derive Decomplex
logic.

## Current Parser Coupling

Most detectors are coupled directly to Ruby AST node types, child
indexes, and span methods:

- `Ast.parse` returns `[RubyVM::AbstractSyntaxTree::Node, lines]`.
- `Ast.node?`, `Ast.slice`, `Ast.def_push`, `Ast.body_stmts`, and
  `Ast.flatten_and` expose Ruby AST details.
- Older modules still parse directly instead of using `Ast.parse`:
  `SiteExtractor`, `CoUpdate`, and `PredicateAlias`.
- `RubyTopology` is Ruby-specific in both name and semantics:
  class/module owners, `public`/`private` visibility, bare/self calls.

That means a direct replacement of `RubyVM::AbstractSyntaxTree.parse`
with Tree-sitter would still leave detectors full of Ruby node names
such as `:DEFN`, `:CALL`, `:ATTRASGN`, `:IASGN`, `:CASE`, `:WHEN`,
`:AND`, and `:QCALL`.

The migration should not attempt to construct `RubyVM::AbstractSyntaxTree::Node`
objects from Tree-sitter. That would preserve the wrong runtime
abstraction and make every new language emulate Ruby internals. Instead,
introduce a Decomplex syntax facade for direct facts and a small generic
Decomplex AST vocabulary for detectors that already share `Ast.parse`.

## Proposed Architecture

Add a parser and fact layer under `Decomplex::Syntax`, then move
detectors from raw Ruby AST walks to language-neutral facts.

```
Decomplex::Syntax.parse(file, language: nil)
  -> Document

Document
  # file, language, source, lines
  # root wrapper node
  # language adapter

Node
  # type, children, span, text
  # Decomplex-owned generic node, not a RubyVM object

LanguageAdapter
  # methods and owners
  # branch/decision shapes
  # calls and receivers
  # reads/writes
  # literals and constants
  # comments/blank-line boundaries
  # language capability flags
```

The facade should produce stable facts. Detectors should consume facts
before falling back to syntax nodes.

Recommended fact records:

| Fact | Fields | Used by |
|---|---|---|
| `FunctionDef` | `file`, `name`, `owner`, `line`, `span`, `body`, `visibility` | location keys, convergence, topology, WICC, locality, operational discontinuity |
| `OwnerDef` | `file`, `name`, `kind`, `line`, `span` | topology, temporal ordering, class/module style detectors |
| `CallSite` | `file`, `function`, `line`, `span`, `receiver`, `message`, `args`, `bare`, `self_call`, `safe_navigation` | false simplicity, sequence mining, topology, decision pressure |
| `StateRead` | `file`, `function`, `line`, `span`, `receiver`, `field` | StateMesh, state branch density, temporal ordering |
| `StateWrite` | `file`, `function`, `line`, `span`, `receiver`, `field` | CoUpdate, StateMesh, temporal ordering |
| `LocalRead` / `LocalWrite` | `name`, `line`, `span`, `value`, `deps` | derived state, locality drag, function LCOM |
| `DecisionSite` | `kind`, `members`, `file`, `function`, `line`, `span`, `predicate` | missing abstractions, neglected conditions, SlopCop spans |
| `PathAction` | `guards`, `action`, `file`, `function`, `line`, `span` | path conditions |
| `ProtocolEvent` | `message`, `receiver`, `file`, `function`, `line`, `span`, `path_context` | sequence mining, broken protocols, implicit control flow |
| `Boundary` | `kind`, `line`, `text` | operational discontinuity, locality drag |

The current detector output hashes should remain unchanged. Only their
input source changes.

## Language Profiles

Each language should be a small profile, not a fork of every detector.

```
lib/decomplex/languages/ruby.rb
lib/decomplex/languages/python.rb
lib/decomplex/languages/javascript.rb
lib/decomplex/languages/typescript.rb
lib/decomplex/languages/go.rb
lib/decomplex/languages/rust.rb
```

Each profile owns:

- file extensions
- Tree-sitter grammar loading
- Tree-sitter query strings or query files
- mapping from syntax captures to Decomplex facts
- naming rules for functions, methods, classes/modules/types
- field/read/write rules
- call and receiver rules
- language-specific guard lexicons
- capability flags

Example capability flags:

```
{
  owners: true,
  visibility: false,
  methods: true,
  bare_self_calls: false,
  safe_navigation: false,
  nil_literal: true,
  exception_rescue_nil: false,
  monkeypatching: false,
  comments: true,
  case_dispatch: true,
  boolean_chains: true,
  field_writes: true
}
```

Detectors should skip unsupported sub-signals rather than infer them
from unrelated syntax.

## Native Rust Port Contract

The Rust implementation is a performance port, not a new Decomplex.
It must stay structurally symmetric with the Ruby implementation so the
remaining detectors and languages can be migrated mechanically.

Rules:

- Port Ruby files file-for-file and function-for-function unless a
  later optimization is proven after parity.
- Keep the normalized AST API aligned with `lib/decomplex/ast.rb`:
  `parse`, `node`, `slice`, `body_stmts`, `def_push`,
  `canon_polarity`, `flatten_and`, and the `Node` vocabulary.
- Keep language adapters responsible for syntax normalization, not
  detector decisions. Detectors should consume the same normalized AST
  or the same syntax facts their Ruby counterpart consumes.
- Do not hide AST drift by sorting, filtering, or reshaping detector
  results. Fix the normalizer or the detector port so the canonical
  JSON matches Ruby output.
- Every native detector needs an engine-parity test and a real `src/`
  parity smoke before it is treated as migrated.

Current split:

- `DecisionPressure`, `PredicateAlias`, and `SemanticAlias` are
  AST-backed ports and compare byte-for-byte with Ruby on `src/`.
- `CoUpdate` and `Miner` consume syntax facts because their Ruby
  counterparts consume `Syntax.parse` / `SiteExtractor` facts.
- `FlaySimilarity` consumes `Syntax.parse` in both Ruby and Rust.

## Preserving Output

Ruby migration must be gated by exact-output tests before Tree-sitter
becomes the default for Ruby.

Preserve:

- section titles and order
- finding hash keys
- sort order
- score formulas and thresholds
- location string shape: `file:method:line`
- method names for Ruby, including `(top-level)` and `self.foo`
- span shape: `[first_line, first_col, last_line, last_col]`
- current column convention: 1-based lines and 0-based columns
- source text normalization from `Ast.slice`: trim and collapse
  whitespace with `gsub(/\s+/, " ")`

Tree-sitter points are row/column pairs where rows are zero-based.
Adapters must convert to existing Decomplex spans. Be careful with
byte columns versus character columns; Decomplex currently slices Ruby
source strings using Ruby offsets, and SlopCop span joins depend on
those columns matching coverage data.

For non-Ruby languages, keep the same output schema even though exact
text and method naming will naturally be language-specific.

## Detector Migration Order

### Phase 0: Freeze Ruby baselines

Before changing parser internals:

- Add fixture-level snapshots for `Report#sections_data`.
- Add Markdown snapshots for representative Ruby input.
- Add explicit tests for `:spans` on every detector that emits spans.
- Add consumer fixture tests for Boobytrap, SlopCop, and Espalier.
- Capture a small real-project baseline from `src/` if runtime is
  acceptable in CI, or use it as a manual smoke command.

This is the safety net that enforces "avoid changing the output."

### Phase 1: Centralize current Ruby AST access

Move direct parser calls behind `Decomplex::Ast` or the new
`Decomplex::Syntax` facade without changing behavior.

Targets:

- `SiteExtractor.extract`
- `CoUpdate.scan`
- `PredicateAlias.scan`
- any direct `RubyVM::AbstractSyntaxTree::Node` checks outside `ast.rb`

At the end of this phase, RubyVM remains the backing parser, but the
parser boundary is centralized.

### Phase 2: Add Tree-sitter Ruby adapter behind a flag

Add a Ruby Tree-sitter adapter and dual-run mode:

```
DECOMPLEX_PARSER=rubyvm
DECOMPLEX_PARSER=tree_sitter
DECOMPLEX_COMPARE_PARSERS=1
```

The adapter should first emit facts, not try to satisfy every existing
raw-node helper. For migration convenience, a thin compatibility layer
can keep `Ast.slice`, `body_stmts`, and `flatten_and` alive while
detectors are moved, but new detector code should consume facts.

Exit criteria:

- existing Ruby unit tests pass with the old parser
- migrated detector tests pass with Tree-sitter Ruby
- compare mode shows exact equality for migrated detector outputs

### Phase 3: Port high-value universal detectors

Start with detectors whose defect class is language-agnostic and whose
inputs map cleanly to facts:

| Detector | Required facts | Notes |
|---|---|---|
| Missing Abstractions / Neglected Conditions | `DecisionSite` for case/switch and boolean chains | Highest value, most portable. |
| CoUpdate / Neglected Updates | `StateWrite` | Generalize "attribute" to field/property/member/key where the language profile supports it. |
| StateMesh | `StateRead`, `StateWrite`, re-derivation links | Natural consumer of fact extraction. |
| State-Based Branch Density | `DecisionSite` plus state refs inside predicates | Important for Boobytrap. |
| Path Conditions | branch facts plus condition atoms | Works across `if`, `unless`, `match`, `switch`, `case`, boolean operators. |
| Derived-State Staleness | local writes, reads, dependencies | Language-neutral intra-function dataflow. |

These establish useful non-Ruby output without tackling every
Ruby-specific heuristic.

### Phase 4: Port topology and local-structure detectors

Rename internal implementation toward `CodeTopology` while preserving
`RubyTopology.scan` as a Ruby compatibility alias.

Targets:

- `RubyTopology`
- `WeightedInlinedCognitiveComplexity`
- `LocalityDrag`
- `FunctionLCOM`
- `OperationalDiscontinuity`
- `TemporalOrderingPressure`
- `SequenceMine` / `ImplicitControlFlow`

These need function ownership, internal calls, path contexts, comment
boundaries, and local variable lifetimes. They are portable, but their
quality depends heavily on language profile completeness.

### Phase 5: Port language-profile-specific detectors

These should run only where the profile declares support:

| Detector | Portability decision |
|---|---|
| PredicateAlias / SemanticAlias / ReificationMisses | Generalize to small boolean-returning functions and inline predicate expressions. Per-language naming conventions should be profile data. |
| DecisionPressure | Keep Ruby nil/type guard output stable; add profile lexicons for null checks, type tests, optional chaining, rescue/exception fallbacks, and dynamic casts. |
| RedundantNilGuard | Generalize to null/nil/None checks only where the profile exposes null facts and local dominance can be approximated. |
| FalseSimplicity | Split into universal sub-signals and language-specific lexicons. Hidden IO, globals, mutation, callbacks, and dynamic dispatch are portable; monkeypatch/reopen is mostly Ruby/Python/JavaScript. |
| FatUnion | Generalize from Ruby class constants to variant/type-discriminator dispatch. Rust/Swift/TypeScript should get different profile treatment because sum types are first-class. |
| FlaySimilarity | Replace the old Flay adapter with a Tree-sitter structural fingerprint detector. Keep the published finding shape stable while enabling Type-2/Type-3 clone pressure for every language with a configured Tree-sitter grammar. |

### Phase 6: Add non-Ruby language profiles

Recommended order:

1. Python - dynamic language, strong overlap with Ruby risk surfaces.
2. JavaScript / TypeScript - dynamic plus optional static types, common
   optional chaining/null pressure.
3. Go - simple grammar, useful contrast with nil/interface pressure.
4. Rust - exercises sum types and explicit ownership-related caveats.
5. Zig - systems-language target in this repository; useful for
   switch/error-union/control-flow smoke coverage.
6. C / C++ - valuable but higher ambiguity around macros and fields.

Each new profile should ship with:

- parser smoke fixture
- fact extraction fixture
- at least one end-to-end report fixture
- capability declaration
- documented detector gaps

## CLI Changes

Current `collect_files` only collects `*.rb`. Change this only after
Tree-sitter profiles exist.

Proposed behavior:

- default: collect files whose extensions match loaded language
  profiles
- `--language=ruby,python` to constrain detection
- `--parser=rubyvm|tree-sitter` while Ruby compatibility is being
  proven
- keep `decomplex FILE_OR_DIR...` and existing subcommands unchanged
- preserve "no .rb files" wording until the default collector changes;
  then switch to "no supported source files"

Do not make downstream gems pass language flags for current Ruby use.

## Dependency Strategy

The old design principle said "zero runtime deps" because Decomplex
was a Ruby compiler-source auditor. General language support changes
that tradeoff.

Preferred boundary:

- keep report, convergence, delta, and consumers dependency-light
- isolate Tree-sitter runtime and grammar loading in `Decomplex::Syntax`
- fail loudly only when the selected parser or language profile is
  required and unavailable
- allow RubyVM fallback during migration

The final packaging can be either:

- one `decomplex` gem with Tree-sitter runtime plus optional grammar
  packages, or
- a core `decomplex` gem plus `decomplex-tree-sitter` parser package

The important design rule is that consumers such as Boobytrap and
SlopCop should not need to know which parser produced the findings.

## Consumer Migration Notes

### Boobytrap

Boobytrap only needs Decomplex section data and state branch density.
If Decomplex can return the same hashes for Ruby, Boobytrap does not
need code changes. For non-Ruby, Boobytrap's own method coverage model
may still be Ruby/SimpleCov-specific, so Decomplex generalization
should not imply Boobytrap is immediately cross-language.

### SlopCop

SlopCop depends on span-precise joins. It will be the strictest
compatibility test because a small span shift can change whether an
uncovered branch arm is marked precise or coarse. Ruby Tree-sitter
spans should be compared against SlopCop fixture coverage before
defaulting to the new parser.

SlopCop itself still uses `RubyVM::AbstractSyntaxTree`; replacing that
can come later with the same syntax facade if SlopCop becomes
cross-language.

### Espalier

Espalier has two touchpoints:

- `Aggregator` calls `Decomplex::RubyTopology.scan(files)`.
- `Reporter` parses `gems/decomplex/report.md` convergence rows.

Keep `RubyTopology` as a compatibility wrapper around a generalized
topology implementation. Later, replace report-text parsing with a
structured Decomplex JSON or section-data input so Markdown can evolve
without breaking Espalier.

### Nil-kill

Nil-kill's current Prism use is broader and rewrite-oriented. It is
not a Decomplex consumer in the same way, but the syntax facade should
avoid Decomplex-specific assumptions so nil-kill can reuse pieces later
for location-safe rewrites if that becomes a goal.

## Test Plan

Minimum gates before enabling Tree-sitter Ruby by default:

- Run every Decomplex detector test under RubyVM.
- Run migrated detector tests under Tree-sitter Ruby.
- Compare `Report#sections_data` for fixture suites.
- Compare `Report#to_markdown` for fixture suites.
- Assert every emitted span is a four-integer tuple with `first_line <= last_line`.
- Run Boobytrap `decomplex_risk_test`.
- Run SlopCop `decomplex_verdict_test`.
- Run Espalier topology-related tests.
- Run `decomplex report` on a representative Ruby directory and diff
  old/new section counts, convergence rows, and root clusters.

For non-Ruby profiles:

- test fact extraction independently from detector scoring
- test unsupported capabilities skip cleanly
- test report schema and JSON/delta schema remain valid
- test mixed-language directories preserve deterministic ordering

## Risks

- Tree-sitter columns are byte-oriented in many bindings; existing Ruby
  spans may be character offsets. This can break SlopCop joins.
- Tree-sitter is error-tolerant. Decomplex must decide whether parse
  errors suppress a file, emit partial facts, or fail. Ruby behavior
  should remain fail-loud unless explicitly changed.
- Method naming is not universal. Top-level functions, nested
  functions, lambdas, object methods, traits, impl blocks, and
  anonymous functions need stable names that still work in
  `file:method:line`.
- Field/member writes are language-specific. `obj.x =`, `self.x =`,
  `this.x =`, `x.field =`, hash key writes, destructuring, pointer
  writes, and macros should not be collapsed unless the profile says
  they represent the same state concept.
- Some Ruby detectors intentionally encode Ruby semantics. Porting
  them blindly would create misleading cross-language findings.
- Mixed-language sorting can change report order if file collection is
  not deterministic.

## First Implementation Slice

The smallest useful slice is:

1. Add `Decomplex::Syntax` with a RubyVM-backed adapter that emits
   `FunctionDef`, `DecisionSite`, `StateRead`, and `StateWrite`.
2. Rewrite `SiteExtractor`, `CoUpdate`, and `StateBranchDensity` to
   consume those facts while keeping outputs byte-for-byte compatible.
3. Add a Tree-sitter Ruby adapter for those same facts behind
   `DECOMPLEX_PARSER=tree_sitter`.
4. Add compare-mode tests for those three detectors.
5. Only after equality is proven, migrate `Report` to use the syntax
   facade for those detectors.

That slice protects the current consumers, proves the output discipline
on the highest-value detectors, and creates the extension point needed
for Python/JavaScript/TypeScript/Go/Rust/Zig profiles without forcing a
full rewrite.

## Native Rust Detector Migration

Status: in progress. The native Rust port must stay a structural mirror
of the Ruby implementation: shared syntax/AST facts first, detector
reducers second. Do not add detector-specific Tree-sitter walkers.

Migration order follows the Decomplex Metrics Expo tiers. Tier 1
detectors move first because they carry the highest signal and should
benefit earliest from native speed.

Benchmarks below use `src/` on this repository through:

```
ruby gems/decomplex/exe/decomplex detector DETECTOR --engine=ruby --json src/
ruby gems/decomplex/exe/decomplex detector DETECTOR --engine=rust --json --jobs=8 src/
```

The JSON outputs are canonical detector-only payloads and are byte-for-
byte compared before recording a detector as migrated.

| Tier | Detector / section | Native status | Ruby | Rust | Speedup | Notes |
|---|---|---:|---:|---:|---:|---|
| 1 | Missing Abstractions | migrated | 13.02s | 0.64s | 20.3x | Implemented by `miner`; consumes shared `DecisionSite` facts, matching Ruby `SiteExtractor`. |
| 1 | Semantic Predicate Aliases | migrated | 86.41s | 2.60s | 33.2x | AST-backed file/function port of `SemanticAlias`. |
| 1 | Reification Misses | migrated | 86.41s | 2.60s | 33.2x | Same AST-backed native pass as semantic aliases. |
| 1 | Exact Predicate Aliases | migrated | 85.50s | 2.58s | 33.1x | AST-backed file/function port of `PredicateAlias`. |
| 1 | Decision Pressure | migrated | 84.45s | 2.77s | 30.5x | AST-backed file/function port of `DecisionPressure`. |
| 1 | Redundant Nil Guards | pending | - | - | - | Needs local dominance/null-check normalized AST facts. |
| 1 | State Heatmap | pending | - | - | - | Needs shared `StateRead`, `StateWrite`, and semantic re-derivation facts. |
| 1 | State-Based Branch Density | pending | - | - | - | Needs branch decision facts with state refs. |
| 1 | Temporal Ordering Pressure | pending | - | - | - | Needs owner/method visibility plus state read/write facts. |
| 2 | Structural Similarity (Type-2/3) | migrated | 85.34s | 2.88s | 29.6x | File/function port of structural fingerprinting over shared `RawNode`. |
| 2 | Neglected Updates | migrated | 43.90s | 0.62s | 70.8x | Same native pass as co-update. |
| 2 | Neglected Conditions | migrated | 13.02s | 0.64s | 20.3x | Implemented by `miner`; consumes shared `DecisionSite` facts, matching Ruby `SiteExtractor`. |
| 2 | Derived-State Staleness | pending | - | - | - | Needs local write/read/dependency facts or Rust normalized AST. |
| 2 | Inconsistent Rename Clones | pending | - | - | - | Can likely share structural clone tokenization with Rust AST facade. |
| 2 | Implicit Control Flow | pending | - | - | - | Needs topology/path protocol and state effect facts. |
| 2 | Weighted Inlined Cognitive Complexity | pending | - | - | - | Needs topology plus local cognitive scorer. |
| 2 | Locality Drag | pending | - | - | - | Needs local flow summaries and boundaries. |
| 2/3 | Operational Discontinuity | pending | - | - | - | Needs local flow summaries and boundaries. |
| 3 | Neglected Path Conditions | pending | - | - | - | Needs path-condition facts over normalized branch syntax. |
| 3 | Oversized Predicates | pending | - | - | - | Needs normalized boolean atom counting. |
| 3 | Broken Protocols | pending | - | - | - | Needs call-sequence mining facts. |
| 3 | Function LCOM | pending | - | - | - | Needs local flow summaries. |
| 3 | False Simplicity | pending | - | - | - | Needs language lexicons plus call/mutation/reopen facts. |
| 3 | Fat Unions | pending | - | - | - | Needs class/variant dispatch and member-use facts. |

Earlier single-thread / pre-architecture-correction timings recorded before the
AST-backed alias and decision-pressure ports:

- co-update: Ruby 43.205838s, Rust 2.144622s, 20.1x.
- predicate-alias: Ruby 81.583126s, Rust 2.136387s, 38.2x.
- structural-similarity: Ruby 85.163481s, Rust 4.331976s, 19.7x.
