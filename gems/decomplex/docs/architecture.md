# Decomplex Architecture

Decomplex is a source-fact compiler plus detector/report pipeline. The architecture must scale across languages by keeping concrete language code narrow: language files describe syntax quirks and normalization hooks; shared passes collect and derive facts.

This document describes the intended pass order, the responsibility of each pass, and where language-specific code is allowed.

## Pipeline Summary

### 0. Source Selection

Input files are mapped to a language by extension or explicit language option.

Responsibility:

- decide which grammar/profile applies
- preserve deterministic file order
- reject unsupported source

Not responsible:

- fact extraction
- detector decisions
- report shaping

Ruby implementation:

- `Decomplex::Syntax.language_for`
- `Decomplex::Syntax.supported_source?`

Rust implementation:

- `Language::for_extension`
- CLI language options and parse targets

### 1. Concrete Parse

Source text is parsed with Tree-sitter into a concrete syntax tree.

Responsibility:

- produce a concrete parser tree
- retain source spans, text, and line data

Not responsible:

- semantic interpretation
- state reads/writes
- detector facts

Ruby implementation:

- `TreeSitterAdapter#parse_raw`
- `TreeSitterFacadeContext`
- `TreeSitterNodeFacade`

Rust implementation:

- `syntax/tree_sitter_adapter.rs`
- `RawNode::from_tree_sitter`

Language-specific fit:

- grammar package names
- parser setup
- concrete node names only as parser facts

### 2. Normalization

Concrete syntax is normalized into the shared syntax schema. This is where concrete grammar quirks are allowed to be handled.

Responsibility:

- convert concrete branches into normalized branch nodes
- convert concrete calls into normalized call nodes
- convert concrete assignments into normalized write/read shapes
- normalize owner/function/scope shapes
- preserve source spans and text

Not responsible:

- detector findings
- protocol/effect mining
- report-level ranking

Rust implementation:

- `ast.rs`
- `ast/adapters/<language>.rs`

Current Ruby implementation:

- Ruby source facts now use native Rust `syntax-facts` and hydrate `FactDocument`.
- Legacy Ruby raw parsing still exists for tests and compatibility.

Language-specific fit:

- Ruby `body_statement` wrappers
- Ruby modifier `if`/`unless`
- Python block/suite shapes
- JavaScript/TypeScript optional chaining and member expressions
- PHP `$this->field`/`::`/nullsafe member access
- Lua colon calls
- Perl sigils and statement modifiers, if added

The normalizer may know grammar quirks. It must not know detector names or report semantics.

### 3. Stateless Structural Fact Extraction

This pass walks normalized syntax and emits facts that can be computed from one node and local lexical context.

Responsibility:

- owners/classes/modules
- functions/methods
- call sites
- state declarations
- state reads
- state writes
- comparison uses
- branch decisions
- branch arms
- decision sites
- predicate bodies
- path-condition sites when branch/action structure is already normalized
- local-flow statements when statement/read/write facts are local

Not responsible:

- cross-file aggregation
- detector findings
- report ranking
- language-specific API policy beyond profile lexicons

Rust implementation:

- `syntax/normalized_extractor.rs` for Ruby normalized facts
- future split should move role-specific logic to normalized shared modules such as:
  - `normalized_predicates.rs`
  - `normalized_local_flow.rs`
  - `normalized_path_conditions.rs`

Ruby implementation:

- `syntax/dynamic_language.rb` now owns shared dynamic-language predicate, local-flow, and path-condition extraction for the legacy Ruby raw path.
- `syntax/passes.rb` owns explicit raw-parser stateless pass orchestration.
- `syntax/ruby.rb` provides Ruby hook methods for concrete grammar quirks.

Language-specific fit:

- node-kind constants
- small hooks that answer "is this concrete node an assignment/function/branch/call?"
- concrete text normalization such as PHP variable names or Ruby visibility argument strings

Language-specific code should not own the traversal algorithm. It should answer grammar questions used by shared traversal.

### 4. Stateful Syntax Enrichment

Some facts require multiple already-collected facts or document-level state. These should run after stateless facts exist.

Yes, this should be a distinct pass class conceptually.

Responsibility:

- apply visibility events to function facts
- derive semantic effects from call facts and lexicons
- derive protocol method effects from call/read/write facts
- derive dispatch sites from branch arms and calls
- filter branch decisions using immutable value metadata
- compute local complexity from function bodies
- aggregate metadata needed by later detectors

