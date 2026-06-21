# Rust Normalized Architecture Audit

## Architecturally Incorrect Rust Code

- `gems/fact-mine/rust/src/syntax/tree_sitter_adapter.rs` routes only Ruby through normalized extraction.
  - Why wrong: Ruby FactMine defaults every language to `NormalizedExtractor`; Rust still runs the raw tree-sitter fact collector for Python, JavaScript, TypeScript, Go, Rust, Zig, Lua, C, C++, C#, Java, Kotlin, Swift, and PHP.
  - Required fix: make `parse_file_with_options` normalize every supported language, then run stateless normalized extraction and stateful enrichment for that language.

- `gems/fact-mine/rust/src/syntax/tree_sitter_adapter.rs` still owns raw stateless fact extraction.
  - Examples: `collect_facts`, `record_branch_decision`, `collect_dispatch_sites`, `collect_implicit_state_accesses`, raw call/state/owner extraction helpers.
  - Why wrong: parser orchestration should read source, build a tree, normalize, then invoke passes. Fact extraction belongs to normalized extractor/passes.
  - Required fix: quarantine raw extraction as legacy compatibility only or delete it once normalized parity is proven. It must not be on the default path.

- `gems/fact-mine/rust/src/syntax/adapters/base.rs` exposes raw detector-fact hooks through `LanguageProfile`.
  - Examples: owner/function/call/state/branch/case/dispatch/path-condition/local-flow node kind hooks, raw call targets, raw state targets, raw clone hooks.
  - Why wrong: concrete syntax adapters should provide parser facts and grammar-to-normalized facts. They must not become a detector fact API.
  - Required fix: keep grammar/parser setup in syntax adapters; move normalized semantic behavior to `syntax/normalized_<language>.rs` modules; remove raw fact hooks after the default raw path is gone.

- `gems/fact-mine/rust/src/syntax/local_flow.rs` uses normalized local facts only for Ruby.
  - Why wrong: local flow is a shared normalized pass in Ruby FactMine. Rust falls back to raw extraction for non-Ruby and contains concrete-language branches for Ruby and Python.
  - Required fix: use normalized local facts for every document with a normalized root. Move/delete raw local-flow fallback after parity.

- `gems/fact-mine/rust/src/syntax/path_condition.rs` has a raw fallback fact engine.
  - Examples: `sites_from_raw_facts`, `raw_path_walk`, `raw_unless_node`, raw branch/body/action helpers.
  - Why wrong: path-condition facts should come from stored facts or normalized AST. Raw parser traversal reintroduces language-specific branch parsing in a generic pass.
  - Required fix: consume `document.path_condition_sites` first, otherwise derive from normalized root only. Delete/quarantine raw fallback.

- `gems/fact-mine/rust/src/syntax/protocols.rs` computes protocol call paths from raw function bodies.
  - Examples: `function_body_node`, `protocol_paths_for_raw`, `protocol_paths_for_node`, raw `if`/`unless`/`case` logic.
  - Why wrong: protocol paths should be fact/normalized-IR based like Ruby. Raw body traversal makes call-path behavior depend on parser spellings.
  - Required fix: derive simple call paths from `call_sites` immediately, then add normalized branch/case path splitting if required by fixtures.

- `gems/fact-mine/rust/src/syntax/complexity.rs` computes local complexity over `RawNode`.
  - Why wrong: Ruby’s normalized local facts compute local complexity from normalized nodes. Rust currently works only because normalized functions are projected back into fake raw nodes.
  - Required fix: move local complexity scoring into the normalized local-facts/stateful pass over `Node`, or introduce a normalized complexity scorer and stop using `RawNode`.

- `gems/fact-mine/rust/src/syntax/clone_similarity.rs` still contains dead raw clone code and concrete Ruby/Sorbet suppression.
  - Examples: raw clone candidate constants, `raw_clone_candidates_for_profile`, `default_clone_candidate_node`, `typed_struct_schema`, `T::Struct`.
  - Why wrong: the public entry point already returns normalized clone candidates. Dead raw code hides concrete language behavior in a generic file.
  - Required fix: remove the raw clone fallback or move any still-needed suppression into `normalized_ruby.rs` via `suppress_clone_candidate`.

- `gems/fact-mine/rust/src/syntax/normalized_behavior.rs` only registers Ruby behavior.
  - Why wrong: Ruby FactMine has per-language normalized behavior classes. Rust still depends on raw adapters for many non-Ruby source projections and lexicons.
  - Required fix: add `normalized_<language>.rs` modules as needed and move source projection, nil-guard, protocol, mutation, case-pattern, and semantic-effect lexicons there.

