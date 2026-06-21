# Ruby-Specific Code Budget Viability

## Question

Can Ruby-specific syntax and adapter code be reduced below 1,500 LoC without hiding complexity in helper files, dense formatting, generated-looking hand code, or non-idiomatic Ruby/Rust?

Can the Ruby source-fact fixtures be generalized enough to prove the compiler architecture scales beyond one language?

## Current Verdict

For the Rust compiler's Ruby path, yes: the Ruby-specific syntax/AST adapter code is now below the target.

For the whole repository, not yet: the legacy Ruby implementation still contains thousands of Ruby-specific syntax/normalization lines. If that implementation remains first-class, the total Ruby-specific maintenance budget is still blown.

The architectural direction is viable only if this boundary is preserved:

- Adapters normalize concrete grammar into the shared normalized schema.
- Generic fact extraction consumes only normalized data and extracted document facts.
- Adapters do not expose or implement detector fact engines.
- New Ruby helper files cannot be added to bypass the adapter boundary.

## Rust Compiler State

The Rust Ruby syntax adapter is now parser-only:

| File | LoC | Counted as Ruby-specific? | Role |
| --- | ---: | --- | --- |
| `rust/src/decomplex/syntax/adapters/ruby.rs` | 15 | Yes | Selects Ruby language enum and tree-sitter grammar. |
| `rust/src/decomplex/ast/adapters/ruby.rs` | 267 | Yes | Ruby grammar quirks for normalization into the shared AST schema. |
| `rust/src/decomplex/syntax/normalized_extractor.rs` | 1,154 | No | Shared normalized fact extractor. It imports no tree-sitter or concrete language. |
| `rust/src/decomplex/syntax/protocols.rs` | 220 | No | Shared protocol derivation from document facts. |

Rust Ruby-specific total:

| Scope | LoC |
| --- | ---: |
| Rust Ruby syntax profile only | 15 |
| Rust Ruby syntax profile plus AST adapter | 282 |

That is comfortably below 1,500 LoC.

## Legacy Ruby Implementation State

Measured with `wc -l` on 2026-06-21:

| File | LoC | Role |
| --- | ---: | --- |
| `lib/decomplex/syntax/ruby.rb` | 1,213 | Legacy Ruby syntax adapter. |
| `lib/decomplex/syntax/ruby_effects.rb` | 221 | Legacy Ruby-specific effect logic. |
| `lib/decomplex/syntax/ruby_protocols.rb` | 387 | Legacy Ruby-specific protocol logic. |
| `lib/decomplex/ast/adapters/ruby.rb` | 101 | Ruby AST adapter. |
| `lib/decomplex/ast/legacy_normalizer.rb` | 2,598 | Legacy normalizer. |

Legacy Ruby-specific total:

| Scope | LoC |
| --- | ---: |
| Legacy Ruby syntax files only | 1,821 |
| Legacy Ruby AST adapter plus legacy normalizer | 2,699 |
| Legacy Ruby syntax plus AST/normalizer | 4,520 |

If the legacy Ruby compiler remains in scope, the repository does not meet the <1,500 LoC target. The Rust compiler path now does; the legacy path does not.

## Architecture Now Enforced In Rust

The Rust architecture invariants now enforce the intended boundary:

- `syntax/adapters/ruby.rs` is parser-only.
- `syntax/adapters/mod.rs` cannot forward protocol/effect detector engines.
- `LanguageProfile` cannot expose detector fact-engine entrypoints.
- Concrete syntax adapters cannot define detector fact engines.
- `syntax/normalized_extractor.rs` cannot depend on tree-sitter, concrete languages, Ruby/Python/JS names, protocol types, or API lexicons such as `send`, `puts`, `ENV`, `File`, or `Dir`.
- `syntax/` has a fixed allowlist, so adding helper files requires deliberately updating an architecture invariant.
- Syntax subfiles cannot hide nested modules.
- Concrete profiles must live in their own language file.

This directly prevents the failure mode where a Ruby adapter grows private fact engines in side files.

## Normalization Diagnosis

