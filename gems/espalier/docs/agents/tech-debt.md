# Espalier Tech Debt

Status: living debt ledger. This document complements
`static-fact-mining-architecture.md` by listing the concrete debt that still
exists after moving static analysis ownership toward FactMine.

## Boundary

Espalier should project architecture evidence from FactMine facts. It should not
mine source facts, parse concrete language syntax, inspect raw Tree-sitter
nodes, or own language/type-system vocabulary.

Correct ownership:

- FactMine: source parsing, normalized AST construction, source-fact mining,
  language metadata, type metadata, literal shapes, guards, return facts.
- Espalier: architecture projection, dependency graph construction, report
  evidence, manifest-level heuristics.
- Nil-kill: nilability/rewrite interpretation, Sorbet action planning, runtime
  tracing, legacy compatibility projection.

Current migration status:

- Done: FactMine exposes public `type_definitions` rows and language-owned
  metadata hooks for Ruby/Sorbet, Python typing, and TypeScript.
- Done: FactMine Ruby-owned code emits Sorbet method signatures, `T.type_alias`,
  `Struct.new`, `T::Struct` fields, and included module rows.
- Done: FactMine Python-owned code emits method annotations, typed state
  fields, `.pyi` stub rows, and type aliases.
- Done: FactMine TypeScript-owned code emits method annotations, typed class
  fields, interface members, and type aliases.
- Done: Espalier static projection prefers FactMine-mined `type_definitions`
  and uses the old source parsing path only as legacy fallback.
- Remaining: literal shapes, guard proofs, return origins, noreturn facts,
  complete parser-node-backed Ruby `T.let` coverage, raw-node fallback removal,
  and structured `type_references` coverage still need proper FactMine passes.

## Highest Priority Debt

### `Espalier::FactMineStaticFacts` Is Still A Source-Fact Miner

`gems/espalier/lib/espalier/fact_mine_static_facts.rb` still walks raw nodes,
reads source lines, matches concrete node kinds, and reconstructs fact families
that should be emitted by FactMine.

Debt examples:

- `walk_tree`, `named_child`, `node_named_children`, `node_text`, and
  `node_span` are raw syntax helpers in Espalier.
- `extra_typed_state_declarations` mines assignment/type syntax.
- `literal_shapes` mines hash/array shapes from raw nodes.
- `dead_nil_checks`, `deterministic_guards`, `return_origins`, and
  `noreturn_methods` derive nil-kill-style static facts.
- Ruby, Python, TypeScript, and JavaScript branches live in one generic class.

Target state:

- `FactMineStaticFacts` becomes a pure projector over FactMine public facts, or
  is deleted.
- Any remaining legacy field names are produced by a narrow compatibility
  adapter, preferably in Nil-kill when the output is nil-kill-only.

## Fact Families To Move Into FactMine

### Type Definitions And Signatures

Resolved boundary:

- Ruby `sig`, `T.type_alias`, `Struct.new`, `T::Struct`, and included module
  facts are emitted by FactMine Ruby-owned metadata code.
- Python annotations, `.pyi` stubs, `TypeAlias`, and `type Name = ...` aliases
  are emitted by FactMine Python-owned metadata code.
- TypeScript interfaces, method signatures, field declarations, and type
  aliases are emitted by FactMine TypeScript-owned metadata code.
- Espalier consumes `type_definitions` rows from FactMine before using any
  compatibility fallback.

Remaining Espalier debt:

- `StaticEvidence#ruby_annotation_type_definitions` scans `sorbet/rbi/**/*.rbi`
  and feeds those files back through Espalier static facts.
- `FactMineStaticFacts` still contains legacy fallback parsers for older
  non-FactMine documents. These should be deleted after downstream fixtures and
  CLI paths rely only on FactMine public facts.
- Structured `type_references` are not complete for all moved rows.

Move to FactMine:

- Mine remaining native type syntax from Tree-sitter parse nodes instead of
  source-line fallback inside the language adapters where parser coverage
  allows it.
- Let Espalier consume rows such as `method_signature`, `state_field`,
  `type_alias`, `included_module`, and structured `type_references`.

### State Declarations With Types

Current Espalier debt:

- `extra_typed_state_declarations` and `source_typed_state_declarations` remain
  as legacy fallbacks when no mined FactMine type metadata exists.
- Ruby single-line `T.let` state declarations are emitted by FactMine Ruby-owned
  metadata; multiline and parser-node-backed coverage still need to be
  completed.
