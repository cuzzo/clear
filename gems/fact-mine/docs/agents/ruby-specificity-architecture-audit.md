# FactMine Ruby Specificity Architecture Audit

Date: 2026-06-21

This is an actionable violation ledger. It lists the concrete Ruby-specific
problems currently present in the Ruby and Rust FactMine implementations, why
each problem is wrong, and the specific fix.

Scope:

- Production implementation files scanned:
  - `gems/fact-mine/lib/fact_mine/**/*.rb`
  - `gems/fact-mine/rust/src/**/*.rs`
- Test files were scanned separately for architecture-enforcing mistakes.
- Central language registries are allowed to mention Ruby only for dispatch.
- Language-owned files are allowed to mention Ruby:
  - Ruby: `syntax/ruby.rb`, `ast/adapters/ruby.rb`, future `ast/ruby_compat.rb`
  - Rust: `syntax/adapters/ruby.rs`, `ast/adapters/ruby.rs`, future `ast/ruby_compat.rs`

## Executive Summary

### Recurring Problems

| Pattern | Where it repeats | Why it keeps causing bad implementations |
|---|---|---|
| RubyVM/ParseTree compatibility is treated as "normalized" syntax | Rust `ast.rs`, Rust `normalized_extractor.rs`, Rust local-flow/path/nil-guard consumers, Ruby `legacy_normalizer.rb`, Ruby `ast.rb` helpers | The shared system is not actually language-neutral. Other languages are forced to imitate Ruby AST node names instead of emitting source facts. |
| Literal Ruby behavior is hidden in generic files | Rust `ruby_metadata.rs`, Rust `tree_sitter_adapter.rs`, Rust `local_flow.rs`, Ruby `syntax/effects.rb`, Ruby `syntax/protocols.rb`, Ruby `clone_similarity.rb` | Reviewers can look at `syntax/adapters/ruby.rs` or `syntax/ruby.rb` and miss real Ruby behavior elsewhere. |
| Generic files branch on concrete languages | Rust `tree_sitter_adapter.rs`, Rust `passes.rs`, Rust `local_flow.rs`, Ruby `syntax.rb`, Ruby `ast/adapters/base.rb` | The framework becomes a switch statement instead of a contract. Every new language adds more branches. |
| Shared extractors consume concrete node spellings | Rust `normalized_extractor.rs`, Rust `path_condition.rs`, Rust `redundant_nil_guard.rs`, Rust `local_flow.rs`, Ruby `ast.rb` helpers | The "generic extractor" is coupled to one compatibility vocabulary. It cannot stay generic. |
| Language vocabulary is stored in engine modules | Ruby `syntax/effects.rb`, Ruby `syntax/protocols.rb`, Rust `false_simplicity_lexicon.rs` | Engine code owns language data, so adding languages edits engines instead of language files. |
| Metadata model names are Ruby/Sorbet-shaped | `immutable_struct_readers`, `T::Struct`, `sig`, `T.type_alias` in Ruby and Rust | The model conflates generic immutable reader/type facts with Ruby Sorbet syntax. |
| Ruby is the default when language is unknown | Ruby `Syntax.language_for`, `FactDocument` | Unsupported input silently becomes Ruby. That hides missing language support and corrupts fixtures. |
| Tests assert RubyVM compatibility instead of semantic facts | Rust `ast-test.rs`, Rust `architecture_test.rs` | The tests protect the wrong boundary, so regressions toward Ruby-shaped generic code look like passing architecture. |

### Recurring Solutions

| Solution | Applies to | Concrete result |
|---|---|---|
| Replace RubyVM-shaped normalization with a semantic source-fact schema | Rust production source facts first, Ruby raw fallback second | Generic extraction consumes `Function`, `Call`, `Assignment`, `StateRead`, `Branch`, etc., not `DEFN`, `FCALL`, `IASGN`, `ITER`. |
| Move all language-specific code/data behind language files | Ruby and Rust | Ruby behavior lives in `syntax/ruby.rb`, `syntax/adapters/ruby.rs`, or explicitly named `ruby_compat` files only. |
| Make adapters return descriptors/events, not detector facts | Ruby and Rust adapters | Adapters answer "what concrete shape is this?" Shared passes do the traversal and extraction. |
| Add shared metadata events | Sorbet today, Python/TS/PHP later | Ruby parses `sig`/`T::Struct`; shared code stores `method_param_type`, `immutable_reader`, `type_alias`. |
| Add shared dynamic-language machinery in Rust | Rust, mirroring Ruby `dynamic_language.rb` | Ruby/Python/Lua/JS/PHP/Perl reuse local-flow, path-condition, predicate, dynamic call/state logic. |
| Delete or quarantine compatibility AST code | Ruby `legacy_normalizer.rb`, Rust `ast.rs` production dependency | Compatibility cannot be on the production source-fact path. |
| Invariant-test both literal tokens and structural schema tokens | Ruby and Rust | Tests fail on hidden `ruby_`, `T::Struct`, `Language::Ruby`, and RubyVM node names in generic code. |
| Replace RubyVM parity tests with semantic oracle tests | Rust `ast-test.rs`, cross-language fixtures | Python/Lua/JS/PHP should prove they emit semantic facts, not that they can masquerade as Ruby AST. |

