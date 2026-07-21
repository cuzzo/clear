# Incremental mutation artifacts and Lineage sync

## Implemented checkpoint path

The repository now implements the safe file-based checkpoint boundary used by
GitHub CI:

- `test-miser-artifact update` creates a canonical, self-contained
  `mutation-corpus/v1`, an immutable `mutation-delta/v1`, a digest manifest,
  per-suite `mutant-facts/v1`, and combined Weak Tests SARIF;
- `test-miser-github-artifact restore` looks up the artifact for the exact
  parent commit, rejects expired/corrupt/cross-repository artifacts, and never
  substitutes a checkpoint from another commit;
- Ruby subjects and Zig source files are independently replaceable components,
  so an incremental run carries unchanged components forward without losing
  whole-corpus auditability;
- a missing exact parent forces a complete runner plan, producing a new
  self-contained checkpoint rather than depending on a distant artifact; and
- `.github/workflows/test-miser.yml` republishes that complete state at every
  successfully tested default-branch commit as
  `test-miser-corpus-<head-sha>`.

GitHub's 90-day retention is a cache lifetime, not a correctness assumption.
An active default branch continuously advances the exact-parent checkpoint. If
the repository is idle beyond retention, the next successful commit performs
a complete refresh. Thus the latest successfully processed default-branch
artifact is sufficient by itself to populate Lineage; no delta chain or old
artifact is needed to recover current state.

The richer Lineage-native transactional tables described later in this design
remain future work. Today the checkpoint materializes Lineage's existing
`ingest-mutants` and `ingest-sarif` inputs, which is enough to rebuild current
mutation and Weak Tests views without teaching Lineage to read compressed
corpus envelopes directly.

The checkpoint -> ledger path is wired:
`gems/lineage/tools/ingest_mutation_corpus.rb` accepts either the canonical
`mutation-corpus.json.zst` envelope (materializing it via
`test-miser-artifact materialize`) or an already-materialized directory, then
runs `ingest-mutants` per suite and `ingest-sarif` for the combined Weak
Tests SARIF. `bin/lineage-import --mutation-corpus=PATH` invokes it as part
of a repository import, so downloading the latest
`test-miser-corpus-<head-sha>` artifact and passing it to the importer fully
populates the mutation-exposure and Weak Tests views. The round-trip is
covered by `gems/test-miser/test/lineage_ingest_integration_test.rb`. The
`result` job additionally publishes an advisory per-suite mutant-count step
summary on every run (`tools/test_miser_step_summary.rb`); verdict-bearing
weak-test findings still come only from the canonical snapshot.

## Decision

Test Miser should own a file-based, cross-run mutation corpus that can be
updated by small immutable delta artifacts. Lineage should ingest those same
deltas transactionally and maintain a materialized current mutation state in
`lineage.db`.

The mutation runner remains responsible for executing mutants. Test Miser is
responsible for normalizing, validating, merging, applying, and compacting the
runner facts. Lineage is responsible for mapping the resulting state to
logical units and maintaining history and UI summaries. Neither Test Miser nor
CI needs to read or write `lineage.db` to decide which mutants to run.

This separates three artifacts that must not be conflated:

- a **run fragment**, produced by one runner shard;
- a **delta**, describing authoritative changes from one corpus state to the
  next; and
- a **snapshot**, materializing the complete current corpus after applying an
  ordered delta chain.

Weak-test findings may be generated only from an auditable snapshot. A PR
fragment or delta is not, by itself, proof that a test kills no mutant across
the whole corpus.

## Why the current shape is insufficient

`mutant-facts/v1` is currently useful as a portable runner result, but it is
mostly a list of subject summaries plus optional test/mutant attribution. It
does not define cross-commit replacement semantics.

Lineage currently converts subject facts into append-oriented quality and
`test_exposure_events` rows. That path is idempotent for repeated input, but it
cannot correctly maintain a current mutation corpus when:

- a mutant is removed;
- a previously killed mutant survives at the next commit;
- a test is renamed or deleted;
- a candidate keeps its identity while its source location moves;
- one component is refreshed while another component is reused; or
- a partial PR run must coexist with a previously complete snapshot.

In particular, mutation evidence cannot use monotonic `MAX(killed)` merge
semantics. A new surviving observation must replace the old killed observation
in current state while preserving both observations in history.

## Artifact model

Keep `mutant-facts/v1` as the runner interchange format. Add two Test Miser
envelopes:

- `mutation-delta/v1`: immutable changes relative to a named base state;
- `mutation-corpus/v1`: a complete materialized state at one commit.

