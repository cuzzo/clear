# Ruby-First Cross-Language AST Architecture

Status: Ruby implementation complete for the production detector architecture.
Rust mirror work is pending. The legacy AST normalizer remains quarantined as a
compatibility layer, not as detector infrastructure.

Related analysis: `gems/decomplex/docs/agents/architectural-issues.md`.

## Implementation Status

Completed so far:

- `ast.rb` has been reduced to a small facade.
- AST infrastructure has been split into `ast/node.rb`, `ast/cache.rb`,
  `ast/source_map.rb`, and adapter files.
- `Ast.parse_semantic` and `SemanticNode` still exist as compatibility
  infrastructure, but production detectors should consume `Syntax` facts
  directly.
- `TreeSitterNormalizationAdapter.for` now fails loudly for unsupported AST
  compatibility languages instead of silently falling back to a generic
  adapter.
- Ruby-specific defaults for `yield`, `&.`, leading `def`, heredoc handling,
  and Ruby variable text checks have been moved out of the base AST adapter
  into `adapters/ruby.rb`.
- `RubySyntaxAdapter` owns Ruby method visibility markers and singleton
  method receiver naming for structural facts.
- `PythonSyntaxAdapter` owns Python receiverless adjacent-call syntax.
- `Syntax::SemanticEffectSite` and Ruby effect adapters now expose
  False-Simplicity-style semantic effects such as Ruby dynamic dispatch,
  command literals, `yield`, singleton-class metaprogramming, globals,
  receiver mutation, callbacks, and core-class reopen support.
- `Syntax::ProtocolMethodEffect` and `Syntax::ProtocolMethodPath` now expose
  Ruby ordered-protocol method effects and path-separated internal call
  sequences, including branch/case separation and lambda-body exclusion.
- `Syntax` no longer requires the `Ast` facade; the dependency direction is
  compatibility-only (`Ast` may call into `Syntax`, not the reverse).
- Ruby structural/local/path helper behavior has been split out of `syntax.rb`
  into `syntax/ruby.rb`; `syntax.rb` now keeps only the shared profile and
  dispatcher layer plus a Ruby adapter stub.
- These detectors now avoid `Ast.parse` and `Ast.parse_semantic` in production
  and consume `Syntax` facts:
  - `SequenceMine`
  - `OversizedPredicate`
  - `StructuralTopology`
  - `TemporalOrderingPressure`
  - `StateBranchDensity`
  - `StateMesh` write/read discovery
  - `PredicateAlias`
  - `SemanticAlias`
  - `LocalFlow`
  - `DerivedState`
  - `FatUnion`
  - `DecisionPressure`
  - `PathCondition`
  - `InconsistentRenameClone`
  - `WeightedInlinedCognitiveComplexity`
  - `RedundantNilGuard`
  - `FalseSimplicity`
  - `OrderedProtocolMine`
- A production detector search now leaves legacy Ruby AST node names only in
  `ast.rb`, the explicit compatibility facade.

Remaining follow-up work:

- `ast/legacy_normalizer.rb` is still a large Ruby-shaped compatibility
  normalizer. It is no longer production detector infrastructure, but it should
  eventually shrink or become Ruby-only compatibility code.
- The base `TreeSitterLanguageAdapter` in `syntax.rb` still contains broad
  cross-language heuristic tables; non-Ruby language work should continue to
  move behavior into explicit language profiles.
- The semantic model still does not expose exception-flow details or a full
  expression tree. Current Ruby detector coverage does not require those facts,
  but future detectors must add adapter-owned facts rather than reviving the
  legacy AST model.
- Rust has not yet been mirrored to the Ruby architecture; current Rust parity
  is preserved for the migrated Ruby detector fixtures.

## Goal

Make Decomplex's Ruby AST/normalization implementation architecturally correct
first, then mirror that architecture in Rust with minimal behavioral drift.

The correct end state is not "one Ruby AST shape that every language pretends
to be." The correct end state is:

1. Language adapters own Tree-sitter grammar quirks.
2. A shared semantic model represents facts detectors can use across
   languages.
