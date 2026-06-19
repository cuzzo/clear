# Multi-Language Static Analysis Fix

## Problem

Nil-kill had a misleading static-analysis boundary. `StaticEvidence`
looked language-neutral, but the Ruby provider previously called a legacy
Ruby source index from inside `provider.static_evidence`. That index was Ruby/Sorbet-specific:
it parses Ruby through Nil-kill's Ruby syntax facade, knows about RBI/Sorbet
facts, and contains inference-oriented collectors that are not portable.

That means the current "multi-language provider" shape overclaims support. The
portable part is structural evidence collection. The Ruby-only part is
inference, checker/RBI integration, and rewrite planning. These must be modeled
as separate capabilities.

## Decision

`StaticEvidence` must not call the legacy Ruby source index, directly or indirectly. The static
analysis path should consume Tree-sitter facts from Decomplex and Nil-kill
language adapters. Ruby inference must consume the same StaticAnalysis facts
through a Ruby provider instead of owning another fact-mining path.

Nil-kill-specific static analysis should be implemented by extending
Decomplex's Tree-sitter normalization/adapters and consuming the normalized
facts from Nil-kill. It must not smuggle Ruby-specific behavior through
`Language::Provider`.

## What Static Analysis Needs

Static analysis should emit only facts that are useful without a language
checker or standard-library type model:

- `files`: path, language, parser, line count
- `methods`: owner, name, kind, path, line/span, params, syntactic signature
- `fields`: owner, name, path, line/span, declared type when syntactically present
- Decomplex input facts: `state_reads` and `state_writes`
- `state_types`: declared state/field type by `owner\0field`
- `state_protocols`: method names called on known state fields
- `state_param_origins`: constructor/function params assigned into state fields
- `type_definitions`: syntactic method signatures, state fields, type aliases,
  included modules or equivalent composition facts
- `hash_shapes`: literal object/hash/dict/map keys and conservative literal
  value types
- `array_shapes`: literal/list/array element types, size, homogeneous flag, and
  tuple-like positional types
- `alias_recommendations`: derived from `type_definitions`
- `language_capabilities`: what the adapter can actually emit

These are report/evidence facts. They are not proof of inferred types.

Decomplex already provides `state_reads` and `state_writes`; Nil-kill should not
reimplement those collectors. Nil-kill's static layer should consume those facts
and derive Nil-kill-specific records such as fields, protocols, param origins,
slot coverage, and pressure reports.

## What Decomplex Already Has

Decomplex is already the right owner for language-neutral syntax facts:

- language detection and Tree-sitter parser selection
- parsed `Document` with source, lines, root node, language, and adapter
- `structural_facts(document)` with:
  - `function_defs`
  - `owner_defs`
  - `call_sites`
  - `state_declarations`
  - `state_param_origins`
  - `state_reads`
  - `state_writes`
- branch/decision facts used by other Decomplex detectors
- a normalized AST path through `Decomplex::Ast::TreeSitterNormalizer`
- language-specific normalization adapters for generic syntax shape
- an O(1) Tree-sitter facade/cache pattern that avoids repeated parent/child
  lookups

Nil-kill should consume those facts first. If a fact is broadly useful to
Decomplex detectors or to multi-language static analysis, add it to Decomplex's
Syntax/adapter/normalizer layer. Nil-kill should only keep final evidence
assembly and Nil-kill-specific scoring/reporting.

## New Facts Nil-Kill Needs

Nil-kill still needs facts that Decomplex either does not emit yet or does not
emit in the exact evidence schema:

- `array_shapes`: array/list literal size, positional element types,
  homogeneous flag, source location, and code
- language-specific type definitions:
  - Ruby `sig` method signatures
  - Ruby `T::Struct` fields
  - Ruby `Struct.new` fields
  - Ruby `include` composition facts
  - Python `.pyi` signatures and fields
  - TypeScript interface/type alias/class field declarations
- corrected owner scopes for Ruby `Struct.new(...) do ... def ... end`
- protocol derivations from known state fields when Decomplex call-site output
  is incomplete, such as Ruby ivar member calls around Sorbet `sig` wrappers
- capability metadata that distinguishes "annotation parsing" from real
  checker-backed type indexing

These are static evidence facts. They should not imply inferred receiver types
or safe rewrites.

## What Static Analysis Must Not Own

The portable static path must not produce or depend on:

- RBI parsing or Sorbet return/field indexes
- Ruby stdlib/gem return inference
- receiver method return typing
- return-origin inference used for signature rewrites
- deterministic nil guard rewrite actions
- collection lookup provenance that depends on expression typing
- confidence gates based on "this will typecheck"
- autofix actions

Those belong to a provider-specific inference/repair backend. Today that backend
is Ruby/Sorbet.

## Architecture

Use four explicit layers:

1. `Decomplex::Syntax`
   Parses files with Tree-sitter and exposes raw documents plus generic
   structural helpers.

2. `Decomplex::Ast::TreeSitterNormalizer` and Decomplex adapters
   Normalize language-specific Tree-sitter node shapes into common syntax facts.
   Extend this layer for multi-language facts Nil-kill needs: array shapes,
   owner scopes, state access protocol calls, annotations, and declaration
   shapes.

3. `NilKill::StaticAnalysis`
   Consumes normalized Decomplex facts and assembles the Nil-kill evidence
   schema. It should not parse language syntax itself.

