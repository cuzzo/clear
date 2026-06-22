# FactMine Agent Architecture

FactMine is a source-fact compiler. Its job is to turn concrete language source
into stable, language-neutral fact sections for Decomplex. Detectors consume
facts only. They do not parse source, inspect raw syntax, inspect normalized
syntax, or call adapters.

This is the agent-facing architecture contract. The user-facing architecture is
also documented in `gems/fact-mine/docs/architecture.md`; this file is the
source to use when auditing or moving code.

## Non-Negotiable Rules

- Concrete language behavior lives in concrete language files only.
- Generic files may dispatch to language behavior, but may not contain
  concrete-language branches, lexicons, node-kind lists, or source spellings.
- Adapters normalize concrete grammar into shared normalized IR. They do not
  extract detector facts.
- Generic extractors consume normalized IR and language-owned behavior hooks.
  They do not inspect raw Tree-sitter nodes.
- Stateful passes consume normalized facts and normalized IR. They do not fall
  back to raw parser traversal.
- Public document readers return stored facts. They do not recompute missing
  fact sections from source or raw syntax.
- Ruby and Rust implementations must mirror the same pass architecture even if
  individual file organization differs.
- Refactors that repair architecture should move code to the correct layer
  first, even if tests fail temporarily. Green compatibility comes after the
  architecture boundary is correct.

## Pass Pipeline

1. Source selection
2. Concrete parse
3. Normalized AST construction
4. Stateless normalized extraction
5. Stateful normalized enrichment
6. Public fact projection
7. Decomplex detector consumption

## Ruby Reference Architecture

Ruby is the current reference implementation for the target architecture. Rust
must mirror these phase boundaries even when the filenames differ.

| Pass | Ruby files | Input | Output | May do | Must not do |
| --- | --- | --- | --- | --- | --- |
| Source selection | `syntax.rb`, `syntax/<language>.rb` registry entries | file path or explicit language | language id and parser choice | map extensions to languages | mine facts or guess unsupported languages |
| Concrete parse | `ast.rb`, Tree-sitter parser setup | source text and language id | raw parser tree plus source lines | parse and preserve spans/text | normalize facts or detector behavior |
| Normalized AST construction | `ast/normalizer.rb`, `ast/adapters/<language>.rb` | raw parser tree | normalized IR root | translate concrete grammar to shared node concepts | emit detector-ready facts |
| Stateless normalized extraction | `syntax/normalized_extractor.rb`, `syntax/normalized_extraction_behavior.rb` | normalized IR root | structural facts and pass seeds | traverse normalized IR once and call narrow behavior hooks | inspect raw parser nodes, own lexicons, or branch on concrete languages |
| Stateful normalized enrichment | `syntax/passes.rb`, `syntax/effects.rb`, `syntax/protocols.rb`, `syntax/clone_similarity.rb`, `syntax/nil_guards.rb`, `syntax/normalized_local_facts.rb` | normalized IR plus structural facts | derived fact sections | derive cross-node/cross-fact facts from normalized data | fall back to raw traversal or re-parse source |
| Public projection | `syntax/fact_document.rb`, `syntax/normalized_extractor.rb` row projection | completed fact rows | stable public readers/JSON | hydrate and serialize stored facts | recompute missing sections |
| Decomplex detectors | `gems/decomplex/lib/decomplex/**` | FactMine public facts | detector reports | score and report from facts | parse source or inspect raw/normalized syntax |

The Ruby normalized path is:

1. `FactMine::Ast.parse` produces a normalized root with the selected
   `Ast::TreeSitterNormalizationAdapters` language adapter.
2. `Syntax::NormalizedExtractor` scans only the normalized root and builds the
   base row: owners, functions, calls, state declarations, reads/writes,
   decisions, branch decisions, branch arms, dispatch seeds, predicate aliases,
   comparisons, path-condition seed sites, and intrinsic semantic effects.
3. `Syntax::NormalizedStatefulSyntaxPass.enrich` mutates that row by applying
   visibility, call-lexicon semantic effects, dispatch derivations, protocol
   facts, normalized local facts, clone candidates, redundant nil guards, and
   metadata facts.
4. `Syntax::FactDocument` exposes stored sections. Its readers are hydration
   views, not permission to re-mine facts.

Any Rust implementation that extracts facts from a raw tree after parse is not
mirroring Ruby's architecture. Any Ruby implementation that keeps a raw fallback
for a normalized fact section is architectural debt, not precedent.

### 1. Source Selection

Responsibility:

- map file extension or explicit option to a supported language
- choose the grammar/parser package
- preserve deterministic file order

Allowed language-specific code:

- central registry entries that map language names/extensions to language files

Forbidden:

- fact extraction
- source scanning for detector behavior
- fallback to Ruby or any default language when unsupported

### 2. Concrete Parse

Responsibility:

- read source
- construct the parser tree for the selected language
- report parser errors if needed