The original failure was not that Ruby could not be normalized. It was that fact production did not require normalized input.

Ruby used the raw adapter path to rediscover calls, effects, protocols, branches, state reads, and clone surfaces from unnormalized tree-sitter syntax. That turned the adapter into a private compiler.

The corrected Rust Ruby path is:

1. Parse Ruby with tree-sitter.
2. Normalize Ruby into the shared AST schema.
3. Extract structural facts from that normalized schema.
4. Derive semantic effects from normalized call facts.
5. Derive protocol facts from document facts and normalized/raw-projected function bodies.
6. Run detectors against generated facts only.

The shared normalized schema still uses legacy names such as `DEFN`, `SCOPE`, `CALL`, `IF`, and `CASE`. That vocabulary is ugly, but it is not Ruby-only: Python, JavaScript, and Ruby normalize simple examples into the same labels. Renaming the schema to more neutral names would improve readability, but it is not the same architectural problem as an adapter bypassing normalization.

## Remaining Project Risks

Non-Ruby Rust paths still use the older raw tree-sitter fact extraction path. Ruby has been fixed first, but the project is not globally normalized-only until the remaining languages move to the same normalized extractor.

Effect lexicons still exist as language/API data under shared syntax support. They are no longer in the normalized extractor or Ruby adapter, and Ruby consumes them from normalized call facts. This is acceptable as profile data, but not as adapter-owned traversal logic.

The legacy Ruby implementation remains oversized and split across Ruby-specific syntax/effect/protocol files. If that implementation stays active, it needs the same boundary treatment or should be explicitly deprecated.

## Fixture Generalization Audit

There are 27 Ruby source-fact fixtures under `examples/source-facts/ruby`.

Existing reusable fixture infrastructure already exists:

- Cross-language detector fixtures under `examples/<language>`.
- Shared detector oracles under `examples/oracles`.
- Fact-level fixtures under `examples/facts`.
- Syntax-fact fixtures under `examples/syntax-facts`.

Classification:

| Category | Count | Meaning |
| --- | ---: | --- |
| Generalizable now | 17 | The behavior is language-neutral compiler behavior. |
| Mixed with reusable core | 5 | Split the generic behavior from Ruby syntax spelling. |
| Ruby-specific | 5 | Keep as Ruby-only grammar coverage. |
| Total | 27 | Current Ruby source-fact fixture count. |

At least 22 of 27 fixtures have reusable value if split correctly. That is a large enough generalization win to continue the project, provided new fixture work is gated.

## Fixture Migration Plan

Move pure detector behavior into `examples/facts`:

- `local_flow_edges`
- `branch_predicate_paths`
- `predicate_bodies`
- Generic portions of `protocols_nil_clone`
- Generic portions of `semantic_effects`
- Generic portions of `sequence_call_edges`

Move syntax-normalization behavior into cross-language `examples/syntax-facts`:

- `block_receiver_calls`
- `branch_nested_scope_refs`
- `receiver_attribute_local_flow`
- `state_reads`
- `state_read_chains_and_constants`
- `indexed_state_reads`
- Generic portions of `visibility`

Keep Ruby-only source fixtures for irreducible Ruby grammar:

- `implicit_self_chain_state_reads`
- `implicit_self_predicate_branch_refs`
- `memoized_helper_calls`
- `modifier_return_path_conditions`
- Ruby-specific portions of `visibility`, `semantic_effects`, and `sequence_call_edges`
- `slopcop_parity_edges`, if project parity remains a test goal

## Continue Or Pause Decision

Continue Rust Ruby normalization work because the current refactor shows the intended architecture can hold and the Rust Ruby-specific code is now 282 LoC.

Pause language expansion if any of these are rejected:

- Keep the Rust architecture invariants in CI.
- Migrate non-Ruby Rust fact extraction to normalized data.
- Split the reusable Ruby source-fact fixtures into shared fixture families.
- Either refactor or deprecate the legacy Ruby implementation.

The project cannot scale if every language gets a private compiler. The Rust Ruby path now demonstrates the salvage path: normalize first, extract facts generically, and make adapter escape hatches fail architecture tests.