- `gems/fact-mine/rust/src/syntax/adapters/false_simplicity_lexicon.rs` centralizes language lexicons in one adapter-side file.
  - Why wrong: these are language-specific semantic-effect lexicons, not parser adapter facts. Ruby owns this data in the concrete language syntax files.
  - Required fix: move the lexicon surface to normalized language behavior or per-language syntax modules; keep the generic effect engine language-neutral.

- `gems/fact-mine/rust/src/ast.rs` mixes raw tree serialization with grammar-specific compatibility rewrites.
  - Examples: `RawNode::from_tree_sitter` rewrites `argument_list`, `call`, `return`, `when`, and `body_statement` shapes before normalization.
  - Why wrong: raw serialization should serialize raw trees; normalization belongs in `TreeSitterNormalizer` and AST adapters.
  - Required fix: stop depending on `RawNode::from_tree_sitter` for default facts, then remove the compatibility rewrites or move them into legacy raw compatibility.

- `gems/fact-mine/rust/src/syntax.rs` exposes public fallback functions that recompute facts when document sections are empty.
  - Examples: `protocol_method_effects`, `protocol_call_paths`, `clone_candidates`.
  - Why wrong: in the normalized architecture, parse populates fact sections; fallback recomputation should not hide missing pass output.
  - Required fix: populate these sections during stateful normalized enrichment, then make public readers return stored facts without raw recomputation.

## Repeated Problem Patterns

- Rust still treats normalized extraction as a Ruby special case instead of the default compiler architecture.
- Generic Rust files still own raw parser traversal engines that should be normalized passes.
- `LanguageProfile` still acts as a detector-fact adapter for non-Ruby languages.
- Concrete-language behavior is centralized in generic registries or generic raw helpers instead of language-specific normalized behavior modules.
- Some public readers recompute missing facts, which masks missing pass output and prevents the test suite from revealing architecture gaps.

## Target Rust Architecture

- Parser layer:
  - `tree_sitter_adapter.rs` reads source, selects grammar, builds tree, normalizes, and orchestrates passes.
  - It does not mine facts from raw parser nodes.

- AST normalization layer:
  - `ast.rs` and `ast/adapters/<language>.rs` normalize concrete grammar shapes to normalized `Node`.
  - Language-specific normalization quirks live in concrete AST adapter files.

- Stateless normalized extraction:
  - `normalized_extractor.rs` traverses normalized `Node`.
  - It emits structural facts, calls, state facts, decisions, branch arms, dispatch seeds, comparison facts, semantic effects that are intrinsic to normalized nodes, and predicate aliases.
  - It knows no concrete language names.

- Stateful normalized enrichment:
  - `passes.rs` applies visibility, semantic effects from calls, dispatch merging, local facts, path conditions, protocol facts, clone candidates, nil-guard facts, and metadata.
  - It invokes language-specific behavior only through the narrow normalized behavior trait.

- Language behavior:
  - `normalized_<language>.rs` files own language lexicons and normalized semantic quirks.
  - Examples: mutating receiver messages, nil predicate spellings, terminating calls, case pattern display, source text projection, visibility calls, language metadata.

- Public document:
  - `Document` contains facts already produced by the pipeline.
  - Reader helpers should not parse raw trees or compute missing fact sections from raw syntax.

## Implementation Plan

1. First WIP move:
   - Make Rust default parse path normalized for every language.
   - Make normalized local flow/path conditions authoritative when `normalized_root` is present.
   - Stop protocol call paths from walking raw bodies on the public path.
   - Commit as WIP even if some tests fail, after fixing obvious compile errors.

2. Second WIP move:
   - Move normalized local complexity from `RawNode` to normalized `Node`.
   - Remove or quarantine dead raw clone code and any `T::Struct` suppression in generic clone code.
   - Start moving non-Ruby normalized behavior/lexicons out of `LanguageProfile` and central lexicon files.
   - Add/expand architecture invariants that forbid default raw extraction and raw fallback fact engines.

3. Green pass:
   - Run Rust FactMine and Rust Decomplex tests.
   - Update fixtures only for public fact changes that are correct consequences of normalized extraction.
   - Fix missing normalized behavior in language-specific files only.
   - Run Ruby FactMine and Ruby Decomplex tests to make sure shared examples still agree.

4. Final review:
   - Re-scan production files for raw parser fact engines on default paths, concrete-language branches in generic passes, and fact recomputation fallbacks.
   - Commit and push final passing state.