Allowed language-specific code:

- parser package and grammar selection in narrow parser registries

Forbidden:

- detector fact extraction
- raw traversal engines
- concrete-language semantic lexicons

### 3. Normalized AST Construction

Responsibility:

- convert concrete grammar shapes into shared normalized IR
- preserve source spans and source text needed for public facts
- expose language quirks as normalized nodes or narrow descriptors
- normalize all linguistic constructs needed by later passes before facts are
  mined

Allowed language-specific code:

- Ruby `syntax/<language>.rb`
- Ruby `ast/adapters/<language>.rb`
- Rust `ast/adapters/<language>.rs`
- Rust `syntax/normalized_<language>.rs`
- language-owned metadata parsers and lexicons

Forbidden:

- producing detector-ready facts
- walking subtrees to compute path-condition/local-flow/clone/protocol/nil
  findings
- placing language quirks in generic normalizers under generalized names
- emitting stored fact rows such as `functions`, `calls`, `state_reads`,
  `protocol_call_paths`, `clone_candidates`, or `redundant_nil_guards`

Required normalized concepts:

- owners: class/module/struct/interface/trait-like declarations
- functions: methods, functions, static/receiver functions, constructors
- parameters: positional, keyword/named, receiver/self/this aliases
- calls: bare calls, receiver calls, safe/null-safe calls, index calls,
  attribute writes, operator calls, block/closure calls
- assignments: local writes, state writes, multiple assignment, operator
  assignment, loop target writes, context/resource target writes
- state access: receiver/field reads and writes, global reads/writes
- control: `if`/`elsif`/`else`, modifier branches, ternaries, boolean
  conjunction/disjunction, `case`/`switch`/`match`, loops, rescue/catch
- literals: nil/null/none, booleans, strings, arrays/lists, hashes/maps
- metadata events: visibility declarations, immutable/read-only fields, type
  aliases, method parameter types, owner field declarations

### 4. Stateless Normalized Extraction

Responsibility:

- traverse normalized IR
- emit facts that require no cross-node or cross-function state beyond the
  traversal stack
- collect structural facts and pass seeds

Facts populated:

- owners
- functions
- calls
- state declarations
- state reads
- state writes
- decisions
- branch decisions
- branch arms
- dispatch seeds
- predicate aliases
- comparison uses
- path-condition seed sites when directly represented by normalized IR
- intrinsic semantic effects that are visible in normalized IR

Allowed language-specific input:

- calls to the normalized language behavior interface only

Forbidden:

- concrete language names
- concrete node-kind names from Tree-sitter
- raw parser node access
- source regexes that model one language
- detector-specific fallback engines
- visibility timeline application
- clone fingerprinting
- local-flow or path-condition traversal
- protocol path/effect derivation
- nil-guard finding derivation

### 5. Stateful Normalized Enrichment

Responsibility:

- consume normalized facts and normalized IR
- produce derived fact sections that need global or path state
- apply language-owned descriptors through behavior hooks

Facts populated:

- visibility
- semantic effects from calls
- protocol method effects
- protocol call paths
- clone candidates and fingerprints
- local flow summaries
- local complexity scores
- path conditions
- redundant nil guards
- metadata facts such as immutable readers, type aliases, and method parameter
  types

Allowed language-specific input:

- normalized language behavior hooks and language-owned lexicons only

Forbidden:

- raw parser traversal
- `Language::Ruby`/`:ruby` style branches in generic engines
- concrete-language lexicons in generic files
- fallback recomputation from public `Document` readers
- deriving language facts by reading concrete source spellings directly

Stateful enrichment order in the Ruby reference implementation:

1. Apply visibility events from language-owned call descriptors to already
   extracted function rows.
2. Append semantic effects from generic call facts using language-owned effect
   lexicons.
3. Dedupe and sort semantic effects.
4. Append dispatch facts from normalized branch/call facts.
5. Append protocol method effects and protocol call paths from normalized
   state/call/branch facts plus language-owned labels.
6. Append normalized local facts: local methods, path conditions, local
   complexity, and local contract assignments.
7. Append normalized extension facts: clone candidates and redundant nil guards.
8. Append metadata facts such as immutable readers, type aliases, and method
   parameter types.

### 6. Public Fact Projection

Responsibility:

- serialize facts in stable public JSON
- hydrate stored facts
- preserve byte-for-byte fact compatibility unless public behavior intentionally
  changes

Forbidden:

- raw source parsing
- filling missing fact sections by re-mining syntax

### 7. Decomplex Detector Consumption

Responsibility:

- consume FactMine public facts
- compute detector metrics and reports
- combine fact sections where needed

Forbidden:

- parsing source
- scanning raw source text for language syntax
- inspecting raw parser nodes
- inspecting normalized IR
- calling syntax adapters or language behavior hooks

## Normalized IR Contract

