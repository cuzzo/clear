# Menhir-Inspired Grammar Manifest and Validator

## Status

Proposed design. This document specifies an independently reviewable grammar
model for CLEAR without replacing the hand-written parser or introducing a
runtime grammar-string interpreter.

The immediate parser modularization is complete. `ClearParser` keeps one token
cursor, one delimiter index, one frontend resource budget, one precedence
model, and one public parse entry point. Its implementation is separated into
the following grammar-domain components:

- `parser/statements_and_control_flow.rb`
- `parser/declarations_and_definitions.rb`
- `parser/expressions_and_postfix.rb`
- `parser/predicates_and_refinements.rb`
- `parser/types.rb`
- `parser/collections_capabilities_and_tenses.rb`
- `parser/state.rb`

The components reopen the same Sorbet-typed `ClearParser` class. This is
deliberate: Ruby mixins cannot call the parser's private host methods or access
its typed instance state without duplicating a large abstract interface or
using `T.unsafe`. The physical and ownership boundaries are now explicit while
the runtime object and static type remain unchanged.

## Decision summary

Build a static, language-neutral grammar manifest and a validator. Do not
generate the production parser from it in the first implementation.

The manifest will describe:

- terminal token identities;
- production entry conditions;
- sequences, alternatives, optional cells, and repetitions;
- statement and expression terminators;
- operator precedence and associativity;
- legal parsing contexts;
- named lookahead or semantic decisions where tokens alone are insufficient;
- the Ruby and future CLEAR parser methods implementing each production;
- approved ambiguities, with a reason and a regression-test reference.

The validator will detect nullable cycles, zero-progress repetitions,
unreachable alternatives, inconsistent precedence, missing terminators,
unmapped parser routes, and overlapping FIRST sets that are not resolved by an
explicit named decision.

This obtains the most useful Menhir properties for CLEAR today: an inspectable
grammar, systematic conflict discovery, and an implementation-independent
porting contract. It does not claim the formal completeness of an LR(1)
automaton when a production delegates to contextual Ruby predicates.

## Problem being solved

The Ruby parser can accept and reject programs consistently while the language
as a whole is still difficult to audit. Today, the grammar is distributed
among:

- lexer keyword and token definitions;
- statement, primary-expression, and suffix route tables;
- Pratt precedence code;
- individual `parse_*` methods;
- contextual lookahead helpers;
- legacy migration branches;
- annotator restrictions that users may perceive as syntax restrictions;
- examples, transpile tests, and fuzz templates.

This distribution creates three risks before self-hosting:

1. Two constructs can each work independently but have an undocumented or
   accidental interaction.
2. A CLEAR port can omit an uncommon alternative without any finite parser
   source file serving as a checklist.
3. A syntax change can update a parser method without updating precedence,
   terminators, formatter assumptions, or the other parser implementation.

Parser modularity reduces navigation cost, but it does not by itself prove
that the language is coherent. The manifest makes the language-level contract
separate from either parser implementation.

## Goals

1. Make every supported syntax production reviewable without reading parser
   control flow.
2. Detect grammar conflicts and non-progress conditions in CI.
3. Give the Ruby and self-hosted parsers the same versioned contract.
4. Make precedence, associativity, and terminators single-source data.
5. Identify every place where CLEAR needs contextual disambiguation and force
   that exception to have a name, rationale, and test.
6. Reuse the existing fuzz, transpile, oracle, and source-driven compiler tests
   as conformance evidence.
7. Keep normal parsing hand-written, direct, and performance-predictable.

## Non-goals

- Replacing `ClearParser` with Menhir, ANTLR, or another generated parser.
- Parsing grammar strings at compiler startup.
- Generating semantic AST construction code in the first implementation.
- Adding Csmith-style random whole-program generation.
- Adding new pairwise or three-way composition fuzz matrices as part of this
  project. Existing matrices should be indexed before new coverage is proposed.
