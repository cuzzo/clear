# Mutation runner PR roadmap

## Purpose

Test Miser analyzes mutation data after a mutation run. It must not run each
mutant once per test or carry repository-specific test commands in its analysis
code. A supported mutation runner must provide, directly or through a stable
adapter:

- the complete in-scope test inventory;
- every test selected for each mutant;
- every test that failed for each mutant;
- a guarantee that selected tests continued after the first failure; and
- corpus and attribution completeness metadata.

Adapters translate existing runner output into `mutant-facts/v1`. Upstream PRs
are needed only when the runner does not execute or retain information required
by that contract. Repository-specific command selection remains user
configuration or a small project script.

## Summary

| Language | Mutation framework | Upstream PR | Reason |
|---|---|---|---|
| Ruby | Mutant | Required | The optimized integration stops at the first failing test. Add an opt-in run-to-completion mode that retains every killer ID. |
| Python | mutmut | Required | Mutant trials use fail-fast and retain only aggregate status. Disable fail-fast in the opt-in mode and emit complete test attribution. |
| Go | Gremlins | Required | Gremlins invokes `go test` with `-failfast` and discards per-test JSON events. Run without fail-fast and retain all failed test IDs. |
| PHP | Infection | Required | Infection's killer extraction retains one PHPUnit failure. Add a supported run-to-completion option and retain all killers in MTE output. |
| Swift | Muter | Required | Existing logs contain the needed XCTest results, but current Muter requires three general correctness fixes before attribution is reliable. |
| Rust | cargo-mutants | Optional | `--cargo-test-arg=--no-fail-fast` plus existing logs works. Structured killer IDs would remove log parsing. |
| JavaScript/TypeScript | StrykerJS | None | `disableBail: true` and MTE output already provide the required data. |
| C# | Stryker.NET | None | `disable-bail: true` and MTE output already provide the required data. |
| Java/Kotlin | PIT | None currently | `fullMutationMatrix=true`, PIT XML, and baseline Surefire XML provide the required data. The feature remains experimental and must be version-tested. |
| C/C++ | Mull plus GoogleTest | None | Mull's SQLite output retains mutant stdout/stderr and GoogleTest runs all tests by default. A framework adapter is sufficient. |
| Zig | zig-mutants | Not applicable | We own zig-mutants and have implemented `--test-miser` and ordered `test_commands` directly. |
| Lua | No established standard | No target PR | There is no sufficiently mature standard mutation runner to fix. Lua needs a new runner integration or a project script that emits mutant-facts. |

## Required upstream PRs

### Ruby: Mutant

Problem:

- Mutant's normal optimization stops after the first failing selected test.
- Output formatting cannot recover tests that were never executed.

Proposed change:

- Add `--run-to-complete` to the relevant test integration.
- Execute every selected test for a mutant even after one fails.
- Retain all failing test IDs in the mutant result.
- Mark timeouts, crashes, and incomplete selections as attribution-incomplete.

The branch implementation proves the execution model. The production change
belongs in Mutant or its standard test integration, not in Test Miser's report
processor.

### Python: mutmut

Problem:

- The Hammett/pytest mutant path uses fail-fast behavior.
- The stored mutant result is aggregate and does not contain every failed node
  ID.

Proposed change:

- Add an opt-in machine-output option, represented by
  `--test-miser-output FILE` in the proof patch.
- Disable fail-fast only for that mode.
- Inventory the selected pytest tests once.
- Emit `tests`, `covered_by`, `killed_by`, and completeness metadata as part of
  the normal single mutant trial.

Proof patch: `patches/mutmut-run-to-complete.patch`.

### Go: Gremlins

Problem:

- Gremlins passes `-failfast` to `go test`.
- Its result schema records the mutant outcome but not all failed test names.
- A mutated file can belong to a package below the module root; Test Miser mode
  must run that package rather than derive an invalid module import path.
- Some failed package trials emit no named failing-test event. On Boobytrap,
  39 of 994 mutant trials had this shape, so merely retaining JSON events does
  not yet make attribution complete.

Proposed change:

- Add an opt-in machine-output option, represented by
  `--test-miser-output FILE` in the proof patch.
- Remove `-failfast` for that mode.
- Consume the existing `go test -json` event stream.
- Record every event with `Action == "fail"` and a non-empty test name.
- Define and expose the reason for package-level failures without a named test,
  or explicitly mark those trials incomplete.
- Emit the complete baseline inventory and attribution completeness metadata.

Proof patch: `patches/gremlins-test-miser.patch`.

