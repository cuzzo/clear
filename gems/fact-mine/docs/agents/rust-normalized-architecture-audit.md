# Rust Normalized Architecture Audit

This audit is measured against `gems/fact-mine/docs/agents/architecture.md`.
Ruby remains the reference shape: parse concrete syntax, normalize to shared
IR, run stateless extraction over normalized IR, run stateful enrichment over
normalized facts/IR, then expose stored public facts.

## Current Status

- Rust production parsing now routes through normalized AST construction and
  normalized stateless/stateful passes.
- The old `syntax/adapters` raw fact-profile layer has been deleted.
- `syntax/tree_sitter_adapter.rs` is parse orchestration plus pass invocation.
- `syntax/parser_grammar.rs` is grammar lookup only.
- `syntax/normalized_extractor.rs` performs stateless extraction from
  normalized IR only.
- `syntax/passes.rs` owns stateful enrichment orchestration.
- Public protocol/clone/path/local/nil readers return stored facts instead of
  recomputing fact sections after parse.
- Ruby semantic-effect/core-constant/Sorbet metadata moved into
  `syntax/normalized_ruby.rs`; the separate `syntax/ruby_metadata.rs` sidecar
  was deleted.
- Per-language semantic-effect, eliminable-guard, nil-guard, predicate-body,
  and local-flow vocabularies live in `syntax/normalized_<language>.rs`.
- Generic `syntax/effects.rs` owns only the language-neutral classifier
  algorithm plus `EffectLexicon`; concrete vocabulary is supplied by normalized
  language behavior.
- Decomplex `decision_pressure` consumes stored `eliminable_guard` semantic
  effects instead of owning guard method-name lexicons.

## Moved Or Deleted

- Deleted raw `syntax/adapters/{base,c,cpp,csharp,go,java,javascript,kotlin,lua,php,python,ruby,rust,swift,typescript,zig}.rs`.
- Deleted shared `syntax/adapters/false_simplicity_lexicon.rs`.
- Deleted `syntax/raw_tree.rs`.
- Deleted `materialize_protocol_facts` and `ProtocolFacts` no-op/public
  fallback facade.
- Removed public protocol fact materialization calls from FactMine oracle and
  Decomplex report/detector entrypoints.
- Moved grammar selection to `syntax/parser_grammar.rs`.
- Moved Ruby semantic effect, core-constant, and metadata data to
  `syntax/normalized_ruby.rs`.
- Moved all supported-language effect and guard lexicons to
  `syntax/normalized_<language>.rs`.
- Moved local-flow declaration/operator/keyword ownership to normalized
  language behavior hooks.
- Replaced local-contract source keyword checks with normalized control-node
  checks.
- Removed detector-side guard method lexicons from Decomplex
  `decision_pressure`.

## Current Pass Boundaries

1. `syntax/tree_sitter_adapter.rs`
   - Reads source.
   - Builds a Tree-sitter parse tree.
   - Calls `ast::normalize_tree`.
   - Runs `StatelessSyntaxPass`.
   - Runs `StatefulSyntaxPass`.
   - Builds `Document` from stored fact sections.

2. `ast/adapters/<language>.rs`
   - Own concrete grammar to normalized IR translation.
   - May inspect Tree-sitter nodes.
   - Must not emit detector fact rows.

3. `syntax/normalized_<language>.rs`
   - Own language behavior over normalized IR/facts.
   - Own language lexicons and standard-library/source spellings.
   - Own concrete guard predicate names, nil predicate names, semantic-effect
     vocabulary, local-flow keywords/operators, and language metadata quirks.
   - May answer narrow behavior hooks used by generic extraction/enrichment.
   - Must not become a detector-specific fact engine.

4. `syntax/normalized_extractor.rs`
   - Own stateless normalized traversal.
   - Consumes only normalized IR and narrow behavior hooks.
   - Must not contain concrete language names, parser APIs, or stateful
     enrichment engines.

5. `syntax/passes.rs`
   - Own stateful pass order.
   - Applies visibility events, semantic-effect classification, local-flow
     facts, path-condition facts, protocol facts, clone candidates, redundant
     nil guards, complexity, and language metadata.
   - Stores `eliminable_guard` semantic effects for safe navigation and
     language-owned guard predicates before Decomplex detectors run.

6. `syntax/{effects,protocols,clone_similarity,local_flow,path_condition,redundant_nil_guard,complexity,visibility}.rs`
   - Shared engines over normalized IR and stored facts.
   - May call `NormalizedLanguageBehavior`.
   - Must not inspect Tree-sitter nodes or branch on concrete languages.

## Remaining Debt

- `ast.rs` is still a large mixed module. It owns raw serialization,
  normalized IR model, normalizer orchestration, and helpers. The next cleanup
  is to split model/raw serialization/orchestration without changing behavior.
- `Document.root` and `FunctionDef.body` still expose projected `RawNode`
  compatibility data. Production fact engines no longer use it, but the public
  schema still carries it.
- `syntax/local_flow.rs` still uses normalized source text heuristics for local
  contracts and comments. It no longer walks raw parser nodes and no longer
  owns concrete conditional keywords, but source-text heuristics should stay
  under review.
- `syntax/normalized_ruby.rs` is now the visible owner for Ruby lexicons and
  metadata hooks. That file should be monitored for becoming a detector engine
  rather than a behavior/lexicon provider.

## Enforced Invariants

- `syntax/adapters` must not exist.
- Every supported language must have an `ast/adapters/<language>.rs` normalizer.
- `syntax/tree_sitter_adapter.rs` must call normalized passes and must not own
  raw collection engines.
- `syntax/normalized_extractor.rs` must not reference concrete languages,
  parser APIs, stateful enrichment, or language lexicons.
- `syntax/clone_similarity.rs` must consume normalized IR only.
- Generic syntax files must not reintroduce `LanguageProfile`,
  `false_simplicity_lexicon`, `materialize_protocol_facts`, `raw_tree`, or
  `syntax/adapters`.
- Generic syntax files must not own concrete guard predicate spellings or Ruby
  metadata spellings; those belong in `normalized_<language>.rs`.
- Decomplex detectors and post-syntax consumers must not inspect raw syntax,
  normalized syntax, parser internals, adapter internals, or language branches.
- Decomplex `decision_pressure` must not own guard method names or safe-nav
  classification; it consumes `eliminable_guard` semantic effects.

## Viability Read

After the aggressive move, Rust is much closer to the Ruby architecture. The
remaining per-language cost should live in:

- `ast/adapters/<language>.rs` for grammar normalization.
- `syntax/normalized_<language>.rs` for behavior hooks, metadata quirks, and
  language vocabulary.

The major risk is not the generic pass architecture anymore; it is per-language
normalization and vocabulary coverage. Each language owns its vocabulary
explicitly in its normalized behavior file. Reintroducing central
cross-language lexicons or detector-owned method names would hide per-language
cost again and is not allowed.
