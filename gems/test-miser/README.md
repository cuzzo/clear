# Test Miser

Test Miser audits tests using their stochastic-mutant kill sets. It reports:

1. tests that kill no mutants; and
2. groups of tests that kill exactly the same non-empty mutant set as
   `POSSIBLY REDUNDANT`.

These are review candidates. Two tests can kill the same mutants while proving
different behavior that the current mutant corpus does not distinguish.
Every finding is relative to the supplied mutant corpus, so an audit intended
to cover the whole suite must combine reports for the whole mutation scope.

## Input

The native input is Lineage's `mutant-facts/v1` artifact, starting from the
format emitted by `gems/zig-mutants`. Mutation runners execute separately. An
audit-capable artifact retains its existing `subjects` and `mutants` fields and
adds a complete `tests` inventory, per-mutant `covered_by` and `killed_by`, and:

```json
"test_miser": {
  "complete": true,
  "attribution_complete": true,
  "run_to_complete": true
}
```

`killed_by` must include every test that failed during the one normal trial for
the mutant. It must not contain only the first failure. See
[`docs/agents/multi-lang-support.md`](docs/agents/multi-lang-support.md) for the
runner contract and language support matrix.

Test Miser also consumes the
[Mutation Testing Elements](https://github.com/stryker-mutator/mutation-testing-elements)
report shape. It uses only:

- `testFiles.*.tests[*].id`, `name`, and the containing test file;
- `files.*.mutants[*].id`;
- `coveredBy`; and
- `killedBy`.

Mutant IDs are qualified by their source path because report IDs only need to
be unique within one source file. Tests referenced by mutants are retained even
when a producer omits `testFiles`, but a complete test inventory is required to
find tests that cover no mutants.

Minimal input:

```json
{
  "schemaVersion": "2.0",
  "files": {
    "lib/example.rb": {
      "mutants": [
        {
          "id": "1",
          "coveredBy": ["test:a", "test:b"],
          "killedBy": ["test:a"]
        }
      ]
    }
  },
  "testFiles": {
    "test/example_test.rb": {
      "tests": [
        { "id": "test:a", "name": "ExampleTest#test_a" },
        { "id": "test:b", "name": "ExampleTest#test_b" }
      ]
    }
  }
}
```

## Usage

```sh
bundle exec test-miser mutation-report.json
bundle exec test-miser --format json mutation-report.json
bundle exec test-miser shard-0.json shard-1.json -o test-miser-report.md
bundle exec test-miser infer --root . -o test-miser.sarif mutant-facts.json
bundle exec test-miser adapt pit mutations.xml target/surefire-reports -o mutant-facts.json
bundle exec test-miser adapt infection infection.html junit.xml -o mutant-facts.json
bundle exec test-miser adapt mull-gtest mull.sqlite gtest.json -o mutant-facts.json
bundle exec test-miser adapt muter muter.json muter_logs -o mutant-facts.json
```

`infer` makes SARIF the default output. It uses explicit test file/line metadata
when present, otherwise scans the named test file for common test declarations.
Its SARIF format is `test-miser.report.sarif.v1`; ingest it with Lineage's
existing `ingest-sarif` command. Lineage displays the findings in its Weak Tests
tab using only the test name, test file, and line. Test source does not need to
be indexed as production code.

Multiple reports are merged by qualified mutant ID. This supports sharded
mutation runs.

## Collecting Per-Test Mutant Data

Mutant normally stops a selected test group after its first failure, so its
standard result cannot identify the complete set of tests that killed a mutant:
the integration stops at the first failure and returns only an aggregate
pass/fail result. `--run-to-complete` adds the missing attribution without
starting another mutated process per test. For each non-neutral mutant,
`test-miser-mutant` uses one mutated process and one Minitest reporter, continues
through every currently relevant selected test, and records every failing test
ID before the process exits. It writes a Mutation Testing Elements report for
the audit:

```sh
bundle exec test-miser-mutant \
  -I gems/example/lib \
  -r example \
  -r ./path/to/mutant_test_setup \
  --run-to-complete \
  -o mutation-report.json \
  'Example*'

bundle exec test-miser mutation-report.json
```

The setup file must load the test files. A broad Mutant Minitest `cover`
declaration is sufficient because Test Miser traces the production Ruby methods
actually called by each isolated baseline test and uses that runtime map for
selection. Collection stops if any baseline test fails or times out. Mutant's
neutral validation mutations are not included in test kill sets.

Use `--jobs` for process shards and `--resume` to retain completed shard work:

```sh
bundle exec test-miser-mutant --jobs 4 --resume \
  -I gems/example/lib \
  -r example \
  -r ./path/to/mutant_test_setup \
  --run-to-complete \
  -o mutation-report.json \
  'Example*'
```

Generated shard reports include a fingerprint and expected mutant count.
Partial generated corpora withhold audit findings; the merged report becomes
auditable only when every expected mutant is present. To avoid needless test
execution, the collector retires a test after it has a non-empty kill signature
that differs from every other test. A complete report is therefore exact for
the audit candidates (zero-kill tests and equal-kill groups), but intentionally
does not reconstruct the full kill set of already-distinguished tests. The
metadata records this as `attributionMode: audit-candidate-elimination` and
`killSetsComplete: false`; do not use this report to calculate a conventional
mutation score.

## Complete Espalier Corpus

Trace every passing Espalier test once to create an accurate runtime
test-to-subject map:

```sh
bundle exec ruby gems/test-miser/exe/test-miser-map \
  -I gems/espalier/lib \
  -r ./gems/espalier/script/test_miser_mutant_setup \
  -o tmp/espalier-test-miser-runtime-map.json
```

Inventory every concrete Espalier method, collect the corpus in small resumable
batches, and merge it only after every component is complete:

```sh
bundle exec ruby gems/test-miser/exe/test-miser-corpus \
  -I gems/espalier/lib \
  -r ./gems/espalier/script/test_miser_mutant_setup \
  --namespace Espalier \
  --selection-map tmp/espalier-test-miser-runtime-map.json \
  --jobs 9 --collector-jobs 2 --batch-size 8 --resume \
  -o tmp/espalier-test-miser-full-mutants.json
```

Finally, audit only the merged, complete corpus:

```sh
bundle exec ruby gems/test-miser/exe/test-miser \
  --format json \
  -o tmp/espalier-test-miser-full-audit.json \
  tmp/espalier-test-miser-full-mutants.json

bundle exec ruby gems/test-miser/exe/test-miser \
  -o tmp/espalier-test-miser-full-audit.md \
  tmp/espalier-test-miser-full-mutants.json
```

`test-miser-corpus` records inventory size, compatible and incompatible
subjects, expected and completed mutant counts, and corpus completeness in the
merged report. The audit CLI withholds all findings if a generated corpus is
incomplete.

The fixture at `test/fixtures/espalier-mutation-report.json` is a deterministic
small example of the expected Espalier-shaped attribution data. Run it with:

```sh
bundle exec ruby gems/test-miser/exe/test-miser \
  gems/test-miser/test/fixtures/espalier-mutation-report.json
```
