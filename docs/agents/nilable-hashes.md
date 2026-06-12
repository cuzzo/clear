# Nilable Hash Inventory

## Purpose

`T.nilable(T::Hash[...])` should be rare. Most "no entries" states are better represented by `{}` because optional hashes add nil checks, widen downstream contracts, and hide whether absence has semantics distinct from emptiness.

## Initial Count

- Total textual matches: 65
- Production/source matches under `src/`: 53
- `gems/nil-kill` report/spec/string-handling matches: 12
- Generated RBI matches: 0

Nil-kill specifically called out weak nilable-hash return contracts in LSP hover/RPC, method-analysis index-op lookup, parser `REQUIRES` parsing, fallible-return enforcement, diagnostic lookup, and generic type-argument inference.

## Final Status

- `src/`: 0 direct `T.nilable(T::Hash...)` signatures remain.
- `src/`: 0 direct `T.nilable(T::Array...)` signatures remain from the previous pass.
- Empty-map states now use `{}` defaults/factories or concrete typed caches.
- Truly optional "no result" APIs now return `T.nilable(<named result alias>)` instead of anonymous nilable hash contracts.
- Remaining whole-repo textual matches are nil-kill fixtures, nil-kill historical report output, nil-kill implementation string matching, and this inventory doc.

## Source Inventory Resolution

### Normalized To Empty Hashes

- `src/annotator/helpers/auto_inference.rb`: local declaration maps now use concrete hashes, including saved/restored local-decl state.
- `src/annotator/helpers/function_analysis.rb`: `requires_map` normalizes missing clauses to `{}`.
- `src/annotator/helpers/generic_analysis.rb`: generic type-argument inference returns a concrete substitution map.
- `src/backends/transpiler.rb`: exact-tier maps default to `{}`.
- `src/mir/lower/pipeline/pipeline_host.rb`: fiber capture maps default to `{}`.
- `src/mir/lower/pipeline/pipeline_lowering_bridge.rb`: fiber capture maps default to `{}`.
- `src/mir/lowering/schema_registry.rb`: schema merge inputs are concrete hashes.
- `src/mir/lowering/state.rb`: fiber capture symbols and FSM owned-result guards use empty hash factories.
- `src/mir/mir.rb`: background block captures default to `{}`.
- `src/mir/mir_lowering.rb`: fiber capture maps default to `{}`; imported module schema maps normalize nil to `{}` at the untyped importer boundary.
- `src/mir/mir_pass.rb`: body summaries default to `{}`.
- `src/mir/test_lowering.rb`: active stubs moved out of a loose ivar and into `MIRLoweringTestState#active_stubs`.
- `src/semantic/escape_analysis.rb`: body summaries and call-result fact maps default to `{}`.
- `src/tools/doctor.rb`: section-freeze resolution maps normalize to `{}`.
- `src/tools/stack_verifier.rb`: caller-provided function-node maps default to `{}`.

### Changed To Void

These signatures were accidental nilable-hash returns caused by implicit Ruby method return values. They now state the intended side-effect-only contract.

- `src/annotator/domains/lifetimes.rb`
- `src/annotator/helpers/effects.rb`
- `src/annotator/helpers/reentrance.rb`
- `src/annotator/helpers/union.rb`
- `src/annotator/phases/expression_domains.rb`
- `src/backends/importer.rb`
- `src/tools/multi_statement_linter.rb`

### Kept Optional, But Named

These APIs genuinely express "no result", so the result stays optional, but the hash shape is now named instead of anonymous.

- `src/ast/diagnostic_registry.rb`: `DiagnosticEntry`
- `src/annotator/helpers/method_analysis.rb`: `IndexOpDefinition`
- `src/lsp/hover.rb`: `HoverResponse`
- `src/lsp/rpc.rb`: `Message`, `Headers`
- `src/lsp/server.rb`: delegates the hover optional result through `HoverResponse`
- `src/mir/lowering/state.rb`: `ShardContextMap` for optional shard context
- `src/tools/lint_fix_rewriter.rb`: `Edit`
- `src/tools/method_rewriter.rb`: `Edit`
- `src/tools/stack_verifier.rb`: `CallGraphData`, `MainTierResult`

### Parser And Type Registry Cleanups

- `src/ast/parser.rb`: `parse_requires_clause` now returns a concrete requirements hash; family/reentrance parsing no longer exposes an optional hash return.
- `src/ast/parser.rb`: struct-body parsing returns a concrete field map.
- `src/ast/type.rb`: observable terminal/wrapper registries now use concrete typed cache constants instead of nullable hash ivars.
- `src/lsp/diagnostics.rb`: template regex cache is a concrete typed constant instead of a nullable hash ivar.

## Historical / Fixture Matches

These were not production compiler contracts and were left as-is.

- `gems/nil-kill/report.md`: historical report output from before this cleanup.
- `gems/nil-kill/spec/apply_spec.rb`: fixtures covering nil-kill rewrite behavior.
- `gems/nil-kill/spec/source_index_spec.rb`: fixture for nil-kill signature-target inference.
- `gems/nil-kill/lib/nil_kill/apply.rb`: string detection logic that must recognize old nilable-hash signatures.

## Verification

- `rg -n "T\\.nilable\\((T::Hash|Hash|T\\.Hash|T\\.hash)" src -S`: no matches.
- `rg -n "T\\.nilable\\((T::Array|Array|T\\.Array|T\\.array)" src -S`: no matches.
- `bundle exec srb tc`: pass.
- Focused `prspec` across stack verifier, pipeline backend coverage, LSP, rewrite tools, MIR lowering/gap burn, annotator, and transpiler: 1,198 examples, 0 failures.
- Full `bundle exec prspec`: 5,807 examples, 0 failures.