Both formats use the same normalized entities:

- corpus/component;
- candidate mutant;
- test;
- candidate/test observation; and
- completeness proof.

### Corpus identity

A repository may contain several independently refreshed mutation components.
The stable corpus key is:

```text
repository identity
+ component key
+ language
+ runner family
+ mutation configuration identity
```

Examples of component keys are `ruby:espalier`, `rust:lineage`, and
`zig:runtime-frame`. A runner upgrade or operator/configuration change does not
silently reuse the old corpus. It either starts a new corpus generation or
emits an explicit full invalidation.

Each corpus records these fingerprints separately:

- runner and adapter versions;
- mutation operator/configuration fingerprint;
- build dependency and feature fingerprint;
- test command/configuration fingerprint;
- source inventory fingerprint; and
- test inventory fingerprint.

This allows a test-only change to invalidate observations without pretending
that the candidate inventory changed.

### Stable entity identities

Candidate IDs must not be based only on line numbers. Prefer a runner's native
stable ID. Otherwise use the normalized structural identity described in
`optimizations.md`: operator, original/replacement expression, enclosing
subject fingerprint, relative AST position, language, runner, and mutation
configuration.

Test IDs must be stable framework IDs, qualified by component. File and line
are mutable display locations, not identity. A rename map may preserve a test
identity; otherwise the producer emits one test tombstone and one new test.

An observation key is `(corpus_id, candidate_id, test_id)`. Its current value
is one of:

- `not-selected`;
- `passed`;
- `killed`;
- `timeout`;
- `error`; or
- `unknown`.

Only `passed` and `killed` from a complete run-to-completion trial are valid
inputs to exact weak-test kill signatures. Timeout/error/unknown keep the
corpus non-auditable for the affected scope.

## `mutation-delta/v1`

A delta is an immutable, content-addressed artifact. A representative shape is:

```json
{
  "schema": "mutation-delta/v1",
  "artifact_id": "sha256:...",
  "repository": "github.com/example/project",
  "base": {
    "commit": "abc123",
    "state_digest": "sha256:base-state"
  },
  "head": {
    "commit": "def456",
    "state_digest": "sha256:expected-head-state"
  },
  "producer": {
    "name": "zig-mutants",
    "version": "0.1.0",
    "adapter_version": "test-miser/0.1.0"
  },
  "components": [
    {
      "id": "zig:runtime-frame",
      "generation": "sha256:runner-and-config",
      "selection": {
        "mode": "native-diff",
        "direct_complete": true,
        "impact_complete": false,
        "attribution_complete": true
      },
      "upsert_tests": [],
      "remove_tests": [],
      "upsert_candidates": [],
      "remove_candidates": [],
      "upsert_observations": [],
      "remove_observations": [],
      "invalidations": []
    }
  ]
}
```

Every upsert contains the complete current entity, not an ambiguous JSON merge
patch. Every removal is a tombstone containing the stable ID and reason.
Tombstones are required because omission from an incremental run means
"unchanged", not "deleted".

`invalidations` cover cases that cannot be enumerated cheaply. They name the
smallest invalid scope, such as a component, subject, test footprint, or
configuration generation. Applying an invalidation removes that scope from
the auditable current state until replacement facts arrive.

### Shards versus deltas

Parallel shards for the same planned run are run fragments, not independent
cross-commit deltas. Test Miser first merges them under one run ID and plan
digest. Their assigned candidate sets must be disjoint, and their union must
match the plan's expected set.

Only then does Test Miser produce one delta. This avoids ordering ambiguity and
prevents a missing shard from being mistaken for unchanged evidence.

## `mutation-corpus/v1`

A snapshot contains the complete normalized current state plus provenance:

```json
{
  "schema": "mutation-corpus/v1",
  "repository": "github.com/example/project",
  "commit": "def456",
  "state_digest": "sha256:...",
  "parents": ["sha256:base-state", "sha256:delta"],
  "components": [],
  "completeness": {
    "candidate_inventory": true,
    "impact": true,
    "test_inventory": true,
    "attribution": true,
    "run_to_complete": true,
    "auditable": true
  }
}
```

The digest is computed from a canonical serialization of current entities and
component generations, not timestamps or display ordering. Applying the same
delta twice produces the same digest.

A snapshot is auditable only when every component contributing to the audit
has a valid completeness proof. A direct changed-line PR run with
`impact_complete: false` may update useful evidence but cannot manufacture an
auditable global snapshot. It should carry the last full audit timestamp and a
precise stale/unknown scope.

