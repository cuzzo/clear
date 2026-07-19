# Mutation execution optimizations

## Decision

Test Miser should build a federated mutation planner, not a new universal
mutation engine or a universal static test selector.

The planner should use a mutation framework's native incremental and coverage
facilities whenever they are available. Test Miser should normalize their
plans and results, enforce completeness requirements, and provide a
cross-language fallback only where native support is proven absent. Ecosystem
capability discovery comes before any Tree-sitter implementation. Fact Mine's
Tree-sitter normalization is a later fallback for changed source regions and
enclosing syntactic units, not the first implementation path. SCIP and compiler
indexes are useful for optional impact expansion, but are unnecessary for
direct changed-line selection.

Native semantic tooling must outrank generic analysis. Rust compiler/cargo
information, PIT bytecode analysis, Roslyn/Stryker, Clang/Mull, and equivalent
language-owned evidence are more precise than Fact Mine and must not be
replaced by it.

This document describes two independent optimizations:

1. Select the set of mutant trials required for a pull request, `M_PR`.
2. For each individual mutant `m` in that set, select the tests `T(m)` that
   should run against it.

## Cost model and terminology

Let:

- `M_HEAD` be every candidate mutant that the configured mutation framework
  can generate at the head revision.
- `M_PR` be the subset selected for execution for a pull request.
- `m` be one individual mutant in `M_PR`.
- `T_ALL` be the complete in-scope test inventory.
- `T(m)` be the tests selected to execute against `m`.
- `C_setup(m)` be the cost of materializing, compiling, or activating `m`.
- `C_test(t, m)` be the cost of running test `t` against `m`.

The approximate execution cost is:

```text
total_cost(PR) = sum over m in M_PR of:
                 C_setup(m) + sum over t in T(m) of C_test(t, m)
```

Reducing `|M_PR|` is the outer optimization. Reducing `|T(m)|` is the inner
optimization. They require different evidence and must have separate
completeness claims.

The symbol `m` does not mean a second global mutant set. It is one mutant. The
second optimization is formally the construction of `T(m)` for that mutant.

### Direct and impacted meanings of `M_PR`

There are two useful definitions of `M_PR`:

```text
M_PR_direct = mutants newly generated in, or overlapping, directly changed code

M_PR_impact = M_PR_direct plus unchanged mutants whose results may have been
              invalidated by the PR
```

`M_PR_direct` is practical and finite. Git identifies changed spans, a parser
maps them to source constructs, and a language mutation framework enumerates
the valid candidates.

The exact minimal `M_PR_impact` is undecidable in the general case. An unchanged
mutant can be affected by reflection, generated code, dynamic dispatch,
configuration, FFI, subprocesses, shared state, or concurrency. Static analysis
can provide a conservative over-approximation, not the exact minimum.

The initial Test Miser planner should promise complete direct selection, not
complete semantic impact selection.

## Correctness boundaries

### `M_PR` is not one problem

The following questions have different answers:

1. Which mutant candidates syntactically overlap the Git diff?
2. Which candidates are new or changed relative to the base revision?
3. Which unchanged candidates might now produce a different test result?
4. Which candidates are the most valuable stochastic sample?

Questions 1 and 2 can be answered deterministically for a fixed mutation
framework, framework version, source tree, and configuration. Question 3 is an
impact-analysis approximation. Question 4 is prioritization or sampling and
must never be represented as completeness.

### `T(m)` is also not uniformly unsolved

The exact minimum set of tests capable of detecting arbitrary semantic effects
of `m` is undecidable. Practical dynamic selection is nevertheless strong in
several frameworks:

- per-test baseline coverage selects tests that executed the mutated location;
- language/package ownership selects a conservative test group;
- explicit test-to-subject declarations select tests by contract; and
- a full-suite fallback preserves operational completeness.