- Implementing multi-error recovery, incremental parsing, or IDE parsing.
- Moving annotator/type-system validity rules into the syntax grammar.
- Proving semantic type-system soundness. The manifest concerns syntax and
  parser progress; semantic coherence needs separate type and capability laws.

## Why not adopt Menhir directly

Menhir builds LR(1) parsers from declarative grammars and provides conflict
analysis, incremental checkpoints, inspection, and error-handling facilities.
Those are valuable properties, but a direct adoption is a poor bootstrap fit:

- the production compiler is currently Ruby and the target implementation is
  CLEAR, while Menhir generates OCaml;
- CLEAR contains contextual decisions such as generic-angle lookahead,
  brace-literal classification, conditional refinement binding, and legacy
  migration syntax;
- semantic actions construct a large existing AST and diagnostic model;
- replacing the parser would combine grammar discovery, AST compatibility,
  diagnostic compatibility, and bootstrap work into one migration;
- generated-parser error locations and accepted malformed inputs would differ,
  even if valid programs remained compatible.

The relevant Menhir lesson is that the grammar and its conflicts are explicit
artifacts. CLEAR can obtain that property without coupling its compiler to an
OCaml parser generator.

## Artifact layout

Proposed files:

```text
compiler/grammar/
  schema.json                 # schema for the source manifest
  clear.grammar.json          # reviewed source of truth
  approved_conflicts.json     # explicit conflict waivers and test links
  generated/
    token_index.json          # normalized terminal index
    precedence.json           # normalized Pratt table
    production_index.json     # stable IDs and implementation mappings

compiler/ruby/grammar/
  loader.rb
  validator.rb
  first_sets.rb
  progress_checks.rb
  parser_route_checks.rb

compiler/spec/integration/
  grammar_manifest_spec.rb
```

JSON is intentionally used for the shared manifest. It is verbose, but it is
language-neutral, deterministic, schema-validatable, and consumable by both
Ruby and CLEAR without inventing a new grammar language. The compiler does not
load this file in production; validation and generated-index checks run at
development/CI time.

If hand-authoring JSON proves too review-hostile, a constrained YAML authoring
file may be evaluated later, with canonical JSON checked into the repository.
That is not part of the initial implementation because dual artifacts create a
drift risk.

## Manifest data model

### Terminals

A terminal is a structured token matcher, never a string to be interpreted:

```json
{"token": "KEYWORD", "value": "IF"}
```

Token-only matches omit `value`:

```json
{"token": "TYPE_ID"}
```

Every token kind and fixed keyword/value must exist in the lexer token index.

### Production cells

The schema supports a small closed set of cells:

- `terminal`: token matcher;
- `ref`: another production ID;
- `sequence`: ordered cells;
- `choice`: alternatives;
- `optional`: a nullable child;
- `repeat`: child, minimum, optional maximum, and optional separator;
- `context`: a child enabled only in a named parsing context;
- `decision`: a named contextual discriminator implemented by both parsers;
- `commit`: the point after which failure is a diagnostic rather than another
  alternative.

There is no general executable expression, callback, regex, or inline source
code in the manifest.

Representative shape:

```json
{
  "id": "if_statement",
  "contexts": ["statement"],
  "entry": [{"token": "KEYWORD", "value": "IF"}],
  "body": {
    "sequence": [
      {"terminal": {"token": "KEYWORD", "value": "IF"}},
      {"optional": {"ref": "branch_likelihood"}},
      {"decision": "conditional_refinement_or_expression"},
      {"choice": [
        {"terminal": {"token": "ARROW", "value": "->"}},
        {"terminal": {"token": "KEYWORD", "value": "THEN"}}
      ]},
      {"ref": "statement_body"},
      {"ref": "if_tail"}
    ]
  },
  "terminators": [
    {"token": "KEYWORD", "value": "ELSE_IF"},
    {"token": "KEYWORD", "value": "ELSE"},
    {"token": "KEYWORD", "value": "END"}
  ],
  "implements": {
    "ruby": "ClearParser#parse_if_statement",
    "clear": "Parser.parseIfStatement"
  }
}
```