3. Ruby parser compatibility exists only at a Ruby boundary.
4. Unsupported language features are explicit capability gaps, not silent
   generic fallbacks.

## Non-Goals

- Do not add another layer of string matching to the shared normalizer.
- Do not preserve `ruby?` as a shared-code branch mechanism.
- Do not make Rust lead the architecture. Rust mirrors Ruby after Ruby is
  correct.
- Do not claim cross-language support because tests produce Ruby AST node
  names for non-Ruby code.
- Do not keep expanding `ast.rb` as a universal normalization file.

## Current Problem

`gems/decomplex/lib/decomplex/ast.rb` is 4,023 lines and currently combines:

- AST facade helpers.
- Tree-sitter grammar adaptation.
- Ruby AST compatibility output.
- Ruby local/scope semantics.
- Shared cross-language normalization.
- Source span reconstruction.

`gems/decomplex/src/decomplex/ast.rs` is 8,642 lines and mirrors the same
architectural mistake. Rust currently has `syntax/tree_sitter_adapter.rs` with
a `LanguageProfile` trait, but AST normalization itself is still a single
large enum-driven file.

The first implementation target is Ruby because Ruby owns the legacy behavior
and the existing detector contracts. Once Ruby has a clean boundary, Rust can
mirror the structure without copying the monolith.

## Target Ruby File Layout

The Ruby implementation should move toward this structure:

```text
gems/decomplex/lib/decomplex/ast.rb
gems/decomplex/lib/decomplex/ast/node.rb
gems/decomplex/lib/decomplex/ast/span.rb
gems/decomplex/lib/decomplex/ast/source_map.rb
gems/decomplex/lib/decomplex/ast/semantic_node.rb
gems/decomplex/lib/decomplex/ast/semantic_normalizer.rb
gems/decomplex/lib/decomplex/ast/ruby_compat.rb
gems/decomplex/lib/decomplex/ast/adapters/base.rb
gems/decomplex/lib/decomplex/ast/adapters/ruby.rb
gems/decomplex/lib/decomplex/ast/adapters/python.rb
gems/decomplex/lib/decomplex/ast/adapters/lua.rb
gems/decomplex/lib/decomplex/ast/adapters/typescript.rb
```

`ast.rb` should become a facade and compatibility entry point. It should not
contain language-specific grammar tables or semantic rewrites.

## Target Rust File Layout

Rust should mirror Ruby after the Ruby boundary is correct:

```text
gems/decomplex/src/decomplex/ast/mod.rs
gems/decomplex/src/decomplex/ast/node.rs
gems/decomplex/src/decomplex/ast/span.rs
gems/decomplex/src/decomplex/ast/source_map.rs
gems/decomplex/src/decomplex/ast/semantic_node.rs
gems/decomplex/src/decomplex/ast/semantic_normalizer.rs
gems/decomplex/src/decomplex/ast/ruby_compat.rs
gems/decomplex/src/decomplex/ast/adapters/mod.rs
gems/decomplex/src/decomplex/ast/adapters/ruby.rs
gems/decomplex/src/decomplex/ast/adapters/python.rs
gems/decomplex/src/decomplex/ast/adapters/lua.rs
gems/decomplex/src/decomplex/ast/adapters/typescript.rs
```

Rust should not receive a large redesign before Ruby is stabilized. The Rust
work is a mirror step, not an independent architecture experiment.

## Line-of-Code Budgets

These budgets are guardrails. They are not strict limits, but exceeding them
should trigger review.

| Component | Target LoC |
|---|---:|
| `ast.rb` facade | 50-150 |
| `node.rb` | 50-120 |
| `span.rb` / `source_map.rb` | 100-250 total |
| `semantic_node.rb` | 100-250 |
| `semantic_normalizer.rb` | 400-800 |
| `ruby_compat.rb` | 400-900 |
| Base adapter contract | 150-300 |
| Ruby adapter | 400-700 |
| Python adapter | 250-400 |
| TypeScript/JavaScript adapter | 250-450 |
| Lua adapter | 150-300 |
| Each later language adapter | 200-500 |