Dynamic languages are difficult for static `T(m)` construction, but dynamic
runtime evidence can be more precise than static analysis. In particular,
mutmut already tracks which Python tests execute functions. Ruby Mutant can use
explicit coverage expressions, and Test Miser's Ruby runtime mapper can fill
gaps. Python and Ruby are not evidence that nobody can optimize `T(m)`; they are
evidence that static call graphs should not be the primary mechanism.

For Test Miser auditing, the runner must execute every test in `T(m)` to
completion and retain every failure. A runner's ordinary first-killer
optimization is incompatible with complete kill sets even when its selection
of `T(m)` is good.

## Existing framework support

This inventory was checked on 2026-07-19. "Native" means the mutation
framework already owns the relevant semantic or runtime evidence. It does not
mean its current output already contains Test Miser's complete killer list;
that separate requirement is documented in
[prs-needed.md](./prs-needed.md).

| Language | Framework | Native `M_PR` support | Native `T(m)` support | Planner decision |
|---|---|---|---|---|
| JavaScript/TypeScript | StrykerJS | Excellent: incremental result reuse, code/test diffing, stable remapping, and explicit mutation ranges | Excellent with `coverageAnalysis: perTest`; static mutants fall back to all tests | Delegate both axes to Stryker and normalize its mutant facts. |
| C# | Stryker.NET | Excellent: `since` for changed code and `with-baseline` for cached full reports | Excellent per-test coverage modes; static initialization receives conservative handling | Delegate both axes to Stryker.NET. |
| Java/Kotlin | PIT | Good cached incremental analysis at class/bytecode level, but dependency invalidation is intentionally incomplete | Excellent: baseline line coverage and test timing select tests for each mutation | Use PIT history and coverage natively; cross-language tooling may conservatively expand invalidation. |
| Rust | cargo-mutants | Excellent direct support with `--in-diff`; also supports file, package, and regex filters | Limited: normally executes Cargo test targets rather than selecting by per-test coverage | Use cargo-mutants for `M_PR`; initially retain target/full-suite `T(m)`. Do not replace Rust parsing with Fact Mine. |
| Go | Gremlins | Good direct support with `--diff` against a branch or commit | Moderate: package-local tests by default, full suite in integration mode | Delegate direct `M_PR`; use package selection unless cross-package or cross-language edges require integration mode. |
| C/C++ | Mull | Excellent direct changed-line support through `gitDiffRef` and `gitProjectRoot` | Limited: runs the configured test executable/suite for each active mutation | Delegate `M_PR` to Mull/Clang; use framework-specific test adapters and conservative test binaries. |
| PHP | Infection | Excellent direct file and line support through `--git-diff-filter` and `--git-diff-lines` | Good: coverage selects tests covering the changed line | Delegate both axes to Infection; retain the run-to-completion patch/PR requirement. |
| Python | mutmut | Strong function-content cache: re-tests mutants in changed functions and detects dependency/config changes | Strong runtime selection: records relevant tests by function execution, with an optional stack-depth bound | Delegate both axes to mutmut. Add complete killer output; do not substitute a Python static call graph. |
| Ruby | Mutant | Good subject-level direct selection with `--since REVISION` | Good when test integrations declare accurate subject expressions; otherwise mapping is project-dependent | Use Mutant `--since`; prefer explicit integration mapping, then runtime mapping, then full fallback. |
| Swift | Muter | Basic file filtering with `--files-to-mutate`; its documented CI example supplies files from Git diff | Limited: configured XCTest/Swift test suite runs for each mutant | Use Muter's file filter first; exhaust SwiftSyntax, SwiftPM, XCTest, SourceKit, and IndexStoreDB options before adding a generic fallback. |
| Zig | zig-mutants | Native `--since` and `--diff-file` changed-line selection over its AST mutation inventory | Native source-level mutation switching records direct test/mutant pairs; standard `-Dtest-file` roots are filtered per mutant, with static/concurrent/custom targets falling back to the full target | Use the owned Mull/Stryker hybrid. It avoids LLVM coverage because Zig 0.16's `~/dwarf-bug` makes DWARF-dependent selection unsound. |
| Lua | Future owned runner | None | None; Busted can expose per-test lifecycle events through a custom output handler | Use Git/Tree-sitter for direct `M_PR`; use Busted runtime events for `T(m)` and full fallback for other frameworks. |

