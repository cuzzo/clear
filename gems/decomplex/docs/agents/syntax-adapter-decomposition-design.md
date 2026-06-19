# Syntax Adapter Decomposition Design

## Goal

`Decomplex::Syntax` should be a cross-language fact model and Tree-sitter facade. It should not know Ruby, PHP, Java, Rust, Zig, or any other concrete grammar beyond the registry that maps a language key to an adapter.

Language adapters own:

- parser package metadata and extensions
- lexicon regexes
- concrete Tree-sitter node kind names
- grammar-specific hidden constructs
- source-text conventions that cannot be represented generically

The base `TreeSitterLanguageAdapter` owns:

- traversal
- shared fact emission
- generic algorithms over adapter-provided grammar shapes
- empty defaults for optional language-specific fact providers

## Current Issues

`syntax.rb` still contains a large union of concrete grammar node names. That makes new language support look easy until a language differs, then the generic code grows another special case. The result is brittle cross-language support because unrelated languages inherit grammar assumptions they do not share.

The main areas are:

- function and owner detection
- parameter, body, and local-flow discovery
- assignment and declaration recognition
- branch, case, loop, and hidden branch detection
- call, member-access, and state-target discovery

## Target Shape

Each adapter exposes declarative grammar-shape methods. The base adapter uses those methods instead of hard-coded language unions:

- `function_node_kinds`
- `method_node_kinds`
- `owner_node_kinds`
- `loop_node_kinds`
- `if_node_kinds`
- `case_node_kinds`
- `hidden_if_wrapper_kinds`
- `hidden_case_wrapper_kinds`
- `case_arm_node_kinds`
- `function_body_node_kinds`
- `parameter_list_node_kinds`
- `assignment_node_kinds`
- `declaration_node_kinds`
- `field_declaration_node_kinds`
- `identifier_node_kinds`
- `field_like_node_kinds`
- `call_node_kinds`
- `adjacent_call_node_kinds`
- `argument_list_node_kinds`
- `comment_prefixes`

Adapters override only the shapes they need. When a language needs real logic instead of vocabulary, it overrides the semantic method directly, such as `function_name`, `call_target`, `state_target`, or `case_arm_patterns`.

## Migration Plan

1. Move source-text language quirks out of `syntax.rb`.
   - Generic defaults return empty facts.
   - Ruby owns Sorbet `T::Struct`, `const`, and `T.type_alias` parsing.

2. Move lexicons beside adapters.
   - `LanguageLexicon` remains shared.
   - Concrete `*_LEXICON` constants live in the files that define their adapters.

3. Introduce grammar-shape methods in the base adapter.
   - Start with one area at a time.
   - Replace each concrete node-kind union with an adapter method call.
   - Keep behavior stable while moving the data boundary.

4. Push concrete node kinds down into adapters.
   - The base adapter may retain only truly generic names if they are part of a documented normalized adapter contract.
   - Otherwise, adapters provide the language-specific kind sets.

5. Add architecture invariants.
   - `syntax.rb` must not define language lexicons.
   - `syntax.rb` must not contain Sorbet or Ruby source-text patterns.
   - Detectors must not call Tree-sitter APIs directly.
   - New concrete grammar kind lists in `syntax.rb` should fail review unless backed by a documented generic adapter contract.

## Verification

For each migration step:

- run the examples oracle tests
- run the full Decomplex Ruby test suite
- run architecture invariant tests
- run `decomplex report` on `gems/decomplex/lib/decomplex` before and after
- compare whether reported issues are stable or whether differences reflect reduced self-findings in `syntax.rb`

The expected direction is a smaller `syntax.rb`, fewer language names and source-level quirks in shared code, and no loss of detector oracle specificity.