The exact production should mirror the accepted language discovered during
implementation; the example shows the representation, not a grammar change.

### Contextual decisions

Some choices cannot be distinguished by a one-token FIRST set. Each such case
must use a stable decision ID. The initial expected set includes:

- `conditional_refinement_or_expression`;
- `hash_literal_or_value_block`;
- `generic_arguments_or_comparison`;
- `struct_literal_or_identifier`;
- `range_for_or_collection_for`;
- `match_destructure_or_inline_union_variant`;
- `type_prefix_or_expression_prefix`.

Each decision record contains:

- a prose invariant;
- maximum intended lookahead, or `delimiter_index` when paired delimiters are
  skipped;
- whether it consumes tokens;
- the Ruby helper implementing it;
- the future CLEAR helper implementing it;
- positive and negative test references;
- a complexity contract such as `O(1)`, `O(depth)`, or `O(tokens)`;
- a reason it cannot be expressed as an ordinary FIRST-set choice.

Unnamed priority is forbidden. An alternative may not win merely because its
parser branch happens to appear first.

### Precedence

All prefix, infix, and postfix operators are recorded in one table:

```json
{
  "operator": {"token": "KEYWORD", "value": "AND"},
  "fixity": "infix",
  "precedence": 30,
  "associativity": "left",
  "production": "logical_and"
}
```

The validator compares the manifest against the Ruby Pratt dispatch and later
against the CLEAR parser. Duplicate operator entries, missing associativity,
and contradictory precedence are errors.

### Terminators and progress

Every block/repetition production declares:

- the tokens that end it;
- whether the terminator is consumed locally or by its parent;
- its minimum token consumption per successful iteration;
- its EOF behavior;
- the diagnostic used for missing termination, when stable.

This makes accidental infinite loops and parent/child terminator disagreement
checkable without executing hostile input.

### Compatibility syntax

Legacy spellings and migration-only alternatives are tagged:

```json
{
  "stability": "migration",
  "canonical": "inline_list_type",
  "removal_issue": "...",
  "diagnostic": "..."
}
```

Compatibility alternatives participate in conflict checks but are reported
separately. This prevents a deprecated spelling from silently defining the
canonical grammar.

## Validator behavior

### Structural validation

The loader validates schema version, unique stable IDs, valid references,
known tokens, known contexts, and complete implementation mappings.

### FIRST and nullable analysis

The validator computes FIRST sets and nullability to a fixed point. It rejects:

- a `repeat` whose child can succeed without consuming a token;
- a cycle composed entirely of nullable productions;
- an optional cell inside an unbounded nullable repetition;
- alternatives with identical FIRST sets unless they name a decision or have
  an approved conflict;
- an unreachable alternative shadowed by an earlier committed alternative.

For contextual decisions, FIRST-set overlap is recorded as resolved rather
than erased. Reports therefore show how much of the grammar is token-driven
and how much relies on custom recognition.

### Precedence validation

The precedence checker rejects:

- an infix operator without associativity;
- multiple precedence values for the same token/context;
- an operator routed by the parser but absent from the manifest;
- a manifest operator absent from parser dispatch;
- a postfix form whose entry token is also an unresolved primary/infix
  conflict in the same context.

### Terminator validation

For every block production, the validator checks that:

- all child alternatives can stop at the declared terminators;
- child-owned and parent-owned consumption are not contradictory;
- EOF is either accepted explicitly or has a diagnostic contract;
- nested blocks do not accidentally treat an outer terminator as ordinary
  input.

This is conservative. A named contextual decision can discharge a false
positive, but it must document the invariant.

### Parser route validation

The Ruby adapter extracts the existing statement, primary, and suffix route
tables and compares them with manifest entry sets. It also verifies that every
`implements.ruby` method exists and belongs to the expected grammar-domain
file.