Why separate it:

- these operations depend on several fact sections
- they are order-sensitive
- they should not be hidden in language adapters
- it makes Ruby-like dynamic features explicit without giving adapters a private compiler

Rust implementation:

- `apply_visibility` in normalized extraction should become a named stateful enrichment pass.
- `semantic_effect_sites_from_calls`
- `protocols.rs`
- `path_condition.rs` when consuming stored/normalized sites
- `complexity.rs`
- immutable reader/type metadata aggregation in `tree_sitter_adapter.rs` and consumers

Ruby implementation:

- `FactDocument` hydrates stored facts.
- `syntax/passes.rb` owns raw-parser stateful enrichment, including visibility event application.
- `StateBranchDensity` and syntax oracle aggregate immutable metadata.
- `syntax/ruby.rb` supplies Ruby visibility events; it must not apply visibility to function facts directly.

Language-specific fit:

- lexicon data such as "this API implies hidden IO"
- visibility event syntax such as Ruby `private :name`, PHP `private function`, TypeScript `private`
- immutable/type metadata syntax such as Sorbet `T::Struct`, Python dataclasses, TypeScript readonly/types

Language-specific code may produce events or metadata. Shared enrichment applies them.

### 5. Fact Document Hydration

Stored facts are converted into the Ruby or Rust document representation.

Responsibility:

- deserialize syntax facts
- provide stable fact readers
- preserve exact fact shape for detector parity

Not responsible:

- raw parsing
- recomputing facts from source
- detector-specific fallback extraction

Ruby implementation:

- `syntax/fact_document.rb`

Rust implementation:

- `Document` deserialization in `syntax.rs`
- `detector-facts` CLI input

### 6. Detectors

Detectors consume facts only.

Responsibility:

- rank, group, and report smells/findings
- consume `Document` fact sections and detector options
- stay language-agnostic unless the detector explicitly consumes language-neutral lexicon categories

Not responsible:

- Tree-sitter traversal
- normalized AST traversal
- concrete language branches
- syntax adapter calls

Examples:

- state mesh
- path condition
- false simplicity
- flay similarity
- local flow
- redundant nil guard

Architecture invariant:

- Detectors must not import Tree-sitter, inspect raw syntax nodes, read adapter internals, or branch on concrete languages.

### 7. Report, Root Cause, SARIF

Report passes consume detector outputs and facts.

Responsibility:

- post-process detector findings
- render Markdown, JSON, SARIF
- combine detector facts for user-facing explanations

Not responsible:

- syntax extraction
- language-specific source analysis

## What `syntax/<language>.rb` Does

`lib/decomplex/syntax/<language>.rb` is the Ruby runtime language profile for the legacy Ruby implementation.

Allowed responsibilities:

- declare language lexicons:
  - nil literals
  - type guards
  - diagnostic APIs
  - trivial expressions
- declare concrete Tree-sitter node-kind categories:
  - function nodes
  - owner/class/module nodes
  - call nodes
  - branch/case/loop nodes
  - assignment nodes
  - parameter nodes
  - field/member nodes
- provide small grammar hooks:
  - function name extraction when fields are irregular
  - parameter name extraction when grammar wraps identifiers
  - call target extraction when receiver/message are irregular
  - state target extraction when field syntax is irregular
  - concrete source normalization, such as PHP `$name`
  - event extraction, such as visibility declarations

Forbidden responsibilities:

- owning local-flow traversal
- owning path-condition traversal
- owning semantic-effect extraction
- owning protocol extraction
- owning clone fingerprinting
- owning detector-specific fallback parsing
- hiding more code in language-specific helper files

The file may answer grammar questions. It should not implement a private compiler.

## What Rust `ast/adapters/<language>.rs` Does

`rust/src/decomplex/ast/adapters/<language>.rs` is the Rust normalization adapter.

Allowed responsibilities:

- identify concrete grammar quirks
- normalize wrapper nodes away
- map concrete constructs to shared normalized nodes
- preserve source spans and text
- normalize language-specific spelling into shared shape

Forbidden responsibilities:

- detector facts
- semantic effects
- protocols
- local-flow/report findings
- cross-document aggregation

This is where Ruby statement modifiers, Python suites, JS optional chaining, PHP member access, Lua colon calls, and future Perl statement/sigil quirks belong.

