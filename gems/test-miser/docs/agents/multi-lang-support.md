# Multi-language mutant attribution support

## Decision

Test Miser does not run mutants. Mutation runners run separately and produce
one complete mutant-facts artifact. Test Miser consumes that artifact, infers
missing test source locations when possible, and emits SARIF audit candidates.

The native contract extends the `mutant-facts/v1` shape already emitted by
`gems/zig-mutants` and ingested by Lineage. Existing `subjects` summaries are
unchanged. Audit-capable producers add:

```json
{
  "schema": "mutant-facts/v1",
  "tests": [
    { "id": "suite:test", "name": "suite test", "file": "test/example", "line": 12 }
  ],
  "mutants": [
    {
      "id": "src/example:1",
      "file": "src/example",
      "outcome": "killed",
      "covered_by": ["suite:test"],
      "killed_by": ["suite:test"]
    }
  ],
  "test_miser": {
    "complete": true,
    "attribution_complete": true,
    "run_to_complete": true
  }
}
```

`tests` must be the complete in-scope test inventory. `killed_by` must contain
every test that failed in the single test execution for that mutant, not merely
the first failure. `complete` means the intended mutant corpus completed;
`attribution_complete` means every completed mutant ran its selected tests to
completion. Test Miser withholds findings when either guarantee is false.

Mutation Testing Elements (MTE) is supported as an adapter input because
Stryker-family tools already emit it. Converters should normalize other native
formats into mutant-facts. Runner patches belong in their runner repositories;
repo-specific command selection belongs in user configuration or a small
normalization script, like Nil-Kill's runtime tracing script.

## Verified compatibility summary

The following matrix was exercised end to end on 2026-07-19. Each mini-repo has
five tests with known ground truth: one deletable smoke test, one deliberately
duplicated pair, and two distinct tests. A passing integration must report
exactly that zero-kill test and exactly that pair.

| Language | Recommended runner | Status | Required action |
|---|---|---|---|
| JavaScript/TypeScript | StrykerJS | Verified by configuration | Set `disableBail: true`; consume its complete MTE JSON. |
| C# | Stryker.NET | Verified by configuration | Set `disable-bail: true`; consume its complete MTE JSON. |
| Java | PIT | Verified by configuration, experimental | Set `fullMutationMatrix=true`; use the `pit` adapter with PIT XML and Surefire XML. |
| Kotlin | PIT | Verified by configuration, experimental | Same as Java with `--language kotlin`. |
| Rust | cargo-mutants | Verified adapter | Pass `--cargo-test-arg=--no-fail-fast`; the `cargo-mutants` adapter reads the complete libtest logs and baseline inventory. |
| Zig | zig-mutants | Verified native output | `--test-miser` executes every `test_commands` entry, accumulates all failures, and emits native facts. |
| Python | mutmut | Verified runner patch | `--test-miser-output` disables fail-fast and emits native facts in the normal mutant trial. |
| Go | Gremlins | Verified runner patch | `--test-miser-output` removes `-failfast`, consumes `go test -json`, and emits native facts. |
| C/C++ | Mull plus GoogleTest | Verified adapter | Mull's standard SQLite report already retains complete stdout; `mull-gtest` combines it with baseline GoogleTest JSON. No Mull fork. |
| PHP | Infection | Verified runner patch and adapter | Opt-in run-to-completion records all PHPUnit failures; `infection` merges MTE with the baseline JUnit inventory. |
| Swift | Muter | Verified correctness patch and adapter | Standard per-mutant logs already contain all XCTest outcomes; `muter` normalizes them after three general Muter fixes. |
| Lua | No ecosystem standard | Skipped for this pass | A project-specific runner must inventory tests, run them to completion, and emit mutant-facts. |
| Ruby | Mutant | Patch exists on this branch | `--run-to-complete` captures all failing Minitest IDs in one mutated process; production version should live with the runner integration, not Test Miser analysis. |

No language should run the mutant once per test. The acceptable cost is one
normal mutation trial with fail-fast disabled. Any baseline inventory or source
location discovery happens once per suite, not once per mutant.

## Verification results