The CLEAR adapter will expose the same small route/implementation index. The
manifest validator does not parse either implementation's source to reconstruct
the grammar.

### Approved conflicts

Every unavoidable overlap has a stable conflict ID:

```json
{
  "id": "brace.hash_or_value_block",
  "productions": ["hash_literal", "value_block"],
  "decision": "hash_literal_or_value_block",
  "reason": "top-level assignment distinguishes value blocks",
  "tests": ["compiler/spec/integration/frontend_oracles_spec.rb"]
}
```

CI fails if a conflict disappears without removing its waiver, changes its
production set, or appears without a waiver. This makes the conflict file a
review queue rather than a blanket allowlist.

## Conformance with the existing test system

No new composition matrix is required for the initial implementation. The
validator should index existing evidence:

- fuzz template names and the grammar features they claim;
- transpile-test files that cover a production or decision;
- syntax AST golden fixtures;
- negative diagnostic fixtures;
- parse-format-parse equivalence cases;
- hostile-source regressions.

Evidence links are advisory at first. Once the manifest is complete, CI should
require every contextual decision, compatibility alternative, and approved
conflict to name at least one positive and one negative test.

The manifest is not treated as an execution oracle. Accepted source and AST
behavior remain defined by tests until both parser implementations conform.

## Rollout plan

### Phase 1: useful spine

Scope:

- schema and loader;
- lexer terminal index;
- statement/primary/suffix entry routes;
- complete Pratt precedence table;
- method/file mappings for the modular Ruby parser;
- duplicate/missing route checks.

Estimate: 700–1,100 implementation LoC, 600–1,000 manifest LoC, 300–500 test
LoC; approximately 4–7 engineering days.

Value: catches dispatch and precedence drift immediately and provides a
concrete port checklist without describing every production body.

### Phase 2: control flow and type grammar

Scope:

- IF/WHILE/FOR/MATCH and refinement productions;
- declarations and block terminators;
- type, collection, capability, and tense productions;
- FIRST/nullability/progress analysis;
- first approved contextual decisions.

Estimate: 1,200–1,800 implementation LoC, 1,500–2,500 manifest LoC, 700–1,100
test LoC; approximately 2–3 engineering weeks.

Value: audits the areas most likely to expose language incoherence and the
areas most costly to rediscover during self-hosting.

### Phase 3: complete syntax contract

Scope:

- remaining expressions, pipelines, test language, externs, effects, and
  compatibility syntax;
- terminator ownership checks;
- conflict-waiver lifecycle;
- test-evidence indexing;
- human-readable grammar/conflict reports.

Estimate: 900–1,500 implementation LoC, 1,500–2,500 manifest LoC, 600–1,000
test LoC; approximately 2–3 engineering weeks.

Value: one complete review artifact and CI drift detection for the Ruby parser.

### Phase 4: self-hosted parser conformance

Scope:

- CLEAR implementation mapping;
- generated normalized route/precedence index consumed by the CLEAR build;
- Ruby-versus-CLEAR token/AST/diagnostic differential checks;
- production-level port progress report.

Estimate: 500–900 shared-tooling/test LoC, excluding the CLEAR parser itself;
approximately 1–2 engineering weeks alongside the parser port.

### Total expected cost

For a complete, maintained validator: roughly 3,300–5,300 implementation LoC,
4,200–7,000 manifest LoC, and 2,100–3,600 test LoC. Expected elapsed effort is
5–8 engineer-weeks before self-host-specific integration, or 6–10 weeks
including Phase 4.

The first independently valuable checkpoint is Phase 1, not the complete
project. If Phase 1 cannot prevent real route/precedence drift at acceptable
maintenance cost, stop rather than building a larger shadow grammar.

## Expected gains

### Language coherence

- All syntax alternatives and known overlaps become reviewable.
- Optional/repeated constructs have explicit progress and termination laws.
- Context sensitivity becomes a finite named list instead of incidental code.
- Canonical and migration grammars become distinguishable.