## Delta construction and application

The normal flow is:

```text
runner shards
    -> mutant-facts/v1 run fragments
    -> Test Miser same-run merge and validation
    -> mutation-delta/v1
    -> apply to prior mutation-corpus/v1
    -> new mutation-corpus/v1
    -> weak-test SARIF + Lineage sync
```

Application rules are deliberately strict:

1. Verify schema, artifact digest, repository, base commit, and base state
   digest.
2. Verify component generation and the mutation plan/completeness claims.
3. Apply invalidations and tombstones before upserts.
4. Reject duplicate conflicting operations in one delta.
5. Recompute component inventories, kill signatures, and completeness.
6. Verify the computed head state digest if the producer supplied it.
7. Write the new snapshot atomically.

Disjoint shards from one run may be merged in any order. Cross-commit deltas
are ordered and use compare-and-swap semantics on `base.state_digest`. A delta
whose base digest is not the receiver's current digest is rejected; it is never
best-effort merged.

For two independent PRs, rebase/recompute the second delta against the current
default-branch snapshot. Do not attempt a three-way merge of empirical test
outcomes.

## Invalidation rules

Native framework invalidation remains authoritative. The shared fallback must
fail toward rerunning more work.

- Changed production subject: replace its candidate inventory and observations
  for selected/impacted candidates; tombstone disappeared candidates.
- Changed test: invalidate that test's observations across its old and new
  runtime footprint, then rerun it against the affected retained candidates.
- New test: add it and collect observations across its footprint.
- Deleted test: tombstone the test and all its observations.
- Runner/operator/config change: start a new component generation or fully
  invalidate the component.
- Dependency, build, feature, generated-code, FFI, or unresolved cross-language
  change: invalidate the affected component unless a native runner proves a
  smaller safe scope.
- Incomplete/failed trial: retain diagnostic facts, but invalidate exact
  attribution for that candidate rather than retaining its old result as
  current truth.

This is the same correctness boundary as `M_PR` in `optimizations.md`: cheap
sync is safe only when the delta accounts for removals and every invalidated
scope, not merely newly executed mutants.

## Lineage storage design

Lineage should add current-state mutation tables rather than reconstructing
state from `test_exposure_events`:

- `mutation_corpora`: corpus ID, component, generation, current commit,
  current state digest, completeness, and last full verification time;
- `mutation_candidates`: stable candidate ID, current location, subject,
  operator, outcome, generation, and provenance;
- `mutation_tests`: stable test ID and current display location;
- `mutation_observations`: current candidate/test result and completeness;
- `mutation_sync_events`: immutable applied delta/checkpoint ledger; and
- `mutation_invalid_scopes`: unresolved invalidations and their reasons.

Current-state rows use stable IDs and foreign keys. Historical sync events keep
artifact IDs/digests and commit linkage without duplicating the full matrix at
every commit.

The existing `quality_events` and `test_exposure_events` remain derived history
and compatibility views. After a successful delta transaction, Lineage updates
them only for touched logical units. A replacement result must be able to
decrease current kill coverage and retract current mutation verification;
append-only `MAX` semantics are not suitable for that projection.

### Transactional sync

Add a command resembling:

```sh
lineage sync-mutants \
  --db lineage.db \
  --repo . \
  --input mutation-delta.json.zst \
  --commit "$GITHUB_SHA"
```

Within one SQLite transaction it must:

1. verify that the commit exists in Lineage metadata;
2. compare the delta base digest with `mutation_corpora`;
3. apply current-state operations and tombstones;
4. resolve touched candidate locations to logical units at the head commit;
5. recompute only touched unit/component summaries;
6. record the immutable sync event; and
7. advance the corpus digest and commit.

Any failure rolls back the entire delta. Re-ingesting the same artifact ID is a
successful no-op. Reusing an artifact ID with different bytes is an error.

Initial bootstrap accepts a `mutation-corpus/v1` snapshot. Incremental sync
must not require downloading the prior snapshot when `lineage.db` already has
the matching state digest.

## Weak-test and SARIF behavior

Test Miser computes zero-kill tests and identical kill-set groups from the
materialized corpus, not from a PR delta.

- A test is a zero-kill audit candidate only when its complete current
  observation row contains no kills and the entire relevant corpus is
  auditable.
- Tests are possibly redundant only when their complete current kill sets are
  identical across the same auditable corpus generation.
- Tests selected for no candidates remain corpus/configuration warnings, not
  automatically weak tests.
- Any invalid component or unknown observation suppresses global findings that
  depend on that scope and is surfaced as staleness/unknown metadata.

