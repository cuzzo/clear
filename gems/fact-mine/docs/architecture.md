# FactMine Architecture

FactMine is the source-fact compiler used by Decomplex. Its job is to turn
language source into stable, language-neutral fact sections. Detectors consume
those facts; they do not parse source and they do not inspect syntax trees.

FactMine has Ruby and Rust implementations. They must expose the same public
facts for the same source, but neither implementation may achieve parity by
burying concrete-language behavior in generic extractors. Concrete grammar
knowledge belongs in language files and AST adapters; generic passes operate
on normalized AST and language-owned descriptors.

The architecture is normalization-first:

1. Parse concrete source with the language grammar.
2. Normalize concrete syntax into the shared normalized AST vocabulary.
3. Extract stateless facts from normalized AST only.
4. Run stateful enrichment over already-collected facts.
5. Hydrate public `FactDocument` readers and detector fixture JSON.

Language-specific code is allowed only in language-specific files such as
`lib/fact_mine/syntax/ruby.rb`, `lib/fact_mine/syntax/python.rb`, and the
corresponding Rust language modules. Generic files must not hide Ruby,
Python, JavaScript, or any other concrete language behavior behind generalized
names.

## Architectural Boundaries

### Language Files

Language files may own:

- Tree-sitter grammar/package names and file extensions.
- Concrete node-kind declarations for the raw compatibility path.
- Concrete-to-normalized AST adapter rules in `lib/fact_mine/ast/adapters/<language>.rb`.
- Normalized extraction behavior hooks for grammar quirks.
- Language lexicons for nil/type guards, diagnostics, semantic effects, and
  protocol vocabulary.
- Language metadata parsers, such as Ruby Sorbet `T::Struct`, `sig`, and
  `T.type_alias`.
- Concrete syntax normalization quirks, such as Ruby modifier `if`, PHP
  `$this->field`, JavaScript optional chaining, Python suites, Lua colon
  calls, and future Perl sigils.

Language files must not own:

- Detector logic.
- Local-flow traversal.
- Path-condition traversal.
- Clone fingerprinting.
- Redundant nil-guard traversal.
- Semantic-effect or protocol engines.
- Visibility application to functions.
- Cross-fact or cross-document aggregation.

If a language hook walks a subtree to compute detector-ready facts, it is in
the wrong place. The hook should instead normalize syntax or return a small
event/descriptor that a shared pass consumes.

### Generic FactMine Files

Generic files may own:

- Normalized AST traversal.
- Fact section construction.
- Public fact projection and hydration.
- Shared algorithms over normalized nodes/facts.
- Registries that dispatch to language-owned lexicons.

Generic files must not own:

- Concrete language vocabulary.
- Concrete language branches.
- Raw Tree-sitter traversal in normalized fact engines.
- Source-text regexes that model one language while pretending to be general.

## Normalized AST Vocabulary

The normalized AST is private compiler IR. Its names may change if public facts
remain stable. Public source-fact tests should assert facts, not internal node
names, except for explicit normalized-IR fixtures.

The current Ruby implementation normalizes concrete languages into a shared
RubyVM-compatible vocabulary because it already captures the concepts the
generic extractors need. The vocabulary is semantic, not Ruby-specific, and
other languages must target the same concepts rather than reimplementing fact
engines.

Core normalized node families:

- Owners: `CLASS`, `MODULE`.
- Functions: `DEFN`, `DEFS`.
- Scope/body: `SCOPE`, `BLOCK`.
- Parameters: `ARGS`.
- Calls: `VCALL`, `FCALL`, `CALL`, `QCALL`, `ATTRASGN`, `OPCALL`.
- Assignments: `LASGN`, `DASGN`, `IASGN`, `GASGN`, `MASGN`,
  `OP_ASGN1`, `OP_ASGN2`.
