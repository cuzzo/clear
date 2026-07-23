# Lineage CLI and Evidence Pipeline

Status: Proposed design

## Summary

Lineage should provide a coherent command-line workflow for producing,
ingesting, and reviewing architectural and verification evidence:

```text
lineage analyse ─┐
                 ├─> run manifest + artifacts ─> lineage ingest ─> lineage diff
lineage verify ──┘
```

The CLI is an evidence pipeline, not a build system. Lineage owns evidence
identity, normalization, completeness, ingestion, and presentation. Existing
build and test systems continue to own dependency graphs, compilation,
incrementality, caching, sandboxing, and test execution.

Bazel is a first-class optional executor. It is not a prerequisite for any
Lineage command.

## Goals

- Make `lineage diff` a useful architectural and risk-oriented alternative to
  reading a raw `git diff` first.
- Allow bundled static analysis to run without repository configuration.
- Provide a reproducible configured path for tests, coverage, mutation,
  fuzzing, sanitizers, and other dynamic evidence.
- Preserve standalone ingestion from existing CI systems and third-party
  services.
- Distinguish exact, partial, stale, missing, and unconfigured evidence.
- Support repositories that use Bazel without requiring other repositories to
  adopt Bazel.
- Replace the hard-coded orchestration in `tools/import_repo.rb` with a typed,
  declarative configuration and run manifest.
- Keep provider-specific parsing outside the trusted database-writing core, as
  specified by `plugins.md`.

## Non-goals

Lineage must not become responsible for:

- Modeling source and generated-file dependency graphs.
- Determining which compilation actions are invalidated by a source change.
- Build or test result caching.
- Remote execution.
- Hermetic toolchain installation.
- Replacing Cargo, Go, Bazel, Gradle, Maven, npm, Make, CMake, or repository
  scripts.
- Inferring every repository's complete test corpus without configuration.
- Deploying software. The convenience command is therefore `lineage ci`, not
  `lineage cicd`.

## Command Model

| Command | Configuration required | Bazel required | Primary effect |
| --- | --- | --- | --- |
| `lineage diff` | No | No | Render a revision or working-tree architectural diff using available evidence. |
| `lineage analyse` | No for embedded providers; yes for repository commands | No | Run static analyzers and produce normalized findings. |
| `lineage diff --analyse` | No for embedded providers; yes for repository commands | No | Refresh static analysis before rendering the diff. |
| `lineage verify --profile NAME` | Yes | No | Run configured verification producers and write artifacts plus a run manifest. |
| `lineage ingest` | No | No | Validate and transactionally ingest explicit artifacts or a run manifest. |
| `lineage ci` | Yes | No | Run analyse, verify, ingest, and configured policy gates. |
| `lineage diff --full` | No | No | Render every available evidence category and disclose gaps. |

The documented spelling is `analyse`. An `analyze` alias may be provided for
discoverability, but both spellings must invoke exactly the same implementation.

### `lineage diff`

`lineage diff` is read-only unless an explicit refresh flag is supplied. It
must not unexpectedly run tests, mutation, fuzzing, or other expensive tools.

The command should:

- Use the existing revision-pinned `DiffPlan` implementation.
- Support commit-to-commit and working-tree comparisons.
- Rank files and logical units by architectural risk.
- Summarize production, test, generated, documentation, configuration, and
  dependency changes.
- Overlay coverage, mutation, hazard, SARIF, and other evidence when available.
- Clearly identify the revision and corpus represented by every evidence kind.
- Continue rendering useful static and Git-derived results when dynamic
  evidence is unavailable.

Suggested forms:

```sh
lineage diff
lineage diff BASE HEAD
lineage diff --format text
lineage diff --format json
lineage diff --ui
lineage diff --analyse
lineage diff --full
lineage diff --full --require-profile full
```

`--analyse` runs only embedded, allowlisted static analysis by default. Use
`--trust-current-config` only after reviewing repository configuration to run
its command producers. It does not imply `verify`.

`--full` means "show all evidence categories," not "pretend complete evidence
exists." Without a complete verification run, it must render the diff with an
evidence completeness report.

For automation that requires complete evidence,
`--require-profile PROFILE` fails if that profile has not been ingested for the
exact selected revision, tree, configuration, and corpus.

### `lineage analyse`

`lineage analyse` runs embedded source-derived analysis that does not require a
project build or dynamic test execution. FactMine is currently the sole
embedded provider; Decomplex, Espalier, NilKill, and SlopCop remain external
artifact producers until they have constrained, first-class adapters.

The embedded provider is a bounded syntax-hazard scan, not FactMine's full
normalized fact pipeline. Its SARIF explicitly declares partial analysis and
the `bounded-syntax-hazard-scan` capability; it must not be read as complete
FactMine, Decomplex, Espalier, or NilKill evidence.

