# Cross-Language Fixture Commit Audit

Audited commit: `cda67cd87` (`Add cross-language decomplex oracle fixtures`).

This document flags places where the commit moved in the right direction
functionally, but still leaves architecture and oracle precision gaps that
should be fixed before treating the new language support as real parity.

## Architecture Flags

These are places where language-specific parser quirks are still in
detectors or in the base syntax normalizer. New languages will keep forcing
edits in these same files unless these become adapter responsibilities.

### 1. Base `TreeSitterLanguageAdapter` Is Still A Cross-Language Grammar Table

`gems/decomplex/lib/decomplex/syntax.rb` contains many raw grammar node
names in the base adapter:

- `call_target` matches `function_call`, `method_call`, `dot_index_expression`,
  `variable_list`, `identifier`, and `simple_identifier` directly in the base
  adapter (`syntax.rb:380-387`).
- `function_params` has grammar-specific parameter list handling for
  `method_declaration`, `function_value_parameters`, and direct `parameter`
  children (`syntax.rb:666-681`).
- `generic_function_body_node` and `generic_function_body_statements` know
  about `function_body`, `statement_block`, `compound_statement`,
  `declaration_list`, `statements`, and `statement_list` (`syntax.rb:763-788`).
- local read/write extraction knows about wrapper nodes such as
  `argument`, `pattern`, `directly_assignable_expression`, `value_argument`,
  `property_declaration`, `short_var_declaration`, and
  `local_variable_declaration` (`syntax.rb:814-995`).
- branch/case normalization knows raw wrapper kinds and tokens such as
  `block`, `body_statement`, `statements`, `statement_list`, `case`, `match`,
  `switch`, and `when` (`syntax.rb:1735-1803`).
- state/member extraction embeds grammar node names such as
  `navigation_expression`, `directly_assignable_expression`,
  `dot_index_expression`, and `variable_list` (`syntax.rb:2367-2496`).

Expected direction: each adapter should map its parser's AST nodes into
language-neutral roles such as `body`, `statement`, `local_declaration`,
`assignment_lhs`, `field_access`, `call`, `call_arguments`, `branch`,
`case_arm`, and `state_target`. Detectors and the base adapter should consume
those roles, not raw grammar names.

### 2. Base Syntax Still Contains Language Text Rules

Some rules are textual language conventions, not generic syntax:

- Lua comments are added through a hard-coded `--` prefix in
  `generic_source_boundary` (`syntax.rb:869-876`).
- `self`/`this` normalization is hard-coded globally
  (`syntax.rb:2576-2579`).
- declaration/type parsing strips a mixed set of language keywords
  (`public`, `private`, `protected`, `internal`, `static`, `readonly`,
  `const`, `pub`, `mut`, `var`, `let`) in one regex (`syntax.rb:2312-2339`).
- namespace filtering hard-codes `std`, `builtin`, `build_options`, and
  capitalized dotted constants globally (`syntax.rb:2471-2476`).

Expected direction: comment delimiters, self receiver names, visibility/type
modifiers, and namespace conventions should live in the language adapter or a
per-language lexicon.

### 3. `FlaySimilarity` Contains Its Own Language Vocabulary

`gems/decomplex/lib/decomplex/flay_similarity.rb` directly enumerates raw
Tree-sitter grammar node kinds:

- identifier, literal, skip, clone candidate, body, and call kind lists
  (`flay_similarity.rb:25-52`);
- candidate selection by raw node kind (`flay_similarity.rb:266-290`);
- call/message normalization for `argument_list`, `arguments`, `call_suffix`,
  `navigation_expression`, `directly_assignable_expression`, and
  `navigation_suffix` (`flay_similarity.rb:343-369`).

Expected direction: Flay should fingerprint normalized semantic nodes or a
syntax-provided structural stream. Adding a language should not require adding
its node kinds to the detector.

### 4. `RedundantNilGuard` Reimplements A Mini Syntax Adapter