- Identifiers/state: `LVAR`, `DVAR`, `IVAR`, `GVAR`, `CONST`, `SELF`.
- Control: `IF`, `UNLESS`, `CASE`, `CASE2`, `WHEN`, `AND`, `OR`,
  `ITER`, `FOR`, `WHILE`, `UNTIL`.
- Literals/data: `TRUE`, `FALSE`, `NIL`, `STR`, `DSTR`, `HASH`,
  `LIST`, `ZLIST`.

The normalized tree must preserve:

- `type`
- `children`
- `first_lineno`
- `first_column`
- `last_lineno`
- `last_column`
- `text`

Future normalized metadata may be added when source text recovery is forcing
generic extractors to infer concrete grammar behavior. Metadata should describe
language-neutral semantics, not concrete language names.

## Linguistic Features That Must Normalize

These features need normalized representation before generic facts are mined.

### Owners And Functions

Normalize:

- Classes/modules/struct-like owners to owner nodes.
- Instance methods/functions to `DEFN`.
- Singleton/static/receiver methods to `DEFS` or equivalent owner-qualified
  function facts.
- Parameter lists to `ARGS`.
- Hidden wrappers around concrete function bodies to `SCOPE`/`BLOCK`.

Facts populated later:

- `owners`
- `functions`
- `method_param_types`

Language-specific examples:

- Ruby `class`, `module`, `def`, `def self.x`.
- Python `class`, `def`, decorators where needed.
- JavaScript/TypeScript class methods, private methods, function declarations.
- PHP classes/functions and visibility modifiers.
- Rust/Go/Zig/C/C++ owner conventions and receiver methods.

### Calls And Receivers

Normalize:

- Bare calls to `VCALL`/`FCALL` with receiver `self` where applicable.
- Receiver calls to `CALL`.
- Safe navigation/null-safe calls to `QCALL`.
- Index calls to `CALL` message `[]`.
- Attribute/index writes to `ATTRASGN`.
- Operator calls to `OPCALL`.
- Block calls/closures to `ITER`.
- Argument lists to `LIST`/`ZLIST`.

Facts populated later:

- `calls`
- `state_reads`
- `semantic_effects`
- `protocol_call_paths`
- `dispatch_sites`

Language-specific examples:

- Ruby implicit self calls, `&.`, block calls, `obj[]`.
- Python `self.x()`, decorators, comprehensions as calls where needed.
- JavaScript/TypeScript `this.x()`, `obj?.x()`, private `#x`.
- PHP `$this->x()`, `Class::x()`, `?->`.
- Lua `obj:method()`.
- Rust/Zig/Go receiver and function-call conventions.

Source text canonicalization for public facts also belongs to language-owned
behavior. For example, PHP source spellings such as `$value->name` normalize to
`value.name` before generic local-contract and path-condition facts are
projected. The generic pass may call `normalize_source_text`; it must not know
PHP sigils, Ruby ivars, or any other concrete spelling.

### Assignments And Mutation

Normalize:

- Local writes to `LASGN`/`DASGN`.
- State writes to `IASGN`/`GASGN` or normalized receiver/field writes.
- Multiple assignment to `MASGN`.
- Attribute/index assignment to `ATTRASGN`.
- Operator assignment to `OP_ASGN1`/`OP_ASGN2`.
- Mutation calls as calls plus language-owned mutating lexicon entries.

Facts populated later:

- `state_declarations`
- `state_param_origins`
- `state_writes`
- `local_methods`
- `local_contract_assignments`
- `semantic_effects`

Language-specific examples:

- Ruby `@x =`, `$x =`, `x +=`, `items << value`.
- Python `self.x =`, annotated assignments.
- JavaScript/TypeScript `this.x =`, private fields.
- PHP `$this->x =`.
- Rust/Go/Zig/C/C++ field assignment and receiver writes.

### Branches, Boolean Logic, And Cases

Normalize:

- `if`/`elsif`/`else` chains to `IF` with normalized branch children.
- Modifier branches to `IF`/`UNLESS`.
- Ternary expressions to `IF` but mark only nested calls as conditional when
  the branch is expression-only.
