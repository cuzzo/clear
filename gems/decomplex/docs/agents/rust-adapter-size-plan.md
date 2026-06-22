# Rust Adapter Size Reduction Plan

## Problem

The Rust Ruby syntax adapter is too large to support the intended multi-language architecture.

## Implementation Pass: 2026-06-20

Completed generic extractions:

- `syntax/raw_tree.rs`: raw `RawNode` child, field, and sibling helpers.
- `syntax/protocols.rs`: protocol method-effect construction, local-name traversal, state read/write traversal, protocol path traversal, branch/case path composition, and raw protocol call-target extraction.
- `syntax/semantic_effects.rs`: semantic-effect row construction, function attribution, context-dependency projection, method-hook effects, external state mutation effects, and structural-effect tree traversal.
- `syntax/visibility.rs`: generic owner-scoped visibility directive application.
- `syntax/calls.rs`: call text validation, identifier-shape validation, argument-list extraction, and no-argument call span narrowing.

Additional cleanup:

- `local_flow.rs` and `path_condition.rs` now use shared raw-tree helpers instead of local duplicates.
- `implicit_control_flow::scan_files` now materializes protocol facts before reading protocol fields.

Verification:

- Rust test suite: passing.
- `decomplex-rust facts --jobs=8 gems/decomplex/lib/decomplex`: byte-for-byte match against the pre-refactor baseline.
- `decomplex-rust facts --jobs=8 gems/slopcop`: byte-for-byte match against the pre-refactor baseline.

Size after this pass:

- `syntax/adapters/ruby.rs`: 1,479 LoC after moving protocol/call/effect shape handling into shared declaration-driven infrastructure.
- `syntax/adapters/ruby_data.rs`: 217 LoC of Ruby grammar tables, protocol/call shapes, semantic-effect declarations, and lexicons.
- New shared syntax infrastructure: 1,219 LoC total across `calls.rs`, `protocols.rs`, `raw_tree.rs`, `semantic_effects.rs`, and `visibility.rs`.

Remaining risk:

- Ruby is still above the 1,000 LoC warning threshold and well above the <=700 ideal target.
- The remaining large buckets are mostly Ruby call grammar, Ruby semantic-effect declarations, and Ruby protocol hook decisions. Further reduction should avoid moving Ruby-only code into Ruby-only submodules; the next useful pass should data-drive more of the call grammar and protocol hook surfaces from generic extractor declarations.

Current Rust LoC:

- `syntax/adapters/ruby.rs`: 2,300
- `syntax/adapters/base.rs`: 1,919
- `syntax/tree_sitter_adapter.rs`: 2,789
- `syntax/local_flow.rs`: 2,280
- `ast.rs`: 6,807

The original target was roughly:

- ideal adapter: <= 700 LoC
- warning threshold: > 1,000 LoC
- language support goal: 15-20 languages without writing a bespoke analyzer per language

Ruby is already far past the warning threshold. If this remains the pattern, the design does not scale.

## Important Constraint

Do not solve this by splitting `ruby.rs` into `ruby/calls.rs`, `ruby/protocols.rs`, etc. That may improve file readability, but it does not fix the architecture. The goal is to move generic algorithms out of the Ruby adapter and leave Ruby with grammar facts and truly Ruby-specific hooks.

## Current Ruby Adapter Buckets

Approximate line ownership in `ruby.rs`:

- grammar/node-kind declarations and trait overrides: ~400 LoC
- Ruby call target and argument extraction: ~400 LoC
- Ruby structural semantic effects: ~300 LoC
- Ruby protocol method effects and protocol path mining: ~700 LoC
- Ruby raw tree helpers and special-case utilities: ~250 LoC
- constants/lexicons: ~100 LoC

The largest problem is that Ruby owns algorithms for protocols, structural effects, and call parsing. Those are not all Ruby-only concepts.

## Likely Misplaced Code

### 1. Protocol Mining

`ruby_protocol_*` is mostly a generic protocol engine:

- collect method reads/writes
- collect local names
- walk statement paths
- combine branch/case path alternatives
- detect ordered stateful calls
- normalize method names and state tokens

Ruby-specific pieces should be small hooks:

- no-paren bare self calls
- ignored protocol message set
- mutating message set and suffix rules
- Ruby instance/global variable state tokens
- Ruby command-call and hidden wrapper grammar quirks

Target:

- move generic protocol engine to `syntax/protocols.rs`
- add `LanguageProfile` hooks for protocol behavior
- keep Ruby protocol code under ~150-250 LoC

### 2. Structural Semantic Effects

`ruby_structural_semantic_effect_*` contains both reusable effect classification and Ruby-specific facts.

Generic concepts:

- hidden mutation
- context dependency
- dynamic dispatch
- metaprogramming
- global state read/write effects
- operator mutation effects

Ruby-specific hooks:

- backtick/subshell hidden IO
- `yield`
- `class << receiver`
- `ENV[...]`
- global variables
- `method_missing` / `respond_to_missing?`
- Ruby `<<`, `[]=`, operator assignment shapes

Target:

- move generic effect classification to `syntax/effects.rs`
- adapter supplies effect node kinds and extraction hooks
- Ruby effect code should be mostly hook implementations and lexicons

