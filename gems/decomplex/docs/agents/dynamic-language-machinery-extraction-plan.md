# Dynamic-Language Machinery Extraction Plan

- Move predicate-body extraction into shared dynamic syntax support.
  - Why: predicate helper bodies are not Ruby-specific; they are normalized boolean/null/type-test expressions.
  - Languages: Python, Lua, JavaScript, TypeScript, PHP, and Perl all need predicate helpers to become reusable branch facts.
  - Expected Ruby LoC moved: 70-90 LoC from `lib/decomplex/syntax/ruby.rb`.
- Move local-flow statement extraction into shared dynamic syntax support.
  - Why: local reads, writes, assignment dependencies, co-uses, and structural boundaries are detector-neutral facts over statements.
  - Languages: Python, Lua, JavaScript, TypeScript, PHP, and Perl all have local variables, assignment expressions, and statement-level flow.
  - Expected Ruby LoC moved: 150-210 LoC from `lib/decomplex/syntax/ruby.rb`.
- Move path-condition traversal into shared dynamic syntax support.
  - Why: nested `if`, modifier/inline branches, boolean conjunction flattening, polarity, and guarded action recording are language-neutral after branch normalization.
  - Languages: Python, Lua, JavaScript, TypeScript, PHP, and Perl all need guarded-action equivalence such as nested branches versus conjunctions.
  - Expected Ruby LoC moved: 100-130 LoC from `lib/decomplex/syntax/ruby.rb`.
- Move dynamic call target helpers into shared dynamic syntax support later.
  - Why: implicit receiver calls, receiver/message extraction, safe navigation, callable shorthand, and unparenthesized arguments recur across dynamic languages.
  - Languages: Python, JavaScript, TypeScript, PHP, Lua, and Perl all need variants of receiver/message/callable normalization.
  - Expected Ruby LoC moved later: 150-220 LoC from `lib/decomplex/syntax/ruby.rb`.
- Move state-ref helper structure into shared dynamic syntax support later.
  - Why: self/this/global/field reads and writes vary by spelling, but the target model is shared.
  - Languages: Python `self.x`, JavaScript/TypeScript `this.x`, PHP `$this->x`, Lua table fields, Perl object/hash access.
  - Expected Ruby LoC moved later: 80-140 LoC from `lib/decomplex/syntax/ruby.rb`.
- Move visibility and type-metadata event models into shared syntax support later.
  - Why: event application is generic even when concrete syntax differs.
  - Languages: PHP and TypeScript have explicit visibility; Python dataclasses/attrs/pydantic, TypeScript readonly/types, PHP typed properties, and Sorbet all need immutable/type metadata.
  - Expected Ruby LoC moved later: 80-130 LoC from `lib/decomplex/syntax/ruby.rb`.

## Goal

Reduce concrete dynamic-language adapters to grammar facts and narrow language hooks. Shared dynamic machinery should live in explicitly reviewed syntax support files, not in language-specific adapters or detector code.

The first Ruby implementation extracts only the machinery that can move without changing behavior:

- predicate-body extraction
- local-flow extraction
- path-condition extraction

This gives a measurable LoC reduction in `syntax/ruby.rb` while keeping fact output byte-for-byte identical.

## Current Ruby Split

Current physical line counts:

| File | Physical LoC | Role |
| --- | ---: | --- |
| `lib/decomplex/syntax/ruby.rb` | 1,213 | Ruby raw syntax adapter and compatibility hooks. |
| `rust/src/decomplex/ast/adapters/ruby.rs` | 267 | Rust AST normalization hooks. |
| `rust/src/decomplex/syntax/adapters/ruby.rs` | 15 | Rust parser-only Ruby syntax profile. |

The Ruby runtime fact path for Ruby source now uses native `syntax-facts` and hydrates a `FactDocument`. `syntax/ruby.rb` remains for raw parsing/tests and for non-native compatibility. That makes it safe to refactor, but the refactor must still preserve raw Ruby adapter behavior.

## Ruby Implementation Plan

1. Capture baseline facts before edits.
   - Ruby source-fact fixture projection with engine `ruby`.
   - `gems/slopcop/**/*.rb` syntax facts with engine `ruby`.
   - Keep byte snapshots outside the repository for direct `cmp`.
2. Add `lib/decomplex/syntax/dynamic_language.rb`.
   - No `require` or `require_relative` inside the subfile.
   - Define `DynamicLanguageSyntax` as a shared mixin.
   - Add it to the syntax file allowlist invariant.
   - Load it from `syntax.rb`, the only allowed syntax loader.
3. Move predicate-body machinery.
   - Add `dynamic_predicate_def`.
   - Add `dynamic_single_expression_function_body`.
   - Add `dynamic_predicate_expression_body`.
   - Add `dynamic_predicate_body?`.
   - Keep Ruby hooks for body wrappers, heredocs, and flat comparison statements.
4. Move local-flow machinery.
   - Add `dynamic_local_methods`.
   - Add `dynamic_function_body_statements`.
   - Add `dynamic_local_names`, `dynamic_local_statement`, reads/writes/dependencies, structural boundaries, and local tree walk.
   - Keep language hooks for nested scopes, local read/write identifiers, assignment shape, source owner mapping, and comments.