| Fixture | Runner version | Mutants | Result |
|---|---|---:|---|
| JavaScript | StrykerJS (version pinned in `package-lock.json`) | 10 | Exact ground truth. |
| TypeScript | StrykerJS (version pinned in `package-lock.json`) | 10 | Exact ground truth. |
| C# | Stryker.NET 4.16.0 | 10 | Exact ground truth. |
| Java | PIT 1.25.3 | 7 | Exact ground truth. |
| Kotlin | PIT 1.25.3 | 7 | Exact ground truth. |
| Rust | cargo-mutants 27.1.0, Rust 1.96 | fixture corpus | Exact ground truth. |
| Zig | zig-mutants, Zig 0.16 | 4 | Exact ground truth, including two independent test commands. |
| Python | mutmut commit `32f0b426` | 10 | Exact ground truth; mutant phase completed in under one second. |
| Go | Gremlins commit `b48a4aad` | 4 | Exact ground truth; mutant phase completed in under one second. |
| C | Mull 0.34.0 / LLVM 20 / GoogleTest 1.17 | 4 | Exact ground truth; Mull completed in 11 ms. |
| C++ | Mull 0.34.0 / LLVM 20 / GoogleTest 1.17 | 4 | Exact ground truth; Mull completed in 11 ms. |
| PHP | Infection commit `4dfdc7f9`, PHPUnit 12.5.31 | 7 | Exact ground truth; mutant phase completed in under one second. |
| Swift | Muter commit `99624ecf`, Swift 6.3.3 | 4 | Exact ground truth; mutation run completed in about ten seconds. |

Lua was explicitly excluded from this implementation pass. The runnable
mini-repos live under `gems/test-miser/examples`; they are deliberately small
release gates, not representative applications.

## Rust implementation

The experiment used cargo-mutants 27.1.0, Rust 1.96, one mutated predicate,
three failing unit tests, and one failing integration test.

- Default cargo-mutants/libtest output contained all three failures from the
  unit-test binary, then Cargo stopped before the integration-test target.
- Passing `--cargo-test-arg=--no-fail-fast` caused both targets to complete and
  the log contained all four failing test names.
- `outcomes.json` contained only the aggregate `CaughtMutant` result and a log
  path. It did not contain test IDs.