If a language adapter grows past roughly 700 lines, either the shared semantic
contract is too weak or detector logic has leaked into the adapter. If the
shared normalizer grows past roughly 800 lines, it is probably becoming the new
monolith.

## Semantic Model

The detector-facing model must not be Ruby AST names. It should represent
cross-language concepts directly.

Minimum semantic node/fact types:

- `Root`
- `Owner`
- `Function`
- `Parameter`
- `Block`
- `Call`
- `MemberAccess`
- `Subscript`
- `Assignment`
- `Identifier`
- `Literal`
- `Branch`
- `Loop`
- `Case`
- `CaseArm`
- `Return`
- `Break`
- `Continue`
- `BooleanOp`
- `Comparison`
- `UnaryOp`
- `BinaryOp`
- `Lambda`
- `ExceptionHandler`
- `Finally`
- `Unknown`

Every semantic node should carry:

- `type`
- `children`
- `span`
- `text`
- `language`
- optional metadata, such as `name`, `receiver`, `message`, `operator`,
  `parameters`, `visibility`, `owner`, `control`, or `capability_gap`.

The shared semantic model can preserve source text, but it should not depend
on source text to discover language constructs.

## Adapter Contract

Each language adapter should classify native Tree-sitter nodes into semantic
facts. The shared normalizer should ask the adapter for meaning instead of
matching grammar strings directly.

Required adapter methods:

```ruby
function_definition(node)
owner_definition(node)
parameters(node)
call(node)
member_access(node)
subscript(node)
assignment(node)
branch(node)
loop(node)
case_expression(node)
case_arm(node)
return_statement(node)
break_statement(node)
continue_statement(node)
literal(node)
identifier(node)
boolean_operation(node)
comparison(node)
unary_operation(node)
binary_operation(node)
lambda_expression(node)
exception_handler(node)
finally_clause(node)
block(node)
ignored_node?(node)
```

Each method returns either:

- a semantic descriptor,
- `nil` when the node is not that construct,
- or a capability-gap object when the language construct is recognized but not
  implemented yet.

The base adapter should not contain Ruby token checks, shared operator tables,
or broad fallback grammar heuristics. It should mostly define the contract,
safe node access helpers, and common descriptor structs.

## Ruby Adapter Responsibilities

The Ruby adapter owns Ruby grammar and Ruby semantics:

- `def`, singleton methods, inline `def`.
- `class`, `module`, singleton class.
- `yield`, `super`, `block_argument`.
- `&.` safe navigation.
- Ruby block and lambda syntax.
- Ruby `case`/`when`.
- Ruby `rescue`/`ensure`.
- Ruby local variable discovery and bare-call resolution.
- `VCALL`, `FCALL`, `DVAR`, `DASGN`, and `SCOPE` if needed for compatibility.
- Ruby symbols, globals, instance variables, class variables.
- Ruby hash key shorthand.
- Ruby `=~` behavior.
- Implicit nil and tail-return elision.
- Visibility calls such as `private`, `protected`, `public`,
  `module_function`, and `private_class_method`.

None of these should live in shared normalizer code.

## Ruby Compatibility Boundary

Existing Ruby detectors currently depend on Ruby AST-like node names such as:

- `DEFN`, `DEFS`, `SCOPE`
- `CALL`, `QCALL`, `FCALL`, `VCALL`, `OPCALL`
- `LASGN`, `IASGN`, `DASGN`
- `LVAR`, `DVAR`, `IVAR`, `GVAR`
- `IF`, `UNLESS`, `CASE`, `WHEN`
- `RETURN`, `BREAK`, `NEXT`

Those names can remain temporarily, but only behind a Ruby compatibility
adapter:

```text
Tree-sitter Ruby nodes
  -> Ruby adapter descriptors
  -> semantic nodes
  -> Ruby compatibility nodes for legacy detectors
```

New or migrated cross-language detectors should consume semantic nodes/facts:

```text
Tree-sitter language nodes
  -> language adapter descriptors
  -> semantic nodes
  -> detector facts
```

This separation is what makes the system truly cross-language.