With no configuration, it auto-detects supported source languages and runs the
safe embedded default. Repository configuration may select providers, exclude
paths, set thresholds, or add external SARIF-producing analyzers, but command
execution requires `--trust-current-config`.

Analysis produces normalized artifacts and a run manifest. It may print the
merged finding list, but it does not implicitly mutate the Lineage database.
Users can request ingestion explicitly or use `lineage ci`.

Suggested forms:

```sh
lineage analyse
lineage analyse --ingest
lineage analyse --profile security --trust-current-config
```

### `lineage verify`

`lineage verify` runs a repository-defined verification profile. It invokes
existing tools and records their outputs; it does not model their internal
build graph.

Typical profiles are:

- `quick`: unit tests and inexpensive static checks.
- `changed`: repository-defined change-focused verification.
- `ci`: the normal pull-request gate.
- `full`: all configured coverage, mutation, fuzz, sanitizer, race, and
  integration evidence.

Suggested forms:

```sh
lineage verify --profile quick
lineage verify --profile full
lineage verify --profile full --ingest
```

Every producer reports `complete`, `partial`, `failed`, `cancelled`, or
`skipped`. A successful command alone does not prove that its artifact covers
the entire repository or test corpus.

### `lineage ingest`

Ingestion must remain independently useful. It must not require `lineage.yml`,
`lineage verify`, Bazel, or a Lineage-created CI run.

Direct artifact ingestion remains supported:

```sh
lineage ingest \
  --kind coverage \
  --format cobertura \
  --input coverage.xml \
  --commit "$GITHUB_SHA"
```

The preferred complete form consumes a run manifest:

```sh
lineage ingest --run .lineage/runs/RUN_ID/manifest.json
```

This permits ingestion from GitHub Actions, Buildkite, Jenkins, Bazel, Codecov,
mutation services, security scanners, and organization-specific pipelines.

Lineage core remains responsible for verifying revisions, source content,
paths, scopes, and logical-unit identity before writing the database. Providers
and external plugins never write trusted tables directly.

### `lineage ci`

`lineage ci` is a convenience composition rather than a separate execution
engine:

```text
analyse -> verify -> ingest -> policy evaluation
```

Example:

```sh
lineage ci --profile full --require-complete
```

The equivalent explicit sequence is:

```sh
lineage analyse
lineage verify --profile full
lineage ingest --latest-run
lineage diff --full --require-profile full
```

Lineage does not perform deployment, so the command must not be named or grow
into a general CI/CD deployment system.

## Evidence Completeness

Missing evidence must never prevent Lineage from showing facts it can support.
It must also never be interpreted as negative evidence.

Example `lineage diff --full` output:

```text
Evidence completeness: 72%

exact    Static analysis
exact    Unit coverage
exact    Integration coverage
missing  Mutation evidence
stale    Fuzz coverage (3 commits behind)
none     Race testing (not configured)
```

The evidence states are:

- `exact`: revision, source tree, configuration, and corpus match.
- `partial`: valid observations exist but do not establish complete negative
  evidence for the selected corpus.
- `stale`: an artifact exists but its revision, source tree, configuration, or
  corpus does not match.
- `missing`: the profile expects an artifact but none was ingested.
- `unconfigured`: the repository does not claim to produce this evidence.
- `failed` or `cancelled`: production was attempted but did not complete.

Policies may require exact evidence, but presentation must continue to degrade
honestly.

## Configuration

The canonical authoring format is `lineage.yml` at the repository root. A
`lineage.json` representation may be accepted through the same typed schema,
primarily for generated configuration. A repository containing both is an
error; there must be no precedence ambiguity.

Lineage should publish a JSON Schema for validation, editor completion, and
stable versioning.

The existing `.lineage/diff.toml` classification overrides should migrate into
this schema. A compatibility reader may remain for a bounded migration period,
but Lineage must not maintain two independent long-term configuration models.

Example:

```yaml
version: 1

classification:
  - prefix: services/generated/
    role: generated
  - path: spec/production_contract_spec.rb
    role: production

profiles:
  quick:
    producers: [static-analysis, unit-tests]
  full:
    producers:
      - static-analysis
      - unit-tests
      - integration-tests
      - mutation

producers:
  static-analysis:
    executor: lineage
    providers: [decomplex, espalier, nil-kill, slopcop]

  unit-tests:
    executor: command
    argv: [bundle, exec, prspec, spec]
    timeout: 15m
    produces:
      - kind: coverage
        format: simplecov
        path: coverage/.resultset.json
        scope: unit

  bazel-tests:
    executor: bazel
    targets: ["//..."]
    produces:
      - kind: bazel-bep
        path: .lineage/artifacts/bep.json
```

The config describes evidence producers and their declared artifacts. It must
not grow fields for compiler inputs, generated-file dependencies, action cache
keys, or rebuild invalidation. Those belong to the selected build tool.

Commands are represented as argument arrays, not interpolated shell strings.
Shell execution, if supported at all, must be explicit and visibly less safe.

