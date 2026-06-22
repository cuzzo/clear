# Espalier Static Fact Mining Architecture

Status: target architecture. This document describes where static facts should
be mined and how Espalier should consume them. It also records current
implementation debt in `Espalier::FactMineStaticFacts`.

## Goal

Espalier should consume language-neutral source facts and produce architecture
evidence. It should not parse concrete language syntax, infer nil/type rewrite
actions, or own Ruby/Sorbet vocabularies.

The correct boundary is:

```text
source files
  -> FactMine concrete parse
  -> FactMine normalized AST
  -> FactMine public source facts
  -> Espalier architecture projection
  -> Nil-kill compatibility projection, only when requested by Nil-kill
```

FactMine owns static fact mining. Espalier owns architecture synthesis from
those facts. Nil-kill owns nilability, type-action, runtime, and rewrite
interpretation.

## Non-Negotiable Rules

- Espalier must not mine concrete language facts with source-text regexes.
- Espalier must not inspect raw Tree-sitter nodes to recover language grammar.
- Concrete language behavior belongs in FactMine language files, normalized AST
  adapters, and language-owned metadata/type profiles.
- Generic Espalier code must not contain Ruby, Sorbet, Python, TypeScript, or
  other concrete language type vocabularies.
- Nil-kill-only facts must not be treated as Espalier architecture facts.
- Legacy Ruby compatibility keys may be emitted at a boundary adapter, but the
  canonical schema must use language-neutral state/function names.

Regexes are acceptable in Espalier only for non-language semantics, such as
parsing sibling Markdown reports, escaping Graphviz strings, or classifying
architecture naming patterns. They are not acceptable for recognizing method
signatures, type aliases, guards, return expressions, hash literals, language
keywords, or runtime type lattices.

## Current Problem

`Espalier::FactMineStaticFacts` currently acts as a second source-fact miner.
It consumes FactMine structural facts, but then reopens source text and raw
nodes to derive facts such as:

- Ruby Sorbet signatures, `T.let`, `T.type_alias`, `Struct.new`, and
  `T::Struct` fields.
- Python and TypeScript method signatures, fields, stubs, aliases, and
  interface members.
- Literal hash/array shapes and literal value types.
- Dead nil checks, deterministic class guards, noreturn bodies, and return
  origins.
- Ruby ivar protocol records and receiver/state ownership shortcuts.

That is the wrong layer. Those are source facts. They must be emitted by
FactMine and projected by Espalier.

## Desired Pipeline

### 1. FactMine Structural Facts

FactMine normalized extraction emits structural facts from normalized IR:

- owners
- functions
- calls
- state declarations
- state reads and writes
- state-param origins
- decisions and branches
- comparisons
- local-method summaries
- path-condition facts
- protocol and semantic-effect facts

These facts are language-neutral in shape. Language-specific syntax is already
normalized before this pass.

### 2. FactMine Metadata Facts

FactMine must also emit metadata facts that are currently reconstructed by
Espalier. These facts can be produced by language-owned metadata hooks, but the
public rows should be stable and language-neutral.

Required fact families:

- `type_definitions`: method signatures, state-field declarations, type
  aliases, included/extended type memberships, and equivalent type-system
  declarations.
- `literal_shapes`: hash/object/map/dict shapes and array/list/tuple shapes.
- `guard_facts`: deterministic nil/type/literal guard results derived from
  normalized path conditions and language-owned type semantics.
- `return_origins`: normalized local return-source summaries.
- `noreturn_methods`: functions whose declarations or bodies cannot return
  normally.
- `structural_type_members`: struct/class/record field declarations, including
  language-specific sugar such as Ruby `Struct.new` or `T::Struct`.

FactMine may use language-specific regexes inside language-specific files when
the parser cannot expose annotation syntax directly. Those regexes must stay
behind language names and must emit normalized rows. Generic FactMine passes
and Espalier must not know those concrete spellings.

### 3. Espalier Architecture Projection

Espalier consumes FactMine public facts and projects only architecture evidence:

- file records and language metadata
- owners/modules/classes
- functions and signatures for display
- state fields with optional declared type
- state read/write effects
- owner-to-owner delegation edges
- state lifecycle/protocol pressure
- privacy and architecture review candidates

Espalier may derive architecture facts from source facts, for example resolving
a state field's declared type to another manifest owner. It must not re-mine the
source expression that produced the declared type.

### 4. Nil-Kill Compatibility Projection

Nil-kill may call `NilKill::StaticEvidence`, which currently delegates to
`Espalier::StaticEvidence`. That delegation is a compatibility path, not a
reason for Espalier to own Nil-kill facts.

The compatibility projection should live in Nil-kill or a narrow adapter. It can
map language-neutral facts into legacy Nil-kill store sections:

- `state_protocols` -> `ivar_protocols`
- `state_param_origins` -> `ivar_param_origins`
- `state_type_records` -> `struct_field_static`
- `array_shapes` -> `tuple_arrays`
- `type_definitions` -> `existing_sigs` / `unsigned_methods`

Long term, Espalier should expose architecture facts by default. Nil-kill should
request the compatibility bundle explicitly or build its store from FactMine
facts directly.

## Fact Ownership Matrix

| Fact section | Mined in target architecture | Actually used by Espalier | Nil-kill use |
| --- | --- | --- | --- |
| `files` | Espalier projection over selected files | run metadata and report context | store file summary |
| `methods` | FactMine `functions` projected by Espalier | manifest functions, signatures, visibility, effects | method indexing, trace plan |
| `fields` | FactMine state declarations/read-write facts | manifest state rows | slot coverage |
| `state_types` | FactMine state declarations | dependency target resolution, state display | indirect compatibility |
| `state_type_records` | FactMine state declarations | state display and owner resolution | `struct_field_static`, trace plan |
| `state_protocols` | FactMine protocol/state-call facts | lifecycle/protocol pressure | legacy `ivar_protocols`, protocol resolver |
| `state_protocol_records` | FactMine protocol/state-call facts | future report drilldown; not central today | not copied today |
| `state_param_origins` | FactMine state-param origins | state property text | legacy `ivar_param_origins` |
| `state_param_origin_records` | FactMine state-param origins | future report drilldown; not central today | not copied today |
| `signatures` | FactMine function/type metadata | method display fallback | trace plan and method records |
| `type_definitions` | FactMine metadata facts | currently only feeds alias recommendations in static output; not core report input | method signatures, field slots, slot coverage |
| `alias_recommendations` | Derived from `type_definitions` by a typing tool, not Espalier core | not used by Espalier reports today | not copied by current provider; typing/static UX only |
| `struct_declarations` | FactMine structural type members, then Nil-kill legacy projection | not used by Espalier reports today | trace plan, struct-field actions |
| `hash_shapes` | FactMine literal-shape facts | not used by Espalier reports today | hash-record inference and report |
| `array_shapes` | FactMine literal-shape facts | not used by Espalier reports today | `tuple_arrays`, slot coverage |
| `tlet_sites` | Ruby FactMine metadata or Nil-kill Ruby provider | not used by Espalier reports today | trace plan and `T.let` actions |
| `dead_nil_checks` | FactMine guard facts or Nil-kill Ruby provider | not used by Espalier reports today | nil-check rewrite actions |
| `deterministic_guards` | FactMine guard facts or Nil-kill provider | not used by Espalier reports today | guard rewrite actions |
| `return_origins` | FactMine normalized local-flow facts or Nil-kill provider | not used by Espalier reports today | return type inference, hash-record inference |
| `noreturn_methods` | FactMine semantic-effect/control facts | not used by Espalier reports today | return-origin enrichment |
| `rbi_field_types` | Nil-kill Ruby/Sorbet compatibility projection | not used by Espalier reports today | struct-field signature actions |
| `ivar_runtime` | Nil-kill runtime tracing | legacy fallback in `NilKillEvidence` only | runtime evidence |
| `ivar_protocols` | Legacy alias of `state_protocols` | fallback only | protocol resolver |
| `ivar_param_origins` | Legacy alias of `state_param_origins` | fallback only | protocol resolver |

