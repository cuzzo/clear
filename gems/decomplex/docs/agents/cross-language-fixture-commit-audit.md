# Cross-Language Fixture Commit Audit

Audited commit: `cda67cd87` (`Add cross-language decomplex oracle fixtures`).

Status: resolved in the current working tree.

## Architecture Guardrails Added

- `spec/decomplex_architecture_invariants_spec.rb` adds a root RSpec static
  architecture guard matching the repo's existing invariant style.
- `gems/decomplex/test/architecture_invariants_test.rb` adds the same guard to
  the Decomplex minitest suite.
- The guards fail if detector files use raw Tree-sitter node APIs such as
  `children`, `named_children`, `child_by_field_name`, byte/point offsets,
  `TreeSitter*` classes, or raw node duck typing.
- The guards fail if `syntax.rb` starts hosting detector-specific syntax
  extension facts such as clone candidates, dispatch sites, nil guard facts,
  or local complexity facts.
- The guards fail if concrete language adapter implementations move back into
  `syntax.rb`, or if language profiles instantiate the base
  `TreeSitterLanguageAdapter` directly.

## Burned Down Architecture Items

- `FlaySimilarity` now consumes `document.clone_candidates`; parser-specific
  clone fingerprinting lives in `syntax/clone_similarity.rb`.
- `WeightedInlinedCognitiveComplexity` and `LocalityDrag` now consume
  `document.local_complexity_scores`; local scoring lives in
  `syntax/complexity.rb`.
- `RedundantNilGuard` now consumes `document.redundant_nil_guard_findings`;
  nil-guard parsing lives in `syntax/nil_guards.rb`.
- `DecisionPressure` now gets local assignment contracts through
  `document.local_contract_assignments`; contract extraction lives in
  `syntax/contracts.rb`.
- `FatUnion` now consumes `document.dispatch_sites`; dispatch extraction lives
  in `syntax/dispatch.rb`.
- Concrete language adapter behavior has moved from `syntax.rb` into
  `syntax/ruby.rb` and `syntax/adapters.rb`.

## Oracle Strength Restored

The shared example oracle now asserts detector-specific normalized content
instead of mere finding presence for the previously weak detectors:

- `decision-pressure`: contract, decision count, essential count, method count.
- `miner`: conjunction members, support, scatter, neglected-condition pattern.
- `semantic-alias`: normalized canonical predicate and reification miss count.
- `flay-similarity`: clone type, node kind, site count.
- `temporal-ordering-pressure`: owner, method counts, writer count, orderings,
  state fields, shared fields.
- `state-branch-density`: normalized method name, decisions, state refs.
- `state-mesh`: total fields/writes/reads/re-derivations and field names.
- `implicit-control-flow`: protocol pair, dependency, support, observed/missing
  calls, states.
- `path-condition`: normalized pattern, support, missing guard, action.
- `function-lcom`: mode, component count, local count, statement count,
  terminal join.
- `fat-union`: common members, variant members, degeneracy, support, scatter,
  variant set.
- `structural-topology`: method count and exact normalized edge rows.

## Verification

- `bundle exec rspec spec/decomplex_architecture_invariants_spec.rb`
- `bundle exec ruby -I gems/decomplex/test gems/decomplex/test/architecture_invariants_test.rb`
- `bundle exec ruby -I gems/decomplex/test gems/decomplex/test/examples_oracle_test.rb`
- `bundle exec ruby -I gems/decomplex/test -I gems/decomplex/lib -e 'Dir["gems/decomplex/test/*_test.rb"].sort.each { |path| require File.expand_path(path) }'`

Current result: all pass, including the full Decomplex suite with 0 skips.