The resulting Weak Tests SARIF records the corpus state digest. Lineage can
therefore display which exact mutation state justified the finding and retire
findings automatically when a later delta changes the signature.

## CI and artifact retention

### Base-commit resolution

Incremental application requires the state of the Git base, not merely "the
latest artifact". Test Miser needs a resolver with this default flow:

1. Accept the exact base/merge-base commit from the CI event or
   `mutation-plan/v1`.
2. Query the configured store for a corpus manifest keyed by repository,
   component generation, and that commit.
3. Download the manifest and compact snapshot, and verify repository, commit,
   generation, uncompressed state digest, and content digest.
4. If the exact snapshot is absent, walk first-parent ancestors to a checkpoint
   only when every ordered delta from that checkpoint through the requested
   base is still present. Verify every compare-and-swap link while replaying.
5. If no continuous verified path exists, declare a cache miss and run a full
   component mutation refresh. Never apply a delta to a merely similar or
   "latest" snapshot.
6. Apply the new run delta and publish both the immutable delta and a manifest
   for the head state.

The manifest is small, uncompressed JSON and contains artifact names/URLs,
compressed-byte digests, encoding, uncompressed state digest, component
generation, base/head commits, and completeness. The large corpus body is a
separate compressed object.

For GitHub Actions, the resolver queries successful mutation workflow runs by
head SHA and inspects their artifact manifests. Artifact names should include
the component, commit, and abbreviated state digest; names alone are not proof
of contents.

### Retention modes

GitHub run artifacts and Actions caches are expiring storage. They cannot be
the only copy of a distant checkpoint. There are two supported modes:

**Durable mode (recommended):** store content-addressed snapshots and deltas in
GHCR/another OCI registry, release assets, S3, or a durable Lineage service.
GitHub artifacts remain short-lived job handoff files. Lineage may also export
its current corpus as a verified snapshot when its database is the durable
authority.

**GitHub-only mode:** every successful default-branch mutation run downloads
the base-commit checkpoint and publishes a new compact full checkpoint for its
head, in addition to the small delta. The next run normally depends on only
the immediately preceding successful default-branch artifact, not a long
chain. If a repository is idle past artifact retention or an artifact is
deleted, the next run performs a full refresh. A scheduled checkpoint refresh
may reduce those cache misses, but is not a correctness mechanism.

PR artifacts are speculative. They can use the merge-base checkpoint to
produce review evidence, but they do not advance the canonical corpus. After
merge, default-branch CI creates the canonical delta/checkpoint for the actual
landed commit.

Recommended default-branch CI:

1. Resolve and verify the exact base-commit state using the algorithm above.
2. Run native incremental mutation selection and per-mutant test selection.
3. Upload immutable run fragments from parallel jobs.
4. Merge fragments into one delta and validate completeness.
5. Sync the delta into Lineage.
6. In durable mode, upload the delta and compact on policy; in GitHub-only
   mode, always materialize and upload a fresh compressed head snapshot.
7. Emit Weak Tests SARIF only from an auditable materialization.

The durable store keeps:

- the latest compact snapshot per active corpus generation;
- every delta after that snapshot until the next compaction; and
- sync manifests/digests long enough to audit Lineage history.

Compaction applies the delta chain, writes one new immutable snapshot, verifies
its digest against Lineage current state, then permits old run fragments and
superseded deltas to expire. Compaction does not change empirical state.

### Compression and measured size

Mutation JSON is highly repetitive and must be compressed at rest and in
transit. Measurements from the current workspace on 2026-07-19 are:

| Artifact | Contents | Raw JSON | gzip level 6 | zstd level 6 |
|---|---|---:|---:|---:|
| Espalier full Test Miser corpus | 66,893 mutants, 135 tests | 108,139,691 B | 2,570,121 B (2.38%) | 1,784,815 B (1.65%) |
| Zig Mutants report | representative runtime smoke | 441,784 B | 35,475 B (8.03%) | 30,500 B (6.90%) |
| Rust normalized facts | representative Lineage run | 19,066 B | 1,567 B (8.22%) | 1,560 B (8.18%) |

For comparison, encoding the same Espalier object graph as MessagePack
produced 87,519,575 B uncompressed (80.93% of the JSON), and 1,776,420 B with
zstd level 6 (1.64% of the raw JSON). MessagePack therefore saves about 20% if
left uncompressed, but only 8,395 B (0.47%) relative to compressed JSON. It
does not remove the need for compression.