- `declared_type_text` and `state_target` recover field/type text from raw node
  shapes on the legacy fallback path.

Move to FactMine:

- FactMine state declarations should carry declared type text and structured
  `type_references` / `owner_references`.
- Native typed languages should derive this from parsed type nodes.
- Ruby/Sorbet `const`, `prop`, and common single-line `T.let` are emitted by
  the Ruby metadata provider; parser-node-backed `T.let` coverage remains.
- Espalier should only display the declared type and use structured references
  for architecture edges.

### Literal Shapes

Current Espalier debt:

- `hash_shape`, `array_shape`, `hash_pair_nodes`, `hash_key_name`,
  `literal_value_type`, `constant_literal_types`, and `array_literal_type`
  inspect raw nodes and emit Sorbet-shaped literal types.
- Generic Espalier knows concrete literal node names such as `hash`,
  `dictionary`, `object`, `map`, `array`, `list`, and `table_constructor`.

Move to FactMine:

- Add `literal_shapes` public facts for hash/object/map/dict and
  array/list/tuple literals.
- Mine these from normalized literal IR, with language adapters preserving key
  spelling, element spans, and container kind.
- Nil-kill can translate literal shapes into Sorbet struct or tuple actions.
  Espalier should not do that translation.

### Guard Facts

Current Espalier debt:

- `dead_nil_checks` and `deterministic_guards` derive proof facts.
- `deterministic_class_guard`, `deterministic_literal_comparison`, and
  `branch_context_for` still parse expressions and branch context in Espalier.
- Ruby/Sorbet type semantics were moved behind FactMine's Ruby type profile, but
  the proof traversal still lives in Espalier.

Move to FactMine or Nil-kill:

- FactMine should emit language-neutral `guard_facts` from normalized
  path-condition facts plus language-owned type semantics.
- Nil-kill can consume those guard facts to decide rewrites.
- Espalier reports should not depend on nil-check rewrite facts.

### Return Origins And Noreturn

Current Espalier debt:

- `return_origins`, `ruby_return_sources`, `ruby_return_source`, and
  `method_body_lines` scan Ruby method body lines.
- `noreturn_methods` combines Sorbet return annotations with body text checks.

Move to FactMine or Nil-kill:

- FactMine normalized local-flow facts should emit return-origin summaries.
- FactMine semantic-effect facts should identify functions that cannot return
  normally.
- Ruby termination vocabulary belongs in FactMine Ruby-owned code.
- Nil-kill should enrich return-origin facts with runtime traces and rewrite
  policy.

### Structural Type Members

Current Espalier debt:

- `ruby_struct_definitions`, `ruby_struct_definitions_from_facts`,
  `ruby_t_struct_fields`, and `ruby_t_struct_containers` mine Ruby structural
  members.
- Python stubs and TypeScript interfaces are mined in the same generic class.

Move to FactMine:

- Add `structural_type_members` or equivalent rows for struct/class/interface
  fields.
- Ruby `Struct.new` and `T::Struct`, Python dataclasses/stubs, TypeScript
  interfaces, Go/Rust/Zig structs, and C-family record fields should project to
  the same public fact shape.
- Legacy `struct_declarations` should be a Nil-kill compatibility projection.

### Protocol And State-Origin Compatibility

Current Espalier debt:

- `derived_state_param_origins` reconstructs param-to-state origins from local
  statements.
- `ruby_ivar_protocol_records` scans Ruby ivar protocol calls from source text.
- `state_protocols` / `state_param_origins` are copied into legacy `ivar_*`
  concepts elsewhere.

Move to FactMine or Nil-kill:

- FactMine should emit complete state-param origin and protocol path facts from
  normalized assignments and calls.
- Nil-kill should own legacy `ivar_protocols` and `ivar_param_origins` aliases.

## Language-Specific Debt Hidden In Generic Espalier

### Ruby / Sorbet

Hidden outside language-specific FactMine code:

- `FactMineStaticFacts`: legacy fallback copies of `sig`, `T.type_alias`,
  `T::Struct`, `Struct.new`, `include`, and `T.let`, plus still-active ivar
  protocols, nil guards, return origins, literal type names, and
  Sorbet-specific output rows.
- `StaticEvidence`: RBI discovery and conversion through
  `ruby_annotation_type_definitions` and `rbi_field_type_records`.