## Implementation Phases

### Phase 1: Split Non-Language Infrastructure

Create these files without changing behavior:

- `ast/node.rb`
- `ast/span.rb`
- `ast/source_map.rb`
- `ast/adapters/base.rb`

Move only mechanical infrastructure:

- `Node`
- `node?`
- `slice`
- source span construction
- parent/child safe access helpers
- normalized cache helpers

Acceptance criteria:

- Ruby tests still pass.
- `ast.rb` becomes a facade for existing behavior.
- No semantic changes yet.

### Phase 2: Extract Ruby Adapter

Move Ruby-specific syntax and semantics out of `TreeSitterNormalizer` into
`ast/adapters/ruby.rb`.

Initial Ruby adapter methods should cover:

- functions and singleton functions
- owners
- calls and safe calls
- assignments
- identifiers and locals
- blocks/lambdas
- branch/case/loop
- rescue/ensure
- literals
- parameters

Acceptance criteria:

- No `ruby?` branch remains in shared normalizer.
- Ruby-specific token checks are in `RubyAdapter`.
- Ruby tests pass.
- Existing Ruby detector output is unchanged.

### Phase 3: Introduce Semantic Nodes

Add `ast/semantic_node.rb` and `ast/semantic_normalizer.rb`.

The semantic normalizer should:

- walk Tree-sitter nodes,
- ask the adapter for descriptors,
- emit semantic nodes,
- preserve spans and text,
- avoid language-specific grammar strings.

Acceptance criteria:

- Ruby semantic fixtures pass.
- Ruby compatibility output can be generated from semantic nodes.
- Shared semantic code contains no Ruby-specific behavior.

### Phase 4: Move Legacy Ruby AST Output Behind Compatibility

Create `ast/ruby_compat.rb`.

This layer converts Ruby semantic nodes to the legacy Ruby AST-like nodes
needed by existing detectors.

Acceptance criteria:

- `Ast.parse(file)` still returns the legacy shape for Ruby until detectors
  migrate.
- Internally, Ruby Tree-sitter nodes no longer flow through a shared
  Ruby-shaped normalizer.
- All current Ruby detector tests pass.

### Phase 5: Add Detector-Facing Semantic API

Add a new API alongside `Ast.parse`:

```ruby
Ast.parse_semantic(file, language: nil)
```

or equivalent through `Syntax.parse`.

Acceptance criteria:

- Cross-language detectors can use semantic facts without Ruby compatibility
  nodes.
- At least one detector is ported to the semantic API as proof.
- Semantic facts include source spans and file/method context.

### Phase 6: Extract Existing Non-Ruby Adapters

Move the current Python, Lua, and TypeScript logic into adapter files. During
this phase, do not try to make every detector perfect for every language.
Focus on correct adapter ownership.

Acceptance criteria:

- Python/Lua/TypeScript grammar quirks are not in shared normalizer code.
- Unsupported features are explicit capability gaps.
- Existing non-Ruby smoke tests either pass or fail with intentional,
  documented unsupported-feature assertions.

### Phase 7: Rust Mirror

After Ruby is correct, mirror the structure in Rust:

- split `ast.rs`,
- replace `TreeSitterNormalizationAdapter` enum with an adapter trait,
- move language logic to `ast/adapters/*.rs`,
- keep Rust behavior matched to Ruby fixtures.

Acceptance criteria:

- Rust remains behaviorally equivalent for Ruby.
- Rust test files are separate from implementation files.
- Rust adapter files follow the same contract as Ruby.

## Detector Migration Strategy

Detectors fall into three categories.

### Category A: Can Move to Semantic Facts Early

These mostly need functions, branches, calls, assignments, and spans:

- weighted inlined cognitive complexity
- structural topology
- local flow
- temporal ordering pressure
- state branch density
- sequence mining
- path condition
- oversized predicate

### Category B: Needs Ruby Compatibility During Migration

These depend on Ruby-specific node names or Ruby semantics:

- predicate alias
- semantic alias
- redundant nil guard
- false simplicity
- ordered protocol mining
- derived state
- decision pressure
- state mesh
- fat union