## Required New Files, Systems, And Passes

### Rust: `syntax/semantic.rs`

Purpose:

- Define the production normalized schema.
- Replace RubyVM node names with semantic concepts.

Minimum model:

```text
SemanticDocument
SemanticNode::{Root, Owner, Function, Parameter, Block, Statement}
SemanticExpr::{Identifier, Literal, Call, MemberAccess, Subscript}
SemanticControl::{Branch, BranchArm, Loop, Case, CaseArm}
SemanticMutation::{Assignment, StateRead, StateWrite, StateDeclaration}
SemanticEvent::{Visibility, Metadata}
```

Solves:

- Rust `normalized_extractor.rs` no longer depends on `DEFN`, `FCALL`, `IASGN`, `ITER`, etc.
- New languages normalize to source facts instead of Ruby AST compatibility.

### Rust: `syntax/semantic_normalizer.rs`

Purpose:

- Walk Tree-sitter nodes once.
- Ask the language profile for semantic descriptors.
- Build `SemanticDocument`.

Solves:

- Moves production Ruby source facts off `ast.rs`.
- Prevents every language from needing a custom fact extractor.

### Rust: `syntax/semantic_extractor.rs`

Purpose:

- Consume only `SemanticDocument`.
- Emit `Document` fact sections.

Solves:

- Replaces `syntax/normalized_extractor.rs` as the production extractor.
- Makes fact extraction genuinely language-neutral.

### Rust: `syntax/dynamic.rs`

Purpose:

- Mirror Ruby `syntax/dynamic_language.rb`.
- Provide shared algorithms for dynamic-language predicate extraction, local-flow summaries, path conditions, dynamic call/state handling, and local scope traversal.

Solves:

- Rust currently lacks the reusable dynamic-language machinery Ruby already has.
- Prevents Ruby/Python/Lua/JS/PHP/Perl adapters from each reimplementing local-flow/path-condition traversal.

### Rust: `syntax/metadata.rs`

Purpose:

- Define generic metadata events:
  - `MethodParamType`
  - `TypeAlias`
  - `ImmutableReader`
  - `ImmutableReaderType`

Solves:

- Moves Sorbet-specific parsing out of generic `ruby_metadata.rs`.
- Allows Python dataclasses/attrs, TypeScript readonly/types, PHP readonly properties, and future Perl object metadata to feed the same model.

### Rust: `syntax/adapters/ruby.rs`

Purpose after refactor:

- Own Ruby grammar setup.
- Own Ruby semantic descriptors.
- Own Ruby metadata parsing from `sig`, `T::Struct`, `T.type_alias`, `T.let`.
- Own Ruby lexicons.

Solves:

- Makes buried Ruby visible.
- Makes current 12-LoC parser-only Ruby adapter honest.

### Ruby: `syntax/semantic.rb`

Purpose:

- Mirror the Rust semantic model if Ruby raw parsing remains supported.

Solves:

- Ruby raw fallback and Rust native facts can be compared at the semantic layer.
- Ruby raw code stops using Tree-sitter raw facts as detector facts.

### Ruby: `syntax/metadata.rb`

Purpose:

- Store shared metadata event model.
- Keep Ruby Sorbet syntax parsing in `syntax/ruby.rb`.

Solves:

- Renames Ruby/Sorbet-specific `immutable_struct_*` model into generic immutable/type metadata.

### Ruby: `ast/ruby_compat.rb`

Purpose:

- If public API compatibility requires `Ast.parse`, move legacy Ruby AST output here.

Solves:

- `legacy_normalizer.rb` stops looking like generic infrastructure.
- `FactMine::Ast` can be optional compatibility, not default source-fact infrastructure.

### Invariant Tests

Purpose:

- Enforce zero language-specific code outside language-owned files.
- Enforce that tests do not assert generic languages should match RubyVM-shaped trees.

Required checks:

- Literal scans for `ruby_`, `Ruby`, `Language::Ruby`, `T::Struct`, `T.type_alias`, `sig`.
- Structural scans for RubyVM node names in generic source-fact modules: `DEFN`, `DEFS`, `FCALL`, `VCALL`, `IASGN`, `GASGN`, `DASGN`, `DVAR`, `ITER`, `SCOPE`, `ATTRASGN`, `OPCALL`, `QCALL`, `SCLASS`.
- Allow only central registries to name language modules/enums, and only for dispatch.
- Forbid `assert_ruby_parity`, `matches_ruby`, and test names/messages that require non-Ruby languages to match Ruby AST shape outside explicit `ruby_compat` tests.

## Rust Violations

### RUST-01: Active Ruby source facts depend on `ast.rs`

Location:

- `rust/src/syntax/tree_sitter_adapter.rs:58`
- `rust/src/syntax/tree_sitter_adapter.rs:252`
- `rust/src/ast.rs`

Problem:

- Ruby `syntax-facts` special-cases Ruby and calls `normalize_tree(..., Language::Ruby)`.
- That normalizer emits RubyVM/ParseTree compatibility nodes.

Why wrong:

- This is the production Ruby fact compiler.
- Production normalization is not semantic; it is Ruby compatibility.
- Every future language is pressured to normalize into Ruby AST names.

Solution:

- Add `syntax/semantic_normalizer.rs`.
- Route Ruby `syntax-facts` through semantic normalization.
- Keep `ast.rs` only for explicit compatibility APIs or delete it from production.

### RUST-02: `ast.rs` is a monolithic RubyVM compatibility compiler

Location:

- `rust/src/ast.rs`

Problem:

- Emits `DEFN`, `DEFS`, `FCALL`, `VCALL`, `IASGN`, `GASGN`, `DASGN`, `DVAR`, `ITER`, `SCOPE`, `ATTRASGN`, `QCALL`, `OPCALL`, `SCLASS`, `MATCH3`, and other RubyVM-shaped nodes.
- Contains Ruby local scope and local-vs-call semantics:
  - `with_ruby_scope`
  - `ruby_scope_locals`
  - `ruby_vcall_identifier`
  - `ruby_definition_identifier`
  - `ruby_assignment_node`
  - `ruby_instance_variable_text`
  - `ruby_variable_name_text`

Why wrong:

- It hides Ruby behavior in a generic file.
- It gives the generic extractor a Ruby-shaped input contract.
- It is too large to review as an adapter boundary.

Solution:

- Remove `ast.rs` from production source facts.
- If legacy AST output remains, split it into:
  - `ast/ruby_compat.rs`
  - `ast/adapters/ruby.rs`
  - generic source-map/node helpers only.
- Do not use it as normalized source-fact schema.

### RUST-03: `normalized_extractor.rs` is generic by name but Ruby-shaped by schema

Location:

- `rust/src/syntax/normalized_extractor.rs:82`
- `rust/src/syntax/normalized_extractor.rs:87`
- `rust/src/syntax/normalized_extractor.rs:92`
- `rust/src/syntax/normalized_extractor.rs:680`
- `rust/src/syntax/normalized_extractor.rs:752`
- `rust/src/syntax/normalized_extractor.rs:1091`

Problem:

- Extracts facts from RubyVM node names:
  - functions: `DEFN`, `DEFS`
  - calls: `CALL`, `QCALL`, `FCALL`, `VCALL`
  - state: `IASGN`, `GASGN`, `IVAR`, `GVAR`, `ATTRASGN`
  - blocks: `ITER`, `SCOPE`

Why wrong:

- It is not language-neutral extraction.
- It is a RubyVM AST interpreter.
- Invariants scanning for `Ruby` do not catch it.

Solution:

- Replace with `syntax/semantic_extractor.rs`.
- New extractor matches semantic enum variants, not strings.
- Add invariant forbidding RubyVM node names in production generic syntax modules.

### RUST-04: Sorbet/Ruby metadata is hidden in `ruby_metadata.rs`

Location:

- `rust/src/syntax/ruby_metadata.rs`
- `rust/src/syntax.rs:12`
- `rust/src/syntax/passes.rs:2`
- `rust/src/syntax/passes.rs:31`
- `rust/src/syntax/passes.rs:72`
- `rust/src/syntax/tree_sitter_adapter.rs:3`
- `rust/src/syntax/tree_sitter_adapter.rs:1247`
- `rust/src/syntax/tree_sitter_adapter.rs:1613`

Problem:

- Generic syntax modules import `ruby_metadata`.
- Sorbet syntax parsing lives outside the Ruby adapter.
- Stateful pass returns a `ruby` metadata field.

Why wrong:

- Ruby-specific syntax is hidden in generic pass/orchestration modules.
- It blocks other languages from feeding equivalent metadata without more branches.

Solution:

- Move Sorbet parsing into `syntax/adapters/ruby.rs` or `syntax/adapters/ruby/metadata.rs`.
- Add generic `syntax/metadata.rs`.
- `StatefulSyntaxPass` should call `profile.metadata_events(source, functions)`.
- Output generic metadata fields, not `ruby: RubyMetadata`.

### RUST-05: `tree_sitter_adapter.rs` owns Ruby semantic special cases

Location:

- `rust/src/syntax/tree_sitter_adapter.rs:1235`
- `rust/src/syntax/tree_sitter_adapter.rs:1246`
- `rust/src/syntax/tree_sitter_adapter.rs:1282`
- `rust/src/syntax/tree_sitter_adapter.rs:1452`
- `rust/src/syntax/tree_sitter_adapter.rs:1612`

Problem:

- Branch-state refs treat Ruby fields differently.
- Immutable Sorbet reads are filtered in raw extraction.
- Nested branch state refs are Ruby-only.
- Function context reads Ruby `sig` param types.

Why wrong:

- Parser/orchestration code is doing language semantics.
- This creates one-off branches that future languages will copy.

Solution:

- Move this into semantic normalization and metadata events.
- Branch-state collection should consume normalized `StateRead` facts plus metadata.
- Parser adapter should only parse and invoke passes.

### RUST-06: `passes.rs` has a Ruby-specific stateful pass output

Location:

- `rust/src/syntax/passes.rs:31`
- `rust/src/syntax/passes.rs:68`
- `rust/src/syntax/passes.rs:72`

Problem:

- `StatefulSyntaxMetadata` has a `ruby` field.
- `StatefulSyntaxPass` branches on `Language::Ruby`.

Why wrong:

- The pass is not generic.
- New languages will add more fields or branches.

Solution:

- Replace `ruby` with generic metadata collections.
- Pass asks the profile for metadata events.
- Shared pass stores generic metadata maps.

### RUST-07: Raw local-flow fallback contains Ruby branches

Location:

- `rust/src/syntax/local_flow.rs:123`
- `rust/src/syntax/local_flow.rs:374`
- `rust/src/syntax/local_flow.rs:404`
- `rust/src/syntax/local_flow.rs:596`
- `rust/src/syntax/local_flow.rs:619`
- `rust/src/syntax/local_flow.rs:818`
- `rust/src/syntax/local_flow.rs:1018`
- `rust/src/syntax/local_flow.rs:1051`
- `rust/src/syntax/local_flow.rs:1067`

Problem:

- Raw local flow branches on Ruby and Python.
- Ruby textual writes and assertion argument exclusions live in the generic module.

Why wrong:

- Local-flow should consume semantic local read/write facts.
- Raw fallback becomes a second language-specific extractor.

Solution:

- Move raw fallback behind language descriptors while it exists.
- Long-term: delete raw fallback after semantic normalization.
- Implement shared `syntax/dynamic.rs` and feed local-flow from semantic statement/read/write facts.

### RUST-08: Rust local-flow/path/nil-guard consumers depend on RubyVM node names

Location:

- `rust/src/syntax/local_flow.rs:60`
- `rust/src/syntax/local_flow.rs:1553`
- `rust/src/syntax/path_condition.rs:625`
- `rust/src/syntax/path_condition.rs:663`
- `rust/src/syntax/redundant_nil_guard.rs:899`
- `rust/src/syntax/redundant_nil_guard.rs:940`
- `rust/src/syntax/redundant_nil_guard.rs:1034`
- `rust/src/syntax/redundant_nil_guard.rs:1218`
- `rust/src/syntax/redundant_nil_guard.rs:1398`

Problem:

- These modules match `DEFN`, `DEFS`, `SCOPE`, `FCALL`, `VCALL`, `LASGN`, `IASGN`, `OPCALL`, `QCALL`, etc.

Why wrong:

- Detector-support modules are tied to RubyVM compatibility nodes.
- Even if `normalized_extractor.rs` is replaced, these modules keep the Ruby schema alive.

Solution:

- Port them to semantic facts:
  - local flow consumes semantic method statements/read/write sets,
  - path condition consumes semantic branch/action facts,
  - nil guard consumes semantic nil-check and assignment facts.
- Add invariant forbidding RubyVM node names in these modules after migration.

### RUST-09: `complexity.rs` has a Ruby-specific duplicate token hack

Location:

- `rust/src/syntax/complexity.rs:100`
- `rust/src/syntax/complexity.rs:281`

Problem:

- Generic complexity scorer calls `duplicate_ruby_early_exit_token`.

Why wrong:

- A generic scorer should not know Ruby parser token duplication.
- This is a normalization bug leaking into a metric.

Solution:

- Fix normalization so duplicate early-exit tokens do not enter semantic bodies.
- Delete the Ruby-specific filter.

### RUST-10: Clone similarity has Sorbet-specific filtering

Location:

- `rust/src/syntax/clone_similarity.rs:488`

Problem:

- Generic clone similarity skips `T::Struct` schemas by string matching.

Why wrong:

- Clone detection should not know Sorbet.
- Other languages will need schema/data declaration exclusions too.

Solution:

- Add semantic `schema_declaration` or `low_signal_declaration` metadata.
- Language adapter marks Ruby `T::Struct` schema regions.
- Clone engine consumes the generic marker.

### RUST-11: False-simplicity lexicons are centralized instead of language-owned

Location:

- `rust/src/syntax/adapters/false_simplicity_lexicon.rs:32`
- `rust/src/syntax/adapters/false_simplicity_lexicon.rs:96`
- `rust/src/syntax/adapters/false_simplicity_lexicon.rs:257`
- `rust/src/syntax/adapters/false_simplicity_lexicon.rs:313`

Problem:

- Ruby API vocabulary lives in a shared lexicon file.

Why wrong:

- Language vocabulary is language-specific code.
- Adding a language requires editing a shared lexicon switch.

Solution:

- Move Ruby entries to `syntax/adapters/ruby.rs`.
- `LanguageProfile` exposes `effect_lexicon()` or `false_simplicity_lexicon()`.
- Shared effect engine consumes the profile-provided lexicon.

### RUST-12: AST adapter base imports Ruby helper and Ruby operators

Location:

- `rust/src/ast/adapters/base.rs:5`
- `rust/src/ast/adapters/base.rs:19`
- `rust/src/ast/adapters/base.rs:39`
- `rust/src/ast/adapters/base.rs:331`

Problem:

- Base adapter imports `ruby_exception_constant_text`.
- Base adapter defines `RUBY_ASSIGNMENT_OPERATORS`.
- Base adapter exposes `ruby()`.

Why wrong:

- Base adapter is supposed to be language-neutral.
- Ruby-specific exception and assignment semantics belong in Ruby adapter or compatibility code.

Solution:

- Move Ruby constants/helpers into `ast/adapters/ruby.rs`.
- Replace `ruby()` with capability hooks that are implemented by adapters.
- If AST compatibility is removed from production, quarantine this under `ast/ruby_compat`.

