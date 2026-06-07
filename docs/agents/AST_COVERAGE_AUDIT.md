# AST Coverage Audit

Generated: 2026-06-04

Scope: Ruby source files under `src/ast/`.

This document is the completed checklist for burning AST coverage down to
intentional line coverage. A file is checked only when all of the following are
true:

* missing lines are covered, or the code has been simplified/deleted because the
  branch was unreachable under the current parser/type contracts;
* the file has been reviewed against the AST architecture that the parser,
  annotator, and MIR boundary actually use;
* any architecture, brittleness, or correctness issue is fixed or deliberately
  recorded as follow-up work.

## Coverage Baseline

Initial coverage was generated from the same sources used for the MIR and
annotator audits: the RSpec suite, generated transpile tests, corpus transpile
coverage, and BC lowering sweeps.

Commands included in the baseline:

```sh
COVERAGE=1 COVERAGE_DIR=/tmp/cheat-ast-coverage-spec bundle exec prspec spec/
TRANSPILE_GEN_JOBS=4 COVERAGE=1 COVERAGE_ISOLATED=1 COVERAGE_DIR=/tmp/cheat-ast-coverage-unit bundle exec ruby transpile-tests/gen.rb
COVERAGE=1 COVERAGE_DIR=/tmp/cheat-ast-coverage-corpus bundle exec ruby tools/corpus_transpile_coverage.rb
COVERAGE=1 COVERAGE_DIR=/tmp/cheat-ast-coverage-unit bundle exec ruby tools/bc_lower_coverage.rb --jobs 4
COVERAGE=1 COVERAGE_DIR=/tmp/cheat-ast-coverage-unit bundle exec ruby tools/bc_lower_coverage.rb --jobs 4 --include-large
```

Initial collated baseline:

* Project line coverage: `98.51%`.
* Project branch coverage: `84.29%`.
* AST line coverage: `96.86%` (`6723 / 6941`).
* AST uncovered executable lines: `218`.

Post-burndown merged coverage:

* Project line coverage: `99.01%`.
* Project branch coverage: `85.05%`.
* AST line coverage: `100.00%` (`6928 / 6928`).
* AST uncovered executable lines: `0`.
* Collated resultset count: `9`.

Final verification:

* RSpec: `5358 examples, 0 failures`.
* `transpile-tests/gen.rb`: `470` files processed.
* Corpus transpile: `185` transpiled, `3` skipped by the driver.
* BC lowering sweep: `681` eligible files attempted across four shards, with
  `4` files skipped for size in the non-large sweep.
* BC lowering include-large sweep: all `685` eligible files attempted across
  four shards; raised files were counted as coverage up to the raise.

## Architecture Reality Check

There is currently no `src/ast/README.md`. The AST architecture is inferred from
the front-end call chain and downstream consumers:

* `Lexer` tokenizes CLEAR source into `Lexer::Token` values.
* `Parser` consumes tokens and builds the node catalog in `AST`.
* `AST::Locatable` stores source location, storage, type, and capability
  metadata that later phases stamp or read.
* `Type`, `Schemas`, `Scope`, and `SymbolEntry` provide the semantic shape
  model used by the annotator and MIR lowering.
* Diagnostic registries and fixable-diagnostic helpers keep parser/annotator
  errors consistent and machine-actionable.
* `StdLib` and `ErrorRegistry` provide built-in signatures and error-family
  metadata at the language boundary.

The implementation mostly follows that architecture, but the lack of a README
is a real documentation gap. The next architecture pass should add one that
spells out the front-end boundary, the AST metadata ownership rules, and the
division between parse-only syntax nodes and annotator-stamped semantic facts.

Architecture tension to keep watching:

* `parser.rb`, `ast.rb`, and `type.rb` are large central files. They are working,
  but their size makes grammar and semantic-shape changes easy to scatter.
* Parser compatibility branches exist for parser-only token streams and direct
  private helper calls. Those branches are now covered, but they should remain
  rare and explicitly justified.
* `DiagnosticBuckets#frequency_stars` returns Unicode stars while its old
  comment described ASCII stars. The behavior is covered; the comment should be
  cleaned when this helper is next edited.
* `StdLib` mixes data registry entries with validator lambdas. It is acceptable
  today, but validators should stay small and table-local.

## File Checklist

Grade scale: `A` = focused and low-risk; `B` = solid but complex or
transitional; `C` = working but structurally overloaded or brittle.