The 108 MB Espalier corpus becoming 1.8 MB with zstd changes the storage
decision: JSON is acceptable as the logical v1 format, but raw snapshot JSON is
not an acceptable CI transport format.

Use canonical UTF-8 JSON compressed as `.json.zst`, with zstd level 6 as the
default balance. Compute `state_digest` over the canonical **uncompressed**
bytes and record a separate digest/length for the compressed object. This makes
identity independent of compression version and allows decompression-bomb and
truncation checks. Support gzip as an interoperability fallback; do not require
both encodings.

GitHub's artifact action ZIP-compresses uploads, but relying on that alone
means every download expands the 108 MB file before Test Miser can consume it.
Uploading an explicit `.json.zst` keeps cross-job downloads, local caches, and
non-GitHub stores uniformly small. Artifact ZIP wrapping then adds negligible
overhead.

Manifests and very small deltas may remain raw JSON, but implementations should
accept compressed deltas and should stream decompression/parsing. Snapshots
larger than 1 MiB raw should always be explicitly compressed. Avoid pretty
printing canonical artifacts. If future corpora stop compressing well or
parsing becomes the bottleneck, a dictionary-backed/columnar v2 can be
considered; the current measurements do not justify a binary v1 format.

MessagePack is not the v1 canonical format. Its small uncompressed improvement
does not solve artifact size, while compressed JSON is essentially the same
size and retains browser, command-line, schema-validation, and cross-language
tooling. Canonical JSON also gives the project one portable byte-level digest
definition; MessagePack permits multiple valid encodings for equivalent
values unless an additional canonical profile is specified. A future binary
transport may be added behind the same logical schema if measured decode time,
not storage size alone, becomes a bottleneck.

## Proposed Test Miser commands

The command surface should stay file-oriented:

```sh
# Merge parallel fragments for one planned run.
test-miser artifact merge-run --plan mutation-plan.json \
  --output run-facts.json.zst shard-*.json.zst

# Diff normalized run facts against a prior snapshot and emit tombstones.
test-miser artifact delta --base mutation-corpus.json.zst \
  --plan mutation-plan.json --input run-facts.json.zst \
  --output mutation-delta.json.zst

# Materialize and validate an ordered update.
test-miser artifact apply --base mutation-corpus.json.zst \
  --delta mutation-delta.json.zst --output next-corpus.json.zst

# Re-emit a canonical compact checkpoint.
test-miser artifact compact --input next-corpus.json.zst \
  --output compact-corpus.json.zst

# Infer Weak Tests only from an auditable snapshot.
test-miser infer --input compact-corpus.json.zst --output weak-tests.sarif
```

`test-miser-merge` can remain the compatibility command for current MTE shard
merging. Cross-revision application must be a separate operation because
same-run union and state replacement have different correctness rules.

## Implementation order

1. Specify canonical entity serialization, state digest, and
   `mutation-delta/v1`/`mutation-corpus/v1` JSON Schemas.
2. Add Test Miser normalization from existing `mutant-facts/v1` and MTE into
   the canonical entities.
3. Implement deterministic merge-run, delta, apply, and compact commands with
   tombstone and base-digest tests.
4. Add Lineage current-state tables and transactional snapshot bootstrap.
5. Add transactional delta sync and touched-unit summary refresh.
6. Move Weak Tests inference to the auditable materialized corpus and stamp
   SARIF with its state digest.
7. Wire default-branch CI to persist deltas, compact periodically, and sync
   Lineage after successful tests and mutation jobs.
8. Calibrate incremental snapshots against periodic full mutation runs. Any
   mismatch invalidates the affected generation and is a correctness bug.

## Acceptance criteria

- Applying a delta twice is idempotent.
- Applying it to the wrong base digest fails without database changes.
- Missing shards cannot produce a delta marked complete.
- Candidate/test deletions remove current evidence while preserving history.
- A killed-to-survived transition lowers current Lineage metrics.
- A renamed location with stable identity does not duplicate the candidate.
- Test changes invalidate prior observations over the required footprint.
- Disjoint component deltas update only their mapped logical units.
- Snapshot materialization is byte-deterministic after canonicalization.
- Compressed snapshot round trips preserve the canonical uncompressed state
  digest, and readers enforce the manifest's maximum uncompressed length.
- Expiration of the exact base checkpoint and any continuous ancestor delta
  chain causes a safe full refresh, never fallback to an unrelated latest
  artifact.
- Lineage state digest equals the digest of an independently materialized
  snapshot after every sync.
- Weak-test findings are identical between an incrementally materialized
  auditable corpus and a full-run corpus for the same commit.