### How to interpret the remaining gaps

Most supported ecosystems already have a useful native answer for at least one
axis. The remaining work is not accurately summarized as "Zig, Swift, and Ruby
have no support":

- Zig is the only current target where this project owns the mutation engine
  and the ecosystem does not provide another mature standard runner.
  zig-mutants now implements `M_PR`, stable structural identities, one-build
  mutation switching, direct per-test mutation coverage, persistent compiler
  caching, and full-target fallbacks without using DWARF. Nonstandard test
  roots still need explicit adapter support.
- Swift has a real mutation engine based on SwiftSyntax and a file-level Git
  integration path. Its gaps are finer-grained incremental invalidation and
  coverage-guided test selection, plus the Muter correctness fixes documented
  in [prs-needed.md](./prs-needed.md).
- Ruby Mutant already has good subject-level `M_PR` selection through `--since`
  and can have good `T(m)` selection when its integration coverage expressions
  are accurate. Ruby needs better default mapping and complete killer
  attribution, not replacement of Mutant's native subject model.
- Rust, Go, and C/C++ do not always select individual tests, but their native
  Cargo target, Go package, and test-binary scopes are useful conservative
  answers. That is a precision opportunity, not absence of support.

The implementation rule is therefore: prove the native ceiling with a small
revision-pair fixture for each ecosystem, use or extend that native mechanism,
and introduce Fact Mine only for the specific capability that remains missing.

### Native references