| Done | File | Coverage | Missing lines | Grade | Findings |
| --- | --- | ---: | ---: | --- | --- |
| [x] | `src/ast/ast.rb` | `100.00%` | `0` | `B-` | Closed by covering direct typed readers/writers, child walkers, test body enumeration, storage finalization without a value node, and Locatable storage/type helpers. The file is the broad AST node catalog and is too large, but the metadata helpers are coherent. |
| [x] | `src/ast/async_result_shape.rb` | `100.00%` | `0` | `A` | Focused value object for async result shape. No dead code or architecture issue found. |
| [x] | `src/ast/diagnostic_buckets.rb` | `100.00%` | `0` | `B` | Closed by covering bucket coverage, status derivation, frequency stars, and alien-risk labels. Minor doc mismatch remains: the helper returns Unicode stars despite an ASCII-oriented comment. |
| [x] | `src/ast/diagnostic_examples.rb` | `100.00%` | `0` | `B+` | Closed by covering malformed example annotations with comments but no `describe`. Useful scanner, but inherently coupled to spec annotation formatting. |
| [x] | `src/ast/diagnostic_registry.rb` | `100.00%` | `0` | `B+` | Closed by covering pending lookup paths. Large table is appropriate as long as it stays data-only. |
| [x] | `src/ast/error_registry.rb` | `100.00%` | `0` | `A-` | Focused registry for error families and stdlib/custom error metadata. No issue found. |
| [x] | `src/ast/fixable_error.rb` | `100.00%` | `0` | `B+` | Closed by covering span serialization, fix validation, and fatal collector state. Process-global collector state is intentional but must be reset carefully in tests. |
| [x] | `src/ast/lexer.rb` | `100.00%` | `0` | `B` | Closed by covering suffixes, float suffix errors, escape handling, and interpolation/string errors. Removed unreachable string and integer-suffix fallback branches shadowed by existing guards. |
| [x] | `src/ast/parser.rb` | `100.00%` | `0` | `C+` | Closed by covering parser helper edges, OR fallbacks, IF expression parsing, bare mutable errors, match/while shorthand, concurrent ops, capability joins/ranks, WITH escape metadata, error handlers, benchmark parsing, asserts, and stubs. Removed unreachable duplicate `OR EXIT` handling and a dead generic-lookahead guard. This remains the main AST architecture hotspot. |
| [x] | `src/ast/schemas.rb` | `100.00%` | `0` | `A-` | Focused typed schema records for structs, enums, unions, and extern structs. No issue found. |
| [x] | `src/ast/scope.rb` | `100.00%` | `0` | `A-` | Focused lexical/type/function scope owner. No burn-down change needed. |
| [x] | `src/ast/source_error.rb` | `100.00%` | `0` | `A-` | Focused source-diagnostic formatter. No issue found. |
| [x] | `src/ast/std_lib.rb` | `100.00%` | `0` | `B-` | Closed by covering stdlib validator fallbacks. Registry is large and mixes data with small validation lambdas; keep validators local and avoid expanding this into control flow. |
| [x] | `src/ast/symbol_entry.rb` | `100.00%` | `0` | `B` | Closed by covering lifetime/state helpers and protected flow snapshots. Good symbol fact carrier, but mutability should stay disciplined because many phases read and write it. |
| [x] | `src/ast/syntax_typo_scanner.rb` | `100.00%` | `0` | `A-` | Focused typo/fixable scanner. No issue found. |
| [x] | `src/ast/type.rb` | `100.00%` | `0` | `B-` | Closed by covering capability suffix parsing, type shape copying, copyability fallbacks, future/stream acceptance, array acceptance, raw shape coercion, and Zig type edges. Removed an unreachable fixed-array capacity fallback already guaranteed by `fixed?`. The file remains large and mixes type parsing, compatibility, storage, and Zig rendering concerns. |

## Missing Line Detail

| File | Missing executable lines |
| --- | --- |
| `src/ast/ast.rb` | none |
| `src/ast/async_result_shape.rb` | none |
| `src/ast/diagnostic_buckets.rb` | none |
| `src/ast/diagnostic_examples.rb` | none |
| `src/ast/diagnostic_registry.rb` | none |
| `src/ast/error_registry.rb` | none |
| `src/ast/fixable_error.rb` | none |
| `src/ast/lexer.rb` | none |
| `src/ast/parser.rb` | none |
| `src/ast/schemas.rb` | none |
| `src/ast/scope.rb` | none |
| `src/ast/source_error.rb` | none |
| `src/ast/std_lib.rb` | none |
| `src/ast/symbol_entry.rb` | none |
| `src/ast/syntax_typo_scanner.rb` | none |
| `src/ast/type.rb` | none |

## Burn-Down Result

Burn-down followed the source inventory for `src/ast/`, with most work landing
in the files that initially had uncovered executable lines:

1. diagnostic helpers and fixable diagnostics;
2. lexer edge cases and unreachable branches;
3. AST node metadata/walker helpers;
4. parser grammar/helper edges and unreachable branches;
5. type compatibility/capability/storage edges;
6. stdlib validator and symbol-entry helper coverage.

All files in `src/ast/` are checked off with no uncovered executable lines in
the final merged result.
