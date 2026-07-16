# Self-Hosting Preparation

Status: immediate work first; speculative translation work deferred

## Goal

Prepare the Ruby lexer and parser for eventual translation to CLEAR without
turning preparation into a separate architecture project.

Work starts with improvements that are already justified by current source,
coverage, mutation results, and analyzer findings. Translation-specific
redesigns that require new infrastructure or broad dependency changes are not
prerequisites for beginning useful work. They should be proposed only after
the concrete cleanup is complete and its effect is measured.

## Immediate work

### 1. Close known test gaps

The frontend already has high line coverage, but its branch and mutation
coverage show concrete gaps:

| Component | Line coverage | Branch coverage | Pre-pass mutation signal |
| --- | ---: | ---: | ---: |
| Lexer | 99.56% | 90.00% | 76.22% |
| Parser | 99.22% | 91.71% | 50% advisory |
| Parser rules | 100% | 75.00% | not measured separately |
| Type | 96.25% | 85.90% | 24.86% advisory |
| Type-expression parser | 100% | 92.65% | not measured separately |
| AST | 99.17% | 84.00% | not measured separately |

The parser and Type mutation numbers are partly affected by poor mutation-test
selection, so the first action is to identify the exact uncovered branches and
surviving mutants rather than create a new test organization system.

Add tests in this preference order:

1. transpile tests when execution through the compiler is the relevant oracle;
2. existing fuzz matrices or a focused new fuzz dimension;
3. compiler specs that parse or compile CLEAR source strings;
4. direct unit tests only when the behavior is not reasonably observable from
   CLEAR source.

All compiler specs must run through `prspec`.

Priority behavior includes:

- lexer token boundaries, suffixes, interpolation, malformed termination, and
  exact source positions;
- parser type/capability syntax, function and extern declarations, generic
  lookahead, unions, ambiguous collection syntax, and error recovery;
- type-expression nesting, tense preservation, collection composition, and
  capability placement;
- parser progress and no-replay behavior on malformed and nested input;
- exact diagnostic codes, spans, and fixable replacements where applicable.

Do not reorganize the entire test suite up front. Split or move a test only
when working on behavior that is obscured by its current placement. The mixed
`ast_coverage_burndown_spec.rb` should be reduced opportunistically as its
cases are replaced by appropriately located source-driven tests.

### 2. Make obvious typed-contract cleanups

After characterization tests are in place, make the small improvements already
supported by current evidence:

- remove redundant `T.must` calls where the preceding contract is total;
- remove deterministic type/nil guards proven redundant by Sorbet or NilKill;
- replace the fixed-schema mutable extern-effects hash with a named typed
  record;
- replace remaining small parser-local record-shaped hashes or positional
  tuples when their schema and consumers are already unambiguous;
- consolidate duplicated grammar code only where both paths already have the
  same behavior and source-driven tests;
- preserve monotonic cursor progress and the current removal of parser replay.

These changes should not alter the CLEAR grammar, AST contract, diagnostics,
or semantic type rules. If an apparently small cleanup requires changing one
of those, stop and classify it as deferred work.

### 3. Check concrete complexity risks

Espalier currently reports incomplete possible quadratic components in lexer
balanced/interpolation scanning and type-expression splitting. Do not redesign
those paths merely from an incomplete static result.

Add small geometric scaling regressions for the specific methods. If doubling
input produces convincing superlinear behavior, fix the repeated scan in a
separate commit. If it does not, retain the regression and record the Espalier
completeness gap.

The prior exponential statement-parser replay is already fixed. Preserve a
regression that would fail if recursive cursor replay returns.

## Verification for each change

Each implementation commit should run, in proportion to its scope:

- the focused compiler specs through `prspec`;
- relevant transpile tests;
- the affected fuzz template or shard;
- focused line and branch coverage;
- focused mutation testing;
- NilKill, Decomplex, and Espalier on the changed frontend files.

New warnings in changed code must be resolved. When a material improvement is
not reflected by an analyzer, record the minimized example as feedback for the
gem instead of adding compiler complexity to satisfy the metric.

The immediate work is complete when:

- changed executable lines have 100% line coverage;
- known uncovered frontend behavior has direct assertions;
- no critical surviving mutant changes tokens, parser progress, AST shape,
  type syntax, or diagnostics unnoticed;