### RUST-13: Central registry is currently acceptable only as registry

Location:

- `rust/src/syntax.rs:25`
- `rust/src/syntax.rs:45`
- `rust/src/syntax.rs:66`
- `rust/src/syntax.rs:86`
- `rust/src/syntax/adapters/mod.rs:56`
- `rust/src/ast/adapters/mod.rs:55`

Problem:

- Central files name Ruby.

Why wrong if expanded:

- Central files may route to languages, but must not encode language semantics.

Solution:

- Keep only enum/extension/adapter dispatch here.
- Invariants must allow central registry mentions but forbid behavior branches.

## Rust Test And Invariant Violations

These are not production implementation LoC, but they are architecture root
causes. They explain how the implementation got this far while still passing
tests.

### RUST-TEST-01: `ast-test.rs` enforces RubyVM compatibility as the cross-language oracle

Location:

- `rust/src/ast-test.rs`

Problem:

- The file is about 20,852 lines.
- It contains `assert_ruby_parity`.
- It contains hundreds of helpers named `ruby_private_*`.
- It includes non-Ruby tests whose names and messages require Python and Lua to match Ruby AST shape:
  - `python_yield_statement_in_multi_statement_block_matches_ruby_ast`
  - `python_annotation_type_wrappers_match_ruby_tree_shape`
  - `python_single_if_block_under_try_matches_ruby_if_shape`
  - `lua_local_assignment_call_rhs_matches_ruby_expression_list_shape`
  - `lua_single_assignment_function_body_matches_ruby_lasgn_shape`
  - `lua_single_return_function_body_matches_ruby_opcall_shape`

Why wrong:

- The tests make RubyVM compatibility the success criterion for all languages.
- They explain why Ruby-specific AST terms leaked into generic Rust code and stayed there.
- They prevent semantic normalization from being the stable contract.

Solution:

- Move the existing tests under explicit `ast/ruby_compat` coverage if compatibility output must remain.
- Create semantic oracle fixtures for each shared concept:
  - function definition,
  - call,
  - assignment,
  - state read/write,
  - branch,
  - loop,
  - block/lambda,
  - metadata.
- For non-Ruby languages, assert semantic fact JSON, not Ruby AST shape.
- Delete cross-language `assert_ruby_parity` from production source-fact tests.

### RUST-TEST-02: Architecture tests currently preserve an obsolete parser-only Ruby adapter invariant

Location:

- `rust/src/architecture_test.rs:451`
- `rust/src/architecture_test.rs:680`

Problem:

- `ruby_syntax_profile_is_parser_only` requires `syntax/adapters/ruby.rs` to remain parser-only.
- The tests allow or reference `ruby_metadata.rs`.

Why wrong:

- The desired architecture now requires the Ruby adapter/profile to own Ruby descriptors, metadata parsing, and lexicons.
- Keeping the adapter parser-only forces Ruby behavior back into generic files.
- Allowing `ruby_metadata.rs` as a generic-side exception normalizes hidden Ruby code.

Solution:

- Replace this invariant with:
  - Ruby adapter may own descriptors, metadata syntax parsing, and Ruby lexicons.
  - Generic files may not contain Ruby behavior branches or RubyVM node names.
  - Generic files may call language profile hooks without naming Ruby.
- Remove `ruby_metadata.rs` as an allowed generic exception after moving it under the Ruby adapter boundary.

### RUST-TEST-03: Tests use Ruby-private helper parity instead of contract-level fact parity

Location:

- `rust/src/ast-test.rs:281`
- `rust/src/ast-test.rs:2300`
- `rust/src/ast-test.rs:16404`
- `rust/src/ast-test.rs:17006`

Problem:

- Tests compare internal helper behavior to Ruby private methods.
- Examples include normalizing calls, if/elsif, safe navigation, rescue, heredoc, assignment, and member access.

Why wrong:

- Internal helper parity locks in implementation shape.
- The correct invariant is external semantic fact equivalence.
- This makes refactoring impossible without preserving the same bad AST vocabulary.

Solution:

- Keep only public-output compatibility tests in `ruby_compat`.
- For source facts, compare final semantic/fact documents byte-for-byte.
- Do not test private normalizer helpers across language implementations.

## Ruby Violations

### RUBY-01: `legacy_normalizer.rb` is RubyVM compatibility in a generic AST namespace

Location:

- `lib/fact_mine/ast/legacy_normalizer.rb`

Problem:

- It emits RubyVM/ParseTree nodes (`DEFN`, `DEFS`, `FCALL`, `VCALL`, `IASGN`, `ITER`, `SCOPE`, etc.).
- It contains Ruby local/call, Ruby scopes, inline `def`, tail return elision, implicit nil, heredoc, `yield`, `super`, `DASGN`/`DVAR`, and Ruby operator behavior.

Why wrong:

- File name and namespace imply generic AST normalization.
- This is compatibility with Ruby, not a cross-language source-fact model.
- It is still required by `ast.rb` and loaded by `fact_mine.rb`.

Solution:

- Move to `ast/ruby_compat.rb` if `Ast.parse` must remain public.
- Otherwise delete from default load path.
- Production source facts must not call it.

### RUBY-02: `fact_mine.rb` requires the compatibility AST by default