`gems/decomplex/lib/decomplex/redundant_nil_guard.rb` now operates through
Tree-sitter, but it reimplements body, branch, assignment, call, receiver,
nil-predicate, safe-navigation, and field-like normalization internally:

- body/statement wrappers: `statements`, `statement_list`
  (`redundant_nil_guard.rb:243-258`);
- branch wrappers/tokens: `if`, `unless`, `body_statement`, `block`,
  `statements`, `statement_list` (`redundant_nil_guard.rb:260-307`);
- call and receiver extraction for `call`, `call_expression`,
  `function_call`, `invocation_expression`, `method_invocation`,
  `method_call`, `argument_list`, `arguments`, `call_suffix`
  (`redundant_nil_guard.rb:351-419`);
- subject keys and field-like nodes include raw syntax names and `self`/`this`
  handling (`redundant_nil_guard.rb:422-538`).

Expected direction: this detector should consume normalized branch facts,
nil-check facts, safe-navigation facts, and local assignment facts from
`Syntax`/adapters. Otherwise every language with a different nil predicate or
safe-call spelling will keep changing this detector.

### 5. `WeightedInlinedCognitiveComplexity` Scores Raw Tree-Sitter Nodes

`gems/decomplex/lib/decomplex/weighted_inlined_cognitive_complexity.rb`
contains grammar-specific logic in the local scorer:

- boolean node kinds include `binary`, `binary_expression`,
  `boolean_operator`, `conjunction_expression`, `disjunction_expression`
  (`weighted_inlined_cognitive_complexity.rb:156-159`);
- branch/loop detection embeds `if_statement`, `if_expression`,
  `if_modifier`, `body_statement`, `block`, `statements`, `statement_list`,
  `for_statement`, `for_in_statement`, and text checks for `if`, `for`,
  `while`, `loop`, and `match` (`weighted_inlined_cognitive_complexity.rb:162-209`).

Expected direction: WICC should score normalized control-flow events produced
by syntax adapters, not inspect raw parser nodes.

### 6. `FatUnion` Parses Dispatch Semantics With Detector Regexes

`gems/decomplex/lib/decomplex/fat_union.rb` contains language-specific dispatch
normalization in detector code:

- variant constants are parsed with `CONSTANT_PATTERN` and
  `IF_DISPATCH_PATTERN` (`fat_union.rb:12-13`);
- `if` dispatch is inferred by regexing the predicate text
  (`fat_union.rb:69-105`);
- `case ` is stripped from arm text inside the detector
  (`fat_union.rb:133-135`).

Expected direction: syntax adapters should expose normalized dispatch sites:
subject, variant patterns, arm spans, and arm member reads. The detector should
only rank the product-vs-sum smell.

### 7. Protocol Normalization Splits Language Spellings In Generic Syntax

`gems/decomplex/lib/decomplex/syntax/protocols.rb` strips method names with
`split(/[.:]/)` for effects and calls (`syntax/protocols.rb:34`,
`syntax/protocols.rb:50`, `syntax/protocols.rb:62`).

Expected direction: adapters should expose normalized method names and receiver
paths. Generic protocol mining should not know that Lua uses `:` or that some
languages use dotted member paths.

## Oracle Specificity Flags

These projections were made less specific than they should be. They pass the
fixture matrix, but they do not prove enough about detector correctness.

### Must Tighten After Normalization Fixes