### Category C: Should Stay Ruby-Specific Unless Redesigned

Any detector relying on Ruby-only language semantics should explicitly declare
Ruby-only support until it is redesigned.

Examples:

- Ruby visibility wrappers.
- Ruby metaprogramming shapes.
- Ruby `nil?` and safe-navigation-specific analyses.
- Ruby local-vs-call semantics.

## Salvage Plan for `ast.rb`

Expected salvage from the current 4,023 lines:

| Portion | Approximate fate |
|---|---|
| `Node`, cache, `slice`, `node?` | Keep, move to small files |
| Source span helpers | Keep, move to `source_map.rb` |
| `flatten_and`, `def_push`, `body_stmts`, `canon_polarity` | Keep temporarily, then migrate to semantic helpers |
| Ruby scope/local/vcall logic | Keep only in Ruby adapter or Ruby compatibility |
| Ruby inline def/tail return/implicit nil | Keep only in Ruby compatibility |
| Python/Lua/TypeScript shape helpers | Move to adapter files, then rewrite where token mining is unsafe |
| Giant `normalize_node` dispatch | Delete/rewrite |
| Global grammar kind tables | Delete/move into adapters |
| `ruby?` predicate model | Delete |
| Generic fallback adapter | Delete |
| Broad `rescue StandardError` shape checks | Replace with explicit nil-safe helpers |

Realistically:

- 10-15% is directly reusable cross-language infrastructure.
- 25-35% is salvageable Ruby compatibility behavior.
- 15-20% is reusable as adapter seeds.
- 50% or more should be deleted or rewritten.

## Testing Requirements

### Ruby Must Stay Byte-for-Byte Compatible Where Legacy Requires It

Before changing behavior, capture current Ruby detector output fixtures for:

- report sections,
- state branch density,
- structural topology,
- weighted inlined cognitive complexity,
- redundant nil guard,
- false simplicity,
- local flow,
- temporal ordering pressure.

Ruby compatibility output should remain unchanged until a detector is
explicitly migrated.

### Semantic Fixtures

Add language-independent semantic fixtures for:

- function with parameters,
- method/member call,
- receiverless call,
- assignment,
- branch,
- loop,
- case/match/switch,
- boolean and comparison operations,
- return/break/continue,
- exception/finally,
- lambda/block,
- subscript,
- literal families.

Each fixture should assert semantic facts, not Ruby AST node names.

### Adapter Ownership Tests

Add tests that fail if shared normalizer code learns language-specific tokens.
Examples:

- no `ruby?` in shared normalizer,
- no `"def"`/`"function"` keyword checks in shared normalizer,
- no `&.`/`?.` checks in shared normalizer,
- no language assignment-operator tables in shared normalizer,
- no silent default adapter for supported languages.

## Completion Criteria

The Ruby implementation is complete only when all of these are true:

- `ast.rb` is a small facade, not a monolith.
- Ruby-specific grammar and semantic behavior live in `adapters/ruby.rb` or
  `ruby_compat.rb`.
- Shared normalizer code has no `ruby?` branches.
- Shared normalizer code does not inspect Ruby keyword/operator tokens.
- There is an explicit semantic model for detector-facing cross-language
  support.
- `Ast.parse` is compatibility-only; production detectors do not call it.
- `Ast.parse_semantic` is compatibility-only; production detectors consume
  `Syntax` facts directly.
- Ruby production detectors consume semantic facts instead of Ruby AST node
  names.
- Unsupported language features are represented as explicit capability gaps.
- Ruby tests pass.
- Relevant cross-language semantic fixtures pass.
- Rust has not diverged; it is either unchanged pending mirror work or updated
  minimally to match the Ruby architecture.

Do not report the Ruby implementation as finished before these criteria are
satisfied.

## Reporting Protocol

During implementation, report status by phase:

- completed files,
- behavior preserved,
- tests run,
- remaining architectural blockers.

Only report "Ruby implementation complete" when the completion criteria above
are satisfied. Until then, report partial progress as partial progress.
