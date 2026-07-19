# Incremental mutation switching

## Decision

`zig-mutants` uses a Mull/Stryker hybrid. Mull is the model for the outer
mutation plan, `M_PR`; Stryker is the model for activating mutants and deriving
the per-mutant test set, `T(m)`.

LLVM source coverage is deliberately not part of this design. Zig 0.16 emits
invalid DWARF in the repository documented by `~/dwarf-bug`, so LLVM/Kcov
coverage cannot currently be a sound prerequisite. The old optional Kcov build
step was removed from this package.

## Mull-derived `M_PR`

`--since REV` runs `git diff --unified=0 REV --`. `--diff-file PATCH` accepts
the same unified-diff shape without requiring a Git checkout. Added and
modified new-side line ranges select mutation points; deletion-only ranges do
not invent mutants. Both `list` and `run` apply the filter before execution.

Mutant IDs use the `zig-v2` identity. The hash includes the repository-relative
path, enclosing function, function-relative mutation offset, enclosing
function source, operator, original expression, and replacement. Inserting
lines outside the function does not change its IDs. Changing the function does,
which intentionally invalidates stale results.

## Stryker-derived `T(m)`

`--mutation-switching` writes every selected mutation into one source schema:

```zig
if (runtime.active(mutant_id)) mutated_expression else original_expression
```

One instrumented baseline records a direct `(test ID, mutant ID)` pair whenever
a test evaluates a mutation point. The active-mutant runs then set
`ZIG_MUTANTS_ACTIVE` and `ZIG_MUTANTS_TESTS`; unrelated Zig `test` declarations
return `error.SkipZigTest`. This is direct mutation-site evidence, not line or
DWARF coverage.

`--no-test-selection` is a diagnostic and benchmark switch. It keeps the same
source schema and direct coverage baseline but omits `ZIG_MUTANTS_TESTS` from
active-mutant runs. Comparing it with the default isolates the value of
`T(m)` from the value of mutation switching.

The runner instruments tests declared in a subject and test roots named by the
standard `-Dtest-file=...` build option. The generated runtime is imported from
the subject directory, so the production module and external test root share
the same current-test and mutation state. No repository-specific build patch or
custom test runner is required for this standard layout.

All existing mutator families are switchable. Comparison and logical operators
are represented as whole-expression mutations. `defer` and `errdefer` mutate
their deferred expression, and `catch` mutates the complete catch expression;
these forms preserve Zig syntax inside a runtime conditional.

## Sound fallbacks

Optimization must fail open:

- no recorded coverage uses the legacy source-edit executor and runs the full
  configured test target, because an empty set may be a compile-time mutant;
- top-level/static mutations use that same source-edit fallback even when
  runtime initialization records a hit;
- overlapping tests cause every mutant to receive a static marker, disabling
  per-test selection for custom concurrent runners;
- an instrumented baseline compile or test failure automatically reruns through
  the legacy one-source-edit-per-mutant executor; and
- commands without discoverable Zig test roots continue to run as complete
  black-box targets.

The default Zig runner is sequential. Threads spawned by a test share the
current test ID and therefore retain attribution. Custom runners that overlap
different tests trigger the conservative concurrency fallback.

## Cache model

All active mutant runs share one source schema and one Zig global build cache.
`--build-cache DIR` controls its persistent location; the default is
`/tmp/zig-mutants-build-cache`. Zig's content-addressed cache invalidates on
source, compiler, target, and build-input changes. `zig-mutants` does not cache
pass/fail outcomes independently of the test suite, because doing so would be
unsound after test or configuration changes.

On the final three-production-mutant `examples/fast` corpus, legacy execution
took 11.89 seconds, the first switching run took 5.55 seconds, and a repeated
switching run using the persistent cache took 2.59 seconds. These are smoke-test
measurements, not general benchmarks.

### Relationship to Zig incremental compilation

`zig-mutants` does not currently launch or retain a `zig build --watch
-fincremental` process. Each configured test command is a separate process.
The runner gets reuse from Zig's ordinary content-addressed global cache, and
mutation switching makes that reuse effective: after the schema is compiled,
changing `ZIG_MUTANTS_ACTIVE` does not change its source or test binary.

As of 2026-07-19, this repository and `origin/master` still select Zig 0.16.0;
`zig/build.zig.zon` requires `0.16.0-dev.1424+d3e20e71b`. The recently merged
persistent incremental feature is `clear watch`. Its implementation explicitly
passes `-fno-incremental` to ordinary one-shot builds, tests, and CI, and only
the persistent watch command opts into `--watch -fincremental`. No local Zig
0.17 executable was present during verification.