Therefore the needed information is produced during a standard single mutant
trial, but is not present in structured output. The immediate adapter can parse
libtest's `test <name> ... FAILED` records and use a baseline `cargo test --
--list` inventory. The durable change is a cargo-mutants option that forwards
no-fail-fast and writes `tests`, `covered_by`, and `killed_by` to mutant-facts.
Do not use nextest unless its own fail-fast and machine-output behavior is
configured equivalently.

Cargo-mutants documents its normal fail-fast optimization and its output/log
layout: [fail-fast](https://mutants.rs/fail-fast.html),
[mutants.out](https://mutants.rs/mutants-out.html), and
[using results](https://mutants.rs/using-results.html).

## Zig implementation

The experiment used Zig 0.16, `gems/zig-mutants`, one comparison mutant, and six
tests, two of which failed under the mutant.

- `zig test` ran all six tests and printed both failing test names.
- `zig-mutants` captured that process output but discarded it after assigning
  the aggregate killed outcome.
- The current manifest stores one shell command per subject. Commands joined by
  `&&` prevent later test binaries from running after the first failing binary.
- The emitted `mutant-facts/v1` contains subjects and mutants but no test
  inventory or killer IDs.

The implemented manifest accepts `test_commands` as an ordered array while
retaining legacy `test_command`. With `--test-miser`, every command executes even
after an earlier command fails; their outputs and exit status are accumulated.
Each selected test binary still executes once per mutant. The two-command Zig
fixture proves that a failure in the first binary does not suppress inventory
or execution of the second binary.

## Configuration-only runners

StrykerJS has the exact feature Test Miser needs: `disableBail` reports all
failing tests and its documentation explicitly calls out finding tests that do
not kill a mutant. All official runner plugins support it, with Jest internally
running without bail and changing how many failures it reports when the option
is enabled. Stryker.NET exposes the equivalent `disable-bail` flag and explicitly
describes useless-test analysis. Both produce the MTE data model. See the
[StrykerJS option](https://stryker-mutator.io/docs/stryker-js/configuration/#disableBail)
and [Stryker.NET option](https://stryker-mutator.io/docs/stryker-net/configuration/#disable-bail).

PIT's `fullMutationMatrix` continues after a failing test and records additional
failures when XML output is enabled. PIT labels it partially supported research
functionality, so the converter and a small fixture must be version-pinned and
tested before production use. See
[PIT Maven fullMutationMatrix](https://pitest.org/quickstart/maven/#fullMutationMatrix).

## Small runner patches

Mutmut currently runs its Hammett path with fail-fast enabled and stores an
aggregate mutant result. The patch is local: disable fail-fast, collect all
failed pytest/Hammett node IDs, and serialize them. Mutmut already knows its
selected tests. See the [mutmut documentation](https://mutmut.readthedocs.io/en/latest/).

Gremlins currently invokes `go test` with `-failfast` and its JSON output only
contains aggregate mutant status. Go itself supplies the required structured
stream: `go test -json` emits events with test names and `Action == "fail"`.
See [test2json](https://pkg.go.dev/cmd/test2json) and the
[Gremlins output schema](https://gremlins.dev/next/usage/commands/unleash/).

Infection already writes MTE fields, but its current killer extraction selects
only one test from PHPUnit output. The proof patch disables PHPUnit's
`stopOnDefect`/`stopOnFailure` optimization when explicitly enabled and matches
all numbered PHPUnit defect records. The Test Miser adapter only unwraps the MTE
payload and merges the normal baseline JUnit inventory; it does not parse mutant
console text. The environment toggle in the proof patch should become an
official Infection CLI/config option before upstreaming.

Muter's JSON is aggregate, but Muter also keeps a full XCTest log for every
mutant and `swift test` runs independent XCTest cases after assertion failures.
The adapter joins JSON mutant locations to those existing logs and verifies that
every baseline test completed in every mutant log before setting completeness.
No new Muter output mode is required. Current Muter tip did require three general
fixes: a Linux-safe autorelease-pool wrapper, environment propagation, and
position-based matching when mutation mappings are applied to a re-parsed
SwiftSyntax tree. These should be upstream PRs. Crashes/timeouts remain
incomplete and suppress Test Miser findings.

## Framework-dependent languages

Mull cannot solve test attribution generically because a C or C++ test command
has no universal result protocol. Its standard SQLite reporter does, however,
retain stdout and stderr for every mutant. GoogleTest runs every test by default,
so the `mull-gtest` adapter reads failed test IDs from that retained output and
uses one baseline `--gtest_output=json:` file for the full inventory and source
locations. This needs no Mull patch and avoids per-mutant side files. Do not pass
`--gtest_fail_fast`. Catch2 and other frameworks need equivalent adapters.
Arbitrary shell test commands require a user script that emits mutant-facts.

Lua has no sufficiently established standard mutation runner. The available
`luamut` package is a development release with very limited adoption. Support
therefore starts as a documented adapter contract rather than a core patch. See
[luamut on LuaRocks](https://luarocks.org/modules/ligurio/luamut).

## Acceptance test for every producer

Each runner integration needs the same fixture:

1. One or more mutants are killed by an intentionally duplicated pair.
2. A smoke test kills no mutant.
3. The ordinary optimized run may stop early.
4. Run-to-complete executes the mutant once and records both killer IDs.
5. The artifact contains all three tests with file and line where available.
6. `test-miser infer` emits exactly one zero-kill finding and exactly the known
   redundant pair; distinct tests must not be grouped.

This fixture is the release gate. Merely finding multiple names in console text
is not enough; the normalized artifact and completeness flags are the contract.

## Empirical signal audit

The language fixtures establish precision at the adapter boundary. Across all
13 exercised language fixtures, Test Miser reported exactly the intentionally
useless smoke test and exactly the intentionally duplicated pair. It did not
group either distinct test. This verifies that the integrations preserve the
runner data instead of manufacturing findings during normalization.

The complete Espalier audit provides a less artificial check. It contains 135
tests and 66,893 mutants and produced 13 zero-kill candidates and two
identical-kill groups containing eight tests.

The zero-kill candidates have two materially different meanings:

- `TreeSitterCovTest#test_parser_for_languages` was selected for 479 mutants
  and killed none. It has no assertion and rescues `StandardError` around each
  call. This is a genuine high-value weak-test finding.
- The other 12 candidates were selected for no mutants. Two inspect source
  text for architecture boundaries, two test subprocess load behavior, and
  eight exercise code owned by Decomplex or Fact Mine rather than the mutated
  Espalier namespace. These are not evidence that the tests are useless. They
  are useful corpus-scope findings and should be ranked below a covered test
  that kills nothing.

The two exact-kill groups are not safe deletion recommendations. All eight
tests construct distinct source programs and encode different Big-O scenarios.
The five-test group is nevertheless audit-worthy: its test names say that
aggregate scans, insert shifts, nested loops, and recursive branching are
detected, while the assertions currently require `O(1)` and explicitly reject
the corresponding warnings. The three-test group contains legitimate negative
cases for false-positive control. Identical kill sets correctly identify that
the current mutant corpus cannot distinguish these tests, but a reviewer must
decide whether that means duplication, weak assertions, stale names, or a
missing mutant dimension.

The practical ranking is therefore:

1. A mutation-covered test that kills zero mutants is the strongest weak-test
   signal.
2. An exact non-empty kill-set group is a test-design audit candidate, never an
   automatic deletion.
3. A test selected for zero mutants is primarily a corpus/configuration audit;
   it may still be a valuable architecture, integration, or out-of-scope test.

This result is useful rather than merely noisy, provided consumers retain the
`coveredMutantCount` distinction and the `POSSIBLY REDUNDANT` wording. The SARIF
output carries the covered count, test path, inferred test line, and peer group
so Lineage can present that evidence to the reviewer.