## Executors

### Lineage executor

Runs bundled analyzers directly and records their versions, settings, source
corpus, and outputs.

### Command executor

Runs a repository-owned command with an explicit argument vector, working
directory, environment allowlist, timeout, and resource policy. This is the
portable default for Cargo, Go, Gradle, Maven, npm, Make, CMake, `just`, and
custom project scripts.

### Bazel executor

Bazel is an optional high-quality integration. Lineage should invoke declared
targets and consume the Build Event Protocol for:

- Expanded and configured targets.
- Target success and failure.
- Test attempts, runs, and shards.
- Flaky versus failed test summaries.
- Logs and generated artifact locations.
- Effective invocation and build configuration.

Optional Bazel aspects may later produce dependency, source-ownership, lint, or
other metadata. Lineage must not require custom aspects for basic use and must
not reconstruct Bazel's action graph.

## Run Manifest

Both `analyse` and `verify` write a versioned `lineage-run/v1` manifest. At
minimum it records:

- Repository identity.
- Full commit identity.
- Dirty-tree content fingerprint when applicable.
- Configuration hash.
- Producer name, version, and settings hash.
- Exact argument vector and working directory.
- Start time, duration, exit status, and completion state.
- Artifact kind, format, path, and content hash.
- Evidence scope and corpus identity.
- Whether the artifact supports complete negative evidence.
- Tool logs and diagnostic locations.

Artifact paths are relative to the manifest or repository and cannot escape
their declared root. Ingestion verifies hashes before parsing.

## Working-tree Evidence

Commit evidence cannot be presented as exact evidence for a modified working
tree. `lineage diff` may always show Git-derived and source-derived changes, but
dynamic evidence is exact only when its run manifest matches a deterministic
dirty-tree fingerprint.

If a manifest matches `HEAD` but files are modified, Lineage marks affected
evidence stale or out of scope rather than silently attributing it to the
working tree.

## Trust and Security

Verification configuration contains executable commands. A hosted Lineage
service must never execute commands newly introduced or changed by an
untrusted pull request without approval.

Required protections include:

- Execute commands from a trusted base revision or separately approved
  repository configuration.
- Treat a change to `lineage.yml`, build scripts, or producer scripts as a
  security-sensitive configuration change.
- Permit revision-scoped classification metadata to affect presentation, but
  do not confuse that with authority to execute commands.
- Use argument vectors instead of shell interpolation.
- Apply time, memory, process, filesystem, and network restrictions when
  analyzing third-party repositories.
- Preserve complete logs and producer provenance.
- Never give external plugins direct database authority.

## Failure and Exit Semantics

Commands should distinguish operational failure from incomplete evidence:

- `0`: requested operation succeeded; non-required evidence may be absent.
- Nonzero operational error: invalid config, analyzer crash, corrupt artifact,
  database failure, or invalid revision.
- Nonzero verification failure: a required producer or test failed.
- Nonzero policy failure: the operation completed, but a configured policy or
  `--require-profile` condition was not satisfied.

Exact numeric exit codes should be stable and documented for CI consumers.

## Migration Strategy

1. Introduce the typed config schema and `lineage-run/v1` manifest.
2. Add the generic command and bundled-Lineage executors.
3. Implement `analyse` and `verify` as artifact producers.
4. Extend `ingest` to consume run manifests while preserving every existing
   direct ingestion command.
5. Add text and JSON renderers over the existing `DiffPlan` for `lineage diff`.
6. Add `--analyse`, `--full`, and `--require-profile` semantics.
7. Add `lineage ci` as a thin composition of existing commands.
8. Add the Bazel executor and BEP adapter.
9. Convert `tools/import_repo.rb` into a compatibility wrapper around the new
   commands, then remove its duplicated orchestration.
10. Migrate `.lineage/diff.toml` classification into `lineage.yml`.

## Acceptance Criteria

- `lineage diff` and `lineage analyse` work in an unconfigured supported
  repository without Bazel.
- A configured non-Bazel repository can produce and ingest a complete evidence
  profile using its existing scripts.
- A Bazel repository can use BEP-backed verification without a parallel Lineage
  build graph.
- Direct artifact ingestion continues to work without configuration.
- `lineage diff --full` remains useful with partial evidence and labels every
  gap honestly.
- `--require-profile full` fails when any required evidence is not exact and
  complete.
- Working-tree evidence is never confused with commit-pinned evidence.
- Untrusted revision configuration cannot silently authorize command
  execution.
- The legacy importer delegates to the new typed pipeline rather than retaining
  a second orchestration implementation.

## Final Decision

Lineage will provide a declarative evidence pipeline through `lineage.yml`, but
will not become a build system. Bazel is supported as an optional executor and
rich evidence source. All commands remain independent of Bazel; ingestion
remains open to external artifacts; and diffs remain useful even when the full
verification profile has not been run.