| Detector | Current projection | Why this is under-specific | Minimum target |
| --- | --- | --- | --- |
| `decision-pressure` | only `present` (`examples_oracle_test.rb:87-88`) | hides contract normalization drift such as `.symbol` vs `~local` and hides decision-count drift | assert normalized contract class/key, decision count, essential count, and method count |
| `fat-union` | only `present` (`examples_oracle_test.rb:153-154`) | hides common/variant member drift; Lua currently classifies `name`/`value` differently than Ruby | assert normalized `common`, `variant`, `degenerate`, `support`, and `scatter` |
| `function-lcom` | only `present` (`examples_oracle_test.rb:149-150`) | hides data-flow shape drift; Java produced a different component count/mode during development | assert mode, component count, and preferably local/component variable counts after local-flow normalization |
| `implicit-control-flow` | only presence for `ordered_protocols` and `order_drift` (`examples_oracle_test.rb:128-132`) | hides missing protocol edges and state names; Lua previously dropped the `validate -> commit` edge | assert protocol pair, dependency, state set, support, observed calls, and missing calls |
| `miner` | only `missing_abstractions` presence (`examples_oracle_test.rb:95-98`) | hides conjunction atom count and neglected-condition absence in some languages | assert kind, support, scatter, member count, and neglected-condition missing atom/pattern count |
| `path-condition` | only `present` (`examples_oracle_test.rb:145-146`) | hides duplicate findings and path atom drift; Python/Lua produced duplicate rows during development | assert exact neglected count and normalized pattern atom count |
| `state-branch-density` | one present row per finding (`examples_oracle_test.rb:114-117`) | does not prove the detector associated branches with the intended state | assert normalized state refs, branch count/density bucket, and method/finding count |
| `state-mesh` | only `state_mesh.present` (`examples_oracle_test.rb:120-121`, `examples_oracle_test.rb:169-171`) | hides field-name/count drift; several languages produced fields `a,b` where Ruby projected one field | assert normalized total fields and normalized field set once field declarations/read/write parity is fixed |
| `structural-topology` | only graph presence (`examples_oracle_test.rb:162-163`) | hides method count, call edge multiplicity, and missing loop/conditional edge kinds | assert method count and normalized unique edge types or a normalized edge multiset |
| `temporal-ordering-pressure` | only `present` (`examples_oracle_test.rb:110-111`) | does not prove the same lifecycle ordering was found | assert normalized owner, method sequence/orderings, and supporting method count |

### Also Too Loose

| Detector | Current projection | Risk | Minimum target |
| --- | --- | --- | --- |
| `semantic-alias` | only alias cluster name count (`examples_oracle_test.rb:99-104`) | removed the reification-miss check to pass languages where the miss was not normalized | restore a normalized reification-miss presence/count check |
| `redundant-nil-guard` | `rows(...).uniq` (`examples_oracle_test.rb:118-119`) | hides duplicate reports for the same local; duplicates are likely detector bugs | assert exact count after the detector dedupes by span/local/guard |
| `flay-similarity` | prefers `defn` findings and ignores nested clone findings when present (`examples_oracle_test.rb:105-112`) | acceptable as a first top-level clone check, but it will not catch excess nested clone noise | keep the `defn` assertion, add a max/noise assertion once structural fingerprints are normalized |

### Structured Enough For Now

The following projections still assert detector-specific normalized content and
are not the immediate problem: `co-update`, `derived-state`,
`false-simplicity`, `inconsistent-rename-clone`, `local-flow`,
`locality-drag`, `operational-discontinuity`, `oversized-predicate`,
`predicate-alias`, `sequence-mine`, and `weighted-inlined-complexity`.

## Recommended Repair Order

1. Move syntax role extraction out of the base adapter into per-language
   adapters: body statements, calls, arguments, member access, branch/case
   arms, local declarations, assignments, comments, self receivers, and
   visibility/type modifiers.
2. Add normalized syntax facts needed by detectors: nil guard facts, structural
   fingerprint nodes, control-flow events, dispatch variants, and protocol
   paths.
3. Delete detector-local grammar vocabularies from `FlaySimilarity`,
   `RedundantNilGuard`, `WeightedInlinedCognitiveComplexity`, and `FatUnion`.
4. Tighten the oracle projections in the table above and regenerate shared
   oracle JSON only after the normalization makes the expected values stable
   across Ruby, Rust, Zig, and the newly added languages.