- `static_helpers.rb`: Ruby/Sorbet compatibility shims such as
  `static_sorbet_type`, `extract_param_entries`, and `strip_nilable_type`.
  These now delegate to FactMine Ruby type profile, but they should disappear
  when Nil-kill compatibility moves out of Espalier.
- `ArchitectureAnalyzer` and `DependencyGraph`: Ruby/Sorbet string fallback for
  owner resolution remains as compatibility until FactMine emits structured
  references for all Ruby state declarations.

Target:

- Keep Sorbet parsing and Ruby type semantics only in FactMine Ruby-owned code
  or Nil-kill Ruby providers.
- Espalier consumes structured facts and never emits Sorbet action semantics by
  default.

### Python

Hidden outside language-specific FactMine code:

- Legacy fallback copies of `python_source_typed_state_declarations`,
  `python_stub_type_definitions`, `python_type_alias_definitions`, and
  `python_signature_types`.
- Python receiver names such as `self` and `cls` in generic state handling.

Target:

- Python adapter/metadata pass emits annotations, stub facts, type aliases,
  state fields, and function signatures.
- Generic Espalier does not parse `.py` or `.pyi` source lines.

### TypeScript / JavaScript

Hidden outside language-specific FactMine code:

- Legacy fallback copies of `typescript_source_typed_state_declarations`,
  `typescript_interface_type_definitions`, `typescript_type_alias_definitions`,
  `typescript_signature_types`, and `typescript_param_entry`.
- TypeScript/JavaScript receiver and field assumptions in generic state helpers.

Target:

- TypeScript adapter/metadata pass emits interface members, aliases, field
  declarations, method signatures, and structured type references from parsed
  type nodes.
- JavaScript should emit only facts supported by the language or by explicit
  JSDoc/type metadata support in FactMine.

### Generic Raw Node Shape Debt

Hidden outside language-specific FactMine code:

- Raw node-kind groups for state targets, hash pairs, array literals, and
  literal values are centralized in `FactMineStaticFacts`.
- These groups mix language concepts under broad names like `hash`,
  `dictionary`, `object`, `map`, `array`, `list`, and `table_constructor`.

Target:

- Language adapters normalize concrete nodes into shared IR concepts.
- Generic FactMine passes consume normalized literal/state/type metadata.
- Espalier sees only public facts.

## Espalier-Specific Debt That Should Stay In Espalier For Now

These are architecture/reporting heuristics, not source-fact mining:

- Role-name heuristics in `ArchitectureAnalyzer`, such as lifecycle role names
  and mediator/cohesion scoring.
- Graph and DOT formatting concerns in `DependencyGraph` and
  `GraphvizFormatter`.
- Report wording and report organization in `Reporter`.
- Privacy candidate scoring in `PrivacyAnalyzer`, as long as it consumes
  manifest facts and does not parse source.

These may still need cleanup, but they are not FactMine migration blockers.

## Migration Order

1. Add FactMine public readers and fixture/oracle sections for missing fact
   families before removing Espalier compatibility output.
2. Done: move type definitions and most typed state declarations first, because
   architecture dependency edges now expect structured `type_references`.
3. Partially done: move structural type members, including Ruby `Struct.new`,
   Ruby `T::Struct`, Python stubs, and TypeScript interfaces. Remaining work is
   complete structured references and parser-node-backed extraction where
   source-line fallback still exists.
4. Move literal shapes into a normalized literal-shape pass.
5. Move guard facts, return origins, and noreturn facts into FactMine passes or
   Nil-kill providers, depending on whether they are general source facts or
   rewrite-only facts.
6. Move Nil-kill compatibility aliases and Sorbet action payloads out of
   Espalier.
7. Delete or reduce `FactMineStaticFacts` to a pure projector.
8. Remove `static_helpers.rb` Ruby/Sorbet compatibility shims once no caller in
   Espalier needs them.

## Acceptance Checks

- Espalier static projection does not call raw Tree-sitter traversal helpers.
- Espalier generic code has no concrete language branches for Ruby, Python,
  TypeScript, JavaScript, or other language syntax.
- Espalier generic code has no builtin type lists or type-string parsers.
- FactMine public facts include every section consumed by Espalier static
  evidence.
- Nil-kill tests pass without requiring Espalier to know Sorbet rewrite
  semantics.
- New architecture invariant tests fail when source mining is reintroduced into
  Espalier.