Rows marked "not used by Espalier reports today" should not be mined in
Espalier. If they remain in an Espalier-produced JSON file temporarily, they are
compatibility payload for Nil-kill or static typing workflows.

## Type Extraction Boundary

Tree-sitter already parses native type syntax for languages that have native
type annotations. FactMine language adapters and normalized metadata passes
should consume those parse nodes and emit structured type facts. Espalier must
not recover those facts from source strings or by tokenizing type expressions.

For native typed languages, FactMine should expose structured rows such as:

- declared type text for display
- `owner_references` / `type_references` for architecture dependency edges
- intrinsic/broad type classification when needed by a detector
- nullable/optional structure when needed by a typing action

Espalier may display the declared type text, but it should resolve architecture
edges from structured references, not from parsing strings like
`Promise<User>`, `dict[str, Entry]`, `Vec<Node>`, or `*Repository`.

Ruby/Sorbet is the exception because Sorbet is a Ruby DSL, not Ruby grammar.
FactMine's Ruby provider must interpret Sorbet calls and constants such as
`sig`, `T.let`, `T.type_alias`, `T::Struct`, `T.nilable`, and `T.any` as
language-owned metadata.

The following current Espalier patterns are Ruby/Sorbet-specific and should move
out of generic Espalier code:

- `Espalier::CORE_CLASS_CONSTANTS` in `static_helpers.rb`.
- `BROAD_TYPE_PATTERN` in `alias_recommendations.rb`, which mixes Sorbet,
  Python, and language-neutral names.
- `CORE_TYPES` in `architecture_analyzer.rb` and `dependency_graph.rb`, which
  should be replaced by structured FactMine type references for native typed
  languages and Ruby-owned Sorbet classification for Ruby compatibility.
- `CORE_RUNTIME_GUARD_CLASSES`, `NUMERIC_GUARD_SUBCLASSES`, and
  `BOOLEAN_GUARD_SUBCLASSES` in `fact_mine_static_facts.rb`.
- Helpers such as `static_sorbet_type`, `normalize_static_sorbet_type`,
  `strip_nilable_type`, and any code that returns `T::Array`, `T::Hash`,
  `T::Boolean`, `NilClass`, `TrueClass`, or `FalseClass` from generic Espalier.

The replacement is not a cross-language type-string parser. The replacement is
FactMine-owned type facts, plus narrow language-owned semantic helpers where a
language needs metadata not represented directly by Tree-sitter.

```ruby
document.type_definitions
document.state_declarations # includes declared type and type references
FactMine::Syntax.type_profile(:ruby, type_system: "sorbet") # Ruby/Sorbet only
```

Generic Espalier must not contain language builtin lists. Generic FactMine files
must not contain those lists either. If native typed languages need primitive or
standard-library classification, that belongs in the concrete language file or
adapter and should be projected as structured facts.

## Cross-Language Fact Design

### Type Definitions

FactMine should emit one row per declared type slot:

```json
{
  "kind": "method_signature",
  "language": "typescript",
  "type_system": "typescript",
  "path": "src/service.ts",
  "owner": "Service",
  "name": "load",
  "line": 10,
  "signature": "load(id: UserId): Promise<User>",
  "params": [{ "name": "id", "type": "UserId" }],
  "return_type": "Promise<User>"
}
```

The same section can represent state fields and type aliases:

```json
{
  "kind": "state_field",
  "language": "python",
  "type_system": "python-typing",
  "path": "src/cache.py",
  "owner": "Cache",
  "name": "entries",
  "line": 7,
  "declared_type": "dict[str, Entry]"
}
```

```json
{
  "kind": "type_alias",
  "language": "ruby",
  "type_system": "sorbet",
  "path": "src/types.rb",
  "owner": "Types",
  "name": "UserId",
  "line": 3,
  "target": "String"
}
```

Espalier should not parse these expressions. If it needs owner references, it
asks the FactMine type profile for owner-reference tokens.

### Literal Shapes

Literal shapes must be mined from normalized literal nodes, not from source
strings. The public rows should describe shape, key/value facts, source span,
and language:

- hash/object/map/dict keys
- value type families
- nested hash/object shapes
- nested array/list element shapes
- tuple/list element types and fixed size when known

Nil-kill can translate these facts into Sorbet struct candidates. Espalier
should not do that translation.

### Guards And Proofs

Guard facts must be derived from normalized path-condition facts plus a
language-owned type lattice:

- nil/null/none checks
- safe-navigation or optional-chain redundancy
- type/class guard truth
- literal comparison truth
- terminal guard branches

The type lattice belongs to FactMine or Nil-kill providers. Espalier should not
know that Ruby has `NilClass`, `TrueClass`, `FalseClass`, or `T::Boolean`.

### Return Origins

Return origins require local-flow semantics. They should be produced by
FactMine normalized local facts or by Nil-kill provider logic, not by scanning
method body lines in Espalier.

Rows should identify:

- producing function
- return source expressions
- source kind, such as literal, nil, local, call, typed call, unknown
- candidate type when statically known
- blockers when confidence is not strong
- path/span for action/report references

Nil-kill can enrich these facts with runtime traces, RBI data, and whole-program
callee propagation. Espalier should not.

### Noreturn

Noreturn should come from semantic-effect facts and language termination
lexicons:

- Ruby `raise`, `fail`, `abort`, `T.absurd`
- Python `raise`, `sys.exit`
- TypeScript/JavaScript `throw`
- Rust `panic!`, diverging functions
- Go `panic`, `os.Exit`
- Zig/C/C++/Java/C#/Kotlin/Swift equivalents

The public fact should say "this function cannot return normally" without
forcing Espalier to parse each language's termination syntax.

### Struct-Like Declarations

Struct/class/record fields should normalize into owner and field facts. Ruby
`Struct.new` and `T::Struct` are Ruby-specific syntax for declaring fields;
TypeScript interfaces, Python dataclasses/stubs, Go structs, Rust structs, Zig
containers, Java/C#/Kotlin/Swift classes, and C/C++ structs should all project
to the same field fact shape.

Legacy Nil-kill `struct_declarations` can be projected from those rows when
Nil-kill asks for it.

## Migration Plan

1. Add FactMine fixtures for every current `FactMineStaticFacts` feature before
   moving code: Sorbet signatures, aliases, `T.let`, `T::Struct`,
   Python annotations/stubs, TypeScript interfaces/aliases, literal shapes,
   guard facts, return origins, and noreturn facts.
2. Add public FactMine readers and JSON oracle sections for missing fact
   families.
3. Move concrete parsing from Espalier into FactMine language files or
   language-owned normalized metadata hooks.
4. Replace `Espalier::FactMineStaticFacts` with a projector over FactMine public
   facts. The projector may aggregate, sort, dedupe, and rename fields; it must
   not parse source or raw nodes.
5. Move Nil-kill-only compatibility projection into `NilKill::StaticEvidence`
   or `NilKill::Inference::StaticFactProvider`.
6. Replace generic Ruby/Sorbet type lists in Espalier with calls to FactMine
   language/type profiles.
7. Keep legacy `ivar_*` fields only as explicit compatibility aliases. New
   Espalier code must read `state_*` fields.
8. Add architecture invariant tests:
   - Espalier static projection does not call raw Tree-sitter traversal helpers.
   - Espalier generic code does not define language builtin type lists.
   - FactMine public documents expose the facts Espalier consumes.
   - Nil-kill provider tests verify compatibility fields are still populated.

## Acceptance Criteria

The migration is complete when:

- `gems/espalier/lib/espalier/fact_mine_static_facts.rb` no longer mines
  language facts and can be deleted or reduced to a pure projector.
- Espalier architecture reports are generated from FactMine public facts only.
- Nil-kill tests pass using the compatibility projection without requiring
  Espalier to know Sorbet/Ruby rewrite semantics.
- Cross-language fixtures prove the same fact families work for Ruby, Python,
  TypeScript, Go, Rust, Zig, and other supported languages without adding
  language-specific branches to generic Espalier files.