Moving the project to Zig 0.17 may reduce the first compilation of a changed
schema. It should not materially improve the repeated active-mutant phase,
because that phase intentionally has no source changes. A persistent build
process would also need a protocol for repeatedly running the already-built
test artifact with different mutant/test environment variables; merely adding
`-fincremental` to the current subprocess command does not provide that.

## Runtime measurements

Measurements below were taken on 2026-07-19 with Zig 0.16.0. The corpus was 12
runtime-switchable mutants on `zig/runtime/frame.zig` lines 58--74. Every mode
killed all 12 mutants after fixing cleanup removal to emit the valid Zig block
statement `{}` rather than the invalid `{};`.

The ordinary unit-test command ran 17 tests across `frame-test.zig` and
`frame-rewind-test.zig`:

| Mode | Wall time | Relative to legacy |
| --- | ---: | ---: |
| Legacy source edit and rebuild | 51.33 s | 1.00x |
| Mutation switching, all tests | 15.14 s | 3.39x |
| Mutation switching with `T(m)` | 14.46 s | 3.55x |

Mutation switching reduced wall time by 71.8%. `T(m)` contributed only another
4.5% on this slice because each mutation point was reached by 8--15 of the 17
tests. This is a deliberately unfavorable `T(m)` workload: the frame tests
exercise the same allocator paths heavily.

The same mutant slice was also run using `zig build test -Dcoverage
-Dtest-file=frame-test.zig`, which wraps the 16 tests in Kcov. A warm unmutated
run took 0.70 seconds under Kcov and 0.17 seconds normally. Mutation timings
were:

| Kcov mode | Wall time | Relative to legacy Kcov |
| --- | ---: | ---: |
| Legacy source edit and rebuild | 95.76 s | 1.00x |
| Mutation switching, all tests | 25.52 s | 3.75x |
| Mutation switching with `T(m)` | 24.75 s | 3.87x |

Mutation switching reduced Kcov wall time by 74.2%. `T(m)` saved 3.0%; Kcov
startup, report generation, and merging dominate this small, highly
overlapping suite. Kcov was used only as the configured test command in this
measurement. Direct runtime markers still produced `T(m)`, so this does not
make DWARF/Kcov coverage a correctness dependency or resolve the repository's
known Zig DWARF issue.

## Hammer and other stochastic test modes

Coverage-mode execution can show that a test reaches a mutation point. It
cannot show whether a schedule-sensitive mutant is killed under Hammer. A
race-relevant mutant must be executed in the actual Hammer, TSan, Loom, or VOPR
mode whose behavior is the kill oracle.

The current runner can invoke those commands and can filter their Zig test
declarations, but a single Hammer run is not evidence that a surviving mutant
is equivalent or alive: it may simply have missed the triggering schedule.
Repeated Hammer execution per mutant is intentionally not part of the default
plan because its cost is disproportionate. Until command-mode provenance and a
separate stochastic-validation policy exist, Hammer-only survivors should be
reported as inconclusive candidates, not counted as confidently surviving
mutants. Deterministic kills from unit, TSan, Loom, or VOPR modes remain valid.

## Verified cases

- unit tests cover Git hunk parsing, deletion-only diffs, line-move-stable IDs,
  test exclusion from mutation discovery, test declaration instrumentation,
  and switchable expression generation;
- `examples/fast/only-less.patch` selects one of three production mutants;
- the full `examples/fast` switching run attributes each of three killed
  mutants to exactly one covering and killing test;
- Test Miser consumes those facts as a complete two-test/three-mutant corpus
  and reports zero zero-kill tests and zero redundant groups;
- `examples/static` proves that a top-level compile-time boolean mutation is
  materially applied and killed through the separate legacy fallback;
- the first real `subjects.json` safety mutant has the same `survived` outcome
  in legacy and switching modes; and
- its external `zig/lib/safety-test.zig` test is directly recorded in
  `covered_by`, demonstrating `-Dtest-file` instrumentation without DWARF.

## Remaining distance from Mull

Mull operates after Clang/LLVM compilation and consequently supports a broader
C/C++ compilation model and mature IR-level mutation validation. Zig source
schemata require every selected replacement branch to type-check together. The
legacy fallback preserves correctness when they do not, but loses the speedup
for that run.

The next improvements are operational rather than a return to DWARF coverage:

- parallel active-mutant workers with isolated test processes;
- explicit test-root declarations for custom build systems that do not expose
  `-Dtest-file`;
- persistent normalized coverage maps keyed by the schema and test-tree hash;
  and
- broader integration fixtures for custom Zig test runners and cross-target
  builds.
