# Test Miser multi-language mini-repos

These deliberately tiny repositories validate complete per-test mutant
attribution. Every fixture contains the same ground truth:

- `smoke` is intentionally weak and kills no mutants;
- `positive_primary` and `positive_duplicate` are intentional duplicates and
  should have identical non-empty kill sets;
- `high` and `nonpositive` exercise distinct behavior and should not be grouped
  with the duplicate pair after the full mutant corpus is run.

The fixtures are acceptance tests for mutation-runner adapters, not examples of
good test-suite design. Commands and verified runner versions are recorded in
`../docs/agents/multi-lang-support.md`.

## Runner and adapter pairs

| Directory | Mutation command/output | Test Miser input |
|---|---|---|
| `javascript`, `typescript` | StrykerJS JSON with `disableBail` | MTE directly |
| `csharp` | Stryker.NET JSON with `disable-bail` | MTE directly |
| `java`, `kotlin` | `mvn test org.pitest:pitest-maven:mutationCoverage` | `test-miser adapt pit mutations.xml surefire-reports` |
| `rust` | `cargo mutants --cargo-test-arg=--no-fail-fast` | `test-miser adapt cargo-mutants mutants.out` |
| `zig` | `zig-mutants ... --test-miser --facts mutant-facts.json` | native facts |
| `python` | patched `mutmut run --test-miser-output mutant-facts.json` | native facts |
| `go` | patched `gremlins unleash --test-miser-output mutant-facts.json` | native facts |
| `c`, `cpp` | Mull SQLite plus baseline GoogleTest JSON | `test-miser adapt mull-gtest mull.sqlite gtest.json` |
| `php` | patched Infection HTML/MTE plus PHPUnit JUnit | `test-miser adapt infection infection.html junit.xml` |
| `swift` | patched Muter JSON plus its standard `muter_logs` | `test-miser adapt muter muter.json muter_logs` |

Then run `test-miser infer --root . mutant-facts.json`. Stryker MTE can be
passed directly to `infer`. Paths and tool installation differ by workstation;
the exact pinned configurations live in each fixture.
