# Cross-System Fact Oracle Design

Status: WIP design for the Ruby-vs-Rust Decomplex parity work.

## Problem

The current test stack lets Rust drift into detector-owned fact generation. That is an architectural failure. Detectors must consume already-normalized facts. If a detector needs to walk raw Tree-sitter nodes, normalized AST roots, language profiles, or language-specific syntax, the required fact is missing from the syntax layer and must be added there first.

The test suite must prove fact generation before it proves detector scoring. A detector oracle that only checks the final finding is too late and too coarse; it can hide incorrect or missing facts, duplicated mining code, and detector-specific language hacks.

## Required Oracle Layers

Blocking rule: do not continue detector parity, report parity, SARIF parity, or real-repo end-to-end parity until source-level fact generation integration tests exist for every fact consumed by detectors and those tests run against both Ruby Decomplex and Rust Decomplex.

1. Source fact oracle
   - Input: source file in a real language.
   - Engines: Ruby Decomplex and Rust Decomplex.
   - Output: exact canonical fact projection.
   - Purpose: prove that adapters and syntax modules generate the same facts from source.

2. Normalized fact JSON oracle
   - Input: language-neutral JSON fact set.
   - Engines: Ruby detector/report pipeline and Rust detector/report pipeline.
   - Output: exact detector/report/SARIF/root-cause/convergence projection.
   - Purpose: prove detector consumers behave the same once facts are correct.

3. End-to-end repository parity
   - Input: real repos.
   - Engines: Ruby full pipeline and Rust full pipeline.
   - Output: byte-for-byte report/json/SARIF where supported.
   - Purpose: acceptance only. This must not be the primary way bugs are discovered.

## Fact Generation Contract

Every fact that any detector consumes must have source-level oracle coverage:

- `function_defs`
- `owner_defs`
- `call_sites`
- `state_reads`
- `state_writes`
- `state_declarations`
- `state_param_origins`
- `decision_sites`
- `branch_decisions`
- `dispatch_sites`
- `comparison_uses`
- `semantic_effect_sites`
- `predicate_defs`
- `path_condition_sites`
- `local_methods`
- `local_complexity_scores`
- `clone_candidates`
- `protocol_method_effects`
- `protocol_call_paths`
- `redundant_nil_guard_findings`
- language-specific optional contract facts such as immutable reader/type alias facts

If a detector needs a new input, the change order is:

1. Add or extend the syntax fact type.
2. Add source fixtures for at least Ruby and any language being touched.
3. Add exact Ruby-vs-Rust source fact oracle assertions.
4. Update the detector to consume that fact.
5. Add or extend normalized fact JSON detector oracles.

No detector may add fallback fact mining.

## Ruby Source Fixtures Needed First

These Ruby fixtures should live under `gems/decomplex/examples/source-facts/ruby/` and each should have an exact oracle under `examples/source-facts/oracles/`.

- `state_reads.rb`: receivers, chained receivers, self reads, globals, constants that must not become state, safe navigation when represented.
- `state_writes.rb`: instance/global writes, indexed writes, field writes, operator assignment, local writes that must not become state.
- `visibility.rb`: public/protected/private declarations, standalone visibility, symbol-list visibility, default public.
- `semantic_effects.rb`: hidden IO, dynamic dispatch, callback inversion, metaprogramming, context reads, `[]=`, `<<`, method hooks.
- `block_receiver_calls.rb`: block parameter receiver calls, nested block calls, iterator control metadata, without unrelated mutation noise.
- `locals_not_state.rb`: params, locals, `ENV[key]`, indexed local assignment receiver reads, assertion commands, block-local values, outer locals.
- `local_flow.rb`: reads, writes, dependencies, co-uses, boundaries, destructuring, loops, nested scopes, indexed/member writes.
- `nil_guards.rb`: prior non-nil proof, redundant `nil?`, safe navigation, branch dominance, termination.
- `path_conditions.rb`: nested guards, `&&`, modifier conditionals, case/when, guarded actions.
- `clone_candidates.rb`: function bodies, owner bodies, DSL wrapper bodies, fingerprint/mass behavior.
- `protocols.rb`: receiverless Ruby calls, bare readers, internal call paths, method effects, mutating calls, declarative/DSL calls that must not become protocol events.

The Ruby source-fact oracle should not collapse these to counts. It should assert the exact relevant rows and fields for each section under test.

## Cross-Language Happy Path Matrix

For each supported language, add at least one fixture per fact bucket that proves the language adapter emits the shared fact shape:

- functions/owners/calls
- state reads/writes
- local methods
- branch/path facts
- semantic effects
- clone candidates
- protocol facts where the language has receiverless calls or implicit receiver calls
- nil/null guard facts where the language supports the detector

Languages where function calls require `()` should not need Ruby-style bare-call protocol heuristics. Languages that allow omitted call delimiters or implicit receiver calls must solve that ambiguity in the adapter and prove it with source-fact fixtures.

## Normalized Fact JSON Path

The JSON fact fixtures under `gems/decomplex/examples/facts/` should cover detector consumers after normalization. These fixtures are language-neutral and should be shared by Ruby and Rust.

Required groups:

- `facts/local-flow/`: derived-state, locality-drag, function-LCOM, operational discontinuity, inconsistent rename clone, decision pressure.
- `facts/detectors/`: detectors that consume simpler direct facts.
- `facts/root-cause/`: root-cause ranking from a full detector fact set.
- `facts/convergence/`: convergence output from the same full detector fact set.
- `facts/report/`: markdown and JSON report output from the same full detector fact set.
- `facts/sarif/`: SARIF output from the same full detector fact set.

The normalized fact JSON must include the full fact set needed by the downstream stage, not a detector-specific stub that proves only that the current code repeats itself.

## Architecture Invariants

Rust must mirror Ruby's architectural guardrails:

- production detector modules must not import `tree_sitter`
- production detector modules must not import `syntax::adapters`
- production detector modules must not call `language_profile`
- production detector modules must not inspect `document.language`
- production detector modules must not read `document.root` or `document.normalized_root`
- production detector modules must not use `RawNode`
- production detector modules must not branch on `Language::Ruby`, `Language::Python`, or any other concrete language

If one of these invariants blocks a detector fix, the fix belongs in syntax/adapters or in a new fact type.

## CI Gates

The minimum CI gate before end-to-end repo parity work:

- Ruby architecture invariants pass.
- Rust architecture invariants pass.
- Ruby source-fact oracle passes for Ruby and Rust engines.
- Rust integration source-fact oracle passes without shelling through Ruby test assertions.
- Normalized fact JSON detector oracles pass for Ruby and Rust.
- Report/root-cause/convergence/SARIF JSON-input oracles pass for Ruby and Rust.
- No skips for supported fact buckets. Unsupported language/fact combinations must be explicit `unsupported` entries in the matrix, not skipped tests.

End-to-end repo parity should start only after these gates are green.