Location:

- `lib/fact_mine.rb:4`
- `lib/fact_mine/ast.rb:31`

Problem:

- `fact_mine.rb` requires `fact_mine/ast`.
- `ast.rb` unconditionally requires `ast/legacy_normalizer`.

Why wrong:

- Compatibility code becomes default infrastructure.
- Hidden RubyVM compatibility remains loaded even when source facts do not need it.

Solution:

- Stop requiring `fact_mine/ast` from `fact_mine.rb`.
- Require AST compatibility only from callers that explicitly need `Ast.parse`.
- Rename the compatibility entrypoint.

### RUBY-03: `ast.rb` exposes RubyVM helper methods as shared helpers

Location:

- `lib/fact_mine/ast.rb:45`
- `lib/fact_mine/ast.rb:68`

Problem:

- `def_push` knows `DEFN`/`DEFS`.
- `body_stmts` knows `SCOPE`.

Why wrong:

- Generic AST facade knows RubyVM node layout.

Solution:

- Move to `ast/ruby_compat.rb`.
- Replace detector use with semantic function/body facts.

### RUBY-04: `ast/adapters/base.rb` contains Ruby adapter state

Location:

- `lib/fact_mine/ast/adapters/base.rb:15`
- `lib/fact_mine/ast/adapters/base.rb:94`
- `lib/fact_mine/ast/adapters/base.rb:112`

Problem:

- Base adapter defines `RUBY_ASSIGNMENT_OPERATORS`.
- Base adapter selects `RubyTreeSitterNormalizationAdapter`.
- Base adapter exposes `ruby?`.

Why wrong:

- Base adapter is not language-neutral.
- It keeps Ruby-specific behavior in the generic contract.

Solution:

- Move Ruby operators to `ast/adapters/ruby.rb`.
- Keep only registry selection in a small loader.
- Replace `ruby?` with adapter capabilities or remove AST compatibility.

### RUBY-05: `syntax.rb` silently defaults unknown languages to Ruby

Location:

- `lib/fact_mine/syntax.rb:2892`

Problem:

- `LANGUAGE_BY_EXTENSION.fetch(..., :ruby)`.

Why wrong:

- Unsupported files become Ruby.
- Missing language support hides instead of failing.

Solution:

- Return `nil` or raise `UnsupportedLanguageError`.
- Require explicit `DECOMPLEX_FORCE_LANGUAGE` for unknown extensions.

### RUBY-06: `TreeSitterAdapter#parse` special-cases Ruby native facts

Location:

- `lib/fact_mine/syntax.rb:3260`

Problem:

- Ruby path delegates to native `syntax-facts`; non-Ruby uses Ruby raw adapter path.

Why wrong:

- Runtime behavior differs by language in a generic adapter.
- It hides that Rust is the production Ruby compiler.

Solution:

- Make native-vs-ruby-engine selection explicit above the adapter.
- Adapter should parse/orchestrate one implementation, not switch language backends.

### RUBY-07: `FactDocument` defaults language to Ruby

Location:

- `lib/fact_mine/syntax/fact_document.rb:37`

Problem:

- Missing `language` in fact rows becomes `"ruby"`.

Why wrong:

- Missing data is silently interpreted as Ruby.
- Cross-language fixtures can pass accidentally.

Solution:

- Require `language` in serialized fact documents.
- Fail if missing.

### RUBY-08: Generic fact document model uses Ruby/Sorbet-shaped names

Location:

- `lib/fact_mine/syntax/fact_document.rb:45`
- `lib/fact_mine/syntax/fact_document.rb:46`
- `lib/fact_mine/syntax/fact_document.rb:222`
- `lib/fact_mine/syntax.rb:420`
- `lib/fact_mine/syntax.rb:424`
- `lib/fact_mine/syntax.rb:1888`

Problem:

- Generic model is named `immutable_struct_readers` and `immutable_struct_reader_types`.

Why wrong:

- "Struct" is Sorbet/Ruby-biased.
- Other languages have immutable/read-only metadata that is not a struct.

Solution:

- Rename generic model to `immutable_readers` and `reader_types`.
- Ruby adapter maps `T::Struct` to generic metadata events.
- Keep backward-compatible serialized aliases only at fact-file boundary if needed.

### RUBY-09: `syntax/effects.rb` owns Ruby effect lexicon

Location:

- `lib/fact_mine/syntax/effects.rb:89`
- `lib/fact_mine/syntax/effects.rb:142`
- `lib/fact_mine/syntax/effects.rb:194`
- `lib/fact_mine/syntax/effects.rb:441`

Problem:

- Generic effect engine contains `RUBY_EFFECT_LEXICON`.
- Generic effect engine has `ruby_net_receiver?`.

Why wrong:

- Language API vocabulary is language-specific.
- Engine code grows with every language.

Solution:

- Move Ruby lexicon and Ruby Net receiver handling into `syntax/ruby.rb`.
- `LanguageLexicon` or `EffectLexicon` comes from profile.
- Engine consumes only a lexicon object.

### RUBY-10: `syntax/protocols.rb` owns Ruby protocol vocabulary

Location:

- `lib/fact_mine/syntax/protocols.rb:11`
- `lib/fact_mine/syntax/protocols.rb:36`