- the obvious typed-contract and deterministic-guard findings are resolved;
- no measured complexity regression is introduced;
- existing language behavior remains compatible.

## Immediate pass completed

The first pass deliberately changed no CLEAR grammar, AST compatibility
shape, or semantic type rule. It made the following concrete improvements:

- added lexer assertions for every operator/punctuation token, every numeric
  suffix and integer upper bound, escape decoding and malformed escapes,
  token-boundary ambiguity, exponent associativity, and exact error position;
- added source-driven parser coverage for extern-effect record projection and
  invalid effect/qualifier diagnostics, plus rule-registration and
  power-expression invariants;
- fixed mutation selection so token-payload tests participate in the Lexer
  subject;
- added a method-scoped parser mutation contract instead of mapping every
  parser test to the entire `ClearParser` class (which caused nearly every
  mutation to time out and produced a meaningless score);
- replaced the parser's mutable anonymous extern-effects hash with
  `ParsedExternEffects`, while preserving the legacy AST hash at the boundary;
- extracted extern-effect parsing from `parse_extern_fn`;
- fixed type-source reconstruction that could duplicate collection
  capabilities and silently drop `@observable`;
- measured deeply nested string interpolation, confirmed quadratic rescanning
  and recursive stack growth, and bounded interpolation nesting to 64 levels
  so the lexer has a finite O(64N) worst case for that path;
- removed redundant `T.must`, `is_a?`, `respond_to?`, and impossible nil
  guards proven total by signatures and NilKill;
- preserved the no-replay parser regressions for token peeks and expression
  parses.

Verification from this pass:

- 100% line coverage on added executable compiler code (8/8 Lexer and 63/63
  parser lines; the Type change only deletes a guard);
- the full non-integration compiler suite passes (6,613 examples);
- Sorbet passes;
- focused fuzzing passes 46/46 cases across extern boundaries, capability
  wrapping, and tuple/collection composition;
- focused mutation coverage is 99.72% for the changed Lexer slice (733/735
  killed), 85.42% for the changed parser slice (1,184/1,386 killed), and
  96.00% for the changed Type slice (24/25 killed); the parser result rose
  from 52.74% after adding behavior-specific method contracts;
- NilKill reports zero dead-nil checks and zero deterministic guards over
  Lexer, parser, Type, and type-expression code;
- Decomplex no longer places `parse_extern_fn` in cross-detector convergence
  after effect parsing is extracted, though it retains a lower-confidence
  late-join candidate;
- Espalier sees `parse_extern_effects` as linear and no longer reports the
  old exponential parser replay, but remains incomplete for indexed token
  predicates and propagated frontend calls. It correctly pointed toward the
  nested-interpolation rescan, but does not account for the new explicit depth
  budget when describing the resulting worst case.

## Deferred work to assess afterward

The following ideas may be valuable, but are deliberately not prerequisites
for the immediate work:

- separating parsed type syntax completely from semantic `Type`;
- moving every Zig-rendering concern out of `Type`;
- reducing the full parser dependency closure before translating any file;
- building full-corpus canonical Ruby-versus-CLEAR AST infrastructure;
- translating all parser dependencies as a single frontend package;
- adding CLEAR language features for Ruby block, rescue, narrowing, mutable
  pattern, scanner, or reflection behavior;
- broad parser-rule or AST representation redesign;
- stage-one/stage-two bootstrap determinism infrastructure.

After the concrete work is finished, rerun Ruby-to-CLEAR on the smallest useful
lexer/parser slices. Report the remaining failures divided into:

1. ordinary Ruby cleanup;
2. general Ruby-to-CLEAR defects;
3. missing standard-library/runtime support;
4. genuine CLEAR language gaps;
5. broad architectural changes whose benefit is still speculative.

Only then decide which deferred item earns its upfront cost.

## Constraints

- Do not add an inventory, manifest, or new test-classification framework.
- Do not replace the parser or introduce a parser generator.
- Do not change the language to make Ruby translation convenient.
- Do not accept cursor replay, unbounded speculative backtracking, or
  exponential parsing.
- Do not require full self-hosting infrastructure before improving production
  Ruby code.
- Keep characterization, cleanup, behavior change, translator change, and
  language change in separate commits.