### Self-hosting

- The manifest is a production-by-production port checklist.
- Ruby and CLEAR parsers can share token, precedence, and route indexes.
- Differential failures can name a production or decision instead of only an
  AST mismatch.
- The CLEAR port does not need to imitate Ruby file organization to preserve
  language behavior.

### Maintenance

- Operator and entry-token drift fails quickly in CI.
- Grammar reviews can occur without reconstructing control flow from methods.
- Documentation can render syntax summaries from stable structured data.
- Future valid-program generators can consume the manifest, although that is
  not a current goal.

## Costs and limitations

### Shadow-grammar risk

Because the manifest initially does not generate the parser, it can drift. The
route, precedence, method mapping, test evidence, and later differential checks
are mandatory mitigations. A prose-only manifest would not justify its cost.

### Contextual escape hatches

Named decisions weaken formal ambiguity guarantees. The validator can prove
that every overlap is acknowledged; it cannot prove arbitrary Ruby lookahead
code correct. The finite decision registry, complexity contracts, and tests
are therefore essential.

### Syntax is not the whole language

A conflict-free grammar does not prove coherent ownership, tense, capability,
or inference semantics. The grammar can show that combinations are expressible
and unambiguous, but semantic laws still belong to the annotator/type-system
specification and its matrices.

### Review volume

A full manifest will be several thousand lines. Stable IDs, domain-separated
ordering, generated indexes, and reports are needed to keep reviews local.

## Alternatives considered

### Full parser generator

Potential gain: formal LR conflict reports and generated state machines.

Expected cost: approximately 8–16 engineer-weeks for a prototype compatible
with valid programs, and potentially 3–6 months to reach AST, diagnostic,
migration, formatter, and hostile-input parity. It also creates a bootstrap
and implementation-language decision. This should not precede self-hosting
unless the manifest demonstrates that the current grammar is fundamentally
unsuitable for predictive hand parsing.

### Documentation-only grammar

Low implementation cost, but no drift detection, conflict checking, or port
status. It does not adequately address the stated coherence risk.

### Runtime grammar DSL

Concise authoring, but it adds a parser/interpreter inside the parser, obscures
performance, complicates bootstrapping, and makes static checking harder. It is
explicitly rejected.

### Csmith-style generation first

Could find cross-feature failures, but generated failures would still be hard
to classify while the grammar and contextual decisions are implicit. It is a
later consumer of this artifact, not the next step.

## Acceptance criteria

Phase 1 is accepted when:

- every statement, primary, and suffix route has exactly one manifest entry;
- every Pratt operator has one precedence and associativity definition;
- every mapped Ruby method exists in the expected parser component;
- CI rejects an unmapped route, duplicate operator, or stale implementation;
- validation adds less than five seconds to the normal static CI lane.

The full project is accepted when:

- every supported syntax production has a stable manifest ID;
- there are no nullable cycles or zero-progress repetitions;
- every FIRST-set overlap is resolved by a named decision or approved conflict;
- every block declares terminator ownership and EOF behavior;
- every contextual decision and approved conflict names positive and negative
  evidence;
- the Ruby parser passes all existing compiler, transpile, fuzz, hostile-source,
  AST-golden, diagnostic, and round-trip suites;
- the self-hosted parser can report conformance by the same production IDs;
- normalized AST differential tests pass for the production set declared as
  ported.

## Recommendation

Do not start with a complete grammar transcription. Implement Phase 1 after
the modular parser has settled. It is small enough to prove whether a static
manifest can remain synchronized and already captures the highest-value
Menhir-like benefits: explicit routes, explicit precedence, stable production
identity, and conflict visibility.

Proceed to Phases 2 and 3 only if Phase 1 catches real drift or materially
improves the self-host port. This keeps the project incremental and prevents a
large up-front grammar exercise from delaying compiler progress.