### 3. Call Target Extraction

Ruby has complicated call syntax, but much of the code is a generic "extract receiver/message/arguments/block/safe-navigation" problem.

Generic concepts:

- receiver + message field extraction
- argument list extraction
- block detection
- safe navigation
- no-arg span narrowing
- method-object/proc `.call`
- first/named child fallback

Ruby-specific hooks:

- command calls without parentheses
- bare identifiers as self calls
- visibility directives
- `require "x"` unquoted argument handling
- inline `private def foo` hidden method wrappers

Target:

- move generic call extraction to a reusable call extractor in `syntax/calls.rs`
- adapter provides grammar shape and hook overrides
- Ruby call code should fall below ~200 LoC

### 4. Raw Tree Helpers

Ruby duplicates raw-node helpers that exist or should exist generically:

- named children
- field lookup
- sibling lookup
- first child kind
- wrapper/body unwrapping
- branch body extraction

Target:

- move reusable raw-node helpers to a generic raw tree utility module
- Ruby should only describe which node kinds are wrappers, bodies, branches, cases, etc.

### 5. Lexicons

The ignored/mutating protocol message lists are language-specific, but list ownership should be data-like, not algorithmic.

Target:

- keep Ruby lexicons in Ruby adapter or adjacent Ruby data module
- make generic protocol/effect engines consume lexicons through trait methods
- do not let these lists appear in detectors or generic report code

## What Should Remain In `ruby.rs`

Ruby adapter should keep:

- `grammar()`
- node-kind sets
- Ruby lexical constants
- Ruby-specific call syntax hooks
- Ruby visibility directive handling
- Ruby instance/global variable state target hooks
- Ruby Sorbet/T::Struct suppression hooks
- Ruby-specific semantic-effect declarations
- Ruby-specific protocol lexicons

Ruby adapter should not own:

- generic protocol path algorithms
- generic read/write method-effect algorithms
- generic branch/case path combination
- generic call extraction scaffolding
- generic structural effect scan loops
- generic raw tree traversal helpers
- clone fingerprint algorithms

## Target Shape

Proposed module boundaries:

- `syntax/adapters/base.rs`
  - trait definitions
  - default generic behavior
  - small generic helpers only

- `syntax/calls.rs`
  - reusable call extraction engine
  - receiver/message/argument/block/safe-navigation extraction

- `syntax/protocols.rs`
  - protocol method effects
  - protocol call paths
  - branch/case path composition
  - path limit and terminal behavior

- `syntax/effects.rs`
  - structural semantic effect engine
  - generic effect row construction

- `syntax/raw_tree.rs`
  - raw-node traversal and field/sibling helpers

- `syntax/adapters/ruby.rs`
  - Ruby grammar facts and hooks
  - target <= 700 LoC

## Work Plan

1. Inventory every Ruby adapter function into one of three categories:
   - Ruby-only hook
   - generic algorithm with Ruby inputs
   - dead or redundant behavior

2. Lock behavior before moving code:
   - run Ruby syntax fact oracle
   - run Ruby-vs-Rust fact oracle
   - run full Rust facts on `gems/slopcop` and `gems/decomplex/lib/decomplex`
   - save byte-for-byte baselines

3. Extract raw tree utilities first:
   - move duplicated `raw_*` helper functions that have no Ruby semantics
   - verify byte-for-byte facts after each extraction

4. Extract protocol engine:
   - introduce a generic `ProtocolProfile`/trait-hook surface
   - move path combination, branch/case traversal, method-effect construction
   - leave Ruby only with message/state/local-name hooks and lexicons
   - verify syntax oracle protocol fact buckets and full facts

5. Extract call extraction:
   - create `syntax/calls.rs`
   - move generic receiver/message/argument/block extraction
   - keep Ruby bare-call and command-call hooks in Ruby
   - verify call-site fact buckets first, then full facts

6. Extract structural effects:
   - create `syntax/effects.rs`
   - move generic scan loop and effect row construction
   - adapter supplies effect declarations and target extraction hooks
   - verify semantic-effect fact buckets first, then full facts

7. Re-measure LoC and enforce thresholds:
   - add an architectural test that warns/fails when an adapter exceeds the agreed threshold
   - threshold should initially be explicit and realistic:
     - Ruby target: <= 900 during migration, then <= 700
     - non-Ruby adapters: <= 700
   - any exception must be documented with a specific reason

## Verification Rule

Each extraction must be behavior-preserving before the next extraction starts.

Required checks after each move:

- Rust `cargo check`
- Ruby syntax fact oracle for Ruby
- Rust syntax fact oracle for Ruby
- byte-for-byte Rust facts on at least:
  - `gems/slopcop`
  - `gems/decomplex/lib/decomplex`

If byte output changes, stop and classify the change:

- Ruby/Rust bug fixed intentionally
- extraction bug
- oracle gap

Do not continue broad refactoring while facts are drifting.

## Expected Outcome

The Ruby adapter should become mostly data plus small hooks. If, after the extraction work, Ruby still requires more than ~1,000 adapter lines, then the adapter contract is still wrong and needs another design pass before adding more languages.