## What Rust `syntax/adapters/<language>.rs` Does

`rust/src/decomplex/syntax/adapters/<language>.rs` should be a narrow syntax profile.

Target responsibilities:

- choose language enum and grammar
- declare concrete node-kind facts when raw compatibility still needs them
- provide small grammar hooks that cannot be expressed as data

Target non-responsibilities:

- detector fact engines
- semantic-effect engines
- protocol engines
- local-flow/path-condition traversals

Current state:

- Ruby is effectively parser-only in `syntax/adapters/ruby.rs`.
- Non-Ruby languages still use `LanguageProfile` plus raw Tree-sitter extraction in `tree_sitter_adapter.rs`.
- That raw path is compatibility debt. The target is to normalize every language first and run the same normalized extractors.

## Stateless Versus Stateful Extraction

The ideal pass split is:

1. Stateless extraction:
   - one file
   - one normalized tree
   - lexical stack only
   - emits raw structural facts
2. Stateful enrichment:
   - consumes several fact sections
   - may need document/project metadata
   - applies ordering-sensitive events
   - emits derived fact sections
3. Detectors:
   - consume fact sections only
   - do not inspect syntax trees

This split is useful because many dynamic-language facts depend on several normalized features:

- visibility needs functions plus visibility calls/events
- protocol effects need calls plus reads/writes
- semantic effects need calls plus lexicon categories
- immutable-state filtering needs branch decisions plus type/reader metadata
- local-flow boundaries need statement lines plus source lines
- dispatch sites need branch arms plus calls inside arms

These are not adapter responsibilities. The adapter can collect language-specific events or metadata. Shared stateful passes apply them.

## Current Ruby-Specific Issues

These are the remaining areas that still look structurally wrong or only partially corrected.

### `syntax/ruby.rb` Still Contains Raw Compatibility Hooks

The file is now smaller, but it still includes a large amount of concrete raw-tree logic:

- call target extraction
- state target extraction
- visibility event extraction
- Sorbet metadata extraction
- hidden `body_statement` owner/function wrappers

Some of this is valid grammar-hook code. Some should move to shared dynamic call/state/type-metadata passes.

### Visibility Application Has Been Moved Out Of Ruby Adapter Code

Ruby visibility application is now shared stateful enrichment over `VisibilityEvent` facts.

The correct split is:

- Ruby supplies visibility events.
- PHP/TypeScript can supply visibility declarations.
- shared pass applies events to function facts.

### Sorbet Metadata Is Ruby-Specific Syntax, But The Metadata Model Is General

Ruby-specific:

- `sig`
- `T.let`
- `T::Struct`
- `T.type_alias`

General:

- immutable value readers
- reader types
- type aliases
- method parameter types

The event/model should be shared. Ruby should only parse Sorbet spelling into those model facts.

### Call Target Extraction Is Still Too Adapter-Heavy

Ruby call target logic still handles:

- implicit self calls
- receiver/message extraction
- callable shorthand
- safe navigation
- unparenthesized member arguments

Other languages need variants:

- Python attribute calls
- JavaScript/TypeScript optional chaining
- PHP member/nullsafe calls
- Lua colon calls
- Perl method calls and sigils

This should become a shared dynamic call target pass with language hooks for concrete receiver/message shape.

### State Ref Extraction Is Still Too Adapter-Heavy

Ruby state target logic handles:

- `@ivar`
- `$global`
- `self`
- implicit state access
- embedded string exclusions

Other languages need:

- Python `self.x`
- JavaScript/TypeScript `this.x`
- PHP `$this->x`
- Lua table fields
- Perl hash/object/sigil access

The shared model is receiver/field/read/write. The language file should only normalize spelling.

### Python/PHP Legacy Overrides Show The Same Pattern

Python currently owns local-method extraction in its language file.

PHP currently owns redundant nil guard traversal and normalizes path-condition/predicate outputs in its language file.

Those are warning signs. The same extraction performed for Ruby should be generalized to those adapters next.

## Target Architecture Rule

If a language file grows because it names concrete node kinds or handles an unavoidable grammar quirk, that is acceptable.

If a language file grows because it walks subtrees to calculate facts, maintains cross-fact state, or emits detector-ready findings, that is an architecture violation.

The review question for every new language hook should be:

Can this be expressed as normalized syntax plus a shared stateless or stateful pass?

If yes, do that. If no, the language hook should return the smallest grammar fact or event possible.