5. Move path-condition machinery.
   - Add `dynamic_path_condition_sites`.
   - Add `dynamic_path_walk`, branch polarity, guard atoms, action recording.
   - Keep language hooks for branch node detection, condition/then/else/body extraction, and action node shape.
6. Update `RubySyntaxAdapter`.
   - Include `DynamicLanguageSyntax`.
   - Replace Ruby method bodies with calls to shared dynamic methods.
   - Keep Ruby-specific hook implementations in `syntax/ruby.rb`.
7. Verify no behavioral drift.
   - Compare post-refactor Ruby source-fact fixture JSON with the baseline via `cmp`.
   - Compare post-refactor slopcop Ruby syntax facts with the baseline via `cmp`.
   - Run `ruby -I gems/decomplex/test -I gems/decomplex/lib gems/decomplex/test/architecture_invariants_test.rb`.
   - Run `ruby -I gems/decomplex/test -I gems/decomplex/lib gems/decomplex/test/syntax_test.rb`.
   - Run full Ruby tests if targeted checks pass.

## Rust Implementation Plan

The Rust compiler already moved Ruby syntax facts onto the normalized path. The same dynamic-language extraction should be mirrored in Rust as a cleanup of `normalized_extractor.rs`, `local_flow.rs`, `path_condition.rs`, and the adapter traits.

1. Preserve the current invariant.
   - Concrete adapters normalize and supply grammar facts.
   - `normalized_extractor.rs` must not depend on concrete languages, Tree-sitter, API lexicons, or detector types.
2. Split normalized dynamic machinery by role.
   - `syntax/normalized_predicates.rs`: predicate-body facts from normalized function bodies.
   - `syntax/normalized_local_flow.rs`: local method and statement facts from normalized reads/writes.
   - `syntax/normalized_path_conditions.rs`: branch/path condition facts from normalized `IF`/`UNLESS`/boolean nodes.
   - These files must remain language-neutral and operate on normalized AST/document facts.
3. Keep adapter hooks small.
   - Ruby AST adapter keeps grammar quirks such as hidden `body_statement`, inline defs, Sorbet signatures, and modifier normalization.
   - Python/Lua/JS/TS/PHP/Perl adapters add only grammar spelling hooks required to normalize to the same schema.
4. Enforce with Rust architecture tests.
   - Extend the syntax allowlist deliberately for new normalized files.
   - Ban `Language::`, `Ruby`, `Python`, `JavaScript`, `TypeScript`, `Php`, `Lua`, `Perl`, `tree_sitter`, and API lexicons inside these shared normalized files.
   - Ban detector modules from importing or traversing raw/normalized AST directly.
5. Verify byte-for-byte.
   - Capture `syntax-facts` output for Ruby source-fact fixtures and slopcop before each Rust split.
   - Refactor one file/role at a time.
   - Compare syntax facts byte-for-byte after each split.
   - Run full Rust tests and slopcop Ruby/Rust parity after the final split.

## Expected LoC Outcome

First Ruby extraction target:

| Source | Expected moved LoC |
| --- | ---: |
| Predicate-body machinery | 70-90 |
| Local-flow machinery | 150-210 |
| Path-condition machinery | 100-130 |
| Total first pass | 300-430 |

Expected post-first-pass `syntax/ruby.rb`: roughly 900 physical LoC when Ruby hook methods remain explicit.

Later extraction target:

| Source | Expected moved LoC |
| --- | ---: |
| Dynamic call target helpers | 150-220 |
| Dynamic state-ref helpers | 80-140 |
| Visibility/type metadata event model | 80-130 |
| Total later pass | 310-490 |

Expected final `syntax/ruby.rb`: roughly 350-550 physical LoC, with the remainder being Ruby grammar quirks and Ruby-specific metadata such as Sorbet spelling.

## Non-Goals

- Do not move detector fact engines into adapters.
- Do not add language-specific helper files to evade adapter invariants.
- Do not change fact shape during extraction.
- Do not add line-budget-only tests; enforce ownership and dependency boundaries instead.

## Success Criteria

- `syntax/ruby.rb` shrinks by at least 300 physical LoC in the first pass.
- A new shared dynamic syntax component exists and is invariant-controlled.
- Ruby source-fact fixture output is byte-for-byte identical pre/post refactor.
- Slopcop Ruby syntax facts are byte-for-byte identical pre/post refactor.
- Ruby and Rust Decomplex tests remain green.

## First Ruby Pass Result

Implemented first-pass extraction:

| File | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `lib/decomplex/syntax/ruby.rb` | 1,213 physical LoC | 913 physical LoC | -300 |
| `lib/decomplex/syntax/dynamic_language.rb` | 0 physical LoC | 412 physical LoC | +412 |

The shared dynamic module currently owns:

- predicate-body extraction
- local-flow statement extraction
- path-condition traversal

Ruby now keeps explicit hook methods for:

- Ruby method body wrappers and endless method expression bodies
- Ruby hidden `if`/modifier/`case` wrappers
- Ruby heredoc statement bodies
- Ruby local read/write identifier rules
- Ruby flat assignment shape

Verification from the first pass:

- Ruby source-fact fixture projection byte-for-byte identical: 406,427 bytes before and after.
- Slopcop Ruby syntax facts byte-for-byte identical: 7,054,134 bytes before and after.
- Ruby architecture invariants pass.
- Full Ruby test suite passes: 1,333 runs, 4,936 assertions, 0 failures.