Problem:

- Generic protocol engine contains Ruby/Sorbet/RSpec/Ruby DSL vocabulary:
  - `sig`
  - `private_class_method`
  - `type_member`
  - `type_template`
  - `describe`
  - `expect`
  - `raise_error`

Why wrong:

- Protocol engine owns Ruby vocabulary and test DSL policy.

Solution:

- Move Ruby protocol ignored/mutating/diagnostic vocabulary to `syntax/ruby.rb`.
- Shared protocol engine asks the profile for protocol lexicon.

### RUBY-11: `clone_similarity.rb` has Sorbet-specific filtering

Location:

- `lib/fact_mine/syntax/clone_similarity.rb:244`

Problem:

- Generic clone engine skips `T::Struct` schema text.

Why wrong:

- Clone engine knows Ruby Sorbet syntax.

Solution:

- Ruby adapter marks schema declarations as semantic low-signal/schema nodes.
- Clone engine skips generic schema markers.

### RUBY-12: `semantic_normalizer.rb` uses Ruby-like source matching

Location:

- `lib/fact_mine/ast/semantic_normalizer.rb:100`
- `lib/fact_mine/ast/semantic_normalizer.rb:111`
- `lib/fact_mine/ast/semantic_normalizer.rb:112`

Problem:

- Generic semantic normalizer searches for `if`, `unless`, `while`, `until`, and `end`.

Why wrong:

- This is Ruby/Perl-like block syntax in a generic file.
- Span reconstruction should not parse source text with language keywords.

Solution:

- Use spans already emitted by syntax facts.
- If block span repair is needed, ask language adapter for block boundary matching.

### RUBY-13: `SyntaxOracle` defaults engine to Ruby

Location:

- `lib/fact_mine/syntax_oracle.rb:13`
- `lib/fact_mine/syntax_oracle.rb:27`

Problem:

- Oracle engine defaults to `"ruby"`.

Why wrong:

- Test harness defaults can hide Rust/Ruby divergence.

Solution:

- Make engine explicit in cross-implementation tests.
- If a default remains for local development, do not use it in CI oracle tests.

### RUBY-14: `syntax/ruby.rb` still does too much raw fact extraction

Location:

- `lib/fact_mine/syntax/ruby.rb`

Problem:

- The file visibly owns Ruby-specific call target parsing, state target parsing, local/call ambiguity, hidden wrappers, Sorbet metadata, and visibility events.

Why partly wrong:

- It is in the correct file, so it is not hidden.
- But some of this exists because raw Tree-sitter nodes are being mined directly instead of normalizing to semantic descriptors first.

Solution:

- Keep truly Ruby-specific descriptors here:
  - local-vs-call ambiguity,
  - implicit `self`,
  - `@ivar`/`$global`,
  - modifier forms,
  - singleton methods,
  - inline visibility `def`,
  - heredocs,
  - Sorbet spelling.
- Move traversal and fact construction into shared semantic/dynamic passes.
- Expected shrink/generalization: 150-250 code-ish LoC.

## Ruby/Rust Parity Gaps

| Gap | Ruby has | Rust has | Required fix |
|---|---|---|---|
| Shared dynamic machinery | `syntax/dynamic_language.rb` with reusable local-flow/path/predicate traversal | No Rust equivalent | Add `rust/src/syntax/dynamic.rs` and use it from semantic normalizer/extractor. |
| Visible Ruby syntax ownership | `syntax/ruby.rb` owns real Ruby quirks | `syntax/adapters/ruby.rs` is 12 LoC; Ruby behavior is hidden in `ast.rs` and `ruby_metadata.rs` | Expand Rust Ruby adapter to own descriptors and metadata. |
| Production Ruby fact compiler | Delegates to native Rust facts | Active in Rust | Fix Rust first, because Ruby runtime depends on it. |
| Metadata ownership | Ruby Sorbet parsing is visible in `syntax/ruby.rb` | Sorbet parsing hidden in `ruby_metadata.rs` and `tree_sitter_adapter.rs` | Move Rust metadata into Ruby adapter and generic metadata events. |
| Compatibility AST status | Legacy normalizer is loaded but not production detector path | `ast.rs` is active production Ruby fact normalization | Remove Rust production dependency first; then quarantine Ruby compatibility. |
| Stateful pass shape | Ruby raw path has explicit stateless/stateful pass classes | Rust has pass structs but with Ruby metadata branch | Keep pass split; remove concrete language branches. |
| Non-Ruby raw fallback | Ruby raw adapters exist for many languages | Rust raw `collect_facts` path for all non-Ruby | Retire both behind semantic normalization per language. |

## Which Implementation Is Architecturally Closer?

Answer:

- Ruby is closer in visible boundaries.
- Rust is closer in active pass order.
- Rust is farther from the desired architecture because its production Ruby fact path hides RubyVM compatibility in `ast.rs`.

Practical ranking:

1. Best current piece: Ruby `syntax/dynamic_language.rb` plus Ruby `syntax/passes.rb`.
2. Best active pass order: Rust Ruby `parse -> normalize -> stateless -> stateful`.
3. Worst active architecture breach: Rust `ast.rs` as production Ruby normalizer.
4. Worst Ruby-side breach: `legacy_normalizer.rb` loaded under generic `FactMine::Ast`.