Normalized IR is private compiler implementation detail. Public integration
tests assert output facts, not normalized node names, except for explicit IR
fixtures.

The current implementation uses a RubyVM-compatible vocabulary because it is
already implemented, but this is a transitional normalized IR, not permission
to put Ruby-specific behavior in generic code. Any Ruby-only logic required to
produce or interpret that IR belongs in Ruby language files or explicit
Ruby-compat modules.

Core normalized concepts:

- owners: class/module/struct-like owner declarations
- functions: instance/static/receiver functions and methods
- calls: bare, receiver, safe-navigation, index, operator, block calls
- assignments: local writes, state writes, multiple assignment, operator
  assignment, attribute/index writes
- state access: receiver/field reads and writes
- control: branches, boolean operations, case/switch/match, loops, rescue/catch
- literals: nil/null, booleans, strings, arrays/lists, hashes/maps
- metadata: visibility, immutable readers, type aliases, param types

## Language File Responsibilities

Language files own:

- parser setup
- file extensions when local to the language registry
- concrete grammar-to-normalized rules
- language source canonicalization
- nil/null predicate spellings
- terminating call names
- mutating call names
- semantic-effect lexicons
- protocol vocabulary quirks
- metadata syntax such as Ruby Sorbet `sig`/`T::Struct`, TypeScript readonly
  fields, Python dataclass/attrs metadata, PHP readonly properties
- fixture-driven compatibility quirks that are genuinely language-specific
- narrow normalized behavior hooks consumed by generic passes

Language files may return:

- normalized node shapes from concrete grammar
- source canonicalization for public fact text
- event descriptors such as visibility declarations
- lexicon membership answers such as nil predicate, terminating call, mutating
  receiver call, semantic-effect category, or protocol labels
- metadata rows when the metadata is concrete-language syntax and the generic
  pass only stores/projects it

Language files do not own:

- traversal engines
- detector fact engines
- local-flow algorithm
- path-condition algorithm
- redundant nil-guard algorithm
- clone fingerprinting algorithm
- protocol effect/path algorithm
- visibility application
- public fact fallback recomputation
- public detector row construction for structural facts
- cross-function or cross-owner aggregation
- alternate fact extraction pipelines

Language files cannot:

- require helper files that implement private traversal engines for one
  language
- create generic-sounding helper modules that only implement one concrete
  language's syntax
- branch on another concrete language
- write directly to unrelated public fact sections as a side effect of
  normalization
- compensate for missing normalized IR by parsing raw source during extraction
- define local-flow, path-condition, clone, nil-guard, semantic-effect, or
  protocol engines
- bypass `NormalizedExtractionBehavior`/normalized language behavior when a
  generic pass needs language-owned descriptors

## Generic File Responsibilities

Generic files own:

- normalized tree traversal
- shared fact construction
- shared stateful algorithms over normalized IR and stored facts
- stable public fact projection
- small registries that dispatch to language-owned modules
- pass orchestration and deterministic ordering

Generic files do not own:

- concrete language names except in registries
- concrete language source spellings
- raw Tree-sitter traversal in fact engines
- language lexicons
- adapter-specific workarounds
- RubyVM compatibility rewrites in generic production code
- concrete syntax comments, operators, builtin names, DSL names, or standard
  library names

## Rust File Placement

Correct Rust locations:

- `syntax/tree_sitter_adapter.rs`: parse orchestration only
- `syntax/parser_grammar.rs`: grammar registry only
- `ast/adapters/<language>.rs`: concrete grammar to normalized AST quirks
- `syntax/normalized_<language>.rs`: normalized language behavior, lexicons,
  canonicalization, metadata quirks
- `syntax/normalized_extractor.rs`: stateless normalized fact extraction only
- `syntax/passes.rs`: stateful pass orchestration only
- `syntax/{local_flow,path_condition,redundant_nil_guard,clone_similarity,protocols,effects}.rs`:
  shared engines over normalized IR/facts
- `syntax.rs`: public data model, registry, parse facade, fact hydration

Incorrect Rust locations:

- language branches in `normalized_extractor.rs`
- language lexicons in `effects.rs`
- raw fallback fact engines in `local_flow.rs`, `path_condition.rs`,
  `redundant_nil_guard.rs`, `protocols.rs`, or `clone_similarity.rs`
- any production `syntax/adapters` profile layer
- production normalization logic in monolithic `ast.rs` when it belongs in
  concrete `ast/adapters/<language>.rs`

## Movement Workflow

When architecture is wrong:

1. Document every violation and its correct destination.
2. Move code to the correct architectural file, even crudely.
3. Delete code that has no correct architectural destination.
4. Add compile shims only where needed to keep modules visible.
5. Add invariants that make the misplaced pattern illegal.
6. Compile and repair obvious breakage.
7. Only then restore byte-for-byte public output.

Do not green-gate the movement by keeping bad fallback code alive in generic
files. If code belongs in a language module, move it there first.