- StrykerJS [incremental mode](https://stryker-mutator.io/docs/stryker-js/incremental/)
  reuses prior results, diffs code and tests, and documents its invalidation
  limits. Its [configuration](https://stryker-mutator.io/docs/stryker-js/configuration/)
  supports per-test coverage and exact source mutation ranges.
- Stryker.NET documents [`since`, baseline reuse, per-test coverage, and
  disable-bail](https://stryker-mutator.io/docs/stryker-net/configuration/).
- PIT documents [incremental history](https://pitest.org/quickstart/incremental_analysis/)
  and explicitly states its dependency assumptions. PIT performs
  [line-coverage-guided test selection](https://pitest.org/quickstart/basic_concepts/)
  before mutation execution.
- cargo-mutants provides [`--in-diff`](https://mutants.rs/in-diff.html) for
  mutants overlapping Git diff regions.
- Gremlins provides [`--diff`](https://gremlins.dev/latest/usage/commands/unleash/#diff)
  and documents its package-local versus integration-mode test selection.
- Mull provides [Git-diff changed-line mutation](https://mull.readthedocs.io/en/latest/IncrementalMutationTesting.html)
  using its LLVM/Clang mutation inventory.
- Infection provides [`--git-diff-filter` and `--git-diff-lines`](https://infection.github.io/guide/how-to.html)
  and runs tests covering each mutated line.
- mutmut documents [incremental function caching, runtime test selection, and
  non-source invalidation](https://mutmut.readthedocs.io/en/latest/).
- Muter documents [`--files-to-mutate` and a Git-diff CI pattern](https://github.com/muter-mutation-testing/muter#running-muter).
- Ruby Mutant 0.15.1 exposes `--since REVISION` locally and its integrations
  select tests through subject coverage expressions.

## Native-first federated architecture

### Do not build a universal mutation generator

Test Miser must not parse all languages and invent its own mutations. Native
frameworks know details that a shared syntax tree does not:

- PIT mutates JVM bytecode and understands compiler output.
- Mull uses LLVM IR plus Clang AST validation.
- cargo-mutants understands Cargo packages, features, and Rust syntax.
- Stryker understands its mutation schemata and test-runner plugins.
- Infection uses PHP-Parser and PHPUnit coverage.
- mutmut uses Python execution stacks and LibCST.
- Muter uses SwiftSyntax and Swift build/test commands.

A generic replacement would lose precision, duplicate substantial work, and
drift from the mutations users already recognize in their ecosystem.

### Build one universal planner and contract

Test Miser should instead normalize capabilities and plans:

```text
                           +----------------------+
PR diff and prior facts -->| Test Miser planner   |
                           +----------+-----------+
                                      |
                 +--------------------+--------------------+
                 |                    |                    |
          native ecosystem      proven-gap fallback    impact expansion
          runner/compiler       Tree-sitter units      native/SCIP/facts
                 |                    |                    |
                 +--------------------+--------------------+
                                      |
                              mutation-plan/v1
                                      |
                              language runners
                                      |
                              mutant-facts/v1
```

The universal layer owns:

- Git base/head and rename-aware diff normalization;
- framework capability discovery;
- plan provenance and confidence;
- prior-result cache identity;
- cross-language component boundaries;
- fallback and escalation rules;
- merging complete mutant facts; and
- explaining why each mutant or scope was selected.

The native layer owns:

- candidate enumeration;
- mutation validity;
- native diff/history filtering;
- compilation and activation;
- native coverage/test selection; and
- language/test-framework execution.

### Capability negotiation

Each runner adapter should declare capabilities rather than force Test Miser to
infer behavior from a tool name:

```json
{
  "runner": "cargo-mutants",
  "capabilities": {
    "candidate_inventory": true,
    "diff_selection": "source-span",
    "stable_candidate_identity": false,
    "result_cache": false,
    "test_selection": "cargo-target",
    "per_test_coverage": false,
    "run_to_complete": "configurable"
  }
}
```

Important values should be descriptive rather than boolean. For example,
`test_selection` may be `per-test-runtime`, `line-coverage`, `package`,
`explicit-subject`, `test-binary`, or `full-suite`.

### Selection precedence

For each language component, use the strongest available source in this order:

1. Mutation-runner-native incremental selection and candidate identity.
2. Compiler/build-system-native source and dependency information.
3. Compiler-produced SCIP or equivalent semantic index.
4. Fact Mine normalized Tree-sitter units and facts.
5. Changed-file or entire-component fallback.

Lower-confidence evidence may expand a native plan but must not remove items
selected by a higher-confidence source. A heuristic Fact Mine edge must never
override a compiler-proven target.

Tree-sitter work starts only after an ecosystem probe demonstrates that levels
1 through 3 cannot express the required scope. The probe and its result belong
in the runner adapter's compatibility fixture so future framework releases can
replace the fallback automatically.

## Tree-sitter and Fact Mine

### What Tree-sitter is sufficient for

For `M_PR_direct`, Tree-sitter is sufficient to:

- parse every changed source file;
- map changed lines and columns to the smallest enclosing function, method,
  initializer, class body, or top-level chunk;
- distinguish executable changes from comments and whitespace;
- generate normalized source-unit fingerprints;
- recognize moves and line-number drift; and
- emit source spans that can be passed to a runner.

Git itself identifies the changed lines. Tree-sitter supplies syntax boundaries
and stable structure. This is enough for a conservative changed-unit fallback.

Tree-sitter is not sufficient to:

- enumerate the exact candidates a native mutation runner will generate;
- type-check a replacement;
- resolve macros, overloads, virtual dispatch, imports, or build configuration;
- identify every unchanged unit semantically affected by the PR; or
- construct the exact minimal `T(m)`.

Therefore the fallback should ask the native runner to enumerate or execute
mutants within Tree-sitter-derived spans. It should not manufacture the
mutations itself.

### Whether Fact Mine is the right implementation

Fact Mine already provides:

- a language registry and source discovery;
- Tree-sitter grammars across the supported languages;
- normalized owners, functions, calls, effects, and precise source spans;
- language-neutral fact documents; and
- optional SCIP occurrence-to-symbol integration.

That makes Fact Mine the right shared fallback, but the planner should use a
small changed-units profile rather than running every expensive fact pass. The
minimal output should be:

```json
{
  "file": "src/example.py",
  "language": "python",
  "unit_id": "Example.classify",
  "kind": "function",
  "span": { "start_line": 10, "end_line": 22 },
  "normalized_fingerprint": "sha256:...",
  "changed": true
}
```

If Fact Mine cannot parse a changed file reliably, the fallback expands to the
whole changed file. A parse failure must increase work, never silently omit
mutants.

### SCIP is for impact expansion, not direct selection

SCIP adds symbol identity and cross-file targets. It is useful for expanding
`M_PR_direct` toward `M_PR_impact`, particularly for callers, overrides, and
cross-file dependency edges. It is not needed to decide that a mutation
overlaps a changed line.

SCIP is also not an alias, effect, or path-feasibility analysis. Fact Mine's own
measurements show that SCIP improves call identity substantially where good
indexers exist, but still does not supply heap identity, must/may aliases,
escape behavior, or reflection semantics.

The local evidence and current limitations are recorded in Fact Mine's
[minimal call-graph feasibility assessment](../../../fact-mine/docs/agents/minimal-call-graph-feasibility.md)
and Lineage's
[cross-language call-resolution corpus](../../../lineage/docs/agents/call-resolution-mini-corpus.md).

Use SCIP when the language has a good producer. Do not replace stronger native
information:

- Rust: use cargo/rustc and cargo-mutants before generic SCIP or Fact Mine.
- Java/Kotlin: use PIT bytecode/history and compiler-produced indexes.
- C/C++: use Mull/LLVM/Clang and compilation databases.
- C#: use Stryker.NET/Roslyn evidence.
- JavaScript/TypeScript: use Stryker and the TypeScript/test-runner plugins.
- Go: use Gremlins and Go package/build information.
- Swift: prefer SwiftSyntax, SourceKit, and IndexStoreDB when available.
- Python/Ruby: prefer runtime coverage and framework mappings; use static facts
  only to expand uncertain scopes.
- Lua: prefer LuaLS-derived SCIP for semantic expansion, while using
  Tree-sitter for direct changed units.

## `mutation-plan/v1`

The planner should produce an auditable, language-neutral plan. It may contain
explicit candidate IDs when a runner exposes them or delegated source scopes
when the runner owns enumeration.

```json
{
  "schema": "mutation-plan/v1",
  "base": "origin/master",
  "head": "HEAD",
  "mode": "changed-units",
  "components": [
    {
      "language": "rust",
      "runner": "cargo-mutants",
      "selection": {
        "kind": "native-diff",
        "diff_file": "changes.diff"
      },
      "test_selection": "cargo-target",
      "reasons": ["native source-span diff support"]
    },
    {
      "language": "swift",
      "runner": "muter",
      "selection": {
        "kind": "source-files",
        "files": ["Sources/Example/Classifier.swift"]
      },
      "test_selection": "full-suite",
      "reasons": ["runner has file filtering but no native line-diff mode"]
    }
  ],
  "completeness": {
    "direct_candidates": true,
    "semantic_impact": false,
    "test_attribution": true
  }
}
```

Every scope must record:

- base and head identities;
- runner and adapter versions;
- mutation configuration fingerprint;
- selection source and granularity;
- candidate or source-unit fingerprints;
- cache reuse and invalidation reasons;
- `T(m)` selection mode;
- fallbacks taken; and
- separate direct, impact, and attribution completeness.

## Stable candidate identity and cache reuse

Absolute line numbers are not stable mutant identities. Inserting one line can
renumber thousands of otherwise unchanged candidates.

When a native framework exposes stable incremental identity, use it. Otherwise
an adapter should normalize candidate identity from:

- language and runner version;
- mutation operator;
- normalized original and replacement expressions;
- enclosing native or normalized subject fingerprint;
- relative AST position inside that subject; and
- build/mutation configuration fingerprint.

This identity supports four classifications:

- `new`: no equivalent candidate existed at the base revision;
- `changed`: the candidate or enclosing subject changed;
- `reused`: candidate and relevant evidence remain valid;
- `removed`: candidate existed at base but not at head.

The runner remains authoritative about whether two candidates are genuinely
equivalent. Generic fingerprints are a cache hint and must fail toward rerun on
ambiguity.

## Planning modes

Test Miser should expose explicit cost/confidence modes:

| Mode | `M_PR` construction | Intended use |
|---|---|---|
| `changed-lines` | Native candidates overlapping added/modified diff spans | Fast PR gate where the runner supports exact source spans. |
| `changed-units` | All candidates in the smallest changed enclosing units | Default fallback; handles signature and structural changes better than literal lines. |
| `impacted` | Changed units plus native/compiler/SCIP/Fact Mine dependency expansion | Higher-confidence PR analysis; still an approximation. |
| `component` | Every candidate in affected build/test components | Configuration, generated code, unresolved FFI, and uncertain cross-language boundaries. |
| `full` | `M_HEAD` | Periodic calibration and default-branch corpus refresh. |

Recommended defaults:

- Use a runner's native incremental mode when it maintains a full cached report
  and documents invalidation, as StrykerJS, Stryker.NET, PIT, and mutmut do.
- Otherwise use native `changed-lines` when available, as cargo-mutants,
  Gremlins, Mull, and Infection provide.
- Otherwise use Fact Mine `changed-units` and native runner scope filters.
- Escalate to `component` for unresolved generated code, dependency/config
  changes, FFI, subprocess, or cross-language execution edges.
- Run `full` periodically to measure false reuse and refresh the Test Miser
  corpus.

## Cross-language behavior

Cross-language planning is most important at component boundaries. The planner
does not need one parser that understands every language's semantics. It needs
to know that a changed component may invalidate another runner's scope.

Examples:

- Ruby invokes a Rust executable through a subprocess.
- Python imports a native C extension.
- JavaScript calls a Go service in an integration test.
- Swift links a C library.
- generated TypeScript clients depend on an OpenAPI schema.

For direct `M_PR`, each changed language still delegates candidate enumeration
to its own runner. For impact mode, Lineage component edges and Fact Mine/SCIP
evidence expand the affected components. If the boundary cannot be resolved,
the planner selects the complete downstream component rather than guessing a
method-level slice.

Cross-language `T(m)` is harder. Native per-test coverage usually ends at a
runtime or process boundary. The safe initial rule is:

- retain native per-test selection within one supported runtime;
- add explicitly configured integration test commands for known boundaries;
- run those commands to completion; and
- fall back to the component's full integration suite for unresolved edges.

## Changed tests and historical facts

A source-only PR and a test-only PR invalidate different parts of the mutation
matrix.

```text
                 m1       m2       m3
test A          kill     pass     kill
test B          pass     kill     pass
test C          pass     pass     pass
```

- Changed production unit: regenerate or rerun its selected mutants and any
  conservatively impacted cached mutants.
- Changed test: invalidate that test's observations for its prior and current
  coverage footprint.
- New test: execute it against existing mutants in its coverage footprint.
- Deleted test: remove its row; no mutant execution is required solely for the
  deletion.
- Changed runner, mutator set, compiler, features, dependencies, or relevant
  configuration: invalidate the affected candidate/component cache.

Framework-native invalidation should remain authoritative. The shared planner
fills only gaps and records when it cannot prove cache validity.

## Zig-native state-of-the-art target

Zig should not wait for the generic Tree-sitter fallback. zig-mutants already
uses the compiler-distributed `std.zig.Ast`, so it has the correct native
foundation for both candidate enumeration and changed-unit boundaries.

To reach the useful capabilities of Stryker and Mull, zig-mutants should add:

1. Native PR selection. Accept base/head revisions or a unified diff, normalize
   renames, and intersect added or modified byte spans with the native candidate
   inventory. Also support an AST-enclosing-unit mode for signature and
   structural changes.
2. Structural candidate identity. The current ID includes absolute line and
   column, so unrelated line insertion invalidates it. Replace that cache key
   with the mutation operator, enclosing declaration fingerprint, relative AST
   path, original tokens, replacement tokens, and Zig/configuration version.
3. Incremental result reuse. Persist candidate results and their selected test
   observations, with explicit invalidation for source units, tests, Zig
   version, build options, dependencies, test runner, and mutation operators.
4. Native test inventory. Use Zig's standard test metadata or a custom test
   runner rather than scraping human console output when the project exposes a
   standard `zig test` or `zig build test` graph.
5. Coverage-guided `T(m)`. Collect candidate- or enclosing-unit execution per
   test during a baseline run, then run only those tests for each mutant. Static
   initialization, comptime behavior, unresolved integration commands, and
   uncertain mappings must conservatively select the complete affected test
   target.
6. Complete attribution. Keep the existing `--test-miser` run-to-completion
   behavior, but emit selected, covered, and killing test IDs through a stable
   structured protocol instead of relying on console parsing.
7. Explainable plans. Emit the native candidate ID, PR-selection reason, cache
   decision, test-selection mode, and every fallback in `mutation-plan/v1` and
   `mutant-facts/v1`.

The coverage implementation must not run the entire suite once per test or run
each mutant once per test. That recreates the multiplicative cost Test Miser is
eliminating. The first Zig spike should evaluate the compiler's custom test
runner and instrumentation facilities, recording the current test ID while
instrumented candidate or unit IDs execute in one baseline corpus pass.

### Zig 0.16 DWARF constraint

The local reproduction at `~/dwarf-bug` demonstrates that Zig 0.16.0 can emit
invalid LLVM debug locations and DWARF line-table entries for generic/comptime
functions. Its 22-line source has generated locations referring to line 43.
This matters if coverage uses program counters plus DWARF to infer which source
unit each test executed.

It does not affect current zig-mutants candidate locations:

- candidates and function spans come from `std.zig.Ast` source byte offsets;
- mutant line and column values are calculated directly from source text; and
- current test source lines are found from Zig test names and source text.

It can make a future DWARF-only `T(m)` map unsound. A phantom or incorrectly
attributed line can cause the planner to omit a test that actually reaches a
mutant. The Zig coverage design must therefore:

- prefer source-assigned candidate or unit IDs carried through instrumentation
  over translating program counters back through DWARF;
- treat unmapped, conflicting, out-of-range, generic, and comptime mappings as
  incomplete and expand `T(m)` rather than remove tests;
- never use DWARF as the sole negative proof that a test does not cover a
  mutant until the compiler defect is fixed and version-gated; and
- add the `~/dwarf-bug` generic/comptime shape to zig-mutants' coverage
  regression corpus.

If a safe one-pass coverage map is not available for a Zig version or build
mode, zig-mutants should still provide native `M_PR` and cache reuse while
falling back to the affected test target for `T(m)`.

## Implementation path

### Phase 0: ecosystem capability qualification

1. For every supported runner, create a two-revision mini-repo fixture with a
   changed production line, unchanged candidate, changed test, and known
   per-mutant killer set.
2. Exercise the runner's standard diff, history, coverage, test-filter, and
   machine-report facilities without Fact Mine.
3. Record the strongest sound native granularity and its invalidation limits in
   the adapter capability registry.
4. Open or maintain an upstream patch only where the runner fails to execute or
   retain information that no output adapter can recover.
5. Declare a Fact Mine requirement only after the fixture proves a native gap.

### Phase 1: capability adapters and native delegation

1. Add a runner-capability registry to Test Miser.
2. Add `test-miser plan --base REV --head REV`.
3. Delegate to existing native facilities for StrykerJS, Stryker.NET, PIT,
   cargo-mutants, Gremlins, Mull, Infection, mutmut, and Mutant.
4. Normalize plan provenance without reimplementing native selection.
5. Preserve complete run-to-completion attribution from `mutant-facts/v1`.

This phase has the highest leverage and lowest semantic risk.

### Phase 2: Zig-native incremental and test selection

Implement the Zig state-of-the-art target above, starting with source-span PR
selection and structural IDs, then cache reuse, native test metadata, and
one-pass per-test coverage. Gate DWARF-derived coverage on the generic/comptime
regression corpus and fall back conservatively when it is incomplete.

### Phase 3: candidate inventory contract

Define `mutant-candidates/v1` with native IDs, spans, subjects, operators,
original/replacement snippets, and configuration fingerprints. Add cheap
inventory adapters where frameworks expose dry-run/list output.

Use the completed zig-mutants inventory as the reference native implementation,
then add an equivalent contract to the future Lua runner.

### Phase 4: Fact Mine changed-unit fallback

Add a lightweight Fact Mine profile that emits only language, normalized unit,
span, executable-code status, and fingerprint. Avoid full complexity, effect,
or fixed-point analysis for direct planning.

Use it only for a capability still missing after ecosystem qualification. The
initial likely consumers are custom command runners and Lua. Swift must first
exhaust SwiftSyntax and Swift compiler/index support. Zig uses `std.zig.Ast`
directly and should not route through Fact Mine.

### Phase 5: optional impact expansion

Combine, in precedence order:

1. native compiler/build dependency data;
2. native mutation history invalidation;
3. SCIP exact project edges;
4. Fact Mine calls/effects and Lineage component relationships; and
5. component-level fallback.

Label this mode `impact`, not `complete`, until measured against full reruns.

### Phase 6: calibration

On representative repositories, compare each optimized plan to a full run:

- fraction of mutant trials avoided;
- changed outcomes incorrectly reused;
- mutants missed by direct versus impact modes;
- tests omitted from `T(m)` that kill the mutant in a full run;
- wall time and setup/test time separately; and
- differences by language and framework.

No heuristic should become a default merely because it is fast. It must show a
measured error/cost tradeoff.

## Acceptance corpus

Every runner planner needs revision-pair fixtures covering:

1. changed comparison or condition creates new candidates;
2. whitespace/comment-only change creates no new direct candidates;
3. line insertion preserves unchanged candidate identity;
4. function move or file rename preserves identity where the runner permits;
5. deleted code removes candidates;
6. signature change expands to the enclosing unit when line-only selection is
   unsafe;
7. test-only change invalidates the appropriate matrix row;
8. dependency/configuration change escalates scope;
9. generated-source input change escalates to the generated component;
10. FFI or subprocess edge expands the downstream component; and
11. unresolved parse or semantic evidence falls back rather than omitting work.

The full-run result is the oracle. Each fixture must assert both the selected
`M_PR` and every `T(m)`.

## Final assessment

The initial assumptions are partly correct:

- Tree-sitter is enough to locate direct changed code and enclosing units for a
  portable `M_PR_direct` fallback.
- Tree-sitter is not enough to enumerate native mutants; mutation frameworks
  must remain authoritative.
- Exact semantic `M_PR_impact` and exact minimal `T(m)` are undecidable in the
  general case.
- Static `T(m)` is especially difficult for Python and Ruby.

The important correction is that mature frameworks already solve useful
versions of both problems. Stryker, PIT, Infection, and mutmut have strong
runtime test-selection evidence. Stryker, cargo-mutants, Gremlins, Mull,
Infection, mutmut, and Mutant already have meaningful incremental or diff-based
mutant selection.

The best path is therefore one cross-language planner over many native engines:

```text
qualify and use native ecosystem support first
    -> extend owned zig-mutants and pursue focused upstream fixes
    -> Fact Mine/Tree-sitter only for a proven remaining gap
    -> SCIP/native semantic impact expansion
    -> component/full fallback when uncertain
```

That architecture gains a uniform PR workflow without discarding the best
language-specific information or pretending a generic static analyzer can
solve an undecidable problem exactly. No generic Tree-sitter planner work is
required before the ecosystem qualification and Zig-native phases are complete.