- Boolean conjunction/disjunction to `AND`/`OR`.
- `case`/`switch`/`match` to `CASE`/`CASE2` and `WHEN`.
- Loops to `ITER`, `FOR`, `WHILE`, or `UNTIL`.
- Resource/context blocks to normalized compound statements such as `WITH`
  when the concrete grammar otherwise exposes the clause and body as sibling
  nodes.
- Loop targets and loop iterables as explicit normalized children when local
  flow must distinguish writes from reads.

Facts populated later:

- `decisions`
- `branch_decisions`
- `branch_arms`
- `dispatch_sites`
- `path_conditions`
- `local_complexity_scores`

Language-specific examples:

- Ruby `unless`, modifier `if/unless`, `case`.
- Python `elif`, `match`, comprehensions if represented as control.
- JavaScript/TypeScript `switch`, ternary, optional chaining in predicates.
- PHP `elseif`, `match`, `switch`.
- Rust/Zig/Go/C/C++ `match`/`switch`/`if`/loop forms.

### Nil/Null And Guard Semantics

Normalize:

- Nil/null literals to `NIL` or language-neutral nil literal facts.
- Safe navigation to `QCALL`.
- Explicit nil-predicate calls through language behavior hooks.
- Early terminating calls through language behavior hooks.
- Rescue/catch fallback expressions to normalized `RESCUE`/handler nodes so
  eliminable guards can be emitted from normalized IR.

Facts populated later:

- `redundant_nil_guards`
- `branch_decisions`
- `semantic_effects` with `kind: eliminable_guard`
- `decision_pressure` detector inputs

Language-specific examples:

- Ruby `nil?`, `&.`, `raise`, `fail`.
- Python `is None`, truthy guards.
- JavaScript/TypeScript `null`, `undefined`, `?.`.
- PHP `null`, `?->`.
- Rust `None`, `is_none`, `is_some`.
- C-family, Go, Java, Kotlin, Lua, Swift, and Zig fixture guards such as
  `isNull`/`isSome` through language-owned nil-predicate behavior hooks.

### Dynamic Local Flow

Normalize:

- Function body statements into ordered normalized statement nodes.
- Local parameters and local writes.
- Compound statements such as normalized `FOR` and `WITH` as one statement
  when their body is part of the same local-flow operation.
- Loop targets as local writes and loop iterables as local reads.
- Context-manager/resource targets as local writes.
- Import/module path names as import metadata, not local reads.
- Block-local variables as scoped reads/writes without making them method
  locals unless assigned in the method flow.
- Statement spans and source text.
- Blank/comment boundaries from source lines.

Facts populated later:

- `local_methods`
- `local_complexity_scores`
- `path_conditions`
- `local_contract_assignments`

This machinery is shared. Ruby, Python, Lua, JavaScript/TypeScript, PHP, and
Perl should not implement private local-flow analyzers.

### Metadata And Types

Normalize or emit metadata events for:

- Immutable value readers.
- Reader field types.
- Type aliases.
- Method parameter types.
- Visibility events/declarations.
- Owner field declarations.
- State-param origins from normalized state writes whose RHS is a current
  function parameter.
- Body-owner scopes for language constructs that define an owner through a
  function-returned type, such as Zig `fn Box(...) type { return struct { ... } }`.

Facts populated later:

- `state_declarations`
- `state_param_origins`
- `immutable_struct_readers`
- `immutable_struct_reader_types`
- `type_aliases`
- `method_param_types`
- function `visibility`

Ruby Sorbet syntax is language-specific. The metadata model is not.

## Passes

### 0. Source Selection

Responsibility:

- Map a file or explicit option to a language profile.
- Reject unsupported source.
- Preserve deterministic file ordering.

Populates:

- language metadata for the document

Must not:

- parse facts
- run detectors
- infer syntax from source text

### 1. Concrete Parse

Responsibility:

- Parse source with Tree-sitter.
- Preserve source text, lines, spans, and concrete tree.

Populates:

- raw parser tree for normalization

Must not:

- mine facts
- apply language-specific detector semantics

### 2. Normalization

Responsibility:

- Convert concrete grammar shapes into normalized AST nodes.
- Remove wrapper noise that should not affect public facts.
- Preserve source text/spans.
- Normalize the linguistic features listed above.

Populates:

- `normalized_root`

Must not:

- calculate detector findings
- mine local flow
- derive semantic effects
- apply visibility

Ruby implementation:

- `lib/fact_mine/ast/normalizer.rb`
- language AST adapters in `lib/fact_mine/ast/adapters/<language>.rb`
- language extraction behavior in `lib/fact_mine/syntax/<language>.rb`
- `lib/fact_mine/syntax/normalized_extraction_behavior.rb`

Rust implementation:

- `rust/src/ast.rs`
- language AST adapters in `rust/src/ast/adapters/<language>.rs`
- language syntax behavior in `rust/src/syntax/<language>.rs`

### 3. Stateless Normalized Extraction

Responsibility:

- Walk normalized AST once with lexical owner/function/control stacks.
- Emit facts that depend on one node plus stack context.
- Emit semantic effects that are directly represented by normalized nodes,
  such as `yield`, global reads/writes, mutating assignments, and
  `rescue nil`/nil-fallback `eliminable_guard`.

Populates:

- `owners`
- `functions`
- `calls`
- `state_declarations`
- `state_param_origins`
- `state_reads`
- `state_writes`
- `decisions`
- `branch_decisions`
- `branch_arms`
- `dispatch_sites`
- `semantic_effects` from normalized-node semantics
- `predicate_bodies`
- `comparisons`

Ruby implementation:

- `lib/fact_mine/syntax/normalized_extractor.rb`

Rust implementation:

- `rust/src/syntax.rs` and normalized extraction modules under
  `rust/src/syntax/`

Current stateless language hooks are narrow descriptors only:

- receiver spelling and receiver aliases
- owner names and body-owner scopes
- field declarations and state declaration rows
- function visibility and parameter-name projection
- branch predicate/state-ref projection
- nil-predicate spelling and terminating-call spelling
- public projection toggles for index calls, index assignment mutation effects,
  and ternary child conditionality

Hooks must not walk a subtree to compute detector-ready facts. If a hook needs
to inspect concrete grammar structure, that belongs in AST normalization.

Must not:

- know concrete language names
- apply visibility timelines
- own language lexicons
- compute protocol/nil-guard/clone/local-flow facts
- compute call-lexicon semantic effects

### 4. Stateful Normalized Enrichment

Responsibility:

- Consume already-collected facts and normalized AST.
- Apply order-sensitive or multi-section derivations.
- Append lexicon-derived semantic effects from already-collected call facts and
  dedupe them with stateless semantic effects.

Populates:

- final function visibility
- `semantic_effects` from call lexicons and deduplication
- `protocol_method_effects`
- `protocol_call_paths`
- `clone_candidates`
- `redundant_nil_guards`
- `local_methods`
- `path_conditions`
- `local_complexity_scores`
- `local_contract_assignments`
- `immutable_struct_readers`
- `immutable_struct_reader_types`
- `type_aliases`
- `method_param_types`

Ruby implementation:

- `lib/fact_mine/syntax/passes.rb`
- `lib/fact_mine/syntax/effects.rb`
- `lib/fact_mine/syntax/protocols.rb`
- `lib/fact_mine/syntax/clone_similarity.rb`
- `lib/fact_mine/syntax/nil_guards.rb`
- `lib/fact_mine/syntax/normalized_local_facts.rb`

Rust implementation:

- normalized enrichment modules under `rust/src/syntax/`, including
  semantic effects, protocols, clone similarity, nil guards, local flow,
  path conditions, and local complexity.

Must not:

- inspect raw parser nodes
- branch on concrete languages
- own concrete language vocabulary

Stateful pass details:

- Visibility enrichment consumes language-owned visibility events and applies
  them to already-extracted function rows.
- Effect enrichment consumes generic call facts plus language-owned effect
  lexicons; it must not inspect raw source.
- Protocol enrichment consumes state/call/read/write facts and language-owned
  protocol labels.
- Clone enrichment consumes normalized AST and projects canonical public clone
  node names/fingerprints.
- Nil-guard enrichment consumes normalized AST plus language-owned nil-predicate
  and terminating-call hooks.
- Local-flow enrichment consumes normalized AST and canonicalized source text to
  populate statement reads/writes, path conditions, local complexity, and local
  contract assignments.

### 5. Public Projection And Hydration

Responsibility:

- Convert rows into stable `FactDocument` readers.
- Normalize values for JSON/oracle output.
- Keep internal normalized names from leaking into public facts.

Populates:

- `FactDocument`
- syntax oracle JSON
- detector fixture documents

Ruby implementation:

- `lib/fact_mine/syntax/fact_document.rb`
- `lib/fact_mine/syntax_oracle.rb`

Special public projection:

- Clone fingerprints are public detector inputs, so they use a canonical
  fingerprint vocabulary derived from normalized AST.
- Clone output must not expose raw Tree-sitter names or private normalized
  names such as `DEFN`, `LASGN`, or `CALL`.
- If canonical projection changes, only clone oracle expectations should
  change. Detector facts that do not expose clone node names must remain
  byte-for-byte stable.

### 6. Consumers

Responsibility:

- Decomplex detectors and reports consume `FactDocument` facts only.

Must not:

- inspect `normalized_root`
- inspect raw parser nodes
- branch on concrete languages
- run syntax adapters

## Current Ruby-Side Architecture

The Ruby implementation now follows the target shape:

- `syntax/ruby.rb` owns Ruby grammar quirks, Ruby lexicons, Ruby visibility
  events, Ruby nil-predicate spelling, Ruby mutating-method vocabulary, and
  Ruby Sorbet metadata parsing.
- `normalized_extractor.rb` extracts only stateless facts from normalized AST.
- `passes.rb` runs stateful enrichment.
- `effects.rb` and `protocols.rb` are shared engines fed by language-owned
  lexicons.
- `nil_guards.rb`, `clone_similarity.rb`, and `normalized_local_facts.rb`
  operate on normalized AST, not raw parser nodes.
- Decomplex detectors consume facts only.

The same normalized pass structure is used by the other Ruby-side language
profiles. Their language-specific code is limited to concrete AST normalization,
small extraction-behavior projection hooks, and language-owned lexicons.

## Current Rust-Side Architecture

The Rust implementation must match the same boundaries:

- `rust/src/ast/adapters/<language>.rs` owns concrete grammar normalization
  quirks such as Ruby inline visibility wrappers and Python `for`/`with`
  statement parts.
- `rust/src/ast.rs` owns shared normalized tree construction and dispatches to
  adapter hooks without naming concrete languages.
- `rust/src/syntax/clone_similarity.rs` projects clone candidates from
  normalized AST using canonical public clone node names.
- Generic Rust syntax modules must not reintroduce language lexicons or raw
  concrete grammar branches. Add a language hook or adapter method instead.

## Invariants

Architecture tests should enforce:

- Generic normalized extractors do not reference concrete language tokens.
- Generic fact engines do not own language lexicons.
- Generic normalized engines do not call raw parser traversal APIs.
- Detectors do not inspect raw parser nodes or `normalized_root`.
- Syntax helper files are explicitly reviewed and whitelisted.
- Concrete language adapter classes live in their language files.

When adding a language:

1. Add/extend the language file.
2. Normalize concrete grammar quirks to the shared AST vocabulary.
3. Register language lexicons.
4. Add semantic oracle fixtures.
5. Do not add detector facts or private extraction engines to the language file.