The proof ran successfully against Boobytrap but took 14m31s for 994 mutants
and produced the 39 incomplete trials above. The repository therefore keeps
the Go suite in the CI manifest but disabled until the PR can provide complete
attribution at a sustainable cost.

### PHP: Infection

Problem:

- Infection already emits MTE data, but its current PHPUnit killer extraction
  selects only one failure.
- PHPUnit may be configured to stop after the first defect.

Proposed change:

- Add a supported CLI/config option such as `--run-to-complete` or
  `--collect-all-killers`.
- Disable PHPUnit `stopOnDefect` and `stopOnFailure` for that mode.
- Parse and retain every numbered PHPUnit defect record.
- Populate MTE `killedBy` with every killer ID and mark incomplete trials.

The proof patch uses `INFECTION_RUN_TO_COMPLETE=1` to demonstrate the behavior.
That environment variable is not the proposed public interface and should be
replaced before submitting the PR.

Proof patch: `patches/infection-run-to-complete.patch`.

### Swift: Muter

Problem:

- Muter's existing per-mutant XCTest logs already contain all test outcomes.
- Current Muter tip is unreliable for the verified Linux fixture because of
  three general implementation defects.

Proposed changes, preferably as independently reviewable fixes:

1. Use a Linux-safe autorelease-pool wrapper.
2. Propagate the process environment to mutation test commands.
3. Match mutation mappings by source position when applying them to a re-parsed
   SwiftSyntax tree.

These are general Muter correctness fixes, not Test Miser-specific reporting
features. After they land, Test Miser can continue using Muter's standard JSON
and log files. A separate structured attribution format would be helpful but is
not required.

Proof patch: `patches/muter-linux-attribution-fixes.patch`.

## Optional upstream improvement

### Rust: cargo-mutants

The current integration works without a patch:

- pass `--cargo-test-arg=--no-fail-fast` so Cargo continues to later test
  binaries;
- read failed test names from each mutant's standard libtest log; and
- obtain the baseline inventory once with `cargo test -- --list`.

An optional cargo-mutants PR could add a structured attribution output mode
that records test inventory and killer IDs alongside `outcomes.json`. This
would make the integration less sensitive to libtest console formatting, but
it is not required for correct results today.

## No runner PR required

### StrykerJS and Stryker.NET

Both Stryker implementations already expose the required run-to-completion
configuration and structured MTE output:

- StrykerJS: `disableBail: true`.
- Stryker.NET: `disable-bail: true`.

Test Miser consumes their MTE reports directly.

### PIT for Java and Kotlin

PIT's `fullMutationMatrix=true` records additional failing tests in its XML
report. The Test Miser adapter combines that report with the normal Surefire
test inventory. No core patch is currently necessary, but the PIT feature is
experimental, so the pinned and latest supported versions must run through the
mini-repo compatibility gate.

### Mull for C and C++

Mull's standard SQLite reporter already retains stdout and stderr for every
mutant. GoogleTest runs all tests by default and can emit a baseline JSON
inventory with source locations. The `mull-gtest` adapter joins those two data
sources.

No Mull PR or fork is required. Other C/C++ test frameworks need their own
small output adapters. Users must not enable framework fail-fast behavior.

## Owned implementation

### Zig: zig-mutants

Because zig-mutants is maintained in this repository, the required behavior is
implemented directly rather than proposed externally:

- `--test-miser` enables complete per-test attribution;
- manifest subjects accept an ordered `test_commands` array;
- every command runs even if an earlier command fails; and
- native `mutant-facts/v1` includes the test inventory, killer IDs, and
  completeness flags.

## Lua

Lua was intentionally skipped for this implementation pass. There is no mature
standard mutation framework with an appropriate upstream target. Supporting
Lua will require one of:

1. extending a future established Lua mutation runner;
2. creating and maintaining a small runner; or
3. documenting a project script that inventories tests, executes them without
   fail-fast, and emits `mutant-facts/v1`.

This is new integration work, not a fixes-only PR.

## Submission and compatibility policy

Each upstream PR should be independently useful to the mutation framework. It
should describe the capability as complete test attribution or run-to-complete,
without coupling the runner to Lineage or Test Miser's audit policy.

Before a runner version is declared supported, its mini-repo must prove that:

1. one mutant trial records every failing test;
2. a later test binary still runs after an earlier binary fails;
3. the complete baseline test inventory is present;
4. incomplete, crashed, or timed-out trials fail closed; and
5. Test Miser reports exactly the known zero-kill test and exact duplicate pair.

CI should exercise both the pinned known-good version and the newest supported
version. A format change must fail the adapter compatibility test rather than
silently produce incomplete audit findings.