4. Provider-specific semantic backends
   Optional. Ruby/Sorbet, TypeScript compiler, pyright/mypy, Psalm/PHPStan,
   LuaLS, etc. These are not required for static evidence and must not be
   represented as available until wired to a real backend.

`Language::Provider` should be narrowed to capability metadata or split into
explicit capabilities:

- `syntax_adapter`
- `static_fact_extractor`
- `runtime_tracer`
- `type_backend`
- `rewrite_backend`

## Tree-Sitter Access Pattern

The Decomplex Syntax/Normalizer layer must preserve the O(1) Tree-sitter facade
work:

- wrap raw nodes once per document using stable node ids/byte ranges
- cache parent, children, named children, named fields, text slice, kind, span
- never call `node.parent` repeatedly while walking
- maintain an explicit stack during DFS for owner/function/control context
- perform one primary DFS per file, with small post-processing indexes
- use adapter predicates that receive cached node wrappers, not raw nodes
- avoid source-line regex scans for facts that can be derived from nodes

Allowed post-processing:

- de-duplicate records by stable keys
- build `known_state_fields` by owner
- derive `state_protocols` from call sites plus known state fields
- derive alias recommendations from `type_definitions`
- derive slot/collection pressure from hash and array literal shapes

## Adapter Interface

Each Decomplex language adapter should implement the smallest useful surface:

```ruby
module Decomplex
  class Adapter
    def language; end
    def self_receiver_names; end

    def function_definition?(node); end
    def function_name(node); end
    def function_kind(node); end
    def function_params(node); end
    def function_signature(node); end

    def owner_definition?(node); end
    def owner_name(node, stack); end
    def owner_kind(node); end

    def call_target(node, stack); end
    def state_read_target(node, stack); end
    def state_write_target(node, stack); end
    def state_declaration(node, stack); end
    def state_param_origin(write, stack); end

    def hash_literal?(node); end
    def hash_pairs(node); end
    def array_literal?(node); end
    def array_elements(node); end
    def literal_type(node); end

    def annotation_definitions(node, stack); end
  end
end
```

Adapters should expose normalized facts through Decomplex `Syntax` and
`TreeSitterNormalizer`. Nil-kill should consume those facts; it should not add
language parsers or regex-based syntax extraction in providers.

## Language-Specific Scope

Initial adapters should be honest about what they support:

- Ruby: syntactic Sorbet signatures, `T::Struct` fields, `Struct.new` fields,
  includes, ivar assignment/origins/protocols, hash and array shapes.
- Python: functions/methods, class fields from annotations, `self.x`
  assignments, `.pyi` declarations, `typing` aliases, dict/list shapes.
- TypeScript: functions/methods, class/interface fields, `this.x`, declared
  params/returns, type aliases/interfaces, object/array shapes.
- Lua/PHP/Perl: start with functions, owner scopes where available, state
  assignment conventions, and table/hash/array-like shapes. Do not claim type indexing
  until real annotation/type backends exist.

## Migration Plan

1. Keep `StaticEvidence` as the public command output, but make it consume
   Decomplex normalized facts only.
2. Extend Decomplex `TreeSitterNormalizer`, `Syntax`, and language adapters for
   array shapes, annotation definitions, owner scopes, and protocol calls.
3. Port the Ruby-only static facts previously recovered from the legacy Ruby source index into
   Decomplex Tree-sitter collectors: method signatures, `T::Struct` fields,
   `Struct.new` fields, includes.
4. Replace line-regex Ruby extractors with Tree-sitter adapter collectors in
   Decomplex.
5. Add per-language fixture tests that assert exact evidence records and
   explicitly assert that `StaticEvidence` does not instantiate a language-local
   source index.
6. Change capability metadata so `type_indexing` means a real semantic backend,
   not "we parsed annotations."

## Correctness Rules

- A static record must identify its source as `syntax`, `annotation`,
  `runtime`, or provider backend.
- A language must not advertise runtime tracing, type indexing, or rewrites
  unless that capability has an implementation and tests.
- Unknown receiver calls are protocol pressure, not inferred receiver types.
- Syntactic annotations are declared types, not inferred types.
- Ruby/Sorbet facts may enrich Ruby reports, but only through explicit Ruby
  static or inference backends.

## Immediate Follow-Up

After removing the legacy source index from `StaticEvidence`, the next
implementation step is to keep `NilKill::StaticAnalysis` as the fact assembly
surface and keep providers as adapters/capability descriptors rather than
hidden extraction engines.

## Extension Plan

The multi-language path should extend Tree-sitter support in the following
order:

1. Extend `Decomplex::Syntax` structs for generic facts. `state_reads` and
   `state_writes` already live there and should remain the source of truth.
2. Extend Decomplex adapters for language-specific node-shape recognition:
   arrays/lists, object/hash literals, owner scopes, annotations, protocol call
   targets, and state declaration forms.
3. Extend `Decomplex::Ast::TreeSitterNormalizer` to normalize those syntax
   shapes using the O(1) node facade/cache. Normalizer output should stay
   language-neutral.
4. Keep Nil-kill static assembly schema-oriented: merge Decomplex facts,
   de-duplicate records, compute summaries, and run Nil-kill pressure analysis.
5. Add adapters incrementally with exact fixture tests over emitted facts.

The Decomplex walk should run once per file, thread scope in the walk stack, and
avoid hidden fallbacks to Ruby-local source indexing.