Implementation priority:

1. Fix Rust production Ruby path.
2. Add Rust semantic schema and dynamic machinery.
3. Move Rust Ruby metadata into adapter boundary.
4. Quarantine Ruby legacy AST compatibility.
5. Move Ruby lexicons/protocol/Sorbet filters into language-owned files.

## LoC Estimates

These are estimates based on code-ish LoC counts from the current tree.

### Rust

| Category | Estimated LoC | Included code | Fate |
|---|---:|---|---|
| Buried/architecture-tainted Ruby in active production path | 7,500-8,500 | `ast.rs` 6,395; `normalized_extractor.rs` 1,133; RubyVM consumers in local-flow/path/nil-guard/complexity | Replace with semantic schema/extractor; not production-valid. |
| Flat-out should not exist in production | 6,500-7,500 | RubyVM compatibility normalizer and RubyVM extractor as production path | Remove from source-fact pipeline. Keep only explicit compatibility if needed. |
| Should be generalized | 900-1,500 | local-flow/path/nil-guard RubyVM consumption, clone/schema exclusion, branch-state metadata filtering, immutable reader model | Rewrite as semantic/dynamic/metadata shared passes. |
| Should move into Ruby-specific files | 350-600 | `ruby_metadata.rs`, Ruby lexicon entries, Ruby assignment/operator helpers, Ruby raw branch hooks | Move to `syntax/adapters/ruby.rs` or `ast/ruby_compat.rs`. |
| Truly Ruby-specific after fix | 700-1,100 | Ruby descriptors, Sorbet metadata parser, Ruby local/call ambiguity, ivar/global/self, modifier forms, heredoc/block quirks | Live only in Rust Ruby adapter files. |

### Ruby

| Category | Estimated LoC | Included code | Fate |
|---|---:|---|---|
| Buried/architecture-tainted Ruby | 2,400-2,900 | `legacy_normalizer.rb` 2,151; `ast.rb` RubyVM helpers; `ast/adapters/base.rb` Ruby pieces; Ruby defaults; generic Sorbet/protocol/effect filters | Quarantine, move, or delete from default production path. |
| Flat-out should not exist in production | 2,100-2,300 | `legacy_normalizer.rb` as default generic AST infrastructure | Move to `ast/ruby_compat.rb` or remove from default require. |
| Should be generalized | 250-450 | immutable struct model names, clone schema exclusion, semantic span repair, dynamic call/state traversal portions of `syntax/ruby.rb` | Shared metadata/schema/dynamic passes. |
| Should move into Ruby-specific files | 150-300 | effect lexicon, protocol vocabulary, Ruby AST adapter constants, Sorbet filters | Move to `syntax/ruby.rb` or `ast/ruby_compat.rb`. |
| Truly Ruby-specific after fix | 650-950 | visible `syntax/ruby.rb` grammar descriptors and Sorbet spelling | Stay in Ruby-specific files. |

### Combined Judgment

If fixed:

- Ruby-specific code for the most complex language should be about 650-1,100 LoC per implementation.
- Shared infrastructure should grow, but it should be reused by Python, Lua, JavaScript/TypeScript, PHP, and Perl.

If not fixed:

- Each dynamic language will need hundreds to thousands of LoC to fake RubyVM compatibility.
- That is not viable.

### Non-Production Test Debt

| Category | Estimated LoC | Included code | Fate |
|---|---:|---|---|
| Tests that protect RubyVM compatibility as a cross-language contract | 15,000-20,000 | Most of `rust/src/ast-test.rs` plus current parser-only adapter invariants | Move compatibility-only coverage under `ruby_compat`; replace production-source tests with semantic/fact oracle fixtures. |
| Architecture tests with obsolete exceptions | 100-200 | `ruby_syntax_profile_is_parser_only`, `ruby_metadata.rs` allowances, RubyVM-string exceptions | Replace with invariants that allow language-owned adapters and forbid hidden Ruby outside them. |

## Concrete Implementation Order

1. Add invariants that fail on new Ruby-specific code outside language files.
2. Move Rust Sorbet metadata into the Ruby adapter boundary without changing facts.
3. Add Rust semantic schema and semantic extractor.
4. Reimplement Ruby production source facts through semantic normalization.
5. Byte-for-byte compare current and new `syntax-facts` output on all fixtures and `gems/slopcop`.
6. Port Rust local-flow/path-condition/redundant-nil-guard support off RubyVM nodes.
7. Quarantine Ruby `legacy_normalizer.rb` as `ast/ruby_compat.rb`.
8. Move Ruby effect/protocol/clone language data into `syntax/ruby.rb`.
9. Remove default Ruby fallback for unknown languages.
10. Only then add or expand support for the next dynamic language.

## Stop/Continue Decision

Continue only if the semantic schema work is accepted as the next architecture milestone.

Pause language expansion if any of these happen:

- Ruby production facts cannot be generated without `ast.rs` RubyVM nodes.
- Rust Ruby adapter plus explicit Ruby metadata exceeds about 1,200 code-ish LoC after shared dynamic machinery exists.
- Python/Lua/JS/PHP require their own fact extractors instead of semantic descriptors.
- Invariants cannot prohibit hidden language code without constant exemptions.
